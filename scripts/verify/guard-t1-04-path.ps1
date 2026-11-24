# WorkManager T1-04 UAT 路径安全守卫 CLI（Python 验证脚本的唯一原生校验入口）
#
# 用法：
#   powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File guard-t1-04-path.ps1 `
#       -Kind database -Path <databasePath>
#   ... -Kind evidence-dir -DatabasePath <databasePath> -Path <evidenceDir>
#   ... -Kind evidence-file -DatabasePath <databasePath> -EvidenceDirectory <evidenceDir> -Path <jsonPath>
#
# stdout 只输出一行 JSON：{ok:true,...} 或 {ok:false,code:"t1-04-path-rejected",message:"..."}。
# 成功退出码 0；安全校验失败退出码 3。任何无法确认身份、重解析点、卷身份不一致、
# 证据路径越界都在打开 SQLite / 写文件之前 fail-closed。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('database', 'evidence-dir', 'evidence-file')]
    [string]$Kind,
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$DatabasePath = '',
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $OutputEncoding

function Write-GuardResult {
    param([bool]$Ok, [string]$Message = '')
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
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress))
}

try {
    . (Join-Path $PSScriptRoot 'T1-04UatPath.ps1')
    switch ($Kind) {
        'database' {
            [void](Assert-T104UatDatabaseFile -Path $Path)
        }
        'evidence-dir' {
            if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
                throw 'evidence-dir 校验缺少 DatabasePath。'
            }
            [void](Assert-T104UatEvidenceDirectory -DatabasePath $DatabasePath -EvidenceDirectory $Path)
        }
        'evidence-file' {
            if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
                throw 'evidence-file 校验缺少 DatabasePath。'
            }
            if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
                throw 'evidence-file 校验缺少 EvidenceDirectory。'
            }
            [void](Assert-T104UatEvidenceFile -DatabasePath $DatabasePath -EvidenceDirectory $EvidenceDirectory -Path $Path)
        }
        default {
            throw ('未知校验类型：{0}' -f $Kind)
        }
    }
    Write-GuardResult -Ok $true
    exit 0
}
catch {
    Write-GuardResult -Ok $false -Message $_.Exception.Message
    exit 3
}
