//! T1-04 schema 3 → 4 migration 与创建组约束专项测试。
//!
//! 重点验证：
//! - 从已有 schema 3 数据库（含项目与工作事项）升级到 schema 4，原有数据完整保留；
//! - `user_version` 前进到 4、`schema_migrations` 追加且只追加 0004；
//! - 已是最新版本时重复打开安全（不重复执行 migration）；
//! - 注入 0004 迁移失败时事务回滚：`user_version` 停在 3，不留半成品表；
//! - 创建组 / 成员关系表的 STRICT、外键、唯一约束与删除行为真实生效：
//!   同一工作事项最多属于一个创建组；删除工作事项只清除自身成员关系，
//!   删除创建组只清除成员关系，均不得连带删除其他工作副本。

mod support;

use rusqlite::{Connection, params};
use support::TestDir;
use workmanager_core::database::{apply_migrations, read_schema_version};
use workmanager_core::{Database, DatabaseError, LATEST_SCHEMA_VERSION, MIGRATIONS, PortablePaths};

const PROJECT_A_ID: &str = "11111111-1111-4111-8111-111111111111";
const PROJECT_B_ID: &str = "22222222-2222-4222-8222-222222222222";
const WORK_ITEM_1: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1";
const WORK_ITEM_2: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2";
const GROUP_1: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1";
const GROUP_2: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2";

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

/// 构造真实 schema 3 数据库（0001 + 0002 + 0003）并写入两个虚构项目与两条工作事项。
fn prepare_schema_three_database(paths: &PortablePaths) {
    let mut connection = Connection::open(paths.database_file()).expect("打开 schema 3 测试数据库");
    apply_migrations(&mut connection, paths.database_file(), &MIGRATIONS[..3], 3)
        .expect("应用 0001/0002/0003 migration");
    assert_eq!(
        read_schema_version(&connection, paths.database_file()).expect("schema version"),
        3
    );

    for (id, name, archived) in [
        (PROJECT_A_ID, "虚构保留项目甲", 0_i64),
        (PROJECT_B_ID, "虚构保留项目乙", 1),
    ] {
        connection
            .execute(
                "INSERT INTO projects (id, name, is_archived, created_at, updated_at) \
                 VALUES (?1, ?2, ?3, '2026-11-24T01:00:00.000Z', '2026-11-24T01:00:00.000Z')",
                params![id, name, archived],
            )
            .expect("写入 schema 3 项目");
    }
    for (id, project_id, title, status) in [
        (WORK_ITEM_1, Some(PROJECT_A_ID), "虚构保留工作一", "pending"),
        (WORK_ITEM_2, None, "虚构保留工作二", "in_progress"),
    ] {
        connection
            .execute(
                "INSERT INTO work_items \
                     (id, project_id, title, lifecycle_status, created_at, updated_at) \
                 VALUES (?1, ?2, ?3, ?4, '2026-11-24T02:00:00.000Z', '2026-11-24T02:00:00.000Z')",
                params![id, project_id, title, status],
            )
            .expect("写入 schema 3 工作事项");
    }
    drop(connection);
}

fn read_scalar_i64(connection: &Connection, sql: &str) -> i64 {
    connection
        .query_row(sql, [], |row| row.get(0))
        .expect("标量查询")
}

/// 从真实 0004 migration SQL 中提取第一个 CREATE INDEX 的索引名称。
///
/// 测试不得硬编码索引名：索引名称必须来自即将由真实 migration 引擎执行的 SQL，
/// 否则修改 migration 后测试可能悄悄失去冲突覆盖。
fn first_create_index_name(sql: &str) -> String {
    let marker = "CREATE INDEX";
    let start = sql
        .find(marker)
        .unwrap_or_else(|| panic!("真实 0004 migration 必须包含 CREATE INDEX：{sql}"))
        + marker.len();
    let name = sql[start..]
        .trim_start()
        .split(|character: char| character.is_whitespace() || character == ';')
        .next()
        .unwrap_or_else(|| panic!("CREATE INDEX 后必须存在索引名称：{sql}"))
        .trim_matches('"')
        .to_string();
    assert!(!name.is_empty(), "真实 0004 migration 索引名称不得为空");
    name
}

