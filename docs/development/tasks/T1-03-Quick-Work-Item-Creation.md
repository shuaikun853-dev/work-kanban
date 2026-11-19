# T1-03：工作事项快速创建和待安排区域

**任务状态：** 进行中（开发准备；归档项目是否可用于新建工作待用户确认）  
**启动日期：** 2026-11-19  
**所属阶段：** 阶段 1：基础架构与工作事项  
**前置任务：** T1-01、T1-02 已验收完成并合并到 main  
**开发分支：** `task/T1-03-quick-create-pending`  
**开发基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`  
**目标分支：** `main`  
**Pull Request：** 尚未创建（代码实现与自测完成后创建）  
**测试报告：** `docs/testing/reports/T1-03-REPORT.md`（开发完成后创建）

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
- **待用户确认：归档项目是否允许被新建工作选择。** T1-02 将归档项目作为只读记录保留，但 PRD/DEC 尚未明确新工作能否关联归档项目。开发代理不得自行允许或禁止；在用户确认前，不实现该策略，不得通过 UI 隐藏或后端拒绝来暗中确定规则。

### 3.3 未设置字段

- 快速创建不要求重要程度、紧急程度、截止日期、描述或计划日期。
- 未填写的 `importance` / `urgency` 不得伪造为某个评分；若本任务需要在 schema 中建立这些列，允许用 SQL NULL 表示“尚未设置”，非 NULL 值仍必须满足 1–5 约束。
- `due_date`、描述等未填写字段保持 NULL。
- 计划日期不是 `work_items` 的单一字段；每日计划属于 T2-01，T1-03 不创建 `daily_plans` 或 `daily_plan_items`，不安排工作日期。
- 不在本任务实现优先级评分、排序或补录编辑 UI；这些分别属于后续优先级/计划任务。

## 4. 待安排列表

- 从 SQLite 查询所有 `lifecycle_status = 'pending'` 的真实工作事项。
- 同时展示已归属项目与未归属项目的工作事项；项目名称作为辅助信息，未归属项明确显示“未归属项目”。
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
- 有效项目 ID 关联正确；不存在项目 ID 必须返回稳定业务错误。
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

## 10. 当前阻塞问题

**待用户确认：新建工作选择项目时，是否允许选择已归档项目？**

T1-02 明确归档项目只读保留，但现有 PRD / DEC 没有说明“新工作能否关联已归档项目”。在用户明确前，不得擅自将归档项目过滤、禁用或允许选择；其他不依赖该规则的任务准备工作可以继续。
