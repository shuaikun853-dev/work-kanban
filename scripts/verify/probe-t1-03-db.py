#!/usr/bin/env python3
"""T1-03 Release UAT 数据库只读探针。

用标准库 sqlite3 以只读方式检查独立 UAT 便携目录中的数据库：
- schema 版本、完整性、journal_mode、schema_migrations；
- projects / work_items 行数与生命周期状态分布（只读取，不修改任何数据）。

用法：python -X utf8 probe-t1-03-db.py <databasePath> <stage> [outputPath]
- 提供 outputPath 时，JSON 以 UTF-8 写入该文件（供 PowerShell 5.1 无歧义读取），
  stdout 只输出 ASCII 状态行；
- 未提供 outputPath 时，JSON 输出到 stdout。
无法只读打开时退出码 2。
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


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: probe-t1-03-db.py <databasePath> <stage> [outputPath]", file=sys.stderr)
        return 2

    database_path = sys.argv[1]
    stage = sys.argv[2]
    output_path = sys.argv[3] if len(sys.argv) > 3 else None
    report = {
        "task": "T1-03",
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
        "pending_titles": [],
        "_outputPath": output_path,
    }

    if not report["exists"]:
        return emit(report, 2)

    try:
        connection = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True)
    except sqlite3.Error as error:
        report["error"] = f"read-only open failed: {error}"
        return emit(report, 2)

    try:
        connection.execute("PRAGMA foreign_keys = ON")
        report["user_version"] = connection.execute("PRAGMA user_version").fetchone()[0]
        report["integrity_check"] = connection.execute("PRAGMA integrity_check").fetchone()[0]
        report["journal_mode"] = connection.execute("PRAGMA journal_mode").fetchone()[0]
        report["foreign_keys"] = connection.execute("PRAGMA foreign_keys").fetchone()[0]
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
            report["projects_total"] = connection.execute(
                "SELECT COUNT(*) FROM projects"
            ).fetchone()[0]
            report["projects_archived"] = connection.execute(
                "SELECT COUNT(*) FROM projects WHERE is_archived = 1"
            ).fetchone()[0]
        if "work_items" in report["tables"]:
            report["work_items_total"] = connection.execute(
                "SELECT COUNT(*) FROM work_items"
            ).fetchone()[0]
            report["work_items_pending"] = connection.execute(
                "SELECT COUNT(*) FROM work_items WHERE lifecycle_status = 'pending'"
            ).fetchone()[0]
            report["work_items_other_status"] = connection.execute(
                "SELECT COUNT(*) FROM work_items WHERE lifecycle_status != 'pending'"
            ).fetchone()[0]
            report["work_items_null_project"] = connection.execute(
                "SELECT COUNT(*) FROM work_items WHERE project_id IS NULL"
            ).fetchone()[0]
            report["work_items_linked_archived"] = connection.execute(
                "SELECT COUNT(*) FROM work_items w JOIN projects p ON p.id = w.project_id "
                "WHERE p.is_archived = 1"
            ).fetchone()[0]
            report["work_items_linked_active"] = connection.execute(
                "SELECT COUNT(*) FROM work_items w JOIN projects p ON p.id = w.project_id "
                "WHERE p.is_archived = 0"
            ).fetchone()[0]
            report["pending_titles"] = [
                row[0]
                for row in connection.execute(
                    "SELECT title FROM work_items WHERE lifecycle_status = 'pending' "
                    "ORDER BY created_at DESC, id DESC"
                ).fetchall()
            ]
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
