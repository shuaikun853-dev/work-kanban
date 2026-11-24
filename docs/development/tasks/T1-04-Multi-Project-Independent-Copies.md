# T1-04：多项目独立副本创建

**任务状态：** 待审计（第六轮独立审计后定向补正 R6-01～R6-03 完成；未独立审计、未用户验收）
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
- 客户端为一次逻辑批量创建生成规范小写连字符 UUID `requestId`；Rust Core 在 `IMMEDIATE` 写事务内校验后**直接作为** `work_item_creation_groups.id`（幂等重试），不新增 `request_id` 字段或 migration；每个工作副本的 ID 仍由 Rust Core 生成独立 UUID，二者不得混淆。
- 相同 `requestId` + 相同标题 + 相同项目列表返回既有批次；相同 `requestId` + 不同业务参数返回稳定冲突；不同 `requestId` 可创建新的独立批次。
- 批量创建的全部校验、创建组写入、工作副本写入、成员关系写入和读回验证必须在**同一个** `IMMEDIATE` 写事务内完成。
- 必须验证全部项目后再开始插入；不得只检查第一个项目。
- 使用现有 `WorkItemError` / `DatabaseError` 体系，新增必要的稳定错误码；错误消息不得包含标题、项目名称或 SQL 参数。
- SQLite 访问只在 Rust Core；所有 SQL 参数绑定；命令层只做 DTO、`spawn_blocking`、错误转换。
- IPC 使用 serde camelCase、请求 `deny_unknown_fields`、复用现有 `WorkItemDto` 与 `CommandError`；不提供任意 SQL / 文件 / 命令接口。
- Bridge 必须严格验证响应：groupId 必须是规范 UUID 且等于请求 `requestId`、workItems 数组、数量与请求项目数一致、每个项目恰好一个副本、每个副本标题等于请求标题去除首尾空白后的字符串、工作事项 ID 不重复、全部 pending、DTO 无缺失/额外字段；不得静默忽略契约错误。
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

- 请求 camelCase + `deny_unknown_fields`；请求必须包含客户端生成的规范 UUID `requestId`；响应 `{groupId, workItems}` 字段精确，`groupId` 必须等于请求 `requestId`；
- 复用 `WorkItemDto`（10 字段）与 `CommandError` 稳定错误码；
- `spawn_blocking`，命令层不实现业务规则；
- Bridge 严格运行时契约（含 `groupId === requestId`、每个副本标题等于请求标题按 Unicode `White_Space` 规范化后的结果、数量、项目对应关系、ID 唯一、pending、未知字段拒绝；R6-01）；
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

---

## 11. 开发执行结果（2026-11-24，开发与自测完成，等待独立审计）

**状态：** 代码实现、自动化测试、Windows Release E2E、继承回归与文档同步完成；**等待独立代码审计**。开发代理不自行宣布审计或验收通过；T1-03 的独立审计/验收状态保持不变。

**实际交付：**

- **数据库：** migration `0004_work_item_creation_groups.sql`，schema 3 → 4；`work_item_creation_groups`、`work_item_creation_group_members`（真实外键、`work_item_id UNIQUE`、STRICT、创建组查询索引）；未修改 0001/0002/0003；失败 migration 回滚测试通过。
- **Rust Core：** `WorkItemService::create_copies` 在同一个 `IMMEDIATE` 写事务内先按客户端规范 UUID `requestId` 查找既有批次，再验证全部项目，然后写创建组（主键直接复用 `requestId`）、全部独立副本（ID 由 Rust Core 生成）、全部成员关系并做事务内读回验证；新增 `work-item-copies-too-few`、`work-item-copies-duplicate-project`、`work-item-create-request-id-invalid`、`work-item-create-request-conflict` 稳定错误码；任意失败整批回滚；不新增数据库字段或 migration。
- **Tauri IPC：** `create_work_item_copies`（camelCase、`deny_unknown_fields`、必填 `requestId`、`spawn_blocking`、复用 `WorkItemDto`/`CommandError`；响应 `{groupId, workItems}`，`groupId` 为服务端校验后复用的请求标识）。
- **Bridge：** 批量响应严格运行时契约（`groupId === requestId`、副本标题等于请求标题规范化结果、数量/项目一一对应/ID 唯一/pending/无缺失或额外字段）；Node 契约测试 27 → **35/35**（R6-01 后扩展为 **48/48**，标题规则改为 Unicode `White_Space`）。
- **UI：** 快速创建对话框支持多项目选择（0/1 沿用 T1-03 单条创建，2+ 调用批量接口）；显示已选数量与预计创建数量；创建中锁定输入与选择；失败保留标题与原始选择、失效选择需用户主动移除、不自动创建剩余项目；成功使用后端实际数量并从数据库刷新，刷新失败不重复创建。
- **验证工具：** `verify-t1-04-ui.ps1` + 4 个 CDP 检查脚本 + 只读数据库探针 + 仅限 UAT 的 trigger 故障控制器；复用 T1-03 已验证 UAT 路径安全设施；未修改历史证据。

