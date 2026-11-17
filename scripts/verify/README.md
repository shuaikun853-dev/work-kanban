# Release 运行时验证脚本（T1-01）

本目录保存 WorkManager 正式 Release 构建的**运行时**验证工具。单元/集成测试由
`cargo test` 覆盖，这里验证"真实 EXE + 真实 WebView2 窗口 + 真实便携目录"的行为。

## 前置条件

- Windows 10，已执行 `npm run tauri build -- --no-bundle`，产物为
  `target\release\workmanager.exe`（Tauri `--no-bundle` 产出为 Cargo 包名小写；
  用例会复制并重命名为 `WorkManager.exe` 以模拟正式便携包形态）。
- 系统 Python 3（含标准库 `sqlite3`）在 `PATH` 中，用于只读校验数据库。
- 测试数据只能放在 D 盘隔离目录（默认 `D:\WorkManager-test-data`），
  绝不允许写入正式运行目录 `D:\WorkManager` 或 C 盘。

## 脚本

| 文件 | 用途 |
|---|---|
| `VerifyCommon.ps1` | 公共库：进程启动/停止、主窗口等待、UI Automation 读取并关闭原生错误对话框、截图、目录快照、SHA-256、python SQLite 只读探针、summary/report 汇总。 |
| `verify-release-portable.ps1` | 成功路径（106 项检查）：便携目录创建、WebView2 `EBWebView` profile、SQLite PRAGMA/版本/完整性、正常关闭、重启持久化（虚构 canary）、Release 忽略 `WORKMANAGER_TEST_PORTABLE_ROOT`、C 盘边界抽查。 |
| `verify-release-faults.ps1` | 异常路径（59 项检查）：垃圾数据库文件、`data` 被文件阻塞、`work.db` 为同名目录、数据库目录 ACL 拒绝写入。要求启动失败、显示"WorkManager 启动失败"对话框、退出码非 0、原文件字节不变、无初始化临时文件残留。 |
| `inspect-release-ui.mjs` | 通过 WebView2 远程调试端口（CDP）检查真实 Release 窗口：读取渲染后 DOM、直接调用 `get_database_health` IPC 命令、截图并输出 JSON 断言。 |

## 用法

```powershell
# 成功路径 + 异常路径（默认使用仓库相对路径的 Release EXE）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1

# 自定义 EXE / 输出目录（输出目录必须在 D 盘）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1 `
    -ExePath D:\path\to\workmanager.exe `
    -OutputDir D:\WorkManager-test-data\release-verify-manual
```

UI/IPC 检查需要先以远程调试参数启动 Release 进程：

```powershell
$appDir = 'D:\WorkManager-test-data\ui-check\app'
New-Item -ItemType Directory -Path $appDir -Force | Out-Null
Copy-Item target\release\workmanager.exe (Join-Path $appDir 'WorkManager.exe') -Force
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9333'
$process = Start-Process -FilePath (Join-Path $appDir 'WorkManager.exe') -WorkingDirectory $appDir -PassThru
node scripts\verify\inspect-release-ui.mjs 9333 D:\WorkManager-test-data\ui-check\evidence
$null = $process.CloseMainWindow(); $process.WaitForExit(20000)
```

退出码约定：`0` = 全部检查通过（允许 WARN/INFO）；`1` = 存在 FAIL；`2` = 前置条件不满足
（EXE 不存在、python 不可用、输出目录非法）。脚本不会伪造 PASS：无法执行的检查会
如实记录为 FAIL/INFO，并保留可复核证据。

## 当前验证结果（2026-11-17，T1-01）

Release 产物：`target\release\workmanager.exe`，9,899,520 字节，
SHA-256 `B5CBEC7DEAE067247ECCBA8EA10BED86AF814ED4A324AC482B16651C059E43A0`。

| 脚本 | 退出码 | 结果 |
|---|---|---|
| `verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1 INFO=15 |
| `verify-release-faults.ps1` | 0 | TOTAL=59 PASS=51 FAIL=0 WARN=0 INFO=8 |
| `inspect-release-ui.mjs` | 0 | 19/19 断言通过（真实窗口渲染 + 真实 IPC 返回 + 截图） |

详细结果与已知 WARN 见 `docs/testing/reports/T1-01-REPORT.md`。
