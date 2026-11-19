# =============================================================================
# WorkManager T1-01：Release 便携路径 / 数据持久化 / 环境变量隔离 运行时验证
#
# 对应共享任务 task-2（scripts/verify/verify-release-portable.ps1）。
#
# 覆盖检查（a-g）：
#   a. 记录 Release EXE 路径、大小、SHA-256；
#   b. 在隔离目录复制 EXE 并启动，验证主窗口标题、data/ 子目录、work.db 创建；
#   c. 用 python sqlite3 只读验证 user_version=2、integrity_check=ok、
#      journal_mode=wal、schema_migrations 表及版本 1、2、主数据库文件大于 0；
#   d. 关闭应用后验证 WAL/SHM 无残留数据、数据库仍可只读打开且完整性 ok；
#   e. 持久化：关闭后写入虚构 canary 到 settings(key='test-canary')，重启应用，
#      验证 canary 仍在、user_version 仍为 2、schema_migrations 仍只有 2 条；
#   f. Release 忽略 WORKMANAGER_TEST_PORTABLE_ROOT：设置诱饵目录后启动，验证
#      数据库创建在 EXE 同级 data/ 而诱饵目录保持为空；
#   g. 汇总 PASS/FAIL，任一 FAIL 时退出码 1。
#
# 约束：
#   - Windows PowerShell 5.1 兼容；必须在 D:\WorkManager-test-data 下运行并清理；
#   - 不得写入正式便携目录 D:\WorkManager；不得使用真实工作数据；
#   - 所有等待进程退出/窗口出现的循环都有超时上限；
#   - 本文件必须以 UTF-8 with BOM 保存。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1 `
#       -ExePath <repo>\target\release\workmanager.exe `
#       -OutputDir D:\WorkManager-test-data\release-verify-20261117-180000 `
#       -KeepCaseDirectories     # 可选：保留用例沙箱目录便于人工排查（默认清理）
#
# 退出码：0=全部 PASS；1=存在 FAIL；2=前置条件不满足（EXE 不存在 / python 不可用 /
#         -OutputDir 非法），脚本会清晰报错而不会崩溃。
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

Initialize-VerifyContext -ScriptName 'verify-release-portable'
$script:PortableActiveProcesses = New-Object System.Collections.ArrayList
$script:PortableCaseDirectories = New-Object System.Collections.ArrayList
$script:PortableProbeReports = New-Object System.Collections.ArrayList
$script:PortableCaseResults = New-Object System.Collections.ArrayList
$fatalError = ''

# ---------------------------------------------------------------------------
# 本脚本内部辅助函数
# ---------------------------------------------------------------------------
function Start-PortableVerificationApp {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutLogPath,
        [Parameter(Mandatory = $true)][string]$StderrLogPath,
        [System.Collections.IDictionary]$EnvironmentOverrides = $null
    )

    $startArguments = @{
        ExePath          = $ExePath
        WorkingDirectory = $WorkingDirectory
        StdoutLogPath    = $StdoutLogPath
        StderrLogPath    = $StderrLogPath
    }
    if ($null -ne $EnvironmentOverrides) {
        $startArguments['EnvironmentOverrides'] = $EnvironmentOverrides
    }
    $started = Start-AppProcess @startArguments
    [void]$script:PortableActiveProcesses.Add($started.process)
    return $started
}

function Close-PortableApplication {
    param(
        [Parameter(Mandatory = $true)]$Started,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $stopResult = Stop-AppProcess -Process $Started.process -GracefulTimeoutSeconds $script:VerifyGracefulExitTimeoutSeconds
    Write-VerifyLog -Message ('关闭应用 {0}：method={1} exited={2} exit_code={3} elapsed_ms={4}' -f $Label, $stopResult.method, $stopResult.exited, $stopResult.exit_code, $stopResult.elapsed_ms) -Level 'STEP'
    $capturedOutput = Save-AppProcessOutput -Started $Started
    if (-not [string]::IsNullOrWhiteSpace([string]$capturedOutput.saved_stdout_path)) {
        Register-VerifyArtifact -Label ($Label + ' 标准输出日志') -Path $capturedOutput.saved_stdout_path
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$capturedOutput.saved_stderr_path)) {
        Register-VerifyArtifact -Label ($Label + ' 标准错误日志') -Path $capturedOutput.saved_stderr_path
    }
    Write-VerifyLog -Message ('{0} 进程输出捕获：stdout {1} 字符；stderr {2} 字符；读取错误={3}' -f $Label, ([string]$capturedOutput.stdout).Length, ([string]$capturedOutput.stderr).Length, [string]$capturedOutput.error) -Level 'INFO'
    return $stopResult
}

function Add-ApplicationStopChecks {
    param(
        [Parameter(Mandatory = $true)]$StopResult,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    if (-not $StopResult.exited) {
        Add-VerifyCheck -Name ($Prefix + '.process_exited') -Status 'FAIL' -Detail ('进程在超时后仍未退出：method=' + $StopResult.method + ' elapsed_ms=' + $StopResult.elapsed_ms)
        return
    }
    Add-VerifyCheck -Name ($Prefix + '.process_exited') -Status 'PASS' -Detail ('method=' + $StopResult.method + ' elapsed_ms=' + $StopResult.elapsed_ms)
    if ($StopResult.method -like 'CloseMainWindow*') {
        Add-VerifyCheck -Name ($Prefix + '.graceful_close') -Status 'PASS' -Detail ('CloseMainWindow 正常关闭，exit_code=' + $StopResult.exit_code)
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.graceful_close') -Status 'FAIL' -Detail ('未通过主窗口正常关闭：method=' + $StopResult.method + '，可能需要人工确认应用是否挂起')
    }
    if ($StopResult.exit_code -eq 0) {
        Add-VerifyCheck -Name ($Prefix + '.exit_code_zero') -Status 'PASS' -Detail 'exit_code=0'
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.exit_code_zero') -Status 'FAIL' -Detail ('exit_code=' + $StopResult.exit_code)
    }
}

function Register-ProbeReport {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [AllowNull()]$ProbeResult
    )

    $report = [ordered]@{
        label     = $Label
        json_path = $JsonPath
        ok        = $false
        exit_code = $null
        open_mode = $null
        error     = $null
        inspection = $null
    }
    if ($null -ne $ProbeResult) {
        $report.ok = $ProbeResult.ok
        $report.exit_code = $ProbeResult.exit_code
        $report.error = $ProbeResult.error
        if ($null -ne $ProbeResult.json -and $null -ne $ProbeResult.json.inspection) {
            $report.open_mode = [string]$ProbeResult.json.inspection.open_mode
            $report.inspection = $ProbeResult.json.inspection
        }
    }
    [void]$script:PortableProbeReports.Add([pscustomobject]$report)
    Register-VerifyArtifact -Label ('SQLite 检查 JSON ' + $Label) -Path $JsonPath
}

