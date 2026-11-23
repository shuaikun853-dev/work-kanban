//! T1-03 schema 2 → 3 migration 专项测试。
//!
//! 重点验证：
//! - 从已有 schema 2 数据库升级到 schema 3，原有项目数据（含归档项目）完整保留；
//! - `user_version` 前进到 3、`schema_migrations` 追加且只追加 0003；
//! - 已是最新版本时重复打开安全（不重复执行 migration）；
//! - 注入迁移失败时事务回滚：`user_version` 停在 2，不留 `work_items` 半成品表；
//! - 新表约束（STRICT、外键 RESTRICT、状态/评分 CHECK）真实生效。

mod support;

use rusqlite::{Connection, params};
use support::TestDir;
use workmanager_core::database::{apply_migrations, read_schema_version};
use workmanager_core::{Database, DatabaseError, LATEST_SCHEMA_VERSION, MIGRATIONS, PortablePaths};

const ACTIVE_PROJECT_ID: &str = "11111111-1111-4111-8111-111111111111";
const ARCHIVED_PROJECT_ID: &str = "22222222-2222-4222-8222-222222222222";

fn table_exists(connection: &Connection, table: &str) -> bool {
    let count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get(0),
        )
        .expect("sqlite_master 查询");
    count > 0
}

/// 构造一个真实 schema 2 数据库（0001 + 0002），并写入两个虚构项目：
/// 一个未归档、一个已归档，用于验证升级后数据保留。
fn prepare_schema_two_database(paths: &PortablePaths) {
    let mut connection = Connection::open(paths.database_file()).expect("打开 schema 2 测试数据库");
    apply_migrations(&mut connection, paths.database_file(), &MIGRATIONS[..2], 2)
        .expect("应用 0001/0002 migration");
    assert_eq!(
        read_schema_version(&connection, paths.database_file()).expect("schema version"),
        2
    );

    connection
        .execute(
            "INSERT INTO projects (id, name, is_archived, created_at, updated_at) \
             VALUES (?1, ?2, 0, ?3, ?3)",
            params![
                ACTIVE_PROJECT_ID,
                "虚构保留项目",
                "2026-11-18T02:00:00.000Z"
            ],
        )
        .expect("写入未归档项目");
    connection
        .execute(
            "INSERT INTO projects (id, name, is_archived, created_at, updated_at) \
             VALUES (?1, ?2, 1, ?3, ?3)",
            params![
                ARCHIVED_PROJECT_ID,
                "虚构归档保留项目",
                "2026-11-18T03:00:00.000Z"
            ],
        )
        .expect("写入归档项目");
    drop(connection);
}

#[test]
fn upgrades_real_schema_two_database_and_preserves_projects() {
    let dir = TestDir::new("work-items-migration-upgrade");
    let paths = dir.release_paths();
    prepare_schema_two_database(&paths);

    let database = Database::initialize(&paths).expect("打开并升级 schema 2 数据库");
    assert_eq!(database.schema_version().expect("schema version"), 3);
    assert_eq!(LATEST_SCHEMA_VERSION, 3);

    // 项目数据完整保留，归档标记不变。
    let projects: Vec<(String, String, i64)> = {
        let mut statement = database
            .connection()
            .prepare("SELECT id, name, is_archived FROM projects ORDER BY created_at")
            .expect("查询项目");
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .expect("读取项目")
            .collect::<Result<_, _>>()
            .expect("收集项目")
    };
    assert_eq!(projects.len(), 2, "升级不得丢失或复制项目记录");
    assert_eq!(
        projects[0],
        (ACTIVE_PROJECT_ID.to_string(), "虚构保留项目".to_string(), 0)
    );
    assert_eq!(
        projects[1],
        (
            ARCHIVED_PROJECT_ID.to_string(),
            "虚构归档保留项目".to_string(),
            1
        )
    );

    // 新表存在且为空。
    assert!(table_exists(database.connection(), "work_items"));
    let work_item_count: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM work_items", [], |row| row.get(0))
        .expect("count work_items");
    assert_eq!(work_item_count, 0);

    // migration 记录追加到 3 条。
    let migrations: Vec<i64> = {
        let mut statement = database
            .connection()
            .prepare("SELECT version FROM schema_migrations ORDER BY version")
            .expect("查询 migration 记录");
        statement
            .query_map([], |row| row.get(0))
            .expect("读取 migration 版本")
            .collect::<Result<_, _>>()
            .expect("收集 migration 版本")
    };
    assert_eq!(migrations, vec![1, 2, 3]);

    database.check_foreign_keys().expect("升级后外键检查");
    let health = database.health_report().expect("升级后健康检查");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.schema_version, 3);
}

#[test]
fn reopening_latest_schema_does_not_reapply_migrations_or_lose_data() {
    let dir = TestDir::new("work-items-migration-reopen");
    let paths = dir.release_paths();
    prepare_schema_two_database(&paths);

    let database = Database::initialize(&paths).expect("首次升级");
    drop(database);

    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("再次打开最新 schema");
    assert_eq!(database.schema_version().expect("schema version"), 3);

    let migration_count: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .expect("migration 记录数");
    assert_eq!(migration_count, 3, "重复打开不得重复执行 migration");
    let project_count: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM projects", [], |row| row.get(0))
        .expect("项目数");
    assert_eq!(project_count, 2, "重复打开不得丢失项目数据");
}

