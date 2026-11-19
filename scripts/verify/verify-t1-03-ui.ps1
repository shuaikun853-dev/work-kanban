# =============================================================================
# WorkManager T1-03 Release UI/IPC 端到端编排脚本
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1
#   或：-ExePath <target\release\workmanager.exe> -OutputDir D:\WorkManager-test-data\t1-03-ui-manual -Port 9345
#
# 步骤：
# 1. 复制 Release EXE 到 D 盘独立 UAT 便携目录并启动（WebView2 远程调试端口）；
# 2. 运行 inspect-t1-03-ui.mjs：应用壳/导航、待安排 loading/empty/list、真实 UI
#    快速创建（未归属 + 未归档项目）、重复提交保护、项目归档竞态错误、直接 IPC 绕过
#    校验、CDP 故障注入（加载失败/重试、Bridge 契约违规）、长标题布局、截图与证据；
# 3. 调整为最小支持窗口 860×640，运行 inspect-t1-03-min-window.mjs，最后点击红色
#    关闭圆点；本脚本验证进程真实退出码为 0；
# 4. 用 python 标准库只读检查 UAT 数据库（user_version=3、行数、状态分布、外键）；
# 5. 使用同一 UAT 便携目录重新启动 Release，运行 inspect-t1-03-persistence.mjs：
#    验证关闭重开后工作事项持久化、归档项目历史关联保留、选择器仍只含未归档项目、
#    重启后仍可创建；最后关闭并验证退出码；
# 6. 再次只读检查数据库（5 条 pending、无其他状态、外键干净），输出证据摘要 JSON。
#
# 数据边界：只使用 D:\WorkManager-test-data 下的隔离目录与虚构数据，
# 不触碰正式运行目录 D:\WorkManager，不使用真实用户工作数据。
# =============================================================================

[CmdletBinding()]
param(
    [string]$ExePath = '',
    [string]$OutputDir = '',
    [int]$Port = 9345
)

$ErrorActionPreference = 'Stop'
$script:Failed = $false
$script:DbChecks = New-Object System.Collections.ArrayList

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
}
"@
    }
    $SWP_NOZORDER = 0x0004
    return [Win32Window]::SetWindowPos($Hwnd, [IntPtr]::Zero, 40, 40, $Width, $Height, $SWP_NOZORDER)
}

function Close-ReleaseApp([System.Diagnostics.Process]$Process) {
    $exited = $false
    if (-not $Process.HasExited) {
        $exited = $Process.WaitForExit(20000)
    }
    else {
        $exited = $true
    }
    if (-not $exited) {
        try { $Process.Kill() } catch { }
        try { $Process.WaitForExit(5000) | Out-Null } catch { }
        return $null
    }
    return $Process.ExitCode
}

function Invoke-DbProbe([string]$PythonPath, [string]$ProbeScript, [string]$DatabasePath, [string]$Stage, [string]$OutputDir) {
    $probePath = Join-Path $OutputDir ('t1-03-db-' + $Stage + '.json')
    if (Test-Path $probePath) {
        Remove-Item -Path $probePath -Force
    }
    # Python 直接以 UTF-8 写 JSON 文件，避开 PowerShell 5.1 原生命令 stdout 解码差异；
    # 只读打开/查询失败时退出码为 2，文件可能不存在。
    & $PythonPath -X utf8 $ProbeScript $DatabasePath $Stage $probePath | Out-Null
    $exitCode = $LASTEXITCODE
    $probe = $null
    if (Test-Path $probePath -PathType Leaf) {
        try { $probe = Get-Content -Path $probePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $probe = $null }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Probe = $probe; Path = $probePath }
}

$repoRoot = Resolve-RepoRoot
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $ExePath = Join-Path $repoRoot 'target\release\workmanager.exe'
}
else {
    $ExePath = [System.IO.Path]::GetFullPath($ExePath)
}

