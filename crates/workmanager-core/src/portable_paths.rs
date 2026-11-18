//! 便携路径解析（PortablePaths）。
//!
//! 设计目标（对应 T1-01 / DEC-002 / DEC-003 / TD 8.1-8.3）：
//! - Release：数据根目录始终跟随 EXE 所在目录（`<exe 目录>/data`），整个应用目录移动后自动重新定位。
//! - Debug/Test：只允许通过 `WORKMANAGER_TEST_PORTABLE_ROOT` 指定隔离测试根目录；未设置时 fail-closed。
//! - Release 必须忽略 `WORKMANAGER_TEST_PORTABLE_ROOT`。
//! - 只允许 D 盘本地绝对路径；不得回退到 `%APPDATA%`、`%LOCALAPPDATA%`、系统 Temp 或其他盘。
//! - 路径被文件阻塞、目录不可写、含符号链接或 `..` 时返回清晰错误，绝不静默换位置。
//! - Debug/Test 明确禁止把测试数据写进正式目录 `D:\WorkManager`。
//! - Windows 实机（审计 P1）：已存在的 EXE 目录与数据目录必须用 Win32 句柄解析真实最终路径，
//!   展开 Junction/符号链接/重解析点后仍是 D 盘本地固定盘或可移动盘；拒绝映射网络盘、UNC
//!   与 D→C 的 Junction，并在任何创建目录/写探针之前 fail-closed。
//! - 审计 R2-02：Debug/Test 对正式目录的保护在字符串比较之外，还必须比较**真实最终路径**
//!   （受保护根目录可注入，测试用 D 盘隔离目录模拟正式根），防止同卷 Junction 别名绕过。
//! - 审计 R2-03：真实存储位置必须比较**物理卷身份**（Win32 句柄 `VOLUME_NAME_GUID` /
//!   `VOLUME_NAME_NT`），而不是只比较 DOS 盘符；卷身份与 D 盘根卷不一致（SUBST、卷挂载点、
//!   映射网络盘等）一律 fail-closed。路径校验与后续写入之间仍存在 TOCTOU 残余窗口，
//!   句柄相对写入改造未在本任务完成，详见返工报告。
//! - 审计 R3-01：D 盘根卷作为信任锚必须被独立验证：`GetVolumeNameForVolumeMountPointW`
//!   必须成功且与根目录句柄卷 GUID 一致、`QueryDosDeviceW` 映射必须是真实 NT 设备卷
//!   （拒绝 SUBST 的 `\??\...` 别名）、根卷不得与 C 盘为同一物理卷；任何一步失败
//!   fail-closed 返回 `path-root-trust-anchor-invalid`。
//!
//! 本模块不依赖 Tauri，可被普通 `cargo test` 覆盖。

use std::{
    env, fmt, fs, io,
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[cfg(windows)]
use std::path::Prefix;

use serde::Serialize;

#[cfg(windows)]
use windows_sys::Win32::{
    Foundation::{CloseHandle, ERROR_ACCESS_DENIED, HANDLE, INVALID_HANDLE_VALUE},
    Storage::FileSystem::{
        CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE,
        FILE_SHARE_READ, FILE_SHARE_WRITE, GetDriveTypeW, GetFinalPathNameByHandleW,
        GetVolumeNameForVolumeMountPointW, OPEN_EXISTING, QueryDosDeviceW, VOLUME_NAME_DOS,
        VOLUME_NAME_GUID, VOLUME_NAME_NT,
    },
};

/// Debug/Test 构建用于指定隔离测试数据根目录的环境变量。Release 构建忽略该变量。
pub const TEST_PORTABLE_ROOT_ENV: &str = "WORKMANAGER_TEST_PORTABLE_ROOT";

/// 正式便携版默认根目录。Debug/Test 不得把测试数据写入该目录，避免污染未来正式目录。
pub const FORMAL_RELEASE_ROOT: &str = r"D:\WorkManager";

/// 生产环境的受保护正式目录列表。
///
/// 只有 Debug/Test 构建检查该列表；Release 的 EXE 同级便携路径规则不受影响。
/// 测试通过 [`PortablePaths::resolve_with_protected_roots`] 注入 D 盘隔离目录来模拟
/// 正式根目录，绝不创建、修改或删除真实 `D:\WorkManager`（审计 R2-02）。
fn default_protected_roots() -> Vec<PathBuf> {
    vec![PathBuf::from(FORMAL_RELEASE_ROOT)]
}

/// 数据根目录下的 SQLite 数据库文件（固定为 `data/database/work.db`）。
pub const DATABASE_FILE_NAME: &str = "work.db";

/// 目录可写探针文件名（创建后立即删除，不包含任何业务数据）。
const WRITE_PROBE_FILE_PREFIX: &str = ".workmanager-write-probe";

/// 便携路径错误码；测试与前端用稳定字符串断言，不解析自然语言消息。
pub mod error_codes {
    pub const EXE_PATH_UNAVAILABLE: &str = "exe-path-unavailable";
    pub const PATH_NOT_ABSOLUTE: &str = "path-not-absolute";
    pub const PATH_NOT_DRIVE: &str = "path-not-drive";
    pub const PATH_NOT_LOCAL_DRIVE: &str = "path-not-local-drive";
    pub const PATH_NOT_ON_D_DRIVE: &str = "path-not-on-d-drive";
    pub const PATH_HAS_PARENT_COMPONENT: &str = "path-has-parent-component";
    pub const DEBUG_ROOT_MISSING: &str = "debug-root-missing";
    pub const DEBUG_ROOT_NOT_ABSOLUTE: &str = "debug-root-not-absolute";
    pub const DEBUG_ROOT_IS_FORMAL_RELEASE: &str = "debug-root-is-formal-release";
    pub const PORTABLE_ROOT_MISSING: &str = "portable-root-missing";
    pub const PATH_NOT_DIRECTORY: &str = "path-not-directory";
    pub const DIRECTORY_INSPECT_FAILED: &str = "directory-inspect-failed";
    pub const DIRECTORY_CREATE_FAILED: &str = "directory-create-failed";
    pub const DIRECTORY_NOT_WRITABLE: &str = "directory-not-writable";
    /// 无法用 Win32 句柄解析路径的真实存储位置（路径不存在、权限不足或 API 调用失败）。
    pub const PATH_REAL_LOCATION_UNAVAILABLE: &str = "path-real-location-unavailable";
    /// 真实最终目标不在 D 盘（典型：D 盘上的 Junction/符号链接指向 C 盘）。
    pub const PATH_REAL_TARGET_NOT_D: &str = "path-real-target-not-d";
    /// 真实最终路径不是本地盘符，或所在卷类型不允许（映射网络盘、光驱、内存盘等）。
    pub const PATH_NOT_LOCAL_VOLUME: &str = "path-not-local-volume";
    /// 根卷信任锚验证失败：D 根不是真实卷挂载点、挂载点 GUID 与句柄 GUID 不一致、
    /// DOS 设备映射是 SUBST/别名、或 D 根与 C 根为同一物理卷（审计 R3-01）。
    pub const PATH_ROOT_TRUST_ANCHOR_INVALID: &str = "path-root-trust-anchor-invalid";
}

/// 运行模式。
///
/// 模式由构建类型决定，但解析函数显式接收模式，便于单元测试证明
/// “Release 忽略测试环境变量”而不依赖全局环境变量副作用。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeMode {
    /// 正式 Release 构建：数据目录跟随 EXE。
    Release,
    /// Debug/Test 构建：必须显式提供隔离测试数据根目录。
    DebugTest,
}

impl RuntimeMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Release => "release",
            Self::DebugTest => "debug-test",
        }
    }
}

/// 当前进程的构建模式。
pub fn mode_from_build() -> RuntimeMode {
    if cfg!(debug_assertions) {
        RuntimeMode::DebugTest
    } else {
        RuntimeMode::Release
    }
}

/// 根据运行模式决定是否采用测试环境变量。
///
/// 该函数是纯函数：Release 模式无条件返回 `None`，从而保证 Release 构建
/// 即使环境变量存在也不会改变数据目录。
pub fn select_debug_root(mode: RuntimeMode, raw: Option<std::ffi::OsString>) -> Option<PathBuf> {
    match mode {
        RuntimeMode::Release => None,
        RuntimeMode::DebugTest => raw.filter(|value| !value.is_empty()).map(PathBuf::from),
    }
}

/// 便携路径错误：稳定错误码 + 面向用户的中文消息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PortablePathError {
    pub code: &'static str,
    pub message: String,
}

impl PortablePathError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn code(&self) -> &'static str {
        self.code
    }
}

impl fmt::Display for PortablePathError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for PortablePathError {}

/// 已解析的便携目录布局。
///
/// 所有路径均为绝对路径，且保证位于 D 盘本地目录；本模块不会读取任何业务数据。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortablePaths {
    pub mode: RuntimeMode,
    /// `exe-adjacent-data`（Release）或 `debug-env`（Debug/Test）。
    pub data_source: String,
    pub exe_path: PathBuf,
    pub portable_root: PathBuf,
    pub data_root: PathBuf,
    pub database_dir: PathBuf,
    pub database_file: PathBuf,
    pub config_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub webview2_dir: PathBuf,
    pub temp_dir: PathBuf,
    pub backups_dir: PathBuf,
    /// Debug/Test 必须拒绝写入的受保护正式目录（真实最终路径比较）。
    ///
    /// Release 构建为空；该字段只用于安全校验，不进入前端 DTO，因此序列化时跳过。
    #[serde(skip)]
    protected_roots: Vec<PathBuf>,
}

impl PortablePaths {
    /// 从当前进程的 EXE 路径解析便携目录。生产代码只应调用本函数。
    pub fn resolve_for_current_exe() -> Result<Self, PortablePathError> {
        let exe_path = env::current_exe().map_err(|error| {
            PortablePathError::new(
                error_codes::EXE_PATH_UNAVAILABLE,
                format!(
                    "无法读取当前 EXE 路径：{error}。已停止启动，不会回退到 C 盘、AppData 或系统 Temp。"
                ),
            )
        })?;
        let mode = mode_from_build();
        let debug_root = select_debug_root(mode, env::var_os(TEST_PORTABLE_ROOT_ENV));
        Self::resolve(mode, &exe_path, debug_root.as_deref())
    }

    /// 纯路径解析：不创建目录、不写文件，便于测试各种模式与异常路径。
    pub fn resolve(
        mode: RuntimeMode,
        exe_path: &Path,
        debug_data_root: Option<&Path>,
    ) -> Result<Self, PortablePathError> {
        Self::resolve_with_protected_roots(
            mode,
            exe_path,
            debug_data_root,
            &default_protected_roots(),
        )
    }

