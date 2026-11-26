# T1-03：工作事项快速创建和待安排区域

**任务状态：** 第五轮独立审计未通过（P1/F2 跟踪链接穿过未跟踪 Junction、P2/F1 证据写入身份、P3 摘要写入守卫、P4 部分删除语义）；本轮 P1–P4 + B1–B5 定向补正完成，等待第六轮独立审计复核（真实目录/Junction/悬空 Junction/硬链接与 Canary 验证通过，未修改 Windows ACL、未执行实际 `Access Denied` 测试；可复现 Red 证据 + 分开的 Green 证据；P2-01 仍开放，待 GitHub Support 服务端清理；PR #8 保持 Open，未合并）
**启动日期：** 2026-11-19  
**所属阶段：** 阶段 1：基础架构与工作事项  
**前置任务：** T1-01、T1-02 已验收完成并合并到 main  
**开发分支：** `task/T1-03-quick-create-pending`  
**开发基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`  
**目标分支：** `main`  
**第一轮实现提交：** `be8d9c2e9c78710690de189936d6ee65f48ed8df`
**第二轮修复提交：** P2-02 `12b1bdf026f01688c79ba438165a97a652e086a1`；P3-01/P3-02 `2d91c92301713597ccfc1c0ddc2d83a479f572d4`；P2-01 历史清理 `b6cf344abc1693e7031427f8963c27474c0b59f9`
**第三轮修复提交：** `b6a54591b783049142cbbffecd107ec9086723eb`；第三轮审计基准 HEAD `489d8689484c2cf744893bd3ee08dc7b25b5c8b8`
**第四轮修复提交：** `d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（F1/F2；随后为第四轮证据/文档同步提交）
**第五轮审计基准 HEAD：** `6ddae47dd0721d58d5cb11f55e527fc162cedbe9`；**第五轮修复提交：** `af2421e9207f7b9ac185b0d29c3a98f80b5eb11a`
**第六轮修复提交：** `e3bb86b30772159219a8eb16b90e55f3c69f4d59`（P1–P4 + B5 代码/测试/验证脚本；随后为证据/文档同步提交；`origin/main..最终 HEAD` = **30** 个提交）
**Pull Request：** [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8)（指向 main，保持 Open，等待第六轮独立审计）
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

## 13. 第三轮定向修复结果（2026-11-20，等待第三轮独立审计）

**状态：** 第三轮 P2-01/P3-02 定向修复完成；PR #8 保持 Open，等待第三轮独立审计。P3-02 已修复并完成本地验证；P2-01 **仍未关闭**（旧提交 `2342828` 仍可经 GitHub API 读取，GitHub Support 服务端清理未完成）。开发代理不自行宣布审计/验收通过。

**修复内容：**

