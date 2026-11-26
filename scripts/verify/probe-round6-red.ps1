# WorkManager T1-03 第六轮定向补正 — Red 证据探针（修复前基线忠实复现）
#
# 目的：以修复前基线提交 e8205cae22e98afce6480f5a5a0695543a61dee3 的真实脚本与
# 真实 Windows 文件系统对象，复现第六轮审计发现的问题，不得使用修复后的函数冒充修复前实现。
#
# 做法：
# 1. 用 `git archive <baseline>` 把基线提交的完整文件树解压到专用测试根目录下的临时目录，
#    并用 git blob SHA 校验解压出的 T1-03UatPath.ps1 / test-t1-03-uat-path.ps1 与基线一致；
# 2. F1（修复前）：用基线 test-t1-03-uat-path.ps1 以真实脚本入口把证据写到“仓库证据目录之外”
#    的守卫 Canary 文件上；基线实现没有写入边界，因此会创建越界证据并覆盖 Canary；
# 3. F2（修复前）：在基线 T1-03UatPath.ps1 上构造 sandbox\evil(Junction)->external、
#    external\victim-link(Junction)->victim-target，并把 sandbox\evil\victim-link 作为
#    TrackedLinks 传入；基线实现先删链接后扫描，会穿过未跟踪 Junction 删除外部链接；
# 4. P4（修复前）：在真实文件系统上制造递归删除中途失败（第 2 个条目被独占句柄锁定），
#    记录基线结果把已发生的部分删除报告为 recursiveDeletePerformed=false 且无“已开始”信息。
#
# 只使用虚构文件、Canary 和专用测试目录；不修改 Windows ACL；不读取真实工作数据。
# 输出：机器可读 JSON（默认 docs/testing/reports/T1-03-assets/evidence/round6-remediation/red/
# round6-red-evidence.json）+ 脱敏后的原始命令输出（同目录 .log.txt）。
# 退出码：0 = 三项修复前行为均按预期复现；1 = 复现不成立或环境不满足；2 = 前置条件失败。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\probe-round6-red.ps1

[CmdletBinding()]
param(
    [string]$BaselineCommit = 'e8205cae22e98afce6480f5a5a0695543a61dee3',
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$uatRoot = 'D:\WorkManager-test-data'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$caseRoot = Join-Path $uatRoot ('round6-red-' + $stamp + '-' + $PID)
$extractRoot = Join-Path $caseRoot 'baseline-e8205ca'
$redEvidenceDir = Join-Path $repoRoot 'docs/testing/reports/T1-03-assets/evidence/round6-remediation/red'
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $redEvidenceDir 'round6-red-evidence.json'
}
$sanitizedLogPath = Join-Path $redEvidenceDir 'round6-red-command-output.sanitized.log.txt'

