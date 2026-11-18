//! 项目领域模型。
//!
//! 字段范围严格对应 PRD 5.1 与技术设计 5.1 的项目模型：
//! 项目 ID、项目名称、是否归档、创建时间、更新时间。
//! PRD 未定义项目名称唯一性、分类、颜色、描述等字段，因此本模型不擅自扩展业务字段。

use serde::Serialize;

use super::error::ProjectError;

/// 项目业务实体。
///
/// - `id`：Rust Core 生成的稳定 UUID，前端不得使用数组下标作为项目身份；
/// - `is_archived`：归档标记；归档只修改该字段，不删除记录；
/// - 时间字段：UTC RFC3339 字符串，展示时由前端按业务时区 Asia/Shanghai 格式化。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub id: String,
    pub name: String,
    pub is_archived: bool,
    pub created_at: String,
    pub updated_at: String,
}

/// 规范化并校验项目名称。
///
/// PRD 未定义更复杂的命名规则；这里只实施最小必要规则：
/// 去除首尾空白后必须非空。不限制名称长度（长名称是 UI 边界场景，由前端负责展示裁剪），
/// 也不建立名称唯一约束（PRD 未定义）。
pub(crate) fn normalize_name(raw_name: &str) -> Result<String, ProjectError> {
    let trimmed = raw_name.trim();
    if trimmed.is_empty() {
        return Err(ProjectError::EmptyName);
    }
    Ok(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::normalize_name;
    use crate::projects::ProjectError;

    #[test]
    fn normalizes_surrounding_whitespace_only() {
        assert_eq!(
            normalize_name("  中核商品价格异常排查  ").expect("合法名称"),
            "中核商品价格异常排查"
        );
    }

    #[test]
    fn rejects_empty_and_whitespace_only_names() {
        for raw in ["", "   ", "\t", "\n", " \u{3000} "] {
            let error = normalize_name(raw).expect_err("空白名称必须被拒绝");
            assert_eq!(error.code(), "project-name-empty");
        }
    }

    #[test]
    fn keeps_inner_whitespace_and_long_names() {
        let long_name = "很长的项目名称".repeat(40);
        assert_eq!(normalize_name(&long_name).expect("长名称允许"), long_name);
        assert_eq!(
            normalize_name("项目 A · 内部 名称").expect("内部空白保留"),
            "项目 A · 内部 名称"
        );
    }

    #[test]
    fn empty_name_error_does_not_echo_user_input() {
        let error = ProjectError::EmptyName;
        assert!(!error.to_string().contains("中核"));
    }
}
