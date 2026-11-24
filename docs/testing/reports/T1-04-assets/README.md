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

---

## 第五轮定向修复证据（2026-11-24，T104-01～T104-06）

本轮证据保存在 `evidence/round5/` 与 `screenshots/round5/`，**不覆盖**上一轮证据。所有 UAT 数据均为虚构；正式目录 `D:\WorkManager` 未被打开、修改或故障注入。

- **Release EXE：** 10,457,600 字节，SHA-256 `0bbe1dc43f59644e51126aeb277abd98cb124e506f69f25d35ef767010ab4166`
- **UAT：** `<uat-root>`（`D:\WorkManager-test-data` 下独立目录；JSON 已脱敏绝对路径）
- **Release 结果：** 主 UI/IPC **107/107**、最小窗口 **11/11**、真实 trigger 回滚 **13/13**、重启持久化 **15/15**、数据库只读探针 **62/62**；三次真实关闭退出码 **0/0/0**
- **CSP：** `securitypolicyviolation` 监听器实际采集到 `[]`（0 违规），采集状态 `captured`；页面未捕获异常 0
- **幂等重试：** 第一次真实 Tauri IPC 提交 2 个项目批次；传输层丢弃响应并替换为异常响应；UI 保留请求标识；第二次保存复用同一 `requestId`，数据库仍为 1 个创建组 / 2 个副本 / 2 条成员关系

| 证据文件 | 内容 |
|---|---|
| `T104-01-junction-test-evidence.json` | Windows 真实 Junction/重解析点路径安全专项：9 PASS / 0 FAIL / 1 SKIP（文件符号链接无权限，显式记录） |
| `T104-01-junction-test-output.txt` | 上述专项原始输出 |
| `T104-02-ipc-idempotency-evidence.json` | 真实 IPC 响应异常 + 同一 requestId 重试的 UI 检查与数据库权威数量 |
| `T104-03-red-compile.txt` | 测试先行提交后的编译 Red（缺少 4 参数幂等 API） |
| `T104-03-red-behavior.txt` | 最小接口骨架后的行为 Red：18 passed / 6 failed，6 项均为幂等语义 |
| `T104-03-green-work-item-copies.txt` | `work_item_copies` Green：24 passed / 0 failed |
| `T104-03-gate-cargo-*.txt` | `cargo fmt --check` / `cargo check` / `cargo test --workspace` 完整输出（158 passed / 0 failed） |
| `T104-04-green-migration.txt` | schema 专项 Green：6 passed / 0 failed（含真实 0004 索引冲突回滚） |
| `T104-04-release-migration-rollback.txt` | Release EXE 真实 schema 3 + 0004 同名冲突索引启动：原生错误对话框、退出码 1、user_version 仍 3、无新表/version 4、历史数据不变 |
| `T104-06-csp-evidence.json` | 实际 CSP 采集数组、采集状态、页面异常分离记录 |
| `T104-06-release-e2e-output.txt` | 第五轮完整 Release E2E 输出（已脱敏本地路径） |
| `t1-04-*.json` | 第五轮主 UI、最小窗口、故障回滚、持久化、只读探针、编排汇总 |
| `T1-01-portable-regression.txt` | 继承 T1-01 便携回归：106 项（PASS 90 / FAIL 0 / WARN 1 / INFO 15） |
| `T1-01-fault-regression.txt` | 继承 T1-01 异常注入：73 项（PASS 64 / FAIL 0 / INFO 9） |
| `T1-02-ui-regression.txt` | 继承 T1-02 UI 回归：主 73/73 + 最小窗口 12/12 |
| `environment.txt` / `release-exe.sha256` / `test-counts.txt` | 环境、EXE 哈希与统计口径 |

### 第五轮截图

| 文件 | 内容 |
|---|---|
| `screenshots/round5/create-error-contract-violation-batch.png` | 真实 IPC 已提交但返回异常载荷时，Bridge 拒绝、对话框保留输入（第五轮幂等重试场景后续复用同一 requestId） |
| `screenshots/round5/pending-after-main-checks.png` | 第五轮主检查后的正常窗口 |
| `screenshots/round5/pending-min.png` | 第五轮最小窗口 |
| `screenshots/round5/create-dialog-min.png` | 第五轮最小窗口多项目对话框 |
| `screenshots/round5/batch-rollback-error.png` | 真实 SQLite trigger 回滚 |
| `screenshots/round5/pending-after-restart.png` | 重启持久化 |
| `screenshots/round5/create-dialog-multi-projects.png` | 多项目选择基线回归 |

