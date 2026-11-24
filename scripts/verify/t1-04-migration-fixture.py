#!/usr/bin/env python3
"""T1-04 Release migration failure fixture / read-only probe（T104-04，第六轮 R2-02）。

用法：
  python -X utf8 t1-04-migration-fixture.py setup <repoRoot> <databasePath>
  python -X utf8 t1-04-migration-fixture.py probe <databasePath>

第六轮 R2-02 修复：不再直接 `db.parent.mkdir()` / `sqlite3.connect(db)` / 字符串
路径前缀判断。所有数据库路径在创建文件、写 migration、连接 SQLite 之前，必须通过
`t1_04_path_guard` 调用 T1-04 PowerShell 原生路径守卫（复用 T1-03 Windows 原生
句柄、测试根目录信任锚、重解析点拒绝、卷序列号 + 文件 ID + 真实最终路径校验）。

setup 执行顺序（fail-closed）：
1. `database-target` 原生守卫：UAT 根目录身份、父目录链、卷身份、最终路径、
   目标不存在且不是重解析点、无孤立 sidecar；
2. 独占创建空数据库文件（`xb`，绝不覆盖既有文件）；
3. `database` 原生守卫复验实际文件身份；
4. 通过后才 `sqlite3.connect()`，执行真实 0001/0002/0003 SQL，写入虚构历史项目与
   工作事项，设置 user_version=3，然后从真实 0004 SQL 提取索引名并创建同名冲突索引；
5. 关闭连接后再次复验数据库文件身份（文件 ID / 卷序列号 / 最终路径不变）。

probe 先通过 `database` 原生守卫（数据库必须位于可信 UAT 中），通过后才以
`mode=ro` 只读连接；守卫失败时不连接、不降级尝试其他路径，退出码 3。

本脚本只操作隔离 UAT 数据库；不打开/修改正式运行目录。
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote

from t1_04_path_guard import PathGuardError, assert_guarded_path

MIGRATION_TABLE_SQL = [
    (1, "0001_initial_foundation.sql"),
    (2, "0002_projects.sql"),
    (3, "0003_work_items.sql"),
]

IDENTITY_FIELDS = ("volumeSerialNumber", "fileIdHex", "finalPath")


def read_only_uri(database_path: str) -> str:
    absolute = Path(database_path).absolute().as_posix()
    return "file:" + quote(absolute, safe="/:") + "?mode=ro"


def _assert_identity_record(result: dict, context: str) -> dict:
    identity = result.get("identity")
    if not isinstance(identity, dict):
        raise PathGuardError(
            f"{context}：原生守卫成功但未返回文件身份记录。已按 fail-closed 停止。"
        )
    for field in IDENTITY_FIELDS:
        if not str(identity.get(field) or "").strip():
            raise PathGuardError(
                f"{context}：原生守卫返回的文件身份缺少 {field}。已按 fail-closed 停止。"
            )
    return identity


def _assert_identical_identity(before: dict, after: dict, context: str) -> None:
    for field in IDENTITY_FIELDS:
        if str(before.get(field)) != str(after.get(field)):
            raise PathGuardError(
                f"{context}：数据库文件身份在写入前后发生变化（{field}）。"
                "已按 fail-closed 停止。"
            )


def _create_empty_database_file(database_path: Path) -> None:
    """独占创建空数据库文件；绝不覆盖既有文件。"""
    try:
        with open(database_path, "xb"):
            pass
    except FileExistsError as error:
        raise PathGuardError(
            "数据库创建目标已存在，拒绝复用/覆盖旧数据库。已按 fail-closed 停止。"
        ) from error
    except OSError as error:
        raise PathGuardError(
            f"无法在已校验路径创建数据库文件：{error}。已按 fail-closed 停止。"
        ) from error


def setup(repo_root: str, database_path: str) -> int:
    repo = Path(repo_root)
    db = Path(database_path)

    # 1. 原生守卫：创建目标（父目录身份 / 卷身份 / 最终路径 / 非重解析点 / 不存在）。
    target = assert_guarded_path("database-target", str(db))
    if target.get("targetExists") is not False:
        raise PathGuardError(
            "数据库创建目标状态无法确认（targetExists 不为 false）。已按 fail-closed 停止。"
        )

    # 2. 独占创建空文件。
    _create_empty_database_file(db)

    # 3. 创建后复验实际文件身份，通过后才允许连接 SQLite。
    created_identity = _assert_identity_record(
        assert_guarded_path("database", str(db)), "数据库创建后身份复验失败"
    )
    if not db.is_file():
        raise PathGuardError("数据库文件创建后不存在。已按 fail-closed 停止。")

    index_name = ""
    conn = sqlite3.connect(str(db))
    try:
        for version, name in MIGRATION_TABLE_SQL:
            sql = (repo / "crates" / "workmanager-core" / "migrations" / name).read_text(
                encoding="utf-8"
            )
            conn.executescript(sql)
            conn.execute(
                "INSERT INTO schema_migrations(version,name,applied_at) VALUES(?,?,?)",
                (version, name[:-4], "2026-11-24T00:00:00Z"),
            )
        conn.execute("PRAGMA user_version=3")
        conn.execute(
            "INSERT INTO projects VALUES("
            "'11111111-1111-4111-8111-111111111111','虚构迁移项目',0,'t','t')"
        )
        conn.execute(
            "INSERT INTO work_items(id,project_id,title,lifecycle_status,created_at,updated_at) "
            "VALUES('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',"
            "'11111111-1111-4111-8111-111111111111','虚构迁移工作','pending','t','t')"
        )
        sql4 = (
            repo
            / "crates"
            / "workmanager-core"
            / "migrations"
            / "0004_work_item_creation_groups.sql"
        ).read_text(encoding="utf-8")
        match = re.search(r"CREATE\s+INDEX\s+([^\s]+)", sql4, re.I)
        if match is None:
            raise RuntimeError("真实 0004 migration 缺少 CREATE INDEX")
        index_name = match.group(1)
        conn.execute(f'CREATE INDEX "{index_name}" ON projects(name)')
        conn.commit()
    finally:
        conn.close()

    # 5. 关闭连接后再次复验文件身份（写入前后必须是同一普通文件）。
    final_identity = _assert_identity_record(
        assert_guarded_path("database", str(db)), "数据库写入后身份复验失败"
    )
    _assert_identical_identity(created_identity, final_identity, "数据库写入后身份复验失败")

    print("SETUP_SCHEMA_VERSION=3")
    print("SETUP_CONFLICT_INDEX=" + index_name)
    print("SETUP_DATABASE_IDENTITY_VERIFIED=True")
    return 0


def probe(database_path: str) -> int:
    db = Path(database_path)

    # 1. 连接之前调用原生守卫；失败时不得尝试其他路径或降级打开。
    identity = _assert_identity_record(
        assert_guarded_path("database", str(db)), "只读探针路径守卫失败"
    )
    if not db.is_file():
        raise PathGuardError("数据库文件不存在。已按 fail-closed 停止，不会创建新数据库。")

    # 2. 只读连接（唯一一次连接尝试）。
    conn = sqlite3.connect(read_only_uri(str(db)), uri=True, timeout=5.0)
    try:
        report = {
            "user_version": conn.execute("PRAGMA user_version").fetchone()[0],
            "projects": conn.execute("SELECT COUNT(*) FROM projects").fetchone()[0],
            "work_items": conn.execute("SELECT COUNT(*) FROM work_items").fetchone()[0],
            "schema_migrations": conn.execute(
                "SELECT COUNT(*) FROM schema_migrations"
            ).fetchone()[0],
            "version4_rows": conn.execute(
                "SELECT COUNT(*) FROM schema_migrations WHERE version=4"
            ).fetchone()[0],
            "group_table": conn.execute(
                "SELECT COUNT(*) FROM sqlite_master "
                "WHERE type='table' AND name='work_item_creation_groups'"
            ).fetchone()[0],
            "member_table": conn.execute(
                "SELECT COUNT(*) FROM sqlite_master "
                "WHERE type='table' AND name='work_item_creation_group_members'"
            ).fetchone()[0],
            "integrity_check": conn.execute("PRAGMA integrity_check").fetchone()[0],
        }
    finally:
        conn.close()

    # 3. 探针结束后复验数据库文件身份（描述为只读证据：文件 ID 不得变化）。
    final_identity = _assert_identity_record(
        assert_guarded_path("database", str(db)), "只读探针后身份复验失败"
    )
    _assert_identical_identity(identity, final_identity, "只读探针后身份复验失败")

    print(json.dumps(report, ensure_ascii=False))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        if sys.argv[1] == "setup" and len(sys.argv) == 4:
            return setup(sys.argv[2], sys.argv[3])
        if sys.argv[1] == "probe" and len(sys.argv) == 3:
            return probe(sys.argv[2])
    except PathGuardError as error:
        print(f"SAFETY_REFUSED: {error}", file=sys.stderr)
        return 3
    except (sqlite3.Error, OSError, RuntimeError, ValueError) as error:
        print(f"DATABASE_ERROR={type(error).__name__}: {error}", file=sys.stderr)
        return 2
    print("invalid arguments", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
