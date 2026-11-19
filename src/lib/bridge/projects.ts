/**
 * 项目 Tauri Bridge：类型安全地封装四个项目命令。
 *
 * 职责：
 * - 只调用明确的业务命令，不提供任意 SQL / 任意文件读写入口；
 * - 防御式解析 Tauri invoke 失败载荷，统一转换为 `ProjectIpcError`；
 * - 对成功返回值做运行时契约校验，避免后端字段漂移导致页面渲染异常；
 * - 不缓存、不持久化项目业务状态（Rust Core 是唯一权威来源）。
 */

import { invoke, isTauri } from '@tauri-apps/api/core';

import type { IpcErrorPayload } from '../contracts/ipc';
import {
  ARCHIVE_PROJECT_COMMAND,
  CREATE_PROJECT_COMMAND,
  LIST_PROJECTS_COMMAND,
  UPDATE_PROJECT_COMMAND
} from '../contracts/projects';
import type {
  ArchiveProjectInput,
  CreateProjectInput,
  ProjectDto,
  UpdateProjectInput
} from '../contracts/projects';

const COMMAND_FAILED_CODE = 'ipc-command-failed';
const UNKNOWN_IPC_ERROR_CODE = 'ipc-unknown-error';
const CONTRACT_VIOLATION_CODE = 'ipc-contract-violation';
const TAURI_UNAVAILABLE_CODE = 'tauri-runtime-unavailable';

/** 面向 UI 的项目 IPC 错误：稳定错误码 + 中文可读消息。 */
export class ProjectIpcError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'ProjectIpcError';
    this.code = code;
  }
}

/** 查询项目列表（未归档在前，归档项目在后；排序由 Rust Core 决定）。 */
export async function listProjects(): Promise<ProjectDto[]> {
  ensureDesktopRuntime();
  const raw = await invokeProjectCommand(LIST_PROJECTS_COMMAND);
  return parseProjectList(raw);
}

/** 创建项目，返回数据库中的最终记录。 */
export async function createProject(name: string): Promise<ProjectDto> {
  ensureDesktopRuntime();
  const input: CreateProjectInput = { name };
  const raw = await invokeProjectCommand(CREATE_PROJECT_COMMAND, { input });
  return parseProject(raw);
}

/** 编辑项目名称。 */
export async function updateProject(id: string, name: string): Promise<ProjectDto> {
  ensureDesktopRuntime();
  const input: UpdateProjectInput = { id, name };
  const raw = await invokeProjectCommand(UPDATE_PROJECT_COMMAND, { input });
  return parseProject(raw);
}

/** 归档项目（非破坏性标记）。 */
export async function archiveProject(id: string): Promise<ProjectDto> {
  ensureDesktopRuntime();
  const input: ArchiveProjectInput = { id };
  const raw = await invokeProjectCommand(ARCHIVE_PROJECT_COMMAND, { input });
  return parseProject(raw);
}

async function invokeProjectCommand(command: string, args?: Record<string, unknown>): Promise<unknown> {
  try {
    return await invoke<unknown>(command, args);
  } catch (cause: unknown) {
    throw toProjectIpcError(cause);
  }
}

function ensureDesktopRuntime(): void {
  if (!isTauri()) {
    throw new ProjectIpcError(
      TAURI_UNAVAILABLE_CODE,
      '当前页面不在 Tauri 桌面窗口内运行，无法调用本机项目命令。请使用 `npm run tauri dev` 启动应用，或打开打包后的 WorkManager。'
    );
  }
}

/** 校验并解析单个项目 DTO。 */
export function parseProject(raw: unknown): ProjectDto {
  const record = expectRecord(raw, '项目');
  const id = expectNonEmptyString(record.id, '项目.id');
  const name = expectNonEmptyString(record.name, '项目.name');

  return {
    id,
    name,
    isArchived: expectBoolean(record.isArchived, '项目.isArchived'),
    createdAt: expectString(record.createdAt, '项目.createdAt'),
    updatedAt: expectString(record.updatedAt, '项目.updatedAt')
  };
}

/** 校验并解析项目列表。 */
export function parseProjectList(raw: unknown): ProjectDto[] {
  if (!Array.isArray(raw)) {
    throw contractViolation('项目列表', '数组', raw);
  }
  return raw.map((item, index) => parseProjectAt(item, `项目列表[${index}]`));
}

function parseProjectAt(raw: unknown, path: string): ProjectDto {
  const record = expectRecord(raw, path);
  return {
    id: expectNonEmptyString(record.id, `${path}.id`),
    name: expectNonEmptyString(record.name, `${path}.name`),
    isArchived: expectBoolean(record.isArchived, `${path}.isArchived`),
    createdAt: expectString(record.createdAt, `${path}.createdAt`),
    updatedAt: expectString(record.updatedAt, `${path}.updatedAt`)
  };
}

function expectRecord(value: unknown, path: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw contractViolation(path, '对象', value);
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

function expectBoolean(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') {
    throw contractViolation(path, '布尔值', value);
  }
  return value;
}

function contractViolation(path: string, expected: string, actual: unknown): ProjectIpcError {
  return new ProjectIpcError(
    CONTRACT_VIOLATION_CODE,
    `项目 IPC 返回值不符合契约：${path} 应为 ${expected}，实际为 ${describeType(actual)}。请检查前后端版本是否一致。`
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

function toProjectIpcError(cause: unknown): ProjectIpcError {
  if (cause instanceof ProjectIpcError) {
    return cause;
  }

  const payload = readIpcErrorPayload(cause);
  if (payload !== null) {
    return new ProjectIpcError(payload.code, payload.message);
  }

  const serialized = stringifyUnknown(cause);
  return new ProjectIpcError(
    UNKNOWN_IPC_ERROR_CODE,
    serialized === null
      ? '调用项目命令时发生未知错误，且无法读取错误详情。'
      : `调用项目命令时发生未知错误：${serialized}`
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
