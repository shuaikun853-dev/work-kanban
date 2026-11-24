#!/usr/bin/env python3
"""T1-04 Release UAT 数据库只读探针。

用标准库 sqlite3 以只读方式检查独立 UAT 便携目录中的数据库：
- schema 版本、完整性、journal_mode、schema_migrations、外键检查；
- projects / work_items 行数与状态分布；
- work_item_creation_groups / work_item_creation_group_members 行数、组成员数量分布、
  孤儿成员、多创建组工作副本等原子性不变量。

只读打开，不修改任何数据。用法：
  python -X utf8 probe-t1-04-db.py <databasePath> <stage> [outputPath]
提供 outputPath 时 JSON 以 UTF-8 写入该文件；未提供时 JSON 输出到 stdout。
无法只读打开或查询失败时退出码 2。
"""

import json
import os
import sqlite3
import sys


def emit(report, exit_code):
    output_path = report.pop("_outputPath", None)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if output_path:
        with open(output_path, "w", encoding="utf-8") as handle:
            handle.write(text)
        print("DB_PROBE_WRITTEN=" + output_path)
    else:
        print(text)
    return exit_code


def scalar(connection, sql):
    return connection.execute(sql).fetchone()[0]


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: probe-t1-04-db.py <databasePath> <stage> [outputPath]", file=sys.stderr)
        return 2

    database_path = sys.argv[1]
    stage = sys.argv[2]
    output_path = sys.argv[3] if len(sys.argv) > 3 else None
    report = {
        "task": "T1-04",
        "stage": stage,
        "database_path": database_path,
        "exists": os.path.isfile(database_path),
        "user_version": None,
        "integrity_check": None,
        "journal_mode": None,
        "foreign_keys": None,
        "tables": [],
        "schema_migrations": [],
        "projects_total": None,
        "projects_archived": None,
        "work_items_total": None,
        "work_items_pending": None,
        "work_items_other_status": None,
        "work_items_null_project": None,
        "work_items_linked_archived": None,
        "work_items_linked_active": None,
        "creation_groups_total": None,
        "creation_group_members_total": None,
        "creation_group_size_histogram": {},
        "creation_groups_without_members": None,
        "orphan_creation_group_members": None,
        "work_items_with_multiple_groups": None,
        "creation_group_titles": [],
        "pending_titles": [],
        "foreign_key_violations": None,
        "_outputPath": output_path,
    }

    if not report["exists"]:
        return emit(report, 2)

    try:
        connection = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True, timeout=5.0)
    except sqlite3.Error as error:
        report["error"] = f"read-only open failed: {error}"
        return emit(report, 2)

    try:
        connection.execute("PRAGMA foreign_keys = ON")
        report["user_version"] = scalar(connection, "PRAGMA user_version")
        report["integrity_check"] = scalar(connection, "PRAGMA integrity_check")
        report["journal_mode"] = scalar(connection, "PRAGMA journal_mode")
        report["foreign_keys"] = scalar(connection, "PRAGMA foreign_keys")
        report["tables"] = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            ).fetchall()
        ]
        if "schema_migrations" in report["tables"]:
            report["schema_migrations"] = [
                {"version": row[0], "name": row[1]}
                for row in connection.execute(
                    "SELECT version, name FROM schema_migrations ORDER BY version"
                ).fetchall()
            ]
        if "projects" in report["tables"]:
            report["projects_total"] = scalar(connection, "SELECT COUNT(*) FROM projects")
            report["projects_archived"] = scalar(
                connection, "SELECT COUNT(*) FROM projects WHERE is_archived = 1"
            )
        if "work_items" in report["tables"]:
            report["work_items_total"] = scalar(
                connection, "SELECT COUNT(*) FROM work_items"
            )
            report["work_items_pending"] = scalar(
                connection,
                "SELECT COUNT(*) FROM work_items WHERE lifecycle_status = 'pending'",
            )
            report["work_items_other_status"] = scalar(
                connection,
                "SELECT COUNT(*) FROM work_items WHERE lifecycle_status != 'pending'",
            )
            report["work_items_null_project"] = scalar(
                connection, "SELECT COUNT(*) FROM work_items WHERE project_id IS NULL"
            )
            report["work_items_linked_archived"] = scalar(
                connection,
                "SELECT COUNT(*) FROM work_items w JOIN projects p ON p.id = w.project_id "
                "WHERE p.is_archived = 1",
            )
            report["work_items_linked_active"] = scalar(
                connection,
                "SELECT COUNT(*) FROM work_items w JOIN projects p ON p.id = w.project_id "
                "WHERE p.is_archived = 0",
            )
            report["pending_titles"] = [
                row[0]
                for row in connection.execute(
                    "SELECT title FROM work_items WHERE lifecycle_status = 'pending' "
                    "ORDER BY created_at DESC, id DESC"
                ).fetchall()
            ]
        if "work_item_creation_groups" in report["tables"]:
            report["creation_groups_total"] = scalar(
                connection, "SELECT COUNT(*) FROM work_item_creation_groups"
            )
            report["creation_group_titles"] = [
                row[0]
                for row in connection.execute(
                    "SELECT source_title FROM work_item_creation_groups "
                    "ORDER BY created_at DESC, id DESC"
                ).fetchall()
            ]
        if "work_item_creation_group_members" in report["tables"]:
            report["creation_group_members_total"] = scalar(
                connection, "SELECT COUNT(*) FROM work_item_creation_group_members"
            )
            histogram = {}
            for size, count in connection.execute(
                "SELECT member_count, COUNT(*) FROM ("
                "  SELECT group_id, COUNT(*) AS member_count "
                "  FROM work_item_creation_group_members GROUP BY group_id"
                ") GROUP BY member_count ORDER BY member_count"
            ).fetchall():
                histogram[str(int(size))] = int(count)
            report["creation_group_size_histogram"] = histogram
            report["creation_groups_without_members"] = scalar(
                connection,
                "SELECT COUNT(*) FROM work_item_creation_groups g "
                "WHERE NOT EXISTS ("
                "  SELECT 1 FROM work_item_creation_group_members m WHERE m.group_id = g.id"
                ")",
            )
            report["orphan_creation_group_members"] = scalar(
                connection,
                "SELECT COUNT(*) FROM work_item_creation_group_members m "
                "LEFT JOIN work_item_creation_groups g ON g.id = m.group_id "
                "LEFT JOIN work_items w ON w.id = m.work_item_id "
                "WHERE g.id IS NULL OR w.id IS NULL",
            )
            report["work_items_with_multiple_groups"] = scalar(
                connection,
                "SELECT COUNT(*) FROM ("
                "  SELECT work_item_id FROM work_item_creation_group_members "
                "  GROUP BY work_item_id HAVING COUNT(*) > 1"
                ")",
            )
        report["foreign_key_violations"] = len(
            connection.execute("PRAGMA foreign_key_check").fetchall()
        )
    except sqlite3.Error as error:
        report["error"] = f"query failed: {error}"
        return emit(report, 2)
    finally:
        connection.close()

    return emit(report, 0)


if __name__ == "__main__":
    sys.exit(main())
