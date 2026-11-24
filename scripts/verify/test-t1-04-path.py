#!/usr/bin/env python3
"""T1-04 Windows 真实 Junction / 重解析点路径安全测试（T104-01 第六轮修复）。

本测试用于验证“测试脚本自身”的信任锚与 fail-closed 清理，以及 T1-04 原生路径
守卫在测试根 / UAT 根 / 数据库目录 / 证据目录被替换时的拒绝行为：

1. 正常可信测试根目录信任锚 PASS（测试根自身、全部已存在祖先、卷身份、文件 ID、
   真实最终路径，均由 Windows 原生句柄校验）；
2. 测试根目录本身被 Junction 重定向 → 拒绝；真实合成信任锚 → 通过；
3. 测试根目录祖先被 Junction 替换 → 拒绝；拒绝时不产生任何目录 / 文件；
4. UAT 根目录被替换 → 拒绝；
5. 数据库目录被替换 / 数据库文件叶子是重解析点 → 拒绝；
6. 证据目录被替换 → 拒绝；证据写入路径只能是可信 UAT 根下 `evidence` 的直接
   `.json` 子文件；
7. 清理前目录身份发生变化 / 清理时存在重解析点 → 拒绝删除（fail-closed，
   复用 T1-03 `Invoke-T103FailClosedSandboxCleanup`）；
8. 守卫执行失败 → 不创建、不连接 SQLite、不写文件、不删除；
9. 外部 Canary（Junction 目标目录）内容 / 目录结构前后完全一致；
10. 文件符号链接在缺少系统权限时显式 SKIP，不伪造 PASS。

安全边界：
- 所有测试对象均为 `D:\\WorkManager-test-data` 下的隔离目录与虚构文件；
- 绝不打开、修改、安装 trigger 到正式运行目录 `D:\\WorkManager`；正式目录仅做
  只读身份快照（不存在时记录不存在）；
- 测试根目录本身及其全部祖先在写入前必须通过信任锚；测试根目录从不被替换、
  重命名或删除（Junction 重定向场景使用测试根内的隔离合成信任锚构造）；
- 测试沙箱清理复用 fail-closed 安全清理：先删除并复验跟踪链接、扫描未预期
  重解析点、复验目录身份，全部通过后才逐条目校验递归删除；任一失败保留现场。

残余风险：检查与创建/写入之间仍存在并发路径替换窗口（TOCTOU），按 DEC-029 /
Issue #2 保持延期；本测试不宣称消除并发替换风险，只保证静态 Junction / 重解析点 /
身份替换被拒绝。

用法：
  python -X utf8 scripts/verify/test-t1-04-path.py
  python -X utf8 scripts/verify/test-t1-04-path.py \
      --evidence D:\\WorkManager-test-data\\t1-04-path-evidence-<ts>\\evidence\\t1-04-path-evidence.json

退出码：0 = 全部 PASS（允许有明确记录的 SKIP）；1 = 存在 FAIL；2 = 前置条件不满足。
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import time
import traceback
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import t1_04_path_guard as path_guard  # noqa: E402
from t1_04_path_guard import PathGuardError  # noqa: E402
import t1_04_path_test_support as support  # noqa: E402

checks: list[dict] = []
skips: list[dict] = []


def check(name: str, passed: bool, detail: str = "") -> None:
    entry = {
        "name": name,
        "pass": bool(passed),
        "detail": support.sanitize(detail),
    }
    checks.append(entry)
    suffix = f" — {entry['detail']}" if entry["detail"] else ""
    print(f"{'PASS' if passed else 'FAIL'} {name}{suffix}")


def skip(name: str, reason: str) -> None:
    skips.append({"name": name, "reason": support.sanitize(reason)})
    print(f"SKIP {name} — {support.sanitize(reason)}")


def expect_rejected(name: str, keywords: tuple[str, ...], action) -> None:
    try:
        action()
    except (PathGuardError, support.SupportError) as error:
        message = str(error)
        matched = any(keyword in message for keyword in keywords)
        check(name, matched, message[:400])
    except Exception as error:  # noqa: BLE001
        check(name, False, f"unexpected error type: {type(error).__name__}: {error}")
    else:
        check(name, False, "path guard unexpectedly accepted the path")


def expect_cleanup_rejected(name: str, path: Path, identity: dict) -> bool:
    """清理守卫必须拒绝删除；返回是否按预期拒绝且目录仍在。"""
    rejected = False
    message = ""
    try:
        support.guard_cleanup(path, identity)
    except (PathGuardError, support.SupportError) as error:
        rejected = True
        message = str(error)
    except Exception as error:  # noqa: BLE001
        message = f"unexpected error type: {type(error).__name__}: {error}"
    retained = support.path_present(path)
    matched = any(
        keyword in message
        for keyword in ("重解析点", "Junction", "身份", "fail-closed", "清理")
    )
    check(
        name,
        rejected and matched and retained,
        f"rejected={rejected} retained={retained} message={message[:300]}",
    )
    return rejected and retained


def load_module(name: str, filename: str):
    path = SCRIPT_DIR / filename
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise support.SupportError(f"cannot load module: {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# 第五轮已存在的检查名称：第六轮必须全部保留（允许 SKIP，但不允许删除/改名）。
ROUND5_CHECK_NAMES = (
    "normal.databasePathAccepted",
    "normal.evidenceDirectoryAccepted",
    "normal.evidenceFilePathAccepted",
    "junction.databaseAncestorRejected",
    "junction.databaseLeafReparseRejected",
    "symlink.databaseFileRejected",
    "junction.evidenceDirectoryRejected",
    "guard.noDatabaseConnectOnAncestorJunction",
    "guard.noDatabaseConnectOnEvidenceJunction",
    "guard.noExternalWriteOnEvidenceJunction",
)

# 第六轮必须存在的检查名称（防止关键安全测试被静默删除/跳过）。
ROUND6_REQUIRED_CHECK_NAMES = (
    "trustRoot.defaultRootVerified",
    "trustRoot.identityRecorded",
    "trustRoot.syntheticRealRootAccepted",
    "normal.uatRootTargetAccepted",
    "normal.databaseTargetAccepted",
    "normal.evidenceDirTargetAccepted",
    "junction.testRootRedirectedRejected",
    "junction.testRootRedirectedNoCreateRejected",
    "junction.testRootRedirectedNoWriteSideEffect",
    "junction.testRootAncestorRejected",
    "junction.testRootAncestorNoWriteSideEffect",
    "junction.uatRootReplacedRejected",
    "junction.databaseDirectoryReplacedRejected",
    "junction.evidenceDirReplacedRejected",
    "cleanup.identityChangedRejected",
    "cleanup.reparsePointRejected",
    "cleanup.guardFailureRefusedDelete",
    "cleanup.allSandboxesRemovedSafely",
    "cleanup.failClosedMechanismUsed",
    "cleanup.trackedLinkRemovedSafely",
    "guard.failureNoCreate",
    "guard.failureNoSqliteConnect",
    "guard.failureNoProbeConnect",
    "guard.failureNoProbeWrite",
    "canary.allTargetsUnchanged",
    "evidence.writePathStructureEnforced",
    "evidence.targetPrepared",
    "formalRoot.identityUnchanged",
    "formalRoot.guardRejectsFormalPath",
)


def verify_required_check_names() -> None:
    present = {item["name"] for item in checks} | {item["name"] for item in skips}
    missing_round5 = [name for name in ROUND5_CHECK_NAMES if name not in present]
    check(
        "evidence.round5ChecksPreserved",
        not missing_round5,
        "missing=" + (",".join(missing_round5) if missing_round5 else "none"),
    )
    missing_round6 = [name for name in ROUND6_REQUIRED_CHECK_NAMES if name not in present]
    check(
        "evidence.round6NewChecksPresent",
        not missing_round6,
        "missing=" + (",".join(missing_round6) if missing_round6 else "none"),
    )


def call_silently(function) -> int:
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        return int(function())


def make_canary(
    registry: support.PathCaseRegistry,
    label: str,
    files: dict[str, str] | None = None,
    directories: tuple[str, ...] = (),
) -> tuple[Path, dict]:
    case = registry.new_case(f"canary-{label}")
    target = case.path / "target"
    support.ensure_directory(target)
    for directory in directories:
        support.ensure_directory(target / directory)
    for relative_path, content in (files or {}).items():
        file_path = target / relative_path
        file_path.write_text(content, encoding="utf-8")
    before = support.snapshot_tree(target)
    canaries.append({"label": label, "target": target, "before": before})
    return target, before


canaries: list[dict] = []


def run_normal_checks(registry: support.PathCaseRegistry) -> dict:
    """1. 正常可信测试根目录与正常 UAT/数据库/证据目录布局。"""
    planned_path = support.TEST_ROOT / support.unique_name("normal-planned")
    planned = support.guard_path("uat-root-target", str(planned_path))
    check(
        "normal.uatRootTargetAccepted",
        planned.get("ok") is True
        and planned.get("targetExists") is False
        and planned.get("planned") is True,
        f"planned={planned.get('planned')} targetExists={planned.get('targetExists')}",
    )
    check(
        "normal.uatRootTargetNotCreatedByValidation",
        not support.path_present(planned_path),
        f"created={support.path_present(planned_path)}",
    )

    normal = registry.new_case("normal")
    check(
        "normal.uatRootCreatedAndVerified",
        support.identity_complete(normal.identity),
        f"identityDigest={support.sanitize(support.guard_path('uat-root', str(normal.path))['identity']['finalPath'])}",
    )

    database_path = normal.path / "app" / "data" / "database" / "work.db"
    support.ensure_directory(database_path.parent)
    planned_database = support.guard_path("database-target", str(database_path))
    check(
        "normal.databaseTargetAccepted",
        planned_database.get("ok") is True
        and planned_database.get("targetExists") is False,
        f"targetExists={planned_database.get('targetExists')}",
    )
    database_identity = support.create_database_file(database_path)
    check(
        "normal.databasePathAccepted",
        support.identity_complete(database_identity),
        f"databaseIdentityVerified={support.identity_complete(database_identity)}",
    )

    evidence_directory = normal.path / "evidence"
    planned_evidence_directory = support.guard_path(
        "evidence-dir-target",
        str(evidence_directory),
        uat_root=str(normal.path),
    )
    check(
        "normal.evidenceDirTargetAccepted",
        planned_evidence_directory.get("ok") is True
        and planned_evidence_directory.get("targetExists") is False,
        f"targetExists={planned_evidence_directory.get('targetExists')}",
    )
    support.ensure_directory(evidence_directory)
    evidence_directory_record = support.guard_path(
        "evidence-dir", str(evidence_directory), database_path=str(database_path)
    )
    check(
        "normal.evidenceDirectoryAccepted",
        evidence_directory_record.get("ok") is True,
        "evidenceDirectoryIdentityVerified=True",
    )
    probe_path = evidence_directory / "probe.json"
    planned_evidence_file = support.guard_path(
        "evidence-file",
        str(probe_path),
        database_path=str(database_path),
        evidence_directory=str(evidence_directory),
    )
    check(
        "normal.evidenceFilePathAccepted",
        planned_evidence_file.get("ok") is True
        and planned_evidence_file.get("targetExists") is False,
        f"targetExists={planned_evidence_file.get('targetExists')}",
    )
    probe_path.write_text('{"probe": true}', encoding="utf-8")
    written_evidence_file = support.guard_path(
        "evidence-file",
        str(probe_path),
        database_path=str(database_path),
        evidence_directory=str(evidence_directory),
    )
    check(
        "normal.evidenceFileWritten",
        written_evidence_file.get("ok") is True
        and written_evidence_file.get("targetExists") is True
        and written_evidence_file.get("identity") is not None,
        "writtenFileIdentityVerified=True",
    )
    return {"normal": normal, "database": database_path, "evidence": evidence_directory}


def run_trust_root_junction_checks(registry: support.PathCaseRegistry) -> None:
    """2/3. 测试根目录自身、祖先被 Junction 重定向：拒绝且无写入副作用。"""
    anchor = registry.new_case("trust-anchor")
    real_root = anchor.path / "real-root"
    support.ensure_directory(real_root)
    synthetic = support.guard_path("test-root", str(real_root))
    check(
        "trustRoot.syntheticRealRootAccepted",
        synthetic.get("ok") is True
        and support.identity_complete(synthetic.get("identity") or {}),
        "syntheticTrustAnchorIdentityVerified=True",
    )

    redirected_target, redirected_before = make_canary(
        registry, "test-root-redirect", {"canary.txt": "canary-root-redirect"}
    )
    fake_root = anchor.path / "fake-root"
    support.make_junction(fake_root, redirected_target)
    expect_rejected(
        "junction.testRootRedirectedRejected",
        ("重解析点", "Junction", "专用测试根目录"),
        lambda: support.guard_path("test-root", str(fake_root)),
    )
    under_fake_root = fake_root / support.unique_name("redirected-should-not-exist")
    expect_rejected(
        "junction.testRootRedirectedNoCreateRejected",
        ("重解析点", "Junction", "专用测试根目录"),
        lambda: support.guard_path("uat-root-target", str(under_fake_root)),
    )
    under_fake_created = support.path_present(under_fake_root)
    redirected_unchanged = support.snapshot_unchanged(
        redirected_before, support.snapshot_tree(redirected_target)
    )
    check(
        "junction.testRootRedirectedNoWriteSideEffect",
        (not under_fake_created) and redirected_unchanged,
        f"createdUnderJunction={under_fake_created} canaryUnchanged={redirected_unchanged}",
    )
    support.remove_junction(fake_root)

    ancestor_target, ancestor_before = make_canary(
        registry,
        "test-root-ancestor",
        {"canary.txt": "canary-root-ancestor"},
        directories=("real-root",),
    )
    ancestor_junction = anchor.path / "junction-ancestor"
    support.make_junction(ancestor_junction, ancestor_target)
    fake_through_ancestor = ancestor_junction / "real-root"
    expect_rejected(
        "junction.testRootAncestorRejected",
        ("重解析点", "Junction", "专用测试根目录"),
        lambda: support.guard_path("test-root", str(fake_through_ancestor)),
    )
    expect_rejected(
        "junction.testRootAncestorNoCreateRejected",
        ("重解析点", "Junction", "专用测试根目录"),
        lambda: support.guard_path(
            "uat-root-target",
            str(fake_through_ancestor / support.unique_name("should-not-exist")),
        ),
    )
    ancestor_unchanged = support.snapshot_unchanged(
        ancestor_before, support.snapshot_tree(ancestor_target)
    )
    check(
        "junction.testRootAncestorNoWriteSideEffect",
        ancestor_unchanged,
        f"canaryUnchanged={ancestor_unchanged}",
    )
    support.remove_junction(ancestor_junction)


def run_junction_checks(registry: support.PathCaseRegistry) -> dict:
    """4/5/6. UAT 根、数据库目录/文件、证据目录被替换：全部拒绝。"""
    result: dict = {}

    # 5a. 数据库祖先目录是 Junction：拒绝，且不向 Junction 目标写入。
    ancestor_case = registry.new_case("junction-db-ancestor")
    ancestor_target, ancestor_before = make_canary(
        registry, "db-ancestor", {"canary.txt": "canary-db-ancestor"}
    )
    app_junction = ancestor_case.path / "app"
    support.make_junction(app_junction, ancestor_target)
    ancestor_database = ancestor_case.path / "app" / "data" / "database" / "work.db"
    expect_rejected(
        "junction.databaseAncestorRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path("database-target", str(ancestor_database)),
    )
    ancestor_case.track_link(app_junction)
    result["databaseAncestorCanary"] = (ancestor_target, ancestor_before)

    # 5b. 数据库文件叶子路径是重解析点（目录 Junction）：拒绝。
    leaf_case = registry.new_case("junction-db-leaf")
    leaf_database = leaf_case.path / "app" / "data" / "database" / "work.db"
    support.ensure_directory(leaf_database.parent)
    leaf_target, leaf_before = make_canary(
        registry, "db-leaf", {"canary.txt": "canary-db-leaf"}
    )
    support.make_junction(leaf_database, leaf_target)
    expect_rejected(
        "junction.databaseLeafReparseRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path("database-target", str(leaf_database)),
    )
    expect_rejected(
        "junction.databaseLeafExistingReparseRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path("database", str(leaf_database)),
    )
    support.remove_junction(leaf_database)
    result["databaseLeafCanary"] = (leaf_target, leaf_before)

    # 5c. 文件符号链接：能创建则拒绝；缺少权限时显式 SKIP。
    symlink_case = registry.new_case("file-symlink")
    symlink_database = symlink_case.path / "app" / "data" / "database" / "work.db"
    support.ensure_directory(symlink_database.parent)
    symlink_target = symlink_case.path / "outside-target.db"
    symlink_target.write_bytes(b"outside-target-fixture")
    symlink_created, symlink_detail = try_file_symlink(
        symlink_database, symlink_target
    )
    if symlink_created:
        try:
            expect_rejected(
                "symlink.databaseFileRejected",
                ("重解析点", "Junction", "符号链接"),
                lambda: support.guard_path("database-target", str(symlink_database)),
            )
        finally:
            try:
                os.unlink(str(symlink_database))
            except OSError as error:
                skip("symlink.cleanupFailed", f"符号链接清理失败：{error}")
    else:
        skip("symlink.databaseFileRejected", symlink_detail)

    # 6a. 证据目录 Junction：拒绝，且不得向外部写入证据。
    evidence_case = registry.new_case("junction-evidence")
    evidence_database = evidence_case.path / "app" / "data" / "database" / "work.db"
    support.ensure_directory(evidence_database.parent)
    support.create_database_file(evidence_database)
    external_target, external_before = make_canary(
        registry, "external-evidence", {"canary.txt": "canary-evidence-target"}
    )
    evidence_junction = evidence_case.path / "evidence"
    support.make_junction(evidence_junction, external_target)
    expect_rejected(
        "junction.evidenceDirectoryRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path(
            "evidence-dir", str(evidence_junction), database_path=str(evidence_database)
        ),
    )
    expect_rejected(
        "junction.evidenceFileRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path(
            "evidence-file",
            str(evidence_junction / "should-not-be-written.json"),
            database_path=str(evidence_database),
            evidence_directory=str(evidence_junction),
        ),
    )
    external_file = external_target / "should-not-be-written.json"
    check(
        "junction.evidenceJunctionNoExternalWrite",
        not support.path_present(external_file),
        f"externalFileExists={support.path_present(external_file)}",
    )
    support.remove_junction(evidence_junction)
    result["evidenceJunctionCanary"] = (external_target, external_before)

    # 4. UAT 根目录被替换（自身变成 Junction）：拒绝；清理必须拒绝删除。
    replaced_case = registry.new_case("uat-root-replaced")
    replaced_target, replaced_before = make_canary(
        registry, "uat-root-replaced-target", {"canary.txt": "canary-uat-root"}
    )
    replaced_database = replaced_case.path / "app" / "data" / "database" / "work.db"
    support.replace_directory_with_junction(replaced_case.path, replaced_target)
    expect_rejected(
        "junction.uatRootReplacedRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path("database-target", str(replaced_database)),
    )
    expect_rejected(
        "junction.uatRootGuardRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path("uat-root", str(replaced_case.path)),
    )
    expect_cleanup_rejected(
        "cleanup.reparsePointRejected", replaced_case.path, replaced_case.identity
    )
    replaced_unchanged = support.snapshot_unchanged(
        replaced_before, support.snapshot_tree(replaced_target)
    )
    check(
        "junction.uatRootReplacedCanaryUnchanged",
        replaced_unchanged,
        f"canaryUnchanged={replaced_unchanged}",
    )
    support.remove_junction(replaced_case.path)
    result["uatRootReplacedCanary"] = (replaced_target, replaced_before)

    # 5d. 数据库目录被替换：拒绝。
    database_dir_case = registry.new_case("database-dir-replaced")
    database_dir = database_dir_case.path / "app" / "data" / "database"
    support.ensure_directory(database_dir)
    database_dir_target, database_dir_before = make_canary(
        registry, "database-dir-target", {"canary.txt": "canary-database-dir"}
    )
    support.replace_directory_with_junction(database_dir, database_dir_target)
    expect_rejected(
        "junction.databaseDirectoryReplacedRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path(
            "database-target", str(database_dir / "work.db")
        ),
    )
    database_dir_unchanged = support.snapshot_unchanged(
        database_dir_before, support.snapshot_tree(database_dir_target)
    )
    check(
        "junction.databaseDirectoryReplacedCanaryUnchanged",
        database_dir_unchanged,
        f"canaryUnchanged={database_dir_unchanged}",
    )
    support.remove_junction(database_dir)
    support.ensure_directory(database_dir)
    result["databaseDirectoryCanary"] = (database_dir_target, database_dir_before)

    # 6b. 证据目录被替换：拒绝。
    evidence_dir_case = registry.new_case("evidence-dir-replaced")
    evidence_dir_database = (
        evidence_dir_case.path / "app" / "data" / "database" / "work.db"
    )
    support.ensure_directory(evidence_dir_database.parent)
    support.create_database_file(evidence_dir_database)
    real_evidence_dir = evidence_dir_case.path / "evidence"
    support.ensure_directory(real_evidence_dir)
    evidence_dir_target, evidence_dir_before = make_canary(
        registry, "evidence-dir-target", {"canary.txt": "canary-evidence-dir"}
    )
    support.replace_directory_with_junction(real_evidence_dir, evidence_dir_target)
    expect_rejected(
        "junction.evidenceDirReplacedRejected",
        ("重解析点", "Junction"),
        lambda: support.guard_path(
            "evidence-dir",
            str(real_evidence_dir),
            database_path=str(evidence_dir_database),
        ),
    )
    evidence_dir_unchanged = support.snapshot_unchanged(
        evidence_dir_before, support.snapshot_tree(evidence_dir_target)
    )
    check(
        "junction.evidenceDirReplacedCanaryUnchanged",
        evidence_dir_unchanged,
        f"canaryUnchanged={evidence_dir_unchanged}",
    )
    support.remove_junction(real_evidence_dir)
    support.ensure_directory(real_evidence_dir)
    result["evidenceDirectoryCanary"] = (evidence_dir_target, evidence_dir_before)

    # 受控跟踪链接：由 fail-closed 清理删除链接本身，不触碰目标 Canary。
    tracked_case = registry.new_case("tracked-link")
    tracked_target, tracked_before = make_canary(
        registry, "tracked-link-target", {"canary.txt": "canary-tracked-link"}
    )
    tracked_link = tracked_case.path / "linked-target"
    support.make_junction(tracked_link, tracked_target)
    tracked_case.track_link(tracked_link)
    result["trackedCase"] = tracked_case
    result["trackedCanary"] = (tracked_target, tracked_before)
    return result


def run_cleanup_identity_checks(registry: support.PathCaseRegistry) -> None:
    """7. 清理前目录身份变化 / 清理守卫失败：拒绝删除。"""
    identity_case = registry.new_case("cleanup-identity-change")
    sentinel = identity_case.path / "sentinel.txt"
    sentinel.write_text("identity-change-sentinel", encoding="utf-8")
    old_identity = dict(identity_case.identity)
    # 删除并重建同一路径：卷序列号与最终路径不变，文件 ID 变化。
    sentinel.unlink()
    os.rmdir(str(identity_case.path))
    support.guard_path("uat-root-target", str(identity_case.path))
    identity_case.path.mkdir(parents=False)
    new_identity = support.guard_path("uat-root", str(identity_case.path))["identity"]
    identity_changed = (
        str(old_identity.get("fileIdHex")) != str(new_identity.get("fileIdHex"))
    )
    if identity_changed:
        expect_cleanup_rejected(
            "cleanup.identityChangedRejected", identity_case.path, old_identity
        )
        check("cleanup.identityChangedDetected", True, "fileIdChanged=True")
    else:
        check(
            "cleanup.identityChangedDetected",
            False,
            "文件 ID 未变化，无法构造身份变化场景",
        )
    # 以重新验证后的身份清理，证明身份确认后可安全删除。
    identity_case.identity = new_identity

    guard_failure_case = registry.new_case("cleanup-guard-failure")
    guard_failure_file = guard_failure_case.path / "sentinel.txt"
    guard_failure_file.write_text("cleanup-guard-failure-sentinel", encoding="utf-8")
    original_cleanup_script = path_guard.CLEANUP_SCRIPT
    path_guard.CLEANUP_SCRIPT = SCRIPT_DIR / "missing-cleanup-guard-for-test.ps1"
    refused = False
    try:
        support.guard_cleanup(guard_failure_case.path, guard_failure_case.identity)
    except (PathGuardError, support.SupportError) as error:
        refused = "守卫" in str(error) or "不存在" in str(error) or "fail" in str(error).lower()
    except Exception as error:  # noqa: BLE001
        refused = False
        check("cleanup.guardFailureErrorType", False, type(error).__name__)
    finally:
        path_guard.CLEANUP_SCRIPT = original_cleanup_script
    retained = (
        support.path_present(guard_failure_case.path)
        and guard_failure_file.is_file()
        and guard_failure_file.read_text(encoding="utf-8")
        == "cleanup-guard-failure-sentinel"
    )
    check(
        "cleanup.guardFailureRefusedDelete",
        refused and retained,
        f"refused={refused} retained={retained}",
    )


def run_guard_failure_checks(normal: dict) -> None:
    """8. 守卫进程执行失败：不创建、不连接、不写入、不删除。"""
    normal_database: Path = normal["database"]
    normal_evidence: Path = normal["evidence"]
    original_guard_script = path_guard.GUARD_SCRIPT
    path_guard.GUARD_SCRIPT = SCRIPT_DIR / "missing-path-guard-for-test.ps1"
    try:
        planned_path = support.TEST_ROOT / support.unique_name("guard-failure")
        no_create = False
        try:
            support.guard_path("uat-root-target", str(planned_path))
        except (PathGuardError, support.SupportError):
            no_create = True
        check(
            "guard.failureNoCreate",
            no_create and not support.path_present(planned_path),
            f"rejected={no_create} created={support.path_present(planned_path)}",
        )

        control = load_module("control_t1_04_fault", "control-t1-04-fault.py")
        connect_called = {"value": False}

        def forbidden_connect(*_args, **_kwargs):
            connect_called["value"] = True
            raise AssertionError("sqlite3.connect must not be called")

        control.sqlite3.connect = forbidden_connect
        old_argv = sys.argv
        try:
            sys.argv = ["control-t1-04-fault.py", "status", str(normal_database)]
            exit_code = call_silently(control.main)
        finally:
            sys.argv = old_argv
        check(
            "guard.failureNoSqliteConnect",
            exit_code == 3 and connect_called["value"] is False,
            f"exit={exit_code} connectCalled={connect_called['value']}",
        )

        probe = load_module("probe_t1_04_db", "probe-t1-04-db.py")
        connect_called["value"] = False
        probe.sqlite3.connect = forbidden_connect
        probe_output = normal_evidence / "probe-after-guard-failure.json"
        old_argv = sys.argv
        try:
            sys.argv = [
                "probe-t1-04-db.py",
                str(normal_database),
                "guard-failure",
                str(probe_output),
                "--evidence-dir",
                str(normal_evidence),
            ]
            exit_code = call_silently(probe.main)
        finally:
            sys.argv = old_argv
        check(
            "guard.failureNoProbeConnect",
            exit_code == 3 and connect_called["value"] is False,
            f"exit={exit_code} connectCalled={connect_called['value']}",
        )
        check(
            "guard.failureNoProbeWrite",
            not support.path_present(probe_output),
            f"probeWritten={support.path_present(probe_output)}",
        )
    finally:
        path_guard.GUARD_SCRIPT = original_guard_script


def run_guard_no_connect_checks(normal: dict) -> None:
    """既有安全检查：Junction 场景下 Python 侧不得连接 SQLite / 写外部文件。"""
    junction_case = registry_for_no_connect.new_case("no-connect")
    junction_database = junction_case.path / "app" / "data" / "database" / "work.db"
    support.ensure_directory(junction_database.parent)
    support.create_database_file(junction_database)
    target, _before = make_canary(
        registry_for_no_connect, "no-connect-target", {"canary.txt": "no-connect"}
    )
    evidence_junction = junction_case.path / "evidence"
    support.make_junction(evidence_junction, target)

    control = load_module("control_t1_04_fault", "control-t1-04-fault.py")
    connect_called = {"value": False}

    def forbidden_connect(*_args, **_kwargs):
        connect_called["value"] = True
        raise AssertionError("sqlite3.connect must not be called")

    control.sqlite3.connect = forbidden_connect
    old_argv = sys.argv
    try:
        # 数据库路径本身安全，但证据目录 Junction 不影响 control 的数据库守卫；
        # 因此用祖先 Junction 数据库路径单独验证 control 的 fail-closed。
        ancestor_case = registry_for_no_connect.new_case("no-connect-ancestor")
        ancestor_db = ancestor_case.path / "app" / "data" / "database" / "work.db"
        support.ensure_directory(ancestor_db.parent)
        support.create_database_file(ancestor_db)
        ancestor_target, _ancestor_before = make_canary(
            registry_for_no_connect,
            "no-connect-ancestor-target",
            {"canary.txt": "no-connect-ancestor"},
        )
        ancestor_link = ancestor_case.path / "app-link"
        support.make_junction(ancestor_link, ancestor_target)
        ancestor_case.track_link(ancestor_link)
        junction_db_path = (
            ancestor_case.path / "app-link" / "data" / "database" / "work.db"
        )
        sys.argv = ["control-t1-04-fault.py", "status", str(junction_db_path)]
        exit_code = call_silently(control.main)
    finally:
        sys.argv = old_argv
    check(
        "guard.noDatabaseConnectOnAncestorJunction",
        exit_code == 3 and connect_called["value"] is False,
        f"exit={exit_code} connectCalled={connect_called['value']}",
    )

    probe = load_module("probe_t1_04_db", "probe-t1-04-db.py")
    connect_called["value"] = False
    probe.sqlite3.connect = forbidden_connect
    external_file = target / "should-not-be-written.json"
    old_argv = sys.argv
    try:
        sys.argv = [
            "probe-t1-04-db.py",
            str(junction_database),
            "junction-test",
            str(evidence_junction / "should-not-be-written.json"),
            "--evidence-dir",
            str(evidence_junction),
        ]
        exit_code = call_silently(probe.main)
    finally:
        sys.argv = old_argv
    check(
        "guard.noDatabaseConnectOnEvidenceJunction",
        exit_code == 3 and connect_called["value"] is False,
        f"exit={exit_code} connectCalled={connect_called['value']}",
    )
    check(
        "guard.noExternalWriteOnEvidenceJunction",
        not support.path_present(external_file),
        f"externalFileExists={support.path_present(external_file)}",
    )
    support.remove_junction(evidence_junction)
    support.remove_junction(ancestor_link)


def run_evidence_boundary_checks(normal: dict) -> None:
    """证据写入路径结构约束：只能是可信 UAT 根下 evidence 的直接 .json 子文件。"""
    normal_evidence: Path = normal["evidence"]
    valid, invalid = [], []

    def reject_argument(raw: str) -> None:
        try:
            support.validate_evidence_argument(raw)
        except support.SupportError:
            invalid.append(raw)
        else:
            valid.append(raw)

    outside_root = str(Path(r"C:\Temp") / "evidence" / "evil.json")
    reject_argument(outside_root)
    reject_argument(str(Path(str(normal["normal"].path)) / "not-evidence" / "x.json"))
    reject_argument(str(normal_evidence / "sub" / "x.json"))
    reject_argument(str(normal_evidence / "x.txt"))
    reject_argument("relative/evidence/x.json")
    check(
        "evidence.writePathStructureEnforced",
        len(valid) == 0 and len(invalid) == 5,
        f"acceptedInvalid={len(valid)} rejectedInvalid={len(invalid)}",
    )

    expect_rejected(
        "evidence.writeRejectsSubdirectoryFile",
        ("直接子文件", "证据目录"),
        lambda: support.guard_path(
            "evidence-file",
            str(normal_evidence / "sub" / "x.json"),
            database_path=str(normal["database"]),
            evidence_directory=str(normal_evidence),
        ),
    )
    expect_rejected(
        "evidence.writeRejectsNonJsonFile",
        (".json", "扩展名"),
        lambda: support.guard_path(
            "evidence-file",
            str(normal_evidence / "evidence.txt"),
            database_path=str(normal["database"]),
            evidence_directory=str(normal_evidence),
        ),
    )
    check(
        "evidence.writeRejectsOutsideUat",
        support.path_present(Path(str(normal["normal"].path)) / "not-evidence")
        is False,
        "outsideUatCreated=False",
    )


def try_file_symlink(link: Path, target: Path) -> tuple[bool, str]:
    completed = subprocess_run_mklink(link, target)
    if completed.returncode == 0:
        return True, "file symlink created with cmd mklink"
    return (
        False,
        "file symlink unavailable (mklink exit="
        f"{completed.returncode}; SeCreateSymbolicLinkPrivilege/developer mode required)",
    )


def subprocess_run_mklink(link: Path, target: Path):
    import subprocess

    return subprocess.run(
        ["cmd", "/c", "mklink", str(link), str(target)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )


registry_for_no_connect: support.PathCaseRegistry = None  # type: ignore[assignment]


def run_suites(registry: support.PathCaseRegistry) -> dict:
    normal = run_normal_checks(registry)
    run_trust_root_junction_checks(registry)
    run_junction_checks(registry)
    run_cleanup_identity_checks(registry)
    run_guard_failure_checks(normal)
    run_guard_no_connect_checks(normal)
    run_evidence_boundary_checks(normal)
    return normal


def evaluate_canaries() -> None:
    per_target = []
    for canary in canaries:
        after = support.snapshot_tree(canary["target"])
        unchanged = support.snapshot_unchanged(canary["before"], after)
        per_target.append({"label": canary["label"], "unchanged": unchanged})
    all_unchanged = all(item["unchanged"] for item in per_target) if per_target else False
    check(
        "canary.allTargetsUnchanged",
        all_unchanged,
        "targets=" + ",".join(item["label"] for item in per_target) + f"; unchanged={all_unchanged}",
    )


def evaluate_cleanup(cleanup_results: list[dict]) -> None:
    if not cleanup_results:
        check("cleanup.allSandboxesRemovedSafely", False, "no sandbox was registered")
        return
    all_safe = all(item.get("safe") is True for item in cleanup_results)
    all_removed = all(item.get("removed") is True for item in cleanup_results)
    check(
        "cleanup.allSandboxesRemovedSafely",
        all_safe and all_removed,
        f"cases={len(cleanup_results)} allSafe={all_safe} allRemoved={all_removed}",
    )
    steps = [
        step
        for item in cleanup_results
        for step in (item.get("steps") or [])
    ]
    check(
        "cleanup.failClosedMechanismUsed",
        ("sandbox.identityVerified" in steps)
        and ("tree.noUnexpectedReparsePoint" in steps)
        and ("sandbox.identityReVerified" in steps),
        f"stepsObserved={len(steps)}",
    )
    tracked_entries = [
        item
        for item in cleanup_results
        if item.get("label") == "tracked-link"
    ]
    tracked_ok = bool(
        tracked_entries
        and tracked_entries[0].get("safe") is True
        and "link.removed" in (tracked_entries[0].get("steps") or [])
    )
    check(
        "cleanup.trackedLinkRemovedSafely",
        tracked_ok,
        f"trackedLinkEntry={len(tracked_entries)}",
    )
    residue = registry_for_no_connect.residue_paths() if registry_for_no_connect else []
    check(
        "cleanup.noResidueUnderTestRoot",
        len(residue) == 0,
        f"residueCount={len(residue)}",
    )


def main() -> int:
    global registry_for_no_connect
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

    try:
        trust_result = support.guard_path("test-root", str(support.TEST_ROOT))
    except (PathGuardError, support.SupportError) as error:
        print(
            f"PRECONDITION_FAILED: 测试根目录信任锚验证失败：{error}",
            file=sys.stderr,
        )
        print("T1_04_PATH_TRUST_ANCHOR=FAIL", file=sys.stderr)
        return 2

    trust_identity = trust_result.get("identity") or {}
    check("trustRoot.defaultRootVerified", trust_result.get("ok") is True)
    check(
        "trustRoot.identityRecorded",
        support.identity_complete(trust_identity)
        and int(trust_identity.get("componentCount") or 0) >= 1,
        f"componentCount={trust_identity.get('componentCount')}",
    )
    print(
        "T1_04_PATH_TRUST_ANCHOR=PASS "
        f"components={trust_identity.get('componentCount')} "
        "volumeIdentity=verified finalPath=verified"
    )

    formal_before = support.formal_root_status()
    expect_rejected(
        "formalRoot.guardRejectsFormalPath",
        ("专用测试根目录", "正式应用目录"),
        lambda: support.guard_path("uat-root-target", str(support.FORMAL_ROOT)),
    )

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
    registry_for_no_connect = registry
    cleanup_results: list[dict] = []
    error: Exception | None = None
    try:
        run_suites(registry)
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

    formal_after = support.formal_root_status()
    formal_changed = support.formal_root_identity_changed(formal_before, formal_after)
    if formal_changed is None:
        formal_unchanged = None
        skip(
            "formalRoot.identityUnchanged",
            "无法读取正式目录只读身份快照；无法证明正式目录是否被触碰，"
            "证据不足，不伪造“未触碰”结论。",
        )
    else:
        formal_unchanged = not formal_changed
        check(
            "formalRoot.identityUnchanged",
            formal_unchanged,
            f"existedBefore={formal_before.get('existed')} "
            f"existedAfter={formal_after.get('existed')} unchanged={formal_unchanged}",
        )
    verify_required_check_names()

    failed = [item["name"] for item in checks if not item["pass"]]
    evidence = {
        "task": "T1-04",
        "round": "round6",
        "scope": "T104-01 Windows real Junction / reparse-point path security",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "testRoot": "<test-root>",
        "formalRoot": {
            "path": "<formal-root>",
            "existedBefore": formal_before.get("existed"),
            "existedAfter": formal_after.get("existed"),
            "identityBeforeDigest": support.sanitize(
                str(formal_before.get("identityDigest", ""))
            ),
            "identityAfterDigest": support.sanitize(
                str(formal_after.get("identityDigest", ""))
            ),
            "identityEvidenceAvailable": formal_unchanged is not None,
            "identityUnchanged": formal_unchanged,
            "guardRejectedFormalPath": next(
                (
                    item["pass"]
                    for item in checks
                    if item["name"] == "formalRoot.guardRejectsFormalPath"
                ),
                False,
            ),
            "limitation": (
                "只读目录身份快照 + 守卫拒绝正式路径的证据；不构成正式目录内容未被"
                "外部进程修改的绝对证明，也不消除 TOCTOU（DEC-029 / Issue #2）"
            ),
        },
        "trustAnchor": {
            "verified": True,
            "componentCount": int(trust_identity.get("componentCount") or 0),
            "identityDigest": support.sanitize(
                str(trust_identity.get("identityDigest", ""))
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
        print(f"PATH_GUARD_EVIDENCE_WRITE=FAIL: {write_error}", file=sys.stderr)

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
