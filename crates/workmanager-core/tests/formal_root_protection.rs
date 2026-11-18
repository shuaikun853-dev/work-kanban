//! 审计 R2-02 专项测试：Debug/Test 正式目录保护的**真实最终路径**校验。
//!
//! 背景：修复前 Debug/Test 只用输入字符串比较 `is_same_or_child(data_root, D:\WorkManager)`。
//! 同卷 Junction 别名（例如 `D:\WorkManager-test-data\alias` → `D:\WorkManager`）可以绕过
//! 字符串检查。修复后必须：
//! - 展开 Junction/符号链接后比较真实最终路径；
//! - 在创建任何目录、写探针、初始化锁或数据库**之前**拒绝；
//! - Release 的 EXE 同级便携路径规则保持不变。
//!
//! 测试数据边界（不触碰真实 `D:\WorkManager`）：
//! - 用 `PortablePaths::resolve_with_protected_roots` 把受保护根目录注入为
//!   `%WORKMANAGER_TEST_BASE_DIR%\<用例>\formal-sim\WorkManager` 模拟正式目录；
//! - 真实 `D:\WorkManager` 全程不创建、不修改、不删除；用例只创建/删除自己的 Junction
//!   与测试夹具。

#![cfg(windows)]

mod support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use support::TestDir;
use workmanager_core::{Database, FORMAL_RELEASE_ROOT, PortablePaths, RuntimeMode};

/// 真实正式运行目录的状态快照（只读检查，绝不创建/修改）。
struct FormalRootSnapshot {
    existed: bool,
    entries: usize,
}

impl FormalRootSnapshot {
    fn capture() -> Self {
        let path = Path::new(FORMAL_RELEASE_ROOT);
        let existed = fs::symlink_metadata(path).is_ok();
        let entries = if existed {
            fs::read_dir(path)
                .map(|entries| entries.flatten().count())
                .unwrap_or(0)
        } else {
            0
        };
        Self { existed, entries }
    }

    fn assert_unchanged(&self, stage: &str) {
        let after = Self::capture();
        assert_eq!(
            after.existed, self.existed,
            "{stage}：测试不得创建或删除真实正式目录 {FORMAL_RELEASE_ROOT}"
        );
        assert_eq!(
            after.entries, self.entries,
            "{stage}：测试不得修改真实正式目录 {FORMAL_RELEASE_ROOT} 的内容"
        );
    }
}

/// 用 `cmd /c mklink /J` 创建目录 Junction（Junction 不需要管理员权限）。
fn create_junction(link: &Path, target: &Path) -> Result<(), String> {
    if fs::symlink_metadata(link).is_ok() {
        return Err(format!("Junction 链接路径已存在：{}", link.display()));
    }
    let status = Command::new("cmd")
        .args(["/c", "mklink", "/J"])
        .arg(link)
        .arg(target)
        .status()
        .map_err(|error| format!("启动 cmd mklink 失败：{error}"))?;
    if !status.success() {
        return Err(format!(
            "mklink /J 失败（退出码 {status}）：{} -> {}",
            link.display(),
            target.display()
        ));
    }
    fs::symlink_metadata(link).map_err(|error| format!("Junction 创建后不可见：{error}"))?;
    Ok(())
}

/// 只删除 Junction 链接本身（`fs::remove_dir` 使用 RemoveDirectoryW，不会进入目标目录）。
fn remove_junction_link(link: &Path) -> bool {
    if fs::symlink_metadata(link).is_err() {
        return true;
    }
    let _ = Command::new("cmd").args(["/c", "rmdir"]).arg(link).status();
    if fs::symlink_metadata(link).is_err() {
        return true;
    }
    fs::remove_dir(link).is_ok() || fs::symlink_metadata(link).is_err()
}

/// 清理守卫：panic 时也会先删除 Junction 链接，绝不递归删除链接目标。
struct JunctionGuard {
    link: Option<PathBuf>,
}

