/**
 * T1-02 项目 IPC 契约（前端唯一项目数据契约来源）。
 *
 * 字段必须与 Rust 后端 serde camelCase 输出逐字段一致：
 * - 命令：`list_projects` / `create_project` / `update_project` / `archive_project`
 * - 成功：`Project`（crates/workmanager-core/src/projects/model.rs）
 * - 失败：`IpcErrorPayload`（src-tauri/src/commands/mod.rs 的 CommandError）
 *
 * 项目 ID 必须使用后端返回的稳定 UUID；禁止用数组下标作为业务身份。
 * 前端不持久化项目状态，不提供任意 SQL 或任意文件访问接口。
 */

export const LIST_PROJECTS_COMMAND = 'list_projects' as const;
export const CREATE_PROJECT_COMMAND = 'create_project' as const;
export const UPDATE_PROJECT_COMMAND = 'update_project' as const;
export const ARCHIVE_PROJECT_COMMAND = 'archive_project' as const;

/** 项目 DTO（对应 Rust `Project`，serde camelCase）。 */
export interface ProjectDto {
  /** Rust Core 生成的稳定 UUID。 */
  readonly id: string;
  readonly name: string;
  readonly isArchived: boolean;
  /** UTC RFC3339 时间字符串。 */
  readonly createdAt: string;
  /** UTC RFC3339 时间字符串。 */
  readonly updatedAt: string;
}

/** `create_project` 请求体（对应 Rust `CreateProjectRequest`）。 */
export interface CreateProjectInput {
  readonly name: string;
}

/** `update_project` 请求体（对应 Rust `UpdateProjectRequest`）。 */
export interface UpdateProjectInput {
  readonly id: string;
  readonly name: string;
}

/** `archive_project` 请求体（对应 Rust `ArchiveProjectRequest`）。 */
export interface ArchiveProjectInput {
  readonly id: string;
}
