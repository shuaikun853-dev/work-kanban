# WorkManager T1-03 UAT 输出目录安全专项测试（P3-02 第三轮 + F1/F2 第四轮修复验收）
#
# 覆盖（第三轮 60 项全部保留，第四轮新增 F1/F2 真实文件系统故障注入）：
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
# 第四轮 F1（信任锚 / 真实入口顺序）：
# - 脚本入口在任何 New-Item / Set-Content / 创建 Canary / 创建数据库 / 复制 EXE /
#   启动应用之前，先用 Windows 原生句柄验证真实测试根目录（存在、真实目录、全部已存在
#   祖先组件、最终路径、卷身份、不在正式目录内），失败即 fail closed；
# - 测试根目录不存在时直接失败，绝不自动创建；
# - 在隔离测试环境中用真实 Junction 把测试根目录替换为外部 Canary 目录后启动本脚本，
#   验证脚本在任何写操作之前拒绝执行、外部 Canary 内容/目录结构不变、不自动创建沙箱；
# - `-TestRootOverride` 仅用于上述故障注入测试；正式默认路径仍固定为 D:\WorkManager-test-data。
#
# 第四轮 F2（清理 fail closed / 真实故障注入）：
# - 清理前复验沙箱身份（卷序列号 + 文件 ID + 真实最终路径），逐个删除并复验跟踪链接，
#   扫描整个沙箱确认无未预期 reparse point，再次复验身份；
# - 任一条件不满足立即停止，不执行整个沙箱递归删除，保留沙箱与外部目标目录，输出
#   WARN/FAIL 与可定位路径；
# - 正常路径使用逐条目校验的安全递归删除，绝不跟随 Junction / Symbolic Link 进入外部目录；
# - 使用真实 Junction + 受控删除失败注入 / 真实链接重建 / 真实未跟踪链接 / 真实身份替换构造故障。
#
# 第五轮 F1（证据文件写入边界，2026-11-26）：
# - `-EvidencePath` 必须先通过 Windows 原生句柄校验：证据目录存在、是真实目录、真实最终
#   路径与字面一致；请求路径每个已存在组件都是普通目录；真实最终路径严格位于证据目录内；
#   已存在目标文件是单硬链接普通文件。相对路径按仓库根目录解析。越界、别名、重解析点、
#   悬空 Junction、硬链接、原生检查失败一律 fail closed，不创建、不覆盖、不自动建目录。
#
# 第五轮 F2（沙箱入口原生检查，2026-11-26）：
# - 不再用 Test-Path 判断沙箱入口是否存在；改用原生句柄检查入口本身、父目录与全部已存在
#   祖先。Test-Path 对悬空 Junction 之下的路径返回 False，旧实现会把它当作“入口不存在”
#   并跳过清理；新实现只有原生检查确认不存在时才按原有业务规则处理，其余情况 fail closed。
#
# Junction 使用真实 cmd.exe mklink /J 创建；Symbolic Link 使用 mklink /D 尝试创建，
# 失败时记录 SKIP 原因（不把未执行测试算作 PASS）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1
# 可选：-EvidencePath <file>
# 测试专用：-TestRootOverride <absolute_local_path>（仅用于 F1 故障注入子进程）
# 退出码：0 = 全部 PASS（允许有明确记录的 SKIP）；1 = 存在 FAIL；2 = 前置条件不满足。

[CmdletBinding()]
param(
    [string]$EvidencePath = '',
    [string]$TestRootOverride = ''
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

# 第三轮 60 项检查名称（第四轮用于硬校验“原有测试全部保留”，不允许删除/改名）。
$script:Round3CheckNames = @(
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
    'integration.existingDatabaseNotOverwritten',
    'native.newDirectoryUnderRealRootAllowed',
    'native.newDirectoryNotCreatedByValidation',
    'native.nestedNewDirectoryUnderRealRootAllowed',
    'native.nestedDirectoryNotCreatedByValidation',
    'native.missingParentAllowedWithSafetyRules',
    'native.missingParentNotCreatedByValidation',
    'native.testRootIsJunctionRejected',
    'native.testRootPathContainsJunctionRejected',
    'native.middleComponentJunctionRejected',
    'native.outputDirectoryJunctionRejected',
    'native.junctionToFormalRootRejected',
    'native.junctionToCDriveRejected',
    'native.reparsePointInsideTestRootRejected',
    'native.uncPathRejected',
    'native.devicePathRejected',
    'native.wildcardPathRejected',
    'native.trailingDotComponentRejected',
    'native.trailingSpaceComponentRejected',
    'native.reservedCom0Rejected',
    'native.reservedConinRejected',
    'native.missingTestRootRejected',
    'native.guardSummaryVolumeAndFinalPathChecks',
    'integration.junctionOutputRejected',
    'integration.junctionOutputRejectedByReparsePoint',
    'integration.sideEffectSnapshotUnchanged',
    'integration.sideEffectCanaryUnchanged',
    'integration.sideEffectExistingDatabaseUnchanged',
    'integration.sideEffectNoExeCopied',
    'integration.sideEffectNoDatabaseWriteArtifacts',
    'integration.sideEffectJunctionStillPresent',
    'integration.sideEffectNoChildDirectoryCreated',
    'integration.formalRootRejectedWithoutCreation',
    'cleanup.junctionLinkRemovedWithoutTouchingTarget',
    'cleanup.junctionTargetCanaryIntact',
    'evidence.original23ChecksPreserved',
    'evidence.machineIdentifiersRedacted',
    'evidence.passState'
)

# 第四轮 F1/F2 必须存在的检查名称（防止故障注入测试被静默跳过/删除）。
$script:Round4ExpectedNewCheckNames = @(
    'f1.trustAnchorDefaultRootVerified',
    'f1.trustAnchorIdentityRecorded',
    'f1.defaultTestRootConstantUnchanged',
    'f1.mainRunUsesDefaultTrustedRoot',
    'f1.rootJunctionChildExitCode2',
    'f1.rootJunctionRejectedBeforeAnyWrite',
    'f1.rootJunctionCanaryUnchanged',
    'f1.rootJunctionNoSandboxCreated',
    'f1.rootJunctionDefaultRootUntouched',
    'f1.missingRootChildExitCode2',
    'f1.missingRootNotAutoCreated',
    'f1.missingRootNoWriteSideEffects',
    'f1.childDidNotWriteDefaultEvidence',
    'f1.validOverrideChildExitCode2',
    'f1.validOverrideNoSandboxCreated',
    'f1.canaryIntactAfterLinkCleanup',
    'f2.normalJunctionRemovalSucceeds',
    'f2.normalCleanupTargetCanaryIntact',
    'f2.trackedDeleteFailureStopsRecursiveDelete',
    'f2.trackedDeleteFailurePreservesSandbox',
    'f2.trackedDeleteFailureTargetCanaryIntact',
    'f2.trackedDeleteFailureReportsLocatablePath',
    'f2.linkReappearsAfterDeleteDetected',
    'f2.linkReappearsSandboxPreserved',
    'f2.untrackedReparsePointDetected',
    'f2.untrackedReparsePointTargetCanaryIntact',
    'f2.identityChangeBeforeCleanupDetected',
    'f2.identityChangeTargetCanaryIntact',
    'f2.failureCasesRecheckCanaryUnchanged',
    'f2.noRecursiveDeleteInFailureCases',
    'cleanup.sandboxRemovedSafely'
)

# 第五轮 F1/F2 最小修复必须存在的检查名称（防止写入边界/入口原生检查被静默跳过或删除）。
$script:Round5ExpectedNewCheckNames = @(
    'f1.evidenceWriteInsideRootSucceeds',
    'f1.evidenceRelativeEscapeRejected',
    'f1.evidenceDotDotTraversalRejected',
    'f1.evidenceAbsoluteOutsideRejected',
    'f1.evidenceJunctionBypassRejected',
    'f1.evidenceDanglingJunctionRejected',
    'f1.evidenceUnsafeExistingTargetRejected',
    'f1.evidenceRootIdentityMismatchRejected',
    'f1.evidenceFormalDatabaseTargetRejected',
    'f1.evidenceNativeCheckFailureFailsClosed',
    'f1.evidenceDefaultRootTrusted',
    'f1.canariesUnchangedAfterRejections',
    'f2.entryTrulyAbsentConfirmedByNativeCheck',
    'f2.entryNormalDirectoryNativeCheckPasses',
    'f2.entryNormalJunctionDetected',
    'f2.entryDanglingJunctionDetected',
    'f2.entryTestPathFalseDanglingJunctionNotBypassed',
    'f2.entryParentReparsePointFailsClosed',
    'f2.entryIdentityUnconfirmedFailsClosed',
    'f2.entryNativeCheckFailureFailsClosed',
    'f2.canariesUnchangedAfterFailureCases'
)

$script:DefaultEvidencePath = Join-Path $repoRoot 'docs/testing/reports/T1-03-assets/evidence/t1-03-uat-path-evidence.json'
$script:F1Summary = [ordered]@{}
$script:F2Summary = [ordered]@{}
$script:Round5F1Summary = [ordered]@{}
$script:Round5F2Summary = [ordered]@{}
$script:SandboxTrustRecord = $null
$script:CleanupResult = $null

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
    # 原生检查（不跟随重解析点）：悬空 Junction 的 Test-Path 结果不可靠。
    $state = Get-T103EntryNativeState -Path $Path -Label '测试链接'
    return ($state.exists -and $state.isReparsePoint)
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
    $state = Get-T103EntryNativeState -Path $Link -Label '测试链接'
    if (-not $state.exists) {
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

# 第四轮 F1：以“真实入口子进程”方式运行本测试脚本，注入测试根目录（仅故障注入测试使用）。
# 子进程走与正式运行完全相同的入口顺序（前置条件 → 信任锚验证 → 沙箱创建）。
function Invoke-ChildPathTestScript([string]$TestRootOverrideValue, [string]$ChildEvidencePath) {
    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }
    $outputText = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -TestRootOverride $TestRootOverrideValue -EvidencePath $ChildEvidencePath 2>&1 | Out-String)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $outputText }
}

# 创建真实 Junction，但不登记到主套件的跟踪链接列表（用于 F1/F2 故障注入用例，
# 由用例自身负责验证并清理；不登记可避免用例故意保留链接时影响主套件清理语义）。
function New-UntrackedTestJunction([string]$Link, [string]$Target) {
    $result = Invoke-Mklink ('mklink /J "' + $Link + '" "' + $Target + '"')
    if ($result.ExitCode -ne 0) {
        throw ("创建 Junction 失败（exit={0}）：{1} -> {2}；输出：{3}" -f $result.ExitCode, $Link, $Target, $result.Output)
    }
    if (-not (Test-IsReparseLink $Link)) {
        throw ("mklink /J 声称成功但目标不是重解析点：{0}" -f $Link)
    }
}

# 只删除链接本身（非递归）；拒绝用于非重解析点路径。
# 使用原生检查判断存在性：悬空 Junction 的 Test-Path 为 False，但链接本身仍存在。
function Remove-UntrackedTestLink([string]$Link) {
    $state = Get-T103EntryNativeState -Path $Link -Label '测试链接'
    if (-not $state.exists) {
        return
    }
    if (-not $state.isReparsePoint) {
        throw ("拒绝删除非重解析点路径（fail closed）：{0}" -f $Link)
    }
    try {
        [System.IO.Directory]::Delete($Link, $false)
    }
    catch {
        Remove-Item -LiteralPath $Link -Force -ErrorAction Stop
    }
    $after = Get-T103EntryNativeState -Path $Link -Label '测试链接'
    if ($after.exists) {
        throw ("链接删除后仍然存在：{0}" -f $Link)
    }
}

