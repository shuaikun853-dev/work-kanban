//! 项目表 SQL 访问（只允许由 Rust Core 调用）。
//!
//! 所有 SQL 均使用参数绑定；仓储层不决定事务边界，事务由 [`super::service::ProjectService`]
//! 通过 [`crate::database::Database::write_transaction`] 建立。

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use crate::database::connection::map_sqlite_error;

use super::error::ProjectError;
use super::model::Project;

/// 项目表查询列顺序，必须与 [`map_project_row`] 一致。
const PROJECT_COLUMNS: &str = "id, name, is_archived, created_at, updated_at";

/// 查询全部项目：未归档在前，归档项目在后；同组按创建时间倒序，id 作为稳定次级键。
pub(crate) fn list(
    connection: &Connection,
    database_path: &Path,
) -> Result<Vec<Project>, ProjectError> {
    let sql = format!(
        "SELECT {PROJECT_COLUMNS} FROM projects \
         ORDER BY is_archived ASC, created_at DESC, id DESC"
    );
    let mut statement = connection
        .prepare(&sql)
        .map_err(|error| map_error("查询项目列表", database_path, error))?;
    let mut rows = statement
        .query_map([], map_project_row)
        .map_err(|error| map_error("读取项目列表", database_path, error))?;

    let mut projects = Vec::new();
    for row in rows.by_ref() {
        projects.push(row.map_err(|error| map_error("解析项目记录", database_path, error))?);
    }
    Ok(projects)
}

/// 按项目 ID 查询单条项目。
pub(crate) fn find(
    connection: &Connection,
    database_path: &Path,
    project_id: &str,
) -> Result<Option<Project>, ProjectError> {
    let sql = format!("SELECT {PROJECT_COLUMNS} FROM projects WHERE id = ?1");
    connection
        .query_row(&sql, params![project_id], map_project_row)
        .optional()
        .map_err(|error| map_error("查询项目", database_path, error))
}

/// 插入新项目。
pub(crate) fn insert(
    transaction: &Transaction<'_>,
    database_path: &Path,
    project: &Project,
) -> Result<(), ProjectError> {
    transaction
        .execute(
            "INSERT INTO projects (id, name, is_archived, created_at, updated_at) \
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                project.id,
                project.name,
                i64::from(project.is_archived),
                project.created_at,
                project.updated_at
            ],
        )
        .map_err(|error| map_error("创建项目", database_path, error))?;
    Ok(())
}

/// 更新项目名称与更新时间。
pub(crate) fn update_name(
    transaction: &Transaction<'_>,
    database_path: &Path,
    project_id: &str,
    name: &str,
    updated_at: &str,
) -> Result<usize, ProjectError> {
    transaction
        .execute(
            "UPDATE projects SET name = ?1, updated_at = ?2 WHERE id = ?3",
            params![name, updated_at, project_id],
        )
        .map_err(|error| map_error("更新项目", database_path, error))
}

/// 归档项目：只更新标记与更新时间，不删除记录。
pub(crate) fn archive(
    transaction: &Transaction<'_>,
    database_path: &Path,
    project_id: &str,
    updated_at: &str,
) -> Result<usize, ProjectError> {
    transaction
        .execute(
            "UPDATE projects SET is_archived = 1, updated_at = ?1 WHERE id = ?2",
            params![updated_at, project_id],
        )
        .map_err(|error| map_error("归档项目", database_path, error))
}

fn map_project_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Project> {
    Ok(Project {
        id: row.get(0)?,
        name: row.get(1)?,
        is_archived: row.get::<_, i64>(2)? != 0,
        created_at: row.get(3)?,
        updated_at: row.get(4)?,
    })
}

fn map_error(context: &'static str, database_path: &Path, error: rusqlite::Error) -> ProjectError {
    ProjectError::Database(map_sqlite_error(context, database_path, error))
}
