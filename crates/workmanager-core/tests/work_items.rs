//! T1-03 工作事项领域集成测试（真实 SQLite + Rust Core）。
//!
//! 覆盖需求：仅标题快速创建、标题规范化、默认待安排、相同标题独立记录、
//! 未归属/关联项目创建、不存在/已归档项目拒绝（DEC-033）、项目归档保留历史关联、
//! 待安排查询只返回 pending、稳定排序、外键限制与并发归档/创建边界。

mod support;

use std::time::Duration;

use rusqlite::params;
use support::TestDir;
use workmanager_core::{Database, ProjectService, WORK_ITEM_STATUS_PENDING, WorkItemService};

fn setup(label: &str) -> (TestDir, Database) {
    let dir = TestDir::new(label);
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化数据库");
    (dir, database)
}

fn scalar_i64(database: &Database, sql: &str) -> i64 {
    database
        .connection()
        .query_row(sql, [], |row| row.get(0))
        .expect("标量查询")
}

fn count_work_items(database: &Database) -> i64 {
    scalar_i64(database, "SELECT COUNT(*) FROM work_items")
}

fn insert_raw_work_item(
    database: &Database,
    id: &str,
    title: &str,
    lifecycle_status: &str,
    created_at: &str,
) {
    database
        .connection()
        .execute(
            "INSERT INTO work_items \
                 (id, project_id, title, lifecycle_status, created_at, updated_at) \
             VALUES (?1, NULL, ?2, ?3, ?4, ?4)",
            params![id, title, lifecycle_status, created_at],
        )
        .expect("写入测试工作事项");
}

#[test]
fn creates_pending_work_item_with_title_only() {
    let (_dir, mut database) = setup("work-items-title-only");
    let work_item = WorkItemService::create(&mut database, "整理中核商品数据", None)
        .expect("仅标题创建工作事项");

    assert!(
        uuid::Uuid::parse_str(&work_item.id).is_ok(),
        "工作事项 ID 必须是 Rust Core 生成的 UUID：{}",
        work_item.id
    );
    assert_eq!(work_item.title, "整理中核商品数据");
    assert_eq!(work_item.lifecycle_status, WORK_ITEM_STATUS_PENDING);
    assert_eq!(work_item.lifecycle_status, "pending");
    assert_eq!(work_item.project_id, None);
    assert_eq!(work_item.importance, None, "未设置字段不得伪造评分");
    assert_eq!(work_item.urgency, None, "未设置字段不得伪造评分");
    assert_eq!(work_item.due_date, None);
    assert_eq!(work_item.description, None);
    assert_eq!(work_item.created_at, work_item.updated_at);
    assert!(
        work_item.created_at.ends_with('Z'),
        "时间戳必须是 UTC RFC3339：{}",
        work_item.created_at
    );

    assert_eq!(count_work_items(&database), 1);
    assert_eq!(
        database
            .connection()
            .query_row(
                "SELECT lifecycle_status FROM work_items WHERE id = ?1",
                params![work_item.id],
                |row| row.get::<_, String>(0)
            )
            .expect("读取状态"),
        "pending"
    );
}

#[test]
fn normalizes_title_surrounding_whitespace_and_keeps_inner_whitespace() {
    let (_dir, mut database) = setup("work-items-title-normalize");
    let work_item = WorkItemService::create(&mut database, "  整理 中核 商品数据 \t", None)
        .expect("规范化标题后创建");
    assert_eq!(work_item.title, "整理 中核 商品数据");
}

#[test]
fn rejects_empty_and_blank_titles_without_writing_rows() {
    let (_dir, mut database) = setup("work-items-title-empty");
    for raw in ["", "   ", "\t", "\n", " \u{3000} "] {
        let error =
            WorkItemService::create(&mut database, raw, None).expect_err("空标题必须被拒绝");
        assert_eq!(error.code(), "work-item-title-empty");
        assert!(
            !error.to_string().contains("中核"),
            "错误消息不得回显用户输入"
        );
    }
    assert_eq!(count_work_items(&database), 0, "拒绝后不得写入记录");
}

#[test]
fn identical_titles_create_distinct_work_items() {
    let (_dir, mut database) = setup("work-items-duplicate-title");
    let first =
        WorkItemService::create(&mut database, "整理中核商品数据", None).expect("第一次创建");
    let second =
        WorkItemService::create(&mut database, "整理中核商品数据", None).expect("第二次创建");

    assert_ne!(first.id, second.id, "相同标题必须产生不同稳定 ID");
    assert_eq!(count_work_items(&database), 2, "不得覆盖旧记录");
    let pending = WorkItemService::list_pending(&database).expect("查询待安排");
    assert_eq!(pending.len(), 2);
    assert!(pending.iter().all(|item| item.title == "整理中核商品数据"));
}

