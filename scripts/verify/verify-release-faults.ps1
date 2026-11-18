# =============================================================================
# WorkManager T1-01：Release 启动异常路径（fail-closed）运行时验证
#
# 对应共享任务 task-2（scripts/verify/verify-release-faults.ps1）。
#
# 覆盖检查（a-d）：
#   a. 数据库文件被替换为垃圾内容（非 SQLite）→ 启动失败、出现原生
#      “WorkManager 启动失败” MessageBox、退出码非 0、原文件字节不变；
#   b. data/ 路径被同名文件阻塞 → 启动失败、退出码非 0、阻塞文件不变；
#   c. data/database/work.db 为同名目录 → 启动失败、退出码非 0、目录仍存在；
#   d. 数据库目录 ACL 拒绝当前用户写入（icacls /deny ...:(W)）→ 启动失败、
#      退出码非 0；脚本在 finally 中恢复 ACL（icacls /remove:d）并清理测试目录。
#   e. 汇总 PASS/FAIL，任一 FAIL 时退出码 1。
#
# 约束：
#   - Windows PowerShell 5.1 兼容；必须在 D:\WorkManager-test-data 下运行并清理；
#   - 不得写入正式便携目录 D:\WorkManager；不得使用真实工作数据；
#   - 每个失败用例唯一目录，失败后原文件/阻塞文件/目录保持不变；
#   - 所有等待进程退出/窗口出现的循环都有超时上限，只操作本脚本启动的 PID；
#   - 本文件必须以 UTF-8 with BOM 保存。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1 `
#       -ExePath <repo>\target\release\workmanager.exe `
#       -OutputDir D:\WorkManager-test-data\release-verify-faults-20261117-180000 `
#       -KeepCaseDirectories     # 可选：保留用例沙箱目录便于人工排查（默认清理）
#
# 退出码：0=全部 PASS；1=存在 FAIL；2=前置条件不满足（EXE 不存在 / -OutputDir 非法）。
# =============================================================================
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ExePath = '',
    [string]$OutputDir = '',
    [switch]$KeepCaseDirectories
)

$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory 'VerifyCommon.ps1')

# 默认 EXE 使用仓库相对路径（脚本位于 <repo>\scripts\verify\），避免把开发机的
# 绝对路径写入仓库。
if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $repoRoot = (Resolve-Path (Join-Path $scriptDirectory '..\..')).Path
    $ExePath = Join-Path $repoRoot 'target\release\workmanager.exe'
}

Initialize-VerifyContext -ScriptName 'verify-release-faults'
$script:FaultActiveProcesses = New-Object System.Collections.ArrayList
$script:FaultCaseDirectories = New-Object System.Collections.ArrayList
$script:FaultCaseResults = New-Object System.Collections.ArrayList
$script:FaultIcaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'
$fatalError = ''

# ---------------------------------------------------------------------------
# 本脚本内部辅助函数
# ---------------------------------------------------------------------------
function Invoke-IcaclsCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandArguments
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $script:FaultIcaclsPath @CommandArguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{
            exit_code = $null
            output    = $_.Exception.Message
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{
        exit_code = $exitCode
        output    = $output
    }
}

function New-FaultCaseDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$CaseName
    )

    $caseDir = Join-Path $OutputDir $CaseName
    New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
    [void]$script:FaultCaseDirectories.Add($caseDir)
    Register-VerifyArtifact -Label ('用例沙箱目录 ' + $CaseName) -Path $caseDir -Kind 'directory'
    return $caseDir
}

function Copy-FaultCaseExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$SourceExePath,
        [Parameter(Mandatory = $true)][string]$CaseDir,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$SourceSha256
    )

    $appExe = Join-Path $CaseDir 'WorkManager.exe'
    Copy-Item -LiteralPath $SourceExePath -Destination $appExe -Force
    $copiedSha256 = Get-FileSha256 -Path $appExe
    if ($copiedSha256 -eq $SourceSha256) {
        Add-VerifyCheck -Name ($Prefix + '.exe_copy_sha256_matches') -Status 'PASS' -Detail ('sha256=' + $copiedSha256)
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.exe_copy_sha256_matches') -Status 'FAIL' -Detail ('源=' + [string]$SourceSha256 + '；副本=' + [string]$copiedSha256)
    }
    return $appExe
}

function Get-InitTempFiles {
    param([Parameter(Mandatory = $true)][string]$CaseDir)

    # 首次初始化使用 `.work.db.init-<pid>-<nanos>.tmp` 临时文件；启动失败时不得残留。
    $found = New-Object System.Collections.ArrayList
    $dataRoot = Join-Path $CaseDir 'data'
    if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
        return @()
    }
    try {
        $candidateFiles = @(Get-ChildItem -LiteralPath $dataRoot -Recurse -Force -File -ErrorAction Stop)
    }
    catch {
        return @()
    }
    foreach ($candidate in $candidateFiles) {
        if ($candidate.Name -like '.work.db.init-*') {
            [void]$found.Add($candidate.FullName)
        }
    }
    return @($found)
}

