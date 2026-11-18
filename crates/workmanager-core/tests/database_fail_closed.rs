//! 失败保护测试（fail-closed）：
//! - 数据库损坏、不是数据库、schema 版本过高时不覆盖原文件；
//! - 便携路径被文件阻塞、目录不可写时返回清晰错误且不回退；
//! - 初始化失败不留下可被误认为有效的半成品数据库。

mod support;

use std::fs;
use std::path::PathBuf;

use support::{TestDir, raw_release_paths};
use workmanager_core::Database;

fn init_temp_files(database_dir: &std::path::Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(database_dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.starts_with(".work.db.init-"))
                .unwrap_or(false)
        })
        .collect()
}

#[test]
fn garbage_database_file_is_never_overwritten() {
    let dir = TestDir::new("fail-closed-garbage");
    let paths = dir.release_paths();
    let garbage = b"this file is deliberately not a SQLite database; it simulates a corrupted file"
        .repeat(80);
    fs::write(&paths.database_file, &garbage).expect("写入垃圾数据库文件");
    let before = fs::read(&paths.database_file).expect("读取原始文件");

    let error = Database::initialize(&paths).expect_err("非数据库文件必须 fail-closed");
    assert!(
        matches!(
            error.code(),
            "database-corrupt"
                | "database-not-a-database"
                | "database-open-failed"
                | "database-sqlite-error"
                | "database-integrity-check-failed"
        ),
        "错误码应属于数据库异常分类，实际：{} ({error})",
        error.code()
    );

    let after = fs::read(&paths.database_file).expect("读取失败后文件");
    assert_eq!(before, after, "原始数据库文件内容不得被修改");
    assert!(
        init_temp_files(&paths.database_dir).is_empty(),
        "不得留下初始化临时数据库文件"
    );
}

#[test]
fn corrupted_database_image_is_never_overwritten() {
    let dir = TestDir::new("fail-closed-corrupt-image");
    let paths = dir.release_paths();

    {
        let database = Database::initialize(&paths).expect("初始化数据库");
        // 写入较大的虚构数据，让数据库拥有多个页，便于确定性破坏中间页。
        let payload = format!("{{\"marker\":\"{}\"}}", "虚构数据".repeat(40_000));
        database
            .connection()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-big', ?1, '2026-11-17T00:00:00Z')",
                [payload],
            )
            .expect("写入虚构大字段");
    }

    let mut bytes = fs::read(&paths.database_file).expect("读取数据库文件");
    assert!(bytes.len() > 12_288, "数据库应包含多个页");
    let start = 4_096 * 2;
    let end = (start + 4_096).min(bytes.len());
    for byte in &mut bytes[start..end] {
        *byte = 0xFF;
    }
    fs::write(&paths.database_file, &bytes).expect("写入损坏后的数据库");
    let before = fs::read(&paths.database_file).expect("读取损坏数据库");

    let error = Database::initialize(&paths).expect_err("损坏数据库必须 fail-closed");
    assert!(
        matches!(
            error.code(),
            "database-corrupt"
                | "database-not-a-database"
                | "database-open-failed"
                | "database-sqlite-error"
                | "database-integrity-check-failed"
        ),
        "错误码应属于数据库异常分类，实际：{} ({error})",
        error.code()
    );

    let after = fs::read(&paths.database_file).expect("读取失败后文件");
    assert_eq!(before, after, "损坏数据库原文件不得被覆盖或重建");
}

