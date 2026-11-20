# WorkManager T1-03 UAT 输出目录安全校验（P3-02 第三轮修复）
#
# 被 verify-t1-03-ui.ps1 dot-source 使用；也可被 test-t1-03-uat-path.ps1 直接测试。
#
# 规则：
# 1. 输出目录必须在专用测试根目录 D:\WorkManager-test-data\ 之下（不能是根目录本身）；
# 2. 输出目录必须是绝对 DOS 盘符路径；拒绝 UNC、设备路径（\\?\ / \\.\ / \??\）和相对路径；
# 3. 禁止使用/位于正式应用目录 D:\WorkManager（字面路径 + 真实最终路径双重比较）；
# 4. 使用 Windows 原生文件系统句柄（CreateFileW + GetFileInformationByHandleEx +
#    GetFinalPathNameByHandleW）而不是 GetFullPath / Resolve-Path 字符串判断：
#    a. 检查专用测试根目录本身及其所有已存在路径组件；
#    b. 检查输出目录路径上所有已存在的路径组件；
#    c. 任何未获批准的 Junction / Symbolic Link / 其他 reparse point 一律拒绝
#       （当前未批准任何重解析点，白名单为空，因此全部拒绝）；
#    d. 未存在的输出目录：检查其最近已存在祖先目录，并只允许在其下创建普通子目录；
#    e. 校验真实最终路径（展开重解析点后）位于专用测试根目录内且不在正式目录内；
#    f. 校验实际卷身份：输出目录锚点、专用测试根目录与盘符根必须位于同一真实卷；
#    g. 任何无法可靠确认目录身份的情况一律 fail closed（拒绝，不猜测、不回退）；
# 5. 目标目录已存在时：包含数据库文件 -> 拒绝；非空 -> 拒绝；仅空目录允许；
# 6. 本模块只做校验与返回规范化路径，不创建、不删除、不清理任何目录；
# 7. 剩余风险（TOCTOU）：本模块在“检查”与调用方后续“创建目录 / 复制 EXE / 启动程序 /
#    写入数据库”之间仍存在并发替换窗口。调用方必须在每个关键写操作前重新调用本模块的
#    原生校验（verify-t1-03-ui.ps1 已这样做），但路径检查本身不能证明并发攻击已被消除。
#
# 测试注入：Resolve-T103UatOutputDirectoryCore 允许专项测试注入合成测试根/正式根
#（例如用 Junction 模拟根目录），生产入口 Resolve-T103UatOutputDirectory 固定使用常量。

$script:T103UatTestRoot = 'D:\WorkManager-test-data'
$script:T103UatFormalRoot = 'D:\WorkManager'
$script:T103UatApprovedReparsePoints = @() # 当前未批准任何重解析点（显式白名单为空）。
$script:T103NativeGuardSummary = $null

