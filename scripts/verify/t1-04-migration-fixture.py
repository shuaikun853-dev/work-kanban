#!/usr/bin/env python3
"""T1-04 Release migration failure fixture / read-only probe (T104-04).

用法：
  python -X utf8 t1-04-migration-fixture.py setup <repoRoot> <databasePath>
  python -X utf8 t1-04-migration-fixture.py probe <databasePath>

setup 只操作隔离 UAT 数据库：执行真实 0001/0002/0003 SQL，写入虚构历史项目与
工作事项，设置 user_version=3，然后从真实 0004 SQL 提取索引名并创建同名冲突索引。
probe 以只读方式返回迁移失败后的关键不变量（不含标题/项目名称/绝对路径）。
"""

from __future__ import annotations

import json
import re
import sqlite3
import sys
from pathlib import Path


def setup(repo_root: str, database_path: str) -> int:
    repo = Path(repo_root)
    db = Path(database_path)
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db)
    try:
        for version, name in [
            (1, "0001_initial_foundation.sql"),
            (2, "0002_projects.sql"),
            (3, "0003_work_items.sql"),
        ]:
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
    print("SETUP_SCHEMA_VERSION=3")
    print("SETUP_CONFLICT_INDEX=" + index_name)


def probe(database_path: str) -> int:
    db = Path(database_path)
    conn = sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True)
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
    print(json.dumps(report, ensure_ascii=False))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    if sys.argv[1] == "setup" and len(sys.argv) == 4:
        return setup(sys.argv[2], sys.argv[3])
    if sys.argv[1] == "probe" and len(sys.argv) == 3:
        return probe(sys.argv[2])
    print("invalid arguments", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
