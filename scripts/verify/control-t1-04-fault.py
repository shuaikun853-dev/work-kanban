#!/usr/bin/env python3
"""T1-04 UAT 数据库原子性故障注入控制器（仅用于 D 盘隔离测试目录）。

在 UAT 数据库（独立便携目录，绝不是正式数据目录）中安装/移除一个真实 SQLite
TRIGGER，用于验证“第二条工作副本插入失败时整批回滚”。trigger 只在测试数据库
存在，不进入产品代码、不提供生产故障开关。

用法：
  python -X utf8 control-t1-04-fault.py install <databasePath> <projectId>
  python -X utf8 control-t1-04-fault.py remove  <databasePath>
  python -X utf8 control-t1-04-fault.py status  <databasePath>

安全边界（T104-01）：
- 不自行实现字符串前缀判断；所有路径先经 t1_04_path_guard 调用 PowerShell
  原生守卫，复用 T1-03 的 Windows 句柄/信任锚/重解析点/最终路径/卷身份校验；
- 数据库必须位于 D:\\WorkManager-test-data\\<UAT任务目录>\\ 之下，不能直接位于测试根；
- 拒绝正式运行目录 D:\\WorkManager（字面路径 + 真实最终路径双重校验）；
- 数据库文件自身及其父目录、全部祖先不得是未获批准的重解析点；
- 安全校验失败必须在 sqlite3.connect() 之前终止；不会创建数据库文件；
- install 需要规范 UUID projectId；remove/status 不需要。

stdout 只输出 ASCII 状态行；安全边界/参数失败退出码 3，数据库操作失败退出码 2。
"""

import sqlite3
import sys
import uuid
from pathlib import Path
from urllib.parse import quote

from t1_04_path_guard import PathGuardError, assert_guarded_path

TRIGGER_NAME = "t1_04_fault_second_copy"


def database_uri(database_path: str) -> str:
    """构造只打开已有数据库（mode=rw）的 SQLite URI，避免缺失文件被新建。"""
    absolute = Path(database_path).absolute().as_posix()
    return "file:" + quote(absolute, safe="/:") + "?mode=rw"


def assert_safe_path(database_path: str) -> dict:
    if not database_path:
        raise PathGuardError("数据库路径为空。已按 fail-closed 停止。")
    result = assert_guarded_path("database", database_path)
    if not Path(database_path).is_file():
        raise PathGuardError("数据库文件不存在。已按 fail-closed 停止，不会创建新数据库。")
    return result


def open_database(database_path: str) -> sqlite3.Connection:
    # 调用方必须先完成 assert_safe_path；本函数在任何情况下都不创建新数据库。
    connection = sqlite3.connect(database_uri(database_path), uri=True, timeout=10.0)
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 5000")
    return connection


def normalize_project_id(project_id: str) -> str:
    try:
        parsed = uuid.UUID(project_id)
    except (ValueError, AttributeError) as error:
        raise ValueError("projectId must be a canonical UUID") from error
    canonical = str(parsed)
    if canonical != project_id.lower() or str(parsed) != project_id:
        raise ValueError("projectId must be a canonical lower-case UUID")
    return canonical


def install(database_path: str, project_id: str) -> None:
    connection = open_database(database_path)
    try:
        # SQLite 不允许在 CREATE TRIGGER 的 DDL 中使用绑定参数。projectId 已严格校验为
        # 规范 UUID，仍然做单引号转义作为纵深防御；只用于隔离 UAT 测试数据库。
        escaped_project_id = project_id.replace("'", "''")
        connection.execute(f"DROP TRIGGER IF EXISTS {TRIGGER_NAME}")
        connection.execute(
            f"CREATE TRIGGER {TRIGGER_NAME} BEFORE INSERT ON work_items "
            f"WHEN NEW.project_id = '{escaped_project_id}' "
            "BEGIN SELECT RAISE(ABORT, 'T1-04 injected second-copy insert failure'); END"
        )
        connection.commit()
        count = connection.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?",
            (TRIGGER_NAME,),
        ).fetchone()[0]
    finally:
        connection.close()
    print(f"FAULT_TRIGGER_INSTALLED={count}")


def remove(database_path: str) -> None:
    connection = open_database(database_path)
    try:
        connection.execute(f"DROP TRIGGER IF EXISTS {TRIGGER_NAME}")
        connection.commit()
        count = connection.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?",
            (TRIGGER_NAME,),
        ).fetchone()[0]
    finally:
        connection.close()
    print(f"FAULT_TRIGGER_REMAINING={count}")


def status(database_path: str) -> None:
    connection = open_database(database_path)
    try:
        count = connection.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?",
            (TRIGGER_NAME,),
        ).fetchone()[0]
    finally:
        connection.close()
    print(f"FAULT_TRIGGER_PRESENT={count}")


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: control-t1-04-fault.py <install|remove|status> <databasePath> [projectId]",
            file=sys.stderr,
        )
        return 3
    action = sys.argv[1]
    database_path = sys.argv[2]

    try:
        assert_safe_path(database_path)
    except PathGuardError as error:
        print(f"SAFETY_REFUSED: {error}", file=sys.stderr)
        return 3

    try:
        if action == "install":
            if len(sys.argv) < 4 or not sys.argv[3].strip():
                print("usage: install requires a non-empty projectId", file=sys.stderr)
                return 3
            try:
                project_id = normalize_project_id(sys.argv[3].strip())
            except ValueError as error:
                print(f"SAFETY_REFUSED: {error}", file=sys.stderr)
                return 3
            install(database_path, project_id)
        elif action == "remove":
            remove(database_path)
        elif action == "status":
            status(database_path)
        else:
            print(f"unknown action: {action}", file=sys.stderr)
            return 3
    except sqlite3.Error as error:
        print(f"DATABASE_ERROR={error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
