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
 * - 批量创建必须传入完整请求上下文：`requestId` 必须是规范小写连字符 UUID，
 *   响应 `groupId` 必须与 `requestId` 逐字相等（Rust 直接复用请求标识作为创建组主键，
 *   合法但不同的 UUID 也拒绝）；
 * - 请求 `title` 去除首尾空白后必须非空，响应每个副本 `title` 必须等于该 trim 结果
 *   （Rust `normalize_title` 只 trim，不改变大小写、不折叠内部空白）；
 * - 批量创建响应必须恰好包含 `{groupId, workItems}`，数量与请求项目数一致、
 *   每个请求项目恰好一个副本、工作事项 ID 不重复、全部 pending；
 * - 校验失败抛出稳定错误码 `ipc-contract-violation` 的 `WorkItemIpcError`。
 */

import type {
  CreatedWorkItemCopiesDto,
  PendingWorkItemDto,
  WorkItemDto
} from '../contracts/workItems';

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

/** Rust `CreatedWorkItemCopies` serialize 后的完整字段集合（2 字段，serde camelCase）。 */
const CREATED_COPIES_KEYS = ['groupId', 'workItems'] as const;

/** 规范 UUID 文本（8-4-4-4-12 十六进制，大小写不敏感）；Rust Core 生成的工作事项 ID 与客户端 requestId 均应是此类文本。 */
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * 规范小写连字符 UUID：Rust `normalize_request_id` 先 `Uuid::parse_str`，再要求
 * `hyphenated()` 字符串与原文逐字相等，因此大写、无连字符、花括号/URN 包裹等
 * “可解析但非规范”的形式都会被 Rust Core 拒绝，必须在发起调用前就拒绝。
 */
const CANONICAL_REQUEST_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * 批量创建请求上下文：Bridge 必须把调用方传入的三个值全部交给响应校验。
 *
 * 三个值缺一不可 —— 真实 Rust Core 直接复用 `requestId` 作为创建组主键、
 * 只对 `title` 做首尾 `trim`，因此它们本身就是响应契约的一部分。
 */
export interface CreatedCopiesRequestContext {
  /** 调用方生成的规范小写连字符 UUID（Rust 解析后直接作为创建组主键）。 */
  readonly requestId: string;
  /** 请求标题原文；Rust 只做首尾 trim，响应 title 必须等于其 trim 结果。 */
  readonly title: string;
  /** 请求的项目 ID 列表（至少两个、互不相同）。 */
  readonly projectIds: readonly string[];
}

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
  return parseWorkItemAt(raw, '工作事项');
}

