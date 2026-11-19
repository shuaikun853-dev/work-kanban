# P3-02 空状态超时：基线复现探针汇总（e2e-prober）

- 生成时间：2026-11-18（本地 Asia/Shanghai）
- 仓库：`D:\工作事项看板`，分支 `task/T1-02-project-management`，HEAD `54f025d0e2d4c95a53604e3d05b6e6764236e600`
- Release EXE：`D:\工作事项看板\target\release\workmanager.exe`
  - size = **10,230,272 bytes**
  - SHA-256 = **DF4469EA067DEE39E10E49F0592FD4A9DAB076F4186FF3E8CF60F8F72EABB7E8**
  - 所有运行前后均复核哈希，未发生变化；未重新构建 EXE。
- 数据边界：只在 `D:\WorkManager-test-data` 下创建隔离输出目录；日志/元数据只写 `D:\工作事项看板\test-artifacts\e2e-probe`（已 gitignore）。未修改仓库源码、脚本或 git 状态。

## 1. 第 1 组：修改后脚本（返工中间版本，UTF-8 无 BOM）3 次运行

脚本版本（3 次运行前后哈希一致）：

| 脚本 | bytes | SHA-256 |
|---|---|---|
| scripts/verify/verify-t1-02-ui.ps1 | 8781 | `6cc9beefa890675ccf25eec624795d4435661a1929843494e07db73f45a82cf7` |
| scripts/verify/inspect-t1-02-ui.mjs | 36071 | `57a40652adafeb746a8371d91355763742268a05a3dd63e896b9f66f6b9957f6` |
| scripts/verify/inspect-t1-02-min-window.mjs | 12415 | `f1ee5912e38647180b39323b96421f56195b309791dae763042425c242fcd018` |

| 运行 | 开始（本地） | 结束（本地） | 耗时 | 退出码 | 结果 | 输出目录（均为空，0 个子项） | 日志 |
|---|---|---|---|---|---|---|---|
| run1 | 18:13:06.465 | 18:13:50.312 | 43.769s | 1 | FAIL | `D:\WorkManager-test-data\t1-02-probe-1-20261118-181306` | `run1.log.txt`（949B） |
| run2 | 18:17:26.200 | 18:18:11.038 | 44.736s | 1 | FAIL | `D:\WorkManager-test-data\t1-02-probe-2-20261118-181726` | `run2.log.txt`（949B） |
| run3 | 18:21:57.377 | 18:22:43.445 | 45.917s | 1 | FAIL | `D:\WorkManager-test-data\t1-02-probe-3-20261118-182157` | `run3.log.txt`（949B） |

- 3 份日志字节级完全相同：`length=949`，SHA-256 = `DD511FE21EB08D8888616094A21D36CACD973877AF024004C889056E70FD22AB`。
- 未产生 `t1-02-ui-evidence.json` / `t1-02-min-window-evidence.json` / 截图（脚本在启动应用前已因编码误解析跳过相关语句），因此主检查/最小窗口断言数量均为 N/A。
- 失败信息（3 次一致）：
  - node：`Error: CDP page target not found on port 9334. Last error: TypeError: fetch failed`
  - PowerShell：`D:\工作事项看板\scripts\verify\verify-t1-02-ui.ps1 : You cannot call a method on a null-valued expression.`
- 未出现 `Timed out waiting for: projects empty state`，也从未进入项目管理空状态等待。
- 根因（已由 lead 确认）：`verify-t1-02-ui.ps1` 被保存为 UTF-8 **无 BOM**，而任务规定启动器为 Windows PowerShell 5.1（`powershell.exe`），其按 ANSI/CP936 解码脚本：
  - 211 个 LF 中有 16 个换行被吞；
  - 第 79 行注释吞掉第 80 行 `$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"`（AST 中该赋值 = 0，HEAD 版 = 1）；
  - 第 54 行中文 Write-Host 的结束引号被破坏，导致后续 New-Item/Copy-Item 等语句被吞。
  - 归档口径：**返工过程中间版本的脚本编码问题，非 P3-02 失败证据**。
- 另有 2 次不计数诊断运行（`diag-direct-1.log.txt` 等）复现同一故障，已保留、不清理。

## 2. 第 2 组：HEAD 54f025d 基线脚本 2 次复现尝试

导出位置（仓库外，字节与 HEAD git blob 一致）：`D:\WorkManager-test-data\baseline-scripts\scripts\verify\`

| 脚本 | bytes | SHA-256 | HEAD blob |
|---|---|---|---|
| verify-t1-02-ui.ps1（BOM=True） | 6067 | `825dfc21f088acf325d9dd4bb382298d09995295436b1b73a3c4d312a5e59e4e` | `f4af5a64673fdea5ccc7003d7ecf8d84bae9a0cd` |
| inspect-t1-02-ui.mjs | 28789 | `5aaac8515497a70ea4a69f00c64ea55d1fde390a5acec1662d16353b54b9ecf5` | `5e7871d0544f566be6b847076c7eb8b49ba774aa` |
| inspect-t1-02-min-window.mjs | 11246 | `5c2c8eca5fdefff6e77bc62b5483731633d060c53b7db90f1bdd3390ab61b10c` | `705727fe677c8d561b8cc23306ade76c258ba990` |

命令形式（`-ExePath` 显式指向现有 Release EXE）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File <baseline-scripts>\scripts\verify\verify-t1-02-ui.ps1 ^
  -ExePath D:\工作事项看板\target\release\workmanager.exe -OutputDir <独立目录>
```

