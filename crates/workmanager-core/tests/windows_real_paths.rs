//! Windows 实机测试：D 盘真实最终路径与卷类型校验（T1-01 独立审计 P1 返工）。
//!
//! 覆盖范围：
//! - 正常 D 盘目录：`resolve` + `ensure_directories` 成功，数据库目录真实可写；
//! - Junction 攻击：D 盘目录上的 Junction 指向 C 盘目录时，`resolve`/`ensure_directories`
//!   必须 fail-closed 返回错误，且 C 盘目标目录内不得出现任何应用数据/目录/文件；
//! - D 盘内部 Junction（真实目标仍在 D 盘）必须允许，证明校验不会误伤合法重解析点；
//! - 清理：Drop guard 保证 panic 时也先删除 Junction 链接、再删除 C 盘测试夹具，
//!   最后 `TestDir` 自动清理 D 盘测试目录。
//!
//! 未实机覆盖（如实说明，不伪报）：
//! - 映射网络盘（`DRIVE_REMOTE`）无法在本机无网络共享的环境下真实构造，其“拒绝”逻辑仅由
//!   `portable_paths.rs` 中对纯函数 `is_allowed_volume_type` 的单元测试覆盖；
//! - UNC 最终路径、光驱、内存盘等卷类型同样没有可用实机设备，仅覆盖纯函数判定。
//!
//! 测试数据边界：D 盘数据一律位于 `D:\WorkManager-test-data`（由 `support::TestDir` 保证）；
//! C 盘仅使用 `%LOCALAPPDATA%\WorkManager-junction-test-<unique>` 作为攻击目标夹具并在结束时删除。

#![cfg(windows)]

mod support;