> 证据边界：上述为开发代理执行结果，不构成独立审计或用户验收。T1-03 历史证据、审计状态、PR #8、P2-01 与 DEC-029 / Issue #2 风险均未改变。

---

## 第六轮定向修复证据（2026-11-24，R2-01～R2-04）

本轮证据保存在 `evidence/round6/` 与 `screenshots/round6/`，**不覆盖**第五轮/历史证据。所有 UAT 数据均为虚构；正式运行目录 `D:\WorkManager` 本机不存在，仅做只读身份快照，未被打开、修改或写入。

- **Release EXE（第六轮重建，含 Bridge 变更）：** 10,458,112 字节，SHA-256 `eae180c83cd880cf72063ea353214291a6eebe4c74d920cf09d6adf96022d149`
- **新增/重写专项：** `test-t1-04-path.py` **58 PASS / 0 FAIL / 1 SKIP**（文件符号链接权限不足，显式记录）；`test-t1-04-migration-path.py` **31 PASS / 0 FAIL**；Bridge Node 契约 **35/35**（Red 11 失败 → Green 35/35）；真实 Release migration 失败回滚 `ROLLBACK/CLEANUP/EVIDENCE` 全 PASS（脚本退出码 0）
- **Release E2E：** 主 UI/IPC **107/107**、最小窗口 **11/11**、真实 SQLite trigger 原子回滚 **13/13**、重启持久化 **15/15**、数据库只读探针 **62/62**；三次真实关闭退出码 **0/0/0**；CSP 实际采集、页面异常 0
- **继承回归：** T1-01 便携 106（PASS 90 / WARN 1 / INFO 15）、T1-01 异常注入 73（PASS 64 / INFO 9）、T1-02 UI 73/73 + 12/12、T1-03 路径安全 93（SKIPPED=1，FAILED=0）；全部退出码 0
- **安全证据：** 真实 `mklink /J` 测试根重定向/祖先 Junction/UAT 根/数据库目录/证据目录替换全部被拒绝（重解析 tag `0xA0000003`）；Junction 目标 Canary 内容与目录结构前后一致；清理身份变化/重解析点/守卫失败均 fail-closed 拒绝删除；control/probe/Fixture 守卫失败均未调用 `sqlite3.connect`；正式目录只读身份快照前后一致（existed=false）
- **残余风险：** DEC-029 / Issue #2 TOCTOU 并发路径替换窗口仍存在，本轮只治理静态 Junction / 重解析点 / 路径身份校验，不宣称消除并发替换；P2-01 仍未关闭；普通 SQLite 未加密

| 证据文件（`evidence/round6/`） | 内容 |
|---|---|
| `environment.txt` | 机器/工具链、分支、基线 HEAD、时间 |
| `release-exe.sha256` | 第六轮 Release EXE 大小与 SHA-256 |
| `bridge-baseline-subagent.txt` | R2-03 修改前 Bridge 基线（27/27） |
| `bridge-red.txt` | R2-03 新测试 + 旧实现 Red（35 项中 11 项失败） |
| `bridge-green.txt` | R2-03 实现后 Green（35/35） |
| `bridge-svelte-check.txt` | `svelte-check` 0 errors / 0 warnings |
| `path-safety-red.txt` | R2-01 新测试首次执行失败证据（守卫能力未实现） |
| `path-safety-output.txt` | R2-01 专项最终原始输出 |
| `path-safety-evidence.json` | R2-01 机器可读证据（58 项、Junction 拒绝、Canary、清理、正式目录快照） |
| `migration-path-red.txt` | R2-02 旧工具穿过祖先 Junction 写入并继续执行的漏洞 Red 证据 |
| `migration-path-output.txt` | R2-02 专项最终原始输出 |
| `migration-path-evidence.json` | R2-02 机器可读证据（31 项） |
| `migration-failure-output.txt` | 真实 Release migration 失败回滚原始输出（原生守卫 PASS、回滚不变量、fail-closed 清理、证据写入） |
| `migration-failure-evidence.json` | 真实 Release migration 失败回滚机器可读证据 |
| `release-e2e-output.txt` | Release E2E 原始输出（已脱敏本地路径） |
| `release-e2e-evidence/` | 主 UI/最小窗口/故障回滚/持久化/数据库探针/编排 JSON（9 个） |
| `inherited-T1-01-portable.txt` | 继承 T1-01 便携回归（106 项） |
| `inherited-T1-01-faults.txt` | 继承 T1-01 异常注入（73 项） |
| `inherited-T1-02-ui.txt` | 继承 T1-02 UI E2E（73/73 + 12/12） |
| `inherited-T1-03-path.txt` | 继承 T1-03 路径安全专项（93 项，1 SKIP） |
| `inherited-summary.txt` | 继承回归退出码汇总 |
| `gate-cargo-fmt.txt` / `gate-cargo-check.txt` / `gate-cargo-test.txt` | Rust 质量门禁原始输出（158 passed / 0 failed） |
| `gate-npm-check.txt` / `gate-npm-build.txt` | 前端质量门禁原始输出（Bridge 35/35、Token 49/49、167 modules） |
| `gate-git-diff-check.txt` / `gate-summary.txt` | `git diff --check` 输出与全部质量门禁退出码 |
| `test-counts.txt` | 新增/保留测试数量、PASS/FAIL/SKIP 与退出码汇总 |
| `git-diff.patch` / `git-diff-stat.txt` | 本轮修复 Git diff 与统计（不含本证据目录） |
| `README.md` | 本证据说明与复现命令 |

