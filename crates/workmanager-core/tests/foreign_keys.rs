//! 外键约束测试：证明生产连接上 `PRAGMA foreign_keys` 真实生效，
//! 包括插入违规拒绝、合法插入、级联删除与外键违规检查。

mod support;

use support::TestDir;
use workmanager_core::Database;

#[test]
fn foreign_keys_are_really_enforced_on_production_connection() {
    let dir = TestDir::new("foreign-keys");
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化数据库");
    let connection = database.connection();

    let enabled: i64 = connection
        .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
        .expect("读取 foreign_keys");
    assert_eq!(enabled, 1, "生产连接必须开启 foreign_keys");

    connection
        .execute_batch(
            "CREATE TABLE fk_parent (id INTEGER PRIMARY KEY);
             CREATE TABLE fk_child (
                 id INTEGER PRIMARY KEY,
                 parent_id INTEGER NOT NULL REFERENCES fk_parent(id) ON DELETE CASCADE
             );",
        )
        .expect("创建外键测试表");

    // 引用不存在的父行必须被拒绝。
    let insert_error = connection
        .execute("INSERT INTO fk_child (id, parent_id) VALUES (1, 999)", [])
        .expect_err("外键违规必须被拒绝");
    assert!(
        insert_error
            .to_string()
            .to_lowercase()
            .contains("foreign key"),
        "错误信息应说明外键约束失败，实际：{insert_error}"
    );

    let child_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM fk_child", [], |row| row.get(0))
        .expect("统计子表行数");
    assert_eq!(child_count, 0, "违规插入不得留下数据");

    // 合法数据可以写入。
    connection
        .execute("INSERT INTO fk_parent (id) VALUES (999)", [])
        .expect("插入父行");
    connection
        .execute("INSERT INTO fk_child (id, parent_id) VALUES (1, 999)", [])
        .expect("插入合法子行");

    database.check_foreign_keys().expect("外键检查应通过");

    // ON DELETE CASCADE 真实生效。
    connection
        .execute("DELETE FROM fk_parent WHERE id = 999", [])
        .expect("删除父行");
    let child_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM fk_child", [], |row| row.get(0))
        .expect("统计子表行数");
    assert_eq!(child_count, 0, "父行删除后子行应被级联删除");
}

#[test]
fn foreign_key_check_detects_violations_written_while_enforcement_disabled() {
    let dir = TestDir::new("foreign-keys-check");
    let paths = dir.release_paths();

    {
        let database = Database::initialize(&paths).expect("初始化数据库");
        let connection = database.connection();
        connection
            .execute_batch(
                "CREATE TABLE fk_violation_parent (id INTEGER PRIMARY KEY);
                 CREATE TABLE fk_violation_child (
                     id INTEGER PRIMARY KEY,
                     parent_id INTEGER NOT NULL REFERENCES fk_violation_parent(id)
                 );
                 PRAGMA foreign_keys = OFF;
                 INSERT INTO fk_violation_child (id, parent_id) VALUES (1, 999);
                 PRAGMA foreign_keys = ON;",
            )
            .expect("构造外键违规数据");
        let error = database
            .check_foreign_keys()
            .expect_err("外键检查必须发现违规");
        assert_eq!(error.code(), "database-foreign-key-violations");
    }

    // 再次启动时，启动流程应拒绝带外键违规的数据库（fail-closed）。
    let error = Database::initialize(&paths).expect_err("存在外键违规时必须 fail-closed");
    assert_eq!(error.code(), "database-foreign-key-violations");
}
