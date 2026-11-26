# WorkManager T1-03 UAT 输出目录安全校验（P3-02 第三轮修复 + 第四轮 F1/F2 修复）
#
# 被 verify-t1-03-ui.ps1 dot-source 使用；也可被 test-t1-03-uat-path.ps1 直接测试。
#
# 第四轮 F1/F2 增补（2026-11-20）：
# 1. 信任锚验证（Assert-T103UatTrustedTestRoot）：只用于专用测试根目录本身，与普通输出目录
#    校验明确分离。要求在任意写操作之前，用 Windows 原生文件系统句柄验证测试根目录存在、
#    是真实目录、全部已存在祖先组件不是未批准重解析点、真实最终路径与预期一致、卷身份一致、
#    不在正式目录内；任一身份信息无法确认时 fail closed。测试根目录不存在时绝不自动创建。
# 2. 目录身份记录（Get-T103DirectoryIdentityRecord / Compare-T103DirectoryIdentity）：记录并
#    比对卷序列号 + 文件 ID + 真实最终路径，供 fail-closed 清理前确认沙箱身份。
# 3. 无跟随重解析点的目录树扫描（Find-T103ReparsePointsInTree）：逐条目用原生句柄检查，
#    发现任何重解析点即返回，不进入/不跟随。
# 4. Fail-closed 沙箱清理（Invoke-T103FailClosedSandboxCleanup）：先删除并逐个复验跟踪链接、
#    再扫描未预期重解析点、再复验目录身份；任一条件不满足立即停止，绝不执行整个沙箱递归删除，
#    保留现场并返回可定位的失败信息。只有全部条件满足才执行逐条目校验后的安全递归删除
#    （Remove-T103VerifiedDirectoryTree，绝不跟随重解析点进入外部目录）。
# 5. 受控故障注入（FaultHook）：仅专项测试使用；在真实 Junction / Symbolic Link 的删除
#    步骤抛出确定性异常，模拟操作系统拒绝删除链接，不参与产品路径校验。
#
# 规则（第三轮，保持）：
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
# 仓库证据目录：T1-03 证据文件唯一允许写入的根目录（第五轮 F1 写入边界）。
$script:T103RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:T103EvidenceRoot = Join-Path $script:T103RepoRoot 'docs\testing\reports\T1-03-assets\evidence'
$script:T103UatApprovedReparsePoints = @() # 当前未批准任何重解析点（显式白名单为空）。
$script:T103NativeGuardSummary = $null
$script:T103UatTrustedRootRecord = $null  # 信任锚验证成功后的根目录身份记录（第四轮 F1）。
$script:T103UatTrustAnchorVerified = $false

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
        public uint NumberOfLinks;
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
        private const int FileStandardInfo = 1;
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

                // FILE_STANDARD_INFO：NumberOfLinks 位于偏移 16（AllocationSize 8 + EndOfFile 8）。
                IntPtr standardBuffer = Marshal.AllocHGlobal(24);
                try
                {
                    if (!GetFileInformationByHandleEx(handle, FileStandardInfo, standardBuffer, 24))
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "GetFileInformationByHandleEx(FileStandardInfo) failed for " + path);
                    }
                    info.NumberOfLinks = (uint)Marshal.ReadInt32(standardBuffer, 16);
                }
                finally
                {
                    Marshal.FreeHGlobal(standardBuffer);
                }

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
        [bool]$RejectReparsePoint = $true,
        # 允许“最后一个组件”是已存在的普通文件（证据文件写入用；中间组件仍必须是目录）。
        [switch]$AllowFinalFile
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
    for ($segmentIndex = 0; $segmentIndex -lt @($segments).Count; $segmentIndex++) {
        $segment = $segments[$segmentIndex]
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
            $finalFileAllowed = $AllowFinalFile -and ($segmentIndex -eq (@($segments).Count - 1)) -and ($missing.Count -eq 0)
            if (-not $finalFileAllowed) {
                throw ("{0}路径检查失败：路径组件已存在但不是目录：{1}。已按 fail-closed 拒绝。" -f $Label, $current)
            }
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

# ===========================================================================
# 第四轮 F1：专用测试根目录信任锚验证
#
# 与 Resolve-T103UatOutputDirectory（普通输出目录校验）明确分离：
# - 只接受“测试根目录本身”作为被验证对象，不接受子目录；
# - 要求目录必须已存在（缺失时 fail closed，绝不自动创建）；
# - 除共享路径链原语外，额外要求真实最终路径与预期字面路径一致、卷身份与盘符根一致、
#   不在正式应用目录内（字面 + 真实最终路径双重比较）；
# - 捕获卷序列号 + 文件 ID + 真实最终路径作为信任记录，供后续沙箱身份比对；
# - 任何一步无法确认身份都 fail closed。
# ===========================================================================
function Assert-T103UatTrustedTestRoot {
    param(
        [string]$TestRoot = $script:T103UatTestRoot,
        [string]$FormalRoot = $script:T103UatFormalRoot
    )
    $script:T103UatTrustedRootRecord = $null
    $script:T103UatTrustAnchorVerified = $false
    try {
        if ([string]::IsNullOrWhiteSpace($TestRoot)) {
            throw '专用测试根目录参数为空。'
        }
        $testRootPath = Get-T103UatNormalizedPath $TestRoot
        if (-not ($testRootPath -match '^[A-Za-z]:\\')) {
            throw ("专用测试根目录不是本地盘符绝对路径：{0}。" -f $testRootPath)
        }
        $driveRoot = [System.IO.Path]::GetPathRoot($testRootPath)
        if ([string]::Equals($testRootPath.TrimEnd('\'), $driveRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("专用测试根目录不能是盘符根目录本身：{0}。" -f $testRootPath)
        }

        # 1) 用原生句柄逐级检查测试根目录及其全部已存在祖先组件（拒绝未批准重解析点）。
        $chain = Get-T103NativePathChain -Path $testRootPath -Label '专用测试根目录'
        if (@($chain.Missing).Count -gt 0) {
            throw ("专用测试根目录不存在或路径组件缺失：{0}。必须由人工/前置步骤预先创建为普通目录；本脚本不会自动创建测试根目录（fail closed）。" -f $testRootPath)
        }
        $driveInfo = @($chain.Existing)[0]
        $rootInfo = @($chain.Existing)[@($chain.Existing).Count - 1]
        if (-not $rootInfo.IsDirectory) {
            throw ("专用测试根目录不是真实目录：{0}。已按 fail-closed 拒绝。" -f $testRootPath)
        }
        if ($rootInfo.IsReparsePoint) {
            throw ("专用测试根目录是重解析点（tag=0x{0:X8}）：{1}。已按 fail-closed 拒绝。" -f $rootInfo.ReparseTag, $testRootPath)
        }
        if ([string]::IsNullOrWhiteSpace([string]$rootInfo.FileIdHex) -or [string]::IsNullOrWhiteSpace([string]$rootInfo.VolumeSerialNumber)) {
            throw ("无法读取专用测试根目录的卷序列号/文件 ID，无法确认目录身份：{0}。已按 fail-closed 拒绝。" -f $testRootPath)
        }
        Assert-T103NativeVolumeIdentity -ReferenceInfo $driveInfo -CandidateInfo $rootInfo -Context '专用测试根目录'

        # 2) 真实最终路径必须与预期字面路径一致（防止短名/别名/替换）。
        $finalPath = Get-T103NativeChainFinalPath $chain
        if (-not (Test-T103FinalPathEquals $finalPath $testRootPath)) {
            throw ("专用测试根目录的真实最终路径与预期不一致（可能是短名/别名/被替换）：预期={0}，真实={1}。已按 fail-closed 拒绝。" -f $testRootPath, $finalPath)
        }

        # 3) 不得位于正式应用目录内（字面 + 真实最终路径双重比较）。
        $formalRootPath = Get-T103UatNormalizedPath $FormalRoot
        if ((Test-T103UatPathEquals $testRootPath $formalRootPath) -or (Test-T103UatPathInside $testRootPath $formalRootPath)) {
            throw ("专用测试根目录位于正式应用目录内：{0}。已按 fail-closed 拒绝。" -f $testRootPath)
        }
        $formalChain = Get-T103NativePathChain -Path $formalRootPath -Label '正式应用目录' -RejectReparsePoint $false
        if (@($formalChain.Missing).Count -eq 0) {
            $formalFinalPath = Get-T103NativeChainFinalPath $formalChain
            if ((Test-T103FinalPathEquals $finalPath $formalFinalPath) -or (Test-T103FinalPathInside $finalPath $formalFinalPath)) {
                throw ("专用测试根目录的真实最终路径位于正式应用目录内：{0}。已按 fail-closed 拒绝。" -f $finalPath)
            }
        }

        # 4) 记录信任锚身份（供后续沙箱身份比对；不落盘机器专属信息）。
        $record = [pscustomobject]@{
            path                   = $testRootPath
            finalPath              = $finalPath
            volumeSerialNumber     = [string]$rootInfo.VolumeSerialNumber
            fileIdHex              = [string]$rootInfo.FileIdHex
            existingComponentCount = @($chain.Existing).Count
            verifiedAt             = (Get-Date).ToUniversalTime().ToString('o')
        }
        $script:T103UatTrustedRootRecord = $record
        $script:T103UatTrustAnchorVerified = $true
        return $record
    }
    catch {
        $script:T103UatTrustedRootRecord = $null
        $script:T103UatTrustAnchorVerified = $false
        throw ("专用测试根目录信任锚验证失败，已按 fail-closed 停止（未执行任何写操作）：{0}" -f $_.Exception.Message)
    }
}

function Get-T103UatTrustedRootRecord {
    if ($null -eq $script:T103UatTrustedRootRecord) {
        return $null
    }
    return $script:T103UatTrustedRootRecord
}

# ===========================================================================
# 第四轮 F2：目录身份记录 / 重解析点扫描 / fail-closed 清理
# ===========================================================================

# 读取一个真实目录的稳定身份：卷序列号 + 文件 ID + 真实最终路径。
# 任何无法确认身份的情况（不存在/重解析点/非目录/两次句柄不一致/最终路径不一致）都抛错。
function Get-T103DirectoryIdentityRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = '目录'
    )
    $normalized = Get-T103UatNormalizedPath $Path
    $linkInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if (-not $linkInfo.Exists) {
        throw ("{0}不存在，无法确认目录身份：{1}。已按 fail-closed 停止。" -f $Label, $normalized)
    }
    if ($linkInfo.IsReparsePoint) {
        throw ("{0}是重解析点（tag=0x{1:X8}），无法确认其真实目录身份：{2}。已按 fail-closed 停止。" -f $Label, $linkInfo.ReparseTag, $normalized)
    }
    if (-not $linkInfo.IsDirectory) {
        throw ("{0}不是目录，无法确认目录身份：{1}。已按 fail-closed 停止。" -f $Label, $normalized)
    }
    $followInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $false
    if (-not $followInfo.Exists) {
        throw ("{0}在身份检查期间消失或被替换：{1}。已按 fail-closed 停止。" -f $Label, $normalized)
    }
    if (($linkInfo.VolumeSerialNumber -ne $followInfo.VolumeSerialNumber) -or
        ($linkInfo.FileIdHex -ne $followInfo.FileIdHex)) {
        throw ("{0}在两次句柄检查之间指向发生变化（可能是并发重解析点替换）：{1}。已按 fail-closed 停止。" -f $Label, $normalized)
    }
    if ([string]::IsNullOrWhiteSpace([string]$followInfo.FileIdHex) -or [string]::IsNullOrWhiteSpace([string]$followInfo.VolumeSerialNumber)) {
        throw ("无法读取{0}的卷序列号/文件 ID：{1}。已按 fail-closed 停止。" -f $Label, $normalized)
    }
    $finalPath = ConvertTo-T103NativeComparablePath $followInfo.FinalPath
    if (-not (Test-T103FinalPathEquals $finalPath $normalized)) {
        throw ("{0}的真实最终路径与预期字面路径不一致（可能是短名/别名/替换）：预期={1}，真实={2}。已按 fail-closed 停止。" -f $Label, $normalized, $finalPath)
    }
    return [pscustomobject]@{
        path               = $normalized
        finalPath          = $finalPath
        volumeSerialNumber = [string]$followInfo.VolumeSerialNumber
        fileIdHex          = [string]$followInfo.FileIdHex
        capturedAt         = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Compare-T103DirectoryIdentity {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Current
    )
    $issues = New-Object System.Collections.ArrayList
    if (-not (Test-T103FinalPathEquals ([string]$Expected.finalPath) ([string]$Current.finalPath))) {
        [void]$issues.Add('finalPath')
    }
    if ([string]$Expected.volumeSerialNumber -ne [string]$Current.volumeSerialNumber) {
        [void]$issues.Add('volumeSerialNumber')
    }
    if ([string]$Expected.fileIdHex -ne [string]$Current.fileIdHex) {
        [void]$issues.Add('fileId')
    }
    if (@($issues).Count -gt 0) {
        throw ("目录身份与预期不一致（差异：{0}）：{1}。已按 fail-closed 停止。" -f (@($issues) -join ','), $Current.path)
    }
}

# 扫描目录树中的全部重解析点（不跟随、不进入链接目标）。
# 逐条目使用原生句柄 OPEN_REPARSE_POINT 检查；发现重解析点立即记录并跳过，
# 不递归进入；发现目录消失/被替换/枚举失败时 fail closed。
function Find-T103ReparsePointsInTree {
    param(
        [Parameter(Mandatory = $true)][string]$RootDirectory,
        [int]$MaxEntries = 20000
    )
    $rootPath = Get-T103UatNormalizedPath $RootDirectory
    $rootInfo = Get-T103NativePathInfo -Path $rootPath -OpenReparsePoint $true
    if (-not $rootInfo.Exists) {
        throw ("扫描根目录不存在：{0}。已按 fail-closed 停止。" -f $rootPath)
    }
    if ($rootInfo.IsReparsePoint -or (-not $rootInfo.IsDirectory)) {
        throw ("扫描根目录本身不是普通目录：{0}。已按 fail-closed 停止。" -f $rootPath)
    }
    $found = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($rootPath)
    $visited = 0
    try {
        while ($queue.Count -gt 0) {
            $directory = [string]$queue.Dequeue()
            $directoryInfo = Get-T103NativePathInfo -Path $directory -OpenReparsePoint $true
            if (-not $directoryInfo.Exists -or $directoryInfo.IsReparsePoint -or (-not $directoryInfo.IsDirectory)) {
                throw ("扫描期间目录身份异常（消失/重解析点/非目录）：{0}。已按 fail-closed 停止。" -f $directory)
            }
            $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($directory))
            foreach ($entry in $entries) {
                $visited++
                if ($visited -gt $MaxEntries) {
                    throw ("目录树条目数超过安全上限 {0}，拒绝继续扫描：{1}。已按 fail-closed 停止。" -f $MaxEntries, $rootPath)
                }
                $entryInfo = Get-T103NativePathInfo -Path $entry -OpenReparsePoint $true
                if (-not $entryInfo.Exists) {
                    throw ("枚举到的条目在检查时不存在（可能被并发删除/替换）：{0}。已按 fail-closed 停止。" -f $entry)
                }
                if ($entryInfo.IsReparsePoint) {
                    [void]$found.Add([pscustomobject]@{
                        path       = $entry
                        reparseTag = ('0x{0:X8}' -f $entryInfo.ReparseTag)
                    })
                    continue
                }
                if ($entryInfo.IsDirectory) {
                    $queue.Enqueue($entry)
                }
            }
        }
    }
    catch {
        throw ("重解析点扫描失败，已按 fail-closed 停止：{0}" -f $_.Exception.Message)
    }
    return @($found)
}

# 逐条目校验后的安全递归删除：每一步都用原生句柄确认目标不是重解析点，
# 绝不跟随 Junction / Symbolic Link 进入外部目录；发现任何异常立即抛错停止。
function Remove-T103VerifiedDirectoryTree {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$StopPrefix = '安全清理',
        # 仅专项测试使用的受控故障注入：在真实条目删除步骤抛出确定性异常，
        # 用于验证“递归删除已开始但未完整结束”的结果语义。
        [scriptblock]$FaultHook = $null
    )
    $normalized = Get-T103UatNormalizedPath $Directory
    $info = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if (-not $info.Exists) {
        return
    }
    if ($info.IsReparsePoint) {
        throw ("{0}：遇到重解析点（tag=0x{1:X8}），拒绝递归进入：{2}" -f $StopPrefix, $info.ReparseTag, $normalized)
    }
    if (-not $info.IsDirectory) {
        throw ("{0}：目标不是目录：{1}" -f $StopPrefix, $normalized)
    }
    $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($normalized))
    foreach ($entry in $entries) {
        if ($null -ne $FaultHook) {
            & $FaultHook 'beforeEntryDelete' $entry
        }
        $entryInfo = Get-T103NativePathInfo -Path $entry -OpenReparsePoint $true
        if (-not $entryInfo.Exists) {
            throw ("{0}：条目在删除前消失或被替换：{1}" -f $StopPrefix, $entry)
        }
        if ($entryInfo.IsReparsePoint) {
            throw ("{0}：发现未预期的重解析点（tag=0x{1:X8}），拒绝递归删除：{2}" -f $StopPrefix, $entryInfo.ReparseTag, $entry)
        }
        if ($entryInfo.IsDirectory) {
            Remove-T103VerifiedDirectoryTree -Directory $entry -StopPrefix $StopPrefix -FaultHook $FaultHook
        }
        else {
            [System.IO.File]::Delete($entry)
        }
    }
    [System.IO.Directory]::Delete($normalized, $false)
}

