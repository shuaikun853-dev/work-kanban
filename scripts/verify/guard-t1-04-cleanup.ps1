# WorkManager T1-04 UAT fail-closed 清理守卫 CLI（第六轮 T104-01 修复）
#
# 用法：
#   powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File guard-t1-04-cleanup.ps1 `
#       -Path <sandboxPath> `
#       -ExpectedVolumeSerial <volumeSerialNumber> `
#       -ExpectedFileId <fileIdHex> `
#       [-ExpectedFinalPath <finalPath>] `
#       [-TrackedLink <linkPath>[,<linkPath>...]] `
#       [-TestRootOverride <testRootPath>]
#
# 复用 T1-03 `Invoke-T103FailClosedSandboxCleanup`：
# 1. 清理前用 Windows 原生句柄复验沙箱真实身份（卷序列号 + 文件 ID + 真实最终路径）
#    与调用方记录的期望身份一致；身份变化 / 重解析点 / 身份无法确认 → 拒绝删除；
# 2. 逐个删除并原生复验跟踪的 Junction / Symbolic Link（只删链接本身）；
# 3. 扫描整个沙箱，拒绝任何未预期重解析点；
# 4. 再次复验沙箱身份；
# 5. 全部通过后才执行逐条目校验的安全递归删除（绝不跟随重解析点）。
# 任一条件不满足：立即停止、保留现场、不执行整个沙箱递归删除，退出码 3。
#
# stdout 只输出一行 JSON：{ok:true|false,safe,stopCode,stopReason,...}。
# 成功退出码 0；拒绝/失败退出码 3（fail-closed，不删除）。
#
# 测试注入：`-TestRootOverride` 只用于隔离测试信任锚（必须位于默认测试根目录内），
# 生产默认根固定为 D:\WorkManager-test-data。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedVolumeSerial,
    [Parameter(Mandatory = $true)][string]$ExpectedFileId,
    [string]$ExpectedFinalPath = '',
    [string[]]$TrackedLink = @(),
    [string]$TestRootOverride = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $OutputEncoding

function Write-CleanupResult {
    param(
        [bool]$Ok,
        [hashtable]$Extra = @{}
    )
    $result = [ordered]@{
        ok                       = $Ok
        safe                     = $false
        recursiveDeletePerformed = $false
        stopCode                 = ''
        stopReason               = ''
        unsafePaths              = @()
        steps                    = @()
        sandboxPath              = ''
        checkedAt                = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($null -ne $Extra) {
        foreach ($key in $Extra.Keys) {
            $result[$key] = $Extra[$key]
        }
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 8))
}

try {
    . (Join-Path $PSScriptRoot 'T1-04UatPath.ps1')

    $testRoot = $script:T104UatTestRoot
    if (-not [string]::IsNullOrWhiteSpace($TestRootOverride)) {
        $defaultRoot = (Get-T103UatNormalizedPath $script:T104UatTestRoot).TrimEnd('\')
        $candidate = Get-T103UatNormalizedPath $TestRootOverride
        if (-not (Test-T103UatPathInside $candidate $defaultRoot)) {
            throw ("清理测试信任锚只允许位于默认测试根目录内：{0}。已按 fail-closed 拒绝删除。" -f $candidate)
        }
        $testRoot = $candidate
    }

    # 1. 先验证测试根目录信任锚（含全部祖先、卷身份、最终路径），失败即拒绝删除。
    $trustRecord = Assert-T104UatTrustedRoot -TestRoot $testRoot

    $sandbox = Get-T103UatNormalizedPath $Path
    $testRootNormalized = (Get-T103UatNormalizedPath $testRoot).TrimEnd('\')
    if (-not (Test-T103UatPathInside $sandbox $testRootNormalized)) {
        throw ("清理目标不在专用测试根目录内：{0}。已按 fail-closed 拒绝删除。" -f $sandbox)
    }

    $expectedFinalPathValue = $sandbox
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFinalPath)) {
        $expectedFinalPathValue = Get-T103UatNormalizedPath $ExpectedFinalPath
    }
    $expectedIdentity = [pscustomobject]@{
        path               = $sandbox
        finalPath          = $expectedFinalPathValue
        volumeSerialNumber = $ExpectedVolumeSerial
        fileIdHex          = $ExpectedFileId
        capturedAt         = ''
    }

    $trackedLinks = @($TrackedLink | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $cleanupResult = Invoke-T103FailClosedSandboxCleanup `
        -SandboxPath $sandbox `
        -TestRoot $testRootNormalized `
        -TrustRecord $expectedIdentity `
        -TrackedLinks $trackedLinks

    $extra = [ordered]@{
        safe                     = [bool]$cleanupResult.safe
        recursiveDeletePerformed = [bool]$cleanupResult.recursiveDeletePerformed
        stopCode                 = [string]$cleanupResult.stopCode
        stopReason               = [string]$cleanupResult.stopReason
        unsafePaths              = @($cleanupResult.unsafePaths)
        steps                    = @($cleanupResult.steps)
        sandboxPath              = [string]$cleanupResult.sandboxPath
        testRoot                 = $testRootNormalized
        trustAnchorDigest        = (Get-T104UatIdentityDigest -Identity $trustRecord)
    }
    if ($cleanupResult.safe -eq $true) {
        Write-CleanupResult -Ok $true -Extra $extra
        exit 0
    }
    Write-CleanupResult -Ok $false -Extra $extra
    exit 3
}
catch {
    Write-CleanupResult -Ok $false -Extra ([ordered]@{
            stopCode    = 'unexpectedCleanupGuardError'
            stopReason  = $_.Exception.Message
            sandboxPath = $Path
        })
    exit 3
}
