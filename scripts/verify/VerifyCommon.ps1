# =============================================================================
# WorkManager T1-01 Release 运行时验证：公共函数库
#
# 用途：
#   - 供 scripts/verify/verify-release-portable.ps1 与 verify-release-faults.ps1 点源引用；
#   - 提供进程启动/停止（带超时上限）、主窗口等待、UI Automation 错误对话框读取
#     与关闭、窗口截图、目录树快照、SHA-256、SQLite（python 3）只读/写入查询、
#     检查项记录与 summary.json/report.txt 汇总输出。
#
# 约束（与 task-2 一致）：
#   - 仅 Windows PowerShell 5.1 兼容语法（不使用 ??、?.、三元运算符、
#     ForEach-Object -Parallel、-not 的现代别名等）；
#   - 本文件被点源时只定义函数与常量，不产生文件系统副作用；
#   - 所有测试数据目录必须位于 D:\WorkManager-test-data 下，禁止写入正式便携目录
#     D:\WorkManager。
#
# 说明：本文件必须以 UTF-8 with BOM 保存，否则 Windows PowerShell 5.1 会按系统
# ANSI 代码页解析中文，导致字符串比较（标题、错误消息）失效。
# =============================================================================

$script:WorkManagerAppTitle = 'WorkManager'
$script:WorkManagerFailureTitle = 'WorkManager 启动失败'
$script:WorkManagerFailureTitlePattern = '*WorkManager 启动失败*'
$script:VerifyTestDataRoot = 'D:\WorkManager-test-data'
$script:VerifyFormalReleaseRoot = 'D:\WorkManager'
$script:VerifyExpectedSchemaVersion = 3
$script:VerifyExpectedJournalMode = 'wal'
$script:VerifyExpectedBusyTimeoutMs = 5000
$script:VerifyDefaultWindowTimeoutSeconds = 60
$script:VerifyDefaultDialogTimeoutSeconds = 45
$script:VerifyGracefulExitTimeoutSeconds = 20
$script:VerifyKillTimeoutSeconds = 10
$script:VerifyPollIntervalMilliseconds = 300
$script:VerifyUiAutomationLoaded = $false
$script:VerifyCaptureNativeLoaded = $false
$script:VerifyPython = $null

# -----------------------------------------------------------------------------
# 上下文与日志
# -----------------------------------------------------------------------------
function Initialize-VerifyContext {
    param([Parameter(Mandatory = $true)][string]$ScriptName)

    $script:VerifyScriptName = $ScriptName
    $script:VerifyChecks = New-Object System.Collections.ArrayList
    $script:VerifyLogLines = New-Object System.Collections.ArrayList
    $script:VerifyArtifacts = New-Object System.Collections.ArrayList
    $script:VerifyStartedAt = Get-Date
    $script:VerifyPython = $null
}

function Write-VerifyLog {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'PASS', 'FAIL', 'WARN', 'STEP', 'EVID')][string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line = '[{0}][{1}] {2}' -f $stamp, $Level, $Message
    if ($null -ne $script:VerifyLogLines) {
        [void]$script:VerifyLogLines.Add($line)
    }
    Write-Host $line
}

function Write-VerifySection {
    param([Parameter(Mandatory = $true)][string]$Title)

    $line = '==================== ' + $Title + ' ===================='
    if ($null -ne $script:VerifyLogLines) {
        [void]$script:VerifyLogLines.Add('')
        [void]$script:VerifyLogLines.Add($line)
    }
    Write-Host ''
    Write-Host $line
}

function Write-VerifyJsonEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][AllowEmptyString()][string]$JsonText
    )

    Write-VerifyLog -Message ('--- JSON 证据开始: ' + $Label + ' ---') -Level 'EVID'
    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        Write-VerifyLog -Message '    (无 JSON 内容)' -Level 'WARN'
    }
    else {
        foreach ($line in ($JsonText -split "`r?`n")) {
            Write-VerifyLog -Message ('    ' + $line) -Level 'EVID'
        }
    }
    Write-VerifyLog -Message ('--- JSON 证据结束: ' + $Label + ' ---') -Level 'EVID'
}

# -----------------------------------------------------------------------------
# 检查项记录
# -----------------------------------------------------------------------------
function Add-VerifyCheck {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [Parameter(Mandatory = $true, Position = 1)][ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [AllowEmptyString()][string]$Detail = ''
    )

    $check = [pscustomobject]@{
        name       = $Name
        status     = $Status
        detail     = $Detail
        checked_at = (Get-Date).ToString('o')
    }
    if ($null -ne $script:VerifyChecks) {
        [void]$script:VerifyChecks.Add($check)
    }
    $message = $Name
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $message = $Name + ' :: ' + $Detail
    }
    Write-VerifyLog -Message $message -Level $Status
}

function Register-VerifyArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Kind = 'file'
    )

    $artifact = [pscustomobject]@{
        label  = $Label
        path   = $Path
        kind   = $Kind
        exists = (Test-Path -LiteralPath $Path)
    }
    if ($null -ne $script:VerifyArtifacts) {
        [void]$script:VerifyArtifacts.Add($artifact)
    }
}

# -----------------------------------------------------------------------------
# 文件与路径基础工具
# -----------------------------------------------------------------------------
function Save-Utf8TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Save-VerifyJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$Object,
        [int]$Depth = 12
    )

    $jsonText = ConvertTo-Json -InputObject $Object -Depth $Depth
    if ($null -eq $jsonText) {
        $jsonText = 'null'
    }
    Save-Utf8TextFile -Path $Path -Content ($jsonText + "`r`n")
    return $Path
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        return $null
    }
}

function Get-FileSizeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    }
    catch {
        return $null
    }
}