$script:T103CleanupUnsafePaths = New-Object System.Collections.ArrayList
$script:T103CleanupSteps = New-Object System.Collections.ArrayList

function Stop-T103UnsafeCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Path = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        [void]$script:T103CleanupUnsafePaths.Add($Path)
    }
    throw (New-Object System.Exception(('T103CLEANUP|' + $Code + '|' + $Message)))
}

# 第六轮 F2：先验证全部跟踪链接，再允许任何删除。
# 跟踪链接只允许是“已通过身份复验的沙箱”的直接子项（最小实现：现有调用方均为直接子项；
# 不支持任意嵌套，无法确认安全的嵌套路径一律拒绝）。同时记录链接对象自身的
# 卷序列号 + 文件 ID + reparse tag，删除前必须精确匹配，防止删除被替换的对象。
function Get-T103ValidatedTrackedLinkRecords {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$TrackedLinks
    )
    $sandboxLiteral = Get-T103UatNormalizedPath $SandboxPath
    $records = New-Object System.Collections.ArrayList
    foreach ($link in @($TrackedLinks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $linkPath = Get-T103UatNormalizedPath ([string]$link)
        $parentPath = Split-Path -Parent $linkPath
        if ([string]::IsNullOrWhiteSpace($parentPath) -or (-not (Test-T103UatPathEquals $parentPath $sandboxLiteral))) {
            Stop-T103UnsafeCleanup -Code 'trackedLinkNotDirectChild' -Message ('跟踪链接不是测试沙箱的直接子项，拒绝删除（可能穿过未跟踪 Junction 进入沙箱外）：' + $linkPath) -Path $linkPath
        }
        $info = Get-T103NativePathInfo -Path $linkPath -OpenReparsePoint $true
        if (-not $info.Exists) {
            [void]$records.Add([pscustomobject]@{
                path               = $linkPath
                exists             = $false
                isReparsePoint     = $false
                volumeSerialNumber = ''
                fileIdHex          = ''
                reparseTag         = [uint32]0
            })
            continue
        }
        if (-not $info.IsReparsePoint) {
            Stop-T103UnsafeCleanup -Code 'trackedLinkReplaced' -Message ('跟踪链接已不是重解析点（可能被替换为普通文件/目录），拒绝继续清理：' + $linkPath) -Path $linkPath
        }
        if ([string]::IsNullOrWhiteSpace([string]$info.VolumeSerialNumber) -or [string]::IsNullOrWhiteSpace([string]$info.FileIdHex)) {
            Stop-T103UnsafeCleanup -Code 'trackedLinkIdentityUnconfirmed' -Message ('无法读取跟踪链接的对象身份（卷序列号 / 文件 ID），拒绝删除：' + $linkPath) -Path $linkPath
        }
        [void]$records.Add([pscustomobject]@{
            path               = $linkPath
            exists             = $true
            isReparsePoint     = $true
            volumeSerialNumber = [string]$info.VolumeSerialNumber
            fileIdHex          = [string]$info.FileIdHex
            reparseTag         = [uint32]$info.ReparseTag
        })
    }
    return @($records)
}

