#!/usr/bin/env python3
"""T1-04 UAT 路径安全守卫的 Python 适配层（T104-01；第六轮修复）。

所有数据库/证据/清理路径在调用 sqlite3.connect、创建目录、写文件或删除之前，
必须通过 `guard-t1-04-path.ps1` / `guard-t1-04-cleanup.ps1`。该 PowerShell 守卫
直接复用 T1-03 已验证的 Windows 原生句柄路径校验与测试根目录信任锚，而不是在
Python 里重新实现字符串前缀判断。

任何守卫进程启动失败、超时、输出无法解析、退出码非 0 或缺少 ok=true，都按
fail-closed 抛出 PathGuardError；调用方必须先终止，不得继续连接数据库、写文件
或执行删除。

第六轮新增守卫能力（详见 `guard-t1-04-path.ps1` 文件头）：
- test-root：测试根目录信任锚（自身 + 全部祖先 + 重解析点 + 卷身份 + 文件 ID）；
- uat-root / uat-root-target：已存在 UAT 目录身份 / 尚不存在目录的安全创建目标；
- database-target / evidence-dir-target：尚不存在的数据库/证据目录创建目标；
- evidence-file（-UatRoot 形式）：无数据库场景下的证据边界；
- formal-root-status：正式目录只读身份快照；
- cleanup：复用 T1-03 fail-closed 安全清理，身份变化/重解析点/守卫失败拒绝删除。
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

GUARD_SCRIPT = Path(__file__).with_name("guard-t1-04-path.ps1")
CLEANUP_SCRIPT = Path(__file__).with_name("guard-t1-04-cleanup.ps1")
GUARD_TIMEOUT_SECONDS = 90
GUARD_FAILED_EXIT = 3
_CREATE_NO_WINDOW = 0x08000000 if hasattr(subprocess, "CREATE_NO_WINDOW") else 0

SUPPORTED_KINDS = frozenset(
    {
        "test-root",
        "uat-root",
        "uat-root-target",
        "database",
        "database-target",
        "evidence-dir",
        "evidence-dir-target",
        "evidence-file",
        "formal-root-status",
    }
)


class PathGuardError(RuntimeError):
    """路径守卫拒绝或无法完成校验；调用方必须 fail-closed。"""


def _powershell_executable() -> str:
    for name in ("pwsh", "powershell"):
        executable = shutil.which(name)
        if executable:
            return executable
    raise PathGuardError("找不到 PowerShell，无法执行 Windows 原生路径安全校验。已按 fail-closed 停止。")


def _parse_guard_output(stdout: str) -> dict:
    for line in reversed([line.strip() for line in stdout.splitlines() if line.strip()]):
        if not line.startswith("{"):
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    raise PathGuardError("路径守卫未返回可解析的 JSON，无法确认路径身份。已按 fail-closed 停止。")


def _run_guard_script(
    script: Path,
    arguments: list[str],
    *,
    missing_message: str,
) -> dict:
    if not script.is_file():
        raise PathGuardError(f"{missing_message}：{script.name}。已按 fail-closed 停止。")

    command = [
        _powershell_executable(),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
    ]
    command.extend(arguments)

    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=GUARD_TIMEOUT_SECONDS,
            creationflags=_CREATE_NO_WINDOW,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise PathGuardError(
            f"无法执行 Windows 原生路径安全校验：{error}。已按 fail-closed 停止。"
        ) from error

    stdout = completed.stdout or ""
    stderr = (completed.stderr or "").strip()
    try:
        result = _parse_guard_output(stdout)
    except PathGuardError:
        if completed.returncode != 0:
            detail = stderr[:600] if stderr else "无 stderr 输出"
            raise PathGuardError(
                f"路径守卫失败（exit={completed.returncode}）且未返回结构化结果：{detail}"
            )
        raise

    if completed.returncode != 0 or result.get("ok") is not True:
        message = str(
            result.get("message")
            or result.get("stopReason")
            or stderr
            or "路径守卫拒绝该路径"
        )
        stop_code = str(result.get("stopCode") or "").strip()
        if stop_code:
            message = f"{stop_code}: {message}"
        raise PathGuardError(message)
    return result


def assert_guarded_path(
    kind: str,
    path: str | Path,
    *,
    database_path: str | Path | None = None,
    evidence_directory: str | Path | None = None,
    uat_root: str | Path | None = None,
) -> dict:
    """执行原生路径守卫；失败时抛出 PathGuardError，绝不返回“可能安全”。"""
    if kind not in SUPPORTED_KINDS:
        raise PathGuardError(f"未知路径守卫类型：{kind}")

    arguments = ["-Kind", kind]
    if kind != "formal-root-status":
        if path is None or not str(path).strip():
            raise PathGuardError("路径守卫缺少 -Path 参数。已按 fail-closed 停止。")
        arguments.extend(["-Path", str(path)])
    if database_path is not None:
        arguments.extend(["-DatabasePath", str(database_path)])
    if evidence_directory is not None:
        arguments.extend(["-EvidenceDirectory", str(evidence_directory)])
    if uat_root is not None:
        arguments.extend(["-UatRoot", str(uat_root)])

    return _run_guard_script(
        GUARD_SCRIPT,
        arguments,
        missing_message="路径守卫脚本不存在",
    )


def assert_guarded_cleanup(
    path: str | Path,
    identity: dict,
    *,
    tracked_links: tuple[str, ...] | list[str] = (),
    test_root: str | Path | None = None,
) -> dict:
    """执行 fail-closed 安全清理。

    必须提供创建时记录并经原生守卫确认的目录身份（卷序列号 + 文件 ID）；
    清理守卫会在删除前重新获取当前身份并比对，身份变化 / 重解析点 / 守卫失败
    一律拒绝删除并抛出 PathGuardError，调用方必须保留现场、不得强制删除。
    """
    if not isinstance(identity, dict):
        raise PathGuardError("清理守卫缺少可信目录身份记录。已按 fail-closed 停止。")
    volume_serial = str(identity.get("volumeSerialNumber") or "").strip()
    file_id = str(identity.get("fileIdHex") or "").strip()
    if not volume_serial or not file_id:
        raise PathGuardError("清理守卫缺少可信卷序列号/文件 ID。已按 fail-closed 停止。")

    arguments = [
        "-Path",
        str(path),
        "-ExpectedVolumeSerial",
        volume_serial,
        "-ExpectedFileId",
        file_id,
    ]
    expected_final_path = str(identity.get("finalPath") or "").strip()
    if expected_final_path:
        arguments.extend(["-ExpectedFinalPath", expected_final_path])
    for link in tracked_links or ():
        if link is None or not str(link).strip():
            continue
        arguments.extend(["-TrackedLink", str(link)])
    if test_root is not None:
        arguments.extend(["-TestRootOverride", str(test_root)])

    return _run_guard_script(
        CLEANUP_SCRIPT,
        arguments,
        missing_message="fail-closed 清理守卫脚本不存在",
    )


def get_formal_root_status() -> dict:
    """只读获取正式应用目录身份快照；读取失败返回可用性标记，不抛异常。"""
    try:
        return _run_guard_script(
            GUARD_SCRIPT,
            ["-Kind", "formal-root-status"],
            missing_message="路径守卫脚本不存在",
        )
    except PathGuardError as error:
        return {"ok": False, "available": False, "error": str(error)}
