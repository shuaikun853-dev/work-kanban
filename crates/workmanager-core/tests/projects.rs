//! T1-02 项目领域集成测试。
//!
//! 覆盖任务要求的核心行为：
//! - 创建 / 查询 / 编辑 / 归档项目；
//! - 归档不删除项目记录、不删除已有历史关联；
//! - 重启后数据保持；
//! - 多项目互不污染；
//! - schema version 1 → 2 migration 升级与失败回滚；
//! - 非法输入边界；
//! - 数据库完整性与外键检查。
//!
//! 测试数据全部为虚构内容，存放于 D 盘隔离测试目录。

mod support;

use rusqlite::params;
use support::TestDir;
use uuid::Uuid;
use workmanager_core::database::{Migration, apply_migrations, read_schema_version};
use workmanager_core::{
    Database, DatabaseError, LATEST_SCHEMA_VERSION, MIGRATIONS, ProjectError, ProjectService,
};

fn open_database(label: &str) -> (TestDir, workmanager_core::PortablePaths, Database) {
    let dir = TestDir::new(label);
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化测试数据库");
    (dir, paths, database)
}

fn count_projects(database: &Database) -> i64 {
    database
        .connection()
        .query_row("SELECT COUNT(*) FROM projects", [], |row| row.get(0))
        .expect("统计项目行数")
}

fn project_name(database: &Database, project_id: &str) -> String {
    database
        .connection()
        .query_row(
            "SELECT name FROM projects WHERE id = ?1",
            [project_id],
            |row| row.get(0),
        )
        .expect("读取项目名称")
}

#[test]
fn creates_and_lists_project_with_stable_core_generated_id() {
    let (_dir, _paths, mut database) = open_database("projects-create-list");

    let created = ProjectService::create(&mut database, "  中核商品价格异常排查  ")
        .expect("创建项目必须成功");
    assert_eq!(created.name, "中核商品价格异常排查", "名称应去除首尾空白");
    assert!(!created.is_archived);
    assert_eq!(created.created_at, created.updated_at);
    Uuid::parse_str(&created.id).expect("项目 ID 必须是稳定 UUID");
    assert!(
        created.created_at.ends_with('Z'),
        "时间字段必须是 UTC RFC3339"
    );

    let listed = ProjectService::list(&database).expect("查询项目列表");
    assert_eq!(listed, vec![created]);
}

#[test]
fn persists_project_across_restart() {
    let dir = TestDir::new("projects-persist");
    let paths = dir.release_paths();

    let created = {
        let mut database = Database::initialize(&paths).expect("初始化数据库");
        ProjectService::create(&mut database, "跨重启保持的项目").expect("创建项目")
    };

    // 模拟应用重启：释放连接后重新初始化。
    let database = Database::initialize(&paths).expect("重启后打开数据库");
    assert!(!database.created_new(), "重启不得重新创建数据库");
    let projects = ProjectService::list(&database).expect("重启后查询项目");
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0].id, created.id);
    assert_eq!(projects[0].name, "跨重启保持的项目");
}

#[test]
fn updates_project_name_and_keeps_identity() {
    let (_dir, _paths, mut database) = open_database("projects-update");

    let created = ProjectService::create(&mut database, "旧项目名称").expect("创建项目");
    std::thread::sleep(std::time::Duration::from_millis(5));

    let updated = ProjectService::update(&mut database, &created.id, "  新项目名称  ")
        .expect("编辑项目必须成功");
    assert_eq!(updated.id, created.id, "编辑不得改变项目 ID");
    assert_eq!(updated.name, "新项目名称");
    assert_eq!(updated.created_at, created.created_at, "创建时间必须保持");
    assert!(
        updated.updated_at > created.updated_at,
        "更新时间必须前进：{} -> {}",
        created.updated_at,
        updated.updated_at
    );
    assert_eq!(project_name(&database, &created.id), "新项目名称");
}

#[test]
fn archives_project_without_deleting_record() {
    let (_dir, _paths, mut database) = open_database("projects-archive");

    let created = ProjectService::create(&mut database, "待归档项目").expect("创建项目");
    std::thread::sleep(std::time::Duration::from_millis(5));

    let archived = ProjectService::archive(&mut database, &created.id).expect("归档项目必须成功");
    assert_eq!(archived.id, created.id, "归档不得改变项目 ID");
    assert_eq!(archived.name, created.name, "归档不得改变项目名称");
    assert_eq!(archived.created_at, created.created_at);
    assert!(archived.is_archived, "归档项目必须带归档标记");
    assert!(
        archived.updated_at > created.updated_at,
        "归档必须更新更新时间"
    );
    assert_eq!(count_projects(&database), 1, "归档不得删除项目记录");

    let listed = ProjectService::list(&database).expect("归档后仍可查询");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, created.id);
    assert!(listed[0].is_archived);
}