| 运行 | 开始（本地） | 结束（本地） | 耗时 | 退出码 | 主检查 | 最小窗口（JSON） | closeExitCode | orchestration pass | 输出目录 | 日志 |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline-run1 | 18:23:47.906 | 18:24:00.325 | 12.317s | 0 | 73/73，failed 0 | 11/11，failed 0 | 0 | true | `D:\WorkManager-test-data\t1-02-baseline-probe-1-20261118-182347` | `run-baseline1.log.txt`（8160B） |
| baseline-run2 | 18:24:28.833 | 18:24:41.778 | 12.857s | 0 | 73/73，failed 0 | 11/11，failed 0 | 0 | true | `D:\WorkManager-test-data\t1-02-baseline-probe-2-20261118-182428` | `run-baseline2.log.txt`（8160B） |

- 最小窗口证据 JSON 为 11 项（旧脚本在点击关闭按钮前写盘），控制台合计 12 项（含 `minWindow.closeButtonClicked`），属旧脚本口径差异。
- 两次日志均无 `Timed out waiting for`、无 FAIL；`page.noUncaughtErrors` PASS，CSP 0 违规；`closeExitCode=0`。
- 输出目录包含 `app\WorkManager.exe`、13 张截图、`t1-02-ui-evidence.json`、`t1-02-min-window-evidence.json`、`t1-02-ui-orchestration.json`。
- 结论：**本轮 2/2 通过，未复现“projects empty state”等待超时。**

## 3. 冒烟验证：BOM 修复后的修改版脚本（1 次，不属于正式两组）

脚本版本（运行前后一致；EXE 未变）：verify ps1 8995B / BOM=True / CRLF=211 / SHA-256 `20a49d6c595dd3b67face07bcec7d3247b0391b34b8da14205ad260e44a29de6`；两个 .mjs 同第 1 组。

- 18:25:03 启动，**12.731s，退出码 0，PASS**
- 输出目录：`D:\WorkManager-test-data\t1-02-probe-4-20261118-182503`，日志 `run4.log.txt`（8533B）
- 证据：主检查 **73/73**，最小窗口 **12/12**（JSON 内含 `minWindow.closeButtonClicked`）；`mainUiCheckCount=73`、`minWindowCheckCount=12`、`closeButtonCheckPassed=true`、`closeExitCode=0`、`pass=true`
- `deterministicWaits`：`page.reloadNewDocumentBootMarker, appShell.renderedWithTauriInternals, ipc.databaseHealthReady, projectsPage.loadingSettled`
- 无 `Timed out waiting`、无 FAIL。

## 4. 历史对照

`docs/testing/reports/T1-02-INDEPENDENT-AUDIT-REPORT.md`：首次独立 Release UI/IPC 运行失败（“Timed out waiting for: projects empty state”），立即重跑 73/73 + 12/12 通过，随后连续 3 次通过（历史合计 4 通过 / 1 失败），且确认 projects 表 0 行、无数据污染。

## 5. 对“基线能否复现空状态超时”的结论

- **本轮不能复现**：基线脚本 2/2 通过（主 73/73、最小窗口 JSON 11/11、控制台 12/12），无空状态超时；历史审计记录为 1 次首次运行失败 + 4 次通过。
- **根因判断（基于代码等待逻辑与实测证据）**：基线脚本的空状态等待是 `document.body.innerText.includes('暂无项目')` 的 12s 文本轮询，没有“页面初始化/IPC 就绪/loading 结束”的确定性条件；reload 后“就绪”判定也依赖旧文档同样成立的 DOM 条件，存在新/旧文档切换与首次 WebView2 冷启动的时序竞争。历史失败更符合**测试脚本等待逻辑的时序抖动/首次运行冷启动**，而非产品缺陷；P3-02 的确定性等待（boot marker + IPC ready + loading settled）正是对该方向的修复。
- **证据限制**：本轮只有 2 次基线运行且机器 WebView2 已预热（系统已有 msedgewebview2 进程），无法复刻审计当时“首次运行”的冷启动窗口；未做冷启动实验（超出本次授权范围）。因此上述根因为“倾向性判断”，不是已证明结论。

## 6. 建议

1. 在返工中加入脚本编码检查：`scripts/**/*.ps1` 必须 UTF-8 with BOM（或显式统一使用 PowerShell 7），避免再次出现 5.1 按 CP936 误读。
2. BOM 修复后的修改版脚本建议的冒烟验证已通过（见第 3 节）；正式 5 次运行可沿用同一口径：主 73、最小窗口 12（JSON）、closeExitCode=0、deterministicWaits=4。
3. 归档：第 1 组 3 次失败标注“返工中间版本脚本编码问题（非 P3-02）”；第 2 组 2 次 PASS 可作为 P3-02 基线说明；历史审计的那 1 次失败仍需保留在报告中，不得只保留后续 PASS。
