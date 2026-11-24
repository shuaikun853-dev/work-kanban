# WorkManager T1-04 Migration UAT fail-closed 清理核心（R6-02）
#
# 本模块只负责“迁移失败 UAT 目录”的清理决策，不启动 Release、不写证据文件。
# 由 verify-t1-04-migration-failure.ps1 dot-source 调用，并被
# test-t1-04-migration-cleanup.ps1 通过真实 Windows Junction 故障注入直接测试。
#
# 复用 T1-03 / T1-04 已验证设施：
# - Assert-T104UatDirectoryPath：原生句柄、卷序列号 + 文件 ID、最终路径身份；
# - Invoke-T103FailClosedSandboxCleanup：身份复验、重解析点扫描、逐条目安全递归删除；
# - Get-T104UatEntryState：原生句柄识别普通目录 / Junction / Symbolic Link /
#   其他 reparse point / 无法确认身份。
#
# 安全约束：
# - 不得只用 Test-Path 判断重解析点是否存在（悬空 Junction 在部分环境可能返回 false）；
# - 重解析点、身份无法确认、身份变化一律 fail-closed，不递归删除；
# - 只清理 <UAT 根>\migration-failure-uat，不删除 UAT 根或 evidence 目录。

. (Join-Path $PSScriptRoot 'T1-04UatPath.ps1')

Set-StrictMode -Version Latest