#[test]
fn injected_work_items_migration_failure_rolls_back_and_keeps_schema_two() {
    let dir = TestDir::new("work-items-migration-rollback");
    let paths = dir.release_paths();
    prepare_schema_two_database(&paths);

    let mut connection = Connection::open(paths.database_file()).expect("打开 schema 2 数据库");
    let broken_migration = workmanager_core::Migration {
        version: 3,
        name: "0003-broken-work-items",
        // 模拟 0003 在创建表后执行失败：空标题违反 CHECK，整个事务必须回滚。
        sql: "CREATE TABLE work_items (\
                  id TEXT PRIMARY KEY NOT NULL,\
                  title TEXT NOT NULL CHECK (length(trim(title)) > 0),\
                  created_at TEXT NOT NULL,\
                  updated_at TEXT NOT NULL\
              ) STRICT;\n\
              INSERT INTO work_items (id, title, created_at, updated_at) \
              VALUES ('broken-id', '   ', '2026-11-19T00:00:00.000Z', '2026-11-19T00:00:00.000Z');",
    };
    let migrations = [MIGRATIONS[0], MIGRATIONS[1], broken_migration];

    let error = apply_migrations(&mut connection, paths.database_file(), &migrations, 3)
        .expect_err("注入的 0003 必须失败");
    match error {
        DatabaseError::MigrationFailed { version, .. } => assert_eq!(version, 3),
        other => panic!("期望 migration-failed，实际：{other:?}"),
    }

    assert_eq!(
        read_schema_version(&connection, paths.database_file()).expect("schema version"),
        2,
        "失败 migration 的 user_version 不得前进"
    );
    assert!(
        !table_exists(&connection, "work_items"),
        "失败 migration 中已执行的 CREATE TABLE 必须回滚"
    );
    assert!(
        table_exists(&connection, "projects"),
        "已提交的 0002 必须保留"
    );
    let migration_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .expect("migration 记录数");
    assert_eq!(
        migration_count, 2,
        "失败 migration 不得写入 schema_migrations"
    );
    let project_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM projects", [], |row| row.get(0))
        .expect("项目数");
    assert_eq!(project_count, 2, "失败 migration 不得丢失原有项目");

    // 数据库仍可正常升级。
    drop(connection);
    let database = Database::initialize(&paths).expect("回滚后重新升级");
    assert_eq!(database.schema_version().expect("schema version"), 3);
}

#[test]
fn work_items_table_enforces_strict_schema_constraints() {
    let dir = TestDir::new("work-items-schema-constraints");
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化数据库");

    let table_sql: String = database
        .connection()
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'work_items'",
            [],
            |row| row.get(0),
        )
        .expect("读取 work_items DDL");
    assert!(
        table_sql.to_uppercase().contains("STRICT"),
        "work_items 必须是 STRICT 表：{table_sql}"
    );
    assert!(
        table_sql.to_uppercase().contains("ON DELETE RESTRICT"),
        "project_id 外键禁止级联删除：{table_sql}"
    );

    let connection = database.connection();

    // 状态 CHECK：未知状态被拒绝。
    let error = connection
        .execute(
            "INSERT INTO work_items (id, title, lifecycle_status, created_at, updated_at) \
             VALUES ('status-id', '虚构标题', 'unknown-status', 't', 't')",
            [],
        )
        .expect_err("未知生命周期状态必须被数据库拒绝");
    assert!(
        error.to_string().contains("CHECK"),
        "期望 CHECK 约束失败：{error}"
    );

    // 标题 CHECK：纯空白标题即使绕过 Core 也被拒绝。
    connection
        .execute(
            "INSERT INTO work_items (id, title, created_at, updated_at) \
             VALUES ('blank-title-id', '   ', 't', 't')",
            [],
        )
        .expect_err("空白标题必须被数据库拒绝");

    // importance / urgency 只允许 1–5 或 NULL。
    for (importance, urgency) in [
        (Some(0_i64), None),
        (Some(6), None),
        (None, Some(0)),
        (None, Some(6)),
    ] {
        let error = connection
            .execute(
                "INSERT INTO work_items \
                     (id, title, importance, urgency, created_at, updated_at) \
                 VALUES (?1, '虚构标题', ?2, ?3, 't', 't')",
                params![
                    format!("range-{importance:?}-{urgency:?}"),
                    importance,
                    urgency
                ],
            )
            .expect_err("越界评分必须被拒绝");
        assert!(error.to_string().contains("CHECK"));
    }
    connection
        .execute(
            "INSERT INTO work_items (id, title, importance, urgency, created_at, updated_at) \
             VALUES ('valid-range', '虚构标题', 1, 5, 't', 't')",
            [],
        )
        .expect("1–5 边界值允许");

    // 未指定状态时默认 pending（数据库层兜底）。
    let default_status: String = connection
        .query_row(
            "SELECT lifecycle_status FROM work_items WHERE id = 'valid-range'",
            [],
            |row| row.get(0),
        )
        .expect("读取默认状态");
    assert_eq!(default_status, "pending");
}
