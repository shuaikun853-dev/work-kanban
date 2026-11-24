//! 工作事项应用服务：业务规则与事务边界。
//!
//! Rust Core 是工作事项状态的唯一权威来源：
//! - 创建操作在 [`crate::database::Database::write_transaction`] 的 `IMMEDIATE` 事务内完成；
//! - 项目存在性与归档状态（DEC-033）与工作事项插入处于同一事务，前端过滤不是安全边界；
//! - 工作事项 ID 由 Rust Core 生成（UUID v4），前端不得自行构造业务身份；
//! - 创建后的状态固定为 `pending`（待安排），不伪造重要程度/紧急程度/日期等未设置字段；
//! - 待安排查询只返回数据库中的真实 `pending` 记录（含关联归档项目的历史工作）；
//! - 多项目批量创建采用**整批原子提交**（DEC-034）：同一 `IMMEDIATE` 事务内验证全部项目、
//!   写入创建组与全部独立副本及成员关系、事务内读回验证；任一步失败整批回滚，
//!   不允许部分成功、静默跳过或补偿删除。

use std::collections::{HashMap, HashSet};

use chrono::{SecondsFormat, Utc};
use uuid::Uuid;

use crate::database::Database;

use super::error::WorkItemError;
use super::model::{
    CreatedWorkItemCopies, PendingWorkItem, WORK_ITEM_STATUS_PENDING, WorkItem, normalize_title,
};
use super::repository;

/// 工作事项应用服务（无状态）。
pub struct WorkItemService;

impl WorkItemService {
    /// 创建工作事项并返回数据库中的最终记录。
    ///
    /// 规则：
    /// - 标题首尾空白规范化，空标题返回 `work-item-title-empty`；
    /// - `project_id = None` 表示未归属项目，允许创建；
    /// - 指定项目时，在同一个 `IMMEDIATE` 写事务内校验项目存在且未归档：
    ///   不存在返回 `project-not-found`，已归档返回 `project-archived`；
    /// - 相同标题不去重，每次创建都是独立记录。
    pub fn create(
        database: &mut Database,
        raw_title: &str,
        project_id: Option<&str>,
    ) -> Result<WorkItem, WorkItemError> {
        let title = normalize_title(raw_title)?;
        let timestamp = now_utc();
        let work_item = WorkItem {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.map(str::to_string),
            title,
            lifecycle_status: WORK_ITEM_STATUS_PENDING.to_string(),
            importance: None,
            urgency: None,
            due_date: None,
            description: None,
            created_at: timestamp.clone(),
            updated_at: timestamp,
        };
        let database_path = database.database_path().to_path_buf();

        database.write_transaction(move |transaction| {
            // DEC-033：项目校验与插入必须在同一个 IMMEDIATE 写事务中完成。
            // 项目在用户点击保存前被另一个操作归档时，这里看到的是事务内最新状态。
            if let Some(project_id) = work_item.project_id.as_deref() {
                match repository::project_is_archived(transaction, &database_path, project_id)? {
                    None => return Err(WorkItemError::ProjectNotFound),
                    Some(true) => return Err(WorkItemError::ProjectArchived),
                    Some(false) => {}
                }
            }

            repository::insert(transaction, &database_path, &work_item)?;
            repository::find(transaction, &database_path, &work_item.id)?
                .ok_or(WorkItemError::PersistenceVerificationFailed)
        })
    }

    /// 查询全部待安排工作事项（`lifecycle_status = 'pending'`）。
    pub fn list_pending(database: &Database) -> Result<Vec<PendingWorkItem>, WorkItemError> {
        repository::list_pending(
            database.connection(),
            database.database_path(),
            WORK_ITEM_STATUS_PENDING,
        )
    }

