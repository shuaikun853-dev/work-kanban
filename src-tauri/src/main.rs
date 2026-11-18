// 正式 Release 构建不显示额外的控制台窗口（Windows GUI 子系统）。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    workmanager_lib::run()
}
