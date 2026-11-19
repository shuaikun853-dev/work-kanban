//! 编号 SQL migration：`PRAGMA user_version` + `schema_migrations` 审计表。
//!
//! 规则（T1-01 要求）：
//! - migration 从 1 开始按编号连续递增，按顺序执行；
//! - 每个 migration 在独立事务中执行，失败立即回滚，`user_version` 不得前进；
//! - 版本高于应用支持的数据库 fail-closed，绝不自动降级或覆盖；
//! - 不引入 ORM 或第三方 migration crate，保持简单可测试。

use std::path::Path;

use chrono::{SecondsFormat, Utc};
use rusqlite::{Connection, TransactionBehavior, params};

use super::connection::map_sqlite_error;
use crate::error::DatabaseError;

/// 当前应用支持的最新 schema 版本。
pub const LATEST_SCHEMA_VERSION: i64 = 3;

/// 一个编号 SQL migration。
#[derive(Debug, Clone, Copy)]
pub struct Migration {
    pub version: i64,
    pub name: &'static str,
    pub sql: &'static str,
}

/// 内置 migration 列表；SQL 在编译期嵌入可执行文件，运行时不需要外部文件。
pub const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        name: "0001_initial_foundation",
        sql: include_str!("../../migrations/0001_initial_foundation.sql"),
    },
    Migration {
        version: 2,
        name: "0002_projects",
        sql: include_str!("../../migrations/0002_projects.sql"),
    },
    Migration {
        version: 3,
        name: "0003_work_items",
        sql: include_str!("../../migrations/0003_work_items.sql"),
    },
];

/// 一次 migration 执行结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationOutcome {
    pub previous_version: i64,
    pub current_version: i64,
    pub applied_versions: Vec<i64>,
}

impl MigrationOutcome {
    pub fn applied_anything(&self) -> bool {
        !self.applied_versions.is_empty()
    }
}

/// 读取 `PRAGMA user_version`。
pub fn read_schema_version(
    connection: &Connection,
    database_path: &Path,
) -> Result<i64, DatabaseError> {
    connection
        .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
        .map_err(|error| map_sqlite_error("读取 schema 版本", database_path, error))
}

/// 按顺序应用尚未执行的 migration。
///
/// 每个 migration 使用 `IMMEDIATE` 事务：先写 SQL，再写 `schema_migrations`，
/// 最后更新 `user_version`，全部成功后提交。任一步失败都回滚该 migration。
pub fn apply_migrations(
    connection: &mut Connection,
    database_path: &Path,
    migrations: &[Migration],
    latest_schema_version: i64,
) -> Result<MigrationOutcome, DatabaseError> {
    validate_migration_set(migrations, latest_schema_version)?;

    let previous_version = read_schema_version(connection, database_path)?;
    if previous_version > latest_schema_version {
        return Err(DatabaseError::SchemaVersionTooNew {
            found: previous_version,
            supported: latest_schema_version,
        });
    }

    let mut applied_versions = Vec::new();
    for migration in migrations
        .iter()
        .filter(|migration| migration.version > previous_version)
    {
        apply_one_migration(connection, database_path, migration)?;
        applied_versions.push(migration.version);
    }

    let current_version = read_schema_version(connection, database_path)?;
    if current_version != latest_schema_version {
        return Err(DatabaseError::MigrationFailed {
            version: latest_schema_version,
            name: "final-schema-version-check".to_string(),
            detail: format!(
                "migration 执行结束后 schema 版本为 {current_version}，期望 {latest_schema_version}"
            ),
        });
    }

    Ok(MigrationOutcome {
        previous_version,
        current_version,
        applied_versions,
    })
}

fn apply_one_migration(
    connection: &mut Connection,
    database_path: &Path,
    migration: &Migration,
) -> Result<(), DatabaseError> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| map_sqlite_error("开启 migration 事务", database_path, error))?;

    let apply_result = (|| -> Result<(), DatabaseError> {
        transaction
            .execute_batch(migration.sql)
            .map_err(|error| migration_error(migration, format!("SQL 执行失败：{error}")))?;

        transaction
            .execute(
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?1, ?2, ?3)",
                params![migration.version, migration.name, now_utc_rfc3339()],
            )
            .map_err(|error| {
                migration_error(migration, format!("写入 schema_migrations 失败：{error}"))
            })?;

        transaction
            .pragma_update(None, "user_version", migration.version)
            .map_err(|error| {
                migration_error(migration, format!("更新 user_version 失败：{error}"))
            })?;

        Ok(())
    })();

    match apply_result {
        Ok(()) => transaction.commit().map_err(|error| {
            migration_error(migration, format!("提交 migration 事务失败：{error}"))
        }),
        Err(error) => {
            // 显式回滚，确保后续检查能看到未前进的 user_version 与未产生的表。
            let _ = transaction.rollback();
            Err(error)
        }
    }
}

fn migration_error(migration: &Migration, detail: String) -> DatabaseError {
    DatabaseError::MigrationFailed {
        version: migration.version,
        name: migration.name.to_string(),
        detail,
    }
}

/// 校验 migration 定义：从 1 开始连续、无重复、与声明的最新版本一致。
fn validate_migration_set(
    migrations: &[Migration],
    latest_schema_version: i64,
) -> Result<(), DatabaseError> {
    if latest_schema_version < 1 {
        return Err(DatabaseError::InvalidMigrationSet {
            detail: format!("最新 schema 版本必须 >= 1，实际 {latest_schema_version}"),
        });
    }

    for (index, migration) in migrations.iter().enumerate() {
        let expected = index as i64 + 1;
        if migration.version != expected {
            return Err(DatabaseError::InvalidMigrationSet {
                detail: format!(
                    "migration 版本必须从 1 开始连续递增；第 {index} 项期望 {expected}，实际 {}",
                    migration.version
                ),
            });
        }
        if migration.sql.trim().is_empty() {
            return Err(DatabaseError::InvalidMigrationSet {
                detail: format!(
                    "migration {}（{}）SQL 为空",
                    migration.version, migration.name
                ),
            });
        }
    }

    let defined_latest = migrations.len() as i64;
    if defined_latest != latest_schema_version {
        return Err(DatabaseError::InvalidMigrationSet {
            detail: format!(
                "migration 定义共 {defined_latest} 个版本，但声明的最新 schema 版本为 {latest_schema_version}"
            ),
        });
    }

    Ok(())
}

fn now_utc_rfc3339() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}
