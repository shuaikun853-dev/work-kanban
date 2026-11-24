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

# 把 Windows 重解析点 tag 映射为可审计的入口类型；未识别 tag 一律归为
# otherReparsePoint，调用方必须 fail-closed，不得猜测目标类型。
function Get-T104UatReparseKind {
    # PowerShell 5.1 会把 0xA0000003 解析为有符号 Int32；这里用 Int64 十进制值
    # （Junction = 0xA0000003 = 2684354563，Symbolic Link = 0xA000000C = 2684354572）。
    param([Parameter(Mandatory = $true)][long]$Tag)
    if ($Tag -eq [long]2684354563) {
        return 'junction'
    }
    if ($Tag -eq [long]2684354572) {
        return 'symbolicLink'
    }
    return 'otherReparsePoint'
}

# 用原生句柄识别清理入口的真实身份，不依赖 Test-Path：
# - absent：原生句柄确认不存在；
# - directory / file：普通目录或普通文件；
# - junction / symbolicLink / otherReparsePoint：重解析点类型（tag 可审计）；
# - targetExists：跟随重解析点后目标是否存在；悬空 Junction 为 false。
# 本函数只读，不删除、不跟随递归。
function Get-T104UatEntryState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'UAT 路径'
    )
    $normalized = Get-T103UatNormalizedPath $Path
    $linkInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    $state = [ordered]@{
        path         = $normalized
        exists       = [bool]$linkInfo.Exists
        kind         = 'absent'
        reparseTag   = [long]0
        targetExists = $null
        targetError  = ''
        isDirectory  = $false
    }
    if (-not $linkInfo.Exists) {
        return [pscustomobject]$state
    }

    $state.isDirectory = [bool]$linkInfo.IsDirectory
    if ($linkInfo.IsReparsePoint) {
        $state.reparseTag = [long]$linkInfo.ReparseTag
        $state.kind = Get-T104UatReparseKind -Tag $state.reparseTag
        try {
            $targetInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $false
            $state.targetExists = [bool]$targetInfo.Exists
        }
        catch {
            $state.targetExists = $null
            $state.targetError = ('无法确认{0}的重解析点目标：{1}' -f $Label, $_.Exception.Message)
        }
    }
    elseif ($linkInfo.IsDirectory) {
        $state.kind = 'directory'
    }
    else {
        $state.kind = 'file'
    }
    return [pscustomobject]$state
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

# ===========================================================================
# 第六轮 T104-01 修复：安全创建目标 / 目录身份记录 / 只读状态查询
#
# 第五轮守卫只支持“已存在的数据库文件”，无法在“目标尚不存在”时完成父目录、
# 卷身份与最终路径校验；也不能在清理前记录并在删除前复验目录身份。以下函数
# 复用 T1-03 的原生句柄/信任锚/路径链原语补齐这些能力，仍不做任何字符串前缀
# 安全判断、不创建/不删除文件。
# ===========================================================================

