//! Tauri 应用状态：便携路径 + 单连接数据库（`Mutex` 串行化访问，TD 6.2）。
//!
//! 数据库健康检查执行完整 `PRAGMA integrity_check`，属于耗时阻塞操作；
//! 命令层通过 `spawn_blocking` 在阻塞线程池执行，不占用 UI/主线程（审计 P2）。
//! 这里只暴露“可跨线程克隆的上下文”，不向前端暴露 SQLite 连接。
//!
//! T1-02 新增项目上下文：命令层只通过 [`ProjectService`] 调用项目业务规则，
//! Tauri 适配层不包含项目业务判断，也不向前端暴露 SQL。

use std::sync::{Arc, Mutex};

use serde::Serialize;
use workmanager_core::{
    Database, DatabaseError, DatabaseHealth, PortablePaths, Project, ProjectError, ProjectService,
};

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
    paths: Arc<PortablePaths>,
    database: Arc<Mutex<Option<Database>>>,
}

impl AppState {
    pub fn new(paths: PortablePaths, database: Database) -> Self {
        Self {
            paths: Arc::new(paths),
            database: Arc::new(Mutex::new(Some(database))),
        }
    }

    /// 创建可移动到 `spawn_blocking` 任务中的健康检查上下文。
    pub fn health_context(&self) -> DatabaseHealthContext {
        DatabaseHealthContext {
            paths: Arc::clone(&self.paths),
            database: Arc::clone(&self.database),
        }
    }

