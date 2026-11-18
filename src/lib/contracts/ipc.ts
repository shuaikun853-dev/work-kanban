/**
 * 通用 IPC 错误载荷契约（Rust `CommandError` 的 serde camelCase 输出）。
 *
 * 所有业务命令失败时统一返回 `{ code, message }`：
 * - `code`：稳定错误码，前端据此展示和分类；
 * - `message`：面向用户的中文说明，不包含 SQL、内部路径或用户工作内容。
 */

export interface IpcErrorPayload {
  readonly code: string;
  readonly message: string;
}