function Test-PathUnder {
    param(
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$ParentPath
    )

    try {
        $child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\')
        $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
    }
    catch {
        return $false
    }
    if ($child -eq $parent) {
        return $true
    }
    return $child.StartsWith($parent + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-VerifyCaseDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        Write-VerifyLog -Message ('清理：无法解析路径，跳过：' + $Path) -Level 'WARN'
        return $false
    }
    if (-not (Test-PathUnder -ChildPath $fullPath -ParentPath $script:VerifyTestDataRoot)) {
        Write-VerifyLog -Message ('清理：拒绝删除测试数据根目录之外的路径：' + $fullPath) -Level 'WARN'
        return $false
    }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        Write-VerifyLog -Message ('清理：用例目录已不存在：' + $fullPath) -Level 'INFO'
        return $true
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Start-Sleep -Milliseconds 400
        }
        if (-not (Test-Path -LiteralPath $fullPath)) {
            Write-VerifyLog -Message ('清理：已删除用例目录 ' + $Label + '：' + $fullPath) -Level 'INFO'
            return $true
        }
    }
    Write-VerifyLog -Message ('清理：用例目录删除失败 ' + $Label + '：' + $fullPath) -Level 'WARN'
    return $false
}

function Get-DirectorySnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxDepth = 3,
        [int]$MaxEntries = 300
    )

    $snapshot = [ordered]@{
        path        = $Path
        exists      = $false
        is_directory = $false
        captured_at = (Get-Date).ToString('o')
        truncated   = $false
        entries     = @()
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]$snapshot
    }

    $item = Get-Item -LiteralPath $Path -Force
    $snapshot.exists = $true
    $snapshot.is_directory = $item.PSIsContainer
    if (-not $item.PSIsContainer) {
        $snapshot.entries = @([pscustomobject]@{
                relative_path  = '.'
                type           = 'file'
                size_bytes     = $item.Length
                last_write_utc = $item.LastWriteTimeUtc.ToString('o')
            })
        return [pscustomobject]$snapshot
    }

    $root = $item.FullName.TrimEnd('\')
    $entries = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ path = $root; depth = 0 })

    while ($queue.Count -gt 0) {
        if ($entries.Count -ge $MaxEntries) {
            $snapshot.truncated = $true
            break
        }
        $current = $queue.Dequeue()
        $children = @()
        try {
            $children = @(Get-ChildItem -LiteralPath $current.path -Force -ErrorAction Stop)
        }
        catch {
            [void]$entries.Add([pscustomobject]@{
                    relative_path  = $current.path.Substring($root.Length).TrimStart('\')
                    type           = 'inaccessible'
                    size_bytes     = $null
                    last_write_utc = $null
                    error          = $_.Exception.Message
                })
            continue
        }
        foreach ($child in $children) {
            if ($entries.Count -ge $MaxEntries) {
                $snapshot.truncated = $true
                break
            }
            $relativePath = $child.FullName.Substring($root.Length).TrimStart('\')
            $isDirectory = $child.PSIsContainer
            $type = 'file'
            if ($isDirectory) {
                $type = 'directory'
            }
            elseif (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $type = 'reparse_point'
            }
            $sizeBytes = $null
            if (-not $isDirectory) {
                $sizeBytes = $child.Length
            }
            [void]$entries.Add([pscustomobject]@{
                    relative_path  = $relativePath
                    type           = $type
                    size_bytes     = $sizeBytes
                    last_write_utc = $child.LastWriteTimeUtc.ToString('o')
                })
            if ($isDirectory -and ($current.depth + 1) -lt $MaxDepth) {
                $queue.Enqueue([pscustomobject]@{ path = $child.FullName; depth = ($current.depth + 1) })
            }
        }
    }

    $snapshot.entries = @($entries)
    return [pscustomobject]$snapshot
}

function Get-SidecarState {
    param([Parameter(Mandatory = $true)][string]$DatabasePath)

    $result = [ordered]@{
        database_path      = $DatabasePath
        wal_path           = $DatabasePath + '-wal'
        shm_path           = $DatabasePath + '-shm'
        journal_path       = $DatabasePath + '-journal'
        wal_exists         = $false
        wal_size_bytes     = 0
        shm_exists         = $false
        shm_size_bytes     = 0
        journal_exists     = $false
        journal_size_bytes = 0
        captured_at        = (Get-Date).ToString('o')
    }

    foreach ($suffix in @('-wal', '-shm', '-journal')) {
        $sidecarPath = $DatabasePath + $suffix
        $exists = Test-Path -LiteralPath $sidecarPath -PathType Leaf
        $size = 0
        if ($exists) {
            $size = Get-FileSizeBytes -Path $sidecarPath
            if ($null -eq $size) {
                $size = 0
            }
        }
        if ($suffix -eq '-wal') {
            $result.wal_exists = $exists
            $result.wal_size_bytes = $size
        }
        elseif ($suffix -eq '-shm') {
            $result.shm_exists = $exists
            $result.shm_size_bytes = $size
        }
        else {
            $result.journal_exists = $exists
            $result.journal_size_bytes = $size
        }
    }
    return [pscustomobject]$result
}

# -----------------------------------------------------------------------------
# 环境前置检查：python、Release EXE、OutputDir
# -----------------------------------------------------------------------------
function Get-PythonRuntimeInfo {
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    # 注意：Windows PowerShell 5.1 向原生程序传递含双引号的 -c 代码会被剥离引号，
    # 因此这里使用不含双引号的单行 python 代码，并按行解析版本信息。
    $code = 'import sys,sqlite3;print(sys.version.split()[0]);print(sqlite3.sqlite_version)'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = $null
    $exitCode = $null
    try {
        $output = (& $PythonPath -c $code 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    catch {
        return $null
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
        return $null
    }
    $lines = @($output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -lt 2) {
        return $null
    }
    return [pscustomobject]@{
        path           = $PythonPath
        version        = $lines[0].Trim()
        sqlite_version = $lines[1].Trim()
    }
}

function Get-PythonExecutable {
    $candidates = New-Object System.Collections.ArrayList
    foreach ($commandName in @('python.exe', 'python')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            if (-not $candidates.Contains($command.Source)) {
                [void]$candidates.Add($command.Source)
            }
        }
    }
    foreach ($candidate in @($candidates)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $info = Get-PythonRuntimeInfo -PythonPath $candidate
        if ($null -ne $info) {
            return $info
        }
    }
    return $null
}

function Resolve-ReleaseExePath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExePath)

    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        Write-VerifyLog -Message '错误：参数 -ExePath 为空。' -Level 'FAIL'
        return $null
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($ExePath)
    }
    catch {
        Write-VerifyLog -Message ('错误：无法解析 -ExePath：' + $ExePath) -Level 'FAIL'
        return $null
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Write-VerifyLog -Message ('错误：Release EXE 不存在：' + $fullPath) -Level 'FAIL'
        Write-VerifyLog -Message '请先构建 Release 产物：在仓库根目录执行 npm run tauri build -- --no-bundle' -Level 'INFO'
        Write-VerifyLog -Message '默认预期产物：<repo>\target\release\workmanager.exe（Tauri --no-bundle 产物为包名小写；用例中会复制重命名为 WorkManager.exe）' -Level 'INFO'
        return $null
    }
    return $fullPath
}

