# WorkManager T1-04 UAT 数据库/证据路径安全校验（T104-01 第五轮定向修复）
#
# 本模块**复用** T1-03 已验证的 Windows 原生句柄校验与信任锚实现，
# 不重新实现一套弱于 T1-03 的字符串路径安全方案：
# - . T1-03UatPath.ps1：CreateFileW + GetFileInformationByHandleEx +
#   GetFinalPathNameByHandleW、卷序列号/文件 ID、重解析点拒绝、最终路径比较；
# - Assert-T103UatTrustedTestRoot：专用测试根目录信任锚；
# - Assert-T103NativePathSafety：目录及其全部已存在祖先组件的原生校验；
# - Get-T103NativePathInfo / Assert-T103NativeVolumeIdentity：叶子文件身份校验。
#
# T1-04 额外约束：
# - 数据库文件必须是普通文件（不是 Junction / Symbolic Link / 其他 reparse point）；
# - 数据库父目录及其全部祖先必须通过 T1-03 原生目录校验；
# - 数据库路径必须位于 <测试根>\<UAT任务目录>\ 之下，不能直接位于测试根；
# - UAT 根目录本身必须是普通真实目录，并通过信任锚与原生身份校验；
# - 只允许 UAT 根目录下直接名为 evidence 的目录作为证据目录；
# - 证据文件必须是 evidence 目录的直接子文件，扩展名 .json，且自身不是重解析点；
# - 所有失败 fail-closed；本模块只读校验，不创建、不删除、不写文件。
#
# 残余风险：校验与后续 sqlite3.connect / 文件写入之间仍存在 TOCTOU 并发替换窗口，
# 按 DEC-029 / Issue #2 保持延期，不在本轮宣称消除。

. (Join-Path $PSScriptRoot 'T1-03UatPath.ps1')

Set-StrictMode -Version Latest

$script:T104UatTestRoot = $script:T103UatTestRoot
$script:T104UatFormalRoot = $script:T103UatFormalRoot
$script:T104UatApprovedReparsePoints = @()

function Assert-T104UatTrustedRoot {
    param(
        [string]$TestRoot = $script:T104UatTestRoot,
        [string]$FormalRoot = $script:T104UatFormalRoot
    )
    return Assert-T103UatTrustedTestRoot -TestRoot $TestRoot -FormalRoot $FormalRoot
}

