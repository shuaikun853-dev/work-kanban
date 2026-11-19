# WorkManager T1-03 UAT 输出目录安全校验（P3-02 修复）
#
# 被 verify-t1-03-ui.ps1 dot-source 使用；也可被 test-t1-03-uat-path.ps1 直接测试。
#
# 规则：
# 1. 输出目录必须在专用测试根目录 D:\WorkManager-test-data\ 之下（不能是根目录本身）；
# 2. 先使用 [System.IO.Path]::GetFullPath 规范化（处理 . / .. / 相对路径），再做边界判断；
# 3. 禁止使用/位于正式应用目录 D:\WorkManager；
# 4. 目标目录已存在时：包含数据库文件 -> 拒绝；非空 -> 拒绝；仅空目录允许；
# 5. 本模块只做校验与返回规范化路径，不创建、不删除、不清理任何目录。

$script:T103UatTestRoot = 'D:\WorkManager-test-data'
$script:T103UatFormalRoot = 'D:\WorkManager'

function Get-T103UatNormalizedPath([string]$RequestedPath) {
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        throw '输出目录不能为空。请使用新的 UAT 目录，例如 D:\WorkManager-test-data\t1-03-ui-<timestamp>。'
    }
    try {
        $full = [System.IO.Path]::GetFullPath($RequestedPath)
    }
    catch {
        throw ("输出目录路径无效：{0}。请使用新的 UAT 目录，例如 D:\WorkManager-test-data\t1-03-ui-<timestamp>。" -f $RequestedPath)
    }
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    while ($full.Length -gt $pathRoot.Length -and ($full.EndsWith('\') -or $full.EndsWith('/'))) {
        $full = $full.Substring(0, $full.Length - 1)
    }
    return $full
}

function Test-T103UatPathEquals([string]$Path, [string]$Root) {
    return [string]::Equals(
        (Get-T103UatNormalizedPath $Path),
        (Get-T103UatNormalizedPath $Root),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-T103UatPathInside([string]$Path, [string]$Root) {
    $normalizedPath = Get-T103UatNormalizedPath $Path
    $normalizedRoot = (Get-T103UatNormalizedPath $Root).TrimEnd('\')
    return $normalizedPath.StartsWith(
        $normalizedRoot + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-T103UatDatabaseFiles([string]$Directory) {
    return @(
        Get-ChildItem -LiteralPath $Directory -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq 'work.db' -or
                $_.Extension -in @('.db', '.db-wal', '.db-shm', '.sqlite', '.sqlite3')
            }
    )
}

function Resolve-T103UatOutputDirectory([string]$RequestedPath) {
    $testRoot = Get-T103UatNormalizedPath $script:T103UatTestRoot
    $formalRoot = Get-T103UatNormalizedPath $script:T103UatFormalRoot
    $full = Get-T103UatNormalizedPath $RequestedPath

    if ((Test-T103UatPathEquals $full $formalRoot) -or (Test-T103UatPathInside $full $formalRoot)) {
        throw ("禁止使用正式应用目录 {0} 作为 UAT 输出目录（实际：{1}）。请使用新的测试目录，例如 {2}\t1-03-ui-<timestamp>。" -f $formalRoot, $full, $testRoot)
    }
    if (Test-T103UatPathEquals $full $testRoot) {
        throw ("输出目录不能是专用测试根目录本身：{0}。请使用该根目录下的新 UAT 目录，例如 {0}\t1-03-ui-<timestamp>。" -f $testRoot)
    }
    if (-not (Test-T103UatPathInside $full $testRoot)) {
        throw ("输出目录必须位于专用测试根目录 {0} 之下（实际：{1}）。请使用新的 UAT 目录，例如 {0}\t1-03-ui-<timestamp>。" -f $testRoot, $full)
    }

    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            throw ("输出路径已存在且不是目录：{0}。默认拒绝复用/覆盖，请使用新的测试目录。" -f $full)
        }
        $databaseFiles = @(Get-T103UatDatabaseFiles $full)
        if ($databaseFiles.Count -gt 0) {
            throw ("目标 UAT 目录已包含数据库文件（{0} 个），默认拒绝复用旧数据库。请使用新的测试目录，例如 {1}\t1-03-ui-<timestamp>。" -f $databaseFiles.Count, $testRoot)
        }
        $entries = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
        if ($entries.Count -gt 0) {
            throw ("目标 UAT 目录已存在且非空（{0} 个条目），拒绝覆盖或删除未知内容。请使用新的测试目录，例如 {1}\t1-03-ui-<timestamp>。" -f $entries.Count, $testRoot)
        }
    }

    return $full
}
