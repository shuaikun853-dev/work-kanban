//! 工作事项领域模块（T1-03）。
//!
//! 结构：
//! - [`model`]：工作事项实体、待安排读模型与标题规范化；
//! - [`repository`]：`work_items` 表参数化 SQL；
//! - [`service`]：业务规则与事务边界（创建时在同一 IMMEDIATE 事务内校验项目状态）；
//! - [`error`]：稳定的工作事项错误码。
//!
//! 本模块属于 `workmanager-core`，不依赖 Tauri；数据库连接与 SQL 不会暴露给前端。
//! T1-03 只写入生命周期状态 `pending`（待安排），状态流转属于 T1-05。

mod error;
mod model;
mod repository;
mod service;

pub use error::WorkItemError;
pub use model::{PendingWorkItem, WORK_ITEM_STATUS_PENDING, WorkItem};
pub use service::WorkItemService;
