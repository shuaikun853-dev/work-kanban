# =============================================================================
# WorkManager T1-04 多项目独立副本创建 Release UI/IPC 端到端编排脚本
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-04-ui.ps1
#   或：-ExePath <target\release\workmanager.exe> -OutputDir D:\WorkManager-test-data\t1-04-ui-manual -Port 9355
#
# 步骤：
# 1. 复制 Release EXE 到 D 盘独立 UAT 便携目录并启动（WebView2 远程调试端口）；
# 2. 运行 inspect-t1-04-ui.mjs：应用壳/导航、多项目选择计数、两项目/三项目批量创建、
#    未归属/单项目 T1-03 回归、归档项目历史关联、对话框打开后项目归档整批失败、
#    绕过 UI 直接 IPC 校验、重复提交保护、Bridge 严格契约、刷新失败三态、截图与证据；
# 3. 调整为最小支持窗口 860×640，运行 inspect-t1-04-min-window.mjs（最后点击红色关闭圆点），
#    本脚本验证进程真实退出码为 0；
# 4. python 标准库只读探针检查 UAT 数据库（schema 4、12 条 pending、4 个创建组、
#    9 条成员关系、无孤儿成员、无多组工作副本、外键干净）；
# 5. 原子回滚故障注入：应用关闭时向 UAT 数据库安装真实 SQLite TRIGGER（项目 C 的
#    第二条工作副本插入真实 ABORT），重新启动应用 → UI 批量创建 A+C 必须整批失败；
#    关闭后只读探针确认工作/创建组/成员数量完全不变，随后移除 trigger；
# 6. 重启持久化：再次启动同一 UAT 目录 → 12 条记录与创建组持久化、选择器不含归档项目、
#    重启后再批量创建 A+B（14 条 / 5 组 / 11 成员）；关闭后只读探针确认；
# 7. 输出机器可读汇总 t1-04-ui-orchestration.json。
#
# 安全约束（继承 T1-03 已验证设施，见 T1-03UatPath.ps1）：
# - 输出目录必须位于专用测试根目录 D:\WorkManager-test-data\ 之下；
# - 测试根目录信任锚、Windows 原生句柄重解析点/最终路径/卷身份校验，身份无法确认时 fail closed；
# - 故障注入只在 UAT 独立数据库执行，绝不在正式数据目录 D:\WorkManager 执行；
# - 所有测试数据虚构；不删除/覆盖正式目录或其他证据目录。
# - 路径检查与后续文件操作之间仍存在 TOCTOU 窗口，本脚本不宣称已消除该风险（DEC-029）。
# =============================================================================

[CmdletBinding()]
param(
    [string]$ExePath = '',
    [string]$OutputDir = '',
    [int]$Port = 9355
)

$ErrorActionPreference = 'Stop'
$script:Failed = $false
$script:DbChecks = New-Object System.Collections.ArrayList

. (Join-Path $PSScriptRoot 'T1-04UatPath.ps1')

function Assert-UatOutputDirStillSafe([string]$Directory, [string]$Stage) {
    try {
        $guard = Assert-T103NativePathSafety -RequestedPath $Directory -TestRoot $script:T103UatTestRoot -FormalRoot $script:T103UatFormalRoot
        Write-Host ("P3 safety re-check passed ({0}): components={1} volumeIdentityMatch={2} finalPathInsideRoot={3}" -f $Stage, $guard.checkedComponentCount, $guard.volumeIdentityMatch, $guard.finalPathInsideRoot)
    }
    catch {
        Write-Host ("PRECONDITION_FAILED: native path re-check failed ({0}): {1}" -f $Stage, $_.Exception.Message)
        exit 2
    }
}

function Assert-UatDatabasePathStillSafe([string]$Stage) {
    try {
        $record = Assert-T104UatDatabaseFile -Path $databasePath
        Write-Host ("T104-01 database path guard passed ({0}): parent={1} finalPath=verified volumeIdentity=verified reparsePoints=rejected" -f $Stage, [bool]$record.parent.path)
        return $record
    }
    catch {
        Write-Host ("PRECONDITION_FAILED: database native path guard failed ({0}): {1}" -f $Stage, $_.Exception.Message)
        exit 2
    }
}

function Assert-UatEvidenceFileStillSafe([string]$Path, [string]$Stage) {
    try {
        [void](Assert-T104UatEvidenceFile -DatabasePath $databasePath -EvidenceDirectory $script:EvidenceDir -Path $Path)
        Write-Host ("T104-01 evidence path guard passed ({0}): directChildOfEvidence=true finalPath=verified" -f $Stage)
    }
    catch {
        Write-Host ("PRECONDITION_FAILED: evidence native path guard failed ({0}): {1}" -f $Stage, $_.Exception.Message)
        exit 2
    }
}

