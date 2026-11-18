//! 审计返工 P1：已存在的 0 字节数据库文件保护。
//!
//! 背景：SQLite 会把 0 字节文件当作空数据库；实测在“0 字节主库 + 残留 WAL”状态下，
//! SQLite 打开/关闭后会忽略并**删除** WAL，可能造成未 checkpoint 数据丢失。
//! 因此必须：
//! - 区分“首次安装”和“已有数据库”；
//! - 已有数据库为 0 字节时 fail-closed，绝不当作首次安装自动迁移；
//! - 不删除、不覆盖、不打开原文件（连 WAL 也不碰）；
//! - 不产生任何半初始化数据库。

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};

use support::{TestDir, file_sha256, init_temp_files, sidecar_path};
use workmanager_core::Database;

const CHILD_MODE_ENV: &str = "WM_TEST_CHILD_MODE";
const CHILD_DB_PATH_ENV: &str = "WM_TEST_CHILD_DB_PATH";
const INIT_LOCK_FILE_NAME: &str = ".work.db.init.lock";

/// 子进程辅助（父进程通过 `--exact child_writer_helper` 启动）。
///
/// 在普通测试运行中环境变量不存在，直接返回；只有父进程显式设置模式时才执行。
#[test]
fn child_writer_helper() {
    let Ok(mode) = std::env::var(CHILD_MODE_ENV) else {
        return;
    };
    match mode.as_str() {
        "crash-wal-writer" => {
            let db_path =
                PathBuf::from(std::env::var(CHILD_DB_PATH_ENV).expect("child db path environment"));
            let connection = rusqlite::Connection::open(&db_path).expect("child open db");
            connection
                .pragma_update(None, "journal_mode", "WAL")
                .expect("child enable WAL");
            connection
                .execute_batch(
                    "PRAGMA wal_autocheckpoint=0;
                     CREATE TABLE child_wal_probe (x INTEGER);
                     INSERT INTO child_wal_probe VALUES (42);
                     PRAGMA user_version=1;",
                )
                .expect("child write WAL data");
            println!(
                "child-crash-wal-writer main={} wal={}",
                fs::metadata(&db_path).map(|m| m.len()).unwrap_or(0),
                fs::metadata(sidecar_path(&db_path, "-wal"))
                    .map(|m| m.len())
                    .unwrap_or(0)
            );
            // 模拟崩溃：跳过 Rust 析构、SQLite close 与 WAL checkpoint。
            std::process::exit(9);
        }
        other => panic!("unknown child mode: {other}"),
    }
}

fn spawn_crash_wal_writer(db_path: &Path) -> Child {
    Command::new(std::env::current_exe().expect("current test executable"))
        .args(["--exact", "child_writer_helper", "--nocapture"])
        .env(CHILD_MODE_ENV, "crash-wal-writer")
        .env(CHILD_DB_PATH_ENV, db_path)
        .spawn()
        .expect("spawn child crash writer")
}

/// 数据库目录中的“业务文件”（排除初始化锁文件与临时初始化文件）。
fn business_entries(database_dir: &Path) -> Vec<(String, u64)> {
    let Ok(entries) = fs::read_dir(database_dir) else {
        return Vec::new();
    };
    let mut files: Vec<(String, u64)> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let name = path.file_name()?.to_string_lossy().to_string();
            if name == INIT_LOCK_FILE_NAME || name.starts_with(".work.db.init-") {
                return None;
            }
            let size = entry.metadata().ok().map(|metadata| metadata.len())?;
            Some((name, size))
        })
        .collect();
    files.sort();
    files
}

