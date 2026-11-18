//! 审计返工 P2：数据库首次初始化的跨进程竞争。
//!
//! 修复前：每次启动都无条件清理 `.work.db.init-*`，可能删除另一个活动进程正在
//! 使用的临时数据库；两个进程同时首次启动也可能重复初始化。
//!
//! 修复后：
//! - 首次初始化必须取得 `data/database/.work.db.init.lock` 上的跨进程文件锁；
//! - 只有持锁进程才允许清理遗留临时文件；
//! - 打开已有数据库时只做非阻塞“尽力加锁”，未持锁绝不删除任何临时文件；
//! - 锁由操作系统维护，进程崩溃/被强杀后自动释放，可在重启后清理遗留临时文件；
//! - 并发首次启动最终只有一个正式数据库、migration 只执行一次。

mod support;

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus};
use std::time::{Duration, Instant};

use support::{TestDir, init_temp_files};
use workmanager_core::{Database, InitializationLock};

const MODE_ENV: &str = "WM_TEST_CHILD_MODE";
const DATA_ROOT_ENV: &str = "WM_TEST_CHILD_DATA_ROOT";
const DATABASE_DIR_ENV: &str = "WM_TEST_CHILD_DATABASE_DIR";
const SIGNAL_ENV: &str = "WM_TEST_CHILD_SIGNAL";
const TRIGGER_ENV: &str = "WM_TEST_CHILD_TRIGGER";

/// 子进程辅助入口；普通测试运行（无模式环境变量）时直接返回。
#[test]
fn child_helper() {
    let Ok(mode) = std::env::var(MODE_ENV) else {
        return;
    };
    match mode.as_str() {
        "initialize" => {
            let data_root = PathBuf::from(std::env::var(DATA_ROOT_ENV).expect("data root env"));
            if let Ok(trigger) = std::env::var(TRIGGER_ENV) {
                assert!(
                    support::wait_for_file(Path::new(&trigger), Duration::from_secs(15)),
                    "子进程等待启动栅栏超时"
                );
            }
            let paths = support::prepare_debug_paths(&data_root);
            match Database::initialize(&paths) {
                Ok(database) => {
                    println!(
                        "child-initialize-ok pid={} created_new={} schema={}",
                        std::process::id(),
                        database.created_new(),
                        database.schema_version().unwrap_or(-1)
                    );
                    std::process::exit(0);
                }
                Err(error) => {
                    eprintln!(
                        "child-initialize-failed pid={} code={} error={error}",
                        std::process::id(),
                        error.code()
                    );
                    std::process::exit(21);
                }
            }
        }
        "hold-lock-with-active-temp" => {
            let database_dir =
                PathBuf::from(std::env::var(DATABASE_DIR_ENV).expect("database dir env"));
            let signal = PathBuf::from(std::env::var(SIGNAL_ENV).expect("signal env"));
            let lock = InitializationLock::acquire(&database_dir, Duration::from_secs(10))
                .expect("子进程取得锁");
            let _ = lock.write_diagnostic();
            let temp =
                database_dir.join(format!(".work.db.init-{}-active.tmp", std::process::id()));
            fs::write(&temp, b"active-child-temp-database").expect("写入活动临时文件");
            fs::write(
                &signal,
                format!("pid={} temp={}", std::process::id(), temp.display()),
            )
            .expect("写信号文件");
            std::thread::sleep(Duration::from_secs(120));
            drop(lock);
            std::process::exit(0);
        }
        other => panic!("unknown child mode: {other}"),
    }
}

/// 带 Drop 清理的子进程守卫：测试 panic 时也会杀掉子进程，避免遗留。
struct ChildGuard {
    child: Option<Child>,
}

impl ChildGuard {
    fn spawn(mode: &str, envs: &[(&str, &Path)]) -> Self {
        let mut command = Command::new(std::env::current_exe().expect("current test executable"));
        command.args(["--exact", "child_helper", "--nocapture"]);
        command.env(MODE_ENV, mode);
        for (key, value) in envs {
            command.env(key, value);
        }
        let child = command.spawn().expect("spawn child process");
        Self { child: Some(child) }
    }

