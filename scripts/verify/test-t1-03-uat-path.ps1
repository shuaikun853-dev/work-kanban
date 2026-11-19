# WorkManager T1-03 UAT 输出目录安全专项测试（P3-02 修复验收）
#
# 覆盖：
# - 合法的新 UAT 目录允许；
# - C 盘目录拒绝；
# - D:\WorkManager（正式应用目录）拒绝；
# - 专用测试根目录以外的 D 盘目录拒绝；
# - 含 .. 的路径规范化后越界拒绝；
# - 已包含数据库的目录拒绝；
# - 存在的非空未知目录不得静默覆盖/删除；
# - 主编排脚本对不安全目录返回退出码 2 且不启动应用。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1
# 可选：-EvidencePath <file>
# 退出码：0 = 全部 PASS；1 = 存在 FAIL；2 = 前置条件不满足。

[CmdletBinding()]
param(
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$verifyScript = Join-Path $PSScriptRoot 'verify-t1-03-ui.ps1'
$pathScript = Join-Path $PSScriptRoot 'T1-03UatPath.ps1'
. $pathScript

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repoRoot 'docs/testing/reports/T1-03-assets/evidence/t1-03-uat-path-evidence.json'
}

$script:Checks = New-Object System.Collections.ArrayList

function Add-UatPathCheck([string]$Name, [bool]$Pass, [string]$Detail) {
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; pass = $Pass; detail = $Detail })
    if ($Pass) {
        Write-Host "PASS $Name — $Detail"
    }
    else {
        Write-Host "FAIL $Name — $Detail"
    }
}

function Format-EvidencePath([string]$Value) {
    $text = $Value
    $testRoot = Get-T103UatNormalizedPath $script:T103UatTestRoot
    $formalRoot = Get-T103UatNormalizedPath $script:T103UatFormalRoot
    $text = $text.Replace($testRoot, '<uat-root>').Replace($formalRoot, '<formal-root>').Replace($repoRoot, '<repo-root>')
    return $text
}

function Test-UatPathAllowed([string]$Name, [string]$RequestedPath, [string]$ExpectedPrefix = '') {
    try {
        $resolved = Resolve-T103UatOutputDirectory -RequestedPath $RequestedPath
        $prefixOk = $true
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPrefix)) {
            $prefixOk = $resolved.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        }
        Add-UatPathCheck -Name $Name -Pass $prefixOk -Detail ("allowed: " + (Format-EvidencePath $resolved))
    }
    catch {
        Add-UatPathCheck -Name $Name -Pass $false -Detail ("unexpected rejection: " + (Format-EvidencePath $_.Exception.Message))
    }
}

function Test-UatPathRejected([string]$Name, [string]$RequestedPath, [string]$ExpectedKeyword) {
    try {
        $resolved = Resolve-T103UatOutputDirectory -RequestedPath $RequestedPath
        Add-UatPathCheck -Name $Name -Pass $false -Detail ("unexpected allow: " + (Format-EvidencePath $resolved))
    }
    catch {
        $message = $_.Exception.Message
        $keywordOk = $message.Contains($ExpectedKeyword)
        Add-UatPathCheck -Name $Name -Pass $keywordOk -Detail ("rejected: " + (Format-EvidencePath $message))
    }
}

