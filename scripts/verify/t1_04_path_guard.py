#!/usr/bin/env python3
"""T1-04 UAT 路径安全守卫的 Python 适配层（T104-01）。

所有数据库/证据路径在调用 sqlite3.connect 或写文件之前，必须通过
scripts/verify/guard-t1-04-path.ps1。该 PowerShell 守卫直接复用 T1-03
已验证的 Windows 原生句柄路径校验与测试根目录信任锚，而不是在 Python
里重新实现字符串前缀判断。

任何守卫进程启动失败、超时、输出无法解析、退出码非 0 或缺少 ok=true，
都按 fail-closed 抛出 PathGuardError；调用方必须先终止，不得继续连接数据库
或写文件。
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

GUARD_SCRIPT = Path(__file__).with_name("guard-t1-04-path.ps1")
GUARD_TIMEOUT_SECONDS = 90
GUARD_FAILED_EXIT = 3
_CREATE_NO_WINDOW = 0x08000000 if hasattr(subprocess, "CREATE_NO_WINDOW") else 0


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


def assert_guarded_path(
    kind: str,
    path: str | Path,
    *,
    database_path: str | Path | None = None,
    evidence_directory: str | Path | None = None,
) -> dict:
    """执行原生路径守卫；失败时抛出 PathGuardError，绝不返回“可能安全”。"""
    if kind not in {"database", "evidence-dir", "evidence-file"}:
        raise PathGuardError(f"未知路径守卫类型：{kind}")

    if not GUARD_SCRIPT.is_file():
        raise PathGuardError(f"路径守卫脚本不存在：{GUARD_SCRIPT.name}。已按 fail-closed 停止。")

    command = [
        _powershell_executable(),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(GUARD_SCRIPT),
        "-Kind",
        kind,
        "-Path",
        str(path),
    ]
    if database_path is not None:
        command.extend(["-DatabasePath", str(database_path)])
    if evidence_directory is not None:
        command.extend(["-EvidenceDirectory", str(evidence_directory)])

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
        message = str(result.get("message") or stderr or "路径守卫拒绝该路径")
        raise PathGuardError(message)
    return result
