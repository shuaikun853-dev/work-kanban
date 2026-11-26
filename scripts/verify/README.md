# Release 运行时验证脚本（T1-01 / T1-02）

本目录保存 WorkManager 正式 Release 构建的**运行时**验证工具。单元/集成测试由
`cargo test` 覆盖，这里验证"真实 EXE + 真实 WebView2 窗口 + 真实便携目录"的行为。
新增或修改验证时只覆盖当前任务和真实风险，不增加无关检查或为数量而增加测试。

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
| `verify-release-portable.ps1` | 成功路径（106 项检查）：便携目录创建、WebView2 `EBWebView` profile、SQLite PRAGMA/版本/完整性、正常关闭、重启持久化（虚构 canary）、Release 忽略 `WORKMANAGER_TEST_PORTABLE_ROOT`、C 盘边界抽查。schema 版本期望为 **2**。 |
| `verify-release-faults.ps1` | 异常路径（73 项检查）：垃圾数据库文件、`data` 被文件阻塞、`work.db` 为同名目录、数据库目录 ACL 拒绝写入。要求启动失败、显示"WorkManager 启动失败"对话框、退出码非 0、原文件字节不变、无初始化临时文件残留。 |
| `inspect-release-ui.mjs` | T1-01 诊断页回归：通过 CDP 从应用壳进入“设置 → 数据库诊断”，读取渲染后 DOM、调用 `get_database_health` IPC、截图并输出 JSON 断言（24 项）。 |
| `verify-t1-02-ui.ps1` | **T1-02 真实 Release UI/IPC 端到端编排**：启动 Release → 主检查（73 项）→ 调整到最小窗口 860×640 → 最小窗口检查（12 项，含关闭按钮断言）→ 验证进程真实退出；从证据 JSON 汇总断言数量并输出截图与 JSON 证据。任一检查失败退出码为 1。 |
| `inspect-t1-02-ui.mjs` | T1-02 主 UI/IPC 检查（由编排脚本调用）：先等待 reload 新文档 boot marker、应用壳和 IPC 就绪，再验证 loading/空/错误态、真实 UI 创建/编辑/归档、长名称、归档后操作消失、诊断页、CSP、最大化/还原窗口 API；项目管理空状态断言改为“Loading 确定性结束后再判断终态”，失败时写页面状态/IPC/异常/截图诊断 JSON。 |
| `inspect-t1-02-min-window.mjs` | T1-02 最小窗口检查（由编排脚本调用）：视口/布局无横向溢出、弹窗完整可见；点击红色关闭圆点后由 Node 进程把包含 `minWindow.closeButtonClicked` 的 **12 项断言**写入证据 JSON，进程真实退出由编排脚本 ExitCode 独立验证。 |

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

T1-02 完整 Release UI/IPC 验证（一条命令编排，包含截图、最小窗口与关闭按钮退出检查）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
# 也可指定：-OutputDir D:\WorkManager-test-data\t1-02-ui-manual -Port 9341
```

说明：Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时可能误解析中文；本目录新增/修改的 `.ps1` 均以 UTF-8 with BOM 保存（修改后必须保留 BOM，否则 PowerShell 5.1 会按本地代码页解码并破坏脚本结构）。

## Design Token 静态检查（P2-01 门禁）

`src/lib/ui/tokens.css` 是颜色的唯一来源；Feature 页面、通用 UI 组件和相关 UI CSS 不得散落原始颜色。

| 命令 | 用途 |
|---|---|
| `node scripts/quality/check-design-tokens.mjs` | 扫描 `src/**/*.svelte` 的 `<style>` 块与静态内联 `style="..."`、`src/**/*.css`（中央 Token 文件除外），识别 HEX/RGB/RGBA/HSL/HSLA 原始颜色；发现违规则退出码 1，检查无法执行退出码 2。不允许忽略整个 Feature/UI 目录。 |
| `node --test scripts/quality/design-tokens.test.mjs` | 静态检查自身的正反向测试：违规 HEX/RGB/RGBA/HSL 必须失败、使用 Token 必须通过、Token 定义文件不得误报、目录不得整体豁免、真实仓库必须通过。 |
| `npm run check` | 依次执行 `svelte-check`、Design Token 静态检查与上述正反向测试；任一失败则质量门禁失败。 |

可选参数：`--root <repoRoot>` 指定扫描根目录，`--report <file>` 输出机器可读 JSON（`filesScanned`、`scannedFiles`、`violations`、`pass`）。检查结论与截图证据见 `docs/testing/reports/T1-02-AUDIT-FIX-assets/`。

退出码约定：`0` = 全部检查通过（允许 WARN/INFO）；`1` = 存在 FAIL；`2` = 前置条件不满足
（EXE 不存在、python 不可用、输出目录非法）。脚本不会伪造 PASS：无法执行的检查会
如实记录为 FAIL/INFO，并保留可复核证据。

## 当前验证结果（2026-11-18，T1-02 返工修复后，待第二轮独立审计）

Release 产物：`target\release\workmanager.exe`，10,230,784 字节，
SHA-256 `51BBBA8DD17103D742E1BD4A85B83377F7578D34584F2206F30EDFEC8D3DC7F6`。

| 脚本 | 退出码 | 结果 |
|---|---|---|
| `verify-t1-02-ui.ps1`（连续 5 次） | 0 | 每次主 UI/IPC **73/73**；最小窗口 **12/12**（含关闭按钮断言，JSON 全量持久化）；关闭按钮后进程退出码 0；CSP 0；未捕获异常 0 |
| `verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1 INFO=15 |
| `verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9 |
| `inspect-release-ui.mjs`（诊断页） | 0 | 24/24 断言通过（真实窗口渲染 + 真实 IPC 返回 + CSP 0 违规 + 截图） |
| `scripts/quality/check-design-tokens.mjs` | 0 | DESIGN_TOKEN_CHECK=PASS files=18 violations=0 |
| `scripts/quality/design-tokens.test.mjs` | 0 | 8/8 正反向测试通过 |

说明：schema 版本期望已更新为 **2**（0001 foundation + 0002 projects）；审计修复后应用会在数据库目录保留跨进程初始化锁文件
`.work.db.init.lock`（仅 PID/时间戳诊断），异常路径检查允许该文件存在；`.work.db.init-*` 临时数据库仍必须为空。

T1-02 返工修复后的截图、JSON 证据与日志见 `docs/testing/reports/T1-02-AUDIT-FIX-assets/`；
第一轮审计时的历史证据保留在 `docs/testing/reports/T1-02-assets/`；详细结果见
`docs/testing/reports/T1-02-REPORT.md` 与 `docs/testing/reports/T1-02-AUDIT-FIX-REPORT.md`。
