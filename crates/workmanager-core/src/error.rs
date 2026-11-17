//! 数据库与启动路径相关的结构化错误。
//!
//! 每个错误都带有稳定的 `code`，用于前端展示、日志分类与自动化测试断言；
//! 错误消息面向用户，使用中文说明“发生了什么、原文件是否被保留”。
//!
//! 安全约定：本模块的任何消息都不得包含用户工作内容、SQL 参数值或真实附件路径。

use std::path::PathBuf;

use thiserror::Error;

/// SQLite 基础设施错误。
///
/// 设计原则（对应 T1-01 要求）：
/// - 区分“路径不可写 / 打不开 / 不是数据库 / 损坏 / migration 失败 / 完整性检查失败 / 磁盘空间不足”；
/// - 任何失败都不得静默创建空数据库覆盖原文件；
/// - 错误消息只包含诊断信息与路径，不包含用户业务数据。
#[derive(Debug, Error)]
pub enum DatabaseError {
    /// 数据库路径存在，但不是普通文件（例如被同名目录或符号链接占用）。
    #[error("数据库路径已存在但不是普通文件，已停止启动：{path}。不会删除或覆盖该路径。")]
    PathNotAFile { path: PathBuf },

    /// 创建临时初始化数据库文件失败。
    #[error("无法创建数据库初始化临时文件：{path}；系统错误：{source}。原始数据库未被修改。")]
    TemporaryFileFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    /// 文件系统操作失败。
    #[error("{context}失败：{path}；系统错误：{source}。只读或不可写时不会回退到其他目录。")]
    FileSystemFailed {
        context: &'static str,
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    /// SQLite 无法打开数据库连接。
    #[error("无法打开 SQLite 数据库：{path}；详情：{detail}。原始文件未被修改。")]
    OpenFailed { path: PathBuf, detail: String },

    /// 文件存在但不是 SQLite 数据库格式。
    #[error(
        "数据库文件不是有效的 SQLite 数据库：{path}；详情：{detail}。\
         已停止启动，不会删除、重建或覆盖原文件。"
    )]
    NotADatabase { path: PathBuf, detail: String },

    /// 数据库损坏。
    #[error("数据库已损坏：{path}；详情：{detail}。已停止启动，不会自动创建空数据库覆盖原文件。")]
    Corrupt { path: PathBuf, detail: String },

    /// 数据库被其他连接占用。
    #[error("数据库正被占用（busy/locked）：{detail}。请关闭其他 WorkManager 实例后重试。")]
    Busy { detail: String },

    /// 数据库或目录只读。
    #[error("数据库不可写（只读）：{path}；详情：{detail}。请检查 D 盘便携目录权限。")]
    ReadOnly { path: PathBuf, detail: String },

    /// 磁盘空间不足。
    #[error("D 盘空间不足，无法写入数据库：{detail}。原始数据未被修改。")]
    DiskFull { detail: String },

    /// 其他 SQLite 错误。
    #[error("SQLite 操作失败（{context}）：{detail}。")]
    Sqlite {
        context: &'static str,
        detail: String,
    },

    /// PRAGMA 配置失败或配置未生效。
    #[error(
        "SQLite PRAGMA 配置失败：{pragma}；详情：{detail}。已停止启动，避免在不安全配置下写入数据。"
    )]
    PragmaFailed {
        pragma: &'static str,
        detail: String,
    },

    /// `PRAGMA integrity_check` 结果不是 `ok`。
    #[error("数据库完整性检查失败：{detail}。已停止启动；不会自动创建空数据库，也不会删除原文件。")]
    IntegrityCheckFailed { detail: String },

    /// `PRAGMA foreign_key_check` 发现违规。
    #[error("数据库外键约束检查发现 {count} 条违规记录。已停止启动，原文件未被修改。")]
    ForeignKeyViolations { count: i64 },

    /// 数据库 schema 版本高于当前应用支持的版本。
    #[error(
        "数据库 schema 版本（{found}）高于当前应用支持的最新版本（{supported}）。\
         请使用更新版本的 WorkManager；不会自动降级、删除或覆盖数据库。"
    )]
    SchemaVersionTooNew { found: i64, supported: i64 },

    /// migration 定义本身不合法（开发期错误）。
    #[error("数据库 migration 定义不合法：{detail}。")]
    InvalidMigrationSet { detail: String },

    /// 单个 migration 执行失败；该 migration 已在事务中回滚。
    #[error(
        "数据库 migration 失败并已回滚：版本 {version}（{name}）；详情：{detail}。\
         已提交的旧版本保持不变，数据库不会被删除或重建。"
    )]
    MigrationFailed {
        version: i64,
        name: String,
        detail: String,
    },

    /// 新数据库初始化失败（失败时正式路径未被写入）。
    #[error("首次初始化数据库失败：{detail}。正式数据库文件未被创建或覆盖。")]
    NewDatabaseInitializationFailed { detail: String },

    /// 初始化期间目标数据库文件被其他进程创建。
    #[error(
        "初始化期间检测到数据库文件已被其他进程创建：{path}。\
         已停止本次初始化，不会覆盖已有数据库；请重新启动应用。"
    )]
    ConcurrentInitialization { path: PathBuf },

    /// WAL 合并（checkpoint）失败，无法得到单文件完整数据库。
    #[error("WAL 合并失败，未安装初始化数据库文件：{detail}。")]
    WalConsolidationFailed { detail: String },
}

impl DatabaseError {
    /// 稳定的错误码，供 IPC、测试与日志分类使用（不包含用户数据）。
    pub fn code(&self) -> &'static str {
        match self {
            Self::PathNotAFile { .. } => "database-path-not-file",
            Self::TemporaryFileFailed { .. } => "database-temp-file-failed",
            Self::FileSystemFailed { .. } => "database-file-system-failed",
            Self::OpenFailed { .. } => "database-open-failed",
            Self::NotADatabase { .. } => "database-not-a-database",
            Self::Corrupt { .. } => "database-corrupt",
            Self::Busy { .. } => "database-busy",
            Self::ReadOnly { .. } => "database-read-only",
            Self::DiskFull { .. } => "disk-full",
            Self::Sqlite { .. } => "database-sqlite-error",
            Self::PragmaFailed { .. } => "database-pragma-failed",
            Self::IntegrityCheckFailed { .. } => "database-integrity-check-failed",
            Self::ForeignKeyViolations { .. } => "database-foreign-key-violations",
            Self::SchemaVersionTooNew { .. } => "schema-version-too-new",
            Self::InvalidMigrationSet { .. } => "migration-definition-invalid",
            Self::MigrationFailed { .. } => "migration-failed",
            Self::NewDatabaseInitializationFailed { .. } => "database-initialization-failed",
            Self::ConcurrentInitialization { .. } => "database-concurrent-initialization",
            Self::WalConsolidationFailed { .. } => "database-wal-consolidation-failed",
        }
    }
}