function parseWorkItemAt(raw: unknown, path: string): WorkItemDto {
  const record = expectStrictRecord(raw, WORK_ITEM_KEYS, path);
  const lifecycleStatus = expectPendingStatus(
    record.lifecycleStatus,
    `${path}.lifecycleStatus`
  );

  return {
    id: expectNonEmptyString(record.id, `${path}.id`),
    projectId: expectNullableNonEmptyString(record.projectId, `${path}.projectId`),
    title: expectNonEmptyString(record.title, `${path}.title`),
    lifecycleStatus,
    importance: expectNullableScore(record.importance, `${path}.importance`),
    urgency: expectNullableScore(record.urgency, `${path}.urgency`),
    dueDate: expectNullableNonEmptyString(record.dueDate, `${path}.dueDate`),
    description: expectNullableString(record.description, `${path}.description`),
    createdAt: expectString(record.createdAt, `${path}.createdAt`),
    updatedAt: expectString(record.updatedAt, `${path}.updatedAt`)
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
 * 校验并解析多项目批量创建响应（Rust `CreatedWorkItemCopies`）。
 *
 * 必须传入完整请求上下文（`requestId` / `title` / `projectIds`），因为 Rust 的语义是：
 * - `requestId` 由客户端生成且必须为规范小写连字符 UUID，服务端直接复用为创建组主键，
 *   因此 `groupId` 必须与它逐字相等（合法但不同的 UUID 也拒绝）；
 * - 标题只做首尾 trim，因此每个副本 `title` 必须等于 `request.title.trim()`
 *   （大小写、内部空白都不允许变化）；
 * - 响应项目集合必须与请求项目集合一一对应。
 *
 * 除严格字段校验外，还必须验证整批语义：
 * 1. `request.requestId` 必须是规范小写连字符 UUID（Rust 拒绝大小写等非规范形式）；
 * 2. `response.groupId` 必须与 `request.requestId` 完全相等（合法但不同的 UUID 也拒绝）；
 * 3. 每个副本 `title` 必须等于 `request.title.trim()`（空标题/非字符串请求直接拒绝）；
 * 4. 响应数量必须等于请求项目数（不允许部分成功后返回较短数组）；
 * 5. 每个请求项目恰好出现一次（不重复、不缺失、不能被替换成其他项目）；
 * 6. 每个副本工作事项 ID 唯一；
 * 7. 全部副本 `lifecycleStatus = 'pending'` 且 DTO 无缺失/额外字段（由 `parseWorkItemAt` 保证）。
 *
 * 任一不满足都抛 `ipc-contract-violation`，不静默忽略契约错误。
 */
export function parseCreatedWorkItemCopies(
  raw: unknown,
  request: CreatedCopiesRequestContext
): CreatedWorkItemCopiesDto {
  if (!isRecord(request)) {
    throw contractViolation(
      '请求',
      '包含 requestId、title、projectIds 的批量创建请求上下文对象',
      request
    );
  }
  const requestId = expectCanonicalRequestId(request.requestId);
  const expectedTitle = expectRequestTitle(request.title);
  const expectedProjectIds = expectRequestedProjectIds(request.projectIds);
  const record = expectStrictRecord(raw, CREATED_COPIES_KEYS, '批量创建工作结果');
  const groupId = expectCanonicalUuid(record.groupId, '批量创建工作结果.groupId');
  // Rust 直接复用请求标识作为创建组主键：合法但不同的 UUID 同样是契约错误。
  if (groupId !== requestId) {
    throw contractViolation(
      '批量创建工作结果.groupId',
      '与请求 requestId 完全一致的规范 UUID（服务端直接复用请求标识作为创建组主键）',
      groupId
    );
  }
  if (!Array.isArray(record.workItems)) {
    throw contractViolation('批量创建工作结果.workItems', '数组', record.workItems);
  }
  if (record.workItems.length !== expectedProjectIds.size) {
    throw contractViolation(
      '批量创建工作结果.workItems',
      `长度为 ${expectedProjectIds.size}（与请求项目数量一致）`,
      record.workItems.length
    );
  }

  const workItems = record.workItems.map((item, index) =>
    parseWorkItemAt(item, `批量创建工作结果.workItems[${index}]`)
  );

  const seenProjectIds = new Set<string>();
  const seenWorkItemIds = new Set<string>();
  workItems.forEach((item, index) => {
    const path = `批量创建工作结果.workItems[${index}]`;
    // Rust `normalize_title` 只做首尾 trim：大小写与内部空白必须原样保留。
    if (item.title !== expectedTitle) {
      throw contractViolation(
        `${path}.title`,
        '与请求 title 去除首尾空白后的字符串完全一致（不改变大小写或内部空白）',
        item.title
      );
    }
    if (item.projectId === null) {
      throw contractViolation(`${path}.projectId`, '请求项目 ID 字符串', null);
    }
    if (!expectedProjectIds.has(item.projectId)) {
      throw contractViolation(
        `${path}.projectId`,
        '请求项目之一（不得替换为其他项目）',
        item.projectId
      );
    }
    if (seenProjectIds.has(item.projectId)) {
      throw contractViolation(`${path}.projectId`, '每个请求项目恰好一个副本', item.projectId);
    }
    seenProjectIds.add(item.projectId);
    if (seenWorkItemIds.has(item.id)) {
      throw contractViolation(`${path}.id`, '唯一的工作事项 ID', item.id);
    }
    seenWorkItemIds.add(item.id);
  });

  if (seenProjectIds.size !== expectedProjectIds.size) {
    throw contractViolation(
      '批量创建工作结果.workItems',
      '每个请求项目恰好一个副本',
      Array.from(expectedProjectIds)
    );
  }

  return { groupId, workItems };
}

/**
 * 校验请求 `requestId`：必须是规范小写连字符 UUID。
 *
 * Rust 侧先 `Uuid::parse_str` 再用 `hyphenated()` 结果与原文比较，因此大写、无连字符、
 * 花括号/URN 包裹等非规范形式都会被拒绝；该值还会直接成为响应 `groupId`。
 */
function expectCanonicalRequestId(value: unknown): string {
  const text = expectNonEmptyString(value, '请求 requestId');
  if (!CANONICAL_REQUEST_ID_PATTERN.test(text)) {
    throw contractViolation(
      '请求 requestId',
      '规范小写连字符 UUID 字符串（8-4-4-4-12，十六进制小写；大写或非规范形式会被 Rust Core 拒绝）',
      value
    );
  }
  return text;
}

/**
 * 校验请求 `title` 并返回 Rust `normalize_title` 的结果（仅去除首尾空白）。
 *
 * 不改变大小写、不折叠内部空白；响应 `title` 必须与该结果完全相等。
 */
function expectRequestTitle(value: unknown): string {
  const text = expectString(value, '请求 title');
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    throw contractViolation('请求 title', '去除首尾空白后非空的字符串', value);
  }
  return trimmed;
}

/**
 * 校验批量创建调用方传入的请求项目 ID：
 * 必须是 2 个及以上、互不相同、非空白的字符串（与 Rust Core 批量接口规则一致）。
 */
function expectRequestedProjectIds(value: readonly string[]): Set<string> {
  if (!Array.isArray(value)) {
    throw contractViolation('请求 projectIds', '字符串数组', value);
  }
  if (value.length < 2) {
    throw contractViolation('请求 projectIds', '至少两个项目 ID', value.length);
  }
  const unique = new Set<string>();
  value.forEach((projectId, index) => {
    const path = `请求 projectIds[${index}]`;
    if (typeof projectId !== 'string' || projectId.trim().length === 0) {
      throw contractViolation(path, '非空字符串', projectId);
    }
    if (unique.has(projectId)) {
      throw contractViolation(path, '不重复的项目 ID（不得静默去重）', projectId);
    }
    unique.add(projectId);
  });
  return unique;
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

/** 规范 UUID 字符串（Rust Core 生成的创建组 / 工作事项稳定 ID）。 */
function expectCanonicalUuid(value: unknown, path: string): string {
  const text = expectNonEmptyString(value, path);
  if (!UUID_PATTERN.test(text)) {
    throw contractViolation(path, '规范 UUID 字符串', value);
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