#[test]
fn creates_unassigned_work_item_and_lists_it() {
    let (_dir, mut database) = setup("work-items-unassigned");
    let created =
        WorkItemService::create(&mut database, "未归属的快速工作", None).expect("创建未归属工作");

    let pending = WorkItemService::list_pending(&database).expect("查询待安排");
    assert_eq!(pending.len(), 1);
    let item = &pending[0];
    assert_eq!(item.id, created.id);
    assert_eq!(item.project_id, None);
    assert_eq!(item.project_name, None, "未归属工作不得显示虚构项目名称");
    assert!(!item.project_is_archived);
    assert_eq!(item.lifecycle_status, WORK_ITEM_STATUS_PENDING);
}

#[test]
fn creates_work_item_linked_to_unarchived_project() {
    let (_dir, mut database) = setup("work-items-linked-project");
    let project = ProjectService::create(&mut database, "虚构有效项目").expect("创建项目");
    let created = WorkItemService::create(&mut database, "关联有效项目的工作", Some(&project.id))
        .expect("关联未归档项目创建");

    assert_eq!(created.project_id.as_deref(), Some(project.id.as_str()));
    let pending = WorkItemService::list_pending(&database).expect("查询待安排");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].project_id.as_deref(), Some(project.id.as_str()));
    assert_eq!(pending[0].project_name.as_deref(), Some("虚构有效项目"));
    assert!(!pending[0].project_is_archived);
}

#[test]
fn rejects_unknown_project_id_without_writing_rows() {
    let (_dir, mut database) = setup("work-items-project-missing");
    let error = WorkItemService::create(
        &mut database,
        "不应创建的工作",
        Some("33333333-3333-4333-8333-333333333333"),
    )
    .expect_err("不存在的项目必须被拒绝");
    assert_eq!(error.code(), "project-not-found");
    assert_eq!(count_work_items(&database), 0);
}

#[test]
fn rejects_archived_project_id_without_writing_rows() {
    let (_dir, mut database) = setup("work-items-project-archived");
    let project = ProjectService::create(&mut database, "虚构将归档项目").expect("创建项目");
    ProjectService::archive(&mut database, &project.id).expect("归档项目");

    // T1-02 的 list 契约不变：归档项目仍返回（用于历史展示与设置页管理）。
    let projects = ProjectService::list(&database).expect("项目列表");
    assert_eq!(projects.len(), 1);
    assert!(projects[0].is_archived);

    let error = WorkItemService::create(&mut database, "不应创建的工作", Some(&project.id))
        .expect_err("已归档项目必须被拒绝");
    assert_eq!(error.code(), "project-archived");
    assert_eq!(count_work_items(&database), 0, "拒绝后不得产生新工作关联");
}

#[test]
fn preserves_existing_link_after_project_archived() {
    let (dir, mut database) = setup("work-items-archive-preserves-link");
    let project = ProjectService::create(&mut database, "虚构归档后保留项目").expect("创建项目");
    let created = WorkItemService::create(&mut database, "归档前已关联的工作", Some(&project.id))
        .expect("创建关联工作");
    ProjectService::archive(&mut database, &project.id).expect("归档项目");

    // 关联不被删除或改写。
    let stored_project_id: Option<String> = database
        .connection()
        .query_row(
            "SELECT project_id FROM work_items WHERE id = ?1",
            params![created.id],
            |row| row.get(0),
        )
        .expect("读取工作事项关联");
    assert_eq!(stored_project_id.as_deref(), Some(project.id.as_str()));

    // 待安排列表继续返回该历史工作，并带归档标记。
    let pending = WorkItemService::list_pending(&database).expect("归档后查询待安排");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, created.id);
    assert_eq!(pending[0].project_id.as_deref(), Some(project.id.as_str()));
    assert_eq!(
        pending[0].project_name.as_deref(),
        Some("虚构归档后保留项目")
    );
    assert!(pending[0].project_is_archived);

    // 关闭并重新打开数据库：历史关联与归档标记仍然存在。
    drop(database);
    let database = Database::initialize(&dir.release_paths()).expect("重新打开数据库");
    let pending = WorkItemService::list_pending(&database).expect("重启后查询待安排");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, created.id);
    assert_eq!(pending[0].project_id.as_deref(), Some(project.id.as_str()));
    assert!(pending[0].project_is_archived);
}

