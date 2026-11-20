/**
 * 工作事项 IPC 返回值的纯运行时校验（不依赖 Tauri / DOM / 浏览器 API）。
 *
 * 该模块可被 TypeScript 页面与 Node 契约测试直接加载：
 * - 页面通过 `bridge/workItems.ts` 在每次成功 IPC 后调用；
 * - `scripts/quality/work-item-bridge.test.mjs` 用 Node 直接验证合法/非法返回值。
 *
 * 严格契约策略（与 `contracts/workItems.ts` 一致）：
 * - 必填字段缺失 → 拒绝；
 * - 字段类型错误 → 拒绝；
 * - 未列出的额外字段 → 拒绝（不静默忽略未知字段）；
 * - `projectId`、`projectName` 支持 `null`（未归属项目）；
 * - `importance` / `urgency` 支持 `null` 或 1–5 的整数；
 * - `dueDate` / `description` 支持 `null` 或字符串；
 * - 待安排列表与创建响应只接受 `lifecycleStatus = 'pending'`；
 * - 校验失败抛出稳定错误码 `ipc-contract-violation` 的 `WorkItemIpcError`。
 */

import type { PendingWorkItemDto, WorkItemDto } from '../contracts/workItems';

export const CONTRACT_VIOLATION_CODE = 'ipc-contract-violation';

/** 与 `contracts/workItems.ts` 中的常量保持一致（本模块不引入运行时依赖，便于 Node 测试）。 */
const PENDING_STATUS = 'pending';

/** Rust `WorkItem` serialize 后的完整字段集合（10 字段，serde camelCase）。 */
const WORK_ITEM_KEYS = [
  'id',
  'projectId',
  'title',
  'lifecycleStatus',
  'importance',
  'urgency',
  'dueDate',
  'description',
  'createdAt',
  'updatedAt'
] as const;

/** Rust `PendingWorkItem` serialize 后的完整字段集合（8 字段，serde camelCase）。 */
const PENDING_WORK_ITEM_KEYS = [
  'id',
  'projectId',
  'projectName',
  'projectIsArchived',
  'title',
  'lifecycleStatus',
  'createdAt',
  'updatedAt'
] as const;

/** 面向 UI 的工作事项 IPC 错误：稳定错误码 + 中文可读消息。 */
export class WorkItemIpcError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'WorkItemIpcError';
    this.code = code;
  }
}

/** 校验并解析创建接口返回的单个工作事项 DTO（Rust `WorkItem`，10 字段）。 */
export function parseWorkItem(raw: unknown): WorkItemDto {
  const record = expectStrictRecord(raw, WORK_ITEM_KEYS, '工作事项');
  const lifecycleStatus = expectPendingStatus(record.lifecycleStatus, '工作事项.lifecycleStatus');

  return {
    id: expectNonEmptyString(record.id, '工作事项.id'),
    projectId: expectNullableNonEmptyString(record.projectId, '工作事项.projectId'),
    title: expectNonEmptyString(record.title, '工作事项.title'),
    lifecycleStatus,
    importance: expectNullableScore(record.importance, '工作事项.importance'),
    urgency: expectNullableScore(record.urgency, '工作事项.urgency'),
    dueDate: expectNullableNonEmptyString(record.dueDate, '工作事项.dueDate'),
    description: expectNullableString(record.description, '工作事项.description'),
    createdAt: expectString(record.createdAt, '工作事项.createdAt'),
    updatedAt: expectString(record.updatedAt, '工作事项.updatedAt')
  };
}

/** 校验并解析待安排工作列表（Rust `PendingWorkItem`，8 字段）。 */
export function parsePendingWorkItemList(raw: unknown): PendingWorkItemDto[] {
  if (!Array.isArray(raw)) {
    throw contractViolation('待安排工作列表', '数组', raw);
  }
  return raw.map((item, index) => parsePendingWorkItemAt(item, `待安排工作列表[${index}]`));
}

