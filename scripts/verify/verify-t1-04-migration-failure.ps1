# WorkManager T1-04 Release migration failure rollback verification (T104-04)
#
# 第六轮 R2-02 修复：不再使用 [System.IO.Path]::GetFullPath(...).StartsWith(...)
# 字符串路径判断，也不再直接 New-Item / Copy-Item / Start-Process / sqlite 操作。
# 所有 UAT 根目录、数据库目录、数据库文件、证据目录在创建 / 复制 EXE / 启动
# Release / 连接 SQLite 之前，必须通过 T1-04 原生路径守卫（复用 T1-03 Windows
# 原生句柄、信任锚、重解析点拒绝、卷序列号 + 文件 ID + 真实最终路径校验）。
# 清理复用 T1-03 fail-closed 安全清理：先复验 UAT 迁移目录身份，再扫描重解析点，
# 全部通过后才逐条目安全递归删除；身份变化 / 重解析点 / 守卫失败时保留现场，
# 不得强制递归删除。
#
# 业务验证（不削弱原测试）：
# - 构造真实 schema 3 隔离 UAT 数据库（真实 0001/0002/0003 SQL + 虚构历史数据）；
# - 从真实 0004 SQL 读取索引名并预先创建同名冲突索引；
# - 启动 Release EXE：必须显示原生“WorkManager 启动失败”对话框、退出码非 0；
# - migration 必须整体回滚：user_version 仍 3、无 version 4、无两张新表、
#   历史项目/工作事项不变、integrity_check=ok。
#
# 只操作 D:\WorkManager-test-data 下的独立 UAT，不打开/修改/故障注入正式目录。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-04-migration-failure.ps1 `
#       [-ExePath <releaseExe>] `
#       [-OutputDir <newUatDir>] `
#       [-EvidencePath <OutputDir>\evidence\<file>.json]

[CmdletBinding()]
param(
    [string]$ExePath = '',
    [string]$OutputDir = '',
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:ScriptDirectory 'VerifyCommon.ps1')
. (Join-Path $script:ScriptDirectory 'T1-04UatPath.ps1')

$script:TestRootLiteral = $script:T104UatTestRoot
$script:FormalRootLiteral = $script:T104UatFormalRoot
$script:RepoRoot = (Resolve-Path (Join-Path $script:ScriptDirectory '..\..')).Path
$script:FixtureScript = Join-Path $script:ScriptDirectory 't1-04-migration-fixture.py'
$script:ExitCode = 0
$script:UatDir = ''
$script:UatDirIdentity = $null
$script:UatRootIdentity = $null
$script:OutputFull = ''
$script:EvidenceDir = ''
$script:EvidenceDirReady = $false
$script:DatabasePath = ''
$script:Process = $null

$script:Result = [ordered]@{
    task                      = 'T1-04'
    round                     = 'round6'
    scope                     = 'T104-04 Release migration failure rollback + native path guards'
    generatedAt               = (Get-Date).ToUniversalTime().ToString('o')
    status                    = 'fail'
    releaseExeSha256          = ''
    releaseExeSizeBytes       = 0
    trustAnchorVerified       = $false
    uatRoot                   = '<uat-root>'
    evidencePath              = '<evidence-path>'
    guards                    = [ordered]@{}
    migrationFailure          = [ordered]@{
        dialogFound      = $false
        dialogTitle      = ''
        releaseExitCode  = $null
        probeExitCode    = $null
        rollbackPass     = $false
        invariants       = $null
    }
    cleanup                   = [ordered]@{
        performed = $false
        safe      = $false
        stopCode  = ''
        stopReason = ''
        steps     = @()
        uatRootIdentityUnchanged = $false
    }
    failure                   = ''
    residualRisk              = 'TOCTOU concurrent replacement remains deferred by DEC-029 / Issue #2'
}

function Format-T104EvidenceText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    $text = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($script:TestRootLiteral)) {
        $text = $text.Replace($script:TestRootLiteral, '<test-root>')
    }
    if (-not [string]::IsNullOrWhiteSpace($script:FormalRootLiteral)) {
        $text = $text.Replace($script:FormalRootLiteral, '<formal-root>')
    }
    if (-not [string]::IsNullOrWhiteSpace($script:RepoRoot)) {
        $text = $text.Replace($script:RepoRoot, '<repo-root>')
    }
    return $text
}