impl JunctionGuard {
    fn new(link: &Path) -> Self {
        Self {
            link: Some(link.to_path_buf()),
        }
    }

    fn cleanup(&mut self) -> bool {
        self.link
            .take()
            .map(|link| remove_junction_link(&link))
            .unwrap_or(true)
    }
}

impl Drop for JunctionGuard {
    fn drop(&mut self) {
        if let Some(link) = self.link.take() {
            if !remove_junction_link(&link) {
                eprintln!("[cleanup][Drop] Junction 删除失败：{}", link.display());
            }
        }
    }
}

/// 模拟正式目录：位于 D 盘隔离测试目录内的 `formal-sim\WorkManager`。
///
/// 只包含一个标记文件；任何应用数据（config/logs/cache/temp/backups/database、写探针、
/// 初始化锁或 work.db）出现在这里都说明保护被绕过。
fn create_protected_fixture(dir: &TestDir) -> PathBuf {
    let protected = dir.join("formal-sim").join("WorkManager");
    fs::create_dir_all(&protected).expect("创建模拟正式目录夹具");
    fs::write(
        protected.join("protected-marker.txt"),
        b"simulated formal release directory; tests must never write app data here\n",
    )
    .expect("写入模拟正式目录标记文件");
    protected
}

fn sorted_entries(path: &Path) -> Vec<String> {
    let mut entries: Vec<String> = fs::read_dir(path)
        .unwrap_or_else(|error| panic!("读取目录失败 {}：{error}", path.display()))
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    entries.sort();
    entries
}

/// 用例 1：resolver 在 data_root 已是指向受保护目录的 Junction 时必须拒绝。
#[test]
fn resolve_rejects_junction_alias_to_protected_root() {
    let formal = FormalRootSnapshot::capture();
    let dir = TestDir::new("formal-root-junction-resolve");
    let protected = create_protected_fixture(&dir);
    let before = sorted_entries(&protected);

    let alias = dir.join("alias-to-formal");
    create_junction(&alias, &protected).expect("创建指向模拟正式目录的 Junction");
    let mut junction = JunctionGuard::new(&alias);

    let app_root = dir.app_root();
    let error = PortablePaths::resolve_with_protected_roots(
        RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(&alias),
        std::slice::from_ref(&protected),
    )
    .expect_err("同卷 Junction 别名指向受保护正式目录时必须拒绝");

    println!("[resolve-junction] code = {}", error.code());
    println!("[resolve-junction] message = {error}");
    assert_eq!(
        error.code(),
        "debug-root-is-formal-release",
        "必须返回稳定的正式目录保护错误码"
    );
    assert!(
        error.to_string().contains("真实最终路径"),
        "错误消息必须说明命中的是真实最终路径检查：{error}"
    );
    assert_eq!(
        sorted_entries(&protected),
        before,
        "resolve 拒绝后受保护目录不得出现任何新条目"
    );

    // 场景 B：Junction 是 data_root 的祖先（data_root 尚不存在）时同样必须拒绝：
    // 最近已存在祖先的真实最终路径位于受保护目录内。
    let nested_data_root = alias.join("nested-data");
    let nested_error = PortablePaths::resolve_with_protected_roots(
        RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(&nested_data_root),
        std::slice::from_ref(&protected),
    )
    .expect_err("Junction 祖先指向受保护正式目录、data_root 尚不存在时也必须拒绝");
    println!("[resolve-junction-nested] code = {}", nested_error.code());
    println!("[resolve-junction-nested] message = {nested_error}");
    assert_eq!(nested_error.code(), "debug-root-is-formal-release");
    assert!(
        nested_error.to_string().contains("真实最终路径"),
        "嵌套场景错误消息必须说明命中真实最终路径检查：{nested_error}"
    );
    assert!(
        fs::symlink_metadata(&nested_data_root).is_err(),
        "拒绝后不得通过 Junction 在受保护目录内创建嵌套 data_root"
    );
    assert_eq!(
        sorted_entries(&protected),
        before,
        "嵌套场景拒绝后受保护目录不得出现任何新条目"
    );

    assert!(junction.cleanup(), "Junction 必须成功删除");
    formal.assert_unchanged("resolve 用例结束后");
    println!("[resolve-junction] PASS：Junction 别名被真实最终路径检查拒绝，受保护目录零写入");
}