- **P3-02 UAT 路径安全（原生 Windows 句柄校验）：** `scripts/verify/T1-03UatPath.ps1` 改用 `CreateFileW` + `GetFileInformationByHandleEx`（`FILE_ATTRIBUTE_TAG_INFO` / `FILE_ID_INFO`）+ `GetFinalPathNameByHandleW`，使用 `FILE_FLAG_BACKUP_SEMANTICS` + `FILE_FLAG_OPEN_REPARSE_POINT`；拒绝测试根自身及盘符根→输出目录每个已存在路径分量上的未批准 Junction/符号链接/其他重解析点；校验真实最终路径位于 `D:\WorkManager-test-data` 内且在 `D:\WorkManager` 外，并校验卷序列号（FileIdInfo）与盘符根/测试根一致；拒绝 UNC/设备/相对路径/非法字符/保留名/末尾点或空格；缺失输出父目录仅允许在已校验的安全存在祖先下；身份无法确认时 fail-closed；已批准重解析点白名单为空。`verify-t1-03-ui.ps1` 在创建 UAT 根后、创建应用目录后、复制 EXE 前后、每次应用启动前（数据库写入前）原生复验。TOCTOU 窗口已记录但**未消除**（DEC-029 / Issue #2 仍适用）。
- **路径安全测试：** `test-t1-03-uat-path.ps1` 原 23 项保留 + 新增真实 Junction/重解析点/无副作用检查 = **60 项，FAILED=0；SKIPPED=1 显式记录且不计为 PASS**（非管理员进程缺少 SeCreateSymbolicLinkPrivilege、未启用开发者模式，`mklink /D` 退出码 1）；真实 `mklink /J` 覆盖测试根自身、测试根路径分量、中间分量、输出目录、指向正式根、指向 C 盘、指向测试根内部共 7 类全部拒绝（重解析 tag `0xA0000003`）。
- **无副作用验证：** canary 文件、预置假数据库、EXE 复制与编排产物不变；Junction 目标未被触碰；正式根 `D:\WorkManager` 未被创建；清理只删除链接（非递归），目标 canary 完好；退出码 0。
- **P2-01 机器信息/原始日志历史对象：** 复扫当前分支与 PR #8 文本脱敏 0 命中（当前 assets 33 个文件、19 张 PNG；分支增量 18 个提交 / 5,773 次文件树扫描；PR 正文 2,091 字符、SHA-256 `4621bf70…f660`，2 条 issue 评论、0 review）；但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 仍可经 GitHub API 读取（HTTP 200），其 9 个原始 T1-03 命令日志（共 147,009 字节）仍可列出/下载。旧提交不可从 HEAD 到达，仅本地备份分支 `backup/t1-03-r1-audit-baseline` 与 gitignored 本地 bundle 引用、均未推送。GitHub Support 服务端清理未完成（工单材料已准备，需仓库所有者提交）；**P2-01 保持 OPEN/未关闭**，清理完成后必须做旧 SHA 暴露复检。

**验证结果：**

- 质量门禁（全部退出码 0）：`cargo fmt --all -- --check`、`cargo check --workspace --all-targets`、`cargo test --workspace`（**124 passed / 0 failed**，18 个测试套件）、`npm run check`（svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 / 0 违规；49/49）、`npm run build`、`git diff --check`。
- 路径安全专项：**60 项，FAILED=0；SKIPPED=1（已记录，不计为 PASS）**，退出码 0。
- T1-03 Release E2E（新 UAT 目录）：主 UI/IPC **84/84**、最小窗口 **12/12**、重启持久化 **17/17**、数据库只读探针 **25/25**；两次真实关闭退出码 0；CSP 违规 0。
- 继承回归（全部退出码 0）：便携 **106 项 PASS 90 / FAIL 0 / WARN 1（既有 WARN 保留）**；异常注入 **73 项 PASS 64 / FAIL 0**；T1-02 UI E2E 主 73/73 + 最小窗口 12/12 + 关闭退出码 0。
- Release EXE：`10,352,128` 字节，SHA-256 `3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`（产品代码未变，与第二轮一致）。

**证据：**

- 第三轮汇总（机器可读）：`docs/testing/reports/T1-03-assets/evidence/round3-verification-summary.json`
- 路径安全证据：`docs/testing/reports/T1-03-assets/evidence/t1-03-uat-path-evidence.json`（60 项）
- E2E 证据：`docs/testing/reports/T1-03-assets/evidence/` 下 t1-03-ui / min-window / persistence / orchestration / db-after-main / db-after-restart
- 报告：`docs/testing/reports/T1-03-REPORT.md`；证据索引：`docs/testing/reports/T1-03-assets/README.md`
- 第三轮修复提交：`b6a54591b783049142cbbffecd107ec9086723eb`（另有后续文档复核提交，PR #8 时间线可见）；第三轮前 HEAD `bad0688ee9de5e07f769d64d7fc44e3f182a960d`

**停止条件：** 已停止，等待第三轮独立审计；未合并 PR #8、未修改 main（基线 `018e851e8daf5835391a7b61caf881bc57c2ad42`）、未开始 T1-04/T1-05；不自行宣布审计/验收通过。

## 14. 第四轮定向修复结果（2026-11-20，等待第四轮独立审计）

