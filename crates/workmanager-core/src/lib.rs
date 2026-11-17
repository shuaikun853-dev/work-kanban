//! WorkManager 独立 Rust Core。
//!
//! 本 crate 不依赖 Tauri，可用普通 `cargo test` 运行，负责：
//! - [`portable_paths`]：便携路径解析（EXE 跟随、D 盘约束、Debug/Test 隔离）；
//! - [`database`]：普通 SQLite 连接、PRAGMA 配置、`user_version` migration、完整性检查与健康快照；
//! - [`error`]：结构化错误码。
//!
//! Tauri 适配层（`src-tauri`）只负责命令、窗口和 IPC DTO，不在此 crate 内出现。

pub mod database;
pub mod error;
pub mod portable_paths;

pub use database::{
    AppliedMigration, BUSY_TIMEOUT_MS, Database, DatabaseHealth, InitializationLock,
    LATEST_SCHEMA_VERSION, MIGRATIONS, Migration, MigrationOutcome,
};
pub use error::DatabaseError;
pub use portable_paths::{PortablePathError, PortablePaths, RuntimeMode, TEST_PORTABLE_ROOT_ENV};