/// 用例 2：resolve 通过后再把 data_root 替换为指向受保护目录的 Junction，
/// ensure_directories 必须在创建任何目录/写探针之前拒绝。
#[test]
fn ensure_directories_rejects_junction_created_after_resolve() {
    let formal = FormalRootSnapshot::capture();
    let dir = TestDir::new("formal-root-junction-ensure");
    let protected = create_protected_fixture(&dir);
    let before = sorted_entries(&protected);

    let app_root = dir.app_root();
    let data_root = dir.join("data-root");
    let paths = PortablePaths::resolve_with_protected_roots(
        RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(&data_root),
        std::slice::from_ref(&protected),
    )
    .expect("data_root 尚不存在时 resolve 应允许（真实路径检查在 ensure_directories 复验）");

    // 模拟“解析后、创建前”被替换：data_root 位置出现指向受保护正式目录的 Junction。
    create_junction(&data_root, &protected).expect("创建 data_root → 模拟正式目录 Junction");
    let mut junction = JunctionGuard::new(&data_root);

    let error = paths
        .ensure_directories()
        .expect_err("data_root 被替换为指向受保护正式目录的 Junction 时必须拒绝");

    println!("[ensure-junction] code = {}", error.code());
    println!("[ensure-junction] message = {error}");
    assert_eq!(error.code(), "debug-root-is-formal-release");
    assert_eq!(
        sorted_entries(&protected),
        before,
        "ensure_directories 必须在创建任何目录/写探针之前拒绝，受保护目录零写入"
    );
    assert!(
        !protected.join("database").exists(),
        "受保护目录内不得出现 database 目录"
    );
    assert!(
        !protected.join("cache").exists(),
        "受保护目录内不得出现 cache 目录"
    );
    assert!(
        fs::read_dir(&protected)
            .expect("读取受保护目录")
            .flatten()
            .all(|entry| !entry
                .file_name()
                .to_string_lossy()
                .starts_with(".workmanager-write-probe")),
        "受保护目录内不得出现写探针文件"
    );

    assert!(junction.cleanup(), "Junction 必须成功删除");
    formal.assert_unchanged("ensure_directories 用例结束后");
    println!(
        "[ensure-junction] PASS：创建前 Junction 复验拒绝，受保护目录与真实正式目录均未被写入"
    );
}

/// 用例 3：即使 ensure_directories 已通过，Database::initialize 在创建初始化锁/数据库之前
/// 仍必须复验真实路径边界；替换后的 Junction 会被拒绝，且不产生锁文件或数据库。
#[test]
fn database_initialize_rejects_swapped_junction_before_creating_lock_or_database() {
    let formal = FormalRootSnapshot::capture();
    let dir = TestDir::new("formal-root-db-boundary");
    let protected = create_protected_fixture(&dir);
    let before = sorted_entries(&protected);

    let app_root = dir.app_root();
    let data_root = dir.join("data-root");
    let paths = PortablePaths::resolve_with_protected_roots(
        RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(&data_root),
        std::slice::from_ref(&protected),
    )
    .expect("构造 Debug/Test 便携路径");
    paths
        .ensure_directories()
        .expect("正常路径下的目录布局必须创建成功");

    // 模拟 TOCTOU 替换：正常布局创建完成后，把 data_root 换成指向受保护目录的 Junction。
    fs::remove_dir_all(&data_root).expect("删除测试自己创建的 data_root（仅测试夹具）");
    create_junction(&data_root, &protected).expect("创建替换用 Junction");
    let mut junction = JunctionGuard::new(&data_root);

    let error = Database::initialize(&paths)
        .expect_err("Database::initialize 必须在创建初始化锁或数据库之前拒绝被替换的路径");
    println!("[db-boundary] code = {}", error.code());
    println!("[db-boundary] message = {error}");
    assert_eq!(
        error.code(),
        "database-directory-boundary-violation",
        "必须返回稳定的数据库目录边界错误码"
    );
    assert!(
        error.to_string().contains("debug-root-is-formal-release"),
        "数据库边界错误必须保留底层正式目录保护错误码：{error}"
    );

    let after = sorted_entries(&protected);
    assert_eq!(
        after, before,
        "拒绝后受保护目录不得出现任何新条目（尤其是初始化锁或数据库）"
    );
    for forbidden in [
        "database",
        "work.db",
        ".work.db.init.lock",
        "cache",
        "logs",
        "temp",
        "backups",
        "config",
    ] {
        assert!(
            !protected.join(forbidden).exists(),
            "受保护目录内不得出现应用数据 {forbidden}"
        );
    }

    assert!(junction.cleanup(), "Junction 必须成功删除");
    formal.assert_unchanged("Database::initialize 用例结束后");
    println!(
        "[db-boundary] PASS：锁/数据库创建前拒绝被替换路径；受保护目录零写入，真实正式目录未变化"
    );
}