# 用例自清理：先扫描确认目录树中无任何 reparse point，再逐条目校验后删除。
function Remove-TestTreeSafely([string]$Path) {
    $state = Get-T103EntryNativeState -Path $Path -Label '测试自清理目标'
    if (-not $state.exists) {
        return
    }
    if ($state.isReparsePoint) {
        throw ("测试自清理拒绝递归删除重解析点（fail closed）：{0}" -f $Path)
    }
    $reparsePoints = @(Find-T103ReparsePointsInTree -RootDirectory $Path)
    if ($reparsePoints.Count -gt 0) {
        throw ("测试自清理拒绝：目录树中仍有 {0} 个重解析点：{1}" -f $reparsePoints.Count, (($reparsePoints | ForEach-Object { $_.path }) -join '; '))
    }
    Remove-T103VerifiedDirectoryTree -Directory $Path -StopPrefix '测试自清理'
}

# 第四轮 F2：构造一个带外部目标 Canary + 跟踪 Junction + 内部 sentinel 的用例沙箱。
function New-F2CaseSandbox([string]$Name, [string]$CanaryValue) {
    $caseRoot = Join-Path $sandbox ('f2-' + $Name)
    New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
    [void]$script:Targets.Add($caseRoot)
    $externalTarget = Join-Path $caseRoot 'external-target'
    New-Item -ItemType Directory -Force -Path $externalTarget | Out-Null
    Set-Content -Path (Join-Path $externalTarget 'canary.txt') -Value $CanaryValue -Encoding UTF8
    $caseSandbox = Join-Path $caseRoot 'sandbox'
    New-Item -ItemType Directory -Force -Path $caseSandbox | Out-Null
    Set-Content -Path (Join-Path $caseSandbox 'sentinel.txt') -Value ('sentinel-' + $Name) -Encoding UTF8
    $caseLink = Join-Path $caseSandbox 'linked-target'
    New-UntrackedTestJunction $caseLink $externalTarget
    $trustRecord = Get-T103DirectoryIdentityRecord -Path $caseSandbox -Label ('F2 用例沙箱 ' + $Name)
    return [pscustomobject]@{
        Name        = $Name
        Root        = $caseRoot
        Sandbox     = $caseSandbox
        Target      = $externalTarget
        Link        = $caseLink
        TrustRecord = $trustRecord
        Canary      = (Join-Path $externalTarget 'canary.txt')
        CanaryValue = $CanaryValue
        Sentinel    = (Join-Path $caseSandbox 'sentinel.txt')
    }
}