function Add-DatabaseInspectionChecks {
    param(
        [AllowNull()]$Inspection,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [switch]$ExpectCanaryAbsent,
        [AllowEmptyString()][string]$ExpectedCanaryValue = ''
    )

    if ($null -eq $Inspection) {
        Add-VerifyCheck -Name ($Prefix + '.inspection_available') -Status 'FAIL' -Detail '未获得 SQLite 检查 JSON（python 探针执行失败）'
        return
    }

    $openMode = ''
    if ($null -ne $Inspection.open_mode) {
        $openMode = [string]$Inspection.open_mode
    }
    if ($openMode -eq 'mode=ro') {
        Add-VerifyCheck -Name ($Prefix + '.readonly_open') -Status 'PASS' -Detail ('open_mode=' + $openMode)
    }
    elseif ($openMode -like 'mode=ro*') {
        Add-VerifyCheck -Name ($Prefix + '.readonly_open') -Status 'WARN' -Detail ('open_mode=' + $openMode + '（mode=ro 失败后回退 immutable，需人工确认）')
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.readonly_open') -Status 'FAIL' -Detail ('open_mode=' + $openMode)
    }

    $databaseSize = $null
    if ($null -ne $Inspection.database -and $null -ne $Inspection.database.size_bytes) {
        $databaseSize = [long]$Inspection.database.size_bytes
    }
    if ($null -ne $databaseSize -and $databaseSize -gt 0) {
        Add-VerifyCheck -Name ($Prefix + '.database_size_positive') -Status 'PASS' -Detail ('size_bytes=' + $databaseSize)
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.database_size_positive') -Status 'FAIL' -Detail ('size_bytes=' + [string]$databaseSize)
    }

    $userVersion = $null
    if ($null -ne $Inspection.user_version) {
        $userVersion = [long]$Inspection.user_version
    }
    if ($userVersion -eq [long]$script:VerifyExpectedSchemaVersion) {
        Add-VerifyCheck -Name ($Prefix + '.user_version') -Status 'PASS' -Detail ('user_version=' + $userVersion + '（期望 ' + $script:VerifyExpectedSchemaVersion + '）')
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.user_version') -Status 'FAIL' -Detail ('user_version=' + [string]$userVersion + '（期望 ' + $script:VerifyExpectedSchemaVersion + '）')
    }

    $integrityValues = @()
    if ($null -ne $Inspection.integrity_check) {
        $integrityValues = @($Inspection.integrity_check)
    }
    $integrityOk = (($integrityValues.Count -eq 1) -and ([string]$integrityValues[0] -eq 'ok'))
    if ($integrityOk) {
        Add-VerifyCheck -Name ($Prefix + '.integrity_ok') -Status 'PASS' -Detail 'PRAGMA integrity_check = ok'
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.integrity_ok') -Status 'FAIL' -Detail ('integrity_check=' + (($integrityValues | ForEach-Object { [string]$_ }) -join '; '))
    }

    $journalMode = ''
    if ($null -ne $Inspection.journal_mode) {
        $journalMode = [string]$Inspection.journal_mode
    }
    if ($journalMode -eq $script:VerifyExpectedJournalMode) {
        Add-VerifyCheck -Name ($Prefix + '.journal_mode_wal') -Status 'PASS' -Detail ('journal_mode=' + $journalMode)
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.journal_mode_wal') -Status 'FAIL' -Detail ('journal_mode=' + $journalMode + '（期望 ' + $script:VerifyExpectedJournalMode + '）')
    }

    $tables = @()
    if ($null -ne $Inspection.tables) {
        $tables = @($Inspection.tables)
    }
    if ($tables -contains 'schema_migrations') {
        Add-VerifyCheck -Name ($Prefix + '.schema_migrations_table') -Status 'PASS' -Detail ('tables=' + ($tables -join ','))
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.schema_migrations_table') -Status 'FAIL' -Detail ('tables=' + ($tables -join ','))
    }
    if ($tables -contains 'settings') {
        Add-VerifyCheck -Name ($Prefix + '.settings_table') -Status 'PASS' -Detail 'settings 表存在'
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.settings_table') -Status 'FAIL' -Detail 'settings 表不存在'
    }

    $migrationCount = $null
    if ($null -ne $Inspection.schema_migrations_count) {
        $migrationCount = [int]$Inspection.schema_migrations_count
    }
    if ($migrationCount -eq [int]$script:VerifyExpectedSchemaVersion) {
        Add-VerifyCheck -Name ($Prefix + '.schema_migrations_count') -Status 'PASS' -Detail ('schema_migrations 记录数=' + $migrationCount)
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.schema_migrations_count') -Status 'FAIL' -Detail ('schema_migrations 记录数=' + [string]$migrationCount + '（期望 ' + $script:VerifyExpectedSchemaVersion + '）')
    }

    $migrationVersions = @()
    if ($null -ne $Inspection.schema_migrations) {
        $migrationVersions = @($Inspection.schema_migrations | ForEach-Object { [int]$_.version })
    }
    $expectedVersions = @(1..[int]$script:VerifyExpectedSchemaVersion)
    $missingVersions = @($expectedVersions | Where-Object { $migrationVersions -notcontains $_ })
    if ($missingVersions.Count -eq 0) {
        Add-VerifyCheck -Name ($Prefix + '.schema_migration_versions') -Status 'PASS' -Detail ('versions=' + ($migrationVersions -join ','))
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.schema_migration_versions') -Status 'FAIL' -Detail ('versions=' + ($migrationVersions -join ',') + '（缺少 ' + ($missingVersions -join ',') + '）')
    }

    # 外部只读连接无法读取应用进程内的 PRAGMA foreign_keys（SQLite 每连接配置），
    # 用“schema_migrations 包含全部版本”证明初始化/迁移路径已执行。
    if (($tables -contains 'schema_migrations') -and ($missingVersions.Count -eq 0)) {
        Add-VerifyCheck -Name ($Prefix + '.foreign_keys_enabled_evidence') -Status 'PASS' -Detail ('schema_migrations 完整（versions=' + ($migrationVersions -join ',') + '，作为 foreign_keys=ON 初始化路径证据）')
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.foreign_keys_enabled_evidence') -Status 'FAIL' -Detail 'schema_migrations 版本不完整，无法证明初始化路径'
    }

    $foreignKeyViolations = 0
    if ($null -ne $Inspection.foreign_key_check) {
        $foreignKeyViolations = @($Inspection.foreign_key_check).Count
    }
    if ($foreignKeyViolations -eq 0) {
        Add-VerifyCheck -Name ($Prefix + '.foreign_key_check_clean') -Status 'PASS' -Detail 'PRAGMA foreign_key_check 无违规行'
    }
    else {
        Add-VerifyCheck -Name ($Prefix + '.foreign_key_check_clean') -Status 'FAIL' -Detail ('foreign_key_check 违规行数=' + $foreignKeyViolations)
    }

    $canary = $Inspection.settings_canary
    if ($ExpectCanaryAbsent) {
        if ($null -eq $canary) {
            Add-VerifyCheck -Name ($Prefix + '.canary_absent') -Status 'PASS' -Detail 'settings 中不存在 test-canary（首次启动应为空）'
        }
        else {
            Add-VerifyCheck -Name ($Prefix + '.canary_absent') -Status 'FAIL' -Detail ('settings 中已存在 test-canary：' + [string]$canary.value_json)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCanaryValue)) {
        $canaryOk = $false
        if ($null -ne $canary -and $null -ne $canary.value_json) {
            $canaryOk = ([string]$canary.value_json).Contains($ExpectedCanaryValue)
        }
        if ($canaryOk) {
            Add-VerifyCheck -Name ($Prefix + '.canary_present') -Status 'PASS' -Detail ('value_json=' + [string]$canary.value_json + '；updated_at=' + [string]$canary.updated_at)
        }
        else {
            $actual = '<absent>'
            if ($null -ne $canary) {
                $actual = [string]$canary.value_json
            }
            Add-VerifyCheck -Name ($Prefix + '.canary_present') -Status 'FAIL' -Detail ('期望包含 ' + $ExpectedCanaryValue + '，实际=' + $actual)
        }
    }

    $pragmaText = ''
    if ($null -ne $Inspection.probe_connection_pragmas) {
        $pragmaText = ConvertTo-Json -InputObject $Inspection.probe_connection_pragmas -Compress
    }
    Add-VerifyCheck -Name ($Prefix + '.probe_connection_pragmas') -Status 'INFO' -Detail ('python 只读探针连接 PRAGMA（每连接默认值，不代表应用进程配置）：' + $pragmaText)
}

function Remove-VerificationSidecars {
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $walPath = $DatabasePath + '-wal'
    $shmPath = $DatabasePath + '-shm'
    $walSize = 0
    if (Test-Path -LiteralPath $walPath -PathType Leaf) {
        $walSize = Get-FileSizeBytes -Path $walPath
        if ($null -eq $walSize) {
            $walSize = 0
        }
    }
    if ($walSize -gt 0) {
        Write-VerifyLog -Message ('跳过 sidecar 清理（' + $Label + '）：-wal 仍有 ' + $walSize + ' 字节，保留以避免任何数据风险。') -Level 'WARN'
        return
    }
    foreach ($sidecarPath in @($walPath, $shmPath)) {
        if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction Stop
                Write-VerifyLog -Message ('重启前清理验证探针生成的 sidecar（' + $Label + '）：' + $sidecarPath) -Level 'STEP'
            }
            catch {
                Write-VerifyLog -Message ('清理验证探针 sidecar 失败（' + $Label + '）：' + $sidecarPath + '；' + $_.Exception.Message) -Level 'WARN'
            }
        }
    }
}