function Get-T104UatRelativeSegments {
    param([Parameter(Mandatory = $true)][string]$Path)
    $normalized = Get-T103UatNormalizedPath $Path
    $testRoot = (Get-T103UatNormalizedPath $script:T104UatTestRoot).TrimEnd('\')
    if (-not (Test-T103FinalPathInside $normalized $testRoot)) {
        throw ("路径不在专用测试根目录内：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    $relative = $normalized.Substring($testRoot.Length).TrimStart('\')
    $segments = @($relative.Split('\') | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 2) {
        throw ("UAT 路径必须位于专用测试根目录下的独立任务目录中，不能直接位于测试根目录：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    return [pscustomobject]@{
        Normalized = $normalized
        TestRoot   = $testRoot
        Segments   = $segments
        UatRoot    = (Join-Path $testRoot $segments[0])
    }
}

function Assert-T104UatDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'UAT 目录',
        [string]$ExpectedPath = ''
    )
    $normalized = Get-T103UatNormalizedPath $Path
    Assert-T103UatRequestedPathFormat -RequestedPath $normalized -TestRoot $script:T104UatTestRoot
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPath)) {
        $expected = Get-T103UatNormalizedPath $ExpectedPath
        if (-not (Test-T103FinalPathEquals $normalized $expected)) {
            throw ("{0}请求路径与预期 UAT 路径不一致：请求={1}，预期={2}。已按 fail-closed 拒绝。" -f $Label, $normalized, $expected)
        }
    }

    $trust = Assert-T104UatTrustedRoot
    $guard = Assert-T103NativePathSafety `
        -RequestedPath $normalized `
        -TestRoot $script:T104UatTestRoot `
        -FormalRoot $script:T104UatFormalRoot

    $linkInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if (-not $linkInfo.Exists) {
        throw ("{0}不存在，无法确认目录身份：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if ($linkInfo.IsReparsePoint) {
        throw ("{0}是未获批准的 Windows 重解析点（Junction / Symbolic Link / 其他 reparse point，tag=0x{1:X8}）：{2}。已按 fail-closed 拒绝。" -f $Label, $linkInfo.ReparseTag, $normalized)
    }
    if (-not $linkInfo.IsDirectory) {
        throw ("{0}不是真实目录：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }

    $followInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $false
    if (-not $followInfo.Exists) {
        throw ("{0}在两次句柄检查之间消失：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if (($linkInfo.VolumeSerialNumber -ne $followInfo.VolumeSerialNumber) -or
        ($linkInfo.FileIdHex -ne $followInfo.FileIdHex)) {
        throw ("{0}在两次句柄检查之间身份发生变化（可能是并发重解析点替换）：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if ([string]::IsNullOrWhiteSpace([string]$followInfo.FileIdHex) -or
        [string]::IsNullOrWhiteSpace([string]$followInfo.VolumeSerialNumber)) {
        throw ("无法读取{0}的卷序列号/文件 ID：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if (-not (Test-T103FinalPathEquals ([string]$followInfo.VolumeSerialNumber) ([string]$trust.volumeSerialNumber))) {
        throw ("{0}的实际卷身份与专用测试根目录信任锚不一致：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    $finalPath = ConvertTo-T103NativeComparablePath $followInfo.FinalPath
    if (-not (Test-T103FinalPathEquals $finalPath $normalized)) {
        throw ("{0}的真实最终路径与字面路径不一致（可能是短名/别名/重解析点替换）：请求={1}，真实={2}。已按 fail-closed 拒绝。" -f $Label, $normalized, $finalPath)
    }
    if (-not $guard.finalPathInsideRoot) {
        throw ("{0}真实最终路径不在专用测试根目录内：{1}。已按 fail-closed 拒绝。" -f $Label, $finalPath)
    }

    return [pscustomobject]@{
        path               = $normalized
        finalPath          = $finalPath
        volumeSerialNumber = [string]$followInfo.VolumeSerialNumber
        fileIdHex          = [string]$followInfo.FileIdHex
        checkedAt          = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Assert-T104UatRegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'UAT 文件'
    )
    $normalized = Get-T103UatNormalizedPath $Path
    $trust = Get-T103UatTrustedRootRecord
    if ($null -eq $trust) {
        $trust = Assert-T104UatTrustedRoot
    }
    $linkInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if (-not $linkInfo.Exists) {
        throw ("{0}不存在，无法确认文件身份：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if ($linkInfo.IsReparsePoint) {
        throw ("{0}本身是未获批准的 Windows 重解析点（Junction / Symbolic Link / 其他 reparse point，tag=0x{1:X8}）：{2}。已按 fail-closed 拒绝。" -f $Label, $linkInfo.ReparseTag, $normalized)
    }
    if ($linkInfo.IsDirectory) {
        throw ("{0}是目录而不是普通文件：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    $followInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $false
    if (-not $followInfo.Exists) {
        throw ("{0}在两次句柄检查之间消失：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if (($linkInfo.VolumeSerialNumber -ne $followInfo.VolumeSerialNumber) -or
        ($linkInfo.FileIdHex -ne $followInfo.FileIdHex)) {
        throw ("{0}在两次句柄检查之间身份发生变化：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if ([string]::IsNullOrWhiteSpace([string]$followInfo.FileIdHex) -or
        [string]::IsNullOrWhiteSpace([string]$followInfo.VolumeSerialNumber)) {
        throw ("无法读取{0}的卷序列号/文件 ID：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    if (-not (Test-T103FinalPathEquals ([string]$followInfo.VolumeSerialNumber) ([string]$trust.volumeSerialNumber))) {
        throw ("{0}的实际卷身份与专用测试根目录信任锚不一致：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    $finalPath = ConvertTo-T103NativeComparablePath $followInfo.FinalPath
    if (-not (Test-T103FinalPathEquals $finalPath $normalized)) {
        throw ("{0}的真实最终路径与字面路径不一致（可能是短名/别名/重解析点替换）：请求={1}，真实={2}。已按 fail-closed 拒绝。" -f $Label, $normalized, $finalPath)
    }
    return [pscustomobject]@{
        path               = $normalized
        finalPath          = $finalPath
        volumeSerialNumber = [string]$followInfo.VolumeSerialNumber
        fileIdHex          = [string]$followInfo.FileIdHex
        checkedAt          = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Assert-T104UatDatabaseFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $relative = Get-T104UatRelativeSegments -Path $Path
    $normalized = $relative.Normalized
    if ([string]::IsNullOrWhiteSpace((Split-Path -Leaf $normalized))) {
        throw ("数据库路径缺少文件名：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    $uatRootRecord = Assert-T104UatDirectoryPath -Path $relative.UatRoot -Label 'UAT 根目录'
    $parent = Split-Path -Parent $normalized
    $parentRecord = Assert-T104UatDirectoryPath -Path $parent -Label '数据库父目录'

    $fileRecord = Assert-T104UatRegularFile -Path $normalized -Label 'UAT 数据库文件'

    # 已存在的 SQLite sidecar 同样不得是重解析点：否则 SQLite 写入可能被重定向。
    foreach ($suffix in @('-wal', '-shm', '-journal')) {
        $sidecar = $normalized + $suffix
        $sidecarInfo = Get-T103NativePathInfo -Path $sidecar -OpenReparsePoint $true
        if ($sidecarInfo.Exists) {
            [void](Assert-T104UatRegularFile -Path $sidecar -Label ('SQLite sidecar ' + $suffix))
        }
    }

    return [pscustomobject]@{
        database     = $fileRecord
        parent       = $parentRecord
        uatRoot      = $uatRootRecord
        checkedAt    = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Assert-T104UatEvidenceDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory
    )
    $databaseRecord = Assert-T104UatDatabaseFile -Path $DatabasePath
    $expectedEvidence = Join-Path $databaseRecord.uatRoot.path 'evidence'
    $evidenceRecord = Assert-T104UatDirectoryPath `
        -Path $EvidenceDirectory `
        -Label 'UAT 证据目录' `
        -ExpectedPath $expectedEvidence
    if (-not (Test-T103FinalPathEquals (Split-Path -Leaf $evidenceRecord.path) 'evidence')) {
        throw ("证据目录必须是 UAT 根目录下直接名为 evidence 的目录：{0}。已按 fail-closed 拒绝。" -f $evidenceRecord.path)
    }
    return [pscustomobject]@{
        database        = $databaseRecord
        evidenceDirectory = $evidenceRecord
        checkedAt       = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Assert-T104UatEvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $boundary = Assert-T104UatEvidenceDirectory `
        -DatabasePath $DatabasePath `
        -EvidenceDirectory $EvidenceDirectory
    $normalized = Get-T103UatNormalizedPath $Path
    Assert-T103UatRequestedPathFormat -RequestedPath $normalized -TestRoot $script:T104UatTestRoot
    if (-not (Test-T103UatPathInside $normalized $boundary.evidenceDirectory.path)) {
        throw ("证据文件必须位于可信 UAT 证据目录内：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    if (-not (Test-T103FinalPathEquals (Split-Path -Parent $normalized) $boundary.evidenceDirectory.path)) {
        throw ("证据文件必须是证据目录的直接子文件，不允许写入子目录或任意路径：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    if (-not ([System.IO.Path]::GetExtension($normalized).Equals('.json', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw ("证据文件扩展名必须为 .json：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }

    $fileRecord = $null
    $linkInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if ($linkInfo.Exists) {
        $fileRecord = Assert-T104UatRegularFile -Path $normalized -Label 'UAT 证据文件'
    }
    else {
        # 文件尚不存在时：父目录已通过原生校验；此处只确认路径仍在同一卷与同一证据目录下。
        $parentInfo = Get-T103NativePathInfo -Path $boundary.evidenceDirectory.path -OpenReparsePoint $false
        if (-not $parentInfo.Exists) {
            throw ("证据目录在检查期间消失：{0}。已按 fail-closed 拒绝。" -f $boundary.evidenceDirectory.path)
        }
    }

    return [pscustomobject]@{
        database          = $boundary.database
        evidenceDirectory = $boundary.evidenceDirectory
        evidenceFile      = $fileRecord
        plannedPath       = $normalized
        checkedAt         = (Get-Date).ToUniversalTime().ToString('o')
    }
}