function Get-CanaryContent([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
}

# 第五轮 F2：构造以“入口不存在/入口是链接/入口身份异常”为对象的用例目录。
function New-F2EntryCaseRoot([string]$Name) {
    $caseRoot = Join-Path $sandbox ('f2-entry-' + $Name)
    New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
    [void]$script:Targets.Add($caseRoot)
    return $caseRoot
}

# 第五轮 F1：以真实文件系统对象验证证据写入被拒绝，且拒绝时不产生写入。
function Test-EvidenceWriteRejected([string]$Name, [string]$Path, [string]$EvidenceRoot, [string]$ExpectedKeyword, [string]$SideEffectDetail = '') {
    $rejected = $false
    $message = ''
    try {
        [void](Write-T103EvidenceFile -Path $Path -Content '{"round5":"must-not-be-written"}' -EvidenceRoot $EvidenceRoot)
    }
    catch {
        $rejected = $true
        $message = $_.Exception.Message
    }
    $keywordOk = $message.Contains($ExpectedKeyword)
    $detail = ('rejected=' + [bool]$rejected + '; keywordOk=' + [bool]$keywordOk + '; message=' + (Format-EvidencePath $message))
    if (-not [string]::IsNullOrWhiteSpace($SideEffectDetail)) {
        $detail = $detail + '; ' + $SideEffectDetail
    }
    Add-UatPathCheck -Name $Name -Pass ($rejected -and $keywordOk) -Detail $detail
}

# ---------------------------------------------------------------------------
# 前置条件（只读，无文件系统副作用）
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
# 第四轮 F1：真实测试根目录信任锚验证
#
# 必须在任何 New-Item / Set-Content / 创建 Canary / 创建测试数据库 / 创建测试目录 /
# 复制 EXE / 启动应用之前完成。测试根目录不存在或身份无法确认时 fail closed，
# 绝不自动创建测试根目录，也绝不穿过未验证路径写入。
# `-TestRootOverride` 只用于 F1 故障注入子进程；正式默认路径仍是 D:\WorkManager-test-data。
# ---------------------------------------------------------------------------
$defaultTestRoot = $script:T103UatTestRoot
$effectiveTestRoot = $defaultTestRoot
$testRootOverrideActive = $false
if (-not [string]::IsNullOrWhiteSpace($TestRootOverride)) {
    $testRootOverrideActive = $true
    try {
        $effectiveTestRoot = Get-T103UatNormalizedPath $TestRootOverride
    }
    catch {
        Write-Host ("PRECONDITION_FAILED: 测试根目录覆盖参数无效：" + $_.Exception.Message)
        exit 2
    }
}
try {
    $trustRecord = Assert-T103UatTrustedTestRoot -TestRoot $effectiveTestRoot -FormalRoot $script:T103UatFormalRoot
}
catch {
    Write-Host ("PRECONDITION_FAILED: " + $_.Exception.Message)
    Write-Host 'T1_03_UAT_PATH_TRUST_ANCHOR=FAIL'
    exit 2
}
$script:T103UatTestRoot = $effectiveTestRoot
if ($testRootOverrideActive) {
    Write-Host 'PRECONDITION_FAILED: 测试注入模式（-TestRootOverride）仅用于 F1 信任锚失败场景；不会在覆盖根目录下执行完整测试套件，也不会创建沙箱。'
    exit 2
}
# 第五轮 F1：在第一个写操作之前记录证据目录真实身份（卷序列号 + 文件 ID + 真实最终路径）。
# 证据写入时必须与该身份一致；无法确认身份时 fail closed。
$script:EvidenceRootIdentity = $null
try {
    $script:EvidenceRootIdentity = Get-T103DirectoryIdentityRecord -Path $script:T103EvidenceRoot -Label '证据目录'
}
catch {
    Write-Host ("PRECONDITION_FAILED: 证据目录真实身份无法确认（fail closed）：" + $_.Exception.Message)
    exit 2
}
Write-Host ("TRUST_ANCHOR=PASS path=" + (Format-EvidencePath $trustRecord.path) + " components=" + $trustRecord.existingComponentCount + " volumeIdentity=verified finalPath=verified")

# ---------------------------------------------------------------------------
# 准备隔离测试沙箱（只创建/清理本脚本自己创建的目录）
# 只有信任锚验证通过后才允许执行第一个写操作。
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sandbox = Join-Path $script:T103UatTestRoot ('t1-03-path-safety-' + $timestamp + '-' + $PID)
if (-not (Test-T103UatPathInside $sandbox $script:T103UatTestRoot)) {
    Write-Host 'PRECONDITION_FAILED: 测试沙箱不在专用测试根目录内，拒绝创建'
    exit 2
}
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
[void]$script:Targets.Add($sandbox)
try {
    $script:SandboxTrustRecord = Get-T103DirectoryIdentityRecord -Path $sandbox -Label '测试沙箱'
    if ([string]$script:SandboxTrustRecord.volumeSerialNumber -ne [string]$trustRecord.volumeSerialNumber) {
        throw '新测试沙箱与专用测试根目录不在同一个真实卷上。'
    }
    if (-not (Test-T103FinalPathInside ([string]$script:SandboxTrustRecord.finalPath) ([string]$trustRecord.finalPath))) {
        throw ('新测试沙箱的真实最终路径不在信任锚测试根目录内：' + [string]$script:SandboxTrustRecord.finalPath)
    }
}
catch {
    Write-Host ("PRECONDITION_FAILED: 测试沙箱创建后无法确认身份（fail closed）：" + $_.Exception.Message)
    try { Remove-T103VerifiedDirectoryTree -Directory $sandbox -StopPrefix '失败清理' } catch { }
    exit 2
}

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
    # 7. 第四轮 F1：测试根目录信任锚 / 真实 Junction 根目录无副作用入口测试
    # -----------------------------------------------------------------------
    # 7.1 信任锚证据（入口已在任何写操作前完成真实根目录验证）。
    $f1TrustRecord = Get-T103UatTrustedRootRecord
    $f1TrustVerified = ($null -ne $f1TrustRecord) -and
        (Test-T103UatPathEquals ([string]$f1TrustRecord.path) $defaultTestRoot) -and
        (-not [string]::IsNullOrWhiteSpace([string]$f1TrustRecord.finalPath)) -and
        (Test-T103FinalPathEquals ([string]$f1TrustRecord.finalPath) ([string]$f1TrustRecord.path)) -and
        ([int]$f1TrustRecord.existingComponentCount -ge 2)
    Add-UatPathCheck -Name 'f1.trustAnchorDefaultRootVerified' -Pass $f1TrustVerified -Detail ('pathMatches=' + [bool]($null -ne $f1TrustRecord -and (Test-T103UatPathEquals ([string]$f1TrustRecord.path) $defaultTestRoot)) + '; components=' + $(if ($null -ne $f1TrustRecord) { [string]$f1TrustRecord.existingComponentCount } else { 'n/a' }))
    $f1IdentityRecorded = ($null -ne $f1TrustRecord) -and
        ([string]$f1TrustRecord.fileIdHex.Length -eq 32) -and
        (-not [string]::IsNullOrWhiteSpace([string]$f1TrustRecord.volumeSerialNumber))
    Add-UatPathCheck -Name 'f1.trustAnchorIdentityRecorded' -Pass $f1IdentityRecorded -Detail ('fileIdLength=' + $(if ($null -ne $f1TrustRecord) { [string]$f1TrustRecord.fileIdHex.Length } else { '0' }) + '; volumeSerialRecorded=' + [bool]($null -ne $f1TrustRecord -and -not [string]::IsNullOrWhiteSpace([string]$f1TrustRecord.volumeSerialNumber)))
    Add-UatPathCheck -Name 'f1.defaultTestRootConstantUnchanged' -Pass (($defaultTestRoot -eq 'D:\WorkManager-test-data') -and (-not $testRootOverrideActive)) -Detail ('defaultRoot=' + $defaultTestRoot + '; overrideActive=' + [bool]$testRootOverrideActive)
    Add-UatPathCheck -Name 'f1.mainRunUsesDefaultTrustedRoot' -Pass ((Test-T103UatPathInside $sandbox $defaultTestRoot) -and (-not $testRootOverrideActive)) -Detail ('sandboxInsideDefaultRoot=' + [bool](Test-T103UatPathInside $sandbox $defaultTestRoot))

    # 7.2 隔离环境：真实 Junction 把测试根目录替换为外部 Canary 目录，启动真实入口子进程。
    $f1DefaultEvidencePath = $script:DefaultEvidencePath
    $f1DefaultEvidenceBefore = if (Test-Path $f1DefaultEvidencePath -PathType Leaf) { (Get-FileHash -LiteralPath $f1DefaultEvidencePath -Algorithm SHA256).Hash } else { '' }
    $f1Root = Join-Path $sandbox 'f1-root-trust'
    New-Item -ItemType Directory -Force -Path $f1Root | Out-Null
    [void]$script:Targets.Add($f1Root)
    $f1Canary = Join-Path $f1Root 'external-canary'
    New-Item -ItemType Directory -Force -Path (Join-Path $f1Canary 'nested') | Out-Null
    Set-Content -Path (Join-Path $f1Canary 'canary.txt') -Value 'f1-root-trust-canary-do-not-touch' -Encoding UTF8
    Set-Content -Path (Join-Path $f1Canary 'nested\canary-nested.txt') -Value 'f1-nested-canary' -Encoding UTF8
    $f1CanaryFilesBefore = Get-DirectorySnapshot $f1Canary
    $f1CanaryDirsBefore = @(Get-ChildItem -LiteralPath $f1Canary -Recurse -Force -Directory | ForEach-Object { $_.FullName.Substring($f1Canary.Length) })
    $f1RootLink = Join-Path $f1Root 'test-root-junction'
    New-UntrackedTestJunction $f1RootLink $f1Canary
    $f1DefaultRootNamesBefore = @(Get-ChildItem -LiteralPath $defaultTestRoot -Force | ForEach-Object { $_.Name })
    $f1ChildEvidencePath = Join-Path $f1Root 'child-evidence-must-not-be-written.json'
    $f1Child = Invoke-ChildPathTestScript -TestRootOverrideValue $f1RootLink -ChildEvidencePath $f1ChildEvidencePath
    $f1CanaryFilesAfter = Get-DirectorySnapshot $f1Canary
    $f1CanaryDirsAfter = @(Get-ChildItem -LiteralPath $f1Canary -Recurse -Force -Directory | ForEach-Object { $_.FullName.Substring($f1Canary.Length) })
    $f1CanaryDiff = Compare-DirectorySnapshot $f1CanaryFilesBefore $f1CanaryFilesAfter
    $f1CanaryDiffRemoved = @($f1CanaryDiff.Removed)
    $f1CanaryDiffAdded = @($f1CanaryDiff.Added)
    $f1CanaryDiffChanged = @($f1CanaryDiff.Changed)
    $f1SandboxDirsCreated = @(Get-ChildItem -LiteralPath $f1Canary -Recurse -Force -Directory | Where-Object { $_.Name -like 't1-03-path-safety-*' })
    $f1DefaultRootNamesAfter = @(Get-ChildItem -LiteralPath $defaultTestRoot -Force | ForEach-Object { $_.Name })
    $f1DefaultEvidenceAfter = if (Test-Path $f1DefaultEvidencePath -PathType Leaf) { (Get-FileHash -LiteralPath $f1DefaultEvidencePath -Algorithm SHA256).Hash } else { '' }
    $f1DefaultRootAdded = @($f1DefaultRootNamesAfter | Where-Object { $f1DefaultRootNamesBefore -notcontains $_ })
    $f1DefaultRootRemoved = @($f1DefaultRootNamesBefore | Where-Object { $f1DefaultRootNamesAfter -notcontains $_ })

    Add-UatPathCheck -Name 'f1.rootJunctionChildExitCode2' -Pass ($f1Child.ExitCode -eq 2) -Detail ('exit=' + $f1Child.ExitCode)
    $f1ChildRejected = ($f1Child.ExitCode -eq 2) -and
        $f1Child.Output.Contains('PRECONDITION_FAILED') -and
        $f1Child.Output.Contains('专用测试根目录') -and
        $f1Child.Output.Contains('重解析点')
    Add-UatPathCheck -Name 'f1.rootJunctionRejectedBeforeAnyWrite' -Pass $f1ChildRejected -Detail ('exit=' + $f1Child.ExitCode + '; rejectedByTrustAnchor=' + [bool]($f1Child.Output.Contains('专用测试根目录')) + '; reparseKeyword=' + [bool]($f1Child.Output.Contains('重解析点')))
    Add-UatPathCheck -Name 'f1.rootJunctionCanaryUnchanged' -Pass (($f1CanaryDiffRemoved.Count -eq 0) -and ($f1CanaryDiffAdded.Count -eq 0) -and ($f1CanaryDiffChanged.Count -eq 0) -and ($f1CanaryDirsBefore.Count -eq $f1CanaryDirsAfter.Count)) -Detail ('filesRemoved=' + $f1CanaryDiffRemoved.Count + '; filesAdded=' + $f1CanaryDiffAdded.Count + '; filesChanged=' + $f1CanaryDiffChanged.Count + '; dirsBefore=' + $f1CanaryDirsBefore.Count + '; dirsAfter=' + $f1CanaryDirsAfter.Count)
    Add-UatPathCheck -Name 'f1.rootJunctionNoSandboxCreated' -Pass (($f1SandboxDirsCreated.Count -eq 0) -and (-not (Test-Path -LiteralPath $f1ChildEvidencePath))) -Detail ('sandboxDirsCreated=' + $f1SandboxDirsCreated.Count + '; childEvidenceWritten=' + [bool](Test-Path -LiteralPath $f1ChildEvidencePath))
    Add-UatPathCheck -Name 'f1.rootJunctionDefaultRootUntouched' -Pass (($f1DefaultRootAdded.Count -eq 0) -and ($f1DefaultRootRemoved.Count -eq 0)) -Detail ('added=' + $f1DefaultRootAdded.Count + '; removed=' + $f1DefaultRootRemoved.Count)

    # 7.3 测试根目录不存在：直接失败，不得自动创建（真实入口子进程）。
    $f1MissingParent = Join-Path $f1Root 'missing-root-parent'
    $f1MissingRoot = Join-Path $f1MissingParent 'test-root-not-created'
    $f1MissingChildEvidence = Join-Path $f1Root 'child-missing-evidence-must-not-be-written.json'
    $f1MissingChild = Invoke-ChildPathTestScript -TestRootOverrideValue $f1MissingRoot -ChildEvidencePath $f1MissingChildEvidence
    Add-UatPathCheck -Name 'f1.missingRootChildExitCode2' -Pass ($f1MissingChild.ExitCode -eq 2) -Detail ('exit=' + $f1MissingChild.ExitCode)
    $f1MissingRejected = ($f1MissingChild.ExitCode -eq 2) -and
        $f1MissingChild.Output.Contains('PRECONDITION_FAILED') -and
        $f1MissingChild.Output.Contains('不存在')
    Add-UatPathCheck -Name 'f1.missingRootNotAutoCreated' -Pass ((-not (Test-Path -LiteralPath $f1MissingParent)) -and (-not (Test-Path -LiteralPath $f1MissingRoot)) -and $f1MissingRejected) -Detail ('missingParentCreated=' + [bool](Test-Path -LiteralPath $f1MissingParent) + '; keywordMissing=' + [bool]($f1MissingChild.Output.Contains('不存在')))
    Add-UatPathCheck -Name 'f1.missingRootNoWriteSideEffects' -Pass (-not (Test-Path -LiteralPath $f1MissingChildEvidence)) -Detail ('childEvidenceWritten=' + [bool](Test-Path -LiteralPath $f1MissingChildEvidence))

    # 7.4 注入参数本身不得绕过默认路径：即使覆盖到合法普通目录，也只允许“拒绝”，不执行完整套件/不写沙箱。
    $f1ValidOverrideRoot = Join-Path $sandbox 'f1-valid-override-root'
    New-Item -ItemType Directory -Force -Path $f1ValidOverrideRoot | Out-Null
    [void]$script:Targets.Add($f1ValidOverrideRoot)
    $f1ValidOverrideChild = Invoke-ChildPathTestScript -TestRootOverrideValue $f1ValidOverrideRoot -ChildEvidencePath (Join-Path $f1ValidOverrideRoot 'child-evidence-must-not-be-written.json')
    $f1ValidOverrideEntries = @(Get-ChildItem -LiteralPath $f1ValidOverrideRoot -Force)
    Add-UatPathCheck -Name 'f1.validOverrideChildExitCode2' -Pass ($f1ValidOverrideChild.ExitCode -eq 2) -Detail ('exit=' + $f1ValidOverrideChild.ExitCode)
    Add-UatPathCheck -Name 'f1.validOverrideNoSandboxCreated' -Pass (($f1ValidOverrideEntries.Count -eq 0) -and (-not (Test-Path -LiteralPath (Join-Path $f1ValidOverrideRoot 'child-evidence-must-not-be-written.json')))) -Detail ('entriesInOverrideRoot=' + $f1ValidOverrideEntries.Count)

    # 7.5 清理 F1 真实 Junction，并再次确认外部 Canary 未受影响。
    Remove-UntrackedTestLink $f1RootLink
    $f1LinkStillPresent = Test-Path -LiteralPath $f1RootLink
    $f1CanaryAfterLinkCleanup = Get-DirectorySnapshot $f1Canary
    $f1CanaryAfterDiff = Compare-DirectorySnapshot $f1CanaryFilesBefore $f1CanaryAfterLinkCleanup
    $f1CanaryAfterDiffRemoved = @($f1CanaryAfterDiff.Removed)
    $f1CanaryAfterDiffAdded = @($f1CanaryAfterDiff.Added)
    $f1CanaryAfterDiffChanged = @($f1CanaryAfterDiff.Changed)
    Add-UatPathCheck -Name 'f1.canaryIntactAfterLinkCleanup' -Pass ((-not $f1LinkStillPresent) -and ($f1CanaryAfterDiffRemoved.Count -eq 0) -and ($f1CanaryAfterDiffAdded.Count -eq 0) -and ($f1CanaryAfterDiffChanged.Count -eq 0)) -Detail ('linkStillPresent=' + [bool]$f1LinkStillPresent + '; canaryChanged=' + ($f1CanaryAfterDiffRemoved.Count + $f1CanaryAfterDiffAdded.Count + $f1CanaryAfterDiffChanged.Count))
    Add-UatPathCheck -Name 'f1.childDidNotWriteDefaultEvidence' -Pass ($f1DefaultEvidenceBefore -eq $f1DefaultEvidenceAfter) -Detail ('defaultEvidenceChanged=' + [bool]($f1DefaultEvidenceBefore -ne $f1DefaultEvidenceAfter))
    Remove-TestTreeSafely $f1Root

    $script:F1Summary = [ordered]@{
        trustAnchorPath                = [string]$f1TrustRecord.path
        trustAnchorComponents          = [int]$f1TrustRecord.existingComponentCount
        rootJunctionChildExitCode      = $f1Child.ExitCode
        rootJunctionCanaryUnchanged    = [bool](($f1CanaryDiffRemoved.Count -eq 0) -and ($f1CanaryDiffAdded.Count -eq 0) -and ($f1CanaryDiffChanged.Count -eq 0))
        rootJunctionSandboxCreated     = [bool]($f1SandboxDirsCreated.Count -gt 0)
        missingRootChildExitCode       = $f1MissingChild.ExitCode
        missingRootAutoCreated         = [bool](Test-Path -LiteralPath $f1MissingRoot)
        validOverrideChildExitCode     = $f1ValidOverrideChild.ExitCode
        validOverrideSandboxCreated    = [bool]($f1ValidOverrideEntries.Count -gt 0)
        defaultEvidenceUntouched       = [bool]($f1DefaultEvidenceBefore -eq $f1DefaultEvidenceAfter)
        canaryIntactAfterLinkCleanup   = [bool]((-not $f1LinkStillPresent) -and ($f1CanaryAfterDiffRemoved.Count -eq 0) -and ($f1CanaryAfterDiffAdded.Count -eq 0) -and ($f1CanaryAfterDiffChanged.Count -eq 0))
    }

    # -----------------------------------------------------------------------
    # 8. 第四轮 F2：清理 fail closed / 真实文件系统故障注入
    # -----------------------------------------------------------------------
    $f2CaseSummary = [ordered]@{}

    # 8.1 正常清理：真实 Junction 删除成功，外部 Canary 不变。
    $f2Normal = New-F2CaseSandbox -Name 'normal' -CanaryValue 'f2-canary-normal'
    $f2NormalResult = Invoke-T103FailClosedSandboxCleanup -SandboxPath $f2Normal.Sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $f2Normal.TrustRecord -TrackedLinks @($f2Normal.Link)
    $f2NormalCanary = Get-CanaryContent $f2Normal.Canary
    $f2NormalSandboxGone = -not (Test-Path -LiteralPath $f2Normal.Sandbox)
    Add-UatPathCheck -Name 'f2.normalJunctionRemovalSucceeds' -Pass (($f2NormalResult.safe -eq $true) -and $f2NormalSandboxGone -and (-not (Test-Path -LiteralPath $f2Normal.Link))) -Detail ('safe=' + [string]$f2NormalResult.safe + '; stopCode=' + [string]$f2NormalResult.stopCode + '; sandboxGone=' + [bool]$f2NormalSandboxGone)
    Add-UatPathCheck -Name 'f2.normalCleanupTargetCanaryIntact' -Pass ($f2NormalCanary -eq $f2Normal.CanaryValue) -Detail ('canaryPreserved=' + [bool]($f2NormalCanary -eq $f2Normal.CanaryValue))
    Remove-TestTreeSafely $f2Normal.Root
    $f2CaseSummary.normal = [ordered]@{ safe = $f2NormalResult.safe; recursiveDeletePerformed = $f2NormalResult.recursiveDeletePerformed; stopCode = $f2NormalResult.stopCode; targetCanaryIntact = [bool]($f2NormalCanary -eq $f2Normal.CanaryValue) }

    # 8.2 模拟 Junction 删除失败：受控故障注入在真实链接删除步骤抛出确定性异常。
    $f2DeleteFail = New-F2CaseSandbox -Name 'deletefail' -CanaryValue 'f2-canary-deletefail'
    $f2DeleteFailHook = {
        param($stage, $path)
        if ($stage -eq 'beforeLinkDelete') {
            throw '故障注入：模拟操作系统拒绝删除该 Junction（受控注入，不改动真实 ACL）。'
        }
    }
    $f2DeleteFailResult = Invoke-T103FailClosedSandboxCleanup -SandboxPath $f2DeleteFail.Sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $f2DeleteFail.TrustRecord -TrackedLinks @($f2DeleteFail.Link) -FaultHook $f2DeleteFailHook
    $f2DeleteFailCanary = Get-CanaryContent $f2DeleteFail.Canary
    $f2DeleteFailSentinel = Get-CanaryContent $f2DeleteFail.Sentinel
    $f2DeleteFailSandboxPreserved = Test-Path -LiteralPath $f2DeleteFail.Sandbox
    $f2DeleteFailLinkPreserved = Test-IsReparseLink $f2DeleteFail.Link
    $f2DeleteFailUnsafe = @($f2DeleteFailResult.unsafePaths)
    $f2DeleteFailLocatable = ($f2DeleteFailUnsafe.Count -gt 0) -and
        (-not [string]::IsNullOrWhiteSpace([string]$f2DeleteFailResult.stopReason)) -and
        (($f2DeleteFailUnsafe | Where-Object { $_ -eq $f2DeleteFail.Link }).Count -gt 0)
    Add-UatPathCheck -Name 'f2.trackedDeleteFailureStopsRecursiveDelete' -Pass (($f2DeleteFailResult.safe -eq $false) -and ($f2DeleteFailResult.recursiveDeletePerformed -eq $false) -and ($f2DeleteFailResult.stopCode -eq 'trackedLinkDeleteFailed')) -Detail ('safe=' + [string]$f2DeleteFailResult.safe + '; recursiveDeletePerformed=' + [string]$f2DeleteFailResult.recursiveDeletePerformed + '; stopCode=' + [string]$f2DeleteFailResult.stopCode)
    Add-UatPathCheck -Name 'f2.trackedDeleteFailurePreservesSandbox' -Pass ($f2DeleteFailSandboxPreserved -and $f2DeleteFailLinkPreserved -and ($f2DeleteFailSentinel -eq 'sentinel-deletefail')) -Detail ('sandboxPreserved=' + [bool]$f2DeleteFailSandboxPreserved + '; linkPreserved=' + [bool]$f2DeleteFailLinkPreserved + '; sentinelPreserved=' + [bool]($f2DeleteFailSentinel -eq 'sentinel-deletefail'))
    Add-UatPathCheck -Name 'f2.trackedDeleteFailureTargetCanaryIntact' -Pass ($f2DeleteFailCanary -eq $f2DeleteFail.CanaryValue) -Detail ('canaryPreserved=' + [bool]($f2DeleteFailCanary -eq $f2DeleteFail.CanaryValue))
    Add-UatPathCheck -Name 'f2.trackedDeleteFailureReportsLocatablePath' -Pass $f2DeleteFailLocatable -Detail ('unsafePathCount=' + $f2DeleteFailUnsafe.Count + '; stopReasonPresent=' + [bool](-not [string]::IsNullOrWhiteSpace([string]$f2DeleteFailResult.stopReason)))

    # 8.3 模拟链接删除后仍然存在：故障钩子在删除后立即用真实 mklink /J 重建链接。
    $f2Reappear = New-F2CaseSandbox -Name 'reappear' -CanaryValue 'f2-canary-reappear'
    $f2ReappearHook = {
        param($stage, $path)
        if ($stage -eq 'afterLinkDelete') {
            $hookResult = Invoke-Mklink ('mklink /J "' + $path + '" "' + $f2Reappear.Target + '"')
            if ($hookResult.ExitCode -ne 0) {
                throw ('故障注入：重建 Junction 失败：' + $hookResult.Output)
            }
        }
    }
    $f2ReappearResult = Invoke-T103FailClosedSandboxCleanup -SandboxPath $f2Reappear.Sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $f2Reappear.TrustRecord -TrackedLinks @($f2Reappear.Link) -FaultHook $f2ReappearHook
    $f2ReappearCanary = Get-CanaryContent $f2Reappear.Canary
    $f2ReappearSentinel = Get-CanaryContent $f2Reappear.Sentinel
    $f2ReappearSandboxPreserved = Test-Path -LiteralPath $f2Reappear.Sandbox
    Add-UatPathCheck -Name 'f2.linkReappearsAfterDeleteDetected' -Pass (($f2ReappearResult.safe -eq $false) -and ($f2ReappearResult.recursiveDeletePerformed -eq $false) -and ($f2ReappearResult.stopCode -eq 'trackedLinkStillExists')) -Detail ('safe=' + [string]$f2ReappearResult.safe + '; stopCode=' + [string]$f2ReappearResult.stopCode)
    Add-UatPathCheck -Name 'f2.linkReappearsSandboxPreserved' -Pass ($f2ReappearSandboxPreserved -and ($f2ReappearSentinel -eq 'sentinel-reappear')) -Detail ('sandboxPreserved=' + [bool]$f2ReappearSandboxPreserved + '; sentinelPreserved=' + [bool]($f2ReappearSentinel -eq 'sentinel-reappear'))

    # 8.4 沙箱中出现未跟踪的 Reparse Point：拒绝递归删除并保留现场。
    $f2Untracked = New-F2CaseSandbox -Name 'untracked' -CanaryValue 'f2-canary-untracked'
    $f2UntrackedSub = Join-Path $f2Untracked.Sandbox 'sub'
    New-Item -ItemType Directory -Force -Path $f2UntrackedSub | Out-Null
    $f2UntrackedTarget = Join-Path $f2Untracked.Root 'untracked-target'
    New-Item -ItemType Directory -Force -Path $f2UntrackedTarget | Out-Null
    Set-Content -Path (Join-Path $f2UntrackedTarget 'canary.txt') -Value 'f2-canary-untracked-target' -Encoding UTF8
    $f2UntrackedLink = Join-Path $f2UntrackedSub 'untracked-link'
    New-UntrackedTestJunction $f2UntrackedLink $f2UntrackedTarget
    $f2UntrackedResult = Invoke-T103FailClosedSandboxCleanup -SandboxPath $f2Untracked.Sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $f2Untracked.TrustRecord -TrackedLinks @($f2Untracked.Link)
    $f2UntrackedCanary = Get-CanaryContent $f2Untracked.Canary
    $f2UntrackedTargetCanary = Get-CanaryContent (Join-Path $f2UntrackedTarget 'canary.txt')
    $f2UntrackedSentinel = Get-CanaryContent $f2Untracked.Sentinel
    $f2UntrackedSandboxPreserved = Test-Path -LiteralPath $f2Untracked.Sandbox
    $f2UntrackedUnsafe = @($f2UntrackedResult.unsafePaths)
    $f2UntrackedPathReported = (($f2UntrackedUnsafe | Where-Object { $_ -eq $f2UntrackedLink }).Count -gt 0)
    Add-UatPathCheck -Name 'f2.untrackedReparsePointDetected' -Pass (($f2UntrackedResult.safe -eq $false) -and ($f2UntrackedResult.recursiveDeletePerformed -eq $false) -and ($f2UntrackedResult.stopCode -eq 'unexpectedReparsePoint') -and $f2UntrackedSandboxPreserved -and $f2UntrackedPathReported -and ($f2UntrackedSentinel -eq 'sentinel-untracked')) -Detail ('safe=' + [string]$f2UntrackedResult.safe + '; stopCode=' + [string]$f2UntrackedResult.stopCode + '; sandboxPreserved=' + [bool]$f2UntrackedSandboxPreserved + '; untrackedPathReported=' + [bool]$f2UntrackedPathReported)
    Add-UatPathCheck -Name 'f2.untrackedReparsePointTargetCanaryIntact' -Pass (($f2UntrackedCanary -eq $f2Untracked.CanaryValue) -and ($f2UntrackedTargetCanary -eq 'f2-canary-untracked-target')) -Detail ('trackedTargetCanaryPreserved=' + [bool]($f2UntrackedCanary -eq $f2Untracked.CanaryValue) + '; untrackedTargetCanaryPreserved=' + [bool]($f2UntrackedTargetCanary -eq 'f2-canary-untracked-target'))

    # 8.5 清理前路径身份发生变化：真实沙箱目录被替换为指向其他目录的 Junction。
    $f2Identity = New-F2CaseSandbox -Name 'identity' -CanaryValue 'f2-canary-identity'
    $f2IdentityMoved = $f2Identity.Sandbox + '-moved'
    Rename-Item -LiteralPath $f2Identity.Sandbox -NewName (Split-Path $f2IdentityMoved -Leaf)
    $f2IdentityTarget = Join-Path $f2Identity.Root 'identity-target'
    New-Item -ItemType Directory -Force -Path $f2IdentityTarget | Out-Null
    Set-Content -Path (Join-Path $f2IdentityTarget 'canary.txt') -Value 'f2-canary-identity-swapped' -Encoding UTF8
    New-UntrackedTestJunction $f2Identity.Sandbox $f2IdentityTarget
    $f2IdentityResult = Invoke-T103FailClosedSandboxCleanup -SandboxPath $f2Identity.Sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $f2Identity.TrustRecord -TrackedLinks @($f2Identity.Link)
    $f2IdentityCanary = Get-CanaryContent (Join-Path $f2IdentityTarget 'canary.txt')
    $f2IdentitySandboxPreserved = Test-Path -LiteralPath $f2Identity.Sandbox
    $f2IdentityStopOk = (($f2IdentityResult.safe -eq $false) -and ($f2IdentityResult.recursiveDeletePerformed -eq $false) -and ($f2IdentityResult.stopCode -eq 'sandboxIdentityChanged'))
    Add-UatPathCheck -Name 'f2.identityChangeBeforeCleanupDetected' -Pass ($f2IdentityStopOk -and $f2IdentitySandboxPreserved) -Detail ('safe=' + [string]$f2IdentityResult.safe + '; stopCode=' + [string]$f2IdentityResult.stopCode + '; sandboxPreserved=' + [bool]$f2IdentitySandboxPreserved)
    Add-UatPathCheck -Name 'f2.identityChangeTargetCanaryIntact' -Pass ($f2IdentityCanary -eq 'f2-canary-identity-swapped') -Detail ('swappedTargetCanaryPreserved=' + [bool]($f2IdentityCanary -eq 'f2-canary-identity-swapped'))

    # 8.6 失败后重新检查所有目标 Canary；确认所有失败用例均未执行递归删除。
    $f2CanaryRechecks = [ordered]@{
        deleteFailure    = @{ path = $f2DeleteFail.Canary; expected = $f2DeleteFail.CanaryValue }
        reappearTarget   = @{ path = $f2Reappear.Canary; expected = $f2Reappear.CanaryValue }
        untrackedTracked = @{ path = $f2Untracked.Canary; expected = $f2Untracked.CanaryValue }
        untrackedTarget  = @{ path = (Join-Path $f2UntrackedTarget 'canary.txt'); expected = 'f2-canary-untracked-target' }
        identitySwapped  = @{ path = (Join-Path $f2IdentityTarget 'canary.txt'); expected = 'f2-canary-identity-swapped' }
    }
    $f2CanaryRecheckOk = $true
    foreach ($recheck in $f2CanaryRechecks.Values) {
        $actual = Get-CanaryContent ([string]$recheck.path)
        if ($actual -ne [string]$recheck.expected) { $f2CanaryRecheckOk = $false }
    }
    Add-UatPathCheck -Name 'f2.failureCasesRecheckCanaryUnchanged' -Pass $f2CanaryRecheckOk -Detail ('canariesChecked=' + @($f2CanaryRechecks.Keys).Count + '; unchanged=' + [bool]$f2CanaryRecheckOk)
    $f2FailureResults = @($f2DeleteFailResult, $f2ReappearResult, $f2UntrackedResult, $f2IdentityResult)
    $f2NoRecursiveDelete = (@($f2FailureResults | Where-Object { ($_.safe -eq $false) -and ($_.recursiveDeletePerformed -eq $false) }).Count -eq $f2FailureResults.Count)
    Add-UatPathCheck -Name 'f2.noRecursiveDeleteInFailureCases' -Pass $f2NoRecursiveDelete -Detail ('failureCases=' + $f2FailureResults.Count + '; allStoppedBeforeRecursiveDelete=' + [bool]$f2NoRecursiveDelete)

    $f2CaseSummary.deleteFailure = [ordered]@{ safe = $f2DeleteFailResult.safe; recursiveDeletePerformed = $f2DeleteFailResult.recursiveDeletePerformed; stopCode = $f2DeleteFailResult.stopCode; sandboxPreserved = [bool]$f2DeleteFailSandboxPreserved; targetCanaryIntact = [bool]($f2DeleteFailCanary -eq $f2DeleteFail.CanaryValue); faultInjection = 'controlled hook failure at real junction-delete step (real link, sandbox and external canary preserved)' }
    $f2CaseSummary.reappear = [ordered]@{ safe = $f2ReappearResult.safe; recursiveDeletePerformed = $f2ReappearResult.recursiveDeletePerformed; stopCode = $f2ReappearResult.stopCode; sandboxPreserved = [bool]$f2ReappearSandboxPreserved; targetCanaryIntact = [bool]($f2ReappearCanary -eq $f2Reappear.CanaryValue) }
    $f2CaseSummary.untrackedReparsePoint = [ordered]@{ safe = $f2UntrackedResult.safe; recursiveDeletePerformed = $f2UntrackedResult.recursiveDeletePerformed; stopCode = $f2UntrackedResult.stopCode; sandboxPreserved = [bool]$f2UntrackedSandboxPreserved; targetCanaryIntact = [bool](($f2UntrackedCanary -eq $f2Untracked.CanaryValue) -and ($f2UntrackedTargetCanary -eq 'f2-canary-untracked-target')) }
    $f2CaseSummary.identityChange = [ordered]@{ safe = $f2IdentityResult.safe; recursiveDeletePerformed = $f2IdentityResult.recursiveDeletePerformed; stopCode = $f2IdentityResult.stopCode; sandboxPreserved = [bool]$f2IdentitySandboxPreserved; targetCanaryIntact = [bool]($f2IdentityCanary -eq 'f2-canary-identity-swapped') }
    $f2CaseSummary.canaryRecheckUnchanged = [bool]$f2CanaryRecheckOk
    $f2CaseSummary.allFailuresStoppedBeforeRecursiveDelete = [bool]$f2NoRecursiveDelete

    # 8.7 用例自清理（先验证/删除真实链接，再逐条目安全删除普通目录）。
    Remove-UntrackedTestLink $f2DeleteFail.Link
    Remove-TestTreeSafely $f2DeleteFail.Sandbox
    Remove-TestTreeSafely $f2DeleteFail.Root
    Remove-UntrackedTestLink $f2Reappear.Link
    Remove-TestTreeSafely $f2Reappear.Sandbox
    Remove-TestTreeSafely $f2Reappear.Root
    Remove-UntrackedTestLink $f2UntrackedLink
    Remove-TestTreeSafely $f2Untracked.Sandbox
    Remove-TestTreeSafely $f2UntrackedTarget
    Remove-TestTreeSafely $f2Untracked.Root
    Remove-UntrackedTestLink $f2Identity.Sandbox
    Remove-UntrackedTestLink (Join-Path $f2IdentityMoved 'linked-target')
    Remove-TestTreeSafely $f2IdentityMoved
    Remove-TestTreeSafely $f2IdentityTarget
    Remove-TestTreeSafely $f2Identity.Root

    # -----------------------------------------------------------------------
    # 8b. 第五轮 F1/F2 最小修复：证据写入边界 + 沙箱入口原生检查
    # ---------------------------------------------------------------
    # 全部使用真实文件系统对象（真实目录 / 真实 Junction / 真实悬空 Junction /
    # 真实硬链接），不修改 Windows ACL，不执行 Access Denied 测试。
    # -----------------------------------------------------------------------
    $r5Root = Join-Path $sandbox 'round5'
    New-Item -ItemType Directory -Force -Path $r5Root | Out-Null
    [void]$script:Targets.Add($r5Root)

    # 证据目录之外的外部 Canary：业务数据库文件 + 守护 Canary。
    $r5BusinessDir = Join-Path $r5Root 'business'
    New-Item -ItemType Directory -Force -Path $r5BusinessDir | Out-Null
    $r5BusinessFile = Join-Path $r5BusinessDir 'work.db'
    Set-Content -LiteralPath $r5BusinessFile -Value 'ROUND5-BUSINESS-DB-CONTENT' -Encoding UTF8
    $r5BusinessHashBefore = (Get-FileHash -LiteralPath $r5BusinessFile -Algorithm SHA256).Hash
    $r5CanaryFile = Join-Path $r5Root 'guardian-canary.txt'
    Set-Content -LiteralPath $r5CanaryFile -Value 'ROUND5-GUARDIAN-CANARY' -Encoding UTF8
    $r5CanaryHashBefore = (Get-FileHash -LiteralPath $r5CanaryFile -Algorithm SHA256).Hash

    # F1 注入用证据目录（真实普通目录；长名称用于 8.3 短名身份用例）。
    $r5EvidenceRoot = Join-Path $r5Root 'evidence-root-long-name'
    New-Item -ItemType Directory -Force -Path $r5EvidenceRoot | Out-Null
    $r5OkContent = ''

    # F1-1 正常写入：必须真实写入注入证据目录之内。
    $r5OkPath = Join-Path $r5EvidenceRoot 'sub\ok-evidence.json'
    try {
        $r5Written = Write-T103EvidenceFile -Path $r5OkPath -Content '{"round5":"ok"}' -EvidenceRoot $r5EvidenceRoot
        $r5OkContent = if (Test-Path -LiteralPath $r5OkPath -PathType Leaf) { (Get-Content -LiteralPath $r5OkPath -Raw -Encoding UTF8).Trim() } else { '' }
        $r5Ok = ($r5OkContent -eq '{"round5":"ok"}') -and [bool](Test-T103FinalPathInside $r5Written $script:T103UatTestRoot)
        Add-UatPathCheck -Name 'f1.evidenceWriteInsideRootSucceeds' -Pass $r5Ok -Detail ('written=' + (Format-EvidencePath $r5Written) + '; contentMatched=' + [bool]($r5OkContent -eq '{"round5":"ok"}'))
    }
    catch {
        Add-UatPathCheck -Name 'f1.evidenceWriteInsideRootSucceeds' -Pass $false -Detail ('unexpected rejection: ' + (Format-EvidencePath $_.Exception.Message))
    }

    # F1-2 相对路径越界：相对仓库根目录解析后仍不在证据目录内。
    $r5RelativePath = 'test-artifacts\round5-relative-escape.json'
    $r5RelativeAbsolute = Join-Path $script:T103RepoRoot $r5RelativePath
    $r5RelativeExistedBefore = Test-Path -LiteralPath $r5RelativeAbsolute
    Test-EvidenceWriteRejected -Name 'f1.evidenceRelativeEscapeRejected' -Path $r5RelativePath -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '边界' -SideEffectDetail ('outsideFileCreated=' + [bool](Test-Path -LiteralPath $r5RelativeAbsolute))
    if ((-not $r5RelativeExistedBefore) -and (Test-Path -LiteralPath $r5RelativeAbsolute)) {
        Remove-Item -LiteralPath $r5RelativeAbsolute -Force -ErrorAction SilentlyContinue
    }

    # F1-3 “..” 路径遍历越界。
    $r5DotDotPath = Join-Path $r5EvidenceRoot '..\business\dotdot-escape.json'
    $r5DotDotAbsolute = Join-Path $r5BusinessDir 'dotdot-escape.json'
    Test-EvidenceWriteRejected -Name 'f1.evidenceDotDotTraversalRejected' -Path $r5DotDotPath -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '边界' -SideEffectDetail ('outsideFileCreated=' + [bool](Test-Path -LiteralPath $r5DotDotAbsolute))

    # F1-4 证据目录之外的绝对路径。
    $r5AbsolutePath = Join-Path $r5BusinessDir 'absolute-escape.json'
    Test-EvidenceWriteRejected -Name 'f1.evidenceAbsoluteOutsideRejected' -Path $r5AbsolutePath -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '边界' -SideEffectDetail ('outsideFileCreated=' + [bool](Test-Path -LiteralPath $r5AbsolutePath))

    # F1-5 证据目录内 Junction 指向外部目录：必须拒绝且不触碰链接目标。
    $r5JunctionTarget = Join-Path $r5Root 'junction-target'
    New-Item -ItemType Directory -Force -Path $r5JunctionTarget | Out-Null
    $r5JunctionCanary = Join-Path $r5JunctionTarget 'canary.txt'
    Set-Content -LiteralPath $r5JunctionCanary -Value 'ROUND5-JUNCTION-TARGET-CANARY' -Encoding UTF8
    $r5JunctionHashBefore = (Get-FileHash -LiteralPath $r5JunctionCanary -Algorithm SHA256).Hash
    $r5Junction = Join-Path $r5EvidenceRoot 'j-link'
    New-UntrackedTestJunction $r5Junction $r5JunctionTarget
    Test-EvidenceWriteRejected -Name 'f1.evidenceJunctionBypassRejected' -Path (Join-Path $r5Junction 'out.json') -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '重解析点' -SideEffectDetail ('targetCanaryUnchanged=' + [bool]((Get-FileHash -LiteralPath $r5JunctionCanary -Algorithm SHA256).Hash -eq $r5JunctionHashBefore))
    Remove-UntrackedTestLink $r5Junction

    # F1-6 证据目录内悬空 Junction：必须识别链接本身并拒绝。
    $r5DanglingTarget = Join-Path $r5Root 'dangling-target'
    New-Item -ItemType Directory -Force -Path $r5DanglingTarget | Out-Null
    $r5Dangling = Join-Path $r5EvidenceRoot 'j-dangling'
    New-UntrackedTestJunction $r5Dangling $r5DanglingTarget
    [System.IO.Directory]::Delete($r5DanglingTarget, $false)
    $r5DanglingState = Get-T103EntryNativeState -Path $r5Dangling -Label '证据目录悬空 Junction'
    Test-EvidenceWriteRejected -Name 'f1.evidenceDanglingJunctionRejected' -Path (Join-Path $r5Dangling 'out.json') -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '重解析点' -SideEffectDetail ('testPath=' + [bool](Test-Path -LiteralPath $r5Dangling) + '; nativeExists=' + [bool]$r5DanglingState.exists + '; reparseTag=' + [string]$r5DanglingState.reparseTag)
    Remove-UntrackedTestLink $r5Dangling

    # F1-7 已有目标文件是数据库文件的硬链接：必须拒绝且原文件不变。
    $r5HardLink = Join-Path $r5EvidenceRoot 'hardlink-work-db.json'
    New-Item -ItemType HardLink -Path $r5HardLink -Target $r5BusinessFile | Out-Null
    Test-EvidenceWriteRejected -Name 'f1.evidenceUnsafeExistingTargetRejected' -Path $r5HardLink -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '硬链接' -SideEffectDetail ('businessHashUnchanged=' + [bool]((Get-FileHash -LiteralPath $r5BusinessFile -Algorithm SHA256).Hash -eq $r5BusinessHashBefore))
    Remove-Item -LiteralPath $r5HardLink -Force

    # F1-8 证据目录真实身份不一致：同一路径目录被替换（rename + 重建）后，文件 ID 变化必须拒绝。
    $r5SwapRoot = Join-Path $r5Root 'evidence-root-swap'
    New-Item -ItemType Directory -Force -Path $r5SwapRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $r5SwapRoot 'original-marker.txt') -Value 'ROUND5-ORIGINAL-EVIDENCE-ROOT' -Encoding UTF8
    $r5SwapRecordBefore = Get-T103DirectoryIdentityRecord -Path $r5SwapRoot -Label '第五轮证据目录（替换前）'
    Rename-Item -LiteralPath $r5SwapRoot -NewName 'evidence-root-swap-moved'
    New-Item -ItemType Directory -Force -Path $r5SwapRoot | Out-Null
    $r5SwapRecordAfter = Get-T103DirectoryIdentityRecord -Path $r5SwapRoot -Label '第五轮证据目录（替换后）'
    $r5SwapFileIdChanged = -not [string]::Equals([string]$r5SwapRecordBefore.fileIdHex, [string]$r5SwapRecordAfter.fileIdHex, [System.StringComparison]::Ordinal)
    $r5SwapRejected = $false
    $r5SwapMessage = ''
    try {
        [void](Write-T103EvidenceFile -Path (Join-Path $r5SwapRoot 'after-swap.json') -Content 'x' -EvidenceRoot $r5SwapRoot -ExpectedRootIdentity $r5SwapRecordBefore)
    }
    catch {
        $r5SwapRejected = $true
        $r5SwapMessage = $_.Exception.Message
    }
    $r5SwapOk = $r5SwapRejected -and $r5SwapMessage.Contains('身份') -and $r5SwapFileIdChanged -and (-not (Test-Path -LiteralPath (Join-Path $r5SwapRoot 'after-swap.json')))
    Add-UatPathCheck -Name 'f1.evidenceRootIdentityMismatchRejected' -Pass $r5SwapOk -Detail ('rejected=' + [bool]$r5SwapRejected + '; fileIdChanged=' + [bool]$r5SwapFileIdChanged + '; message=' + (Format-EvidencePath $r5SwapMessage))
    Remove-TestTreeSafely $r5SwapRoot
    Remove-TestTreeSafely (Join-Path $r5Root 'evidence-root-swap-moved')

    # F1-9 正式数据库/正式目录作为写入目标：拒绝且正式目录状态不变。
    $r5FormalBefore = Test-Path -LiteralPath $script:T103UatFormalRoot
    Test-EvidenceWriteRejected -Name 'f1.evidenceFormalDatabaseTargetRejected' -Path ($script:T103UatFormalRoot + '\data\database\work.db') -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '正式应用目录' -SideEffectDetail ('formalRootExistsBefore=' + [bool]$r5FormalBefore + '; formalRootExistsAfter=' + [bool](Test-Path -LiteralPath $script:T103UatFormalRoot) + '; businessHashUnchanged=' + [bool]((Get-FileHash -LiteralPath $r5BusinessFile -Algorithm SHA256).Hash -eq $r5BusinessHashBefore))

    # F1-10 原生路径检查失败（路径组件是文件而不是目录）：fail-closed。
    $r5NotADirectory = Join-Path $r5EvidenceRoot 'not-a-directory.txt'
    Set-Content -LiteralPath $r5NotADirectory -Value 'ROUND5-FILE-COMPONENT' -Encoding UTF8
    Test-EvidenceWriteRejected -Name 'f1.evidenceNativeCheckFailureFailsClosed' -Path (Join-Path $r5NotADirectory 'out.json') -EvidenceRoot $r5EvidenceRoot -ExpectedKeyword '不是目录' -SideEffectDetail ('childWritten=' + [bool](Test-Path -LiteralPath (Join-Path $r5NotADirectory 'out.json')))

    # F1-11 默认证据目录必须能通过同一守卫（只校验，不写入）。
    $r5DefaultOk = $false
    try {
        $r5DefaultCandidate = Assert-T103EvidenceWritePath -Path (Join-Path $script:T103EvidenceRoot 'round5\t1-03-uat-path-evidence.json')
        $r5DefaultOk = [bool](Test-T103FinalPathInside $r5DefaultCandidate $script:T103EvidenceRoot)
    }
    catch {
        $r5DefaultOk = $false
    }
    Add-UatPathCheck -Name 'f1.evidenceDefaultRootTrusted' -Pass $r5DefaultOk -Detail ('repositoryEvidenceRoot=' + (Format-EvidencePath $script:T103EvidenceRoot) + '; candidateInsideRoot=' + [bool]$r5DefaultOk)

    # F1-12 全部拒绝用例之后：业务数据库与守护 Canary 内容/哈希不变。
    $r5BusinessHashAfter = (Get-FileHash -LiteralPath $r5BusinessFile -Algorithm SHA256).Hash
    $r5CanaryHashAfter = (Get-FileHash -LiteralPath $r5CanaryFile -Algorithm SHA256).Hash
    $r5JunctionCanaryHashAfter = (Get-FileHash -LiteralPath $r5JunctionCanary -Algorithm SHA256).Hash
    $r5CanariesOk = ($r5BusinessHashAfter -eq $r5BusinessHashBefore) -and ($r5CanaryHashAfter -eq $r5CanaryHashBefore) -and ($r5JunctionCanaryHashAfter -eq $r5JunctionHashBefore)
    Add-UatPathCheck -Name 'f1.canariesUnchangedAfterRejections' -Pass $r5CanariesOk -Detail ('businessDbUnchanged=' + [bool]($r5BusinessHashAfter -eq $r5BusinessHashBefore) + '; guardianCanaryUnchanged=' + [bool]($r5CanaryHashAfter -eq $r5CanaryHashBefore) + '; junctionTargetCanaryUnchanged=' + [bool]($r5JunctionCanaryHashAfter -eq $r5JunctionHashBefore))

    # F2-1 入口确实不存在：原生检查确认后才按原有规则处理。
    $r5F2AbsentRoot = New-F2EntryCaseRoot 'absent'
    $r5AbsentPath = Join-Path $r5F2AbsentRoot 'sandbox'
    $r5AbsentResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $r5AbsentPath -TestRoot $script:T103UatTestRoot -TrustRecord ([pscustomobject]@{})
    $r5AbsentOk = ($r5AbsentResult.safe -eq $true) -and
        ($r5AbsentResult.stopCode -eq 'sandboxAlreadyAbsent') -and
        ($r5AbsentResult.recursiveDeletePerformed -eq $false) -and
        (@($r5AbsentResult.steps) -contains 'sandbox.entryAbsentConfirmedByNativeCheck') -and
        (-not (Test-Path -LiteralPath $r5AbsentPath))
    Add-UatPathCheck -Name 'f2.entryTrulyAbsentConfirmedByNativeCheck' -Pass $r5AbsentOk -Detail ('safe=' + [string]$r5AbsentResult.safe + '; stopCode=' + [string]$r5AbsentResult.stopCode + '; recursiveDelete=' + [string]$r5AbsentResult.recursiveDeletePerformed + '; steps=' + (@($r5AbsentResult.steps) -join ','))
    Remove-TestTreeSafely $r5F2AbsentRoot

    # F2-2 正常沙箱入口：原生身份检查通过并完成逐条目安全清理。
    $r5F2NormalRoot = New-F2EntryCaseRoot 'normal'
    $r5NormalSandbox = Join-Path $r5F2NormalRoot 'sandbox'
    New-Item -ItemType Directory -Force -Path $r5NormalSandbox | Out-Null
    Set-Content -LiteralPath (Join-Path $r5NormalSandbox 'sentinel.txt') -Value 'round5-sentinel' -Encoding UTF8
    $r5NormalRecord = Get-T103DirectoryIdentityRecord -Path $r5NormalSandbox -Label '第五轮正常沙箱入口'
    $r5NormalResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $r5NormalSandbox -TestRoot $script:T103UatTestRoot -TrustRecord $r5NormalRecord
    $r5NormalOk = ($r5NormalResult.safe -eq $true) -and
        ($r5NormalResult.recursiveDeletePerformed -eq $true) -and
        (@($r5NormalResult.steps) -contains 'sandbox.identityVerified') -and
        (-not (Test-Path -LiteralPath $r5NormalSandbox))
    Add-UatPathCheck -Name 'f2.entryNormalDirectoryNativeCheckPasses' -Pass $r5NormalOk -Detail ('safe=' + [string]$r5NormalResult.safe + '; recursiveDelete=' + [string]$r5NormalResult.recursiveDeletePerformed + '; steps=' + (@($r5NormalResult.steps) -join ','))
    Remove-TestTreeSafely $r5F2NormalRoot

    # F2-3 入口是正常 Junction：识别 ReparsePoint 并 fail closed，不递归、不触碰目标。
    $r5F2JunctionRoot = New-F2EntryCaseRoot 'junction'
    $r5EntryJunctionTarget = Join-Path $r5F2JunctionRoot 'target'
    New-Item -ItemType Directory -Force -Path $r5EntryJunctionTarget | Out-Null
    $r5EntryJunctionCanary = Join-Path $r5EntryJunctionTarget 'canary.txt'
    Set-Content -LiteralPath $r5EntryJunctionCanary -Value 'ROUND5-ENTRY-JUNCTION-CANARY' -Encoding UTF8
    $r5EntryJunctionHashBefore = (Get-FileHash -LiteralPath $r5EntryJunctionCanary -Algorithm SHA256).Hash
    $r5EntryJunction = Join-Path $r5F2JunctionRoot 'entry-link'
    New-UntrackedTestJunction $r5EntryJunction $r5EntryJunctionTarget
    $r5EntryJunctionState = Get-T103EntryNativeState -Path $r5EntryJunction -Label '第五轮正常 Junction 入口'
    $r5EntryJunctionResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $r5EntryJunction -TestRoot $script:T103UatTestRoot -TrustRecord ([pscustomobject]@{})
    $r5EntryJunctionOk = ($r5EntryJunctionResult.safe -eq $false) -and
        ($r5EntryJunctionResult.stopCode -eq 'sandboxEntryIsReparsePoint') -and
        ($r5EntryJunctionResult.recursiveDeletePerformed -eq $false) -and
        $r5EntryJunctionState.exists -and $r5EntryJunctionState.isReparsePoint -and
        ((Get-FileHash -LiteralPath $r5EntryJunctionCanary -Algorithm SHA256).Hash -eq $r5EntryJunctionHashBefore) -and
        (Get-T103EntryNativeState -Path $r5EntryJunction -Label '第五轮正常 Junction 入口').exists
    Add-UatPathCheck -Name 'f2.entryNormalJunctionDetected' -Pass $r5EntryJunctionOk -Detail ('safe=' + [string]$r5EntryJunctionResult.safe + '; stopCode=' + [string]$r5EntryJunctionResult.stopCode + '; reparseTag=' + [string]$r5EntryJunctionState.reparseTag + '; targetCanaryUnchanged=' + [bool]((Get-FileHash -LiteralPath $r5EntryJunctionCanary -Algorithm SHA256).Hash -eq $r5EntryJunctionHashBefore) + '; linkStillPresent=' + [bool](Get-T103EntryNativeState -Path $r5EntryJunction -Label '第五轮正常 Junction 入口').exists)
    Remove-UntrackedTestLink $r5EntryJunction
    Remove-TestTreeSafely $r5F2JunctionRoot

    # F2-4 入口是悬空 Junction：原生检查识别链接本身并 fail closed。
    $r5F2DanglingRoot = New-F2EntryCaseRoot 'dangling'
    $r5EntryDanglingTarget = Join-Path $r5F2DanglingRoot 'gone-target'
    New-Item -ItemType Directory -Force -Path $r5EntryDanglingTarget | Out-Null
    $r5EntryDangling = Join-Path $r5F2DanglingRoot 'entry-dangling'
    New-UntrackedTestJunction $r5EntryDangling $r5EntryDanglingTarget
    [System.IO.Directory]::Delete($r5EntryDanglingTarget, $false)
    $r5EntryDanglingState = Get-T103EntryNativeState -Path $r5EntryDangling -Label '第五轮悬空 Junction 入口'
    $r5EntryDanglingResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $r5EntryDangling -TestRoot $script:T103UatTestRoot -TrustRecord ([pscustomobject]@{})
    $r5EntryDanglingOk = ($r5EntryDanglingResult.safe -eq $false) -and
        ($r5EntryDanglingResult.stopCode -eq 'sandboxEntryIsReparsePoint') -and
        ($r5EntryDanglingResult.recursiveDeletePerformed -eq $false) -and
        $r5EntryDanglingState.exists -and $r5EntryDanglingState.isReparsePoint -and
        ($r5EntryDanglingState.reparseTag -eq '0xA0000003') -and
        (Get-T103EntryNativeState -Path $r5EntryDangling -Label '第五轮悬空 Junction 入口').exists
    Add-UatPathCheck -Name 'f2.entryDanglingJunctionDetected' -Pass $r5EntryDanglingOk -Detail ('safe=' + [string]$r5EntryDanglingResult.safe + '; stopCode=' + [string]$r5EntryDanglingResult.stopCode + '; testPath=' + [bool](Test-Path -LiteralPath $r5EntryDangling) + '; nativeExists=' + [bool]$r5EntryDanglingState.exists + '; reparseTag=' + [string]$r5EntryDanglingState.reparseTag + '; linkStillPresent=' + [bool](Get-T103EntryNativeState -Path $r5EntryDangling -Label '第五轮悬空 Junction 入口').exists)
    Remove-UntrackedTestLink $r5EntryDangling
    Remove-TestTreeSafely $r5F2DanglingRoot

    # F2-5 Test-Path=False 的悬空 Junction 路径：不得绕过原生检查（旧实现会当作“入口不存在”）。
    $r5F2BypassRoot = New-F2EntryCaseRoot 'bypass'
    $r5BypassTarget = Join-Path $r5F2BypassRoot 'gone-target'
    New-Item -ItemType Directory -Force -Path $r5BypassTarget | Out-Null
    $r5BypassLink = Join-Path $r5F2BypassRoot 'entry-dangling'
    New-UntrackedTestJunction $r5BypassLink $r5BypassTarget
    [System.IO.Directory]::Delete($r5BypassTarget, $false)
    $r5BypassSandbox = Join-Path $r5BypassLink 'sandbox'
    $r5BypassTestPath = Test-Path -LiteralPath $r5BypassSandbox
    $r5BypassResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $r5BypassSandbox -TestRoot $script:T103UatTestRoot -TrustRecord ([pscustomobject]@{})
    $r5BypassStopOk = (@('sandboxParentIsReparsePoint', 'sandboxEntryNativeCheckFailed') -contains [string]$r5BypassResult.stopCode)
    $r5BypassOk = ($r5BypassTestPath -eq $false) -and
        ($r5BypassResult.safe -eq $false) -and
        ($r5BypassResult.recursiveDeletePerformed -eq $false) -and
        $r5BypassStopOk -and
        (Get-T103EntryNativeState -Path $r5BypassLink -Label '第五轮悬空 Junction 父目录').exists
    Add-UatPathCheck -Name 'f2.entryTestPathFalseDanglingJunctionNotBypassed' -Pass $r5BypassOk -Detail ('testPath=' + [bool]$r5BypassTestPath + '; legacyBranchWouldReturnAbsent=' + [bool](-not $r5BypassTestPath) + '; fixedSafe=' + [string]$r5BypassResult.safe + '; fixedStopCode=' + [string]$r5BypassResult.stopCode + '; recursiveDelete=' + [string]$r5BypassResult.recursiveDeletePerformed + '; danglingLinkStillPresent=' + [bool](Get-T103EntryNativeState -Path $r5BypassLink -Label '第五轮悬空 Junction 父目录').exists)
    Remove-UntrackedTestLink $r5BypassLink
    Remove-TestTreeSafely $r5F2BypassRoot

    # F2-6 沙箱父目录是正常 Junction：入口不存在也不能按“不存在”处理。
    $r5F2ParentRoot = New-F2EntryCaseRoot 'parent'
    $r5ParentTarget = Join-Path $r5F2ParentRoot 'target'
    New-Item -ItemType Directory -Force -Path $r5ParentTarget | Out-Null
    $r5ParentJunction = Join-Path $r5F2ParentRoot 'parent-link'
    New-UntrackedTestJunction $r5ParentJunction $r5ParentTarget
    $r5ParentSandbox = Join-Path $r5ParentJunction 'sandbox'
    $r5ParentResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $r5ParentSandbox -TestRoot $script:T103UatTestRoot -TrustRecord ([pscustomobject]@{})
    $r5ParentOk = ($r5ParentResult.safe -eq $false) -and
        ($r5ParentResult.stopCode -eq 'sandboxParentIsReparsePoint') -and
        ($r5ParentResult.recursiveDeletePerformed -eq $false) -and
        (@(Get-ChildItem -LiteralPath $r5ParentTarget -Force).Count -eq 0) -and
        (Get-T103EntryNativeState -Path $r5ParentJunction -Label '第五轮父目录 Junction').exists
    Add-UatPathCheck -Name 'f2.entryParentReparsePointFailsClosed' -Pass $r5ParentOk -Detail ('safe=' + [string]$r5ParentResult.safe + '; stopCode=' + [string]$r5ParentResult.stopCode + '; targetEntries=' + @(Get-ChildItem -LiteralPath $r5ParentTarget -Force).Count + '; parentLinkStillPresent=' + [bool](Get-T103EntryNativeState -Path $r5ParentJunction -Label '第五轮父目录 Junction').exists)
    Remove-UntrackedTestLink $r5ParentJunction
    Remove-TestTreeSafely $r5F2ParentRoot

    # F2-7 目录身份不明：与信任记录不一致时 fail closed 并保留现场。
    $r5F2IdentityRoot = New-F2EntryCaseRoot 'identity'
    $r5IdentitySandbox = Join-Path $r5F2IdentityRoot 'sandbox'
    New-Item -ItemType Directory -Force -Path $r5IdentitySandbox | Out-Null
    Set-Content -LiteralPath (Join-Path $r5IdentitySandbox 'sentinel.txt') -Value 'round5-identity-sentinel' -Encoding UTF8
    $r5IdentityOther = Join-Path $r5F2IdentityRoot 'other'
    New-Item -ItemType Directory -Force -Path $r5IdentityOther | Out-Null
    $r5IdentityOtherRecord = Get-T103DirectoryIdentityRecord -Path $r5IdentityOther -Label '第五轮其他目录'
    $r5IdentityResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $r5IdentitySandbox -TestRoot $script:T103UatTestRoot -TrustRecord $r5IdentityOtherRecord
    $r5IdentityOk = ($r5IdentityResult.safe -eq $false) -and
        ($r5IdentityResult.stopCode -eq 'sandboxIdentityChanged') -and
        ($r5IdentityResult.recursiveDeletePerformed -eq $false) -and
        (Test-Path -LiteralPath (Join-Path $r5IdentitySandbox 'sentinel.txt'))
    Add-UatPathCheck -Name 'f2.entryIdentityUnconfirmedFailsClosed' -Pass $r5IdentityOk -Detail ('safe=' + [string]$r5IdentityResult.safe + '; stopCode=' + [string]$r5IdentityResult.stopCode + '; sandboxPreserved=' + [bool](Test-Path -LiteralPath $r5IdentitySandbox) + '; sentinelPreserved=' + [bool](Test-Path -LiteralPath (Join-Path $r5IdentitySandbox 'sentinel.txt')))
    Remove-TestTreeSafely $r5IdentitySandbox
    Remove-TestTreeSafely $r5IdentityOther
    Remove-TestTreeSafely $r5F2IdentityRoot

    # F2-8 原生路径检查失败（路径组件是文件）：fail closed。
    $r5F2BadRoot = New-F2EntryCaseRoot 'nativefail'
    $r5BadComponent = Join-Path $r5F2BadRoot 'not-a-directory.txt'
    Set-Content -LiteralPath $r5BadComponent -Value 'ROUND5-F2-FILE-COMPONENT' -Encoding UTF8
    $r5BadResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath (Join-Path $r5BadComponent 'sandbox') -TestRoot $script:T103UatTestRoot -TrustRecord ([pscustomobject]@{})
    $r5BadOk = ($r5BadResult.safe -eq $false) -and
        ($r5BadResult.stopCode -eq 'sandboxEntryNativeCheckFailed') -and
        ($r5BadResult.recursiveDeletePerformed -eq $false)
    Add-UatPathCheck -Name 'f2.entryNativeCheckFailureFailsClosed' -Pass $r5BadOk -Detail ('safe=' + [string]$r5BadResult.safe + '; stopCode=' + [string]$r5BadResult.stopCode + '; reason=' + (Format-EvidencePath ([string]$r5BadResult.stopReason)))
    Remove-TestTreeSafely $r5F2BadRoot

    # F2-9 失败用例之后：外部 Canary 与业务数据库不变。
    $r5CanaryHashAfterF2 = (Get-FileHash -LiteralPath $r5CanaryFile -Algorithm SHA256).Hash
    $r5BusinessHashAfterF2 = (Get-FileHash -LiteralPath $r5BusinessFile -Algorithm SHA256).Hash
    $r5F2CanariesOk = ($r5CanaryHashAfterF2 -eq $r5CanaryHashBefore) -and ($r5BusinessHashAfterF2 -eq $r5BusinessHashBefore)
    Add-UatPathCheck -Name 'f2.canariesUnchangedAfterFailureCases' -Pass $r5F2CanariesOk -Detail ('guardianCanaryUnchanged=' + [bool]($r5CanaryHashAfterF2 -eq $r5CanaryHashBefore) + '; businessDbUnchanged=' + [bool]($r5BusinessHashAfterF2 -eq $r5BusinessHashBefore))

    $r5FailureResults = @($r5EntryJunctionResult, $r5EntryDanglingResult, $r5BypassResult, $r5ParentResult, $r5IdentityResult, $r5BadResult)
    $script:Round5F1Summary = [ordered]@{
        evidenceRootInjected    = (Format-EvidencePath $r5EvidenceRoot)
        normalWriteSucceeded    = [bool]($r5OkContent -eq '{"round5":"ok"}')
        businessDbHashUnchanged = [bool]($r5BusinessHashAfter -eq $r5BusinessHashBefore)
        guardianCanaryUnchanged = [bool]($r5CanaryHashAfter -eq $r5CanaryHashBefore)
        junctionTargetUnchanged = [bool]($r5JunctionCanaryHashAfter -eq $r5JunctionHashBefore)
        identitySwapTested      = [bool]$r5SwapOk
        defaultRootTrusted      = [bool]$r5DefaultOk
    }
    $script:Round5F2Summary = [ordered]@{
        trulyAbsentStopCode         = [string]$r5AbsentResult.stopCode
        normalRecursiveDelete       = [string]$r5NormalResult.recursiveDeletePerformed
        normalJunctionStopCode      = [string]$r5EntryJunctionResult.stopCode
        danglingJunctionStopCode    = [string]$r5EntryDanglingResult.stopCode
        testPathFalseBypassStopCode = [string]$r5BypassResult.stopCode
        parentReparseStopCode       = [string]$r5ParentResult.stopCode
        identityStopCode            = [string]$r5IdentityResult.stopCode
        nativeFailureStopCode       = [string]$r5BadResult.stopCode
        noRecursiveDeleteInFailures = [bool]((@($r5FailureResults | Where-Object { $_.recursiveDeletePerformed -eq $true }).Count -eq 0))
        canariesUnchanged           = [bool]$r5F2CanariesOk
    }

    $script:F2Summary = $f2CaseSummary
}
finally {
    # 第四轮 F2：fail-closed 清理（不再无条件递归删除）。
    # 清理前复验沙箱身份、逐个删除并复验跟踪链接、扫描未预期重解析点、再次复验身份；
    # 任一条件不满足立即停止，保留沙箱与外部目标目录，输出可定位 WARN/FAIL。
    if ($null -eq $script:SandboxTrustRecord) {
        $script:CleanupResult = [pscustomobject]@{
            safe                     = $false
            recursiveDeletePerformed = $false
            stopCode                 = 'missingSandboxTrustRecord'
            stopReason               = '未记录测试沙箱身份，拒绝执行递归清理。'
            unsafePaths              = @($sandbox)
            steps                    = @()
            sandboxPath              = $sandbox
        }
    }
    else {
        try {
            $script:CleanupResult = Invoke-T103SandboxCleanupEntrypoint -SandboxPath $sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $script:SandboxTrustRecord -TrackedLinks @($script:Links)
        }
        catch {
            $script:CleanupResult = [pscustomobject]@{
                safe                     = $false
                recursiveDeletePerformed = $false
                stopCode                 = 'cleanupThrewUnexpectedly'
                stopReason               = $_.Exception.Message
                unsafePaths              = @($sandbox)
                steps                    = @()
                sandboxPath              = $sandbox
            }
        }
    }
    if ($script:CleanupResult.safe) {
        Add-UatPathCheck -Name 'cleanup.sandboxRemovedSafely' -Pass $true -Detail ('steps=' + @($script:CleanupResult.steps).Count + '; recursiveDeletePerformed=' + [string]$script:CleanupResult.recursiveDeletePerformed)
    }
    else {
        Add-UatPathCheck -Name 'cleanup.sandboxRemovedSafely' -Pass $false -Detail ('stopCode=' + [string]$script:CleanupResult.stopCode + '; reason=' + [string]$script:CleanupResult.stopReason + '; sandboxPreserved=' + [bool](Test-Path -LiteralPath $sandbox))
        Write-Host ('WARN 清理未完成：已按 fail-closed 停止整个沙箱递归删除，保留现场供人工处理：' + (Format-EvidencePath $sandbox))
        Write-Host ('FAIL cleanup.sandboxRemovedSafely — stopCode=' + [string]$script:CleanupResult.stopCode + '; ' + (Format-EvidencePath ([string]$script:CleanupResult.stopReason)))
        foreach ($unsafePath in @($script:CleanupResult.unsafePaths)) {
            Write-Host ('WARN unsafePath=' + (Format-EvidencePath ([string]$unsafePath)))
        }
    }
}