# 校验任意待创建/已存在 UAT 路径严格位于专用测试根目录内（不能是根目录本身）。
function Assert-T104UatPathInsideTestRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'UAT 路径'
    )
    $normalized = Get-T103UatNormalizedPath $Path
    $testRoot = (Get-T103UatNormalizedPath $script:T104UatTestRoot).TrimEnd('\')
    if (-not (Test-T103UatPathInside $normalized $testRoot)) {
        throw ("{0}不在专用测试根目录内（不能是测试根目录本身，也不能位于正式应用目录）：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    return $normalized
}

# 安全创建目标校验（目录可以尚不存在）：
# 1. 先验证专用测试根目录信任锚（存在、真实目录、全部祖先、卷身份、最终路径）；
# 2. 用 T1-03 原生路径链检查全部已存在祖先组件（拒绝重解析点、非目录、身份变化）；
# 3. 用 T1-03 原生安全检查确认“最近已存在祖先 + 缺失后缀”的真实最终路径仍在
#    测试根目录内、不在正式目录内、与请求字面路径一致；
# 4. 目录已存在时必须通过完整目录身份校验（重解析点 / 真实目录 / 卷身份 / 最终路径）。
function Assert-T104UatPlannedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'UAT 待创建目录'
    )
    $normalized = Assert-T104UatPathInsideTestRoot -Path $Path -Label $Label
    Assert-T103UatRequestedPathFormat -RequestedPath $normalized -TestRoot $script:T104UatTestRoot
    [void](Assert-T104UatTrustedRoot)

    $existingInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if ($existingInfo.Exists) {
        $record = Assert-T104UatDirectoryPath -Path $normalized -Label $Label
        return [pscustomobject]@{
            path         = $record.path
            finalPath    = $record.finalPath
            planned      = $false
            targetExists = $true
            identity     = $record
            checkedAt    = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    [void](Assert-T103NativePathSafety `
        -RequestedPath $normalized `
        -TestRoot $script:T104UatTestRoot `
        -FormalRoot $script:T104UatFormalRoot)
    # 目标尚不存在：父目录链与“最近已存在祖先”的真实最终路径已由原生校验确认；
    # 此处只允许调用方在已校验的安全存在祖先下创建普通子目录。
    $parent = Split-Path -Parent $normalized
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $parentInfo = Get-T103NativePathInfo -Path $parent -OpenReparsePoint $true
        if ($parentInfo.Exists -and $parentInfo.IsReparsePoint) {
            throw ("{0}父目录路径是未获批准的 Windows 重解析点：{1}。已按 fail-closed 拒绝。" -f $Label, $parent)
        }
    }
    return [pscustomobject]@{
        path         = $normalized
        finalPath    = $normalized
        planned      = $true
        targetExists = $false
        identity     = $null
        checkedAt    = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# 安全创建目标校验（数据库文件可以尚不存在）：
# - UAT 根目录必须已存在并通过完整身份校验；
# - 数据库父目录可以尚不存在，但必须通过安全创建目标校验；
# - 数据库文件目标不得已存在（拒绝复用/覆盖旧数据库），不得是重解析点/目录，
#   且不得存在孤立 SQLite sidecar（-wal/-shm/-journal）。
function Assert-T104UatPlannedDatabaseFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $relative = Get-T104UatRelativeSegments -Path $Path
    $normalized = $relative.Normalized
    if ([string]::IsNullOrWhiteSpace((Split-Path -Leaf $normalized))) {
        throw ("数据库路径缺少文件名：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    $uatRootRecord = Assert-T104UatDirectoryPath -Path $relative.UatRoot -Label 'UAT 根目录'
    $parentPath = Split-Path -Parent $normalized
    $parentRecord = Assert-T104UatPlannedDirectory -Path $parentPath -Label '数据库父目录'

    $leafInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if ($leafInfo.Exists) {
        if ($leafInfo.IsReparsePoint) {
            throw ("数据库创建目标是未获批准的 Windows 重解析点（Junction / Symbolic Link / 其他 reparse point，tag=0x{0:X8}）：{1}。已按 fail-closed 拒绝。" -f $leafInfo.ReparseTag, $normalized)
        }
        if ($leafInfo.IsDirectory) {
            throw ("数据库创建目标是目录而不是普通文件：{0}。已按 fail-closed 拒绝。" -f $normalized)
        }
        throw ("数据库创建目标已存在，拒绝复用/覆盖旧数据库：{0}。请使用新的 UAT 目录。" -f $normalized)
    }
    foreach ($suffix in @('-wal', '-shm', '-journal')) {
        $sidecarInfo = Get-T103NativePathInfo -Path ($normalized + $suffix) -OpenReparsePoint $true
        if ($sidecarInfo.Exists) {
            throw ("数据库创建目标存在孤立 SQLite sidecar（{0}），无法确认目标状态：{1}。已按 fail-closed 拒绝。" -f $suffix, $normalized)
        }
    }

    return [pscustomobject]@{
        path         = $normalized
        finalPath    = $normalized
        planned      = $true
        targetExists = $false
        identity     = $null
        parent       = $parentRecord
        uatRoot      = $uatRootRecord
        checkedAt    = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# 安全创建目标校验（证据目录可以尚不存在）：
# 证据目录固定为 UAT 根目录下直接名为 evidence 的目录；UAT 根目录必须已存在并
# 通过完整身份校验，evidence 目录可以尚不存在但必须通过安全创建目标校验。
function Assert-T104UatPlannedEvidenceDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$UatRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $uatRootRecord = Assert-T104UatDirectoryPath -Path $UatRoot -Label 'UAT 根目录'
    $normalized = Get-T103UatNormalizedPath $Path
    $expected = Join-Path $uatRootRecord.path 'evidence'
    if (-not (Test-T103FinalPathEquals $normalized $expected)) {
        throw ("证据目录必须是 UAT 根目录下直接名为 evidence 的目录：请求={0}，预期={1}。已按 fail-closed 拒绝。" -f $normalized, $expected)
    }
    $plannedRecord = Assert-T104UatPlannedDirectory -Path $normalized -Label 'UAT 证据目录'
    return [pscustomobject]@{
        path         = $normalized
        finalPath    = $plannedRecord.finalPath
        uatRoot      = $uatRootRecord
        planned      = $plannedRecord.planned
        targetExists = $plannedRecord.targetExists
        identity     = $plannedRecord.identity
        checkedAt    = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# 无数据库场景的证据文件校验：证据目录必须已存在并通过安全创建目标校验，
# 文件必须是其直接 .json 子文件；文件已存在时必须是普通非重解析文件。
function Assert-T104UatEvidenceFileWithinUatRoot {
    param(
        [Parameter(Mandatory = $true)][string]$UatRoot,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $boundary = Assert-T104UatPlannedEvidenceDirectory -UatRoot $UatRoot -Path $EvidenceDirectory
    if (-not $boundary.targetExists) {
        throw ("证据目录不存在，无法确认证据文件写入边界：{0}。已按 fail-closed 拒绝。" -f $boundary.path)
    }
    $normalized = Get-T103UatNormalizedPath $Path
    Assert-T103UatRequestedPathFormat -RequestedPath $normalized -TestRoot $script:T104UatTestRoot
    if (-not (Test-T103UatPathInside $normalized $boundary.path)) {
        throw ("证据文件必须位于可信 UAT 证据目录内：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    if (-not (Test-T103FinalPathEquals (Split-Path -Parent $normalized) $boundary.path)) {
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

    return [pscustomobject]@{
        uatRoot           = $boundary.uatRoot
        evidenceDirectory = $boundary
        evidenceFile      = $fileRecord
        plannedPath       = $normalized
        checkedAt         = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# 目录身份摘要：用于证据记录（不落盘机器专属的卷序列号/文件 ID 原值）。
function Get-T104UatIdentityDigest {
    param([Parameter(Mandatory = $true)]$Identity)
    $text = ('{0}|{1}|{2}' -f [string]$Identity.path, [string]$Identity.volumeSerialNumber, [string]$Identity.fileIdHex)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $hash = $sha.ComputeHash($bytes)
        $hex = ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
        return $hex.Substring(0, 16)
    }
    finally {
        $sha.Dispose()
    }
}

# 正式应用目录只读身份快照（不写入、不创建）：用于证明测试前后正式目录本身未被
# 替换/移动；不能证明正式目录内容未被其他进程修改（TOCTOU 按 DEC-029 延期）。
function Get-T104UatFormalRootStatus {
    $formalPath = Get-T103UatNormalizedPath $script:T104UatFormalRoot
    $info = Get-T103NativePathInfo -Path $formalPath -OpenReparsePoint $false
    $identity = $null
    if ($info.Exists) {
        if ([string]::IsNullOrWhiteSpace([string]$info.FileIdHex) -or [string]::IsNullOrWhiteSpace([string]$info.VolumeSerialNumber)) {
            throw ("无法读取正式应用目录的卷序列号/文件 ID，无法记录只读身份快照：{0}。已按 fail-closed 拒绝。" -f $formalPath)
        }
        $finalPath = ConvertTo-T103NativeComparablePath $info.FinalPath
        $identity = [pscustomobject]@{
            path               = $formalPath
            finalPath          = $finalPath
            volumeSerialNumber = [string]$info.VolumeSerialNumber
            fileIdHex          = [string]$info.FileIdHex
        }
        $identity | Add-Member -NotePropertyName identityDigest -NotePropertyValue (Get-T104UatIdentityDigest -Identity $identity)
    }
    return [pscustomobject]@{
        path      = $formalPath
        existed   = [bool]$info.Exists
        identity  = $identity
        checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}
