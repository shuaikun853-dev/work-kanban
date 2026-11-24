/**
 * T1-03 / T1-04 工作事项 IPC 契约（前端唯一工作事项数据契约来源）。
 *
 * 字段必须与 Rust 后端 serde camelCase 输出逐字段一致：
 * - 命令：`create_work_item` / `list_pending_work_items` / `create_work_item_copies`
 * - 成功：`WorkItem`（创建返回，10 字段）、`PendingWorkItem`（待安排列表，8 字段）、
 *   `CreatedWorkItemCopies`（多项目批量创建，`{groupId, workItems}`）
 *   （crates/workmanager-core/src/work_items/model.rs）
 * - 失败：`IpcErrorPayload`（src-tauri/src/commands/mod.rs 的 CommandError）
 *
 * 运行时严格契约（与 `bridge/workItemValidation.ts` 一致）：
 * - DTO 必须包含下列全部字段；缺少任何字段都会被拒绝；
 * - 未列出的额外字段一律拒绝（不允许静默忽略未知字段）；
 * - `importance`、`urgency` 为 `null` 或 1–5 的整数；
 * - `dueDate`、`description` 为 `null` 或字符串；
 * - `lifecycleStatus` 在待安排/创建场景只接受 `"pending"`；
 * - 批量创建响应数量必须与请求项目数一致，且每个项目恰好一个副本；
 * - 批量创建 `groupId` 必须与本次请求的 `requestId` 逐字相等（Rust Core 校验后直接
 *   复用请求标识作为创建组主键，合法但不同的 UUID 也是契约错误）；
 * - 批量创建每个副本 `title` 必须等于请求标题按 Unicode `White_Space` 规范化后的
 *   结果（Rust / TypeScript 使用同一字符集合；不改变大小写、内部空白或 U+FEFF；
 *   不进行 NFC/NFKC）。规范化实现见 `contracts/workItemTitle.ts`。
 *
 * 身份来源（创建组与工作事项不同，不得混淆）：
 * - 工作事项 ID 由 Rust Core 生成，前端禁止自行生成工作事项业务 ID；
 * - 批量创建组 ID（`groupId`）由客户端为一次逻辑创建操作生成规范 UUID `requestId`，
 *   Rust Core 在同一 `IMMEDIATE` 写事务内校验后直接复用为创建组主键；不新增数据库
 *   字段或 migration。
 *
 * 前端不直接访问 SQLite，也不在前端保存/模拟工作事项状态。
 */

export const CREATE_WORK_ITEM_COMMAND = 'create_work_item' as const;
export const CREATE_WORK_ITEM_COPIES_COMMAND = 'create_work_item_copies' as const;
export const LIST_PENDING_WORK_ITEMS_COMMAND = 'list_pending_work_items' as const;

/** T1-03 唯一会写入的生命周期状态：待安排。 */
export const WORK_ITEM_STATUS_PENDING = 'pending' as const;

/** 创建成功后的工作事项 DTO（对应 Rust `WorkItem`，serde camelCase，共 10 字段）。 */
export interface WorkItemDto {
  /** Rust Core 生成的稳定 UUID。 */
  readonly id: string;
  /** 未归属项目时为 `null`；后端不会返回缺省字段。 */
  readonly projectId: string | null;
  readonly title: string;
  readonly lifecycleStatus: string;
  /** 重要程度；未设置为 `null`，已设置为 1–5 的整数。T1-03 不提供写入入口。 */
  readonly importance: number | null;
  /** 紧急程度；未设置为 `null`，已设置为 1–5 的整数。T1-03 不提供写入入口。 */
  readonly urgency: number | null;
  /** 截止日期；未设置为 `null`，已设置为非空日期字符串。T1-03 不提供写入入口。 */
  readonly dueDate: string | null;
  /** 描述；未设置为 `null`，已设置为字符串。T1-03 不提供写入入口。 */
  readonly description: string | null;
  /** UTC RFC3339 时间字符串。 */
  readonly createdAt: string;
  /** UTC RFC3339 时间字符串。 */
  readonly updatedAt: string;
}

/** 待安排列表项 DTO（对应 Rust `PendingWorkItem`，serde camelCase，共 8 字段）。 */
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

/**
 * `create_work_item_copies` 请求体（对应 Rust `CreateWorkItemCopiesRequest`）。
 *
 * - `requestId` 必须由客户端为一次逻辑创建操作生成**规范小写连字符 UUID**，并在 IPC/
 *   Bridge 结果不确定或用户重试时复用；成功确认后必须丢弃。Rust Core 在同一个
 *   `IMMEDIATE` 写事务内校验该标识并**直接复用**为创建组主键（`groupId`）实现幂等：
 *   相同 `requestId` + 相同标题 + 相同项目列表返回既有批次；相同 `requestId` 不同业务
 *   参数返回稳定冲突；不同 `requestId` 可创建新的独立批次；不新增 schema 字段或 migration；
 * - `projectIds` 必须包含 2 个及以上不同项目；少于 2 个或重复项目由 Rust Core 拒绝；
 * - 项目顺序即返回 `workItems` 的顺序；前端不得自行去重后提交；
 * - `title` 由前端先按 `normalizeWorkItemTitle`（Unicode `White_Space`）规范化再提交，
 *   Rust Core 使用同一字符集合再次规范化并保存。
 */
export interface CreateWorkItemCopiesInput {
  readonly requestId: string;
  readonly title: string;
  readonly projectIds: readonly string[];
}

/**
 * `create_work_item_copies` 成功响应（对应 Rust `CreatedWorkItemCopies`）。
 *
 * - `groupId`：客户端本次请求的 `requestId`（规范 UUID）——Rust Core 校验后直接复用
 *   为 `work_item_creation_groups.id`，不是 Rust Core 新生成的 UUID；Bridge 必须验证
 *   `groupId === requestId`；
 * - `workItems`：每个请求项目恰好一个独立工作副本，全部为 `pending`；副本 ID 由 Rust
 *   Core 生成，标题等于请求标题去除首尾 Unicode `White_Space` 后的字符串；
 * - 整批原子提交（DEC-034）：成功响应保证全部副本与成员关系已提交，不存在部分成功。
 */
export interface CreatedWorkItemCopiesDto {
  readonly groupId: string;
  readonly workItems: readonly WorkItemDto[];
}
