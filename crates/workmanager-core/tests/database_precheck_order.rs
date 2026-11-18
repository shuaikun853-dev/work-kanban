//! 审计返工 P2：已有数据库的预检查顺序。
//!
//! 修复前：打开已有数据库后立刻设置 `journal_mode=WAL`（持久化设置），再做
//! 版本/完整性检查，导致被拒绝的数据库可能被无必要地修改。
//!
//! 修复后顺序：打开连接 → 读取 schema 版本 → 完整性检查 → 外键数据检查 →
//! 兼容性判断 → 只有健康且兼容才应用运行期 PRAGMA → migration → 复查完整性。
//!
//! 本文件验证：DELETE 日志模式的“未来版本”数据库与“损坏”数据库在拒绝启动时
//! 文件 SHA-256 完全不变、journal_mode 仍为 DELETE、数据内容完整。

mod support;

use std::fs;

use support::{TestDir, file_sha256, init_temp_files, sidecar_path};
use workmanager_core::Database;

fn read_journal_mode(database_path: &std::path::Path) -> String {
    let connection = rusqlite::Connection::open_with_flags(
        database_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("read-only open for journal_mode");
    let mode: String = connection
        .query_row("PRAGMA journal_mode", [], |row| row.get(0))
        .expect("read journal_mode");
    mode.to_lowercase()
}

fn read_user_version(database_path: &std::path::Path) -> i64 {
    let connection = rusqlite::Connection::open_with_flags(
        database_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("read-only open for user_version");
    connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("read user_version")
}

#[test]
fn version_too_new_delete_mode_database_is_not_modified() {
    let dir = TestDir::new("precheck-version-too-new");
    let paths = dir.release_paths();
    let database_path = paths.database_file().to_path_buf();

    // 构造 DELETE 日志模式、user_version=999、含虚构数据的已有数据库。
    {
        let connection = rusqlite::Connection::open(&database_path).expect("create delete-mode db");
        connection
            .execute_batch(
                "CREATE TABLE app_state (
                     id INTEGER PRIMARY KEY,
                     note TEXT NOT NULL
                 );
                 INSERT INTO app_state (id, note) VALUES (1, 'fictional-precheck-row');
                 PRAGMA user_version=999;",
            )
            .expect("prepare future-version database");
        let mode: String = connection
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .expect("journal mode");
        assert_eq!(
            mode.to_lowercase(),
            "delete",
            "前置条件：必须是 DELETE 模式"
        );
    }
    assert!(!sidecar_path(&database_path, "-wal").exists());
    let sha_before = file_sha256(&database_path).expect("sha before");
    let size_before = fs::metadata(&database_path).expect("stat").len();
    println!(
        "precheck-version-too-new: before sha256={sha_before} size={size_before} journal_mode=delete user_version=999"
    );

    let error = Database::initialize(&paths).expect_err("未来版本必须 fail-closed");
    assert_eq!(
        error.code(),
        "schema-version-too-new",
        "actual: {} ({error})",
        error.code()
    );

    // 文件字节级不变：不得因为提前设置 WAL 等持久化设置而修改数据库。
    assert_eq!(
        file_sha256(&database_path).expect("sha after"),
        sha_before,
        "被拒绝的数据库 SHA-256 必须保持不变"
    );
    assert_eq!(
        fs::metadata(&database_path).expect("stat after").len(),
        size_before,
        "被拒绝的数据库文件大小必须保持不变"
    );
    assert_eq!(
        read_journal_mode(&database_path),
        "delete",
        "journal_mode 必须仍为 DELETE（不得被提前改为 WAL）"
    );
    assert_eq!(
        read_user_version(&database_path),
        999,
        "user_version 必须保持 999"
    );
    assert!(
        !sidecar_path(&database_path, "-wal").exists(),
        "拒绝启动时不得创建 WAL 文件"
    );
    assert!(
        !sidecar_path(&database_path, "-journal").exists(),
        "拒绝启动时不得创建 journal 文件"
    );
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "不得留下初始化临时文件"
    );

    // 数据内容完整：只读查询确认虚构数据仍在。
    let connection = rusqlite::Connection::open_with_flags(
        &database_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("read-only open");
    let note: String = connection
        .query_row("SELECT note FROM app_state WHERE id = 1", [], |row| {
            row.get(0)
        })
        .expect("data must still exist");
    assert_eq!(note, "fictional-precheck-row");
}

#[test]
fn corrupted_delete_mode_database_is_not_modified_by_prechecks() {
    let dir = TestDir::new("precheck-corrupt-delete");
    let paths = dir.release_paths();
    let database_path = paths.database_file().to_path_buf();

    // 构造 DELETE 模式、多页的合法数据库。
    {
        let connection = rusqlite::Connection::open(&database_path).expect("create delete-mode db");
        connection
            .execute_batch(
                "CREATE TABLE corrupt_probe (id INTEGER PRIMARY KEY, payload TEXT NOT NULL);
                 PRAGMA user_version=1;",
            )
            .expect("prepare schema");
        let payload = "虚构损坏测试数据".repeat(40_000);
        connection
            .execute(
                "INSERT INTO corrupt_probe (id, payload) VALUES (1, ?1)",
                [payload],
            )
            .expect("insert large fictional payload");
        let mode: String = connection
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .expect("journal mode");
        assert_eq!(
            mode.to_lowercase(),
            "delete",
            "前置条件：必须是 DELETE 模式"
        );
    }

    // 破坏中间页（保留 page 1 header，使版本读取可能成功，完整性检查必然失败）。
    let mut bytes = fs::read(&database_path).expect("read db bytes");
    assert!(bytes.len() > 12_288, "数据库应包含多个页：{}", bytes.len());
    let start = 4_096 * 2;
    let end = (start + 4_096).min(bytes.len());
    for byte in &mut bytes[start..end] {
        *byte = 0xFF;
    }
    fs::write(&database_path, &bytes).expect("write corrupted db");

    let sha_before = file_sha256(&database_path).expect("sha before");
    let size_before = fs::metadata(&database_path).expect("stat").len();
    println!(
        "precheck-corrupt-delete: before sha256={sha_before} size={size_before} journal_mode=delete"
    );

    let error = Database::initialize(&paths).expect_err("损坏数据库必须 fail-closed");
    assert!(
        matches!(
            error.code(),
            "database-corrupt"
                | "database-not-a-database"
                | "database-open-failed"
                | "database-sqlite-error"
                | "database-integrity-check-failed"
        ),
        "错误码应属于数据库异常分类，实际：{} ({error})",
        error.code()
    );
    println!("precheck-corrupt-delete: code={}", error.code());

    // 损坏数据库在拒绝启动前不得被修改（不得提前设置 WAL、不得写 journal）。
    assert_eq!(
        file_sha256(&database_path).expect("sha after"),
        sha_before,
        "损坏数据库 SHA-256 必须保持不变"
    );
    assert_eq!(
        fs::metadata(&database_path).expect("stat after").len(),
        size_before,
        "损坏数据库文件大小必须保持不变"
    );
    assert!(
        !sidecar_path(&database_path, "-wal").exists(),
        "拒绝启动时不得创建 WAL 文件"
    );
    assert!(
        !sidecar_path(&database_path, "-journal").exists(),
        "拒绝启动时不得创建 journal 文件"
    );
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "不得留下初始化临时文件"
    );
}

