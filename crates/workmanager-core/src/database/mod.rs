//! 普通 SQLite 数据库基础设施（T1-01）。
//!
//! 职责：
//! - 打开/创建 `data/database/work.db`；
//! - 生产 PRAGMA 配置（WAL、foreign_keys、busy_timeout、synchronous=FULL、temp_store=MEMORY）；
//! - `PRAGMA user_version` + 编号 SQL migration；
//! - 首次初始化使用临时数据库文件，完成 schema 与完整性检查后再原子安装为正式库；
//! - 启动时 fail-closed：损坏、非数据库、版本过新、迁移失败都保留原文件并返回结构化错误；
//! - 健康检查快照（不包含用户工作内容）。
//!
//! 本模块由 Rust 后端独占使用；前端只能调用受限的 Tauri command，不能执行 SQL。

mod connection;
mod health;
mod migrations;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

use crate::error::DatabaseError;
use crate::portable_paths::PortablePaths;

pub use health::{AppliedMigration, DatabaseHealth};
pub use migrations::{
    LATEST_SCHEMA_VERSION, MIGRATIONS, Migration, MigrationOutcome, apply_migrations,
    read_schema_version,
};

/// busy_timeout 毫秒数（与 [`connection::BUSY_TIMEOUT_MS`] 一致，供上层展示与测试断言）。
pub use connection::BUSY_TIMEOUT_MS;

const INIT_TEMP_FILE_PREFIX: &str = ".work.db.init-";

/// 已初始化的数据库连接与路径。
///
/// 第一版使用单连接；Tauri 适配层用 `Mutex` 串行化数据库访问（TD 6.2）。
pub struct Database {
    connection: Connection,
    database_path: PathBuf,
    created_new: bool,
}

impl std::fmt::Debug for Database {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Database")
            .field("database_path", &self.database_path)
            .field("created_new", &self.created_new)
            .finish_non_exhaustive()
    }
}