function Assert-UatEvidenceDirStillSafe([string]$Stage) {
    try {
        $record = Assert-T104UatEvidenceDirectory -DatabasePath $databasePath -EvidenceDirectory $script:EvidenceDir
        Write-Host ("T104-01 evidence directory guard passed ({0}): directChildOfUatRoot=true finalPath=verified" -f $Stage)
        return $record
    }
    catch {
        Write-Host ("PRECONDITION_FAILED: evidence directory native path guard failed ({0}): {1}" -f $Stage, $_.Exception.Message)
        exit 2
    }
}

function Assert-SameDatabaseIdentity($Before, $After, [string]$Stage) {
    if ($null -eq $Before -or $null -eq $After) {
        Write-Host ("PRECONDITION_FAILED: missing database identity record ({0})" -f $Stage)
        exit 2
    }
    if ([string]$Before.database.finalPath -ne [string]$After.database.finalPath -or
        [string]$Before.database.fileIdHex -ne [string]$After.database.fileIdHex -or
        [string]$Before.database.volumeSerialNumber -ne [string]$After.database.volumeSerialNumber) {
        Write-Host ("PRECONDITION_FAILED: database path identity changed ({0})" -f $Stage)
        exit 2
    }
    Write-Host ("T104-01 database identity re-check passed ({0}): finalPath/fileId/volume unchanged" -f $Stage)
}

function Resolve-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-EvidenceFileList([string]$Directory) {
    if (-not (Test-Path $Directory)) { return @() }
    return @(Get-ChildItem $Directory -File | Sort-Object Name | Select-Object -ExpandProperty Name)
}

function Add-DbCheck([string]$Name, [bool]$Pass, [string]$Detail) {
    [void]$script:DbChecks.Add([pscustomobject]@{ name = $Name; pass = $Pass; detail = $Detail })
    if ($Pass) {
        Write-Host "PASS $Name — $Detail"
    }
    else {
        $script:Failed = $true
        Write-Host "FAIL $Name — $Detail"
    }
}

function Wait-MainWindow([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $Process.Refresh() } catch { return [IntPtr]::Zero }
        if ($Process.HasExited) { return [IntPtr]::Zero }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $Process.MainWindowHandle }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}

function Start-ReleaseApp([string]$AppExe, [string]$WorkingDirectory, [int]$DebugPort) {
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$DebugPort"
    try {
        $process = Start-Process -FilePath $AppExe -WorkingDirectory $WorkingDirectory -PassThru
    }
    finally {
        Remove-Item Env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
    }
    $hwnd = Wait-MainWindow -Process $process -TimeoutSeconds 40
    return [pscustomobject]@{ Process = $process; Hwnd = $hwnd }
}

function Set-WindowSize([IntPtr]$Hwnd, [int]$Width, [int]$Height) {
    if (-not ('Win32Window' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win32Window {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
    }
    $SWP_NOZORDER = 0x0004
    $SWP_SHOWWINDOW = 0x0040
    $SW_RESTORE = 9
    # WebView2 在窗口被遮挡/后台时可能延迟布局传播；先恢复并激活真实窗口，
    # 再调整尺寸，避免最小窗口检查读到旧视口（不是跳过检查）。
    [void][Win32Window]::ShowWindow($Hwnd, $SW_RESTORE)
    [void][Win32Window]::SetForegroundWindow($Hwnd)
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $ok = [Win32Window]::SetWindowPos($Hwnd, [IntPtr]::Zero, 40, 40, $Width, $Height, ($SWP_NOZORDER -bor $SWP_SHOWWINDOW))
        Start-Sleep -Milliseconds 300
        if ($ok) {
            $rect = New-Object Win32Window+RECT
            [void][Win32Window]::GetWindowRect($Hwnd, [ref]$rect)
            $actualWidth = $rect.Right - $rect.Left
            $actualHeight = $rect.Bottom - $rect.Top
            if ([Math]::Abs($actualWidth - $Width) -le 4 -and [Math]::Abs($actualHeight - $Height) -le 4) {
                Write-Host ("min window resize verified: {0}x{1}" -f $actualWidth, $actualHeight)
                return $true
            }
            Write-Host ("min window resize attempt {0}: got {1}x{2}" -f $attempt, $actualWidth, $actualHeight)
        }
        else {
            Write-Host ("min window resize attempt {0}: SetWindowPos returned false" -f $attempt)
        }
    }
    return $false
}

function Close-ReleaseApp([System.Diagnostics.Process]$Process) {
    if (-not $Process.HasExited) {
        if (-not $Process.WaitForExit(20000)) {
            try { $Process.Kill() } catch { }
            try { $Process.WaitForExit(5000) | Out-Null } catch { }
            return $null
        }
    }
    return $Process.ExitCode
}

function Invoke-DbProbe([string]$PythonPath, [string]$ProbeScript, [string]$DatabasePath, [string]$Stage, [string]$OutputDir) {
    $probePath = Join-Path $script:EvidenceDir ('t1-04-db-' + $Stage + '.json')
    [void](Assert-UatDatabasePathStillSafe -Stage ('before database probe ' + $Stage))
    Assert-UatEvidenceFileStillSafe -Path $probePath -Stage ('before database probe ' + $Stage)
    if (Test-Path -LiteralPath $probePath) {
        Remove-Item -LiteralPath $probePath -Force
    }
    & $PythonPath -X utf8 $ProbeScript $DatabasePath $Stage $probePath --evidence-dir $script:EvidenceDir | Out-Null
    $exitCode = $LASTEXITCODE
    [void](Assert-UatDatabasePathStillSafe -Stage ('after database probe ' + $Stage))
    $probe = $null
    if (Test-Path -LiteralPath $probePath -PathType Leaf) {
        try { $probe = Get-Content -LiteralPath $probePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $probe = $null }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Probe = $probe; Path = $probePath }
}

function Invoke-FaultControl([string]$PythonPath, [string]$ControlScript, [string]$Action, [string]$DatabasePath, [string]$ProjectId) {
    [void](Assert-UatDatabasePathStillSafe -Stage ('before fault control ' + $Action))
    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        & $PythonPath -X utf8 $ControlScript $Action $DatabasePath | Out-Null
    }
    else {
        & $PythonPath -X utf8 $ControlScript $Action $DatabasePath $ProjectId | Out-Null
    }
    $exitCode = $LASTEXITCODE
    [void](Assert-UatDatabasePathStillSafe -Stage ('after fault control ' + $Action))
    return $exitCode
}