#[test]
fn healthy_delete_mode_database_is_upgraded_only_after_passing_prechecks() {
    let dir = TestDir::new("precheck-healthy-delete-upgrade");
    let paths = dir.release_paths();

    // 先由应用创建标准数据库，写入虚构 canary。
    {
        let mut database = Database::initialize(&paths).expect("create database");
        database
            .connection_mut()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-canary', '{\"marker\":\"precheck\"}', '2026-11-17T00:00:00Z')",
                [],
            )
            .expect("insert fictional canary");
    }

    // 把已有数据库切回 DELETE 日志模式（模拟用户/外部工具迁移过的数据库）。
    {
        let connection = rusqlite::Connection::open(paths.database_file()).expect("open db");
        let mode: String = connection
            .query_row("PRAGMA journal_mode = DELETE", [], |row| row.get(0))
            .expect("switch to delete");
        assert_eq!(mode.to_lowercase(), "delete");
    }
    assert_eq!(
        read_journal_mode(paths.database_file()),
        "delete",
        "前置条件：数据库应为 DELETE 模式"
    );

    // 健康且兼容：预检查通过后应升级为 WAL，并保留数据。
    let database = Database::initialize(&paths).expect("healthy delete database must initialize");
    assert!(!database.created_new());
    let health = database.health_report().expect("health");
    assert_eq!(health.journal_mode, "wal");
    assert_eq!(health.schema_version, 1);
    assert_eq!(health.integrity_check, "ok");
    let canary: String = database
        .connection()
        .query_row(
            "SELECT value_json FROM settings WHERE key = 'test-canary'",
            [],
            |row| row.get(0),
        )
        .expect("canary must survive upgrade");
    assert_eq!(canary, "{\"marker\":\"precheck\"}");
    println!(
        "precheck-healthy-delete-upgrade: journal_mode=wal schema_version=1 canary_preserved=true"
    );
}
