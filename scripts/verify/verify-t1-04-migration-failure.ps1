# WorkManager T1-04 Release migration failure rollback verification (T104-04)
#
# 构造真实 schema 3 隔离 UAT 数据库（真实 0001/0002/0003 SQL + 虚构历史数据），
# 从真实 0004 SQL 读取索引名并预先创建同名冲突索引；启动 Release EXE：
# - 必须显示原生“WorkManager 启动失败”对话框；
# - 进程退出码必须非 0；
# - migration 必须整体回滚：user_version 仍 3、无 version 4、无两个新表、
#   历史项目/工作事项不变、integrity_check=ok。
#
# 只操作 D:\WorkManager-test-data 下的独立 UAT，不打开/修改/故障注入正式目录。
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-04-migration-failure.ps1

[CmdletBinding()]
param(
    [string]$ExePath = '',
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory 'VerifyCommon.ps1')

if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $ExePath = Join-Path (Resolve-Path (Join-Path $scriptDirectory '..\..')).Path 'target\release\workmanager.exe'
}
if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    Write-Host "PRECONDITION_FAILED: Release EXE not found: $ExePath"
    exit 2
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = 'D:\WorkManager-test-data\t1-04-migration-failure-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
}

$testRoot = 'D:\WorkManager-test-data'
$formalRoot = 'D:\WorkManager'
$outputFull = [System.IO.Path]::GetFullPath($OutputDir)
if (-not $outputFull.StartsWith($testRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
    $outputFull.StartsWith($formalRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host 'PRECONDITION_FAILED: output directory must be under the isolated D-drive test root and outside the formal root'
    exit 2
}
if (Test-Path -LiteralPath $outputFull) {
    Write-Host 'PRECONDITION_FAILED: output directory already exists; use a new UAT directory'
    exit 2
}

$uat = Join-Path $outputFull 'migration-failure-uat'
$appDir = Join-Path $uat 'app'
$dbDir = Join-Path $appDir 'data\database'
$dbPath = Join-Path $dbDir 'work.db'
$fixtureScript = Join-Path $scriptDirectory 't1-04-migration-fixture.py'

$process = $null
try {
    New-Item -ItemType Directory -Force -Path $dbDir | Out-Null
    Copy-Item -LiteralPath $ExePath -Destination (Join-Path $appDir 'WorkManager.exe') -Force

    & python -X utf8 $fixtureScript setup (Resolve-Path (Join-Path $scriptDirectory '..\..')).Path $dbPath
    if ($LASTEXITCODE -ne 0) { throw 'schema 3 fixture setup failed' }

    $process = Start-Process -FilePath (Join-Path $appDir 'WorkManager.exe') -WorkingDirectory $appDir -PassThru
    $dialog = Wait-FailureDialog -Process $process -TimeoutSeconds 40
    Write-Host ("MIGRATION_FAILURE_DIALOG_FOUND=" + [bool]$dialog.found)
    Write-Host ("MIGRATION_FAILURE_DIALOG_TITLE=" + [string]$dialog.title)
    if (-not $dialog.found) {
        throw ('startup failure dialog not found; exited=' + [bool]$dialog.process_exited + '; exit=' + [string]$dialog.exit_code)
    }
    $closeMethod = Close-FailureDialog -Dialog $dialog -Process $process
    Write-Host "MIGRATION_FAILURE_DIALOG_CLOSE=$closeMethod"
    if (-not $process.WaitForExit(15000)) {
        throw 'process did not exit after failure dialog close'
    }
    $exitCode = $process.ExitCode
    Write-Host "MIGRATION_FAILURE_EXIT_CODE=$exitCode"
    if ($exitCode -eq 0) { throw 'migration failure unexpectedly exited 0' }

    $json = & python -X utf8 $fixtureScript probe $dbPath
    if ($LASTEXITCODE -ne 0) { throw 'post-failure read-only probe failed' }
    Write-Host "MIGRATION_FAILURE_DB=$json"
    $db = $json | ConvertFrom-Json
    if ($db.user_version -ne 3 -or $db.version4_rows -ne 0 -or $db.group_table -ne 0 -or
        $db.member_table -ne 0 -or $db.projects -ne 1 -or $db.work_items -ne 1 -or
        $db.integrity_check -ne 'ok') {
        throw ('migration rollback invariants failed: ' + $json)
    }
    Write-Host 'MIGRATION_FAILURE_ROLLBACK=PASS'
    exit 0
}
catch {
    Write-Host ('MIGRATION_FAILURE_ROLLBACK=FAIL: ' + $_.Exception.Message)
    exit 1
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        try { $process.Kill() } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
    }
    if (Test-Path -LiteralPath $uat) {
        try { Remove-Item -LiteralPath $uat -Recurse -Force } catch { }
    }
}
