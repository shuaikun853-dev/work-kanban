//! 工作事项 Tauri 命令（T1-03 / T1-04 typed IPC）。
//!
//! 安全边界（AGENTS.md / TD 6.1）：
//! - 只暴露明确的业务命令，不提供任意 SQL、任意文件读写或任意命令执行接口；
//! - 命令层只做参数转发、阻塞线程调度和错误 DTO 转换，不实现工作事项业务规则；
//! - 业务规则（标题规范化、项目存在性/归档校验、默认 pending 状态、多项目整批原子提交）
//!   与事务在 `workmanager-core` 中执行，SQLite 连接不会进入前端；
//! - 所有命令都是 `async` + `spawn_blocking`：SQLite 操作在阻塞线程池执行，
//!   不阻塞 Tauri UI 主线程。

use serde::Deserialize;
use tauri::Manager;
use workmanager_core::{CreatedWorkItemCopies, PendingWorkItem, WorkItem, WorkItemError};

use super::CommandError;
use crate::app_state::{AppState, WorkItemContext};

/// 创建工作事项请求。
///
/// - `title` 必填，由 Rust Core 负责 trim 与空值拒绝；
/// - `projectId` 显式 `null` 表示未归属项目；字段缺省同样按 `null` 处理。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateWorkItemRequest {
    pub title: String,
    #[serde(default)]
    pub project_id: Option<String>,
}

/// 创建多项目独立副本请求（T1-04）。
///
/// - `title` 必填，由 Rust Core 负责 trim 与空值拒绝；
/// - `projectIds` 必填字符串数组：批量接口由 Rust Core 校验“至少两个项目且不重复”，
///   命令层不做业务校验，只做 serde 结构校验（`deny_unknown_fields`）。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateWorkItemCopiesRequest {
    pub title: String,
    pub project_ids: Vec<String>,
}

/// 创建工作事项并返回数据库中的最终记录。
///
/// ID、默认生命周期状态 `pending` 与时间戳全部由 Rust Core 生成；前端不得自行生成业务 ID。
#[tauri::command]
pub async fn create_work_item(
    app: tauri::AppHandle,
    input: CreateWorkItemRequest,
) -> Result<WorkItem, CommandError> {
    run_work_item_command(app, move |context| {
        context.create_work_item(&input.title, input.project_id.as_deref())
    })
    .await
}

/// 为多个项目批量创建互相独立的工作事项副本（整批原子提交，DEC-034）。
///
/// 任意项目不存在/已归档或任意写入失败时整批回滚，命令层不实现该规则。
#[tauri::command]
pub async fn create_work_item_copies(
    app: tauri::AppHandle,
    input: CreateWorkItemCopiesRequest,
) -> Result<CreatedWorkItemCopies, CommandError> {
    run_work_item_command(app, move |context| {
        context.create_work_item_copies(&input.title, &input.project_ids)
    })
    .await
}

/// 查询待安排工作事项（`lifecycle_status = 'pending'`，含未归属与已归档项目历史关联）。
#[tauri::command]
pub async fn list_pending_work_items(
    app: tauri::AppHandle,
) -> Result<Vec<PendingWorkItem>, CommandError> {
    run_work_item_command(app, |context| context.list_pending_work_items()).await
}