# Fail-closed 沙箱清理（第四轮 F2；第六轮按审计要求收紧顺序）：
# 1. 清理前确认沙箱真实身份（与创建时记录一致），并原生校验沙箱到盘符根的父目录链；
# 2. 先验证全部跟踪链接（只允许沙箱直接子项，父目录必须是已确认沙箱；记录对象身份）；
# 3. 删除任何对象之前先扫描整个沙箱：除已登记跟踪链接外出现任何重解析点立即停止；
# 4. 只删除身份精确匹配的已登记跟踪链接，删除后用原生句柄复验确实消失；
# 5. 删除后再次扫描整个沙箱，确认没有残余重解析点；
# 6. 再次复验沙箱身份；
# 7. 只有以上全部通过，才执行逐条目校验的安全递归删除，并区分“未开始 / 已开始未完成 / 已完成”。
# 任一条件不满足：立即停止、不执行整个沙箱递归删除、保留现场、返回可定位失败信息。
function Invoke-T103FailClosedSandboxCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxPath,
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)]$TrustRecord,
        [string[]]$TrackedLinks = @(),
        [scriptblock]$FaultHook = $null
    )
    $script:T103CleanupUnsafePaths = New-Object System.Collections.ArrayList
    $script:T103CleanupSteps = New-Object System.Collections.ArrayList
    $sandboxLiteral = Get-T103UatNormalizedPath $SandboxPath
    $recursiveDeleteStarted = $false
    $recursiveDeleteCompleted = $false
    try {
        # 0) 沙箱必须在测试根目录内（字面 + 信任锚真实最终路径）。
        $testRootLiteral = Get-T103UatNormalizedPath $TestRoot
        if (-not (Test-T103UatPathInside $sandboxLiteral $testRootLiteral)) {
            Stop-T103UnsafeCleanup -Code 'sandboxOutsideTestRoot' -Message ('测试沙箱不在专用测试根目录内：' + $sandboxLiteral) -Path $sandboxLiteral
        }
        $trustedRoot = Get-T103UatTrustedRootRecord
        if ($null -ne $trustedRoot) {
            if (-not (Test-T103FinalPathInside ([string]$TrustRecord.finalPath) ([string]$trustedRoot.finalPath))) {
                Stop-T103UnsafeCleanup -Code 'sandboxFinalPathOutsideTrustedRoot' -Message ('测试沙箱真实最终路径不在信任锚测试根目录内：' + [string]$TrustRecord.finalPath) -Path $sandboxLiteral
            }
        }

        # 1) 清理前确认沙箱真实身份。
        try {
            $currentIdentity = Get-T103DirectoryIdentityRecord -Path $sandboxLiteral -Label '测试沙箱'
            Compare-T103DirectoryIdentity -Expected $TrustRecord -Current $currentIdentity
        }
        catch {
            Stop-T103UnsafeCleanup -Code 'sandboxIdentityChanged' -Message ('清理前无法确认测试沙箱身份：' + $_.Exception.Message) -Path $sandboxLiteral
        }
        [void]$script:T103CleanupSteps.Add('sandbox.identityVerified')

        # 2) 父目录链原生校验：跟踪链接只允许沙箱直接子项；父目录已由第 1 步身份复验确认
        #    为沙箱。沙箱到盘符根任意组件出现 Junction / Symbolic Link / reparse point 时立即停止。
        try {
            $sandboxChain = Get-T103NativePathChain -Path $sandboxLiteral -Label '测试沙箱父目录链'
            if (@($sandboxChain.Missing).Count -gt 0) {
                throw ('测试沙箱路径链包含缺失组件：' + $sandboxLiteral)
            }
        }
        catch {
            Stop-T103UnsafeCleanup -Code 'sandboxParentChainUnsafe' -Message ('测试沙箱父目录链原生校验失败（疑似未跟踪 Junction / 身份不明）：' + $_.Exception.Message) -Path $sandboxLiteral
        }
        [void]$script:T103CleanupSteps.Add('sandbox.parentChainVerified')

        # 3) 先验证全部跟踪链接（不执行任何删除）：只接受沙箱直接子项，并记录链接对象身份。
        $trackedRecords = @(Get-T103ValidatedTrackedLinkRecords -SandboxPath $sandboxLiteral -TrackedLinks @($TrackedLinks))
        [void]$script:T103CleanupSteps.Add('link.allValidated')

        # 4) 删除任何对象之前先扫描整个沙箱：除已登记跟踪链接外，任何重解析点都必须在
        #    删除跟踪链接之前停止（修复前先删链接、后扫描，会穿过未跟踪 Junction 误删外部链接）。
        if ($null -ne $FaultHook) {
            & $FaultHook 'beforeTreeScan' $sandboxLiteral
        }
        $reparsePointsBefore = @(Find-T103ReparsePointsInTree -RootDirectory $sandboxLiteral)
        $trackedPathSet = @($trackedRecords | Where-Object { $_.exists } | ForEach-Object { [string]$_.path })
        $unexpectedBefore = @($reparsePointsBefore | Where-Object { $trackedPathSet -notcontains [string]$_.path })
        if ($unexpectedBefore.Count -gt 0) {
            foreach ($item in $unexpectedBefore) {
                [void]$script:T103CleanupUnsafePaths.Add([string]$item.path)
            }
            Stop-T103UnsafeCleanup -Code 'unexpectedReparsePoint' -Message ('测试沙箱中存在 {0} 个未登记重解析点，已在删除任何跟踪链接之前停止' -f $unexpectedBefore.Count) -Path $sandboxLiteral
        }
        [void]$script:T103CleanupSteps.Add('tree.scannedBeforeLinkDelete')

        # 5) 只删除精确匹配的已登记跟踪链接对象（非递归），删除后用原生句柄复验消失。
        foreach ($record in $trackedRecords) {
            $linkPath = [string]$record.path
            if (-not $record.exists) {
                [void]$script:T103CleanupSteps.Add('link.alreadyAbsent')
                continue
            }
            $beforeInfo = Get-T103NativePathInfo -Path $linkPath -OpenReparsePoint $true
            if (-not $beforeInfo.Exists) {
                [void]$script:T103CleanupSteps.Add('link.alreadyAbsent')
                continue
            }
            if ((-not $beforeInfo.IsReparsePoint) -or
                ([string]$beforeInfo.FileIdHex -ne [string]$record.fileIdHex) -or
                ([string]$beforeInfo.VolumeSerialNumber -ne [string]$record.volumeSerialNumber) -or
                ([uint32]$beforeInfo.ReparseTag -ne [uint32]$record.reparseTag)) {
                Stop-T103UnsafeCleanup -Code 'trackedLinkReplaced' -Message ('跟踪链接在验证后发生变化（不是已登记的对象），拒绝删除：' + $linkPath) -Path $linkPath
            }
            if ($null -ne $FaultHook) {
                try {
                    & $FaultHook 'beforeLinkDelete' $linkPath
                }
                catch {
                    Stop-T103UnsafeCleanup -Code 'trackedLinkDeleteFailed' -Message ('删除跟踪链接失败（受控故障注入模拟操作系统拒绝删除；链接目标不会被递归删除）：' + $linkPath + '；原因：' + $_.Exception.Message) -Path $linkPath
                }
            }
            $deleteFailed = $false
            $deleteMessage = ''
            try {
                [System.IO.Directory]::Delete($linkPath, $false)
            }
            catch {
                $deleteFailed = $true
                $deleteMessage = $_.Exception.Message
                try {
                    Remove-Item -LiteralPath $linkPath -Force -ErrorAction Stop
                    $deleteFailed = $false
                }
                catch {
                    $deleteMessage = $deleteMessage + ' / ' + $_.Exception.Message
                }
            }
            if ($deleteFailed) {
                Stop-T103UnsafeCleanup -Code 'trackedLinkDeleteFailed' -Message ('删除跟踪链接失败（链接目标不会被递归删除）：' + $linkPath + '；原因：' + $deleteMessage) -Path $linkPath
            }
            if ($null -ne $FaultHook) {
                & $FaultHook 'afterLinkDelete' $linkPath
            }
            $afterInfo = Get-T103NativePathInfo -Path $linkPath -OpenReparsePoint $true
            if ($afterInfo.Exists) {
                Stop-T103UnsafeCleanup -Code 'trackedLinkStillExists' -Message ('跟踪链接删除后仍然存在（拒绝执行递归删除）：' + $linkPath) -Path $linkPath
            }
            [void]$script:T103CleanupSteps.Add('link.removed')
        }

        # 6) 删除跟踪链接后再次扫描整个沙箱，确认没有残余重解析点。
        $reparsePointsAfter = @(Find-T103ReparsePointsInTree -RootDirectory $sandboxLiteral)
        if ($reparsePointsAfter.Count -gt 0) {
            foreach ($item in $reparsePointsAfter) {
                [void]$script:T103CleanupUnsafePaths.Add([string]$item.path)
            }
            Stop-T103UnsafeCleanup -Code 'residualReparsePoint' -Message ('删除跟踪链接后测试沙箱中仍有 {0} 个残余重解析点，拒绝执行递归删除' -f $reparsePointsAfter.Count) -Path $sandboxLiteral
        }
        [void]$script:T103CleanupSteps.Add('tree.noResidualReparsePoint')

        # 7) 再次复验沙箱身份（清理过程中可能出现身份变化）。
        try {
            $currentAfterScan = Get-T103DirectoryIdentityRecord -Path $sandboxLiteral -Label '测试沙箱'
            Compare-T103DirectoryIdentity -Expected $TrustRecord -Current $currentAfterScan
        }
        catch {
            Stop-T103UnsafeCleanup -Code 'sandboxIdentityChangedDuringCleanup' -Message ('清理过程中无法确认测试沙箱身份：' + $_.Exception.Message) -Path $sandboxLiteral
        }
        [void]$script:T103CleanupSteps.Add('sandbox.identityReVerified')

        # 8) 全部条件满足：逐条目校验的安全递归删除（绝不跟随重解析点）。
        #    单独记录“已开始 / 已完整结束”，异常时不得把已发生的部分删除描述为完全没有执行。
        if ($null -ne $FaultHook) {
            & $FaultHook 'beforeRecursiveDelete' $sandboxLiteral
        }
        $recursiveDeleteStarted = $true
        [void]$script:T103CleanupSteps.Add('recursiveDelete.started')
        Remove-T103VerifiedDirectoryTree -Directory $sandboxLiteral -StopPrefix '安全清理' -FaultHook $FaultHook
        $recursiveDeleteCompleted = $true
        [void]$script:T103CleanupSteps.Add('recursiveDelete.completed')
        $finalInfo = Get-T103NativePathInfo -Path $sandboxLiteral -OpenReparsePoint $true
        if ($finalInfo.Exists) {
            Stop-T103UnsafeCleanup -Code 'sandboxStillExists' -Message ('安全递归清理后测试沙箱仍然存在：' + $sandboxLiteral) -Path $sandboxLiteral
        }
        return [pscustomobject]@{
            safe                     = $true
            recursiveDeletePerformed = $true
            recursiveDeleteStarted   = $true
            recursiveDeleteCompleted = $true
            recursiveDeletePartial   = $false
            stopCode                 = ''
            stopReason               = ''
            unsafePaths              = @()
            steps                    = @($script:T103CleanupSteps)
            sandboxPath              = $sandboxLiteral
        }
    }
    catch {
        $message = $_.Exception.Message
        $code = 'unexpectedCleanupError'
        $text = $message
        $marker = 'T103CLEANUP|'
        if ($message.StartsWith($marker, [System.StringComparison]::Ordinal)) {
            $parts = $message.Substring($marker.Length).Split([char[]]@('|'), 2)
            $code = $parts[0]
            if ($parts.Length -gt 1) {
                $text = $parts[1]
            }
            else {
                $text = $code
            }
        }
        # 递归删除已开始但未完整结束：可能已经删除了部分测试沙箱内容，必须如实报告。
        $recursiveDeletePartial = [bool]($recursiveDeleteStarted -and (-not $recursiveDeleteCompleted))
        if ($recursiveDeletePartial) {
            if ($code -eq 'unexpectedCleanupError') {
                $code = 'recursiveDeleteFailed'
            }
            $text = ('递归删除已开始但未完整结束（测试沙箱可能已被部分删除，不是完全没有执行）：{0}；原因：{1}' -f $sandboxLiteral, $text)
            [void]$script:T103CleanupUnsafePaths.Add($sandboxLiteral)
        }
        return [pscustomobject]@{
            safe                     = $false
            recursiveDeletePerformed = $false
            recursiveDeleteStarted   = [bool]$recursiveDeleteStarted
            recursiveDeleteCompleted = [bool]$recursiveDeleteCompleted
            recursiveDeletePartial   = $recursiveDeletePartial
            stopCode                 = $code
            stopReason               = $text
            unsafePaths              = @($script:T103CleanupUnsafePaths)
            steps                    = @($script:T103CleanupSteps)
            sandboxPath              = $sandboxLiteral
        }
    }
}