**质量门禁（全部真实执行）：**

- `cargo fmt --all -- --check` / `cargo check --workspace --all-targets`：退出码 0；
- `cargo test --workspace`：**149 passed / 0 failed**（基线 124 + T1-04 新增 25）；
- `npm run check`：svelte-check 0/0、Bridge 27/27、Design Token 22 文件 0 违规、49/49；
- `npm run build`：退出码 0（167 modules）；`git diff --check`：退出码 0。

**Windows Release E2E（独立 UAT 目录，虚构数据）：**

- 主 UI/IPC **96/96**、最小窗口 **11/11**、真实 SQLite trigger 原子回滚 **13/13**、重启持久化 **15/15**、数据库只读探针 **57/57**；
- 三次真实关闭退出码 **0/0/0**；CSP 违规 0；页面未捕获异常 0；
- 数据库探针：主阶段 12 工作 / 4 创建组 / 9 成员；故障回滚后完全不变；重启并再次批量创建后 14 / 5 / 11；schema 4、完整性 ok、外键 0 违规；
- Release EXE **10,435,072 字节**，SHA-256 `2d997dea7c44ff323e902478063e01465a42e0544bfd0ff5b05359f38a3f7d79`。

**继承回归：**

- 便携 **106 项（PASS 90 / FAIL 0 / WARN 1 既有 / INFO 15）**；异常注入 **73 项（PASS 64 / FAIL 0 / INFO 9）**；T1-02 UI E2E **73/73 + 12/12**；均退出码 0。
- T1-03 业务规则：Rust 既有单条创建/归档拒绝/待安排测试全部保持通过；T1-04 E2E 覆盖未归属/单项目/归档历史关联回归。T1-03 原 UI E2E 脚本以单项目 `<select>` 为控件基线，不适用于多选控件，本轮未修改该历史脚本与证据。

**实现提交：** `3031552e33e6cae2085a99910b73d769b6aa7a6b`（代码 + 测试 + 验证脚本；编码前设计提交 `e207ea9`）。
**证据与报告：** `docs/testing/reports/T1-04-REPORT.md`；证据 `docs/testing/reports/T1-04-assets/`（14 张截图 + 9 个 JSON + test-counts）。

**第五轮定向修复（2026-11-24）：** 第二轮独立审计 T104-01～T104-06 已修复：原生 UAT 路径守卫与真实 Junction 测试、真实 IPC 响应异常后的 requestId 幂等重试、TDD Red/Green 证据、真实 0004 migration 索引冲突回滚、CSP 实际采集、STATUS/PLAN 状态统一。测试先行提交 `b4f641a`、实现提交 `e6b3f22`；最新质量门禁 `cargo test --workspace` **158 passed / 0 failed**、Release E2E 主 **107/107** + 最小窗口 **11/11** + 回滚 **13/13** + 持久化 **15/15** + 探针 **62/62**、继承回归全部通过；Release EXE 10,457,600 字节、SHA-256 `0bbe1dc4…4166`。详见 `docs/testing/reports/T1-04-REPORT.md` 第 10 节与 `T1-04-assets/evidence/round5/`。本轮仍不构成独立审计或用户验收。

