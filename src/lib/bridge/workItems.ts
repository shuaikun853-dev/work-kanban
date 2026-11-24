/**
 * 工作事项 Tauri Bridge：类型安全地封装
 * `create_work_item` / `create_work_item_copies` / `list_pending_work_items`。
 *
 * 职责：
 * - 只调用明确的业务命令，不提供任意 SQL / 任意文件读写入口；
 * - 防御式解析 Tauri invoke 失败载荷，统一转换为 `WorkItemIpcError`；
 * - 对成功返回值做运行时契约校验（`workItemValidation.ts`），拒绝后端字段漂移；
 * - 不缓存、不持久化工作事项业务状态（Rust Core 是唯一权威来源）。
 */

import { invoke, isTauri } from '@tauri-apps/api/core';

import type { IpcErrorPayload } from '../contracts/ipc';
import {
  CREATE_WORK_ITEM_COMMAND,
  CREATE_WORK_ITEM_COPIES_COMMAND,
  LIST_PENDING_WORK_ITEMS_COMMAND
} from '../contracts/workItems';
import type {
  CreateWorkItemCopiesInput,
  CreateWorkItemInput,
  CreatedWorkItemCopiesDto,
  PendingWorkItemDto,
  WorkItemDto
} from '../contracts/workItems';
import {
  WorkItemIpcError,
  parseCreatedWorkItemCopies,
  parsePendingWorkItemList,
  parseWorkItem
} from './workItemValidation';

export { WorkItemIpcError, parseCreatedWorkItemCopies, parsePendingWorkItemList, parseWorkItem };

const COMMAND_FAILED_CODE = 'ipc-command-failed';
const UNKNOWN_IPC_ERROR_CODE = 'ipc-unknown-error';
const TAURI_UNAVAILABLE_CODE = 'tauri-runtime-unavailable';

/** 创建工作事项；`projectId` 必须显式传 `null` 表示未归属项目。 */
export async function createWorkItem(
  title: string,
  projectId: string | null
): Promise<WorkItemDto> {
  ensureDesktopRuntime();
  const input: CreateWorkItemInput = { title, projectId };
  const raw = await invokeWorkItemCommand(CREATE_WORK_ITEM_COMMAND, { input });
  return parseWorkItem(raw);
}

/**
 * 为多个项目批量创建互相独立的工作事项副本（整批原子提交，DEC-034）。
 *
 * - `projectIds` 必须包含 2 个及以上不同项目；少于 2 个或重复项目由 Rust Core 拒绝；
 * - 响应必须通过严格运行时契约校验（数量、项目一一对应、ID 唯一、全部 pending）；
 * - 任一项目不存在/已归档时后端整批失败，不会返回部分成功。
 */
export async function createWorkItemCopies(
  title: string,
  projectIds: readonly string[]
): Promise<CreatedWorkItemCopiesDto> {
  ensureDesktopRuntime();
  const input: CreateWorkItemCopiesInput = { title, projectIds: [...projectIds] };
  const raw = await invokeWorkItemCommand(CREATE_WORK_ITEM_COPIES_COMMAND, { input });
  return parseCreatedWorkItemCopies(raw, projectIds);
}

/** 查询待安排工作事项（排序由 Rust Core 决定：created_at DESC, id DESC）。 */
export async function listPendingWorkItems(): Promise<PendingWorkItemDto[]> {
  ensureDesktopRuntime();
  const raw = await invokeWorkItemCommand(LIST_PENDING_WORK_ITEMS_COMMAND);
  return parsePendingWorkItemList(raw);
}

async function invokeWorkItemCommand(
  command: string,
  args?: Record<string, unknown>
): Promise<unknown> {
  try {
    return await invoke<unknown>(command, args);
  } catch (cause: unknown) {
    throw toWorkItemIpcError(cause);
  }
}

function ensureDesktopRuntime(): void {
  if (!isTauri()) {
    throw new WorkItemIpcError(
      TAURI_UNAVAILABLE_CODE,
      '当前页面不在 Tauri 桌面窗口内运行，无法调用本机工作事项命令。请使用 `npm run tauri dev` 启动应用，或打开打包后的 WorkManager。'
    );
  }
}

function toWorkItemIpcError(cause: unknown): WorkItemIpcError {
  if (cause instanceof WorkItemIpcError) {
    return cause;
  }

  const payload = readIpcErrorPayload(cause);
  if (payload !== null) {
    return new WorkItemIpcError(payload.code, payload.message);
  }

  const serialized = stringifyUnknown(cause);
  return new WorkItemIpcError(
    UNKNOWN_IPC_ERROR_CODE,
    serialized === null
      ? '调用工作事项命令时发生未知错误，且无法读取错误详情。'
      : `调用工作事项命令时发生未知错误：${serialized}`
  );
}

function readIpcErrorPayload(cause: unknown): IpcErrorPayload | null {
  if (typeof cause === 'string') {
    const text = cause.trim();
    if (text.length === 0) {
      return null;
    }
    const parsed = parseJsonRecord(text);
    if (parsed !== null) {
      const nested = readIpcErrorPayload(parsed);
      return nested ?? { code: COMMAND_FAILED_CODE, message: text };
    }
    return { code: COMMAND_FAILED_CODE, message: text };
  }

  if (cause instanceof Error) {
    const message = cause.message.trim();
    return message.length > 0 ? { code: COMMAND_FAILED_CODE, message } : null;
  }

  if (isRecord(cause)) {
    const code = readNonEmptyString(cause.code);
    const message = readNonEmptyString(cause.message);
    if (code !== null && message !== null) {
      return { code, message };
    }
    if (code !== null) {
      return { code, message: '后端返回了错误码，但没有提供可读的错误消息。' };
    }
    if (message !== null) {
      return { code: COMMAND_FAILED_CODE, message };
    }
  }

  return null;
}

function parseJsonRecord(text: string): Record<string, unknown> | null {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(trimmed);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function stringifyUnknown(value: unknown): string | null {
  if (value === undefined) {
    return null;
  }
  try {
    const text: unknown = JSON.stringify(value);
    return typeof text === 'string' ? text : null;
  } catch {
    return null;
  }
}

function readNonEmptyString(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
