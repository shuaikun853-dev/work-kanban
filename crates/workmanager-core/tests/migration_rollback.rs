//! Migration 事务与回滚测试。
//!
//! 重点验证：
//! - migration 失败时该 migration 在事务中回滚，`user_version` 不得前进；
//! - 已提交的旧版本保持不变；
//! - 全新的空库在首个 migration 失败时仍是空 schema；
//! - migration 定义校验与内置 SQL 的事务边界约定。

mod support;

use support::TestDir;
use workmanager_core::database::{Migration, apply_migrations, read_schema_version};
use workmanager_core::{Database, DatabaseError, LATEST_SCHEMA_VERSION, MIGRATIONS};

fn table_exists(connection: &rusqlite::Connection, table: &str) -> bool {
    let count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get(0),
        )
        .expect("sqlite_master 查询");
    count > 0
}

#[test]
fn failed_migration_rolls_back_and_keeps_previous_version() {
    let dir = TestDir::new("migration-rollback");
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化数据库");
    let mut database = database;
    assert_eq!(
        read_schema_version(database.connection(), paths.database_file()).expect("version"),
        LATEST_SCHEMA_VERSION
    );

    // 在最新内置 schema 之后追加自定义 migration：版本 3 成功，版本 4 在创建表后执行失败。
    let migrations = [
        MIGRATIONS[0],
        MIGRATIONS[1],
        Migration {
            version: 3,
            name: "0003-create-test-parent",
            sql: "CREATE TABLE test_parent (id INTEGER PRIMARY KEY);",
        },
        Migration {
            version: 4,
            name: "0004-broken",
            sql: "CREATE TABLE test_child (id INTEGER PRIMARY KEY);\n\
                  INSERT INTO test_child (id, missing_column) VALUES (1, 2);",
        },
    ];

    let error = apply_migrations(
        database.connection_mut(),
        paths.database_file(),
        &migrations,
        4,
    )
    .expect_err("版本 4 必须失败");
    match error {
        DatabaseError::MigrationFailed { version, .. } => assert_eq!(version, 4),
        other => panic!("期望 migration-failed，实际：{other:?}"),
    }

    // 版本 3 已提交，版本 4 完全回滚：user_version 停在 3。
    assert_eq!(
        read_schema_version(database.connection(), paths.database_file()).expect("version"),
        3
    );
    assert!(
        table_exists(database.connection(), "test_parent"),
        "已提交的版本 3 必须保留"
    );
    assert!(
        !table_exists(database.connection(), "test_child"),
        "失败 migration 中已执行的 CREATE TABLE 必须回滚"
    );

    let migration_rows: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .expect("migration 行数");
    assert_eq!(migration_rows, 3, "只应记录已提交的版本 1、2 与 3");

    // 数据库仍然完整可用。
    database.check_foreign_keys().expect("回滚后外键检查");
    let health = database.health_report().expect("回滚后健康检查");
    assert_eq!(health.integrity_check, "ok");

    // 再次执行同一批 migration 仍应失败且版本不变（不会出现部分前进）。
    let second_error = apply_migrations(
        database.connection_mut(),
        paths.database_file(),
        &migrations,
        4,
    )
    .expect_err("再次执行仍必须失败");
    assert!(matches!(
        second_error,
        DatabaseError::MigrationFailed { version: 4, .. }
    ));
    assert_eq!(
        read_schema_version(database.connection(), paths.database_file()).expect("version"),
        3
    );
}

#[test]
fn failure_in_first_migration_leaves_empty_schema_and_version_zero() {
    let dir = TestDir::new("migration-first-failure");
    let database_path = dir.join("empty-init.db");
    let mut connection = rusqlite::Connection::open(&database_path).expect("打开空数据库");
    assert_eq!(
        read_schema_version(&connection, &database_path).expect("version"),
        0
    );

    let migrations = [Migration {
        version: 1,
        name: "0001-broken",
        sql: "CREATE TABLE first_table (id INTEGER PRIMARY KEY);\n\
              INSERT INTO no_such_table VALUES (1);",
    }];

    let error = apply_migrations(&mut connection, &database_path, &migrations, 1)
        .expect_err("首个 migration 必须失败");
    match error {
        DatabaseError::MigrationFailed { version, .. } => assert_eq!(version, 1),
        other => panic!("期望 migration-failed，实际：{other:?}"),
    }

    assert_eq!(
        read_schema_version(&connection, &database_path).expect("version"),
        0,
        "user_version 不得前进"
    );
    assert!(
        !table_exists(&connection, "first_table"),
        "失败 migration 的建表语句必须回滚"
    );
    assert!(
        !table_exists(&connection, "schema_migrations"),
        "失败 migration 不得留下 schema_migrations 表"
    );
}

#[test]
fn invalid_migration_set_is_rejected_before_touching_database() {
    let dir = TestDir::new("migration-invalid-set");
    let database_path = dir.join("empty-invalid.db");
    let mut connection = rusqlite::Connection::open(&database_path).expect("打开空数据库");

    // 版本不连续。
    let non_contiguous = [
        Migration {
            version: 1,
            name: "0001",
            sql: "CREATE TABLE a (id INTEGER PRIMARY KEY);",
        },
        Migration {
            version: 3,
            name: "0003",
            sql: "CREATE TABLE c (id INTEGER PRIMARY KEY);",
        },
    ];
    let error = apply_migrations(&mut connection, &database_path, &non_contiguous, 2)
        .expect_err("版本不连续必须被拒绝");
    assert_eq!(error.code(), "migration-definition-invalid");

    // latest 与定义数量不一致。
    let mismatched_latest = [Migration {
        version: 1,
        name: "0001",
        sql: "CREATE TABLE a (id INTEGER PRIMARY KEY);",
    }];
    let error = apply_migrations(&mut connection, &database_path, &mismatched_latest, 2)
        .expect_err("latest 不一致必须被拒绝");
    assert_eq!(error.code(), "migration-definition-invalid");

    // 非法定义不得改动数据库。
    assert_eq!(
        read_schema_version(&connection, &database_path).expect("version"),
        0
    );
    assert!(!table_exists(&connection, "a"));
}

#[test]
fn embedded_migrations_do_not_manage_transactions() {
    for migration in MIGRATIONS {
        let statements: String = migration
            .sql
            .lines()
            .map(|line| line.trim_start())
            .filter(|line| !line.starts_with("--"))
            .collect::<Vec<_>>()
            .join("\n")
            .to_uppercase();
        for keyword in ["BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT"] {
            assert!(
                !statements.contains(keyword),
                "migration {}（{}）不得包含事务控制语句 {keyword}；事务由 Rust 引擎负责",
                migration.version,
                migration.name
            );
        }
    }
}

#[test]
fn latest_schema_creates_projects_table_but_no_premature_business_tables() {
    let dir = TestDir::new("migration-scope");
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化数据库");

    let mut statement = database
        .connection()
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .expect("查询表列表");
    let tables: Vec<String> = statement
        .query_map([], |row| row.get(0))
        .expect("读取表列表")
        .collect::<Result<_, _>>()
        .expect("收集表列表");

    assert_eq!(
        tables,
        vec![
            "projects".to_string(),
            "schema_migrations".to_string(),
            "settings".to_string()
        ],
        "T1-02 只新增 projects 表，不得提前创建工作事项等业务表"
    );

    for business_table in ["work_items", "daily_plans", "daily_reviews", "attachments"] {
        assert!(
            !tables.contains(&business_table.to_string()),
            "T1-02 不得提前创建未授权业务表 {business_table}"
        );
    }
}
