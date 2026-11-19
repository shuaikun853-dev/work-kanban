/**
 * T1-03 工作事项 IPC 契约（前端唯一工作事项数据契约来源）。
 *
 * 字段必须与 Rust 后端 serde camelCase 输出逐字段一致：
 * - 命令：`create_work_item` / `list_pending_work_items`
 * - 成功：`WorkItem`（创建返回）、`PendingWorkItem`（待安排列表）
 *   （crates/workmanager-core/src/work_items/model.rs）
 * - 失败：`IpcErrorPayload`（src-tauri/src/commands/mod.rs 的 CommandError）
 *
 * 工作事项 ID 由 Rust Core 生成；前端禁止自行生成业务 ID。
 * 前端不直接访问 SQLite，也不在前端保存/模拟工作事项状态。
 */

export const CREATE_WORK_ITEM_COMMAND = 'create_work_item' as const;
export const LIST_PENDING_WORK_ITEMS_COMMAND = 'list_pending_work_items' as const;

/** T1-03 唯一会写入的生命周期状态：待安排。 */
export const WORK_ITEM_STATUS_PENDING = 'pending' as const;

/** 创建成功后的工作事项 DTO（对应 Rust `WorkItem`，serde camelCase）。 */
export interface WorkItemDto {
  /** Rust Core 生成的稳定 UUID。 */
  readonly id: string;
  /** 未归属项目时为 `null`；后端不会返回缺省字段。 */
  readonly projectId: string | null;
  readonly title: string;
  readonly lifecycleStatus: string;
  /** UTC RFC3339 时间字符串。 */
  readonly createdAt: string;
  /** UTC RFC3339 时间字符串。 */
  readonly updatedAt: string;
}

/** 待安排列表项 DTO（对应 Rust `PendingWorkItem`，serde camelCase）。 */
export interface PendingWorkItemDto {
  /** Rust Core 生成的稳定 UUID；作为 Svelte keyed each 的 key。 */
  readonly id: string;
  readonly projectId: string | null;
  /** 关联项目的名称；未归属项目时为 `null`。 */
  readonly projectName: string | null;
  /** 关联项目是否已归档；未归属项目时为 `false`。 */
  readonly projectIsArchived: boolean;
  readonly title: string;
  readonly lifecycleStatus: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

/**
 * `create_work_item` 请求体（对应 Rust `CreateWorkItemRequest`）。
 *
 * `projectId` 必须显式发送：未选择项目时发送 `null`，不要省略字段。
 */
export interface CreateWorkItemInput {
  readonly title: string;
  readonly projectId: string | null;
}
