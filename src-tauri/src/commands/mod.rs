//! Tauri 命令（最小受限 IPC）。
//!
//! 当前只暴露数据库健康检查。刻意不提供：
//! `execute_sql`、`query_sql`、任意文件读写或任意命令执行接口（TD 6.1）。

use serde::Serialize;
use tauri::State;
use workmanager_core::DatabaseError;

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

/// 返回数据库状态、schema 版本和便携数据库路径（仅诊断用途）。
#[tauri::command]
pub fn get_database_health(
    state: State<'_, AppState>,
) -> Result<DatabaseHealthResponse, CommandError> {
    state.database_health().map_err(CommandError::from)
}