/// 用例 4：Release 的 EXE 同级便携路径规则不得因注入受保护目录而改变。
#[test]
fn release_mode_ignores_injected_protected_roots() {
    let formal = FormalRootSnapshot::capture();
    let dir = TestDir::new("formal-root-release-unchanged");
    let protected = create_protected_fixture(&dir);
    let before = sorted_entries(&protected);
    let app_root = dir.app_root();

    let paths = PortablePaths::resolve_with_protected_roots(
        RuntimeMode::Release,
        &app_root.join("WorkManager.exe"),
        None,
        std::slice::from_ref(&protected),
    )
    .expect("Release 模式必须忽略 Debug/Test 受保护目录注入");
    assert_eq!(
        paths.data_root,
        app_root.join("data"),
        "Release 数据目录必须仍跟随 EXE 所在目录"
    );
    paths
        .ensure_directories()
        .expect("Release EXE 同级目录布局必须创建成功");
    assert!(paths.database_dir.is_dir(), "Release database 目录必须存在");
    assert_eq!(
        sorted_entries(&protected),
        before,
        "Release 模式不得写入注入的受保护目录"
    );
    formal.assert_unchanged("Release 用例结束后");
    println!("[release-unchanged] PASS：Release 数据目录仍为 EXE 同级 data，受保护目录零写入");
}

/// 用例 5：生产默认受保护目录（真实 `D:\WorkManager`）的字符串规则保持有效；
/// 同名测试目录 `D:\WorkManager-test-data` 仍允许。
#[test]
fn default_protected_root_keeps_rejecting_formal_paths() {
    let formal = FormalRootSnapshot::capture();
    let app_root = Path::new(r"D:\dev\WorkManager.exe");
    for candidate in [r"D:\WorkManager", r"D:\WorkManager\data"] {
        let error =
            PortablePaths::resolve(RuntimeMode::DebugTest, app_root, Some(Path::new(candidate)))
                .expect_err("生产默认受保护目录规则必须继续拒绝正式目录路径");
        assert_eq!(
            error.code(),
            "debug-root-is-formal-release",
            "candidate={candidate}"
        );
    }
    // 同名但不是正式目录的 D 盘测试目录仍允许。
    let paths = PortablePaths::resolve(
        RuntimeMode::DebugTest,
        app_root,
        Some(Path::new(
            r"D:\WorkManager-test-data\formal-root-default-check",
        )),
    )
    .expect("D:\\WorkManager-test-data 下的测试目录必须允许");
    assert_eq!(
        paths.data_root,
        PathBuf::from(r"D:\WorkManager-test-data\formal-root-default-check")
    );
    formal.assert_unchanged("默认受保护目录用例结束后");
    println!("[default-protected] PASS：D:\\WorkManager 字符串规则保持有效，真实目录未变化");
}