#[test]
fn pending_query_excludes_other_lifecycle_statuses() {
    let (_dir, mut database) = setup("work-items-pending-filter");
    insert_raw_work_item(
        &database,
        "id-not-started",
        "虚构未开始",
        "not_started",
        "2026-11-19T01:00:00.000Z",
    );
    insert_raw_work_item(
        &database,
        "id-in-progress",
        "虚构进行中",
        "in_progress",
        "2026-11-19T01:01:00.000Z",
    );
    insert_raw_work_item(
        &database,
        "id-completed",
        "虚构已完成",
        "completed",
        "2026-11-19T01:02:00.000Z",
    );
    insert_raw_work_item(
        &database,
        "id-abandoned",
        "虚构已放弃",
        "abandoned",
        "2026-11-19T01:03:00.000Z",
    );
    let pending = WorkItemService::create(&mut database, "虚构待安排", None).expect("创建待安排");

    let listed = WorkItemService::list_pending(&database).expect("查询待安排");
    assert_eq!(listed.len(), 1, "待安排查询不得混入其他生命周期状态");
    assert_eq!(listed[0].id, pending.id);
    assert!(listed.iter().all(|item| item.lifecycle_status == "pending"));
}

#[test]
fn pending_query_ordering_is_stable() {
    let (_dir, database) = setup("work-items-pending-order");
    insert_raw_work_item(
        &database,
        "id-a",
        "虚构工作 A",
        "pending",
        "2026-11-19T01:00:00.000Z",
    );
    insert_raw_work_item(
        &database,
        "id-c",
        "虚构工作 C",
        "pending",
        "2026-11-19T03:00:00.000Z",
    );
    insert_raw_work_item(
        &database,
        "id-b",
        "虚构工作 B",
        "pending",
        "2026-11-19T03:00:00.000Z",
    );

    let first = WorkItemService::list_pending(&database).expect("第一次查询");
    let ids: Vec<&str> = first.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(
        ids,
        vec!["id-c", "id-b", "id-a"],
        "必须按 created_at DESC, id DESC 稳定排序"
    );
    let second = WorkItemService::list_pending(&database).expect("第二次查询");
    let ids_again: Vec<&str> = second.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(ids, ids_again, "重复查询排序必须稳定");
}

#[test]
fn pending_list_is_empty_on_fresh_database() {
    let (_dir, database) = setup("work-items-empty");
    let pending = WorkItemService::list_pending(&database).expect("查询空待安排");
    assert!(pending.is_empty());
}

#[test]
fn database_persists_work_items_across_reopen() {
    let (dir, mut database) = setup("work-items-persistence");
    let project = ProjectService::create(&mut database, "虚构持久化项目").expect("创建项目");
    let assigned =
        WorkItemService::create(&mut database, "重启后保留的关联工作", Some(&project.id))
            .expect("创建关联工作");
    let unassigned = WorkItemService::create(&mut database, "重启后保留的未归属工作", None)
        .expect("创建未归属工作");

    drop(database);
    let database = Database::initialize(&dir.release_paths()).expect("重新打开数据库");
    let pending = WorkItemService::list_pending(&database).expect("重启后查询待安排");
    assert_eq!(pending.len(), 2);
    let ids: Vec<&str> = pending.iter().map(|item| item.id.as_str()).collect();
    assert!(ids.contains(&assigned.id.as_str()));
    assert!(ids.contains(&unassigned.id.as_str()));
    assert!(
        pending
            .iter()
            .any(|item| item.project_name.as_deref() == Some("虚构持久化项目"))
    );
}

#[test]
fn foreign_keys_restrict_project_deletion_and_invalid_links() {
    let (_dir, mut database) = setup("work-items-foreign-keys");
    let project = ProjectService::create(&mut database, "虚构外键项目").expect("创建项目");
    WorkItemService::create(&mut database, "关联外键项目的工作", Some(&project.id))
        .expect("创建关联工作");

    let delete_error = database
        .connection()
        .execute("DELETE FROM projects WHERE id = ?1", params![project.id])
        .expect_err("有工作关联的项目不得被直接删除");
    assert!(
        delete_error
            .to_string()
            .to_lowercase()
            .contains("foreign key"),
        "期望外键 RESTRICT 错误：{delete_error}"
    );
    assert_eq!(
        scalar_i64(&database, "SELECT COUNT(*) FROM projects"),
        1,
        "项目不得被级联删除"
    );
    assert_eq!(count_work_items(&database), 1, "工作事项不得被级联删除");

    let insert_error = database
        .connection()
        .execute(
            "INSERT INTO work_items (id, project_id, title, created_at, updated_at) \
             VALUES ('fk-invalid', 'no-such-project', '虚构工作', 't', 't')",
            [],
        )
        .expect_err("project_id 指向不存在项目必须被外键拒绝");
    assert!(
        insert_error
            .to_string()
            .to_lowercase()
            .contains("foreign key"),
        "期望外键错误：{insert_error}"
    );

    database.check_foreign_keys().expect("外键检查");
}

