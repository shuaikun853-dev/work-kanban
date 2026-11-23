# T1-04：多项目独立副本创建

**任务状态：** 进行中（开发代理自测阶段；未独立审计、未用户验收）  
**启动日期：** 2026-11-24  
**所属阶段：** 阶段 1：基础架构与工作事项  
**前置任务：** T1-01、T1-02 已验收并合并；**T1-03 尚未完成独立审计（PR #8 Open）**  
**用户授权：** 2026-11-24 用户明确授权在 T1-03 未完成独立审计的情况下进行**堆叠开发**，并要求严格保留 T1-03 的独立审计与验收状态，不得宣称 T1-03 已完成。  
**开发分支：** `task/T1-04-multi-project-copies`（从 T1-03 最新真实 HEAD 堆叠创建）  
**堆叠基线：** `e8205cae22e98afce6480f5a5a0695543a61dee3`（`task/T1-03-quick-create-pending`，2026-11-24 重新核实 PR #8 HEAD）  
**main 基线（未包含 T1-03/T1-04）：** `018e851e8daf5835391a7b61caf881bc57c2ad42`  
**PR #8 状态（2026-11-24 核实）：** Open，未合并，headRefOid = `e8205cae22e98afce6480f5a5a0695543a61dee3`，base = main  
**Pull Request：** 暂不创建指向 main 的 T1-04 PR（PR #8 未合并，直接创建会把 T1-03 变更重复带入）；完成后仅推送 T1-04 分支  
**测试报告（计划）：** `docs/testing/reports/T1-04-REPORT.md`  
**证据目录（计划）：** `docs/testing/reports/T1-04-assets/`  
**开发设计：** `docs/development/tasks/T1-04-Implementation-Design.md`

## 1. 权威依据

开发前必须阅读并以实际堆叠基线版本为准：

1. `docs/requirements/PRD.md`（尤其 5.2、10.2、验收标准；本任务新增 PRD-AT-18）
2. `docs/architecture/TECHNICAL_DESIGN.md`（5.1、5.4、5.5、5.6、6.1、6.2、7.4）
3. `docs/decisions/DECISIONS.md`（DEC-007、DEC-033；本任务新增 DEC-034）
4. `docs/design/UI-DESIGN-SPEC.md` 与 `docs/design/assets/workmanager-ui-prototype.svg`
5. `docs/development/DEVELOPMENT_PLAN.md`、`docs/STATUS.md`
6. `AGENTS.md`
7. T1-01 / T1-02 / T1-03 的任务说明、测试报告、已合并/已提交代码
8. PR #8 实际 diff、提交记录与 T1-03 分支实际 Rust Core / Tauri IPC / Bridge / Svelte 实现

发现文档与代码不一致时，先记录差异，不得自行假设或选择对实现最方便的一条。

## 2. 已确认业务规则（最高优先级）

**多项目批量创建采用 A：整批原子提交。**

- 批量接口一次接收标题 + 项目 ID 列表，项目数必须至少为 2。
- 任意项目不存在、已归档，或任意一条工作副本、创建组、成员关系写入失败（含事务内读回验证失败），**整个事务必须回滚**。
- 不允许部分成功；不允许静默跳过无效项目；不允许先创建部分记录再通过补偿删除模拟回滚。
- 必须使用真实 SQLite `IMMEDIATE` 事务实现。
- 同一标题再次批量创建必须产生新的独立创建组与独立工作副本。
- 同一工作事项最多属于一个创建组；创建组只记录来源标题与创建时间，不共享工作状态、进度、日志、计划或附件。
- 删除工作事项时只允许清除该事项自身的成员关联，不得连带删除其他工作副本或创建组。

业务依据：PRD 5.2、DEC-007、DEC-033、DEC-034（本任务记录）、PRD-AT-02、PRD-AT-18（本任务新增）。

## 3. 任务目标

交付“多项目独立副本创建”一个完整纵向切片：

- schema 3 → 4 migration：新增创建组与成员关系表；
- Rust Core：`WorkItemService::create_copies`（整批原子提交、事务内验证全部项目、事务内读回验证）；
- Tauri typed IPC：`create_work_item_copies`；
- TypeScript Contracts / Bridge：批量请求/响应 DTO 与严格运行时校验；
- Svelte UI：把快速创建对话框从单项目选择扩展为多项目选择（0 / 1 / 2+ 三种创建语义），保留原有视觉与信息层级；
- 原子性故障注入测试（真实 SQLite trigger，不增加生产故障开关）；
- Windows Release 实测、截图、数据库只读探针、重启持久化、失败回滚证据；
- 文档、测试报告、证据与 GitHub 分支交付。