/// schema 3 历史数据与 migration 记录快照（逐行字符串比较，避免只比较行数）。
fn snapshot_schema_three_rows(connection: &Connection) -> Vec<String> {
    let mut snapshot = Vec::new();
    for sql in [
        "SELECT id || '|' || name || '|' || is_archived || '|' || created_at || '|' || updated_at \
         FROM projects ORDER BY id",
        "SELECT id || '|' || COALESCE(project_id, '<null>') || '|' || title || '|' || \
                lifecycle_status || '|' || COALESCE(importance, '<null>') || '|' || \
                COALESCE(urgency, '<null>') || '|' || COALESCE(due_date, '<null>') || '|' || \
                COALESCE(description, '<null>') || '|' || created_at || '|' || updated_at \
         FROM work_items ORDER BY id",
        "SELECT version || '|' || name || '|' || applied_at \
         FROM schema_migrations ORDER BY version",
    ] {
        let mut statement = connection.prepare(sql).expect("准备 schema 3 快照查询");
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("执行 schema 3 快照查询")
            .collect::<Result<Vec<_>, _>>()
            .expect("收集 schema 3 快照");
        snapshot.extend(rows);
    }
    snapshot
}

#[test]
fn upgrades_real_schema_three_database_and_preserves_existing_rows() {
    let dir = TestDir::new("creation-groups-migration-upgrade");
    let paths = dir.release_paths();
    prepare_schema_three_database(&paths);

    let database = Database::initialize(&paths).expect("打开并升级 schema 3 数据库");
    assert_eq!(database.schema_version().expect("schema version"), 4);
    assert_eq!(LATEST_SCHEMA_VERSION, 4);

    // 项目与 work_items 数据完整保留（含归档项目与已存在状态）。
    let projects: Vec<(String, String, i64)> = {
        let mut statement = database
            .connection()
            .prepare("SELECT id, name, is_archived FROM projects ORDER BY created_at, id")
            .expect("查询项目");
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .expect("读取项目")
            .collect::<Result<_, _>>()
            .expect("收集项目")
    };
    assert_eq!(projects.len(), 2);
    assert_eq!(
        projects[0],
        (PROJECT_A_ID.to_string(), "虚构保留项目甲".to_string(), 0)
    );
    assert_eq!(
        projects[1],
        (PROJECT_B_ID.to_string(), "虚构保留项目乙".to_string(), 1)
    );

    let work_items: Vec<(String, Option<String>, String, String)> = {
        let mut statement = database
            .connection()
            .prepare("SELECT id, project_id, title, lifecycle_status FROM work_items ORDER BY id")
            .expect("查询工作事项");
        statement
            .query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .expect("读取工作事项")
            .collect::<Result<_, _>>()
            .expect("收集工作事项")
    };
    assert_eq!(work_items.len(), 2, "升级不得丢失或复制工作事项");
    assert_eq!(
        work_items[0],
        (
            WORK_ITEM_1.to_string(),
            Some(PROJECT_A_ID.to_string()),
            "虚构保留工作一".to_string(),
            "pending".to_string()
        )
    );
    assert_eq!(
        work_items[1],
        (
            WORK_ITEM_2.to_string(),
            None,
            "虚构保留工作二".to_string(),
            "in_progress".to_string()
        )
    );

    // 新表存在且为空。
    assert!(table_exists(
        database.connection(),
        "work_item_creation_groups"
    ));
    assert!(table_exists(
        database.connection(),
        "work_item_creation_group_members"
    ));
    assert_eq!(
        read_scalar_i64(
            database.connection(),
            "SELECT COUNT(*) FROM work_item_creation_groups"
        ),
        0
    );
    assert_eq!(
        read_scalar_i64(
            database.connection(),
            "SELECT COUNT(*) FROM work_item_creation_group_members"
        ),
        0
    );

    // migration 记录追加到 4 条。
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
    assert_eq!(migrations, vec![1, 2, 3, 4]);

    database.check_foreign_keys().expect("升级后外键检查");
    let health = database.health_report().expect("升级后健康检查");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.schema_version, 4);
}

#[test]
fn reopening_latest_schema_does_not_reapply_migration_or_lose_data() {
    let dir = TestDir::new("creation-groups-migration-reopen");
    let paths = dir.release_paths();
    prepare_schema_three_database(&paths);

    let database = Database::initialize(&paths).expect("首次升级");
    drop(database);

    let database = Database::initialize(&dir.release_paths()).expect("再次打开最新 schema");
    assert_eq!(database.schema_version().expect("schema version"), 4);
    assert_eq!(
        read_scalar_i64(
            database.connection(),
            "SELECT COUNT(*) FROM schema_migrations"
        ),
        4,
        "重复打开不得重复执行 migration"
    );
    assert_eq!(
        read_scalar_i64(database.connection(), "SELECT COUNT(*) FROM projects"),
        2
    );
    assert_eq!(
        read_scalar_i64(database.connection(), "SELECT COUNT(*) FROM work_items"),
        2
    );
}