# 读取入口本身与父目录的原生状态（不跟随重解析点，不依赖 Test-Path）。
# Test-Path 对悬空 Junction 之下的路径返回 False，不能用来判断“入口不存在”。
function Get-T103EntryNativeState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = '入口'
    )
    $normalized = Get-T103UatNormalizedPath $Path
    $entry = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    $parentPath = Split-Path -Parent $normalized
    $parent = $null
    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and
        -not (Test-T103FinalPathEquals $parentPath $normalized)) {
        $parent = Get-T103NativePathInfo -Path $parentPath -OpenReparsePoint $true
    }
    return [pscustomobject]@{
        label                = $Label
        path                 = $normalized
        exists               = [bool]$entry.Exists
        isReparsePoint       = [bool]$entry.IsReparsePoint
        reparseTag           = ('0x{0:X8}' -f $entry.ReparseTag)
        isDirectory          = [bool]$entry.IsDirectory
        volumeSerialNumber   = [string]$entry.VolumeSerialNumber
        fileIdHex            = [string]$entry.FileIdHex
        parentPath           = [string]$parentPath
        parentExists         = [bool]($null -ne $parent -and $parent.Exists)
        parentIsReparsePoint = [bool]($null -ne $parent -and $parent.IsReparsePoint)
        parentReparseTag     = $(if ($null -ne $parent) { '0x{0:X8}' -f $parent.ReparseTag } else { '' })
        parentIsDirectory    = [bool]($null -ne $parent -and $parent.IsDirectory)
    }
}

