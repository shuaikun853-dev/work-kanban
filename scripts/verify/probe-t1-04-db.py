#!/usr/bin/env python3
"""T1-04 Release UAT 数据库只读探针（T104-01 路径安全收紧）。

用标准库 sqlite3 以只读方式检查独立 UAT 便携目录中的数据库：
- schema 版本、完整性、journal_mode、schema_migrations、外键检查；
- projects / work_items 行数与状态分布（不输出任何标题/项目名称）；
- 创建组 / 成员关系行数、组成员数量分布、孤儿成员、多创建组工作副本等不变量。

路径安全（T104-01）：
- 数据库路径必须经 t1_04_path_guard 调用 PowerShell 原生守卫，复用 T1-03
  已验证的 Windows 句柄/信任锚/重解析点/最终路径/卷身份校验；
- outputPath 只能是 UAT 根目录下直接名为 evidence 的目录的直接 .json 子文件；
- 证据目录、证据文件与数据库父目录/全部祖先均在写入前完成原生校验；
- 安全校验失败时退出码 3，且在 sqlite3.connect() 与任何文件写入之前终止；
- 数据库打开/查询失败时退出码 2，绝不生成“成功”证据文件。

用法：
  python -X utf8 probe-t1-04-db.py <databasePath> <stage> [outputPath] \
      [--evidence-dir <UatEvidenceDir>]
提供 outputPath 时必须提供 --evidence-dir；未提供 outputPath 时 JSON 输出到 stdout。
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote

from t1_04_path_guard import PathGuardError, assert_guarded_path

STAGE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
REQUIRED_TABLES = {
    "schema_migrations",
    "projects",
    "work_items",
    "work_item_creation_groups",
    "work_item_creation_group_members",
}


class ProbeError(RuntimeError):
    """数据库不存在、打开失败或查询失败；不得输出成功证据。"""


def database_uri(database_path: str) -> str:
    absolute = Path(database_path).absolute().as_posix()
    return "file:" + quote(absolute, safe="/:") + "?mode=ro"


def scalar(connection: sqlite3.Connection, sql: str):
    row = connection.execute(sql).fetchone()
    if row is None:
        raise ProbeError(f"query returned no row: {sql}")
    return row[0]


def table_names(connection: sqlite3.Connection) -> set[str]:
    return {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        ).fetchall()
    }


def build_report(connection: sqlite3.Connection, stage: str) -> dict:
    tables = table_names(connection)
    missing = sorted(REQUIRED_TABLES - tables)
    if missing:
        raise ProbeError("required tables missing: " + ",".join(missing))

    integrity_rows = [
        str(row[0]) for row in connection.execute("PRAGMA integrity_check").fetchall()
    ]
    integrity_check = " | ".join(integrity_rows) if integrity_rows else "no-result"
    foreign_key_violations = len(
        connection.execute("PRAGMA foreign_key_check").fetchall()
    )
    migration_versions = [
        int(row[0])
        for row in connection.execute(
            "SELECT version FROM schema_migrations ORDER BY version"
        ).fetchall()
    ]

    histogram: dict[str, int] = {}
    for size, count in connection.execute(
        "SELECT member_count, COUNT(*) FROM ("
        "  SELECT group_id, COUNT(*) AS member_count "
        "  FROM work_item_creation_group_members GROUP BY group_id"
        ") GROUP BY member_count ORDER BY member_count"
    ).fetchall():
        histogram[str(int(size))] = int(count)

    report = {
        "task": "T1-04",
        "stage": stage,
        "status": "ok",
        "scope": "uat",
        "schema_version": int(scalar(connection, "PRAGMA user_version")),
        "migration_versions": migration_versions,
        "integrity_check": integrity_check,
        "journal_mode": str(scalar(connection, "PRAGMA journal_mode")),
        "foreign_keys": bool(scalar(connection, "PRAGMA foreign_keys")),
        "required_tables_present": True,
        "projects_total": int(scalar(connection, "SELECT COUNT(*) FROM projects")),
        "projects_archived": int(
            scalar(connection, "SELECT COUNT(*) FROM projects WHERE is_archived = 1")
        ),
        "work_items_total": int(scalar(connection, "SELECT COUNT(*) FROM work_items")),
        "work_items_pending": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_items WHERE lifecycle_status = 'pending'",
            )
        ),
        "work_items_other_status": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_items WHERE lifecycle_status != 'pending'",
            )
        ),
        "work_items_null_project": int(
            scalar(connection, "SELECT COUNT(*) FROM work_items WHERE project_id IS NULL")
        ),
        "work_items_linked_archived": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_items w JOIN projects p ON p.id = w.project_id "
                "WHERE p.is_archived = 1",
            )
        ),
        "work_items_linked_active": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_items w JOIN projects p ON p.id = w.project_id "
                "WHERE p.is_archived = 0",
            )
        ),
        "creation_groups_total": int(
            scalar(connection, "SELECT COUNT(*) FROM work_item_creation_groups")
        ),
        "creation_group_members_total": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_item_creation_group_members",
            )
        ),
        "creation_group_size_histogram": histogram,
        "creation_groups_without_members": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_item_creation_groups g WHERE NOT EXISTS ("
                "  SELECT 1 FROM work_item_creation_group_members m WHERE m.group_id = g.id"
                ")",
            )
        ),
        "orphan_creation_group_members": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_item_creation_group_members m "
                "LEFT JOIN work_item_creation_groups g ON g.id = m.group_id "
                "LEFT JOIN work_items w ON w.id = m.work_item_id "
                "WHERE g.id IS NULL OR w.id IS NULL",
            )
        ),
        "work_items_with_multiple_groups": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM ("
                "  SELECT work_item_id FROM work_item_creation_group_members "
                "  GROUP BY work_item_id HAVING COUNT(*) > 1"
                ")",
            )
        ),
        "batch_items_not_pending": int(
            scalar(
                connection,
                "SELECT COUNT(*) FROM work_item_creation_group_members m "
                "JOIN work_items w ON w.id = m.work_item_id "
                "WHERE w.lifecycle_status != 'pending'",
            )
        ),
        "foreign_key_violations": foreign_key_violations,
    }
    return report


def write_success(report: dict, output_path: str | None) -> int:
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if output_path:
        try:
            with open(output_path, "w", encoding="utf-8") as handle:
                handle.write(text)
                handle.flush()
        except OSError as error:
            print(f"DB_PROBE_WRITE_FAILED={error}", file=sys.stderr)
            return 2
        print("DB_PROBE_WRITTEN=" + output_path)
    else:
        print(text)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("database_path")
    parser.add_argument("stage")
    parser.add_argument("output_path", nargs="?")
    parser.add_argument("--evidence-dir", default=None)
    args = parser.parse_args()

    if not STAGE_PATTERN.fullmatch(args.stage):
        print("SAFETY_REFUSED: invalid stage name", file=sys.stderr)
        return 3

    try:
        # 1. 数据库路径必须最先通过原生守卫；任何失败都不得连接 SQLite。
        assert_guarded_path("database", args.database_path)
        if not Path(args.database_path).is_file():
            raise PathGuardError(
                "数据库文件不存在。已按 fail-closed 停止，不会创建新数据库。"
            )

        # 2. 输出路径必须在任何目录创建/写文件之前完成证据目录与文件校验。
        if args.output_path:
            if not args.evidence_dir:
                print(
                    "SAFETY_REFUSED: --evidence-dir is required when outputPath is provided",
                    file=sys.stderr,
                )
                return 3
            assert_guarded_path(
                "evidence-dir",
                args.evidence_dir,
                database_path=args.database_path,
            )
            assert_guarded_path(
                "evidence-file",
                args.output_path,
                database_path=args.database_path,
                evidence_directory=args.evidence_dir,
            )
    except PathGuardError as error:
        print(f"SAFETY_REFUSED: {error}", file=sys.stderr)
        return 3

    # 仅在全部路径校验完成后，才允许删除/覆盖已校验的证据文件。
    if args.output_path:
        try:
            Path(args.output_path).unlink(missing_ok=True)
        except OSError as error:
            print(f"DB_PROBE_OUTPUT_PREPARE_FAILED={error}", file=sys.stderr)
            return 2

    connection = None
    try:
        connection = sqlite3.connect(
            database_uri(args.database_path), uri=True, timeout=5.0
        )
        connection.execute("PRAGMA foreign_keys = ON")
        report = build_report(connection, args.stage)
    except (sqlite3.Error, ProbeError) as error:
        print(f"DB_PROBE_FAILED={error}", file=sys.stderr)
        return 2
    finally:
        if connection is not None:
            connection.close()

    return write_success(report, args.output_path)


if __name__ == "__main__":
    sys.exit(main())