#[test]
fn injected_creation_groups_migration_failure_rolls_back_and_keeps_schema_three() {
    let dir = TestDir::new("creation-groups-migration-rollback");
    let paths = dir.release_paths();
    prepare_schema_three_database(&paths);

    let mut connection = Connection::open(paths.database_file()).expect("打开 schema 3 数据库");
    let broken_migration = workmanager_core::Migration {
        version: 4,
        name: "0004-broken-creation-groups",
        // 模拟 0004 在创建两张表后执行失败：空白 source_title 违反 CHECK，整个事务必须回滚。
        sql: "CREATE TABLE work_item_creation_groups (\
                  id TEXT PRIMARY KEY NOT NULL,\
                  source_title TEXT NOT NULL CHECK (length(trim(source_title)) > 0),\
                  created_at TEXT NOT NULL\
              ) STRICT;\
              CREATE TABLE work_item_creation_group_members (\
                  group_id TEXT NOT NULL,\
                  work_item_id TEXT NOT NULL,\
                  PRIMARY KEY (group_id, work_item_id)\
              ) STRICT;\
              INSERT INTO work_item_creation_groups (id, source_title, created_at) \
              VALUES ('broken-group', '   ', '2026-11-24T00:00:00.000Z');",
    };
    let migrations = [
        MIGRATIONS[0],
        MIGRATIONS[1],
        MIGRATIONS[2],
        broken_migration,
    ];

    let error = apply_migrations(&mut connection, paths.database_file(), &migrations, 4)
        .expect_err("注入的 0004 必须失败");
    match error {
        DatabaseError::MigrationFailed { version, .. } => assert_eq!(version, 4),
        other => panic!("期望 migration-failed，实际：{other:?}"),
    }

    assert_eq!(
        read_schema_version(&connection, paths.database_file()).expect("schema version"),
        3,
        "失败 migration 的 user_version 不得前进"
    );
    assert!(
        !table_exists(&connection, "work_item_creation_groups"),
        "失败 migration 中已执行的 CREATE TABLE 必须回滚"
    );
    assert!(
        !table_exists(&connection, "work_item_creation_group_members"),
        "失败 migration 中已执行的 CREATE TABLE 必须回滚"
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM schema_migrations"),
        3
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM work_items"),
        2,
        "失败 migration 不得丢失既有工作事项"
    );

    // 数据库仍可正常升级到 4。
    drop(connection);
    let database = Database::initialize(&paths).expect("回滚后重新升级");
    assert_eq!(database.schema_version().expect("schema version"), 4);
    assert!(table_exists(
        database.connection(),
        "work_item_creation_groups"
    ));
}

