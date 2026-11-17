//! 便携路径解析（PortablePaths）。
//!
//! 设计目标（对应 T1-01 / DEC-002 / DEC-003 / TD 8.1-8.3）：
//! - Release：数据根目录始终跟随 EXE 所在目录（`<exe 目录>/data`），整个应用目录移动后自动重新定位。
//! - Debug/Test：只允许通过 `WORKMANAGER_TEST_PORTABLE_ROOT` 指定隔离测试根目录；未设置时 fail-closed。
//! - Release 必须忽略 `WORKMANAGER_TEST_PORTABLE_ROOT`。
//! - 只允许 D 盘本地绝对路径；不得回退到 `%APPDATA%`、`%LOCALAPPDATA%`、系统 Temp 或其他盘。
//! - 路径被文件阻塞、目录不可写、含符号链接或 `..` 时返回清晰错误，绝不静默换位置。
//! - Debug/Test 明确禁止把测试数据写进正式目录 `D:\WorkManager`。
//!
//! 本模块不依赖 Tauri，可被普通 `cargo test` 覆盖。

use std::{
    env, fmt, fs, io,
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use serde::Serialize;

/// Debug/Test 构建用于指定隔离测试数据根目录的环境变量。Release 构建忽略该变量。
pub const TEST_PORTABLE_ROOT_ENV: &str = "WORKMANAGER_TEST_PORTABLE_ROOT";

/// 正式便携版默认根目录。Debug/Test 不得把测试数据写入该目录，避免污染未来正式目录。
pub const FORMAL_RELEASE_ROOT: &str = r"D:\WorkManager";

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
                if is_same_or_child(data_root, Path::new(FORMAL_RELEASE_ROOT)) {
                    return Err(PortablePathError::new(
                        error_codes::DEBUG_ROOT_IS_FORMAL_RELEASE,
                        format!(
                            "拒绝把 Debug/Test 数据根目录指向正式便携目录 {FORMAL_RELEASE_ROOT}：{}。\
                             请改用独立的测试目录，避免污染正式运行数据。",
                            data_root.display()
                        ),
                    ));
                }
                (data_root.to_path_buf(), "debug-env")
            }
        };

        ensure_no_parent_components(&data_root)?;

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

        self.ensure_directory(&self.data_root, "data 数据根目录")?;
        for (path, label) in self.data_subdirectories() {
            self.ensure_directory(path, label)?;
        }

        for (path, label) in self.writable_probe_directories() {
            write_writable_probe(path, label)?;
        }

        Ok(())
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
}