#[test]
fn archiving_is_idempotent_and_keeps_original_archive_timestamp() {
    let (_dir, _paths, mut database) = open_database("projects-archive-idempotent");

    let created = ProjectService::create(&mut database, "重复归档项目").expect("创建项目");
    let first = ProjectService::archive(&mut database, &created.id).expect("第一次归档");
    std::thread::sleep(std::time::Duration::from_millis(5));
    let second = ProjectService::archive(&mut database, &created.id).expect("第二次归档");

    assert_eq!(second.id, first.id);
    assert!(second.is_archived);
    assert_eq!(
        second.updated_at, first.updated_at,
        "重复归档不得刷新归档时间"
    );
    assert_eq!(count_projects(&database), 1);
}

#[test]
fn archive_does_not_delete_existing_history_associations() {
    let (_dir, _paths, mut database) = open_database("projects-archive-history");

    let created = ProjectService::create(&mut database, "有关联历史的项目").expect("创建项目");

    // 用测试专用表模拟未来工作事项对项目的历史关联（T1-03 才会建立正式表）。
    // 只验证 T1-02 归档行为：UPDATE 标记，不 DELETE 项目，不触发级联删除。
    database
        .connection()
        .execute_batch(
            "CREATE TABLE project_history_probe (
                 id         INTEGER PRIMARY KEY,
                 project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
                 note       TEXT NOT NULL
             );
             INSERT INTO project_history_probe (id, project_id, note)
             VALUES (1, (SELECT id FROM projects LIMIT 1), '虚构历史关联');",
        )
        .expect("创建历史关联探针");

    let archived = ProjectService::archive(&mut database, &created.id).expect("归档项目");
    assert!(archived.is_archived);

    let history_rows: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM project_history_probe", [], |row| {
            row.get(0)
        })
        .expect("统计历史关联");
    assert_eq!(history_rows, 1, "归档不得删除已有历史关联");

    let linked_project_id: String = database
        .connection()
        .query_row(
            "SELECT project_id FROM project_history_probe WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .expect("读取历史关联");
    assert_eq!(linked_project_id, created.id);

    database
        .check_foreign_keys()
        .expect("归档后外键检查必须通过");
    let health = database.health_report().expect("归档后健康检查");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.foreign_key_violations, 0);
}

#[test]
fn multiple_projects_are_isolated() {
    let (_dir, _paths, mut database) = open_database("projects-isolation");

    let alpha = ProjectService::create(&mut database, "项目 Alpha").expect("创建 Alpha");
    let beta = ProjectService::create(&mut database, "项目 Beta").expect("创建 Beta");

    let updated_alpha = ProjectService::update(&mut database, &alpha.id, "项目 Alpha（已编辑）")
        .expect("编辑 Alpha");
    let archived_beta = ProjectService::archive(&mut database, &beta.id).expect("归档 Beta");

    assert_eq!(updated_alpha.name, "项目 Alpha（已编辑）");
    assert!(!updated_alpha.is_archived);
    assert_eq!(archived_beta.name, "项目 Beta");
    assert!(archived_beta.is_archived);
    assert_ne!(updated_alpha.id, archived_beta.id);

    let listed = ProjectService::list(&database).expect("查询全部项目");
    assert_eq!(listed.len(), 2);
    // 未归档项目必须排在归档项目之前。
    assert_eq!(listed[0].id, alpha.id);
    assert_eq!(listed[1].id, beta.id);
    assert_eq!(count_projects(&database), 2);
}

#[test]
fn rejects_empty_names_without_writing_rows() {
    let (_dir, _paths, mut database) = open_database("projects-invalid-name");

    for raw in ["", "   ", "\t\n", "\u{3000}"] {
        let error = ProjectService::create(&mut database, raw).expect_err("空白名称必须被拒绝");
        assert_eq!(error.code(), "project-name-empty");
    }
    assert_eq!(count_projects(&database), 0, "非法输入不得产生项目记录");

    let created = ProjectService::create(&mut database, "有效项目").expect("创建有效项目");
    let error = ProjectService::update(&mut database, &created.id, "   ")
        .expect_err("编辑为空名称必须被拒绝");
    assert_eq!(error.code(), "project-name-empty");
    assert_eq!(project_name(&database, &created.id), "有效项目");
}

