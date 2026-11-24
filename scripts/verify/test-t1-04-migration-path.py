#!/usr/bin/env python3
"""T1-04 Release migration fixture 路径安全专项（R2-02 第六轮修复）。

背景：第五轮 `verify-t1-04-migration-failure.ps1` / `t1-04-migration-fixture.py`
仍使用 `GetFullPath().StartsWith(...)` 字符串检查与直接 `sqlite3.connect()`，
未调用 T1-04 原生路径守卫；PowerShell 清理也没有 fail-closed 身份复验。

本测试覆盖：
1. 正常 Migration Fixture setup / 只读 probe PASS（真实 0001/0002/0003 + 真实
   0004 索引名冲突索引）；
2. 输出目录祖先 Junction → PowerShell 迁移验证脚本拒绝（exit 2，不创建目录）；
3. 数据库父目录 Junction / 数据库文件重解析点 → Python Fixture 拒绝；
4. setup 安全验证失败 → 不创建数据库、不调用 sqlite3.connect；
5. probe 安全验证失败 → 不连接数据库；
6. Python 守卫进程执行失败 → setup/probe 均 fail-closed，不调用 sqlite3.connect；
7. 清理前目录身份变化 → fail-closed 清理拒绝删除（复用 T1-03 安全清理机制）；
8. 外部 Canary（Junction 目标目录）内容 / 目录结构前后完全一致；
9. 迁移验证脚本源码必须调用 T1-04 原生守卫与 T1-03 fail-closed 清理，且不再
   出现对 UAT 目录的 `Remove-Item -Recurse -Force` 强制清理。

真实 Migration 失败回滚测试（schema 3、真实 0004 索引冲突、Release EXE 启动失败、
退出码非 0、user_version 仍 3、无 version 4 / 两张新表、历史数据不变、
integrity_check=ok）由 `verify-t1-04-migration-failure.ps1` 保留并单独执行；本测试
不削弱该测试。

安全边界：所有测试对象位于 `D:\\WorkManager-test-data` 下的隔离 UAT 与虚构文件；
不打开/修改正式运行目录 `D:\\WorkManager`（仅只读身份快照）。

用法：
  python -X utf8 scripts/verify/test-t1-04-migration-path.py [--evidence <uat>/evidence/<file>.json]
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sqlite3
import subprocess
import sys
import time
import traceback
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import t1_04_path_guard as path_guard  # noqa: E402
from t1_04_path_guard import PathGuardError  # noqa: E402
import t1_04_path_test_support as support  # noqa: E402

MIGRATION_SCRIPT = SCRIPT_DIR / "verify-t1-04-migration-failure.ps1"
FIXTURE_SCRIPT = SCRIPT_DIR / "t1-04-migration-fixture.py"
RELEASE_EXE = REPO_ROOT / "target" / "release" / "workmanager.exe"

checks: list[dict] = []
skips: list[dict] = []
canaries: list[dict] = []


def check(name: str, passed: bool, detail: str = "") -> None:
    entry = {"name": name, "pass": bool(passed), "detail": support.sanitize(detail)}
    checks.append(entry)
    suffix = f" — {entry['detail']}" if entry["detail"] else ""
    print(f"{'PASS' if passed else 'FAIL'} {name}{suffix}")


def skip(name: str, reason: str) -> None:
    skips.append({"name": name, "reason": support.sanitize(reason)})
    print(f"SKIP {name} — {support.sanitize(reason)}")


def load_module(name: str, filename: str):
    path = SCRIPT_DIR / filename
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise support.SupportError(f"cannot load module: {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def call_silently(function, *args):
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        return function(*args)


def capture_stdout(function, *args) -> tuple[int, str]:
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        code = function(*args)
    return code, buffer.getvalue()


def make_canary(registry: support.PathCaseRegistry, label: str) -> tuple[Path, dict]:
    case = registry.new_case(f"canary-{label}")
    target = case.path / "target"
    support.ensure_directory(target)
    (target / "canary.txt").write_text(f"canary-{label}", encoding="utf-8")
    before = support.snapshot_tree(target)
    canaries.append({"label": label, "target": target, "before": before})
    return target, before


def make_database_path(case: support.ManagedCase) -> Path:
    database = case.path / "app" / "data" / "database" / "work.db"
    support.ensure_directory(database.parent)
    return database


def expect_guard_error(name: str, action) -> tuple[bool, str]:
    try:
        action()
    except PathGuardError as error:
        check(name, True, str(error)[:400])
        return True, str(error)
    except Exception as error:  # noqa: BLE001
        check(name, False, f"unexpected error type: {type(error).__name__}: {error}")
        return False, str(error)
    check(name, False, "path guard unexpectedly accepted the path")
    return False, ""


def with_guard_script(path: Path, action):
    original = path_guard.GUARD_SCRIPT
    path_guard.GUARD_SCRIPT = path
    try:
        return action()
    finally:
        path_guard.GUARD_SCRIPT = original


def run_fixture_normal(fixture, registry: support.PathCaseRegistry) -> dict:
    case = registry.new_case("migration-normal")
    database = make_database_path(case)
    exit_code = call_silently(fixture.setup, str(REPO_ROOT), str(database))
    database_created = database.is_file()
    check(
        "fixture.normalSetup",
        exit_code in (0, None) and database_created,
        f"exit={exit_code} databaseCreated={database_created}",
    )

    probe_code, probe_text = capture_stdout(fixture.probe, str(database))
    report = {}
    try:
        report = json.loads(probe_text.strip().splitlines()[-1])
    except (ValueError, IndexError):
        report = {}
    check(
        "fixture.normalProbe",
        probe_code == 0
        and int(report.get("user_version", -1)) == 3
        and int(report.get("version4_rows", -1)) == 0
        and int(report.get("group_table", -1)) == 0
        and int(report.get("member_table", -1)) == 0
        and int(report.get("projects", -1)) == 1
        and int(report.get("work_items", -1)) == 1
        and str(report.get("integrity_check", "")) == "ok",
        f"exit={probe_code} report={json.dumps(report, ensure_ascii=False)[:300]}",
    )
    return {"case": case, "database": database}


def run_fixture_guard_checks(fixture, registry: support.PathCaseRegistry, normal: dict) -> None:
    # 1) 正常 DB 存在时，只允许通过安全校验后的只读连接（mode=ro）。
    recorded: list[dict] = []
    real_connect = sqlite3.connect

    def spy_connect(*args, **kwargs):
        recorded.append({"args": args, "kwargs": kwargs})
        return real_connect(*args, **kwargs)

    sqlite3.connect = spy_connect
    try:
        probe_code, _probe_text = capture_stdout(fixture.probe, str(normal["database"]))
    finally:
        sqlite3.connect = real_connect
    probe_uris = [str(item["args"][0]) if item["args"] else "" for item in recorded]
    read_only = bool(probe_uris) and all("mode=ro" in uri for uri in probe_uris)
    check(
        "fixture.probeReadOnlyConnection",
        probe_code == 0 and len(recorded) == 1 and read_only,
        f"connectCalls={len(recorded)} modeRo={read_only}",
    )

    # 2) setup 目标已存在：拒绝复用/覆盖。
    existing_case = registry.new_case("migration-existing-target")
    existing_database = make_database_path(existing_case)
    existing_database.write_bytes(b"existing-database-must-not-be-overwritten")
    expect_guard_error(
        "fixture.setupExistingTargetRejected",
        lambda: call_silently(fixture.setup, str(REPO_ROOT), str(existing_database)),
    )
    check(
        "fixture.setupExistingTargetNotOverwritten",
        existing_database.read_bytes() == b"existing-database-must-not-be-overwritten",
        "existingTargetUnchanged=True",
    )

    # 3) 数据库父目录是 Junction：拒绝，且不向 Junction 目标写入。
    parent_case = registry.new_case("migration-parent-junction")
    parent_canary, parent_before = make_canary(registry, "migration-parent")
    support.ensure_directory(parent_case.path / "app" / "data")
    support.make_junction(parent_case.path / "app" / "data" / "database", parent_canary)
    junction_database = parent_case.path / "app" / "data" / "database" / "work.db"
    forbidden_calls = {"value": False}

    def forbidden_connect(*_args, **_kwargs):
        forbidden_calls["value"] = True
        raise AssertionError("sqlite3.connect must not be called")

    sqlite3.connect = forbidden_connect
    try:
        parent_rejected, _message = expect_guard_error(
            "fixture.setupParentJunctionRejected",
            lambda: call_silently(
                fixture.setup, str(REPO_ROOT), str(junction_database)
            ),
        )
    finally:
        sqlite3.connect = real_connect
    parent_canary_unchanged = support.snapshot_unchanged(
        parent_before, support.snapshot_tree(parent_canary)
    )
    check(
        "fixture.setupParentJunctionNoWrite",
        parent_rejected
        and forbidden_calls["value"] is False
        and parent_canary_unchanged,
        f"connectCalled={forbidden_calls['value']} "
        f"canaryUnchanged={parent_canary_unchanged}",
    )
    support.remove_junction(parent_case.path / "app" / "data" / "database")

    # 4) 数据库文件叶子是重解析点（目录 Junction）：拒绝，不连接。
    leaf_case = registry.new_case("migration-leaf-junction")
    leaf_database = make_database_path(leaf_case)
    leaf_canary, leaf_before = make_canary(registry, "migration-leaf")
    support.make_junction(leaf_database, leaf_canary)
    forbidden_calls["value"] = False
    sqlite3.connect = forbidden_connect
    try:
        leaf_rejected, _leaf_message = expect_guard_error(
            "fixture.setupLeafReparseRejected",
            lambda: call_silently(fixture.setup, str(REPO_ROOT), str(leaf_database)),
        )
    finally:
        sqlite3.connect = real_connect
    leaf_unchanged = support.snapshot_unchanged(
        leaf_before, support.snapshot_tree(leaf_canary)
    )
    check(
        "fixture.setupLeafReparseNoWrite",
        leaf_rejected
        and forbidden_calls["value"] is False
        and leaf_unchanged,
        f"connectCalled={forbidden_calls['value']} canaryUnchanged={leaf_unchanged}",
    )
    support.remove_junction(leaf_database)

    # 5) 守卫进程执行失败：setup 不创建数据库、不连接。
    failure_case = registry.new_case("migration-guard-failure")
    failure_database = make_database_path(failure_case)
    failure_database.unlink(missing_ok=True)
    forbidden_calls["value"] = False
    sqlite3.connect = forbidden_connect
    try:
        guard_rejected, _guard_message = expect_guard_error(
            "fixture.setupGuardFailureRejected",
            lambda: with_guard_script(
                SCRIPT_DIR / "missing-migration-guard-for-test.ps1",
                lambda: call_silently(
                    fixture.setup, str(REPO_ROOT), str(failure_database)
                ),
            ),
        )
    finally:
        sqlite3.connect = real_connect
    check(
        "fixture.setupGuardFailureNoCreate",
        guard_rejected
        and forbidden_calls["value"] is False
        and not support.path_present(failure_database),
        f"connectCalled={forbidden_calls['value']} "
        f"databaseCreated={support.path_present(failure_database)}",
    )

    # 6) probe 守卫执行失败：不连接数据库。
    forbidden_calls["value"] = False
    sqlite3.connect = forbidden_connect
    try:
        probe_guard_rejected, _probe_message = expect_guard_error(
            "fixture.probeGuardFailureRejected",
            lambda: with_guard_script(
                SCRIPT_DIR / "missing-migration-guard-for-test.ps1",
                lambda: call_silently(fixture.probe, str(normal["database"])),
            ),
        )
    finally:
        sqlite3.connect = real_connect
    check(
        "fixture.probeGuardFailureNoConnect",
        probe_guard_rejected and forbidden_calls["value"] is False,
        f"connectCalled={forbidden_calls['value']}",
    )

    # 7) probe 父目录 Junction：不连接数据库。
    probe_parent_case = registry.new_case("migration-probe-parent-junction")
    probe_parent_database = make_database_path(probe_parent_case)
    probe_canary, probe_before = make_canary(registry, "migration-probe-parent")
    probe_database_dir = probe_parent_case.path / "app" / "data" / "database"
    support.replace_directory_with_junction(probe_database_dir, probe_canary)
    forbidden_calls["value"] = False
    sqlite3.connect = forbidden_connect
    try:
        probe_parent_rejected, _probe_parent_message = expect_guard_error(
            "fixture.probeParentJunctionRejected",
            lambda: call_silently(fixture.probe, str(probe_parent_database)),
        )
    finally:
        sqlite3.connect = real_connect
    check(
        "fixture.probeSafetyFailureNoConnect",
        probe_parent_rejected and forbidden_calls["value"] is False,
        f"connectCalled={forbidden_calls['value']}",
    )
    support.remove_junction(probe_database_dir)
    support.ensure_directory(probe_database_dir)


def invoke_migration_script(output_dir: str) -> subprocess.CompletedProcess:
    arguments = [
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(MIGRATION_SCRIPT),
        "-ExePath",
        str(RELEASE_EXE),
    ]
    if output_dir:
        arguments.extend(["-OutputDir", output_dir])
    try:
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=300,
            check=False,
        )
    except subprocess.SubprocessError as error:
        return subprocess.CompletedProcess(arguments, 1, "", f"failed to start: {error}")


def run_migration_script_checks(registry: support.PathCaseRegistry) -> None:
    script_text = MIGRATION_SCRIPT.read_text(encoding="utf-8-sig")
    check(
        "migrationScript.nativeGuardsPresent",
        all(
            marker in script_text
            for marker in (
                "Assert-T104UatTrustedRoot",
                "Assert-T104UatPlannedDatabaseFile",
                "Assert-T104UatPlannedEvidenceDirectory",
                "Assert-T104UatDatabaseFile",
            )
        ),
        "trust-anchor/planned-database/planned-evidence/database guards present",
    )
    check(
        "migrationScript.failClosedCleanupReused",
        "Invoke-T103FailClosedSandboxCleanup" in script_text
        and "Remove-Item -LiteralPath $uat -Recurse -Force" not in script_text,
        "fail-closed cleanup reused; forced recursive cleanup removed",
    )
    check(
        "migrationScript.realMigrationRollbackTestPreserved",
        "MIGRATION_FAILURE_ROLLBACK=PASS" in script_text
        and "Start-Process" in script_text
        and "Wait-FailureDialog" in script_text,
        "real Release migration rollback assertions preserved",
    )

    # 输出目录祖先 Junction：PowerShell 脚本必须在创建任何目录前拒绝。
    junction_case = registry.new_case("migration-output-junction")
    canary_target, canary_before = make_canary(registry, "migration-output")
    support.make_junction(junction_case.path / "junction-link", canary_target)
    rejected_output_dir = (
        junction_case.path / "junction-link" / "t1-04-migration-should-not-exist"
    )
    completed = invoke_migration_script(str(rejected_output_dir))
    created_under_canary = support.path_present(
        canary_target / "t1-04-migration-should-not-exist"
    )
    canary_unchanged = support.snapshot_unchanged(
        canary_before, support.snapshot_tree(canary_target)
    )
    check(
        "migrationScript.outputAncestorJunctionRejected",
        completed.returncode == 2
        and "PRECONDITION_FAILED" in (completed.stdout or "")
        and not created_under_canary
        and canary_unchanged,
        f"exit={completed.returncode} createdUnderJunction={created_under_canary} "
        f"canaryUnchanged={canary_unchanged}",
    )
    support.remove_junction(junction_case.path / "junction-link")

    # 输出目录在测试根之外：必须在创建前拒绝。
    outside_output = str(support.TEST_ROOT.parent / "WorkManager-outside-out")
    outside = invoke_migration_script(outside_output)
    check(
        "migrationScript.outsideTestRootRejected",
        outside.returncode == 2
        and "PRECONDITION_FAILED" in (outside.stdout or ""),
        f"exit={outside.returncode}",
    )

    # 输出目录位于正式目录内：必须在创建前拒绝（不写入正式目录）。
    formal_case = registry.new_case("migration-formal-output")
    formal_candidate = str(Path(r"D:\WorkManager") / "data" / "t1-04-should-not-exist")
    formal = invoke_migration_script(formal_candidate)
    check(
        "migrationScript.formalRootOutputRejected",
        formal.returncode == 2
        and "PRECONDITION_FAILED" in (formal.stdout or ""),
        f"exit={formal.returncode}",
    )
    _ = formal_case


def run_cleanup_checks(registry: support.PathCaseRegistry) -> None:
    case = registry.new_case("migration-cleanup-identity")
    sentinel = case.path / "sentinel.txt"
    sentinel.write_text("migration-cleanup-sentinel", encoding="utf-8")
    old_identity = dict(case.identity)
    sentinel.unlink()
    os.rmdir(str(case.path))
    support.guard_path("uat-root-target", str(case.path))
    case.path.mkdir(parents=False)
    new_identity = support.guard_path("uat-root", str(case.path))["identity"]
    identity_changed = (
        str(old_identity.get("fileIdHex")) != str(new_identity.get("fileIdHex"))
    )
    rejected = False
    retained = False
    if identity_changed:
        try:
            support.guard_cleanup(case.path, old_identity)
        except PathGuardError as error:
            rejected = "身份" in str(error) or "fileId" in str(error)
        retained = support.path_present(case.path)
    check(
        "cleanup.identityChangedRejected",
        identity_changed and rejected and retained,
        f"identityChanged={identity_changed} rejected={rejected} retained={retained}",
    )
    case.identity = new_identity


def evaluate_canaries() -> None:
    per_target = []
    for canary in canaries:
        unchanged = support.snapshot_unchanged(
            canary["before"], support.snapshot_tree(canary["target"])
        )
        per_target.append({"label": canary["label"], "unchanged": unchanged})
    all_unchanged = all(item["unchanged"] for item in per_target) if per_target else False
    check(
        "canary.allTargetsUnchanged",
        all_unchanged,
        "targets=" + ",".join(item["label"] for item in per_target)
        + f"; unchanged={all_unchanged}",
    )


def evaluate_cleanup(results: list[dict]) -> None:
    if not results:
        check("cleanup.allSandboxesRemovedSafely", False, "no sandbox registered")
        return
    all_safe = all(item.get("safe") is True for item in results)
    all_removed = all(item.get("removed") is True for item in results)
    check(
        "cleanup.allSandboxesRemovedSafely",
        all_safe and all_removed,
        f"cases={len(results)} allSafe={all_safe} allRemoved={all_removed}",
    )
    steps = [step for item in results for step in (item.get("steps") or [])]
    check(
        "cleanup.failClosedMechanismUsed",
        ("sandbox.identityVerified" in steps)
        and ("tree.noUnexpectedReparsePoint" in steps),
        f"stepsObserved={len(steps)}",
    )


REQUIRED_CHECK_NAMES = (
    "fixture.normalSetup",
    "fixture.normalProbe",
    "fixture.probeReadOnlyConnection",
    "fixture.setupExistingTargetRejected",
    "fixture.setupParentJunctionRejected",
    "fixture.setupLeafReparseRejected",
    "fixture.setupGuardFailureNoCreate",
    "fixture.probeGuardFailureNoConnect",
    "fixture.probeSafetyFailureNoConnect",
    "cleanup.identityChangedRejected",
    "canary.allTargetsUnchanged",
    "migrationScript.nativeGuardsPresent",
    "migrationScript.failClosedCleanupReused",
    "migrationScript.outputAncestorJunctionRejected",
    "migrationScript.outsideTestRootRejected",
    "migrationScript.formalRootOutputRejected",
    "migrationScript.realMigrationRollbackTestPreserved",
    "evidence.targetPrepared",
)


def verify_required_check_names() -> None:
    present = {item["name"] for item in checks} | {item["name"] for item in skips}
    missing = [name for name in REQUIRED_CHECK_NAMES if name not in present]
    check(
        "evidence.requiredChecksPresent",
        not missing,
        "missing=" + (",".join(missing) if missing else "none"),
    )


def main() -> int:
    evidence_argument = None
    if "--evidence" in sys.argv:
        index = sys.argv.index("--evidence")
        if index + 1 >= len(sys.argv):
            print("PRECONDITION_FAILED: --evidence 缺少路径参数", file=sys.stderr)
            return 2
        evidence_argument = sys.argv[index + 1]

    if not support.TEST_ROOT.is_dir():
        print(
            f"PRECONDITION_FAILED: test root missing: {support.TEST_ROOT}",
            file=sys.stderr,
        )
        return 2
    if not MIGRATION_SCRIPT.is_file() or not FIXTURE_SCRIPT.is_file():
        print("PRECONDITION_FAILED: migration verification scripts missing", file=sys.stderr)
        return 2

    try:
        trust_result = support.guard_path("test-root", str(support.TEST_ROOT))
    except (PathGuardError, support.SupportError) as error:
        print(f"PRECONDITION_FAILED: 测试根目录信任锚验证失败：{error}", file=sys.stderr)
        return 2
    trust_identity = trust_result.get("identity") or {}
    check(
        "trustRoot.defaultRootVerified",
        trust_result.get("ok") is True
        and support.identity_complete(trust_identity),
        f"componentCount={trust_identity.get('componentCount')}",
    )

    formal_before = support.formal_root_status()

    fixture = load_module("t1_04_migration_fixture", "t1-04-migration-fixture.py")
    evidence_target = support.EvidenceTarget(evidence_argument)
    try:
        evidence_target.prepare()
        check(
            "evidence.targetPrepared",
            True,
            f"evidencePath={support.sanitize(str(evidence_target.path))}",
        )
    except (PathGuardError, support.SupportError) as error:
        check("evidence.targetPrepared", False, str(error))
        print(f"PRECONDITION_FAILED: 证据输出路径被拒绝：{error}", file=sys.stderr)
        return 2

    registry = support.PathCaseRegistry()
    cleanup_results: list[dict] = []
    error: Exception | None = None
    try:
        normal = run_fixture_normal(fixture, registry)
        run_fixture_guard_checks(fixture, registry, normal)
        run_migration_script_checks(registry)
        run_cleanup_checks(registry)
        evaluate_canaries()
    except Exception as caught:  # noqa: BLE001
        error = caught
        check(
            "harness.unexpectedError",
            False,
            f"{type(caught).__name__}: {caught}",
        )
        traceback.print_exc()
    finally:
        try:
            cleanup_results = registry.cleanup_all()
        except Exception as cleanup_error:  # noqa: BLE001
            check(
                "cleanup.registryFailure",
                False,
                f"{type(cleanup_error).__name__}: {cleanup_error}",
            )
    evaluate_cleanup(cleanup_results)
    verify_required_check_names()

    formal_after = support.formal_root_status()
    formal_changed = support.formal_root_identity_changed(formal_before, formal_after)
    if formal_changed is None:
        formal_unchanged = None
        skip(
            "formalRoot.identityUnchanged",
            "无法读取正式目录只读身份快照；证据不足，不伪造“未触碰”结论。",
        )
    else:
        formal_unchanged = not formal_changed
        check(
            "formalRoot.identityUnchanged",
            formal_unchanged,
            f"existedBefore={formal_before.get('existed')} "
            f"existedAfter={formal_after.get('existed')}",
        )

    failed = [item["name"] for item in checks if not item["pass"]]
    evidence = {
        "task": "T1-04",
        "round": "round6",
        "scope": "T104-01 migration fixture / Release migration verification native path guards",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "testRoot": "<test-root>",
        "formalRoot": {
            "path": "<formal-root>",
            "existedBefore": formal_before.get("existed"),
            "existedAfter": formal_after.get("existed"),
            "identityEvidenceAvailable": formal_unchanged is not None,
            "identityUnchanged": formal_unchanged,
            "limitation": (
                "只读目录身份快照；不构成正式目录内容未被外部进程修改的绝对证明，"
                "也不消除 TOCTOU（DEC-029 / Issue #2）"
            ),
        },
        "checks": checks,
        "failed": failed,
        "skips": skips,
        "cleanup": cleanup_results,
        "pass": not failed,
        "residualRisk": (
            "TOCTOU concurrent replacement remains deferred by DEC-029 / Issue #2"
        ),
    }

    evidence_written = False
    try:
        written_path = evidence_target.write(evidence)
        evidence_written = True
        check(
            "evidence.writeSucceeded",
            True,
            f"evidencePath={support.sanitize(str(written_path))}",
        )
    except (PathGuardError, support.SupportError) as write_error:
        check("evidence.writeSucceeded", False, str(write_error))
        print(f"MIGRATION_PATH_EVIDENCE_WRITE=FAIL: {write_error}", file=sys.stderr)

    machine_redacted = True
    serialized = json.dumps(evidence, ensure_ascii=False)
    for raw_value in (
        str(support.TEST_ROOT),
        str(support.FORMAL_ROOT),
        os.environ.get("COMPUTERNAME", ""),
        os.environ.get("USERNAME", ""),
    ):
        if raw_value and raw_value in serialized:
            machine_redacted = False
    check(
        "evidence.machineIdentifiersRedacted",
        machine_redacted,
        "rawMachineValuesPresent=False"
        if machine_redacted
        else "rawMachineValuesPresent=True",
    )

    failed = [item["name"] for item in checks if not item["pass"]]
    print(
        json.dumps(
            {
                "checks": len(checks),
                "failed": len(failed),
                "skips": len(skips),
                "cleanupCases": len(cleanup_results),
                "evidenceWritten": evidence_written,
            },
            ensure_ascii=False,
        )
    )
    if error is not None:
        return 1
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