**状态：** 第三轮独立审计未通过，阻塞项为 F1（测试根目录未验证就创建测试沙箱）与 F2（Junction 清理失败后仍递归删除），并要求修正证据/文档一致性。第四轮只修复 F1/F2 与证据一致性，仅修改验证脚本/测试脚本/文档，**未修改产品代码**、未新增业务功能、未修改业务决策、未重写历史、未强制推送。PR #8 保持 Open，等待第四轮独立审计。开发代理不自行宣布审计/验收通过。

**修复内容：**

- **F1 测试根目录信任锚：** `scripts/verify/test-t1-03-uat-path.ps1` 在任何写操作（创建沙箱 / `Set-Content` / Canary / 测试数据库 / 测试目录 / 复制 EXE / 启动应用）之前调用 `Assert-T103UatTrustedTestRoot`：用 Windows 原生文件系统句柄验证测试根目录存在、是真实目录、全部已存在祖先组件、拒绝未获批准的重解析点、真实最终路径与预期字面路径一致、卷身份一致、不在正式目录 `D:\WorkManager` 内；测试根目录缺失或身份无法确认时 **fail closed，且绝不自动创建测试根目录**。新增真实 Junction 把测试根替换为外部 Canary 目录后启动真实入口子进程的无副作用测试（exit=2、任何写操作之前拒绝执行、Canary 内容与目录结构不变、不创建沙箱、不写默认证据）；`-TestRootOverride` 注入参数仅用于故障注入、不影响正式默认路径，且不能执行完整套件；`verify-t1-03-ui.ps1` 同样在任何写操作前验证信任锚。信任锚验证与普通输出目录校验明确分离（不只复用子目录校验逻辑）。
- **F2 清理 fail-closed：** 新增 fail-closed 沙箱清理：清理前复验沙箱身份（卷序列号 + 文件 ID + 真实最终路径），逐个删除并复验所有已创建 Junction/Symbolic Link，扫描整个沙箱确认无未预期 reparse point，再次复验身份；任一条件不满足立即停止（**不执行整个沙箱递归删除**），保留沙箱与外部目标目录，输出明确 WARN/FAIL 与可定位路径。仅当全部条件满足时才执行逐条目校验后的安全递归删除，绝不跟随 Junction/Symbolic Link 进入外部目录。新增场景验证：正常删除、链接删除后重建、未跟踪 reparse point、清理前身份替换及失败后 Canary 复检均使用真实文件系统对象；其中“链接删除失败”由受控 `FaultHook` 在 `beforeLinkDelete` 阶段抛出确定性异常，未修改 Windows ACL，也未实际执行 Windows ACL 拒绝/`Access Denied` 测试。
- **原有测试零回归：** 第三轮 60 项检查全部保留（硬校验 `evidence.round3ChecksPreserved`），第四轮新增 31 项目标检查全部存在（`evidence.round4NewChecksPresent`）；不得把 SKIP 统计成 PASS。

**验证结果：**

- 路径安全专项（`test-t1-03-uat-path.ps1`，第四轮证据路径）：**93 项，FAILED=0；SKIPPED=1（Symbolic Link 权限限制，明确记录、不计 PASS）**；原有 60 项全部保留；F1/F2 新增 31 项全部通过；信任锚 PASS；主套件沙箱清理 SAFE（无遗留）；退出码 0。
- 质量门禁（全部退出码 0）：`cargo fmt --all -- --check`、`cargo check --workspace --all-targets`、`cargo test --workspace`（**124 passed / 0 failed**，18 个测试套件）、`npm run check`（svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 0 违规；49/49）、`npm run build`（167 modules）、`node --test scripts/quality/work-item-bridge.test.mjs`（17/17）、`git diff --check`。
- T1-03 Release E2E（新 UAT 目录 `<uat-root>\t1-03-ui-r4-20261120-181549`，不覆盖第三轮证据）：主 UI/IPC **84/84**、最小窗口 **12/12**、重启持久化 **17/17**、数据库只读探针 **25/25**；两次真实关闭退出码 **0/0**；CSP 违规 0；页面未捕获异常 0。
- 继承回归（全部退出码 0）：便携 **106 项 PASS 90 / FAIL 0 / WARN 1（既有 WARN 保留）**；异常注入 **73 项 PASS 64 / FAIL 0**；T1-02 UI E2E 主 73/73 + 最小窗口 12/12 + 关闭退出码 0（首次执行出现窗口尺寸/加载超时的环境性失败，无并发负载下单独重跑通过；产品代码与 T1-02 验证脚本未修改）。
- Release EXE：`10,352,128` 字节，SHA-256 `3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`（产品代码未变，与第二/三轮一致）。

