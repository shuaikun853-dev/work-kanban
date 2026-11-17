//! SQLite 连接打开与 PRAGMA 配置。
//!
//! 生产连接必须满足（T1-01 要求，TD 6.3）：
//! - `foreign_keys = ON`（真实生效，不只是执行过语句）
//! - `journal_mode = WAL`
//! - `synchronous = FULL`（优先数据可靠性）
//! - `busy_timeout = 5000ms`
//! - `temp_store = MEMORY`
//!
//! 打开后统一调用 [`configure`] 并 [`verify`]，避免“配置语句失败但继续写入”的静默降级。

use std::path::Path;
use std::time::Duration;

use rusqlite::{Connection, ErrorCode, OpenFlags};

use crate::error::DatabaseError;

/// busy_timeout：并发写锁最多等待 5 秒，超过后返回明确错误，而不是无限阻塞。
pub const BUSY_TIMEOUT_MS: u32 = 5_000;

/// `PRAGMA synchronous` 的 FULL 取值。
pub const SYNCHRONOUS_FULL: i64 = 2;

/// `PRAGMA temp_store` 的 MEMORY 取值。
pub const TEMP_STORE_MEMORY: i64 = 2;

/// `PRAGMA foreign_keys` 的 ON 取值。
pub const FOREIGN_KEYS_ON: i64 = 1;

/// WAL 日志模式。
pub const JOURNAL_MODE_WAL: &str = "wal";

/// `PRAGMA integrity_check` 通过时的返回值。
pub const INTEGRITY_OK: &str = "ok";

/// 打开已存在的数据库（不创建）。
pub fn open_read_write(path: &Path) -> Result<Connection, DatabaseError> {
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    Connection::open_with_flags(path, flags)
        .map_err(|error| map_sqlite_error("打开已存在的数据库", path, error))
}

/// 打开/创建初始化临时数据库文件。
pub fn open_for_initialization(path: &Path) -> Result<Connection, DatabaseError> {
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
        | OpenFlags::SQLITE_OPEN_CREATE
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    Connection::open_with_flags(path, flags)
        .map_err(|error| map_sqlite_error("创建初始化临时数据库", path, error))
}

/// 应用生产 PRAGMA 配置并验证其真实生效。
pub fn configure(connection: &Connection, path: &Path) -> Result<(), DatabaseError> {
    connection
        .busy_timeout(Duration::from_millis(u64::from(BUSY_TIMEOUT_MS)))
        .map_err(|error| DatabaseError::PragmaFailed {
            pragma: "busy_timeout",
            detail: error.to_string(),
        })?;

    // foreign_keys 必须在任何事务之外设置；SQLite 默认关闭外键。
    connection
        .pragma_update(None, "foreign_keys", true)
        .map_err(|error| sqlite_pragma_error("foreign_keys", path, error))?;

    // journal_mode 会返回一行结果，必须用 query_row 读取并校验。
    let journal_mode = pragma_text(connection, path, "PRAGMA journal_mode = WAL")?;
    if !journal_mode.eq_ignore_ascii_case(JOURNAL_MODE_WAL) {
        return Err(DatabaseError::PragmaFailed {
            pragma: "journal_mode",
            detail: format!("期望 {JOURNAL_MODE_WAL}，实际 {journal_mode}"),
        });
    }

    connection
        .pragma_update(None, "synchronous", "FULL")
        .map_err(|error| sqlite_pragma_error("synchronous", path, error))?;
    connection
        .pragma_update(None, "temp_store", "MEMORY")
        .map_err(|error| sqlite_pragma_error("temp_store", path, error))?;

    verify(connection, path)
}

/// 重新读取 PRAGMA，确认配置没有被驱动或环境悄悄改变。
pub fn verify(connection: &Connection, path: &Path) -> Result<(), DatabaseError> {
    let foreign_keys = pragma_i64(connection, path, "PRAGMA foreign_keys")?;
    if foreign_keys != FOREIGN_KEYS_ON {
        return Err(DatabaseError::PragmaFailed {
            pragma: "foreign_keys",
            detail: format!("期望 {FOREIGN_KEYS_ON}，实际 {foreign_keys}"),
        });
    }

    let journal_mode = pragma_text(connection, path, "PRAGMA journal_mode")?;
    if !journal_mode.eq_ignore_ascii_case(JOURNAL_MODE_WAL) {
        return Err(DatabaseError::PragmaFailed {
            pragma: "journal_mode",
            detail: format!("期望 {JOURNAL_MODE_WAL}，实际 {journal_mode}"),
        });
    }

    let synchronous = pragma_i64(connection, path, "PRAGMA synchronous")?;
    if synchronous != SYNCHRONOUS_FULL {
        return Err(DatabaseError::PragmaFailed {
            pragma: "synchronous",
            detail: format!("期望 FULL({SYNCHRONOUS_FULL})，实际 {synchronous}"),
        });
    }

    let busy_timeout = pragma_i64(connection, path, "PRAGMA busy_timeout")?;
    if busy_timeout != i64::from(BUSY_TIMEOUT_MS) {
        return Err(DatabaseError::PragmaFailed {
            pragma: "busy_timeout",
            detail: format!("期望 {BUSY_TIMEOUT_MS}，实际 {busy_timeout}"),
        });
    }

    let temp_store = pragma_i64(connection, path, "PRAGMA temp_store")?;
    if temp_store != TEMP_STORE_MEMORY {
        return Err(DatabaseError::PragmaFailed {
            pragma: "temp_store",
            detail: format!("期望 MEMORY({TEMP_STORE_MEMORY})，实际 {temp_store}"),
        });
    }

    Ok(())
}