## 4. UI 交互要求

- 0 个项目：未归属工作，沿用 T1-03 单条创建语义。
- 1 个项目：单项目工作，沿用 T1-03 单条创建语义。
- 2 个及以上项目：调用批量创建接口。
- 显示“已选择项目数”和“预计创建数量”。
- 创建期间：禁止重复点击、禁止修改项目选择、展示真实提交状态。
- 创建失败：保留工作标题、保留原始选择、刷新项目列表；**不得静默删除已失效的项目选择**，必须由用户主动调整后重新提交。
- 项目在对话框打开后被归档：Core 返回 `project-archived`，整批必须失败；UI 不允许自动移除无效项目后创建剩余项目。
- 创建成功：关闭对话框，显示实际创建数量，再从 SQLite 重新读取待安排列表；区分“创建成功”和“列表刷新成功”，刷新失败不得再次提交创建请求。
- 不新增一级导航，不新增全局 Design Token，不引入新 UI 依赖，不改 AppShell/Sidebar/工作总览页面。

## 5. 允许修改范围

预期涉及（以实际代码结构为准）：

- `crates/workmanager-core/migrations/0004_work_item_creation_groups.sql`
- `crates/workmanager-core/src/database/migrations.rs`
- `crates/workmanager-core/src/work_items/**`
- `crates/workmanager-core/src/lib.rs`
- `crates/workmanager-core/tests/**`（新增 T1-04 测试；更新受 schema 版本影响的既有测试期望）
- `src-tauri/src/app_state.rs`
- `src-tauri/src/commands/work_items.rs`
- `src-tauri/src/commands/mod.rs`
- `src-tauri/src/lib.rs`
- `src/lib/contracts/workItems.ts`
- `src/lib/bridge/workItems.ts`
- `src/lib/bridge/workItemValidation.ts`
- `src/lib/features/work-items/**`
- `scripts/quality/work-item-bridge.test.mjs`
- `scripts/verify/**`（新增 T1-04 验证脚本；更新受 schema 版本影响的既有验证脚本期望；不改历史证据 JSON）
- 对应测试报告、证据与开发文档。

不得为了本任务重构无关模块、修改历史 migration 0001/0002/0003、改变 T1-02 项目管理行为或 T1-03 已有单项目创建规则。

## 6. 明确不在本任务范围

- T1-05 状态流转与历史记录、完成/放弃操作；
- 工作日志、每日计划、未来 7 天、优先级评分与排序、当前工作指针、跳过/补录；
- 复盘与提醒、报表、附件、三个月清理、备份恢复；
- 工作事项删除入口、批量编辑、周期任务、标签、评论、协作、云同步、遥测；
- T1-03 遗留 P2-01、DEC-029 / Issue #2 TOCTOU 加固（不属于 T1-04 修复范围）；
- 新增一级导航、图表、完成率、统计卡片或演示数据；
- 修改 AppShell、Sidebar、全局 Design Tokens 或 T1-01 便携路径安全实现。

## 7. 数据与架构要求

- schema 从 3 升级到 4；新增 migration 必须沿用现有引擎规则（独立 `IMMEDIATE` 事务、失败回滚、`user_version` 只在成功后前进），不得修改 0001/0002/0003。
- 创建组与成员关系表必须具有正确外键、唯一约束与查询索引；同一工作事项最多属于一个创建组。
- 批量创建的全部校验、创建组写入、工作副本写入、成员关系写入和读回验证必须在**同一个** `IMMEDIATE` 写事务内完成。
- 必须验证全部项目后再开始插入；不得只检查第一个项目。
- 使用现有 `WorkItemError` / `DatabaseError` 体系，新增必要的稳定错误码；错误消息不得包含标题、项目名称或 SQL 参数。
- SQLite 访问只在 Rust Core；所有 SQL 参数绑定；命令层只做 DTO、`spawn_blocking`、错误转换。
- IPC 使用 serde camelCase、请求 `deny_unknown_fields`、复用现有 `WorkItemDto` 与 `CommandError`；不提供任意 SQL / 文件 / 命令接口。
- Bridge 必须严格验证响应：groupId 合法、workItems 数组、数量与请求项目数一致、每个项目恰好一个副本、工作事项 ID 不重复、全部 pending、DTO 无缺失/额外字段；不得静默忽略契约错误。
- 不新增 ORM、migration crate、前端测试框架或其他第三方依赖。
- 不记录工作标题、项目名称或 SQL 参数到日志。