function Add-InitTempFileCheck {
    param(
        [Parameter(Mandatory = $true)][string]$CaseDir,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $initTempFiles = @(Get-InitTempFiles -CaseDir $CaseDir)
    if ($initTempFiles.Count -eq 0) {
        Add-VerifyCheck -Name ($Prefix + '.no_init_temp_files') -Status 'PASS' -Detail '未发现 .work.db.init-* 初始化临时文件残留'
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.no_init_temp_files') -Status 'FAIL' -Detail ('发现初始化临时文件残留：' + ($initTempFiles -join '; '))
    }
}

function Invoke-StartupFailureObservation {
    param(
        [Parameter(Mandatory = $true)][string]$CaseDir,
        [Parameter(Mandatory = $true)][string]$EvidenceDir,
        [Parameter(Mandatory = $true)][string]$Tag,
        [System.Collections.IDictionary]$EnvironmentOverrides = $null
    )

    $appExe = Join-Path $CaseDir 'WorkManager.exe'
    $stdoutLog = Join-Path $EvidenceDir ($Tag + '-stdout.log')
    $stderrLog = Join-Path $EvidenceDir ($Tag + '-stderr.log')
    $startArguments = @{
        ExePath          = $appExe
        WorkingDirectory = $CaseDir
        StdoutLogPath    = $stdoutLog
        StderrLogPath    = $stderrLog
    }
    if ($null -ne $EnvironmentOverrides) {
        $startArguments['EnvironmentOverrides'] = $EnvironmentOverrides
    }
    $started = Start-AppProcess @startArguments
    [void]$script:FaultActiveProcesses.Add($started.process)

    $observation = [ordered]@{
        tag                    = $Tag
        started_at             = (Get-Date).ToString('o')
        dialog_found           = $false
        dialog_title           = $null
        dialog_texts           = @()
        dialog_button_names    = @()
        dialog_screenshot      = $null
        dialog_close_method    = $null
        process_exited         = $false
        exit_code              = $null
        had_to_kill            = $false
        stdout                 = ''
        stderr                 = ''
        observed_window_titles = @()
    }

    $dialog = Wait-FailureDialog -Process $started.process -TimeoutSeconds $script:VerifyDefaultDialogTimeoutSeconds
    if ($dialog.found) {
        $observation.dialog_found = $true
        $observation.dialog_title = $dialog.title
        $observation.dialog_texts = @($dialog.texts)
        $observation.dialog_button_names = @($dialog.button_names)
        Write-VerifyLog -Message ($Tag + ' 检测到启动失败对话框：title=' + [string]$dialog.title + '；elapsed_ms=' + $dialog.elapsed_ms) -Level 'STEP'
        $dialogJsonText = ConvertTo-Json -InputObject ([ordered]@{
                title       = $dialog.title
                class_name  = $dialog.class_name
                button_names = @($dialog.button_names)
                text_details = @($dialog.text_details)
            }) -Depth 8
        Write-VerifyJsonEvidence -Label ($Tag + ' 启动失败对话框 UI 内容') -JsonText $dialogJsonText
        $dialogEvidencePath = Join-Path $EvidenceDir ($Tag + '-dialog.json')
        Save-Utf8TextFile -Path $dialogEvidencePath -Content ($dialogJsonText + "`r`n")
        Register-VerifyArtifact -Label ($Tag + ' 对话框 UI 内容 JSON') -Path $dialogEvidencePath
        if ($dialog.hwnd -ne 0) {
            $dialogScreenshot = Capture-WindowScreenshot -WindowHandle $dialog.hwnd -OutputPath (Join-Path $EvidenceDir ($Tag + '-dialog.png'))
            if ($dialogScreenshot.ok) {
                $observation.dialog_screenshot = $dialogScreenshot.path
                Register-VerifyArtifact -Label ($Tag + ' 对话框截图') -Path $dialogScreenshot.path
            }
            else {
                Write-VerifyLog -Message ($Tag + ' 对话框截图失败（仅证据缺失）：' + [string]$dialogScreenshot.error) -Level 'WARN'
            }
        }
        $closeMethod = Close-FailureDialog -Dialog $dialog -Process $started.process
        $observation.dialog_close_method = $closeMethod
        Write-VerifyLog -Message ($Tag + ' 对话框关闭方式：' + $closeMethod) -Level 'INFO'
        $exitResult = Wait-ProcessExit -Process $started.process -TimeoutSeconds $script:VerifyGracefulExitTimeoutSeconds
        $observation.process_exited = $exitResult.exited
        $observation.exit_code = $exitResult.exit_code
        $observation.had_to_kill = $exitResult.had_to_kill
    }
    else {
        Write-VerifyLog -Message ($Tag + ' 未检测到启动失败对话框：timed_out=' + $dialog.timed_out + '；process_exited=' + $dialog.process_exited + '；exit_code=' + [string]$dialog.exit_code + '；top_windows=' + ((@($dialog.top_window_names)) -join ' | ')) -Level 'FAIL'
        $observation.observed_window_titles = @($dialog.top_window_names)
        if ($dialog.process_exited) {
            $observation.process_exited = $true
            $observation.exit_code = $dialog.exit_code
        }
        else {
            $stopResult = Stop-AppProcess -Process $started.process
            $observation.process_exited = $stopResult.exited
            $observation.exit_code = $stopResult.exit_code
            if ($stopResult.method -like '*Kill*') {
                $observation.had_to_kill = $true
            }
        }
    }
    # 进程退出后统一读取已重定向的 stdout/stderr（Release 为 windows 子系统，
    # 启动日志与 fatal 消息可能为空；捕获成功时作为证据保留）。
    $capturedOutput = Save-AppProcessOutput -Started $started
    $observation.stdout = [string]$capturedOutput.stdout
    $observation.stderr = [string]$capturedOutput.stderr
    $logFiles = @(
        [pscustomobject]@{ label = ($Tag + ' 标准输出日志'); path = $stdoutLog },
        [pscustomobject]@{ label = ($Tag + ' 标准错误日志'); path = $stderrLog }
    )
    foreach ($logFile in $logFiles) {
        if (Test-Path -LiteralPath $logFile.path -PathType Leaf) {
            Register-VerifyArtifact -Label $logFile.label -Path $logFile.path
        }
    }
    Write-VerifyLog -Message ('{0} 进程输出捕获：stdout {1} 字符；stderr {2} 字符；读取错误={3}' -f $Tag, ([string]$capturedOutput.stdout).Length, ([string]$capturedOutput.stderr).Length, [string]$capturedOutput.error) -Level 'INFO'
    $observation.finished_at = (Get-Date).ToString('o')
    return [pscustomobject]$observation
}

function Add-ExpectedFailureChecks {
    param(
        [Parameter(Mandatory = $true)]$Observation,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$ExpectedKeyword
    )

    if ($Observation.dialog_found) {
        Add-VerifyCheck -Name ($Prefix + '.failure_dialog_found') -Status 'PASS' -Detail ('title=' + [string]$Observation.dialog_title + '；texts=' + ((@($Observation.dialog_texts)) -join ' | '))
        if ([string]$Observation.dialog_title -like '*WorkManager 启动失败*') {
            Add-VerifyCheck -Name ($Prefix + '.failure_dialog_title') -Status 'PASS' -Detail ('对话框标题=' + [string]$Observation.dialog_title + '（要求含 “WorkManager 启动失败”）')
        }
        else {
            Add-VerifyCheck -Name ($Prefix + '.failure_dialog_title') -Status 'FAIL' -Detail ('对话框标题=' + [string]$Observation.dialog_title + '（要求含 “WorkManager 启动失败”）')
        }
        $dialogTextsJoined = (@($Observation.dialog_texts)) -join ' | '
        if ($dialogTextsJoined -like ('*' + $ExpectedKeyword + '*')) {
            Add-VerifyCheck -Name ($Prefix + '.failure_dialog_message') -Status 'PASS' -Detail ('对话框文本包含预期关键字 “' + $ExpectedKeyword + '”：' + $dialogTextsJoined)
        }
        else {
            Add-VerifyCheck -Name ($Prefix + '.failure_dialog_message') -Status 'FAIL' -Detail ('对话框文本未包含预期关键字 “' + $ExpectedKeyword + '”：' + $dialogTextsJoined)
        }
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.failure_dialog_found') -Status 'FAIL' -Detail ('未出现 “WorkManager 启动失败” 对话框；process_exited=' + [string]$Observation.process_exited + '；exit_code=' + [string]$Observation.exit_code + '；observed_windows=' + ((@($Observation.observed_window_titles)) -join ' | '))
        Add-VerifyCheck -Name ($Prefix + '.failure_dialog_title') -Status 'FAIL' -Detail '未找到对话框，无法核对标题'
        Add-VerifyCheck -Name ($Prefix + '.failure_dialog_message') -Status 'FAIL' -Detail '未找到对话框，无法核对错误消息'
    }

    if ($Observation.process_exited) {
        Add-VerifyCheck -Name ($Prefix + '.process_exited') -Status 'PASS' -Detail ('对话框关闭后进程已退出；close_method=' + [string]$Observation.dialog_close_method)
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.process_exited') -Status 'FAIL' -Detail '进程在超时后仍未退出'
    }
    if ($null -ne $Observation.exit_code -and $Observation.exit_code -ne 0) {
        Add-VerifyCheck -Name ($Prefix + '.exit_code_nonzero') -Status 'PASS' -Detail ('exit_code=' + [string]$Observation.exit_code)
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.exit_code_nonzero') -Status 'FAIL' -Detail ('exit_code=' + [string]$Observation.exit_code + '（要求非 0）')
    }
    if ($Observation.had_to_kill) {
        Add-VerifyCheck -Name ($Prefix + '.dialog_dismissed_cleanly') -Status 'WARN' -Detail '对话框关闭后进程未及时退出，验证脚本强制结束进程（退出码可能不可信）'
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.dialog_dismissed_cleanly') -Status 'PASS' -Detail '对话框关闭后应用自行退出，未强制结束'
    }
    $stderrText = ([string]$Observation.stderr).Trim()
    if ([string]::IsNullOrWhiteSpace($stderrText)) {
        Add-VerifyCheck -Name ($Prefix + '.stderr_output') -Status 'INFO' -Detail '未捕获到 stderr 输出（Release 为 windows 子系统或输出不可重定向，不构成失败）'
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.stderr_output') -Status 'INFO' -Detail ('stderr（启动日志证据）=' + $stderrText)
    }
}

# ===========================================================================
# 主流程
# ===========================================================================
Write-VerifySection 'WorkManager T1-01 Release 启动异常路径（fail-closed）验证（task-2）'

# --- 前置条件 1：Release EXE ---
$resolvedExe = Resolve-ReleaseExePath -ExePath $ExePath
if ($null -eq $resolvedExe) {
    Write-Host ''
    Write-Host '结论：无法开始验证（Release EXE 不存在或 -ExePath 无效）。退出码 2。'
    exit 2
}
$ExePath = $resolvedExe

# --- 前置条件 2：输出目录 ---
$resolvedOutputDir = Resolve-VerifyOutputDir -OutputDir $OutputDir
if ($null -eq $resolvedOutputDir) {
    Write-Host ''
    Write-Host '结论：无法开始验证（-OutputDir 不合法）。退出码 2。'
    exit 2
}
$OutputDir = $resolvedOutputDir
$evidenceDir = Join-Path $OutputDir 'evidence'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$exeSizeBytes = Get-FileSizeBytes -Path $ExePath
$exeSha256 = Get-FileSha256 -Path $ExePath
$pythonInfo = Get-PythonExecutable

Write-VerifySection '0. 环境与 Release EXE 记录'
Write-VerifyLog -Message ('Release EXE：' + $ExePath) -Level 'INFO'
Write-VerifyLog -Message ('大小（字节）：' + [string]$exeSizeBytes) -Level 'INFO'
Write-VerifyLog -Message ('SHA-256：' + [string]$exeSha256) -Level 'INFO'
Write-VerifyLog -Message ('输出目录：' + $OutputDir) -Level 'INFO'
Write-VerifyLog -Message ('PowerShell：' + $PSVersionTable.PSVersion.ToString() + '，OS：' + [System.Environment]::OSVersion.VersionString) -Level 'INFO'
if ($null -ne $pythonInfo) {
    Write-VerifyLog -Message ('python（本脚本不强制依赖）：' + $pythonInfo.path + ' ' + $pythonInfo.version) -Level 'INFO'
}
else {
    Write-VerifyLog -Message 'python 不可用（本脚本不需要 python，仅记录环境）' -Level 'WARN'
}
Add-VerifyCheck -Name 'precondition.release_exe' -Status 'INFO' -Detail ('path=' + $ExePath + '；size_bytes=' + [string]$exeSizeBytes + '；sha256=' + [string]$exeSha256)
Add-VerifyCheck -Name 'precondition.output_dir' -Status 'INFO' -Detail $OutputDir
Add-VerifyCheck -Name 'precondition.current_identity' -Status 'INFO' -Detail ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
if (Test-Path -LiteralPath $script:FaultIcaclsPath -PathType Leaf) {
    Add-VerifyCheck -Name 'precondition.icacls_available' -Status 'PASS' -Detail $script:FaultIcaclsPath
}
else {
    Add-VerifyCheck -Name 'precondition.icacls_available' -Status 'FAIL' -Detail ('未找到 icacls：' + $script:FaultIcaclsPath)
}

try {
    # =======================================================================
    # 用例 A：数据库文件被替换为垃圾内容（非 SQLite）
    # =======================================================================
    Write-VerifySection '用例 A：数据库文件为非 SQLite 垃圾内容 → 启动必须失败且原文件不变'
    $caseName = 'fault-corrupt-db'
    $caseDir = New-FaultCaseDirectory -OutputDir $OutputDir -CaseName $caseName
    $appExe = Copy-FaultCaseExecutable -SourceExePath $ExePath -CaseDir $caseDir -Prefix 'fault.corrupt_db' -SourceSha256 $exeSha256

    $databaseDirectory = Join-Path $caseDir 'data\database'
    New-Item -ItemType Directory -Path $databaseDirectory -Force | Out-Null
    $databasePath = Join-Path $databaseDirectory 'work.db'
    $markerText = 'NOT-A-SQLITE-DB: WorkManager fault-injection fixture (fictitious data). '
    $markerBytes = [System.Text.Encoding]::ASCII.GetBytes($markerText)
    $garbageBytes = New-Object byte[] 1024
    for ($byteIndex = 0; $byteIndex -lt $garbageBytes.Length; $byteIndex++) {
        if ($byteIndex -lt $markerBytes.Length) {
            $garbageBytes[$byteIndex] = $markerBytes[$byteIndex]
        }
        else {
            $garbageBytes[$byteIndex] = [byte](65 + ($byteIndex % 26))
        }
    }
    [System.IO.File]::WriteAllBytes($databasePath, $garbageBytes)
    $corruptHashBefore = Get-FileSha256 -Path $databasePath
    $corruptSizeBefore = Get-FileSizeBytes -Path $databasePath
    Write-VerifyLog -Message ('已写入非 SQLite 垃圾数据库文件：' + $databasePath + '；size=' + [string]$corruptSizeBefore + '；sha256=' + [string]$corruptHashBefore) -Level 'STEP'
    Add-VerifyCheck -Name 'fault.corrupt_db.fixture_created' -Status 'PASS' -Detail ('size_bytes=' + [string]$corruptSizeBefore + '；sha256=' + [string]$corruptHashBefore + '；内容标记=' + $markerText.Trim())

    $corruptObservation = Invoke-StartupFailureObservation -CaseDir $caseDir -EvidenceDir $evidenceDir -Tag 'fault-corrupt-db'
    Add-ExpectedFailureChecks -Observation $corruptObservation -Prefix 'fault.corrupt_db' -ExpectedKeyword '数据库'
    Add-InitTempFileCheck -CaseDir $caseDir -Prefix 'fault.corrupt_db'

    if (Test-Path -LiteralPath $databasePath -PathType Leaf) {
        Add-VerifyCheck -Name 'fault.corrupt_db.original_still_file' -Status 'PASS' -Detail ('原数据库文件仍存在：' + $databasePath)
    }
    else {
        Add-VerifyCheck -Name 'fault.corrupt_db.original_still_file' -Status 'FAIL' -Detail ('原数据库文件已不存在：' + $databasePath)
    }
    $corruptHashAfter = Get-FileSha256 -Path $databasePath
    $corruptSizeAfter = Get-FileSizeBytes -Path $databasePath
    if (($corruptHashAfter -eq $corruptHashBefore) -and ($corruptSizeAfter -eq $corruptSizeBefore)) {
        Add-VerifyCheck -Name 'fault.corrupt_db.original_bytes_unchanged' -Status 'PASS' -Detail ('size=' + [string]$corruptSizeAfter + '；sha256=' + [string]$corruptHashAfter)
    }
    else {
        Add-VerifyCheck -Name 'fault.corrupt_db.original_bytes_unchanged' -Status 'FAIL' -Detail ('原文件被修改：before size=' + [string]$corruptSizeBefore + ' sha256=' + [string]$corruptHashBefore + '；after size=' + [string]$corruptSizeAfter + ' sha256=' + [string]$corruptHashAfter)
    }
    $corruptDirSnapshot = Get-DirectorySnapshot -Path $databaseDirectory -MaxDepth 2 -MaxEntries 50
    $corruptDirSnapshotPath = Join-Path $evidenceDir 'fault-corrupt-db-database-dir-snapshot.json'
    Save-VerifyJsonFile -Path $corruptDirSnapshotPath -Object $corruptDirSnapshot -Depth 10 | Out-Null
    Register-VerifyArtifact -Label 'fault-corrupt-db 数据库目录快照' -Path $corruptDirSnapshotPath
    # `.work.db.init.lock` 是审计 P2 修复引入的跨进程初始化锁文件（仅含 PID/时间戳诊断），
    # 属于应用的持久锁文件，不是空库或临时库，不应计为“新增数据库文件”。
    $allowedDatabaseEntries = @('work.db', '.work.db.init.lock')
    $unexpectedDbEntries = @($corruptDirSnapshot.entries | Where-Object { $allowedDatabaseEntries -notcontains $_.relative_path })
    if ($unexpectedDbEntries.Count -eq 0) {
        Add-VerifyCheck -Name 'fault.corrupt_db.no_new_database_files' -Status 'PASS' -Detail '数据库目录中除原 work.db 与初始化锁文件外没有新增文件（未创建空库/临时库）'
    }
    else {
        Add-VerifyCheck -Name 'fault.corrupt_db.no_new_database_files' -Status 'WARN' -Detail ('数据库目录出现额外条目：' + (($unexpectedDbEntries | ForEach-Object { $_.relative_path + '(' + $_.size_bytes + ')' }) -join ', '))
    }
    [void]$script:FaultCaseResults.Add([ordered]@{
            case                 = $caseName
            directory            = $caseDir
            database_path        = $databasePath
            database_sha256_before = $corruptHashBefore
            database_sha256_after  = $corruptHashAfter
            database_size_before   = $corruptSizeBefore
            database_size_after    = $corruptSizeAfter
            dialog_title         = $corruptObservation.dialog_title
            dialog_texts         = $corruptObservation.dialog_texts
            exit_code            = $corruptObservation.exit_code
        })

    # =======================================================================
    # 用例 A2：已存在的 0 字节 work.db（审计 P1 修复）
    # =======================================================================
    Write-VerifySection '用例 A2：已存在 0 字节 work.db → 启动必须失败且原文件不变'
    $caseName = 'fault-zero-byte-db'
    $caseDir = New-FaultCaseDirectory -OutputDir $OutputDir -CaseName $caseName
    $appExe = Copy-FaultCaseExecutable -SourceExePath $ExePath -CaseDir $caseDir -Prefix 'fault.zero_byte_db' -SourceSha256 $exeSha256
    $zeroByteDatabaseDirectory = Join-Path $caseDir 'data\database'
    New-Item -ItemType Directory -Path $zeroByteDatabaseDirectory -Force | Out-Null
    $zeroByteDatabasePath = Join-Path $zeroByteDatabaseDirectory 'work.db'
    [System.IO.File]::WriteAllBytes($zeroByteDatabasePath, (New-Object byte[] 0))
    $zeroByteHashBefore = Get-FileSha256 -Path $zeroByteDatabasePath
    $zeroByteSizeBefore = Get-FileSizeBytes -Path $zeroByteDatabasePath
    Write-VerifyLog -Message ('已写入 0 字节 work.db：' + $zeroByteDatabasePath + '；size=' + [string]$zeroByteSizeBefore + '；sha256=' + [string]$zeroByteHashBefore) -Level 'STEP'
    Add-VerifyCheck -Name 'fault.zero_byte_db.fixture_created' -Status 'PASS' -Detail ('size_bytes=' + [string]$zeroByteSizeBefore + '；sha256=' + [string]$zeroByteHashBefore + '；期望 size=0')

    $zeroByteObservation = Invoke-StartupFailureObservation -CaseDir $caseDir -EvidenceDir $evidenceDir -Tag 'fault-zero-byte-db'
    Add-ExpectedFailureChecks -Observation $zeroByteObservation -Prefix 'fault.zero_byte_db' -ExpectedKeyword '0 字节'
    Add-InitTempFileCheck -CaseDir $caseDir -Prefix 'fault.zero_byte_db'

    if (Test-Path -LiteralPath $zeroByteDatabasePath -PathType Leaf) {
        Add-VerifyCheck -Name 'fault.zero_byte_db.original_still_file' -Status 'PASS' -Detail ('原 0 字节数据库文件仍存在：' + $zeroByteDatabasePath)
    }
    else {
        Add-VerifyCheck -Name 'fault.zero_byte_db.original_still_file' -Status 'FAIL' -Detail ('原 0 字节数据库文件已不存在：' + $zeroByteDatabasePath)
    }
    $zeroByteHashAfter = Get-FileSha256 -Path $zeroByteDatabasePath
    $zeroByteSizeAfter = Get-FileSizeBytes -Path $zeroByteDatabasePath
    if (($zeroByteHashAfter -eq $zeroByteHashBefore) -and ($zeroByteSizeAfter -eq $zeroByteSizeBefore) -and ($zeroByteSizeAfter -eq 0)) {
        Add-VerifyCheck -Name 'fault.zero_byte_db.original_bytes_unchanged' -Status 'PASS' -Detail ('size=' + [string]$zeroByteSizeAfter + '；sha256=' + [string]$zeroByteHashAfter + '；文件保持 0 字节')
    }
    else {
        Add-VerifyCheck -Name 'fault.zero_byte_db.original_bytes_unchanged' -Status 'FAIL' -Detail ('原 0 字节文件被修改：before size=' + [string]$zeroByteSizeBefore + ' sha256=' + [string]$zeroByteHashBefore + '；after size=' + [string]$zeroByteSizeAfter + ' sha256=' + [string]$zeroByteHashAfter)
    }
    $zeroByteWalPath = $zeroByteDatabasePath + '-wal'
    $zeroByteShmPath = $zeroByteDatabasePath + '-shm'
    if ((-not (Test-Path -LiteralPath $zeroByteWalPath)) -and (-not (Test-Path -LiteralPath $zeroByteShmPath))) {
        Add-VerifyCheck -Name 'fault.zero_byte_db.no_sidecars_created' -Status 'PASS' -Detail '未创建 WAL/SHM 文件（未把 0 字节文件交给 SQLite 打开）'
    }
    else {
        Add-VerifyCheck -Name 'fault.zero_byte_db.no_sidecars_created' -Status 'FAIL' -Detail ('发现 WAL/SHM 文件：wal=' + [string](Test-Path -LiteralPath $zeroByteWalPath) + '；shm=' + [string](Test-Path -LiteralPath $zeroByteShmPath))
    }
    $zeroByteDirSnapshot = Get-DirectorySnapshot -Path $zeroByteDatabaseDirectory -MaxDepth 2 -MaxEntries 50
    $zeroByteDirSnapshotPath = Join-Path $evidenceDir 'fault-zero-byte-db-database-dir-snapshot.json'
    Save-VerifyJsonFile -Path $zeroByteDirSnapshotPath -Object $zeroByteDirSnapshot -Depth 10 | Out-Null
    Register-VerifyArtifact -Label 'fault-zero-byte-db 数据库目录快照' -Path $zeroByteDirSnapshotPath
    $zeroByteAllowedEntries = @('work.db', '.work.db.init.lock')
    $zeroByteUnexpectedEntries = @($zeroByteDirSnapshot.entries | Where-Object { $zeroByteAllowedEntries -notcontains $_.relative_path })
    if ($zeroByteUnexpectedEntries.Count -eq 0) {
        Add-VerifyCheck -Name 'fault.zero_byte_db.no_schema_created' -Status 'PASS' -Detail '数据库目录中只有原 work.db（0 字节）与初始化锁文件，没有生成任何 schema/数据库文件'
    }
    else {
        Add-VerifyCheck -Name 'fault.zero_byte_db.no_schema_created' -Status 'FAIL' -Detail ('数据库目录出现额外条目：' + (($zeroByteUnexpectedEntries | ForEach-Object { $_.relative_path + '(' + $_.size_bytes + ')' }) -join ', '))
    }
    [void]$script:FaultCaseResults.Add([ordered]@{
            case                   = $caseName
            directory              = $caseDir
            database_path          = $zeroByteDatabasePath
            database_sha256_before = $zeroByteHashBefore
            database_sha256_after  = $zeroByteHashAfter
            database_size_before   = $zeroByteSizeBefore
            database_size_after    = $zeroByteSizeAfter
            dialog_title           = $zeroByteObservation.dialog_title
            dialog_texts           = $zeroByteObservation.dialog_texts
            exit_code              = $zeroByteObservation.exit_code
        })

    # =======================================================================
    # 用例 B：data/ 路径被同名文件阻塞
    # =======================================================================
    Write-VerifySection '用例 B：data/ 被同名文件阻塞 → 启动必须失败且阻塞文件不变'
    $caseName = 'fault-data-blocked-by-file'
    $caseDir = New-FaultCaseDirectory -OutputDir $OutputDir -CaseName $caseName
    $appExe = Copy-FaultCaseExecutable -SourceExePath $ExePath -CaseDir $caseDir -Prefix 'fault.data_blocker' -SourceSha256 $exeSha256
    $dataBlockerPath = Join-Path $caseDir 'data'
    $blockerText = 'WorkManager fault-injection blocker file (fictitious data).' + "`r`n" + 'This regular file intentionally blocks the data/ directory.' + "`r`n"
    Save-Utf8TextFile -Path $dataBlockerPath -Content $blockerText
    $blockerHashBefore = Get-FileSha256 -Path $dataBlockerPath
    $blockerSizeBefore = Get-FileSizeBytes -Path $dataBlockerPath
    Write-VerifyLog -Message ('已创建阻塞文件：' + $dataBlockerPath + '；size=' + [string]$blockerSizeBefore + '；sha256=' + [string]$blockerHashBefore) -Level 'STEP'
    Add-VerifyCheck -Name 'fault.data_blocker.fixture_created' -Status 'PASS' -Detail ('size_bytes=' + [string]$blockerSizeBefore + '；sha256=' + [string]$blockerHashBefore)

    $blockerObservation = Invoke-StartupFailureObservation -CaseDir $caseDir -EvidenceDir $evidenceDir -Tag 'fault-data-blocked-by-file'
    Add-ExpectedFailureChecks -Observation $blockerObservation -Prefix 'fault.data_blocker' -ExpectedKeyword '便携数据目录'
    Add-InitTempFileCheck -CaseDir $caseDir -Prefix 'fault.data_blocker'

    if (Test-Path -LiteralPath $dataBlockerPath -PathType Leaf) {
        Add-VerifyCheck -Name 'fault.data_blocker.still_regular_file' -Status 'PASS' -Detail ('阻塞文件仍为普通文件：' + $dataBlockerPath)
    }
    else {
        Add-VerifyCheck -Name 'fault.data_blocker.still_regular_file' -Status 'FAIL' -Detail ('阻塞文件已不存在或不再是普通文件：' + $dataBlockerPath)
    }
    $blockerHashAfter = Get-FileSha256 -Path $dataBlockerPath
    $blockerSizeAfter = Get-FileSizeBytes -Path $dataBlockerPath
    if (($blockerHashAfter -eq $blockerHashBefore) -and ($blockerSizeAfter -eq $blockerSizeBefore)) {
        Add-VerifyCheck -Name 'fault.data_blocker.original_bytes_unchanged' -Status 'PASS' -Detail ('size=' + [string]$blockerSizeAfter + '；sha256=' + [string]$blockerHashAfter)
    }
    else {
        Add-VerifyCheck -Name 'fault.data_blocker.original_bytes_unchanged' -Status 'FAIL' -Detail ('阻塞文件被修改：before size=' + [string]$blockerSizeBefore + ' sha256=' + [string]$blockerHashBefore + '；after size=' + [string]$blockerSizeAfter + ' sha256=' + [string]$blockerHashAfter)
    }
    [void]$script:FaultCaseResults.Add([ordered]@{
            case               = $caseName
            directory          = $caseDir
            blocker_path       = $dataBlockerPath
            blocker_sha256_before = $blockerHashBefore
            blocker_sha256_after  = $blockerHashAfter
            dialog_title       = $blockerObservation.dialog_title
            dialog_texts       = $blockerObservation.dialog_texts
            exit_code          = $blockerObservation.exit_code
        })

    # =======================================================================
    # 用例 C：data/database/work.db 为同名目录
    # =======================================================================
    Write-VerifySection '用例 C：work.db 为同名目录 → 启动必须失败且目录仍存在'
    $caseName = 'fault-db-is-directory'
    $caseDir = New-FaultCaseDirectory -OutputDir $OutputDir -CaseName $caseName
    $appExe = Copy-FaultCaseExecutable -SourceExePath $ExePath -CaseDir $caseDir -Prefix 'fault.db_directory' -SourceSha256 $exeSha256
    $databaseDirectory = Join-Path $caseDir 'data\database'
    New-Item -ItemType Directory -Path $databaseDirectory -Force | Out-Null
    $databasePath = Join-Path $databaseDirectory 'work.db'
    New-Item -ItemType Directory -Path $databasePath -Force | Out-Null
    Add-VerifyCheck -Name 'fault.db_directory.fixture_created' -Status 'PASS' -Detail ('已创建同名目录：' + $databasePath)

    $dbDirectoryObservation = Invoke-StartupFailureObservation -CaseDir $caseDir -EvidenceDir $evidenceDir -Tag 'fault-db-is-directory'
    Add-ExpectedFailureChecks -Observation $dbDirectoryObservation -Prefix 'fault.db_directory' -ExpectedKeyword '数据库'
    Add-InitTempFileCheck -CaseDir $caseDir -Prefix 'fault.db_directory'

    if (Test-Path -LiteralPath $databasePath -PathType Container) {
        Add-VerifyCheck -Name 'fault.db_directory.still_directory' -Status 'PASS' -Detail ('work.db 仍为目录：' + $databasePath)
    }
    else {
        Add-VerifyCheck -Name 'fault.db_directory.still_directory' -Status 'FAIL' -Detail ('work.db 目录已不存在或不再是目录：' + $databasePath)
    }
    $dbDirectorySnapshot = Get-DirectorySnapshot -Path $databasePath -MaxDepth 2 -MaxEntries 50
    if (@($dbDirectorySnapshot.entries).Count -eq 0) {
        Add-VerifyCheck -Name 'fault.db_directory.not_replaced_by_database' -Status 'PASS' -Detail 'work.db 目录内没有写入任何条目（未覆盖/替换为数据库文件）'
    }
    else {
        Add-VerifyCheck -Name 'fault.db_directory.not_replaced_by_database' -Status 'FAIL' -Detail ('work.db 目录内出现条目：' + ((@($dbDirectorySnapshot.entries) | ForEach-Object { $_.relative_path }) -join ', '))
    }
    [void]$script:FaultCaseResults.Add([ordered]@{
            case          = $caseName
            directory     = $caseDir
            blocked_path  = $databasePath
            dialog_title  = $dbDirectoryObservation.dialog_title
            dialog_texts  = $dbDirectoryObservation.dialog_texts
            exit_code     = $dbDirectoryObservation.exit_code
        })

    # =======================================================================
    # 用例 D：数据库目录 ACL 拒绝当前用户写入（finally 中必须恢复 ACL）
    # =======================================================================
    Write-VerifySection '用例 D：数据库目录 ACL 拒绝写入 → 启动必须失败（finally 恢复 ACL）'
    $caseName = 'fault-acl-denied'
    $caseDir = New-FaultCaseDirectory -OutputDir $OutputDir -CaseName $caseName
    $appExe = Copy-FaultCaseExecutable -SourceExePath $ExePath -CaseDir $caseDir -Prefix 'fault.acl_denied' -SourceSha256 $exeSha256
    $databaseDirectory = Join-Path $caseDir 'data\database'
    New-Item -ItemType Directory -Path $databaseDirectory -Force | Out-Null
    $databasePath = Join-Path $databaseDirectory 'work.db'
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $denyArgument = $currentIdentity + ':(W)'
    $aclObservation = $null
    $denyAppliedOk = $false
    $denyEnforced = $false
    $denyRemovedOk = $false
    $writeRestoredOk = $false
    $aclCaseFailed = $false

    try {
        $denyResult = Invoke-IcaclsCommand -CommandArguments @($databaseDirectory, '/deny', $denyArgument)
        Write-VerifyLog -Message ('icacls /deny ' + $denyArgument + ' ' + $databaseDirectory + '：exit_code=' + [string]$denyResult.exit_code + '；' + $denyResult.output) -Level 'STEP'
        if ($denyResult.exit_code -eq 0) {
            $denyAppliedOk = $true
            Add-VerifyCheck -Name 'fault.acl_denied.deny_applied' -Status 'PASS' -Detail ('icacls /deny ' + $denyArgument + ' 执行成功')
        }
        else {
            Add-VerifyCheck -Name 'fault.acl_denied.deny_applied' -Status 'FAIL' -Detail ('icacls /deny 失败：exit_code=' + [string]$denyResult.exit_code + '；' + $denyResult.output)
        }

        # 自检：确认 ACL 确实阻止当前用户写入（否则该用例的前提不成立）
        $aclProbeFile = Join-Path $databaseDirectory 'acl-write-probe.tmp'
        try {
            [System.IO.File]::WriteAllText($aclProbeFile, 'acl probe')
        }
        catch {
            $denyEnforced = $true
        }
        if (Test-Path -LiteralPath $aclProbeFile) {
            try {
                Remove-Item -LiteralPath $aclProbeFile -Force -ErrorAction Stop
            }
            catch {
            }
        }
        if ($denyEnforced) {
            Add-VerifyCheck -Name 'fault.acl_denied.deny_enforced' -Status 'PASS' -Detail 'ACL 实际阻止当前用户写入数据库目录（自检探测文件创建失败）'
        }
        else {
            Add-VerifyCheck -Name 'fault.acl_denied.deny_enforced' -Status 'FAIL' -Detail 'ACL 未能阻止当前用户写入数据库目录，用例前提不成立；已跳过应用启动观测'
        }

        if ($denyAppliedOk -and $denyEnforced) {
            $aclObservation = Invoke-StartupFailureObservation -CaseDir $caseDir -EvidenceDir $evidenceDir -Tag 'fault-acl-denied'
            Add-ExpectedFailureChecks -Observation $aclObservation -Prefix 'fault.acl_denied' -ExpectedKeyword '便携数据目录'
        }
        else {
            Add-VerifyCheck -Name 'fault.acl_denied.failure_dialog_found' -Status 'FAIL' -Detail 'ACL 前提不成立，未能验证应用启动失败行为'
        }
    }
    catch {
        $aclCaseFailed = $true
        Write-VerifyLog -Message ('用例 D ACL 执行异常：' + $_.Exception.Message) -Level 'FAIL'
        Add-VerifyCheck -Name 'fault.acl_denied.case_exception' -Status 'FAIL' -Detail $_.Exception.Message
    }
    finally {
        # 无论前面发生什么，都必须恢复 ACL，并验证恢复后当前用户可以写入。
        $removeResult = Invoke-IcaclsCommand -CommandArguments @($databaseDirectory, '/remove:d', $currentIdentity)
        Write-VerifyLog -Message ('icacls /remove:d ' + $currentIdentity + ' ' + $databaseDirectory + '：exit_code=' + [string]$removeResult.exit_code + '；' + $removeResult.output) -Level 'STEP'
        if ($removeResult.exit_code -eq 0) {
            $denyRemovedOk = $true
            Add-VerifyCheck -Name 'fault.acl_denied.deny_removed_in_finally' -Status 'PASS' -Detail ('icacls /remove:d ' + $currentIdentity + ' 执行成功（finally 中恢复）')
        }
        else {
            Add-VerifyCheck -Name 'fault.acl_denied.deny_removed_in_finally' -Status 'FAIL' -Detail ('icacls /remove:d 失败：exit_code=' + [string]$removeResult.exit_code + '；' + $removeResult.output + '；请人工执行 icacls "' + $databaseDirectory + '" /remove:d ' + $currentIdentity)
        }

        $restoreProbeFile = Join-Path $databaseDirectory 'acl-restore-probe.tmp'
        try {
            [System.IO.File]::WriteAllText($restoreProbeFile, 'acl restore probe')
            $writeRestoredOk = $true
        }
        catch {
            $writeRestoredOk = $false
        }
        if (Test-Path -LiteralPath $restoreProbeFile) {
            try {
                Remove-Item -LiteralPath $restoreProbeFile -Force -ErrorAction Stop
            }
            catch {
            }
        }
        if ($writeRestoredOk) {
            Add-VerifyCheck -Name 'fault.acl_denied.write_restored' -Status 'PASS' -Detail 'ACL 恢复后当前用户可正常写入数据库目录'
        }
        else {
            Add-VerifyCheck -Name 'fault.acl_denied.write_restored' -Status 'FAIL' -Detail 'ACL 恢复后当前用户仍无法写入数据库目录，请人工检查 ACL'
        }

        if (Test-Path -LiteralPath $databaseDirectory -PathType Container) {
            Add-VerifyCheck -Name 'fault.acl_denied.database_dir_still_exists' -Status 'PASS' -Detail ('数据库目录仍存在：' + $databaseDirectory)
        }
        else {
            Add-VerifyCheck -Name 'fault.acl_denied.database_dir_still_exists' -Status 'FAIL' -Detail ('数据库目录已不存在：' + $databaseDirectory)
        }
        if (Test-Path -LiteralPath $databasePath) {
            Add-VerifyCheck -Name 'fault.acl_denied.no_database_created' -Status 'FAIL' -Detail ('ACL 拒绝写入时仍出现了 work.db：' + $databasePath)
        }
        else {
            Add-VerifyCheck -Name 'fault.acl_denied.no_database_created' -Status 'PASS' -Detail 'ACL 拒绝写入时未创建 work.db'
        }
        $aclDirectorySnapshot = Get-DirectorySnapshot -Path $databaseDirectory -MaxDepth 2 -MaxEntries 50
        $aclSnapshotPath = Join-Path $evidenceDir 'fault-acl-denied-database-dir-snapshot.json'
        Save-VerifyJsonFile -Path $aclSnapshotPath -Object $aclDirectorySnapshot -Depth 10 | Out-Null
        Register-VerifyArtifact -Label 'fault-acl-denied 数据库目录快照' -Path $aclSnapshotPath
        Add-InitTempFileCheck -CaseDir $caseDir -Prefix 'fault.acl_denied'
        [void]$script:FaultCaseResults.Add([ordered]@{
                case                = $caseName
                directory           = $caseDir
                database_directory  = $databaseDirectory
                denied_identity     = $currentIdentity
                deny_applied        = $denyAppliedOk
                deny_enforced       = $denyEnforced
                deny_removed        = $denyRemovedOk
                write_restored      = $writeRestoredOk
                case_exception      = $aclCaseFailed
                dialog_title        = $null
                dialog_texts        = @()
                exit_code           = $null
            })
        if ($null -ne $aclObservation) {
            $script:FaultCaseResults[$script:FaultCaseResults.Count - 1].dialog_title = $aclObservation.dialog_title
            $script:FaultCaseResults[$script:FaultCaseResults.Count - 1].dialog_texts = $aclObservation.dialog_texts
            $script:FaultCaseResults[$script:FaultCaseResults.Count - 1].exit_code = $aclObservation.exit_code
        }
    }
}
catch {
    $fatalError = $_.Exception.Message
    Write-VerifyLog -Message ('未预期异常：' + $fatalError) -Level 'FAIL'
    Write-VerifyLog -Message ('异常位置：' + $_.ScriptStackTrace) -Level 'FAIL'
    Add-VerifyCheck -Name 'script.unexpected_exception' -Status 'FAIL' -Detail $fatalError
}
finally {
    # --- 安全清理：终止遗留在运行的被测进程（只处理本脚本启动的 PID）---
    Write-VerifySection '清理'
    $lingeringProcessCount = 0
    foreach ($trackedProcess in @($script:FaultActiveProcesses)) {
        try {
            if ($null -ne $trackedProcess -and -not $trackedProcess.HasExited) {
                $lingeringProcessCount = $lingeringProcessCount + 1
                Write-VerifyLog -Message ('清理：强制结束仍存活的被测进程 PID=' + $trackedProcess.Id) -Level 'WARN'
                $trackedProcess.Kill()
                [void]$trackedProcess.WaitForExit($script:VerifyKillTimeoutSeconds * 1000)
            }
        }
        catch {
        }
    }
    if ($lingeringProcessCount -eq 0) {
        Add-VerifyCheck -Name 'cleanup.process_cleanup' -Status 'PASS' -Detail '没有遗留的被测进程'
    }
    else {
        Add-VerifyCheck -Name 'cleanup.process_cleanup' -Status 'WARN' -Detail ('强制结束了 ' + $lingeringProcessCount + ' 个遗留进程')
    }

    # --- 清理用例沙箱目录（证据目录保留）---
    if ($KeepCaseDirectories) {
        Add-VerifyCheck -Name 'cleanup.case_directories' -Status 'INFO' -Detail ('-KeepCaseDirectories 已指定，保留用例沙箱：' + (@($script:FaultCaseDirectories) -join '; '))
    }
    else {
        $failedCleanupCount = 0
        foreach ($caseDirectoryPath in @($script:FaultCaseDirectories)) {
            $removedOk = Remove-VerifyCaseDirectory -Path $caseDirectoryPath -Label (Split-Path -Leaf $caseDirectoryPath)
            if (-not $removedOk) {
                $failedCleanupCount = $failedCleanupCount + 1
            }
        }
        if ($failedCleanupCount -eq 0) {
            Add-VerifyCheck -Name 'cleanup.case_directories' -Status 'PASS' -Detail '已删除本脚本创建的用例沙箱目录（证据在 evidence/ 与 summary/report 中保留）'
        }
        else {
            Add-VerifyCheck -Name 'cleanup.case_directories' -Status 'WARN' -Detail ($failedCleanupCount + ' 个用例沙箱目录未能完全删除，请人工检查 D:\WorkManager-test-data')
        }
    }
    Add-VerifyCheck -Name 'cleanup.evidence_retained' -Status 'INFO' -Detail ('证据与汇总保留在：' + $OutputDir)
}

# ===========================================================================
# 汇总
# ===========================================================================
$metadata = [ordered]@{
    release_exe = [ordered]@{
        path       = $ExePath
        size_bytes = $exeSizeBytes
        sha256     = $exeSha256
    }
    python_available = ($null -ne $pythonInfo)
    keep_case_directories = [bool]$KeepCaseDirectories
    case_results = @($script:FaultCaseResults)
}
$summaryResult = Write-VerifySummary -OutputDir $OutputDir -ScriptName 'verify-release-faults' -ExePath $ExePath -ExeSha256 $exeSha256 -ExeSizeBytes $exeSizeBytes -Metadata $metadata -FatalError $fatalError

if (-not [string]::IsNullOrWhiteSpace($fatalError)) {
    Write-Host '结论：验证过程中发生未预期异常，判定 FAIL（退出码 1）。'
    exit 1
}
if ($summaryResult.fail -gt 0) {
    Write-Host ('结论：存在 ' + $summaryResult.fail + ' 个 FAIL 检查项，判定 FAIL（退出码 1）。')
    exit 1
}
Write-Host '结论：全部检查通过（允许 WARN/INFO），退出码 0。'
exit 0