function Resolve-VerifyOutputDir {
    param([AllowEmptyString()][string]$OutputDir = '')

    $requested = $OutputDir
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $requested = Join-Path $script:VerifyTestDataRoot ('release-verify-' + $stamp)
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($requested)
    }
    catch {
        Write-VerifyLog -Message ('错误：无法解析 -OutputDir：' + $requested) -Level 'FAIL'
        return $null
    }
    if (-not (Test-PathUnder -ChildPath $fullPath -ParentPath $script:VerifyTestDataRoot)) {
        Write-VerifyLog -Message ('错误：-OutputDir 必须位于测试数据根目录 ' + $script:VerifyTestDataRoot + ' 下：' + $fullPath) -Level 'FAIL'
        return $null
    }
    if ($fullPath.TrimEnd('\') -eq $script:VerifyTestDataRoot.TrimEnd('\')) {
        Write-VerifyLog -Message ('错误：-OutputDir 必须是 ' + $script:VerifyTestDataRoot + ' 的子目录，不能直接使用测试数据根目录。') -Level 'FAIL'
        return $null
    }
    if (Test-PathUnder -ChildPath $fullPath -ParentPath $script:VerifyFormalReleaseRoot) {
        Write-VerifyLog -Message ('错误：拒绝向正式便携目录写入测试数据：' + $fullPath) -Level 'FAIL'
        return $null
    }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        Write-VerifyLog -Message ('错误：-OutputDir 已存在且是文件，不是目录：' + $fullPath) -Level 'FAIL'
        return $null
    }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        try {
            New-Item -ItemType Directory -Path $fullPath -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-VerifyLog -Message ('错误：无法创建 -OutputDir：' + $fullPath + '；' + $_.Exception.Message) -Level 'FAIL'
            return $null
        }
    }
    return $fullPath
}