#[test]
fn zero_byte_existing_database_is_not_treated_as_first_install() {
    let dir = TestDir::new("zero-byte-existing");
    let paths = dir.release_paths();
    let database_path = paths.database_file().to_path_buf();

    fs::write(&database_path, b"").expect("create zero-byte work.db");
    assert_eq!(fs::metadata(&database_path).expect("stat").len(), 0);
    let sha_before = file_sha256(&database_path).expect("sha before");
    let entries_before = business_entries(&paths.database_dir);

    let error = Database::initialize(&paths).expect_err("0 字节已有数据库必须 fail-closed");
    assert_eq!(
        error.code(),
        "database-empty-existing-file",
        "expected database-empty-existing-file, actual: {} ({error})",
        error.code()
    );
    assert!(
        error.to_string().contains("0 字节"),
        "错误消息必须说明 0 字节异常空文件：{error}"
    );
    println!(
        "zero-byte-existing: code={} sha256={sha_before}",
        error.code()
    );

    // 原文件必须保持不变（大小 + SHA-256）。
    let metadata = fs::metadata(&database_path).expect("stat after");
    assert_eq!(metadata.len(), 0, "原 0 字节文件不得被写入");
    assert_eq!(
        file_sha256(&database_path).expect("sha after"),
        sha_before,
        "原文件 SHA-256 必须保持不变"
    );
    // 文件仍存在（未被删除），且没有创建 WAL/SHM。
    assert!(database_path.is_file(), "原文件不得被删除");
    assert!(
        !sidecar_path(&database_path, "-wal").exists(),
        "不得创建 WAL 文件"
    );
    assert!(
        !sidecar_path(&database_path, "-shm").exists(),
        "不得创建 SHM 文件"
    );
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "不得留下半初始化临时数据库"
    );

    // 数据目录中不得出现新的业务文件（允许初始化锁文件存在）。
    assert_eq!(
        business_entries(&paths.database_dir),
        entries_before,
        "不得产生任何新的数据库/业务文件"
    );

    // 结构证明：主文件仍为 0 字节，因此不可能包含业务 schema。
    assert_eq!(fs::metadata(&database_path).expect("stat").len(), 0);

    // 恢复演练：用户确认后删除异常空文件，应用仍能正常首次初始化。
    fs::remove_file(&database_path).expect("user-confirmed removal of zero-byte file");
    let database = Database::initialize(&paths).expect("删除异常空文件后应可首次初始化");
    assert!(database.created_new());
    assert_eq!(database.schema_version().expect("schema version"), 1);
    println!(
        "zero-byte-existing: recovery-after-user-removal created_new=true schema={}",
        database.schema_version().expect("schema version")
    );
}

#[test]
fn zero_byte_database_with_wal_leftover_fails_closed_and_preserves_wal() {
    let dir = TestDir::new("zero-byte-wal");
    let paths = dir.release_paths();
    let database_path = paths.database_file().to_path_buf();
    let wal_path = sidecar_path(&database_path, "-wal");

    // 用独立子进程制造“崩溃后”的 WAL 状态（不 close、不 checkpoint）。
    let mut child = spawn_crash_wal_writer(&database_path);
    let status = child.wait().expect("wait crash writer");
    assert_eq!(
        status.code(),
        Some(9),
        "子进程必须以崩溃模拟退出码 9 结束，实际：{status:?}"
    );
    let main_len = fs::metadata(&database_path).expect("main stat").len();
    let wal_len = fs::metadata(&wal_path).expect("wal stat").len();
    assert!(main_len > 0, "崩溃后主库不应为 0 字节：{main_len}");
    assert!(wal_len > 0, "崩溃后应遗留非空 WAL：{wal_len}");
    println!("zero-byte-wal: crash-state main={main_len} wal={wal_len}");

    // 模拟外部截断/异常状态：主库被截断为 0 字节，但保留非空 WAL。
    fs::write(&database_path, b"").expect("truncate main db to zero bytes");
    let main_sha_before = file_sha256(&database_path).expect("main sha before");
    let wal_sha_before = file_sha256(&wal_path).expect("wal sha before");

    let error = Database::initialize(&paths).expect_err("0 字节主库 + WAL 必须 fail-closed");
    assert_eq!(
        error.code(),
        "database-empty-existing-file",
        "actual: {} ({error})",
        error.code()
    );
    assert!(
        error.to_string().contains("WAL"),
        "错误消息必须说明残留 WAL 不会被 SQLite 打开/丢弃：{error}"
    );
    println!(
        "zero-byte-wal: code={} main_sha256={main_sha_before} wal_sha256={wal_sha_before}",
        error.code()
    );

    // 主文件与 WAL 都必须原样保留：SQLite 打开 0 字节主库会删除 WAL，必须避免。
    assert_eq!(
        fs::metadata(&database_path).expect("main stat after").len(),
        0,
        "主文件必须保持 0 字节"
    );
    assert_eq!(
        file_sha256(&database_path).expect("main sha after"),
        main_sha_before,
        "主文件 SHA-256 必须保持不变"
    );
    assert!(wal_path.is_file(), "残留 WAL 不得被删除");
    assert_eq!(
        file_sha256(&wal_path).expect("wal sha after"),
        wal_sha_before,
        "残留 WAL SHA-256 必须保持不变"
    );
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "不得留下半初始化临时数据库"
    );
}

