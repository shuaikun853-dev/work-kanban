# WorkManager T1-03 UAT 输出目录安全专项测试（P3-02 第三轮修复验收）
#
# 覆盖（原有 23 项保持，新增 Windows 原生文件系统 reparse point 专项）：
# - 合法的新 UAT 目录 / 嵌套新目录允许创建（但本脚本只校验，不创建）；
# - C 盘目录、正式应用目录、测试根目录外目录、测试根目录本身、相对路径拒绝；
# - UNC、设备路径（\\?\ / \\.\）、非法文件名字符拒绝；
# - 含 .. 的路径规范化后越界拒绝；
# - 已包含数据库的目录、非空未知目录拒绝且不被删除/覆盖；
# - 专用测试根目录本身为 Junction 拒绝；
# - 专用测试根目录路径上某一级目录为 Junction 拒绝；
# - 输出目录路径中间组件为 Junction 拒绝；
# - 输出目录本身为 Junction 拒绝；
# - Junction 指向正式目录 / C 盘 / 测试根目录内部：全部拒绝；
# - Symbolic Link 指向外部目录：能创建则拒绝；受系统权限限制无法创建时明确记录 SKIP；
# - 输出目录父目录不存在：按安全规则允许新子目录，且校验过程不产生目录；
# - 路径校验失败：不创建目录、不复制 EXE、不创建数据库、canary 内容不变；
# - 删除 Junction 只删除链接本身，不递归删除链接目标；
# - 证据输出自检：不得包含机器标识（计算机名/账户名/用户目录/仓库绝对路径）。
#
# Junction 使用真实 cmd.exe mklink /J 创建；Symbolic Link 使用 mklink /D 尝试创建，
# 失败时记录 SKIP 原因（不把未执行测试算作 PASS）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1
# 可选：-EvidencePath <file>
# 退出码：0 = 全部 PASS（允许有明确记录的 SKIP）；1 = 存在 FAIL；2 = 前置条件不满足。

[CmdletBinding()]
param(
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$verifyScript = Join-Path $PSScriptRoot 'verify-t1-03-ui.ps1'
$pathScript = Join-Path $PSScriptRoot 'T1-03UatPath.ps1'
$releaseExe = Join-Path $repoRoot 'target\release\workmanager.exe'
. $pathScript

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repoRoot 'docs/testing/reports/T1-03-assets/evidence/t1-03-uat-path-evidence.json'
}

$script:Checks = New-Object System.Collections.ArrayList
$script:Skipped = New-Object System.Collections.ArrayList
$script:Links = New-Object System.Collections.ArrayList
$script:Targets = New-Object System.Collections.ArrayList

$script:OriginalCheckNames = @(
    'unit.freshNewUatDirectoryAllowed',
    'unit.emptyExistingDirectoryAllowed',
    'unit.caseInsensitiveRootAllowed',
    'unit.normalizedDotDotInsideAllowed',
    'unit.cDriveRejected',
    'unit.formalRootRejected',
    'unit.formalRootSubdirectoryRejected',
    'unit.outsideTestRootDDriveRejected',
    'unit.dotDotEscapeToFormalRejected',
    'unit.dotDotEscapeOutsideRejected',
    'unit.testRootItselfRejected',
    'unit.testRootWithTrailingSlashRejected',
    'unit.relativePathRejected',
    'unit.nonEmptyUnknownDirectoryRejected',
    'unit.existingDatabaseDirectoryRejected',
    'integration.cDriveRejected',
    'integration.formalRootRejected',
    'integration.outsideTestRootRejected',
    'integration.dotDotEscapeRejected',
    'integration.nonEmptyUnknownDirectoryRejected',
    'integration.existingDatabaseDirectoryRejected',
    'integration.nonEmptyDirectoryNotDeletedOrModified',
    'integration.existingDatabaseNotOverwritten'
)

function Add-UatPathCheck([string]$Name, [bool]$Pass, [string]$Detail) {
    [void]$script:Checks.Add([pscustomobject]@{ name = $Name; pass = $Pass; detail = (Format-EvidencePath $Detail) })
    if ($Pass) {
        Write-Host "PASS $Name — $Detail"
    }
    else {
        Write-Host "FAIL $Name — $Detail"
    }
}

function Add-UatPathSkip([string]$Name, [string]$Reason) {
    [void]$script:Skipped.Add([pscustomobject]@{ name = $Name; reason = (Format-EvidencePath $Reason) })
    Write-Host "SKIP $Name — $Reason"
}