function New-PortableCaseDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$CaseName
    )

    $caseDir = Join-Path $OutputDir $CaseName
    New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
    [void]$script:PortableCaseDirectories.Add($caseDir)
    Register-VerifyArtifact -Label ('用例沙箱目录 ' + $CaseName) -Path $caseDir -Kind 'directory'
    return $caseDir
}

function Wait-ForPathExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 20,
        [string]$PathType = 'Container'
    )

    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $exists = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType $PathType) {
            $exists = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    return [pscustomobject]@{
        path            = $Path
        exists          = $exists
        path_type       = $PathType
        timeout_seconds = $TimeoutSeconds
        elapsed_ms      = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
    }
}

function Get-RunningDatabaseSnapshot {
    param([Parameter(Mandatory = $true)][string]$DatabasePath)

    $snapshot = [ordered]@{
        captured_at        = (Get-Date).ToString('o')
        database_path      = $DatabasePath
        database_exists    = (Test-Path -LiteralPath $DatabasePath -PathType Leaf)
        database_size_bytes = $null
        sidecars           = $null
    }
    if ($snapshot.database_exists) {
        $snapshot.database_size_bytes = Get-FileSizeBytes -Path $DatabasePath
    }
    $snapshot.sidecars = Get-SidecarState -DatabasePath $DatabasePath
    return [pscustomobject]$snapshot
}

function Get-CDriveBoundarySnapshot {
    param([Parameter(Mandatory = $true)][string]$Label)

    $candidates = @(
        [pscustomobject]@{
            name = 'LOCALAPPDATA\com.workmanager.portable'
            path = (Join-Path $env:LOCALAPPDATA 'com.workmanager.portable')
        },
        [pscustomobject]@{
            name = 'APPDATA\com.workmanager.portable'
            path = (Join-Path $env:APPDATA 'com.workmanager.portable')
        },
        [pscustomobject]@{
            name = 'LOCALAPPDATA\EBWebView'
            path = (Join-Path $env:LOCALAPPDATA 'EBWebView')
        }
    )

    $locations = New-Object System.Collections.ArrayList
    foreach ($candidate in $candidates) {
        $entry = [ordered]@{
            name                  = $candidate.name
            path                  = $candidate.path
            exists                = $false
            is_directory          = $false
            creation_time_utc     = $null
            last_write_utc        = $null
            top_level_entry_count = $null
        }
        if (Test-Path -LiteralPath $candidate.path) {
            $entry.exists = $true
            $item = Get-Item -LiteralPath $candidate.path -Force
            $entry.is_directory = $item.PSIsContainer
            $entry.creation_time_utc = $item.CreationTimeUtc.ToString('o')
            $entry.last_write_utc = $item.LastWriteTimeUtc.ToString('o')
            if ($item.PSIsContainer) {
                $children = @()
                try {
                    $children = @(Get-ChildItem -LiteralPath $candidate.path -Force -ErrorAction Stop)
                }
                catch {
                    $children = @()
                }
                $entry.top_level_entry_count = $children.Count
            }
        }
        [void]$locations.Add([pscustomobject]$entry)
    }
    return [pscustomobject]@{
        label       = $Label
        captured_at = (Get-Date).ToString('o')
        locations   = @($locations)
    }
}

function Add-CDriveBoundaryChecks {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)]$After,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $baselineByLocation = @{}
    foreach ($location in @($Baseline.locations)) {
        $baselineByLocation[[string]$location.name] = $location
    }

    foreach ($location in @($After.locations)) {
        $checkName = $Prefix + '.' + ([string]$location.name).Replace('\', '_')
        $display = 'path=' + [string]$location.path + '；exists=' + $location.exists
        if ($null -ne $location.last_write_utc) {
            $display = $display + '；last_write_utc=' + [string]$location.last_write_utc
        }
        if ($null -ne $location.creation_time_utc) {
            $display = $display + '；creation_time_utc=' + [string]$location.creation_time_utc
        }
        if ($null -ne $location.top_level_entry_count) {
            $display = $display + '；top_level_entries=' + [string]$location.top_level_entry_count
        }

        $before = $baselineByLocation[[string]$location.name]
        $existedBefore = ($null -ne $before -and $before.exists -eq $true)
        if ((-not $existedBefore) -and $location.exists) {
            Add-VerifyCheck -Name $checkName -Status 'FAIL' -Detail ('本次验证期间创建了 C 盘路径（应不存在，存在越界风险）：' + $display)
        }
        elseif ($existedBefore -and $location.exists) {
            $unchanged = (($before.last_write_utc -eq $location.last_write_utc) -and ($before.top_level_entry_count -eq $location.top_level_entry_count))
            if ($unchanged) {
                Add-VerifyCheck -Name $checkName -Status 'WARN' -Detail ('C 盘路径在验证开始前已存在且相同时刻/条目未变化（非本次验证创建，需人工确认来源）：' + $display)
            }
            else {
                Add-VerifyCheck -Name $checkName -Status 'WARN' -Detail ('C 盘路径在验证开始前已存在，但时间戳或条目发生变化，需人工确认是否被本次启动写入：' + $display + '；baseline_last_write_utc=' + [string]$before.last_write_utc + '；baseline_top_level_entries=' + [string]$before.top_level_entry_count)
            }
        }
        elseif ($existedBefore -and -not $location.exists) {
            Add-VerifyCheck -Name $checkName -Status 'INFO' -Detail ('C 盘路径验证前存在、验证后不存在（非本次验证创建，已记录原时间戳：' + [string]$before.last_write_utc + '）：' + $display)
        }
        else {
            Add-VerifyCheck -Name $checkName -Status 'PASS' -Detail ('C 盘路径不存在（符合便携边界预期）：' + $display)
        }
    }
}

# ===========================================================================
# 主流程
# ===========================================================================
Write-VerifySection 'WorkManager T1-01 Release 便携/持久化运行时验证（task-2）'

# --- 前置条件 1：Release EXE -------------------------------------------------
$resolvedExe = Resolve-ReleaseExePath -ExePath $ExePath
if ($null -eq $resolvedExe) {
    Write-Host ''
    Write-Host '结论：无法开始验证（Release EXE 不存在或 -ExePath 无效）。退出码 2。'
    exit 2
}
$ExePath = $resolvedExe

# --- 前置条件 2：python ------------------------------------------------------
$pythonInfo = Get-PythonExecutable
if ($null -eq $pythonInfo) {
    Write-VerifyLog -Message '错误：未找到可用的 python（需要 python 3 + sqlite3 标准库）。' -Level 'FAIL'
    Write-Host ''
    Write-Host '结论：无法开始验证（python 不可用）。退出码 2。'
    exit 2
}
$script:VerifyPython = $pythonInfo

# --- 前置条件 3：输出目录 ----------------------------------------------------
$resolvedOutputDir = Resolve-VerifyOutputDir -OutputDir $OutputDir
if ($null -eq $resolvedOutputDir) {
    Write-Host ''
    Write-Host '结论：无法开始验证（-OutputDir 不合法）。退出码 2。'
    exit 2
}
$OutputDir = $resolvedOutputDir
$evidenceDir = Join-Path $OutputDir 'evidence'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$probeScript = Ensure-SqliteProbeScript -OutputDir $OutputDir
Register-VerifyArtifact -Label 'python SQLite 探针脚本' -Path $probeScript
$exeSizeBytes = Get-FileSizeBytes -Path $ExePath
$exeSha256 = Get-FileSha256 -Path $ExePath

