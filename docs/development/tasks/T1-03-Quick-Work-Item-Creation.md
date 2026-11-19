# T1-03：工作事项快速创建和待安排区域

**任务状态：** 第二轮定向修复完成，等待第二轮独立审计（PR #8 保持 Open，未合并）
**启动日期：** 2026-11-19  
**所属阶段：** 阶段 1：基础架构与工作事项  
**前置任务：** T1-01、T1-02 已验收完成并合并到 main  
**开发分支：** `task/T1-03-quick-create-pending`  
**开发基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`  
**目标分支：** `main`  
**第一轮实现提交：** `be8d9c2e9c78710690de189936d6ee65f48ed8df`
**第二轮修复提交：** P2-02 `12b1bdf026f01688c79ba438165a97a652e086a1`；P3-01/P3-02 `2d91c92301713597ccfc1c0ddc2d83a479f572d4`；P2-01 历史清理 `b6cf344abc1693e7031427f8963c27474c0b59f9`
**Pull Request：** [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8)（指向 main，保持 Open，等待第二轮独立审计）
**测试报告：** `docs/testing/reports/T1-03-REPORT.md`
**截图与证据：** `docs/testing/reports/T1-03-assets/`
**开发设计：** `docs/development/tasks/T1-03-Implementation-Design.md`

## 1. 权威依据

开发前必须阅读并以 main/本任务分支的最新版本为准：

1. `docs/requirements/PRD.md`
2. `docs/architecture/TECHNICAL_DESIGN.md`
3. `docs/decisions/DECISIONS.md`
4. `docs/design/UI-DESIGN-SPEC.md`
5. `docs/design/assets/workmanager-ui-prototype.svg`
6. `docs/development/DEVELOPMENT_PLAN.md`
7. `docs/STATUS.md`
8. `AGENTS.md`
9. T1-01 / T1-02 的任务说明、测试报告、独立审计报告和已合并代码

发现文档与代码不一致时，先核对最新用户决策；不得自行改变 PRD、DEC 决策或 UI 基线。

## 2. 任务目标

交付“工作事项快速创建 + 待安排列表”的完整纵向切片，包含：

- SQLite 版本化 migration；
- Rust Core 工作事项模型、仓储与应用服务；
- Tauri typed IPC 命令与 DTO；
- TypeScript Contracts / Bridge；
- 紧凑桌面 UI：快速录入、项目选择、待安排列表；
- 自动化测试、Release 实际运行验证、截图和 GitHub 证据。

## 3. 已确认需求与实现边界

### 3.1 快速创建

- 用户快速录入工作时，只要求填写**工作标题**即可立即保存，不要求先填写重要程度、紧急程度或计划日期。
- 标题首尾空白应规范化；空标题或纯空白标题必须拒绝，并返回稳定错误码及可理解的中文消息。
- 新建工作事项的生命周期状态必须默认为**待安排**。
- 相同标题可以创建多条不同工作事项；标题不是业务唯一键，不得做标题去重或覆盖旧记录。
- Rust Core 生成稳定 UUID；前端不得自行生成业务 ID。
- 快速创建成功后，UI 必须从 Rust Core/SQLite 重新读取权威数据，不得只在前端插入临时对象。

### 3.2 项目关联

- 新工作允许暂时不归属项目；未选择项目时，`project_id = NULL`，并在待安排列表中清楚显示“未归属项目”。
- T1-03 的单条工作事项最多关联一个项目；多项目选择时为每个项目创建独立工作事项副本属于 T1-04（DEC-007），不得在本任务实现多项目共享同一条可变工作记录。
- 项目选择必须使用 T1-02 的真实项目列表与稳定项目 ID；禁止前端自行维护项目副本或使用项目名称作为关联键。
- **已确认规则（DEC-033）：新建工作只能关联未归档项目。** 项目选择器必须仅展示 `isArchived === false` 的项目；已归档项目不得显示为可选项。现有 `list_projects` 仍按 T1-02 契约返回全部项目（含归档项目），不得改变设置页项目管理和历史展示行为；前端选择器只过滤可选项。
- Rust Core 必须在创建工作事项的同一个 `IMMEDIATE` 写事务内验证所选项目存在且 `is_archived = 0`，防止项目列表加载后、用户提交前项目被归档的竞态。项目不存在返回 `project-not-found`；项目已归档返回稳定错误码 `project-archived`。不得只依赖前端过滤。
- 未选择项目时 `project_id = NULL`，允许创建“未归属项目”工作；没有任何未归档项目时仍必须允许不归属项目创建。
- 项目归档不删除或改写既有工作事项的 `project_id`；历史关联必须保留。

### 3.3 未设置字段

- 快速创建不要求重要程度、紧急程度、截止日期、描述或计划日期。
- 未填写的 `importance` / `urgency` 不得伪造为某个评分；若本任务需要在 schema 中建立这些列，允许用 SQL NULL 表示“尚未设置”，非 NULL 值仍必须满足 1–5 约束。
- `due_date`、描述等未填写字段保持 NULL。
- 计划日期不是 `work_items` 的单一字段；每日计划属于 T2-01，T1-03 不创建 `daily_plans` 或 `daily_plan_items`，不安排工作日期。
- 不在本任务实现优先级评分、排序或补录编辑 UI；这些分别属于后续优先级/计划任务。

## 4. 待安排列表

- 从 SQLite 查询所有 `lifecycle_status = 'pending'` 的真实工作事项。
- 同时展示已归属项目与未归属项目的工作事项；项目名称作为辅助信息，未归属项明确显示“未归属项目”。
- 不得因为关联项目后来被归档而从待安排列表隐藏已有工作事项；保留原 `project_id` 与项目名称关联。必要时用轻量“项目已归档”辅助标识，不得把这类历史关联误当成可选项目。
- 列表不得混入未开始、进行中、已完成或已放弃事项。
- 使用稳定的工作事项 ID 作为 Svelte keyed each key。
- 列表顺序必须稳定且可测试；本任务可使用创建时间倒序、ID 作为稳定次级键，不实现可配置排序或手动置顶。
- Loading、空列表、加载失败、创建失败和创建成功后的刷新状态必须明确；不得展示演示数据或虚构统计。
- UI 入口不得新增一级侧边栏项目。UI 规范 V1.1 固定六个一级导航；待安排应作为现有工作页面下的次级视图/入口实现，具体组件树和影响文件清单须在编码前列出，并遵守 UI 规范的信息密度。

## 5. 允许修改范围

预期涉及（以实际代码结构为准，不要求机械照抄）：

- `crates/workmanager-core/migrations/0003_work_items.sql`
- `crates/workmanager-core/src/database/migrations.rs`
- `crates/workmanager-core/src/work_items/**`
- `crates/workmanager-core/src/lib.rs`
- `src-tauri/src/app_state.rs`
- `src-tauri/src/commands/work_items.rs`
- `src-tauri/src/commands/mod.rs`
- `src-tauri/src/lib.rs`
- `src/lib/contracts/workItems.ts`
- `src/lib/bridge/workItems.ts`
- `src/lib/features/work-items/**`
- `src/lib/features/today/**`（仅 T1-03 必要入口/集成）
- `src/App.svelte` / `src/app/navigation.ts`（仅当建立不新增一级导航的次级视图确有必要）
- 对应测试、测试报告、截图与开发文档。

不得为了本任务重构无关模块、批量修改设计 Token、重写 AppShell/Sidebar、改变 T1-02 项目管理行为或修改已验收 T1-01 便携路径/数据库初始化逻辑。

## 6. 明确不在本任务范围

- T1-04：一次选择多个项目并创建独立工作事项副本（包括 creation group/member 关系）。
- T1-05：生命周期状态流转、工作事项历史记录及完成/放弃操作。
- T2-01：每日计划、安排日期、未来 7 天计划。
- T2-02/T2-03：重要程度/紧急程度评分、全局优先级、手动置顶和排序。
- T2-04：每日计划顺序。
- T2-05/T2-06：当前工作指针、切换、暂时跳过和待补充进度。
- T3：每日复盘与提醒。
- T4：工作日志、历史搜索和报表。
- T5：附件、数据清理和备份恢复。
- 工作事项删除、批量创建、周期任务、标签、评论、协作、云同步、遥测。
- 未经确认不得增加新的 UI 一级导航、图表、完成率、统计卡片或演示数据。

## 7. 数据与架构要求

- schema 从当前版本 2 升级到版本 3；新增 migration 必须按现有迁移引擎规则执行，独立 IMMEDIATE 事务、失败回滚，`user_version` 不得错误前进。
- 不得修改或覆盖现有 projects、settings 或用户数据库；必须验证从 schema 2 的真实数据库升级后项目记录保持不变。
- `work_items` 至少包含当前纵向切片需要的稳定 ID、可空 project_id、title、lifecycle_status、创建/更新时间；如果按技术设计一次建立后续字段，未设置的字段必须允许 NULL，并具备相应 CHECK 约束。
- `project_id` 外键必须正确处理未归属项目；不得级联删除项目或工作记录。项目物理删除不是本任务功能。
- 标题校验、项目存在性校验、默认状态和事务边界属于 Rust Core，不得仅由前端保证。
- 数据库访问只在 Rust Core；所有 SQL 使用参数绑定；命令层只做 DTO、spawn_blocking、错误转换。
- IPC 使用 `deny_unknown_fields` 和 serde camelCase；前端 DTO 必须与 Rust 返回值逐字段一致，并做运行时契约校验。
- 不新增 ORM、migration crate 或其他第三方依赖。
- 不记录工作标题、项目名称、客户信息或 SQL 参数值到日志。
- 保持普通 SQLite、本地 D 盘便携目录、不上传数据的现有约束。

## 8. 测试与验收标准

### 8.1 Rust Core / SQLite

- schema 2 -> 3 migration 成功；已有项目数据保留；migration 重复执行安全。
- 注入 migration 失败时事务回滚，schema 版本不前进，不留下半成品表。
- 仅标题即可创建工作事项，首尾空白规范化，空标题被拒绝。
- 创建后状态严格为 pending；未设置的优先级/日期字段没有伪造默认值。
- 不同请求即使标题相同，也生成不同 ID 和独立记录。
- project_id 为 NULL 时可创建并在查询中返回未归属状态。
- 有效且未归档项目 ID 关联正确；不存在项目 ID 返回 `project-not-found`；已归档项目 ID 返回 `project-archived`。
- 前端项目选择器只展示未归档项目；即使通过伪造 IPC 请求绕过 UI，Core 仍拒绝已归档项目；已有工作事项对该项目的关联不受归档操作影响，且仍能在待安排查询中正确显示。
- 项目列表加载后、提交前项目被归档的竞态必须由 Core 事务内校验兜底；并发归档/创建不得产生已归档项目的新工作关联。
- 待安排查询只返回 pending；其他生命周期状态不混入；有/无项目的记录均正确返回。
- 关闭数据库、SQL 错误和约束失败时返回结构化错误，不 panic、不泄露 SQL/工作内容。

### 8.2 Tauri IPC / Frontend

- create/list 请求与响应 camelCase 契约测试通过；未知字段拒绝。
- SQLite 工作在 spawn_blocking，不阻塞 UI 主线程。
- Bridge 对返回 DTO 做运行时校验；错误码和中文错误信息可正确显示。
- 快速创建仅要求标题；可不选择项目；成功后重新读取后端列表。
- 待安排列表真实读取 SQLite 数据，能区分项目名称与“未归属项目”。
- 覆盖 loading、empty、error、submit、重复点击/并发提交保护和成功刷新。
- 不新增前端测试框架依赖；沿用仓库已有质量门禁和 Release UI 验证方式。

### 8.3 Windows Release / 回归

至少执行并保存原始结果：

- `cargo fmt --all -- --check`
- `cargo check --workspace --all-targets`
- `cargo test --workspace`
- `npm run check`
- `npm run build`
- `git diff --check`
- 现有 Release UI E2E / 便携与异常保护验证中受影响的回归项。
- Windows 10 目标环境 Release 实际启动；在独立 UAT 目录创建虚构工作事项，关闭重开后确认数据仍存在。
- 固定窗口与最小窗口截图；检查无横向溢出、遮挡、按钮不可点击、标题裁切和控制台异常。
- 验证数据库仍位于便携 D 盘目录；不得用真实用户工作标题或真实项目数据作为测试数据。

截图和原始测试输出保存到 `docs/testing/reports/T1-03-assets/` 及报告中。不得只写“测试通过”，必须给出命令、环境、结果和证据路径。

## 9. 开发流程与停止条件

1. 确认本地仓库、remote、当前分支、工作区状态和最新 main；不得丢弃任何未提交改动。
2. checkout 本任务分支，核对基线 commit。
3. 阅读本任务列出的权威文档和 T1-02 实际代码。
4. 在编码前提交组件树/页面状态流、影响文件清单、数据模型/IPC 契约草案和测试计划；不得直接重写整个 TodayPage。
5. 优先 TDD：先写失败测试，确认真实失败，再实现最小纵向切片。
6. 完成测试、Release 实测、截图和 `git diff --check`。
7. 更新 `docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md` 和 `docs/testing/reports/T1-03-REPORT.md`，记录真实 commit SHA、测试环境和未完成项。
8. 只提交 T1-03 范围内的变更，推送本任务分支并创建指向 main 的 PR。
9. PR 创建后停止，等待独立审计；不得自行宣布审计通过、用户验收完成、合并 PR 或开始 T1-04。

## 10. 已确认的关键业务规则

2026-11-19，用户明确确认：**新建工作不允许选择已归档项目**（DEC-033）。本规则已同步写入 PRD V0.3.2 和 DECISIONS.md。

开发实现必须同时满足：选择器仅展示未归档项目；Rust Core 在创建事务内拒绝已归档项目 ID（`project-archived`）；不归属项目仍可创建；归档不改变已有工作事项的历史项目关联。此项不再是阻塞问题。
---

## 11. 开发执行结果（2026-11-19，待独立审计）

**状态：** 代码实现与开发自测完成；PR #8 等待独立审计。开发代理不自行宣布审计通过或验收完成。

**实际交付：**

- **数据库：** migration `0003_work_items.sql`，schema 2 → 3；`work_items` 表（稳定 ID、可空 `project_id` + `ON DELETE RESTRICT`、标题 CHECK、生命周期 CHECK、可空评分/日期/描述、时间戳、待安排查询索引）；未修改 0001/0002。
- **Rust Core：** 新增 `crates/workmanager-core/src/work_items/**`；创建时标题规范化、Rust Core 生成 UUID、默认 `pending`；**项目存在性与归档校验与插入在同一个 `IMMEDIATE` 写事务内（DEC-033）**；待安排查询只返回 `pending`，含未归属与归档项目历史关联。
- **Tauri IPC：** `create_work_item` / `list_pending_work_items`；serde camelCase、`deny_unknown_fields`、`spawn_blocking`、结构化错误码 `work-item-title-empty` / `project-not-found` / `project-archived`。
- **前端：** 今日工作页下的“待安排”次级视图（不新增一级导航）+ 独立快速创建组件；选择器只展示未归档项目；loading/empty/error/list/重复提交保护；创建成功后从后端重新读取；项目归档竞态显示 `project-archived`；归档项目历史关联保留并显示“项目已归档”。
- **验证工具：** T1-03 Release E2E（主检查 70 / 最小窗口 12 / 重启持久化 17 / 数据库探针 25，全部 PASS，两次真实关闭退出码 0）；Bridge 运行时契约 Node 测试 10 项接入 `npm run check`；继承便携（106 项）、异常注入（73 项）、T1-02 UI E2E 回归通过。

**质量门禁：** `cargo fmt --check`、`cargo check --workspace --all-targets`、`cargo test --workspace`（123 passed / 0 failed）、`npm run check`、`npm run build`、`git diff --check` 全部退出码 0。

**Release 产物：** `target\release\workmanager.exe`，10,351,616 字节，SHA-256 `22af942fe2817388596118fc7cb66f34fce4e8c5e2367fe1a2942dc13dd66b23`。

**详细报告：** `docs/testing/reports/T1-03-REPORT.md`；证据：`docs/testing/reports/T1-03-assets/`。
**停止条件：** 已停止开发，等待独立审计；未合并 PR、未修改 main、未开始 T1-04/T1-05。

---

## 12. 第二轮定向修复结果（2026-11-19，等待第二轮独立审计）

第一轮独立审计未通过；本轮只修复四项审计问题，不新增业务功能、不修改业务决策。

**状态：** 第二轮定向修复完成；PR #8 保持 Open，等待第二轮独立审计。开发代理不自行宣布审计/验收通过。

**修复内容：**

- **P2-01 原始日志与机器信息：** 删除 `T1-03-assets/logs/` 9 个原始命令日志；11 个 JSON 证据脱敏（计算机名/账户名/用户目录/仓库与 UAT 绝对路径替换为占位符）；新增 `SANITIZATION.md`；重写本任务分支 docs/evidence 提交（旧 HEAD `2342828` → 新 HEAD `b6cf344`）并 `--force-with-lease` 推送；本地恢复分支 `backup/t1-03-r1-audit-baseline` 与仓库外 bundle 保留。当前证据扫描 0 命中；脱敏前后结构一致性 11/11；分支新增历史深度扫描 0 命中。
- **P2-02 Rust/TS DTO 契约：** `WorkItemDto` 与 Rust 统一为 10 个 camelCase 字段（含可空 `importance`/`urgency`/`dueDate`/`description`）；Bridge 严格拒绝缺字段、类型错误、非法状态与未知字段；Rust 增加完整字段/可空值序列化测试；Node 契约测试扩展为 17 项。
- **P3-01 创建提示时机：** 创建成功、列表刷新成功、刷新失败三态分离；刷新成功后才显示列表已更新；刷新失败显示 warning 并允许重新加载；不重复创建同一工作。
- **P3-02 UAT 路径安全：** 新增 `T1-03UatPath.ps1`，规范化路径后限定专用测试根目录 `D:\WorkManager-test-data\`，拒绝正式目录、根目录外、`..` 越界、已含数据库目录与非空未知目录；脚本不删除/不覆盖；新增 23 项专项测试。

**第二轮验证：**

- `cargo fmt --all -- --check` / `cargo check --workspace --all-targets`：退出码 0；
- `cargo test --workspace`：**124 passed / 0 failed**；
- `npm run check`：svelte-check 0/0、Bridge 17/17、Design Token 49/49；`npm run build`：退出码 0；
- Bridge DTO 专项：**17/17 PASS**；UAT 路径安全专项：**23/23 PASS**；
- T1-03 Release E2E：**主 84/84 + 最小窗口 12/12 + 重启持久化 17/17 + 数据库探针 25/25**，两次真实关闭退出码 0；
- 继承回归：便携 106 项（0 FAIL，保留 1 WARN）、异常注入 73 项（0 FAIL）、T1-02 UI E2E（73/73 + 12/12）全部通过；
- Release EXE：10,352,128 字节，SHA-256 `3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`。

**详细报告：** `docs/testing/reports/T1-03-REPORT.md`；证据：`docs/testing/reports/T1-03-assets/`（含 `SANITIZATION.md`）。
**停止条件：** 已停止，等待第二轮独立审计；未合并 PR #8、未修改 main、未开始 T1-04/T1-05。