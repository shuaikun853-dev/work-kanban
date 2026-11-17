/**
 * `get_database_health` IPC 调用封装。
 *
 * 职责：
 * - 只调用受限命令 `get_database_health`，不提供任意 SQL / 任意文件读写入口；
 * - 对 Tauri invoke 的失败载荷做防御式解析（`{ code, message }`、字符串、
 *   Error 或其他未知形状），统一转换为 `DatabaseHealthError`，保证调用方
 *   不会遇到未处理 rejection；
 * - 对成功返回值做运行时契约校验，避免后端字段漂移导致模板渲染异常。
 *
 * 前端不访问 SQLite，也不持久化任何业务状态。
 */

import { invoke, isTauri } from '@tauri-apps/api/core';

import { DATABASE_HEALTH_COMMAND } from '../contracts/databaseHealth';
import type {
  AppliedMigration,
  DatabaseHealth,
  DatabaseHealthResponse,
  IpcErrorPayload
} from '../contracts/databaseHealth';

/** 失败载荷没有稳定错误码时的兜底码。 */
const COMMAND_FAILED_CODE = 'ipc-command-failed';
/** 无法解析的异常载荷统一错误码。 */
const UNKNOWN_IPC_ERROR_CODE = 'ipc-unknown-error';
/** 成功返回值不符合 IPC 契约时的错误码。 */
const CONTRACT_VIOLATION_CODE = 'ipc-contract-violation';
/** 当前页面不在 Tauri 桌面窗口中运行时的错误码。 */
const TAURI_UNAVAILABLE_CODE = 'tauri-runtime-unavailable';

/** 面向 UI 的数据库健康检查错误：稳定错误码 + 中文可读消息。 */
export class DatabaseHealthError extends Error {
  /** 稳定错误码，直接展示给用户以便定位问题。 */
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'DatabaseHealthError';
    this.code = code;
  }
}

/**
 * 调用 `get_database_health` 并返回通过契约校验的健康检查响应。
 *
 * 该函数只会以 `DatabaseHealthError` reject，且调用方（App.svelte）会在
 * 内部捕获，因此不会产生未处理的 Promise rejection。
 */
export async function fetchDatabaseHealth(): Promise<DatabaseHealthResponse> {
  if (!isTauri()) {
    throw new DatabaseHealthError(
      TAURI_UNAVAILABLE_CODE,
      '当前页面不在 Tauri 桌面窗口内运行，无法调用本机数据库命令。请使用 `npm run tauri dev` 启动应用，或打开打包后的 WorkManager。'
    );
  }

  let raw: unknown;
  try {
    raw = await invoke<unknown>(DATABASE_HEALTH_COMMAND);
  } catch (cause: unknown) {
    throw toDatabaseHealthError(cause);
  }

  return parseDatabaseHealthResponse(raw);
}

/**
 * 校验并解析 `get_database_health` 成功返回值。
 *
 * 严格匹配 Rust DTO 的字段与类型；任何不匹配都以 `DatabaseHealthError`
 * （错误码 `ipc-contract-violation`）抛出，而不是让错误延迟到渲染阶段。
 */
export function parseDatabaseHealthResponse(raw: unknown): DatabaseHealthResponse {
  const root = expectRecord(raw, '返回值');

  return {
    appName: expectString(root.appName, 'appName'),
    appVersion: expectString(root.appVersion, 'appVersion'),
    runtimeMode: expectString(root.runtimeMode, 'runtimeMode'),
    dataRoot: expectString(root.dataRoot, 'dataRoot'),
    databasePath: expectString(root.databasePath, 'databasePath'),
    webview2DataDir: expectString(root.webview2DataDir, 'webview2DataDir'),
    database: parseDatabaseHealth(root.database)
  };
}

function parseDatabaseHealth(raw: unknown): DatabaseHealth {
  const record = expectRecord(raw, 'database');

  return {
    status: expectString(record.status, 'database.status'),
    schemaVersion: expectNumber(record.schemaVersion, 'database.schemaVersion'),
    latestSchemaVersion: expectNumber(record.latestSchemaVersion, 'database.latestSchemaVersion'),
    databasePath: expectString(record.databasePath, 'database.databasePath'),
    databaseFileSizeBytes: expectNumber(
      record.databaseFileSizeBytes,
      'database.databaseFileSizeBytes'
    ),
    integrityCheck: expectString(record.integrityCheck, 'database.integrityCheck'),
    foreignKeyViolations: expectNumber(
      record.foreignKeyViolations,
      'database.foreignKeyViolations'
    ),
    journalMode: expectString(record.journalMode, 'database.journalMode'),
    synchronous: expectNumber(record.synchronous, 'database.synchronous'),
    foreignKeys: expectBoolean(record.foreignKeys, 'database.foreignKeys'),
    busyTimeoutMs: expectNumber(record.busyTimeoutMs, 'database.busyTimeoutMs'),
    tempStore: expectNumber(record.tempStore, 'database.tempStore'),
    appliedMigrations: expectMigrationList(
      record.appliedMigrations,
      'database.appliedMigrations'
    ),
    checkedAt: expectString(record.checkedAt, 'database.checkedAt')
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

function expectNumber(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw contractViolation(path, '有限数字', value);
  }
  return value;
}

function expectBoolean(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') {
    throw contractViolation(path, '布尔值', value);
  }
  return value;
}

function expectMigrationList(value: unknown, path: string): readonly AppliedMigration[] {
  if (!Array.isArray(value)) {
    throw contractViolation(path, '数组', value);
  }

  return value.map((item, index) => {
    const itemPath = `${path}[${index}]`;
    const record = expectRecord(item, itemPath);

    return {
      version: expectNumber(record.version, `${itemPath}.version`),
      name: expectString(record.name, `${itemPath}.name`),
      appliedAt: expectString(record.appliedAt, `${itemPath}.appliedAt`)
    };
  });
}

function contractViolation(path: string, expected: string, actual: unknown): DatabaseHealthError {
  return new DatabaseHealthError(
    CONTRACT_VIOLATION_CODE,
    `IPC 返回值不符合契约：${path} 应为 ${expected}，实际为 ${describeType(actual)}。请检查前后端版本是否一致。`
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

/**
 * 把任意 invoke 失败载荷转换为 `DatabaseHealthError`。
 *
 * Tauri 在命令返回 Err 时通常 reject `{ code, message }`；命令缺失等宿主层
 * 错误可能是字符串或 Error。所有形状都必须安全处理，不允许异常逃逸。
 */
function toDatabaseHealthError(cause: unknown): DatabaseHealthError {
  if (cause instanceof DatabaseHealthError) {
    return cause;
  }

  const payload = readIpcErrorPayload(cause);
  if (payload !== null) {
    return new DatabaseHealthError(payload.code, payload.message);
  }

  const serialized = stringifyUnknown(cause);
  return new DatabaseHealthError(
    UNKNOWN_IPC_ERROR_CODE,
    serialized === null
      ? '调用数据库健康检查命令时发生未知错误，且无法读取错误详情。'
      : `调用数据库健康检查命令时发生未知错误：${serialized}`
  );
}

function readIpcErrorPayload(cause: unknown): IpcErrorPayload | null {
  if (typeof cause === 'string') {
    const text = cause.trim();
    if (text.length === 0) {
      return null;
    }

    // 少数场景下字符串载荷本身可能是 JSON 序列化后的错误对象。
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