function parsePendingWorkItemAt(raw: unknown, path: string): PendingWorkItemDto {
  const record = expectStrictRecord(raw, PENDING_WORK_ITEM_KEYS, path);
  const lifecycleStatus = expectPendingStatus(record.lifecycleStatus, `${path}.lifecycleStatus`);
  const projectId = expectNullableNonEmptyString(record.projectId, `${path}.projectId`);
  const projectName = expectNullableNonEmptyString(record.projectName, `${path}.projectName`);
  const projectIsArchived = expectBoolean(record.projectIsArchived, `${path}.projectIsArchived`);

  // 前后端对“未归属项目”的理解必须唯一：projectId 与 projectName 同时为 null。
  if (projectId === null && projectName !== null) {
    throw contractViolation(
      `${path}.projectName`,
      'projectId 为 null 时 projectName 也应为 null',
      projectName
    );
  }
  if (projectId !== null && projectName === null) {
    throw contractViolation(
      `${path}.projectName`,
      'projectId 非 null 时 projectName 应为项目名称字符串',
      projectName
    );
  }
  if (projectId === null && projectIsArchived) {
    throw contractViolation(
      `${path}.projectIsArchived`,
      '未归属项目时 projectIsArchived 应为 false',
      projectIsArchived
    );
  }

  return {
    id: expectNonEmptyString(record.id, `${path}.id`),
    projectId,
    projectName,
    projectIsArchived,
    title: expectNonEmptyString(record.title, `${path}.title`),
    lifecycleStatus,
    createdAt: expectString(record.createdAt, `${path}.createdAt`),
    updatedAt: expectString(record.updatedAt, `${path}.updatedAt`)
  };
}

/**
 * 严格对象校验：必须包含全部约定字段，且不得包含任何额外字段。
 *
 * 缺失字段与未知字段都按 `ipc-contract-violation` 拒绝，避免后端契约漂移被静默忽略。
 */
function expectStrictRecord(
  value: unknown,
  requiredKeys: readonly string[],
  path: string
): Record<string, unknown> {
  if (!isRecord(value)) {
    throw contractViolation(path, '对象', value);
  }
  for (const key of requiredKeys) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) {
      throw contractViolation(`${path}.${key}`, '必需的字段（缺失）', undefined);
    }
  }
  for (const key of Object.keys(value)) {
    if (!requiredKeys.includes(key)) {
      throw contractViolation(`${path}.${key}`, '未定义字段（严格契约拒绝未知字段）', value[key]);
    }
  }
  return value;
}

function expectString(value: unknown, path: string): string {
  if (typeof value !== 'string') {
    throw contractViolation(path, '字符串', value);
  }
  return value;
}

function expectNonEmptyString(value: unknown, path: string): string {
  const text = expectString(value, path);
  if (text.trim().length === 0) {
    throw contractViolation(path, '非空字符串', value);
  }
  return text;
}

function expectNullableString(value: unknown, path: string): string | null {
  if (value === null) {
    return null;
  }
  return expectString(value, path);
}

function expectNullableNonEmptyString(value: unknown, path: string): string | null {
  if (value === null) {
    return null;
  }
  return expectNonEmptyString(value, path);
}

function expectBoolean(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') {
    throw contractViolation(path, '布尔值', value);
  }
  return value;
}

/** 重要程度/紧急程度：`null` 或 1–5 的整数（与数据库 CHECK 约束一致）。 */
function expectNullableScore(value: unknown, path: string): number | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1 || value > 5) {
    throw contractViolation(path, 'null 或 1–5 的整数', value);
  }
  return value;
}

function expectPendingStatus(value: unknown, path: string): string {
  const status = expectString(value, path);
  if (status !== PENDING_STATUS) {
    throw contractViolation(path, `状态 "${PENDING_STATUS}"`, value);
  }
  return status;
}

function contractViolation(path: string, expected: string, actual: unknown): WorkItemIpcError {
  return new WorkItemIpcError(
    CONTRACT_VIOLATION_CODE,
    `工作事项 IPC 返回值不符合契约：${path} 应为 ${expected}，实际为 ${describeType(actual)}。请检查前后端版本是否一致。`
  );
}

function describeType(value: unknown): string {
  if (value === null) {
    return 'null';
  }
  if (Array.isArray(value)) {
    return 'array';
  }
  return typeof value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