# ---------------------------------------------------------------------------
# 9. 证据自检（在所有检查与清理完成之后执行，包含清理安全检查）
# ---------------------------------------------------------------------------
$checkNames = @($script:Checks | ForEach-Object { $_.name })
$missingOriginal = @($script:OriginalCheckNames | Where-Object { $checkNames -notcontains $_ })
Add-UatPathCheck -Name 'evidence.original23ChecksPreserved' -Pass ($missingOriginal.Count -eq 0) -Detail ('originalExpected=23; missing=' + $missingOriginal.Count)

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

$checkNames = @($script:Checks | ForEach-Object { $_.name })
# evidence.passState 是本段最后添加的自引用检查，比较时排除；其余第三轮 59 项必须全部存在。
$missingRound3 = @($script:Round3CheckNames | Where-Object { $_ -ne 'evidence.passState' -and $checkNames -notcontains $_ })
Add-UatPathCheck -Name 'evidence.round3ChecksPreserved' -Pass ($missingRound3.Count -eq 0) -Detail ('round3Expected=' + @($script:Round3CheckNames).Count + '; missing=' + $missingRound3.Count + '; selfReferentialExcluded=evidence.passState')
$missingRound4 = @($script:Round4ExpectedNewCheckNames | Where-Object { $checkNames -notcontains $_ })
Add-UatPathCheck -Name 'evidence.round4NewChecksPresent' -Pass ($missingRound4.Count -eq 0) -Detail ('round4Expected=' + @($script:Round4ExpectedNewCheckNames).Count + '; missing=' + $missingRound4.Count + '; missingNames=' + ($missingRound4 -join ','))