Write-VerifySection '0. 环境与 Release EXE 记录'
Write-VerifyLog -Message ('Release EXE：' + $ExePath) -Level 'INFO'
Write-VerifyLog -Message ('大小（字节）：' + [string]$exeSizeBytes) -Level 'INFO'
Write-VerifyLog -Message ('SHA-256：' + [string]$exeSha256) -Level 'INFO'
Write-VerifyLog -Message ('python：' + $pythonInfo.path + '（' + $pythonInfo.version + '，sqlite ' + $pythonInfo.sqlite_version + '）') -Level 'INFO'
Write-VerifyLog -Message ('输出目录：' + $OutputDir) -Level 'INFO'
Write-VerifyLog -Message ('PowerShell：' + $PSVersionTable.PSVersion.ToString() + '，OS：' + [System.Environment]::OSVersion.VersionString) -Level 'INFO'
Add-VerifyCheck -Name 'precondition.release_exe' -Status 'INFO' -Detail ('path=' + $ExePath + '；size_bytes=' + [string]$exeSizeBytes + '；sha256=' + [string]$exeSha256)
Add-VerifyCheck -Name 'precondition.python' -Status 'INFO' -Detail ($pythonInfo.path + ' ' + $pythonInfo.version + ' / sqlite ' + $pythonInfo.sqlite_version)
Add-VerifyCheck -Name 'precondition.output_dir' -Status 'INFO' -Detail $OutputDir
$sourceExeDirectory = Split-Path -Parent $ExePath
$sourceDataDirectory = Join-Path $sourceExeDirectory 'data'
if (Test-Path -LiteralPath $sourceDataDirectory) {
    Add-VerifyCheck -Name 'precondition.source_exe_data_directory' -Status 'WARN' -Detail ('源 EXE 目录已存在 data/（可能是历史运行残留，本次验证不修改它）：' + $sourceDataDirectory)
}
else {
    Add-VerifyCheck -Name 'precondition.source_exe_data_directory' -Status 'INFO' -Detail '源 EXE 目录尚无 data/（本次验证只写入隔离复制目录）'
}

$firstLaunchExitCode = $null
$firstWindowTitle = ''
$persistenceWindowTitle = ''
$persistenceExitCode = $null
$envIgnoreWindowTitle = ''
$envIgnoreExitCode = $null
$canaryValue = 'release-verify-canary-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
$case1DatabasePath = ''
$runningDbSnapshot = $null
$cDriveAfter = $null

# --- C 盘边界基线（任何应用启动前采集）---
Write-VerifySection '0b. C 盘边界基线（启动前）'
$cDriveBaseline = Get-CDriveBoundarySnapshot -Label 'before'
$cDriveBaselinePath = Join-Path $evidenceDir 'c-drive-boundary-before.json'
Save-VerifyJsonFile -Path $cDriveBaselinePath -Object $cDriveBaseline -Depth 8 | Out-Null
Register-VerifyArtifact -Label 'C 盘边界基线 JSON（before）' -Path $cDriveBaselinePath
$cDriveBaselineSummary = (@($cDriveBaseline.locations | ForEach-Object { $_.name + ' exists=' + $_.exists })) -join '；'
Write-VerifyLog -Message ('C 盘边界基线：' + $cDriveBaselineSummary) -Level 'INFO'
Add-VerifyCheck -Name 'c_drive.baseline' -Status 'INFO' -Detail $cDriveBaselineSummary
foreach ($location in @($cDriveBaseline.locations)) {
    if ($location.exists) {
        Write-VerifyLog -Message ('C 盘路径启动前已存在：' + $location.path + '；creation_time_utc=' + [string]$location.creation_time_utc + '；last_write_utc=' + [string]$location.last_write_utc + '；top_level_entries=' + [string]$location.top_level_entry_count) -Level 'WARN'
    }
}

