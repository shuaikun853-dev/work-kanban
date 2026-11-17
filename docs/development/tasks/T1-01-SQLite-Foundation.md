# T1-01：正式工程骨架、便携路径接入与 SQLite 基础设施

**任务状态：** 待开始  
**任务阶段：** 阶段 1：基础架构与工作事项  
**执行方式：** 用户 Windows 10 本机 DeepSeek Agent  
**授权日期：** 2026-11-17  
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
4. 检查 GitHub 仓库 shuaikun853-dev/work-kanban 的最新 main，确认已包含 DEC-028 和本任务说明。
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

**停止条件：** 上述核心验收项未满足，不得开始 T1-02 项目管理功能。