    /// 与 [`Self::resolve`] 相同，但显式指定 Debug/Test 的受保护正式目录。
    ///
    /// 生产代码固定使用 [`Self::resolve`]（默认受保护目录为 `D:\WorkManager`）。
    /// 该入口仅用于测试注入 D 盘隔离的模拟正式根目录，以验证“同卷 Junction 别名指向
    /// 受保护目录”会在创建任何目录、写探针、初始化锁和数据库之前被拒绝（审计 R2-02）。
    /// Release 模式忽略该参数，EXE 同级便携路径规则不变。
    pub fn resolve_with_protected_roots(
        mode: RuntimeMode,
        exe_path: &Path,
        debug_data_root: Option<&Path>,
        protected_roots: &[PathBuf],
    ) -> Result<Self, PortablePathError> {
        if !exe_path.is_absolute() {
            return Err(PortablePathError::new(
                error_codes::PATH_NOT_ABSOLUTE,
                format!(
                    "当前 EXE 路径不是绝对路径：{}。已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                    exe_path.display()
                ),
            ));
        }
        ensure_local_d_drive(exe_path, "EXE")?;

        let portable_root = exe_path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .ok_or_else(|| {
                PortablePathError::new(
                    error_codes::PORTABLE_ROOT_MISSING,
                    format!(
                        "无法从 EXE 路径解析所在目录：{}。已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                        exe_path.display()
                    ),
                )
            })?
            .to_path_buf();
        ensure_local_d_drive(&portable_root, "EXE 所在目录")?;

        let (data_root, data_source) = match mode {
            RuntimeMode::Release => (portable_root.join("data"), "exe-adjacent-data"),
            RuntimeMode::DebugTest => {
                let data_root = debug_data_root.ok_or_else(|| {
                    PortablePathError::new(
                        error_codes::DEBUG_ROOT_MISSING,
                        format!(
                            "Debug/Test 模式必须显式设置环境变量 {TEST_PORTABLE_ROOT_ENV} 为 D 盘隔离测试目录；\
                             已停止启动，不会回退到 C 盘、AppData 或系统 Temp。"
                        ),
                    )
                })?;
                if !data_root.is_absolute() {
                    return Err(PortablePathError::new(
                        error_codes::DEBUG_ROOT_NOT_ABSOLUTE,
                        format!(
                            "{TEST_PORTABLE_ROOT_ENV} 不是绝对路径：{}。已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                            data_root.display()
                        ),
                    ));
                }
                ensure_local_d_drive(data_root, TEST_PORTABLE_ROOT_ENV)?;
                ensure_no_parent_components(data_root)?;
                // 审计 R2-02：字符串比较 + 真实最终路径比较（展开 Junction/符号链接后）。
                ensure_not_protected_root(data_root, TEST_PORTABLE_ROOT_ENV, protected_roots)?;
                (data_root.to_path_buf(), "debug-env")
            }
        };

        ensure_no_parent_components(&data_root)?;

        // Windows 实机 fail-closed 校验（审计 P1/R2-03）：
        // 对“已存在”的 EXE 目录与数据根目录，用 Win32 句柄解析真实最终路径（展开 Junction/
        // 符号链接/卷挂载点）并比较**物理卷身份**，确认最终真实目标仍是 D 盘本地固定/可移动卷。
        // 不存在的路径保留纯字符串规则，由 `ensure_directories()` 在创建任何目录之前校验最近
        // 已存在祖先。
        if path_exists_without_follow(&portable_root) {
            validate_real_storage_path(&portable_root, "EXE 所在目录")?;
        }
        if path_exists_without_follow(&data_root) {
            validate_real_storage_path(&data_root, "data 数据根目录")?;
        }

        let database_dir = data_root.join("database");
        let database_file = database_dir.join(DATABASE_FILE_NAME);

        Ok(Self {
            mode,
            data_source: data_source.to_string(),
            exe_path: exe_path.to_path_buf(),
            portable_root,
            data_root: data_root.clone(),
            database_dir,
            database_file,
            config_dir: data_root.join("config"),
            logs_dir: data_root.join("logs"),
            cache_dir: data_root.join("cache"),
            webview2_dir: data_root.join("cache").join("webview2"),
            temp_dir: data_root.join("temp"),
            backups_dir: data_root.join("backups"),
            protected_roots: match mode {
                // 只有 Debug/Test 需要正式目录保护；Release 数据目录本来就在 EXE 旁边。
                RuntimeMode::DebugTest => protected_roots.to_vec(),
                RuntimeMode::Release => Vec::new(),
            },
        })
    }

