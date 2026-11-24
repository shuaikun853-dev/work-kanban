# T1-04 证据目录

本目录保存 T1-04 多项目独立副本创建的 Windows Release 实测证据与机器可读结果。

- **任务：** T1-04 多项目独立副本创建
- **环境：** Windows 10，Tauri 2 Release（`--no-bundle`），真实桌面窗口
- **UAT 目录：** `<uat-root>\t1-04-ui-20261124-082717`（`D:\WorkManager-test-data` 下独立隔离目录；证据 JSON 中已用 `<uat-root>` / `<repo>` 脱敏绝对路径）
- **Release EXE：** 10,435,072 字节，SHA-256 `2d997dea7c44ff323e902478063e01465a42e0544bfd0ff5b05359f38a3f7d79`
- **数据：** 全部为虚构项目/工作标题；不使用真实用户数据。

## 截图（screenshots/）

| 文件 | 内容 |
|---|---|
| `pending-empty.png` | 待安排空状态 |
| `create-dialog-multi-projects.png` | 多项目选择对话框（已选 2 个项目，显示预计创建 2 项） |
| `pending-two-project-copies.png` | 两项目批量创建后的待安排列表（正常窗口） |
| `pending-three-project-copies.png` | 三项目批量创建后的待安排列表 |
| `pending-unassigned-regression.png` | T1-03 未归属创建回归 |
| `pending-archived-project.png` | 归档项目历史关联保留 + “项目已归档”标识 |
| `create-error-project-archived-batch.png` | 对话框打开后项目被归档：整批失败、失效选择保留并需用户主动移除 |
| `create-error-contract-violation-batch.png` | Bridge 严格契约拒绝非法批量响应 |
| `pending-refresh-recovered.png` | 创建成功但列表刷新失败后重新加载恢复 |
| `batch-rollback-error.png` | 真实 SQLite trigger 使第二条副本插入失败：整批回滚、对话框保留标题与选择 |
| `pending-after-main-checks.png` | 主检查结束后正常窗口 |
| `pending-min.png` | 最小支持窗口 860×640 下的待安排列表 |
| `create-dialog-min.png` | 最小窗口下的多项目选择对话框 |
| `pending-after-restart.png` | 关闭重开后的重启持久化 + 重启后新批次 |

## 机器可读证据（evidence/）

| 文件 | 内容 |
|---|---|
| `t1-04-ui-evidence.json` | 主 UI/IPC 96 项检查、截图/异常/CSP 记录 |
| `t1-04-min-window-evidence.json` | 最小窗口 11 项检查 + 真实关闭按钮 |
| `t1-04-fault-evidence.json` | 真实 SQLite trigger 原子回滚 13 项检查 |
| `t1-04-persistence-evidence.json` | 重启持久化 15 项检查 |
| `t1-04-prerequisite.json` | 主阶段创建的项目/标题/期望数量，供故障与持久化阶段复用 |
| `t1-04-db-after-main.json` | 主阶段后数据库只读探针（12 工作 / 4 组 / 9 成员） |
| `t1-04-db-after-fault.json` | 故障注入回滚后数据库探针（数量与主阶段完全一致） |
| `t1-04-db-after-restart.json` | 重启持久化后数据库探针（14 工作 / 5 组 / 11 成员） |
| `t1-04-ui-orchestration.json` | 编排汇总（各阶段检查数、退出码、DB 检查、截图清单） |

## 复现命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-04-ui.ps1
```

退出码：`0` = 全部通过；`1` = 存在检查失败；`2` = 前置条件不满足/路径安全检查失败。