#[test]
fn rejects_unknown_project_ids() {
    let (_dir, _paths, mut database) = open_database("projects-unknown-id");
    let unknown = Uuid::new_v4().to_string();

    let update_error =
        ProjectService::update(&mut database, &unknown, "任意名称").expect_err("未知项目不可编辑");
    assert_eq!(update_error.code(), "project-not-found");

    let archive_error =
        ProjectService::archive(&mut database, &unknown).expect_err("未知项目不可归档");
    assert_eq!(archive_error.code(), "project-not-found");
    assert_eq!(count_projects(&database), 0);
}

#[test]
fn rejects_editing_archived_project() {
    let (_dir, _paths, mut database) = open_database("projects-edit-archived");

    let created = ProjectService::create(&mut database, "归档后不可编辑").expect("创建项目");
    ProjectService::archive(&mut database, &created.id).expect("归档项目");

    let error = ProjectService::update(&mut database, &created.id, "尝试改名")
        .expect_err("已归档项目必须拒绝编辑");
    assert_eq!(error.code(), "project-archived");
    assert_eq!(project_name(&database, &created.id), "归档后不可编辑");
}

#[test]
fn project_write_failure_rolls_back_transaction() {
    let (_dir, _paths, mut database) = open_database("projects-transaction-rollback");

    let created = ProjectService::create(&mut database, "事务回滚项目").expect("创建项目");
    let before = ProjectService::list(&database).expect("查询项目")[0].clone();

    // 注入失败：更新项目时必须 ABORT，验证写事务回滚且不留部分更新。
    database
        .connection()
        .execute_batch(
            "CREATE TRIGGER fail_project_update
             BEFORE UPDATE ON projects
             BEGIN
                 SELECT RAISE(ABORT, 'injected project update failure');
             END;",
        )
        .expect("注入失败触发器");

    let error = ProjectService::update(&mut database, &created.id, "不应写入的名称")
        .expect_err("注入失败后编辑必须失败");
    let ProjectError::Database(DatabaseError::Sqlite { .. }) = &error else {
        panic!("期望数据库结构化错误，实际：{error:?}");
    };

    database
        .connection()
        .execute_batch("DROP TRIGGER fail_project_update;")
        .expect("移除失败触发器");

    let after = ProjectService::list(&database).expect("再次查询项目");
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].name, before.name, "失败编辑不得部分写入名称");
    assert_eq!(
        after[0].updated_at, before.updated_at,
        "失败编辑不得推进更新时间"
    );
    assert_eq!(after[0].id, created.id);
}

#[test]
fn new_database_runs_all_migrations_and_integrity_checks() {
    let (_dir, paths, database) = open_database("projects-new-schema");

    assert_eq!(
        database.schema_version().expect("schema 版本"),
        LATEST_SCHEMA_VERSION
    );
    assert_eq!(LATEST_SCHEMA_VERSION, 3, "T1-03 引入 schema version 3");
    let health = database.health_report().expect("健康检查");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.foreign_key_violations, 0);
    assert_eq!(health.applied_migrations.len(), 3);
    assert_eq!(
        health
            .applied_migrations
            .iter()
            .map(|migration| migration.version)
            .collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
    assert_eq!(health.applied_migrations[1].name, "0002_projects");
    assert_eq!(health.applied_migrations[2].name, "0003_work_items");

    let tables: Vec<String> = database
        .connection()
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .expect("查询表列表")
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
            "work_items".to_string()
        ],
        "T1-03 只新增 work_items 表，不得提前创建其他业务表"
    );
    assert!(
        paths.database_file.is_file(),
        "正式数据库文件必须存在：{}",
        paths.database_file.display()
    );
}