    /// 需要创建的便携数据子目录（顺序：父目录先于子目录）。
    pub fn data_subdirectories(&self) -> [(&Path, &'static str); 7] {
        [
            (&self.config_dir, "config"),
            (&self.logs_dir, "logs"),
            (&self.cache_dir, "cache"),
            (&self.webview2_dir, "cache/webview2"),
            (&self.temp_dir, "temp"),
            (&self.backups_dir, "backups"),
            (&self.database_dir, "database"),
        ]
    }

    /// 创建完整便携目录布局，并证明数据库、日志、缓存、WebView2、临时和备份目录真实可写。
    ///
    /// WebView2 绝对数据目录必须在创建主窗口之前完成校验，否则 WebView2 可能
    /// 回落到 C 盘默认用户数据目录。
    pub fn ensure_directories(&self) -> Result<(), PortablePathError> {
        if !self.portable_root.is_dir() {
            return Err(PortablePathError::new(
                error_codes::PORTABLE_ROOT_MISSING,
                format!(
                    "便携根目录不存在或不是目录：{}。已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                    self.portable_root.display()
                ),
            ));
        }

        // fail-closed：在任何 create_dir_all / 写探针之前，先确认便携根目录当前的真实存储位置
        // 仍在 D 盘本地卷，并确认 data_root 的最近已存在祖先没有被重解析到其他卷。
        validate_real_storage_path(&self.portable_root, "便携根目录")?;
        // 审计 R2-02：正式目录保护必须在创建任何目录/写探针之前完成（真实最终路径比较）。
        self.validate_protected_write_boundary(&self.data_root, "data 数据根目录")?;
        self.validate_real_storage_for_creation(&self.data_root, "data 数据根目录")?;

        self.ensure_directory(&self.data_root, "data 数据根目录")?;
        for (path, label) in self.data_subdirectories() {
            self.ensure_directory(path, label)?;
        }

        // 创建完成后再用句柄解析一次：防止 data_root / database / cache/webview2 等目录在创建
        // 过程中被并发替换为重解析点而静默写入其他卷（fail-closed，发现异常立即停止启动）。
        validate_real_storage_path(&self.data_root, "data 数据根目录")?;
        self.validate_protected_write_boundary(&self.data_root, "data 数据根目录")?;
        for (path, label) in self.data_subdirectories() {
            validate_real_storage_path(path, label)?;
            self.validate_protected_write_boundary(path, label)?;
        }

        for (path, label) in self.writable_probe_directories() {
            write_writable_probe(path, label)?;
        }

        Ok(())
    }

    /// 写入前置边界复验：数据库目录的真实物理卷必须是 D 盘，且 Debug/Test 数据目录不得
    /// 落在受保护正式目录内。
    ///
    /// 该方法是 `Database::initialize()` 在创建初始化锁文件或正式数据库之前的最后一道
    /// 路径边界检查。它**不能**消除路径校验与实际写入之间的 TOCTOU 竞争窗口（句柄相对
    /// 写入改造尚未完成），只能缩小窗口并保证常见情况 fail-closed。
    pub fn validate_write_boundary(&self) -> Result<(), PortablePathError> {
        self.validate_protected_write_boundary(&self.data_root, "data 数据根目录")?;
        let anchor = nearest_existing_ancestor(&self.database_dir)
            .or_else(|| nearest_existing_ancestor(&self.data_root))
            .ok_or_else(|| {
                PortablePathError::new(
                    error_codes::PATH_REAL_LOCATION_UNAVAILABLE,
                    format!(
                        "无法定位数据库目录的最近已存在祖先：{}。已停止启动，\
                         不会回退到 C 盘、AppData 或系统 Temp。",
                        self.database_dir.display()
                    ),
                )
            })?;
        validate_real_storage_path(&anchor, "database 目录")
    }

    /// 受保护正式目录检查（仅 Debug/Test 生效）：输入字符串 + 真实最终路径双重比较。
    fn validate_protected_write_boundary(
        &self,
        path: &Path,
        label: &str,
    ) -> Result<(), PortablePathError> {
        if self.protected_roots.is_empty() {
            return Ok(());
        }
        ensure_not_protected_root(path, label, &self.protected_roots)
    }

    /// 创建目录之前：校验目标路径“最近已存在祖先”的真实存储位置。
    ///
    /// 例如 `data_root = <portable_root>\data` 时校验 `portable_root`；若 `data_root` 本身
    /// 已存在（可能是 Junction）则校验 `data_root`。该校验发生在任何 `create_dir_all` 之前。
    fn validate_real_storage_for_creation(
        &self,
        path: &Path,
        label: &str,
    ) -> Result<(), PortablePathError> {
        let ancestor = nearest_existing_ancestor(path).ok_or_else(|| {
            PortablePathError::new(
                error_codes::PATH_REAL_LOCATION_UNAVAILABLE,
                format!(
                    "无法定位 {label} 的最近已存在祖先目录：{}。已停止启动，\
                     不会回退到 C 盘、AppData 或系统 Temp。",
                    path.display()
                ),
            )
        })?;
        validate_real_storage_path(&ancestor, label)
    }

    /// 必须通过可写探针验证的目录：数据库、日志、缓存/WebView2、临时和备份。
    fn writable_probe_directories(&self) -> [(&Path, &'static str); 6] {
        [
            (&self.database_dir, "database"),
            (&self.logs_dir, "logs"),
            (&self.cache_dir, "cache"),
            (&self.webview2_dir, "cache/webview2"),
            (&self.temp_dir, "temp"),
            (&self.backups_dir, "backups"),
        ]
    }

    fn ensure_directory(&self, path: &Path, label: &str) -> Result<(), PortablePathError> {
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                if metadata.is_dir() {
                    Ok(())
                } else {
                    Err(PortablePathError::new(
                        error_codes::PATH_NOT_DIRECTORY,
                        format!(
                            "{label} 路径已存在但不是普通目录（可能是文件或符号链接）：{}。\
                             已停止启动，不会删除或覆盖该路径，也不会回退到 C 盘、AppData 或系统 Temp。",
                            path.display()
                        ),
                    ))
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir_all(path)
                .map_err(|error| {
                    PortablePathError::new(
                        error_codes::DIRECTORY_CREATE_FAILED,
                        format!(
                            "创建 {label} 目录失败：{}；系统错误：{error}。\
                             已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                            path.display()
                        ),
                    )
                }),
            Err(error) => Err(PortablePathError::new(
                error_codes::DIRECTORY_INSPECT_FAILED,
                format!(
                    "检查 {label} 目录失败：{}；系统错误：{error}。已停止启动。",
                    path.display()
                ),
            )),
        }
    }

    pub fn database_file(&self) -> &Path {
        &self.database_file
    }

    pub fn is_debug_test(&self) -> bool {
        self.mode == RuntimeMode::DebugTest
    }
}

/// 只允许 D 盘本地绝对路径。
fn ensure_local_d_drive(path: &Path, label: &str) -> Result<(), PortablePathError> {
    if !path.is_absolute() {
        return Err(PortablePathError::new(
            error_codes::PATH_NOT_ABSOLUTE,
            format!(
                "{label} 必须是绝对路径：{}。已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                path.display()
            ),
        ));
    }

    let drive = match path.components().next() {
        Some(Component::Prefix(prefix)) => prefix.kind(),
        _ => {
            return Err(PortablePathError::new(
                error_codes::PATH_NOT_DRIVE,
                format!(
                    "{label} 必须是带盘符的 Windows 本地路径：{}。WorkManager 只允许 D 盘。",
                    path.display()
                ),
            ));
        }
    };

    match drive {
        std::path::Prefix::Disk(letter) if letter == b'D' || letter == b'd' => Ok(()),
        std::path::Prefix::Disk(letter) => Err(PortablePathError::new(
            error_codes::PATH_NOT_ON_D_DRIVE,
            format!(
                "{label} 不在 D 盘（当前盘符 {}）：{}。WorkManager 只允许 D 盘；\
                 已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                char::from(letter),
                path.display()
            ),
        )),
        _ => Err(PortablePathError::new(
            error_codes::PATH_NOT_LOCAL_DRIVE,
            format!(
                "{label} 不是 Windows 本地盘符路径：{}。WorkManager 只允许 D 盘；\
                 已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                path.display()
            ),
        )),
    }
}

fn ensure_no_parent_components(path: &Path) -> Result<(), PortablePathError> {
    if path
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(PortablePathError::new(
            error_codes::PATH_HAS_PARENT_COMPONENT,
            format!(
                "路径包含 `..`，拒绝使用：{}。已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                path.display()
            ),
        ));
    }
    Ok(())
}

/// Windows 路径比较：大小写不敏感，统一分隔符。
fn is_same_or_child(path: &Path, parent: &Path) -> bool {
    let normalize = |value: &Path| {
        value
            .to_string_lossy()
            .replace('/', "\\")
            .trim_end_matches('\\')
            .to_lowercase()
    };
    let path = normalize(path);
    let parent = normalize(parent);
    path == parent || path.starts_with(&format!("{parent}\\"))
}

/// 判断路径是否命中受保护正式目录：输入字符串 + 真实最终路径双重比较。
///
/// 审计 R2-02：只比较输入字符串会被同卷 Junction 别名绕过（例如
/// `D:\WorkManager-test-data\alias` → `D:\WorkManager`）。因此先做规范化字符串比较
/// （覆盖受保护目录尚不存在的情况），再用 Win32 句柄解析真实最终路径（展开完整祖先链）
/// 后比较；受保护根目录若存在，也按其真实最终路径比较。调用点必须早于任何目录创建、
/// 写探针、初始化锁和数据库写入。
fn ensure_not_protected_root(
    path: &Path,
    label: &str,
    protected_roots: &[PathBuf],
) -> Result<(), PortablePathError> {
    for root in protected_roots {
        if is_same_or_child(path, root) {
            return Err(protected_root_error(path, root, "输入路径", label));
        }
    }

    #[cfg(windows)]
    {
        // 路径本身已存在（可能是 Junction）则解析自身；否则解析最近已存在祖先，保证
        // “即将在受保护目录内部创建新目录”同样会被拒绝。
        let anchor = if path_exists_without_follow(path) {
            path.to_path_buf()
        } else {
            nearest_existing_ancestor(path).ok_or_else(|| {
                PortablePathError::new(
                    error_codes::PATH_REAL_LOCATION_UNAVAILABLE,
                    format!(
                        "无法定位 {label} 的最近已存在祖先目录：{}。已停止启动，\
                         不会回退到 C 盘、AppData 或系统 Temp。",
                        path.display()
                    ),
                )
            })?
        };
        let real_anchor = resolve_real_final_path(&anchor)?;
        for root in protected_roots {
            if !path_exists_without_follow(root) {
                // 受保护目录当前不存在：真实最终路径不可能与它指向同一目录对象。
                // 输入字符串命中（如 D:\WorkManager\data）已在上面的字符串比较中拒绝。
                continue;
            }
            let real_root = resolve_real_final_path(root).map_err(|_| {
                PortablePathError::new(
                    error_codes::PATH_REAL_LOCATION_UNAVAILABLE,
                    format!(
                        "受保护正式目录存在但无法解析真实最终路径：{}。\
                         已停止启动，不会创建或写入任何数据。",
                        root.display()
                    ),
                )
            })?;
            if is_same_or_child_final(&real_anchor, &real_root) {
                return Err(protected_root_error(
                    &anchor,
                    root,
                    "真实最终路径（Junction/符号链接解析后）",
                    label,
                ));
            }
        }
    }

    let _ = (path, label);
    Ok(())
}

fn protected_root_error(
    path: &Path,
    protected_root: &Path,
    check_stage: &str,
    label: &str,
) -> PortablePathError {
    PortablePathError::new(
        error_codes::DEBUG_ROOT_IS_FORMAL_RELEASE,
        format!(
            "拒绝把 Debug/Test {label} 指向正式便携目录（{check_stage} 检查命中）：{}；\
             受保护目录：{}。该路径可能通过 Junction/符号链接等别名指向正式运行数据；\
             已停止启动，未创建任何目录、写探针、初始化锁或数据库。请改用独立的 D 盘测试目录。",
            path.display(),
            protected_root.display()
        ),
    )
}

/// 比较两个由 `GetFinalPathNameByHandleW` 返回的真实最终路径：大小写不敏感、统一
/// 分隔符，并去掉 `\\?\` / `\??\` 前缀。
#[cfg(windows)]
fn is_same_or_child_final(path: &Path, parent: &Path) -> bool {
    let normalize = |value: &Path| {
        let text = value.to_string_lossy().replace('/', "\\");
        let text = text
            .strip_prefix(r"\\?\")
            .or_else(|| text.strip_prefix(r"\??\"))
            .unwrap_or(&text)
            .to_string();
        text.trim_end_matches('\\').to_lowercase()
    };
    let path = normalize(path);
    let parent = normalize(parent);
    path == parent || path.starts_with(&format!("{parent}\\"))
}

// ---------------------------------------------------------------------------
// Windows 真实存储位置校验（T1-01 独立审计 P1 返工）
//
// 仅用字符串判断盘符不足以证明数据真的落在 D 盘：D 盘上的 Junction/符号链接可以把路径
// 重解析到 C 盘、映射网络盘或其他卷。这里用 Win32 句柄解析真实最终目标，再校验卷类型，
// 并在任何创建目录/写文件之前 fail-closed。
// ---------------------------------------------------------------------------

/// 路径自身是否存在（不跟随最后一级重解析点；Junction/符号链接本身也算存在）。
fn path_exists_without_follow(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

/// 返回 `path` 自身或最深的已存在祖先（逐级向上，不跟随最后一级重解析点）。
///
/// 用于在创建目录之前校验“当前真实可落脚的位置”：只要最近已存在祖先被重解析到其他卷，
/// 就拒绝创建任何目录，避免先写入再报错。
fn nearest_existing_ancestor(path: &Path) -> Option<PathBuf> {
    let mut candidate = path.to_path_buf();
    loop {
        match fs::symlink_metadata(&candidate) {
            Ok(_) => return Some(candidate),
            Err(error) if error.kind() == io::ErrorKind::NotFound => match candidate.parent() {
                Some(parent) if !parent.as_os_str().is_empty() => {
                    candidate = parent.to_path_buf();
                }
                _ => return None,
            },
            Err(_) => return None,
        }
    }
}

/// Win32 句柄的 RAII 包装：无论函数正常返回、返回错误还是 panic，都会 `CloseHandle`。
#[cfg(windows)]
struct HandleGuard(HANDLE);

#[cfg(windows)]
impl Drop for HandleGuard {
    fn drop(&mut self) {
        // SAFETY: 句柄来自成功的 CreateFileW 调用，只会在此处关闭一次。
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

/// 把 Windows 路径转换为以 NUL 结尾的 UTF-16（宽字符）缓冲区。
#[cfg(windows)]
fn to_wide_null(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

/// 无法解析真实存储位置时的统一错误（fail-closed，绝不回退到其他目录）。
#[cfg(windows)]
fn real_location_unavailable(path: &Path, detail: impl fmt::Display) -> PortablePathError {
    PortablePathError::new(
        error_codes::PATH_REAL_LOCATION_UNAVAILABLE,
        format!(
            "无法解析路径的真实存储位置（Windows API 调用失败或结果异常）：{}；详情：{detail}。\
             已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
            path.display()
        ),
    )
}

/// 打开路径句柄失败时的错误映射。
///
/// “拒绝访问”说明权限不足、目录不可检查，保持既有 `directory-inspect-failed` 错误码语义
/// （目录不可写/不可访问仍会由后续写探针以 `directory-not-writable` 暴露），避免把权限
/// 问题误报成“真实路径不可解析”而覆盖既有行为；其余错误一律 fail-closed 为
/// `path-real-location-unavailable`。
#[cfg(windows)]
fn handle_open_failed(path: &Path, error: &io::Error) -> PortablePathError {
    if error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) {
        return PortablePathError::new(
            error_codes::DIRECTORY_INSPECT_FAILED,
            format!(
                "检查路径的真实存储位置失败（拒绝访问）：{}；系统错误：{error}。\
                 已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                path.display()
            ),
        );
    }
    real_location_unavailable(path, error)
}

/// 打开已存在路径的句柄。
///
/// 目录必须带 `FILE_FLAG_BACKUP_SEMANTICS`，并共享读/写/删除，避免因为其他进程正在使用
/// 同一目录而无法完成路径校验。访问权限只请求 `FILE_READ_ATTRIBUTES`
/// （`GetFinalPathNameByHandleW` 的要求）：若像 `GENERIC_READ` 那样附带请求 `SYNCHRONIZE`，
/// 一个“拒绝写入”的 ACL 会连带拒绝 `SYNCHRONIZE`，导致真实路径校验先于写探针报错，
/// 掩盖真正的“目录不可写”错误码。
#[cfg(windows)]
fn open_path_handle(path: &Path) -> Result<HandleGuard, PortablePathError> {
    let wide_path = to_wide_null(path);
    // SAFETY: wide_path 以 NUL 结尾且在本函数内保持存活；失败时 last_os_error 立即读取。
    let raw_handle = unsafe {
        CreateFileW(
            wide_path.as_ptr(),
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            std::ptr::null_mut(),
        )
    };
    if raw_handle.is_null() || raw_handle == INVALID_HANDLE_VALUE {
        return Err(handle_open_failed(path, &io::Error::last_os_error()));
    }
    Ok(HandleGuard(raw_handle))
}

/// 调用 `GetFinalPathNameByHandleW` 并正确处理缓冲区不足的二次调用。
///
/// 返回语义：
/// - 0：失败（错误码用 `GetLastError` 读取）；
/// - 小于缓冲区长度：成功，返回不含结尾 NUL 的字符数；
/// - 大于等于缓冲区长度：缓冲区不足，返回所需长度（含结尾 NUL），扩容后二次调用。
#[cfg(windows)]
fn get_final_path_by_flags(
    handle: HANDLE,
    path: &Path,
    flags: u32,
) -> Result<PathBuf, PortablePathError> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;

    let mut buffer = vec![0u16; 512];
    loop {
        // SAFETY: handle 有效；buffer 可写且长度与传入的 cchfilepath 一致。
        let written = unsafe {
            GetFinalPathNameByHandleW(handle, buffer.as_mut_ptr(), buffer.len() as u32, flags)
        };
        if written == 0 {
            return Err(real_location_unavailable(
                path,
                format!(
                    "GetFinalPathNameByHandleW(flags={flags}) 失败：{}",
                    io::Error::last_os_error()
                ),
            ));
        }
        let written = written as usize;
        if written < buffer.len() {
            buffer.truncate(written);
            break;
        }
        buffer = vec![0u16; written + 1];
    }

    let real_path = PathBuf::from(OsString::from_wide(&buffer));
    if real_path.as_os_str().is_empty() {
        return Err(real_location_unavailable(
            path,
            format!("GetFinalPathNameByHandleW(flags={flags}) 返回空路径"),
        ));
    }
    Ok(real_path)
}

/// 用 Win32 句柄解析路径的真实最终 DOS 存储路径（展开 Junction/符号链接/卷挂载点）。
///
/// 使用 `GetFinalPathNameByHandleW(VOLUME_NAME_DOS)` 取得形如 `\\?\D:\...` 的最终路径。
/// 句柄解析会跟随完整祖先链上的重解析点，因此能识别“EXE 目录本身正常，但某个祖先目录是
/// D→C Junction”的情况；不使用 `std::fs::canonicalize` 做单点判断。
#[cfg(windows)]
fn resolve_real_final_path(path: &Path) -> Result<PathBuf, PortablePathError> {
    let handle = open_path_handle(path)?;
    let real_path = get_final_path_by_flags(handle.0, path, VOLUME_NAME_DOS)?;
    if !real_path.is_absolute() {
        return Err(real_location_unavailable(
            path,
            format!("真实最终路径不是绝对路径：{}", real_path.display()),
        ));
    }
    Ok(real_path)
}

// ---------------------------------------------------------------------------
// 审计 R2-03 / R3-01：真实物理卷身份校验与根卷信任锚
//
// 只比较最终 DOS 盘符仍可能被别名欺骗（SUBST 驱动器、目录卷挂载点等）。这里用同一
// Win32 句柄查询 `VOLUME_NAME_GUID` 与 `VOLUME_NAME_NT`，取得目标对象实际所在物理卷的
// 身份，再与 D 盘根卷身份比较；D 盘根卷自身还必须先通过独立信任锚验证（见下文 R3-01）。
//
// 评估/使用的 API：
// - `GetFinalPathNameByHandleW(VOLUME_NAME_GUID)`：返回句柄背后对象的卷 GUID，由对象
//   管理器解析 Junction/SUBST/挂载点别名，是物理卷身份主证据；
// - `GetFinalPathNameByHandleW(VOLUME_NAME_NT)`：返回 `\Device\HarddiskVolumeN`，
//   作为备用/交叉校验；
// - `GetVolumeNameForVolumeMountPointW`：生产信任锚校验使用。只有真实卷挂载点才成功；
//   SUBST 盘符失败，可作为“D: 是真实卷挂载点”的独立证据；
// - `QueryDosDeviceW`：生产信任锚校验使用。真实卷返回 `\Device\HarddiskVolumeN`；
//   SUBST 返回 `\??\C:\...` DOS 路径别名，必须拒绝；
// - `GetVolumePathNameW`：返回路径所在挂载点（盘符根或挂载点目录），不提供物理卷身份，
//   已评估但不作为主校验。
// ---------------------------------------------------------------------------

/// 物理卷身份：卷 GUID 分量与 NT 设备卷分量（任一可用即可比较）。
#[cfg(windows)]
#[derive(Debug, Clone, PartialEq, Eq)]
struct VolumeIdentity {
    volume_guid: Option<String>,
    nt_device: Option<String>,
}

#[cfg(windows)]
impl VolumeIdentity {
    fn is_empty(&self) -> bool {
        self.volume_guid.is_none() && self.nt_device.is_none()
    }
}

/// 从 `\\?\Volume{GUID}\...` 中提取卷 GUID 分量（小写）。
#[cfg(windows)]
fn volume_guid_component(path: &Path) -> Option<String> {
    let text = path.to_string_lossy().replace('/', "\\").to_lowercase();
    let rest = text.strip_prefix(r"\\?\volume{")?;
    let end = rest.find('}')?;
    Some(format!(r"\\?\volume{{{}}}", &rest[..end]))
}

/// 从 `\Device\HarddiskVolumeN\...` 中提取 NT 设备卷分量（小写）。
#[cfg(windows)]
fn nt_device_component(path: &Path) -> Option<String> {
    let text = path.to_string_lossy().replace('/', "\\").to_lowercase();
    let rest = text.strip_prefix(r"\device\")?;
    let device = rest.split('\\').next()?;
    if device.is_empty() {
        return None;
    }
    Some(format!(r"\device\{device}"))
}

/// 查询某个已打开句柄背后对象的物理卷身份。
#[cfg(windows)]
fn volume_identity_for_handle(
    handle: HANDLE,
    path: &Path,
) -> Result<VolumeIdentity, PortablePathError> {
    let volume_guid = get_final_path_by_flags(handle, path, VOLUME_NAME_GUID)
        .ok()
        .and_then(|final_path| volume_guid_component(&final_path));
    let nt_device = get_final_path_by_flags(handle, path, VOLUME_NAME_NT)
        .ok()
        .and_then(|final_path| nt_device_component(&final_path));
    let identity = VolumeIdentity {
        volume_guid,
        nt_device,
    };
    if identity.is_empty() {
        return Err(real_location_unavailable(
            path,
            "无法取得卷 GUID 或 NT 设备卷身份（可能是 UNC/网络路径或 Windows API 不支持）",
        ));
    }
    Ok(identity)
}

/// 查询已存在路径的物理卷身份。
#[cfg(windows)]
fn volume_identity_for_path(path: &Path) -> Result<VolumeIdentity, PortablePathError> {
    let handle = open_path_handle(path)?;
    volume_identity_for_handle(handle.0, path)
}

// ---------------------------------------------------------------------------
// 审计 R3-01：根卷信任锚（默认 D:\）独立验证
//
// R2-03 只证明“目标目录与当前 D:\ 根目录句柄指向同一卷”，但参考卷身份本身没有被
// 独立验证：如果 D: 是 SUBST 之类的 DOS 设备别名，这个参考锚点就不可信。本节新增生产
// 校验，独立证明 D:\ 是真实的本地卷挂载点、且与 C 盘不是同一物理卷：
// 1. GetVolumeNameForVolumeMountPointW("D:\\") 必须成功返回卷 GUID（SUBST 会失败）；
// 2. D:\ 根目录句柄的 VOLUME_NAME_GUID 必须与挂载点 GUID 一致；
// 3. QueryDosDeviceW("D:") 的映射目标必须是 \Device\HarddiskVolumeN 形式的 NT 设备卷，
//    且与根目录句柄的 VOLUME_NAME_NT 一致（SUBST 返回 \??\C:\... 的 DOS 路径，拒绝）；
// 4. D 根卷 GUID 不得与 C 根卷 GUID 相同（产品要求 D 盘独立于 C 盘存储）；
// 5. 保留根卷类型白名单（GetDriveTypeW 固定盘/可移动盘）。
//
// 这些函数同时供测试注入候选根（例如真实 SUBST Q:）验证拒绝逻辑，避免“测试通过但
// 生产未使用”。任何一步失败都返回 `path-root-trust-anchor-invalid` 并 fail-closed。
// ---------------------------------------------------------------------------

/// 根卷信任锚失败：统一错误码，消息包含失败原因与根路径。
#[cfg(windows)]
fn trust_anchor_error(root: &Path, detail: impl fmt::Display) -> PortablePathError {
    PortablePathError::new(
        error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID,
        format!(
            "根卷信任锚验证失败：{detail}；根路径：{}。\
             无法证明该盘符是独立的本地 D 盘卷，已停止启动，\
             不会回退到 C 盘、AppData 或系统 Temp。",
            root.display()
        ),
    )
}

/// 生产函数：把盘符根或卷挂载点目录转换为卷 GUID 路径（`\\?\Volume{GUID}`）。
///
/// `GetVolumeNameForVolumeMountPointW` 只对真实的卷挂载点成功；SUBST 等 DOS 设备别名
/// 会失败（实测 `ERROR_INVALID_PARAMETER`），因此可直接作为“D: 是真实卷挂载点”的
/// 独立证据（审计 R3-01）。
#[cfg(windows)]
fn volume_mount_point_guid(mount_point: &Path) -> Result<String, PortablePathError> {
    let wide = to_wide_null(mount_point);
    let mut buffer = vec![0u16; 1024];
    // SAFETY: wide 以 NUL 结尾；buffer 可写且长度与传入值一致。
    let ok = unsafe {
        GetVolumeNameForVolumeMountPointW(wide.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32)
    };
    if ok == 0 {
        return Err(trust_anchor_error(
            mount_point,
            format!(
                "GetVolumeNameForVolumeMountPointW 失败（系统错误：{}），该路径不是真实的卷挂载点",
                io::Error::last_os_error()
            ),
        ));
    }
    let length = buffer
        .iter()
        .position(|&value| value == 0)
        .unwrap_or(buffer.len());
    let text = String::from_utf16_lossy(&buffer[..length]);
    volume_guid_component(Path::new(&text)).ok_or_else(|| {
        trust_anchor_error(
            mount_point,
            format!("卷挂载点 API 返回的卷名不是卷 GUID 路径：{text}"),
        )
    })
}

/// 生产函数：把 MS-DOS 设备名（如 `D:`）翻译为 NT 目标路径。
///
/// 真实卷挂载点返回 `\Device\HarddiskVolumeN`；SUBST 返回 `\??\C:\...` 形式的 DOS
/// 路径别名（审计 R3-01）。
#[cfg(windows)]
fn query_dos_device_target(device: &str) -> Result<String, PortablePathError> {
    let wide = to_wide_null(Path::new(device));
    let mut buffer = vec![0u16; 4096];
    // SAFETY: wide 以 NUL 结尾；buffer 可写且长度与传入值一致。
    let length =
        unsafe { QueryDosDeviceW(wide.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32) };
    if length == 0 {
        return Err(trust_anchor_error(
            Path::new(device),
            format!(
                "QueryDosDeviceW 失败（系统错误：{}）",
                io::Error::last_os_error()
            ),
        ));
    }
    // 返回值是 NUL 分隔的多字符串列表；取第一个目标即可。
    let text = String::from_utf16_lossy(&buffer[..length as usize]);
    text.split('\0')
        .find(|segment| !segment.is_empty())
        .map(str::to_string)
        .ok_or_else(|| trust_anchor_error(Path::new(device), "QueryDosDeviceW 返回空映射"))
}

/// 纯校验：根卷挂载点 GUID 必须与根目录句柄的 `VOLUME_NAME_GUID` 一致。
#[cfg(windows)]
fn ensure_mount_point_guid_matches_handle(
    mount_point_guid: &str,
    identity: &VolumeIdentity,
    root: &Path,
) -> Result<(), PortablePathError> {
    let handle_guid = identity
        .volume_guid
        .as_deref()
        .ok_or_else(|| trust_anchor_error(root, "无法从根目录句柄取得 VOLUME_NAME_GUID 卷身份"))?;
    if !mount_point_guid.eq_ignore_ascii_case(handle_guid) {
        return Err(trust_anchor_error(
            root,
            format!(
                "卷挂载点 GUID（{mount_point_guid}）与根目录句柄 GUID（{handle_guid}）不一致，\
                 根卷身份存在歧义"
            ),
        ));
    }
    Ok(())
}

/// 纯校验：`QueryDosDeviceW` 的映射目标必须是 NT 设备卷路径，且与根目录句柄的
/// `VOLUME_NAME_NT` 设备卷身份一致。
///
/// SUBST 的映射目标形如 `\??\C:\...`（DOS 路径别名），不是独立设备卷，必须拒绝。
#[cfg(windows)]
fn ensure_dos_device_maps_to_volume(
    device_target: &str,
    identity: &VolumeIdentity,
    root: &Path,
) -> Result<(), PortablePathError> {
    let Some(mapped_device) = nt_device_component(Path::new(device_target)) else {
        return Err(trust_anchor_error(
            root,
            format!(
                "DOS 设备映射目标不是 NT 设备卷路径（可能是 SUBST/DOS 设备别名）：{device_target}"
            ),
        ));
    };
    let expected_device = identity.nt_device.as_deref().ok_or_else(|| {
        trust_anchor_error(root, "无法从根目录句柄取得 VOLUME_NAME_NT 设备卷身份")
    })?;
    if mapped_device != expected_device {
        return Err(trust_anchor_error(
            root,
            format!(
                "DOS 设备映射目标（{mapped_device}）与根目录句柄设备卷身份（{expected_device}）不一致"
            ),
        ));
    }
    Ok(())
}

/// 纯校验：根卷不得与 C 盘根卷是同一物理卷（D 盘必须独立于 C 盘存储）。
#[cfg(windows)]
fn ensure_root_volume_differs_from_c(
    root_mount_point_guid: &str,
    c_mount_point_guid: &str,
    root: &Path,
) -> Result<(), PortablePathError> {
    if root_mount_point_guid.eq_ignore_ascii_case(c_mount_point_guid) {
        return Err(trust_anchor_error(
            root,
            format!(
                "根卷与 C 盘根卷是同一物理卷（卷 GUID：{root_mount_point_guid}），\
                 不满足数据必须位于独立 D 盘卷的要求"
            ),
        ));
    }
    Ok(())
}

/// 独立验证候选根卷（生产默认 `D:\`）是否是可信的真实本地卷挂载点。
///
/// 成功时返回根目录句柄的物理卷身份，供目标路径卷身份比较使用。
/// 该函数接收可注入的根路径：生产固定传 `D:\`，测试可用真实 SUBST 盘符等候选根验证
/// 拒绝逻辑（审计 R3-01）。
#[cfg(windows)]
fn verify_root_volume_trust(root: &Path) -> Result<VolumeIdentity, PortablePathError> {
    if !root.is_absolute() {
        return Err(trust_anchor_error(root, "根路径不是绝对路径"));
    }
    let Some(drive_letter) = drive_letter_of_local_path(root) else {
        return Err(trust_anchor_error(root, "根路径不是本地盘符路径"));
    };
    // 信任锚必须是盘符根目录（例如 `D:\`），不接受任意子目录。
    let mut components = root.components();
    let is_drive_root = matches!(components.next(), Some(Component::Prefix(_)))
        && matches!(components.next(), Some(Component::RootDir))
        && components.next().is_none();
    if !is_drive_root {
        return Err(trust_anchor_error(
            root,
            "信任锚路径必须是盘符根目录（例如 D:\\）",
        ));
    }

    // 1) 保留原有卷类型白名单：必须是本地固定盘或可移动盘。
    let drive_type = query_drive_type(drive_letter);
    if !is_allowed_volume_type(drive_type) {
        return Err(trust_anchor_error(
            root,
            format!(
                "根卷类型不在白名单（GetDriveTypeW={drive_type}；DRIVE_REMOTE=4 表示映射网络盘）"
            ),
        ));
    }

    // 2) 独立卷挂载点 GUID：SUBST/DOS 设备别名会在此失败。
    let mount_point_guid = volume_mount_point_guid(root)?;

    // 3) 根目录句柄身份必须与挂载点 GUID 一致。
    let identity = volume_identity_for_path(root)
        .map_err(|error| trust_anchor_error(root, format!("无法解析根目录句柄卷身份：{error}")))?;
    ensure_mount_point_guid_matches_handle(&mount_point_guid, &identity, root)?;

    // 4) DOS 设备映射必须是真实 NT 设备卷，而不是 SUBST 的 `\??\...` 路径别名。
    let device_name = format!("{drive_letter}:");
    let device_target = query_dos_device_target(&device_name)?;
    ensure_dos_device_maps_to_volume(&device_target, &identity, root)?;

    // 5) 根卷不得与 C 盘根卷是同一物理卷。
    let c_mount_point_guid = volume_mount_point_guid(Path::new(r"C:\")).map_err(|error| {
        trust_anchor_error(
            root,
            format!("无法解析 C 盘根卷身份，不能证明根卷独立于 C 盘：{error}"),
        )
    })?;
    ensure_root_volume_differs_from_c(&mount_point_guid, &c_mount_point_guid, root)?;

    Ok(identity)
}

/// `D:\` 根目录的物理卷身份：必须通过独立的根卷信任锚验证（审计 R3-01）。
#[cfg(windows)]
fn d_drive_volume_identity() -> Result<VolumeIdentity, PortablePathError> {
    verify_root_volume_trust(Path::new(r"D:\"))
}

/// 两个物理卷身份是否指向同一卷：优先比较卷 GUID；GUID 不可用时退回 NT 设备卷比较。
#[cfg(windows)]
fn volume_identities_match(left: &VolumeIdentity, right: &VolumeIdentity) -> bool {
    if let (Some(left_guid), Some(right_guid)) = (&left.volume_guid, &right.volume_guid) {
        return left_guid == right_guid;
    }
    if let (Some(left_device), Some(right_device)) = (&left.nt_device, &right.nt_device) {
        return left_device == right_device;
    }
    false
}

/// 要求目标路径所在物理卷与 D 盘根卷一致（审计 R2-03 + R3-01）。
///
/// D 盘根卷身份来自 [`verify_root_volume_trust`]：在生产路径上必须通过独立信任锚验证
/// （真实卷挂载点、挂载点/句柄 GUID 一致、DOS 设备映射为真实 NT 设备卷、独立于 C 盘）。
/// 信任锚失败时原样返回 `path-root-trust-anchor-invalid`，不会继续比较或写入。
#[cfg(windows)]
fn ensure_volume_is_d_volume(
    real_path: &Path,
    volume: &VolumeIdentity,
    original_path: &Path,
    label: &str,
) -> Result<(), PortablePathError> {
    let d_drive_volume = d_drive_volume_identity()?;
    if volume_identities_match(volume, &d_drive_volume) {
        return Ok(());
    }
    Err(PortablePathError::new(
        error_codes::PATH_REAL_TARGET_NOT_D,
        format!(
            "{label} 所在物理卷与 D 盘根卷不一致（卷 GUID / NT 设备卷身份比对失败；\
             可能是 SUBST 驱动器、目录卷挂载点、Junction 或映射网络盘别名）：{} -> {}。\
             已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
            original_path.display(),
            real_path.display()
        ),
    ))
}

/// 从 Win32 最终路径中提取本地盘符；UNC、卷 GUID、设备路径等返回 `None`。
#[cfg(windows)]
fn drive_letter_of_local_path(path: &Path) -> Option<char> {
    match path.components().next()? {
        Component::Prefix(prefix) => match prefix.kind() {
            Prefix::Disk(letter) | Prefix::VerbatimDisk(letter) => Some(char::from(letter)),
            _ => None,
        },
        _ => None,
    }
}

/// 查询盘符根目录的卷类型（Win32 `GetDriveTypeW`）。
#[cfg(windows)]
fn query_drive_type(letter: char) -> u32 {
    let root = format!("{letter}:\\");
    let wide_root = to_wide_null(Path::new(&root));
    // SAFETY: wide_root 以 NUL 结尾；GetDriveTypeW 只读取该字符串。
    unsafe { GetDriveTypeW(wide_root.as_ptr()) }
}

/// 允许的卷类型：本地固定盘（`DRIVE_FIXED`=3）或可移动盘（`DRIVE_REMOVABLE`=2）。
///
/// 显式拒绝 `DRIVE_REMOTE`=4（映射网络盘）、`DRIVE_CDROM`=5、`DRIVE_RAMDISK`=6、
/// `DRIVE_NO_ROOT_DIR`=1 以及 `DRIVE_UNKNOWN`=0。纯函数，便于单元测试覆盖各卷类型。
#[cfg(windows)]
fn is_allowed_volume_type(drive_type: u32) -> bool {
    use windows_sys::Win32::System::WindowsProgramming::{DRIVE_FIXED, DRIVE_REMOVABLE};
    drive_type == DRIVE_FIXED || drive_type == DRIVE_REMOVABLE
}

/// fail-closed 校验：`path` 的真实最终存储位置必须与 D 盘根目录位于**同一物理卷**，
/// 且仍是 D 盘本地固定盘或可移动盘。
///
/// 调用方必须保证 `path` 已存在；不存在时返回 `path-real-location-unavailable`。
/// 步骤（审计 P1 + R2-03 + R3-01）：
/// 0. 独立验证 D 盘根卷信任锚（真实卷挂载点、挂载点/句柄 GUID 一致、QueryDosDevice 映射
///    为真实 NT 设备卷、根卷独立于 C 盘）；失败返回 `path-root-trust-anchor-invalid`；
/// 1. 用句柄解析真实最终 DOS 路径（展开完整祖先链上的 Junction/符号链接/挂载点）；
/// 2. 用同一句柄取卷 GUID / NT 设备卷身份，与已通过信任锚验证的 D 盘根卷身份比较；
///    不一致即拒绝（SUBST、目录卷挂载点、D→C 别名等）；
/// 3. 最终 DOS 路径必须仍是 D 盘本地盘符；
/// 4. 盘符卷类型必须是本地固定盘或可移动盘（拒绝映射网络盘/光驱/内存盘）。
#[cfg(windows)]
fn validate_real_storage_path(path: &Path, label: &str) -> Result<(), PortablePathError> {
    let handle = open_path_handle(path)?;
    let real_path = get_final_path_by_flags(handle.0, path, VOLUME_NAME_DOS)?;
    let volume = volume_identity_for_handle(handle.0, path)?;
    drop(handle);

    if !real_path.is_absolute() {
        return Err(real_location_unavailable(
            path,
            format!("真实最终路径不是绝对路径：{}", real_path.display()),
        ));
    }

    // 1) 物理卷身份必须与 D 盘根卷一致（不能只看盘符字符串）。
    ensure_volume_is_d_volume(&real_path, &volume, path, label)?;

    // 2) DOS 最终路径必须仍是 D 盘本地盘符。
    let Some(drive) = drive_letter_of_local_path(&real_path) else {
        return Err(PortablePathError::new(
            error_codes::PATH_NOT_LOCAL_VOLUME,
            format!(
                "{label} 的真实最终路径不是本地盘符路径（可能是 UNC 网络路径、卷挂载点或设备路径）：\
                 {} -> {}。WorkManager 只允许 D 盘本地固定盘或可移动盘；已停止启动，\
                 不会回退到 C 盘、AppData 或系统 Temp。",
                path.display(),
                real_path.display()
            ),
        ));
    };

    if !matches!(drive, 'D' | 'd') {
        return Err(PortablePathError::new(
            error_codes::PATH_REAL_TARGET_NOT_D,
            format!(
                "{label} 的真实最终目标在 {drive}: 盘而不是 D 盘：{} -> {}。\
                 该路径可能被 Junction/符号链接重解析到其他卷；已停止启动，\
                 不会回退到 C 盘、AppData 或系统 Temp。",
                path.display(),
                real_path.display()
            ),
        ));
    }

    // 3) 盘符卷类型必须是本地固定盘或可移动盘。
    let drive_type = query_drive_type(drive);
    if !is_allowed_volume_type(drive_type) {
        return Err(PortablePathError::new(
            error_codes::PATH_NOT_LOCAL_VOLUME,
            format!(
                "{label} 所在的 {drive}: 卷不是本地固定盘或可移动盘（GetDriveTypeW={drive_type}；\
                 DRIVE_REMOTE=4 表示映射网络盘）：{} -> {}。已停止启动，\
                 不会回退到 C 盘、AppData 或系统 Temp。",
                path.display(),
                real_path.display()
            ),
        ));
    }

    Ok(())
}

/// 非 Windows 平台降级实现：保留既有纯字符串规则，不引入 Win32 卷/重解析点语义。
#[cfg(not(windows))]
fn resolve_real_final_path(path: &Path) -> Result<PathBuf, PortablePathError> {
    Ok(path.to_path_buf())
}

/// 非 Windows 平台降级实现：真实存储位置校验为空操作（本产品目标平台为 Windows 10）。
#[cfg(not(windows))]
fn validate_real_storage_path(path: &Path, _label: &str) -> Result<(), PortablePathError> {
    let _ = resolve_real_final_path(path)?;
    Ok(())
}

fn write_writable_probe(directory: &Path, label: &str) -> Result<(), PortablePathError> {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let probe_path = directory.join(format!(
        "{WRITE_PROBE_FILE_PREFIX}-{}-{unique}",
        std::process::id()
    ));

    let result = (|| -> io::Result<()> {
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&probe_path)?;
        io::Write::write_all(
            &mut file,
            format!(
                "WorkManager write probe (deleted immediately)\npid={}\n",
                std::process::id()
            )
            .as_bytes(),
        )?;
        file.sync_all()?;
        io::Write::flush(&mut file)?;
        drop(file);
        fs::remove_file(&probe_path)?;
        Ok(())
    })();

    result.map_err(|error| {
        let _ = fs::remove_file(&probe_path);
        PortablePathError::new(
            error_codes::DIRECTORY_NOT_WRITABLE,
            format!(
                "{label} 目录不可写：{}；系统错误：{error}。\
                 已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                directory.display()
            ),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d_path(value: &str) -> PathBuf {
        PathBuf::from(value)
    }

    #[test]
    fn release_mode_uses_exe_adjacent_data() {
        let paths = PortablePaths::resolve(
            RuntimeMode::Release,
            &d_path(r"D:\WorkManager\WorkManager.exe"),
            None,
        )
        .expect("release paths");
        assert_eq!(paths.mode, RuntimeMode::Release);
        assert_eq!(paths.data_source, "exe-adjacent-data");
        assert_eq!(paths.portable_root, d_path(r"D:\WorkManager"));
        assert_eq!(paths.data_root, d_path(r"D:\WorkManager\data"));
        assert_eq!(
            paths.database_file(),
            d_path(r"D:\WorkManager\data\database\work.db")
        );
        assert_eq!(
            paths.webview2_dir,
            d_path(r"D:\WorkManager\data\cache\webview2")
        );
    }

    #[test]
    fn release_mode_ignores_test_root_environment() {
        // Release 无条件忽略测试根目录，即使调用方传入（等价于环境变量存在）。
        assert_eq!(
            select_debug_root(
                RuntimeMode::Release,
                Some(std::ffi::OsString::from(r"D:\decoy-data"))
            ),
            None
        );
        let decoy = d_path(r"D:\decoy-data");
        let paths = PortablePaths::resolve(
            RuntimeMode::Release,
            &d_path(r"D:\WorkManager\WorkManager.exe"),
            Some(&decoy),
        )
        .expect("release paths");
        assert_eq!(paths.data_root, d_path(r"D:\WorkManager\data"));
        assert_ne!(paths.data_root, decoy);
    }

    #[test]
    fn debug_mode_requires_test_root() {
        let error = PortablePaths::resolve(
            RuntimeMode::DebugTest,
            &d_path(r"D:\dev\WorkManager.exe"),
            None,
        )
        .expect_err("debug requires root");
        assert_eq!(error.code(), error_codes::DEBUG_ROOT_MISSING);

        let debug_root = d_path(r"D:\WorkManager-test-data\case-001\data");
        let paths = PortablePaths::resolve(
            RuntimeMode::DebugTest,
            &d_path(r"D:\dev\WorkManager.exe"),
            Some(&debug_root),
        )
        .expect("debug paths");
        assert_eq!(paths.mode, RuntimeMode::DebugTest);
        assert_eq!(paths.data_source, "debug-env");
        assert_eq!(paths.data_root, debug_root);
    }

    #[test]
    fn debug_mode_rejects_formal_release_root() {
        for candidate in [
            r"D:\WorkManager",
            r"D:\WorkManager\data",
            r"d:\workmanager\data",
        ] {
            let error = PortablePaths::resolve(
                RuntimeMode::DebugTest,
                &d_path(r"D:\dev\WorkManager.exe"),
                Some(&d_path(candidate)),
            )
            .expect_err("formal release root must be rejected");
            assert_eq!(
                error.code(),
                error_codes::DEBUG_ROOT_IS_FORMAL_RELEASE,
                "candidate={candidate}"
            );
        }
        // 同名但不是正式目录的路径仍允许（如 D:\WorkManager-test-data）。
        PortablePaths::resolve(
            RuntimeMode::DebugTest,
            &d_path(r"D:\dev\WorkManager.exe"),
            Some(&d_path(r"D:\WorkManager-test-data\case")),
        )
        .expect("test dir is fine");
    }

    #[test]
    fn non_d_and_non_drive_paths_are_rejected() {
        for (candidate, expected) in [
            (
                r"C:\WorkManager\WorkManager.exe",
                error_codes::PATH_NOT_ON_D_DRIVE,
            ),
            (
                r"Q:\WorkManager\WorkManager.exe",
                error_codes::PATH_NOT_ON_D_DRIVE,
            ),
            (
                r"\\server\share\WorkManager.exe",
                error_codes::PATH_NOT_LOCAL_DRIVE,
            ),
            (r"WorkManager.exe", error_codes::PATH_NOT_ABSOLUTE),
        ] {
            let error = PortablePaths::resolve(RuntimeMode::Release, &d_path(candidate), None)
                .expect_err("path must be rejected");
            assert_eq!(error.code(), expected, "candidate={candidate}");
        }
    }

    #[test]
    fn parent_dir_components_are_rejected() {
        let error = PortablePaths::resolve(
            RuntimeMode::DebugTest,
            &d_path(r"D:\dev\WorkManager.exe"),
            Some(&d_path(r"D:\WorkManager-test-data\..\elsewhere")),
        )
        .expect_err("parent component must be rejected");
        assert_eq!(error.code(), error_codes::PATH_HAS_PARENT_COMPONENT);
    }

    #[test]
    fn relative_debug_root_is_rejected() {
        let error = PortablePaths::resolve(
            RuntimeMode::DebugTest,
            &d_path(r"D:\dev\WorkManager.exe"),
            Some(&d_path(r"portable-test-data")),
        )
        .expect_err("relative root must be rejected");
        assert_eq!(error.code(), error_codes::DEBUG_ROOT_NOT_ABSOLUTE);
    }

    #[test]
    fn select_debug_root_filters_empty_values() {
        assert_eq!(
            select_debug_root(RuntimeMode::DebugTest, Some(std::ffi::OsString::new())),
            None
        );
        assert_eq!(
            select_debug_root(
                RuntimeMode::DebugTest,
                Some(std::ffi::OsString::from(r"D:\WorkManager-test-data\x"))
            ),
            Some(d_path(r"D:\WorkManager-test-data\x"))
        );
    }

    #[cfg(windows)]
    #[test]
    fn only_fixed_and_removable_volumes_are_allowed() {
        use windows_sys::Win32::System::WindowsProgramming::{
            DRIVE_CDROM, DRIVE_FIXED, DRIVE_NO_ROOT_DIR, DRIVE_RAMDISK, DRIVE_REMOTE,
            DRIVE_REMOVABLE,
        };

        assert!(is_allowed_volume_type(DRIVE_FIXED), "本地固定盘必须允许");
        assert!(is_allowed_volume_type(DRIVE_REMOVABLE), "可移动盘必须允许");
        // 映射网络盘无法在无网络共享的实机上真实构造，这里用 Win32 常量覆盖拒绝逻辑。
        assert!(!is_allowed_volume_type(DRIVE_REMOTE), "映射网络盘必须拒绝");
        assert!(!is_allowed_volume_type(DRIVE_CDROM), "光驱必须拒绝");
        assert!(!is_allowed_volume_type(DRIVE_RAMDISK), "内存盘必须拒绝");
        assert!(
            !is_allowed_volume_type(DRIVE_NO_ROOT_DIR),
            "无效盘符必须拒绝"
        );
        assert!(!is_allowed_volume_type(0), "DRIVE_UNKNOWN 必须拒绝");
    }

    #[cfg(windows)]
    #[test]
    fn real_final_path_drive_letters_are_parsed_conservatively() {
        // GetFinalPathNameByHandleW(VOLUME_NAME_DOS) 返回 `\\?\D:\...`（VerbatimDisk）；
        // 普通 `D:\...` 路径解析为 Disk。盘符大小写不敏感（std 可能规范化为大写）。
        for candidate in [
            r"\\?\D:\WorkManager\data",
            r"\\?\d:\WorkManager",
            r"D:\WorkManager",
            r"d:\WorkManager",
        ] {
            assert_eq!(
                drive_letter_of_local_path(Path::new(candidate)).map(|c| c.to_ascii_uppercase()),
                Some('D'),
                "candidate={candidate}"
            );
        }
        assert_eq!(
            drive_letter_of_local_path(Path::new(r"\\?\C:\Users\Public"))
                .map(|c| c.to_ascii_uppercase()),
            Some('C')
        );
        // UNC 网络路径、卷 GUID 路径、设备路径一律不视为本地盘符。
        assert_eq!(
            drive_letter_of_local_path(Path::new(r"\\?\UNC\server\share\data")),
            None
        );
        assert_eq!(
            drive_letter_of_local_path(Path::new(
                r"\\?\Volume{00000000-0000-0000-0000-000000000000}\data"
            )),
            None
        );
        assert_eq!(
            drive_letter_of_local_path(Path::new(r"\\.\PhysicalDrive0")),
            None
        );
    }

    // -----------------------------------------------------------------------
    // 审计 R2-03 / R3-01：真实物理卷身份与根卷信任锚
    //
    // 生产函数 `volume_mount_point_guid()` / `query_dos_device_target()` 由测试直接调用，
    // 保证“测试验证的检查就是生产路径真正使用的检查”。
    // -----------------------------------------------------------------------

    /// 子进程级 SUBST 夹具：把空闲盘符映射到 C 盘测试目录；Drop 时删除映射与测试目录。
    ///
    /// 说明：本机 `D:` 是真实物理卷，Windows 不允许对已存在的盘符执行 SUBST；审计报告里
    /// “SUBST 把 D: 映射到 C 盘目录”的场景无法在本机真实构造，因此用“空闲盘符 → C 盘目录”
    /// 验证同一底层机制（DOS 设备别名）的卷身份识别，并在报告中如实标注差异。
    #[cfg(windows)]
    struct SubstFixture {
        letter: char,
        target: PathBuf,
    }

    #[cfg(windows)]
    impl SubstFixture {
        fn new() -> Self {
            let local_app_data = std::env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .expect("需要 %LOCALAPPDATA% 绝对路径来构造 SUBST 测试夹具");
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let target = local_app_data.join(format!(
                "WorkManager-subst-identity-{}-{nanos}",
                std::process::id()
            ));
            fs::create_dir_all(&target).expect("创建 SUBST 测试目标目录");
            assert_ne!(
                drive_letter_of_local_path(&target).map(|letter| letter.to_ascii_uppercase()),
                Some('D'),
                "SUBST 测试目标必须在非 D 盘才能构造跨卷别名：{}",
                target.display()
            );

            let letter = ['Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z']
                .into_iter()
                .find(|letter| !Path::new(&format!("{letter}:\\")).exists())
                .expect("没有空闲盘符可用于 SUBST 测试");
            let status = std::process::Command::new("cmd")
                .args(["/c", "subst"])
                .arg(format!("{letter}:"))
                .arg(&target)
                .status()
                .expect("执行 subst 命令");
            assert!(
                status.success(),
                "subst {letter}: <目标> 失败（退出码 {status}）"
            );
            assert!(
                Path::new(&format!("{letter}:\\")).is_dir(),
                "SUBST 驱动器必须可见：{letter}:"
            );
            Self { letter, target }
        }
    }

    #[cfg(windows)]
    impl Drop for SubstFixture {
        fn drop(&mut self) {
            let _ = std::process::Command::new("cmd")
                .args(["/c", "subst"])
                .arg(format!("{}:", self.letter))
                .arg("/D")
                .status();
            let _ = fs::remove_dir_all(&self.target);
        }
    }

    /// R2-03：D 盘根卷的句柄卷 GUID 必须与 `GetVolumeNameForVolumeMountPointW` 独立 API
    /// 返回的卷 GUID 一致，证明卷身份来自真实卷对象，而不是盘符字符串。
    #[cfg(windows)]
    #[test]
    fn d_drive_volume_identity_matches_independent_mount_point_api() {
        let identity = d_drive_volume_identity().expect("必须能解析 D 盘根卷身份");
        let handle_guid = identity
            .volume_guid
            .clone()
            .expect("D 盘根卷必须能取得卷 GUID（VOLUME_NAME_GUID）");
        let api_guid = volume_mount_point_guid(Path::new(r"D:\"))
            .expect("GetVolumeNameForVolumeMountPointW(D:\\) 应成功");
        println!("[r2-03] D:\\ handle(VOLUME_NAME_GUID) = {handle_guid}");
        println!("[r2-03] D:\\ GetVolumeNameForVolumeMountPointW = {api_guid}");
        assert_eq!(
            handle_guid, api_guid,
            "句柄卷 GUID 必须与独立卷挂载点 API 结果一致"
        );
        let nt_device = identity
            .nt_device
            .as_deref()
            .expect("D 盘根卷必须能取得 NT 设备卷身份（VOLUME_NAME_NT）");
        assert!(
            nt_device.starts_with(r"\device\"),
            "NT 设备卷身份格式异常：{nt_device}"
        );
        println!("[r2-03] D:\\ VOLUME_NAME_NT = {nt_device}");
        println!("[r2-03] PASS：D 盘卷身份由两个独立 Win32 API 交叉确认，非盘符字符串推断");
    }

    /// 串行化使用 SUBST 盘符的测试：同一测试进程内并行运行会争抢空闲盘符。
    #[cfg(windows)]
    static SUBST_DRIVE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// R2-03：SUBST 驱动器（DOS 设备别名）指向非 D 盘卷时，句柄卷身份必须识别为 C 盘卷，
    /// 并且真实存储校验必须 fail-closed。
    #[cfg(windows)]
    #[test]
    fn subst_drive_to_c_volume_is_detected_by_handle_volume_identity() {
        let _serial = SUBST_DRIVE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let fixture = SubstFixture::new();
        let subst_root = PathBuf::from(format!("{}:\\", fixture.letter));
        let probe = subst_root.join("r2-03-subst-probe.txt");
        fs::write(&probe, b"workmanager-test-fixture").expect("通过 SUBST 写入测试探针");

        let d_identity = d_drive_volume_identity().expect("D 盘根卷身份");
        let c_identity = volume_identity_for_path(Path::new(r"C:\")).expect("C 盘根卷身份");
        let subst_identity = volume_identity_for_path(&subst_root).expect("SUBST 根目录卷身份");

        println!(
            "[r2-03] D: identity = guid {:?} / nt {:?}",
            d_identity.volume_guid, d_identity.nt_device
        );
        println!(
            "[r2-03] C: identity = guid {:?} / nt {:?}",
            c_identity.volume_guid, c_identity.nt_device
        );
        println!(
            "[r2-03] {}: identity = guid {:?} / nt {:?}",
            fixture.letter, subst_identity.volume_guid, subst_identity.nt_device
        );

        assert!(
            volume_identities_match(&c_identity, &subst_identity),
            "SUBST 根目录的句柄卷身份必须与 C 盘根卷一致（证明句柄解析穿透 DOS 设备别名）"
        );
        assert!(
            !volume_identities_match(&d_identity, &subst_identity),
            "SUBST 根目录的句柄卷身份不得与 D 盘根卷相同"
        );

        // QueryDosDeviceW 证据：SUBST 是 DOS 设备层别名，而不是卷挂载点。
        let dos_device = query_dos_device_target(&format!("{}:", fixture.letter))
            .expect("QueryDosDeviceW 应返回 SUBST 映射目标");
        println!(
            "[r2-03] QueryDosDeviceW({}:) = {:?}",
            fixture.letter, dos_device
        );
        // GetVolumeNameForVolumeMountPointW 期望卷挂载点；SUBST 盘符不是卷挂载点。
        let mount_point_error = volume_mount_point_guid(&subst_root)
            .expect_err("SUBST 盘符不是卷挂载点，挂载点 API 必须失败");
        println!(
            "[r2-03] GetVolumeNameForVolumeMountPointW({}:) -> code = {}",
            fixture.letter,
            mount_point_error.code()
        );
        assert_eq!(
            mount_point_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID
        );

        // 真实存储校验必须 fail-closed（物理卷不是 D 盘卷）。
        let error = validate_real_storage_path(&probe, "SUBST 测试路径")
            .expect_err("SUBST 指向非 D 盘卷时真实存储校验必须 fail-closed");
        println!(
            "[r2-03] validate_real_storage_path(SUBST) -> code = {}",
            error.code()
        );
        assert_eq!(
            error.code(),
            error_codes::PATH_REAL_TARGET_NOT_D,
            "SUBST 跨卷别名必须返回 path-real-target-not-d：{error}"
        );

        // 字符串盘符规则仍然独立拒绝非 D 盘符（防御纵深）。
        let resolve_error = PortablePaths::resolve(
            RuntimeMode::Release,
            &subst_root.join("WorkManager.exe"),
            None,
        )
        .expect_err("非 D 盘符必须被字符串规则拒绝");
        assert_eq!(resolve_error.code(), error_codes::PATH_NOT_ON_D_DRIVE);

        fs::remove_file(&probe).expect("删除 SUBST 测试探针");
        println!("[r2-03] PASS：SUBST 卷别名被物理卷身份识别并 fail-closed；映射与测试探针已清理");
    }

    // -----------------------------------------------------------------------
    // 审计 R3-01：根卷信任锚独立验证
    // -----------------------------------------------------------------------

    /// 构造测试用卷身份（仅用于注入错误/不一致场景，不代表真实 API 结果）。
    #[cfg(windows)]
    fn synthetic_volume_identity(guid: &str, nt_device: &str) -> VolumeIdentity {
        VolumeIdentity {
            volume_guid: Some(guid.to_string()),
            nt_device: Some(nt_device.to_string()),
        }
    }

    /// R3-01 正常场景：真实 D 盘是独立的本地卷挂载点，两条独立证据链一致且与 C 盘不同卷。
    #[cfg(windows)]
    #[test]
    fn r3_01_trust_anchor_passes_for_real_d_drive_and_differs_from_c() {
        // 生产信任锚函数（目标路径卷身份比较实际使用的同一函数）。
        let identity =
            verify_root_volume_trust(Path::new(r"D:\")).expect("真实 D 盘根卷必须通过信任锚验证");
        let mount_point_guid = volume_mount_point_guid(Path::new(r"D:\"))
            .expect("GetVolumeNameForVolumeMountPointW(D:\\) 必须成功");
        let dos_device_target =
            query_dos_device_target("D:").expect("QueryDosDeviceW(D:) 必须返回 NT 设备映射");
        let drive_type = query_drive_type('D');
        let c_mount_point_guid =
            volume_mount_point_guid(Path::new(r"C:\")).expect("C 盘根卷身份必须可解析");

        println!("[r3-01] D:\\ mount-point GUID = {mount_point_guid}");
        println!(
            "[r3-01] D:\\ handle(VOLUME_NAME_GUID) = {:?}",
            identity.volume_guid
        );
        println!(
            "[r3-01] D:\\ handle(VOLUME_NAME_NT) = {:?}",
            identity.nt_device
        );
        println!("[r3-01] QueryDosDeviceW(D:) = {dos_device_target}");
        println!("[r3-01] D:\\ GetDriveTypeW = {drive_type}");
        println!("[r3-01] C:\\ mount-point GUID = {c_mount_point_guid}");

        assert_eq!(
            identity.volume_guid.as_deref(),
            Some(mount_point_guid.as_str()),
            "D 根句柄 GUID 必须与独立卷挂载点 API 一致"
        );
        assert!(
            dos_device_target.starts_with(r"\Device\"),
            "真实 D 盘的 DOS 设备映射必须是 NT 设备路径，实际：{dos_device_target}"
        );
        ensure_dos_device_maps_to_volume(&dos_device_target, &identity, Path::new(r"D:\"))
            .expect("真实 D 盘的 DOS 设备映射必须与根卷 NT 设备身份一致");
        assert!(
            is_allowed_volume_type(drive_type),
            "D 盘卷类型必须属于本地固定盘/可移动盘白名单：{drive_type}"
        );
        assert_ne!(
            mount_point_guid, c_mount_point_guid,
            "真实 D 盘必须与 C 盘是不同物理卷"
        );
        ensure_root_volume_differs_from_c(
            &mount_point_guid,
            &c_mount_point_guid,
            Path::new(r"D:\"),
        )
        .expect("真实 D 盘与 C 盘不同卷，信任锚应允许");

        // 生产路径：普通 D 盘路径通过 validate_real_storage_path（内部调用信任锚）。
        validate_real_storage_path(Path::new(r"D:\WorkManager-test-data"), "D 盘测试根目录")
            .expect("真实 D 盘路径必须通过生产校验");
        println!(
            "[r3-01] PASS：D 根卷信任锚由挂载点 API、句柄 GUID/NT、QueryDosDevice 与 D/C 卷比较独立验证"
        );
    }

    /// R3-01 负向实机场景：真实 SUBST 盘符作为候选信任锚必须在信任锚阶段被拒绝，
    /// 且 QueryDosDevice 的 `\??\...` 别名映射被生产分类函数拒绝。
    #[cfg(windows)]
    #[test]
    fn r3_01_trust_anchor_rejects_real_subst_candidate_root() {
        let _serial = SUBST_DRIVE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let fixture = SubstFixture::new();
        let subst_root = PathBuf::from(format!("{}:\\", fixture.letter));

        // 生产信任锚函数直接拒绝 SUBST 候选根（不是靠目标路径最终盘符检查碰巧拒绝）。
        let trust_error =
            verify_root_volume_trust(&subst_root).expect_err("SUBST 盘符不能作为可信根卷");
        println!(
            "[r3-01] verify_root_volume_trust({}:) -> code = {}",
            fixture.letter,
            trust_error.code()
        );
        println!("[r3-01] message = {trust_error}");
        assert_eq!(
            trust_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID,
            "SUBST 候选根必须返回 path-root-trust-anchor-invalid：{trust_error}"
        );
        assert!(
            trust_error
                .to_string()
                .contains("GetVolumeNameForVolumeMountPointW"),
            "SUBST 候选根应在挂载点 GUID 校验阶段失败：{trust_error}"
        );

        // QueryDosDevice 实机行为：SUBST 返回 `\??\...` DOS 路径别名，生产分类函数拒绝。
        let dos_device_target = query_dos_device_target(&format!("{}:", fixture.letter))
            .expect("QueryDosDeviceW 应返回 SUBST 映射目标");
        println!(
            "[r3-01] QueryDosDeviceW({}:) = {dos_device_target}",
            fixture.letter
        );
        assert!(
            dos_device_target.starts_with(r"\??\"),
            "SUBST 的 DOS 设备映射应是 \\??\\ 路径别名，实际：{dos_device_target}"
        );
        let d_identity = d_drive_volume_identity().expect("D 盘根卷身份");
        let dos_error =
            ensure_dos_device_maps_to_volume(&dos_device_target, &d_identity, &subst_root)
                .expect_err("SUBST 的 DOS 路径别名必须被生产分类函数拒绝");
        println!(
            "[r3-01] ensure_dos_device_maps_to_volume(SUBST) -> code = {}",
            dos_error.code()
        );
        assert_eq!(
            dos_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID
        );

        println!("[r3-01] PASS：真实 SUBST 候选根在信任锚阶段被拒绝；DOS 设备别名分类拒绝生效");
    }

    /// R3-01 注入模拟①：挂载点 GUID 与根目录句柄 GUID 不一致必须拒绝。
    #[cfg(windows)]
    #[test]
    fn r3_01_trust_anchor_rejects_mount_point_guid_mismatch() {
        let root = Path::new(r"D:\");
        let identity = synthetic_volume_identity(
            r"\\?\volume{11111111-1111-1111-1111-111111111111}",
            r"\device\harddiskvolume4",
        );
        let mismatch = ensure_mount_point_guid_matches_handle(
            r"\\?\volume{22222222-2222-2222-2222-222222222222}",
            &identity,
            root,
        )
        .expect_err("挂载点 GUID 与句柄 GUID 不一致必须拒绝");
        println!(
            "[r3-01] injected GUID mismatch -> code = {}",
            mismatch.code()
        );
        assert_eq!(mismatch.code(), error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID);

        // 注入模拟：两者一致时通过（不代表真实实机结果）。
        ensure_mount_point_guid_matches_handle(
            r"\\?\volume{11111111-1111-1111-1111-111111111111}",
            &identity,
            root,
        )
        .expect("注入的相同 GUID 必须通过纯校验");
        println!("[r3-01] PASS（注入模拟）：GUID 不一致拒绝、一致允许；非真实实机场景");
    }

    /// R3-01 注入模拟②：D 根与 C 根 GUID 相同必须拒绝（真实同卷环境未在本机构造）。
    #[cfg(windows)]
    #[test]
    fn r3_01_trust_anchor_rejects_d_root_same_volume_as_c() {
        let root = Path::new(r"D:\");
        let same = r"\\?\volume{33333333-3333-3333-3333-333333333333}";
        let error = ensure_root_volume_differs_from_c(same, same, root)
            .expect_err("D 根与 C 根同一物理卷必须拒绝");
        println!("[r3-01] injected D == C -> code = {}", error.code());
        assert_eq!(error.code(), error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID);

        ensure_root_volume_differs_from_c(
            r"\\?\volume{44444444-4444-4444-4444-444444444444}",
            r"\\?\volume{55555555-5555-5555-5555-555555555555}",
            root,
        )
        .expect("不同卷 GUID 必须通过纯校验");
        println!("[r3-01] PASS（注入模拟）：D 与 C 同卷拒绝、不同卷允许；非真实实机场景");
    }

    /// R3-01 注入模拟③ + 实机：DOS 设备别名/设备不一致必须拒绝。
    #[cfg(windows)]
    #[test]
    fn r3_01_trust_anchor_rejects_dos_device_alias_and_device_mismatch() {
        let root = Path::new(r"D:\");
        let d_identity = d_drive_volume_identity().expect("D 盘根卷身份");

        // 注入模拟：SUBST 风格的 DOS 路径别名。
        let alias_error =
            ensure_dos_device_maps_to_volume(r"\??\C:\Users\Public", &d_identity, root)
                .expect_err("DOS 路径别名必须被拒绝");
        println!(
            "[r3-01] injected DOS alias -> code = {}",
            alias_error.code()
        );
        assert_eq!(
            alias_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID
        );

        // 注入模拟：映射到其他 NT 设备卷。
        let mismatch_error =
            ensure_dos_device_maps_to_volume(r"\Device\HarddiskVolume99", &d_identity, root)
                .expect_err("DOS 设备映射与根卷身份不一致必须拒绝");
        assert_eq!(
            mismatch_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID
        );

        // 实机：真实 D 盘的 QueryDosDevice 映射必须通过分类校验。
        let real_target = query_dos_device_target("D:").expect("QueryDosDeviceW(D:)");
        ensure_dos_device_maps_to_volume(&real_target, &d_identity, root)
            .expect("真实 D 盘 DOS 设备映射必须通过");
        println!(
            "[r3-01] PASS：注入 DOS 别名/设备不一致拒绝；真实 D 盘映射允许（实机 API 证据 {real_target}）"
        );
    }

    /// R3-01 fail-closed：根卷身份 API 不可用/路径不是真实卷挂载点时必须拒绝启动。
    #[cfg(windows)]
    #[test]
    fn r3_01_trust_anchor_fails_closed_on_api_unavailable() {
        // 真实 API 行为：普通子目录不是卷挂载点，GetVolumeNameForVolumeMountPointW 失败。
        let mount_point_error = volume_mount_point_guid(Path::new(r"D:\WorkManager-test-data"))
            .expect_err("普通目录不是卷挂载点，挂载点 API 必须失败");
        println!(
            "[r3-01] volume_mount_point_guid(普通目录) -> code = {}",
            mount_point_error.code()
        );
        assert_eq!(
            mount_point_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID
        );

        // 信任锚要求盘符根目录：普通子目录直接拒绝。
        let non_root_error = verify_root_volume_trust(Path::new(r"D:\WorkManager-test-data"))
            .expect_err("非盘符根目录不能作为信任锚");
        assert_eq!(
            non_root_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID
        );

        // 非本地盘符路径（UNC）不能作为信任锚。
        let unc_error = verify_root_volume_trust(Path::new(r"\\server\share\"))
            .expect_err("UNC 路径不能作为信任锚");
        assert_eq!(
            unc_error.code(),
            error_codes::PATH_ROOT_TRUST_ANCHOR_INVALID
        );

        println!("[r3-01] PASS：挂载点 API 失败与非法信任锚路径均 fail-closed");
    }
}