    /// 为多个项目批量创建互相独立的工作事项副本，整批原子提交（DEC-034）。
    ///
    /// 幂等语义（T104-02）：
    /// - `request_id` 是客户端为一次逻辑创建操作生成的规范 UUID，并直接复用为
    ///   `work_item_creation_groups.id`（不新增 schema 字段）；
    /// - 同一请求标识 + 相同标题 + 相同项目列表：在真实 `IMMEDIATE` 写事务内返回既有批次，
    ///   不重复创建任何工作副本；即使项目后来已归档，仍返回已提交的既有结果；
    /// - 同一请求标识 + 不同标题或不同项目列表：返回稳定的
    ///   `work-item-create-request-conflict`，不得覆盖或追加；
    /// - 不同请求标识允许使用相同标题创建新的独立批次；
    /// - 并发相同请求标识由 SQLite `IMMEDIATE` 写事务串行化，只允许一个批次。
    ///
    /// 业务规则：
    /// - 标题首尾空白规范化，空标题返回 `work-item-title-empty`；
    /// - 项目数量必须 >= 2，否则返回 `work-item-copies-too-few`；
    /// - 项目 ID 不得重复（不静默去重），否则返回 `work-item-copies-duplicate-project`；
    /// - 在同一 `IMMEDIATE` 写事务内**先验证全部项目**（存在且未归档），再写入创建组、
    ///   全部工作副本与全部成员关系，最后在事务内读回验证；
    /// - 任一项目不存在（`project-not-found`）、已归档（`project-archived`）、
    ///   任一条写入失败（数据库错误）或读回验证不一致
    ///   （`work-item-persistence-verification-failed`）时整批回滚。
    pub fn create_copies(
        database: &mut Database,
        request_id: &str,
        raw_title: &str,
        project_ids: &[String],
    ) -> Result<CreatedWorkItemCopies, WorkItemError> {
        // 1. 标题规范化与校验（与 T1-03 单条创建规则一致）。
        let title = normalize_title(raw_title)?;
        // 2. 批量项目数量与去重校验（在任何数据库写入之前拒绝）。
        validate_copy_batch(project_ids)?;
        // 3. 客户端请求标识必须是规范 UUID；它同时作为创建组主键。
        let group_id = normalize_request_id(request_id)?;

        // 4. 生成每个项目独立的工作副本身份；时间戳统一使用同一 UTC 时刻。
        //    幂等重试时这些候选身份不会落库：事务内先按请求标识返回既有批次。
        let timestamp = now_utc();
        let work_items: Vec<WorkItem> = project_ids
            .iter()
            .map(|project_id| WorkItem {
                id: Uuid::new_v4().to_string(),
                project_id: Some(project_id.clone()),
                title: title.clone(),
                lifecycle_status: WORK_ITEM_STATUS_PENDING.to_string(),
                importance: None,
                urgency: None,
                due_date: None,
                description: None,
                created_at: timestamp.clone(),
                updated_at: timestamp.clone(),
            })
            .collect();
        let database_path = database.database_path().to_path_buf();

        // 5. 整批原子事务：先幂等查重 → 验证全部项目 → 写创建组 → 写全部副本
        //    → 写全部成员关系 → 读回验证。
        database.write_transaction(move |transaction| {
            // 5.1 相同请求标识的已提交批次必须原样返回；标题/项目列表不一致则稳定拒绝。
            if let Some(existing) =
                find_existing_batch(transaction, &database_path, &group_id, &title, project_ids)?
            {
                return Ok(existing);
            }

            // 5.2 先验证全部项目；此循环结束前不写入任何记录。
            // 不得只校验第一个项目：任一项目不存在/已归档都导致整批失败。
            for work_item in &work_items {
                let Some(project_id) = work_item.project_id.as_deref() else {
                    // 批量创建的副本必须关联项目；构造阶段已保证 Some，防御性处理。
                    return Err(WorkItemError::CopiesTooFewProjects);
                };
                match repository::project_is_archived(transaction, &database_path, project_id)? {
                    None => return Err(WorkItemError::ProjectNotFound),
                    Some(true) => return Err(WorkItemError::ProjectArchived),
                    Some(false) => {}
                }
            }

            // 5.3 创建组（客户端请求标识 + 来源标题 + 创建时间）。
            repository::insert_creation_group(
                transaction,
                &database_path,
                &group_id,
                &title,
                &timestamp,
            )?;

            // 5.4 全部独立工作副本。
            for work_item in &work_items {
                repository::insert(transaction, &database_path, work_item)?;
            }

            // 5.5 全部成员关系。
            for work_item in &work_items {
                repository::insert_creation_group_member(
                    transaction,
                    &database_path,
                    &group_id,
                    &work_item.id,
                )?;
            }

            // 5.6 事务内读回验证：任何不一致都视为持久化验证失败并整批回滚。
            let stored_group =
                repository::find_creation_group(transaction, &database_path, &group_id)?
                    .ok_or(WorkItemError::PersistenceVerificationFailed)?;
            if stored_group.source_title != title || stored_group.created_at != timestamp {
                return Err(WorkItemError::PersistenceVerificationFailed);
            }

            let stored_members =
                repository::list_creation_group_members(transaction, &database_path, &group_id)?;
            if stored_members.len() != work_items.len() {
                return Err(WorkItemError::PersistenceVerificationFailed);
            }

            let expected_item_ids: HashSet<&str> = work_items
                .iter()
                .map(|work_item| work_item.id.as_str())
                .collect();
            for member in &stored_members {
                if member.group_id != group_id
                    || !expected_item_ids.contains(member.work_item_id.as_str())
                {
                    return Err(WorkItemError::PersistenceVerificationFailed);
                }
            }

            let mut verified_work_items = Vec::with_capacity(work_items.len());
            for work_item in &work_items {
                let stored = repository::find(transaction, &database_path, &work_item.id)?
                    .ok_or(WorkItemError::PersistenceVerificationFailed)?;
                if stored != *work_item {
                    return Err(WorkItemError::PersistenceVerificationFailed);
                }
                let matching_members: Vec<&repository::CreationGroupMemberRow> = stored_members
                    .iter()
                    .filter(|member| member.work_item_id == work_item.id)
                    .collect();
                if matching_members.len() != 1 {
                    return Err(WorkItemError::PersistenceVerificationFailed);
                }
                if matching_members[0].project_id != work_item.project_id {
                    return Err(WorkItemError::PersistenceVerificationFailed);
                }
                verified_work_items.push(stored);
            }

            Ok(CreatedWorkItemCopies {
                group_id,
                work_items: verified_work_items,
            })
        })
    }
}