function Format-EvidencePath([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) {
        return $Value
    }
    $text = [string]$Value
    $text = $text.Replace($script:T103UatTestRoot, '<uat-root>')
    $text = $text.Replace($script:T103UatFormalRoot, '<formal-root>')
    $text = $text.Replace($repoRoot, '<repo-root>')
    $profile = $env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($profile)) {
        $text = $text.Replace($profile, '<user-profile>')
    }
    $computerName = $env:COMPUTERNAME
    if (-not [string]::IsNullOrWhiteSpace($computerName) -and $computerName.Length -ge 4) {
        $text = $text.Replace($computerName, '<computer-name>')
    }
    $userName = $env:USERNAME
    if (-not [string]::IsNullOrWhiteSpace($userName) -and $userName.Length -ge 4) {
        $text = [regex]::Replace($text, ('\b' + [regex]::Escape($userName) + '\b'), '<user>')
    }
    # 其余盘符绝对路径统一占位（保留相对路径与 <uat-root> 等占位符）。
    $text = [regex]::Replace($text, '(?<![A-Za-z0-9_<>])[A-Za-z]:\\', '<drive-root>\')
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
        Add-UatPathCheck -Name $Name -Pass $false -Detail ("unexpected rejection: " + $_.Exception.Message)
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

function Test-UatPathAllowedCore([string]$Name, [string]$RequestedPath, [string]$TestRoot, [string]$FormalRoot) {
    try {
        $resolved = Resolve-T103UatOutputDirectoryCore -RequestedPath $RequestedPath -TestRoot $TestRoot -FormalRoot $FormalRoot
        Add-UatPathCheck -Name $Name -Pass $true -Detail ("allowed: " + (Format-EvidencePath $resolved))
    }
    catch {
        Add-UatPathCheck -Name $Name -Pass $false -Detail ("unexpected rejection: " + $_.Exception.Message)
    }
}

function Test-UatPathRejectedCore([string]$Name, [string]$RequestedPath, [string]$TestRoot, [string]$FormalRoot, [string]$ExpectedKeyword) {
    try {
        $resolved = Resolve-T103UatOutputDirectoryCore -RequestedPath $RequestedPath -TestRoot $TestRoot -FormalRoot $FormalRoot
        Add-UatPathCheck -Name $Name -Pass $false -Detail ("unexpected allow: " + (Format-EvidencePath $resolved))
    }
    catch {
        $message = $_.Exception.Message
        $keywordOk = $message.Contains($ExpectedKeyword)
        Add-UatPathCheck -Name $Name -Pass $keywordOk -Detail ("rejected: " + (Format-EvidencePath $message))
    }
}

function Test-IsReparseLink([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function New-TestDirectory([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    [void]$script:Targets.Add($Path)
}

function Invoke-Mklink([string]$Arguments) {
    # cmd.exe 的 stderr（例如权限不足）在 $ErrorActionPreference='Stop' 下会被包装成
    # NativeCommandError；这里局部放宽错误处理，只把输出与退出码作为数据返回。
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & cmd.exe /d /c $Arguments 2>&1
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = (($output | Out-String).Trim()) }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function New-TestJunction([string]$Link, [string]$Target) {
    $result = Invoke-Mklink ('mklink /J "' + $Link + '" "' + $Target + '"')
    if ($result.ExitCode -ne 0) {
        throw ("创建 Junction 失败（exit={0}）：{1} -> {2}；输出：{3}" -f $result.ExitCode, $Link, $Target, $result.Output)
    }
    if (-not (Test-IsReparseLink $Link)) {
        throw ("mklink /J 声称成功但目标不是重解析点：{0}" -f $Link)
    }
    [void]$script:Links.Add($Link)
}

function Try-New-TestSymbolicLink([string]$Link, [string]$Target) {
    $result = Invoke-Mklink ('mklink /D "' + $Link + '" "' + $Target + '"')
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Created = $false; ExitCode = $result.ExitCode; Output = $result.Output }
    }
    if (-not (Test-IsReparseLink $Link)) {
        return [pscustomobject]@{ Created = $false; ExitCode = -1; Output = 'mklink /D 声称成功但目标不是重解析点' }
    }
    [void]$script:Links.Add($Link)
    return [pscustomobject]@{ Created = $true; ExitCode = 0; Output = '' }
}

# 只删除链接本身（非递归），绝不删除链接指向的目标。
function Remove-TestLink([string]$Link) {
    if (-not (Test-Path -LiteralPath $Link)) {
        return
    }
    try {
        [System.IO.Directory]::Delete($Link, $false)
    }
    catch {
        Remove-Item -LiteralPath $Link -Force -ErrorAction Stop
    }
}

function Get-DirectorySnapshot([string]$Directory) {
    $snapshot = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Directory)) {
        return $snapshot
    }
    Get-ChildItem -LiteralPath $Directory -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($Directory.Length).TrimStart('\')
        $snapshot[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    return $snapshot
}

function Compare-DirectorySnapshot($Before, $After) {
    $beforeKeys = @($Before.Keys)
    $afterKeys = @($After.Keys)
    $removed = @($beforeKeys | Where-Object { -not $After.Contains($_) })
    $added = @($afterKeys | Where-Object { -not $Before.Contains($_) })
    $changed = @($beforeKeys | Where-Object { $After.Contains($_) -and ($After[$_] -ne $Before[$_]) })
    return [pscustomobject]@{ Removed = $removed; Added = $added; Changed = $changed }
}

function Invoke-VerifyScript([string]$OutputDir, [int]$Port) {
    $outputText = (& powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -OutputDir $OutputDir -Port $Port 2>&1 | Out-String)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $outputText }
}

# ---------------------------------------------------------------------------
# 前置条件
# ---------------------------------------------------------------------------
if (-not (Test-Path $verifyScript -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: 编排脚本不存在：$verifyScript"
    exit 2
}
if (-not (Test-Path $releaseExe -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: Release EXE 不存在（集成测试需要）：$releaseExe"
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
[void]$script:Targets.Add($sandbox)

$emptyExisting = Join-Path $sandbox 'empty-existing'
$nonEmptyExisting = Join-Path $sandbox 'non-empty-existing'
$withDatabase = Join-Path $sandbox 'with-database'
$freshDir = Join-Path $sandbox ('fresh-' + $timestamp)
New-Item -ItemType Directory -Force -Path $emptyExisting | Out-Null
New-Item -ItemType Directory -Force -Path $nonEmptyExisting | Out-Null
Set-Content -Path (Join-Path $nonEmptyExisting 'unknown-user-file.txt') -Value 'must-not-be-deleted' -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $withDatabase 'app\data\database') | Out-Null
Set-Content -Path (Join-Path $withDatabase 'app\data\database\work.db') -Value 'existing-uat-database' -Encoding UTF8

# 合成测试根/正式根（均为沙箱内虚构目录，不接触真实正式目录 D:\WorkManager）。
$synthRoot = Join-Path $sandbox 'synth'
New-Item -ItemType Directory -Force -Path $synthRoot | Out-Null
$syntheticRootTarget = Join-Path $synthRoot 'root-target'
New-Item -ItemType Directory -Force -Path $syntheticRootTarget | Out-Null
$syntheticSubRoot = Join-Path $syntheticRootTarget 'sub-root'
New-Item -ItemType Directory -Force -Path $syntheticSubRoot | Out-Null
$syntheticFormalTarget = Join-Path $synthRoot 'formal-target'
New-Item -ItemType Directory -Force -Path $syntheticFormalTarget | Out-Null

# 真实 Junction 场景（全部使用真实文件系统对象）。
$junctionEmptyTarget = Join-Path $sandbox 'junction-empty-target'
New-Item -ItemType Directory -Force -Path $junctionEmptyTarget | Out-Null
$outputJunction = Join-Path $sandbox 'output-junction'
New-TestJunction $outputJunction $junctionEmptyTarget

$junctionMidTarget = Join-Path $sandbox 'junction-mid-target'
New-Item -ItemType Directory -Force -Path $junctionMidTarget | Out-Null
$middleJunction = Join-Path $sandbox 'junction-mid-link'
New-TestJunction $middleJunction $junctionMidTarget

$junctionInsideTarget = Join-Path $sandbox 'junction-inside-target'
New-Item -ItemType Directory -Force -Path $junctionInsideTarget | Out-Null
$insideJunction = Join-Path $sandbox 'junction-inside-link'
New-TestJunction $insideJunction $junctionInsideTarget

$junctionFormalLink = Join-Path $sandbox 'junction-formal-link'
New-TestJunction $junctionFormalLink $syntheticFormalTarget

$junctionCDriveLink = Join-Path $sandbox 'junction-c-drive-link'
New-TestJunction $junctionCDriveLink 'C:\Windows'

$syntheticRootJunction = Join-Path $synthRoot 'root-junction'
New-TestJunction $syntheticRootJunction $syntheticRootTarget

# 失败无副作用验证目标：canary 文件 + 既有数据库内容 + 不能新增 EXE/数据库。
$sideEffectTarget = Join-Path $sandbox 'side-effect-target'
New-Item -ItemType Directory -Force -Path $sideEffectTarget | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $sideEffectTarget 'canary') | Out-Null
Set-Content -Path (Join-Path $sideEffectTarget 'canary\canary.txt') -Value 'junction-target-canary-do-not-delete' -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $sideEffectTarget 'app\data\database') | Out-Null
Set-Content -Path (Join-Path $sideEffectTarget 'app\data\database\work.db') -Value 'pre-existing-uat-database' -Encoding UTF8
$sideEffectSnapshotBefore = Get-DirectorySnapshot $sideEffectTarget
$sideEffectJunction = Join-Path $sandbox 'side-effect-junction'
New-TestJunction $sideEffectJunction $sideEffectTarget

# Symbolic Link：受当前进程权限限制，可能无法创建；不能创建时记录 SKIP 而不是 PASS。
$externalSymlinkTarget = 'C:\Windows'
$externalSymlink = Join-Path $sandbox 'external-symbolic-link'
$symlinkAttempt = Try-New-TestSymbolicLink $externalSymlink $externalSymlinkTarget

$formalRootExistedBefore = Test-Path -LiteralPath $script:T103UatFormalRoot

try {
    # -----------------------------------------------------------------------
    # 1. 原有 23 项：校验函数单元测试（不启动应用）
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
    # 2. 原有 23 项：编排脚本集成测试（不安全目录必须退出码 2，不得删除/覆盖内容）
    # -----------------------------------------------------------------------
    $integrationCases = @(
        @{ name = 'integration.cDriveRejected'; path = 'C:\WorkManager-test-data\t1-03-ui-reject'; keyword = 'PRECONDITION_FAILED' },
        @{ name = 'integration.formalRootRejected'; path = 'D:\WorkManager'; keyword = '正式应用目录' },
        @{ name = 'integration.outsideTestRootRejected'; path = 'D:\OtherWorkManagerDir\t1-03-ui'; keyword = '专用测试根目录' },
        @{ name = 'integration.dotDotEscapeRejected'; path = 'D:\WorkManager-test-data\..\WorkManager'; keyword = '正式应用目录' },
        @{ name = 'integration.nonEmptyUnknownDirectoryRejected'; path = $nonEmptyExisting; keyword = '非空' },
        @{ name = 'integration.existingDatabaseDirectoryRejected'; path = $withDatabase; keyword = '数据库' }
    )

    $integrationPort = 9711
    foreach ($case in $integrationCases) {
        $result = Invoke-VerifyScript -OutputDir $case.path -Port $integrationPort
        $integrationPort++
        $pass = ($result.ExitCode -eq 2) -and $result.Output.Contains('PRECONDITION_FAILED') -and $result.Output.Contains($case.keyword)
        $detail = ('exit=' + $result.ExitCode + '; keyword=' + $case.keyword)
        Add-UatPathCheck -Name $case.name -Pass $pass -Detail $detail
    }

    $markerPath = Join-Path $nonEmptyExisting 'unknown-user-file.txt'
    $markerContent = if (Test-Path $markerPath -PathType Leaf) { (Get-Content $markerPath -Raw -Encoding UTF8).Trim() } else { '' }
    Add-UatPathCheck -Name 'integration.nonEmptyDirectoryNotDeletedOrModified' -Pass (($markerContent -eq 'must-not-be-deleted')) -Detail ('marker=' + $markerContent)

    $dbPath = Join-Path $withDatabase 'app\data\database\work.db'
    $dbContent = if (Test-Path $dbPath -PathType Leaf) { (Get-Content $dbPath -Raw -Encoding UTF8).Trim() } else { '' }
    Add-UatPathCheck -Name 'integration.existingDatabaseNotOverwritten' -Pass (($dbContent -eq 'existing-uat-database')) -Detail ('database content preserved=' + [bool]($dbContent -eq 'existing-uat-database'))

    # -----------------------------------------------------------------------
    # 3. 新增：Windows 原生文件系统 / reparse point 专项
    # -----------------------------------------------------------------------
    # 3.1 正常 D 盘新目录与嵌套新目录允许（校验本身不得创建目录）。
    $nativeFresh = Join-Path $sandbox ('native-fresh-' + $timestamp)
    Test-UatPathAllowed -Name 'native.newDirectoryUnderRealRootAllowed' -RequestedPath $nativeFresh -ExpectedPrefix $script:T103UatTestRoot
    Add-UatPathCheck -Name 'native.newDirectoryNotCreatedByValidation' -Pass (-not (Test-Path -LiteralPath $nativeFresh)) -Detail ('existsAfterValidation=' + [bool](Test-Path -LiteralPath $nativeFresh))

    $nestedParent = Join-Path $sandbox 'nested-plain-parent'
    New-Item -ItemType Directory -Force -Path $nestedParent | Out-Null
    [void]$script:Targets.Add($nestedParent)
    $nestedOutput = Join-Path $nestedParent 'deep\native-nested'
    Test-UatPathAllowed -Name 'native.nestedNewDirectoryUnderRealRootAllowed' -RequestedPath $nestedOutput -ExpectedPrefix $script:T103UatTestRoot
    Add-UatPathCheck -Name 'native.nestedDirectoryNotCreatedByValidation' -Pass (-not (Test-Path -LiteralPath $nestedOutput)) -Detail ('existsAfterValidation=' + [bool](Test-Path -LiteralPath $nestedOutput))

    # 3.2 输出目录父目录不存在：按安全规则允许，且校验过程不产生目录。
    $missingParentOutput = Join-Path $sandbox 'missing-parent-not-exist\child-output'
    Test-UatPathAllowedCore -Name 'native.missingParentAllowedWithSafetyRules' -RequestedPath $missingParentOutput -TestRoot $script:T103UatTestRoot -FormalRoot $script:T103UatFormalRoot
    Add-UatPathCheck -Name 'native.missingParentNotCreatedByValidation' -Pass (-not (Test-Path -LiteralPath (Join-Path $sandbox 'missing-parent-not-exist'))) -Detail 'missing parent still absent'

    # 3.3 专用测试根目录本身为 Junction：拒绝。
    Test-UatPathRejectedCore -Name 'native.testRootIsJunctionRejected' -RequestedPath (Join-Path $syntheticRootJunction 'out') -TestRoot $syntheticRootJunction -FormalRoot (Join-Path $synthRoot 'formal-unused') -ExpectedKeyword '重解析点'

    # 3.4 专用测试根目录路径上某一级目录为 Junction：拒绝。
    $syntheticSubRootViaJunction = Join-Path $syntheticRootJunction 'sub-root'
    Test-UatPathRejectedCore -Name 'native.testRootPathContainsJunctionRejected' -RequestedPath (Join-Path $syntheticSubRootViaJunction 'out') -TestRoot $syntheticSubRootViaJunction -FormalRoot (Join-Path $synthRoot 'formal-unused') -ExpectedKeyword '重解析点'

    # 3.5 输出目录路径中间组件为 Junction：拒绝。
    Test-UatPathRejected -Name 'native.middleComponentJunctionRejected' -RequestedPath (Join-Path $middleJunction 'child') -ExpectedKeyword '重解析点'

    # 3.6 输出目录本身为 Junction：拒绝。
    Test-UatPathRejected -Name 'native.outputDirectoryJunctionRejected' -RequestedPath $outputJunction -ExpectedKeyword '重解析点'

    # 3.7 Junction 指向正式目录：拒绝（使用沙箱内合成正式根，不触碰真实 D:\WorkManager）。
    Test-UatPathRejectedCore -Name 'native.junctionToFormalRootRejected' -RequestedPath (Join-Path $junctionFormalLink 'out') -TestRoot $sandbox -FormalRoot $syntheticFormalTarget -ExpectedKeyword '重解析点'

    # 3.8 Junction 指向 C 盘：拒绝。
    Test-UatPathRejected -Name 'native.junctionToCDriveRejected' -RequestedPath (Join-Path $junctionCDriveLink 'out') -ExpectedKeyword '重解析点'

    # 3.9 重解析点指向测试根目录内部：仍然拒绝（不因目标在根内而放行）。
    Test-UatPathRejected -Name 'native.reparsePointInsideTestRootRejected' -RequestedPath (Join-Path $insideJunction 'out') -ExpectedKeyword '重解析点'

    # 3.10 UNC / 设备路径 / 非法字符 / 测试根目录缺失：fail closed。
    Test-UatPathRejected -Name 'native.uncPathRejected' -RequestedPath '\\server\share\t1-03-ui' -ExpectedKeyword 'UNC'
    Test-UatPathRejected -Name 'native.devicePathRejected' -RequestedPath '\\?\D:\WorkManager-test-data\t1-03-ui' -ExpectedKeyword 'UNC'
    Test-UatPathRejected -Name 'native.wildcardPathRejected' -RequestedPath (Join-Path $sandbox 'bad*name') -ExpectedKeyword '非法字符'
    # 归一化前拒绝尾部点/空白组件与扩展保留设备名（红队复核补充的低风险形状）。
    Test-UatPathRejected -Name 'native.trailingDotComponentRejected' -RequestedPath (Join-Path $sandbox 'dot-suffix.') -ExpectedKeyword '点或空白'
    Test-UatPathRejected -Name 'native.trailingSpaceComponentRejected' -RequestedPath (Join-Path $sandbox 'space suffix \child') -ExpectedKeyword '点或空白'
    Test-UatPathRejected -Name 'native.reservedCom0Rejected' -RequestedPath (Join-Path $sandbox 'COM0') -ExpectedKeyword '保留设备名'
    Test-UatPathRejected -Name 'native.reservedConinRejected' -RequestedPath (Join-Path $sandbox 'CONIN$') -ExpectedKeyword '保留设备名'
    $missingTestRoot = Join-Path $sandbox 'missing-test-root'
    Test-UatPathRejectedCore -Name 'native.missingTestRootRejected' -RequestedPath (Join-Path $missingTestRoot 'out') -TestRoot $missingTestRoot -FormalRoot (Join-Path $synthRoot 'formal-unused') -ExpectedKeyword '不存在'

    # 3.11 成功校验必须产生原生守卫证据（卷身份/最终路径/组件数），而不是仅字符串判断。
    $guardFresh = Join-Path $sandbox ('guard-fresh-' + $timestamp)
    $guardResolved = Resolve-T103UatOutputDirectory -RequestedPath $guardFresh
    $guard = Get-T103UatNativeGuardSummary
    $guardOk = ($null -ne $guard) -and
        ($guard.volumeIdentityMatch -eq $true) -and
        ($guard.finalPathInsideRoot -eq $true) -and
        ($guard.reparsePointAllowed -eq $false) -and
        ([int]$guard.checkedComponentCount -ge 2)
    Add-UatPathCheck -Name 'native.guardSummaryVolumeAndFinalPathChecks' -Pass $guardOk -Detail ('volumeIdentityMatch=' + [string]$guard.volumeIdentityMatch + '; finalPathInsideRoot=' + [string]$guard.finalPathInsideRoot + '; checkedComponents=' + [string]$guard.checkedComponentCount)

    # 3.12 Symbolic Link 指向外部目录：能创建则拒绝；不能创建则记录 SKIP。
    if ($symlinkAttempt.Created) {
        Test-UatPathRejected -Name 'native.symbolicLinkToExternalRejected' -RequestedPath (Join-Path $externalSymlink 'out') -ExpectedKeyword '重解析点'
    }
    else {
        Add-UatPathSkip -Name 'native.symbolicLinkToExternalRejected' -Reason ('当前进程无法创建 Windows Symbolic Link（mklink /D 退出码=' + $symlinkAttempt.ExitCode + '；SeCreateSymbolicLinkPrivilege 未启用/未以管理员运行）。该场景未执行，不计为 PASS。')
    }

    # -----------------------------------------------------------------------
    # 4. 新增：失败场景无副作用（不创建、不复制 EXE、不写数据库、canary 不变）
    # -----------------------------------------------------------------------
    $sideEffectResult = Invoke-VerifyScript -OutputDir $sideEffectJunction -Port 9731
    Add-UatPathCheck -Name 'integration.junctionOutputRejected' -Pass (($sideEffectResult.ExitCode -eq 2) -and $sideEffectResult.Output.Contains('PRECONDITION_FAILED')) -Detail ('exit=' + $sideEffectResult.ExitCode)
    Add-UatPathCheck -Name 'integration.junctionOutputRejectedByReparsePoint' -Pass ($sideEffectResult.Output.Contains('重解析点')) -Detail ('keyword=重解析点; exit=' + $sideEffectResult.ExitCode)

    $sideEffectSnapshotAfter = Get-DirectorySnapshot $sideEffectTarget
    $sideEffectDiff = Compare-DirectorySnapshot $sideEffectSnapshotBefore $sideEffectSnapshotAfter
    Add-UatPathCheck -Name 'integration.sideEffectSnapshotUnchanged' -Pass (($sideEffectDiff.Removed.Count -eq 0) -and ($sideEffectDiff.Added.Count -eq 0) -and ($sideEffectDiff.Changed.Count -eq 0)) -Detail ('removed=' + $sideEffectDiff.Removed.Count + '; added=' + $sideEffectDiff.Added.Count + '; changed=' + $sideEffectDiff.Changed.Count)

    $sideEffectCanaryPath = Join-Path $sideEffectTarget 'canary\canary.txt'
    $sideEffectCanary = if (Test-Path $sideEffectCanaryPath -PathType Leaf) { (Get-Content $sideEffectCanaryPath -Raw -Encoding UTF8).Trim() } else { '' }
    Add-UatPathCheck -Name 'integration.sideEffectCanaryUnchanged' -Pass ($sideEffectCanary -eq 'junction-target-canary-do-not-delete') -Detail ('canaryPreserved=' + [bool]($sideEffectCanary -eq 'junction-target-canary-do-not-delete'))

    $sideEffectDbPath = Join-Path $sideEffectTarget 'app\data\database\work.db'
    $sideEffectDb = if (Test-Path $sideEffectDbPath -PathType Leaf) { (Get-Content $sideEffectDbPath -Raw -Encoding UTF8).Trim() } else { '' }
    Add-UatPathCheck -Name 'integration.sideEffectExistingDatabaseUnchanged' -Pass ($sideEffectDb -eq 'pre-existing-uat-database') -Detail ('databasePreserved=' + [bool]($sideEffectDb -eq 'pre-existing-uat-database'))

    $copiedExeCount = @(Get-ChildItem -LiteralPath $sideEffectTarget -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.exe' }).Count
    Add-UatPathCheck -Name 'integration.sideEffectNoExeCopied' -Pass ($copiedExeCount -eq 0) -Detail ('exeCount=' + $copiedExeCount)
    $writeArtifacts = @(Get-ChildItem -LiteralPath $sideEffectTarget -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 't1-03-ui-orchestration.json' -or $_.Name -like '*.db-wal' -or $_.Name -like '*.db-shm'
    }).Count
    Add-UatPathCheck -Name 'integration.sideEffectNoDatabaseWriteArtifacts' -Pass ($writeArtifacts -eq 0) -Detail ('orchestrationOrWalArtifacts=' + $writeArtifacts + '; existingDatabasePreserved=' + [bool]($sideEffectDb -eq 'pre-existing-uat-database'))
    Add-UatPathCheck -Name 'integration.sideEffectJunctionStillPresent' -Pass (Test-IsReparseLink $sideEffectJunction) -Detail 'junction link preserved after rejection'
    Add-UatPathCheck -Name 'integration.sideEffectNoChildDirectoryCreated' -Pass (-not (Test-Path -LiteralPath (Join-Path $sideEffectTarget 'child'))) -Detail 'no child directory created in junction target'

    # 输出路径通过 Junction 指向正式目录：失败后不得创建正式目录、不得写入。
    $formalIntegrationResult = Invoke-VerifyScript -OutputDir 'D:\WorkManager' -Port 9741
    $formalRootExistsAfter = Test-Path -LiteralPath $script:T103UatFormalRoot
    $formalRootStateUnchanged = ($formalRootExistsAfter -eq $formalRootExistedBefore)
    Add-UatPathCheck -Name 'integration.formalRootRejectedWithoutCreation' -Pass (($formalIntegrationResult.ExitCode -eq 2) -and $formalRootStateUnchanged) -Detail ('exit=' + $formalIntegrationResult.ExitCode + '; formalRootExistedBefore=' + [bool]$formalRootExistedBefore + '; formalRootExistsAfter=' + [bool]$formalRootExistsAfter)

    # -----------------------------------------------------------------------
    # 5. 新增：Junction 清理语义（只删除链接本身，不递归删除目标）
    # -----------------------------------------------------------------------
    $cleanupTarget = Join-Path $sandbox 'cleanup-target'
    New-Item -ItemType Directory -Force -Path $cleanupTarget | Out-Null
    Set-Content -Path (Join-Path $cleanupTarget 'cleanup-canary.txt') -Value 'cleanup-canary-content' -Encoding UTF8
    $cleanupLink = Join-Path $sandbox 'cleanup-link'
    New-TestJunction $cleanupLink $cleanupTarget
    $cleanupCanaryBefore = (Get-Content (Join-Path $cleanupTarget 'cleanup-canary.txt') -Raw -Encoding UTF8).Trim()
    Remove-TestLink $cleanupLink
    $cleanupLinkGone = -not (Test-Path -LiteralPath $cleanupLink)
    $cleanupTargetAlive = Test-Path -LiteralPath (Join-Path $cleanupTarget 'cleanup-canary.txt')
    $cleanupCanaryAfter = if ($cleanupTargetAlive) { (Get-Content (Join-Path $cleanupTarget 'cleanup-canary.txt') -Raw -Encoding UTF8).Trim() } else { '' }
    Add-UatPathCheck -Name 'cleanup.junctionLinkRemovedWithoutTouchingTarget' -Pass ($cleanupLinkGone -and $cleanupTargetAlive) -Detail ('linkRemoved=' + [bool]$cleanupLinkGone + '; targetCanaryAlive=' + [bool]$cleanupTargetAlive)
    Add-UatPathCheck -Name 'cleanup.junctionTargetCanaryIntact' -Pass ($cleanupCanaryAfter -eq $cleanupCanaryBefore -and $cleanupCanaryAfter -eq 'cleanup-canary-content') -Detail ('canaryPreserved=' + [bool]($cleanupCanaryAfter -eq 'cleanup-canary-content'))

    # -----------------------------------------------------------------------
    # 6. 原有 23 项测试保持与证据自检
    # -----------------------------------------------------------------------
    $checkNames = @($script:Checks | ForEach-Object { $_.name })
    $missingOriginal = @($script:OriginalCheckNames | Where-Object { $checkNames -notcontains $_ })
    Add-UatPathCheck -Name 'evidence.original23ChecksPreserved' -Pass ($missingOriginal.Count -eq 0) -Detail ('originalExpected=23; missing=' + $missingOriginal.Count)

    $evidencePass = (@($script:Checks | Where-Object { -not $_.pass }).Count -eq 0)
    $sanitizedProbe = (($script:Checks | ConvertTo-Json -Depth 6) + ($script:Skipped | ConvertTo-Json -Depth 6))
    $leakPatterns = @()
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $env:COMPUTERNAME.Length -ge 4) { $leakPatterns += [regex]::Escape($env:COMPUTERNAME) }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $leakPatterns += [regex]::Escape($env:USERPROFILE) }
    $leakPatterns += [regex]::Escape($repoRoot)
    $leakPatterns += 'C:\\Users\\'
    $leakPatterns += 'T1-03-assets\\logs'
    $leakFound = $false
    foreach ($pattern in $leakPatterns) {
        if ($sanitizedProbe -match $pattern) { $leakFound = $true; break }
    }
    Add-UatPathCheck -Name 'evidence.machineIdentifiersRedacted' -Pass (-not $leakFound) -Detail ('sensitivePatternsFound=' + [bool]$leakFound + '; patternsChecked=' + $leakPatterns.Count)
    Add-UatPathCheck -Name 'evidence.passState' -Pass $evidencePass -Detail ('failed=' + (@($script:Checks | Where-Object { -not $_.pass }).Count))
}
finally {
    # 只清理本脚本自己在专用测试根目录下创建的沙箱：先删除链接本身（非递归），
    # 再递归删除沙箱内的普通目录，避免任何递归删除跟随 Junction 目标。
    foreach ($link in @($script:Links)) {
        try {
            Remove-TestLink $link
        }
        catch {
            Write-Host ('WARN 清理链接失败：' + (Format-EvidencePath $_.Exception.Message))
        }
    }
    if ((Test-Path -LiteralPath $sandbox) -and (Test-T103UatPathInside $sandbox $script:T103UatTestRoot)) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($script:Checks | Where-Object { -not $_.pass })
$evidence = [ordered]@{
    task                = 'T1-03'
    fix                 = 'P3-02 UAT path safety (round 3: native Windows reparse-point checks)'
    generatedAt         = (Get-Date).ToUniversalTime().ToString('o')
    command             = 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1'
    environment         = [ordered]@{
        os              = [System.Environment]::OSVersion.VersionString
        powershell      = $PSVersionTable.PSVersion.ToString()
        isAdmin         = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        symlinkCreation = [bool]$symlinkAttempt.Created
    }
    pathCheckMethod     = 'CreateFileW + GetFileInformationByHandleEx(FileAttributeTagInfo/FileIdInfo) + GetFinalPathNameByHandleW'
    originalCheckCount  = @($script:OriginalCheckNames).Count
    checkCount          = @($script:Checks).Count
    failed              = @($failed | ForEach-Object { $_.name })
    checks              = @($script:Checks)
    skipped             = @($script:Skipped)
    skipCount           = @($script:Skipped).Count
    nativeGuard         = Get-T103UatNativeGuardSummary
    pass                = ($failed.Count -eq 0)
}
if ($failed.Count -gt 0) {
    Write-Host 'T1_03_UAT_PATH_SECURITY=FAIL'
    exit 1
}

$evidenceJson = $evidence | ConvertTo-Json -Depth 8
# 证据落盘前最后一次机器标识自检：命中则拒绝写入（fail closed）。
$finalLeak = $false
foreach ($pattern in $leakPatterns) {
    if ($evidenceJson -match $pattern) { $finalLeak = $true; break }
}
if ($finalLeak) {
    Write-Host 'T1_03_UAT_PATH_EVIDENCE_LEAK=FAIL（证据仍包含机器标识，拒绝写入）'
    exit 1
}
$evidenceDir = Split-Path -Parent $EvidencePath
if (-not (Test-Path $evidenceDir)) {
    New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
}
$evidenceJson | Set-Content -Path $EvidencePath -Encoding UTF8
Write-Host ("UAT_PATH_EVIDENCE=" + $EvidencePath)
Write-Host ("UAT_PATH_CHECK_TOTAL=" + $evidence.checkCount + " ORIGINAL=" + $evidence.originalCheckCount + " SKIPPED=" + $evidence.skipCount + " FAILED=" + $failed.Count)
Write-Host 'T1_03_UAT_PATH_SECURITY=PASS'
exit 0