#[test]
fn upgrades_schema_version_1_database_and_preserves_existing_data() {
    let dir = TestDir::new("projects-upgrade-v1");
    let paths = dir.release_paths();
    let database_path = paths.database_file.clone();
    assert!(!database_path.exists(), "前置条件：数据库尚不存在");

    // 构造 T1-01 的 schema version 1 数据库（使用内嵌的 0001 migration SQL）。
    {
        let connection = rusqlite::Connection::open(&database_path).expect("创建 v1 数据库");
        connection
            .execute_batch(MIGRATIONS[0].sql)
            .expect("执行 0001 migration SQL");
        connection
            .execute(
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?1, ?2, ?3)",
                params![1, "0001_initial_foundation", "2026-11-18T00:00:00Z"],
            )
            .expect("记录 v1 migration");
        connection
            .pragma_update(None, "user_version", 1)
            .expect("设置 user_version=1");
        connection
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) \
                 VALUES ('test-canary', '{\"marker\":\"v1-upgrade\"}', '2026-11-18T00:00:00Z')",
                [],
            )
            .expect("写入虚构 v1 canary");
        assert_eq!(
            read_schema_version(&connection, &database_path).expect("读取 v1 版本"),
            1
        );
    }

    // 应用启动时应按顺序升级到最新 schema，并保留 v1 数据。
    let mut database = Database::initialize(&paths).expect("v1 数据库必须可升级");
    assert!(!database.created_new(), "已有数据库不得被当作新库覆盖");
    assert_eq!(
        database.schema_version().expect("升级后版本"),
        LATEST_SCHEMA_VERSION
    );

    let canary: String = database
        .connection()
        .query_row(
            "SELECT value_json FROM settings WHERE key = 'test-canary'",
            [],
            |row| row.get(0),
        )
        .expect("v1 canary 必须保留");
    assert_eq!(canary, "{\"marker\":\"v1-upgrade\"}");

    let health = database.health_report().expect("升级后健康检查");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.foreign_key_violations, 0);
    assert_eq!(health.schema_version, 3);
    assert_eq!(health.applied_migrations.len(), 3);

    // 升级后的数据库必须可正常创建项目。
    let project = ProjectService::create(&mut database, "升级后新建项目").expect("创建项目");
    assert_eq!(ProjectService::list(&database).expect("查询项目").len(), 1);
    assert_eq!(project.name, "升级后新建项目");
}

#[test]
fn failed_migration_after_projects_rolls_back_without_touching_project_data() {
    let (_dir, paths, mut database) = open_database("projects-migration-rollback");
    let created = ProjectService::create(&mut database, "迁移失败前的项目").expect("创建项目");

    // 在 v3 基础上追加一个“先建表、后失败”的 v4 migration。
    let migrations = [
        MIGRATIONS[0],
        MIGRATIONS[1],
        MIGRATIONS[2],
        Migration {
            version: 4,
            name: "0004-broken-probe",
            sql: "CREATE TABLE migration_probe (id INTEGER PRIMARY KEY);\n\
                  INSERT INTO migration_probe (id, missing_column) VALUES (1, 2);",
        },
    ];
    let error = apply_migrations(
        database.connection_mut(),
        paths.database_file(),
        &migrations,
        4,
    )
    .expect_err("损坏 migration 必须失败");
    assert!(matches!(
        error,
        DatabaseError::MigrationFailed { version: 4, .. }
    ));

    assert_eq!(
        read_schema_version(database.connection(), paths.database_file()).expect("版本"),
        3,
        "失败 migration 不得前进 user_version"
    );
    let probe_count: i64 = database
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'migration_probe'",
            [],
            |row| row.get(0),
        )
        .expect("查询失败 migration 的建表结果");
    assert_eq!(probe_count, 0, "失败 migration 的建表语句必须回滚");

    let projects = ProjectService::list(&database).expect("迁移失败后项目数据必须仍可读");
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0].id, created.id);
    let health = database.health_report().expect("迁移失败后健康检查");
    assert_eq!(health.integrity_check, "ok");
}

#[test]
fn project_operations_keep_integrity_and_foreign_key_checks_clean() {
    let (_dir, paths, mut database) = open_database("projects-integrity");

    let first = ProjectService::create(&mut database, "完整性项目 A").expect("创建 A");
    let second = ProjectService::create(&mut database, "完整性项目 B").expect("创建 B");
    ProjectService::update(&mut database, &first.id, "完整性项目 A（编辑）").expect("编辑 A");
    ProjectService::archive(&mut database, &second.id).expect("归档 B");

    let health = database.health_report().expect("健康检查");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.foreign_key_violations, 0);
    assert_eq!(health.journal_mode, "wal");
    assert_eq!(health.schema_version, LATEST_SCHEMA_VERSION);
    database.check_foreign_keys().expect("外键检查必须通过");

    // 重启后再次检查，证明归档/编辑结果已持久化且数据库仍完整。
    drop(database);
    let database = Database::initialize(&paths).expect("重启数据库");
    let health = database.health_report().expect("重启后健康检查");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.foreign_key_violations, 0);
    let listed = ProjectService::list(&database).expect("重启后查询");
    assert_eq!(listed.len(), 2);
    assert!(!listed[0].is_archived, "未归档项目应排在列表前面");
    assert_eq!(listed[0].id, first.id);
    assert!(listed[1].is_archived, "归档项目应排在列表末尾");
    assert_eq!(listed[1].id, second.id);

    // 时间戳格式用于前端展示：UTC RFC3339。
    assert!(listed[0].updated_at.ends_with('Z'));
}
