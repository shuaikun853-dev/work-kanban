//! 项目领域模块（T1-02）。
//!
//! 结构：
//! - [`model`]：项目实体与名称规范化；
//! - [`repository`]：项目表参数化 SQL；
//! - [`service`]：业务规则与事务边界；
//! - [`error`]：稳定的项目错误码。
//!
//! 本模块属于 `workmanager-core`，不依赖 Tauri；数据库连接与 SQL 不会暴露给前端。

mod error;
mod model;
mod repository;
mod service;

pub use error::ProjectError;
pub use model::Project;
pub use service::ProjectService;