function Set-T104ResultGuard {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $script:Result.guards[$Name] = [ordered]@{
        pass   = $Pass
        detail = (Format-T104EvidenceText $Detail)
    }
    if ($Pass) {
        Write-Host ('T104_MIGRATION_PATH_GUARD=PASS ' + $Name)
    }
    else {
        Write-Host ('T104_MIGRATION_PATH_GUARD=FAIL ' + $Name + ' ' + $Detail)
    }
}

function Write-T104MigrationEvidence {
    if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
        return $true
    }
    if (-not $script:EvidenceDirReady) {
        Write-Host 'MIGRATION_FAILURE_EVIDENCE=SKIPPED evidence directory was not prepared'
        return $true
    }
    try {
        # 写入前验证证据文件边界：只能是 <UAT根>\evidence\<file>.json 的直接子文件，
        # 证据目录必须已存在并通过原生目录身份校验。
        [void](Assert-T104UatEvidenceFileWithinUatRoot `
            -UatRoot $script:OutputFull `
            -EvidenceDirectory $script:EvidenceDir `
            -Path $EvidencePath)
        $json = ($script:Result | ConvertTo-Json -Depth 8)
        [System.IO.File]::WriteAllText($EvidencePath, $json, (New-Object System.Text.UTF8Encoding($false)))
        # 写入后复验实际文件身份（普通文件、非重解析点、最终路径一致）。
        [void](Assert-T104UatEvidenceFileWithinUatRoot `
            -UatRoot $script:OutputFull `
            -EvidenceDirectory $script:EvidenceDir `
            -Path $EvidencePath)
        Write-Host 'MIGRATION_FAILURE_EVIDENCE=PASS'
        return $true
    }
    catch {
        Write-Host ('MIGRATION_FAILURE_EVIDENCE=FAIL: ' + $_.Exception.Message)
        return $false
    }
}