#[test]
fn real_0004_migration_failure_rolls_back_all_changes() {
    let dir = TestDir::new("creation-groups-migration-real-0004-failure");
    let paths = dir.release_paths();
    prepare_schema_three_database(&paths);

    let mut connection = Connection::open(paths.database_file()).expect("打开 schema 3 数据库");
    let real_migration = MIGRATIONS[3];
    assert_eq!(real_migration.version, 4);
    let conflicting_index_name = first_create_index_name(real_migration.sql);

    // 预先创建与真实 0004 索引同名的冲突索引。真实 0004 会先成功创建两张新表，
    // 然后在 CREATE INDEX 处因名称冲突失败；整个 migration 事务必须回滚。
    connection
        .execute(
            &format!("CREATE INDEX \"{conflicting_index_name}\" ON projects(name)"),
            [],
        )
        .expect("创建与真实 0004 同名的冲突索引");
    let before = snapshot_schema_three_rows(&connection);

    let error = apply_migrations(
        &mut connection,
        paths.database_file(),
        MIGRATIONS,
        LATEST_SCHEMA_VERSION,
    )
    .expect_err("真实 0004 migration 必须因索引名称冲突而失败");
    match error {
        DatabaseError::MigrationFailed { version, name, .. } => {
            assert_eq!(version, 4);
            assert_eq!(name, "0004_work_item_creation_groups");
        }
        other => panic!("期望 migration-failed，实际：{other:?}"),
    }

    assert_eq!(
        read_schema_version(&connection, paths.database_file()).expect("schema version"),
        3,
        "失败 migration 的 user_version 不得前进"
    );
    assert!(
        !table_exists(&connection, "work_item_creation_groups"),
        "真实 0004 在索引失败前创建的第一个新表必须随事务回滚"
    );
    assert!(
        !table_exists(&connection, "work_item_creation_group_members"),
        "真实 0004 在索引失败前创建的第二个新表必须随事务回滚"
    );
    assert_eq!(
        read_scalar_i64(
            &connection,
            "SELECT COUNT(*) FROM schema_migrations WHERE version = 4"
        ),
        0,
        "失败 migration 不得写入 version 4 记录"
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM schema_migrations"),
        3,
        "既有 migration 记录不得增加或丢失"
    );
    assert_eq!(
        snapshot_schema_three_rows(&connection),
        before,
        "失败 migration 必须保持历史项目、工作事项与 migration 记录逐行不变"
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM projects"),
        2,
        "失败 migration 不得丢失历史项目"
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM work_items"),
        2,
        "失败 migration 不得丢失历史工作事项"
    );

    // 删除测试冲突索引后，真实 migration 引擎必须能够正常升级至 schema 4。
    connection
        .execute(&format!("DROP INDEX \"{conflicting_index_name}\""), [])
        .expect("删除测试冲突索引");

    let outcome = apply_migrations(
        &mut connection,
        paths.database_file(),
        MIGRATIONS,
        LATEST_SCHEMA_VERSION,
    )
    .expect("移除冲突索引后真实 0004 migration 必须成功");
    assert_eq!(outcome.previous_version, 3);
    assert_eq!(outcome.current_version, 4);
    assert_eq!(outcome.applied_versions, vec![4]);
    assert_eq!(
        read_schema_version(&connection, paths.database_file()).expect("升级后 schema version"),
        4
    );
    assert!(table_exists(&connection, "work_item_creation_groups"));
    assert!(table_exists(
        &connection,
        "work_item_creation_group_members"
    ));
    assert_eq!(
        read_scalar_i64(
            &connection,
            &format!(
                "SELECT COUNT(*) FROM sqlite_master \
                 WHERE type = 'index' AND name = '{conflicting_index_name}'"
            )
        ),
        1,
        "冲突索引删除后，真实 0004 必须重新创建同名索引"
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM schema_migrations"),
        4
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM projects"),
        2
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM work_items"),
        2
    );
    assert_eq!(
        read_scalar_i64(
            &connection,
            "SELECT COUNT(*) FROM work_items WHERE lifecycle_status = 'in_progress'"
        ),
        1,
        "历史工作事项状态不得被 migration 改写"
    );
    assert_eq!(
        read_scalar_i64(
            &connection,
            "SELECT COUNT(*) FROM projects WHERE is_archived = 1"
        ),
        1,
        "历史项目归档状态不得被 migration 改写"
    );
    assert_eq!(
        read_scalar_i64(
            &connection,
            "SELECT COUNT(*) FROM pragma_integrity_check WHERE integrity_check != 'ok'"
        ),
        0,
        "升级后 integrity_check 必须为 ok"
    );
    assert_eq!(
        read_scalar_i64(&connection, "SELECT COUNT(*) FROM pragma_foreign_key_check"),
        0,
        "升级后不得存在外键违规"
    );
}