# -----------------------------------------------------------------------------
# SQLite 验证：python 探针脚本
# -----------------------------------------------------------------------------
function Ensure-SqliteProbeScript {
    param([Parameter(Mandatory = $true)][string]$OutputDir)

    $toolsDir = Join-Path $OutputDir 'tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }
    $probePath = Join-Path $toolsDir 'sqlite_probe.py'
    $probeSource = @'
"""WorkManager T1-01 SQLite verification probe.

Read-only inspection by default; optional canary insert for persistence tests.
All evidence is emitted as JSON so the PowerShell caller never depends on console
encoding. Standard library only (sqlite3, json, urllib.parse).
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys
import urllib.parse


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime(
        '%Y-%m-%dT%H:%M:%SZ'
    )


def file_metadata(path):
    if not os.path.isfile(path):
        return {'exists': os.path.exists(path), 'is_file': False, 'size_bytes': None}
    return {'exists': True, 'is_file': True, 'size_bytes': os.path.getsize(path)}


def sidecar_metadata(path):
    sidecars = {}
    for suffix in ('-wal', '-shm', '-journal'):
        sidecar_path = path + suffix
        exists = os.path.exists(sidecar_path)
        sidecars[suffix] = {
            'path': sidecar_path,
            'exists': exists,
            'size_bytes': os.path.getsize(sidecar_path) if exists else 0,
        }
    return sidecars


def sqlite_header(path):
    info = {
        'exists': False,
        'magic': None,
        'page_size': None,
        'write_version': None,
        'read_version': None,
    }
    if not os.path.isfile(path):
        return info
    with open(path, 'rb') as handle:
        header = handle.read(100)
    info['exists'] = True
    if len(header) >= 16:
        info['magic'] = header[:16].decode('ascii', 'replace')
    if len(header) >= 18:
        info['page_size'] = int.from_bytes(header[16:18], 'big')
    if len(header) >= 20:
        info['write_version'] = header[18]
        info['read_version'] = header[19]
    return info


def build_uri(path, parameters):
    posix_path = path.replace('\\', '/')
    quoted_path = urllib.parse.quote(posix_path, safe='/:')
    return 'file:' + quoted_path + '?' + parameters


def open_read_only(path):
    errors = []
    for parameters in ('mode=ro', 'mode=ro&immutable=1'):
        uri = build_uri(path, parameters)
        connection = None
        try:
            connection = sqlite3.connect(uri, uri=True, timeout=5.0)
            connection.execute('SELECT 1').fetchone()
            return connection, parameters, errors
        except sqlite3.Error as error:
            errors.append({
                'parameters': parameters,
                'error': type(error).__name__ + ': ' + str(error),
            })
            if connection is not None:
                try:
                    connection.close()
                except sqlite3.Error:
                    pass
    raise RuntimeError('read-only open failed: ' + json.dumps(errors, ensure_ascii=True))


def pragma_value(connection, pragma):
    return connection.execute('PRAGMA ' + pragma).fetchone()[0]


def inspect_database(path):
    report = {
        'database_path': path,
        'database': file_metadata(path),
        'header': sqlite_header(path),
        'sidecars_before_open': sidecar_metadata(path),
        'open_mode': None,
        'open_errors': [],
        'user_version': None,
        'integrity_check': None,
        'journal_mode': None,
        'probe_connection_pragmas': {},
        'tables': [],
        'schema_migrations': [],
        'schema_migrations_count': 0,
        'settings_row_count': None,
        'settings_canary': None,
        'foreign_key_check': [],
        'sidecars_after_close': None,
    }
    connection, parameters, errors = open_read_only(path)
    report['open_mode'] = parameters
    report['open_errors'] = errors
    try:
        report['user_version'] = pragma_value(connection, 'user_version')
        report['integrity_check'] = [
            row[0] for row in connection.execute('PRAGMA integrity_check').fetchall()
        ]
        report['journal_mode'] = pragma_value(connection, 'journal_mode')
        for pragma in (
            'foreign_keys',
            'synchronous',
            'busy_timeout',
            'temp_store',
            'page_size',
            'page_count',
        ):
            report['probe_connection_pragmas'][pragma] = pragma_value(connection, pragma)
        report['tables'] = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            ).fetchall()
        ]
        if 'schema_migrations' in report['tables']:
            rows = connection.execute(
                'SELECT version, name, applied_at FROM schema_migrations ORDER BY version'
            ).fetchall()
            report['schema_migrations'] = [
                {'version': row[0], 'name': row[1], 'applied_at': row[2]} for row in rows
            ]
            report['schema_migrations_count'] = len(rows)
        if 'settings' in report['tables']:
            report['settings_row_count'] = connection.execute(
                'SELECT COUNT(*) FROM settings'
            ).fetchone()[0]
            canary = connection.execute(
                "SELECT key, value_json, updated_at FROM settings WHERE key = 'test-canary'"
            ).fetchone()
            if canary is not None:
                report['settings_canary'] = {
                    'key': canary[0],
                    'value_json': canary[1],
                    'updated_at': canary[2],
                }
        report['foreign_key_check'] = [
            {'table': row[0], 'rowid': row[1], 'parent': row[2], 'fkid': row[3]}
            for row in connection.execute('PRAGMA foreign_key_check').fetchall()
        ]
    finally:
        connection.close()
    report['sidecars_after_close'] = sidecar_metadata(path)
    return report


def insert_canary(path, value):
    if not os.path.isfile(path):
        raise RuntimeError('database file does not exist; refusing to create: ' + path)
    connection = sqlite3.connect(path, timeout=10.0)
    try:
        connection.execute('PRAGMA busy_timeout = 5000')
        connection.execute('PRAGMA foreign_keys = ON')
        connection.execute(
            "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-canary', ?, ?) "
            'ON CONFLICT(key) DO UPDATE SET '
            'value_json = excluded.value_json, updated_at = excluded.updated_at',
            (json.dumps({'value': value}), utc_now()),
        )
        connection.commit()
        row = connection.execute(
            "SELECT value_json, updated_at FROM settings WHERE key = 'test-canary'"
        ).fetchone()
    finally:
        connection.close()
    return {'value': value, 'value_json': row[0], 'updated_at': row[1]}


def main(argv):
    parser = argparse.ArgumentParser(description='WorkManager SQLite verification probe')
    parser.add_argument('--database', required=True)
    parser.add_argument('--action', choices=('inspect', 'insert-canary'), default='inspect')
    parser.add_argument('--canary-value', default='')
    parser.add_argument('--json-out', default='')
    parsed = parser.parse_args(argv)

    payload = {
        'ok': False,
        'action': parsed.action,
        'checked_at': utc_now(),
        'python_version': sys.version.split()[0],
        'sqlite_version': sqlite3.sqlite_version,
        'error': None,
        'inserted_canary': None,
        'inspection': None,
    }
    exit_code = 0
    try:
        if parsed.action == 'insert-canary':
            payload['inserted_canary'] = insert_canary(
                parsed.database, parsed.canary_value
            )
        payload['inspection'] = inspect_database(parsed.database)
        payload['ok'] = True
    except Exception as error:  # noqa: BLE001 - evidence probe must always emit JSON
        payload['error'] = type(error).__name__ + ': ' + str(error)
        exit_code = 1

    json_text = json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True)
    if parsed.json_out:
        with open(parsed.json_out, 'w', encoding='utf-8') as handle:
            handle.write(json_text)
            handle.write('\n')
    sys.stdout.write(json_text + '\n')
    return exit_code


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
'@
    Save-Utf8TextFile -Path $probePath -Content $probeSource
    return $probePath
}

function Invoke-SqliteProbe {
    param(
        [Parameter(Mandatory = $true)][string]$ProbeScriptPath,
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$JsonOutPath,
        [ValidateSet('inspect', 'insert-canary')][string]$Action = 'inspect',
        [AllowEmptyString()][string]$CanaryValue = ''
    )

    $result = [ordered]@{
        ok        = $false
        exit_code = $null
        json      = $null
        json_path = $JsonOutPath
        database  = $DatabasePath
        action    = $Action
        error     = $null
        output    = ''
    }

    if ($null -eq $script:VerifyPython) {
        $result.error = 'python 不可用，无法执行 SQLite 验证'
        return [pscustomobject]$result
    }

    $jsonParent = Split-Path -Parent $JsonOutPath
    if (-not [string]::IsNullOrWhiteSpace($jsonParent) -and -not (Test-Path -LiteralPath $jsonParent)) {
        New-Item -ItemType Directory -Path $jsonParent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $JsonOutPath) {
        Remove-Item -LiteralPath $JsonOutPath -Force -ErrorAction SilentlyContinue
    }

    $probeArguments = @(
        $ProbeScriptPath,
        '--database', $DatabasePath,
        '--action', $Action,
        '--json-out', $JsonOutPath
    )
    if ($Action -eq 'insert-canary') {
        $probeArguments += @('--canary-value', $CanaryValue)
    }

    $rawLines = New-Object System.Collections.ArrayList
    $exitCode = $null
    $launchError = $null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:VerifyPython.path @probeArguments 2>&1
        $exitCode = $LASTEXITCODE
        foreach ($line in @($raw)) {
            [void]$rawLines.Add([string]$line)
        }
    }
    catch {
        $launchError = $_.Exception.Message
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $result.exit_code = $exitCode
    $result.output = ($rawLines -join "`n")
    if ($null -ne $launchError) {
        $result.error = 'python 调用失败：' + $launchError
        return [pscustomobject]$result
    }

    $payload = $null
    if (Test-Path -LiteralPath $JsonOutPath -PathType Leaf) {
        $payload = Read-JsonFile -Path $JsonOutPath
    }
    if ($null -eq $payload) {
        $result.error = 'python 未生成 JSON 结果文件；exit_code=' + [string]$exitCode + '；输出：' + $result.output
        return [pscustomobject]$result
    }

    $result.json = $payload
    if ($null -ne $payload.PSObject.Properties['ok'] -and $payload.ok -eq $true) {
        $result.ok = $true
    }
    else {
        $errorText = 'python 探针返回 ok=false'
        if ($null -ne $payload.PSObject.Properties['error'] -and $null -ne $payload.error) {
            $errorText = $errorText + '；error=' + [string]$payload.error
        }
        $result.error = $errorText
    }
    return [pscustomobject]$result
}

# -----------------------------------------------------------------------------
# 进程启动 / 主窗口等待 / 停止（全部带超时上限）
# -----------------------------------------------------------------------------
function Start-AppProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [string]$WorkingDirectory = '',
        [string]$StdoutLogPath = '',
        [string]$StderrLogPath = '',
        [System.Collections.IDictionary]$EnvironmentOverrides = $null
    )

    # 说明：PowerShell 5.1 的 Start-Process -PassThru 与 -RedirectStandardOutput 组合
    # 在进程退出后无法可靠读取 ExitCode（实测返回空值），因此这里直接使用
    # System.Diagnostics.Process + 异步 ReadToEndAsync 捕获输出，确保退出码可靠。
    $savedEnvironment = @{}
    if ($null -ne $EnvironmentOverrides) {
        foreach ($name in $EnvironmentOverrides.Keys) {
            $savedEnvironment[[string]$name] = [Environment]::GetEnvironmentVariable([string]$name, 'Process')
            [Environment]::SetEnvironmentVariable([string]$name, [string]$EnvironmentOverrides[$name], 'Process')
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ExePath
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    $startInfo.UseShellExecute = $false
    $redirectOutput = ((-not [string]::IsNullOrWhiteSpace($StdoutLogPath)) -or (-not [string]::IsNullOrWhiteSpace($StderrLogPath)))
    if ($redirectOutput) {
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedAt = Get-Date
    $stdoutTask = $null
    $stderrTask = $null
    try {
        [void]$process.Start()
        if ($redirectOutput) {
            # 启动后立即开始异步读取，避免子进程输出填满管道导致阻塞。
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }
    }
    finally {
        # 子进程创建后立即恢复父进程环境变量，避免污染后续用例。
        if ($null -ne $EnvironmentOverrides) {
            foreach ($name in $EnvironmentOverrides.Keys) {
                $previousValue = $savedEnvironment[[string]$name]
                if ($null -eq $previousValue) {
                    [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process')
                }
                else {
                    [Environment]::SetEnvironmentVariable([string]$name, [string]$previousValue, 'Process')
                }
            }
        }
    }

    return [pscustomobject]@{
        process               = $process
        started_at            = $startedAt
        exe_path              = $ExePath
        working_directory     = $WorkingDirectory
        stdout_log_path       = $StdoutLogPath
        stderr_log_path       = $StderrLogPath
        stdout_task           = $stdoutTask
        stderr_task           = $stderrTask
        output_redirected     = $redirectOutput
        environment_overrides = $EnvironmentOverrides
    }
}

function Save-AppProcessOutput {
    param(
        [Parameter(Mandatory = $true)]$Started,
        [int]$WaitMilliseconds = 5000
    )

    $result = [ordered]@{
        stdout            = ''
        stderr            = ''
        saved_stdout_path = $null
        saved_stderr_path = $null
        error             = $null
        timed_out         = $false
    }
    if ($null -eq $Started -or $null -eq $Started.process) {
        return [pscustomobject]$result
    }

    foreach ($streamKind in @('stdout', 'stderr')) {
        $task = $null
        $logPath = $null
        if ($streamKind -eq 'stdout') {
            $task = $Started.stdout_task
            $logPath = $Started.stdout_log_path
        }
        else {
            $task = $Started.stderr_task
            $logPath = $Started.stderr_log_path
        }
        if ($null -ne $task) {
            try {
                if ($task.Wait($WaitMilliseconds)) {
                    $result[$streamKind] = [string]$task.Result
                }
                else {
                    $result.timed_out = $true
                    $result.error = '读取进程输出超时：可能有子进程继续持有输出管道'
                }
            }
            catch {
                $result.error = $_.Exception.Message
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($logPath)) {
            Save-Utf8TextFile -Path $logPath -Content ([string]$result[$streamKind])
            $result['saved_' + $streamKind + '_path'] = $logPath
        }
    }
    return [pscustomobject]$result
}
function Wait-MainWindow {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [string]$TitlePattern = '*WorkManager*',
        [int]$TimeoutSeconds = $script:VerifyDefaultWindowTimeoutSeconds
    )

    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $title = $null
    $handle = [IntPtr]::Zero
    $exited = $false
    $exitCode = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $Process.Refresh()
            $exited = $Process.HasExited
        }
        catch {
            $exited = $true
        }
        if ($exited) {
            try {
                $exitCode = $Process.ExitCode
            }
            catch {
                $exitCode = $null
            }
            break
        }
        $candidateHandle = [IntPtr]::Zero
        $candidateTitle = $null
        try {
            $candidateHandle = [IntPtr]$Process.MainWindowHandle
        }
        catch {
            $candidateHandle = [IntPtr]::Zero
        }
        if ($candidateHandle -ne [IntPtr]::Zero) {
            try {
                $candidateTitle = $Process.MainWindowTitle
            }
            catch {
                $candidateTitle = $null
            }
            if (-not [string]::IsNullOrWhiteSpace($candidateTitle)) {
                $isFailureDialog = $candidateTitle -like '*启动失败*'
                if ((-not $isFailureDialog) -and ($candidateTitle -like $TitlePattern)) {
                    $title = $candidateTitle
                    $handle = $candidateHandle
                    break
                }
            }
        }
        Start-Sleep -Milliseconds $script:VerifyPollIntervalMilliseconds
    }

    if (-not $exited) {
        try {
            $Process.Refresh()
            $exited = $Process.HasExited
            if ($exited) {
                $exitCode = $Process.ExitCode
            }
        }
        catch {
        }
    }
    $elapsedMs = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
    $found = ($null -ne $title)
    return [pscustomobject]@{
        found           = $found
        title           = $title
        hwnd            = $handle.ToInt64()
        elapsed_ms      = $elapsedMs
        timed_out       = ((-not $found) -and (-not $exited))
        process_exited  = $exited
        exit_code       = $exitCode
        title_pattern   = $TitlePattern
    }
}

function Stop-AppProcess {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$GracefulTimeoutSeconds = $script:VerifyGracefulExitTimeoutSeconds,
        [int]$KillTimeoutSeconds = $script:VerifyKillTimeoutSeconds
    )

    $started = Get-Date
    $method = 'none'
    $exited = $false

    try {
        $Process.Refresh()
        $exited = $Process.HasExited
    }
    catch {
        $exited = $true
    }

    if ($exited) {
        $method = 'already-exited'
    }
    else {
        try {
            if ($Process.CloseMainWindow()) {
                $method = 'CloseMainWindow'
            }
        }
        catch {
        }
        if ($method -eq 'CloseMainWindow') {
            try {
                $exited = $Process.WaitForExit($GracefulTimeoutSeconds * 1000)
            }
            catch {
                $exited = $false
            }
        }
        else {
            # 没有可关闭的主窗口：短暂等待自然退出，随后强制结束，避免误杀。
            Start-Sleep -Milliseconds 500
            try {
                $Process.Refresh()
                $exited = $Process.HasExited
            }
            catch {
                $exited = $true
            }
        }
        if (-not $exited) {
            try {
                $Process.Kill()
                $method = $method + '+Kill'
            }
            catch {
                $method = $method + '+KillFailed'
            }
            try {
                $exited = $Process.WaitForExit($KillTimeoutSeconds * 1000)
            }
            catch {
                $exited = $false
            }
        }
    }

    $exitCode = $null
    if ($exited) {
        try {
            $Process.Refresh()
            $exitCode = $Process.ExitCode
        }
        catch {
            $exitCode = $null
        }
    }
    return [pscustomobject]@{
        exited     = $exited
        exit_code  = $exitCode
        method     = $method
        elapsed_ms = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
    }
}

function Wait-ProcessExit {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = $script:VerifyGracefulExitTimeoutSeconds,
        [int]$KillTimeoutSeconds = $script:VerifyKillTimeoutSeconds
    )

    $started = Get-Date
    $exited = $false
    $hadToKill = $false
    try {
        $exited = $Process.WaitForExit($TimeoutSeconds * 1000)
    }
    catch {
        $exited = $false
    }
    if (-not $exited) {
        try {
            $Process.Kill()
            $hadToKill = $true
        }
        catch {
        }
        try {
            $exited = $Process.WaitForExit($KillTimeoutSeconds * 1000)
        }
        catch {
            $exited = $false
        }
    }
    $exitCode = $null
    if ($exited) {
        try {
            $Process.Refresh()
            $exitCode = $Process.ExitCode
        }
        catch {
            $exitCode = $null
        }
    }
    return [pscustomobject]@{
        exited      = $exited
        exit_code   = $exitCode
        had_to_kill = $hadToKill
        elapsed_ms  = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
    }
}

# -----------------------------------------------------------------------------
# UI Automation：查找/读取/关闭 “WorkManager 启动失败” MessageBox
# -----------------------------------------------------------------------------
function Initialize-UiAutomation {
    if ($script:VerifyUiAutomationLoaded) {
        return
    }
    Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
    $script:VerifyUiAutomationLoaded = $true
}

function Get-ProcessTopWindows {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    Initialize-UiAutomation
    $windows = New-Object System.Collections.ArrayList
    try {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $processIdProperty = [System.Windows.Automation.AutomationElement]::ProcessIdProperty
        $condition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList $processIdProperty, $ProcessId
        $collection = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
        for ($index = 0; $index -lt $collection.Count; $index++) {
            $element = $collection.Item($index)
            try {
                [void]$windows.Add([pscustomobject]@{
                        element              = $element
                        name                 = $element.Current.Name
                        class_name           = $element.Current.ClassName
                        automation_id        = $element.Current.AutomationId
                        control_type         = $element.Current.ControlType.ProgrammaticName
                        native_window_handle = $element.Current.NativeWindowHandle
                    })
            }
            catch {
            }
        }
    }
    catch {
    }
    return @($windows)
}

function Read-DialogContent {
    param([Parameter(Mandatory = $true)]$Element)

    $texts = New-Object System.Collections.ArrayList
    $textDetails = New-Object System.Collections.ArrayList
    $buttonNames = New-Object System.Collections.ArrayList
    $buttonElements = New-Object System.Collections.ArrayList

    try {
        $descendants = $Element.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        for ($index = 0; $index -lt $descendants.Count; $index++) {
            $child = $descendants.Item($index)
            try {
                $name = $child.Current.Name
                $controlType = $child.Current.ControlType
                $controlTypeName = $controlType.ProgrammaticName
                $className = $child.Current.ClassName
                # 标准 Win32 MessageBox 的按钮在部分 UIA 提供程序下被报告为
                # ControlType.Pane（class=Button），因此同时接受两种判定。
                $isButton = ($controlTypeName -eq 'ControlType.Button') -or ($className -eq 'Button')
                if ($isButton) {
                    if ([string]::IsNullOrWhiteSpace($name)) {
                        [void]$buttonNames.Add('<unnamed-button>')
                    }
                    else {
                        [void]$buttonNames.Add($name)
                    }
                    [void]$buttonElements.Add($child)
                    continue
                }
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    [void]$texts.Add($name)
                    [void]$textDetails.Add([pscustomobject]@{
                            name           = $name
                            control_type   = $controlTypeName
                            class_name     = $className
                            automation_id  = $child.Current.AutomationId
                        })
                }
            }
            catch {
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        texts           = @($texts)
        text_details    = @($textDetails)
        button_names    = @($buttonNames)
        button_elements = @($buttonElements)
    }
}

function Wait-FailureDialog {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = $script:VerifyDefaultDialogTimeoutSeconds,
        [string]$TitlePattern = '*WorkManager 启动失败*'
    )

    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $dialogWindow = $null
    $exited = $false
    $exitCode = $null
    $topWindowNames = @()

    while ((Get-Date) -lt $deadline) {
        try {
            $Process.Refresh()
            $exited = $Process.HasExited
        }
        catch {
            $exited = $true
        }
        if ($exited) {
            try {
                $exitCode = $Process.ExitCode
            }
            catch {
                $exitCode = $null
            }
            break
        }
        $topWindows = @(Get-ProcessTopWindows -ProcessId $Process.Id)
        if ($topWindows.Count -gt 0) {
            $topWindowNames = @($topWindows | ForEach-Object { $_.name })
        }
        foreach ($window in $topWindows) {
            if ($window.name -like $TitlePattern) {
                $dialogWindow = $window
                break
            }
        }
        if ($null -ne $dialogWindow) {
            break
        }
        Start-Sleep -Milliseconds $script:VerifyPollIntervalMilliseconds
    }

    $uiaFallback = $false
    $title = $null
    $hwnd = 0
    $className = $null
    $content = [pscustomobject]@{
        texts           = @()
        text_details    = @()
        button_names    = @()
        button_elements = @()
    }

    if ($null -ne $dialogWindow) {
        $content = Read-DialogContent -Element $dialogWindow.element
        $title = $dialogWindow.name
        $hwnd = $dialogWindow.native_window_handle
        $className = $dialogWindow.class_name
    }
    else {
        $fallbackTitle = $null
        $fallbackHandle = [IntPtr]::Zero
        try {
            $Process.Refresh()
            if (-not $Process.HasExited) {
                $fallbackTitle = $Process.MainWindowTitle
                $fallbackHandle = [IntPtr]$Process.MainWindowHandle
            }
        }
        catch {
        }
        if ((-not $exited) -and (-not [string]::IsNullOrWhiteSpace($fallbackTitle)) -and ($fallbackTitle -like $TitlePattern)) {
            $uiaFallback = $true
            $title = $fallbackTitle
            $hwnd = $fallbackHandle.ToInt64()
        }
    }

    if (-not $exited) {
        try {
            $Process.Refresh()
            $exited = $Process.HasExited
            if ($exited) {
                $exitCode = $Process.ExitCode
            }
        }
        catch {
        }
    }
    $found = (($null -ne $dialogWindow) -or $uiaFallback)
    return [pscustomobject]@{
        found             = $found
        title             = $title
        hwnd              = [long]$hwnd
        class_name        = $className
        texts             = $content.texts
        text_details      = $content.text_details
        button_names      = $content.button_names
        button_elements   = $content.button_elements
        elapsed_ms        = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
        timed_out         = ((-not $found) -and (-not $exited))
        process_exited    = $exited
        exit_code         = $exitCode
        uia_fallback      = $uiaFallback
        top_window_names  = @($topWindowNames)
        title_pattern     = $TitlePattern
    }
}

function Close-FailureDialog {
    param(
        [Parameter(Mandatory = $true)]$Dialog,
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process
    )

    if ($null -eq $Dialog -or -not $Dialog.found) {
        return 'no-dialog'
    }
    $buttons = @($Dialog.button_elements)
    if ($buttons.Count -gt 0) {
        try {
            $invokePattern = $buttons[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $invokePattern.Invoke()
            return 'UIAutomation.Invoke'
        }
        catch {
        }
    }
    try {
        if ($Process.CloseMainWindow()) {
            return 'CloseMainWindow'
        }
    }
    catch {
    }
    return 'none'
}

# -----------------------------------------------------------------------------
# 窗口截图（CopyFromScreen；失败时只作为 WARN 证据，不影响验收判定）
# -----------------------------------------------------------------------------
function Initialize-CaptureNative {
    if ($script:VerifyCaptureNativeLoaded) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WorkManagerVerifyNative
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
'@
    $script:VerifyCaptureNativeLoaded = $true
}

function Capture-WindowScreenshot {
    param(
        [Parameter(Mandatory = $true)][long]$WindowHandle,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [int]$SettleMilliseconds = 700
    )

    $result = [ordered]@{
        ok          = $false
        path        = $OutputPath
        width       = 0
        height      = 0
        captured_at = (Get-Date).ToString('o')
        error       = $null
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Initialize-CaptureNative
        if ($WindowHandle -eq 0) {
            throw '窗口句柄为 0，无法截图'
        }
        $handle = [IntPtr]$WindowHandle
        [void][WorkManagerVerifyNative]::SetProcessDPIAware()
        [void][WorkManagerVerifyNative]::ShowWindow($handle, 9)
        [void][WorkManagerVerifyNative]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds $SettleMilliseconds

        $rect = New-Object WorkManagerVerifyNative+RECT
        if (-not [WorkManagerVerifyNative]::GetWindowRect($handle, [ref]$rect)) {
            throw 'GetWindowRect 失败'
        }
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -le 0 -or $height -le 0) {
            throw ('窗口尺寸无效：{0}x{1}' -f $width, $height)
        }
        $outputParent = Split-Path -Parent $OutputPath
        if (-not [string]::IsNullOrWhiteSpace($outputParent) -and -not (Test-Path -LiteralPath $outputParent)) {
            New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
        }
        $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $width, $height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            $rect.Left,
            $rect.Top,
            0,
            0,
            (New-Object System.Drawing.Size -ArgumentList $width, $height),
            [System.Drawing.CopyPixelOperation]::SourceCopy
        )
        $graphics.Dispose()
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()

        $result.ok = $true
        $result.width = $width
        $result.height = $height
    }
    catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

# -----------------------------------------------------------------------------
# 汇总输出：summary.json / summary-<script>.json / report.txt
# -----------------------------------------------------------------------------
function Write-VerifySummary {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [AllowEmptyString()][string]$ExePath = '',
        [AllowEmptyString()][string]$ExeSha256 = '',
        [AllowNull()]$ExeSizeBytes = $null,
        [System.Collections.IDictionary]$Metadata = $null,
        [AllowEmptyString()][string]$FatalError = ''
    )

    $finishedAt = Get-Date
    $checks = @($script:VerifyChecks)
    $passCount = 0
    $failCount = 0
    $warnCount = 0
    $infoCount = 0
    foreach ($check in $checks) {
        switch ($check.status) {
            'PASS' { $passCount = $passCount + 1 }
            'FAIL' { $failCount = $failCount + 1 }
            'WARN' { $warnCount = $warnCount + 1 }
            'INFO' { $infoCount = $infoCount + 1 }
        }
    }
    $overall = 'PASS'
    if ($failCount -gt 0 -or -not [string]::IsNullOrWhiteSpace($FatalError)) {
        $overall = 'FAIL'
    }
    $startedAt = $script:VerifyStartedAt
    if ($null -eq $startedAt) {
        $startedAt = $finishedAt
    }
    $artifacts = @()
    if ($null -ne $script:VerifyArtifacts) {
        $artifacts = @($script:VerifyArtifacts)
    }

    $summary = [ordered]@{
        script           = $ScriptName
        overall          = $overall
        started_at       = $startedAt.ToString('o')
        finished_at      = $finishedAt.ToString('o')
        duration_seconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 1)
        output_dir       = $OutputDir
        exe_path         = $ExePath
        exe_size_bytes   = $ExeSizeBytes
        exe_sha256       = $ExeSha256
        fatal_error      = $FatalError
        counts           = [ordered]@{
            total = $checks.Count
            pass  = $passCount
            fail  = $failCount
            warn  = $warnCount
            info  = $infoCount
        }
        environment      = [ordered]@{
            computer_name           = $env:COMPUTERNAME
            user_name               = $env:USERNAME
            user_identity           = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            powershell_version      = $PSVersionTable.PSVersion.ToString()
            powershell_edition      = [string]$PSVersionTable.PSEdition
            os_version              = [System.Environment]::OSVersion.VersionString
            is_64_bit_process       = [System.Environment]::Is64BitProcess
            process_id              = $PID
            current_directory       = (Get-Location).Path
            test_data_root          = $script:VerifyTestDataRoot
            output_dir              = $OutputDir
            python                  = $script:VerifyPython
        }
        artifacts        = $artifacts
        checks           = $checks
    }
    if ($null -ne $Metadata) {
        foreach ($key in $Metadata.Keys) {
            $summary[[string]$key] = $Metadata[$key]
        }
    }

    $jsonText = ConvertTo-Json -InputObject $summary -Depth 14
    $summaryPath = Join-Path $OutputDir 'summary.json'
    Save-Utf8TextFile -Path $summaryPath -Content ($jsonText + "`r`n")
    $scriptSummaryPath = Join-Path $OutputDir ('summary-' + $ScriptName + '.json')
    if ($scriptSummaryPath -ne $summaryPath) {
        Save-Utf8TextFile -Path $scriptSummaryPath -Content ($jsonText + "`r`n")
    }

    Write-Host ''
    Write-VerifySection -Title ($ScriptName + ' 检查汇总')
    $tableText = '（无检查项）'
    if ($checks.Count -gt 0) {
        $tableText = ($checks | Format-Table -AutoSize -Property status, name, detail | Out-String -Width 260).TrimEnd()
    }
    foreach ($line in ($tableText -split "`r?`n")) {
        Write-Host $line
    }
    $countLine = 'TOTAL={0} PASS={1} FAIL={2} WARN={3} INFO={4} OVERALL={5}' -f $checks.Count, $passCount, $failCount, $warnCount, $infoCount, $overall
    Write-Host $countLine
    $summaryLine = 'SUMMARY=' + $summaryPath
    Write-Host $summaryLine

    $reportLines = New-Object System.Collections.ArrayList
    if ($null -ne $script:VerifyLogLines) {
        foreach ($logLine in $script:VerifyLogLines) {
            [void]$reportLines.Add($logLine)
        }
    }
    [void]$reportLines.Add('')
    [void]$reportLines.Add($tableText)
    [void]$reportLines.Add($countLine)
    [void]$reportLines.Add($summaryLine)
    $reportText = ($reportLines -join "`r`n") + "`r`n"
    Save-Utf8TextFile -Path (Join-Path $OutputDir 'report.txt') -Content $reportText

    return [pscustomobject]@{
        fail         = $failCount
        pass         = $passCount
        warn         = $warnCount
        info         = $infoCount
        overall      = $overall
        summary_path = $summaryPath
        report_path  = (Join-Path $OutputDir 'report.txt')
    }
}
