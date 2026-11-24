//! R6-01 真实 Rust / Bridge 交叉契约测试的 Rust 侧执行器。
//!
//! 该测试由 `scripts/quality/work-item-title-cross-contract.test.mjs` 通过环境变量
//! 传入原始标题（UTF-32 十六进制码点列表），走真实 `WorkItemService::create_copies`
//! + 真实 SQLite 保存与读回，再把 Rust Core 实际返回的标题输出给 Node。
//!
//! 普通 `cargo test --workspace` 不运行该执行器（`#[ignore]`）；Node 测试用
//! `--ignored --nocapture` 启动它，并把 Rust 返回值交给真实 Bridge
//! `parseCreatedWorkItemCopies`，因此不是两个独立函数的各自断言。
//!
//! 测试数据全部虚构；数据库位于 D 盘隔离测试目录，不触碰正式目录。

mod support;

use support::TestDir;
use workmanager_core::{Database, ProjectService, WorkItemService};

const CASES_ENV: &str = "WORKMANAGER_TITLE_CROSS_CONTRACT_CASES";

/// 每个用例在同一个 requestId 上连续创建两次，验证幂等重试仍返回原批次。
fn decode_title(encoded: &str) -> String {
    encoded
        .split(',')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let code_point = u32::from_str_radix(part, 16).expect("UTF-32 十六进制码点");
            char::from_u32(code_point).expect("合法 Unicode 标量")
        })
        .collect()
}

fn encode_title(title: &str) -> String {
    title
        .chars()
        .map(|character| format!("{:04X}", character as u32))
        .collect::<Vec<_>>()
        .join(",")
}

fn scalar_i64(database: &Database, sql: &str) -> i64 {
    database
        .connection()
        .query_row(sql, [], |row| row.get(0))
        .expect("标量查询")
}

#[test]
#[ignore = "由 scripts/quality/work-item-title-cross-contract.test.mjs 通过 --ignored 启动"]
fn cross_contract_title_roundtrip() {
    let payload = std::env::var(CASES_ENV).expect("缺少 Node 传入的交叉契约用例");
    let cases: Vec<(&str, String)> = payload
        .split(';')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let (id, encoded) = part.split_once('=').expect("用例格式 id=hex,hex");
            (id, decode_title(encoded))
        })
        .collect();
    assert!(!cases.is_empty(), "交叉契约用例不得为空");

    let dir = TestDir::new("t1-04-title-cross-contract");
    let paths = dir.release_paths();
    let mut database = Database::initialize(&paths).expect("初始化测试数据库");
    let project_a = ProjectService::create(&mut database, "虚构交叉契约项目甲").expect("项目甲");
    let project_b = ProjectService::create(&mut database, "虚构交叉契约项目乙").expect("项目乙");
    let project_ids = vec![project_a.id.clone(), project_b.id.clone()];

    let mut expected_work_items = 0_i64;
    for (case_id, raw_title) in cases {
        let request_id = uuid::Uuid::new_v4().to_string();
        let first =
            WorkItemService::create_copies(&mut database, &request_id, &raw_title, &project_ids)
                .expect("Rust Core 必须接受该标题并完成原子创建");
        assert_eq!(first.group_id, request_id, "创建组 ID 必须复用 requestId");
        assert_eq!(first.work_items.len(), 2, "两个项目必须各一个副本");

        let first_ids: Vec<String> = first
            .work_items
            .iter()
            .map(|work_item| work_item.id.clone())
            .collect();
        let first_titles: Vec<String> = first
            .work_items
            .iter()
            .map(|work_item| work_item.title.clone())
            .collect();

        // 同一 requestId 重试：必须返回同一创建组、同一工作事项 ID 与同一标题。
        let retry =
            WorkItemService::create_copies(&mut database, &request_id, &raw_title, &project_ids)
                .expect("同一 requestId 重试必须返回既有批次");
        assert_eq!(retry.group_id, first.group_id, "重试 groupId 必须一致");
        assert_eq!(
            retry
                .work_items
                .iter()
                .map(|work_item| work_item.id.clone())
                .collect::<Vec<_>>(),
            first_ids,
            "重试不得创建重复副本"
        );
        assert_eq!(
            retry
                .work_items
                .iter()
                .map(|work_item| work_item.title.clone())
                .collect::<Vec<_>>(),
            first_titles,
            "重试标题必须一致"
        );

        expected_work_items += 2;
        assert_eq!(
            scalar_i64(&database, "SELECT COUNT(*) FROM work_items"),
            expected_work_items,
            "每个逻辑批次只允许写入两个工作副本"
        );
        assert_eq!(
            scalar_i64(&database, "SELECT COUNT(*) FROM work_item_creation_groups"),
            expected_work_items / 2,
            "每个逻辑批次只允许一个创建组"
        );

        println!("CROSS_CONTRACT_CASE\t{case_id}");
        println!("CROSS_CONTRACT_GROUP\t{}", first.group_id);
        for work_item in &first.work_items {
            let project_id = work_item
                .project_id
                .as_deref()
                .expect("批量副本必须关联项目");
            println!(
                "CROSS_CONTRACT_ITEM\t{}\t{}\t{}\t{}\t{}",
                project_id,
                work_item.id,
                encode_title(&work_item.title),
                work_item.created_at,
                work_item.updated_at
            );
        }
        println!("CROSS_CONTRACT_RETRY=PASS\t{case_id}");
    }
    println!("CROSS_CONTRACT_DONE");
}
