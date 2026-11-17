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
//! - 取得初始化锁后**先重新检查正式主库**，只有确认主库仍不存在时才检查孤儿
//!   WAL/journal；等待锁的进程不会把另一个进程已创建数据库的活动 WAL 误判为孤儿文件
//!   （审计 R2-01）；
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
        // 审计 R2-02/P1：在创建初始化锁文件或正式数据库之前，最后一道路径边界复验。
        // 该复验基于真实最终路径与物理卷身份；它缩小但不能完全消除校验与写入之间的
        // TOCTOU 窗口（句柄相对写入改造未在本任务完成）。
        paths.validate_write_boundary().map_err(|error| {
            DatabaseError::DirectoryBoundaryViolation {
                portable_code: error.code(),
                detail: error.message,
            }
        })?;

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
                let database = Self::open_or_create_after_lock(paths, &lock);
                drop(lock);
                database
            }
        }
    }

    /// 取得初始化锁之后的统一处理：先重新检查正式主库，只有确认主库仍不存在
    /// 时才检查孤儿 sidecar 并创建新数据库。
    ///
    /// **审计 R2-01 修复：** 旧实现在取得锁后先调用 [`Self::orphaned_sidecar_error`]，
    /// 再重新检查主库。等待锁的进程 B 初次检查时主库不存在；进程 A 取得锁、创建正式
    /// 数据库、进入 WAL 模式并写入后释放锁；B 取得锁时若先看到 A 活动连接产生的非空
    /// `-wal`，就会把**正常活动 WAL** 误判为孤儿文件并 fail-closed。正确顺序是先重检
    /// 主库：主库已存在时非空 `-wal` 是正常状态，绝不能按孤儿 sidecar 处理。
    ///
    /// 调用约束：调用方必须已持有 [`InitializationLock`]（`_lock` 参数只表达该约束，
    /// 锁的获取/释放由调用方管理），否则并发初始化保护失效。
    fn open_or_create_after_lock(
        paths: &PortablePaths,
        _lock: &InitializationLock,
    ) -> Result<Self, DatabaseError> {
        let database_path = paths.database_file.clone();

        // 1. 取得锁后重新检查正式主库：等待锁期间另一个进程可能已完成首次初始化。
        match Self::inspect_existing_database(&database_path)? {
            Some(size_bytes) => {
                // 主库已存在：这是正常数据库（可能带有另一个进程活动连接产生的非空 WAL）。
                // 只清理本模块的初始化临时文件；**绝不检查孤儿 sidecar**。
                Self::remove_stale_initialization_files(&paths.database_dir);
                if size_bytes == 0 {
                    return Err(empty_existing_database_error(&database_path));
                }
                Self::open_existing_database(paths, false)
            }
            None => {
                // 2. 只有在确认主库仍不存在时，非空 WAL/journal 才可能是孤儿残留：
                //    绝不能当作首次安装，创建新库可能让 SQLite 误用或丢弃其中可能有效的数据。
                if let Some(error) = Self::orphaned_sidecar_error(&database_path) {
                    return Err(error);
                }

                // 3. 主库、WAL、journal 均不存在，才允许创建全新数据库。
                Self::remove_stale_initialization_files(&paths.database_dir);
                Self::remove_stale_shm_when_creating_new(&database_path);
                Self::create_new_database(paths)?;
                Self::open_existing_database(paths, true)
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

// ---------------------------------------------------------------------------
// 审计 R2-01 专项测试：等待初始化锁的进程遇到活动 WAL
//
// 测试用真实独立子进程（不是线程模拟）复现审计场景：
//   1. 父进程创建隔离的便携数据目录（不含数据库）；
//   2. 进程 A（creator 子进程）先取得跨进程初始化锁，然后等待 B 完成初次检查；
//   3. 进程 B（waiter 子进程）初次检查正式主库不存在，写出信号后阻塞在初始化锁上；
//   4. A 在持锁状态下创建正式数据库、进入 WAL 模式、写入虚构 canary（产生非空 WAL），
//      释放初始化锁；
//   5. B 取得锁后调用生产代码 `open_or_create_after_lock`：
//      必须先重检主库，正常打开，绝不能返回 `database-orphaned-sidecar`；
//   6. 父进程复核 canary 保留、integrity_check=ok、migration 只执行一次。
//
// 顺序由“文件信号 + 跨进程锁”保证，不依赖 sleep 时长。
// ---------------------------------------------------------------------------
#[cfg(test)]
mod r2_01_tests {
    use std::fs::{self, File};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, ExitStatus, Stdio};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use super::{Database, InitializationLock, LATEST_SCHEMA_VERSION, sidecar_path};
    use crate::portable_paths::{PortablePaths, RuntimeMode};

    const MODE_ENV: &str = "WM_R2_01_CHILD_MODE";
    const DATA_ROOT_ENV: &str = "WM_R2_01_DATA_ROOT";
    const MARKER_DIR_ENV: &str = "WM_R2_01_MARKER_DIR";

    /// 子进程辅助入口；普通测试运行（无模式环境变量）时直接返回。
    ///
    /// 必须作为独立进程运行：`current_exe --exact database::r2_01_tests::r2_01_child_helper`。
    #[test]
    fn r2_01_child_helper() {
        let Ok(mode) = std::env::var(MODE_ENV) else {
            return;
        };
        let data_root = PathBuf::from(std::env::var(DATA_ROOT_ENV).expect("data root env"));
        let marker_dir = PathBuf::from(std::env::var(MARKER_DIR_ENV).expect("marker dir env"));
        match mode.as_str() {
            "creator" => creator_child(&data_root, &marker_dir),
            "waiter" => waiter_child(&data_root, &marker_dir),
            other => panic!("unknown R2-01 child mode: {other}"),
        }
    }

    /// 进程 A：持有初始化锁 → 等待 B 初次检查 → 创建正式库并写入 canary → 释放锁。
    fn creator_child(data_root: &Path, marker_dir: &Path) {
        let paths = prepare_paths(data_root);
        let lock = InitializationLock::acquire(&paths.database_dir, Duration::from_secs(60))
            .expect("creator 必须取得初始化锁");
        fs::write(
            marker_dir.join("a-has-lock"),
            format!("pid={}", std::process::id()),
        )
        .expect("写 a-has-lock 信号");
        assert!(
            wait_for_marker(&marker_dir.join("b-inspected"), Duration::from_secs(120)),
            "creator 等待 waiter 初次检查信号超时"
        );

        // A 在持锁状态下执行与生产首次初始化相同的步骤：创建正式库 → 打开并进入 WAL。
        Database::create_new_database(&paths).expect("creator 创建正式数据库");
        let mut database =
            Database::open_existing_database(&paths, true).expect("creator 打开刚创建的正式数据库");
        database
            .connection_mut()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) \
                 VALUES ('r2-01-canary', '{\"marker\":\"waiter-active-wal\"}', '2026-11-17T00:00:00Z')",
                [],
            )
            .expect("creator 写入虚构 canary");

        let wal_path = sidecar_path(&paths.database_file, "-wal");
        let wal_bytes = fs::metadata(&wal_path).map(|meta| meta.len()).unwrap_or(0);
        assert!(
            wal_bytes > 0,
            "creator 写入 canary 后必须存在非空 WAL：{}",
            wal_path.display()
        );
        fs::write(
            marker_dir.join("a-created"),
            format!("pid={} wal_bytes={wal_bytes}", std::process::id()),
        )
        .expect("写 a-created 信号");

        // 释放初始化锁：waiter 可以在主库存在且有活动 WAL 的情况下取得锁。
        drop(lock);
        assert!(
            wait_for_marker(&marker_dir.join("b-done"), Duration::from_secs(120)),
            "creator 等待 waiter 完成超时"
        );
        // 保持连接打开直到 B 完成，保证 B 取得锁时 WAL 属于真实活动连接。
        drop(database);
        std::process::exit(0);
    }

    /// 进程 B：初次检查主库不存在 → 等待初始化锁 → 调用生产代码处理锁后状态。
    fn waiter_child(data_root: &Path, marker_dir: &Path) {
        let paths = prepare_paths(data_root);
        // 模拟 B 在 Database::initialize 中的初次检查结果（主库不存在）。
        assert!(
            fs::symlink_metadata(&paths.database_file).is_err(),
            "waiter 初次检查必须看到正式主库不存在：{}",
            paths.database_file.display()
        );
        fs::write(
            marker_dir.join("b-inspected"),
            format!("pid={} main_missing=true", std::process::id()),
        )
        .expect("写 b-inspected 信号");

        // 阻塞等待 A 释放初始化锁。
        let lock = InitializationLock::acquire(&paths.database_dir, Duration::from_secs(120))
            .expect("waiter 必须取得初始化锁");
        // 审计 R2-01 的生产代码路径：先重检主库，只有确实缺失才检查孤儿 sidecar。
        let database = Database::open_or_create_after_lock(&paths, &lock)
            .expect("waiter 必须正常打开 A 已创建的数据库，不得返回 database-orphaned-sidecar");
        assert!(
            !database.created_new(),
            "waiter 不得重新创建数据库（A 已经创建）"
        );
        assert_eq!(
            database.schema_version().expect("schema version"),
            LATEST_SCHEMA_VERSION
        );
        let canary: String = database
            .connection()
            .query_row(
                "SELECT value_json FROM settings WHERE key = 'r2-01-canary'",
                [],
                |row| row.get(0),
            )
            .expect("A 写入的 canary 必须保留");
        assert_eq!(canary, "{\"marker\":\"waiter-active-wal\"}");
        let migration_rows: i64 = database
            .connection()
            .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
                row.get(0)
            })
            .expect("count migrations");
        assert_eq!(migration_rows, 1, "migration 不得重复执行");
        let health = database.health_report().expect("waiter health report");
        assert_eq!(health.integrity_check, "ok");
        assert_eq!(health.applied_migrations.len(), 1);
        println!(
            "r2-01-waiter: acquired lock after creator; main_db_exists=true; \
             opened_existing=true; orphaned_sidecar=false; canary_preserved=true; \
             integrity=ok; migrations=1"
        );
        drop(lock);
        fs::write(
            marker_dir.join("b-done"),
            format!("pid={}", std::process::id()),
        )
        .expect("写 b-done 信号");
        drop(database);
        std::process::exit(0);
    }

    /// 真实独立子进程守卫：等待超时或测试 panic 时强制结束，避免遗留进程。
    struct ChildGuard {
        child: Option<Child>,
        stdout_path: PathBuf,
        stderr_path: PathBuf,
    }

    impl ChildGuard {
        fn spawn(mode: &str, data_root: &Path, marker_dir: &Path) -> Self {
            let stdout_path = marker_dir.join(format!("{mode}.stdout.log"));
            let stderr_path = marker_dir.join(format!("{mode}.stderr.log"));
            let mut command =
                Command::new(std::env::current_exe().expect("current test executable"));
            command.args([
                "--exact",
                "database::r2_01_tests::r2_01_child_helper",
                "--nocapture",
            ]);
            command.env(MODE_ENV, mode);
            command.env(DATA_ROOT_ENV, data_root);
            command.env(MARKER_DIR_ENV, marker_dir);
            command.stdout(Stdio::from(
                File::create(&stdout_path).expect("create child stdout log"),
            ));
            command.stderr(Stdio::from(
                File::create(&stderr_path).expect("create child stderr log"),
            ));
            let child = command.spawn().expect("spawn R2-01 child process");
            Self {
                child: Some(child),
                stdout_path,
                stderr_path,
            }
        }

        fn wait_with_timeout(&mut self, timeout: Duration) -> ChildExit {
            let deadline = Instant::now() + timeout;
            let status = loop {
                let child = self.child.as_mut().expect("child present");
                match child.try_wait().expect("try_wait child") {
                    Some(status) => break status,
                    None if Instant::now() >= deadline => {
                        let _ = child.kill();
                        let _ = child.wait();
                        panic!("R2-01 子进程在 {timeout:?} 内未退出");
                    }
                    None => std::thread::sleep(Duration::from_millis(20)),
                }
            };
            self.collect(status)
        }

        fn collect(&mut self, status: ExitStatus) -> ChildExit {
            ChildExit {
                status,
                stdout: fs::read_to_string(&self.stdout_path).unwrap_or_default(),
                stderr: fs::read_to_string(&self.stderr_path).unwrap_or_default(),
            }
        }
    }

    impl Drop for ChildGuard {
        fn drop(&mut self) {
            if let Some(mut child) = self.child.take() {
                let _ = child.try_wait();
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }

    struct ChildExit {
        status: ExitStatus,
        stdout: String,
        stderr: String,
    }

    impl ChildExit {
        fn assert_success(&self, label: &str) {
            assert!(
                self.status.success(),
                "{label} 子进程失败：status={:?}\nstdout:\n{}\nstderr:\n{}",
                self.status,
                self.stdout,
                self.stderr
            );
        }
    }

    /// 位于 D 盘隔离目录中的唯一测试目录；Drop 时只删除本用例创建的目录。
    struct IsolatedTestDir {
        base: PathBuf,
        path: PathBuf,
    }

    impl IsolatedTestDir {
        fn new(label: &str) -> Self {
            let base = std::env::var_os("WORKMANAGER_TEST_BASE_DIR")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(r"D:\WorkManager-test-data"));
            let base_text = comparable(&base);
            assert!(
                base_text.starts_with("d:\\"),
                "R2-01 测试根目录必须在 D 盘：{}",
                base.display()
            );
            assert!(
                !base_text.starts_with("d:\\workmanager\\") && base_text != "d:\\workmanager",
                "R2-01 测试不得写入正式目录 D:\\WorkManager：{}",
                base.display()
            );
            fs::create_dir_all(&base).expect("create R2-01 test base");
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let path = base.join(format!("{label}-{}-{unique}", std::process::id()));
            fs::create_dir_all(&path).expect("create R2-01 isolated dir");
            Self { base, path }
        }

        fn join(&self, relative: impl AsRef<Path>) -> PathBuf {
            self.path.join(relative)
        }
    }

    impl Drop for IsolatedTestDir {
        fn drop(&mut self) {
            // 只删除测试根目录之下、由本用例创建的唯一子目录。
            let base = comparable(&self.base);
            let path = comparable(&self.path);
            if path.starts_with("d:\\workmanager\\") || path == "d:\\workmanager" {
                eprintln!("跳过清理：拒绝删除正式目录下的路径 {}", self.path.display());
                return;
            }
            if !path.starts_with(&(base.clone() + "\\")) && path != base {
                eprintln!(
                    "跳过清理：测试目录 {} 不在测试根目录 {} 之下",
                    self.path.display(),
                    self.base.display()
                );
                return;
            }
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn comparable(path: &Path) -> String {
        path.to_string_lossy()
            .replace('/', "\\")
            .trim_end_matches('\\')
            .to_lowercase()
    }

    /// 构造 Debug/Test 隔离便携目录布局（不创建数据库）。
    fn prepare_paths(data_root: &Path) -> PortablePaths {
        let paths = PortablePaths::resolve(
            RuntimeMode::DebugTest,
            &data_root.join("WorkManager.exe"),
            Some(data_root),
        )
        .expect("resolve R2-01 debug paths");
        paths
            .ensure_directories()
            .expect("ensure R2-01 debug layout");
        paths
    }

    fn wait_for_marker(path: &Path, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if path.is_file() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        path.is_file()
    }

    /// R2-01 回归：等待初始化锁的进程必须识别另一个进程已创建的数据库和活动 WAL。
    #[test]
    fn waiting_process_opens_database_with_active_wal_instead_of_orphan_error() {
        let dir = IsolatedTestDir::new("r2-01-waiter-active-wal");
        let data_root = dir.join("data-root");
        fs::create_dir_all(&data_root).expect("create data root");
        // 父进程预先创建便携目录布局，但绝不创建数据库。
        let paths = prepare_paths(&data_root);
        assert!(
            !paths.database_file.exists(),
            "前置条件：正式数据库尚不存在"
        );
        let marker_dir = dir.join("markers");
        fs::create_dir_all(&marker_dir).expect("create marker dir");

        // A 先启动并取得初始化锁；A 在 B 完成初次检查之前不会创建数据库。
        let mut creator = ChildGuard::spawn("creator", &data_root, &marker_dir);
        assert!(
            wait_for_marker(&marker_dir.join("a-has-lock"), Duration::from_secs(120)),
            "进程 A 未在超时内取得初始化锁"
        );
        // B 此时启动：初次检查看到主库不存在，然后阻塞在跨进程锁上。
        let mut waiter = ChildGuard::spawn("waiter", &data_root, &marker_dir);
        assert!(
            wait_for_marker(&marker_dir.join("a-created"), Duration::from_secs(120)),
            "进程 A 未在超时内创建数据库并发信号"
        );

        // 证据：B 取得锁之前，正式主库已存在，且 WAL 属于 A 的活动连接。
        let main_bytes = fs::metadata(&paths.database_file)
            .map(|meta| meta.len())
            .unwrap_or(0);
        assert!(main_bytes > 0, "等待者取得锁前正式主库必须已存在");
        let wal_path = sidecar_path(&paths.database_file, "-wal");
        let wal_bytes = fs::metadata(&wal_path).map(|meta| meta.len()).unwrap_or(0);
        assert!(
            wal_bytes > 0,
            "等待者取得锁前必须存在 A 的活动非空 WAL：{}",
            wal_path.display()
        );
        println!(
            "r2-01: creator holds active WAL before waiter acquires lock; \
             main_db_bytes={main_bytes} wal_bytes={wal_bytes}"
        );

        let waiter_exit = waiter.wait_with_timeout(Duration::from_secs(120));
        waiter_exit.assert_success("waiter");
        assert!(
            !waiter_exit.stderr.contains("database-orphaned-sidecar"),
            "等待者不得返回 database-orphaned-sidecar；实际 stderr：\n{}",
            waiter_exit.stderr
        );
        println!("r2-01-waiter-stdout: {}", waiter_exit.stdout.trim());

        let creator_exit = creator.wait_with_timeout(Duration::from_secs(120));
        creator_exit.assert_success("creator");

        // 父进程最终复核：canary 保留、完整性 ok、migration 只执行一次。
        let database = Database::initialize(&paths).expect("父进程重新打开数据库");
        assert!(!database.created_new(), "最终数据库必须是已有数据库");
        assert_eq!(
            database.schema_version().expect("schema version"),
            LATEST_SCHEMA_VERSION
        );
        let canary: String = database
            .connection()
            .query_row(
                "SELECT value_json FROM settings WHERE key = 'r2-01-canary'",
                [],
                |row| row.get(0),
            )
            .expect("canary 必须在最终数据库中保留");
        assert_eq!(canary, "{\"marker\":\"waiter-active-wal\"}");
        let migration_rows: i64 = database
            .connection()
            .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
                row.get(0)
            })
            .expect("count migrations");
        assert_eq!(migration_rows, 1, "migration 不得重复执行");
        let health = database.health_report().expect("final health report");
        assert_eq!(health.integrity_check, "ok");
        assert_eq!(
            health.applied_migrations.len(),
            1,
            "schema_migrations 只应有一条记录"
        );
        println!(
            "r2-01: PASS — waiter recognized existing database with active WAL; \
             no database-orphaned-sidecar; canary preserved; integrity=ok; migrations=1"
        );
    }

    /// 确认测试夹具位于 D 盘隔离目录内（防止误写正式目录）。
    #[test]
    fn r2_01_fixtures_stay_inside_isolated_test_dir() {
        let dir = IsolatedTestDir::new("r2-01-marker-paths");
        let data_root = dir.join("data-root");
        let marker_dir = dir.join("markers");
        fs::create_dir_all(&data_root).expect("create data root");
        fs::create_dir_all(&marker_dir).expect("create marker dir");
        let root_text = comparable(dir.path.as_path());
        let data_root_text = comparable(&data_root);
        let marker_text = comparable(&marker_dir);
        assert!(
            data_root_text.starts_with(&(root_text.clone() + "\\")),
            "R2-01 数据根目录必须位于隔离测试目录内：{}",
            data_root.display()
        );
        assert!(
            marker_text.starts_with(&(root_text + "\\")),
            "R2-01 信号目录必须位于隔离测试目录内：{}",
            marker_dir.display()
        );
        assert!(
            data_root_text.starts_with("d:\\"),
            "R2-01 测试夹具必须在 D 盘：{}",
            data_root.display()
        );
    }
}
