#!/usr/bin/env python3
"""T1-04 Windows 真实 Junction / 重解析点路径安全测试（T104-01）。

覆盖：
1. 正常 UAT 数据库路径允许通过（信任锚 + 原生最终路径 + 卷身份）；
2. UAT 数据库祖先目录是真实 Junction（指向受保护目录）时拒绝；
3. 数据库文件自身/叶子路径是重解析点时拒绝；文件符号链接在无权限时显式 SKIP；
4. 证据目录是 Junction（指向外部目录）时拒绝；
5. 安全检查失败时不会调用 sqlite3.connect；
6. 安全检查失败时不会在外部目录产生文件写入。

所有测试对象均为 D:\\WorkManager-test-data 下的隔离目录/虚构文件；
绝不打开、修改、安装 trigger 到正式数据库 D:\\WorkManager。
残余 TOCTOU 并发替换风险按 DEC-029 / Issue #2 保持延期，不在本测试宣称消除。
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import time
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TEST_ROOT = Path(r"D:\WorkManager-test-data")
FORMAL_ROOT = Path(r"D:\WorkManager")
sys.path.insert(0, str(SCRIPT_DIR))

from t1_04_path_guard import PathGuardError, assert_guarded_path  # noqa: E402

CASE_PREFIX = "t1-04-path-test-"
checks: list[dict] = []
skips: list[dict] = []
case_roots: list[Path] = []
junctions: list[Path] = []


def check(name: str, passed: bool, detail: str = "") -> None:
    checks.append({"name": name, "pass": bool(passed), "detail": detail})
    print(f"{'PASS' if passed else 'FAIL'} {name}" + (f" — {detail}" if detail else ""))


def skip(name: str, reason: str) -> None:
    skips.append({"name": name, "reason": reason})
    print(f"SKIP {name} — {reason}")


def new_uat_root(label: str) -> Path:
    unique = f"{CASE_PREFIX}{label}-{os.getpid()}-{int(time.time() * 1000)}"
    path = TEST_ROOT / unique
    if path.exists():
        raise RuntimeError(f"test root already exists: {path}")
    path.mkdir(parents=True)
    case_roots.append(path)
    return path


def make_junction(link: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        ["cmd", "/c", "mklink", "/J", str(link), str(target)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"mklink /J failed: {completed.stdout} {completed.stderr}")
    junctions.append(link)


def remove_junction(link: Path) -> None:
    if link in junctions:
        subprocess.run(
            ["cmd", "/c", "rmdir", str(link)],
            capture_output=True,
            text=True,
            check=False,
        )
        junctions.remove(link)


def try_file_symlink(link: Path, target: Path) -> tuple[bool, str]:
    completed = subprocess.run(
        ["cmd", "/c", "mklink", str(link), str(target)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if completed.returncode == 0:
        junctions.append(link)
        return True, "file symlink created with cmd mklink"
    return (
        False,
        f"file symlink unavailable (mklink exit={completed.returncode}; "
        "SeCreateSymbolicLinkPrivilege/developer mode required)",
    )


def expect_rejected(name: str, action) -> None:
    try:
        action()
    except PathGuardError as error:
        message = str(error)
        reparse_rejected = (
            "重解析点" in message
            or "reparse" in message.lower()
            or "Junction" in message
            or "不是真实目录" in message
        )
        check(name, reparse_rejected, message[:400])
    except Exception as error:  # noqa: BLE001
        check(name, False, f"unexpected error type: {type(error).__name__}: {error}")
    else:
        check(name, False, "path guard unexpectedly accepted the path")


def load_module(name: str, filename: str):
    path = SCRIPT_DIR / filename
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def cleanup() -> None:
    for link in list(junctions):
        remove_junction(link)
    for root in case_roots:
        if not str(root).lower().startswith(str(TEST_ROOT).lower() + "\\"):
            continue
        formal_text = str(FORMAL_ROOT).lower().rstrip("\\")
        root_text = str(root).lower()
        if root_text == formal_text or root_text.startswith(formal_text + "\\"):
            continue
        shutil.rmtree(root, ignore_errors=True)


def main() -> int:
    if not TEST_ROOT.is_dir():
        print(f"PRECONDITION_FAILED: test root missing: {TEST_ROOT}", file=sys.stderr)
        return 2
    if TEST_ROOT.resolve() == FORMAL_ROOT.resolve():
        print("PRECONDITION_FAILED: formal root must not be used", file=sys.stderr)
        return 2

    try:
        # 1. 正常 UAT 布局：数据库与证据目录均为普通目录/文件。
        uat = new_uat_root("normal")
        db = uat / "app" / "data" / "database" / "work.db"
        evidence = uat / "evidence"
        db.parent.mkdir(parents=True)
        evidence.mkdir()
        db.write_bytes(b"not-a-real-database-but-safe-test-fixture")
        check(
            "normal.databasePathAccepted",
            assert_guarded_path("database", db)["ok"] is True,
        )
        check(
            "normal.evidenceDirectoryAccepted",
            assert_guarded_path(
                "evidence-dir", evidence, database_path=db
            )["ok"]
            is True,
        )
        check(
            "normal.evidenceFilePathAccepted",
            assert_guarded_path(
                "evidence-file",
                evidence / "probe.json",
                database_path=db,
                evidence_directory=evidence,
            )["ok"]
            is True,
        )

        # 2. UAT 子目录 Junction 指向受保护目录：必须拒绝。
        protected = new_uat_root("protected-target") / "protected"
        protected.mkdir(parents=True)
        junction_uat = new_uat_root("ancestor-junction")
        real_app = junction_uat / "app-real"
        (real_app / "data" / "database").mkdir(parents=True)
        (real_app / "data" / "database" / "work.db").write_bytes(b"safe")
        (protected / "data" / "database").mkdir(parents=True)
        (protected / "data" / "database" / "work.db").write_bytes(b"protected")
        make_junction(junction_uat / "app", protected)
        junction_db = junction_uat / "app" / "data" / "database" / "work.db"
        expect_rejected(
            "junction.databaseAncestorRejected",
            lambda: assert_guarded_path("database", junction_db),
        )

        # 3. 数据库叶子路径是重解析点：目录 Junction 必须拒绝；文件符号链接尽力实测。
        leaf_uat = new_uat_root("leaf-reparse")
        leaf_db = leaf_uat / "app" / "data" / "database" / "work.db"
        leaf_db.parent.mkdir(parents=True)
        leaf_target = leaf_uat / "reparse-target"
        leaf_target.mkdir()
        make_junction(leaf_db, leaf_target)
        expect_rejected(
            "junction.databaseLeafReparseRejected",
            lambda: assert_guarded_path("database", leaf_db),
        )

        symlink_uat = new_uat_root("file-symlink")
        symlink_db = symlink_uat / "app" / "data" / "database" / "work.db"
        symlink_db.parent.mkdir(parents=True)
        symlink_target = symlink_uat / "outside-target.db"
        symlink_target.write_bytes(b"outside")
        created, detail = try_file_symlink(symlink_db, symlink_target)
        if created:
            expect_rejected(
                "symlink.databaseFileRejected",
                lambda: assert_guarded_path("database", symlink_db),
            )
        else:
            skip("symlink.databaseFileRejected", detail)

        # 4. 证据目录 Junction 指向外部目录：必须拒绝，且探针不得写外部文件。
        evidence_uat = new_uat_root("evidence-junction")
        evidence_db = evidence_uat / "app" / "data" / "database" / "work.db"
        evidence_db.parent.mkdir(parents=True)
        evidence_db.write_bytes(b"safe-fixture")
        external = new_uat_root("external-evidence-target") / "external"
        external.mkdir(parents=True)
        make_junction(evidence_uat / "evidence", external)
        junction_evidence = evidence_uat / "evidence"
        expect_rejected(
            "junction.evidenceDirectoryRejected",
            lambda: assert_guarded_path(
                "evidence-dir", junction_evidence, database_path=evidence_db
            ),
        )

        # 5. 安全失败不得调用 sqlite3.connect。
        control = load_module("control_t1_04_fault", "control-t1-04-fault.py")
        connect_called = {"value": False}

        def forbidden_connect(*_args, **_kwargs):
            connect_called["value"] = True
            raise AssertionError("sqlite3.connect must not be called after path guard failure")

        control.sqlite3.connect = forbidden_connect
        old_argv = sys.argv
        try:
            sys.argv = ["control-t1-04-fault.py", "status", str(junction_db)]
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                exit_code = control.main()
        finally:
            sys.argv = old_argv
        check(
            "guard.noDatabaseConnectOnAncestorJunction",
            exit_code == 3 and connect_called["value"] is False,
            f"exit={exit_code} connectCalled={connect_called['value']}",
        )

        # 6. 安全失败不得产生外部文件写入。
        probe = load_module("probe_t1_04_db", "probe-t1-04-db.py")
        external_file = external / "should-not-be-written.json"
        connect_called["value"] = False
        probe.sqlite3.connect = forbidden_connect
        old_argv = sys.argv
        try:
            sys.argv = [
                "probe-t1-04-db.py",
                str(evidence_db),
                "junction-test",
                str(junction_evidence / "should-not-be-written.json"),
                "--evidence-dir",
                str(junction_evidence),
            ]
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                exit_code = probe.main()
        finally:
            sys.argv = old_argv
        check(
            "guard.noDatabaseConnectOnEvidenceJunction",
            exit_code == 3 and connect_called["value"] is False,
            f"exit={exit_code} connectCalled={connect_called['value']}",
        )
        check(
            "guard.noExternalWriteOnEvidenceJunction",
            not external_file.exists(),
            f"externalFileExists={external_file.exists()}",
        )
    finally:
        cleanup()

    failed = [item["name"] for item in checks if not item["pass"]]
    evidence = {
        "task": "T1-04",
        "scope": "T104-01 Windows real Junction / reparse-point path security",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "testRoot": "D:\\WorkManager-test-data",
        "formalRootTouched": False,
        "checks": checks,
        "failed": failed,
        "skips": skips,
        "pass": not failed,
        "residualRisk": "TOCTOU concurrent replacement remains deferred by DEC-029 / Issue #2",
    }
    output_index = sys.argv.index("--evidence") if "--evidence" in sys.argv else -1
    if output_index >= 0 and output_index + 1 < len(sys.argv):
        output_path = Path(sys.argv[output_index + 1])
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"PATH_GUARD_EVIDENCE={output_path}")
    print(json.dumps({"checks": len(checks), "failed": len(failed), "skips": len(skips)}, ensure_ascii=False))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