#[test]
fn create_waits_for_in_flight_archive_transaction_then_rejects() {
    let (dir, mut archiver) = setup("work-items-concurrent-inflight");
    let mut creator = Database::initialize(&dir.release_paths()).expect("第二个数据库连接");
    let project = ProjectService::create(&mut archiver, "虚构事务中归档项目").expect("创建项目");
    let project_id = project.id.clone();

    // 归档事务先开始并持有 IMMEDIATE 写锁，在提交前保持打开；
    // 模拟“用户点击保存前，项目已被另一个操作归档”的真实边界。
    archiver
        .connection_mut()
        .execute_batch("BEGIN IMMEDIATE;")
        .expect("开启归档事务");
    archiver
        .connection_mut()
        .execute(
            "UPDATE projects SET is_archived = 1, updated_at = '2026-11-19T00:00:00.000Z' \
             WHERE id = ?1",
            params![project_id],
        )
        .expect("事务内归档");
    let archive_project_id = project_id.clone();

    let create_handle = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        WorkItemService::create(&mut creator, "并发创建的工作", Some(&archive_project_id))
    });

    std::thread::sleep(Duration::from_millis(500));
    archiver
        .connection_mut()
        .execute_batch("COMMIT;")
        .expect("提交归档事务");

    let error = create_handle
        .join()
        .expect("等待创建线程")
        .expect_err("归档事务提交后创建必须被拒绝");
    assert_eq!(error.code(), "project-archived");
    assert_eq!(
        count_work_items(&archiver),
        0,
        "不得产生违反 DEC-033 的新关联"
    );
    assert_eq!(
        WorkItemService::create(&mut archiver, "归档提交后创建", Some(&project_id))
            .expect_err("归档后创建仍然必须失败")
            .code(),
        "project-archived"
    );
}

#[test]
fn concurrent_archive_and_create_never_associate_archived_project() {
    let (dir, mut creator) = setup("work-items-concurrent-race");
    let mut archiver = Database::initialize(&dir.release_paths()).expect("归档连接");

    for index in 0..3 {
        let project = ProjectService::create(&mut archiver, &format!("虚构并发项目{index}"))
            .expect("创建项目");
        let project_id = project.id.clone();
        let title = format!("虚构并发工作{index}");
        let barrier = std::sync::Barrier::new(2);

        let (create_result, archive_result) = std::thread::scope(|scope| {
            let creator_ref: &mut Database = &mut creator;
            let archiver_ref: &mut Database = &mut archiver;
            let create_handle = {
                let barrier = &barrier;
                let project_id = &project_id;
                let title = &title;
                scope.spawn(move || {
                    barrier.wait();
                    WorkItemService::create(creator_ref, title, Some(project_id))
                })
            };
            let archive_handle = {
                let barrier = &barrier;
                let project_id = &project_id;
                scope.spawn(move || {
                    barrier.wait();
                    ProjectService::archive(archiver_ref, project_id)
                })
            };
            (
                create_handle.join().expect("等待创建线程"),
                archive_handle.join().expect("等待归档线程"),
            )
        });

        archive_result.expect("归档必须成功");
        match create_result {
            Ok(work_item) => {
                // 创建先于归档提交：关联在创建时是合法的。
                assert_eq!(work_item.lifecycle_status, WORK_ITEM_STATUS_PENDING);
                assert_eq!(work_item.project_id.as_deref(), Some(project_id.as_str()));
            }
            Err(error) => {
                // 归档先提交：创建必须被事务内校验拒绝。
                assert_eq!(error.code(), "project-archived");
            }
        }

        // 归档已提交后，新创建不得再关联该项目。
        let after_archive = WorkItemService::create(&mut creator, "归档后创建", Some(&project_id));
        assert_eq!(
            after_archive.expect_err("归档后创建必须失败").code(),
            "project-archived"
        );
    }

    // 不变量：任何已关联工作都不可能晚于其项目的归档更新时间。
    let violates = scalar_i64(
        &creator,
        "SELECT COUNT(*) FROM work_items w \
         JOIN projects p ON p.id = w.project_id \
         WHERE w.created_at > p.updated_at",
    );
    assert_eq!(violates, 0, "不得出现归档后新增的关联（DEC-033）");

    let linked = scalar_i64(
        &creator,
        "SELECT COUNT(*) FROM work_items WHERE project_id IS NOT NULL",
    );
    assert!(
        (0..=3).contains(&linked),
        "并发结果只允许 0–3 条合法关联，实际 {linked}"
    );
}