function Invoke-Native([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = '') {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $output = & $FilePath @Arguments 2>&1
        }
        else {
            $output = & $FilePath @Arguments 2>&1
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-MklinkJunction([string]$Link, [string]$Target) {
    $result = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/d', '/c', ('mklink /J "' + $Link + '" "' + $Target + '"'))
    if ($result.ExitCode -ne 0) {
        throw ('创建 Junction 失败（exit={0}）：{1} -> {2}；输出：{3}' -f $result.ExitCode, $Link, $Target, $result.Output)
    }
}

function Get-LinkState([string]$Link) {
    try {
        $info = Get-T103NativePathInfo -Path $Link -OpenReparsePoint $true
        return [pscustomobject]@{ Exists = [bool]$info.Exists; IsReparsePoint = [bool]$info.IsReparsePoint; ReparseTag = ('0x{0:X8}' -f $info.ReparseTag) }
    }
    catch {
        return [pscustomobject]@{ Exists = $false; IsReparsePoint = $false; ReparseTag = '' }
    }
}

function Remove-LinkOnly([string]$Link) {
    $state = Get-LinkState $Link
    if (-not $state.Exists) { return }
    if (-not $state.IsReparsePoint) {
        throw ('拒绝删除非重解析点路径（fail closed）：' + $Link)
    }
    [System.IO.Directory]::Delete($Link, $false)
    if ((Get-LinkState $Link).Exists) {
        throw ('链接删除后仍然存在：' + $Link)
    }
}

function Remove-PlainTree([string]$Path) {
    try {
        $info = Get-T103NativePathInfo -Path $Path -OpenReparsePoint $true
        if (-not $info.Exists) { return }
        if ($info.IsReparsePoint) { throw ('拒绝递归删除重解析点：' + $Path) }
        Remove-T103VerifiedDirectoryTree -Directory $Path -StopPrefix 'Red 探针自清理'
    }
    catch {
        Write-Host ('WARN 自清理失败（保留现场供人工处理）：' + $Path + '；原因：' + $_.Exception.Message)
    }
}

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# 脱敏：固定测试根统一 <uat-root>；仓库根 <repo-root>；临时解压目录 <baseline-extract>；
# 其余盘符绝对路径 <drive-root>；机器名/用户目录/用户名继续严格替换。
function Format-RedText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = [string]$Text
    $result = $result.Replace($caseRoot, '<red-case-root>')
    $result = $result.Replace($extractRoot, '<baseline-extract>')
    $result = $result.Replace($repoRoot, '<repo-root>')
    $result = $result.Replace($uatRoot, '<uat-root>')
    # 固定测试根路径统一 <uat-root>（含基线脚本输出中的大小写变体/相对占位形式）。
    $result = [regex]::Replace($result, '(?i)(?<![A-Za-z0-9_<>])[A-Za-z]:\\WorkManager-test-data', '<uat-root>')
    $result = [regex]::Replace($result, '(?i)<drive-root>\\WorkManager-test-data', '<uat-root>')
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $result = $result.Replace($env:USERPROFILE, '<user-profile>')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $env:COMPUTERNAME.Length -ge 4) {
        $result = $result.Replace($env:COMPUTERNAME, '<computer-name>')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and $env:USERNAME.Length -ge 4) {
        $result = [regex]::Replace($result, ('\b' + [regex]::Escape($env:USERNAME) + '\b'), '<user>')
    }
    $result = [regex]::Replace($result, '(?<![A-Za-z0-9_<>])[A-Za-z]:\\', '<drive-root>\')
    return $result
}

function Assert-RedSanitized([string]$Text, [string]$Label) {
    $patterns = @()
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $env:COMPUTERNAME.Length -ge 4) { $patterns += [regex]::Escape($env:COMPUTERNAME) }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $patterns += [regex]::Escape($env:USERPROFILE) }
    $patterns += [regex]::Escape($repoRoot)
    $patterns += [regex]::Escape($uatRoot)
    $patterns += '(?i)WorkManager-test-data'
    $patterns += 'C:\\Users\\'
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) {
            $match = [regex]::Match($Text, $pattern)
            $start = [Math]::Max(0, $match.Index - 80)
            $length = [Math]::Min(240, $Text.Length - $start)
            throw ('Red 探针输出脱敏自检失败（{0}）：命中模式 {1}；上下文：{2}' -f $Label, $pattern, $Text.Substring($start, $length))
        }
    }
}

$redLog = New-Object System.Collections.ArrayList
function Add-RedLog([string]$Line) {
    [void]$redLog.Add((Format-RedText $Line))
    Write-Host $Line
}

$result = [ordered]@{
    task                 = 'T1-03'
    round                = 6
    kind                 = 'red-baseline-behavior-probe'
    note                 = '使用修复前基线提交的真实脚本与真实 Windows 文件系统对象复现问题；未使用修复后的函数冒充修复前实现。'
    baselineCommit       = ''
    baselineCommitDate   = ''
    baselinePathScriptBlobSha = ''
    extractedPathScriptBlobSha = ''
    currentHead          = ''
    branch               = ''
    workingTreeDirty     = $false
    command              = 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\probe-round6-red.ps1'
    generatedAt          = (Get-Date).ToUniversalTime().ToString('o')
    environment          = [ordered]@{
        os             = [System.Environment]::OSVersion.VersionString
        powershell     = $PSVersionTable.PSVersion.ToString()
        isAdmin        = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        testRoot       = '<uat-root>'
        caseRoot       = ''
        baselineExtract = '<baseline-extract>'
    }
    f1OldEvidenceWrite  = [ordered]@{}
    f2OldTrackedLinkDelete = [ordered]@{}
    p4OldPartialDelete  = [ordered]@{}
    redConfirmed        = $false
    sanitizedLog        = 'docs/testing/reports/T1-03-assets/evidence/round6-remediation/red/round6-red-command-output.sanitized.log.txt'
}