$script:T103NativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace WorkManager
{
    public sealed class NativePathInfo
    {
        public bool Exists;
        public bool IsDirectory;
        public bool IsReparsePoint;
        public uint ReparseTag;
        public uint FileAttributes;
        public string FinalPath;
        public ulong VolumeSerialNumber;
        public string FileIdHex;
        public int Win32Error;
    }

    public static class T103NativeFileSystem
    {
        private const uint FILE_READ_ATTRIBUTES = 0x80;
        private const uint FILE_SHARE_READ = 0x1;
        private const uint FILE_SHARE_WRITE = 0x2;
        private const uint FILE_SHARE_DELETE = 0x4;
        private const uint OPEN_EXISTING = 0x3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
        private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
        private const int FileAttributeTagInfo = 9;
        private const int FileIdInfo = 18;
        private const uint VOLUME_NAME_DOS = 0x0;
        private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileW(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(
            IntPtr hFile,
            int fileInformationClass,
            IntPtr lpFileInformation,
            uint dwBufferSize);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern uint GetFinalPathNameByHandleW(
            IntPtr hFile,
            StringBuilder lpszFilePath,
            uint cchFilePath,
            uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static NativePathInfo Inspect(string path, bool openReparsePoint)
        {
            NativePathInfo info = new NativePathInfo();
            uint flags = FILE_FLAG_BACKUP_SEMANTICS;
            if (openReparsePoint)
            {
                flags |= FILE_FLAG_OPEN_REPARSE_POINT;
            }

            IntPtr handle = CreateFileW(
                path,
                FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero,
                OPEN_EXISTING,
                flags,
                IntPtr.Zero);

            if (handle == InvalidHandleValue)
            {
                int openError = Marshal.GetLastWin32Error();
                info.Win32Error = openError;
                info.Exists = false;
                // 2 = ERROR_FILE_NOT_FOUND，3 = ERROR_PATH_NOT_FOUND：路径不存在，由调用方按
                // “不存在”处理；其余错误（含拒绝访问）交给调用方 fail closed。
                if (openError == 2 || openError == 3)
                {
                    return info;
                }
                throw new Win32Exception(openError, "CreateFileW failed for " + path);
            }

            IntPtr attributeBuffer = IntPtr.Zero;
            IntPtr idBuffer = IntPtr.Zero;
            try
            {
                // FILE_ATTRIBUTE_TAG_INFO：DWORD FileAttributes + DWORD ReparseTag。
                attributeBuffer = Marshal.AllocHGlobal(8);
                if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, attributeBuffer, 8))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetFileInformationByHandleEx(FileAttributeTagInfo) failed for " + path);
                }
                uint attributes = (uint)Marshal.ReadInt32(attributeBuffer, 0);
                uint reparseTag = (uint)Marshal.ReadInt32(attributeBuffer, 4);
                info.FileAttributes = attributes;
                info.IsReparsePoint = (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                info.ReparseTag = reparseTag;
                info.IsDirectory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

                // FILE_ID_INFO：ULONGLONG VolumeSerialNumber + FILE_ID_128 FileId[16]。
                idBuffer = Marshal.AllocHGlobal(24);
                if (!GetFileInformationByHandleEx(handle, FileIdInfo, idBuffer, 24))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetFileInformationByHandleEx(FileIdInfo) failed for " + path);
                }
                info.VolumeSerialNumber = (ulong)Marshal.ReadInt64(idBuffer, 0);
                byte[] fileId = new byte[16];
                Marshal.Copy(new IntPtr(idBuffer.ToInt64() + 8), fileId, 0, 16);
                StringBuilder fileIdHex = new StringBuilder(32);
                for (int index = 0; index < fileId.Length; index++)
                {
                    fileIdHex.Append(fileId[index].ToString("x2"));
                }
                info.FileIdHex = fileIdHex.ToString();

                // 需要真实最终路径时打开“跟随重解析点”的句柄；仅检测重解析属性时不调用，
                // 因为 OPEN_REPARSE_POINT 句柄的最终路径语义不适合作为目标身份证据。
                if (!openReparsePoint)
                {
                    StringBuilder finalPath = new StringBuilder(512);
                    while (true)
                    {
                        uint written = GetFinalPathNameByHandleW(
                            handle,
                            finalPath,
                            (uint)finalPath.Capacity,
                            VOLUME_NAME_DOS);
                        if (written == 0)
                        {
                            throw new Win32Exception(
                                Marshal.GetLastWin32Error(),
                                "GetFinalPathNameByHandleW failed for " + path);
                        }
                        if (written < (uint)finalPath.Capacity)
                        {
                            finalPath.Length = (int)written;
                            break;
                        }
                        finalPath = new StringBuilder((int)written + 1);
                    }
                    info.FinalPath = finalPath.ToString();
                }

                info.Exists = true;
                return info;
            }
            finally
            {
                if (attributeBuffer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(attributeBuffer);
                }
                if (idBuffer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(idBuffer);
                }
                CloseHandle(handle);
            }
        }
    }
}
'@