**证据与数据一致性：**

- 第四轮证据（不覆盖第三轮）：`docs/testing/reports/T1-03-assets/evidence/round4/`（路径安全 93 项证据、脱敏后的 UAT 证据 JSON、19 张第四轮实测截图、`round4-verification-summary.json` 机器可读汇总）。
- 重新采集：当前分支 HEAD、main HEAD、`main..HEAD` 提交数（扫描时 22，含证据同步提交）、分支增量扫描数量、T1-03-assets 实际文件数（62）/PNG 数（38）、PR #8 正文长度（3,957 字符）/SHA-256（`725d5df3…0ae0`）、PR 全部评论数量（4 条 issue 评论、0 review comment、0 review）与脱敏扫描结果、全部远程 refs（18 个，tags 0）、旧 SHA 服务端可访问状态。
- 修正第三轮遗留不一致：第三轮 UAT 运行目录统一为 `<uat-root>\t1-03-ui-r3-20261120-081100`（原 README/test-counts 误写 `075440`）；资产文件数按实际统计；分支提交数与 PR 评论数/正文统计同步到最新扫描。
- **P2-01 仍未关闭：** 旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 及其 9 个原始日志（合计 147,009 字节）**仍可通过 GitHub API 读取（HTTP 200）**；GitHub Support 服务端清理材料见 `docs/testing/reports/T1-03-assets/SANITIZATION.md` 第 4 节，需仓库所有者提交工单。第四轮未重写历史、未强制推送、未删除备份分支/bundle，也不声称服务端对象已清理。

**停止条件：** 已停止，等待第四轮独立审计；未合并 PR #8、未修改 main（基线 `018e851e8daf5835391a7b61caf881bc57c2ad42`）、未开始 T1-04/T1-05、未获授权不再次执行全仓库历史重写或强制推送；不自行宣布审计/验收通过。

## 15. 第四轮审计 F1/F2 最小修复结果（2026-11-26，等待第四轮独立审计复核）

**状态：** 第四轮独立审计发现 F1（EvidencePath 证据写入缺少边界与路径身份保护）与 F2（沙箱入口 `Test-Path` False 绕过 Windows 原生路径检查）。本轮只修复这两项，仅修改验证脚本/测试脚本/文档，**未修改产品代码**、未新增依赖、未重写历史、未强制推送。PR #8 保持 Open，等待第四轮独立审计复核。开发代理不自行宣布审计/验收通过。

**修复内容：**

- **F1 证据写入边界与身份：** `scripts/verify/T1-03UatPath.ps1` 新增 `Assert-T103EvidenceWritePath` / `Write-T103EvidenceFile`：相对路径按仓库根解析；拒绝 UNC/设备路径；证据目录必须是真实目录且真实最终路径与字面一致、卷身份一致；请求路径全部已存在组件必须是普通目录（拒绝 Junction / Symbolic Link / 悬空链接）；真实最终路径必须严格位于证据目录内（非字符串前缀）；已存在目标文件必须是普通文件且只有 1 个硬链接；测试脚本启动时记录证据目录身份（卷序列号 + File ID + 最终路径），写入时比对；任一失败 fail closed，不创建、不覆盖。`test-t1-03-uat-path.ps1` 的证据写入改走该入口。
- **F2 沙箱入口原生检查：** 新增 `Get-T103EntryNativeState` 与 `Invoke-T103SandboxCleanupEntrypoint`，移除 `Test-Path` 判断：先检查入口本身与父目录，再用原生路径链检查全部已存在祖先；只有原生检查确认入口确实不存在时才按原有业务规则返回 `sandboxAlreadyAbsent`；入口是 Junction / 悬空 Junction、父目录是重解析点、身份不明、原生检查失败一律 fail closed 且不执行递归删除。测试脚本的链接存在性辅助函数同步改为原生检查。
- **零回归：** 第三轮 60 项 + 第四轮 31 项检查名称继续硬校验保留；本轮新增 21 项（F1 12 项、F2 8 项、Canary 1 项）全部存在（`evidence.round5NewChecksPresent`）。

