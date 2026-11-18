//! 数据库首次初始化的跨进程锁。
//!
//! 为什么需要（审计 P2）：
//! - 两个进程同时首次启动时，都可能创建临时数据库并尝试安装正式数据库；
//! - 每次启动都无条件清理 `.work.db.init-*` 可能删除另一个活动进程正在使用的临时库；
//! - 仅有 hard link 的“不覆盖”保护不足以避免重复 migration 与临时文件互删。
//!
//! 实现（Windows）：对 `data/database/.work.db.init.lock` 的固定字节范围使用
//! `LockFileEx` 独占锁。锁由操作系统维护：进程崩溃、被强杀或正常退出时都会自动
//! 释放，因此不需要 PID 心跳、清理超时或删除锁文件即可恢复。
//!
//! 使用规则：
//! - 首次初始化必须取得锁后再检查数据库是否存在、清理遗留临时文件、创建正式库；
//! - 打开已有数据库时只做“尽力而为”的非阻塞加锁，取得锁后才允许清理遗留临时文件；
//! - 绝不删除活动进程正在使用的临时数据库文件。
//!
//! 锁文件本身永久保留（0 字节），不要删除：删除会破坏正在等待的进程的锁语义。

use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::error::DatabaseError;

/// 初始化锁文件名（位于数据库目录内）。
pub const INITIALIZATION_LOCK_FILE_NAME: &str = ".work.db.init.lock";

/// 首次初始化时等待其他进程完成初始化的最长时间。
pub const DEFAULT_ACQUIRE_TIMEOUT: Duration = Duration::from_secs(5);

/// 重试间隔。
const RETRY_INTERVAL: Duration = Duration::from_millis(50);

/// 锁定的字节范围长度（锁定首字节即可表达跨进程独占）。
const LOCK_BYTE_RANGE_LENGTH: u32 = 1;

/// 测试专用锁竞争观察点（审计 R3-02）。
///
/// 仅在 `cfg(test)` 构建中存在，不是生产 API、IPC 或配置开关；未安装回调时为无操作，
/// **不改变加锁/等待语义**。双进程测试用它在“底层 `LockFileEx` 明确返回锁竞争
/// （`ERROR_LOCK_VIOLATION`）”时得到确定性通知，从而证明 waiter 确实在锁被持有时尝试
/// 获取过锁，而不是提前写信号后依赖操作系统调度。
#[cfg(test)]
pub(crate) mod test_contention_observer {
    use std::path::Path;
    use std::sync::{Mutex, OnceLock};

    type Callback = Box<dyn Fn(&Path) + Send + 'static>;

    fn slot() -> &'static Mutex<Option<Callback>> {
        static SLOT: OnceLock<Mutex<Option<Callback>>> = OnceLock::new();
        SLOT.get_or_init(|| Mutex::new(None))
    }

    /// 安装观察回调（仅测试进程使用）。
    pub(crate) fn install(callback: impl Fn(&Path) + Send + 'static) {
        let mut guard = slot()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *guard = Some(Box::new(callback));
    }

    /// 移除观察回调，避免影响同一进程后续测试。
    pub(crate) fn clear() {
        let mut guard = slot()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *guard = None;
    }

    /// 底层锁操作观察到真实竞争时通知已安装的回调。
    pub(crate) fn notify(path: &Path) {
        let guard = slot()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(callback) = guard.as_ref() {
            callback(path);
        }
    }
}

/// 已取得的数据库初始化锁；Drop 时释放。
#[derive(Debug)]
pub struct InitializationLock {
    file: File,
    path: PathBuf,
}

impl InitializationLock {
    /// 阻塞式取得初始化锁，最多等待 `wait`。
    ///
    /// 超时返回 [`DatabaseError::InitializationLockBusy`]，调用方应 fail-closed，
    /// 不得删除任何临时文件或数据库。
    pub fn acquire(directory: &Path, wait: Duration) -> Result<Self, DatabaseError> {
        let path = directory.join(INITIALIZATION_LOCK_FILE_NAME);
        let file = open_lock_file(&path)?;
        let started = Instant::now();

        loop {
            match try_lock_exclusive(&file) {
                Ok(true) => return Ok(Self { file, path }),
                Ok(false) => {
                    // 测试专用观察点：此处是底层 LockFileEx 明确返回“锁被占用”的时刻，
                    // 只有真实观察到竞争才会通知（审计 R3-02）。生产构建不包含该分支。
                    #[cfg(test)]
                    test_contention_observer::notify(&path);
                    let waited = started.elapsed();
                    if waited >= wait {
                        return Err(DatabaseError::InitializationLockBusy {
                            lock_path: path,
                            waited_ms: u64::try_from(waited.as_millis()).unwrap_or(u64::MAX),
                        });
                    }
                    std::thread::sleep(RETRY_INTERVAL);
                }
                Err(error) => {
                    return Err(DatabaseError::InitializationLockFailed {
                        lock_path: path,
                        detail: error.to_string(),
                    });
                }
            }
        }
    }