try {
    # =======================================================================
    # 用例 1：首次启动 + 便携目录 + SQLite 基础配置 + 正常关闭（a,b,c,d）
    # =======================================================================
    Write-VerifySection '用例 1：首次启动、便携目录、SQLite 基础检查'
    $caseName = 'case1-first-launch'
    $caseDir = New-PortableCaseDirectory -OutputDir $OutputDir -CaseName $caseName
    $case1DatabasePath = Join-Path $caseDir 'data\database\work.db'
    $appExe = Join-Path $caseDir 'WorkManager.exe'
    Copy-Item -LiteralPath $ExePath -Destination $appExe -Force
    $copiedSha256 = Get-FileSha256 -Path $appExe
    if ($copiedSha256 -eq $exeSha256) {
        Add-VerifyCheck -Name 'case1.exe_copy_sha256_matches' -Status 'PASS' -Detail ('sha256=' + $copiedSha256)
    }
    else {
        Add-VerifyCheck -Name 'case1.exe_copy_sha256_matches' -Status 'FAIL' -Detail ('源=' + [string]$exeSha256 + '；副本=' + [string]$copiedSha256)
    }

    $case1Stdout1 = Join-Path $evidenceDir 'case1-app1-stdout.log'
    $case1Stderr1 = Join-Path $evidenceDir 'case1-app1-stderr.log'
    $firstStart = Start-PortableVerificationApp -ExePath $appExe -WorkingDirectory $caseDir -StdoutLogPath $case1Stdout1 -StderrLogPath $case1Stderr1
    $firstWindow = Wait-MainWindow -Process $firstStart.process -TitlePattern '*WorkManager*' -TimeoutSeconds $script:VerifyDefaultWindowTimeoutSeconds

    if ($firstWindow.found) {
        $firstWindowTitle = [string]$firstWindow.title
        Add-VerifyCheck -Name 'case1.main_window_visible' -Status 'PASS' -Detail ('title=' + $firstWindow.title + '；hwnd=' + $firstWindow.hwnd + '；elapsed_ms=' + $firstWindow.elapsed_ms)
        if ($firstWindow.title -eq $script:WorkManagerAppTitle) {
            Add-VerifyCheck -Name 'case1.main_window_title' -Status 'PASS' -Detail ('窗口标题=' + $firstWindow.title + '（期望 ' + $script:WorkManagerAppTitle + '）')
        }
        else {
            Add-VerifyCheck -Name 'case1.main_window_title' -Status 'FAIL' -Detail ('窗口标题=' + $firstWindow.title + '（期望 ' + $script:WorkManagerAppTitle + '）')
        }
        $mainScreenshot = Capture-WindowScreenshot -WindowHandle $firstWindow.hwnd -OutputPath (Join-Path $evidenceDir 'case1-main-window.png')
        if ($mainScreenshot.ok) {
            Add-VerifyCheck -Name 'case1.main_window_screenshot' -Status 'PASS' -Detail ('png=' + $mainScreenshot.path + '；' + $mainScreenshot.width + 'x' + $mainScreenshot.height)
            Register-VerifyArtifact -Label '首次启动主窗口截图' -Path $mainScreenshot.path
        }
        else {
            Add-VerifyCheck -Name 'case1.main_window_screenshot' -Status 'WARN' -Detail ('截图失败（仅证据缺失，不影响功能判定）：' + [string]$mainScreenshot.error)
        }

        # WebView2 便携 profile 目录：data\cache\webview2\EBWebView 必须真实创建
        $webview2EbWebViewPath = Join-Path $caseDir 'data\cache\webview2\EBWebView'
        $ebWebViewWait = Wait-ForPathExists -Path $webview2EbWebViewPath -TimeoutSeconds 20 -PathType 'Container'
        if ($ebWebViewWait.exists) {
            Add-VerifyCheck -Name 'case1.webview2_ebwebview_dir' -Status 'PASS' -Detail ('WebView2 profile 目录存在：' + $webview2EbWebViewPath + '；等待 ' + $ebWebViewWait.elapsed_ms + ' ms')
        }
        else {
            Add-VerifyCheck -Name 'case1.webview2_ebwebview_dir' -Status 'FAIL' -Detail ('未在 ' + $ebWebViewWait.timeout_seconds + ' 秒内检测到 WebView2 profile 目录：' + $webview2EbWebViewPath + '（需人工确认 data_directory 是否真实生效）')
        }
        $webview2Snapshot = Get-DirectorySnapshot -Path (Join-Path $caseDir 'data\cache\webview2') -MaxDepth 2 -MaxEntries 100
        $webview2SnapshotPath = Join-Path $evidenceDir 'case1-webview2-directory-snapshot.json'
        Save-VerifyJsonFile -Path $webview2SnapshotPath -Object $webview2Snapshot -Depth 10 | Out-Null
        Register-VerifyArtifact -Label 'case1 WebView2 目录快照 JSON' -Path $webview2SnapshotPath

        # 进程运行期间数据库文件与 WAL/SHM 状态快照（文件系统层，避免只读探针副作用）
        $runningDbSnapshot = Get-RunningDatabaseSnapshot -DatabasePath $case1DatabasePath
        $runningDbSnapshotPath = Join-Path $evidenceDir 'case1-db-running-snapshot.json'
        Write-VerifyJsonEvidence -Label 'case1 进程运行期间数据库文件与 WAL/SHM 快照' -JsonText (ConvertTo-Json -InputObject $runningDbSnapshot -Depth 8)
        Save-VerifyJsonFile -Path $runningDbSnapshotPath -Object $runningDbSnapshot -Depth 10 | Out-Null
        Register-VerifyArtifact -Label 'case1 运行期间数据库快照 JSON' -Path $runningDbSnapshotPath
        if ($runningDbSnapshot.database_exists -and $null -ne $runningDbSnapshot.database_size_bytes -and $runningDbSnapshot.database_size_bytes -gt 0) {
            Add-VerifyCheck -Name 'case1.running_database_file' -Status 'PASS' -Detail ('运行期间 work.db 存在且非空：size_bytes=' + [string]$runningDbSnapshot.database_size_bytes)
        }
        else {
            Add-VerifyCheck -Name 'case1.running_database_file' -Status 'FAIL' -Detail ('运行期间 work.db 不存在或为空：exists=' + $runningDbSnapshot.database_exists + '；size_bytes=' + [string]$runningDbSnapshot.database_size_bytes)
        }
        $runningSidecars = $runningDbSnapshot.sidecars
        Add-VerifyCheck -Name 'case1.running_sidecars' -Status 'INFO' -Detail ('运行期间 sidecar 状态：-wal exists=' + $runningSidecars.wal_exists + ' size=' + $runningSidecars.wal_size_bytes + '；-shm exists=' + $runningSidecars.shm_exists + ' size=' + $runningSidecars.shm_size_bytes + '；-journal exists=' + $runningSidecars.journal_exists)
    }
    else {
        Add-VerifyCheck -Name 'case1.main_window_visible' -Status 'FAIL' -Detail ('未在 ' + $script:VerifyDefaultWindowTimeoutSeconds + ' 秒内找到主窗口；process_exited=' + $firstWindow.process_exited + '；exit_code=' + [string]$firstWindow.exit_code + '；timed_out=' + $firstWindow.timed_out)
        if ((-not $firstWindow.process_exited) -and $firstWindow.timed_out) {
            $unexpectedDialog = Wait-FailureDialog -Process $firstStart.process -TimeoutSeconds 15
            if ($unexpectedDialog.found) {
                Add-VerifyCheck -Name 'case1.unexpected_failure_dialog' -Status 'FAIL' -Detail ('启动未出现主窗口，而是失败对话框：title=' + $unexpectedDialog.title + '；texts=' + ((@($unexpectedDialog.texts)) -join ' | '))
                $dialogJson = ConvertTo-Json -InputObject @($unexpectedDialog.text_details) -Depth 6
                Write-VerifyJsonEvidence -Label 'case1 意外启动失败对话框 UI 文本' -JsonText $dialogJson
                Save-Utf8TextFile -Path (Join-Path $evidenceDir 'case1-unexpected-dialog.json') -Content ($dialogJson + "`r`n")
                Register-VerifyArtifact -Label 'case1 意外启动失败对话框文本' -Path (Join-Path $evidenceDir 'case1-unexpected-dialog.json')
                if ($unexpectedDialog.hwnd -ne 0) {
                    $dialogShot = Capture-WindowScreenshot -WindowHandle $unexpectedDialog.hwnd -OutputPath (Join-Path $evidenceDir 'case1-unexpected-dialog.png')
                    if ($dialogShot.ok) {
                        Register-VerifyArtifact -Label 'case1 意外启动失败对话框截图' -Path $dialogShot.path
                    }
                }
                $dialogCloseMethod = Close-FailureDialog -Dialog $unexpectedDialog -Process $firstStart.process
                Write-VerifyLog -Message ('意外启动失败对话框关闭方式：' + $dialogCloseMethod) -Level 'INFO'
                $dialogExit = Wait-ProcessExit -Process $firstStart.process -TimeoutSeconds $script:VerifyGracefulExitTimeoutSeconds
                Write-VerifyLog -Message ('意外启动失败对话框关闭后进程：exited=' + $dialogExit.exited + '；exit_code=' + [string]$dialogExit.exit_code) -Level 'INFO'
            }
        }
    }

    $firstStop = Close-PortableApplication -Started $firstStart -Label 'case1 首次启动'
    $firstLaunchExitCode = $firstStop.exit_code
    Add-ApplicationStopChecks -StopResult $firstStop -Prefix 'case1'

    # --- 便携目录结构 ---
    $dataRoot = Join-Path $caseDir 'data'
    $case1DatabasePath = Join-Path $dataRoot 'database\work.db'
    $requiredDirectories = @(
        [pscustomobject]@{ relative = 'data'; name = 'case1.data_root_created' },
        [pscustomobject]@{ relative = 'data\database'; name = 'case1.database_dir_created' },
        [pscustomobject]@{ relative = 'data\cache'; name = 'case1.cache_dir_created' },
        [pscustomobject]@{ relative = 'data\cache\webview2'; name = 'case1.webview2_dir_created' },
        [pscustomobject]@{ relative = 'data\config'; name = 'case1.config_dir_created' },
        [pscustomobject]@{ relative = 'data\logs'; name = 'case1.logs_dir_created' },
        [pscustomobject]@{ relative = 'data\temp'; name = 'case1.temp_dir_created' },
        [pscustomobject]@{ relative = 'data\backups'; name = 'case1.backups_dir_created' }
    )
    foreach ($required in $requiredDirectories) {
        $targetPath = Join-Path $caseDir $required.relative
        if (Test-Path -LiteralPath $targetPath -PathType Container) {
            Add-VerifyCheck -Name $required.name -Status 'PASS' -Detail ('目录存在：' + $targetPath)
        }
        else {
            Add-VerifyCheck -Name $required.name -Status 'FAIL' -Detail ('目录不存在：' + $targetPath)
        }
    }
    $webview2Directory = Join-Path $dataRoot 'cache\webview2'
    $webview2Snapshot = Get-DirectorySnapshot -Path $webview2Directory -MaxDepth 2 -MaxEntries 50
    $webview2EntryCount = 0
    if (@($webview2Snapshot.entries).Count -gt 0) {
        $webview2EntryCount = @($webview2Snapshot.entries).Count
    }
    if ($webview2EntryCount -gt 0) {
        Add-VerifyCheck -Name 'case1.webview2_dir_populated' -Status 'PASS' -Detail ('WebView2 数据目录内有 ' + $webview2EntryCount + ' 个条目（截断=' + $webview2Snapshot.truncated + '）')
    }
    else {
        Add-VerifyCheck -Name 'case1.webview2_dir_populated' -Status 'WARN' -Detail 'WebView2 数据目录为空，需人工确认 WebView2 是否使用了便携 data_directory'
    }
    if (Test-Path -LiteralPath $case1DatabasePath -PathType Leaf) {
        $databaseFileSize = Get-FileSizeBytes -Path $case1DatabasePath
        if ($null -ne $databaseFileSize -and $databaseFileSize -gt 0) {
            Add-VerifyCheck -Name 'case1.database_file_created' -Status 'PASS' -Detail ('work.db 存在且非空：size_bytes=' + $databaseFileSize)
        }
        else {
            Add-VerifyCheck -Name 'case1.database_file_created' -Status 'FAIL' -Detail ('work.db 存在但为空：size_bytes=' + [string]$databaseFileSize)
        }
    }
    else {
        Add-VerifyCheck -Name 'case1.database_file_created' -Status 'FAIL' -Detail ('work.db 不存在：' + $case1DatabasePath)
    }

    $dataSnapshot = Get-DirectorySnapshot -Path $dataRoot -MaxDepth 3 -MaxEntries 300
    $dataSnapshotPath = Join-Path $evidenceDir 'case1-data-directory-snapshot.json'
    Save-VerifyJsonFile -Path $dataSnapshotPath -Object $dataSnapshot -Depth 10 | Out-Null
    Register-VerifyArtifact -Label 'case1 data 目录快照 JSON' -Path $dataSnapshotPath
    Add-VerifyCheck -Name 'case1.data_directory_snapshot' -Status 'INFO' -Detail ('条目数=' + @($dataSnapshot.entries).Count + '；truncated=' + $dataSnapshot.truncated + '；快照=' + $dataSnapshotPath)

    # --- 关闭后 sidecar 残留检查（必须先于任何 python 探针，探针本身会创建 -wal/-shm）---
    $sidecarAfterFirstClose = Get-SidecarState -DatabasePath $case1DatabasePath
    $sidecarJson = ConvertTo-Json -InputObject $sidecarAfterFirstClose -Depth 6
    Write-VerifyJsonEvidence -Label 'case1 正常关闭后 WAL/SHM/journal 残留状态' -JsonText $sidecarJson
    Save-Utf8TextFile -Path (Join-Path $evidenceDir 'case1-sidecars-after-first-close.json') -Content ($sidecarJson + "`r`n")
    Register-VerifyArtifact -Label 'case1 关闭后 sidecar 状态 JSON' -Path (Join-Path $evidenceDir 'case1-sidecars-after-first-close.json')
    $walCleared = ((-not $sidecarAfterFirstClose.wal_exists) -or ($sidecarAfterFirstClose.wal_size_bytes -eq 0))
    if ($walCleared) {
        Add-VerifyCheck -Name 'case1.wal_cleared_after_close' -Status 'PASS' -Detail ('-wal 不存在或为 0 字节（无未提交数据残留）：exists=' + $sidecarAfterFirstClose.wal_exists + '；size=' + $sidecarAfterFirstClose.wal_size_bytes)
    }
    else {
        Add-VerifyCheck -Name 'case1.wal_cleared_after_close' -Status 'FAIL' -Detail ('-wal 残留：exists=' + $sidecarAfterFirstClose.wal_exists + '；size=' + $sidecarAfterFirstClose.wal_size_bytes)
    }
    if (-not $sidecarAfterFirstClose.shm_exists) {
        Add-VerifyCheck -Name 'case1.shm_cleared_after_close' -Status 'PASS' -Detail ('-shm 不存在（wal_exists=' + $sidecarAfterFirstClose.wal_exists + '；wal_size=' + $sidecarAfterFirstClose.wal_size_bytes + '）')
    }
    elseif ($sidecarAfterFirstClose.wal_size_bytes -eq 0) {
        Add-VerifyCheck -Name 'case1.shm_cleared_after_close' -Status 'WARN' -Detail ('-shm 索引文件残留（exists=True；size=' + $sidecarAfterFirstClose.shm_size_bytes + '），但 -wal 为 0 字节、无未提交数据；SQLite 下次启动会安全重建 shm，不构成数据残留。该现象表明应用进程退出时可能未显式关闭 SQLite 连接（不影响重启一致性，已由重启持久化检查验证）')
    }
    else {
        Add-VerifyCheck -Name 'case1.shm_cleared_after_close' -Status 'FAIL' -Detail ('-shm 残留且 -wal 含未提交数据：-wal size=' + $sidecarAfterFirstClose.wal_size_bytes + '；-shm size=' + $sidecarAfterFirstClose.shm_size_bytes)
    }
    Add-VerifyCheck -Name 'case1.journal_after_close' -Status 'INFO' -Detail ('-journal exists=' + $sidecarAfterFirstClose.journal_exists + '；size=' + $sidecarAfterFirstClose.journal_size_bytes)

    # --- 只读 SQLite 检查（关闭后）---
    $case1ProbeJson = Join-Path $evidenceDir 'case1-db-after-first-close.json'
    $case1Probe = Invoke-SqliteProbe -ProbeScriptPath $probeScript -DatabasePath $case1DatabasePath -JsonOutPath $case1ProbeJson -Action 'inspect'
    Register-ProbeReport -Label 'case1-db-after-first-close' -JsonPath $case1ProbeJson -ProbeResult $case1Probe
    $case1Inspection = $null
    if ($null -ne $case1Probe.json) {
        $case1Inspection = $case1Probe.json.inspection
    }
    if ($null -ne $case1Inspection) {
        Write-VerifyJsonEvidence -Label 'case1 关闭后 SQLite 检查 JSON（task-2 c/d）' -JsonText (ConvertTo-Json -InputObject $case1Inspection -Depth 10)
    }
    else {
        Write-VerifyLog -Message ('case1 python 探针失败：' + [string]$case1Probe.error) -Level 'FAIL'
    }
    Add-DatabaseInspectionChecks -Inspection $case1Inspection -Prefix 'case1' -ExpectCanaryAbsent

    $probeSidecarNote = 'INFO'
    if ($null -ne $case1Inspection) {
        $afterProbeSidecars = $case1Inspection.sidecars_after_close
        if ($null -ne $afterProbeSidecars) {
            Add-VerifyCheck -Name 'case1.probe_side_effects' -Status 'INFO' -Detail ('python 只读探针会创建 -wal/-shm（SQLite WAL 只读访问的正常副作用）；探针后 -wal size=' + [string]$afterProbeSidecars.'-wal'.size_bytes + '；-shm size=' + [string]$afterProbeSidecars.'-shm'.size_bytes)
        }
    }

    # --- 用例 1 结果记录 ---
    [void]$script:PortableCaseResults.Add([ordered]@{
            case                 = $caseName
            directory            = $caseDir
            exe                  = $appExe
            database_path        = $case1DatabasePath
            main_window_title    = $firstWindowTitle
            first_exit_code      = $firstLaunchExitCode
            wal_cleared          = $walCleared
            shm_cleared          = $shmCleared
            database_inspection  = $case1Inspection
        })

    # =======================================================================
    # 用例 2：数据持久化（关闭后写虚构 canary，重启后仍存在且不重复迁移）（e）
    # =======================================================================
    Write-VerifySection '用例 2：数据持久化（虚构 canary + 重启）'
    Remove-VerificationSidecars -DatabasePath $case1DatabasePath -Label 'canary 插入前'

    $canaryInsertJson = Join-Path $evidenceDir 'persistence-canary-insert.json'
    $canaryInsert = Invoke-SqliteProbe -ProbeScriptPath $probeScript -DatabasePath $case1DatabasePath -JsonOutPath $canaryInsertJson -Action 'insert-canary' -CanaryValue $canaryValue
    Register-ProbeReport -Label 'persistence-canary-insert' -JsonPath $canaryInsertJson -ProbeResult $canaryInsert
    if ($canaryInsert.ok -and $null -ne $canaryInsert.json.inserted_canary -and ([string]$canaryInsert.json.inserted_canary.value) -eq $canaryValue) {
        Add-VerifyCheck -Name 'persistence.canary_inserted' -Status 'PASS' -Detail ('settings(key=test-canary) value_json=' + [string]$canaryInsert.json.inserted_canary.value_json)
    }
    else {
        Add-VerifyCheck -Name 'persistence.canary_inserted' -Status 'FAIL' -Detail ([string]$canaryInsert.error)
    }

    $canaryBeforeRestartJson = Join-Path $evidenceDir 'persistence-canary-before-restart.json'
    $canaryBeforeRestart = Invoke-SqliteProbe -ProbeScriptPath $probeScript -DatabasePath $case1DatabasePath -JsonOutPath $canaryBeforeRestartJson -Action 'inspect'
    Register-ProbeReport -Label 'persistence-canary-before-restart' -JsonPath $canaryBeforeRestartJson -ProbeResult $canaryBeforeRestart
    $canaryBeforeRestartInspection = $null
    if ($null -ne $canaryBeforeRestart.json) {
        $canaryBeforeRestartInspection = $canaryBeforeRestart.json.inspection
    }
    Add-DatabaseInspectionChecks -Inspection $canaryBeforeRestartInspection -Prefix 'persistence.before_restart' -ExpectedCanaryValue $canaryValue

    Remove-VerificationSidecars -DatabasePath $case1DatabasePath -Label '重启前'

    $case1Stdout2 = Join-Path $evidenceDir 'case1-app2-stdout.log'
    $case1Stderr2 = Join-Path $evidenceDir 'case1-app2-stderr.log'
    $restartStart = Start-PortableVerificationApp -ExePath $appExe -WorkingDirectory $caseDir -StdoutLogPath $case1Stdout2 -StderrLogPath $case1Stderr2
    $restartWindow = Wait-MainWindow -Process $restartStart.process -TitlePattern '*WorkManager*' -TimeoutSeconds $script:VerifyDefaultWindowTimeoutSeconds
    if ($restartWindow.found) {
        $persistenceWindowTitle = [string]$restartWindow.title
        Add-VerifyCheck -Name 'persistence.restart_window_visible' -Status 'PASS' -Detail ('title=' + $restartWindow.title + '；elapsed_ms=' + $restartWindow.elapsed_ms)
        if ($restartWindow.title -eq $script:WorkManagerAppTitle) {
            Add-VerifyCheck -Name 'persistence.restart_window_title' -Status 'PASS' -Detail ('窗口标题=' + $restartWindow.title)
        }
        else {
            Add-VerifyCheck -Name 'persistence.restart_window_title' -Status 'FAIL' -Detail ('窗口标题=' + $restartWindow.title + '（期望 ' + $script:WorkManagerAppTitle + '）')
        }
    }
    else {
        Add-VerifyCheck -Name 'persistence.restart_window_visible' -Status 'FAIL' -Detail ('重启后未找到主窗口；process_exited=' + $restartWindow.process_exited + '；exit_code=' + [string]$restartWindow.exit_code)
    }
    $restartStop = Close-PortableApplication -Started $restartStart -Label 'case1 重启'
    $persistenceExitCode = $restartStop.exit_code
    Add-ApplicationStopChecks -StopResult $restartStop -Prefix 'persistence.restart'

    $restartSidecar = Get-SidecarState -DatabasePath $case1DatabasePath
    $restartWalCleared = ((-not $restartSidecar.wal_exists) -or ($restartSidecar.wal_size_bytes -eq 0))
    if ($restartWalCleared) {
        Add-VerifyCheck -Name 'persistence.wal_cleared_after_restart' -Status 'PASS' -Detail ('-wal 不存在或为 0 字节：exists=' + $restartSidecar.wal_exists + '；size=' + $restartSidecar.wal_size_bytes)
    }
    else {
        Add-VerifyCheck -Name 'persistence.wal_cleared_after_restart' -Status 'FAIL' -Detail ('-wal 残留 size=' + $restartSidecar.wal_size_bytes)
    }
    if (-not $restartSidecar.shm_exists) {
        Add-VerifyCheck -Name 'persistence.shm_after_restart' -Status 'PASS' -Detail '-shm 不存在'
    }
    elseif ($restartSidecar.wal_size_bytes -eq 0) {
        Add-VerifyCheck -Name 'persistence.shm_after_restart' -Status 'WARN' -Detail ('-shm 索引残留（size=' + $restartSidecar.shm_size_bytes + '），但 -wal 为 0 字节、无未提交数据；不构成数据残留')
    }
    else {
        Add-VerifyCheck -Name 'persistence.shm_after_restart' -Status 'FAIL' -Detail ('-shm 残留且 -wal 含数据：-wal size=' + $restartSidecar.wal_size_bytes + '；-shm size=' + $restartSidecar.shm_size_bytes)
    }

    $persistenceProbeJson = Join-Path $evidenceDir 'persistence-db-after-restart.json'
    $persistenceProbe = Invoke-SqliteProbe -ProbeScriptPath $probeScript -DatabasePath $case1DatabasePath -JsonOutPath $persistenceProbeJson -Action 'inspect'
    Register-ProbeReport -Label 'persistence-db-after-restart' -JsonPath $persistenceProbeJson -ProbeResult $persistenceProbe
    $persistenceInspection = $null
    if ($null -ne $persistenceProbe.json) {
        $persistenceInspection = $persistenceProbe.json.inspection
    }
    if ($null -ne $persistenceInspection) {
        Write-VerifyJsonEvidence -Label 'persistence 重启后 SQLite 检查关键字段' -JsonText (ConvertTo-Json -InputObject ([ordered]@{
                    user_version             = $persistenceInspection.user_version
                    integrity_check          = $persistenceInspection.integrity_check
                    journal_mode             = $persistenceInspection.journal_mode
                    schema_migrations_count  = $persistenceInspection.schema_migrations_count
                    schema_migrations        = $persistenceInspection.schema_migrations
                    settings_canary          = $persistenceInspection.settings_canary
                    tables                   = $persistenceInspection.tables
                }) -Depth 8)
    }
    Add-DatabaseInspectionChecks -Inspection $persistenceInspection -Prefix 'persistence.after_restart' -ExpectedCanaryValue $canaryValue

    [void]$script:PortableCaseResults.Add([ordered]@{
            case               = 'case2-persistence'
            directory          = $caseDir
            exe                = $appExe
            database_path      = $case1DatabasePath
            canary_value       = $canaryValue
            restart_window_title = $persistenceWindowTitle
            restart_exit_code  = $persistenceExitCode
            database_inspection = $persistenceInspection
        })

    # =======================================================================
    # 用例 3：Release 忽略 WORKMANAGER_TEST_PORTABLE_ROOT（f）
    # =======================================================================
    Write-VerifySection '用例 3：Release 忽略 WORKMANAGER_TEST_PORTABLE_ROOT'
    $envCaseName = 'case2-env-ignore'
    $envCaseDir = New-PortableCaseDirectory -OutputDir $OutputDir -CaseName $envCaseName
    $envAppExe = Join-Path $envCaseDir 'WorkManager.exe'
    Copy-Item -LiteralPath $ExePath -Destination $envAppExe -Force
    $envCopiedSha256 = Get-FileSha256 -Path $envAppExe
    if ($envCopiedSha256 -eq $exeSha256) {
        Add-VerifyCheck -Name 'env.exe_copy_sha256_matches' -Status 'PASS' -Detail ('sha256=' + $envCopiedSha256)
    }
    else {
        Add-VerifyCheck -Name 'env.exe_copy_sha256_matches' -Status 'FAIL' -Detail '复制文件 SHA-256 与源不一致'
    }
    $decoyRoot = Join-Path $envCaseDir 'decoy-portable-root'
    New-Item -ItemType Directory -Path $decoyRoot -Force | Out-Null
    $decoySnapshotBefore = Get-DirectorySnapshot -Path $decoyRoot -MaxDepth 2
    Add-VerifyCheck -Name 'env.decoy_root_empty_before' -Status 'INFO' -Detail ('诱饵目录初始条目数=' + @($decoySnapshotBefore.entries).Count + '；' + $decoyRoot)

    $environmentVariableName = 'WORKMANAGER_TEST_PORTABLE_ROOT'
    $savedEnvironmentValue = [Environment]::GetEnvironmentVariable($environmentVariableName, 'Process')
    Write-VerifyLog -Message ('进程级 ' + $environmentVariableName + ' 原值=' + [string]$savedEnvironmentValue + '；用例期间临时设置为诱饵目录：' + $decoyRoot) -Level 'STEP'
    $envStdout = Join-Path $evidenceDir 'case2-env-ignore-stdout.log'
    $envStderr = Join-Path $evidenceDir 'case2-env-ignore-stderr.log'
    $envStart = Start-PortableVerificationApp -ExePath $envAppExe -WorkingDirectory $envCaseDir -StdoutLogPath $envStdout -StderrLogPath $envStderr -EnvironmentOverrides @{ $environmentVariableName = $decoyRoot }
    $environmentAfterStart = [Environment]::GetEnvironmentVariable($environmentVariableName, 'Process')
    $environmentRestored = (([string]$environmentAfterStart) -eq ([string]$savedEnvironmentValue))
    if ($environmentRestored) {
        Add-VerifyCheck -Name 'env.override_restored_after_start' -Status 'PASS' -Detail ('子进程启动后父进程环境变量已恢复：' + [string]$environmentAfterStart)
    }
    else {
        Add-VerifyCheck -Name 'env.override_restored_after_start' -Status 'FAIL' -Detail ('父进程环境变量未恢复：期望=' + [string]$savedEnvironmentValue + '；实际=' + [string]$environmentAfterStart)
    }

    $envWindow = Wait-MainWindow -Process $envStart.process -TitlePattern '*WorkManager*' -TimeoutSeconds $script:VerifyDefaultWindowTimeoutSeconds
    if ($envWindow.found) {
        $envIgnoreWindowTitle = [string]$envWindow.title
        Add-VerifyCheck -Name 'env.main_window_visible' -Status 'PASS' -Detail ('title=' + $envWindow.title + '；elapsed_ms=' + $envWindow.elapsed_ms)
        if ($envWindow.title -eq $script:WorkManagerAppTitle) {
            Add-VerifyCheck -Name 'env.main_window_title' -Status 'PASS' -Detail ('窗口标题=' + $envWindow.title)
        }
        else {
            Add-VerifyCheck -Name 'env.main_window_title' -Status 'FAIL' -Detail ('窗口标题=' + $envWindow.title + '（期望 ' + $script:WorkManagerAppTitle + '）')
        }
    }
    else {
        Add-VerifyCheck -Name 'env.main_window_visible' -Status 'FAIL' -Detail ('未找到主窗口；process_exited=' + $envWindow.process_exited + '；exit_code=' + [string]$envWindow.exit_code)
    }
    $envStop = Close-PortableApplication -Started $envStart -Label 'case2 环境变量隔离'
    $envIgnoreExitCode = $envStop.exit_code
    Add-ApplicationStopChecks -StopResult $envStop -Prefix 'env'

    $envDatabasePath = Join-Path $envCaseDir 'data\database\work.db'
    $decoyDatabasePath = Join-Path $decoyRoot 'database\work.db'
    if (Test-Path -LiteralPath $envDatabasePath -PathType Leaf) {
        Add-VerifyCheck -Name 'env.database_created_adjacent_to_exe' -Status 'PASS' -Detail ('数据库位于 EXE 同级 data/：' + $envDatabasePath)
    }
    else {
        Add-VerifyCheck -Name 'env.database_created_adjacent_to_exe' -Status 'FAIL' -Detail ('EXE 同级 data/database/work.db 不存在：' + $envDatabasePath)
    }
    if (Test-Path -LiteralPath $decoyDatabasePath) {
        Add-VerifyCheck -Name 'env.decoy_database_not_created' -Status 'FAIL' -Detail ('诱饵目录中出现数据库：' + $decoyDatabasePath)
    }
    else {
        Add-VerifyCheck -Name 'env.decoy_database_not_created' -Status 'PASS' -Detail ('诱饵目录中未创建数据库：' + $decoyDatabasePath)
    }
    $decoySnapshotAfter = Get-DirectorySnapshot -Path $decoyRoot -MaxDepth 3 -MaxEntries 100
    $decoySnapshotPath = Join-Path $evidenceDir 'case2-decoy-root-snapshot.json'
    Save-VerifyJsonFile -Path $decoySnapshotPath -Object $decoySnapshotAfter -Depth 10 | Out-Null
    Register-VerifyArtifact -Label 'case2 诱饵目录快照 JSON' -Path $decoySnapshotPath
    $decoyEntryCountAfter = @($decoySnapshotAfter.entries).Count
    if ($decoyEntryCountAfter -eq 0) {
        Add-VerifyCheck -Name 'env.decoy_root_still_empty' -Status 'PASS' -Detail ('诱饵目录仍为空：' + $decoyRoot)
    }
    else {
        Add-VerifyCheck -Name 'env.decoy_root_still_empty' -Status 'FAIL' -Detail ('诱饵目录出现 ' + $decoyEntryCountAfter + ' 个条目，Release 未忽略环境变量：' + $decoyRoot)
    }
    if (Test-Path -LiteralPath $envDatabasePath -PathType Leaf) {
        $envProbeJson = Join-Path $evidenceDir 'case2-env-ignore-db.json'
        $envProbe = Invoke-SqliteProbe -ProbeScriptPath $probeScript -DatabasePath $envDatabasePath -JsonOutPath $envProbeJson -Action 'inspect'
        Register-ProbeReport -Label 'case2-env-ignore-db' -JsonPath $envProbeJson -ProbeResult $envProbe
        $envInspection = $null
        if ($null -ne $envProbe.json) {
            $envInspection = $envProbe.json.inspection
        }
        Add-DatabaseInspectionChecks -Inspection $envInspection -Prefix 'env'
    }
    [void]$script:PortableCaseResults.Add([ordered]@{
            case                  = $envCaseName
            directory             = $envCaseDir
            exe                   = $envAppExe
            database_path         = $envDatabasePath
            decoy_root            = $decoyRoot
            decoy_entry_count     = $decoyEntryCountAfter
            window_title          = $envIgnoreWindowTitle
            exit_code             = $envIgnoreExitCode
        })
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
    foreach ($trackedProcess in @($script:PortableActiveProcesses)) {
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

    # --- 清理本脚本创建的用例沙箱目录（证据目录保留）---
    if ($KeepCaseDirectories) {
        Add-VerifyCheck -Name 'cleanup.case_directories' -Status 'INFO' -Detail ('-KeepCaseDirectories 已指定，保留用例沙箱：' + (@($script:PortableCaseDirectories) -join '; '))
    }
    else {
        $failedCleanupCount = 0
        foreach ($caseDirectoryPath in @($script:PortableCaseDirectories)) {
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
# C 盘边界抽查（启动前后对比，独立于应用是否启动成功）
# ===========================================================================
Write-VerifySection 'C 盘边界抽查（所有用例结束后）'
$cDriveAfter = Get-CDriveBoundarySnapshot -Label 'after'
$cDriveAfterPath = Join-Path $evidenceDir 'c-drive-boundary-after.json'
Save-VerifyJsonFile -Path $cDriveAfterPath -Object $cDriveAfter -Depth 8 | Out-Null
Register-VerifyArtifact -Label 'C 盘边界快照 JSON（after）' -Path $cDriveAfterPath
Add-CDriveBoundaryChecks -Baseline $cDriveBaseline -After $cDriveAfter -Prefix 'c_drive'
Write-VerifyJsonEvidence -Label 'C 盘边界快照（before/after）' -JsonText (ConvertTo-Json -InputObject ([ordered]@{
            before = $cDriveBaseline
            after  = $cDriveAfter
        }) -Depth 10)

# ===========================================================================
# 汇总
# ===========================================================================
$metadata = [ordered]@{
    release_exe = [ordered]@{
        path       = $ExePath
        size_bytes = $exeSizeBytes
        sha256     = $exeSha256
    }
    python = [ordered]@{
        path           = $pythonInfo.path
        version        = $pythonInfo.version
        sqlite_version = $pythonInfo.sqlite_version
    }
    canary_value   = $canaryValue
    keep_case_directories = [bool]$KeepCaseDirectories
    c_drive_boundary = [ordered]@{
        before = $cDriveBaseline
        after  = $cDriveAfter
    }
    running_database_snapshot = $runningDbSnapshot
    case_results   = @($script:PortableCaseResults)
    probe_reports  = @($script:PortableProbeReports)
}
$summaryResult = Write-VerifySummary -OutputDir $OutputDir -ScriptName 'verify-release-portable' -ExePath $ExePath -ExeSha256 $exeSha256 -ExeSizeBytes $exeSizeBytes -Metadata $metadata -FatalError $fatalError

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
