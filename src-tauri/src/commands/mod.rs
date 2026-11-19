//! Tauri 命令（最小受限 IPC）。
//!
//! 当前暴露：
//! - 数据库健康检查（T1-01）；
//! - 项目列表 / 创建 / 编辑 / 归档（T1-02）；
//! - 工作事项创建 / 待安排列表（T1-03）。
//!
//! 刻意不提供：`execute_sql`、`query_sql`、任意文件读写或任意命令执行接口（TD 6.1）。
//!
//! 数据库健康检查会在阻塞线程池中执行（`spawn_blocking`），避免完整
//! `PRAGMA integrity_check` 阻塞 UI/主线程（审计 P2）。IPC DTO 契约保持不变。

pub mod projects;
pub mod work_items;

use serde::Serialize;
use tauri::Manager;
use workmanager_core::{DatabaseError, ProjectError, WorkItemError};

use crate::app_state::{AppState, DatabaseHealthResponse};

/// 命令错误 DTO：稳定错误码 + 面向用户的中文消息。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandError {
    pub code: String,
    pub message: String,
}

impl From<DatabaseError> for CommandError {
    fn from(error: DatabaseError) -> Self {
        Self {
            code: error.code().to_string(),
            message: error.to_string(),
        }
    }
}

impl From<ProjectError> for CommandError {
    fn from(error: ProjectError) -> Self {
        Self {
            code: error.code().to_string(),
            message: error.to_string(),
        }
    }
}

impl From<WorkItemError> for CommandError {
    fn from(error: WorkItemError) -> Self {
        Self {
            code: error.code().to_string(),
            message: error.to_string(),
        }
    }
}

/// 返回数据库状态、schema 版本和便携数据库路径（仅诊断用途）。
///
/// 实现要点（审计 P2）：
/// - `async` 命令 + `tauri::async_runtime::spawn_blocking`：同步 rusqlite 操作
///   在阻塞线程池运行，不阻塞主线程；
/// - 只克隆 `Arc` 上下文进入任务，不把 SQLite 连接或任意 SQL 暴露给前端；
/// - 返回 DTO 与修复前完全一致，前端契约无需变化。
#[tauri::command]
pub async fn get_database_health(
    app: tauri::AppHandle,
) -> Result<DatabaseHealthResponse, CommandError> {
    let context = app.state::<AppState>().health_context();

    tauri::async_runtime::spawn_blocking(move || context.run_health_check())
        .await
        .map_err(|error| CommandError {
            code: "database-health-task-failed".to_string(),
            message: format!("数据库健康检查任务执行失败：{error}"),
        })?
        .map_err(CommandError::from)
}
