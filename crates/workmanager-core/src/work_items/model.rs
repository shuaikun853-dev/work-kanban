//! 工作事项领域模型。
//!
//! 字段范围严格对应 PRD 5.2 / 5.3 与技术设计 5.1 / 5.4：
//! 稳定 ID、可空项目关联、标题、生命周期状态、可选的重要程度/紧急程度/截止日期/描述、
//! 创建与更新时间。T1-03 只创建“待安排”状态，不提供评分、计划日期或排序字段的写入入口。

use serde::Serialize;

use super::error::WorkItemError;

/// 工作事项生命周期状态：待安排。
///
/// T1-03 创建的工作事项固定写入该状态；其余状态（not_started / in_progress / completed /
/// abandoned）已由 schema CHECK 约束预留，流转属于 T1-05。
pub const WORK_ITEM_STATUS_PENDING: &str = "pending";

/// 工作事项业务实体（创建成功后的权威记录）。
///
/// - `id`：Rust Core 生成的稳定 UUID，前端不得自行生成业务 ID；
/// - `project_id`：`None` 表示未归属项目；
/// - 时间字段：UTC RFC3339 字符串，展示时由前端按业务时区 Asia/Shanghai 格式化。
///
/// **序列化契约（与 `src/lib/contracts/workItems.ts` 的 `WorkItemDto` 逐字段一致）：**
/// serde `camelCase` 输出且恰好包含 10 个字段：
/// `id`、`projectId`、`title`、`lifecycleStatus`、`importance`、`urgency`、`dueDate`、
/// `description`、`createdAt`、`updatedAt`。其中 `projectId`、`importance`、`urgency`、
/// `dueDate`、`description` 未设置时序列化为 JSON `null`（不省略字段）；`importance`/
/// `urgency` 已设置时为 1–5 的整数。前端 Bridge 对该字段集合做严格运行时校验，新增或
/// 删除字段必须同步更新 TypeScript 契约与测试。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkItem {
    pub id: String,
    pub project_id: Option<String>,
    pub title: String,
    pub lifecycle_status: String,
    pub importance: Option<i64>,
    pub urgency: Option<i64>,
    pub due_date: Option<String>,
    pub description: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

/// 多项目批量创建的权威结果（T1-04）。
///
/// - `group_id`：客户端为一次逻辑创建操作生成的规范 UUID `requestId`；Rust Core 校验
///   后**直接复用**为 `work_item_creation_groups.id`，不是 Rust Core 新生成的 UUID；
/// - `work_items`：按请求项目顺序返回的事务内读回记录，每个项目恰好一条独立工作副本；
///   每个工作副本的 `WorkItem::id` 仍由 Rust Core 生成（UUID v4），与 `group_id` 无关。
///
/// **序列化契约（与 `src/lib/contracts/workItems.ts` 的 `CreatedWorkItemCopiesDto` 一致）：**
/// 恰好两个 camelCase 字段 `groupId`、`workItems`；`workItems` 复用 [`WorkItem`] 的 10 字段
/// camelCase 契约。整批创建采用原子提交（DEC-034），任一项目或任一写入失败都不返回该结构。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreatedWorkItemCopies {
    pub group_id: String,
    pub work_items: Vec<WorkItem>,
}

/// 待安排列表读模型。
///
/// 通过 `LEFT JOIN projects` 一次性返回项目名称与归档标记：
/// - `project_id = None`：未归属项目，`project_name = None`、`project_is_archived = false`；
/// - 项目已归档：保留 `project_id` 与项目名称，`project_is_archived = true`，
///   用于 UI 轻量提示，不把历史工作从待安排列表隐藏。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingWorkItem {
    pub id: String,
    pub project_id: Option<String>,
    pub project_name: Option<String>,
    pub project_is_archived: bool,
    pub title: String,
    pub lifecycle_status: String,
    pub created_at: String,
    pub updated_at: String,
}

/// 规范化并校验工作标题。
///
/// 规则（PRD 5.2 / T1-03 任务说明）：
/// - 去除首尾空白后必须非空，否则返回 [`WorkItemError::EmptyTitle`]；
/// - 不限制长度，不改变内部空白；
/// - 标题不是业务唯一键，不做去重。
pub(crate) fn normalize_title(raw_title: &str) -> Result<String, WorkItemError> {
    // `str::trim` 使用 `char::is_whitespace`（Unicode White_Space），与
    // `src/lib/contracts/workItemTitle.ts` 的显式字符集合一致；不删除 U+FEFF。
    let normalized = raw_title.trim();
    if normalized.is_empty() {
        return Err(WorkItemError::EmptyTitle);
    }
    Ok(normalized.to_string())
}

#[cfg(test)]
mod tests {
    use super::normalize_title;
    use crate::work_items::WorkItemError;

