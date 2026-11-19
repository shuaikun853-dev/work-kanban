# WorkManager T1-02 Release UI/IPC 端到端编排脚本
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
#   pnpm ... (仅 node，不适用)
#
# 步骤：
# 1. 复制 Release EXE 到 D 盘隔离目录并启动（远程调试端口）；
# 2. 运行 inspect-t1-02-ui.mjs：先等待 reload 后的新文档 boot marker、应用壳和
#    IPC 就绪，再以确定性页面状态等待验证项目 loading/空状态/CRUD/错误态/诊断/
#    CSP/窗口最大化；失败时写入页面状态、IPC、异常与截图诊断 JSON；
# 3. 将真实窗口调整为最小支持尺寸 860×640，运行 inspect-t1-02-min-window.mjs；
# 4. 最小窗口脚本最后点击红色关闭圆点并把 12 项断言写入证据 JSON；
#    本脚本验证进程真实退出并汇总主检查/最小窗口的断言数量；
# 5. 输出证据摘要 JSON，任一检查失败退出码为 1。
#
# 统计口径（P3-02 修复）：主检查与最小窗口检查数量直接读取机器可读证据 JSON，
# 不再依赖人工抄写；最小窗口的关闭按钮点击断言与进程退出验证分开记录。
#
# 数据边界：只使用 D:\WorkManager-test-data 下的隔离目录，不触碰 D:\WorkManager。

[CmdletBinding()]
param(
    [string]$ExePath = '',
    [string]$OutputDir = '',
    [int]$Port = 9334
)

$ErrorActionPreference = 'Stop'
$script:Failed = $false

function Resolve-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-EvidenceFileList([string]$Directory) {
    if (-not (Test-Path $Directory)) { return @() }
    return @(Get-ChildItem $Directory -File | Sort-Object Name | Select-Object -ExpandProperty Name)
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
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

$exeInfo = Get-Item $ExePath
$exeSha256 = (Get-FileHash -Path $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = 'D:\WorkManager-test-data\t1-02-ui-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
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

Write-Host "T1-02 UI 验证：exe=$ExePath sha256=$exeSha256 output=$outputFull port=$Port"

# 启动 Release（WebView2 远程调试端口）。
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
$process = Start-Process -FilePath $appExe -WorkingDirectory $appDir -PassThru
Remove-Item Env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue

$deadline = (Get-Date).AddSeconds(40)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    try { $process.Refresh() } catch { break }
    if ($process.HasExited) { break }
    if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
        $hwnd = $process.MainWindowHandle
        break
    }
    Start-Sleep -Milliseconds 250
}

if ($process.HasExited -or $hwnd -eq [IntPtr]::Zero) {
    Write-Host "PRECONDITION_FAILED: Release 主窗口未在超时内出现（exited=$($process.HasExited)）"
    if (-not $process.HasExited) { $process.Kill() }
    exit 2
}

