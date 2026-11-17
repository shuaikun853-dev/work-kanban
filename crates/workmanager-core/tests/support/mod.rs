//! 测试公共支持：隔离测试目录、便携路径构造与数据库文件检查。
//!
//! 测试数据规则（T1-01）：
//! - 所有测试数据必须位于 D 盘隔离目录，默认 `D:\WorkManager-test-data`；
//! - 可用环境变量 `WORKMANAGER_TEST_BASE_DIR` 覆盖（仍必须位于 D 盘）；
//! - 绝不写入正式运行目录 `D:\WorkManager`；
//! - 每个用例使用唯一子目录，`Drop` 时只删除本用例创建的目录。

#![allow(dead_code)]

use std::ffi::OsString;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use workmanager_core::{PortablePaths, RuntimeMode};

/// 测试根目录覆盖环境变量。
pub const TEST_BASE_ENV: &str = "WORKMANAGER_TEST_BASE_DIR";
/// 默认测试根目录（D 盘，仓库之外）。
pub const DEFAULT_TEST_BASE: &str = r"D:\WorkManager-test-data";
/// 正式运行目录，测试绝不允许写入。
pub const FORMAL_RELEASE_ROOT: &str = r"D:\WorkManager";

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// 一个隔离的测试目录；Drop 时安全清理。
pub struct TestDir {
    base: PathBuf,
    path: PathBuf,
}

impl TestDir {
    /// 创建唯一测试目录：`<base>/<label>-<pid>-<seq>-<nanos>`。
    pub fn new(label: &str) -> Self {
        let base = resolve_test_base();
        fs::create_dir_all(&base)
            .unwrap_or_else(|error| panic!("无法创建测试根目录 {}：{error}", base.display()));

        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let sequence = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = base.join(format!("{label}-{}-{sequence}-{nanos}", std::process::id()));
        fs::create_dir_all(&path)
            .unwrap_or_else(|error| panic!("无法创建测试目录 {}：{error}", path.display()));
        Self { base, path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, relative: impl AsRef<Path>) -> PathBuf {
        self.path.join(relative)
    }

    /// 创建一个“便携应用目录”：其中包含 EXE 占位与 data 目录布局。
    pub fn app_root(&self) -> PathBuf {
        let app_root = self.path.join("app");
        fs::create_dir_all(&app_root).expect("create app root");
        app_root
    }

    /// 构造 Release 模式便携路径（EXE 位于测试目录内）。
    pub fn release_paths(&self) -> PortablePaths {
        let app_root = self.app_root();
        let paths = PortablePaths::resolve(
            RuntimeMode::Release,
            &app_root.join("WorkManager.exe"),
            None,
        )
        .expect("resolve release paths");
        paths.ensure_directories().expect("ensure release layout");
        paths
    }

    /// 构造 Debug/Test 模式便携路径（数据根目录独立）。返回路径与数据根目录。
    pub fn debug_paths(&self) -> (PortablePaths, PathBuf) {
        let app_root = self.app_root();
        let data_root = self.path.join("debug-data");
        let paths = PortablePaths::resolve(
            RuntimeMode::DebugTest,
            &app_root.join("WorkManager.exe"),
            Some(&data_root),
        )
        .expect("resolve debug paths");
        paths.ensure_directories().expect("ensure debug layout");
        (paths, data_root)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        // 只删除本用例创建的、位于测试根目录之下的唯一子目录。
        let Some(canonical_base) = comparable(&self.base) else {
            return;
        };
        let Some(canonical_path) = comparable(&self.path) else {
            return;
        };
        if !is_same_or_child(&canonical_path, &canonical_base) {
            eprintln!(
                "跳过清理：测试目录 {} 不在测试根目录 {} 之下",
                self.path.display(),
                self.base.display()
            );
            return;
        }
        if is_same_or_child(&canonical_path, &comparable_path(FORMAL_RELEASE_ROOT)) {
            eprintln!(
                "跳过清理：拒绝删除正式运行目录下的路径 {}",
                self.path.display()
            );
            return;
        }
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// 解析测试根目录并强制校验 D 盘与正式目录边界。
pub fn resolve_test_base() -> PathBuf {
    let base = std::env::var_os(TEST_BASE_ENV)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_TEST_BASE));
    assert_test_location(&base);
    base
}

fn assert_test_location(path: &Path) {
    assert!(
        path.is_absolute(),
        "测试根目录必须是绝对路径：{}",
        path.display()
    );
    let drive = match path.components().next() {
        Some(Component::Prefix(prefix)) => prefix.kind(),
        _ => panic!("测试根目录必须是带盘符的 Windows 路径：{}", path.display()),
    };
    match drive {
        std::path::Prefix::Disk(letter) if letter == b'D' || letter == b'd' => {}
        std::path::Prefix::Disk(letter) => panic!(
            "测试数据必须位于 D 盘；当前测试根目录在 {} 盘：{}",
            char::from(letter),
            path.display()
        ),
        _ => panic!("测试根目录必须是 Windows 本地盘符路径：{}", path.display()),
    }
    if is_same_or_child(
        &comparable_or_self(path),
        &comparable_path(FORMAL_RELEASE_ROOT),
    ) {
        panic!(
            "测试根目录不得位于正式运行目录 {FORMAL_RELEASE_ROOT}：{}",
            path.display()
        );
    }
}

fn comparable(path: &Path) -> Option<PathBuf> {
    fs::canonicalize(path).ok()
}

fn comparable_or_self(path: &Path) -> PathBuf {
    comparable(path).unwrap_or_else(|| path.to_path_buf())
}

fn comparable_path(value: &str) -> PathBuf {
    comparable_or_self(Path::new(value))
}

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

/// 读取由测试写入的虚构 canary 行数量（用于验证重启后数据持久化）。
pub fn count_canary_rows(database_path: &Path) -> i64 {
    let connection = rusqlite::Connection::open_with_flags(
        database_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open database read-only");
    connection
        .query_row(
            "SELECT COUNT(*) FROM settings WHERE key = 'test-canary'",
            [],
            |row| row.get(0),
        )
        .expect("count canary rows")
}

/// 写入一条虚构测试数据（只用于测试，不代表业务默认设置）。
pub fn write_canary_row(database_path: &Path, value: &str) {
    let connection =
        rusqlite::Connection::open(database_path).expect("open database for canary write");
    connection
        .execute(
            "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-canary', ?1, '2026-11-17T00:00:00Z')",
            [value],
        )
        .expect("insert canary row");
}

/// 便捷构造 Debug/Test 模式的隔离数据根目录（与 `TestDir` 组合使用）。
pub fn debug_root(test_dir: &TestDir) -> PathBuf {
    test_dir.join("debug-data")
}

/// 让测试可以构造 Release 路径但暂不创建目录，用于异常路径测试。
pub fn raw_release_paths(app_root: &Path) -> PortablePaths {
    PortablePaths::resolve(
        RuntimeMode::Release,
        &app_root.join("WorkManager.exe"),
        None,
    )
    .expect("resolve release paths")
}

/// 让测试可以使用任意字符串形式的调试根目录。
pub fn raw_debug_paths(app_root: &Path, data_root: &Path) -> PortablePaths {
    PortablePaths::resolve(
        RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(data_root),
    )
    .expect("resolve debug paths")
}

/// 构造 `OsString` 的辅助函数（避免测试中重复写长类型）。
pub fn os(value: &str) -> OsString {
    OsString::from(value)
}
