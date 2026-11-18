//! 项目 Tauri 命令（T1-02 typed IPC）。
//!
//! 安全边界（AGENTS.md / TD 6.1）：
//! - 只暴露明确的业务命令，不提供任意 SQL、任意文件读写或任意命令执行接口；
//! - 命令层只做参数转发、阻塞线程调度和错误 DTO 转换，不实现项目业务规则；
//! - 项目规则与事务在 `workmanager-core` 中执行，SQLite 连接不会进入前端。
//!
//! 所有命令都是 `async` + `spawn_blocking`：SQLite 写操作在阻塞线程池执行，
//! 不阻塞 Tauri UI 主线程。

use serde::Deserialize;
use tauri::Manager;
use workmanager_core::{Project, ProjectError};

use super::CommandError;
use crate::app_state::{AppState, ProjectContext};

/// 创建项目请求。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateProjectRequest {
    pub name: String,
}

/// 编辑项目请求：必须使用稳定项目 ID。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateProjectRequest {
    pub id: String,
    pub name: String,
}

/// 归档项目请求：必须使用稳定项目 ID。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArchiveProjectRequest {
    pub id: String,
}

/// 查询项目列表。
#[tauri::command]
pub async fn list_projects(app: tauri::AppHandle) -> Result<Vec<Project>, CommandError> {
    run_project_command(app, |context| context.list_projects()).await
}

/// 创建项目并返回数据库中的最终记录。
#[tauri::command]
pub async fn create_project(
    app: tauri::AppHandle,
    input: CreateProjectRequest,
) -> Result<Project, CommandError> {
    run_project_command(app, move |context| context.create_project(&input.name)).await
}

/// 编辑项目名称。
#[tauri::command]
pub async fn update_project(
    app: tauri::AppHandle,
    input: UpdateProjectRequest,
) -> Result<Project, CommandError> {
    run_project_command(app, move |context| {
        context.update_project(&input.id, &input.name)
    })
    .await
}

/// 归档项目（非破坏性标记，不删除项目记录或历史关联）。
#[tauri::command]
pub async fn archive_project(
    app: tauri::AppHandle,
    input: ArchiveProjectRequest,
) -> Result<Project, CommandError> {
    run_project_command(app, move |context| context.archive_project(&input.id)).await
}

async fn run_project_command<T, F>(app: tauri::AppHandle, action: F) -> Result<T, CommandError>
where
    T: Send + 'static,
    F: FnOnce(&ProjectContext) -> Result<T, ProjectError> + Send + 'static,
{
    let context = app.state::<AppState>().project_context();

    tauri::async_runtime::spawn_blocking(move || action(&context))
        .await
        .map_err(|error| CommandError {
            code: "project-task-failed".to_string(),
            message: format!("项目命令任务执行失败：{error}"),
        })?
        .map_err(CommandError::from)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn request_contracts_accept_camel_case_and_reject_unknown_fields() {
        let create: CreateProjectRequest =
            serde_json::from_value(json!({ "name": "虚构项目" })).expect("create request");
        assert_eq!(create.name, "虚构项目");

        let update: UpdateProjectRequest =
            serde_json::from_value(json!({ "id": "project-id", "name": "虚构项目（编辑）" }))
                .expect("update request");
        assert_eq!(update.id, "project-id");
        assert_eq!(update.name, "虚构项目（编辑）");

        let archive: ArchiveProjectRequest =
            serde_json::from_value(json!({ "id": "project-id" })).expect("archive request");
        assert_eq!(archive.id, "project-id");

        assert!(
            serde_json::from_value::<CreateProjectRequest>(
                json!({ "name": "虚构项目", "unexpected": true })
            )
            .is_err(),
            "请求 DTO 必须拒绝未知字段，避免前端契约漂移"
        );
    }

    #[test]
    fn project_response_serializes_camel_case_contract() {
        let project = Project {
            id: "3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000".to_string(),
            name: "虚构项目".to_string(),
            is_archived: false,
            created_at: "2026-11-18T04:00:00.000Z".to_string(),
            updated_at: "2026-11-18T04:00:00.000Z".to_string(),
        };
        let value = serde_json::to_value(&project).expect("serialize project");
        let object = value.as_object().expect("project JSON object");
        assert_eq!(object.len(), 5, "项目 DTO 只包含已定义字段");
        assert_eq!(value["id"], "3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000");
        assert_eq!(value["name"], "虚构项目");
        assert_eq!(value["isArchived"], false);
        assert_eq!(value["createdAt"], "2026-11-18T04:00:00.000Z");
        assert_eq!(value["updatedAt"], "2026-11-18T04:00:00.000Z");
        assert!(object.get("is_archived").is_none());
    }
}