#[test]
fn schema_version_newer_than_application_fails_closed_and_keeps_data() {
    let dir = TestDir::new("fail-closed-version");
    let paths = dir.release_paths();

    {
        let database = Database::initialize(&paths).expect("初始化数据库");
        database
            .connection()
            .execute(
                "INSERT INTO settings (key, value_json, updated_at) VALUES ('test-version-canary', '{\"marker\":\"keep-me\"}', '2026-11-17T00:00:00Z')",
                [],
            )
            .expect("写入虚构 canary");
    }

    {
        let raw = rusqlite::Connection::open(&paths.database_file).expect("打开数据库");
        raw.pragma_update(None, "user_version", 999)
            .expect("设置未来版本");
    }

    let error = Database::initialize(&paths).expect_err("未来版本必须 fail-closed");
    assert_eq!(error.code(), "schema-version-too-new");
    match &error {
        workmanager_core::DatabaseError::SchemaVersionTooNew { found, supported } => {
            assert_eq!(*found, 999);
            assert_eq!(*supported, workmanager_core::LATEST_SCHEMA_VERSION);
        }
        other => panic!("期望 schema-version-too-new，实际：{other:?}"),
    }

    // 原库数据保持完整，没有被重建为空库。
    let read_only = rusqlite::Connection::open_with_flags(
        &paths.database_file,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("只读打开数据库");
    let user_version: i64 = read_only
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("读取 user_version");
    assert_eq!(user_version, 999);
    let canary: String = read_only
        .query_row(
            "SELECT value_json FROM settings WHERE key = 'test-version-canary'",
            [],
            |row| row.get(0),
        )
        .expect("旧数据必须仍然存在");
    assert_eq!(canary, "{\"marker\":\"keep-me\"}");
}

#[test]
fn data_directory_blocked_by_file_fails_without_fallback() {
    let dir = TestDir::new("fail-closed-data-is-file");
    let app_root = dir.app_root();
    fs::write(app_root.join("data"), b"blocking file").expect("用文件阻塞 data 路径");

    let paths = raw_release_paths(&app_root);
    let error = paths
        .ensure_directories()
        .expect_err("data 路径被文件阻塞时必须失败");
    assert_eq!(error.code(), "path-not-directory");
    assert!(app_root.join("data").is_file(), "阻塞文件不得被删除或覆盖");
    // 不得在其他位置回退创建数据库目录。
    assert!(!paths.database_dir.exists());
}

#[test]
fn database_directory_blocked_by_file_fails_without_fallback() {
    let dir = TestDir::new("fail-closed-database-is-file");
    let app_root = dir.app_root();
    fs::create_dir_all(app_root.join("data")).expect("创建 data 目录");
    fs::write(app_root.join(r"data\database"), b"blocking file").expect("用文件阻塞 database 路径");

    let paths = raw_release_paths(&app_root);
    let error = paths
        .ensure_directories()
        .expect_err("database 路径被文件阻塞时必须失败");
    assert_eq!(error.code(), "path-not-directory");
    assert!(
        app_root.join(r"data\database").is_file(),
        "阻塞文件不得被删除或覆盖"
    );
}

#[test]
fn database_path_that_is_a_directory_fails_closed() {
    let dir = TestDir::new("fail-closed-db-is-dir");
    let paths = dir.release_paths();
    // 把 work.db 变成同名目录。
    fs::create_dir_all(&paths.database_file).expect("创建同名目录");

    let error = Database::initialize(&paths).expect_err("数据库路径是目录时必须失败");
    assert_eq!(error.code(), "database-path-not-file");
    assert!(paths.database_file.is_dir(), "同名目录不得被删除");
}

#[test]
fn webview2_directory_blocked_by_file_fails_without_fallback() {
    let dir = TestDir::new("fail-closed-webview2-is-file");
    let app_root = dir.app_root();
    fs::create_dir_all(app_root.join(r"data\cache")).expect("创建 cache 目录");
    fs::write(app_root.join(r"data\cache\webview2"), b"blocking file")
        .expect("用文件阻塞 WebView2 目录");

    let paths = raw_release_paths(&app_root);
    let error = paths
        .ensure_directories()
        .expect_err("WebView2 路径被文件阻塞时必须失败");
    assert_eq!(error.code(), "path-not-directory");
    assert!(
        app_root.join(r"data\cache\webview2").is_file(),
        "阻塞文件不得被删除或覆盖"
    );
}

#[cfg(windows)]
mod acl {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use crate::support::{TestDir, raw_debug_paths};

    /// 对指定目录设置“拒绝当前用户写权限”的 ACL，并在 Drop 时恢复。
    struct DenyWriteAcl {
        path: PathBuf,
        account: String,
    }

    impl DenyWriteAcl {
        fn apply(path: &Path) -> Self {
            let account = std::env::var("USERNAME").expect("USERNAME 环境变量");
            let output = Command::new("icacls")
                .arg(path)
                .arg("/deny")
                .arg(format!("{account}:(W)"))
                .output()
                .expect("执行 icacls /deny");
            assert!(
                output.status.success(),
                "icacls /deny 失败：stdout={}, stderr={}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            Self {
                path: path.to_path_buf(),
                account,
            }
        }

        fn restore(&self) {
            let output = Command::new("icacls")
                .arg(&self.path)
                .arg("/remove:d")
                .arg(&self.account)
                .output()
                .expect("执行 icacls /remove:d");
            assert!(
                output.status.success(),
                "icacls /remove:d 失败：stdout={}, stderr={}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    impl Drop for DenyWriteAcl {
        fn drop(&mut self) {
            // 即使断言失败也要尽力恢复 ACL，避免测试目录无法清理。
            let _ = Command::new("icacls")
                .arg(&self.path)
                .arg("/remove:d")
                .arg(&self.account)
                .output();
        }
    }

    #[test]
    fn unwritable_database_directory_fails_closed_and_recovers_after_acl_restore() {
        let dir = TestDir::new("fail-closed-unwritable");
        let app_root = dir.app_root();
        let data_root = dir.join("debug-data");
        let paths = raw_debug_paths(&app_root, &data_root);
        // 先正常创建布局，再撤销数据库目录写权限。
        paths.ensure_directories().expect("初次创建目录布局");
        assert!(paths.database_dir.is_dir());

        let acl = DenyWriteAcl::apply(&paths.database_dir);
        let result = paths.ensure_directories();
        acl.restore();
        drop(acl);

        let error = result.expect_err("数据库目录不可写时必须 fail-closed");
        assert!(
            matches!(
                error.code(),
                "directory-not-writable" | "directory-create-failed" | "directory-inspect-failed"
            ),
            "错误码应表达目录不可写，实际：{} ({error})",
            error.code()
        );

        // 恢复权限后必须重新可用（证明错误是真实权限问题而非缓存状态）。
        paths
            .ensure_directories()
            .expect("恢复 ACL 后目录应重新可写");
        fs::write(paths.database_dir.join("probe.txt"), b"ok").expect("恢复后可写");
        fs::remove_file(paths.database_dir.join("probe.txt")).expect("清理探针");
    }
}