#[test]
fn creation_group_tables_enforce_strict_foreign_key_and_unique_constraints() {
    let dir = TestDir::new("creation-groups-schema-constraints");
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化数据库");
    let connection = database.connection();

    for table in [
        "work_item_creation_groups",
        "work_item_creation_group_members",
    ] {
        let table_sql: String = connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |row| row.get(0),
            )
            .expect("读取创建组 DDL");
        assert!(
            table_sql.to_uppercase().contains("STRICT"),
            "{table} 必须是 STRICT 表：{table_sql}"
        );
    }
    let members_sql: String = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' \
             AND name = 'work_item_creation_group_members'",
            [],
            |row| row.get(0),
        )
        .expect("读取成员表 DDL");
    assert!(
        members_sql.to_uppercase().contains("ON DELETE CASCADE"),
        "成员关系外键必须只级联成员关系本身：{members_sql}"
    );
    assert!(
        members_sql.to_uppercase().contains("UNIQUE"),
        "work_item_id 必须有唯一约束（每个工作事项最多一个创建组）：{members_sql}"
    );

    // 空白来源标题被拒绝。
    connection
        .execute(
            "INSERT INTO work_item_creation_groups (id, source_title, created_at) \
             VALUES (?1, '   ', '2026-11-24T00:00:00.000Z')",
            params![GROUP_1],
        )
        .expect_err("空白 source_title 必须被 CHECK 拒绝");

    // 准备真实项目与两个工作事项。
    for (id, name) in [
        (PROJECT_A_ID, "虚构约束项目甲"),
        (PROJECT_B_ID, "虚构约束项目乙"),
    ] {
        connection
            .execute(
                "INSERT INTO projects (id, name, is_archived, created_at, updated_at) \
                 VALUES (?1, ?2, 0, 't', 't')",
                params![id, name],
            )
            .expect("写入项目");
    }
    for (id, project_id) in [(WORK_ITEM_1, PROJECT_A_ID), (WORK_ITEM_2, PROJECT_B_ID)] {
        connection
            .execute(
                "INSERT INTO work_items (id, project_id, title, created_at, updated_at) \
                 VALUES (?1, ?2, '虚构约束工作', 't', 't')",
                params![id, project_id],
            )
            .expect("写入工作事项");
    }
    for (id, title) in [(GROUP_1, "虚构批次一"), (GROUP_2, "虚构批次二")] {
        connection
            .execute(
                "INSERT INTO work_item_creation_groups (id, source_title, created_at) \
                 VALUES (?1, ?2, 't')",
                params![id, title],
            )
            .expect("写入创建组");
    }

    // 成员关系引用不存在的工作事项 / 创建组必须被外键拒绝。
    connection
        .execute(
            "INSERT INTO work_item_creation_group_members (group_id, work_item_id) \
             VALUES (?1, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc')",
            params![GROUP_1],
        )
        .expect_err("不存在的工作事项必须被外键拒绝");
    connection
        .execute(
            "INSERT INTO work_item_creation_group_members (group_id, work_item_id) \
             VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', ?1)",
            params![WORK_ITEM_1],
        )
        .expect_err("不存在的创建组必须被外键拒绝");

    // 正常成员关系。
    connection
        .execute(
            "INSERT INTO work_item_creation_group_members (group_id, work_item_id) \
             VALUES (?1, ?2)",
            params![GROUP_1, WORK_ITEM_1],
        )
        .expect("写入成员关系");
    connection
        .execute(
            "INSERT INTO work_item_creation_group_members (group_id, work_item_id) \
             VALUES (?1, ?2)",
            params![GROUP_1, WORK_ITEM_2],
        )
        .expect("写入同组第二个成员关系");

    // 同一工作事项不得属于第二个创建组。
    connection
        .execute(
            "INSERT INTO work_item_creation_group_members (group_id, work_item_id) \
             VALUES (?1, ?2)",
            params![GROUP_2, WORK_ITEM_1],
        )
        .expect_err("同一工作事项最多属于一个创建组");
    assert_eq!(
        read_scalar_i64(
            connection,
            "SELECT COUNT(*) FROM work_item_creation_group_members"
        ),
        2
    );

    // 删除单个工作事项：只清除该事项自身成员关系；同组其他副本与创建组保留。
    connection
        .execute("DELETE FROM work_items WHERE id = ?1", params![WORK_ITEM_1])
        .expect("删除单个工作事项");
    assert_eq!(
        read_scalar_i64(
            connection,
            "SELECT COUNT(*) FROM work_item_creation_group_members"
        ),
        1,
        "只允许清除被删除工作事项自身的成员关联"
    );
    assert_eq!(
        read_scalar_i64(connection, "SELECT COUNT(*) FROM work_items"),
        1,
        "不得连带删除其他工作副本"
    );
    assert_eq!(
        read_scalar_i64(connection, "SELECT COUNT(*) FROM work_item_creation_groups"),
        2,
        "不得连带删除创建组"
    );
    assert_eq!(
        read_scalar_i64(
            connection,
            &format!(
                "SELECT COUNT(*) FROM work_item_creation_group_members WHERE work_item_id = '{WORK_ITEM_1}'"
            )
        ),
        0,
        "被删除工作事项的成员关系已清除"
    );

    // 删除创建组：只清除成员关系，不删除工作副本。
    connection
        .execute(
            "DELETE FROM work_item_creation_groups WHERE id = ?1",
            params![GROUP_1],
        )
        .expect("删除创建组");
    assert_eq!(
        read_scalar_i64(
            connection,
            "SELECT COUNT(*) FROM work_item_creation_group_members"
        ),
        0,
        "删除创建组只清除成员关系"
    );
    assert_eq!(
        read_scalar_i64(connection, "SELECT COUNT(*) FROM work_items"),
        1,
        "删除创建组不得删除工作副本"
    );

    database.check_foreign_keys().expect("约束测试后外键检查");
}

#[test]
fn creation_group_tables_only_add_expected_business_tables() {
    let dir = TestDir::new("creation-groups-table-scope");
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
            "settings".to_string(),
            "work_item_creation_group_members".to_string(),
            "work_item_creation_groups".to_string(),
            "work_items".to_string(),
        ],
        "T1-04 只允许新增创建组与成员关系两张表，不得提前创建其他业务表"
    );
}
