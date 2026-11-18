//! 数据库生命周期测试：首次初始化、重复启动、重启持久化、WAL 与健康快照。

mod support;

use std::fs;

use support::TestDir;
use workmanager_core::database::BUSY_TIMEOUT_MS;
use workmanager_core::{Database, LATEST_SCHEMA_VERSION};

fn scenario_dir(label: &str) -> TestDir {
    TestDir::new(label)
}

#[test]
fn initializes_empty_database_with_latest_schema_and_safe_pragmas() {
    let dir = scenario_dir("lifecycle-init");
    let paths = dir.release_paths();

    assert!(!paths.database_file.exists(), "初始状态不应存在数据库文件");

    let database = Database::initialize(&paths).expect("首次初始化数据库");
    assert!(database.created_new(), "首次初始化应标记为新建");
    assert_eq!(
        database.schema_version().expect("schema version"),
        LATEST_SCHEMA_VERSION
    );
    assert!(paths.database_file.is_file(), "正式数据库文件必须存在");
    assert!(paths.webview2_dir.is_dir(), "WebView2 数据目录必须已创建");
    assert!(paths.temp_dir.is_dir());
    assert!(paths.backups_dir.is_dir());
    assert!(paths.logs_dir.is_dir());

    let health = database.health_report().expect("健康检查");
    assert_eq!(health.status, "ok");
    assert_eq!(health.schema_version, LATEST_SCHEMA_VERSION);
    assert_eq!(health.latest_schema_version, LATEST_SCHEMA_VERSION);
    assert_eq!(health.integrity_check, "ok");
    assert!(health.foreign_keys, "foreign_keys 必须真实开启");
    assert_eq!(health.journal_mode, "wal");
    assert_eq!(health.synchronous, 2, "synchronous 必须为 FULL");
    assert_eq!(health.busy_timeout_ms, i64::from(BUSY_TIMEOUT_MS));
    assert_eq!(health.temp_store, 2, "temp_store 必须为 MEMORY");
    assert_eq!(health.foreign_key_violations, 0);
    assert!(health.database_file_size_bytes > 0);
    assert_eq!(
        health.applied_migrations.len(),
        LATEST_SCHEMA_VERSION as usize
    );
    assert_eq!(health.applied_migrations[0].version, 1);
    assert_eq!(
        health.applied_migrations[1].version, 2,
        "T1-02 必须应用 0002_projects"
    );
    assert!(health.database_path.ends_with("work.db"));

    let migration_rows: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .expect("migration 行数");
    assert_eq!(migration_rows, LATEST_SCHEMA_VERSION);

    let settings_rows: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM settings", [], |row| row.get(0))
        .expect("settings 行数");
    assert_eq!(settings_rows, 0, "T1-01 不写入未确认的默认业务设置");
}

#[test]
fn repeated_initialize_is_idempotent_and_does_not_rerun_migrations() {
    let dir = scenario_dir("lifecycle-repeat");
    let paths = dir.release_paths();

    let first_health = {
        let database = Database::initialize(&paths).expect("首次初始化");
        assert!(database.created_new());
        database.health_report().expect("首次健康检查")
    };
    assert_eq!(
        first_health.applied_migrations.len(),
        LATEST_SCHEMA_VERSION as usize
    );
    let first_applied_at = first_health.applied_migrations[0].applied_at.clone();

    // 模拟应用关闭后再次启动。
    let second_health = {
        let database = Database::initialize(&paths).expect("再次打开数据库");
        assert!(!database.created_new(), "再次启动不应重新创建数据库");
        database.health_report().expect("再次健康检查")
    };

    assert_eq!(second_health.schema_version, first_health.schema_version);
    assert_eq!(second_health.integrity_check, "ok");
    // migration 不得重复执行：applied_at 与记录数都应保持不变。
    assert_eq!(
        second_health.applied_migrations.len(),
        LATEST_SCHEMA_VERSION as usize
    );
    assert_eq!(
        second_health.applied_migrations[0].applied_at,
        first_applied_at
    );
}

#[test]
fn data_persists_across_restart() {
    let dir = scenario_dir("lifecycle-persist");
    let paths = dir.release_paths();

    {
        let database = Database::initialize(&paths).expect("首次初始化");
        database
            .connection()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-canary', '{\"marker\":\"fictional-restart-canary\"}', '2026-11-17T00:00:00Z')",
                [],
            )
            .expect("写入虚构 canary 数据");
    }

    {
        let database = Database::initialize(&paths).expect("重启后打开数据库");
        assert!(!database.created_new());
        let value: String = database
            .connection()
            .query_row(
                "SELECT value_json FROM settings WHERE key = 'test-canary'",
                [],
                |row| row.get(0),
            )
            .expect("重启后仍应读到 canary 数据");
        assert_eq!(value, "{\"marker\":\"fictional-restart-canary\"}");
        assert_eq!(
            database.schema_version().expect("schema version"),
            LATEST_SCHEMA_VERSION
        );
    }
}

#[test]
fn clean_shutdown_checkpoints_wal_and_keeps_single_valid_database_file() {
    let dir = scenario_dir("lifecycle-wal");
    let paths = dir.release_paths();

    {
        let database = Database::initialize(&paths).expect("首次初始化");
        database
            .connection()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-wal-canary', '{\"marker\":\"wal\"}', '2026-11-17T00:00:00Z')",
                [],
            )
            .expect("写入 WAL 数据");
        let health = database.health_report().expect("健康检查");
        assert_eq!(health.journal_mode, "wal");
    }

    // 连接正常关闭后，WAL/SHM 应被 checkpoint 并删除，数据全部回到主文件。
    let wal_path = std::path::PathBuf::from(format!("{}-wal", paths.database_file.display()));
    let shm_path = std::path::PathBuf::from(format!("{}-shm", paths.database_file.display()));
    assert!(
        !wal_path.exists() || fs::metadata(&wal_path).map(|m| m.len()).unwrap_or(0) == 0,
        "正常关闭后不应遗留有数据的 WAL：{}",
        wal_path.display()
    );
    assert!(
        !shm_path.exists() || fs::metadata(&shm_path).map(|m| m.len()).unwrap_or(0) == 0,
        "正常关闭后不应遗留 SHM：{}",
        shm_path.display()
    );

    // 用独立只读连接证明主文件自身完整可读（数据不只存在于 WAL）。
    let read_only = rusqlite::Connection::open_with_flags(
        &paths.database_file,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("只读打开数据库");
    let integrity: String = read_only
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .expect("只读完整性检查");
    assert_eq!(integrity, "ok");
    let canary: String = read_only
        .query_row(
            "SELECT value_json FROM settings WHERE key = 'test-wal-canary'",
            [],
            |row| row.get(0),
        )
        .expect("只读读取 canary");
    assert_eq!(canary, "{\"marker\":\"wal\"}");
}

#[test]
fn health_check_is_read_only_and_does_not_change_schema_version() {
    let dir = scenario_dir("lifecycle-health");
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("首次初始化");

    for _ in 0..3 {
        let health = database.health_report().expect("健康检查");
        assert_eq!(health.status, "ok");
        assert_eq!(health.schema_version, LATEST_SCHEMA_VERSION);
    }
    assert_eq!(
        database.schema_version().expect("schema version"),
        LATEST_SCHEMA_VERSION
    );
}