**第六轮定向修复（2026-11-24）：** 第五轮修复后的独立复审提出的四项问题已修复：R2-01 路径安全测试自身信任锚与 fail-closed 清理（测试根 / UAT 根 / 数据库目录 / 证据目录创建前后原生守卫、Junction 重定向场景覆盖、清理复用 T1-03 fail-closed 机制、`formalRootTouched` 硬编码替换为只读身份快照证据）、R2-02 Migration 验证工具原生守卫（PowerShell / Python 双侧在创建 / 复制 / 启动 / 连接前守卫；清理 fail-closed 且保留证据目录）、R2-03 Bridge 业务契约（`groupId === requestId`、副本标题 trim 校验，Node 契约测试 27 → 35）、R2-04 文档 / Rust 注释 / TypeScript 契约对创建组 ID 来源统一为“客户端 requestId 直接复用为创建组主键，工作副本 ID 由 Rust Core 生成，不新增 schema 字段或 migration”。未改变 DEC-034 整批原子事务语义、未重新开发 T1-04、未合并 PR；本轮仍不构成独立审计或用户验收。详见 `docs/testing/reports/T1-04-REPORT.md` 第 11 节与 `T1-04-assets/evidence/round6/`。

**第六轮独立审计后定向补正（R6-01～R6-03，2026-11-24）：**

第六轮独立审计确认此前主要路径安全问题已解决，但提出三项残余问题；本轮仅做最小范围补正：

- **R6-01 标题 Unicode 空白规范化不一致：** Rust `str::trim()`（Unicode `White_Space`）与 JavaScript `String.trim()` 对 U+0085 / U+FEFF 处理不同，可能导致服务端已提交、Bridge 却拒绝合法响应并被 UI 误报为创建失败。新增 `src/lib/contracts/workItemTitle.ts`，显式固定 25 个 Unicode `White_Space` 字符；Rust 增加逐标量全量契约测试证明 `char::is_whitespace()` 与该集合一致。快速创建对话框、页面 requestId 绑定、Bridge 请求/响应校验全部改用同一规范化函数；内部空白、大小写与 U+FEFF 原样保留，不做 NFC/NFKC。新增 Node 用例 48/48（原 35 项全部保留 + 13 项 R6-01），并新增真实 Rust SQLite 保存/读回 → Bridge 解析的交叉契约测试（10 个标题场景，含同一 requestId 重试和副本数量断言）。
- **R6-02 Migration 清理悬空 Junction 防护：** 原清理入口先用 `Test-Path` 判断目录是否存在；悬空 Junction 在部分环境可能被误判为不存在并直接标记 `alreadyAbsent`。新增 `scripts/verify/T1-04MigrationCleanup.ps1`，清理前用原生句柄识别普通目录 / Junction / Symbolic Link / 其他 reparse point / 无法确认身份；悬空 Junction 返回 `danglingJunction` 并 fail-closed，不递归删除；清理完成后再次用原生句柄确认入口消失。`verify-t1-04-migration-failure.ps1` 改为调用该模块并记录 entryKind / targetExists / reparseTag。真实 Windows 故障注入测试 8 PASS / 0 FAIL / 1 SKIP（当前权限无法创建真实 Symbolic Link，显式 SKIP）。环境限制：Windows 10 19045 的 `Test-Path` 对本次真实悬空 Junction 返回 `True`，因此“`Test-Path` 误报 false 后直接 `alreadyAbsent`”这一具体分支未能在本机复现；测试仍记录真实 `Test-Path` 结果，并验证原生句柄识别与 fail-closed，未使用模拟对象冒充真实 Junction。
- **R6-03 文档与过期注释：** 修正 `workItemValidation.ts` 中“Rust Core 生成创建组 ID”的过期注释，明确创建组 ID 来源是客户端 `requestId` 经 Rust 校验后直接复用、工作事项 ID 由 Rust Core 生成；同步 T1-04 设计文档的 Unicode `White_Space` 契约；任务状态更新为“第六轮独立审计后定向补正完成，等待独立审计”。历史轮次记录保留，不删除、不改写。

本轮未改变 DEC-034 整批原子事务语义、requestId 幂等设计、创建组 ID 来源、数据库 schema/migration、T1-03 历史实现与证据、main、PR #8 目标分支或合并状态；未开始 T1-05。证据独立保存于 `docs/testing/reports/T1-04-assets/evidence/round6-remediation/`，不覆盖 round6 原始证据。本轮修复提交：`ada85906c033a98b2e942bd5ff37e09ec119e723`（证据同步提交见 Git 日志）。**本轮仍不构成独立审计或用户验收。**

**状态与停止条件：** 等待独立代码审计；PR #8 保持 Open，未在 PR #8 合并前创建 T1-04 main PR；未合并任何 PR、未修改 main、未开始 T1-05；不自行宣布审计/验收通过。
