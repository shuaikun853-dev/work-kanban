#!/usr/bin/env python3
"""T1-04 UAT 数据库原子性故障注入控制器（仅用于 D 盘隔离测试目录）。

在 UAT 数据库（独立便携目录，绝不是正式数据目录）中安装/移除一个真实 SQLite
TRIGGER，用于验证“第二条工作副本插入失败时整批回滚”。trigger 只在测试数据库
存在，不进入产品代码、不提供生产故障开关。

用法：
  python -X utf8 control-t1-04-fault.py install <databasePath> <projectId>
  python -X utf8 control-t1-04-fault.py remove  <databasePath>
  python -X utf8 control-t1-04-fault.py status  <databasePath>

安全边界：
- 只允许 D:\\WorkManager-test-data 之下的数据库路径；
- 拒绝正式运行目录 D:\\WorkManager；
- install 需要非空 projectId；remove/status 不需要。

stdout 只输出 ASCII 状态行；失败退出码 3（安全边界/参数）或 2（数据库操作）。
"""

import os
import sqlite3
import sys

TRIGGER_NAME = "t1_04_fault_second_copy"
TEST_ROOT = "d:\\workmanager-test-data"
FORMAL_ROOT = "d:\\workmanager"


def comparable(path):
    return os.path.abspath(path).replace("/", "\\").rstrip("\\").lower()


def assert_safe_path(database_path):
    path = comparable(database_path)
    if not path.startswith(TEST_ROOT + "\\"):
        raise SystemExit("SAFETY_REFUSED: database path is not inside D:\\WorkManager-test-data")
    if path == FORMAL_ROOT or path.startswith(FORMAL_ROOT + "\\"):
        raise SystemExit("SAFETY_REFUSED: refusing formal release directory")
    if not os.path.isfile(database_path):
        raise SystemExit("SAFETY_REFUSED: database file does not exist")


def open_database(database_path):
    connection = sqlite3.connect(database_path, timeout=10.0)
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 5000")
    return connection


def install(database_path, project_id):
    connection = open_database(database_path)
    try:
        # SQLite 不允许在 CREATE TRIGGER 的 DDL 中使用绑定参数，因此把已校验的
        # UUID 项目 ID 转义单引号后嵌入 trigger 定义（只用于隔离 UAT 测试数据库）。
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


def remove(database_path):
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


def status(database_path):
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
    assert_safe_path(database_path)
    try:
        if action == "install":
            if len(sys.argv) < 4 or not sys.argv[3].strip():
                print("usage: install requires a non-empty projectId", file=sys.stderr)
                return 3
            install(database_path, sys.argv[3].strip())
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