function Invoke-T104FailClosedMigrationCleanup {
    if ([string]::IsNullOrWhiteSpace($script:UatDir) -or -not (Test-Path -LiteralPath $script:UatDir)) {
        $script:Result.cleanup.performed = $false
        $script:Result.cleanup.safe = $true
        $script:Result.cleanup.stopCode = 'alreadyAbsent'
        Write-Host 'MIGRATION_FAILURE_CLEANUP=PASS alreadyAbsent'
        return $true
    }
    if ($null -eq $script:UatDirIdentity -or $null -eq $script:UatRootIdentity) {
        $script:Result.cleanup.performed = $false
        $script:Result.cleanup.safe = $false
        $script:Result.cleanup.stopCode = 'missingIdentityRecord'
        $script:Result.cleanup.stopReason = '缺少创建时记录的目录身份，拒绝删除。'
        Write-Host 'MIGRATION_FAILURE_CLEANUP=FAIL missingIdentityRecord'
        return $false
    }
    try {
        # 清理前重新验证 UAT 根目录身份（卷序列号 + 文件 ID + 真实最终路径）。
        $currentRoot = Assert-T104UatDirectoryPath -Path $script:OutputFull -Label 'UAT 根目录'
        if (($currentRoot.fileIdHex -ne $script:UatRootIdentity.fileIdHex) -or
            ($currentRoot.volumeSerialNumber -ne $script:UatRootIdentity.volumeSerialNumber) -or
            (-not (Test-T103FinalPathEquals ([string]$currentRoot.finalPath) ([string]$script:UatRootIdentity.finalPath)))) {
            throw '清理前 UAT 根目录身份发生变化，拒绝删除。'
        }
        $script:Result.cleanup.uatRootIdentityUnchanged = $true
        # 复用 T1-03 fail-closed 安全清理：复验迁移目录身份 → 扫描重解析点 →
        # 复验身份 → 逐条目校验安全递归删除。身份不符/异常时不执行递归删除。
        $cleanupResult = Invoke-T103FailClosedSandboxCleanup `
            -SandboxPath $script:UatDir `
            -TestRoot $script:T104UatTestRoot `
            -TrustRecord $script:UatDirIdentity `
            -TrackedLinks @()
        $script:Result.cleanup.performed = [bool]$cleanupResult.recursiveDeletePerformed
        $script:Result.cleanup.safe = [bool]$cleanupResult.safe
        $script:Result.cleanup.stopCode = [string]$cleanupResult.stopCode
        $script:Result.cleanup.stopReason = (Format-T104EvidenceText ([string]$cleanupResult.stopReason))
        $script:Result.cleanup.steps = @($cleanupResult.steps)
        $uatStillExists = Test-Path -LiteralPath $script:UatDir
        if ([bool]$cleanupResult.safe -ne $true -or $uatStillExists) {
            Write-Host ('MIGRATION_FAILURE_CLEANUP=FAIL ' + [string]$cleanupResult.stopCode + ' ' + [string]$cleanupResult.stopReason)
            return $false
        }
        # 清理后复验 UAT 根目录身份未变化（fail-closed 清理不得触碰根目录本身）。
        $afterRoot = Assert-T104UatDirectoryPath -Path $script:OutputFull -Label 'UAT 根目录'
        if (($afterRoot.fileIdHex -ne $script:UatRootIdentity.fileIdHex) -or
            ($afterRoot.volumeSerialNumber -ne $script:UatRootIdentity.volumeSerialNumber)) {
            $script:Result.cleanup.safe = $false
            $script:Result.cleanup.stopCode = 'uatRootIdentityChangedAfterCleanup'
            Write-Host 'MIGRATION_FAILURE_CLEANUP=FAIL uatRootIdentityChangedAfterCleanup'
            return $false
        }
        Write-Host 'MIGRATION_FAILURE_CLEANUP=PASS'
        return $true
    }
    catch {
        $script:Result.cleanup.safe = $false
        $script:Result.cleanup.stopCode = 'unexpectedCleanupGuardError'
        $script:Result.cleanup.stopReason = (Format-T104EvidenceText $_.Exception.Message)
        Write-Host ('MIGRATION_FAILURE_CLEANUP=FAIL: ' + $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------------------
# 前置条件（不产生文件系统副作用）
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $ExePath = Join-Path $script:RepoRoot 'target\release\workmanager.exe'
}
if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: Release EXE not found: $ExePath"
    exit 2
}
if (-not (Test-Path -LiteralPath $script:FixtureScript -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: fixture script not found: $script:FixtureScript"
    exit 2
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host 'PRECONDITION_FAILED: python not available'
    exit 2
}
$exeInfo = Get-Item -LiteralPath $ExePath
$script:Result.releaseExeSha256 = (Get-FileHash -Path $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
$script:Result.releaseExeSizeBytes = [long]$exeInfo.Length

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $script:TestRootLiteral ('t1-04-migration-failure-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

# 信任锚必须先于任何写操作完成：测试根目录自身、全部祖先、重解析点、卷身份、
# 真实最终路径；失败时 fail closed，不创建任何 UAT 目录。
try {
    $script:TrustRecord = Assert-T104UatTrustedRoot
    $script:Result.trustAnchorVerified = $true
    Write-Host ('T104_MIGRATION_PATH_GUARD=PASS trustRoot components=' + [string]$script:TrustRecord.existingComponentCount)
}
catch {
    Write-Host ('PRECONDITION_FAILED: trust anchor failed: ' + $_.Exception.Message)
    exit 2
}

# 输出目录 / UAT 根目录 / 证据文件结构：在任何写操作之前完成原生守卫规划期校验；
# 守卫拒绝时退出码 2（PRECONDITION_FAILED），不创建任何目录。
$script:OutputFull = ''
$evidenceFull = ''
try {
    $script:OutputFull = Get-T103UatNormalizedPath $OutputDir
    $plannedUat = Assert-T104UatPlannedDirectory -Path $script:OutputFull -Label 'UAT 根目录'
    if ([bool]$plannedUat.targetExists) {
        throw 'output directory already exists; use a new UAT directory'
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $evidenceFull = Get-T103UatNormalizedPath $EvidencePath
        $expectedEvidenceDir = Join-Path $script:OutputFull 'evidence'
        if (-not (Test-T103UatPathInside $evidenceFull $script:OutputFull)) {
            throw 'evidence path must be inside the output UAT root'
        }
        if (-not (Test-T103FinalPathEquals (Split-Path -Parent $evidenceFull) $expectedEvidenceDir)) {
            throw 'evidence path must be <OutputDir>\evidence\<file>.json'
        }
        if (-not ([System.IO.Path]::GetExtension($evidenceFull).Equals('.json', [System.StringComparison]::OrdinalIgnoreCase))) {
            throw 'evidence file extension must be .json'
        }
        $script:Result.evidencePath = '<evidence-path>'
    }
    Set-T104ResultGuard -Name 'uatRootTarget' -Pass $true -Detail 'planned=true targetExists=false'
}
catch {
    Write-Host ('PRECONDITION_FAILED: ' + $_.Exception.Message)
    exit 2
}

try {
    # -----------------------------------------------------------------------
    # 1. 创建 UAT 根目录并复验身份；数据库/证据目录随后按规划期守卫创建
    # -----------------------------------------------------------------------
    New-Item -ItemType Directory -Path $script:OutputFull -ErrorAction Stop | Out-Null
    $script:UatRootIdentity = Assert-T104UatDirectoryPath -Path $script:OutputFull -Label 'UAT 根目录'
    Set-T104ResultGuard -Name 'uatRootCreated' -Pass $true -Detail 'uatRootIdentityVerified=true'

    $script:UatDir = Join-Path $script:OutputFull 'migration-failure-uat'
    $appDir = Join-Path $script:UatDir 'app'
    $dbDir = Join-Path $appDir 'data\database'
    $script:DatabasePath = Join-Path $dbDir 'work.db'
    $script:EvidenceDir = Join-Path $script:OutputFull 'evidence'
    $evidenceDirPlanned = $false

    # -----------------------------------------------------------------------
    # 2. 数据库目录 / 证据目录：规划期安全创建目标守卫
    # -----------------------------------------------------------------------
    [void](Assert-T104UatPlannedDatabaseFile -Path $script:DatabasePath)
    Set-T104ResultGuard -Name 'databaseTarget' -Pass $true -Detail 'databaseTargetPlanned=true'
    $evidenceDirPlan = Assert-T104UatPlannedEvidenceDirectory -UatRoot $script:OutputFull -Path $script:EvidenceDir
    $evidenceDirPlanned = -not [bool]$evidenceDirPlan.targetExists
    Set-T104ResultGuard -Name 'evidenceDirectoryTarget' -Pass $evidenceDirPlanned -Detail ('planned=' + [string]$evidenceDirPlanned)

    # -----------------------------------------------------------------------
    # 3. 创建目录，并在每个目录创建后复验实际身份
    # -----------------------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $dbDir -ErrorAction Stop | Out-Null
    $script:UatDirIdentity = Assert-T104UatDirectoryPath -Path $script:UatDir -Label 'UAT 迁移目录'
    [void](Assert-T104UatDirectoryPath -Path $dbDir -Label '数据库目录')
    Set-T104ResultGuard -Name 'databaseDirectoryCreated' -Pass $true -Detail 'databaseDirectoryIdentityVerified=true'

    New-Item -ItemType Directory -Force -Path $script:EvidenceDir -ErrorAction Stop | Out-Null
    $evidenceDirRecord = Assert-T104UatPlannedEvidenceDirectory -UatRoot $script:OutputFull -Path $script:EvidenceDir
    if (-not [bool]$evidenceDirRecord.targetExists) {
        throw 'evidence directory was not created'
    }
    $script:EvidenceDirReady = $true
    Set-T104ResultGuard -Name 'evidenceDirectoryCreated' -Pass $true -Detail 'evidenceDirectoryIdentityVerified=true'

    [void](Assert-T104UatPlannedDirectory -Path $appDir -Label '应用目录')
    New-Item -ItemType Directory -Force -Path $appDir -ErrorAction Stop | Out-Null
    [void](Assert-T104UatDirectoryPath -Path $appDir -Label '应用目录')

    # -----------------------------------------------------------------------
    # 4. 复制 EXE / 启动 Release 之前再次复验实际路径身份
    # -----------------------------------------------------------------------
    [void](Assert-T104UatDirectoryPath -Path $script:OutputFull -Label 'UAT 根目录')
    [void](Assert-T104UatDirectoryPath -Path $dbDir -Label '数据库目录')
    Copy-Item -LiteralPath $ExePath -Destination (Join-Path $appDir 'WorkManager.exe') -Force
    [void](Assert-T104UatDirectoryPath -Path $appDir -Label '应用目录')
    Set-T104ResultGuard -Name 'releaseExeCopied' -Pass $true -Detail 'pathIdentityReVerifiedBeforeRelease=true'

    if (-not [string]::IsNullOrWhiteSpace($evidenceFull)) {
        [void](Assert-T104UatEvidenceFileWithinUatRoot `
            -UatRoot $script:OutputFull `
            -EvidenceDirectory $script:EvidenceDir `
            -Path $evidenceFull)
        Set-T104ResultGuard -Name 'evidenceFileTarget' -Pass $true -Detail 'evidenceFileBoundaryVerified=true'
    }

    # -----------------------------------------------------------------------
    # 5. 真实 schema 3 fixture（Python 内部再次调用原生守卫）
    # -----------------------------------------------------------------------
    & python -X utf8 $script:FixtureScript setup $script:RepoRoot $script:DatabasePath
    if ($LASTEXITCODE -ne 0) {
        throw 'schema 3 fixture setup failed'
    }
    $script:Result.guards['fixtureSetup'] = [ordered]@{ pass = $true; detail = 'schema3FixtureCreated=true' }
    [void](Assert-T104UatDatabaseFile -Path $script:DatabasePath)
    [void](Assert-T104UatEvidenceDirectory -DatabasePath $script:DatabasePath -EvidenceDirectory $script:EvidenceDir)
    Set-T104ResultGuard -Name 'databaseAndEvidenceAfterFixture' -Pass $true -Detail 'databaseFileIdentityVerified=true evidenceDirectoryIdentityVerified=true'

    # -----------------------------------------------------------------------
    # 6. 启动 Release EXE：真实 migration 失败回滚
    # -----------------------------------------------------------------------
    $script:Process = Start-Process -FilePath (Join-Path $appDir 'WorkManager.exe') -WorkingDirectory $appDir -PassThru
    $dialog = Wait-FailureDialog -Process $script:Process -TimeoutSeconds 40
    $script:Result.migrationFailure.dialogFound = [bool]$dialog.found
    $script:Result.migrationFailure.dialogTitle = [string]$dialog.title
    Write-Host ('MIGRATION_FAILURE_DIALOG_FOUND=' + [bool]$dialog.found)
    Write-Host ('MIGRATION_FAILURE_DIALOG_TITLE=' + [string]$dialog.title)
    if (-not $dialog.found) {
        throw ('startup failure dialog not found; exited=' + [bool]$dialog.process_exited + '; exit=' + [string]$dialog.exit_code)
    }
    $closeMethod = Close-FailureDialog -Dialog $dialog -Process $script:Process
    Write-Host ('MIGRATION_FAILURE_DIALOG_CLOSE=' + $closeMethod)
    if (-not $script:Process.WaitForExit(15000)) {
        throw 'process did not exit after failure dialog close'
    }
    $releaseExitCode = [int]$script:Process.ExitCode
    $script:Result.migrationFailure.releaseExitCode = $releaseExitCode
    Write-Host ('MIGRATION_FAILURE_EXIT_CODE=' + [string]$releaseExitCode)
    if ($releaseExitCode -eq 0) {
        throw 'migration failure unexpectedly exited 0'
    }

    # 只读探针（Python 内部在连接前调用原生守卫，失败不降级、不打开其他路径）。
    $json = & python -X utf8 $script:FixtureScript probe $script:DatabasePath
    $probeExitCode = $LASTEXITCODE
    $script:Result.migrationFailure.probeExitCode = $probeExitCode
    if ($probeExitCode -ne 0) {
        throw 'post-failure read-only probe failed'
    }
    Write-Host ('MIGRATION_FAILURE_DB=' + $json)
    $db = $json | ConvertFrom-Json
    $script:Result.migrationFailure.invariants = [ordered]@{
        user_version     = [int]$db.user_version
        projects         = [int]$db.projects
        work_items       = [int]$db.work_items
        schema_migrations = [int]$db.schema_migrations
        version4_rows    = [int]$db.version4_rows
        group_table      = [int]$db.group_table
        member_table     = [int]$db.member_table
        integrity_check  = [string]$db.integrity_check
    }
    if ($db.user_version -ne 3 -or $db.version4_rows -ne 0 -or $db.group_table -ne 0 -or
        $db.member_table -ne 0 -or $db.projects -ne 1 -or $db.work_items -ne 1 -or
        $db.integrity_check -ne 'ok') {
        throw ('migration rollback invariants failed: ' + $json)
    }
    $script:Result.migrationFailure.rollbackPass = $true
    $script:Result.status = 'pass'
    Write-Host 'MIGRATION_FAILURE_ROLLBACK=PASS'
}
catch {
    $script:Result.failure = (Format-T104EvidenceText $_.Exception.Message)
    Write-Host ('MIGRATION_FAILURE_ROLLBACK=FAIL: ' + $_.Exception.Message)
    $script:ExitCode = 1
}
finally {
    if ($null -ne $script:Process -and -not $script:Process.HasExited) {
        try { $script:Process.Kill() } catch { }
        try { [void]$script:Process.WaitForExit(5000) } catch { }
    }

    $cleanupPass = Invoke-T104FailClosedMigrationCleanup

    $evidencePass = Write-T104MigrationEvidence

    $script:Result.status = if ($script:Result.migrationFailure.rollbackPass -and $cleanupPass) { 'pass' } else { 'fail' }
    if (-not $cleanupPass) {
        $script:ExitCode = 1
    }
    if (-not $evidencePass) {
        $script:ExitCode = 1
    }
    Write-Host ('T104_MIGRATION_RESULT_STATUS=' + [string]$script:Result.status)
}
exit $script:ExitCode
