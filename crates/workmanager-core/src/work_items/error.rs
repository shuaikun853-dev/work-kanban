//! 工作事项相关的结构化错误。
//!
//! 错误码供 Tauri IPC 与前端稳定映射；消息面向用户，不包含工作标题、项目名称或
//! SQL 参数值。数据库错误直接透传 T1-01 的结构化错误码，保持错误分类一致。

use thiserror::Error;

use crate::error::DatabaseError;

/// 工作事项领域错误。
#[derive(Debug, Error)]
pub enum WorkItemError {
    /// 工作标题为空或只包含空白字符。
    #[error("工作标题不能为空，请填写工作标题。")]
    EmptyTitle,

    /// 指定的项目 ID 不存在。
    #[error("所选项目不存在或已被删除。请刷新项目列表后重试。")]
    ProjectNotFound,

    /// 项目已归档，不允许新建工作事项关联。
    ///
    /// DEC-033：新建工作只能关联未归档项目；已存在工作事项的历史关联不受影响。
    #[error("所选项目已归档，不能再关联新工作。请选择其他项目或不选择项目。")]
    ProjectArchived,

    /// 多项目批量创建时项目数量少于 2。
    ///
    /// 批量创建接口只接受 2 个及以上项目；0 / 1 个项目应使用 T1-03 单条创建接口。
    #[error("批量创建至少需要两个不同的项目。")]
    CopiesTooFewProjects,

    /// 多项目批量创建时项目 ID 出现重复。
    ///
    /// 不得静默去重后继续创建：去重会改变用户在界面上确认的预计创建数量。
    #[error("所选项目存在重复，请重新选择项目后提交。")]
    CopiesDuplicateProject,

    /// 创建事务提交后无法按 ID 读回刚写入的记录（不应发生的内部一致性错误）。
    #[error("工作事项已写入但无法读取，请重试或检查数据库状态。")]
    PersistenceVerificationFailed,

    /// 底层数据库错误（SQLite 打开、写入、完整性等）。
    #[error("{0}")]
    Database(#[from] DatabaseError),
}

impl WorkItemError {
    /// 稳定的错误码，供 IPC 与测试断言使用。
    pub fn code(&self) -> &'static str {
        match self {
            Self::EmptyTitle => "work-item-title-empty",
            Self::ProjectNotFound => "project-not-found",
            Self::ProjectArchived => "project-archived",
            Self::CopiesTooFewProjects => "work-item-copies-too-few",
            Self::CopiesDuplicateProject => "work-item-copies-duplicate-project",
            Self::PersistenceVerificationFailed => "work-item-persistence-verification-failed",
            Self::Database(error) => error.code(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::WorkItemError;

    #[test]
    fn error_messages_do_not_echo_business_content() {
        for error in [
            WorkItemError::EmptyTitle,
            WorkItemError::ProjectNotFound,
            WorkItemError::ProjectArchived,
            WorkItemError::CopiesTooFewProjects,
            WorkItemError::CopiesDuplicateProject,
            WorkItemError::PersistenceVerificationFailed,
        ] {
            let message = error.to_string();
            assert!(!message.contains("整理中核商品数据"));
            assert!(!message.contains("虚构项目"));
            assert!(!message.contains("SELECT"));
        }
    }

    #[test]
    fn stable_error_codes_are_exposed() {
        assert_eq!(WorkItemError::EmptyTitle.code(), "work-item-title-empty");
        assert_eq!(WorkItemError::ProjectNotFound.code(), "project-not-found");
        assert_eq!(WorkItemError::ProjectArchived.code(), "project-archived");
        assert_eq!(
            WorkItemError::CopiesTooFewProjects.code(),
            "work-item-copies-too-few"
        );
        assert_eq!(
            WorkItemError::CopiesDuplicateProject.code(),
            "work-item-copies-duplicate-project"
        );
        assert_eq!(
            WorkItemError::PersistenceVerificationFailed.code(),
            "work-item-persistence-verification-failed"
        );
    }
}