function Invoke-T104FailClosedMigrationCleanupCore {
    param(
        [string]$UatDir,
        [string]$UatRoot,
        [string]$TestRoot,
        $UatDirIdentity,
        $UatRootIdentity
    )

    $result = [ordered]@{
        performed                = $false
        safe                     = $false
        stopCode                 = ''
        stopReason               = ''
        steps                    = @()
        entryKind                = ''
        entryTargetExists        = $null
        entryReparseTag          = ''
        uatRootIdentityUnchanged = $false
    }

    if ([string]::IsNullOrWhiteSpace($UatDir)) {
        $result.safe = $true
        $result.stopCode = 'alreadyAbsent'
        return [pscustomobject]$result
    }

    # 清理入口身份必须先由原生句柄确认；Test-Path 只作为交叉检查，不能决定删除。
    try {
        $entry = Get-T104UatEntryState -Path $UatDir -Label 'UAT 迁移目录'
    }
    catch {
        $result.stopCode = 'entryInspectionFailed'
        $result.stopReason = ('无法读取清理入口的原生文件系统身份：{0}' -f $_.Exception.Message)
        return [pscustomobject]$result
    }
    $result.entryKind = [string]$entry.kind
    $result.entryTargetExists = $entry.targetExists
    if ([long]$entry.reparseTag -ne 0) {
        $result.entryReparseTag = ('0x{0:X8}' -f [long]$entry.reparseTag)
    }

    if (-not [bool]$entry.exists) {
        # 原生句柄确认不存在，但仍要求 Test-Path 与之一致；不一致/无法判断时 fail-closed。
        try {
            $testPathExists = Test-Path -LiteralPath $UatDir
        }
        catch {
            $result.stopCode = 'entryStateUnverifiable'
            $result.stopReason = ('原生句柄报告路径不存在，但 Test-Path 无法完成：{0}' -f $_.Exception.Message)
            return [pscustomobject]$result
        }
        if ($testPathExists) {
            $result.stopCode = 'entryStateUnverifiable'
            $result.stopReason = '原生句柄报告路径不存在，但 Test-Path 报告存在；拒绝标记 alreadyAbsent。'
            return [pscustomobject]$result
        }
        $result.safe = $true
        $result.stopCode = 'alreadyAbsent'
        return [pscustomobject]$result
    }

    if ($entry.kind -eq 'junction' -or $entry.kind -eq 'symbolicLink' -or $entry.kind -eq 'otherReparsePoint') {
        if ($null -eq $entry.targetExists) {
            $result.stopCode = 'reparseTargetUnverifiable'
            $result.stopReason = ('无法确认重解析点目标是否存在：{0}；{1}' -f $entry.path, $entry.targetError)
            return [pscustomobject]$result
        }
        if ($entry.kind -eq 'junction' -and $entry.targetExists -eq $false) {
            $result.stopCode = 'danglingJunction'
            $result.stopReason = '清理入口是悬空 Junction（入口存在、目标不存在）；fail-closed，不递归删除。'
            return [pscustomobject]$result
        }
        if ($entry.kind -eq 'junction') {
            $result.stopCode = 'entryIsJunction'
            $result.stopReason = '清理入口是 Junction；fail-closed，不递归删除。'
            return [pscustomobject]$result
        }
        if ($entry.kind -eq 'symbolicLink') {
            $result.stopCode = 'entryIsSymbolicLink'
            $result.stopReason = '清理入口是 Symbolic Link；fail-closed，不递归删除。'
            return [pscustomobject]$result
        }
        $result.stopCode = 'entryIsOtherReparsePoint'
        $result.stopReason = ('清理入口是未获批准的其他重解析点（tag={0}）；fail-closed，不递归删除。' -f $result.entryReparseTag)
        return [pscustomobject]$result
    }

    if (-not [bool]$entry.isDirectory -or $entry.kind -ne 'directory') {
        $result.stopCode = 'entryNotDirectory'
        $result.stopReason = '清理入口不是普通目录；fail-closed，不删除。'
        return [pscustomobject]$result
    }

    if ($null -eq $UatDirIdentity -or $null -eq $UatRootIdentity) {
        $result.stopCode = 'missingIdentityRecord'
        $result.stopReason = '缺少创建时记录的目录身份，拒绝删除。'
        return [pscustomobject]$result
    }

    try {
        # 清理前重新验证 UAT 根目录身份（卷序列号 + 文件 ID + 真实最终路径）。
        $currentRoot = Assert-T104UatDirectoryPath -Path $UatRoot -Label 'UAT 根目录'
        if (($currentRoot.fileIdHex -ne $UatRootIdentity.fileIdHex) -or
            ($currentRoot.volumeSerialNumber -ne $UatRootIdentity.volumeSerialNumber) -or
            (-not (Test-T103FinalPathEquals ([string]$currentRoot.finalPath) ([string]$UatRootIdentity.finalPath)))) {
            $result.stopCode = 'uatRootIdentityChanged'
            $result.stopReason = '清理前 UAT 根目录身份发生变化，拒绝删除。'
            return [pscustomobject]$result
        }
        $result.uatRootIdentityUnchanged = $true

        $cleanupResult = Invoke-T103FailClosedSandboxCleanup `
            -SandboxPath $UatDir `
            -TestRoot $TestRoot `
            -TrustRecord $UatDirIdentity `
            -TrackedLinks @()
        $result.performed = [bool]$cleanupResult.recursiveDeletePerformed
        $result.safe = [bool]$cleanupResult.safe
        $result.stopCode = [string]$cleanupResult.stopCode
        $result.stopReason = [string]$cleanupResult.stopReason
        $result.steps = @($cleanupResult.steps)

        if ([bool]$cleanupResult.safe -ne $true) {
            return [pscustomobject]$result
        }

        # 清理完成后必须再次由原生句柄确认入口消失，不能只信 Test-Path。
        $afterEntry = Get-T104UatEntryState -Path $UatDir -Label '清理后 UAT 迁移目录'
        if ([bool]$afterEntry.exists) {
            $result.safe = $false
            $result.stopCode = 'sandboxStillExists'
            $result.stopReason = ('安全清理后清理入口仍然存在（kind={0}）；fail-closed。' -f $afterEntry.kind)
            return [pscustomobject]$result
        }

        # 清理后复验 UAT 根目录身份未变化（fail-closed 清理不得触碰根目录本身）。
        $afterRoot = Assert-T104UatDirectoryPath -Path $UatRoot -Label 'UAT 根目录'
        if (($afterRoot.fileIdHex -ne $UatRootIdentity.fileIdHex) -or
            ($afterRoot.volumeSerialNumber -ne $UatRootIdentity.volumeSerialNumber)) {
            $result.safe = $false
            $result.uatRootIdentityUnchanged = $false
            $result.stopCode = 'uatRootIdentityChangedAfterCleanup'
            $result.stopReason = '清理后 UAT 根目录身份发生变化，拒绝确认清理成功。'
            return [pscustomobject]$result
        }
        $result.safe = $true
        return [pscustomobject]$result
    }
    catch {
        $message = $_.Exception.Message
        $result.safe = $false
        $result.stopCode = 'unexpectedCleanupGuardError'
        $result.stopReason = $message
        return [pscustomobject]$result
    }
}