## 8. 测试与验收标准

### 8.1 Rust Core / SQLite（必须覆盖原子性）

1. 两个项目创建两个独立副本；
2. 三个项目创建三个独立副本；
3. 每个副本 UUID 不同；
4. 每个副本 `project_id` 正确；
5. 创建组与成员关系完整；
6. 相同标题可再次创建（新创建组、新副本）；
7. 空标题拒绝；
8. 少于两个项目拒绝批量接口调用；
9. 重复 `project_id` 拒绝；
10. 不存在项目导致整批回滚；
11. 已归档项目导致整批回滚；
12. 第一条工作已插入、第二条失败，全部回滚（真实 SQLite trigger 故障注入）；
13. 成员关系插入失败，全部回滚（真实 SQLite trigger 故障注入）；
14. 读回验证失败，全部回滚（真实 SQLite trigger 在事务内制造不一致）；
15. 事务失败后没有创建组残留；
16. 事务失败后没有成员关系残留；
17. 事务失败后没有工作副本残留；
18. 事务失败前已有的历史数据不变；
19. 并发归档和批量创建符合 `IMMEDIATE` 事务规则；
20. 重启后全部记录与成员关系持久化。

另外：migration 3 → 4 升级保留既有数据、重复打开安全、注入 migration 失败回滚、外键/唯一约束/删除行为与 STRICT 约束测试。

### 8.2 Tauri IPC / Frontend

- 请求 camelCase + `deny_unknown_fields`；响应 `{groupId, workItems}` 字段精确；
- 复用 `WorkItemDto`（10 字段）与 `CommandError` 稳定错误码；
- `spawn_blocking`，命令层不实现业务规则；
- Bridge 严格运行时契约（含数量、项目对应关系、ID 唯一、pending、未知字段拒绝）；
- UI 覆盖 0 / 1 / 2+ 项目语义、选择计数、提交锁、失败保留选择、归档竞态整批失败、成功后实际数量提示与权威刷新、刷新失败不重复创建。

### 8.3 Windows Release / 回归

- 独立 UAT 便携目录 + 虚构数据；复用 T1-03 已验证的测试根信任锚、Windows 原生路径身份验证、fail-closed 清理与重解析点检查。
- 正常窗口截图、最小窗口截图、两项目创建截图、三项目创建截图、原有未归属创建回归截图、失败原子回滚证据、重启持久化证据。
- 数据库只读探针核对工作副本、创建组、成员关系与 schema 版本。
- 继承回归：T1-02 UI E2E、便携路径验证、异常注入验证；T1-03 业务规则回归（单项目/未归属创建、归档项目拒绝、待安排列表）在 T1-04 E2E 内覆盖；说明 T1-03 原 UI 脚本因控件从单选扩展为多选而不再作为可执行回归基线，历史证据不修改。

### 8.4 质量门禁（全部真实执行）

```bash
cargo fmt --all -- --check
cargo check --workspace --all-targets
cargo test --workspace
npm run check
npm run build
git diff --check
```

## 9. 开发流程与停止条件

1. 核查本地仓库、remote、当前分支、工作区状态、PR #8 与远程分支真实状态。
2. 从最新 T1-03 HEAD 创建 T1-04 分支；不修改 main、不修改 T1-03 分支、不重写历史、不强制推送。
3. 编码前先提交本任务说明与 `T1-04-Implementation-Design.md`。
4. TDD：先写失败测试，确认真实失败，再实现最小正确行为。
5. 完成全部自动化测试、Release E2E、截图、数据库探针、重启持久化与文档同步。
6. 推送 T1-04 分支；PR #8 未合并时不创建指向 main 的 PR。
7. 完成开发与自测后立即停止，等待独立代码审计；不宣布独立审计/用户验收通过，不合并 PR，不进入 T1-05。

## 10. 已知前置风险

- **T1-03 尚未完成独立审计**：本轮为堆叠开发，T1-03 的审计状态、PR #8 与 P2-01 遗留问题保持原状；本任务不得宣称 T1-03 已完成或已审计通过。
- T1-04 完成后的真实基线整合必须先等 PR #8 合并，再从更新后的 main 迁移 T1-04 自身提交；本阶段不创建错误包含整个 T1-03 diff 的 main PR。
- TOCTOU 残余风险按 DEC-029 延期至 Issue #2，T1-04 不修复。
- 普通 SQLite 未加密；本地工作数据可被拥有文件访问权限的人读取。
