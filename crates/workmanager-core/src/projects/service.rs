//! 项目应用服务：业务规则与事务边界。
//!
//! Rust Core 是项目状态的唯一权威来源：
//! - 所有写操作在 [`crate::database::Database::write_transaction`] 的 `IMMEDIATE` 事务内完成；
//! - 归档只更新 `is_archived`，不删除记录，也不触碰未来工作事项历史关联；
//! - 已归档项目拒绝编辑，但保留在列表中用于历史数据展示；
//! - 项目 ID 由 Rust Core 生成（UUID v4），前端不得自行构造业务身份。

use chrono::{SecondsFormat, Utc};
use uuid::Uuid;

use crate::database::Database;

use super::error::ProjectError;
use super::model::{Project, normalize_name};
use super::repository;

/// 项目应用服务（无状态）。
pub struct ProjectService;

impl ProjectService {
    /// 查询全部项目（未归档在前，归档项目在后）。
    pub fn list(database: &Database) -> Result<Vec<Project>, ProjectError> {
        repository::list(database.connection(), database.database_path())
    }

    /// 创建项目并返回数据库中的最终记录。
    pub fn create(database: &mut Database, raw_name: &str) -> Result<Project, ProjectError> {
        let name = normalize_name(raw_name)?;
        let timestamp = now_utc();
        let project = Project {
            id: Uuid::new_v4().to_string(),
            name,
            is_archived: false,
            created_at: timestamp.clone(),
            updated_at: timestamp,
        };
        let database_path = database.database_path().to_path_buf();

        database.write_transaction(move |transaction| {
            repository::insert(transaction, &database_path, &project)?;
            repository::find(transaction, &database_path, &project.id)?.ok_or_else(|| {
                ProjectError::NotFound {
                    id: project.id.clone(),
                }
            })
        })
    }

    /// 编辑项目名称。
    ///
    /// - 项目不存在：`project-not-found`；
    /// - 项目已归档：`project-archived`（归档项目只读用于历史展示）。
    pub fn update(
        database: &mut Database,
        project_id: &str,
        raw_name: &str,
    ) -> Result<Project, ProjectError> {
        let name = normalize_name(raw_name)?;
        let project_id = project_id.to_string();
        let database_path = database.database_path().to_path_buf();

        database.write_transaction(move |transaction| {
            let current =
                repository::find(transaction, &database_path, &project_id)?.ok_or_else(|| {
                    ProjectError::NotFound {
                        id: project_id.clone(),
                    }
                })?;
            if current.is_archived {
                return Err(ProjectError::ArchivedNotEditable { id: project_id });
            }

            let updated_at = now_utc();
            repository::update_name(transaction, &database_path, &project_id, &name, &updated_at)?;
            repository::find(transaction, &database_path, &project_id)?.ok_or_else(|| {
                ProjectError::NotFound {
                    id: project_id.clone(),
                }
            })
        })
    }

    /// 归档项目。
    ///
    /// 归档是幂等的非破坏性操作：项目记录与 ID 保留，`is_archived` 置为 1；
    /// 重复归档返回当前记录且不改变更新时间。不执行任何 DELETE / 级联删除。
    pub fn archive(database: &mut Database, project_id: &str) -> Result<Project, ProjectError> {
        let project_id = project_id.to_string();
        let database_path = database.database_path().to_path_buf();

        database.write_transaction(move |transaction| {
            let current =
                repository::find(transaction, &database_path, &project_id)?.ok_or_else(|| {
                    ProjectError::NotFound {
                        id: project_id.clone(),
                    }
                })?;
            if current.is_archived {
                return Ok(current);
            }

            let updated_at = now_utc();
            repository::archive(transaction, &database_path, &project_id, &updated_at)?;
            repository::find(transaction, &database_path, &project_id)?.ok_or_else(|| {
                ProjectError::NotFound {
                    id: project_id.clone(),
                }
            })
        })
    }
}

/// 项目时间戳统一使用 UTC RFC3339（毫秒精度），展示时由前端转换为业务时区。
fn now_utc() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}