if (-not (Test-Path $verifyScript -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: 编排脚本不存在：$verifyScript"
    exit 2
}

# ---------------------------------------------------------------------------
# 准备隔离测试沙箱（只创建/清理本脚本自己创建的目录）
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sandbox = Join-Path $script:T103UatTestRoot ('t1-03-path-safety-' + $timestamp + '-' + $PID)
if (-not (Test-T103UatPathInside $sandbox $script:T103UatTestRoot)) {
    Write-Host 'PRECONDITION_FAILED: 测试沙箱不在专用测试根目录内，拒绝创建'
    exit 2
}
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

$emptyExisting = Join-Path $sandbox 'empty-existing'
$nonEmptyExisting = Join-Path $sandbox 'non-empty-existing'
$withDatabase = Join-Path $sandbox 'with-database'
$freshDir = Join-Path $sandbox ('fresh-' + $timestamp)
New-Item -ItemType Directory -Force -Path $emptyExisting | Out-Null
New-Item -ItemType Directory -Force -Path $nonEmptyExisting | Out-Null
Set-Content -Path (Join-Path $nonEmptyExisting 'unknown-user-file.txt') -Value 'must-not-be-deleted' -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $withDatabase 'app\data\database') | Out-Null
Set-Content -Path (Join-Path $withDatabase 'app\data\database\work.db') -Value 'existing-uat-database' -Encoding UTF8

