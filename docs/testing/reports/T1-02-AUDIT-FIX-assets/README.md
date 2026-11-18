# T1-02 第一轮独立审计问题修复证据（P2-01 / P3-01 / P3-02）

**对应任务：** T1-02 项目创建、编辑、归档（返工）
**生成日期：** 2026-11-18
**状态：** 待第二轮独立审计（本目录不构成独立审计结论）
**权威修复报告：** [../T1-02-AUDIT-FIX-REPORT.md](../T1-02-AUDIT-FIX-REPORT.md)
**机器可读修复证据：** [../T1-02-AUDIT-FIX-evidence.json](../T1-02-AUDIT-FIX-evidence.json)

本目录只保存修复后重新执行的完整回归证据，不修改第一轮独立审计报告
（[../T1-02-INDEPENDENT-AUDIT-REPORT.md](../T1-02-INDEPENDENT-AUDIT-REPORT.md)）。

## 目录结构

| 路径 | 内容 |
|---|---|
| `logs/` | 每个回归命令/每次 Release UI E2E 运行的完整控制台日志。`verify-t1-02-ui-run1..5.log.txt` 为连续 5 次完整 E2E；每次日志含 73 项主检查 + 12 项最小窗口检查的逐条 PASS。 |
| `evidence/` | 机器可读证据。`run1..run5/` 每次 E2E 的 `t1-02-ui-evidence.json`（73 项）、`t1-02-min-window-evidence.json`（12 项，含 `minWindow.closeButtonClicked`）、`t1-02-ui-orchestration.json`（断言数量、关闭退出码、EXE SHA-256）；`release-portable-summary.json`、`release-faults-summary.json` 为继承套件汇总；`p3-02-probe/` 为 P3-02 根因调查探针日志。 |
| `screenshots/run1..run5/` | 每次运行的真实 Release 截图（应用壳、工作总览、今日工作、设置、项目管理 loading/空/列表/归档确认/归档后/错误、诊断页、最小窗口、弹窗）。 |
| `regression-summary.json` | 本次完整回归编排汇总：环境、Release 产物、逐命令退出码与耗时、5 次 E2E 断言数量与关闭退出码、继承套件计数、`overallPass=true`。 |
| `design-token-check.json` | Design Token 静态检查机器可读报告（18 个文件、0 违规）。 |
| `diagnostics-ui-regression.json` | T1-01 诊断页 UI 回归（24/24，新 EXE）汇总。 |
| `p3-02-probe/README.md` | P3-02 基线复现探针与返工过程失败记录的说明。 |

## 说明

- 全部测试数据位于 `D:\WorkManager-test-data` 隔离目录，未触碰正式目录 `D:\WorkManager`。
- 日志中的本机账户标识已脱敏为 `<user>` / `<host>`；测试内容均为虚构数据。
- 日志、JSON、截图均为真实执行产物；`regression-summary.json` 的继承套件 `overallPass`
  在生成后按各套件自身 `summary.json` 的 `overall` 字段回填（见该文件 `notes`）。