    fn wait_with_timeout(&mut self, timeout: Duration) -> ExitStatus {
        let child = self.child.as_mut().expect("child present");
        let deadline = Instant::now() + timeout;
        loop {
            match child.try_wait().expect("try_wait child") {
                Some(status) => return status,
                None if Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("子进程在 {timeout:?} 内未退出");
                }
                None => std::thread::sleep(Duration::from_millis(50)),
            }
        }
    }

    fn pid(&self) -> u32 {
        self.child.as_ref().expect("child present").id()
    }

    fn kill(&mut self) -> ExitStatus {
        let child = self.child.as_mut().expect("child present");
        let _ = child.kill();
        child.wait().expect("wait killed child")
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.try_wait();
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn spawn_initialize(data_root: &Path, trigger: &Path) -> ChildGuard {
    ChildGuard::spawn(
        "initialize",
        &[(DATA_ROOT_ENV, data_root), (TRIGGER_ENV, trigger)],
    )
}

#[test]
fn two_processes_concurrent_first_initialization_is_safe() {
    let dir = TestDir::new("init-concurrency");
    let data_root = dir.join("data-root");
    fs::create_dir_all(&data_root).expect("create data root");
    // 父进程预先创建便携目录布局（不创建数据库），两个子进程共用同一数据根目录。
    let paths = support::prepare_debug_paths(&data_root);
    let database_path = paths.database_file().to_path_buf();
    assert!(!database_path.exists(), "前置条件：数据库尚不存在");

    let trigger = dir.join("start-trigger");
    let mut child_a = spawn_initialize(&data_root, &trigger);
    let mut child_b = spawn_initialize(&data_root, &trigger);
    println!(
        "init-concurrency: spawned pids {} and {}; releasing start trigger",
        child_a.pid(),
        child_b.pid()
    );
    std::thread::sleep(Duration::from_millis(300));
    fs::write(&trigger, b"go").expect("release start trigger");

    let status_a = child_a.wait_with_timeout(Duration::from_secs(90));
    let status_b = child_b.wait_with_timeout(Duration::from_secs(90));
    assert!(status_a.success(), "子进程 A 初始化失败：{status_a:?}");
    assert!(status_b.success(), "子进程 B 初始化失败：{status_b:?}");

    // 只允许存在一个正式数据库，且没有遗留初始化临时文件。
    let work_db_entries = fs::read_dir(&paths.database_dir)
        .expect("read database dir")
        .flatten()
        .filter(|entry| entry.file_name() == OsStr::new("work.db"))
        .count();
    assert_eq!(work_db_entries, 1, "必须只生成一个正式数据库");
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "并发初始化后不得遗留临时数据库：{:?}",
        init_temp_files(&paths.database_dir)
    );

    // 最终数据库完整、migration 只执行一次。
    let database = Database::initialize(&paths).expect("并发创建后再次打开数据库");
    assert!(!database.created_new(), "再次启动不应重新创建数据库");
    assert_eq!(database.schema_version().expect("schema version"), 1);
    let health = database.health_report().expect("health");
    assert_eq!(health.integrity_check, "ok");
    assert_eq!(health.applied_migrations.len(), 1, "migration 只应执行一次");
    let migration_rows: i64 = database
        .connection()
        .query_row("SELECT COUNT(*) FROM schema_migrations", [], |row| {
            row.get(0)
        })
        .expect("count migrations");
    assert_eq!(migration_rows, 1, "schema_migrations 只应有一条记录");
    println!(
        "init-concurrency: both children succeeded; single work.db; integrity=ok; migrations=1; temp_files=none"
    );
}

