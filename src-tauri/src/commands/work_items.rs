//! 工作事项 Tauri 命令（T1-03 typed IPC）。
//!
//! 安全边界（AGENTS.md / TD 6.1）：
//! - 只暴露明确的业务命令，不提供任意 SQL、任意文件读写或任意命令执行接口；
//! - 命令层只做参数转发、阻塞线程调度和错误 DTO 转换，不实现工作事项业务规则；
//! - 业务规则（标题规范化、项目存在性/归档校验、默认 pending 状态）与事务在
//!   `workmanager-core` 中执行，SQLite 连接不会进入前端；
//! - 所有命令都是 `async` + `spawn_blocking`：SQLite 操作在阻塞线程池执行，
//!   不阻塞 Tauri UI 主线程。

use serde::Deserialize;
use tauri::Manager;
use workmanager_core::{PendingWorkItem, WorkItem, WorkItemError};

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
    use workmanager_core::{PendingWorkItem, WORK_ITEM_STATUS_PENDING, WorkItem};

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

    #[test]
    fn created_work_item_serializes_camel_case_contract() {
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
        assert_eq!(value["projectId"], serde_json::Value::Null);
        assert_eq!(value["lifecycleStatus"], "pending");
        assert_eq!(value["createdAt"], "2026-11-19T10:00:00.000Z");
        assert_eq!(value["updatedAt"], "2026-11-19T10:00:00.000Z");
        assert!(value.get("project_id").is_none());
        assert!(value.get("lifecycle_status").is_none());
        assert_eq!(
            value.as_object().expect("对象").len(),
            10,
            "创建 DTO 只包含已定义字段"
        );
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
    fn command_error_maps_work_item_codes() {
        for (error, expected_code) in [
            (WorkItemError::EmptyTitle, "work-item-title-empty"),
            (WorkItemError::ProjectNotFound, "project-not-found"),
            (WorkItemError::ProjectArchived, "project-archived"),
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