#[test]
fn main_database_missing_but_wal_leftover_fails_closed() {
    let dir = TestDir::new("orphaned-wal");
    let paths = dir.release_paths();
    let database_path = paths.database_file().to_path_buf();
    let wal_path = sidecar_path(&database_path, "-wal");

    // 制造崩溃后的 WAL 状态，然后删除主库（模拟主文件被外部删除/丢失）。
    let mut child = spawn_crash_wal_writer(&database_path);
    let status = child.wait().expect("wait crash writer");
    assert_eq!(status.code(), Some(9), "子进程必须以崩溃模拟退出码 9 结束");
    assert!(fs::metadata(&wal_path).expect("wal stat").len() > 0);
    fs::remove_file(&database_path).expect("simulate lost main database file");
    assert!(!database_path.exists());
    let wal_sha_before = file_sha256(&wal_path).expect("wal sha before");
    let wal_size_before = fs::metadata(&wal_path).expect("wal stat").len();
    println!(
        "orphaned-wal: main_missing=true wal_size={wal_size_before} wal_sha256={wal_sha_before}"
    );

    let error = Database::initialize(&paths).expect_err("主库缺失 + 残留 WAL 必须 fail-closed");
    assert_eq!(
        error.code(),
        "database-orphaned-sidecar",
        "actual: {} ({error})",
        error.code()
    );
    assert!(
        error.to_string().contains("WAL"),
        "错误消息必须说明残留 WAL：{error}"
    );
    assert!(
        !database_path.exists(),
        "不得创建新的正式数据库文件（不得当作首次安装）"
    );
    assert!(wal_path.is_file(), "残留 WAL 不得被删除");
    assert_eq!(
        file_sha256(&wal_path).expect("wal sha after"),
        wal_sha_before,
        "残留 WAL SHA-256 必须保持不变"
    );
    assert_eq!(
        fs::metadata(&wal_path).expect("wal stat after").len(),
        wal_size_before,
        "残留 WAL 大小必须保持不变"
    );
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "不得留下半初始化临时数据库"
    );
}

#[test]
fn main_database_missing_but_journal_leftover_fails_closed() {
    let dir = TestDir::new("orphaned-journal");
    let paths = dir.release_paths();
    let database_path = paths.database_file().to_path_buf();
    let journal_path = sidecar_path(&database_path, "-journal");
    let journal_bytes = b"fictional hot-journal bytes that must not be deleted or misused";
    fs::write(&journal_path, journal_bytes).expect("write fictitious journal leftover");
    let journal_sha_before = file_sha256(&journal_path).expect("journal sha");
    println!(
        "orphaned-journal: main_missing=true journal_size={} journal_sha256={journal_sha_before}",
        journal_bytes.len()
    );

    let error = Database::initialize(&paths).expect_err("主库缺失 + 残留 journal 必须 fail-closed");
    assert_eq!(
        error.code(),
        "database-orphaned-sidecar",
        "actual: {} ({error})",
        error.code()
    );
    assert!(
        error.to_string().contains("journal"),
        "错误消息必须说明残留 journal：{error}"
    );
    assert!(!database_path.exists(), "不得当作首次安装创建新数据库");
    assert_eq!(
        file_sha256(&journal_path).expect("journal sha after"),
        journal_sha_before,
        "残留 journal 必须原样保留"
    );
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "不得留下半初始化临时数据库"
    );
}

#[test]
fn stale_shm_without_database_is_cleaned_before_first_initialization() {
    let dir = TestDir::new("stale-shm");
    let paths = dir.release_paths();
    let database_path = paths.database_file().to_path_buf();
    let shm_path = sidecar_path(&database_path, "-shm");

    // 孤立的 -shm 只是运行时共享内存索引，不含已提交数据；首次初始化应在持锁后清理它。
    fs::write(&shm_path, vec![0xAB_u8; 32_768]).expect("write stale shm fixture");
    println!(
        "stale-shm: stale_shm_size={} main_missing=true",
        fs::metadata(&shm_path).expect("shm stat").len()
    );

    let database = Database::initialize(&paths).expect("孤立 SHM 不应阻止首次初始化");
    assert!(database.created_new());
    assert_eq!(database.schema_version().expect("schema version"), 1);
    let health = database.health_report().expect("health");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.journal_mode, "wal");
    println!("stale-shm: initialized created_new=true schema=1 integrity=ok journal_mode=wal");
}
