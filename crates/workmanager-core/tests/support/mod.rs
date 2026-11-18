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

// ---------------------------------------------------------------------------
// 审计返工新增：文件哈希、数据库 sidecar、子进程与数据根目录辅助
// ---------------------------------------------------------------------------

/// 极简 SHA-256（FIPS 180-4）实现，只用于测试证据（不引入额外依赖）。
pub fn sha256_hex(input: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];

    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    let mut message = input.to_vec();
    let bit_len = (message.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in message.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (index, word) in chunk.chunks_exact(4).enumerate() {
            w[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..64 {
            let s0 = w[index - 15].rotate_right(7)
                ^ w[index - 15].rotate_right(18)
                ^ (w[index - 15] >> 3);
            let s1 = w[index - 2].rotate_right(17)
                ^ w[index - 2].rotate_right(19)
                ^ (w[index - 2] >> 10);
            w[index] = w[index - 16]
                .wrapping_add(s0)
                .wrapping_add(w[index - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[index])
                .wrapping_add(w[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    h.iter().map(|value| format!("{value:08x}")).collect()
}

/// 文件 SHA-256（十六进制小写）；文件不存在时返回 `None`。
pub fn file_sha256(path: &Path) -> Option<String> {
    fs::read(path).ok().map(|bytes| sha256_hex(&bytes))
}

/// SQLite sidecar 路径：`<path>-wal` / `<path>-shm` / `<path>-journal`。
pub fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{suffix}", path.display()))
}

/// 列出数据库目录中的初始化临时文件（`.work.db.init-*`）。
pub fn init_temp_files(database_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(database_dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.starts_with(".work.db.init-"))
                .unwrap_or(false)
        })
        .collect()
}

/// 在 Debug/Test 模式下构造独立数据根目录的便携路径（供子进程与并发测试使用）。
pub fn prepare_debug_paths(data_root: &Path) -> PortablePaths {
    let paths = PortablePaths::resolve(
        RuntimeMode::DebugTest,
        &data_root.join("WorkManager.exe"),
        Some(data_root),
    )
    .expect("resolve debug paths");
    paths.ensure_directories().expect("ensure debug layout");
    paths
}

/// 轮询等待文件出现（用于子进程启动栅栏）。
pub fn wait_for_file(path: &Path, timeout: std::time::Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if path.is_file() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    path.is_file()
}