use std::{
    fs,
    path::{Component, Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use support::TestDir;
use workmanager_core::{PortablePaths, RuntimeMode};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// 构造唯一后缀，避免并行测试/多次运行互相干扰。
fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let sequence = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("{}-{sequence}-{nanos}", std::process::id())
}

/// 提取 Windows 路径的盘符（用于断言夹具确实位于预期卷）。
fn drive_letter(path: &Path) -> Option<char> {
    match path.components().next()? {
        Component::Prefix(prefix) => match prefix.kind() {
            std::path::Prefix::Disk(letter) => Some(char::from(letter)),
            _ => None,
        },
        _ => None,
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

/// 只删除 Junction 链接本身：先 `cmd /c rmdir`，失败再退化为 `RemoveDirectoryW`。
///
/// 两种方式都只删除链接，不会递归删除目标内容。
fn remove_junction_link(link: &Path) -> bool {
    if fs::symlink_metadata(link).is_err() {
        return true;
    }
    let _ = Command::new("cmd").args(["/c", "rmdir"]).arg(link).status();
    if fs::symlink_metadata(link).is_err() {
        return true;
    }
    // fs::remove_dir 使用 RemoveDirectoryW：对 Junction 只删除链接，不进入目标目录。
    fs::remove_dir(link).is_ok() || fs::symlink_metadata(link).is_err()
}

/// 测试夹具清理守卫：即使断言失败导致 panic，也会先删 Junction 链接、再删 C 盘夹具目录。
struct FixtureCleanup {
    junction: Option<PathBuf>,
    c_target: Option<PathBuf>,
}

impl FixtureCleanup {
    fn cleanup(&mut self) -> Result<(), String> {
        let mut problems = Vec::new();
        if let Some(link) = self.junction.take() {
            if remove_junction_link(&link) {
                println!(
                    "[cleanup] Junction 链接已删除（只删链接，未触碰目标内容）：{}",
                    link.display()
                );
            } else {
                problems.push(format!("Junction 删除失败：{}", link.display()));
            }
        }
        if let Some(target) = self.c_target.take() {
            match fs::remove_dir_all(&target) {
                Ok(()) => println!("[cleanup] C 盘测试夹具目录已删除：{}", target.display()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    println!("[cleanup] C 盘测试夹具目录已不存在：{}", target.display());
                }
                Err(error) => problems.push(format!(
                    "C 盘测试夹具删除失败 {}：{error}",
                    target.display()
                )),
            }
        }
        if problems.is_empty() {
            Ok(())
        } else {
            Err(problems.join("；"))
        }
    }
}

impl Drop for FixtureCleanup {
    fn drop(&mut self) {
        if self.junction.is_none() && self.c_target.is_none() {
            return;
        }
        eprintln!("[cleanup][Drop] 检测到未清理的测试夹具，正在兜底清理……");
        if let Err(problem) = self.cleanup() {
            eprintln!("[cleanup][Drop] 兜底清理失败：{problem}");
        }
    }
}

/// 正常 D 盘目录：真实路径/卷校验必须通过，目录布局创建成功且数据库目录可写。
#[test]
fn normal_d_drive_layout_passes_real_path_validation() {
    let dir = TestDir::new("realpath-normal-d");
    let app_root = dir.app_root();

    let paths = PortablePaths::resolve(
        RuntimeMode::Release,
        &app_root.join("WorkManager.exe"),
        None,
    )
    .expect("D 盘正常目录必须通过真实存储位置校验");
    paths
        .ensure_directories()
        .expect("D 盘正常目录必须成功创建便携布局");
    println!(
        "[normal] resolve OK：portable_root = {}",
        paths.portable_root.display()
    );
    println!(
        "[normal] ensure_directories OK：database_dir = {}",
        paths.database_dir.display()
    );
    assert!(paths.data_root.is_dir(), "data 根目录必须存在");
    assert!(paths.database_dir.is_dir(), "database 目录必须存在");
    assert!(paths.webview2_dir.is_dir(), "cache/webview2 目录必须存在");

    // database 目录真实可写：写入并读回/删除一个测试探针，不包含任何业务数据。
    let probe = paths.database_dir.join("realpath-test-probe.tmp");
    fs::write(&probe, b"workmanager-test-fixture").expect("database 目录必须可写");
    assert_eq!(
        fs::read(&probe).expect("读取测试探针"),
        b"workmanager-test-fixture"
    );
    fs::remove_file(&probe).expect("删除测试探针");
    println!("[normal] database 目录可写：测试探针已写入、读回并删除");
}

/// Junction 攻击：D 盘上的 Junction 指向 C 盘目录时，必须在写入前 fail-closed 拒绝。
#[test]
fn junction_from_d_to_c_is_rejected_without_writing_c_drive() {
    let dir = TestDir::new("realpath-junction-c-attack");
    let app_root = dir.app_root();

    // C 盘夹具目标目录：%LOCALAPPDATA%\WorkManager-junction-test-<unique>（仅测试夹具）。
    let local_app_data = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .expect("需要 %LOCALAPPDATA% 绝对路径来构造 C 盘测试夹具");
    let c_target = local_app_data.join(format!("WorkManager-junction-test-{}", unique_suffix()));
    assert_ne!(
        drive_letter(&c_target).map(|letter| letter.to_ascii_uppercase()),
        Some('D'),
        "C 盘测试夹具必须位于非 D 盘才能构造跨卷 Junction 攻击：{}",
        c_target.display()
    );
    fs::create_dir_all(&c_target).expect("创建 C 盘测试夹具目录");
    println!("[fixture] C 盘夹具目标目录 = {}", c_target.display());

    // 先登记 C 盘夹具，若后续断言 panic，Drop guard 也会兜底清理。
    let mut fixture = FixtureCleanup {
        junction: None,
        c_target: Some(c_target.clone()),
    };

    let link = app_root.join("portable-root-link");
    create_junction(&link, &c_target).expect("创建 D→C Junction");
    fixture.junction = Some(link.clone());
    println!(
        "[fixture] Junction = {} -> {}",
        link.display(),
        c_target.display()
    );
    assert!(link.is_dir(), "Junction 应可见为目录");

    // 场景 A：EXE 位于 D→C 的 Junction 目录内，resolve 必须拒绝。
    let resolve_error =
        PortablePaths::resolve(RuntimeMode::Release, &link.join("WorkManager.exe"), None)
            .expect_err("D→C Junction 中的 EXE 必须 fail-closed 拒绝");
    println!(
        "[case A] resolve(Release, link\\WorkManager.exe) -> code = {}",
        resolve_error.code()
    );
    println!("[case A] message = {}", resolve_error);
    assert_eq!(
        resolve_error.code(),
        "path-real-target-not-d",
        "最终真实目标在 C 盘必须返回 path-real-target-not-d"
    );
    assert!(
        !link.join("data").exists(),
        "拒绝后不得在 Junction 下创建 data 目录"
    );

    // 场景 B：Debug 数据根目录位于 Junction 之下，ensure_directories 必须在任何创建之前拒绝。
    let data_root = link.join("app-data");
    let paths = PortablePaths::resolve(
        RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(&data_root),
    )
    .expect("data_root 尚不存在时 resolve 保留纯字符串 D 盘规则");
    let ensure_error = paths
        .ensure_directories()
        .expect_err("data_root 的最近已存在祖先被重解析到 C 盘时必须拒绝");
    println!(
        "[case B] ensure_directories() -> code = {}",
        ensure_error.code()
    );
    println!("[case B] message = {}", ensure_error);
    assert_eq!(
        ensure_error.code(),
        "path-real-target-not-d",
        "最近已存在祖先的真实目标在 C 盘必须返回 path-real-target-not-d"
    );
    assert!(!data_root.exists(), "拒绝后不得创建 data_root");
    assert!(
        !link.join("data").exists(),
        "拒绝后不得在 Junction 下创建 data 目录"
    );

    // C 盘夹具目标目录必须仍然为空：拒绝发生在任何写入之前。
    let remaining: Vec<PathBuf> = fs::read_dir(&c_target)
        .expect("读取 C 盘测试夹具目录")
        .flatten()
        .map(|entry| entry.path())
        .collect();
    println!(
        "[assert] C 盘夹具目录内条目数 = {}（期望 0）",
        remaining.len()
    );
    assert!(
        remaining.is_empty(),
        "C 盘目标目录不得被写入任何应用数据/目录/文件：{remaining:?}"
    );

    // 清理并验证：先删 Junction 链接，再删 C 盘夹具，TestDir 稍后自动清理 D 盘测试目录。
    fixture.cleanup().expect("清理测试夹具");
    assert!(!link.exists(), "Junction 链接必须已删除");
    assert!(!c_target.exists(), "C 盘测试夹具必须已删除");
    println!("[cleanup] 已验证 Junction 与 C 盘夹具均已清理；D 盘测试目录由 TestDir 自动清理");
}

/// Junction 攻击（祖先链场景）：Junction 位于 EXE 目录的**祖先**层级时，句柄解析必须
/// 沿完整祖先链展开重解析点并拒绝，而不是只看 EXE 父目录的字符串盘符。
#[test]
fn junction_above_exe_directory_is_rejected_via_ancestor_chain() {
    let dir = TestDir::new("realpath-junction-ancestor");
    let app_root = dir.app_root();

    let local_app_data = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .expect("需要 %LOCALAPPDATA% 绝对路径来构造 C 盘测试夹具");
    let c_target = local_app_data.join(format!("WorkManager-junction-test-{}", unique_suffix()));
    assert_ne!(
        drive_letter(&c_target).map(|letter| letter.to_ascii_uppercase()),
        Some('D'),
        "C 盘测试夹具必须位于非 D 盘才能构造跨卷 Junction 攻击：{}",
        c_target.display()
    );
    fs::create_dir_all(&c_target).expect("创建 C 盘测试夹具目录");
    println!(
        "[fixture-ancestor] C 盘夹具目标目录 = {}",
        c_target.display()
    );

    let mut fixture = FixtureCleanup {
        junction: None,
        c_target: Some(c_target.clone()),
    };

    // Junction 是 EXE 目录的祖先：link\app-sub 才是 EXE 所在目录。
    let link = app_root.join("link-ancestor");
    create_junction(&link, &c_target).expect("创建 D→C 祖先 Junction");
    fixture.junction = Some(link.clone());
    let exe_dir = link.join("app-sub");
    fs::create_dir_all(&exe_dir).expect("通过 Junction 在 C 盘夹具中创建子目录（测试夹具）");
    println!(
        "[fixture-ancestor] Junction = {} -> {}；EXE 目录 = {}",
        link.display(),
        c_target.display(),
        exe_dir.display()
    );

    // 场景 A：EXE 目录本身不在 Junction 上，但其祖先 link 是 D→C Junction。
    let resolve_error =
        PortablePaths::resolve(RuntimeMode::Release, &exe_dir.join("WorkManager.exe"), None)
            .expect_err("EXE 目录的祖先被重解析到 C 盘时必须 fail-closed 拒绝");
    println!(
        "[ancestor-A] resolve(Release, link\\app-sub\\WorkManager.exe) -> code = {}",
        resolve_error.code()
    );
    println!("[ancestor-A] message = {}", resolve_error);
    assert_eq!(resolve_error.code(), "path-real-target-not-d");
    assert!(
        !exe_dir.join("data").exists(),
        "拒绝后不得在祖先 Junction 下创建 data 目录"
    );

    // 场景 B：ensure_directories 校验 data_root 的最近已存在祖先（link\app-sub）时拒绝。
    let data_root = exe_dir.join("app-data");
    let paths = PortablePaths::resolve(
        RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(&data_root),
    )
    .expect("data_root 尚不存在时 resolve 保留纯字符串 D 盘规则");
    let ensure_error = paths
        .ensure_directories()
        .expect_err("data_root 的最近已存在祖先位于跨卷 Junction 之下时必须拒绝");
    println!(
        "[ancestor-B] ensure_directories() -> code = {}",
        ensure_error.code()
    );
    println!("[ancestor-B] message = {}", ensure_error);
    assert_eq!(ensure_error.code(), "path-real-target-not-d");
    assert!(!data_root.exists(), "拒绝后不得创建 data_root");

    // C 盘夹具中只有测试自己创建的 app-sub 目录，不得出现 data / app-data 等应用数据。
    let mut entries: Vec<String> = fs::read_dir(&c_target)
        .expect("读取 C 盘测试夹具目录")
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    entries.sort();
    println!("[assert] C 盘夹具目录条目 = {entries:?}（期望仅 [\"app-sub\"]）");
    assert_eq!(entries, vec!["app-sub".to_string()]);
    assert!(
        !c_target.join("app-sub").join("data").exists(),
        "C 盘夹具中不得出现应用 data 目录"
    );
    assert!(
        !c_target.join("app-sub").join("app-data").exists(),
        "C 盘夹具中不得出现 app-data 目录"
    );

    fixture.cleanup().expect("清理测试夹具");
    assert!(!link.exists(), "Junction 链接必须已删除");
    assert!(!c_target.exists(), "C 盘测试夹具必须已删除");
    println!("[cleanup-ancestor] 已验证祖先 Junction 与 C 盘夹具均已清理");
}

/// 正向对照：Junction 的真实目标仍在 D 盘时必须允许，证明校验只拒绝跨卷/非本地卷。
#[test]
fn junction_within_d_drive_is_allowed_when_real_target_stays_on_d() {
    let dir = TestDir::new("realpath-junction-same-volume");
    let real_target = dir.join("real-target");
    fs::create_dir_all(&real_target).expect("创建 D 盘真实目标目录");

    let mut fixture = FixtureCleanup {
        junction: None,
        c_target: None,
    };
    let link = dir.join("link-within-d");
    create_junction(&link, &real_target).expect("创建 D 盘内部 Junction");
    fixture.junction = Some(link.clone());
    println!(
        "[same-volume] Junction = {} -> {}",
        link.display(),
        real_target.display()
    );

    let paths = PortablePaths::resolve(RuntimeMode::Release, &link.join("WorkManager.exe"), None)
        .expect("真实目标仍在 D 盘的 Junction 必须允许");
    paths
        .ensure_directories()
        .expect("在 Junction 下创建目录应成功（真实目标仍在 D 盘）");
    assert!(
        real_target.join("data").is_dir(),
        "数据目录应落在 Junction 的真实目标下"
    );
    assert!(paths.data_root.is_dir());
    println!(
        "[same-volume] 允许通过：真实数据目录 = {}",
        real_target.join("data").display()
    );

    fixture.cleanup().expect("清理 D 盘内部 Junction");
    assert!(!link.exists(), "Junction 链接必须已删除");
    assert!(
        real_target.is_dir(),
        "只删除 Junction 链接，真实目标目录保留并由 TestDir 清理"
    );
}