/// 在写事务内按客户端请求标识查找既有批次。
///
/// 返回 `Ok(None)` 表示请求标识尚未处理，可创建新批次；
/// 返回 `Ok(Some(..))` 表示幂等重试，必须原样返回既有权威记录，不写入任何行；
/// 相同请求标识对应不同标题/项目列表时返回 [`WorkItemError::CreateRequestConflict`]。
/// 批次内部数据不一致时 fail-closed 返回持久化验证失败，绝不静默重建。
fn find_existing_batch(
    transaction: &rusqlite::Transaction<'_>,
    database_path: &std::path::Path,
    request_id: &str,
    title: &str,
    project_ids: &[String],
) -> Result<Option<CreatedWorkItemCopies>, WorkItemError> {
    let Some(stored_group) =
        repository::find_creation_group(transaction, database_path, request_id)?
    else {
        return Ok(None);
    };
    if stored_group.source_title != title {
        return Err(WorkItemError::CreateRequestConflict);
    }

    let stored_members =
        repository::list_creation_group_members(transaction, database_path, request_id)?;
    let member_row_count =
        repository::count_creation_group_members(transaction, database_path, request_id)?;
    if member_row_count != stored_members.len() as i64 {
        // 成员关系表有行但 JOIN 不到工作副本/创建组：数据不一致，不得当作重试成功。
        return Err(WorkItemError::PersistenceVerificationFailed);
    }
    if stored_members.len() != project_ids.len() {
        return Err(WorkItemError::CreateRequestConflict);
    }

    // 以真实 project_id 建立索引；重复项目或缺失项目都表示请求内容与既有批次不一致。
    let mut members_by_project: HashMap<String, repository::CreationGroupMemberRow> =
        HashMap::with_capacity(stored_members.len());
    for member in stored_members {
        if member.group_id != request_id {
            return Err(WorkItemError::PersistenceVerificationFailed);
        }
        let Some(project_id) = member.project_id.clone() else {
            return Err(WorkItemError::PersistenceVerificationFailed);
        };
        if members_by_project.insert(project_id, member).is_some() {
            return Err(WorkItemError::PersistenceVerificationFailed);
        }
    }

    let mut work_items = Vec::with_capacity(project_ids.len());
    for project_id in project_ids {
        let Some(member) = members_by_project.remove(project_id) else {
            return Err(WorkItemError::CreateRequestConflict);
        };
        let stored = repository::find(transaction, database_path, &member.work_item_id)?
            .ok_or(WorkItemError::PersistenceVerificationFailed)?;
        if stored.project_id.as_deref() != Some(project_id.as_str()) {
            return Err(WorkItemError::PersistenceVerificationFailed);
        }
        work_items.push(stored);
    }
    if !members_by_project.is_empty() {
        return Err(WorkItemError::CreateRequestConflict);
    }

    Ok(Some(CreatedWorkItemCopies {
        group_id: request_id.to_string(),
        work_items,
    }))
}

/// 校验客户端请求标识：必须是规范小写连字符 UUID。
fn normalize_request_id(raw_request_id: &str) -> Result<String, WorkItemError> {
    let parsed =
        Uuid::parse_str(raw_request_id).map_err(|_| WorkItemError::InvalidCreateRequestId)?;
    let canonical = parsed.hyphenated().to_string();
    if canonical != raw_request_id {
        return Err(WorkItemError::InvalidCreateRequestId);
    }
    Ok(canonical)
}

/// 批量创建请求校验：至少两个项目，且项目 ID 不得重复。
///
/// 校验发生在开启写事务之前：无效输入不会触碰数据库。
fn validate_copy_batch(project_ids: &[String]) -> Result<(), WorkItemError> {
    if project_ids.len() < 2 {
        return Err(WorkItemError::CopiesTooFewProjects);
    }
    let mut seen = HashSet::with_capacity(project_ids.len());
    for project_id in project_ids {
        if !seen.insert(project_id.as_str()) {
            return Err(WorkItemError::CopiesDuplicateProject);
        }
    }
    Ok(())
}

/// 工作事项时间戳统一使用 UTC RFC3339（毫秒精度），展示时由前端转换为业务时区。
fn now_utc() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}