### 第六轮截图（`screenshots/round6/`）

| 文件 | 内容 |
|---|---|
| `pending-after-main-checks.png` | 主检查后的待安排列表 |
| `pending-two-project-copies.png` / `pending-three-project-copies.png` | 两/三项目批量创建结果 |
| `pending-unassigned-regression.png` | T1-03 未归属创建回归 |
| `pending-archived-project.png` | 归档项目历史关联保留 |
| `create-dialog-multi-projects.png` / `create-dialog-min.png` | 多项目选择对话框（正常/最小窗口） |
| `create-error-contract-violation-batch.png` | Bridge 严格契约拒绝非法批量响应 |
| `create-error-project-archived-batch.png` | 归档竞态整批失败 |
| `batch-rollback-error.png` | 真实 SQLite trigger 整批回滚 |
| `pending-refresh-recovered.png` | 刷新失败后重试恢复 |
| `pending-empty.png` / `pending-min.png` | 空状态 / 最小窗口 |
| `pending-after-restart.png` | 重启持久化 |

> 证据边界：上述为开发代理执行结果，不构成独立审计或用户验收。T1-03 历史证据、审计状态、PR #8、P2-01 与 DEC-029 / Issue #2 风险均未改变。

---

## 第六轮独立审计后定向补正证据（2026-11-24，R6-01～R6-03）

本轮证据保存在 `evidence/round6-remediation/`，**不覆盖** `evidence/round6/` 或更早证据。所有 UAT 数据均为虚构；正式运行目录 `D:\WorkManager` 未访问、未修改、未写入。

- **R6-01：** Bridge **48/48**（原 35 项全部保留 + 13 项 Unicode `White_Space`）；真实 Rust SQLite 保存/读回 → Bridge 交叉契约 **1/1**（10 场景）；Rust 契约测试 9/9；Red 为旧 `.trim()` 下 42 pass / 4 fail；基线 worktree 交叉 Red 退出码 1。
- **R6-02：** 真实 Windows 故障注入 **8 PASS / 0 FAIL / 1 SKIP**；悬空 Junction 返回 `danglingJunction`、`safe=false`、`performed=false`；Canary SHA-256 前后一致；Symbolic Link 无权限显式 SKIP；路径专项 **58 项 / 0 FAIL / 1 SKIP**；Migration 路径专项 **31 项 / 0 FAIL**。
- **R6-03：** 注释、任务状态、设计契约与 STATUS/PLAN/报告同步；历史轮次记录保留。
- **质量门禁：** Rust **162 passed / 0 failed / 1 ignored**；`npm run check` 0/0 + Bridge 48 + 交叉 1 + Token 49；`npm run build` 168 modules。
- **环境限制：** Windows 10 19045 的 `Test-Path` 对本次真实悬空 Junction 返回 `True`，未复现“false → alreadyAbsent”的具体分支；未使用模拟对象冒充真实 Junction。
- **Release E2E / Migration 回滚 / EXE 哈希：** 见 `T1-04-REPORT.md` 第 12.5 节与本目录 `release-exe.sha256`。

详细逐文件说明见 [`evidence/round6-remediation/README.md`](evidence/round6-remediation/README.md)。

> 证据边界：上述为开发代理执行结果，不构成独立审计或用户验收。T1-03 历史证据、审计状态、PR #8、P2-01 与 DEC-029 / Issue #2 风险均未改变。