Start-Sleep -Seconds 1
$mainExit = 1
$minExit = 1
try {
    Write-Host '--- 运行 T1-02 主 UI/IPC 检查 ---'
    & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-02-ui.mjs') $Port $outputFull
    $mainExit = $LASTEXITCODE
    if ($mainExit -ne 0) { $script:Failed = $true }

    Write-Host '--- 调整到最小支持窗口 860x640 ---'
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win32Window {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
"@
    $SWP_NOZORDER = 0x0004
    $setSize = [Win32Window]::SetWindowPos($hwnd, [IntPtr]::Zero, 40, 40, 860, 640, $SWP_NOZORDER)
    if (-not $setSize) {
        $script:Failed = $true
        Write-Host 'FAIL minWindow.setWindowPos'
    }
    Start-Sleep -Seconds 2

    Write-Host '--- 运行最小窗口/关闭按钮检查 ---'
    & node (Join-Path $repoRoot 'scripts\verify\inspect-t1-02-min-window.mjs') $Port $outputFull
    $minExit = $LASTEXITCODE
    if ($minExit -ne 0) { $script:Failed = $true }
}
finally {
    # 最小窗口脚本会点击关闭按钮；等待真实退出，超时则清理。
    $exited = $false
    if (-not $process.HasExited) {
        $exited = $process.WaitForExit(20000)
    }
    else {
        $exited = $true
    }
    if (-not $exited) {
        Write-Host 'FAIL closeButton.processDidNotExit'
        $script:Failed = $true
        try { $process.Kill() } catch { }
        try { $process.WaitForExit(5000) | Out-Null } catch { }
    }
}

$exitCodeAfterClose = if ($process.HasExited) { $process.ExitCode } else { $null }
if ($exitCodeAfterClose -ne 0) {
    $script:Failed = $true
    Write-Host "FAIL closeButton.nonZeroExit exitCode=$exitCodeAfterClose"
}

# 汇总机器可读证据中的断言数量，避免“主检查/最小窗口”统计口径依赖人工抄写。
$mainEvidence = Read-JsonFile (Join-Path $outputFull 't1-02-ui-evidence.json')
$minWindowEvidence = Read-JsonFile (Join-Path $outputFull 't1-02-min-window-evidence.json')

$mainCheckCount = if ($null -ne $mainEvidence -and $null -ne $mainEvidence.checks) { @($mainEvidence.checks).Count } else { $null }
$mainFailedCheckCount = if ($null -ne $mainEvidence -and $null -ne $mainEvidence.failed) { @($mainEvidence.failed).Count } else { $null }
$minWindowCheckCount = if ($null -ne $minWindowEvidence -and $null -ne $minWindowEvidence.checks) { @($minWindowEvidence.checks).Count } else { $null }
$minWindowFailedCheckCount = if ($null -ne $minWindowEvidence -and $null -ne $minWindowEvidence.failed) { @($minWindowEvidence.failed).Count } else { $null }

$closeButtonCheckPassed = $null
if ($null -ne $minWindowEvidence -and $null -ne $minWindowEvidence.checks) {
    $closeCheck = @($minWindowEvidence.checks) | Where-Object { $_.name -eq 'minWindow.closeButtonClicked' } | Select-Object -First 1
    if ($null -ne $closeCheck) { $closeButtonCheckPassed = [bool]$closeCheck.pass }
}

if ($mainExit -eq 0 -and $null -eq $mainCheckCount) {
    $script:Failed = $true
    Write-Host 'FAIL mainUi.evidenceMissing'
}
if ($minExit -eq 0 -and $null -eq $minWindowCheckCount) {
    $script:Failed = $true
    Write-Host 'FAIL minWindow.evidenceMissing'
}
if ($minExit -eq 0 -and $closeButtonCheckPassed -ne $true) {
    $script:Failed = $true
    Write-Host "FAIL minWindow.closeButtonEvidenceMissing passed=$closeButtonCheckPassed"
}

$summary = [ordered]@{
    task                        = 'T1-02'
    generatedAt                 = (Get-Date).ToUniversalTime().ToString('o')
    exePath                     = $ExePath
    exeSha256                   = $exeSha256
    exeSizeBytes                = $exeInfo.Length
    outputDir                   = $outputFull
    remoteDebugPort             = $Port
    mainUiCheckExitCode         = $mainExit
    mainUiCheckCount            = $mainCheckCount
    mainUiFailedCheckCount      = $mainFailedCheckCount
    minWindowCheckExit          = $minExit
    minWindowCheckCount         = $minWindowCheckCount
    minWindowFailedCheckCount   = $minWindowFailedCheckCount
    closeButtonCheckPassed      = $closeButtonCheckPassed
    closeExitCode               = $exitCodeAfterClose
    evidenceFiles               = Get-EvidenceFileList $outputFull
    screenshots                 = @(Get-EvidenceFileList $outputFull | Where-Object { $_ -like '*.png' })
    pass                        = (-not $script:Failed)
}
$summaryPath = Join-Path $outputFull 't1-02-ui-orchestration.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "T1-02 证据摘要：$summaryPath"
Write-Host ($summary | ConvertTo-Json -Depth 5)

if ($script:Failed) { exit 1 }
Write-Host 'T1_02_RELEASE_UI_E2E=PASS'
exit 0
