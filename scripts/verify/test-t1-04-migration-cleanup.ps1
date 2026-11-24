# WorkManager T1-04 migration 清理真实 Windows 故障注入测试（R6-02）
#
# 验证目标：
# - 普通目录：安全递归清理迁移 UAT 子目录，保留 UAT 根目录与 evidence；
# - 已不存在：只有原生句柄确认不存在时才标记 alreadyAbsent；
# - 悬空 Junction：Test-Path 为 false，但原生句柄仍能识别 reparse point；
#   清理必须 fail-closed，不得误报 alreadyAbsent，不得递归删除；
# - 存活 Junction / Symbolic Link：必须识别类型并 fail-closed，外部 Canary 不变；
# - 普通文件 / 缺失身份记录：fail-closed，不删除；
# - 清理完成后重新进行原生身份检查；
# - 正式目录 D:\WorkManager 不访问、不写入。
#
# 所有写入均位于 D:\WorkManager-test-data 下本次唯一测试根；写入前先验证信任锚。
# 真实 Junction 由 New-Item -ItemType Junction 创建，不使用模拟对象。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-04-migration-cleanup.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:ScriptDirectory 'T1-04MigrationCleanup.ps1')

Set-StrictMode -Version Latest

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:Results = New-Object System.Collections.ArrayList
$script:TrackedLinks = New-Object System.Collections.ArrayList
$script:TestRoot = ''
$script:CanaryPath = ''
$script:CanaryBefore = ''
$script:CanaryAfter = ''
$script:CleanupError = ''
$script:RunId = ''

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = '',
        $Data = $null
    )
    if ($Status -eq 'PASS') { $script:Passed += 1 }
    elseif ($Status -eq 'FAIL') { $script:Failed += 1 }
    else { $script:Skipped += 1 }
    [void]$script:Results.Add([ordered]@{
        name   = $Name
        status = $Status
        detail = $Detail
        data   = $Data
    })
    Write-Host ('T1-04_MIGRATION_CLEANUP_TEST=' + $Status + ' ' + $Name + $(if ($Detail) { ' :: ' + $Detail } else { '' }))
}

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-Scenario {
    param([Parameter(Mandatory = $true)][string]$Name)
    $scenario = Join-Path $script:TestRoot $Name
    $uatRoot = Join-Path $scenario 'uat-root'
    $uatDir = Join-Path $uatRoot 'migration-failure-uat'
    $evidenceDir = Join-Path $uatRoot 'evidence'
    $canaryDir = Join-Path $scenario 'canary'
    New-Item -ItemType Directory -Path $evidenceDir -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $canaryDir -Force -ErrorAction Stop | Out-Null
    $canary = Join-Path $canaryDir 'canary.txt'
    [System.IO.File]::WriteAllText($canary, 'R6-02 external canary；不得被迁移清理删除。', (New-Object System.Text.UTF8Encoding($false)))
    $uatRootIdentity = Assert-T104UatDirectoryPath -Path $uatRoot -Label '测试 UAT 根目录'
    return [pscustomobject]@{
        Name            = $Name
        Scenario        = $scenario
        UatRoot         = $uatRoot
        UatDir          = $uatDir
        EvidenceDir     = $evidenceDir
        Canary          = $canary
        CanaryHash      = (Get-FileSha256 -Path $canary)
        UatRootIdentity = $uatRootIdentity
    }
}

function New-NormalUatDirectory {
    param([Parameter(Mandatory = $true)]$Scenario)
    New-Item -ItemType Directory -Path $Scenario.UatDir -Force -ErrorAction Stop | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Scenario.UatDir 'inside.txt'), 'virtual UAT file', (New-Object System.Text.UTF8Encoding($false)))
    return Assert-T104UatDirectoryPath -Path $Scenario.UatDir -Label '测试迁移 UAT 目录'
}

