//! WorkManager Tauri 适配层。
//!
//! 职责边界（AGENTS.md / TD 2.3）：
//! - 解析便携路径、初始化数据库、创建主窗口（含 WebView2 绝对数据目录）；
//! - 暴露最小受限命令：数据库健康检查（T1-01）与项目列表/创建/编辑/归档（T1-02），
//!   完整注册列表见 [`run`] 中的 `tauri::generate_handler!`；
//! - 不实现业务规则，不向前端暴露数据库连接或任意 SQL；
//! - 任何启动失败都在创建 WebView2 窗口之前 fail-closed，绝不回退到 C 盘默认目录。

mod app_state;
mod commands;
mod startup_error;

use std::error::Error;

use tauri::Manager;
use workmanager_core::{Database, PortablePaths};

use app_state::AppState;

/// 应用名称（仅显示用途，不包含用户数据）。
pub const APP_NAME: &str = "WorkManager";

fn setup_app(app: &mut tauri::App) -> Result<(), Box<dyn Error>> {
    // 1. 便携路径必须在创建任何 WebView2 窗口之前解析完成，否则 WebView2 可能
    //    回落到 C 盘默认用户数据目录。
    let paths = match PortablePaths::resolve_for_current_exe() {
        Ok(paths) => paths,
        Err(error) => startup_error::fatal(&format!(
            "便携路径解析失败，已停止启动。\n\n错误码：{}\n{}",
            error.code(),
            error.message
        )),
    };

    // 2. 创建并验证完整便携目录布局（含 WebView2 目录可写性）。
    let paths = match paths.ensure_directories() {
        Ok(()) => paths,
        Err(error) => startup_error::fatal(&format!(
            "便携数据目录不可用，已停止启动。\n\n错误码：{}\n{}",
            error.code(),
            error.message
        )),
    };

    // 3. 初始化或打开普通 SQLite 数据库；失败时保留原文件并停止启动。
    let database = match Database::initialize(&paths) {
        Ok(database) => database,
        Err(error) => startup_error::fatal(&format!(
            "数据库初始化失败，已停止启动，原始数据库未被删除或覆盖。\n\n错误码：{}\n{}",
            error.code(),
            error
        )),
    };

    let schema_version = database.schema_version().unwrap_or(-1);
    println!(
        "[WorkManager][startup] mode={} source={} exe={} data_root={} database={} schema_version={} created_new={}",
        paths.mode.as_str(),
        paths.data_source,
        paths.exe_path.display(),
        paths.data_root.display(),
        paths.database_file.display(),
        schema_version,
        database.created_new()
    );

    let webview2_data_dir = paths.webview2_dir.clone();
    app.manage(AppState::new(paths, database));

    // 4. 使用 Rust 侧绝对路径创建主窗口，指定 WebView2 data_directory。
    let window_config = app
        .config()
        .app
        .windows
        .iter()
        .find(|window| window.label == "main")
        .cloned()
        .unwrap_or_else(|| {
            startup_error::fatal("tauri.conf.json 中找不到 label=main 的主窗口配置，已停止启动。")
        });

    if window_config.create {
        startup_error::fatal(
            "主窗口配置必须为 create=false，由 Rust 在解析便携路径后使用 data_directory 创建；\
             已停止启动，避免 WebView2 在初始化前写入 C 盘默认目录。",
        );
    }

    let builder = tauri::WebviewWindowBuilder::from_config(app.handle(), &window_config)
        .unwrap_or_else(|error| {
            startup_error::fatal(&format!("读取主窗口配置失败：{error}。已停止启动。"))
        });

    builder
        .data_directory(webview2_data_dir.clone())
        .build()
        .unwrap_or_else(|error| {
            startup_error::fatal(&format!(
                "创建主窗口/WebView2 失败：{error}。\nWebView2 data_directory={}；\
                 已停止启动，不会回退到 C 盘、AppData 或系统 Temp。",
                webview2_data_dir.display()
            ))
        });

    println!(
        "[WorkManager][startup] webview2_data_directory={}",
        webview2_data_dir.display()
    );

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::get_database_health,
            commands::projects::list_projects,
            commands::projects::create_project,
            commands::projects::update_project,
            commands::projects::archive_project,
        ])
        .setup(|app| {
            setup_app(app)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("WorkManager Tauri 应用构建失败");

    // 正常退出时显式关闭 SQLite 连接（触发 WAL checkpoint 并清理 -wal/-shm）。
    // 强制结束进程时不会执行该逻辑，依赖 SQLite WAL 崩溃恢复与启动完整性检查。
    app.run(|app_handle, event| {
        if let tauri::RunEvent::Exit = event {
            if let Some(state) = app_handle.try_state::<AppState>() {
                state.shutdown();
            }
        }
    });
}
