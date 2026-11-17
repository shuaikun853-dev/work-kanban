//! Tauri 应用状态：便携路径 + 单连接数据库（`Mutex` 串行化访问，TD 6.2）。

use std::sync::Mutex;

use serde::Serialize;
use workmanager_core::{Database, DatabaseError, DatabaseHealth, PortablePaths};

use crate::APP_NAME;

/// 数据库健康检查命令响应。
///
/// 只包含运行时诊断信息（应用版本、便携路径、数据库状态）；
/// 不包含任何工作内容、客户信息、SQL 或用户数据。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DatabaseHealthResponse {
    pub app_name: &'static str,
    pub app_version: String,
    pub runtime_mode: String,
    pub data_root: String,
    pub database_path: String,
    pub webview2_data_dir: String,
    pub database: DatabaseHealth,
}

pub struct AppState {
    paths: PortablePaths,
    database: Mutex<Option<Database>>,
}

impl AppState {
    pub fn new(paths: PortablePaths, database: Database) -> Self {
        Self {
            paths,
            database: Mutex::new(Some(database)),
        }
    }

    /// 读取数据库健康快照。
    ///
    /// 锁中毒说明此前有数据库操作 panic；此处返回结构化错误，而不是继续使用可能
    /// 不一致的连接。
    pub fn database_health(&self) -> Result<DatabaseHealthResponse, DatabaseError> {
        let guard = self.database.lock().map_err(|_| DatabaseError::Sqlite {
            context: "数据库连接互斥锁",
            detail: "数据库连接锁已中毒（前一次操作发生 panic），请重启 WorkManager".to_string(),
        })?;
        let database = guard.as_ref().ok_or_else(|| DatabaseError::Sqlite {
            context: "数据库连接状态",
            detail: "数据库连接已关闭（应用正在退出），无法读取健康状态".to_string(),
        })?;
        let health = database.health_report()?;

        Ok(DatabaseHealthResponse {
            app_name: APP_NAME,
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            runtime_mode: self.paths.mode.as_str().to_string(),
            data_root: self.paths.data_root.display().to_string(),
            database_path: self.paths.database_file.display().to_string(),
            webview2_data_dir: self.paths.webview2_dir.display().to_string(),
            database: health,
        })
    }

    /// 应用正常退出时显式关闭 SQLite 连接。
    ///
    /// 关闭最后一个连接时 SQLite 会执行 WAL checkpoint 并删除 `-wal`/`-shm`
    /// 附属文件，避免残留未被 checkpoint 的 WAL 内容（虽然重启时 SQLite 也能
    /// 恢复，但显式关闭更容易审计且不留下多余文件）。
    ///
    /// 仅处理正常退出事件；进程被强制结束（任务管理器、断电）时无法执行，
    /// 此时依赖 SQLite WAL 的崩溃恢复能力，启动时仍会执行完整性检查。
    pub fn shutdown(&self) {
        if let Ok(mut guard) = self.database.lock() {
            if let Some(database) = guard.take() {
                drop(database);
            }
        }
    }
}
