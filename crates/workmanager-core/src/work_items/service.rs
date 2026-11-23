//! 工作事项应用服务：业务规则与事务边界。
//!
//! Rust Core 是工作事项状态的唯一权威来源：
//! - 创建操作在 [`crate::database::Database::write_transaction`] 的 `IMMEDIATE` 事务内完成；
//! - 项目存在性与归档状态（DEC-033）与工作事项插入处于同一事务，前端过滤不是安全边界；
//! - 工作事项 ID 由 Rust Core 生成（UUID v4），前端不得自行构造业务身份；
//! - 创建后的状态固定为 `pending`（待安排），不伪造重要程度/紧急程度/日期等未设置字段；
//! - 待安排查询只返回数据库中的真实 `pending` 记录（含关联归档项目的历史工作）。

use chrono::{SecondsFormat, Utc};
use uuid::Uuid;

use crate::database::Database;

use super::error::WorkItemError;
use super::model::{PendingWorkItem, WORK_ITEM_STATUS_PENDING, WorkItem, normalize_title};
use super::repository;

/// 工作事项应用服务（无状态）。
pub struct WorkItemService;

impl WorkItemService {
    /// 创建工作事项并返回数据库中的最终记录。
    ///
    /// 规则：
    /// - 标题首尾空白规范化，空标题返回 `work-item-title-empty`；
    /// - `project_id = None` 表示未归属项目，允许创建；
    /// - 指定项目时，在同一个 `IMMEDIATE` 写事务内校验项目存在且未归档：
    ///   不存在返回 `project-not-found`，已归档返回 `project-archived`；
    /// - 相同标题不去重，每次创建都是独立记录。
    pub fn create(
        database: &mut Database,
        raw_title: &str,
        project_id: Option<&str>,
    ) -> Result<WorkItem, WorkItemError> {
        let title = normalize_title(raw_title)?;
        let timestamp = now_utc();
        let work_item = WorkItem {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.map(str::to_string),
            title,
            lifecycle_status: WORK_ITEM_STATUS_PENDING.to_string(),
            importance: None,
            urgency: None,
            due_date: None,
            description: None,
            created_at: timestamp.clone(),
            updated_at: timestamp,
        };
        let database_path = database.database_path().to_path_buf();

        database.write_transaction(move |transaction| {
            // DEC-033：项目校验与插入必须在同一个 IMMEDIATE 写事务中完成。
            // 项目在用户点击保存前被另一个操作归档时，这里看到的是事务内最新状态。
            if let Some(project_id) = work_item.project_id.as_deref() {
                match repository::project_is_archived(transaction, &database_path, project_id)? {
                    None => return Err(WorkItemError::ProjectNotFound),
                    Some(true) => return Err(WorkItemError::ProjectArchived),
                    Some(false) => {}
                }
            }

            repository::insert(transaction, &database_path, &work_item)?;
            repository::find(transaction, &database_path, &work_item.id)?
                .ok_or(WorkItemError::PersistenceVerificationFailed)
        })
    }

    /// 查询全部待安排工作事项（`lifecycle_status = 'pending'`）。
    pub fn list_pending(database: &Database) -> Result<Vec<PendingWorkItem>, WorkItemError> {
        repository::list_pending(
            database.connection(),
            database.database_path(),
            WORK_ITEM_STATUS_PENDING,
        )
    }
}

/// 工作事项时间戳统一使用 UTC RFC3339（毫秒精度），展示时由前端转换为业务时区。
fn now_utc() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}
