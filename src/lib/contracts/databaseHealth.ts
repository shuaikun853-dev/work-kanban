/**
 * T1-01 数据库健康检查 IPC 契约（前端唯一数据契约来源）。
 *
 * 字段必须与 Rust 后端 serde camelCase 输出逐字段一致：
 * - 命令：`get_database_health`
 * - 成功：`DatabaseHealthResponse`（src-tauri/src/app_state.rs）
 * - 失败：`IpcErrorPayload`（src-tauri/src/commands/mod.rs 的 CommandError）
 *
 * 本任务不提供任意 SQL、任意文件读写或任意命令执行接口；
 * 契约变更必须同时修改 Rust DTO、本文件与 docs/architecture/TECHNICAL_DESIGN.md。
 */

export type { IpcErrorPayload } from './ipc';

/** 生产代码中唯一允许调用的数据库相关命令名。 */
export const DATABASE_HEALTH_COMMAND = 'get_database_health' as const;

/**
 * 运行模式字面量，对应 Rust `RuntimeMode::as_str()`：
 * - `release`：正式便携模式，数据目录跟随 EXE 所在目录；
 * - `debug-test`：调试/测试隔离模式，数据目录来自隔离测试根目录。
 */
export type RuntimeMode = 'release' | 'debug-test';

/** 已应用的 migration 审计记录（对应 Rust `AppliedMigration`）。 */
export interface AppliedMigration {
  readonly version: number;
  readonly name: string;
  /** UTC RFC3339 时间字符串。 */
  readonly appliedAt: string;
}

/** SQLite 数据库健康快照（对应 Rust `DatabaseHealth`）。 */
export interface DatabaseHealth {
  /** 成功时固定为 `"ok"`；失败不会返回健康快照，而是走 IPC 错误。 */
  readonly status: string;
  readonly schemaVersion: number;
  readonly latestSchemaVersion: number;
  readonly databasePath: string;
  readonly databaseFileSizeBytes: number;
  /** `PRAGMA integrity_check` 结果，通过时为 `"ok"`。 */
  readonly integrityCheck: string;
  readonly foreignKeyViolations: number;
  /** 期望为 `"wal"`。 */
  readonly journalMode: string;
  /** SQLite `PRAGMA synchronous` 数值（期望 2）。 */
  readonly synchronous: number;
  readonly foreignKeys: boolean;
  readonly busyTimeoutMs: number;
  /** SQLite `PRAGMA temp_store` 数值（期望 2）。 */
  readonly tempStore: number;
  readonly appliedMigrations: readonly AppliedMigration[];
  /** 检查时间（UTC RFC3339）。 */
  readonly checkedAt: string;
}

/** `get_database_health` 成功响应（对应 Rust `DatabaseHealthResponse`）。 */
export interface DatabaseHealthResponse {
  /** 应用名，固定 `"WorkManager"`。 */
  readonly appName: string;
  /** 应用版本，例如 `"0.1.0"`，用于页头展示。 */
  readonly appVersion: string;
  /** `"release"` 或 `"debug-test"`（保留为 string 以兼容未来新增模式）。 */
  readonly runtimeMode: string;
  readonly dataRoot: string;
  readonly databasePath: string;
  readonly webview2DataDir: string;
  readonly database: DatabaseHealth;
}
