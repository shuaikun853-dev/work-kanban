//! `work_items` 表 SQL 访问（只允许由 Rust Core 调用）。
//!
//! 所有 SQL 均使用参数绑定；仓储层不决定事务边界，事务由
//! [`super::service::WorkItemService`] 通过 [`crate::database::Database::write_transaction`] 建立。

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use crate::database::connection::map_sqlite_error;

use super::error::WorkItemError;
use super::model::{PendingWorkItem, WorkItem};

/// 工作事项表查询列顺序，必须与 [`map_work_item_row`] 一致。
const WORK_ITEM_COLUMNS: &str = "id, project_id, title, lifecycle_status, importance, urgency, \
                                 due_date, description, created_at, updated_at";

/// 在同一写事务内读取项目归档状态。
///
/// 返回：
/// - `None`：项目不存在；
/// - `Some(false)`：项目存在且未归档，允许关联；
/// - `Some(true)`：项目已归档，按 DEC-033 拒绝关联。
///
/// 该查询必须与工作事项插入处于同一个 `IMMEDIATE` 事务，防止“项目列表加载后、
/// 提交前项目被归档”的竞态只由前端过滤兜底。
pub(crate) fn project_is_archived(
    transaction: &Transaction<'_>,
    database_path: &Path,
    project_id: &str,
) -> Result<Option<bool>, WorkItemError> {
    transaction
        .query_row(
            "SELECT is_archived FROM projects WHERE id = ?1",
            params![project_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map(|value| value.map(|flag| flag != 0))
        .map_err(|error| map_error("校验工作事项关联项目", database_path, error))
}

/// 插入新工作事项。
pub(crate) fn insert(
    transaction: &Transaction<'_>,
    database_path: &Path,
    work_item: &WorkItem,
) -> Result<(), WorkItemError> {
    transaction
        .execute(
            "INSERT INTO work_items (\
                 id, project_id, title, lifecycle_status, importance, urgency, \
                 due_date, description, created_at, updated_at\
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                work_item.id,
                work_item.project_id,
                work_item.title,
                work_item.lifecycle_status,
                work_item.importance,
                work_item.urgency,
                work_item.due_date,
                work_item.description,
                work_item.created_at,
                work_item.updated_at
            ],
        )
        .map_err(|error| map_error("创建工作事项", database_path, error))?;
    Ok(())
}

/// 按稳定工作事项 ID 查询单条记录。
pub(crate) fn find(
    connection: &Connection,
    database_path: &Path,
    work_item_id: &str,
) -> Result<Option<WorkItem>, WorkItemError> {
    let sql = format!("SELECT {WORK_ITEM_COLUMNS} FROM work_items WHERE id = ?1");
    connection
        .query_row(&sql, params![work_item_id], map_work_item_row)
        .optional()
        .map_err(|error| map_error("查询工作事项", database_path, error))
}

/// 查询待安排工作事项：有/无项目均返回，项目归档后历史关联继续展示。
///
/// 排序固定为创建时间倒序、稳定 ID 次级键；T1-03 不实现手动排序或优先级排序。
pub(crate) fn list_pending(
    connection: &Connection,
    database_path: &Path,
    lifecycle_status: &str,
) -> Result<Vec<PendingWorkItem>, WorkItemError> {
    let mut statement = connection
        .prepare(
            "SELECT w.id, w.project_id, p.name, p.is_archived, w.title, \
                    w.lifecycle_status, w.created_at, w.updated_at \
             FROM work_items w \
             LEFT JOIN projects p ON p.id = w.project_id \
             WHERE w.lifecycle_status = ?1 \
             ORDER BY w.created_at DESC, w.id DESC",
        )
        .map_err(|error| map_error("查询待安排工作列表", database_path, error))?;

    let mut rows = statement
        .query_map(params![lifecycle_status], map_pending_work_item_row)
        .map_err(|error| map_error("读取待安排工作列表", database_path, error))?;

    let mut work_items = Vec::new();
    for row in rows.by_ref() {
        work_items
            .push(row.map_err(|error| map_error("解析待安排工作记录", database_path, error))?);
    }
    Ok(work_items)
}

fn map_work_item_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<WorkItem> {
    Ok(WorkItem {
        id: row.get(0)?,
        project_id: row.get(1)?,
        title: row.get(2)?,
        lifecycle_status: row.get(3)?,
        importance: row.get(4)?,
        urgency: row.get(5)?,
        due_date: row.get(6)?,
        description: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

fn map_pending_work_item_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<PendingWorkItem> {
    let project_archive_flag: Option<i64> = row.get(3)?;
    Ok(PendingWorkItem {
        id: row.get(0)?,
        project_id: row.get(1)?,
        project_name: row.get(2)?,
        // LEFT JOIN：未归属项目时 is_archived 为 NULL，统一映射为 false。
        project_is_archived: project_archive_flag.map(|flag| flag != 0).unwrap_or(false),
        title: row.get(4)?,
        lifecycle_status: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

fn map_error(context: &'static str, database_path: &Path, error: rusqlite::Error) -> WorkItemError {
    WorkItemError::Database(map_sqlite_error(context, database_path, error))
}