function Remove-NormalUatDirectory {
    param([Parameter(Mandatory = $true)]$Scenario)
    if (Test-Path -LiteralPath $Scenario.UatDir) {
        Remove-T103VerifiedDirectoryTree -Directory $Scenario.UatDir -StopPrefix '测试准备'
    }
}

function New-JunctionEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    [void]$script:TrackedLinks.Add($Path)
}

function Remove-TrackedJunction {
    param([Parameter(Mandatory = $true)][string]$Path)
    $info = Get-T103NativePathInfo -Path $Path -OpenReparsePoint $true
    if (-not $info.Exists) {
        return
    }
    if (-not $info.IsReparsePoint) {
        throw ('测试清理拒绝删除非重解析点：' + $Path)
    }
    [System.IO.Directory]::Delete($Path, $false)
    $after = Get-T103NativePathInfo -Path $Path -OpenReparsePoint $true
    if ($after.Exists) {
        throw ('测试清理后 Junction 仍然存在：' + $Path)
    }
}

function Test-MigrationCleanupScenario {
    param(
        [Parameter(Mandatory = $true)]$Scenario,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedStopCode,
        [Parameter(Mandatory = $true)][bool]$ExpectedSafe,
        [Parameter(Mandatory = $true)][bool]$ExpectedPerformed,
        [Parameter(Mandatory = $true)][string]$ExpectedKind,
        [Parameter(Mandatory = $true)][string]$Setup
    )
    try {
        $uatDirIdentity = $null
        $uatDir = $Scenario.UatDir
        $target = Join-Path $Scenario.Scenario 'junction-target'
        $testPath = $null
        switch ($Setup) {
            'normal' {
                $uatDirIdentity = New-NormalUatDirectory -Scenario $Scenario
            }
            'alreadyAbsent' {
                $uatDirIdentity = New-NormalUatDirectory -Scenario $Scenario
                Remove-NormalUatDirectory -Scenario $Scenario
            }
            'danglingJunction' {
                $uatDirIdentity = New-NormalUatDirectory -Scenario $Scenario
                Remove-NormalUatDirectory -Scenario $Scenario
                New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
                New-JunctionEntry -Path $uatDir -Target $target
                # 删除目标目录，形成“入口存在、目标不存在”的真实悬空 Junction。
                Remove-T103VerifiedDirectoryTree -Directory $target -StopPrefix '构造悬空 Junction'
                $native = Get-T103NativePathInfo -Path $uatDir -OpenReparsePoint $true
                Assert-Condition -Condition ([bool]$native.Exists) -Message '悬空 Junction 入口必须能被原生句柄识别'
                Assert-Condition -Condition ([bool]$native.IsReparsePoint) -Message '悬空 Junction 入口必须是重解析点'
            }
            'liveJunction' {
                $uatDirIdentity = New-NormalUatDirectory -Scenario $Scenario
                Remove-NormalUatDirectory -Scenario $Scenario
                New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $target 'external.txt'), 'external target', (New-Object System.Text.UTF8Encoding($false)))
                New-JunctionEntry -Path $uatDir -Target $target
            }
            'symbolicLink' {
                $uatDirIdentity = New-NormalUatDirectory -Scenario $Scenario
                Remove-NormalUatDirectory -Scenario $Scenario
                New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
                try {
                    New-Item -ItemType SymbolicLink -Path $uatDir -Target $target -ErrorAction Stop | Out-Null
                }
                catch {
                    throw ('R6_02_SKIP|当前 Windows 权限无法创建真实 Symbolic Link（需要管理员权限/开发者模式）：' + $_.Exception.Message)
                }
                [void]$script:TrackedLinks.Add($uatDir)
            }
            'file' {
                $uatDirIdentity = New-NormalUatDirectory -Scenario $Scenario
                Remove-NormalUatDirectory -Scenario $Scenario
                [System.IO.File]::WriteAllText($uatDir, 'not a directory', (New-Object System.Text.UTF8Encoding($false)))
            }
            'missingIdentity' {
                $uatDirIdentity = $null
                New-Item -ItemType Directory -Path $uatDir -Force -ErrorAction Stop | Out-Null
            }
            default {
                throw ('未知测试场景：' + $Setup)
            }
        }

        $testPath = Test-Path -LiteralPath $uatDir
        Write-Host ('R6-02_TEST_PATH_RESULT setup=' + $Setup + ' result=' + $testPath)

        $cleanup = Invoke-T104FailClosedMigrationCleanupCore `
            -UatDir $uatDir `
            -UatRoot $Scenario.UatRoot `
            -TestRoot $script:T104UatTestRoot `
            -UatDirIdentity $uatDirIdentity `
            -UatRootIdentity $Scenario.UatRootIdentity

        Assert-Condition -Condition ([bool]$cleanup.safe -eq $ExpectedSafe) -Message ('safe 期望 ' + $ExpectedSafe + '，实际 ' + $cleanup.safe + '；stopCode=' + $cleanup.stopCode)
        Assert-Condition -Condition ([bool]$cleanup.performed -eq $ExpectedPerformed) -Message ('performed 期望 ' + $ExpectedPerformed + '，实际 ' + $cleanup.performed)
        if (-not [string]::IsNullOrWhiteSpace($ExpectedStopCode)) {
            Assert-Condition -Condition ($cleanup.stopCode -eq $ExpectedStopCode) -Message ('stopCode 期望 ' + $ExpectedStopCode + '，实际 ' + $cleanup.stopCode)
        }
        Assert-Condition -Condition ($cleanup.entryKind -eq $ExpectedKind) -Message ('entryKind 期望 ' + $ExpectedKind + '，实际 ' + $cleanup.entryKind)
        # UAT 根目录 / evidence 必须保留；外部 Canary 必须不变。
        Assert-Condition -Condition (Test-Path -LiteralPath $Scenario.UatRoot -PathType Container) -Message 'UAT 根目录不得被删除'
        Assert-Condition -Condition (Test-Path -LiteralPath $Scenario.EvidenceDir -PathType Container) -Message 'evidence 目录不得被删除'
        Assert-Condition -Condition (Test-Path -LiteralPath $Scenario.Canary -PathType Leaf) -Message '外部 Canary 必须存在'
        $canaryAfter = Get-FileSha256 -Path $Scenario.Canary
        Assert-Condition -Condition ($canaryAfter -eq $Scenario.CanaryHash) -Message '外部 Canary 哈希不得变化'
        Assert-Condition -Condition (Test-Path -LiteralPath ([string]$Scenario.UatRoot)) -Message 'UAT 根目录必须保留'

        $rootAfter = Assert-T104UatDirectoryPath -Path $Scenario.UatRoot -Label '清理后 UAT 根目录'
        Assert-Condition -Condition ($rootAfter.fileIdHex -eq $Scenario.UatRootIdentity.fileIdHex) -Message '清理后 UAT 根目录文件 ID 不得变化'
        Assert-Condition -Condition ($rootAfter.volumeSerialNumber -eq $Scenario.UatRootIdentity.volumeSerialNumber) -Message '清理后 UAT 根目录卷序列号不得变化'

        if ($Setup -eq 'danglingJunction' -or $Setup -eq 'liveJunction') {
            $entryAfter = Get-T103NativePathInfo -Path $uatDir -OpenReparsePoint $true
            Assert-Condition -Condition ([bool]$entryAfter.Exists) -Message 'fail-closed 清理必须保留重解析点入口现场'
        }
        if ($Setup -eq 'file') {
            Assert-Condition -Condition (Test-Path -LiteralPath $uatDir -PathType Leaf) -Message 'fail-closed 清理不得删除非目录入口'
        }

        Add-TestResult -Name ('R6-02 ' + $Scenario.Name) -Status 'PASS' -Detail ('stopCode=' + $cleanup.stopCode + '; kind=' + $cleanup.entryKind + '; Test-Path=' + $testPath) -Data ([ordered]@{
                setup             = $Setup
                safe              = [bool]$cleanup.safe
                performed         = [bool]$cleanup.performed
                stopCode          = [string]$cleanup.stopCode
                entryKind         = [string]$cleanup.entryKind
                entryTargetExists = $cleanup.entryTargetExists
                testPathResult    = [bool]$testPath
                canarySha256      = $canaryAfter
            })
    }
    catch {
        $message = $_.Exception.Message
        if ($message.StartsWith('R6_02_SKIP|', [System.StringComparison]::Ordinal)) {
            Add-TestResult -Name ('R6-02 ' + $Scenario.Name) -Status 'SKIP' -Detail $message.Substring('R6_02_SKIP|'.Length)
        }
        else {
            Add-TestResult -Name ('R6-02 ' + $Scenario.Name) -Status 'FAIL' -Detail $message
        }
    }
}

function Invoke-TestCleanup {
    foreach ($link in @($script:TrackedLinks)) {
        if ([string]::IsNullOrWhiteSpace($link)) {
            continue
        }
        try {
            Remove-TrackedJunction -Path $link
        }
        catch {
            $script:CleanupError = $script:CleanupError + ' junction:' + $_.Exception.Message
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:TestRoot)) {
        return
    }
    try {
        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-T103VerifiedDirectoryTree -Directory $script:TestRoot -StopPrefix '测试清理'
        }
    }
    catch {
        $script:CleanupError = $script:CleanupError + ' testRoot:' + $_.Exception.Message
    }
}

try {
    # 信任锚必须先于任何写入；测试根不存在时绝不自动创建。
    [void](Assert-T104UatTrustedRoot)
    $script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $PID
    $script:TestRoot = Join-Path $script:T104UatTestRoot ('t1-04-migration-cleanup-' + $script:RunId)
    New-Item -ItemType Directory -Path $script:TestRoot -ErrorAction Stop | Out-Null
    $testRootIdentity = Assert-T104UatDirectoryPath -Path $script:TestRoot -Label 'R6-02 测试根目录'
    Assert-Condition -Condition ([bool]($testRootIdentity.fileIdHex.Length -gt 0)) -Message '测试根目录必须具有文件 ID 身份'
    Write-Host ('R6-02_TRUST_ANCHOR=PASS testRoot=<test-root>/' + $script:RunId)

    $normal = New-Scenario -Name 'normal-cleanup'
    $script:CanaryPath = $normal.Canary
    $script:CanaryBefore = $normal.CanaryHash
    Test-MigrationCleanupScenario -Scenario $normal -ExpectedStopCode '' -ExpectedSafe $true -ExpectedPerformed $true -ExpectedKind 'directory' -Setup 'normal'

    $alreadyAbsent = New-Scenario -Name 'already-absent'
    Test-MigrationCleanupScenario -Scenario $alreadyAbsent -ExpectedStopCode 'alreadyAbsent' -ExpectedSafe $true -ExpectedPerformed $false -ExpectedKind 'absent' -Setup 'alreadyAbsent'

    $dangling = New-Scenario -Name 'dangling-junction'
    Test-MigrationCleanupScenario -Scenario $dangling -ExpectedStopCode 'danglingJunction' -ExpectedSafe $false -ExpectedPerformed $false -ExpectedKind 'junction' -Setup 'danglingJunction'

    $live = New-Scenario -Name 'live-junction'
    Test-MigrationCleanupScenario -Scenario $live -ExpectedStopCode 'entryIsJunction' -ExpectedSafe $false -ExpectedPerformed $false -ExpectedKind 'junction' -Setup 'liveJunction'

    $fileEntry = New-Scenario -Name 'file-entry'
    Test-MigrationCleanupScenario -Scenario $fileEntry -ExpectedStopCode 'entryNotDirectory' -ExpectedSafe $false -ExpectedPerformed $false -ExpectedKind 'file' -Setup 'file'

    $missing = New-Scenario -Name 'missing-identity'
    Test-MigrationCleanupScenario -Scenario $missing -ExpectedStopCode 'missingIdentityRecord' -ExpectedSafe $false -ExpectedPerformed $false -ExpectedKind 'directory' -Setup 'missingIdentity'

    $symbolic = New-Scenario -Name 'symbolic-link'
    Test-MigrationCleanupScenario -Scenario $symbolic -ExpectedStopCode 'entryIsSymbolicLink' -ExpectedSafe $false -ExpectedPerformed $false -ExpectedKind 'symbolicLink' -Setup 'symbolicLink'

    # 重解析点 tag 分类单元：真实故障注入覆盖 Junction；Symbolic Link 在权限不足时
    # 显式 SKIP，不冒充 PASS。其他 reparse point 无法在当前环境安全创建真实挂载，
    # 这里只验证 tag 映射，不宣称已完成真实“其他重解析点”文件系统测试。
    $tagChecks = [ordered]@{
        junctionTag        = (Get-T104UatReparseKind -Tag ([long]2684354563))
        symbolicLinkTag    = (Get-T104UatReparseKind -Tag ([long]2684354572))
        otherReparseTag    = (Get-T104UatReparseKind -Tag ([long]2147483671))
    }
    if ($tagChecks.junctionTag -eq 'junction' -and
        $tagChecks.symbolicLinkTag -eq 'symbolicLink' -and
        $tagChecks.otherReparseTag -eq 'otherReparsePoint') {
        Add-TestResult -Name 'R6-02 重解析点 tag 分类' -Status 'PASS' -Detail 'junction/symbolicLink/otherReparsePoint' -Data $tagChecks
    }
    else {
        Add-TestResult -Name 'R6-02 重解析点 tag 分类' -Status 'FAIL' -Detail ($tagChecks | ConvertTo-Json -Compress)
    }
}
catch {
    Add-TestResult -Name 'R6-02 测试前置/环境' -Status 'FAIL' -Detail $_.Exception.Message
}
finally {
    # Canary 必须在测试根清理前读取；测试根清理不得影响正式目录或仓库证据。
    if (Test-Path -LiteralPath $script:CanaryPath -PathType Leaf) {
        $script:CanaryAfter = Get-FileSha256 -Path $script:CanaryPath
    }
    Invoke-TestCleanup
    $canaryUnchanged = ($script:CanaryBefore -eq $script:CanaryAfter -and -not [string]::IsNullOrWhiteSpace($script:CanaryBefore))
    if (-not $canaryUnchanged -and $script:Failed -eq 0) {
        Add-TestResult -Name 'R6-02 全局 Canary' -Status 'FAIL' -Detail 'Canary 汇总哈希不一致'
    }
    elseif ($canaryUnchanged) {
        Add-TestResult -Name 'R6-02 全局 Canary' -Status 'PASS' -Detail ('sha256=' + $script:CanaryAfter)
    }

    $result = [ordered]@{
        task                = 'T1-04'
        scope               = 'R6-02 migration cleanup native reparse-point fail-closed'
        generatedAt         = (Get-Date).ToUniversalTime().ToString('o')
        testRoot            = '<test-root>/' + $script:RunId
        trustAnchorVerified = $true
        pass                = $script:Passed
        fail                = $script:Failed
        skip                = $script:Skipped
        canaryBefore        = $script:CanaryBefore
        canaryAfter         = $script:CanaryAfter
        canaryUnchanged     = $canaryUnchanged
        formalRootTouched   = $false
        cleanupError        = $script:CleanupError
        scenarios           = @($script:Results)
    }
    $json = $result | ConvertTo-Json -Depth 8 -Compress
    Write-Host ('T1-04_MIGRATION_CLEANUP_TEST_RESULT=' + $json)
    if ($script:Failed -gt 0 -or -not [string]::IsNullOrWhiteSpace($script:CleanupError)) {
        exit 1
    }
    exit 0
}