impl Database {
    /// 打开已存在的数据库，或在明确首次安装时原子创建新数据库。
    ///
    /// 失败时不会删除、截断或覆盖任何已存在的数据库文件。
    pub fn initialize(paths: &PortablePaths) -> Result<Self, DatabaseError> {
        if !paths.database_dir.is_dir() {
            return Err(DatabaseError::NewDatabaseInitializationFailed {
                detail: format!(
                    "数据库目录不存在：{}。请先调用 PortablePaths::ensure_directories()。",
                    paths.database_dir.display()
                ),
            });
        }

        // 清理本应用上次初始化中断留下的临时文件（只匹配本模块创建的固定前缀）。
        Self::remove_stale_initialization_files(&paths.database_dir);

        let database_path = paths.database_file.clone();
        let existed = match fs::symlink_metadata(&database_path) {
            Ok(metadata) if metadata.is_file() => true,
            Ok(_) => {
                return Err(DatabaseError::PathNotAFile {
                    path: database_path,
                });
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => {
                return Err(DatabaseError::FileSystemFailed {
                    context: "检查数据库文件状态",
                    path: database_path,
                    source: error,
                });
            }
        };

        if !existed {
            Self::create_new_database(paths)?;
        }

        Self::open_existing_database(paths, !existed)
    }

    /// 数据库文件路径（`data/database/work.db`）。
    pub fn database_path(&self) -> &Path {
        &self.database_path
    }

    /// 本次启动是否创建了新数据库。
    pub fn created_new(&self) -> bool {
        self.created_new
    }

    /// 只读连接访问入口，供 Rust Core 内部仓储/测试使用；不暴露给前端。
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// 可变连接访问入口；写操作（含事务）必须通过 `Mutex` 串行化后再取得。
    /// 不暴露给前端。
    pub fn connection_mut(&mut self) -> &mut Connection {
        &mut self.connection
    }

    /// 当前 schema 版本（`PRAGMA user_version`）。
    pub fn schema_version(&self) -> Result<i64, DatabaseError> {
        migrations::read_schema_version(&self.connection, &self.database_path)
    }

    /// 数据库健康快照；执行完整性检查与外键检查。
    pub fn health_report(&self) -> Result<DatabaseHealth, DatabaseError> {
        health::build_health(&self.connection, &self.database_path)
    }

    /// 显式执行外键违规检查。
    pub fn check_foreign_keys(&self) -> Result<(), DatabaseError> {
        connection::run_foreign_key_check(&self.connection, &self.database_path)
    }

    /// 首次初始化：在临时数据库中完成 migration 与检查，再原子安装为正式数据库文件。
    ///
    /// Windows 说明：安装使用 `hard_link`（NTFS 原子、目标已存在时失败而不是覆盖），
    /// 然后把临时文件名删除。这样不会出现“正式库只写了一半”的中间状态；
    /// 如果目标文件在初始化期间被其他进程创建，会返回
    /// [`DatabaseError::ConcurrentInitialization`] 而不是覆盖。
    fn create_new_database(paths: &PortablePaths) -> Result<(), DatabaseError> {
        let database_path = paths.database_file.clone();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let temp_path = paths.database_dir.join(format!(
            "{INIT_TEMP_FILE_PREFIX}{}-{unique}.tmp",
            std::process::id()
        ));

        let result = Self::initialize_temp_database(&temp_path, &database_path);
        if result.is_err() {
            // 失败时只清理本次创建的临时文件，正式数据库路径从未被写入。
            remove_file_if_exists(&temp_path);
            remove_file_if_exists(&sidecar_path(&temp_path, "-wal"));
            remove_file_if_exists(&sidecar_path(&temp_path, "-shm"));
        }
        result
    }

    fn initialize_temp_database(
        temp_path: &Path,
        database_path: &Path,
    ) -> Result<(), DatabaseError> {
        let mut connection = connection::open_for_initialization(temp_path)?;
        connection::configure(&connection, temp_path)?;

        let outcome = migrations::apply_migrations(
            &mut connection,
            temp_path,
            migrations::MIGRATIONS,
            migrations::LATEST_SCHEMA_VERSION,
        )?;
        debug_assert!(
            outcome.applied_anything(),
            "全新初始化的数据库必须至少应用一个 migration"
        );

        // 迁移后完整性与外键检查（WAL 状态下读取）。
        connection::run_integrity_check(&connection, temp_path)?;
        connection::run_foreign_key_check(&connection, temp_path)?;

        // 合并 WAL 并切回 DELETE 日志模式，保证主文件自身包含全部数据。
        connection::consolidate_wal_into_main_file(&connection, temp_path)?;
        connection::run_integrity_check(&connection, temp_path)?;

        drop(connection);

        ensure_no_sqlite_sidecars(temp_path)?;
        install_initialized_database(temp_path, database_path)
    }

    fn open_existing_database(
        paths: &PortablePaths,
        created_new: bool,
    ) -> Result<Self, DatabaseError> {
        let database_path = paths.database_file.clone();
        let mut connection = connection::open_read_write(&database_path)?;
        connection::configure(&connection, &database_path)?;

        // 先证明数据库健康，再允许执行 migration 等写入操作。
        connection::run_integrity_check(&connection, &database_path)?;
        connection::run_foreign_key_check(&connection, &database_path)?;

        let outcome = migrations::apply_migrations(
            &mut connection,
            &database_path,
            migrations::MIGRATIONS,
            migrations::LATEST_SCHEMA_VERSION,
        )?;

        if outcome.applied_anything() {
            // 迁移后复查数据库完整性与外键。
            connection::run_integrity_check(&connection, &database_path)?;
            connection::run_foreign_key_check(&connection, &database_path)?;
        }

        Ok(Self {
            connection,
            database_path,
            created_new,
        })
    }

    fn remove_stale_initialization_files(database_dir: &Path) {
        let Ok(entries) = fs::read_dir(database_dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if !name.starts_with(INIT_TEMP_FILE_PREFIX) {
                continue;
            }
            if path.is_file() {
                remove_file_if_exists(&path);
            }
            remove_file_if_exists(&sidecar_path(&path, "-wal"));
            remove_file_if_exists(&sidecar_path(&path, "-shm"));
        }
    }
}

/// 把已通过检查的临时数据库安装为正式数据库文件。
///
/// - 优先使用 `hard_link`：同卷原子操作，目标已存在时返回 `AlreadyExists`，不会覆盖。
/// - 不支持硬链接的文件系统：显式复查目标不存在后回退到 `rename`。
fn install_initialized_database(
    temp_path: &Path,
    database_path: &Path,
) -> Result<(), DatabaseError> {
    match fs::hard_link(temp_path, database_path) {
        Ok(()) => {
            // 只删除临时文件名，正式库通过硬链接保留同一文件数据。
            remove_file_if_exists(temp_path);
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            Err(DatabaseError::ConcurrentInitialization {
                path: database_path.to_path_buf(),
            })
        }
        Err(error) if error.kind() == std::io::ErrorKind::Unsupported => {
            if database_path.exists() {
                return Err(DatabaseError::ConcurrentInitialization {
                    path: database_path.to_path_buf(),
                });
            }
            fs::rename(temp_path, database_path).map_err(|error| {
                DatabaseError::NewDatabaseInitializationFailed {
                    detail: format!("安装初始化数据库失败（rename 回退）：{error}"),
                }
            })
        }
        Err(error) => Err(DatabaseError::NewDatabaseInitializationFailed {
            detail: format!("安装初始化数据库失败（hard link）：{error}"),
        }),
    }
}

/// 安装前确认临时库没有遗留 WAL/SHM；否则单文件不完整，必须 fail-closed。
fn ensure_no_sqlite_sidecars(temp_path: &Path) -> Result<(), DatabaseError> {
    let wal_path = sidecar_path(temp_path, "-wal");
    let shm_path = sidecar_path(temp_path, "-shm");

    if let Ok(metadata) = fs::metadata(&wal_path) {
        if metadata.len() > 0 {
            return Err(DatabaseError::WalConsolidationFailed {
                detail: format!(
                    "WAL 文件仍包含 {} 字节数据：{}",
                    metadata.len(),
                    wal_path.display()
                ),
            });
        }
        remove_file_if_exists(&wal_path);
    }
    if let Ok(metadata) = fs::metadata(&shm_path) {
        if metadata.len() > 0 {
            return Err(DatabaseError::WalConsolidationFailed {
                detail: format!("SHM 文件未被清理：{}", shm_path.display()),
            });
        }
        remove_file_if_exists(&shm_path);
    }
    Ok(())
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{suffix}", path.display()))
}

fn remove_file_if_exists(path: &Path) {
    if path.is_file() {
        let _ = fs::remove_file(path);
    }
}
