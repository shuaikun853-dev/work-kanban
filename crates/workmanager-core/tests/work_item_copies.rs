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

use std::sync::{Mutex, mpsc};
use std::time::Duration;

use rusqlite::functions::FunctionFlags;
use rusqlite::params;
use support::TestDir;
use workmanager_core::{
    CreatedWorkItemCopies, Database, Project, ProjectService, WORK_ITEM_STATUS_PENDING,
    WorkItemError, WorkItemService,
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

/// 为每个独立逻辑创建操作生成新的请求标识。
///
/// 真实的 T1-04 批量接口要求客户端预先生成并复用请求标识；普通行为测试
/// 每次调用都代表一个新的逻辑操作，因此使用新的 UUID。
fn new_request_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// 现有成功/失败行为测试的便捷入口：每次调用生成新的请求标识。
fn create_copies(
    database: &mut Database,
    title: &str,
    project_ids: &[String],
) -> Result<CreatedWorkItemCopies, WorkItemError> {
    WorkItemService::create_copies(database, &new_request_id(), title, project_ids)
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

    let created = create_copies(
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

    let created =
        create_copies(&mut database, "三个项目各一份工作", &ids).expect("三个项目批量创建成功");

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

    let first = create_copies(&mut database, "相同标题的独立批次", &ids).expect("第一次批量创建");
    let second = create_copies(&mut database, "相同标题的独立批次", &ids).expect("第二次批量创建");

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
// T104-02：客户端请求标识幂等性（真实 SQLite 事务）
// ---------------------------------------------------------------------------

#[test]
fn same_request_id_returns_same_batch_without_writing_again() {
    let (_dir, mut database) = setup("copies-idempotent-retry");
    let project_a = create_project(&mut database, "虚构幂等项目甲");
    let project_b = create_project(&mut database, "虚构幂等项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];
    let request_id = new_request_id();

    let first = WorkItemService::create_copies(&mut database, &request_id, "幂等批次工作", &ids)
        .expect("第一次批量创建");
    assert_eq!(
        first.group_id, request_id,
        "创建组主键必须就是客户端请求标识"
    );
    let before_retry = snapshot_rows(&database);

    let retry = WorkItemService::create_copies(&mut database, &request_id, "幂等批次工作", &ids)
        .expect("相同请求标识重试必须返回既有结果");
    assert_eq!(retry, first, "重试必须返回同一批次、同一组工作副本");
    assert_eq!(
        snapshot_rows(&database),
        before_retry,
        "幂等重试不得写入任何新行或修改既有行"
    );
    assert_eq!(count_work_items(&database), 2);
    assert_eq!(count_groups(&database), 1);
    assert_eq!(count_members(&database), 2);
}

#[test]
fn same_request_id_with_different_title_is_rejected_stably() {
    let (_dir, mut database) = setup("copies-idempotent-title-conflict");
    let project_a = create_project(&mut database, "虚构标题冲突项目甲");
    let project_b = create_project(&mut database, "虚构标题冲突项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];
    let request_id = new_request_id();

    let first = WorkItemService::create_copies(&mut database, &request_id, "原始批次标题", &ids)
        .expect("第一次批量创建");
    let before_retry = snapshot_rows(&database);

    let error =
        WorkItemService::create_copies(&mut database, &request_id, "被修改的批次标题", &ids)
            .expect_err("相同请求标识对应不同标题必须拒绝");
    assert_eq!(error.code(), "work-item-create-request-conflict");
    assert!(
        !error.to_string().contains("原始批次标题")
            && !error.to_string().contains("被修改的批次标题"),
        "冲突错误消息不得包含工作标题"
    );
    assert_eq!(
        snapshot_rows(&database),
        before_retry,
        "冲突不得修改既有批次"
    );
    assert_eq!(
        read_group(&database, &first.group_id).unwrap().0,
        "原始批次标题"
    );
    assert_eq!(count_groups(&database), 1);
    assert_eq!(count_members(&database), 2);
}

#[test]
fn same_request_id_with_different_project_list_is_rejected_stably() {
    let (_dir, mut database) = setup("copies-idempotent-project-conflict");
    let project_a = create_project(&mut database, "虚构项目冲突甲");
    let project_b = create_project(&mut database, "虚构项目冲突乙");
    let project_c = create_project(&mut database, "虚构项目冲突丙");
    let request_id = new_request_id();
    let first_ids = vec![project_a.id.clone(), project_b.id.clone()];

    WorkItemService::create_copies(&mut database, &request_id, "项目列表绑定批次", &first_ids)
        .expect("第一次批量创建");
    let before_retry = snapshot_rows(&database);

    for different_ids in [
        vec![project_b.id.clone(), project_c.id.clone()],
        vec![
            project_a.id.clone(),
            project_b.id.clone(),
            project_c.id.clone(),
        ],
    ] {
        let error = WorkItemService::create_copies(
            &mut database,
            &request_id,
            "项目列表绑定批次",
            &different_ids,
        )
        .expect_err("相同请求标识对应不同项目列表必须拒绝");
        assert_eq!(
            error.code(),
            "work-item-create-request-conflict",
            "项目列表冲突必须返回稳定错误码"
        );
    }
    assert_eq!(
        snapshot_rows(&database),
        before_retry,
        "冲突不得修改既有批次"
    );
    assert_eq!(count_work_items(&database), 2);
    assert_eq!(count_groups(&database), 1);
    assert_eq!(count_members(&database), 2);
}

#[test]
fn idempotent_retry_after_project_archive_returns_existing_batch() {
    let (_dir, mut database) = setup("copies-idempotent-archived-retry");
    let project_a = create_project(&mut database, "虚构幂等归档项目甲");
    let project_b = create_project(&mut database, "虚构幂等归档项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];
    let request_id = new_request_id();

    let first =
        WorkItemService::create_copies(&mut database, &request_id, "归档后的幂等重试", &ids)
            .expect("第一次批量创建");
    ProjectService::archive(&mut database, &project_a.id).expect("归档项目甲");
    ProjectService::archive(&mut database, &project_b.id).expect("归档项目乙");
    let before_retry = snapshot_rows(&database);

    let retry =
        WorkItemService::create_copies(&mut database, &request_id, "归档后的幂等重试", &ids)
            .expect("已提交请求的重试必须在项目归档后仍返回既有结果");
    assert_eq!(
        retry, first,
        "幂等重试不得因项目后来归档而返回 project-archived"
    );
    assert_eq!(
        snapshot_rows(&database),
        before_retry,
        "归档后的幂等重试不得新增或修改任何行"
    );
    assert_eq!(count_groups(&database), 1);
    assert_eq!(count_members(&database), 2);
}

#[test]
fn concurrent_same_request_id_creates_only_one_batch() {
    let (dir, mut creator) = setup("copies-idempotent-concurrent");
    let mut retry_connection = Database::initialize(&dir.release_paths()).expect("第二数据库连接");
    let project_a = create_project(&mut creator, "虚构并发幂等项目甲");
    let project_b = create_project(&mut creator, "虚构并发幂等项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];
    let request_id = new_request_id();
    let barrier = std::sync::Barrier::new(2);

    let (first, second) = std::thread::scope(|scope| {
        let creator_ref: &mut Database = &mut creator;
        let retry_ref: &mut Database = &mut retry_connection;
        let barrier_ref = &barrier;
        let request_id_ref = &request_id;
        let ids_ref = &ids;
        let first_handle = scope.spawn(move || {
            barrier_ref.wait();
            WorkItemService::create_copies(creator_ref, request_id_ref, "并发幂等批次", ids_ref)
        });
        let second_handle = scope.spawn(move || {
            barrier_ref.wait();
            WorkItemService::create_copies(retry_ref, request_id_ref, "并发幂等批次", ids_ref)
        });
        (
            first_handle.join().expect("等待第一个幂等请求"),
            second_handle.join().expect("等待第二个幂等请求"),
        )
    });

    let first = first.expect("第一个并发请求必须成功或返回既有批次");
    let second = second.expect("第二个并发请求必须返回同一批次的既有结果");
    assert_eq!(first.group_id, request_id);
    assert_eq!(second.group_id, request_id);
    assert_eq!(
        first.work_items, second.work_items,
        "两次响应必须是同一批次"
    );
    assert_eq!(count_work_items(&creator), 2, "并发请求只能创建两个副本");
    assert_eq!(count_groups(&creator), 1, "并发请求只能创建一个批次");
    assert_eq!(count_members(&creator), 2, "并发请求只能创建两条成员关系");
    assert_eq!(
        scalar_i64(
            &creator,
            &format!(
                "SELECT COUNT(*) FROM work_item_creation_group_members WHERE group_id = '{}'",
                request_id
            ),
        ),
        2
    );
}

#[test]
fn different_request_ids_allow_same_title_as_new_independent_batches() {
    let (_dir, mut database) = setup("copies-idempotent-different-requests");
    let project_a = create_project(&mut database, "虚构不同请求项目甲");
    let project_b = create_project(&mut database, "虚构不同请求项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];

    let first = WorkItemService::create_copies(
        &mut database,
        &new_request_id(),
        "允许重复标题的新批次",
        &ids,
    )
    .expect("第一个请求标识");
    let second = WorkItemService::create_copies(
        &mut database,
        &new_request_id(),
        "允许重复标题的新批次",
        &ids,
    )
    .expect("不同请求标识必须允许创建新批次");

    assert_ne!(first.group_id, second.group_id);
    assert_ne!(first.work_items[0].id, second.work_items[0].id);
    assert_eq!(count_work_items(&database), 4);
    assert_eq!(count_groups(&database), 2);
    assert_eq!(count_members(&database), 4);
}

#[test]
fn rejects_non_canonical_request_id_without_writing_any_rows() {
    let (_dir, mut database) = setup("copies-idempotent-invalid-request-id");
    let project_a = create_project(&mut database, "虚构非法请求项目甲");
    let project_b = create_project(&mut database, "虚构非法请求项目乙");
    let ids = vec![project_a.id.clone(), project_b.id.clone()];

    for invalid_request_id in [
        "",
        "not-a-uuid",
        "11111111-1111-4111-8111-11111111111",
        "11111111-1111-4111-8111-1111111111111",
        "urn:uuid:11111111-1111-4111-8111-111111111111",
        "11111111-1111-4111-8111-11111111111A",
    ] {
        let error = WorkItemService::create_copies(
            &mut database,
            invalid_request_id,
            "非法请求标识不得创建",
            &ids,
        )
        .expect_err("非规范 UUID 请求标识必须拒绝");
        assert_eq!(error.code(), "work-item-create-request-id-invalid");
        assert!(
            !error.to_string().contains(invalid_request_id),
            "错误消息不得回显请求标识"
        );
    }
    assert_eq!(count_work_items(&database), 0);
    assert_empty_batch_tables(&database, "非法请求标识");
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
        let error = create_copies(&mut database, raw, &ids).expect_err("空标题必须拒绝");
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
        let error = create_copies(&mut database, "不足两个项目的工作", &project_ids)
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
        let error = create_copies(&mut database, "重复项目不应创建", &project_ids)
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

    let error = create_copies(
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

    let error = create_copies(
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

    let error = create_copies(
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

    let error = create_copies(
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
fn creation_group_insert_failure_rolls_back_everything() {
    let (_dir, mut database) = setup("copies-fault-group-insert");
    let project_a = create_project(&mut database, "虚构创建组故障项目甲");
    let project_b = create_project(&mut database, "虚构创建组故障项目乙");
    let existing =
        WorkItemService::create(&mut database, "创建组故障前历史工作", None).expect("创建历史工作");
    let before = snapshot_rows(&database);

    // 真实 SQLite TRIGGER：在创建组 INSERT 前注入失败。该写入是整批事务的第一步，
    // 用于证明即使故障发生在创建组阶段，也不会留下组、成员或工作副本。
    install_trigger(
        &database,
        "CREATE TRIGGER t1_04_fail_group_insert \
         BEFORE INSERT ON work_item_creation_groups \
         BEGIN SELECT RAISE(ABORT, 'T1-04 injected creation-group insert failure'); END;",
    );

    let error = create_copies(
        &mut database,
        "中核商品价格异常排查",
        &[project_a.id.clone(), project_b.id.clone()],
    )
    .expect_err("创建组插入失败必须导致整批回滚");
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
        !error.to_string().contains("虚构创建组故障项目"),
        "错误消息不得包含项目名称"
    );

    assert_no_batch_residue(&database, 1, "创建组插入失败");
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

    let error = create_copies(
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

    let error = create_copies(
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

    let earlier = create_copies(
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
    let error = create_copies(
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

    // 场景一：归档事务先完整提交；批量创建随后开始，必须观察到已归档并整批失败。
    // 使用 channel 明确建立“归档提交完成 → 批量创建开始”的 happens-before 顺序，
    // 不使用 sleep 或重复运行碰运气。
    let (archive_committed_tx, archive_committed_rx) = mpsc::channel();
    std::thread::scope(|scope| {
        let archiver_ref: &mut Database = &mut archiver;
        let project_b_id = project_b_id.as_str();
        scope.spawn(move || {
            let result = ProjectService::archive(archiver_ref, project_b_id);
            archive_committed_tx
                .send(result.is_ok())
                .expect("发送归档提交结果");
        });
    });
    assert!(
        archive_committed_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("归档必须在超时前完成"),
        "归档事务必须成功提交"
    );

    let batch_ids = vec![project_a_id.clone(), project_b_id.clone()];
    let error = create_copies(&mut creator, "并发批量创建的工作", &batch_ids)
        .expect_err("归档事务提交后批量创建必须被拒绝");
    assert_eq!(error.code(), "project-archived");
    assert_eq!(count_work_items(&archiver), 0, "不得产生部分工作副本");
    assert_empty_batch_tables(&archiver, "并发归档");
}

#[test]
fn concurrent_archive_and_batch_create_never_produces_partial_batch() {
    let (dir, mut creator) = setup("copies-concurrent-race");
    let mut archiver = Database::initialize(&dir.release_paths()).expect("归档连接");
    let project_a = create_project(&mut creator, "虚构并发批次甲");
    let project_b = create_project(&mut creator, "虚构并发批次乙");
    let project_a_id = project_a.id.clone();
    let project_b_id = project_b.id.clone();
    let batch_ids = vec![project_a_id.clone(), project_b_id.clone()];

    // 场景二：批量创建先取得真实 IMMEDIATE 写事务。
    //
    // 通过测试连接专用的 SQLite 标量函数 + BEFORE INSERT trigger，在创建组 INSERT
    // 处暂停批量创建事务；此时它已经持有写锁。测试再启动归档线程，随后释放批量创建。
    // 这提供确定的“批量创建先取得写事务 → 完整提交 → 归档继续”顺序，不依赖 sleep。
    // SQLite UDF 只注册在测试连接上，不进入生产代码，也不是生产故障开关。
    let (batch_locked_tx, batch_locked_rx) = mpsc::channel();
    let (release_batch_tx, release_batch_rx) = mpsc::channel();
    let release_batch_rx = Mutex::new(release_batch_rx);
    creator
        .connection()
        .create_scalar_function(
            "wm_t104_pause_batch_insert",
            0,
            FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
            move |_| {
                batch_locked_tx.send(()).map_err(|_| {
                    rusqlite::Error::UserFunctionError("测试同步信号接收端已关闭".into())
                })?;
                release_batch_rx
                    .lock()
                    .expect("测试同步锁")
                    .recv_timeout(Duration::from_secs(15))
                    .map_err(|_| {
                        rusqlite::Error::UserFunctionError("等待释放批量创建事务超时".into())
                    })?;
                Ok(1_i64)
            },
        )
        .expect("注册测试同步 SQLite 函数");
    creator
        .connection()
        .execute_batch(
            "CREATE TRIGGER t1_04_pause_batch_group_insert \
             BEFORE INSERT ON work_item_creation_groups \
             BEGIN SELECT wm_t104_pause_batch_insert(); END;",
        )
        .expect("安装测试同步 trigger");

    let title = "虚构并发创建先提交";
    let create_handle = std::thread::spawn(move || create_copies(&mut creator, title, &batch_ids));
    batch_locked_rx
        .recv_timeout(Duration::from_secs(15))
        .expect("批量创建必须在超时前进入创建组写入并持有写事务");

    let (archive_started_tx, archive_started_rx) = mpsc::channel();
    let archive_project_id = project_b_id.clone();
    let archive_handle = std::thread::spawn(move || {
        archive_started_tx.send(()).expect("发送归档线程已启动信号");
        ProjectService::archive(&mut archiver, &archive_project_id)
    });
    archive_started_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("归档线程必须在超时前启动");

    // 批量创建仍暂停在事务内，此时归档调用已发起；释放后批量创建必须完整提交，
    // 归档随后才能取得写事务并成功。
    release_batch_tx.send(()).expect("释放批量创建事务");

    let created = create_handle
        .join()
        .expect("等待批量创建线程")
        .expect("批量创建先取得写事务时必须完整提交");
    let archived = archive_handle
        .join()
        .expect("等待归档线程")
        .expect("批量创建提交后归档必须成功");
    assert!(archived.is_archived);
    assert_eq!(created.work_items.len(), 2);

    let check = Database::initialize(&dir.release_paths()).expect("复核数据库");
    assert_eq!(count_work_items(&check), 2, "批量创建必须完整提交两个副本");
    assert_eq!(count_groups(&check), 1);
    assert_eq!(count_members(&check), 2);
    for item in &created.work_items {
        assert!(
            item.project_id.as_deref() == Some(project_a_id.as_str())
                || item.project_id.as_deref() == Some(project_b_id.as_str()),
            "成功批次的副本必须关联请求项目"
        );
    }
    assert_eq!(
        scalar_i64(
            &check,
            &format!(
                "SELECT is_archived FROM projects WHERE id = '{}'",
                project_b_id
            )
        ),
        1,
        "批量创建提交后归档必须实际生效"
    );
    assert_eq!(
        scalar_i64(
            &check,
            "SELECT COUNT(*) FROM (SELECT work_item_id FROM work_item_creation_group_members \
             GROUP BY work_item_id HAVING COUNT(*) > 1)",
        ),
        0,
        "工作副本不得属于多个创建组"
    );
    assert_eq!(
        scalar_i64(
            &check,
            "SELECT COUNT(*) FROM work_item_creation_group_members m \
             LEFT JOIN work_item_creation_groups g ON g.id = m.group_id \
             LEFT JOIN work_items w ON w.id = m.work_item_id \
             WHERE g.id IS NULL OR w.id IS NULL",
        ),
        0,
        "不得存在孤儿成员关系"
    );
    check.check_foreign_keys().expect("并发测试后外键检查");
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
    let two =
        create_copies(&mut database, "重启后保留的两项目批次", &pair_ids).expect("两项目批次");
    let three =
        create_copies(&mut database, "重启后保留的三项目批次", &trio_ids).expect("三项目批次");
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