function Add-ProbeCommonChecks([string]$Prefix, $Probe) {
    Add-DbCheck -Name ($Prefix + '.readable') -Pass ($null -ne $Probe) -Detail 'probe JSON readable'
    if ($null -eq $Probe) { return }
    Add-DbCheck -Name ($Prefix + '.probeStatusOk') -Pass ([string]$Probe.status -eq 'ok' -and [string]$Probe.scope -eq 'uat') -Detail ('status=' + [string]$Probe.status + ' scope=' + [string]$Probe.scope)
    Add-DbCheck -Name ($Prefix + '.schemaVersion4') -Pass ([int]$Probe.schema_version -eq 4) -Detail ('schema_version=' + [string]$Probe.schema_version)
    Add-DbCheck -Name ($Prefix + '.integrityOk') -Pass ([string]$Probe.integrity_check -eq 'ok') -Detail ([string]$Probe.integrity_check)
    Add-DbCheck -Name ($Prefix + '.journalModeWal') -Pass ([string]$Probe.journal_mode -eq 'wal') -Detail ([string]$Probe.journal_mode)
    Add-DbCheck -Name ($Prefix + '.foreignKeysEnabled') -Pass ([bool]$Probe.foreign_keys -eq $true) -Detail ('foreign_keys=' + [string]$Probe.foreign_keys)
    Add-DbCheck -Name ($Prefix + '.requiredTablesPresent') -Pass ([bool]$Probe.required_tables_present -eq $true) -Detail ('required_tables_present=' + [string]$Probe.required_tables_present)
    $migrationVersions = @($Probe.migration_versions)
    Add-DbCheck -Name ($Prefix + '.migrations1To4') -Pass ($migrationVersions.Count -eq 4 -and [int]$migrationVersions[0] -eq 1 -and [int]$migrationVersions[1] -eq 2 -and [int]$migrationVersions[2] -eq 3 -and [int]$migrationVersions[3] -eq 4) -Detail ($migrationVersions -join ',')
    Add-DbCheck -Name ($Prefix + '.foreignKeyViolationsZero') -Pass ([int]$Probe.foreign_key_violations -eq 0) -Detail ('violations=' + [string]$Probe.foreign_key_violations)
    Add-DbCheck -Name ($Prefix + '.allRowsPending') -Pass ([int]$Probe.work_items_pending -eq [int]$Probe.work_items_total -and [int]$Probe.work_items_other_status -eq 0) -Detail ('total=' + [string]$Probe.work_items_total + ' pending=' + [string]$Probe.work_items_pending)
    Add-DbCheck -Name ($Prefix + '.noOrphanMembers') -Pass ([int]$Probe.orphan_creation_group_members -eq 0) -Detail ('orphan=' + [string]$Probe.orphan_creation_group_members)
    Add-DbCheck -Name ($Prefix + '.noGroupsWithoutMembers') -Pass ([int]$Probe.creation_groups_without_members -eq 0) -Detail ('empty_groups=' + [string]$Probe.creation_groups_without_members)
    Add-DbCheck -Name ($Prefix + '.noWorkItemInMultipleGroups') -Pass ([int]$Probe.work_items_with_multiple_groups -eq 0) -Detail ('multi_group=' + [string]$Probe.work_items_with_multiple_groups)
    Add-DbCheck -Name ($Prefix + '.allBatchItemsPending') -Pass ([int]$Probe.batch_items_not_pending -eq 0) -Detail ('not_pending=' + [string]$Probe.batch_items_not_pending)
}