try {
    # -----------------------------------------------------------------------
    # 1. 校验函数单元测试（不启动应用）
    # -----------------------------------------------------------------------
    Test-UatPathAllowed -Name 'unit.freshNewUatDirectoryAllowed' -RequestedPath $freshDir -ExpectedPrefix $script:T103UatTestRoot
    Test-UatPathAllowed -Name 'unit.emptyExistingDirectoryAllowed' -RequestedPath $emptyExisting -ExpectedPrefix $script:T103UatTestRoot
    Test-UatPathAllowed -Name 'unit.caseInsensitiveRootAllowed' -RequestedPath ($freshDir.ToLowerInvariant()) -ExpectedPrefix $script:T103UatTestRoot
    Test-UatPathAllowed -Name 'unit.normalizedDotDotInsideAllowed' -RequestedPath ($sandbox + '\..\' + (Split-Path $sandbox -Leaf) + '\fresh-normalized') -ExpectedPrefix $script:T103UatTestRoot

    Test-UatPathRejected -Name 'unit.cDriveRejected' -RequestedPath 'C:\WorkManager-test-data\t1-03-ui-reject' -ExpectedKeyword '专用测试根目录'
    Test-UatPathRejected -Name 'unit.formalRootRejected' -RequestedPath 'D:\WorkManager' -ExpectedKeyword '正式应用目录'
    Test-UatPathRejected -Name 'unit.formalRootSubdirectoryRejected' -RequestedPath 'D:\WorkManager\data\uat' -ExpectedKeyword '正式应用目录'
    Test-UatPathRejected -Name 'unit.outsideTestRootDDriveRejected' -RequestedPath 'D:\OtherWorkManagerDir\t1-03-ui' -ExpectedKeyword '专用测试根目录'
    Test-UatPathRejected -Name 'unit.dotDotEscapeToFormalRejected' -RequestedPath ('D:\WorkManager-test-data\..\WorkManager') -ExpectedKeyword '正式应用目录'
    Test-UatPathRejected -Name 'unit.dotDotEscapeOutsideRejected' -RequestedPath ('D:\WorkManager-test-data\..\OtherWorkManagerDir') -ExpectedKeyword '专用测试根目录'
    Test-UatPathRejected -Name 'unit.testRootItselfRejected' -RequestedPath 'D:\WorkManager-test-data' -ExpectedKeyword '根目录本身'
    Test-UatPathRejected -Name 'unit.testRootWithTrailingSlashRejected' -RequestedPath 'D:\WorkManager-test-data\' -ExpectedKeyword '根目录本身'
    Test-UatPathRejected -Name 'unit.relativePathRejected' -RequestedPath 't1-03-ui-relative-dir' -ExpectedKeyword '专用测试根目录'
    Test-UatPathRejected -Name 'unit.nonEmptyUnknownDirectoryRejected' -RequestedPath $nonEmptyExisting -ExpectedKeyword '非空'
    Test-UatPathRejected -Name 'unit.existingDatabaseDirectoryRejected' -RequestedPath $withDatabase -ExpectedKeyword '数据库'

    # -----------------------------------------------------------------------
    # 2. 编排脚本集成测试：不安全目录必须以退出码 2 失败，且不得删除/覆盖既有内容
    # -----------------------------------------------------------------------
    $integrationCases = @(
        @{ name = 'integration.cDriveRejected'; path = 'C:\WorkManager-test-data\t1-03-ui-reject'; keyword = 'PRECONDITION_FAILED' },
        @{ name = 'integration.formalRootRejected'; path = 'D:\WorkManager'; keyword = '正式应用目录' },
        @{ name = 'integration.outsideTestRootRejected'; path = 'D:\OtherWorkManagerDir\t1-03-ui'; keyword = '专用测试根目录' },
        @{ name = 'integration.dotDotEscapeRejected'; path = 'D:\WorkManager-test-data\..\WorkManager'; keyword = '正式应用目录' },
        @{ name = 'integration.nonEmptyUnknownDirectoryRejected'; path = $nonEmptyExisting; keyword = '非空' },
        @{ name = 'integration.existingDatabaseDirectoryRejected'; path = $withDatabase; keyword = '数据库' }
    )

    foreach ($case in $integrationCases) {
        $outputText = (& powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -OutputDir $case.path -Port 9711 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        $pass = ($exitCode -eq 2) -and $outputText.Contains('PRECONDITION_FAILED') -and $outputText.Contains($case.keyword)
        $detail = ('exit=' + $exitCode + '; keyword=' + $case.keyword)
        Add-UatPathCheck -Name $case.name -Pass $pass -Detail $detail
    }

    # 失败后未知目录内容必须原样保留（不得静默覆盖/删除）。
    $markerPath = Join-Path $nonEmptyExisting 'unknown-user-file.txt'
    $markerContent = if (Test-Path $markerPath -PathType Leaf) { (Get-Content $markerPath -Raw -Encoding UTF8).Trim() } else { '' }
    Add-UatPathCheck -Name 'integration.nonEmptyDirectoryNotDeletedOrModified' -Pass (($markerContent -eq 'must-not-be-deleted')) -Detail ('marker=' + $markerContent)

    $dbPath = Join-Path $withDatabase 'app\data\database\work.db'
    $dbContent = if (Test-Path $dbPath -PathType Leaf) { (Get-Content $dbPath -Raw -Encoding UTF8).Trim() } else { '' }
    Add-UatPathCheck -Name 'integration.existingDatabaseNotOverwritten' -Pass (($dbContent -eq 'existing-uat-database')) -Detail ('database content preserved=' + [bool]($dbContent -eq 'existing-uat-database'))
}
finally {
    # 只清理本脚本自己在专用测试根目录下创建的沙箱目录。
    if ((Test-Path -LiteralPath $sandbox) -and (Test-T103UatPathInside $sandbox $script:T103UatTestRoot)) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($script:Checks | Where-Object { -not $_.pass })
$evidence = [ordered]@{
    task        = 'T1-03'
    fix         = 'P3-02 UAT path safety'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    checkCount  = @($script:Checks).Count
    failed      = @($failed | ForEach-Object { $_.name })
    checks      = @($script:Checks)
    pass        = ($failed.Count -eq 0)
}
$evidenceDir = Split-Path -Parent $EvidencePath
if (-not (Test-Path $evidenceDir)) {
    New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
}
$evidence | ConvertTo-Json -Depth 6 | Set-Content -Path $EvidencePath -Encoding UTF8
Write-Host ("UAT_PATH_EVIDENCE=" + $EvidencePath)
Write-Host ("UAT_PATH_CHECK_TOTAL=" + $evidence.checkCount + " FAILED=" + $failed.Count)

if ($failed.Count -gt 0) {
    Write-Host 'T1_03_UAT_PATH_SECURITY=FAIL'
    exit 1
}
Write-Host 'T1_03_UAT_PATH_SECURITY=PASS'
exit 0
