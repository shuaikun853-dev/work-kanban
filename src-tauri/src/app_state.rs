//! Tauri 应用状态：便携路径 + 单连接数据库（`Mutex` 串行化访问，TD 6.2）。
//!
//! 数据库健康检查执行完整 `PRAGMA integrity_check`，属于耗时阻塞操作；
//! 命令层通过 `spawn_blocking` 在阻塞线程池执行，不占用 UI/主线程（审计 P2）。
//! 这里只暴露“可跨线程克隆的上下文”，不向前端暴露 SQLite 连接。
//!
//! T1-02 新增项目上下文：命令层只通过 [`ProjectService`] 调用项目业务规则，
//! Tauri 适配层不包含项目业务判断，也不向前端暴露 SQL。
//!
//! T1-03 新增工作事项上下文：命令层只通过 [`WorkItemService`] 调用工作事项业务规则；
//! 标题校验、项目归档校验（DEC-033）与事务边界都在 Rust Core 中。

use std::sync::{Arc, Mutex};

use serde::Serialize;
use workmanager_core::{
    CreatedWorkItemCopies, Database, DatabaseError, DatabaseHealth, PendingWorkItem, PortablePaths,
    Project, ProjectError, ProjectService, WorkItem, WorkItemError, WorkItemService,
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

    /// 创建可移动到 `spawn_blocking` 任务中的工作事项命令上下文。
    pub fn work_item_context(&self) -> WorkItemContext {
        WorkItemContext {
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

/// 工作事项命令的线程安全上下文（`Send + 'static`，供 `spawn_blocking` 使用）。
///
/// 命令层只能调用本上下文暴露的业务方法；不返回 SQLite 连接、不执行任意 SQL。
#[derive(Clone)]
pub struct WorkItemContext {
    database: Arc<Mutex<Option<Database>>>,
}

impl WorkItemContext {
    /// 创建工作事项（标题校验与项目归档校验在 Rust Core 事务内完成）。
    pub fn create_work_item(
        &self,
        title: &str,
        project_id: Option<&str>,
    ) -> Result<WorkItem, WorkItemError> {
        let mut guard = self.lock_database()?;
        let database = guard
            .as_mut()
            .ok_or_else(|| work_item_database_closed_error("创建工作事项"))?;
        WorkItemService::create(database, title, project_id)
    }

    /// 查询待安排工作事项（只读连接）。
    pub fn list_pending_work_items(&self) -> Result<Vec<PendingWorkItem>, WorkItemError> {
        let guard = self.lock_database()?;
        let database = guard
            .as_ref()
            .ok_or_else(|| work_item_database_closed_error("查询待安排工作列表"))?;
        WorkItemService::list_pending(database)
    }

    /// 为多个项目批量创建独立工作副本（整批原子提交在 Rust Core 事务内完成）。
    pub fn create_work_item_copies(
        &self,
        title: &str,
        project_ids: &[String],
    ) -> Result<CreatedWorkItemCopies, WorkItemError> {
        let mut guard = self.lock_database()?;
        let database = guard
            .as_mut()
            .ok_or_else(|| work_item_database_closed_error("批量创建工作事项副本"))?;
        WorkItemService::create_copies(database, title, project_ids)
    }

    fn lock_database(&self) -> Result<std::sync::MutexGuard<'_, Option<Database>>, WorkItemError> {
        self.database.lock().map_err(|_| {
            work_item_database_error(
                "数据库连接互斥锁",
                "数据库连接锁已中毒（前一次操作发生 panic），请重启 WorkManager",
            )
        })
    }
}

fn work_item_database_closed_error(context: &'static str) -> WorkItemError {
    work_item_database_error(
        context,
        "数据库连接已关闭（应用正在退出），无法处理工作事项请求",
    )
}

fn work_item_database_error(context: &'static str, detail: &str) -> WorkItemError {
    WorkItemError::Database(DatabaseError::Sqlite {
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

    /// T1-03：工作事项命令上下文必须通过 Rust Core 完成真实创建/查询，
    /// 并在事务内遵守 DEC-033（归档项目拒绝新关联，历史关联保留）。
    #[test]
    fn work_item_context_runs_real_lifecycle_against_database() {
        let data_root = unique_test_data_root();
        std::fs::create_dir_all(&data_root).expect("create D-drive test data root");
        let exe_path = data_root.join("WorkManager.exe");
        let paths = PortablePaths::resolve(RuntimeMode::DebugTest, &exe_path, Some(&data_root))
            .expect("resolve test portable paths");
        paths.ensure_directories().expect("ensure portable layout");
        let database = Database::initialize(&paths).expect("initialize database");

        let state = AppState::new(paths.clone(), database);
        let work_item_context = state.work_item_context();
        assert_send(&work_item_context);
        let project_context = state.project_context();

        assert!(
            work_item_context
                .list_pending_work_items()
                .expect("empty pending list")
                .is_empty(),
            "新数据库不应包含工作事项"
        );

        // 未归属工作：仅标题即可创建，默认 pending。
        let unassigned = work_item_context
            .create_work_item("  整理中核商品数据  ", None)
            .expect("create unassigned work item");
        assert_eq!(unassigned.title, "整理中核商品数据");
        assert_eq!(unassigned.lifecycle_status, "pending");
        assert_eq!(unassigned.project_id, None);
        assert_ne!(unassigned.id, "");
        assert_eq!(unassigned.created_at, unassigned.updated_at);

        // 相同标题产生独立记录。
        let duplicate = work_item_context
            .create_work_item("整理中核商品数据", None)
            .expect("create duplicate title work item");
        assert_ne!(duplicate.id, unassigned.id);

        // 有效未归档项目关联成功。
        let project = project_context
            .create_project("虚构 IPC 项目")
            .expect("create project");
        let linked = work_item_context
            .create_work_item("关联项目的工作", Some(&project.id))
            .expect("create linked work item");
        assert_eq!(linked.project_id.as_deref(), Some(project.id.as_str()));

        // 归档项目后：既有工作关联保留；新建关联被拒绝（DEC-033）。
        project_context
            .archive_project(&project.id)
            .expect("archive project");
        let pending = work_item_context
            .list_pending_work_items()
            .expect("list pending work items");
        assert_eq!(pending.len(), 3);
        let archived_link = pending
            .iter()
            .find(|item| item.id == linked.id)
            .expect("archived linked item must remain in pending list");
        assert_eq!(
            archived_link.project_name.as_deref(),
            Some("虚构 IPC 项目"),
            "历史关联必须保留项目名称"
        );
        assert!(archived_link.project_is_archived);

        let error = work_item_context
            .create_work_item("不应创建的工作", Some(&project.id))
            .expect_err("已归档项目必须拒绝");
        assert_eq!(error.code(), "project-archived");

        let error = work_item_context
            .create_work_item("不存在项目的工作", Some("missing-project-id"))
            .expect_err("不存在项目必须拒绝");
        assert_eq!(error.code(), "project-not-found");

        let error = work_item_context
            .create_work_item("   ", None)
            .expect_err("空白标题必须拒绝");
        assert_eq!(error.code(), "work-item-title-empty");

        // 应用退出关闭连接后，工作事项命令必须返回结构化错误而不是 panic。
        state.shutdown();
        let error = work_item_context
            .list_pending_work_items()
            .expect_err("数据库关闭后必须返回结构化错误");
        assert_eq!(error.code(), "database-sqlite-error");

        let _ = std::fs::remove_dir_all(&data_root);
    }

    /// T1-04：多项目批量创建必须通过 Rust Core 在同一事务内完成；
    /// 归档项目导致整批失败，不得留下任何部分记录。
    #[test]
    fn work_item_context_batch_creates_copies_and_rolls_back_whole_batch() {
        let data_root = unique_test_data_root();
        std::fs::create_dir_all(&data_root).expect("create D-drive test data root");
        let exe_path = data_root.join("WorkManager.exe");
        let paths = PortablePaths::resolve(RuntimeMode::DebugTest, &exe_path, Some(&data_root))
            .expect("resolve test portable paths");
        paths.ensure_directories().expect("ensure portable layout");
        let database = Database::initialize(&paths).expect("initialize database");

        let state = AppState::new(paths.clone(), database);
        let work_item_context = state.work_item_context();
        let project_context = state.project_context();
        assert_send(&work_item_context);

        let project_a = project_context
            .create_project("虚构 IPC 批量项目甲")
            .expect("create project A");
        let project_b = project_context
            .create_project("虚构 IPC 批量项目乙")
            .expect("create project B");
        let batch_ids = vec![project_a.id.clone(), project_b.id.clone()];

        let created = work_item_context
            .create_work_item_copies("  IPC 批量创建  ", &batch_ids)
            .expect("batch create via context");
        assert!(!created.group_id.is_empty(), "必须返回创建组 ID");
        assert_eq!(created.work_items.len(), 2);
        assert_eq!(created.work_items[0].title, "IPC 批量创建");
        assert_eq!(created.work_items[0].lifecycle_status, "pending");
        let pending = work_item_context
            .list_pending_work_items()
            .expect("list pending after batch");
        assert_eq!(pending.len(), 2);

        // 归档项目乙：包含甲+乙的批量创建必须整批失败，不得为甲写入部分副本。
        project_context
            .archive_project(&project_b.id)
            .expect("archive project B");
        let error = work_item_context
            .create_work_item_copies("整批失败工作", &batch_ids)
            .expect_err("archived project must fail whole batch");
        assert_eq!(error.code(), "project-archived");
        let pending = work_item_context
            .list_pending_work_items()
            .expect("list pending after failed batch");
        assert_eq!(pending.len(), 2, "失败批次不得留下部分记录");
        assert!(
            !pending.iter().any(|item| item.title == "整批失败工作"),
            "失败批次标题不得落库"
        );

        // 少于两个项目属于 Rust Core 业务校验。
        let error = work_item_context
            .create_work_item_copies("单项目批量请求", &[project_a.id.clone()])
            .expect_err("too few projects must fail");
        assert_eq!(error.code(), "work-item-copies-too-few");

        // 应用退出关闭连接后，批量创建必须返回结构化错误而不是 panic。
        state.shutdown();
        let error = work_item_context
            .create_work_item_copies("数据库关闭后的批量请求", &batch_ids)
            .expect_err("database closed must fail with structured error");
        assert_eq!(error.code(), "database-sqlite-error");

        let _ = std::fs::remove_dir_all(&data_root);
    }
}
