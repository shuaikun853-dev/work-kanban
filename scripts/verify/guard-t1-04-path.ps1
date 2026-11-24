# WorkManager T1-04 UAT 路径安全守卫 CLI（Python / PowerShell 验证脚本的唯一原生校验入口）
#
# 用法：
#   powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File guard-t1-04-path.ps1 `
#       -Kind test-root -Path <testRoot>
#       -Kind uat-root -Path <existingUatRootOrSubDir>
#       -Kind uat-root-target -Path <plannedUatRootOrSubDir>
#       -Kind database -Path <existingDatabasePath>
#       -Kind database-target -Path <plannedDatabasePath>
#       -Kind evidence-dir -DatabasePath <databasePath> -Path <evidenceDir>
#       -Kind evidence-dir-target -UatRoot <uatRoot> -Path <plannedEvidenceDir>
#       -Kind evidence-file -DatabasePath <databasePath> -EvidenceDirectory <evidenceDir> -Path <jsonPath>
#       -Kind evidence-file -UatRoot <uatRoot> -EvidenceDirectory <evidenceDir> -Path <jsonPath>
#       -Kind formal-root-status
#
# stdout 只输出一行 JSON：{ok:true,...,identity:{...}} 或
# {ok:false,code:"t1-04-path-rejected",message:"..."}。
# 成功退出码 0；安全校验失败退出码 3。任何无法确认身份、重解析点、卷身份不一致、
# 证据路径越界、目标已存在/状态不明都在打开 SQLite / 写文件 / 创建目录之前 fail-closed。
#
# 第六轮（T104-01 修复）新增：
# - test-root：验证测试根目录信任锚（自身 + 全部已存在祖先 + 卷身份 + 文件 ID +
#   真实最终路径）；只允许默认测试根目录或其下的隔离合成信任锚（仅用于故障注入测试，
#   合成信任锚仍执行与默认根完全相同的原生验证，Junction 根必须被拒绝）；
# - uat-root：验证已存在 UAT 目录/子目录的完整身份；
# - uat-root-target / database-target / evidence-dir-target：验证尚不存在的创建目标
#   （父目录链、卷身份、最终路径、目标非重解析点），不创建任何目录/文件；
# - evidence-file（-UatRoot 形式）：无数据库场景下仍约束证据文件只能是
#   <UAT根>\evidence\<file>.json 的直接子文件；
# - formal-root-status：只读正式目录身份快照（不写入），用于证明测试前后正式目录
#   本身未被替换；不宣称正式目录内容未被外部进程修改（DEC-029 / Issue #2 延期）。
#
# 本 CLI 只读校验：不创建、不删除、不写文件（删除操作由 guard-t1-04-cleanup.ps1
# 复用 T1-03 fail-closed 安全清理执行）。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'test-root',
        'uat-root',
        'uat-root-target',
        'database',
        'database-target',
        'evidence-dir',
        'evidence-dir-target',
        'evidence-file',
        'formal-root-status'
    )]
    [string]$Kind,
    [string]$Path = '',
    [string]$DatabasePath = '',
    [string]$EvidenceDirectory = '',
    [string]$UatRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $OutputEncoding

function Get-GuardIdentityPayload {
    param(
        $Record,
        [bool]$Planned = $false,
        [bool]$TargetExists = $false,
        [string]$IdentityPath = '',
        [string]$IdentityFinalPath = ''
    )
    $identity = $null
    if ($null -ne $Record) {
        $pathValue = [string]$Record.path
        if ([string]::IsNullOrWhiteSpace($pathValue)) {
            $pathValue = $IdentityPath
        }
        $finalPathValue = [string]$Record.finalPath
        if ([string]::IsNullOrWhiteSpace($finalPathValue)) {
            $finalPathValue = $IdentityFinalPath
        }
        $identity = [ordered]@{
            path               = $pathValue
            finalPath          = $finalPathValue
            volumeSerialNumber = [string]$Record.volumeSerialNumber
            fileIdHex          = [string]$Record.fileIdHex
            identityDigest     = (Get-T104UatIdentityDigest -Identity $Record)
        }
    }
    return [ordered]@{
        planned      = $Planned
        targetExists = $TargetExists
        identity     = $identity
    }
}

function Write-GuardResult {
    param(
        [bool]$Ok,
        [string]$Message = '',
        [hashtable]$Extra = @{}
    )
    $resultCode = if ($Ok) { 't1-04-path-verified' } else { 't1-04-path-rejected' }
    $reparseResult = if ($Ok) { 'rejected' } else { 'not-evaluated' }
    $finalPathResult = if ($Ok) { 'verified' } else { 'not-verified' }
    $volumeResult = if ($Ok) { 'verified' } else { 'not-verified' }
    $result = [ordered]@{
        ok             = $Ok
        kind           = $Kind
        code           = $resultCode
        message        = $Message
        reparsePoints  = $reparseResult
        finalPath      = $finalPathResult
        volumeIdentity = $volumeResult
        checkedAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $Extra) {
        foreach ($key in $Extra.Keys) {
            $result[$key] = $Extra[$key]
        }
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 8))
}

function Read-RequiredParameter {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw ('{0} 校验缺少必需的 -{1} 参数。' -f $Kind, $Name)
    }
    return $Value
}