    /// 非阻塞尝试取得初始化锁；锁被占用时返回 `Ok(None)`。
    ///
    /// 用于“打开已有数据库”路径：取得锁才允许清理遗留临时文件，
    /// 未取得锁时不得删除任何文件。
    pub fn try_acquire(directory: &Path) -> Result<Option<Self>, DatabaseError> {
        let path = directory.join(INITIALIZATION_LOCK_FILE_NAME);
        let file = open_lock_file(&path)?;
        match try_lock_exclusive(&file) {
            Ok(true) => Ok(Some(Self { file, path })),
            Ok(false) => {
                // 测试专用观察点：非阻塞加锁明确返回锁被占用（审计 R3-02）。
                #[cfg(test)]
                test_contention_observer::notify(&path);
                Ok(None)
            }
            Err(error) => Err(DatabaseError::InitializationLockFailed {
                lock_path: path,
                detail: error.to_string(),
            }),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 写入诊断信息（PID、UTC 时间戳）；失败不影响锁的正确性，不包含任何用户数据。
    pub fn write_diagnostic(&self) -> Result<(), DatabaseError> {
        use std::io::{Seek, SeekFrom, Write};

        let mut file = &self.file;
        file.set_len(0)
            .map_err(|source| DatabaseError::FileSystemFailed {
                context: "重置数据库初始化锁诊断信息",
                path: self.path.clone(),
                source,
            })?;
        file.seek(SeekFrom::Start(0))
            .map_err(|source| DatabaseError::FileSystemFailed {
                context: "定位数据库初始化锁诊断信息",
                path: self.path.clone(),
                source,
            })?;
        let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        write!(
            file,
            "pid={}\nstarted_at={}\n",
            std::process::id(),
            timestamp
        )
        .map_err(|source| DatabaseError::FileSystemFailed {
            context: "写入数据库初始化锁诊断信息",
            path: self.path.clone(),
            source,
        })?;
        file.flush()
            .map_err(|source| DatabaseError::FileSystemFailed {
                context: "刷新数据库初始化锁诊断信息",
                path: self.path.clone(),
                source,
            })
    }
}

impl Drop for InitializationLock {
    fn drop(&mut self) {
        // 关闭句柄本身会释放锁；仍显式解锁以表达意图并尽早释放。
        #[cfg(windows)]
        unlock_file_range(&self.file);
    }
}

fn open_lock_file(path: &Path) -> Result<File, DatabaseError> {
    OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(path)
        .map_err(|source| DatabaseError::FileSystemFailed {
            context: "打开数据库初始化锁文件",
            path: path.to_path_buf(),
            source,
        })
}

/// 尝试对锁文件首字节加独占锁。
///
/// 返回 `Ok(true)` 表示取得锁，`Ok(false)` 表示已被其他句柄/进程占用。
#[cfg(windows)]
fn try_lock_exclusive(file: &File) -> Result<bool, io::Error> {
    use std::os::windows::io::AsRawHandle;

    use windows_sys::Win32::Storage::FileSystem::{
        LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY, LockFileEx,
    };
    use windows_sys::Win32::System::IO::OVERLAPPED;

    /// `ERROR_LOCK_VIOLATION`：请求的字节范围已被其他句柄锁定。
    const ERROR_LOCK_VIOLATION: i32 = 33;

    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    // SAFETY: 句柄来自存活的 `File`；OVERLAPPED 为本次调用栈上有效且零初始化；
    // 使用 FAIL_IMMEDIATELY 时调用同步完成，不依赖该结构在调用结束后继续存在。
    let result = unsafe {
        LockFileEx(
            file.as_raw_handle().cast(),
            LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
            0,
            LOCK_BYTE_RANGE_LENGTH,
            0,
            &mut overlapped,
        )
    };
    if result != 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION) {
        Ok(false)
    } else {
        Err(error)
    }
}

#[cfg(windows)]
fn unlock_file_range(file: &File) {
    use std::os::windows::io::AsRawHandle;

    use windows_sys::Win32::Storage::FileSystem::UnlockFileEx;
    use windows_sys::Win32::System::IO::OVERLAPPED;

    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    // SAFETY: 与加锁时相同的句柄与字节范围；OVERLAPPED 有效期覆盖调用。
    unsafe {
        let _ = UnlockFileEx(
            file.as_raw_handle().cast(),
            0,
            LOCK_BYTE_RANGE_LENGTH,
            0,
            &mut overlapped,
        );
    }
}

/// 非 Windows 降级实现：目标平台是 Windows 10，本实现仅保证 crate 可跨平台编译。
///
/// 这**不提供**可靠的跨进程锁，因此相关并发保护在非 Windows 平台不可用；
/// 产品不在非 Windows 平台发布。
#[cfg(not(windows))]
fn try_lock_exclusive(_file: &File) -> Result<bool, io::Error> {
    Ok(true)
}