#[test]
fn active_process_temp_database_is_never_deleted_and_lock_recovers_after_kill() {
    let dir = TestDir::new("init-active-temp");
    let data_root = dir.join("data-root");
    fs::create_dir_all(&data_root).expect("create data root");
    let paths = support::prepare_debug_paths(&data_root);

    // 先创建已有数据库并写入虚构 canary。
    {
        let mut database = Database::initialize(&paths).expect("initial database");
        assert!(database.created_new());
        database
            .connection_mut()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-canary', '{\"marker\":\"active-temp\"}', '2026-11-17T00:00:00Z')",
                [],
            )
            .expect("insert fictional canary");
    }

    let database_dir = paths.database_dir.clone();
    let signal = dir.join("child-lock-signal");
    let mut child = ChildGuard::spawn(
        "hold-lock-with-active-temp",
        &[(DATABASE_DIR_ENV, &database_dir), (SIGNAL_ENV, &signal)],
    );
    assert!(
        support::wait_for_file(&signal, Duration::from_secs(30)),
        "子进程未在超时内取得初始化锁并发出信号"
    );
    let child_pid = child.pid();
    let temp_files = init_temp_files(&database_dir);
    assert_eq!(
        temp_files.len(),
        1,
        "子进程应创建恰一个活动临时数据库：{temp_files:?}"
    );
    let active_temp = temp_files[0].clone();
    assert!(
        active_temp
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.contains(&child_pid.to_string())),
        "活动临时文件应属于子进程：{}",
        active_temp.display()
    );
    println!(
        "init-active-temp: child pid={child_pid} holds lock; active temp={}",
        active_temp.display()
    );

    // 父进程在子进程持锁期间尝试加锁：必须返回明确“被占用”错误（fail-closed）。
    let lock_error = InitializationLock::acquire(&database_dir, Duration::from_millis(400))
        .expect_err("子进程持锁时父进程不应取得初始化锁");
    assert_eq!(
        lock_error.code(),
        "database-initialization-locked",
        "actual: {} ({lock_error})",
        lock_error.code()
    );
    assert!(
        InitializationLock::try_acquire(&database_dir)
            .expect("try acquire does not fail")
            .is_none(),
        "try_acquire 在子进程持锁时必须返回 None"
    );

    // 父进程以已有数据库路径启动：必须成功打开，且绝不删除活动子进程的临时文件。
    let database = Database::initialize(&paths)
        .expect("parent opens existing database while child holds lock");
    assert!(!database.created_new());
    assert!(
        active_temp.is_file(),
        "不得删除活动进程正在使用的临时数据库：{}",
        active_temp.display()
    );
    drop(database);

    // 强杀子进程：操作系统自动释放初始化锁；重启后应能清理遗留临时文件。
    let killed_status = child.kill();
    assert!(
        killed_status.code() != Some(0),
        "子进程应被强制终止，实际：{killed_status:?}"
    );
    std::thread::sleep(Duration::from_millis(300));

    let recovered_lock = InitializationLock::acquire(&database_dir, Duration::from_secs(5))
        .expect("子进程被强杀后初始化锁必须自动释放");
    assert!(recovered_lock.path().is_file());
    drop(recovered_lock);

    let database = Database::initialize(&paths).expect("重启后应能继续使用数据库");
    assert!(!database.created_new());
    assert!(
        init_temp_files(&database_dir).is_empty(),
        "取得锁后应清理崩溃遗留的临时数据库：{:?}",
        init_temp_files(&database_dir)
    );
    let health = database
        .health_report()
        .expect("health after crash recovery");
    assert_eq!(health.integrity_check, "ok");
    let canary: String = database
        .connection()
        .query_row(
            "SELECT value_json FROM settings WHERE key = 'test-canary'",
            [],
            |row| row.get(0),
        )
        .expect("canary must survive");
    assert_eq!(canary, "{\"marker\":\"active-temp\"}");
    println!(
        "init-active-temp: lock_busy_code=database-initialization-locked; active temp preserved; after-kill lock recovered; temp cleaned; integrity=ok; canary_preserved=true"
    );
}