    /// 创建可移动到 `spawn_blocking` 任务中的项目命令上下文。
    pub fn project_context(&self) -> ProjectContext {
        ProjectContext {
            database: Arc::clone(&self.database),
        }
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

/// 健康检查的线程安全上下文（`Send + 'static`，供 `spawn_blocking` 使用）。
#[derive(Clone)]
pub struct DatabaseHealthContext {
    paths: Arc<PortablePaths>,
    database: Arc<Mutex<Option<Database>>>,
}

impl DatabaseHealthContext {
    /// 同步执行健康检查；只应在阻塞线程池中调用。
    ///
    /// 锁中毒说明此前有数据库操作 panic；此处返回结构化错误，而不是继续使用可能
    /// 不一致的连接。应用退出后连接已被关闭，此时返回明确错误。
    pub fn run_health_check(&self) -> Result<DatabaseHealthResponse, DatabaseError> {
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
}

/// 项目命令的线程安全上下文（`Send + 'static`，供 `spawn_blocking` 使用）。
///
/// 命令层只能调用本上下文暴露的项目业务方法；不返回 SQLite 连接、不执行任意 SQL。
#[derive(Clone)]
pub struct ProjectContext {
    database: Arc<Mutex<Option<Database>>>,
}

impl ProjectContext {
    /// 查询项目列表（只读连接；未归档在前）。
    pub fn list_projects(&self) -> Result<Vec<Project>, ProjectError> {
        let mut guard = self.lock_database()?;
        let database = guard
            .as_mut()
            .ok_or_else(|| database_closed_error("查询项目列表"))?;
        ProjectService::list(database)
    }

    /// 创建项目。
    pub fn create_project(&self, name: &str) -> Result<Project, ProjectError> {
        let mut guard = self.lock_database()?;
        let database = guard
            .as_mut()
            .ok_or_else(|| database_closed_error("创建项目"))?;
        ProjectService::create(database, name)
    }

    /// 编辑项目名称。
    pub fn update_project(&self, project_id: &str, name: &str) -> Result<Project, ProjectError> {
        let mut guard = self.lock_database()?;
        let database = guard
            .as_mut()
            .ok_or_else(|| database_closed_error("编辑项目"))?;
        ProjectService::update(database, project_id, name)
    }

    /// 归档项目（非破坏性标记）。
    pub fn archive_project(&self, project_id: &str) -> Result<Project, ProjectError> {
        let mut guard = self.lock_database()?;
        let database = guard
            .as_mut()
            .ok_or_else(|| database_closed_error("归档项目"))?;
        ProjectService::archive(database, project_id)
    }

    fn lock_database(&self) -> Result<std::sync::MutexGuard<'_, Option<Database>>, ProjectError> {
        self.database.lock().map_err(|_| {
            database_unavailable_error(
                "数据库连接互斥锁",
                "数据库连接锁已中毒（前一次操作发生 panic），请重启 WorkManager",
            )
        })
    }
}

fn database_closed_error(context: &'static str) -> ProjectError {
    database_unavailable_error(
        context,
        "数据库连接已关闭（应用正在退出），无法处理项目请求",
    )
}

fn database_unavailable_error(context: &'static str, detail: &str) -> ProjectError {
    ProjectError::Database(DatabaseError::Sqlite {
        context,
        detail: detail.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;
    use workmanager_core::{Database, LATEST_SCHEMA_VERSION, PortablePaths, RuntimeMode};

    fn unique_test_data_root() -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        std::path::PathBuf::from(format!(
            r"D:\WorkManager-test-data\src-tauri-async-health-{}-{nanos}",
            std::process::id()
        ))
    }

    fn assert_send<T: Send>(_: &T) {}

    /// 审计 P2：健康检查必须能在 Tauri 阻塞线程池执行，且 IPC DTO 契约保持不变。
    #[test]
    fn health_check_runs_on_blocking_pool_and_returns_unchanged_contract() {
        let data_root = unique_test_data_root();
        std::fs::create_dir_all(&data_root).expect("create D-drive test data root");
        let exe_path = data_root.join("WorkManager.exe");
        let paths = PortablePaths::resolve(RuntimeMode::DebugTest, &exe_path, Some(&data_root))
            .expect("resolve test portable paths");
        paths.ensure_directories().expect("ensure portable layout");
        let database = Database::initialize(&paths).expect("initialize database");

        let state = AppState::new(paths.clone(), database);
        let context = state.health_context();
        assert_send(&context);

        // 真实使用 Tauri async runtime 的 spawn_blocking，验证线程安全上下文与 DTO。
        let join_handle = tauri::async_runtime::spawn_blocking(move || context.run_health_check());
        let response = tauri::async_runtime::block_on(join_handle)
            .expect("blocking task must join")
            .expect("health check must succeed");

        assert_eq!(response.app_name, "WorkManager");
        assert_eq!(response.app_version, env!("CARGO_PKG_VERSION"));
        assert_eq!(response.runtime_mode, "debug-test");
        assert_eq!(response.database.status, "ok");
        assert_eq!(response.database.schema_version, LATEST_SCHEMA_VERSION);
        assert_eq!(response.database.journal_mode, "wal");
        assert!(response.database.foreign_keys);
        assert_eq!(response.database.busy_timeout_ms, 5000);
        assert_eq!(
            response.database_path,
            paths.database_file.display().to_string()
        );
        assert_eq!(
            response.database.database_path,
            paths.database_file.display().to_string()
        );

        // 正常退出关闭连接后，只清理本测试创建的 D 盘隔离目录。
        state.shutdown();
        let _ = std::fs::remove_dir_all(&data_root);
    }

    /// T1-02：项目命令上下文必须通过 Rust Core 完成真实 CRUD，
    /// 且错误以稳定错误码返回；不向命令层泄露 SQLite 连接。
    #[test]
    fn project_context_runs_real_project_lifecycle_against_database() {
        let data_root = unique_test_data_root();
        std::fs::create_dir_all(&data_root).expect("create D-drive test data root");
        let exe_path = data_root.join("WorkManager.exe");
        let paths = PortablePaths::resolve(RuntimeMode::DebugTest, &exe_path, Some(&data_root))
            .expect("resolve test portable paths");
        paths.ensure_directories().expect("ensure portable layout");
        let database = Database::initialize(&paths).expect("initialize database");

        let state = AppState::new(paths.clone(), database);
        let context = state.project_context();
        assert_send(&context);

        assert!(
            context
                .list_projects()
                .expect("empty project list")
                .is_empty(),
            "新数据库不应包含项目"
        );

        let created = context
            .create_project("  虚构 IPC 项目  ")
            .expect("create project via context");
        assert_eq!(created.name, "虚构 IPC 项目");
        assert!(!created.is_archived);

        let listed = context.list_projects().expect("list projects via context");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, created.id);

        let updated = context
            .update_project(&created.id, "虚构 IPC 项目（编辑）")
            .expect("update project via context");
        assert_eq!(updated.name, "虚构 IPC 项目（编辑）");

        let archived = context
            .archive_project(&created.id)
            .expect("archive project via context");
        assert!(archived.is_archived);
        assert_eq!(
            context.list_projects().expect("list after archive").len(),
            1,
            "归档不得删除项目记录"
        );

        let error = context
            .update_project(&created.id, "不应成功")
            .expect_err("已归档项目必须拒绝编辑");
        assert_eq!(error.code(), "project-archived");

        let error = context.create_project("   ").expect_err("空白名称必须失败");
        assert_eq!(error.code(), "project-name-empty");

        // 应用退出关闭连接后，项目命令必须返回结构化错误而不是 panic。
        state.shutdown();
        let error = context
            .list_projects()
            .expect_err("数据库关闭后必须返回结构化错误");
        assert_eq!(error.code(), "database-sqlite-error");

        let _ = std::fs::remove_dir_all(&data_root);
    }
}