/// 执行完整 `PRAGMA integrity_check`；只有唯一结果 `ok` 才视为通过。
pub fn run_integrity_check(connection: &Connection, path: &Path) -> Result<String, DatabaseError> {
    let mut statement = connection
        .prepare("PRAGMA integrity_check")
        .map_err(|error| map_sqlite_error("准备完整性检查", path, error))?;
    let mut rows = statement
        .query([])
        .map_err(|error| map_sqlite_error("执行完整性检查", path, error))?;
    let mut results = Vec::new();
    while let Some(row) = rows
        .next()
        .map_err(|error| map_sqlite_error("读取完整性检查结果", path, error))?
    {
        let value: String = row
            .get(0)
            .map_err(|error| DatabaseError::IntegrityCheckFailed {
                detail: format!("无法读取完整性检查结果：{error}"),
            })?;
        results.push(value);
    }

    if results.len() == 1 && results[0].eq_ignore_ascii_case(INTEGRITY_OK) {
        Ok(INTEGRITY_OK.to_string())
    } else {
        Err(DatabaseError::IntegrityCheckFailed {
            detail: if results.is_empty() {
                "完整性检查没有返回结果".to_string()
            } else {
                results.join("; ")
            },
        })
    }
}

/// 统计 `PRAGMA foreign_key_check` 返回的违规行数。
pub fn count_foreign_key_violations(
    connection: &Connection,
    path: &Path,
) -> Result<i64, DatabaseError> {
    let mut statement = connection
        .prepare("PRAGMA foreign_key_check")
        .map_err(|error| map_sqlite_error("准备外键检查", path, error))?;
    let mut rows = statement
        .query([])
        .map_err(|error| map_sqlite_error("执行外键检查", path, error))?;
    let mut count = 0i64;
    while rows
        .next()
        .map_err(|error| map_sqlite_error("读取外键检查结果", path, error))?
        .is_some()
    {
        count += 1;
    }
    Ok(count)
}

/// 外键检查不通过时返回错误。
pub fn run_foreign_key_check(connection: &Connection, path: &Path) -> Result<(), DatabaseError> {
    let count = count_foreign_key_violations(connection, path)?;
    if count > 0 {
        return Err(DatabaseError::ForeignKeyViolations { count });
    }
    Ok(())
}

/// 将 WAL 内容合并回主数据库文件，并切换到 `DELETE` 日志模式。
///
/// 只用于“首次初始化临时库 → 安装为正式库”的流程：安装前必须得到单个完整
/// 的数据库文件，否则把主文件硬链接为正式库会丢失仍在 WAL 中的数据。
pub fn consolidate_wal_into_main_file(
    connection: &Connection,
    path: &Path,
) -> Result<(), DatabaseError> {
    let mode = pragma_text(connection, path, "PRAGMA journal_mode = DELETE")?;
    if !mode.eq_ignore_ascii_case("delete") {
        return Err(DatabaseError::WalConsolidationFailed {
            detail: format!("切换到 DELETE 日志模式后返回 {mode}"),
        });
    }
    Ok(())
}

fn pragma_i64(
    connection: &Connection,
    path: &Path,
    sql: &'static str,
) -> Result<i64, DatabaseError> {
    connection
        .query_row(sql, [], |row| row.get::<_, i64>(0))
        .map_err(|error| map_sqlite_error("读取 PRAGMA", path, error))
}

fn pragma_text(
    connection: &Connection,
    path: &Path,
    sql: &'static str,
) -> Result<String, DatabaseError> {
    connection
        .query_row(sql, [], |row| row.get::<_, String>(0))
        .map_err(|error| map_sqlite_error("读取 PRAGMA", path, error))
}

pub(crate) fn pragma_read_i64(
    connection: &Connection,
    path: &Path,
    sql: &'static str,
) -> Result<i64, DatabaseError> {
    pragma_i64(connection, path, sql)
}

pub(crate) fn pragma_read_text(
    connection: &Connection,
    path: &Path,
    sql: &'static str,
) -> Result<String, DatabaseError> {
    pragma_text(connection, path, sql)
}

fn sqlite_pragma_error(pragma: &'static str, path: &Path, error: rusqlite::Error) -> DatabaseError {
    match map_sqlite_error("执行 PRAGMA", path, error) {
        DatabaseError::Sqlite { detail, .. } => DatabaseError::PragmaFailed { pragma, detail },
        other => other,
    }
}

/// 将 rusqlite 错误映射为结构化的 [`DatabaseError`]。
///
/// 关键映射用于满足“错误分类”和 fail-closed 要求：
/// 损坏、非数据库、busy、只读、磁盘满必须可区分。
pub fn map_sqlite_error(
    context: &'static str,
    path: &Path,
    error: rusqlite::Error,
) -> DatabaseError {
    let detail = error.to_string();
    if let rusqlite::Error::SqliteFailure(ffi_error, _message) = &error {
        return match ffi_error.code {
            ErrorCode::DatabaseCorrupt => DatabaseError::Corrupt {
                path: path.to_path_buf(),
                detail,
            },
            ErrorCode::NotADatabase => DatabaseError::NotADatabase {
                path: path.to_path_buf(),
                detail,
            },
            ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked => DatabaseError::Busy { detail },
            ErrorCode::DiskFull => DatabaseError::DiskFull { detail },
            ErrorCode::ReadOnly => DatabaseError::ReadOnly {
                path: path.to_path_buf(),
                detail,
            },
            ErrorCode::CannotOpen => DatabaseError::OpenFailed {
                path: path.to_path_buf(),
                detail,
            },
            _ => DatabaseError::Sqlite { context, detail },
        };
    }

    if matches!(error, rusqlite::Error::InvalidQuery) {
        return DatabaseError::Sqlite { context, detail };
    }

    DatabaseError::Sqlite { context, detail }
}