function New-T103CleanupStopResult {
    param(
        [string]$StopCode,
        [string]$StopReason,
        [string[]]$UnsafePaths = @(),
        [string[]]$Steps = @(),
        [string]$SandboxPath = ''
    )
    return [pscustomobject]@{
        safe                     = $false
        recursiveDeletePerformed = $false
        recursiveDeleteStarted   = $false
        recursiveDeleteCompleted = $false
        recursiveDeletePartial   = $false
        stopCode                 = $StopCode
        stopReason               = $StopReason
        unsafePaths              = @($UnsafePaths)
        steps                    = @($Steps)
        sandboxPath              = $SandboxPath
    }
}

# 沙箱清理入口：不再用 Test-Path 判断入口是否存在。先取得入口本身与父目录的原生状态，
# 再用原生路径链检查全部已存在祖先；只有原生检查确认入口确实不存在时，才按原有业务规则
# 视为“已不存在”。入口是 Junction / 悬空 Junction / 父目录是重解析点 / 身份不明 /
# 原生检查失败，一律 fail closed，不执行递归删除。
function Invoke-T103SandboxCleanupEntrypoint {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxPath,
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)]$TrustRecord,
        [string[]]$TrackedLinks = @(),
        [scriptblock]$FaultHook = $null
    )
    try {
        $sandboxLiteral = Get-T103UatNormalizedPath $SandboxPath
        $testRootLiteral = Get-T103UatNormalizedPath $TestRoot
    }
    catch {
        return New-T103CleanupStopResult -StopCode 'sandboxEntryNativeCheckFailed' `
            -StopReason ('沙箱入口路径无法规范化，无法执行原生检查：' + $_.Exception.Message) `
            -UnsafePaths @($SandboxPath) -SandboxPath $SandboxPath
    }
    if (-not (Test-T103UatPathInside $sandboxLiteral $testRootLiteral)) {
        return New-T103CleanupStopResult -StopCode 'sandboxOutsideTestRoot' `
            -StopReason ('测试沙箱不在专用测试根目录内：' + $sandboxLiteral) `
            -UnsafePaths @($sandboxLiteral) -SandboxPath $sandboxLiteral
    }
    $entryState = $null
    try {
        $entryState = Get-T103EntryNativeState -Path $sandboxLiteral -Label '测试沙箱入口'
    }
    catch {
        return New-T103CleanupStopResult -StopCode 'sandboxEntryNativeCheckFailed' `
            -StopReason ('沙箱入口原生路径检查失败：' + $_.Exception.Message) `
            -UnsafePaths @($sandboxLiteral) -SandboxPath $sandboxLiteral
    }
    if ($entryState.exists -and $entryState.isReparsePoint) {
        return New-T103CleanupStopResult -StopCode 'sandboxEntryIsReparsePoint' `
            -StopReason ('沙箱入口本身是重解析点（Junction / Symbolic Link / 悬空链接，tag=' + $entryState.reparseTag + '），无法确认其真实目标：' + $sandboxLiteral) `
            -UnsafePaths @($sandboxLiteral) -SandboxPath $sandboxLiteral
    }
    if ($entryState.exists -and (-not $entryState.isDirectory)) {
        return New-T103CleanupStopResult -StopCode 'sandboxEntryNotDirectory' `
            -StopReason ('沙箱入口已存在但不是目录：' + $sandboxLiteral) `
            -UnsafePaths @($sandboxLiteral) -SandboxPath $sandboxLiteral
    }
    if ($entryState.parentIsReparsePoint) {
        return New-T103CleanupStopResult -StopCode 'sandboxParentIsReparsePoint' `
            -StopReason ('沙箱父目录是重解析点（tag=' + $entryState.parentReparseTag + '），无法确认入口不存在：' + $entryState.parentPath) `
            -UnsafePaths @($entryState.parentPath, $sandboxLiteral) -SandboxPath $sandboxLiteral
    }
    try {
        $chain = Get-T103NativePathChain -Path $sandboxLiteral -Label '测试沙箱入口'
    }
    catch {
        return New-T103CleanupStopResult -StopCode 'sandboxEntryNativeCheckFailed' `
            -StopReason ('沙箱入口原生路径链检查失败（可能是悬空链接或身份不明）：' + $_.Exception.Message) `
            -UnsafePaths @($sandboxLiteral) -SandboxPath $sandboxLiteral
    }
    if (@($chain.Missing).Count -gt 0) {
        return [pscustomobject]@{
            safe                     = $true
            recursiveDeletePerformed = $false
            recursiveDeleteStarted   = $false
            recursiveDeleteCompleted = $false
            recursiveDeletePartial   = $false
            stopCode                 = 'sandboxAlreadyAbsent'
            stopReason               = ''
            unsafePaths              = @()
            steps                    = @('sandbox.entryAbsentConfirmedByNativeCheck')
            sandboxPath              = $sandboxLiteral
        }
    }
    return Invoke-T103FailClosedSandboxCleanup `
        -SandboxPath $sandboxLiteral `
        -TestRoot $TestRoot `
        -TrustRecord $TrustRecord `
        -TrackedLinks $TrackedLinks `
        -FaultHook $FaultHook
}

# 证据文件写入边界（第五轮 F1；第六轮 P2 收紧函数级不变量）：
# 写入前必须用 Windows 原生句柄确认
# 1. 证据目录存在、是真实目录、真实最终路径与字面路径一致（固定身份）；
# 2. 请求路径的每个已存在组件都是普通目录（拒绝 Junction / Symbolic Link / 悬空链接）；
# 3. 请求路径真实最终路径严格位于证据目录内（不是字符串前缀比较）；
# 4. 已存在的目标文件是普通文件且只有 1 个硬链接（防止覆盖数据库/业务文件的硬链接别名）。
# 相对路径按仓库根目录解析；任何身份无法确认的情况 fail closed。
# 第六轮 P2：实际写入（Write-T103EvidenceFile）必须提供启动时记录的证据根目录身份，
# 缺少记录时拒绝写入；目录身份变化时拒绝写入。EvidenceRoot 参数仅供专项测试注入隔离
# 目录使用，不是生产 CLI 参数；测试注入时必须显式传入该隔离目录的身份记录。
function Assert-T103EvidenceWritePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$EvidenceRoot = $script:T103EvidenceRoot,
        # 启动时记录的证据目录身份（卷序列号 + 文件 ID + 真实最终路径）；提供时必须一致。
        [object]$ExpectedRootIdentity = $null,
        # 实际写入时为 true：缺少身份记录必须拒绝，不能跳过身份校验。
        [switch]$RequireRootIdentity
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '证据输出路径不能为空。'
    }
    $trimmed = $Path.Trim()
    if ($trimmed.StartsWith('\\', [System.StringComparison]::Ordinal) -or
        $trimmed.StartsWith('//', [System.StringComparison]::Ordinal) -or
        $trimmed.StartsWith('\', [System.StringComparison]::Ordinal) -or
        $trimmed.StartsWith('/', [System.StringComparison]::Ordinal)) {
        throw ("证据输出路径不能使用 UNC、设备路径（\\?\ / \\.\ / \??\）或根相对路径：{0}。已按 fail-closed 拒绝。" -f $Path)
    }
    if (-not [System.IO.Path]::IsPathRooted($trimmed)) {
        $trimmed = Join-Path $script:T103RepoRoot $trimmed
    }
    $normalized = Get-T103UatNormalizedPath $trimmed
    if (-not ($normalized -match '^[A-Za-z]:\\')) {
        throw ("证据输出路径必须是本地盘符绝对路径（相对路径按仓库根目录解析）：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }
    Assert-T103UatSafePathSegments $normalized

    if ((Test-T103UatPathEquals $normalized $script:T103UatFormalRoot) -or
        (Test-T103UatPathInside $normalized $script:T103UatFormalRoot)) {
        throw ("证据输出路径不得指向正式应用目录：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }

    $rootPath = Get-T103UatNormalizedPath $EvidenceRoot
    $rootChain = Get-T103NativePathChain -Path $rootPath -Label '证据目录'
    if (@($rootChain.Missing).Count -gt 0) {
        throw ("证据目录不存在或路径组件缺失，无法确认其真实身份：{0}。已按 fail-closed 拒绝。" -f $rootPath)
    }
    $rootDriveInfo = @($rootChain.Existing)[0]
    $rootInfo = @($rootChain.Existing)[@($rootChain.Existing).Count - 1]
    if (-not $rootInfo.IsDirectory) {
        throw ("证据目录不是目录：{0}。已按 fail-closed 拒绝。" -f $rootPath)
    }
    Assert-T103NativeVolumeIdentity -ReferenceInfo $rootDriveInfo -CandidateInfo $rootInfo -Context '证据目录'
    $rootFinalPath = Get-T103NativeChainFinalPath $rootChain
    if (-not (Test-T103FinalPathEquals $rootFinalPath $rootPath)) {
        throw ("证据目录的真实最终路径与预期不一致（可能是短名/别名/被替换）：预期={0}，真实={1}。已按 fail-closed 拒绝。" -f $rootPath, $rootFinalPath)
    }
    if ($null -ne $ExpectedRootIdentity) {
        $currentRootIdentity = Get-T103DirectoryIdentityRecord -Path $rootPath -Label '证据目录'
        Compare-T103DirectoryIdentity -Expected $ExpectedRootIdentity -Current $currentRootIdentity
    }
    elseif ($RequireRootIdentity) {
        throw ("证据写入被拒绝：缺少启动时记录的证据根目录身份，无法确认写入位置未被替换：{0}。已按 fail-closed 拒绝。" -f $normalized)
    }

    $chain = Get-T103NativePathChain -Path $normalized -Label '证据输出' -AllowFinalFile
    $missing = @($chain.Missing)
    if ($missing.Count -eq 0) {
        $anchorFinalPath = Get-T103NativeChainFinalPath $chain
        $targetInfo = @($chain.Existing)[@($chain.Existing).Count - 1]
        if ($targetInfo.IsDirectory) {
            throw ("证据输出路径已存在且是目录，不是可写文件：{0}。已按 fail-closed 拒绝。" -f $normalized)
        }
        if ([uint32]$targetInfo.NumberOfLinks -ne 1) {
            throw ("证据输出路径已存在且不是单一硬链接文件（可能是数据库/业务文件的硬链接别名）：{0}。已按 fail-closed 拒绝。" -f $normalized)
        }
    }
    else {
        $anchorFinalPath = (Get-T103NativeChainFinalPath $chain).TrimEnd('\') + '\' + ($missing -join '\')
    }
    if (-not (Test-T103FinalPathInside $anchorFinalPath $rootFinalPath)) {
        throw ("证据输出路径越过证据目录边界：请求={0}，真实={1}，证据目录={2}。已按 fail-closed 拒绝。" -f $normalized, $anchorFinalPath, $rootFinalPath)
    }
    if (-not (Test-T103FinalPathEquals $anchorFinalPath $normalized)) {
        throw ("证据输出路径与 Windows 文件系统解析出的真实路径不一致（可能是短名/别名）：请求={0}，真实={1}。已按 fail-closed 拒绝。" -f $normalized, $anchorFinalPath)
    }
    return $normalized
}

# 证据文件写入（发现的最小 seam）：写之前必须先通过证据目录写入边界校验（第五轮 F1），
# 并且必须提供启动时记录的证据根目录身份（第六轮 P2）。缺少身份记录时拒绝写入。
function Write-T103EvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [string]$EvidenceRoot = $script:T103EvidenceRoot,
        [object]$ExpectedRootIdentity = $null
    )
    $normalized = Assert-T103EvidenceWritePath -Path $Path -EvidenceRoot $EvidenceRoot -ExpectedRootIdentity $ExpectedRootIdentity -RequireRootIdentity
    $evidenceDir = Split-Path -Parent $normalized
    if (-not (Test-Path -LiteralPath $evidenceDir)) {
        New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
    }
    Set-Content -LiteralPath $normalized -Value $Content -Encoding UTF8
    return $normalized
}

# UAT 输出目录内文件写入（第六轮 P3）：verify-t1-03-ui.ps1 最终摘要写入前，
# 重新执行原生路径检查并复验输出目录身份；输出目录被替换为 Junction / Symbolic Link /
# 其他 reparse point 或目录身份变化时拒绝写入；只允许覆盖普通单硬链接文件。
# shortcut: 检查与 Set-Content 之间仍存在并发替换窗口（DEC-029 接受，未消除）。
function Write-T103VerifiedOutputFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)][string]$FormalRoot,
        [Parameter(Mandatory = $true)][object]$ExpectedRootIdentity
    )
    $normalized = Get-T103UatNormalizedPath $Path
    $directory = Split-Path -Parent $normalized
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw ("UAT 输出文件路径没有父目录，拒绝写入：{0}" -f $normalized)
    }
    # 1) 原生路径检查（重解析点 / 真实最终路径 / 卷身份 / 正式目录边界）。
    [void](Assert-T103NativePathSafety -RequestedPath $directory -TestRoot $TestRoot -FormalRoot $FormalRoot)
    # 2) 输出目录身份复验（卷序列号 + 文件 ID + 真实最终路径），防止目录在运行期间被替换。
    $currentIdentity = Get-T103DirectoryIdentityRecord -Path $directory -Label 'UAT 输出目录'
    Compare-T103DirectoryIdentity -Expected $ExpectedRootIdentity -Current $currentIdentity
    # 3) 已存在的目标文件必须是普通单硬链接文件（不得覆盖目录/重解析点/硬链接别名）。
    $targetInfo = Get-T103NativePathInfo -Path $normalized -OpenReparsePoint $true
    if ($targetInfo.Exists) {
        if ($targetInfo.IsReparsePoint -or $targetInfo.IsDirectory) {
            throw ("UAT 输出摘要目标不是普通文件（可能是目录或重解析点），拒绝写入：{0}" -f $normalized)
        }
        if ([uint32]$targetInfo.NumberOfLinks -ne 1) {
            throw ("UAT 输出摘要目标不是单一硬链接文件（可能是业务文件的硬链接别名），拒绝写入：{0}" -f $normalized)
        }
    }
    Set-Content -LiteralPath $normalized -Value $Content -Encoding UTF8
    return $normalized
}

# 受控故障注入（仅专项测试使用，不参与产品路径校验）：由测试传入 FaultHook，在真实
# Junction / Symbolic Link 的删除步骤抛出确定性异常，模拟操作系统拒绝删除链接。
# 清理函数必须把该失败映射为 trackedLinkDeleteFailed 并 fail closed（不递归删除沙箱）；
# 链接、沙箱与外部 Canary 均为真实文件系统对象，测试仍对真实现场做无副作用验证。