**验证结果：**

- 路径安全专项（`test-t1-03-uat-path.ps1`，`evidence/round5/`）：**115 项，FAILED=0；SKIPPED=1（Symbolic Link 权限限制，明确记录、不计 PASS）**；退出码 0；沙箱清理 SAFE。
- 质量门禁（全部退出码 0）：`cargo fmt --all -- --check`、`cargo check --workspace --all-targets`、`cargo test --workspace`（**124 passed / 0 failed**，18 个测试套件）、`npm run check`（svelte-check 0/0；Bridge 17/17；Design Token 22 文件 0 违规、49/49）、`npm run build`（167 modules）、`node --test scripts/quality/work-item-bridge.test.mjs`（17/17）、`git diff --check`。
- T1-03 Release E2E（UAT `<uat-root>\t1-03-ui-r5b-20261126-183147`）：主 UI/IPC **84/84**、最小窗口 **12/12**、重启持久化 **17/17**、数据库只读探针 **25/25**；两次真实关闭退出码 **0/0**；CSP 违规 0；页面未捕获异常 0。
- Release EXE：工作区原二进制为 schema 4（T1-04）构建、与 T1-03 schema 3 不符，首次 E2E 失败；本轮按本分支重建 **10,352,128 字节**、SHA-256 `f46c9b0cb3c9d094475cab6abd8276276126f2ea0d2e5b38b6d6a4fbf92b2b68` 后重跑通过（构建产物不入库）。

**Red/Green 证据：** 修复前真实文件系统实测：F1 证据写到仓库证据目录之外（34,904 字节）并覆盖业务 Canary（SHA-256 改变）、自动创建越界父目录；F2 真实悬空 Junction 之下路径 `Test-Path=False`，旧分支表达式本会返回 `sandboxAlreadyAbsent`，修复后同一对象返回 `sandboxParentIsReparsePoint`。Windows PowerShell 5.1 对悬空 Junction **本身**的 `Test-Path` 返回 True，因此不声称“悬空 Junction 本身 Test-Path 必为 False”。

**证据：** `docs/testing/reports/T1-03-assets/evidence/round5/`（115 项路径安全证据、7 个脱敏 E2E JSON、`round5-verification-summary.json`）；19 张截图未复制入仓（产品 UI 未修改）。

**限制：** 未执行 Windows ACL `Access Denied` 测试；“原生检查失败”用例是“路径组件是文件”的真实 Win32 失败；Symbolic Link 场景 SKIP；DEC-029 / Issue #2 的 TOCTOU 风险未消除；P2-01 仍未关闭。

**停止条件：** 已停止，等待第六轮独立审计复核；未合并 PR #8、未修改 main（当前远端 main `9171fe35a7e080097991f547efe37ff5a504257c`）、未开始 T1-04/T1-05；不自行宣布审计/验收通过。

## 16. 第六轮定向补正结果（2026-11-27，等待第六轮独立审计）

**状态：** 第五轮独立审计未通过，阻塞项为 P1/F2（跟踪链接穿过未跟踪 Junction 在删除前误删沙箱外链接）、P2/F1（证据写入缺少启动身份强制）、P3（UI 最终摘要写入未走安全守卫）、P4（递归删除部分失败语义失实）及 B1–B5 交付证据问题。本轮只修复这些项，仅修改验证脚本/测试脚本/证据/状态文档，**未修改产品业务代码**、未改 T1-04/T1-02、未新增依赖、未重写历史、未强制推送。PR #8 保持 Open，等待第六轮独立审计。

