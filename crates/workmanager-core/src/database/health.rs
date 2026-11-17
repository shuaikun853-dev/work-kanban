//! 数据库健康检查 DTO 与构建逻辑。
//!
//! 健康检查只返回数据库状态与配置诊断信息，不包含任何用户工作内容；
//! `databasePath` 仅用于开发诊断与便携路径核验（T1-01 要求）。

use std::path::Path;

use chrono::{SecondsFormat, Utc};
use rusqlite::Connection;
use serde::Serialize;

use super::{connection, migrations};
use crate::error::DatabaseError;

/// 已应用的 migration 审计记录。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppliedMigration {
    pub version: i64,
    pub name: String,
    pub applied_at: String,
}

/// 数据库健康快照。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DatabaseHealth {
    /// 固定为 `ok`；失败时由命令返回结构化错误，不会伪造健康状态。
    pub status: String,
    pub schema_version: i64,
    pub latest_schema_version: i64,
    pub database_path: String,
    pub database_file_size_bytes: u64,
    /// `PRAGMA integrity_check` 的结果，通过时必须为 `ok`。
    pub integrity_check: String,
    pub foreign_key_violations: i64,
    pub journal_mode: String,
    pub synchronous: i64,
    pub foreign_keys: bool,
    pub busy_timeout_ms: i64,
    pub temp_store: i64,
    pub applied_migrations: Vec<AppliedMigration>,
    /// 检查时间（UTC RFC3339），不包含用户数据。
    pub checked_at: String,
}

pub(crate) fn build_health(
    connection: &Connection,
    database_path: &Path,
) -> Result<DatabaseHealth, DatabaseError> {
    let schema_version = migrations::read_schema_version(connection, database_path)?;
    let integrity_check = connection::run_integrity_check(connection, database_path)?;
    let foreign_key_violations =
        connection::count_foreign_key_violations(connection, database_path)?;

    let journal_mode =
        connection::pragma_read_text(connection, database_path, "PRAGMA journal_mode")?;
    let synchronous = connection::pragma_read_i64(connection, database_path, "PRAGMA synchronous")?;
    let foreign_keys_raw =
        connection::pragma_read_i64(connection, database_path, "PRAGMA foreign_keys")?;
    let busy_timeout_ms =
        connection::pragma_read_i64(connection, database_path, "PRAGMA busy_timeout")?;
    let temp_store = connection::pragma_read_i64(connection, database_path, "PRAGMA temp_store")?;

    let applied_migrations = read_applied_migrations(connection, database_path)?;
    let database_file_size_bytes = std::fs::metadata(database_path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);

    Ok(DatabaseHealth {
        status: "ok".to_string(),
        schema_version,
        latest_schema_version: migrations::LATEST_SCHEMA_VERSION,
        database_path: database_path.display().to_string(),
        database_file_size_bytes,
        integrity_check,
        foreign_key_violations,
        journal_mode,
        synchronous,
        foreign_keys: foreign_keys_raw == connection::FOREIGN_KEYS_ON,
        busy_timeout_ms,
        temp_store,
        applied_migrations,
        checked_at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
    })
}

fn read_applied_migrations(
    connection: &Connection,
    database_path: &Path,
) -> Result<Vec<AppliedMigration>, DatabaseError> {
    let mut statement = connection
        .prepare("SELECT version, name, applied_at FROM schema_migrations ORDER BY version ASC")
        .map_err(|error| {
            connection::map_sqlite_error("读取 migration 记录", database_path, error)
        })?;

    let rows = statement
        .query_map([], |row| {
            Ok(AppliedMigration {
                version: row.get(0)?,
                name: row.get(1)?,
                applied_at: row.get(2)?,
            })
        })
        .map_err(|error| {
            connection::map_sqlite_error("查询 migration 记录", database_path, error)
        })?;

    let mut migrations = Vec::new();
    for row in rows {
        migrations.push(row.map_err(|error| {
            connection::map_sqlite_error("读取 migration 记录行", database_path, error)
        })?);
    }
    Ok(migrations)
}