try {
    . (Join-Path $PSScriptRoot 'T1-04UatPath.ps1')
    $extra = [ordered]@{ planned = $false; targetExists = $false; identity = $null }
    switch ($Kind) {
        'test-root' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $normalized = Get-T103UatNormalizedPath $requested
            $defaultRoot = (Get-T103UatNormalizedPath $script:T104UatTestRoot).TrimEnd('\')
            if (-not ((Test-T103FinalPathEquals $normalized $defaultRoot) -or (Test-T103UatPathInside $normalized $defaultRoot))) {
                throw ("test-root 校验只允许默认测试根目录或其下的隔离合成信任锚：{0}。已按 fail-closed 拒绝。" -f $normalized)
            }
            $record = Assert-T104UatTrustedRoot -TestRoot $normalized
            $identityPayload = Get-GuardIdentityPayload -Record $record -Planned $false -TargetExists $true
            if ($null -ne $identityPayload.identity) {
                $identityPayload.identity['componentCount'] = [int]$record.existingComponentCount
            }
            $extra = $identityPayload
        }
        'uat-root' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $record = Assert-T104UatDirectoryPath -Path $requested -Label 'UAT 目录'
            $extra = Get-GuardIdentityPayload -Record $record -Planned $false -TargetExists $true
        }
        'uat-root-target' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $record = Assert-T104UatPlannedDirectory -Path $requested -Label 'UAT 待创建目录'
            $extra = Get-GuardIdentityPayload `
                -Record $record.identity `
                -Planned ([bool]$record.planned) `
                -TargetExists ([bool]$record.targetExists) `
                -IdentityPath ([string]$record.path) `
                -IdentityFinalPath ([string]$record.finalPath)
        }
        'database' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $record = Assert-T104UatDatabaseFile -Path $requested
            $extra = Get-GuardIdentityPayload -Record $record.database -Planned $false -TargetExists $true
        }
        'database-target' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $record = Assert-T104UatPlannedDatabaseFile -Path $requested
            $extra = Get-GuardIdentityPayload `
                -Record $record.identity `
                -Planned ([bool]$record.planned) `
                -TargetExists ([bool]$record.targetExists) `
                -IdentityPath ([string]$record.path) `
                -IdentityFinalPath ([string]$record.finalPath)
        }
        'evidence-dir' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $database = Read-RequiredParameter -Value $DatabasePath -Name 'DatabasePath'
            $record = Assert-T104UatEvidenceDirectory -DatabasePath $database -EvidenceDirectory $requested
            $extra = Get-GuardIdentityPayload -Record $record.evidenceDirectory -Planned $false -TargetExists $true
        }
        'evidence-dir-target' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $uatRootValue = Read-RequiredParameter -Value $UatRoot -Name 'UatRoot'
            $record = Assert-T104UatPlannedEvidenceDirectory -UatRoot $uatRootValue -Path $requested
            $extra = Get-GuardIdentityPayload `
                -Record $record.identity `
                -Planned ([bool]$record.planned) `
                -TargetExists ([bool]$record.targetExists) `
                -IdentityPath ([string]$record.path) `
                -IdentityFinalPath ([string]$record.finalPath)
        }
        'evidence-file' {
            $requested = Read-RequiredParameter -Value $Path -Name 'Path'
            $evidenceDirectoryValue = Read-RequiredParameter -Value $EvidenceDirectory -Name 'EvidenceDirectory'
            if (-not [string]::IsNullOrWhiteSpace($DatabasePath)) {
                $record = Assert-T104UatEvidenceFile `
                    -DatabasePath $DatabasePath `
                    -EvidenceDirectory $evidenceDirectoryValue `
                    -Path $requested
                $fileExists = ($null -ne $record.evidenceFile)
                if ($fileExists) {
                    $extra = Get-GuardIdentityPayload -Record $record.evidenceFile -Planned $false -TargetExists $true
                }
                else {
                    $extra = [ordered]@{
                        planned      = $true
                        targetExists = $false
                        identity     = $null
                        plannedPath  = [string]$record.plannedPath
                    }
                }
            }
            else {
                $uatRootValue = Read-RequiredParameter -Value $UatRoot -Name 'UatRoot'
                $record = Assert-T104UatEvidenceFileWithinUatRoot `
                    -UatRoot $uatRootValue `
                    -EvidenceDirectory $evidenceDirectoryValue `
                    -Path $requested
                $fileExists = ($null -ne $record.evidenceFile)
                if ($fileExists) {
                    $extra = Get-GuardIdentityPayload -Record $record.evidenceFile -Planned $false -TargetExists $true
                }
                else {
                    $extra = [ordered]@{
                        planned      = $true
                        targetExists = $false
                        identity     = $null
                        plannedPath  = [string]$record.plannedPath
                    }
                }
            }
        }
        'formal-root-status' {
            $status = Get-T104UatFormalRootStatus
            $extra = [ordered]@{
                planned      = $false
                targetExists = [bool]$status.existed
                identity     = $null
                path         = [string]$status.path
                existed      = [bool]$status.existed
            }
            if ($null -ne $status.identity) {
                $extra['identity'] = [ordered]@{
                    path               = [string]$status.identity.path
                    finalPath          = [string]$status.identity.finalPath
                    volumeSerialNumber = [string]$status.identity.volumeSerialNumber
                    fileIdHex          = [string]$status.identity.fileIdHex
                    identityDigest     = [string]$status.identity.identityDigest
                }
            }
        }
        default {
            throw ('未知校验类型：{0}' -f $Kind)
        }
    }
    Write-GuardResult -Ok $true -Extra $extra
    exit 0
}
catch {
    Write-GuardResult -Ok $false -Message $_.Exception.Message
    exit 3
}
