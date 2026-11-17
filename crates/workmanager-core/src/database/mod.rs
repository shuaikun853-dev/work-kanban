//! 普通 SQLite 数据库基础设施（T1-01）。
//!
//! 职责：
//! - 打开/创建 `data/database/work.db`；
//! - 生产 PRAGMA 配置（WAL、foreign_keys、busy_timeout、synchronous=FULL、temp_store=MEMORY）；
//! - `PRAGMA user_version` + 编号 SQL migration；
//! - 首次初始化使用临时数据库文件，完成 schema 与完整性检查后再原子安装为正式库；
//! - 已有数据库先做只读预检查（版本、完整性、外键数据、兼容性），确认健康兼容后才
//!   应用持久化 PRAGMA（`journal_mode=WAL`），避免在不兼容/损坏库上留下设置改动；
//! - 区分“首次安装”和“已有数据库”：已存在的 0 字节异常空文件 fail-closed，
//!   绝不当作首次安装，也绝不交给 SQLite 打开（SQLite 会把 0 字节文件当空库，
//!   并可能丢弃残留 WAL 中未 checkpoint 的数据）；
//! - 首次初始化使用跨进程初始化锁，避免并发首次启动互相删除临时库或重复迁移；
//! - 健康检查快照（不包含用户工作内容）。
//!
//! 本模块由 Rust 后端独占使用；前端只能调用受限的 Tauri command，不能执行 SQL。

mod connection;
mod health;
mod init_lock;
mod migrations;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

use crate::error::DatabaseError;
use crate::portable_paths::PortablePaths;

