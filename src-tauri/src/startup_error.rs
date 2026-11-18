//! 启动失败处理。
//!
//! 启动阶段的便携路径、目录或数据库错误必须在创建 WebView2 窗口之前暴露给用户：
//! 一旦创建窗口，WebView2 可能已经开始写默认用户数据目录（C 盘），违反便携数据边界。
//!
//! 因此这里使用 Windows 原生 MessageBoxW 显示错误，然后以非零退出码结束进程。
//! 不写日志文件（此时日志目录可能也不可用），也不回退到任何备用数据目录。

use std::io::Write;

#[cfg(target_os = "windows")]
fn show_message_box(message: &str) {
    // 简化的 Win32 常量，避免为单一 MessageBox 引入额外依赖。
    const MB_OK: u32 = 0x0000_0000;
    const MB_ICONERROR: u32 = 0x0000_0010;
    const MB_SETFOREGROUND: u32 = 0x0001_0000;

    #[link(name = "user32")]
    unsafe extern "system" {
        fn MessageBoxW(
            hwnd: *mut core::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            message_box_type: u32,
        ) -> i32;
    }

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    let text = wide(message);
    let caption = wide("WorkManager 启动失败");
    // SAFETY: 两个字符串都是有效期覆盖整个调用的、以 0 结尾的 UTF-16 缓冲区；
    // MessageBoxW 允许空 owner window。
    unsafe {
        let _ = MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            caption.as_ptr(),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        );
    }
}

#[cfg(not(target_os = "windows"))]
fn show_message_box(message: &str) {
    let _ = writeln!(std::io::stderr(), "WorkManager 启动失败: {message}");
}

/// 显示可见的启动失败信息并终止进程；绝不回退到其他数据目录。
pub fn fatal(message: &str) -> ! {
    let _ = writeln!(std::io::stderr(), "[WorkManager][fatal] {message}");
    show_message_box(message);
    std::process::exit(1);
}