function Initialize-T103NativeFileSystem {
    if ('WorkManager.T103NativeFileSystem' -as [type]) {
        return
    }
    Add-Type -TypeDefinition $script:T103NativeSource -Language CSharp -ErrorAction Stop
}

function Get-T103NativePathInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$OpenReparsePoint
    )
    Initialize-T103NativeFileSystem
    try {
        return [WorkManager.T103NativeFileSystem]::Inspect($Path, $OpenReparsePoint)
    }
    catch {
        throw ("无法读取路径的真实文件系统信息（已按 fail-closed 拒绝）：{0}；原因：{1}" -f $Path, $_.Exception.Message)
    }
}

# 把句柄返回的最终路径规范化为可比较的 DOS 盘符路径（去掉 \\?\ 前缀）。
# UNC / 设备路径直接拒绝（不允许作为 UAT 输出目录或测试根目录）。
function ConvertTo-T103NativeComparablePath {
    param([Parameter(Mandatory = $true)][string]$FinalPath)
    if ([string]::IsNullOrWhiteSpace($FinalPath)) {
        throw 'Windows 文件系统句柄返回了空最终路径，无法确认目录身份（已按 fail-closed 拒绝）。'
    }
    $text = $FinalPath.Replace('/', '\')
    if ($text.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Windows 文件系统句柄解析出的最终路径是 UNC 网络路径：{0}。UAT 输出目录不允许使用网络路径（已按 fail-closed 拒绝）。" -f $text)
    }
    if ($text.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $text = $text.Substring(4)
    }
    elseif ($text.StartsWith('\??\', [System.StringComparison]::Ordinal)) {
        $text = $text.Substring(4)
    }
    if ($text.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        throw ("Windows 文件系统句柄解析出的最终路径不是本地 DOS 盘符路径：{0}。已按 fail-closed 拒绝。" -f $text)
    }
    if (-not ($text -match '^[A-Za-z]:')) {
        throw ("Windows 文件系统句柄解析出的最终路径不是绝对盘符路径：{0}。已按 fail-closed 拒绝。" -f $text)
    }
    if ($text.Length -gt 2) {
        $text = $text.TrimEnd('\')
    }
    return $text
}

function Test-T103FinalPathEquals {
    param([string]$Left, [string]$Right)
    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-T103FinalPathInside {
    param([string]$Path, [string]$Root)
    $normalizedPath = ConvertTo-T103NativeComparablePath $Path
    $normalizedRoot = (ConvertTo-T103NativeComparablePath $Root).TrimEnd('\')
    if (Test-T103FinalPathEquals $normalizedPath $normalizedRoot) {
        return $false
    }
    return $normalizedPath.StartsWith(
        $normalizedRoot + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-T103UatSafePathSegments {
    param([Parameter(Mandatory = $true)][string]$FullPath)
    $driveRoot = [System.IO.Path]::GetPathRoot($FullPath)
    if ([string]::IsNullOrWhiteSpace($driveRoot)) {
        throw ("输出目录不是绝对盘符路径，无法拆分为路径组件：{0}。已按 fail-closed 拒绝。" -f $FullPath)
    }
    # 盘符后的部分不允许 Windows 文件名非法字符（冒号只允许出现在盘符位置）。
    $afterDrive = $FullPath.Substring($driveRoot.Length)
    if ($afterDrive -match '[<>:"|?*]') {
        throw ("输出目录路径包含 Windows 文件名非法字符（<>:`"|?*）：{0}。已按 fail-closed 拒绝。" -f $FullPath)
    }
    $segments = @($FullPath.Substring($driveRoot.Length).Split('\') | Where-Object { $_ -ne '' })
    foreach ($segment in $segments) {
        if ($segment -eq '.' -or $segment -eq '..') {
            throw ("输出目录包含未规范化的相对组件（. 或 ..）：{0}。已按 fail-closed 拒绝。" -f $FullPath)
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw ("输出目录路径组件以点或空格结尾，Windows 会做名称归一化，无法保证身份一致：{0}。已按 fail-closed 拒绝。" -f $FullPath)
        }
        if ($segment -match '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9]|LPT[0-9])(\..*)?$') {
            throw ("输出目录路径组件是 Windows 保留设备名：{0}（组件：{1}）。已按 fail-closed 拒绝。" -f $FullPath, $segment)
        }
    }
}

# 逐级检查一个绝对盘符路径的所有已存在组件：
# - 每一级打开两次句柄：一次带 FILE_FLAG_OPEN_REPARSE_POINT（检测重解析属性），一次跟随
#   重解析点（取得真实最终路径、卷序列号与文件 ID）；
# - 未获批准的重解析点立即拒绝；
# - 两次句柄的卷序列号/文件 ID 不一致（检查期间被替换）立即拒绝；
# - 已存在但非目录的组件拒绝；
# - 不存在的后缀记录到 Missing，由调用方确认“只创建普通子目录”。
function Get-T103NativePathChain {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [bool]$RejectReparsePoint = $true
    )
    $normalized = Get-T103UatNormalizedPath $Path
    if (-not ($normalized -match '^[A-Za-z]:\\')) {
        throw ("{0}不是本地盘符绝对路径，无法用 Windows 文件系统句柄检查：{1}。已按 fail-closed 拒绝。" -f $Label, $normalized)
    }
    Assert-T103UatSafePathSegments $normalized

    $driveRoot = [System.IO.Path]::GetPathRoot($normalized)
    $segments = @($normalized.Substring($driveRoot.Length).Split('\') | Where-Object { $_ -ne '' })

    $existing = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $driveInfo = Get-T103NativePathInfo -Path $driveRoot -OpenReparsePoint $true
    if (-not $driveInfo.Exists) {
        throw ("无法打开盘符根目录句柄，无法确认目录身份：{0}。已按 fail-closed 拒绝。" -f $driveRoot)
    }
    if ($driveInfo.IsReparsePoint) {
        throw ("盘符根本身是 Windows 重解析点，无法确认真实卷身份：{0}。已按 fail-closed 拒绝。" -f $driveRoot)
    }
    [void]$existing.Add($driveInfo)

    $current = $driveRoot
    $inMissingSuffix = $false
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if ($inMissingSuffix) {
            [void]$missing.Add($segment)
            continue
        }
        $linkInfo = Get-T103NativePathInfo -Path $current -OpenReparsePoint $true
        if (-not $linkInfo.Exists) {
            $inMissingSuffix = $true
            [void]$missing.Add($segment)
            continue
        }
        if ($linkInfo.IsReparsePoint -and $RejectReparsePoint) {
            throw ("{0}路径检查失败：路径组件是未获批准的 Windows 重解析点（Junction / Symbolic Link / 其他 reparse point），重解析标签=0x{1:X8}：{2}。本任务未批准任何重解析点，已按 fail-closed 拒绝；请改用专用测试根目录内的普通新目录。" -f $Label, $linkInfo.ReparseTag, $current)
        }
        $followInfo = Get-T103NativePathInfo -Path $current -OpenReparsePoint $false
        if (-not $followInfo.Exists) {
            throw ("{0}路径检查失败：路径组件在检查期间消失或被替换：{1}。已按 fail-closed 拒绝。" -f $Label, $current)
        }
        if (($linkInfo.VolumeSerialNumber -ne $followInfo.VolumeSerialNumber) -or ($linkInfo.FileIdHex -ne $followInfo.FileIdHex)) {
            throw ("{0}路径检查失败：路径组件在两次句柄检查之间指向发生变化（可能是并发重解析点替换）：{1}。已按 fail-closed 拒绝。" -f $Label, $current)
        }
        if (-not $followInfo.IsDirectory) {
            throw ("{0}路径检查失败：路径组件已存在但不是目录：{1}。已按 fail-closed 拒绝。" -f $Label, $current)
        }
        [void]$existing.Add($followInfo)
    }

    return [pscustomobject]@{
        Normalized = $normalized
        DriveRoot  = $driveRoot
        Existing   = @($existing)
        Missing    = @($missing)
    }
}

function Get-T103NativeChainFinalPath {
    param([Parameter(Mandatory = $true)]$Chain)
    if (@($Chain.Existing).Count -eq 0) {
        throw '内部错误：路径链没有任何已存在组件。已按 fail-closed 拒绝。'
    }
    $lastExisting = $Chain.Existing[@($Chain.Existing).Count - 1]
    $finalPath = ConvertTo-T103NativeComparablePath $lastExisting.FinalPath
    return $finalPath
}

function Assert-T103NativeVolumeIdentity {
    param(
        [Parameter(Mandatory = $true)]$ReferenceInfo,
        [Parameter(Mandatory = $true)]$CandidateInfo,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($ReferenceInfo.VolumeSerialNumber -ne $CandidateInfo.VolumeSerialNumber) {
        throw ("{0}的实际卷身份校验失败：目标路径与专用测试根目录不在同一个真实卷上。已按 fail-closed 拒绝。" -f $Context)
    }
}

# 原生文件系统安全检查（P3-02 核心）：
# 1. 专用测试根目录必须存在、全部组件为普通目录、本身不是重解析点；
# 2. 盘符根、专用测试根目录与输出目录锚点必须位于同一真实卷；
# 3. 输出目录路径的所有已存在组件不得是未获批准的重解析点；
# 4. 输出目录（或最近已存在祖先）的真实最终路径必须在专用测试根目录内；
# 5. 真实最终路径不得位于正式目录内（字面路径命中已在 Resolve 中提前拒绝）；
# 6. 真实最终路径必须与请求的字面路径一致（大小写不敏感），否则 fail closed。
function Assert-T103NativePathSafety {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)][string]$FormalRoot
    )
    # 先校验信任锚（专用测试根目录本身），再校验输出路径：测试根目录本身或其祖先
    # 为重解析点时直接拒绝，不依赖输出路径链的间接命中。
    $testRootChain = Get-T103NativePathChain -Path $TestRoot -Label '专用测试根目录'
    if (@($testRootChain.Missing).Count -gt 0) {
        throw ("无法确认专用测试根目录的真实文件系统身份：目录不存在或路径组件缺失：{0}。已按 fail-closed 拒绝。" -f $testRootChain.Normalized)
    }
    $requestedChain = Get-T103NativePathChain -Path $RequestedPath -Label '输出目录'

    $driveInfo = @($testRootChain.Existing)[0]
    $testRootInfo = @($testRootChain.Existing)[@($testRootChain.Existing).Count - 1]
    if (-not $testRootInfo.IsDirectory) {
        throw ("专用测试根目录不是目录，无法确认身份：{0}。已按 fail-closed 拒绝。" -f $testRootChain.Normalized)
    }
    Assert-T103NativeVolumeIdentity -ReferenceInfo $driveInfo -CandidateInfo $testRootInfo -Context '专用测试根目录'

    # 正式目录存在时解析其真实最终路径；不存在时字面比较已在 Resolve 中完成。
    $formalFinalPath = ''
    $formalChain = Get-T103NativePathChain -Path $FormalRoot -Label '正式应用目录' -RejectReparsePoint $false
    if (@($formalChain.Missing).Count -eq 0) {
        $formalFinalPath = Get-T103NativeChainFinalPath $formalChain
    }

    $testRootFinalPath = Get-T103NativeChainFinalPath $testRootChain
    $missing = @($requestedChain.Missing)
    $anchorInfo = @($requestedChain.Existing)[@($requestedChain.Existing).Count - 1]
    Assert-T103NativeVolumeIdentity -ReferenceInfo $testRootInfo -CandidateInfo $anchorInfo -Context 'UAT 输出目录锚点'

    if ($missing.Count -eq 0) {
        $anchorFinalPath = Get-T103NativeChainFinalPath $requestedChain
        $anchorExpectedPath = $requestedChain.Normalized
    }
    else {
        $parentFinalPath = Get-T103NativeChainFinalPath $requestedChain
        $anchorFinalPath = $parentFinalPath.TrimEnd('\') + '\' + ($missing -join '\')
        $anchorExpectedPath = $requestedChain.Normalized
    }

    $finalPathInsideRoot = Test-T103FinalPathInside $anchorFinalPath $testRootFinalPath
    if (-not $finalPathInsideRoot) {
        throw ("UAT 输出目录的实际最终路径（展开重解析点后）不在专用测试根目录内：最终路径={0}，专用测试根目录最终路径={1}。已按 fail-closed 拒绝。" -f $anchorFinalPath, $testRootFinalPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($formalFinalPath) -and (Test-T103FinalPathInside $anchorFinalPath $formalFinalPath)) {
        throw ("UAT 输出目录的实际最终路径位于正式应用目录内：{0}。正式目录的真实最终路径：{1}。已按 fail-closed 拒绝。" -f $anchorFinalPath, $formalFinalPath)
    }
    if (-not (Test-T103FinalPathEquals $anchorFinalPath $anchorExpectedPath)) {
        throw ("UAT 输出目录请求路径与 Windows 文件系统解析出的真实路径不一致（可能是短名/别名路径），无法保证写入位置：请求={0}，真实={1}。已按 fail-closed 拒绝。" -f $anchorExpectedPath, $anchorFinalPath)
    }

    $script:T103NativeGuardSummary = [ordered]@{
        checkedComponentCount  = @($requestedChain.Existing).Count + @($testRootChain.Existing).Count
        testRootExists         = $true
        testRootReparsePoint   = $false
        requestedPathExists    = ($missing.Count -eq 0)
        missingComponentCount  = $missing.Count
        reparsePointAllowed    = $false
        finalPathInsideRoot    = $finalPathInsideRoot
        finalPathOutsideFormal = $true
        volumeIdentityMatch    = $true
        fileIdConsistency      = $true
        checkedAt              = (Get-Date).ToUniversalTime().ToString('o')
    }
    return $script:T103NativeGuardSummary
}

function Get-T103UatNativeGuardSummary {
    if ($null -eq $script:T103NativeGuardSummary) {
        return $null
    }
    return $script:T103NativeGuardSummary
}

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

# 校验输出的形式要求（绝对本地盘符路径；拒绝 UNC / 设备路径 / 相对路径 / 非法字符）。
function Assert-T103UatRequestedPathFormat {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$TestRoot
    )
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        throw '输出目录不能为空。请使用新的 UAT 目录，例如 D:\WorkManager-test-data\t1-03-ui-<timestamp>。'
    }
    $trimmed = $RequestedPath.Trim()
    if ($trimmed.StartsWith('\\', [System.StringComparison]::Ordinal) -or
        $trimmed.StartsWith('//', [System.StringComparison]::Ordinal) -or
        $trimmed.StartsWith('\', [System.StringComparison]::Ordinal) -or
        $trimmed.StartsWith('/', [System.StringComparison]::Ordinal)) {
        throw ("输出目录不能使用 UNC、设备路径（\\?\ / \\.\ / \??\）或根相对路径：{0}。必须位于专用测试根目录 {1} 之下并使用普通本地盘符绝对路径。" -f $RequestedPath, $TestRoot)
    }
    if (-not ($trimmed -match '^[A-Za-z]:[\\/]')) {
        throw ("输出目录必须是本地盘符绝对路径，拒绝相对路径：{0}。必须位于专用测试根目录 {1} 之下。" -f $RequestedPath, $TestRoot)
    }
    if ($trimmed.Substring(2) -match '[<>:"|?*]') {
        throw ("输出目录路径包含 Windows 文件名非法字符（<>:`"|?*）：{0}。已按 fail-closed 拒绝。" -f $RequestedPath)
    }
    # 在 GetFullPath 归一化之前检查原始请求路径组件：尾部点/空白会被 Windows 归一化，
    # 可能形成路径别名；保留设备名（含 COM0/LPT0/CONIN$/CONOUT$）不得作为组件。
    $rawSegments = @($trimmed.Split([char[]]@('\', '/')) | Where-Object { $_ -ne '' })
    foreach ($segment in $rawSegments) {
        if ($segment -match '^[A-Za-z]:$') {
            continue
        }
        # 单独的 . / .. 由 GetFullPath 规范化处理（越界由边界规则拒绝），不算尾部点别名。
        if ($segment -ne '.' -and $segment -ne '..' -and ($segment.EndsWith('.') -or ($segment -match '\s$'))) {
            throw ("输出目录路径组件以点或空白结尾（Windows 会归一化名称，可能造成路径别名）：{0}（组件：{1}）。已按 fail-closed 拒绝。" -f $RequestedPath, $segment)
        }
        if ($segment -match '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9]|LPT[0-9])(\..*)?$') {
            throw ("输出目录路径组件是 Windows 保留设备名：{0}（组件：{1}）。已按 fail-closed 拒绝。" -f $RequestedPath, $segment)
        }
    }
}

function Resolve-T103UatOutputDirectoryCore {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)][string]$FormalRoot
    )
    $testRootPath = Get-T103UatNormalizedPath $TestRoot
    $formalRootPath = Get-T103UatNormalizedPath $FormalRoot
    Assert-T103UatRequestedPathFormat -RequestedPath $RequestedPath -TestRoot $testRootPath
    $full = Get-T103UatNormalizedPath $RequestedPath

    if ((Test-T103UatPathEquals $full $formalRootPath) -or (Test-T103UatPathInside $full $formalRootPath)) {
        throw ("禁止使用正式应用目录 {0} 作为 UAT 输出目录（实际：{1}）。请使用新的测试目录，例如 {2}\t1-03-ui-<timestamp>。" -f $formalRootPath, $full, $testRootPath)
    }
    if (Test-T103UatPathEquals $full $testRootPath) {
        throw ("输出目录不能是专用测试根目录本身：{0}。请使用该根目录下的新 UAT 目录，例如 {0}\t1-03-ui-<timestamp>。" -f $testRootPath)
    }
    if (-not (Test-T103UatPathInside $full $testRootPath)) {
        throw ("输出目录必须位于专用测试根目录 {0} 之下（实际：{1}）。请使用新的 UAT 目录，例如 {0}\t1-03-ui-<timestamp>。" -f $testRootPath, $full)
    }

    # P3-02：在任何创建/复制/启动/写库之前完成 Windows 原生文件系统身份检查。
    [void](Assert-T103NativePathSafety -RequestedPath $full -TestRoot $testRootPath -FormalRoot $formalRootPath)

    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            throw ("输出路径已存在且不是目录：{0}。默认拒绝复用/覆盖，请使用新的测试目录。" -f $full)
        }
        $databaseFiles = @(Get-T103UatDatabaseFiles $full)
        if ($databaseFiles.Count -gt 0) {
            throw ("目标 UAT 目录已包含数据库文件（{0} 个），默认拒绝复用旧数据库。请使用新的测试目录，例如 {1}\t1-03-ui-<timestamp>。" -f $databaseFiles.Count, $testRootPath)
        }
        $entries = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
        if ($entries.Count -gt 0) {
            throw ("目标 UAT 目录已存在且非空（{0} 个条目），拒绝覆盖或删除未知内容。请使用新的测试目录，例如 {1}\t1-03-ui-<timestamp>。" -f $entries.Count, $testRootPath)
        }
    }

    return $full
}

function Resolve-T103UatOutputDirectory([string]$RequestedPath) {
    return Resolve-T103UatOutputDirectoryCore `
        -RequestedPath $RequestedPath `
        -TestRoot $script:T103UatTestRoot `
        -FormalRoot $script:T103UatFormalRoot
}