# 第五轮新增检查必须全部存在（SKIP 记入 Skipped，仍视为“已执行到”而不是缺失）。
$round5NamesPresent = @($script:Checks | ForEach-Object { $_.name }) + @($script:Skipped | ForEach-Object { $_.name })
$missingRound5 = @($script:Round5ExpectedNewCheckNames | Where-Object { $round5NamesPresent -notcontains $_ })
$round5Skipped = @($script:Skipped | Where-Object { $script:Round5ExpectedNewCheckNames -contains $_.name })
Add-UatPathCheck -Name 'evidence.round5NewChecksPresent' -Pass ($missingRound5.Count -eq 0) -Detail ('round5Expected=' + @($script:Round5ExpectedNewCheckNames).Count + '; missing=' + $missingRound5.Count + '; skippedButPresent=' + $round5Skipped.Count + '; missingNames=' + ($missingRound5 -join ','))

$evidencePass = (@($script:Checks | Where-Object { -not $_.pass }).Count -eq 0)
Add-UatPathCheck -Name 'evidence.passState' -Pass $evidencePass -Detail ('failed=' + (@($script:Checks | Where-Object { -not $_.pass }).Count))

$failed = @($script:Checks | Where-Object { -not $_.pass })
$cleanupForEvidence = [ordered]@{
    safe                     = [bool]$script:CleanupResult.safe
    recursiveDeletePerformed = [bool]$script:CleanupResult.recursiveDeletePerformed
    stopCode                 = [string]$script:CleanupResult.stopCode
    stopReason               = (Format-EvidencePath ([string]$script:CleanupResult.stopReason))
    unsafePathCount          = @($script:CleanupResult.unsafePaths).Count
    stepsCount               = @($script:CleanupResult.steps).Count
}
$evidence = [ordered]@{
    task                = 'T1-03'
    fix                 = 'P3-02 + round-4 F1/F2 UAT path safety (test-root trust anchor + fail-closed sandbox cleanup) + round-5 F1/F2 (evidence write boundary + sandbox entry native check)'
    generatedAt         = (Get-Date).ToUniversalTime().ToString('o')
    command             = 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1'
    environment         = [ordered]@{
        os              = [System.Environment]::OSVersion.VersionString
        powershell      = $PSVersionTable.PSVersion.ToString()
        isAdmin         = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        symlinkCreation = [bool]$symlinkAttempt.Created
        testRoot        = (Format-EvidencePath $defaultTestRoot)
        testRootOverrideActive = [bool]$testRootOverrideActive
        sandbox         = (Format-EvidencePath $sandbox)
    }
    pathCheckMethod     = 'CreateFileW + GetFileInformationByHandleEx(FileAttributeTagInfo/FileIdInfo) + GetFinalPathNameByHandleW'
    trustAnchor         = [ordered]@{
        verified              = [bool]($null -ne $trustRecord)
        path                  = (Format-EvidencePath ([string]$trustRecord.path))
        finalPathMatchesPath  = [bool](Test-T103FinalPathEquals ([string]$trustRecord.finalPath) ([string]$trustRecord.path))
        existingComponents    = [int]$trustRecord.existingComponentCount
        volumeSerialRecorded  = [bool](-not [string]::IsNullOrWhiteSpace([string]$trustRecord.volumeSerialNumber))
        fileIdRecorded        = [bool](-not [string]::IsNullOrWhiteSpace([string]$trustRecord.fileIdHex))
        fileIdLength          = [int]([string]$trustRecord.fileIdHex).Length
        sandboxIdentityVerified = [bool]($null -ne $script:SandboxTrustRecord)
    }
    cleanup             = $cleanupForEvidence
    faultInjection      = [ordered]@{
        f1 = $script:F1Summary
        f2 = $script:F2Summary
    }
    round5              = [ordered]@{
        fix                   = 'F1 evidence write boundary (native final path/identity/hardlink) + F2 sandbox entry native check (no Test-Path bypass)'
        f1                    = $script:Round5F1Summary
        f2                    = $script:Round5F2Summary
        expectedNewCheckCount = @($script:Round5ExpectedNewCheckNames).Count
    }
    round5NewCheckTarget = @($script:Round5ExpectedNewCheckNames).Count
    round3CheckCountPreserved = @($script:Round3CheckNames).Count
    round4NewCheckTarget      = @($script:Round4ExpectedNewCheckNames).Count
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
[void](Write-T103EvidenceFile -Path $EvidencePath -Content $evidenceJson -ExpectedRootIdentity $script:EvidenceRootIdentity)
Write-Host ("UAT_PATH_EVIDENCE=" + $EvidencePath)
Write-Host ("UAT_PATH_CHECK_TOTAL=" + $evidence.checkCount + " ORIGINAL=" + $evidence.originalCheckCount + " ROUND3_PRESERVED=" + $evidence.round3CheckCountPreserved + " ROUND4_NEW_TARGET=" + $evidence.round4NewCheckTarget + " SKIPPED=" + $evidence.skipCount + " FAILED=" + $failed.Count)
Write-Host ("UAT_PATH_TRUST_ANCHOR=" + $(if ([bool]$evidence.trustAnchor.verified) { 'PASS' } else { 'FAIL' }) + " CLEANUP_SAFE=" + [string]$evidence.cleanup.safe + " CLEANUP_STOP_CODE=" + [string]$evidence.cleanup.stopCode)
Write-Host ('T1_03_UAT_PATH_SECURITY=PASS')
exit 0