    /// Unicode `White_Space` 属性对应的 25 个字符；Rust 与 TypeScript 必须完全一致。
    const UNICODE_WHITE_SPACE: [char; 25] = [
        '\u{0009}', '\u{000A}', '\u{000B}', '\u{000C}', '\u{000D}', '\u{0020}', '\u{0085}',
        '\u{00A0}', '\u{1680}', '\u{2000}', '\u{2001}', '\u{2002}', '\u{2003}', '\u{2004}',
        '\u{2005}', '\u{2006}', '\u{2007}', '\u{2008}', '\u{2009}', '\u{200A}', '\u{2028}',
        '\u{2029}', '\u{202F}', '\u{205F}', '\u{3000}',
    ];

    #[test]
    fn title_whitespace_contract_matches_unicode_white_space_exactly() {
        // 全量标量校验：Rust `char::is_whitespace()` 必须恰好等于契约字符集合。
        // 该断言把“Rust 采用 Unicode White_Space”从隐含实现细节变成可审计契约。
        for code_point in 0..=0x10FFFF {
            let Some(character) = char::from_u32(code_point) else {
                continue;
            };
            assert_eq!(
                character.is_whitespace(),
                UNICODE_WHITE_SPACE.contains(&character),
                "字符 U+{code_point:04X} 的 White_Space 判定与契约集合不一致"
            );
        }
        // U+FEFF（ZERO WIDTH NO-BREAK SPACE）不是 Unicode White_Space，必须保留。
        assert!(!'\u{FEFF}'.is_whitespace());
    }

    #[test]
    fn normalizes_each_unicode_white_space_at_both_ends() {
        for whitespace in UNICODE_WHITE_SPACE {
            let raw = format!("{whitespace}整理中核商品数据{whitespace}");
            assert_eq!(
                normalize_title(&raw).expect("首尾 Unicode White_Space 应被删除"),
                "整理中核商品数据",
                "U+{:04X} 必须从两端删除",
                whitespace as u32
            );
            assert_eq!(
                normalize_title(&whitespace.to_string())
                    .expect_err("纯空白标题必须拒绝")
                    .code(),
                "work-item-title-empty",
                "U+{:04X} 单独成标题时必须拒绝",
                whitespace as u32
            );
        }
    }

    #[test]
    fn preserves_leading_and_trailing_zero_width_no_break_space() {
        let raw = "\u{FEFF}整理中核商品数据\u{FEFF}";
        assert_eq!(
            normalize_title(raw).expect("U+FEFF 不是 White_Space，标题非空"),
            raw
        );
        assert_eq!(
            normalize_title("\u{FEFF}").expect("U+FEFF 单独成标题时非空"),
            "\u{FEFF}"
        );
    }

    #[test]
    fn preserves_internal_whitespace_and_does_not_case_fold_or_normalize_unicode() {
        assert_eq!(
            normalize_title("\t\u{0085}\u{3000}Review  中核\t商品数据\u{3000}\u{0085}\n")
                .expect("混合空白规范化"),
            "Review  中核\t商品数据"
        );
        assert_eq!(
            normalize_title("\u{3000}e\u{0301} 与 中核\u{3000}").expect("不做 NFC/NFKC"),
            "e\u{0301} 与 中核"
        );
        // 对照：规范化不会把 combining sequence 折叠成预组合字符。
        assert_ne!(
            normalize_title("\u{3000}e\u{0301}\u{3000}").expect("不做 NFC/NFKC"),
            "\u{00E9}"
        );
    }

    #[test]
    fn normalizes_surrounding_whitespace_only() {
        assert_eq!(
            normalize_title("  整理中核商品数据  ").expect("合法标题"),
            "整理中核商品数据"
        );
        assert_eq!(
            normalize_title("\t整理 中核 商品数据\n").expect("合法标题"),
            "整理 中核 商品数据"
        );
    }

    #[test]
    fn rejects_empty_and_whitespace_only_titles() {
        for raw in ["", "   ", "\t", "\n", " \u{3000} "] {
            let error = normalize_title(raw).expect_err("空白标题必须被拒绝");
            assert_eq!(error.code(), "work-item-title-empty");
        }
    }

    #[test]
    fn keeps_long_titles_without_limit() {
        let long_title = "很长的虚构工作标题".repeat(50);
        assert_eq!(
            normalize_title(&long_title).expect("长标题允许"),
            long_title
        );
    }

    #[test]
    fn identical_titles_are_not_deduplicated_by_model() {
        let first = normalize_title("整理中核商品数据").expect("first");
        let second = normalize_title("整理中核商品数据").expect("second");
        assert_eq!(first, second);
    }

    #[test]
    fn title_error_does_not_echo_user_input() {
        let error = WorkItemError::EmptyTitle;
        assert!(!error.to_string().contains("中核"));
    }
}