pub use health::{AppliedMigration, DatabaseHealth};
pub use init_lock::{DEFAULT_ACQUIRE_TIMEOUT, INITIALIZATION_LOCK_FILE_NAME, InitializationLock};
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

        let database_path = paths.database_file.clone();

        // 只读判断当前是否已有数据库文件（含 0 字节异常空文件），不修改任何文件。
        match Self::inspect_existing_database(&database_path)? {
            Some(size_bytes) => {
                // 已有数据库：尽力取得初始化锁；只有持锁时才清理遗留临时文件，
                // 绝不删除其他活动进程正在使用的临时数据库。
                let lock = InitializationLock::try_acquire(&paths.database_dir)?;
                if let Some(lock) = lock.as_ref() {
                    let _ = lock.write_diagnostic();
                    Self::remove_stale_initialization_files(&paths.database_dir);
                }
                if size_bytes == 0 {
                    return Err(empty_existing_database_error(&database_path));
                }
                let database = Self::open_existing_database(paths, false)?;
                drop(lock);
                Ok(database)
            }
            None => {
                // 首次安装：必须取得跨进程初始化锁，防止两个进程同时初始化、
                // 互相删除临时库或重复执行 migration。
                let lock = InitializationLock::acquire(
                    &paths.database_dir,
                    init_lock::DEFAULT_ACQUIRE_TIMEOUT,
                )?;
                let _ = lock.write_diagnostic();

                // 主库缺失时，若存在非空 WAL/journal 残留，绝不能当作首次安装：
                // 创建新库可能让 SQLite 误用或丢弃其中可能有效的数据。
                if let Some(error) = Self::orphaned_sidecar_error(&database_path) {
                    return Err(error);
                }

                // 取得锁后重新检查：另一个进程可能刚完成首次初始化并释放锁。
                match Self::inspect_existing_database(&database_path)? {
                    Some(size_bytes) => {
                        Self::remove_stale_initialization_files(&paths.database_dir);
                        if size_bytes == 0 {
                            return Err(empty_existing_database_error(&database_path));
                        }
                        let database = Self::open_existing_database(paths, false)?;
                        drop(lock);
                        Ok(database)
                    }
                    None => {
                        Self::remove_stale_initialization_files(&paths.database_dir);
                        Self::remove_stale_shm_when_creating_new(&database_path);
                        Self::create_new_database(paths)?;
                        let database = Self::open_existing_database(paths, true)?;
                        drop(lock);
                        Ok(database)
                    }
                }
            }
        }
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

    /// 只读检查数据库文件是否存在及其大小；不打开数据库、不修改文件。
    fn inspect_existing_database(path: &Path) -> Result<Option<u64>, DatabaseError> {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.is_file() => Ok(Some(metadata.len())),
            Ok(_) => Err(DatabaseError::PathNotAFile {
                path: path.to_path_buf(),
            }),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(DatabaseError::FileSystemFailed {
                context: "检查数据库文件状态",
                path: path.to_path_buf(),
                source: error,
            }),
        }
    }

    /// 主库缺失时检查非空 WAL / journal 残留。
    ///
    /// 存在时 fail-closed：当作首次安装创建新库可能让 SQLite 误用或丢弃
    /// 这些残留文件中可能有效、尚未 checkpoint 的数据。
    fn orphaned_sidecar_error(database_path: &Path) -> Option<DatabaseError> {
        for (suffix, name) in [("-wal", "WAL"), ("-journal", "journal")] {
            let sidecar = sidecar_path(database_path, suffix);
            if let Ok(metadata) = fs::metadata(&sidecar) {
                if metadata.len() > 0 {
                    return Some(DatabaseError::OrphanedSidecar {
                        database_path: database_path.to_path_buf(),
                        sidecar_path: sidecar,
                        sidecar_name: name.to_string(),
                        sidecar_size_bytes: metadata.len(),
                    });
                }
            }
        }
        None
    }

    /// 创建全新数据库前清理孤立的 `-shm` 文件。
    ///
    /// 仅在主库、WAL、journal 都不存在时调用：此时 `-shm` 只是运行时共享内存索引，
    /// 不含已提交数据；若保留，SQLite 可能因共享内存头与新建数据库不匹配而拒绝打开。
    fn remove_stale_shm_when_creating_new(database_path: &Path) {
        remove_file_if_exists(&sidecar_path(database_path, "-shm"));
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
        connection::set_busy_timeout(&connection)?;
        connection::configure_runtime(&connection, temp_path)?;

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

    /// 打开已有数据库。
    ///
    /// 严格顺序（审计 P2）：
    /// 1. 打开连接（不修改数据库）；
    /// 2. 读取 schema 版本；
    /// 3. 完整性检查；
    /// 4. 外键数据检查；
    /// 5. 判断 schema 版本兼容性（过高则 fail-closed）；
    /// 6. 只有健康且兼容后才应用持久化运行参数（`journal_mode=WAL` 等）；
    /// 7. 执行 migration；
    /// 8. 再次检查完整性与外键。
    fn open_existing_database(
        paths: &PortablePaths,
        created_new: bool,
    ) -> Result<Self, DatabaseError> {
        let database_path = paths.database_file.clone();
        let mut connection = connection::open_read_write(&database_path)?;

        // 连接级、非持久化设置：避免并发访问产生瞬时 SQLITE_BUSY。
        connection::set_busy_timeout(&connection)?;

        // 1. schema 版本（只读数据库 header）。
        let schema_version = migrations::read_schema_version(&connection, &database_path)?;

        // 2. 完整性检查（只读，不修改数据库）。
        connection::run_integrity_check(&connection, &database_path)?;

        // 3. 外键数据检查（只读）。
        connection::run_foreign_key_check(&connection, &database_path)?;

        // 4. 兼容性判断：高于当前支持版本时立即 fail-closed，不应用 WAL 等
        //    持久化设置，保证被拒绝的数据库保持原样。
        if schema_version > migrations::LATEST_SCHEMA_VERSION {
            return Err(DatabaseError::SchemaVersionTooNew {
                found: schema_version,
                supported: migrations::LATEST_SCHEMA_VERSION,
            });
        }

        // 5. 健康且兼容，才应用持久化运行参数并验证。
        connection::configure_runtime(&connection, &database_path)?;

        // 6. migration（内部仍会再次校验版本，防止竞态）。
        let outcome = migrations::apply_migrations(
            &mut connection,
            &database_path,
            migrations::MIGRATIONS,
            migrations::LATEST_SCHEMA_VERSION,
        )?;

        if outcome.applied_anything() {
            // 7. 迁移后复查数据库完整性与外键。
            connection::run_integrity_check(&connection, &database_path)?;
            connection::run_foreign_key_check(&connection, &database_path)?;
        }

        Ok(Self {
            connection,
            database_path,
            created_new,
        })
    }

    /// 清理本应用上次初始化中断遗留的临时文件。
    ///
    /// 只匹配本模块创建的固定前缀（`.work.db.init-*`）。**只能在取得初始化锁后调用**，
    /// 否则可能删除另一个活动进程正在使用的临时数据库（审计 P2）。
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

/// 构造“已有数据库文件为 0 字节”错误，并附带 WAL 边界说明。
///
/// 设计结论（审计 P1，已在真机验证）：SQLite 会把 0 字节主文件当作空数据库，
/// 并在打开/关闭过程中**忽略并删除**残留 WAL。因此绝不能打开该文件；
/// 必须保留主文件与 WAL 原样，由用户确认或从备份恢复。
fn empty_existing_database_error(database_path: &Path) -> DatabaseError {
    let wal_path = sidecar_path(database_path, "-wal");
    let wal_hint = match fs::metadata(&wal_path) {
        Ok(metadata) if metadata.len() == 0 => {
            format!("；残留 WAL 文件为 0 字节：{}", wal_path.display())
        }
        Ok(metadata) => format!(
            "；检测到非空残留 WAL：{}（{} 字节），已原样保留，未交给 SQLite 打开，避免其丢弃可能有效的数据",
            wal_path.display(),
            metadata.len()
        ),
        Err(_) => String::new(),
    };
    DatabaseError::EmptyExistingDatabase {
        path: database_path.to_path_buf(),
        wal_hint,
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
