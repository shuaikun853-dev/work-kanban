//! T1-04 多项目独立副本创建领域集成测试（真实 SQLite + Rust Core）。
//!
//! 最高优先级业务规则（用户确认 A：整批原子提交）：
//! - 一次批量创建 2 个及以上项目时，每个项目生成一条独立工作事项；
//! - 创建组与成员关系在同一 `IMMEDIATE` 写事务内写入；
//! - 任意项目不存在/已归档，或任意一条工作副本、创建组、成员关系写入失败，
//!   或事务内读回验证失败，整批回滚：不允许部分成功、静默跳过或补偿删除；
//! - 故障注入使用真实 SQLite `TRIGGER` 制造真实数据库错误，不增加生产故障开关。
//!
//! 测试数据全部虚构，数据库位于 D 盘隔离测试目录。

mod support;

use std::time::Duration;

use rusqlite::params;
use support::TestDir;
use workmanager_core::{
    Database, Project, ProjectService, WORK_ITEM_STATUS_PENDING, WorkItemService,
};

fn setup(label: &str) -> (TestDir, Database) {
    let dir = TestDir::new(label);
    let paths = dir.release_paths();
    let database = Database::initialize(&paths).expect("初始化数据库");
    (dir, database)
}

fn create_project(database: &mut Database, name: &str) -> Project {
    ProjectService::create(database, name).expect("创建虚构项目")
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

fn count_groups(database: &Database) -> i64 {
    scalar_i64(database, "SELECT COUNT(*) FROM work_item_creation_groups")
}

fn count_members(database: &Database) -> i64 {
    scalar_i64(
        database,
        "SELECT COUNT(*) FROM work_item_creation_group_members",
    )
}

fn assert_empty_batch_tables(database: &Database, context: &str) {
    assert_eq!(
        count_groups(database),
        0,
        "{context}：事务失败后不得残留创建组"
    );
    assert_eq!(
        count_members(database),
        0,
        "{context}：事务失败后不得残留成员关系"
    );
}

/// 事务失败后的完整不变量：创建组 / 成员关系 / 工作副本均无残留。
fn assert_no_batch_residue(database: &Database, expected_work_items: i64, context: &str) {
    assert_empty_batch_tables(database, context);
    assert_eq!(
        count_work_items(database),
        expected_work_items,
        "{context}：事务失败后不得残留工作副本"
    );
    assert_eq!(
        scalar_i64(
            database,
            "SELECT COUNT(*) FROM work_items WHERE title LIKE '%中核商品%'"
        ),
        0,
        "{context}：失败横幅目标题不得落库"
    );
}

/// 读取创建组的来源标题与创建时间（不存在时返回 None）。
fn read_group(database: &Database, group_id: &str) -> Option<(String, String)> {
    database
        .connection()
        .query_row(
            "SELECT source_title, created_at FROM work_item_creation_groups WHERE id = ?1",
            params![group_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .ok()
}

/// 按创建组读取成员关系：`(work_item_id, work_items.project_id)`。
fn read_members(database: &Database, group_id: &str) -> Vec<(String, Option<String>)> {
    let mut statement = database
        .connection()
        .prepare(
            "SELECT m.work_item_id, w.project_id \
             FROM work_item_creation_group_members m \
             JOIN work_items w ON w.id = m.work_item_id \
             WHERE m.group_id = ?1 \
             ORDER BY m.work_item_id",
        )
        .expect("准备成员查询");
    statement
        .query_map(params![group_id], |row| Ok((row.get(0)?, row.get(1)?)))
        .expect("执行成员查询")
        .collect::<Result<_, _>>()
        .expect("收集成员关系")
}

/// 记录全部业务表的完整快照（用于验证失败事务不改变历史数据）。
fn snapshot_rows(database: &Database) -> Vec<Vec<String>> {
    let mut snapshot = Vec::new();
    for sql in [
        "SELECT id, COALESCE(project_id, '<null>'), title, lifecycle_status, created_at, updated_at \
         FROM work_items ORDER BY id",
        "SELECT id, source_title, created_at FROM work_item_creation_groups ORDER BY id",
        "SELECT group_id, work_item_id FROM work_item_creation_group_members \
         ORDER BY group_id, work_item_id",
    ] {
        let mut statement = database.connection().prepare(sql).expect("准备快照查询");
        let rows = statement
            .query_map([], |row| {
                let mut values = Vec::new();
                for index in 0..row.as_ref().column_count() {
                    values.push(row.get::<_, String>(index)?);
                }
                Ok(values)
            })
            .expect("执行快照查询")
            .collect::<Result<Vec<_>, _>>()
            .expect("收集快照");
        snapshot.push(rows.concat());
    }
    snapshot
}

/// 在真实测试数据库中创建故障注入 trigger（仅测试使用，不进入生产代码）。
fn install_trigger(database: &Database, sql: &str) {
    database
        .connection()
        .execute_batch(sql)
        .expect("安装测试故障注入 trigger");
}

// ---------------------------------------------------------------------------
// 1–6：成功路径
// ---------------------------------------------------------------------------

#[test]
fn creates_independent_pending_copies_for_each_project() {
    let (_dir, mut database) = setup("copies-two-projects");
    let project_a = create_project(&mut database, "虚构项目甲");
    let project_b = create_project(&mut database, "虚构项目乙");

    let created = WorkItemService::create_copies(
        &mut database,
        "  中核商品价格异常排查  ",
        &[project_a.id.clone(), project_b.id.clone()],
    )
    .expect("两个项目批量创建成功");

    // 独立创建组 UUID 与两个独立工作副本 UUID。
    assert!(
        uuid::Uuid::parse_str(&created.group_id).is_ok(),
        "创建组 ID 必须是 UUID：{}",
        created.group_id
    );
    assert_eq!(created.work_items.len(), 2, "两个项目必须创建两个副本");
    let first = &created.work_items[0];
    let second = &created.work_items[1];
    assert_ne!(first.id, second.id, "每个副本必须拥有独立 UUID");
    assert!(uuid::Uuid::parse_str(&first.id).is_ok());
    assert!(uuid::Uuid::parse_str(&second.id).is_ok());

    // 每个副本 project_id 正确。
    assert_eq!(first.project_id.as_deref(), Some(project_a.id.as_str()));
    assert_eq!(second.project_id.as_deref(), Some(project_b.id.as_str()));

    // 全部为待安排，未设置字段为 NULL，不伪造评分。
    for item in &created.work_items {
        assert_eq!(item.title, "中核商品价格异常排查", "标题必须 trim 后写入");
        assert_eq!(item.lifecycle_status, WORK_ITEM_STATUS_PENDING);
        assert_eq!(item.lifecycle_status, "pending");
        assert_eq!(item.importance, None);
        assert_eq!(item.urgency, None);
        assert_eq!(item.due_date, None);
        assert_eq!(item.description, None);
        assert_eq!(item.created_at, item.updated_at);
        assert!(item.created_at.ends_with('Z'));
    }

    // 数据库真实记录：工作副本、创建组、成员关系完整。
    assert_eq!(count_work_items(&database), 2);
    assert_eq!(count_groups(&database), 1);
    assert_eq!(count_members(&database), 2);
    assert_eq!(
        read_group(&database, &created.group_id),
        Some(("中核商品价格异常排查".to_string(), first.created_at.clone())),
        "创建组必须保存规范化来源标题与创建时间"
    );
    let mut members = read_members(&database, &created.group_id);
    members.sort();
    let mut expected_members = vec![
        (first.id.clone(), Some(project_a.id.clone())),
        (second.id.clone(), Some(project_b.id.clone())),
    ];
    expected_members.sort();
    assert_eq!(members, expected_members);
    assert_eq!(
        scalar_i64(
            &database,
            "SELECT COUNT(*) FROM work_item_creation_group_members m \
             JOIN work_items w ON w.id = m.work_item_id \
             WHERE m.group_id = (SELECT id FROM work_item_creation_groups LIMIT 1) \
               AND w.project_id IS NOT NULL"
        ),
        2,
        "每个成员必须关联真实工作副本"
    );

    // 读回记录与数据库一致。
    for item in &created.work_items {
        let (title, status): (String, String) = database
            .connection()
            .query_row(
                "SELECT title, lifecycle_status FROM work_items WHERE id = ?1",
                params![item.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("读回工作副本");
        assert_eq!(title, item.title);
        assert_eq!(status, "pending");
    }
}

#[test]
fn creates_three_independent_copies_for_three_projects() {
    let (_dir, mut database) = setup("copies-three-projects");
    let projects: Vec<Project> = (1..=3)
        .map(|index| create_project(&mut database, &format!("虚构三项目场景{index}")))
        .collect();
    let ids: Vec<String> = projects.iter().map(|project| project.id.clone()).collect();

    let created = WorkItemService::create_copies(&mut database, "三个项目各一份工作", &ids)
        .expect("三个项目批量创建成功");

    assert_eq!(created.work_items.len(), 3);
    assert_eq!(count_work_items(&database), 3);
    assert_eq!(count_groups(&database), 1);
    assert_eq!(count_members(&database), 3);

    let mut item_ids: Vec<&str> = created
        .work_items
        .iter()
        .map(|item| item.id.as_str())
        .collect();
    item_ids.sort_unstable();
    item_ids.dedup();
    assert_eq!(item_ids.len(), 3, "三个副本 ID 必须互不相同");

    for (index, item) in created.work_items.iter().enumerate() {
        assert_eq!(
            item.project_id.as_deref(),
            Some(projects[index].id.as_str()),
            "第 {index} 个副本必须关联对应项目"
        );
        assert_eq!(item.lifecycle_status, WORK_ITEM_STATUS_PENDING);
    }

    let members = read_members(&database, &created.group_id);
    assert_eq!(members.len(), 3);
    let mut member_projects: Vec<String> = members
        .into_iter()
        .filter_map(|(_, project_id)| project_id)
        .collect();
    member_projects.sort();
    let mut expected: Vec<String> = projects.iter().map(|project| project.id.clone()).collect();
    expected.sort();
    assert_eq!(member_projects, expected);
}

#[test]
fn same_title_can_be_batched_again_as_new_independent_group() {
    let (_dir, mut database) = setup("copies-repeat-title");
    let project_a = create_project(&mut database, "虚构重复标题项目甲");
    let project_b = create_project(&mut database, "虚构重复标题项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];

    let first = WorkItemService::create_copies(&mut database, "相同标题的独立批次", &ids)
        .expect("第一次批量创建");
    let second = WorkItemService::create_copies(&mut database, "相同标题的独立批次", &ids)
        .expect("第二次批量创建");

    assert_ne!(
        first.group_id, second.group_id,
        "每次批量创建必须是新创建组"
    );
    assert_eq!(count_work_items(&database), 4);
    assert_eq!(count_groups(&database), 2);
    assert_eq!(count_members(&database), 4);
    for item in first.work_items.iter().chain(second.work_items.iter()) {
        assert_eq!(
            scalar_i64(
                &database,
                &format!(
                    "SELECT COUNT(*) FROM work_item_creation_group_members WHERE work_item_id = '{}'",
                    item.id
                )
            ),
            1,
            "每个副本必须恰好属于一个创建组"
        );
    }
}

// ---------------------------------------------------------------------------
// 7–9：输入校验
// ---------------------------------------------------------------------------

#[test]
fn rejects_empty_title_without_writing_any_batch_rows() {
    let (_dir, mut database) = setup("copies-empty-title");
    let project_a = create_project(&mut database, "虚构空标题项目甲");
    let project_b = create_project(&mut database, "虚构空标题项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];

    for raw in ["", "   ", "\t", "\n", " \u{3000} "] {
        let error =
            WorkItemService::create_copies(&mut database, raw, &ids).expect_err("空标题必须拒绝");
        assert_eq!(error.code(), "work-item-title-empty");
        assert!(!error.to_string().contains("虚构空标题项目甲"));
        assert!(!error.to_string().contains("SELECT"));
    }
    assert_eq!(count_work_items(&database), 0);
    assert_empty_batch_tables(&database, "空标题");
}

#[test]
fn rejects_batch_with_fewer_than_two_projects() {
    let (_dir, mut database) = setup("copies-too-few-projects");
    let project = create_project(&mut database, "虚构单项目");

    for project_ids in [Vec::new(), vec![project.id.clone()]] {
        let error =
            WorkItemService::create_copies(&mut database, "不足两个项目的工作", &project_ids)
                .expect_err("少于两个项目必须拒绝批量创建");
        assert_eq!(error.code(), "work-item-copies-too-few");
        assert!(!error.to_string().contains("虚构单项目"));
    }
    assert_eq!(count_work_items(&database), 0);
    assert_empty_batch_tables(&database, "项目数不足");
}

#[test]
fn rejects_duplicate_project_ids_without_silently_deduplicating() {
    let (_dir, mut database) = setup("copies-duplicate-projects");
    let project_a = create_project(&mut database, "虚构重复项目甲");
    let project_b = create_project(&mut database, "虚构重复项目乙");

    for project_ids in [
        vec![project_a.id.clone(), project_a.id.clone()],
        vec![
            project_a.id.clone(),
            project_b.id.clone(),
            project_a.id.clone(),
        ],
    ] {
        let error = WorkItemService::create_copies(&mut database, "重复项目不应创建", &project_ids)
            .expect_err("重复项目必须拒绝");
        assert_eq!(error.code(), "work-item-copies-duplicate-project");
    }
    assert_eq!(count_work_items(&database), 0, "不得静默去重后创建");
    assert_empty_batch_tables(&database, "项目重复");
}

// ---------------------------------------------------------------------------
// 10–14：事务内项目校验与故障注入回滚
// ---------------------------------------------------------------------------

#[test]
fn missing_project_rolls_back_entire_batch() {
    let (_dir, mut database) = setup("copies-missing-project");
    let project_a = create_project(&mut database, "虚构有效项目甲");

    let error = WorkItemService::create_copies(
        &mut database,
        "中核商品批量创建不应成功",
        &[
            project_a.id.clone(),
            "66666666-6666-4666-8666-666666666666".to_string(),
        ],
    )
    .expect_err("不存在的项目必须导致整批失败");
    assert_eq!(error.code(), "project-not-found");
    assert!(
        !error.to_string().contains("虚构有效项目甲"),
        "错误消息不得包含项目名称"
    );
    assert_no_batch_residue(&database, 0, "项目不存在");
}

#[test]
fn archived_project_rolls_back_entire_batch() {
    let (_dir, mut database) = setup("copies-archived-project");
    let project_a = create_project(&mut database, "虚构未归档项目甲");
    let project_b = create_project(&mut database, "虚构已归档项目乙");
    ProjectService::archive(&mut database, &project_b.id).expect("归档项目乙");

    let error = WorkItemService::create_copies(
        &mut database,
        "中核商品批量创建不应成功",
        &[project_a.id.clone(), project_b.id.clone()],
    )
    .expect_err("已归档项目必须导致整批失败");
    assert_eq!(error.code(), "project-archived");
    assert_no_batch_residue(&database, 0, "项目已归档");
}

#[test]
fn only_first_project_validated_would_have_passed_but_second_fails_batch() {
    // 反向证明：只校验第一个项目就会部分成功的场景，必须在第二个项目处整批失败。
    let (_dir, mut database) = setup("copies-second-project-invalid");
    let project_a = create_project(&mut database, "虚构首个有效项目");

    let error = WorkItemService::create_copies(
        &mut database,
        "中核商品只校验首个项目就会错误成功",
        &[
            project_a.id.clone(),
            "77777777-7777-4777-8777-777777777777".to_string(),
        ],
    )
    .expect_err("第二个项目不存在必须导致整批失败");
    assert_eq!(error.code(), "project-not-found");
    assert_no_batch_residue(&database, 0, "第二个项目不存在");
}

#[test]
fn work_item_insert_failure_on_second_copy_rolls_back_everything() {
    let (_dir, mut database) = setup("copies-fault-second-work-item");
    let project_a = create_project(&mut database, "虚构故障注入项目甲");
    let project_b = create_project(&mut database, "虚构故障注入项目乙");
    let existing = WorkItemService::create(&mut database, "故障前已存在的历史工作", None)
        .expect("创建历史工作");
    let before = snapshot_rows(&database);

    // 真实 SQLite TRIGGER：第一条工作副本插入成功，第二条（项目乙）真实失败。
    install_trigger(
        &database,
        &format!(
            "CREATE TRIGGER t1_04_fail_second_copy BEFORE INSERT ON work_items \
             WHEN NEW.project_id = '{}' \
             BEGIN SELECT RAISE(ABORT, 'T1-04 injected second-copy insert failure'); END;",
            project_b.id
        ),
    );

    let error = WorkItemService::create_copies(
        &mut database,
        "中核商品价格异常排查",
        &[project_a.id.clone(), project_b.id.clone()],
    )
    .expect_err("第二条工作副本插入失败必须导致整批回滚");
    assert_eq!(
        error.code(),
        "database-sqlite-error",
        "真实 SQLite 写入失败应透传数据库结构化错误码：{error}"
    );
    assert!(
        !error.to_string().contains("中核商品"),
        "错误消息不得包含工作标题"
    );
    assert!(
        !error.to_string().contains("虚构故障注入项目"),
        "错误消息不得包含项目名称"
    );

    // 事务失败后：无创建组、无成员关系、无工作副本残留；历史数据逐行不变。
    assert_no_batch_residue(&database, 1, "第二条工作副本失败");
    assert_eq!(snapshot_rows(&database), before, "失败事务不得改变历史数据");
    assert_eq!(
        scalar_i64(
            &database,
            &format!(
                "SELECT COUNT(*) FROM work_items WHERE id = '{}'",
                existing.id
            )
        ),
        1,
        "失败前已有工作必须保留"
    );
    let pending = WorkItemService::list_pending(&database).expect("查询待安排");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, existing.id);
}

#[test]
fn member_relation_insert_failure_rolls_back_everything() {
    let (_dir, mut database) = setup("copies-fault-second-member");
    let project_a = create_project(&mut database, "虚构成员故障项目甲");
    let project_b = create_project(&mut database, "虚构成员故障项目乙");

    // 第一条成员关系写入成功；第二条成员关系真实失败。
    install_trigger(
        &database,
        "CREATE TRIGGER t1_04_fail_second_member \
         BEFORE INSERT ON work_item_creation_group_members \
         WHEN (SELECT COUNT(*) FROM work_item_creation_group_members \
               WHERE group_id = NEW.group_id) = 1 \
         BEGIN SELECT RAISE(ABORT, 'T1-04 injected second-member insert failure'); END;",
    );

    let error = WorkItemService::create_copies(
        &mut database,
        "中核商品价格异常排查",
        &[project_a.id.clone(), project_b.id.clone()],
    )
    .expect_err("成员关系写入失败必须导致整批回滚");
    assert_eq!(error.code(), "database-sqlite-error");
    assert!(
        !error.to_string().contains("中核商品"),
        "错误消息不得包含工作标题"
    );
    assert_no_batch_residue(&database, 0, "第二条成员关系失败");
}

#[test]
fn read_back_verification_failure_rolls_back_everything() {
    let (_dir, mut database) = setup("copies-fault-readback");
    let project_a = create_project(&mut database, "虚构读回项目甲");
    let project_b = create_project(&mut database, "虚构读回项目乙");

    // 真实数据库写入成功，但在事务内制造与内存记录不一致的数据，
    // 用于验证 Core 的“事务内读回验证失败 → 整批回滚”路径。
    install_trigger(
        &database,
        "CREATE TRIGGER t1_04_corrupt_readback \
         AFTER INSERT ON work_item_creation_group_members \
         BEGIN UPDATE work_items SET title = title || '（读回篡改）' \
               WHERE id = NEW.work_item_id; END;",
    );

    let error = WorkItemService::create_copies(
        &mut database,
        "中核商品价格异常排查",
        &[project_a.id.clone(), project_b.id.clone()],
    )
    .expect_err("读回验证失败必须导致整批回滚");
    assert_eq!(
        error.code(),
        "work-item-persistence-verification-failed",
        "读回验证失败必须返回稳定错误码：{error}"
    );
    assert_no_batch_residue(&database, 0, "读回验证失败");
}

#[test]
fn failed_batch_keeps_previous_successful_batches_unchanged() {
    let (_dir, mut database) = setup("copies-history-preserved");
    let project_a = create_project(&mut database, "虚构历史批次项目甲");
    let project_b = create_project(&mut database, "虚构历史批次项目乙");
    let project_c = create_project(&mut database, "虚构历史批次项目丙");
    let project_d = create_project(&mut database, "虚构历史批次项目丁");

    let earlier = WorkItemService::create_copies(
        &mut database,
        "更早成功的批次",
        &[project_a.id.clone(), project_b.id.clone()],
    )
    .expect("创建历史批次");
    let single = WorkItemService::create(&mut database, "历史单条工作", Some(&project_a.id))
        .expect("创建历史单条工作");
    let before = snapshot_rows(&database);

    install_trigger(
        &database,
        &format!(
            "CREATE TRIGGER t1_04_history_failure BEFORE INSERT ON work_items \
             WHEN NEW.project_id = '{}' \
             BEGIN SELECT RAISE(ABORT, 'T1-04 injected history failure'); END;",
            project_d.id
        ),
    );
    let error = WorkItemService::create_copies(
        &mut database,
        "不应写入的后续批次",
        &[project_c.id.clone(), project_d.id.clone()],
    )
    .expect_err("故障批次必须失败");
    assert_eq!(error.code(), "database-sqlite-error");

    assert_eq!(snapshot_rows(&database), before, "历史记录必须逐行不变");
    assert_eq!(count_groups(&database), 1);
    assert_eq!(count_members(&database), 2);
    assert_eq!(count_work_items(&database), 3);
    let pending = WorkItemService::list_pending(&database).expect("查询待安排");
    assert_eq!(pending.len(), 3);
    assert_eq!(
        read_group(&database, &earlier.group_id),
        Some((
            "更早成功的批次".to_string(),
            earlier.work_items[0].created_at.clone()
        ))
    );
    let still_there = pending.iter().any(|item| item.id == single.id);
    assert!(still_there, "失败前已有单条工作必须保留");
}

// ---------------------------------------------------------------------------
// 15–16：并发与持久化
// ---------------------------------------------------------------------------

#[test]
fn batch_create_waits_for_in_flight_archive_then_fails_entirely() {
    let (dir, mut archiver) = setup("copies-concurrent-inflight");
    let mut creator = Database::initialize(&dir.release_paths()).expect("第二个数据库连接");
    let project_a = create_project(&mut archiver, "虚构并发批次项目甲");
    let project_b = create_project(&mut archiver, "虚构并发批次项目乙");
    let project_a_id = project_a.id.clone();
    let project_b_id = project_b.id.clone();

    // 归档事务先开始并持有 IMMEDIATE 写锁，提交前保持打开。
    archiver
        .connection_mut()
        .execute_batch("BEGIN IMMEDIATE;")
        .expect("开启归档事务");
    archiver
        .connection_mut()
        .execute(
            "UPDATE projects SET is_archived = 1, updated_at = '2026-11-24T00:00:00.000Z' \
             WHERE id = ?1",
            params![project_b_id],
        )
        .expect("事务内归档项目乙");

    let batch_ids = vec![project_a_id.clone(), project_b_id.clone()];
    let create_handle = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        WorkItemService::create_copies(&mut creator, "并发批量创建的工作", &batch_ids)
    });

    std::thread::sleep(Duration::from_millis(500));
    archiver
        .connection_mut()
        .execute_batch("COMMIT;")
        .expect("提交归档事务");

    let error = create_handle
        .join()
        .expect("等待批量创建线程")
        .expect_err("归档事务提交后批量创建必须被拒绝");
    assert_eq!(error.code(), "project-archived");
    assert_eq!(count_work_items(&archiver), 0, "不得产生部分工作副本");
    assert_empty_batch_tables(&archiver, "并发归档");
}

#[test]
fn concurrent_archive_and_batch_create_never_produces_partial_batch() {
    let (dir, mut creator) = setup("copies-concurrent-race");
    let mut archiver = Database::initialize(&dir.release_paths()).expect("归档连接");

    for index in 0..3 {
        let project_a = create_project(&mut archiver, &format!("虚构并发批次甲{index}"));
        let project_b = create_project(&mut archiver, &format!("虚构并发批次乙{index}"));
        let project_a_id = project_a.id.clone();
        let project_b_id = project_b.id.clone();
        let title = format!("虚构并发批量工作{index}");
        let barrier = std::sync::Barrier::new(2);

        let (create_result, archive_result) = std::thread::scope(|scope| {
            let creator_ref: &mut Database = &mut creator;
            let archiver_ref: &mut Database = &mut archiver;
            let create_handle = {
                let barrier = &barrier;
                let project_a_id = &project_a_id;
                let project_b_id = &project_b_id;
                let title = &title;
                scope.spawn(move || {
                    barrier.wait();
                    WorkItemService::create_copies(
                        creator_ref,
                        title,
                        &[project_a_id.clone(), project_b_id.clone()],
                    )
                })
            };
            let archive_handle = {
                let barrier = &barrier;
                let project_b_id = &project_b_id;
                scope.spawn(move || {
                    barrier.wait();
                    ProjectService::archive(archiver_ref, project_b_id)
                })
            };
            (
                create_handle.join().expect("等待批量创建线程"),
                archive_handle.join().expect("等待归档线程"),
            )
        });

        archive_result.expect("归档必须成功");
        match create_result {
            Ok(created) => {
                // 批量创建先提交：两个副本必须同时存在且都属于未归档项目。
                assert_eq!(created.work_items.len(), 2);
                let group_size = scalar_i64(
                    &creator,
                    &format!(
                        "SELECT COUNT(*) FROM work_item_creation_group_members WHERE group_id = '{}'",
                        created.group_id
                    ),
                );
                assert_eq!(group_size, 2, "成功批次必须有且只有两条成员关系");
                for item in &created.work_items {
                    assert!(
                        item.project_id.as_deref() == Some(project_a_id.as_str())
                            || item.project_id.as_deref() == Some(project_b_id.as_str()),
                        "成功批次的副本必须关联请求项目"
                    );
                }
            }
            Err(error) => {
                // 归档先提交：整批失败，不得留下部分副本/组/成员。
                assert_eq!(error.code(), "project-archived");
                let residue = scalar_i64(
                    &creator,
                    &format!(
                        "SELECT COUNT(*) FROM work_items WHERE project_id IN ('{}','{}')",
                        project_a_id, project_b_id
                    ),
                );
                assert_eq!(residue, 0, "失败批次不得留下任何副本");
            }
        }

        // 归档已提交后，新批量创建必须整批失败。
        let after_archive = WorkItemService::create_copies(
            &mut creator,
            "归档后批量创建",
            &[project_a_id.clone(), project_b_id.clone()],
        );
        assert_eq!(
            after_archive.expect_err("归档后创建必须失败").code(),
            "project-archived"
        );
    }

    // 全局不变量：不存在“创建时间晚于项目归档时间”的副本关联。
    let violates = scalar_i64(
        &creator,
        "SELECT COUNT(*) FROM work_items w \
         JOIN projects p ON p.id = w.project_id \
         WHERE w.created_at > p.updated_at",
    );
    assert_eq!(violates, 0, "不得出现归档后新增的副本关联");

    // 每个成员关系必须唯一、每个工作副本最多一个创建组。
    assert_eq!(
        scalar_i64(
            &creator,
            "SELECT COUNT(*) FROM (SELECT work_item_id FROM work_item_creation_group_members \
             GROUP BY work_item_id HAVING COUNT(*) > 1)",
        ),
        0,
        "工作副本不得属于多个创建组"
    );
    assert_eq!(
        scalar_i64(
            &creator,
            "SELECT COUNT(*) FROM work_item_creation_group_members m \
             LEFT JOIN work_item_creation_groups g ON g.id = m.group_id \
             LEFT JOIN work_items w ON w.id = m.work_item_id \
             WHERE g.id IS NULL OR w.id IS NULL",
        ),
        0,
        "不得存在孤儿成员关系"
    );
}

#[test]
fn batch_rows_and_members_persist_across_restart() {
    let (dir, mut database) = setup("copies-persistence");
    let projects: Vec<Project> = (1..=5)
        .map(|index| create_project(&mut database, &format!("虚构持久化项目{index}")))
        .collect();
    let pair_ids = vec![projects[0].id.clone(), projects[1].id.clone()];
    let trio_ids = vec![
        projects[2].id.clone(),
        projects[3].id.clone(),
        projects[4].id.clone(),
    ];
    let two = WorkItemService::create_copies(&mut database, "重启后保留的两项目批次", &pair_ids)
        .expect("两项目批次");
    let three = WorkItemService::create_copies(&mut database, "重启后保留的三项目批次", &trio_ids)
        .expect("三项目批次");
    let expected_group_ids = vec![two.group_id.clone(), three.group_id.clone()];
    let expected_item_ids: Vec<String> = two
        .work_items
        .iter()
        .chain(three.work_items.iter())
        .map(|item| item.id.clone())
        .collect();

    drop(database);
    let database = Database::initialize(&dir.release_paths()).expect("重新打开数据库");

    assert_eq!(count_work_items(&database), 5);
    assert_eq!(count_groups(&database), 2);
    assert_eq!(count_members(&database), 5);
    for group_id in expected_group_ids {
        let size = scalar_i64(
            &database,
            &format!(
                "SELECT COUNT(*) FROM work_item_creation_group_members WHERE group_id = '{group_id}'"
            ),
        );
        assert!(size == 2 || size == 3, "创建组成员数量必须保留：{size}");
    }
    let pending = WorkItemService::list_pending(&database).expect("重启后待安排");
    let pending_ids: Vec<&str> = pending.iter().map(|item| item.id.as_str()).collect();
    for item_id in &expected_item_ids {
        assert!(
            pending_ids.contains(&item_id.as_str()),
            "重启后工作副本必须存在：{item_id}"
        );
    }
    assert_eq!(
        scalar_i64(
            &database,
            "SELECT COUNT(*) FROM work_item_creation_group_members m \
             JOIN work_items w ON w.id = m.work_item_id \
             WHERE w.lifecycle_status != 'pending'",
        ),
        0,
        "批量创建的工作副本必须全部为 pending"
    );
    database.check_foreign_keys().expect("重启后外键检查");
}