$repoRoot = Resolve-RepoRoot

# F1：任何写操作前验证专用测试根目录信任锚（缺失或身份不确定时 fail closed，不自动创建）。
try {
    $trustRecord = Assert-T103UatTrustedTestRoot -TestRoot $script:T103UatTestRoot -FormalRoot $script:T103UatFormalRoot
}
catch {
    Write-Host ("PRECONDITION_FAILED: " + $_.Exception.Message)
    exit 2
}
Write-Host ("F1 test-root trust anchor verified: components=" + $trustRecord.existingComponentCount + " volumeIdentity=verified finalPath=verified")

if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $ExePath = Join-Path $repoRoot 'target\release\workmanager.exe'
}
else {
    $ExePath = [System.IO.Path]::GetFullPath($ExePath)
}
if (-not (Test-Path $ExePath -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: Release EXE not found: $ExePath"
    exit 2
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    Write-Host 'PRECONDITION_FAILED: python not found (stdlib sqlite3 read-only probe required)'
    exit 2
}
$probeScript = Join-Path $repoRoot 'scripts\verify\probe-t1-04-db.py'
$controlScript = Join-Path $repoRoot 'scripts\verify\control-t1-04-fault.py'
$guardScript = Join-Path $repoRoot 'scripts\verify\guard-t1-04-path.ps1'
$guardModule = Join-Path $repoRoot 'scripts\verify\t1_04_path_guard.py'
foreach ($required in @($probeScript, $controlScript, $guardScript, $guardModule)) {
    if (-not (Test-Path $required -PathType Leaf)) {
        Write-Host "PRECONDITION_FAILED: verification script missing: $required"
        exit 2
    }
}

$exeInfo = Get-Item $ExePath
$exeSha256 = (Get-FileHash -Path $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = 'D:\WorkManager-test-data\t1-04-ui-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
}
try {
    $outputFull = Resolve-T103UatOutputDirectory -RequestedPath $OutputDir
}
catch {
    Write-Host ("PRECONDITION_FAILED: " + $_.Exception.Message)
    exit 2
}
New-Item -ItemType Directory -Force -Path $outputFull | Out-Null
Assert-UatOutputDirStillSafe -Directory $outputFull -Stage 'after creating UAT root'

$appDir = Join-Path $outputFull 'app'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
Assert-UatOutputDirStillSafe -Directory $appDir -Stage 'after creating app dir'
$appExe = Join-Path $appDir 'WorkManager.exe'
Copy-Item -Path $ExePath -Destination $appExe -Force
Assert-UatOutputDirStillSafe -Directory $appDir -Stage 'after copying EXE (before app start)'
$databasePath = Join-Path $appDir 'data\database\work.db'
$prerequisitePath = Join-Path $outputFull 't1-04-prerequisite.json'
$script:EvidenceDir = Join-Path $outputFull 'evidence'

Write-Host "T1-04 UI verification: exe=$ExePath sha256=$exeSha256 size=$($exeInfo.Length) output=$outputFull port=$Port"

$mainExit = 1
$minExit = 1
$faultExit = 1
$persistExit = 1
$firstExitCode = $null
$faultCloseExitCode = $null
$persistCloseExitCode = $null
$probeAfterMain = $null
$probeAfterFault = $null
$probeAfterRestart = $null

# ---------------------------------------------------------------------------
# 阶段 1：主 UI/IPC 检查 + 最小窗口/关闭按钮检查
# ---------------------------------------------------------------------------
$first = Start-ReleaseApp -AppExe $appExe -WorkingDirectory $appDir -DebugPort $Port
if ($first.Hwnd -eq [IntPtr]::Zero) {
    Write-Host "PRECONDITION_FAILED: Release main window did not appear (exited=$($first.Process.HasExited))"
    if (-not $first.Process.HasExited) { try { $first.Process.Kill() } catch { } }
    exit 2
}
Start-Sleep -Seconds 1

try {
    Write-Host '--- Running T1-04 main UI/IPC checks ---'
    & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-04-ui.mjs') $Port $outputFull
    $mainExit = $LASTEXITCODE
    if ($mainExit -ne 0) { $script:Failed = $true }

    Write-Host '--- Resizing to minimum supported window 860x640 ---'
    Write-Host ("first app pid={0} hwnd={1} exited={2}" -f $first.Process.Id, $first.Hwnd, $first.Process.HasExited)
    $script:MinWindowResizeOk = Set-WindowSize -Hwnd $first.Hwnd -Width 860 -Height 640
    if (-not $script:MinWindowResizeOk) {
        $script:Failed = $true
        Write-Host 'FAIL minWindow.setWindowPos'
    }
    else {
        $resizeProbe = New-Object Win32Window+RECT
        [void][Win32Window]::GetWindowRect($first.Hwnd, [ref]$resizeProbe)
        Write-Host ("window rect after resize: {0},{1},{2},{3}" -f $resizeProbe.Left, $resizeProbe.Top, $resizeProbe.Right, $resizeProbe.Bottom)

    }
    Start-Sleep -Seconds 2
    Write-Host '--- Running minimum window / close button checks ---'
    & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-04-min-window.mjs') $Port $outputFull
    $minExit = $LASTEXITCODE
    if ($minExit -ne 0) { $script:Failed = $true }
}
finally {
    $firstExitCode = Close-ReleaseApp -Process $first.Process
    if ($null -eq $firstExitCode) {
        $script:Failed = $true
        Write-Host 'FAIL firstClose.processDidNotExit'
    }
}
if ($firstExitCode -ne 0) {
    $script:Failed = $true
    Write-Host "FAIL firstClose.nonZeroExit exitCode=$firstExitCode"
}

# 主阶段数据库只读探针：12 条工作副本 / 4 个创建组 / 9 条成员关系。
# T104-01：先验证实际数据库文件及其全部祖先，再创建证据目录并验证其身份。
$dbIdentityAfterMain = Assert-UatDatabasePathStillSafe -Stage 'after main app close (before evidence dir)'
New-Item -ItemType Directory -Force -Path $script:EvidenceDir | Out-Null
[void](Assert-UatEvidenceDirStillSafe -Stage 'after creating UAT evidence dir')
$probeAfterMain = Invoke-DbProbe -PythonPath $pythonCommand.Source -ProbeScript $probeScript -DatabasePath $databasePath -Stage 'after-main' -OutputDir $outputFull
Add-ProbeCommonChecks -Prefix 'dbProbe.afterMain' -Probe $probeAfterMain.Probe
if ($null -ne $probeAfterMain.Probe) {
    $probe = $probeAfterMain.Probe
    Add-DbCheck -Name 'dbProbe.afterMain.workItems14' -Pass ([int]$probe.work_items_total -eq 14) -Detail ('work_items=' + [string]$probe.work_items_total)
    Add-DbCheck -Name 'dbProbe.afterMain.pending14' -Pass ([int]$probe.work_items_pending -eq 14) -Detail ('pending=' + [string]$probe.work_items_pending)
    Add-DbCheck -Name 'dbProbe.afterMain.unassigned1' -Pass ([int]$probe.work_items_null_project -eq 1) -Detail ('null_project=' + [string]$probe.work_items_null_project)
    Add-DbCheck -Name 'dbProbe.afterMain.archivedLink1' -Pass ([int]$probe.work_items_linked_archived -eq 1) -Detail ('linked_archived=' + [string]$probe.work_items_linked_archived)
    Add-DbCheck -Name 'dbProbe.afterMain.linkedActive12' -Pass ([int]$probe.work_items_linked_active -eq 12) -Detail ('linked_active=' + [string]$probe.work_items_linked_active)
    Add-DbCheck -Name 'dbProbe.afterMain.projects4Archived1' -Pass ([int]$probe.projects_total -eq 4 -and [int]$probe.projects_archived -eq 1) -Detail ('projects=' + [string]$probe.projects_total + ' archived=' + [string]$probe.projects_archived)
    Add-DbCheck -Name 'dbProbe.afterMain.creationGroups5' -Pass ([int]$probe.creation_groups_total -eq 5) -Detail ('groups=' + [string]$probe.creation_groups_total)
    Add-DbCheck -Name 'dbProbe.afterMain.members11' -Pass ([int]$probe.creation_group_members_total -eq 11) -Detail ('members=' + [string]$probe.creation_group_members_total)
    $histogram = $probe.creation_group_size_histogram
    Add-DbCheck -Name 'dbProbe.afterMain.groupSizeHistogram' -Pass ([int]$histogram.'2' -eq 4 -and [int]$histogram.'3' -eq 1) -Detail ($histogram | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------------------
# 阶段 2：原子回滚故障注入（真实 SQLite TRIGGER，仅 UAT 数据库）
# ---------------------------------------------------------------------------
$prerequisite = Read-JsonFile $prerequisitePath
$projectCId = $null
if ($null -ne $prerequisite -and $null -ne $prerequisite.projects -and $null -ne $prerequisite.projects.C) {
    $projectCId = [string]$prerequisite.projects.C.id
}
if ([string]::IsNullOrWhiteSpace($projectCId)) {
    Write-Host 'FAIL fault.projectCIdMissing — prerequisite JSON does not contain project C id'
    $script:Failed = $true
}
else {
    # T104-01 顺序：先验证实际数据库路径与身份，再执行故障注入；
    # 注入后、启动应用前、应用关闭后、移除后都重新验证路径身份。
    $dbIdentityBeforeFault = Assert-UatDatabasePathStillSafe -Stage 'before fault install'
    Write-Host "--- Installing atomic-rollback fault trigger for project C ($projectCId) ---"
    $installExit = Invoke-FaultControl -PythonPath $pythonCommand.Source -ControlScript $controlScript -Action 'install' -DatabasePath $databasePath -ProjectId $projectCId
    if ($installExit -ne 0) {
        $script:Failed = $true
        Write-Host "FAIL fault.installExit=$installExit"
    }
    $dbIdentityAfterInstall = Assert-UatDatabasePathStillSafe -Stage 'after fault install before app start'
    Assert-SameDatabaseIdentity -Before $dbIdentityBeforeFault -After $dbIdentityAfterInstall -Stage 'after fault install'

    $faultPort = $Port + 1
    Assert-UatOutputDirStillSafe -Directory $appDir -Stage 'before fault-phase app start (application copy)'
    [void](Assert-UatDatabasePathStillSafe -Stage 'before fault-phase app start (database write)')
    $second = Start-ReleaseApp -AppExe $appExe -WorkingDirectory $appDir -DebugPort $faultPort
    if ($second.Hwnd -eq [IntPtr]::Zero) {
        $script:Failed = $true
        Write-Host "FAIL fault.mainWindowMissing (exited=$($second.Process.HasExited))"
        if (-not $second.Process.HasExited) { try { $second.Process.Kill() } catch { } }
    }
    else {
        Start-Sleep -Seconds 1
        try {
            & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-04-fault.mjs') $faultPort $outputFull $prerequisitePath
            $faultExit = $LASTEXITCODE
            if ($faultExit -ne 0) { $script:Failed = $true }
        }
        finally {
            $faultCloseExitCode = Close-ReleaseApp -Process $second.Process
            if ($null -eq $faultCloseExitCode) {
                $script:Failed = $true
                Write-Host 'FAIL faultClose.processDidNotExit'
            }
        }
        if ($faultCloseExitCode -ne 0) {
            $script:Failed = $true
            Write-Host "FAIL faultClose.nonZeroExit exitCode=$faultCloseExitCode"
        }
    }

    $dbIdentityAfterFaultApp = Assert-UatDatabasePathStillSafe -Stage 'after fault app close before trigger removal'
    Assert-SameDatabaseIdentity -Before $dbIdentityBeforeFault -After $dbIdentityAfterFaultApp -Stage 'after fault app close'

    $removeExit = Invoke-FaultControl -PythonPath $pythonCommand.Source -ControlScript $controlScript -Action 'remove' -DatabasePath $databasePath -ProjectId ''
    if ($removeExit -ne 0) {
        $script:Failed = $true
        Write-Host "FAIL fault.removeExit=$removeExit"
    }
    $dbIdentityAfterRemove = Assert-UatDatabasePathStillSafe -Stage 'after fault trigger removal before probe'
    Assert-SameDatabaseIdentity -Before $dbIdentityBeforeFault -After $dbIdentityAfterRemove -Stage 'after fault trigger removal'

    $probeAfterFault = Invoke-DbProbe -PythonPath $pythonCommand.Source -ProbeScript $probeScript -DatabasePath $databasePath -Stage 'after-fault' -OutputDir $outputFull
    Add-ProbeCommonChecks -Prefix 'dbProbe.afterFault' -Probe $probeAfterFault.Probe
    if ($null -ne $probeAfterFault.Probe) {
        $faultProbe = $probeAfterFault.Probe
        Add-DbCheck -Name 'dbProbe.afterFault.workItemsStill14' -Pass ([int]$faultProbe.work_items_total -eq 14) -Detail ('work_items=' + [string]$faultProbe.work_items_total)
        Add-DbCheck -Name 'dbProbe.afterFault.creationGroupsStill5' -Pass ([int]$faultProbe.creation_groups_total -eq 5) -Detail ('groups=' + [string]$faultProbe.creation_groups_total)
        Add-DbCheck -Name 'dbProbe.afterFault.membersStill11' -Pass ([int]$faultProbe.creation_group_members_total -eq 11) -Detail ('members=' + [string]$faultProbe.creation_group_members_total)
        $faultHistogram = $faultProbe.creation_group_size_histogram
        Add-DbCheck -Name 'dbProbe.afterFault.noFaultBatchResidue' -Pass ([int]$faultProbe.work_items_total -eq 14 -and [int]$faultProbe.creation_groups_total -eq 5 -and [int]$faultProbe.creation_group_members_total -eq 11 -and [int]$faultHistogram.'2' -eq 4 -and [int]$faultHistogram.'3' -eq 1) -Detail ('work_items=' + [string]$faultProbe.work_items_total + ' groups=' + [string]$faultProbe.creation_groups_total + ' members=' + [string]$faultProbe.creation_group_members_total)
    }
}

# ---------------------------------------------------------------------------
# 阶段 3：重启持久化 + 重启后批量创建
# ---------------------------------------------------------------------------
if (-not (Test-Path $prerequisitePath -PathType Leaf)) {
    $script:Failed = $true
    Write-Host 'FAIL persistence.prerequisiteMissing — main check did not write t1-04-prerequisite.json'
}
else {
    $persistPort = $Port + 2
    Write-Host "--- Restarting Release (port $persistPort) for persistence checks ---"
    Assert-UatOutputDirStillSafe -Directory $appDir -Stage 'before persistence-phase app start (application copy)'
    $dbIdentityBeforeRestart = Assert-UatDatabasePathStillSafe -Stage 'before persistence-phase app start (database write)'
    $third = Start-ReleaseApp -AppExe $appExe -WorkingDirectory $appDir -DebugPort $persistPort
    if ($third.Hwnd -eq [IntPtr]::Zero) {
        $script:Failed = $true
        Write-Host "FAIL persistence.restartMainWindowMissing (exited=$($third.Process.HasExited))"
        if (-not $third.Process.HasExited) { try { $third.Process.Kill() } catch { } }
    }
    else {
        Start-Sleep -Seconds 1
        try {
            & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-04-persistence.mjs') $persistPort $outputFull $prerequisitePath
            $persistExit = $LASTEXITCODE
            if ($persistExit -ne 0) { $script:Failed = $true }
        }
        finally {
            $persistCloseExitCode = Close-ReleaseApp -Process $third.Process
            if ($null -eq $persistCloseExitCode) {
                $script:Failed = $true
                Write-Host 'FAIL persistenceClose.processDidNotExit'
            }
        }
        if ($persistCloseExitCode -ne 0) {
            $script:Failed = $true
            Write-Host "FAIL persistenceClose.nonZeroExit exitCode=$persistCloseExitCode"
        }

        $dbIdentityAfterRestartApp = Assert-UatDatabasePathStillSafe -Stage 'after persistence app close before probe'
        Assert-SameDatabaseIdentity -Before $dbIdentityBeforeRestart -After $dbIdentityAfterRestartApp -Stage 'after persistence app close'

        $probeAfterRestart = Invoke-DbProbe -PythonPath $pythonCommand.Source -ProbeScript $probeScript -DatabasePath $databasePath -Stage 'after-restart' -OutputDir $outputFull
        Add-ProbeCommonChecks -Prefix 'dbProbe.afterRestart' -Probe $probeAfterRestart.Probe
        if ($null -ne $probeAfterRestart.Probe) {
            $restartProbe = $probeAfterRestart.Probe
            Add-DbCheck -Name 'dbProbe.afterRestart.workItems16' -Pass ([int]$restartProbe.work_items_total -eq 16) -Detail ('work_items=' + [string]$restartProbe.work_items_total)
            Add-DbCheck -Name 'dbProbe.afterRestart.pending16' -Pass ([int]$restartProbe.work_items_pending -eq 16) -Detail ('pending=' + [string]$restartProbe.work_items_pending)
            Add-DbCheck -Name 'dbProbe.afterRestart.creationGroups6' -Pass ([int]$restartProbe.creation_groups_total -eq 6) -Detail ('groups=' + [string]$restartProbe.creation_groups_total)
            Add-DbCheck -Name 'dbProbe.afterRestart.members13' -Pass ([int]$restartProbe.creation_group_members_total -eq 13) -Detail ('members=' + [string]$restartProbe.creation_group_members_total)
            $restartHistogram = $restartProbe.creation_group_size_histogram
            Add-DbCheck -Name 'dbProbe.afterRestart.groupSizeHistogram' -Pass ([int]$restartHistogram.'2' -eq 5 -and [int]$restartHistogram.'3' -eq 1) -Detail ($restartHistogram | ConvertTo-Json -Compress)
            Add-DbCheck -Name 'dbProbe.afterRestart.newBatchPersisted' -Pass ([int]$restartProbe.work_items_total -eq 16 -and [int]$restartProbe.creation_groups_total -eq 6 -and [int]$restartProbe.creation_group_members_total -eq 13 -and [int]$restartHistogram.'2' -eq 5) -Detail ('work_items=' + [string]$restartProbe.work_items_total + ' groups=' + [string]$restartProbe.creation_groups_total + ' members=' + [string]$restartProbe.creation_group_members_total)
            Add-DbCheck -Name 'dbProbe.afterRestart.noArchivedLinkLost' -Pass ([int]$restartProbe.work_items_linked_archived -eq 1) -Detail ('linked_archived=' + [string]$restartProbe.work_items_linked_archived)
        }
    }
}

# ---------------------------------------------------------------------------
# 汇总机器可读证据
# ---------------------------------------------------------------------------
$mainEvidence = Read-JsonFile (Join-Path $outputFull 't1-04-ui-evidence.json')
$minWindowEvidence = Read-JsonFile (Join-Path $outputFull 't1-04-min-window-evidence.json')
$faultEvidence = Read-JsonFile (Join-Path $outputFull 't1-04-fault-evidence.json')
$persistenceEvidence = Read-JsonFile (Join-Path $outputFull 't1-04-persistence-evidence.json')

function Get-CheckCount($Evidence) {
    if ($null -ne $Evidence -and $null -ne $Evidence.checks) { return @($Evidence.checks).Count }
    return $null
}
function Get-FailedCount($Evidence) {
    if ($null -ne $Evidence -and $null -ne $Evidence.failed) { return @($Evidence.failed).Count }
    return $null
}

$mainCheckCount = Get-CheckCount $mainEvidence
$mainFailedCount = Get-FailedCount $mainEvidence
$minWindowCheckCount = Get-CheckCount $minWindowEvidence
$minWindowFailedCount = Get-FailedCount $minWindowEvidence
$faultCheckCount = Get-CheckCount $faultEvidence
$faultFailedCount = Get-FailedCount $faultEvidence
$persistenceCheckCount = Get-CheckCount $persistenceEvidence
$persistenceFailedCount = Get-FailedCount $persistenceEvidence

if ($mainExit -eq 0 -and $null -eq $mainCheckCount) { $script:Failed = $true; Write-Host 'FAIL mainUi.evidenceMissing' }
if ($minExit -eq 0 -and $null -eq $minWindowCheckCount) { $script:Failed = $true; Write-Host 'FAIL minWindow.evidenceMissing' }
if ($faultExit -eq 0 -and $null -eq $faultCheckCount) { $script:Failed = $true; Write-Host 'FAIL fault.evidenceMissing' }
if ($persistExit -eq 0 -and $null -eq $persistenceCheckCount) { $script:Failed = $true; Write-Host 'FAIL persistence.evidenceMissing' }
foreach ($failedCount in @($mainFailedCount, $minWindowFailedCount, $faultFailedCount, $persistenceFailedCount)) {
    if ($null -ne $failedCount -and $failedCount -gt 0) { $script:Failed = $true }
}

$dbFailedCount = @($script:DbChecks | Where-Object { -not $_.pass }).Count
if ($dbFailedCount -gt 0) { $script:Failed = $true }

$summary = [ordered]@{
    task                        = 'T1-04'
    generatedAt                 = (Get-Date).ToUniversalTime().ToString('o')
    exePath                     = $ExePath
    exeSha256                   = $exeSha256
    exeSizeBytes                = $exeInfo.Length
    outputDir                   = $outputFull
    appDir                      = $appDir
    databasePath                = $databasePath
    remoteDebugPort             = $Port
    mainUiCheckExitCode         = $mainExit
    mainUiCheckCount            = $mainCheckCount
    mainUiFailedCheckCount      = $mainFailedCount
    minWindowCheckExit          = $minExit
    minWindowCheckCount         = $minWindowCheckCount
    minWindowFailedCheckCount   = $minWindowFailedCount
    minWindowResizeOk           = $script:MinWindowResizeOk
    firstCloseExitCode          = $firstExitCode
    faultCheckExitCode          = $faultExit
    faultCheckCount             = $faultCheckCount
    faultFailedCheckCount       = $faultFailedCount
    faultCloseExitCode          = $faultCloseExitCode
    persistenceCheckExitCode    = $persistExit
    persistenceCheckCount       = $persistenceCheckCount
    persistenceFailedCheckCount = $persistenceFailedCount
    persistenceCloseExitCode    = $persistCloseExitCode
    dbCheckCount                = @($script:DbChecks).Count
    dbFailedCheckCount          = $dbFailedCount
    dbChecks                    = @($script:DbChecks)
    evidenceDir                 = $script:EvidenceDir
    pathGuard                   = [ordered]@{
        trustAnchorVerified                  = $true
        databasePathAndAncestorsVerified     = $true
        databaseFileReparsePointRejected     = $true
        evidenceDirectoryBoundaryVerified    = $true
        evidenceFileBoundaryVerified         = $true
        volumeIdentityVerified               = $true
        staticReparsePointsRejected          = $true
        concurrentReplacementRisk            = 'DEC-029 / Issue #2 remains deferred and unresolved'
    }
    dbProbeAfterMain            = $probeAfterMain.Path
    dbProbeAfterFault           = if ($null -ne $probeAfterFault) { $probeAfterFault.Path } else { $null }
    dbProbeAfterRestart         = if ($null -ne $probeAfterRestart) { $probeAfterRestart.Path } else { $null }
    evidenceFiles               = Get-EvidenceFileList $outputFull
    screenshots                 = @(Get-EvidenceFileList $outputFull | Where-Object { $_ -like '*.png' })
    pass                        = (-not $script:Failed)
}
$summaryPath = Join-Path $outputFull 't1-04-ui-orchestration.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "T1-04 evidence summary: $summaryPath"
Write-Host ($summary | ConvertTo-Json -Depth 8)

if ($script:Failed) { exit 1 }
Write-Host 'T1_04_RELEASE_UI_E2E=PASS'
exit 0