if (-not (Test-Path $ExePath -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: Release EXE 不存在：$ExePath"
    exit 2
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    Write-Host 'PRECONDITION_FAILED: 未找到 python（需要标准库 sqlite3 做只读数据库探针）'
    exit 2
}
$probeScript = Join-Path $repoRoot 'scripts\verify\probe-t1-03-db.py'
if (-not (Test-Path $probeScript -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: 数据库探针脚本不存在：$probeScript"
    exit 2
}

$exeInfo = Get-Item $ExePath
$exeSha256 = (Get-FileHash -Path $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = 'D:\WorkManager-test-data\t1-03-ui-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
}
$outputFull = [System.IO.Path]::GetFullPath($OutputDir)
if ($outputFull -notmatch '^[Dd]:\\') {
    Write-Host "PRECONDITION_FAILED: 输出目录必须在 D 盘（实际 $outputFull）"
    exit 2
}
New-Item -ItemType Directory -Force -Path $outputFull | Out-Null

$appDir = Join-Path $outputFull 'app'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
$appExe = Join-Path $appDir 'WorkManager.exe'
Copy-Item -Path $ExePath -Destination $appExe -Force
$databasePath = Join-Path $appDir 'data\database\work.db'

Write-Host "T1-03 UI 验证：exe=$ExePath sha256=$exeSha256 size=$($exeInfo.Length) output=$outputFull port=$Port"

# ---------------------------------------------------------------------------
# 阶段 1：主 UI/IPC 检查 + 最小窗口/关闭按钮检查
# ---------------------------------------------------------------------------
$first = Start-ReleaseApp -AppExe $appExe -WorkingDirectory $appDir -DebugPort $Port
if ($first.Hwnd -eq [IntPtr]::Zero) {
    Write-Host "PRECONDITION_FAILED: Release 主窗口未在超时内出现（exited=$($first.Process.HasExited)）"
    if (-not $first.Process.HasExited) { try { $first.Process.Kill() } catch { } }
    exit 2
}
Start-Sleep -Seconds 1

$mainExit = 1
$minExit = 1
$firstExitCode = $null
try {
    Write-Host '--- 运行 T1-03 主 UI/IPC 检查 ---'
    & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-03-ui.mjs') $Port $outputFull
    $mainExit = $LASTEXITCODE
    if ($mainExit -ne 0) { $script:Failed = $true }

    Write-Host '--- 调整到最小支持窗口 860x640 ---'
    if (-not (Set-WindowSize -Hwnd $first.Hwnd -Width 860 -Height 640)) {
        $script:Failed = $true
        Write-Host 'FAIL minWindow.setWindowPos'
    }
    Start-Sleep -Seconds 2

    Write-Host '--- 运行最小窗口/关闭按钮检查 ---'
    & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-03-min-window.mjs') $Port $outputFull
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

# 关闭后只读检查数据库（证明数据真实写入便携目录 SQLite）。
$dbProbeAfterMain = Invoke-DbProbe -PythonPath $pythonCommand.Source -ProbeScript $probeScript -DatabasePath $databasePath -Stage 'after-main' -OutputDir $outputFull
if ($dbProbeAfterMain.ExitCode -ne 0 -or $null -eq $dbProbeAfterMain.Probe) {
    Add-DbCheck -Name 'dbProbe.afterMain.readable' -Pass $false -Detail ('exitCode=' + [string]$dbProbeAfterMain.ExitCode + ' path=' + $dbProbeAfterMain.Path)
}
else {
    $probe = $dbProbeAfterMain.Probe
    Add-DbCheck -Name 'dbProbe.afterMain.readable' -Pass $true -Detail $dbProbeAfterMain.Path
    Add-DbCheck -Name 'dbProbe.afterMain.portablePath' -Pass ([string]$probe.database_path -like ($outputFull + '*')) -Detail ([string]$probe.database_path)
    Add-DbCheck -Name 'dbProbe.afterMain.userVersion3' -Pass ([int]$probe.user_version -eq 3) -Detail ('user_version=' + [string]$probe.user_version)
    Add-DbCheck -Name 'dbProbe.afterMain.integrityOk' -Pass ([string]$probe.integrity_check -eq 'ok') -Detail ([string]$probe.integrity_check)
    Add-DbCheck -Name 'dbProbe.afterMain.journalModeWal' -Pass ([string]$probe.journal_mode -eq 'wal') -Detail ([string]$probe.journal_mode)
    Add-DbCheck -Name 'dbProbe.afterMain.foreignKeysClean' -Pass ([int]$probe.foreign_key_violations -eq 0) -Detail ('violations=' + [string]$probe.foreign_key_violations)
    Add-DbCheck -Name 'dbProbe.afterMain.migrations1To3' -Pass (@($probe.schema_migrations).Count -eq 3 -and [int]$probe.schema_migrations[0].version -eq 1 -and [int]$probe.schema_migrations[1].version -eq 2 -and [int]$probe.schema_migrations[2].version -eq 3) -Detail ('migrations=' + (@($probe.schema_migrations) | ForEach-Object { $_.version }) -join ',')
    Add-DbCheck -Name 'dbProbe.afterMain.workItems4' -Pass ([int]$probe.work_items_total -eq 4) -Detail ('work_items=' + [string]$probe.work_items_total)
    Add-DbCheck -Name 'dbProbe.afterMain.pending4' -Pass ([int]$probe.work_items_pending -eq 4) -Detail ('pending=' + [string]$probe.work_items_pending)
    Add-DbCheck -Name 'dbProbe.afterMain.noOtherStatus' -Pass ([int]$probe.work_items_other_status -eq 0) -Detail ('other_status=' + [string]$probe.work_items_other_status)
    Add-DbCheck -Name 'dbProbe.afterMain.unassigned3' -Pass ([int]$probe.work_items_null_project -eq 3) -Detail ('null_project=' + [string]$probe.work_items_null_project)
    Add-DbCheck -Name 'dbProbe.afterMain.archivedLink1' -Pass ([int]$probe.work_items_linked_archived -eq 1) -Detail ('linked_archived=' + [string]$probe.work_items_linked_archived)
    Add-DbCheck -Name 'dbProbe.afterMain.noActiveProjectLink' -Pass ([int]$probe.work_items_linked_active -eq 0) -Detail ('linked_active=' + [string]$probe.work_items_linked_active)
    Add-DbCheck -Name 'dbProbe.afterMain.projects2Archived2' -Pass ([int]$probe.projects_total -eq 2 -and [int]$probe.projects_archived -eq 2) -Detail ('projects=' + [string]$probe.projects_total + ' archived=' + [string]$probe.projects_archived)
    $expectedTitles = @('整理中核商品数据', '重复提交保护验证', '关联未归档项目的待安排工作')
    $titles = @($probe.pending_titles)
    $titlesOk = $expectedTitles | ForEach-Object { $titles -contains $_ }
    Add-DbCheck -Name 'dbProbe.afterMain.expectedTitlesPersisted' -Pass (-not ($titlesOk -contains $false)) -Detail ('titles=' + ($titles -join ' | '))
}

# ---------------------------------------------------------------------------
# 阶段 2：关闭 → 重启持久化检查
# ---------------------------------------------------------------------------
$prerequisitePath = Join-Path $outputFull 't1-03-prerequisite.json'
$persistExit = 1
$secondExitCode = $null
$dbProbeAfterRestart = $null

if (-not (Test-Path $prerequisitePath -PathType Leaf)) {
    $script:Failed = $true
    Write-Host 'FAIL persistence.prerequisiteMissing — 主检查未生成 t1-03-prerequisite.json'
}
else {
    $secondPort = $Port + 1
    Write-Host "--- 重新启动 Release（端口 $secondPort）验证持久化 ---"
    $second = Start-ReleaseApp -AppExe $appExe -WorkingDirectory $appDir -DebugPort $secondPort
    if ($second.Hwnd -eq [IntPtr]::Zero) {
        $script:Failed = $true
        Write-Host "FAIL persistence.restartMainWindowMissing（exited=$($second.Process.HasExited)）"
        if (-not $second.Process.HasExited) { try { $second.Process.Kill() } catch { } }
    }
    else {
        Start-Sleep -Seconds 1
        try {
            & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-03-persistence.mjs') $secondPort $outputFull $prerequisitePath
            $persistExit = $LASTEXITCODE
            if ($persistExit -ne 0) { $script:Failed = $true }
        }
        finally {
            $secondExitCode = Close-ReleaseApp -Process $second.Process
            if ($null -eq $secondExitCode) {
                $script:Failed = $true
                Write-Host 'FAIL secondClose.processDidNotExit'
            }
        }
        if ($secondExitCode -ne 0) {
            $script:Failed = $true
            Write-Host "FAIL secondClose.nonZeroExit exitCode=$secondExitCode"
        }

        $dbProbeAfterRestart = Invoke-DbProbe -PythonPath $pythonCommand.Source -ProbeScript $probeScript -DatabasePath $databasePath -Stage 'after-restart' -OutputDir $outputFull
        if ($dbProbeAfterRestart.ExitCode -ne 0 -or $null -eq $dbProbeAfterRestart.Probe) {
            Add-DbCheck -Name 'dbProbe.afterRestart.readable' -Pass $false -Detail ('exitCode=' + [string]$dbProbeAfterRestart.ExitCode + ' path=' + $dbProbeAfterRestart.Path)
        }
        else {
            $probe2 = $dbProbeAfterRestart.Probe
            Add-DbCheck -Name 'dbProbe.afterRestart.readable' -Pass $true -Detail $dbProbeAfterRestart.Path
            Add-DbCheck -Name 'dbProbe.afterRestart.userVersion3' -Pass ([int]$probe2.user_version -eq 3) -Detail ('user_version=' + [string]$probe2.user_version)
            Add-DbCheck -Name 'dbProbe.afterRestart.integrityOk' -Pass ([string]$probe2.integrity_check -eq 'ok') -Detail ([string]$probe2.integrity_check)
            Add-DbCheck -Name 'dbProbe.afterRestart.workItems5' -Pass ([int]$probe2.work_items_total -eq 5) -Detail ('work_items=' + [string]$probe2.work_items_total)
            Add-DbCheck -Name 'dbProbe.afterRestart.pending5' -Pass ([int]$probe2.work_items_pending -eq 5) -Detail ('pending=' + [string]$probe2.work_items_pending)
            Add-DbCheck -Name 'dbProbe.afterRestart.noOtherStatus' -Pass ([int]$probe2.work_items_other_status -eq 0) -Detail ('other_status=' + [string]$probe2.work_items_other_status)
            Add-DbCheck -Name 'dbProbe.afterRestart.unassigned4' -Pass ([int]$probe2.work_items_null_project -eq 4) -Detail ('null_project=' + [string]$probe2.work_items_null_project)
            Add-DbCheck -Name 'dbProbe.afterRestart.archivedLink1' -Pass ([int]$probe2.work_items_linked_archived -eq 1) -Detail ('linked_archived=' + [string]$probe2.work_items_linked_archived)
            Add-DbCheck -Name 'dbProbe.afterRestart.foreignKeysClean' -Pass ([int]$probe2.foreign_key_violations -eq 0) -Detail ('violations=' + [string]$probe2.foreign_key_violations)
            Add-DbCheck -Name 'dbProbe.afterRestart.newWorkPersisted' -Pass (@($probe2.pending_titles) -contains '重启后新建的工作') -Detail ('titles=' + (@($probe2.pending_titles) -join ' | '))
        }
    }
}

# ---------------------------------------------------------------------------
# 汇总机器可读证据
# ---------------------------------------------------------------------------
$mainEvidence = Read-JsonFile (Join-Path $outputFull 't1-03-ui-evidence.json')
$minWindowEvidence = Read-JsonFile (Join-Path $outputFull 't1-03-min-window-evidence.json')
$persistenceEvidence = Read-JsonFile (Join-Path $outputFull 't1-03-persistence-evidence.json')

$mainCheckCount = if ($null -ne $mainEvidence -and $null -ne $mainEvidence.checks) { @($mainEvidence.checks).Count } else { $null }
$mainFailedCount = if ($null -ne $mainEvidence -and $null -ne $mainEvidence.failed) { @($mainEvidence.failed).Count } else { $null }
$minWindowCheckCount = if ($null -ne $minWindowEvidence -and $null -ne $minWindowEvidence.checks) { @($minWindowEvidence.checks).Count } else { $null }
$minWindowFailedCount = if ($null -ne $minWindowEvidence -and $null -ne $minWindowEvidence.failed) { @($minWindowEvidence.failed).Count } else { $null }
$persistenceCheckCount = if ($null -ne $persistenceEvidence -and $null -ne $persistenceEvidence.checks) { @($persistenceEvidence.checks).Count } else { $null }
$persistenceFailedCount = if ($null -ne $persistenceEvidence -and $null -ne $persistenceEvidence.failed) { @($persistenceEvidence.failed).Count } else { $null }
$dbCheckCount = @($script:DbChecks).Count
$dbFailedCount = @($script:DbChecks | Where-Object { -not $_.pass }).Count

if ($mainExit -eq 0 -and $null -eq $mainCheckCount) {
    $script:Failed = $true
    Write-Host 'FAIL mainUi.evidenceMissing'
}
if ($minExit -eq 0 -and $null -eq $minWindowCheckCount) {
    $script:Failed = $true
    Write-Host 'FAIL minWindow.evidenceMissing'
}
if ($persistExit -eq 0 -and $null -eq $persistenceCheckCount) {
    $script:Failed = $true
    Write-Host 'FAIL persistence.evidenceMissing'
}
if ($null -ne $mainFailedCount -and $mainFailedCount -gt 0) { $script:Failed = $true }
if ($null -ne $minWindowFailedCount -and $minWindowFailedCount -gt 0) { $script:Failed = $true }
if ($null -ne $persistenceFailedCount -and $persistenceFailedCount -gt 0) { $script:Failed = $true }

$summary = [ordered]@{
    task                        = 'T1-03'
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
    firstCloseExitCode          = $firstExitCode
    persistenceCheckExitCode    = $persistExit
    persistenceCheckCount       = $persistenceCheckCount
    persistenceFailedCheckCount = $persistenceFailedCount
    secondCloseExitCode         = $secondExitCode
    dbCheckCount                = $dbCheckCount
    dbFailedCheckCount          = $dbFailedCount
    dbChecks                    = @($script:DbChecks)
    dbProbeAfterMain            = $dbProbeAfterMain.Path
    dbProbeAfterRestart         = $dbProbeAfterRestart.Path
    evidenceFiles               = Get-EvidenceFileList $outputFull
    screenshots                 = @(Get-EvidenceFileList $outputFull | Where-Object { $_ -like '*.png' })
    pass                        = (-not $script:Failed)
}
$summaryPath = Join-Path $outputFull 't1-03-ui-orchestration.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "T1-03 证据摘要：$summaryPath"
Write-Host ($summary | ConvertTo-Json -Depth 8)

if ($script:Failed) { exit 1 }
Write-Host 'T1_03_RELEASE_UI_E2E=PASS'
exit 0
