//! 便携路径与测试隔离测试（文件系统层面）：
//! - Release 在 EXE 同级创建 data 布局；
//! - Debug/Test 根目录互相隔离，不共享数据库；
//! - Release 解析忽略测试根目录参数；
//! - 测试目录边界（D 盘、不得写入正式运行目录）。

mod support;

use std::fs;

use support::{TestDir, raw_debug_paths, resolve_test_base};
use workmanager_core::{Database, LATEST_SCHEMA_VERSION};

#[test]
fn release_layout_is_created_next_to_exe() {
    let dir = TestDir::new("portable-release-layout");
    let app_root = dir.app_root();
    let paths = dir.release_paths();

    assert_eq!(paths.data_root, app_root.join("data"));
    assert_eq!(paths.database_file, app_root.join(r"data\database\work.db"));
    assert_eq!(paths.webview2_dir, app_root.join(r"data\cache\webview2"));

    for directory in [
        &paths.data_root,
        &paths.database_dir,
        &paths.config_dir,
        &paths.logs_dir,
        &paths.cache_dir,
        &paths.webview2_dir,
        &paths.temp_dir,
        &paths.backups_dir,
    ] {
        assert!(
            directory.is_dir(),
            "便携目录必须创建：{}",
            directory.display()
        );
    }

    // 写探针必须已清理，不能留下测试文件。
    let leftovers: Vec<_> = fs::read_dir(&paths.database_dir)
        .expect("读取 database 目录")
        .flatten()
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".workmanager-write-probe")
        })
        .collect();
    assert!(leftovers.is_empty(), "目录写探针必须被清理");
}

#[test]
fn debug_test_roots_are_isolated_from_each_other() {
    let first = TestDir::new("portable-isolation-a");
    let second = TestDir::new("portable-isolation-b");
    let (first_paths, first_root) = first.debug_paths();
    let (second_paths, second_root) = second.debug_paths();

    assert_ne!(first_root, second_root);
    assert_ne!(first_paths.database_file, second_paths.database_file);

    {
        let first_database = Database::initialize(&first_paths).expect("初始化第一套测试数据库");
        assert!(first_database.created_new());
        first_database
            .connection()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-isolation', '{\"marker\":\"first\"}', '2026-11-17T00:00:00Z')",
                [],
            )
            .expect("写入第一套测试数据");
    }

    {
        let second_database = Database::initialize(&second_paths).expect("初始化第二套测试数据库");
        assert!(
            second_database.created_new(),
            "第二套根目录必须独立创建新库"
        );
        let rows: i64 = second_database
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM settings WHERE key = 'test-isolation'",
                [],
                |row| row.get(0),
            )
            .expect("查询第二套测试库");
        assert_eq!(rows, 0, "测试根目录之间不得共享数据库数据");
        assert_eq!(
            second_database.schema_version().expect("schema version"),
            LATEST_SCHEMA_VERSION
        );
    }

    // 第一套数据仍然存在且完整。
    let first_read_only = rusqlite::Connection::open_with_flags(
        &first_paths.database_file,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("只读打开第一套数据库");
    let value: String = first_read_only
        .query_row(
            "SELECT value_json FROM settings WHERE key = 'test-isolation'",
            [],
            |row| row.get(0),
        )
        .expect("读取第一套数据");
    assert_eq!(value, "{\"marker\":\"first\"}");
}

#[test]
fn release_resolution_ignores_test_root_argument() {
    let dir = TestDir::new("portable-release-ignore");
    let app_root = dir.app_root();
    let decoy = dir.join("decoy-data");

    let paths = raw_debug_paths(&app_root, &decoy);
    assert_eq!(paths.data_root, decoy, "Debug 模式应使用显式测试根目录");

    // Release 模式：即使传入测试根目录也必须忽略，数据目录跟随 EXE。
    let release_paths = workmanager_core::PortablePaths::resolve(
        workmanager_core::RuntimeMode::Release,
        &app_root.join("WorkManager.exe"),
        Some(&decoy),
    )
    .expect("解析 Release 路径");
    assert_eq!(release_paths.data_root, app_root.join("data"));
    release_paths
        .ensure_directories()
        .expect("创建 Release 目录");
    assert!(!decoy.exists(), "Release 不得创建测试根目录");
    assert!(app_root.join("data").is_dir());
}

#[test]
fn test_base_directory_is_d_drive_and_outside_formal_release_root() {
    let base = resolve_test_base();
    assert!(base.is_absolute());
    let text = base.to_string_lossy().to_lowercase();
    assert!(
        text.starts_with("d:\\"),
        "测试根目录必须位于 D 盘：{}",
        base.display()
    );
    assert!(
        !text.starts_with(r"d:\workmanager\") && text != "d:\\workmanager",
        "测试根目录不得位于正式运行目录 D:\\WorkManager：{}",
        base.display()
    );
}

#[test]
fn debug_root_inside_formal_release_root_is_rejected() {
    let dir = TestDir::new("portable-formal-reject");
    let app_root = dir.app_root();
    let error = workmanager_core::PortablePaths::resolve(
        workmanager_core::RuntimeMode::DebugTest,
        &app_root.join("WorkManager.exe"),
        Some(std::path::Path::new(r"D:\WorkManager\data")),
    )
    .expect_err("正式目录不得作为测试根目录");
    assert_eq!(error.code(), "debug-root-is-formal-release");
}
