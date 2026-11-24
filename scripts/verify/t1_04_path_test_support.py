#!/usr/bin/env python3
"""T1-04 路径安全专项测试支持代码（第六轮 T104-01 修复）。

本模块只被 `test-t1-04-path.py` / `test-t1-04-migration-path.py` 的测试入口使用，
不参与产品代码、不参与 Release 运行路径。所有安全判断都委托给
`t1_04_path_guard.py`（进而委托给 Windows 原生路径守卫），这里不重新实现
Python 字符串前缀判断。

安全边界：
- 测试根目录固定为 D:\\WorkManager-test-data，正式目录固定为 D:\\WorkManager；
- 信任锚验证通过之前，不创建任何目录 / 文件 / Junction；
- 所有目录创建前后都通过 `uat-root-target` / `uat-root` 原生守卫复验身份；
- 所有 Junction 使用真实 `mklink /J` 创建，且只删除链接本身（不递归删除目标）；
- 测试沙箱清理复用 T1-03 fail-closed 安全清理（`guard-t1-04-cleanup.ps1`），
  清理前比对卷序列号 + 文件 ID，身份变化 / 重解析点 / 守卫失败时拒绝删除；
- 证据文件只能是可信 UAT 根目录下 `evidence` 目录的直接 `.json` 子文件，
  写入前经原生守卫验证。

残余风险（DEC-029 / Issue #2）：检查与创建/写入之间仍存在并发路径替换窗口，
本模块不宣称消除 TOCTOU；它只保证静态 Junction / 重解析点 / 身份替换被
fail-closed 拒绝。
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

import t1_04_path_guard as path_guard
from t1_04_path_guard import PathGuardError

TEST_ROOT = Path(r"D:\WorkManager-test-data")
FORMAL_ROOT = Path(r"D:\WorkManager")
CASE_PREFIX = "t1-04-path-test-"
EVIDENCE_UAT_PREFIX = "t1-04-path-evidence-"
_MKLINK = "cmd"
_JSON_ENCODING = "utf-8"


class SupportError(RuntimeError):
    """测试支持代码无法安全执行；调用方必须 fail-closed。"""


class EvidenceWriteError(SupportError):
    """证据文件写入失败；调用方必须记录真实失败状态。"""


def unique_name(label: str) -> str:
    return f"{CASE_PREFIX}{label}-{os.getpid()}-{int(time.time() * 1000)}"


def sanitize(text: str) -> str:
    """移除证据中的机器专属路径；证据入库前必须脱敏。"""
    if not isinstance(text, str):
        text = str(text)
    replacements = [
        (str(TEST_ROOT), "<test-root>"),
        (str(FORMAL_ROOT), "<formal-root>"),
        (str(Path(__file__).resolve().parent.parent.parent), "<repo-root>"),
    ]
    sanitized = text
    for value, placeholder in replacements:
        if not value:
            continue
        sanitized = sanitized.replace(value, placeholder)
    computer_name = os.environ.get("COMPUTERNAME")
    if computer_name:
        sanitized = sanitized.replace(computer_name, "<machine>")
    user_name = os.environ.get("USERNAME")
    if user_name:
        sanitized = sanitized.replace(user_name, "<user>")
    return sanitized


def path_present(path: Path) -> bool:
    """判断路径是否存在（包含不存在的重解析点，避免 Path.exists() 跟随失败）。"""
    return os.path.lexists(str(path)) or path.exists()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_tree(root: Path) -> dict:
    """对目录树做只读快照（相对路径 + 文件哈希），用于 Canary 前后比较。"""
    if not path_present(root):
        return {"exists": False, "files": {}, "dirs": []}
    files: dict[str, dict] = {}
    dirs: list[str] = []
    base = str(root)
    for directory, dirnames, filenames in os.walk(base, followlinks=False):
        relative_directory = os.path.relpath(directory, base)
        dirs.append("." if relative_directory == "." else relative_directory.replace("\\", "/"))
        for name in filenames:
            full_path = Path(directory) / name
            relative_path = os.path.relpath(str(full_path), base).replace("\\", "/")
            try:
                stat_result = full_path.stat()
                files[relative_path] = {
                    "size": stat_result.st_size,
                    "sha256": _sha256(full_path),
                }
            except OSError as error:
                files[relative_path] = {"error": type(error).__name__}
        for name in list(dirnames):
            # 不跟随重解析点；只记录目录名。
            if os.path.islink(os.path.join(directory, name)) or os.path.isjunction(
                os.path.join(directory, name)
            ):
                dirnames.remove(name)
    return {"exists": True, "files": files, "dirs": sorted(dirs)}


def diff_snapshot(before: dict, after: dict) -> dict:
    if not before.get("exists") or not after.get("exists"):
        return {
            "existsChanged": before.get("exists") != after.get("exists"),
            "added": [],
            "removed": [],
            "changed": [],
            "dirsChanged": [],
        }
    before_files = before["files"]
    after_files = after["files"]
    added = sorted(set(after_files) - set(before_files))
    removed = sorted(set(before_files) - set(after_files))
    changed = sorted(
        name
        for name in set(before_files) & set(after_files)
        if before_files[name] != after_files[name]
    )
    return {
        "existsChanged": False,
        "added": added,
        "removed": removed,
        "changed": changed,
        "dirsChanged": sorted(set(before["dirs"]) ^ set(after["dirs"])),
    }


def snapshot_unchanged(before: dict, after: dict) -> bool:
    diff = diff_snapshot(before, after)
    return not any(
        diff[key]
        for key in ("existsChanged", "added", "removed", "changed", "dirsChanged")
    )


def guard_path(kind: str, path, **kwargs) -> dict:
    """调用原生路径守卫；PathGuardError 原样抛出，由测试判定。"""
    return path_guard.assert_guarded_path(kind, path, **kwargs)


def guard_cleanup(path, identity: dict, tracked_links=()) -> dict:
    return path_guard.assert_guarded_cleanup(
        path, identity, tracked_links=tracked_links
    )


def identity_paths(identity: dict) -> dict:
    return {
        "path": sanitize(str(identity.get("path", ""))),
        "finalPath": sanitize(str(identity.get("finalPath", ""))),
        "volumeSerialNumber": str(identity.get("volumeSerialNumber", "")),
        "fileIdHex": str(identity.get("fileIdHex", "")),
    }


def identity_complete(identity: dict) -> bool:
    return bool(
        str(identity.get("volumeSerialNumber", "")).strip()
        and str(identity.get("fileIdHex", "")).strip()
        and str(identity.get("finalPath", "")).strip()
    )


def ensure_directory(path: Path) -> dict:
    """在原生守卫下创建目录：先验证目标路径，再创建，再复验实际身份。"""
    path = Path(path)
    guard_path("uat-root-target", str(path))
    path.mkdir(parents=True)
    result = guard_path("uat-root", str(path))
    identity = result.get("identity")
    if not isinstance(identity, dict) or not identity_complete(identity):
        raise SupportError(f"目录创建后无法确认身份：{sanitize(str(path))}")
    return identity


def create_case_root(label: str) -> Path:
    path = TEST_ROOT / unique_name(label)
    guard_path("uat-root-target", str(path))
    path.mkdir(parents=False)
    result = guard_path("uat-root", str(path))
    identity = result.get("identity")
    if not isinstance(identity, dict) or not identity_complete(identity):
        raise SupportError(f"UAT 根目录创建后无法确认身份：{sanitize(str(path))}")
    return path


def create_database_file(
    path: Path, content: bytes = b"not-a-real-database-but-safe-test-fixture"
) -> dict:
    """在原生守卫下独占创建数据库目标文件，创建后再次验证文件身份。"""
    path = Path(path)
    guard_path("database-target", str(path))
    try:
        with open(path, "xb") as handle:
            handle.write(content)
    except FileExistsError as error:
        raise SupportError(f"数据库目标文件已存在，拒绝覆盖：{sanitize(str(path))}") from error
    result = guard_path("database", str(path))
    identity = result.get("identity")
    if not isinstance(identity, dict) or not identity_complete(identity):
        raise SupportError(f"数据库文件创建后无法确认身份：{sanitize(str(path))}")
    return identity


def make_junction(link: Path, target: Path) -> None:
    """创建真实 Windows Junction；目标目录不存在时先创建（由调用方保证父路径已受控）。"""
    link = Path(link)
    target = Path(target)
    target.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [_MKLINK, "/c", "mklink", "/J", str(link), str(target)],
        capture_output=True,
        text=True,
        encoding=_JSON_ENCODING,
        errors="replace",
        check=False,
    )
    if completed.returncode != 0:
        raise SupportError(
            "创建 Junction 失败："
            f"{sanitize(str(link))} -> {sanitize(str(target))}；"
            f"exit={completed.returncode}；输出={completed.stdout} {completed.stderr}"
        )
    if not os.path.isjunction(str(link)):
        raise SupportError(f"mklink /J 声称成功但目标不是 Junction：{sanitize(str(link))}")


def remove_junction(link: Path) -> None:
    """只删除 Junction 链接本身（rmdir 不递归删除链接目标）。"""
    link = Path(link)
    if not path_present(link):
        return
    subprocess.run(
        [_MKLINK, "/c", "rmdir", str(link)],
        capture_output=True,
        text=True,
        encoding=_JSON_ENCODING,
        errors="replace",
        check=False,
    )
    if path_present(link):
        raise SupportError(f"Junction 链接删除后仍然存在：{sanitize(str(link))}")


def replace_directory_with_junction(path: Path, target: Path) -> None:
    """删除已清空的普通目录并在同一路径创建 Junction（仅用于故障注入测试）。"""
    path = Path(path)
    if path_present(path):
        try:
            os.rmdir(str(path))
        except OSError as error:
            raise SupportError(
                f"故障注入目录不是空目录，拒绝替换：{sanitize(str(path))}；{error}"
            ) from error
    make_junction(path, target)


def replace_junction_with_empty_directory(path: Path) -> None:
    remove_junction(path)
    guard_path("uat-root-target", str(path))
    path.mkdir(parents=False)
    guard_path("uat-root", str(path))


class ManagedCase:
    """一个受管理的测试 UAT 沙箱：记录身份与跟踪链接，供 fail-closed 清理。"""

    def __init__(self, label: str, path: Path, identity: dict):
        self.label = label
        self.path = path
        self.identity = identity
        self.tracked_links: list[str] = []

    def track_link(self, link: Path) -> None:
        self.tracked_links.append(str(link))


class PathCaseRegistry:
    """测试沙箱注册表：只登记本测试创建、且已通过原生守卫确认身份的目录。"""

    def __init__(self) -> None:
        self.cases: list[ManagedCase] = []

    def new_case(self, label: str) -> ManagedCase:
        path = create_case_root(label)
        identity = guard_path("uat-root", str(path))["identity"]
        case = ManagedCase(label, path, identity)
        self.cases.append(case)
        return case

    def register_existing(self, label: str, path: Path) -> ManagedCase:
        identity = guard_path("uat-root", str(path))["identity"]
        case = ManagedCase(label, Path(path), identity)
        self.cases.append(case)
        return case

    def cleanup_all(self) -> list[dict]:
        """按创建逆序执行 fail-closed 清理；失败时保留现场并记录，不强制删除。"""
        results: list[dict] = []
        for case in reversed(self.cases):
            entry = {
                "label": case.label,
                "path": sanitize(str(case.path)),
                "removed": False,
                "safe": False,
                "stopCode": "",
                "stopReason": "",
                "trackedLinkCount": len(case.tracked_links),
                "steps": [],
                "error": "",
            }
            if not path_present(case.path):
                entry["removed"] = True
                entry["safe"] = True
                entry["stopCode"] = "alreadyAbsent"
                results.append(entry)
                continue
            try:
                cleanup_result = guard_cleanup(
                    case.path, case.identity, tracked_links=case.tracked_links
                )
            except PathGuardError as error:
                entry["error"] = sanitize(str(error))
                if path_present(case.path):
                    entry["safe"] = False
                results.append(entry)
                continue
            entry["safe"] = cleanup_result.get("safe") is True
            entry["stopCode"] = str(cleanup_result.get("stopCode", ""))
            entry["stopReason"] = sanitize(str(cleanup_result.get("stopReason", "")))
            entry["steps"] = list(cleanup_result.get("steps") or [])
            entry["removed"] = not path_present(case.path)
            results.append(entry)
        return results

    def residue_paths(self) -> list[str]:
        return [sanitize(str(case.path)) for case in self.cases if path_present(case.path)]


def _normalize(path: Path) -> str:
    return os.path.normpath(str(path))


def validate_evidence_argument(raw_path: str | None) -> tuple[Path, Path, Path]:
    """校验 --evidence 路径结构：<UAT根>/evidence/<file>.json 的直接子文件。"""
    if raw_path is None or not str(raw_path).strip():
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        uat_root = TEST_ROOT / f"{EVIDENCE_UAT_PREFIX}{os.getpid()}-{timestamp}"
        evidence_dir = uat_root / "evidence"
        return uat_root, evidence_dir, evidence_dir / "t1-04-path-evidence.json"

    requested = Path(str(raw_path))
    if not requested.is_absolute():
        raise SupportError("--evidence 必须是绝对路径，且位于专用测试根目录下的 UAT 证据目录中。")
    normalized = _normalize(requested)
    test_root_text = _normalize(TEST_ROOT)
    if not normalized.lower().startswith(test_root_text.lower() + os.sep):
        raise SupportError(
            "安全拒绝：--evidence 必须位于专用测试根目录 D:\\WorkManager-test-data 下。"
        )
    relative = os.path.relpath(normalized, test_root_text)
    parts = relative.split(os.sep)
    if len(parts) != 3:
        raise SupportError(
            "安全拒绝：--evidence 只能是 <UAT根>\\evidence\\<file>.json 的直接子文件。"
        )
    uat_root = TEST_ROOT / parts[0]
    if parts[1].lower() != "evidence":
        raise SupportError("安全拒绝：证据目录必须是 UAT 根目录下直接名为 evidence 的目录。")
    evidence_file = Path(normalized)
    if evidence_file.suffix.lower() != ".json":
        raise SupportError("安全拒绝：证据文件扩展名必须为 .json。")
    if not evidence_file.parent.name:
        raise SupportError("安全拒绝：证据文件必须直接位于 evidence 目录下。")
    return uat_root, evidence_file.parent, evidence_file


class EvidenceTarget:
    """受原生守卫约束的证据输出位置：<UAT根>/evidence/<file>.json。"""

    def __init__(self, raw_path: str | None):
        self.uat_root, self.evidence_dir, self.path = validate_evidence_argument(raw_path)

    def prepare(self) -> None:
        # 先在信任锚已通过的前提下验证并创建 UAT 根目录，再验证/创建 evidence 目录。
        guard_path("uat-root-target", str(self.uat_root))
        self.uat_root.mkdir(parents=False, exist_ok=True)
        guard_path("uat-root", str(self.uat_root))
        guard_path(
            "evidence-dir-target",
            str(self.evidence_dir),
            uat_root=str(self.uat_root),
        )
        self.evidence_dir.mkdir(parents=False, exist_ok=True)
        guard_path("uat-root", str(self.evidence_dir))

    def write(self, payload: dict) -> Path:
        content = json.dumps(payload, ensure_ascii=False, indent=2)
        # 写入前验证证据文件边界（缺失文件也验证父目录与最终路径）。
        guard_path(
            "evidence-file",
            str(self.path),
            uat_root=str(self.uat_root),
            evidence_directory=str(self.evidence_dir),
        )
        try:
            self.path.write_text(content, encoding=_JSON_ENCODING)
        except OSError as error:
            raise EvidenceWriteError(
                f"证据文件写入失败：{sanitize(str(self.path))}；原因：{error}"
            ) from error
        # 写入后再次验证实际文件身份（普通文件、非重解析点、最终路径一致）。
        guard_path(
            "evidence-file",
            str(self.path),
            uat_root=str(self.uat_root),
            evidence_directory=str(self.evidence_dir),
        )
        return self.path


def formal_root_status() -> dict:
    """只读获取正式目录指纹（不写入）；用于证明前后身份未变化。

    无法读取时返回 available=False（证据不足，不得伪造“未触碰”结论）。
    """
    status = path_guard.get_formal_root_status()
    available = status.get("ok") is True
    identity = status.get("identity") or {}
    status["available"] = available
    status["existed"] = bool(status.get("existed")) if available else None
    status["identityDigest"] = (
        str(identity.get("identityDigest") or "") if available else ""
    )
    for key in ("path", "finalPath"):
        if status.get(key):
            status[key] = sanitize(str(status[key]))
        elif key in identity and identity.get(key):
            status[key] = sanitize(str(identity[key]))
    if not available:
        status["error"] = sanitize(
            str(status.get("error") or status.get("message") or "无法读取正式目录身份")
        )
    return status


def formal_root_identity_changed(before: dict, after: dict) -> bool | None:
    """返回 True/False 表示能否确认身份变化；None 表示证据不足（无法读取）。"""
    if not before.get("available") or not after.get("available"):
        return None
    if bool(before.get("existed")) != bool(after.get("existed")):
        return True
    return str(before.get("identityDigest", "")) != str(
        after.get("identityDigest", "")
    )
