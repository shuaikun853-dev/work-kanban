# P3-02 基线复现探针与返工过程失败记录

本目录保存 P3-02（Release UI E2E 首次运行空状态等待超时）根因调查期间的真实探针日志。
这些运行不是最终验收证据，最终证据见同目录上一级的 `run1..run5` 与 `logs/verify-t1-02-ui-run*.log.txt`。

## 1. 基线复现尝试（HEAD 54f025d 脚本 + 旧 Release EXE）

- 脚本来源：`git show HEAD:scripts/verify/...` 导出到仓库外临时目录，`git hash-object`
  校验与 HEAD blob 一致；未修改仓库。
- EXE：10,230,272 bytes，SHA-256 `DF4469EA067DEE39E10E49F0592FD4A9DAB076F4186FF3E8CF60F8F72EABB7E8`（第一轮审计同一产物）。
- 结果：`run-baseline1.log.txt`、`run-baseline2.log.txt` 均退出码 0，主检查 73/73、
  最小窗口（旧脚本 JSON 口径）11/11、`closeExitCode=0`；**本轮 2/2 未复现 “Timed out waiting for:
  projects empty state”**。
- 结论限制：本轮机器 WebView2 已预热，无法完全复刻第一轮审计时可能的首次冷启动窗口；
  故“测试等待逻辑时序抖动”是倾向性根因判断，不是已证明结论。历史第一次失败记录只存在于
  第一轮独立审计报告，仓库内没有该次运行的原始日志（详见修复报告）。

## 2. 修改后脚本冒烟（返工中间版本脚本 + 旧 Release EXE）

- `run4.log.txt`：BOM 修复后的修改版脚本 1 次冒烟，退出码 0；主检查 73/73、
  最小窗口 12/12（JSON 已包含 `minWindow.closeButtonClicked`）、CSP 0、无未捕获异常。
- 该次运行验证了 P3-02 确定性等待与证据统计修复本身可用；最终验收仍以新 EXE 的 5 次正式运行为准。

## 3. 返工过程中的失败记录（脚本编码问题，非 P3-02 失败）

- `encoding-regression-failure-run1.log.txt`：返工中间版本 `verify-t1-02-ui.ps1` 经编辑工具保存后
  丢失 UTF-8 BOM，Windows PowerShell 5.1 按本地代码页解码，导致换行被吞、WebView2 调试端口赋值
  被并入注释，E2E 在 CDP 连接阶段失败（3 次运行字节级相同，仅保留 1 份）。
- 该问题已修复：最终 `.ps1` 恢复 UTF-8 BOM + CRLF，并用 Windows PowerShell 5.1 解析器验证
  `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` 赋值等关键语句存在；修复后 5 次正式运行全部通过。
- 保留此失败日志是为了满足“保留每次运行真实日志、包括失败记录”的要求，不隐藏返工过程中的失败。