- **P1 / F2：** 清理顺序改为“沙箱身份 + 父目录链原生校验 → 先验证全部跟踪链接（只允许沙箱直接子项，记录对象卷序列号/File ID/tag）→ 删除任何对象前全沙箱扫描（非登记重解析点立即停止）→ 只删除精确匹配的登记对象并原生复验 → 删除后残余扫描 → 身份复验 → 安全递归删除”。真实故障注入：`sandbox\evil(Junction)->external`、`external\victim-link(Junction)->victim-target`，修复前外部 victim-link 被删除，修复后在删除前 `trackedLinkNotDirectChild` fail closed，victim-link、victim-target Canary 内容/SHA-256、沙箱均保留。
- **P2 / F1：** `Write-T103EvidenceFile` 强制要求启动时记录的证据根目录身份；`Assert-T103EvidenceWritePath` 增加 `-RequireRootIdentity`；缺少身份/目录身份变化均拒绝写入；隔离 EvidenceRoot 仅保留为专项测试内部注入能力（需显式身份），不是生产 CLI 参数。
- **P3：** `verify-t1-03-ui.ps1` 创建输出目录后记录身份；最终摘要经 `Write-T103VerifiedOutputFile`（原生路径检查 + 目录身份复验 + 普通单硬链接检查）写入；Junction 替换/身份变化拒绝写入；E2E 输出 `PASS summary.writeGuard`。DEC-029 TOCTOU 残余风险未消除。
- **P4：** 结果新增 `recursiveDeleteStarted/Completed/Partial`；删除开始后异常返回 `recursiveDeleteFailed` 并如实说明部分删除；真实故障注入验证已删除部分条目。
- **B1–B5：** PR 正文/新增评论更新；round5 汇总时间戳拆分修正；新增可重复执行 Red 探针 `scripts/verify/probe-round6-red.ps1`（修复前基线 e8205ca + blob SHA 校验 + 真实文件系统对象，F1/F2/P4 全部真实复现）；提交数重算（25/27/28/30）；固定测试根统一 `<uat-root>`（历史证据 3 文件 8 处占位修正，扫描规则不放宽）。
- **验证结果：** 路径安全专项 **128 项，FAILED=0，SKIPPED=1**（原 115 项全部保留）；质量门禁全部退出码 0：`cargo fmt`、`cargo check`、`cargo test --workspace` **124 passed / 0 failed**、`npm.cmd run check`（svelte-check 0/0、Bridge 17/17、Design Token 49/49）、`npm.cmd run build`（167 modules）、`node --test` 17/17、`git diff --check`；T1-03 Release E2E 最终通过轮次 `<uat-root>\t1-03-ui-r6f-20261127-071753`：主 84/84、最小窗口 12/12、持久化 17/17、数据库探针 25/25、两次关闭 0/0、CSP 0、页面异常 0。
- **E2E 尝试记录：** 共 5 次真实尝试，1 次并发负载下应用壳渲染超时 + 2 次最小窗口尺寸时序竞态（其余断言通过）如实记录、不计入通过；验证脚本 `Set-WindowSize` 有限重试 + 真实客户区核对加固（仅测试脚本）后连续 2 次 PASS。
- **证据：** `docs/testing/reports/T1-03-assets/evidence/round6-remediation/`（Red `red/`、Green `green/` 分开保存；`round6-verification-summary.json`；`round6-remediation-notes.md`）。Release EXE 沿用第五轮按本分支 schema 3 重建的构建（10,352,128 字节，SHA-256 `f46c9b0cb3c9d094475cab6abd8276276126f2ea0d2e5b38b6d6a4fbf92b2b68`），本轮未改产品代码。
- **遗留风险：** P2-01 仍未关闭；DEC-029 / Issue #2 TOCTOU 未消除；未执行 Windows ACL `Access Denied` 测试；Symbolic Link 场景 SKIP；普通 SQLite 未加密（DEC-028）；PR #8 base 落后于 main 的问题本轮不处理。
- **停止条件：** 已停止，等待第六轮独立审计；未合并 PR #8、未修改 main、未开始 T1-04/T1-05；不自行宣布审计/验收通过。