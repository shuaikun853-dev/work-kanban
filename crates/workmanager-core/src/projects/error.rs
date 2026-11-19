//! 项目相关的结构化错误。
//!
//! 错误码供 Tauri IPC 与前端稳定映射；消息面向用户，不包含用户输入的项目名称。
//! 数据库错误直接透传 T1-01 的结构化错误码，保持错误分类一致。

use thiserror::Error;

use crate::error::DatabaseError;

/// 项目领域错误。
#[derive(Debug, Error)]
pub enum ProjectError {
    /// 项目名称为空或只包含空白字符。
    #[error("项目名称不能为空，请填写项目名称。")]
    EmptyName,

    /// 指定项目 ID 不存在。
    #[error("项目不存在或已被删除（{id}）。请刷新项目列表后重试。")]
    NotFound { id: String },

    /// 项目已归档，不允许继续编辑。
    #[error("已归档项目不能再编辑（{id}）。归档项目仅用于历史数据展示。")]
    ArchivedNotEditable { id: String },

    /// 底层数据库错误（SQLite 打开、写入、完整性等）。
    #[error("{0}")]
    Database(#[from] DatabaseError),
}

impl ProjectError {
    /// 稳定的错误码，供 IPC 与测试断言使用。
    pub fn code(&self) -> &'static str {
        match self {
            Self::EmptyName => "project-name-empty",
            Self::NotFound { .. } => "project-not-found",
            Self::ArchivedNotEditable { .. } => "project-archived",
            Self::Database(error) => error.code(),
        }
    }
}
