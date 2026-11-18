# T1-01：正式工程骨架、便携路径接入与 SQLite 基础设施

**任务状态：** **验收完成**（用户于 2026-11-18 明确接受第四轮独立审计交付及 DEC-029 中已接受但未修复的 TOCTOU 残余风险） \
**第一轮返工报告：** [T1-01-AUDIT-FIX-REPORT.md](../../testing/reports/T1-01-AUDIT-FIX-REPORT.md)（历史修复与测试记录） \
**第二轮独立审计：** [T1-01-SECOND-AUDIT-REPORT.md](../../testing/reports/T1-01-SECOND-AUDIT-REPORT.md)（历史） \
**第二轮返工修复报告：** [T1-01-SECOND-AUDIT-FIX-REPORT.md](../../testing/reports/T1-01-SECOND-AUDIT-FIX-REPORT.md)（历史） \
**第三轮独立审计报告：** [T1-01-THIRD-AUDIT-REPORT.md](../../testing/reports/T1-01-THIRD-AUDIT-REPORT.md)（R3 修复依据） \
**第三轮 R3 修复报告：** [T1-01-R3-FIX-REPORT.md](../../testing/reports/T1-01-R3-FIX-REPORT.md)（R3-01/R3-02 修复、测试与剩余风险） \
**第三轮机读证据：** [T1-01-R3-FIX-evidence.json](../../testing/reports/T1-01-R3-FIX-evidence.json) \
**第四轮独立审计报告：** [T1-01-FOURTH-AUDIT-REPORT.md](../../testing/reports/T1-01-FOURTH-AUDIT-REPORT.md) \\
**用户验收记录：** [T1-01-USER-ACCEPTANCE.md](../../testing/reports/T1-01-USER-ACCEPTANCE.md) \
**第二轮机器可读证据：** [T1-01-AUDIT-FIX-evidence.json](../../testing/reports/T1-01-AUDIT-FIX-evidence.json)（历史） \
**测试报告：** [T1-01-REPORT.md](../../testing/reports/T1-01-REPORT.md)（返工前历史证据） \
**Pull Request：** [PR #1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（已于 2026-11-18 10:07（北京时间） 合并至 main；合并提交 `260e6c07802a297529d8bda1e2d9239fca90fc10`）
**任务阶段：** 阶段 1：基础架构与工作事项  
**执行方式：** 用户 Windows 10 本机 DeepSeek Agent  
**授权日期：** 2026-11-17  
**计划启动时间：** 2026-11-17 18:00（北京时间），由用户在本机 DeepSeek 环境执行  
**权威依据：** PRD、技术设计 V0.4.0、DECISIONS.md、DEVELOPMENT_PLAN.md、AGENTS.md、STATUS.md

---

## 给 DeepSeek 的完整执行提示词

你现在负责 WorkManager 项目的第一个正式开发任务：**T1-01 正式工程骨架、便携路径接入与普通 SQLite 基础设施**。

不要只给建议或示例代码。你需要在当前本地 Git 仓库中检查现状、制定实施方案、编写代码、运行测试，并提交可审查的 Git 变更。严格遵守仓库根目录的 AGENTS.md。

### 1. 开始前检查

1. 确认当前目录是本地仓库（用户此前使用的路径为 D:/工作事项看板；若实际路径不同，以用户当前指定路径为准）。
2. 执行并报告：
   - git status --short
   - git branch --show-current
   - git remote -v
   - git log -1 --oneline
3. 不得覆盖、清理或重置用户未提交的修改。
4. 检查 GitHub 仓库 shuaikun853-dev/work-kanban 的最新 main，确认已包含 DEC-028、本任务说明，以及 T0-06 延期至阶段 6 的安排。T0-06 不属于 T1-01 阻塞项。
5. 阅读 AGENTS.md、PRD、决策记录、技术设计、开发计划和 STATUS。
6. 检查仓库是否已有实际 Tauri 源码。如果有，先理解并复用；如果目前只有文档，再创建正式工程骨架。

### 2. 当前机器已知环境

- Windows 10 Home China，OS Build 19045
- Node.js 22.20.0，npm 10.9.3
- Rust stable，rustc 1.100.0，Cargo 1.100.0
- MSVC Build Tools 2022，MSVC 14.44.35207
- Windows SDK 10.0.19041.0
- Git 2.52.0
- Rust 工具链和 VS Build Tools 安装在 D 盘，Rust 环境变量已配置

已验证的技术原型位于 D:/DevTools/verify/tauri-smoke。PortablePaths/WebView2 代码只作为参考，先检查文件，不得假设原型已经进入正式仓库。只移植必要逻辑，并在正式仓库补充测试。

### 3. 本任务目标与技术栈

建立可在用户 Windows 10 电脑上构建和运行的正式 WorkManager 工程，并完成最小 SQLite 数据基础设施。

- Tauri 2
- Svelte 5
- TypeScript
- Vite
- Rust
- rusqlite + 普通 bundled SQLite

**不要引入 SvelteKit，除非先提供官方模板/构建证据和必要性分析，并暂停等待用户确认。**

### 4. 明确禁止事项

- 不实现六位数字应用密码、登录页、应用锁屏或密码找回。
- 不引入 SQLCipher、DPAPI、数据库密钥文件或加密插件。
- 不把普通 SQLite 描述为加密数据库。
- 不引入云同步、账号登录、遥测、远程数据库或在线授权。
- 不让 Svelte 前端直接访问 SQLite、执行 SQL 或传入任意 SQL。
- 不在本任务实现项目 CRUD、工作事项 CRUD、每日计划、复盘、报表或附件功能。
- 不进行无关重构，不擅自修改 PRD 中已确认的业务规则。
- 不删除或覆盖用户现有数据库、文件或未提交代码。
- 不把真实工作数据、客户信息、附件路径或本机敏感信息提交到 Git。

### 5. 便携路径要求

沿用 T0-02/T0-03 已验证的路径设计：

- Release：从当前 EXE 所在目录定位便携根目录，数据库路径为 EXE 同级目录下的 data/database/work.db。
- WebView2 数据目录使用 Rust 侧绝对路径：EXE 同级目录下的 data/cache/webview2。
- Debug/Test：只允许通过测试专用的 WORKMANAGER_TEST_PORTABLE_ROOT 指定隔离测试根目录；Release 必须忽略该变量。
- 不得回退到 AppData、LocalAppData、系统 Temp 或 C 盘。
- D 盘路径不存在、不可写、父目录被文件阻塞时，必须返回清晰错误，不得静默创建到其他位置。
- 不得在 D:/WorkManager 中运行开发态测试，避免污染未来正式便携目录。
- 所有测试使用独立临时目录；测试清理只能删除测试自身创建的文件。

### 6. SQLite 基础设施要求

1. 数据库文件：data/database/work.db。
2. 使用普通 SQLite bundled feature，不使用 SQLCipher。
3. 由 Rust 后端独占数据库访问；前端只能调用受限的 Tauri command。
4. 使用 PRAGMA user_version 管理 schema 版本。
5. 建立编号 SQL migration 机制，例如 0001_initial.sql；migration 必须按顺序执行。
6. 每个 migration 必须在事务中执行；失败时回滚，user_version 不得错误前进。
7. 开启并验证 PRAGMA foreign_keys = ON。
8. 配置合理的 busy_timeout。
9. 可采用 WAL 模式；测试时必须检查 WAL/SHM 处理、关闭连接和重启后的数据库一致性。
10. synchronous 设置优先考虑数据可靠性，并记录实际值与选择理由。
11. 使用参数化 SQL；不得把用户输入拼接进 SQL。
12. 设计清晰的数据库错误类型，区分路径不可写、数据库打不开、migration 失败、完整性检查失败和磁盘空间不足。
13. 数据库已经存在但损坏、版本不兼容或 migration 失败时，绝不能自动删除并创建空数据库。
14. 初始化过程必须可恢复：新库应先在临时数据库文件完成 schema 初始化和检查，再安全地安装为正式数据库文件；说明 Windows 文件替换/重命名行为及回滚策略。
15. 运行 PRAGMA integrity_check 并验证结果为 ok。

可使用 rusqlite 的 bundled 和 backup feature。不要为了 migration 引入庞大 ORM；优先采用简单、可测试的 user_version + SQL 文件方案。若选择额外 migration crate，必须说明必要性并先检查许可证和维护状态。

### 7. 推荐模块边界

按当前项目结构选择合理实现，不要求机械照搬：

- portable_paths：解析数据根目录和各子目录。
- database：连接创建、PRAGMA 初始化、schema 版本检查。
- migrations：按版本执行 SQL migration。
- core：为后续业务模块预留独立边界。
- commands：只暴露健康检查/版本信息等最小命令。

数据库连接不要暴露给前端。不要新增任意 SQL command。

### 8. 最小可演示功能

本任务完成时，应用至少应具备：

- 正式 Tauri 窗口可以启动。
- Svelte 页面正常显示 WorkManager 名称和当前应用版本。
- 页面调用一个受限 Rust command，返回数据库状态、schema 版本和数据库所在便携路径（仅用于开发诊断，不返回用户工作内容）。
- 数据库首次启动时自动初始化 schema。
- 重启后能打开同一数据库，不重复初始化或覆盖已有数据。
- 在测试环境可执行一次数据库健康检查。

### 9. 必须运行的测试

至少执行并记录：

- cargo fmt --check
- cargo check
- cargo test
- npm run check
- npm run build
- npm run tauri build -- --no-bundle（若当前 CLI 版本不兼容，记录实际替代命令和原因）
- Release 构建可启动验证（条件允许时）
- SQLite migration 从空库初始化测试
- 已是最新版本时重复启动/迁移无副作用测试
- migration 中途失败时事务回滚测试
- foreign_keys 实际约束测试
- 数据库损坏或无法打开时不自动覆盖原库测试
- D 盘路径不可写/目录被文件阻塞时 fail-closed 测试
- Debug/Test 测试根目录隔离测试
- Release 忽略 WORKMANAGER_TEST_PORTABLE_ROOT 的测试
- 关闭应用再启动后数据持久化测试

所有测试使用虚构数据，不要用真实工作内容做 canary。

### 10. Git 与交付

1. 使用独立分支：task/T1-01-sqlite-foundation。
2. 提交前检查 git diff --check、git status --short 和完整 diff。
3. 不要把 target/、node_modules/、构建产物、数据库文件、日志或机器专属配置提交到仓库。
4. 测试通过后更新开发计划、STATUS，并新增 docs/testing/reports/T1-01-REPORT.md。
5. 只有在代码和测试已提交后，才推送分支并创建 PR。
6. 不得直接推送到 main。
7. 如果测试失败，保留真实失败状态并提交可审查的修复或阻塞说明，不得虚报通过。

### 11. 交付汇报

最终必须报告：

- 实际创建/修改的文件。
- 工程技术栈及实际依赖版本。
- 数据库 schema 版本和 migration 文件。
- SQLite PRAGMA 实际配置。
- 便携路径实际结果。
- 每条测试命令、退出码和摘要。
- Release EXE 路径、大小和 SHA-256（如果已构建）。
- Git 分支、commit SHA、PR 链接。
- 尚未完成的验收项和风险。
- 明确说明：T1-01 只完成基础设施，不代表项目/工作事项业务功能已实现。

遇到无法确认的架构选择、破坏性数据操作或用户决策冲突时，先停止相关操作并提出一个关键问题；不得猜测后继续。

---

## T1-01 验收清单

- [ ] 正式 Tauri 2 + Svelte 5 + TypeScript + Vite 工程可构建。
- [ ] Rust Core/基础设施边界清晰。
- [ ] Release 数据路径跟随 EXE 位置。
- [ ] WebView2 使用便携目录绝对路径。
- [ ] 普通 SQLite bundled 构建成功。
- [ ] user_version migration 可重复、安全执行。
- [ ] migration 失败可回滚。
- [ ] 外键约束实际生效。
- [ ] 数据库异常时不会自动覆盖原库。
- [ ] 前端不能直接执行 SQL。
- [ ] Debug/Test 路径隔离，Release 忽略测试路径环境变量。
- [ ] 构建、静态检查和自动化测试通过。
- [ ] 测试报告、Git commit 和 PR 可追溯。

**历史停止条件（截至第四轮审计前）：** 上述核心验收项未满足，或 R3-01/R3-02 尚未完成独立复核，不得开始 T1-02。该条件现已满足，用户已验收 T1-01。后续 PR #1 合并及 T1-02 启动仍作为单独执行步骤，等待明确指示。TOCTOU 按 DEC-029 作为已接受但未修复的残余风险单独追踪，不得在报告中写成已修复。

---

## 第二轮独立审计返工执行记录（2026-11-17，开发代理）

**历史状态：** 第二轮返工当时仍在等待 TOCTOU 处置决定；2026-11-18 用户已按 DEC-029 接受该残余风险并延期至 Issue #2。R3-01/R3-02 已在后续第三轮返工中处理（见文末 R3 执行记录）。

| 审计问题 | 处理结果 | 专项测试 |
|---|---|---|
| R2-01 初始化锁后先检查孤儿 WAL，误判有效数据库活动 WAL | 已修复：取得锁后先重检主库；主库缺失时才检查孤儿 sidecar | 确定性真实双进程测试 3 项 PASS；零字节/孤儿 sidecar 回归 6 项 PASS |
| R2-02 Debug/Test 正式目录保护可被同卷 Junction 绕过 | 已修复：字符串 + 真实最终路径双重比较；创建目录/写探针/锁/数据库之前拒绝；Release 规则不变 | `tests/formal_root_protection.rs` 5 项 PASS；真实 `D:\WorkManager` 零触碰 |
| R2-03 真实卷身份与 TOCTOU | 部分修复：卷 GUID + NT 设备卷身份校验已实现并实机验证；TOCTOU 残余窗口未关闭，用户按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未宣称绝对保证 | 卷身份交叉核验 + SUBST→C 实测 PASS；D 盘真实路径回归 4 项 PASS；跨卷挂载点/映射网络盘标注未验证 |
| R2-04 GitHub 证据与进度过期 | 已修复：旧 evidence 标记历史；新增返工后机器可读证据与脱敏日志；更新 STATUS/计划/本任务说明/PR 描述 | 见[第二轮返工修复报告](../../testing/reports/T1-01-SECOND-AUDIT-FIX-REPORT.md) |

完整回归：`cargo test --workspace` 62 passed / 0 failed；Release 便携验证 106 项 0 FAIL；异常注入 73 项 0 FAIL；真实窗口 UI/IPC/CSP 21/21；Release EXE SHA-256 `849E803D2456B28DF8BABFE201E187FB0FC45B7104A5E2CD2FD34B1D4366019E`。

**历史门禁（第二轮返工）：** TOCTOU 残余风险已按 DEC-029 接受并延期，不再单独阻塞 T1-01；R3-01/R3-02 已在第三轮返工中修复，见文末记录。


## 第三轮独立审计与用户风险决策（2026-11-18）

- 第三轮审计发现：R3-01（D 根卷信任锚未独立验证，P1）和 R3-02（真实双进程测试未严格证明 waiter 已观察到锁竞争，P2）。详见[第三轮独立审计报告](../../testing/reports/T1-01-THIRD-AUDIT-REPORT.md)。
- 用户明确选择接受现有 TOCTOU 残余风险：不要求在 T1-01 内实施完整句柄相对改造/custom SQLite VFS。该决定记录为 DEC-029。
- TOCTOU 仍然未修复，不能声称任何情况下都不会写入 C 盘；禁止静默回退 C 盘和已检测边界违规 fail-closed 规则不变。
- 后续完整加固单独跟踪：[Security Hardening Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。仅建立跟踪项，不代表已授权立即实施。
- 当前 T1-01 的剩余工作（当时）：修复 R3-01、补强 R3-02，随后重新独立审计。PR #1 保持打开、不合并；main 不修改；T1-02 不得开始。

---

## 第三轮审计 R3 返工执行记录（2026-11-18，开发代理）

**第三轮返工完成时状态：** **独立审计通过，待用户验收**（R3-01/R3-02 已修复并通过完整回归；TOCTOU 按 DEC-029 接受延期、未修复；开发代理自测不等同独立审计通过）。用户随后已于 2026-11-18 验收，当前任务状态见本文件开头及用户验收记录。

| 审计问题 | 处理结果 | 专项测试 |
|---|---|---|
| R3-01 D 盘根卷作为信任锚但自身未独立验证（P1） | 已修复：生产路径独立验证 D 根为真实卷挂载点（`GetVolumeNameForVolumeMountPointW`）、挂载点 GUID 与根目录句柄 `VOLUME_NAME_GUID` 一致、`QueryDosDeviceW` 映射为真实 NT 设备卷且与句柄 `VOLUME_NAME_NT` 一致、D 根与 C 根不同卷；任一步失败 `path-root-trust-anchor-invalid`，在创建目录/写探针/初始化锁/数据库之前 fail-closed；保留原有卷类型白名单、真实路径、目标卷身份与 Junction 检查 | 6 项 PASS：真实 D 盘（挂载点 GUID=`\\?\volume{519fbe4e-…}` 与句柄一致、NT=`\device\harddiskvolume4`、D≠C）；真实 SUBST Q:→C: 候选根在信任锚阶段拒绝；注入模拟 GUID 不一致/D==C/DOS 别名拒绝；API 失败 fail-closed |
| R3-02 真实双进程初始化锁测试同步确定性不足（P2） | 已修复：`#[cfg(test)]` 锁竞争观察点只在 `LockFileEx` 明确返回锁竞争时通知；waiter 走完整 `Database::initialize()`，真实竞争后才写 `b-lock-contention`；creator 收到确认后才创建数据库与活动 WAL；父进程确认后才放锁。观察点不进入生产构建、不是 IPC、不改变锁语义 | 专项测试 3 项 PASS；**10/10 连续多轮真实进程运行通过**；主库 20480 B / 活动 WAL 8272 B；无 orphaned-sidecar；integrity=ok；migrations=1 |
| TOCTOU（R2-03 遗留） | 按 DEC-029 **接受并延期，未修复**：不实施完整句柄相对改造/custom SQLite VFS，转入 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)；不得宣称绝不写入 C 盘 | 不在本轮范围 |

**完整回归：** `cargo test --workspace` **68 passed / 0 failed**（上轮 62，新增 6 项 R3-01 测试）；Release 便携验证 **106 项 0 FAIL**；异常注入 **73 项 0 FAIL**；真实窗口 UI/IPC/CSP **21/21、CSP 违规 0**；Release EXE **9,993,216 字节**，SHA-256 `41A8F6B4759107625487FE605820FAABF20D312A560AE9765949027D100F7800`。修复代码提交：R3-01 `ae1eb65`、R3-02 `4942eb0`。

**第三轮审计当时的门禁（历史记录）：** 当时 T1-01 尚待独立审计；第四轮复核及用户验收现已通过，T1-01 当前为验收完成。PR #1 仍未合并，main 未修改；T1-02 未开始。证据见 [T1-01-R3-FIX-REPORT.md](../../testing/reports/T1-01-R3-FIX-REPORT.md) 与 [T1-01-R3-FIX-evidence.json](../../testing/reports/T1-01-R3-FIX-evidence.json)。


## 第四轮独立审计结论（2026-11-18）

- R3-01 P1：通过代码与证据复核。生产路径确实执行 D 根卷信任锚验证；真实 D 盘、真实 Q:→C: SUBST 和注入负向测试证据已核对。
- R3-02 P2：通过代码与证据复核。观察器仅在 `cfg(test)` 存在，只在底层锁操作明确返回竞争时通知；waiter 走完整 `Database::initialize()`；10/10 轮日志已核对。
- 本轮未在开发代理 Windows 10 主机独立重放测试；仓库当前没有 GitHub Actions/status checks。证据边界和非阻塞观察项详见[第四轮独立审计报告](../../testing/reports/T1-01-FOURTH-AUDIT-REPORT.md)。
- 当前状态：**T1-01 验收完成**（用户于 2026-11-18 明确确认）。PR #1 已于 2026-11-18 10:07（北京时间） 合并至 main（`260e6c07802a297529d8bda1e2d9239fca90fc10`）；T1-02 尚未开始。
- TOCTOU 仍未修复，按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)；不得宣称绝对 D 盘写入保证。


## 用户验收记录（2026-11-18）

用户明确回复“接受”，确认接受 T1-01 当前交付结果，包括第四轮独立审计通过结论，以及 DEC-029 中已接受但未修复的 TOCTOU 残余风险。T1-01 正式标记为**验收完成**。

- 验收记录：[T1-01-USER-ACCEPTANCE.md](../../testing/reports/T1-01-USER-ACCEPTANCE.md)
- PR #1 已于 2026-11-18 10:07（北京时间） 按用户明确授权合并至 main，采用 Merge commit；合并提交 `260e6c07802a297529d8bda1e2d9239fca90fc10`。
- T1-02 未开始，等待单独启动指示。
- TOCTOU 仍由 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2) 跟踪，未修复。


## PR 合并记录（2026-11-18）

用户随后明确授权合并 PR #1。GitHub 已确认合并成功，PR 状态 Closed / Merged；采用 Merge commit，保留完整提交历史。合并提交：`260e6c07802a297529d8bda1e2d9239fca90fc10`。T1-02 尚未开始，等待单独启动指示；TOCTOU 仍由 Issue #2 跟踪，未修复。