async fn run_work_item_command<T, F>(app: tauri::AppHandle, action: F) -> Result<T, CommandError>
where
    T: Send + 'static,
    F: FnOnce(&WorkItemContext) -> Result<T, WorkItemError> + Send + 'static,
{
    let context = app.state::<AppState>().work_item_context();

    tauri::async_runtime::spawn_blocking(move || action(&context))
        .await
        .map_err(|error| CommandError {
            code: "work-item-task-failed".to_string(),
            message: format!("工作事项命令任务执行失败：{error}"),
        })?
        .map_err(CommandError::from)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use workmanager_core::{
        CreatedWorkItemCopies, PendingWorkItem, WORK_ITEM_STATUS_PENDING, WorkItem,
    };

    #[test]
    fn create_request_accepts_camel_case_null_and_missing_project_id() {
        let with_project: CreateWorkItemRequest = serde_json::from_value(json!({
            "title": "整理中核商品数据",
            "projectId": "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001"
        }))
        .expect("带项目请求");
        assert_eq!(with_project.title, "整理中核商品数据");
        assert_eq!(
            with_project.project_id.as_deref(),
            Some("9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001")
        );

        let unassigned_null: CreateWorkItemRequest =
            serde_json::from_value(json!({ "title": "未归属工作", "projectId": null }))
                .expect("projectId=null 请求");
        assert_eq!(unassigned_null.project_id, None);

        let unassigned_missing: CreateWorkItemRequest =
            serde_json::from_value(json!({ "title": "未归属工作" })).expect("缺省 projectId 请求");
        assert_eq!(unassigned_missing.project_id, None);
    }

    #[test]
    fn create_request_rejects_unknown_fields_and_snake_case() {
        assert!(
            serde_json::from_value::<CreateWorkItemRequest>(json!({
                "title": "虚构工作",
                "unexpected": true
            }))
            .is_err(),
            "请求 DTO 必须拒绝未知字段"
        );
        assert!(
            serde_json::from_value::<CreateWorkItemRequest>(json!({
                "title": "虚构工作",
                "project_id": "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001"
            }))
            .is_err(),
            "契约必须使用 camelCase projectId；snake_case 字段应被拒绝"
        );
        assert!(
            serde_json::from_value::<CreateWorkItemRequest>(json!({})).is_err(),
            "title 必填"
        );
    }

    /// Rust `WorkItem` 的 serde 输出字段必须与 TypeScript `WorkItemDto` 逐字段一致：
    /// 10 个 camelCase 字段，四个可空字段为 JSON null，禁止 snake_case 字段。
    #[test]
    fn created_work_item_serializes_full_camel_case_contract() {
        let work_item = WorkItem {
            id: "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001".to_string(),
            project_id: None,
            title: "整理中核商品数据".to_string(),
            lifecycle_status: WORK_ITEM_STATUS_PENDING.to_string(),
            importance: None,
            urgency: None,
            due_date: None,
            description: None,
            created_at: "2026-11-19T10:00:00.000Z".to_string(),
            updated_at: "2026-11-19T10:00:00.000Z".to_string(),
        };
        let value = serde_json::to_value(&work_item).expect("序列化工作事项");
        let object = value.as_object().expect("工作事项 JSON 对象");

        let expected_keys = [
            "id",
            "projectId",
            "title",
            "lifecycleStatus",
            "importance",
            "urgency",
            "dueDate",
            "description",
            "createdAt",
            "updatedAt",
        ];
        assert_eq!(
            object.len(),
            expected_keys.len(),
            "创建 DTO 必须只包含 10 个已定义字段"
        );
        for key in expected_keys {
            assert!(
                object.contains_key(key),
                "创建 DTO 必须包含字段 {key}；实际字段：{:?}",
                object.keys().collect::<Vec<_>>()
            );
        }
        for snake_case_key in [
            "project_id",
            "lifecycle_status",
            "due_date",
            "created_at",
            "updated_at",
        ] {
            assert!(
                object.get(snake_case_key).is_none(),
                "创建 DTO 不得包含 snake_case 字段 {snake_case_key}"
            );
        }

        assert_eq!(value["projectId"], serde_json::Value::Null);
        assert_eq!(value["importance"], serde_json::Value::Null);
        assert_eq!(value["urgency"], serde_json::Value::Null);
        assert_eq!(value["dueDate"], serde_json::Value::Null);
        assert_eq!(value["description"], serde_json::Value::Null);
        assert_eq!(value["lifecycleStatus"], "pending");
        assert_eq!(value["createdAt"], "2026-11-19T10:00:00.000Z");
        assert_eq!(value["updatedAt"], "2026-11-19T10:00:00.000Z");
    }

    /// 四个可空字段具有合法值时，序列化类型与字段名保持一致（数字/字符串）。
    #[test]
    fn created_work_item_serializes_optional_values_with_exact_contract() {
        let work_item = WorkItem {
            id: "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001".to_string(),
            project_id: Some("3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000".to_string()),
            title: "关联项目的工作".to_string(),
            lifecycle_status: WORK_ITEM_STATUS_PENDING.to_string(),
            importance: Some(3),
            urgency: Some(5),
            due_date: Some("2026-12-31".to_string()),
            description: Some("虚构描述：已补齐可选字段".to_string()),
            created_at: "2026-11-19T10:00:00.000Z".to_string(),
            updated_at: "2026-11-19T10:00:00.000Z".to_string(),
        };
        let value = serde_json::to_value(&work_item).expect("序列化工作事项");
        assert_eq!(value.as_object().expect("对象").len(), 10);
        assert_eq!(value["importance"], 3);
        assert_eq!(value["urgency"], 5);
        assert_eq!(value["dueDate"], "2026-12-31");
        assert_eq!(value["description"], "虚构描述：已补齐可选字段");
        assert_eq!(value["projectId"], "3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000");
        assert!(value["importance"].is_number(), "importance 必须是数字");
        assert!(value["urgency"].is_number(), "urgency 必须是数字");
    }

    #[test]
    fn pending_work_item_serializes_camel_case_and_null_project() {
        let pending = PendingWorkItem {
            id: "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a002".to_string(),
            project_id: None,
            project_name: None,
            project_is_archived: false,
            title: "未归属工作".to_string(),
            lifecycle_status: WORK_ITEM_STATUS_PENDING.to_string(),
            created_at: "2026-11-19T10:00:00.000Z".to_string(),
            updated_at: "2026-11-19T10:00:00.000Z".to_string(),
        };
        let value = serde_json::to_value(&pending).expect("序列化待安排工作");
        assert_eq!(value["projectId"], serde_json::Value::Null);
        assert_eq!(value["projectName"], serde_json::Value::Null);
        assert_eq!(value["projectIsArchived"], false);
        assert_eq!(value["lifecycleStatus"], "pending");
        assert!(value.get("project_is_archived").is_none());
        assert_eq!(value.as_object().expect("对象").len(), 8);

        let archived = PendingWorkItem {
            project_id: Some("9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a003".to_string()),
            project_name: Some("虚构归档项目".to_string()),
            project_is_archived: true,
            ..pending
        };
        let archived_value = serde_json::to_value(&archived).expect("序列化归档项目关联");
        assert_eq!(
            archived_value["projectName"],
            serde_json::Value::String("虚构归档项目".to_string())
        );
        assert_eq!(archived_value["projectIsArchived"], true);
    }

    #[test]
    fn create_copies_request_accepts_camel_case_array() {
        let request: CreateWorkItemCopiesRequest = serde_json::from_value(json!({
            "title": "中核商品价格异常排查",
            "projectIds": ["project-a", "project-b"]
        }))
        .expect("合法批量创建请求");
        assert_eq!(request.title, "中核商品价格异常排查");
        assert_eq!(request.project_ids, vec!["project-a", "project-b"]);

        // “至少两个项目”属于 Rust Core 业务规则：命令层只校验结构，
        // 因此单元素数组在 serde 层是合法请求，必须在 Core 返回稳定错误码。
        let single: CreateWorkItemCopiesRequest = serde_json::from_value(json!({
            "title": "单项目请求",
            "projectIds": ["project-a"]
        }))
        .expect("结构合法的单项目请求");
        assert_eq!(single.project_ids.len(), 1);
    }

    #[test]
    fn create_copies_request_rejects_invalid_shapes() {
        for invalid in [
            json!({ "projectIds": ["a", "b"] }),
            json!({ "title": "x" }),
            json!({ "title": "x", "projectIds": null }),
            json!({ "title": "x", "projectIds": "a,b" }),
            json!({ "title": "x", "projectIds": [1, 2] }),
            json!({ "title": "x", "projectIds": ["a", "b"], "extra": true }),
            json!({ "title": "x", "project_ids": ["a", "b"] }),
        ] {
            assert!(
                serde_json::from_value::<CreateWorkItemCopiesRequest>(invalid.clone()).is_err(),
                "非法批量创建请求必须被拒绝：{invalid}"
            );
        }
    }

    /// Rust `CreatedWorkItemCopies` 的 serde 输出必须恰好为 `{groupId, workItems}`，
    /// `workItems` 每项复用 `WorkItem` 的 10 字段 camelCase 契约。
    #[test]
    fn created_copies_serialize_full_camel_case_contract() {
        let first = WorkItem {
            id: "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a010".to_string(),
            project_id: Some("11111111-1111-4111-8111-111111111111".to_string()),
            title: "中核商品价格异常排查".to_string(),
            lifecycle_status: WORK_ITEM_STATUS_PENDING.to_string(),
            importance: None,
            urgency: None,
            due_date: None,
            description: None,
            created_at: "2026-11-24T10:00:00.000Z".to_string(),
            updated_at: "2026-11-24T10:00:00.000Z".to_string(),
        };
        let second = WorkItem {
            id: "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a011".to_string(),
            project_id: Some("22222222-2222-4222-8222-222222222222".to_string()),
            ..first.clone()
        };
        let response = CreatedWorkItemCopies {
            group_id: "33333333-3333-4333-8333-333333333333".to_string(),
            work_items: vec![first, second],
        };
        let value = serde_json::to_value(&response).expect("序列化批量创建结果");
        let object = value.as_object().expect("批量创建结果 JSON 对象");
        assert_eq!(object.len(), 2, "批量创建结果只能有两个字段");
        assert_eq!(value["groupId"], "33333333-3333-4333-8333-333333333333");
        assert!(value.get("group_id").is_none(), "禁止 snake_case 字段");
        let items = value["workItems"].as_array().expect("workItems 数组");
        assert_eq!(items.len(), 2);
        for item in items {
            let item_object = item.as_object().expect("工作副本对象");
            assert_eq!(item_object.len(), 10, "每个副本必须是 10 字段 WorkItem");
            assert_eq!(item["lifecycleStatus"], "pending");
            assert_eq!(item["importance"], serde_json::Value::Null);
            assert_eq!(item["urgency"], serde_json::Value::Null);
            assert_eq!(item["dueDate"], serde_json::Value::Null);
            assert_eq!(item["description"], serde_json::Value::Null);
            assert!(item["projectId"].is_string());
        }
        assert_eq!(items[0]["id"], "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a010");
        assert_eq!(items[1]["id"], "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a011");
    }

    #[test]
    fn command_error_maps_work_item_codes() {
        for (error, expected_code) in [
            (WorkItemError::EmptyTitle, "work-item-title-empty"),
            (WorkItemError::ProjectNotFound, "project-not-found"),
            (WorkItemError::ProjectArchived, "project-archived"),
            (
                WorkItemError::CopiesTooFewProjects,
                "work-item-copies-too-few",
            ),
            (
                WorkItemError::CopiesDuplicateProject,
                "work-item-copies-duplicate-project",
            ),
        ] {
            let command_error = CommandError::from(error);
            assert_eq!(command_error.code, expected_code);
            assert!(
                !command_error.message.contains("SELECT"),
                "错误消息不得包含 SQL"
            );
        }
    }
}