$f1Confirmed = $false
$f2Confirmed = $false
$p4Confirmed = $false
$f1Facts = [ordered]@{}
$f2Facts = [ordered]@{}
$p4Facts = [ordered]@{}
$oldPathScriptLoaded = $false
$f2Stream = $null
$p4LockStream = $null

try {
    # -----------------------------------------------------------------------
    # 0. 前置条件：基线提交可解析；专用测试根目录存在；git / tar / cmd 可用。
    # -----------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $uatRoot -PathType Container)) {
        Write-Host ('PRECONDITION_FAILED: 专用测试根目录不存在：' + $uatRoot)
        exit 2
    }
    $baselineSha = (Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'rev-parse', ($BaselineCommit + '^{commit}'))).Output.Trim()
    if ($baselineSha -ne $BaselineCommit) {
        Write-Host ('PRECONDITION_FAILED: 基线提交无法解析为精确 SHA：{0} -> {1}' -f $BaselineCommit, $baselineSha)
        exit 2
    }
    $baselineDate = (Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'log', '-1', '--format=%cI', $BaselineCommit)).Output.Trim()
    $currentHead = (Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'rev-parse', 'HEAD')).Output.Trim()
    $currentBranch = (Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')).Output.Trim()
    $dirty = ((Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'status', '--porcelain')).Output.Trim().Length -gt 0)
    $result.baselineCommit = $BaselineCommit
    $result.baselineCommitDate = $baselineDate
    $result.currentHead = $currentHead
    $result.branch = $currentBranch
    $result.workingTreeDirty = $dirty

    New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $redEvidenceDir | Out-Null
    $result.environment.caseRoot = (Format-RedText $caseRoot)
    Add-RedLog ('=== 第六轮 Red 探针：基线 ' + $BaselineCommit + '（' + $baselineDate + '），当前 HEAD ' + $currentHead + ' ===')

    $tarPath = Join-Path $caseRoot 'baseline.tar'
    $archiveResult = Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'archive', '--format=tar', ('--output=' + $tarPath), $BaselineCommit)
    if ($archiveResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tarPath -PathType Leaf)) {
        throw ('git archive 基线提交失败（exit={0}）：{1}' -f $archiveResult.ExitCode, $archiveResult.Output)
    }
    $tarResult = Invoke-Native -FilePath 'tar.exe' -Arguments @('-xf', $tarPath, '-C', $extractRoot)
    if ($tarResult.ExitCode -ne 0) {
        throw ('解压基线归档失败（exit={0}）：{1}' -f $tarResult.ExitCode, $tarResult.Output)
    }
    $extractedPathScript = Join-Path $extractRoot 'scripts\verify\T1-03UatPath.ps1'
    $extractedTestScript = Join-Path $extractRoot 'scripts\verify\test-t1-03-uat-path.ps1'
    foreach ($required in @($extractedPathScript, $extractedTestScript, (Join-Path $extractRoot 'scripts\verify\verify-t1-03-ui.ps1'))) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw ('基线归档缺少必需文件：' + $required)
        }
    }
    $baselineBlob = (Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'rev-parse', ($BaselineCommit + ':scripts/verify/T1-03UatPath.ps1'))).Output.Trim()
    $extractedBlob = (Invoke-Native -FilePath 'git.exe' -Arguments @('-C', $repoRoot, 'hash-object', $extractedPathScript)).Output.Trim()
    if ($baselineBlob -ne $extractedBlob) {
        throw ('解压出的基线脚本与 git 对象不一致：git={0}，解压={1}' -f $baselineBlob, $extractedBlob)
    }
    $result.baselinePathScriptBlobSha = $baselineBlob
    $result.extractedPathScriptBlobSha = $extractedBlob
    Add-RedLog ('BASELINE_PATHS_SCRIPT_BLOB=' + $baselineBlob + ' (extracted matches git object)')

    # -----------------------------------------------------------------------
    # F1（修复前）：基线脚本入口把证据写到一个“仓库证据目录之外”的守卫 Canary 文件。
    # -----------------------------------------------------------------------
    Add-RedLog '--- F1-RED: 基线脚本入口以 -EvidencePath 越界写入并覆盖守卫 Canary ---'
    $f1OutsideDir = Join-Path $caseRoot 'outside-evidence'
    New-Item -ItemType Directory -Force -Path $f1OutsideDir | Out-Null
    $f1CanaryPath = Join-Path $f1OutsideDir 'guardian-business-canary.json'
    Set-Content -LiteralPath $f1CanaryPath -Value '{"sentinel":"ROUND6-RED-BUSINESS-CANARY-MUST-NOT-CHANGE"}' -Encoding UTF8
    $f1CanaryHashBefore = Get-Sha256 $f1CanaryPath
    # 基线测试脚本要求仓库相对路径下存在 Release EXE（仅前置条件；产品代码未修改）。
    $releaseExe = Join-Path $repoRoot 'target\release\workmanager.exe'
    if (-not (Test-Path -LiteralPath $releaseExe -PathType Leaf)) {
        throw ('缺少 Release EXE 前置条件（集成用例需要）：' + $releaseExe)
    }
    $extractExeDir = Join-Path $extractRoot 'target\release'
    New-Item -ItemType Directory -Force -Path $extractExeDir | Out-Null
    Copy-Item -LiteralPath $releaseExe -Destination (Join-Path $extractExeDir 'workmanager.exe') -Force
    $oldSuiteStart = Get-Date
    $oldSuiteResult = Invoke-Native -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $extractedTestScript, '-EvidencePath', $f1CanaryPath)
    $oldSuiteElapsed = ((Get-Date) - $oldSuiteStart).TotalSeconds
    $f1CanaryExistsAfter = Test-Path -LiteralPath $f1CanaryPath -PathType Leaf
    $f1CanaryHashAfter = Get-Sha256 $f1CanaryPath
    $f1CanaryJson = $null
    if ($f1CanaryExistsAfter) {
        try { $f1CanaryJson = (Get-Content -LiteralPath $f1CanaryPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $f1CanaryJson = $null }
    }
    $f1EvidenceOutsideRepoEvidenceRoot = -not ($f1CanaryPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase))
    $f1EscapedEvidenceWritten = $false
    if ($f1CanaryExistsAfter -and ($f1CanaryHashAfter -ne $f1CanaryHashBefore) -and $null -ne $f1CanaryJson -and [string]$f1CanaryJson.task -eq 'T1-03') {
        $f1EscapedEvidenceWritten = $true
    }
    $f1CanaryOverwritten = ($f1CanaryExistsAfter -and $f1CanaryHashAfter -ne $f1CanaryHashBefore)
    $f1Facts = [ordered]@{
        oldSuiteExitCode            = $oldSuiteResult.ExitCode
        oldSuiteElapsedSeconds      = [math]::Round($oldSuiteElapsed, 2)
        evidencePathArgument        = (Format-RedText $f1CanaryPath)
        evidenceWrittenOutsideRepoEvidenceRoot = [bool]($f1EscapedEvidenceWritten -and $f1EvidenceOutsideRepoEvidenceRoot)
        guardCanaryOverwritten      = [bool]$f1CanaryOverwritten
        guardCanarySha256Before     = $f1CanaryHashBefore
        guardCanarySha256After      = $f1CanaryHashAfter
        escapedEvidenceFileSize     = $(if ($f1CanaryExistsAfter) { (Get-Item -LiteralPath $f1CanaryPath).Length } else { 0 })
        escapedEvidenceTask         = $(if ($null -ne $f1CanaryJson) { [string]$f1CanaryJson.task } else { '' })
        oldSuiteOutputExcerpt = @(
            (Format-RedText (($oldSuiteResult.Output -split "`r?`n") | Where-Object { $_ -match 'T1_03_UAT_PATH_SECURITY|UAT_PATH_CHECK_TOTAL|TRUST_ANCHOR' } | Select-Object -First 4) -join "`n")
        )
    }
    $f1Confirmed = $f1EscapedEvidenceWritten -and $f1CanaryOverwritten
    Add-RedLog ('F1_RED_CONFIRMED=' + [bool]$f1Confirmed + ' oldSuiteExit=' + $oldSuiteResult.ExitCode + ' escapedEvidence=' + [bool]$f1EscapedEvidenceWritten + ' canaryOverwritten=' + [bool]$f1CanaryOverwritten)
    Add-RedLog ($oldSuiteResult.Output)
    # 记录 F1 原始命令输出（脱敏后写入汇总日志；见文件末尾统一写出）。
    $f1RawOutput = 'COMMAND: powershell -NoProfile -ExecutionPolicy Bypass -File <baseline-extract>\scripts\verify\test-t1-03-uat-path.ps1 -EvidencePath <red-case-root>\outside-evidence\guardian-business-canary.json' + "`r`n`r`n" + $oldSuiteResult.Output

    # -----------------------------------------------------------------------
    # F2（修复前）：加载基线 T1-03UatPath.ps1（git blob 已校验），在真实文件系统上复现
    # “先删跟踪链接、后扫描未跟踪 Junction”导致的外部链接删除。
    # -----------------------------------------------------------------------
    Add-RedLog '--- F2-RED: 基线清理函数穿过未跟踪 Junction 删除外部跟踪链接 ---'
    . $extractedPathScript
    $oldPathScriptLoaded = $true
    $f2Case = Join-Path $caseRoot 'f2'
    $f2External = Join-Path $f2Case 'external'
    $f2VictimTarget = Join-Path $f2External 'victim-target'
    $f2Sandbox = Join-Path $f2Case 'sandbox'
    New-Item -ItemType Directory -Force -Path $f2VictimTarget | Out-Null
    New-Item -ItemType Directory -Force -Path $f2Sandbox | Out-Null
    $f2VictimCanary = Join-Path $f2VictimTarget 'victim-canary.txt'
    Set-Content -LiteralPath $f2VictimCanary -Value 'ROUND6-RED-VICTIM-CANARY' -Encoding UTF8
    $f2VictimCanaryHashBefore = Get-Sha256 $f2VictimCanary
    Set-Content -LiteralPath (Join-Path $f2Sandbox 'sentinel.txt') -Value 'round6-red-f2-sentinel' -Encoding UTF8
    $f2Evil = Join-Path $f2Sandbox 'evil'
    Invoke-MklinkJunction $f2Evil $f2External
    $f2VictimLink = Join-Path $f2Evil 'victim-link'
    Invoke-MklinkJunction $f2VictimLink $f2VictimTarget
    $f2VictimLinkBefore = Get-LinkState $f2VictimLink
    $f2Trust = Get-T103DirectoryIdentityRecord -Path $f2Sandbox -Label 'Red F2 沙箱'
    Add-RedLog ('F2_BEFORE victimLinkExists=' + [bool]$f2VictimLinkBefore.Exists + ' victimLinkIsReparse=' + [bool]$f2VictimLinkBefore.IsReparsePoint + ' tag=' + $f2VictimLinkBefore.ReparseTag)
    $f2OldResult = Invoke-T103FailClosedSandboxCleanup -SandboxPath $f2Sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $f2Trust -TrackedLinks @($f2VictimLink)
    $f2VictimLinkAfter = Get-LinkState $f2VictimLink
    $f2VictimCanaryHashAfter = Get-Sha256 $f2VictimCanary
    $f2EvilAfter = Get-LinkState $f2Evil
    $f2SandboxAfter = Test-Path -LiteralPath $f2Sandbox
    $f2Facts = [ordered]@{
        sandboxPath                     = (Format-RedText $f2Sandbox)
        trackedLinkArgument             = (Format-RedText $f2VictimLink)
        victimLinkExistedBefore         = [bool]$f2VictimLinkBefore.Exists
        victimLinkDeletedByOldCleanup   = [bool]($f2VictimLinkBefore.Exists -and (-not $f2VictimLinkAfter.Exists))
        oldResultSafe                   = [bool]$f2OldResult.safe
        oldResultStopCode               = [string]$f2OldResult.stopCode
        oldResultRecursiveDeletePerformed = [bool]$f2OldResult.recursiveDeletePerformed
        oldResultStopReason             = (Format-RedText ([string]$f2OldResult.stopReason))
        oldResultSteps                  = @($f2OldResult.steps)
        victimTargetCanaryContent       = $(if (Test-Path -LiteralPath $f2VictimCanary -PathType Leaf) { (Get-Content -LiteralPath $f2VictimCanary -Raw -Encoding UTF8).Trim() } else { '' })
        victimTargetCanarySha256Before  = $f2VictimCanaryHashBefore
        victimTargetCanarySha256After   = $f2VictimCanaryHashAfter
        sandboxPreservedByOldCleanup    = [bool]$f2SandboxAfter
        untrackedEvilJunctionPreserved  = [bool]$f2EvilAfter.Exists
    }
    $f2Confirmed = $f2Facts.victimLinkExistedBefore -and $f2Facts.victimLinkDeletedByOldCleanup -and (-not $f2Facts.oldResultSafe)
    Add-RedLog ('F2_RED_CONFIRMED=' + [bool]$f2Confirmed + ' victimLinkDeleted=' + [bool]$f2Facts.victimLinkDeletedByOldCleanup + ' oldStopCode=' + $f2Facts.oldResultStopCode + ' canaryUnchanged=' + [bool]($f2VictimCanaryHashBefore -eq $f2VictimCanaryHashAfter))
    Remove-LinkOnly $f2VictimLink
    Remove-LinkOnly $f2Evil
    Remove-PlainTree $f2Case

    # -----------------------------------------------------------------------
    # P4（修复前）：真实递归删除中途失败（被独占打开的文件）。基线 catch 把已发生的
    # 部分删除报告为 recursiveDeletePerformed=false，且没有“已开始/未完成”语义。
    # 目录项按名称排序（NTFS 索引顺序）：0001..0006 先被删除，zz-subdir 中的锁定文件失败。
    # -----------------------------------------------------------------------
    Add-RedLog '--- P4-RED: 基线递归删除中途真实失败后的结果语义 ---'
    $p4Case = Join-Path $caseRoot 'p4'
    $p4Sandbox = Join-Path $p4Case 'sandbox'
    $p4Sub = Join-Path $p4Sandbox 'zz-subdir'
    New-Item -ItemType Directory -Force -Path $p4Sub | Out-Null
    foreach ($index in 1..6) {
        Set-Content -LiteralPath (Join-Path $p4Sandbox ('{0:D4}-file.txt' -f $index)) -Value ('round6-red-p4-' + $index) -Encoding UTF8
    }
    $p4Locked = Join-Path $p4Sub 'locked.txt'
    Set-Content -LiteralPath $p4Locked -Value 'ROUND6-RED-LOCKED-FILE' -Encoding UTF8
    $p4EntriesBefore = @(Get-ChildItem -LiteralPath $p4Sandbox -Force).Count
    $p4Trust = Get-T103DirectoryIdentityRecord -Path $p4Sandbox -Label 'Red P4 沙箱'
    $p4LockStream = [System.IO.File]::Open($p4Locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    $p4OldResult = Invoke-T103FailClosedSandboxCleanup -SandboxPath $p4Sandbox -TestRoot $script:T103UatTestRoot -TrustRecord $p4Trust -TrackedLinks @()
    $p4EntriesAfter = @(Get-ChildItem -LiteralPath $p4Sandbox -Force).Count
    $p4PartialObserved = ($p4EntriesAfter -lt $p4EntriesBefore)
    $p4HasStartedField = $null -ne $p4OldResult.PSObject.Properties['recursiveDeleteStarted']
    $p4Facts = [ordered]@{
        sandboxPath                          = (Format-RedText $p4Sandbox)
        failureInjection                     = 'real sharing violation: a file inside the sandbox subdirectory is opened with FileShare.None'
        entriesBefore                        = $p4EntriesBefore
        entriesAfter                         = $p4EntriesAfter
        partialDeletionObserved              = [bool]$p4PartialObserved
        oldResultSafe                        = [bool]$p4OldResult.safe
        oldResultStopCode                    = [string]$p4OldResult.stopCode
        oldResultRecursiveDeletePerformed    = [bool]$p4OldResult.recursiveDeletePerformed
        oldResultHasRecursiveDeleteStartedField = [bool]$p4HasStartedField
        oldResultStopReason                  = (Format-RedText ([string]$p4OldResult.stopReason))
    }
    $p4Confirmed = $p4PartialObserved -and (-not $p4Facts.oldResultSafe) -and (-not $p4Facts.oldResultRecursiveDeletePerformed) -and (-not $p4HasStartedField)
    Add-RedLog ('P4_RED_CONFIRMED=' + [bool]$p4Confirmed + ' entriesBefore=' + $p4EntriesBefore + ' entriesAfter=' + $p4EntriesAfter + ' oldPerformed=' + [bool]$p4Facts.oldResultRecursiveDeletePerformed + ' oldStopCode=' + $p4Facts.oldResultStopCode + ' hasStartedField=' + [bool]$p4HasStartedField)
    $p4LockStream.Dispose()
    $p4LockStream = $null
    Remove-PlainTree $p4Case

    # -----------------------------------------------------------------------
    # 汇总并写出机器可读证据 + 脱敏原始命令输出。
    # -----------------------------------------------------------------------
    $result.f1OldEvidenceWrite = $f1Facts
    $result.f2OldTrackedLinkDelete = $f2Facts
    $result.p4OldPartialDelete = $p4Facts
    $result.redConfirmed = [bool]($f1Confirmed -and $f2Confirmed -and $p4Confirmed)
    $evidenceJson = ($result | ConvertTo-Json -Depth 10)
    Assert-RedSanitized -Text $evidenceJson -Label 'JSON 证据'
    $evidenceParent = Split-Path -Parent $EvidencePath
    if (-not [string]::IsNullOrWhiteSpace($evidenceParent)) {
        New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
    }
    [System.IO.File]::WriteAllText($EvidencePath, $evidenceJson, (New-Object System.Text.UTF8Encoding($false)))

    $logHeader = @(
        '# T1-03 第六轮 Red 探针 — 脱敏后的原始命令输出',
       ('# 生成时间（UTC）：' + (Get-Date).ToUniversalTime().ToString('o')),
        ('# 基线提交：' + $BaselineCommit + '（' + $baselineDate + '）'),
        ('# 命令：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\probe-round6-red.ps1'),
        ('# 说明：F1 为基线测试脚本入口子进程的真实输出；F2/P4 为探针在基线 T1-03UatPath.ps1 上执行的诊断输出。'),
        ''
    ) -join "`r`n"
    $sanitizedLog = Format-RedText ($logHeader + $f1RawOutput + "`r`n`r`n" + (($redLog | ForEach-Object { [string]$_ }) -join "`r`n") + "`r`n")
    Assert-RedSanitized -Text $sanitizedLog -Label '脱敏日志'
    [System.IO.File]::WriteAllText($sanitizedLogPath, $sanitizedLog, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('RED_EVIDENCE_JSON=' + $EvidencePath)
    Write-Host ('RED_EVIDENCE_LOG=' + $sanitizedLogPath)
    Write-Host ('R6_RED_CONFIRMED=' + [bool]$result.redConfirmed)

    Remove-PlainTree $caseRoot
    if (-not $result.redConfirmed) {
        Write-Host 'R6_RED_PROBE=FAIL（修复前行为未全部按审计预期复现，需人工复核）'
        exit 1
    }
    Write-Host 'R6_RED_PROBE=PASS'
    exit 0
}
catch {
    Write-Host ('RED_PROBE_ERROR=' + $_.Exception.Message)
    try { if ($null -ne $p4LockStream) { $p4LockStream.Dispose() } } catch { }
    try { if ($oldPathScriptLoaded) { } } catch { }
    try { Remove-PlainTree $caseRoot } catch { }
    exit 1
}
