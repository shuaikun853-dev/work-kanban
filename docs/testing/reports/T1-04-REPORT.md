# T1-04 多项目独立副本创建 — 测试与交付报告

**任务：** T1-04 多项目独立副本创建
**报告时间：** 2026-11-24（Asia/Shanghai）
**当前状态：** **开发与自测完成，等待独立代码审计**（开发代理不自行宣布独立审计或用户验收通过）
**开发分支：** `task/T1-04-multi-project-copies`
**堆叠基线：** `e8205cae22e98afce6480f5a5a0695543a61dee3`（T1-03 分支最新真实 HEAD，2026-11-24 重新核实）
**main 基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`（未包含 T1-03/T1-04）
**PR #8 状态：** Open，未合并（2026-11-24 核实时 headRefOid = `e8205cae…a61dee3`）；T1-04 未创建指向 main 的 PR
**设计文档：** [T1-04-Implementation-Design.md](../../development/tasks/T1-04-Implementation-Design.md)
**实现提交：** `3031552e33e6cae2085a99910b73d769b6aa7a6b`（代码 + 测试 + 验证脚本；文档/证据提交见分支日志）
**任务说明：** [T1-04-Multi-Project-Independent-Copies.md](../../development/tasks/T1-04-Multi-Project-Independent-Copies.md)
**证据目录：** [T1-04-assets/](T1-04-assets/README.md)

> **状态边界：** 本报告记录开发代理执行的真实命令与结果，不构成独立审计或用户验收。T1-03 仍未完成独立审计、PR #8 仍未合并、P2-01 仍未关闭；T1-04 的堆叠开发不改变这些状态。
>
> **第五轮更新（2026-11-24）：** 第二轮独立审计 T104-01～T104-06 已完成定向修复；最新测试先行提交 `b4f641a`、实现提交 `e6b3f22`。最新质量门禁、真实 IPC 幂等重试、Junction 专项、CSP 实际采集与 Release E2E 结果见[第 10 节](#10-第五轮定向修复2026-11-24t104-01t104-06)；第 1–9 节保留上一轮历史记录，不覆盖、不改写。
>
> **第六轮更新（2026-11-24）：** 第五轮修复后的独立复审提出的 R2-01～R2-04 四项问题已完成定向修复（路径安全测试自身信任锚与 fail-closed 清理、Migration 验证工具原生守卫、Bridge 业务契约校验、文档/注释/契约的创建组 ID 来源统一）；新增测试与证据见[第 11 节](#11-第六轮定向修复2026-11-24r2-01r2-04)。第 1–10 节保留历史记录；其中涉及批量创建组 ID 来源、Bridge 解析接口的历史描述已按当前真实实现同步更正，不改变历史测试结论。
>
> **第六轮独立审计后定向补正（2026-11-24）：** 针对独立审计残余问题 R6-01（Rust/JavaScript 标题 Unicode 空白规范化不一致）、R6-02（Migration 清理悬空 Junction 存在性判断不安全）、R6-03（Bridge 注释与任务文档状态过期）完成小范围补正；新增测试与证据见第 12 节。历史轮次记录保留，不覆盖 `round6/` 原始证据。

---

## 0. 结论摘要

| 项目 | 结果 |
|---|---|
| 业务规则 | 多项目批量创建采用**整批原子提交**（用户 2026-11-24 确认，记录为 DEC-034 / PRD-AT-18） |
| 数据库 | schema 3 → 4：`work_item_creation_groups`、`work_item_creation_group_members`；真实 `IMMEDIATE` 事务、失败回滚 |
| Rust Core | `WorkItemService::create_copies`：先验证全部项目 → 写创建组 → 写全部副本 → 写全部成员关系 → 事务内读回验证 → 提交 |
| Tauri IPC | `create_work_item_copies`，serde camelCase + `deny_unknown_fields` + `spawn_blocking` + 复用现有 DTO/错误体系 |
| Bridge | 批量响应严格运行时契约：数量一致、项目一一对应、ID 唯一、全部 pending、无缺失/额外字段 |
| UI | 快速创建对话框从单项目选择扩展为多项目多选；0/1 沿用 T1-03 单条创建，2+ 调用批量接口；失败保留标题与选择、失效选择保留并需用户主动移除 |
| 自动化测试 | `cargo test --workspace` **149 passed / 0 failed**；Bridge Node 契约 **27/27**；Design Token 49/49 |
| 原子性故障注入 | 3 类真实 SQLite trigger 场景（第二条副本失败 / 第二条成员关系失败 / 读回验证失败）全部整批回滚；Release UAT 数据库 trigger 故障注入同样整批回滚、无残留 |
| Release E2E | 主检查 **96/96**、最小窗口 **11/11**、回滚故障 **13/13**、重启持久化 **15/15**、数据库只读探针 **57/57**；三次真实关闭退出码 **0/0/0** |
| 继承回归 | 便携 **106 项（PASS 90 / FAIL 0 / WARN 1 / INFO 15）**；异常注入 **73 项（PASS 64 / FAIL 0 / INFO 9）**；T1-02 UI E2E **73/73 + 12/12** |
| Release EXE | `10,435,072` 字节，SHA-256 `2d997dea7c44ff323e902478063e01465a42e0544bfd0ff5b05359f38a3f7d79` |
| Git | 分支已创建并提交；PR #8 未合并前不创建 main PR（详见第 12 节） |

---

## 1. 权威依据与前置核查

开发前重新查询 GitHub（2026-11-24）：

- `gh pr view 8`：`state=OPEN`、`baseRefName=main`、`headRefName=task/T1-03-quick-create-pending`、`headRefOid=e8205cae22e98afce6480f5a5a0695543a61dee3`、`mergeable=MERGEABLE`、`mergedAt=null`。
- 远程分支 `origin/task/T1-03-quick-create-pending` HEAD 与 PR head 一致；本地 T1-03 分支落后 3 个仅文档提交，未修改该分支。
- `origin/main = 018e851e8daf5835391a7b61caf881bc57c2ad42`，main 未包含 T1-03/T1-04 产品代码。
- 依据用户指令：从最新 T1-03 分支 HEAD 创建堆叠分支 `task/T1-04-multi-project-copies`；未修改 main、未修改 T1-03 分支、未重写历史、未强制推送、未合并 PR #8。

本轮新增决策编号核实：DECISIONS.md 最后一个已确认决策为 DEC-033，下一个可用编号为 **DEC-034**；PRD 最后一个验收项为 PRD-AT-17，新增 **PRD-AT-18**。

---

## 2. 业务规则与实现约束

**整批原子提交（A）规则：**

1. 批量接口一次接收标题 + 项目 ID 列表，项目数必须 ≥ 2；0/1 个项目沿用 T1-03 单条创建。
2. 标题 trim 后非空；项目 ID 不得重复（不得静默去重）。
3. 任意项目不存在或已归档 → 整批失败。
4. 必须使用真实 SQLite `IMMEDIATE` 事务；且必须在同一事务内先验证**全部**项目，再写入创建组、全部独立工作副本与全部成员关系。
5. 任一条写入失败（含故障注入）或事务内读回验证失败 → 整批回滚；不允许部分成功、静默跳过或补偿删除。
6. 创建组只记录来源标题与创建时间；每个工作事项最多属于一个创建组；副本之间不共享可变状态。
7. 删除工作事项只清除该事项自身的成员关联，不连带删除同组其他副本或创建组。

对应文档：PRD 5.2 / PRD-AT-02 / **PRD-AT-18**、DEC-007 / DEC-033 / **DEC-034**、TECHNICAL_DESIGN 5.1 / **5.4.1** / 5.6 / 7.4、T1-04 任务说明与编码前设计。

---

## 3. 实际实现范围

### 3.1 数据库 migration

- 新增 `crates/workmanager-core/migrations/0004_work_item_creation_groups.sql`，`LATEST_SCHEMA_VERSION` 3 → 4；未修改 0001/0002/0003。
- `work_item_creation_groups(id TEXT PK, source_title TEXT CHECK(trim 非空), created_at TEXT)`，STRICT。
- `work_item_creation_group_members(group_id, work_item_id, PRIMARY KEY(group_id, work_item_id))`，STRICT：
  - `group_id` → `work_item_creation_groups(id)` `ON DELETE CASCADE ON UPDATE RESTRICT`（删除创建组只清除成员关系）；
  - `work_item_id` → `work_items(id)` `ON DELETE CASCADE ON UPDATE RESTRICT` 且 `UNIQUE`（每个工作事项最多一个创建组；删除工作事项只清除自身成员关系）；
  - 组内查询由复合主键最左列索引满足，按工作事项反查由唯一索引满足。
- 新增创建组按 `created_at DESC, id DESC` 的索引。
- migration 仍由现有引擎在独立 `IMMEDIATE` 事务中执行；失败回滚、`user_version` 不前进。

### 3.2 Rust Core

- `WorkItemService::create_copies(database, request_id, raw_title, project_ids) -> CreatedWorkItemCopies`：
  1. `normalize_title` / 批量项目数量 / 重复项目校验（失败不触碰数据库）；客户端 `request_id` 必须是规范小写连字符 UUID，否则 `work-item-create-request-id-invalid`；
  2. 创建组 ID 直接复用客户端 `requestId`（不是 Rust Core 新生成）；为每个项目生成独立工作事项 UUID（由 Rust Core 生成）与统一 UTC 时间戳；
  3. 在同一个 `Database::write_transaction`（`IMMEDIATE`）内：先按请求标识幂等查重（相同内容返回既有批次、不同内容稳定冲突）→ **先循环验证全部项目**（存在且未归档）→ 插入创建组（主键 = requestId）→ 插入全部 `work_items`（`pending`，未设置字段 NULL）→ 插入全部成员关系 → 按 ID 读回创建组、全部副本、全部成员关系并逐项比对 → 全部一致才提交；
  4. 任一步失败由事务显式回滚；读回不一致返回 `work-item-persistence-verification-failed`。
- 新增稳定错误码：`work-item-copies-too-few`、`work-item-copies-duplicate-project`；复用 `work-item-title-empty`、`project-not-found`、`project-archived`、`work-item-persistence-verification-failed`、数据库错误码。
- 错误消息不含工作标题、项目名称或 SQL 参数；本模块不写日志。

### 3.3 Tauri IPC

- 新增命令 `create_work_item_copies`，参数 `input: CreateWorkItemCopiesRequest { requestId, title, projectIds }`：
  - serde camelCase、`deny_unknown_fields`；`requestId` 必填且必须是规范 UUID，`projectIds` 必须是字符串数组；
  - 复用 `WorkItemDto`（Rust `WorkItem`）与 `CommandError`；响应 `{ groupId, workItems }`，其中 `groupId` 是服务端校验后直接复用的客户端 `requestId`；
  - `async` + `spawn_blocking`；命令层只做 DTO/转发/错误转换，不实现业务规则；不暴露 SQL/文件/命令接口。
- `WorkItemContext::create_work_item_copies` 在 `Arc<Mutex<Option<Database>>>` 下调用 Core；数据库关闭时返回结构化错误。
- `src-tauri/src/lib.rs` 注册新命令；启动/退出逻辑未修改。

### 3.4 TypeScript Contracts / Bridge

- `contracts/workItems.ts`：新增 `CREATE_WORK_ITEM_COPIES_COMMAND`、`CreateWorkItemCopiesInput`、`CreatedWorkItemCopiesDto`。
- `bridge/workItemValidation.ts`：新增 `parseCreatedWorkItemCopies(raw, request)`（`request: CreatedCopiesRequestContext`），严格验证：
  - 顶层恰好 `{groupId, workItems}`；
  - `request.requestId` 必须是规范小写连字符 UUID；
  - `groupId` 为规范 UUID 且必须等于 `request.requestId`（合法但不同的 UUID 拒绝）；
  - 请求项目列表 ≥ 2、非空、不重复；
  - `workItems` 数量与请求项目数一致；
  - 每项通过既有 `parseWorkItem`（10 字段、无缺失/额外字段、`pending`）；每个副本标题等于请求标题按 Unicode `White_Space` 规范化的结果（R6-01 前为 `.trim()`；不改变大小写/内部空白）；
  - 每个请求项目恰好出现一次（不重复/不缺失/不替换）、工作事项 ID 唯一；
  - 任一项违反 → `ipc-contract-violation`。
- `bridge/workItems.ts`：新增 `createWorkItemCopies(requestId, title, projectIds)`；调用响应解析时传入完整请求上下文；失败载荷统一转 `WorkItemIpcError`。
- `scripts/quality/work-item-bridge.test.mjs`：批量契约测试由 17 项扩展为 **35 项**（第六轮新增 `groupId === requestId` 与标题 trim 校验场景），仍使用 Node 内置 `node:test`，未新增依赖。

### 3.5 Svelte UI（不新增一级导航 / Token / 依赖）

- `QuickCreateWorkItemDialog.svelte`：单项目 `<select>` 扩展为多项目 checkbox 列表（“未归属项目”= 清空选择）；显示“已选择 N 个项目，将创建 X 项独立工作”和“预计创建 X 项”；创建中锁定标题、项目选择、保存与取消；新增失效选择区块（保留 + 标记 + 用户主动“移除”），不再自动回退为未归属项目。
- `PendingWorkItemsView.svelte`：0/1 项目调用 `create_work_item`（沿用 T1-03），2+ 调用 `create_work_item_copies`；成功提示使用后端返回的实际创建数量；创建成功与列表刷新成功/失败三态分离；刷新失败只允许重新加载，不重复创建；项目归档/不存在错误时刷新项目选项但**不**修改对话框中的原始选择。
- 未修改 AppShell、Sidebar、TodayPage 结构、Design Tokens 或其他 Feature 页面；未新增 UI 依赖。

### 3.6 验证工具

新增（不修改历史证据）：

- `scripts/verify/verify-t1-04-ui.ps1`：Release E2E 编排（主 UI / 最小窗口 / 原子回滚故障 / 重启持久化 / 数据库只读探针 / 汇总）。
- `scripts/verify/inspect-t1-04-ui.mjs`（96 项检查）、`inspect-t1-04-min-window.mjs`（11 项）、`inspect-t1-04-fault.mjs`（13 项）、`inspect-t1-04-persistence.mjs`（15 项）。
- `scripts/verify/probe-t1-04-db.py`（只读数据库探针，含创建组/成员关系不变量）。
- `scripts/verify/control-t1-04-fault.py`（仅在 D 盘 UAT 测试数据库安装/移除测试 trigger；拒绝正式目录）。

受 schema 版本 3→4 影响的**仍然有效**的继承脚本已更新期望值：`VerifyCommon.ps1`（`VerifyExpectedSchemaVersion = 4`）、`inspect-release-ui.mjs`（schema 4 / migrations 1–4）、`inspect-t1-02-ui.mjs`（schema 4 / migrations 1–4 / 诊断页 migrationRows 1–4）。T1-03 的历史证据 JSON、历史审计报告与 T1-03 分支未修改。

---

## 4. 自动化测试结果（真实执行）

### 4.1 质量门禁

| 命令 | 结果 |
|---|---|
| `cargo fmt --all -- --check` | 退出码 0 |
| `cargo check --workspace --all-targets` | 退出码 0 |
| `cargo test --workspace` | **149 passed / 0 failed**（基线 124 + T1-04 新增 25） |
| `npm run check` | svelte-check **0 errors / 0 warnings**；Bridge **27/27**；Design Token 22 文件 **0 违规**、49/49 |
| `npm run build` | 退出码 0（167 modules） |
| `git diff --check` | 退出码 0 |

T1-04 新增 Rust 测试：`work_item_copies.rs` **16 项**、`creation_groups_migration.rs` **5 项**、Tauri command DTO/serde **3 项**、`WorkItemContext` 批量生命周期 **1 项**；另更新受 schema 版本影响的既有测试期望（`work_items_migration.rs`、`migration_rollback.rs`、`projects.rs`）与 Tauri/Node 契约测试。

### 4.2 原子性/领域测试覆盖（对应任务要求 1–20）

| # | 要求 | 测试 |
|---|---|---|
| 1 | 两个项目创建两个副本 | `creates_independent_pending_copies_for_each_project` |
| 2 | 三个项目创建三个副本 | `creates_three_independent_copies_for_three_projects` |
| 3 | 每个副本 UUID 不同 | 上述两项 + `item_ids.dedup()` 断言 |
| 4 | 每个副本 project_id 正确 | 上述两项逐项断言 |
| 5 | 创建组与成员关系完整 | `creates_independent_pending_copies_for_each_project`（组标题/时间/成员 JOIN/项目集合） |
| 6 | 相同标题可再次创建 | `same_title_can_be_batched_again_as_new_independent_group` |
| 7 | 空标题拒绝 | `rejects_empty_title_without_writing_any_batch_rows` |
| 8 | 少于两个项目拒绝 | `rejects_batch_with_fewer_than_two_projects`（0 与 1 个项目） |
| 9 | 重复 project_id 拒绝 | `rejects_duplicate_project_ids_without_silently_deduplicating` |
| 10 | 不存在项目整批回滚 | `missing_project_rolls_back_entire_batch`、`only_first_project_validated_would_have_passed_but_second_fails_batch` |
| 11 | 已归档项目整批回滚 | `archived_project_rolls_back_entire_batch` |
| 12 | 第一条已插入、第二条失败全部回滚 | `work_item_insert_failure_on_second_copy_rolls_back_everything`（真实 SQLite trigger） |
| 13 | 成员关系写入失败全部回滚 | `member_relation_insert_failure_rolls_back_everything`（真实 SQLite trigger） |
| 14 | 读回验证失败全部回滚 | `read_back_verification_failure_rolls_back_everything`（trigger 在事务内制造不一致） |
| 15/16/17 | 无创建组/成员/副本残留 | 上述故障测试统一断言 `count_groups=0`、`count_members=0`、`count_work_items` 不变 |
| 18 | 事务失败前历史数据不变 | `failed_batch_keeps_previous_successful_batches_unchanged`（全表快照逐行比对） |
| 19 | 并发归档与批量创建符合 IMMEDIATE | `batch_create_waits_for_in_flight_archive_then_fails_entirely`、`concurrent_archive_and_batch_create_never_produces_partial_batch`（3 轮竞态 + 全局不变量） |
| 20 | 重启后记录与成员关系持久化 | `batch_rows_and_members_persist_across_restart` |

补充不变量测试：`no work item belongs to multiple groups`、`no orphan members`、`all batch rows pending`、`failure does not alter historical rows`。

### 4.3 Migration 专项

- 真实 schema 3 数据库（含 2 个项目、2 条工作事项，其中一个已归档/一个非 pending）升级到 4：数据逐行保留、`user_version=4`、`schema_migrations` 记录 1–4、外键/完整性通过。
- 重复打开最新 schema：不重复执行 migration、不丢数据。
- 注入 0004 失败（建表后 CHECK 失败）：整批回滚、`user_version` 停留 3、无半成品表、既有数据保留，随后仍可正常升级。
- 约束测试：STRICT、外键、`work_item_id` 唯一（同一工作事项不能属于两个创建组）、空白 `source_title` 拒绝、删除单个工作事项只清除自身成员关系、删除创建组只清除成员关系且不删除副本、孤儿成员引用被外键拒绝。
- 表集合测试：T1-04 只新增两张表，不提前创建后续业务表。

### 4.4 Bridge 契约测试（Node）

合法两项目/三项目响应、乱序返回、groupId 规范 UUID、缺字段/额外字段、workItems 非数组/数量不符、项目重复/缺失/替换、副本项目为 null、非 pending 状态、副本 ID 重复、调用方请求参数非法等均覆盖；共 **27/27 PASS**。

---

## 5. Windows Release 实测

### 5.1 环境与产物

- 平台：Windows 10（本机真实桌面），Release 构建：`npm run tauri build -- --no-bundle`。
- Release EXE：`10,435,072` 字节，SHA-256 `2d997dea7c44ff323e902478063e01465a42e0544bfd0ff5b05359f38a3f7d79`。
- UAT 目录：`<uat-root>\t1-04-ui-20261124-082717`（`D:\WorkManager-test-data` 下的独立隔离目录，未使用正式目录 `D:\WorkManager`）。
- 复用 T1-03 已验证设施：测试根目录信任锚（F1）、Windows 原生句柄路径/重解析点/最终路径/卷身份校验、fail-closed 清理；迁移失败/路径失败均 fail-closed。
- 全部测试数据虚构；故障注入仅在 UAT 独立数据库执行，未在正式数据目录执行，未修改 Windows ACL。

### 5.2 E2E 结果

| 阶段 | 结果 |
|---|---|
| 主 UI/IPC 检查 | **96/96 PASS** |
| 最小窗口 860×640 检查 | **11/11 PASS**（视口 844×632、无横向溢出、多项目对话框完整可见、真实关闭按钮退出码 0） |
| 失败原子回滚（真实 SQLite trigger） | **13/13 PASS**（第二条副本插入真实失败 → 整批失败、无部分记录、标题/选择保留） |
| 重启持久化 | **15/15 PASS**（12 条记录持久化、归档历史关联保留、重启后再批量创建 → 14 条） |
| 数据库只读探针 | **57/57 PASS**（三个阶段汇总） |
| 真实关闭退出码 | 阶段 1/故障阶段/持久化阶段 = **0/0/0** |
| CSP 违规 / 页面未捕获异常 | **0 / 0** |

主检查覆盖：

1. 应用壳、固定六个一级导航（无新增一级导航）、今日工作 → 待安排次级视图、空状态；
2. 多项目选择对话框渲染（无遗留单项目 `<select>`）、选择计数与预计创建数量、0/1/2+ 三种语义；
3. 真实 UI 两项目批量创建 → 2 条独立 pending 副本（ID 不同、project_id 正确、实际数量提示）；
4. 三项目批量创建 → 3 条独立副本；
5. T1-03 回归：未归属创建（projectId=null）、单项目创建（projectId 正确）、归档项目历史关联保留并显示“项目已归档”；
6. 批量创建期间重复点击保护（传输层延迟注入下两次同步点击只产生一次批量创建）且提交中选择/保存被锁定；
7. 对话框打开后项目被归档 → `project-archived`，整批失败、无部分记录；失效选择保留并提示“移除”，不自动创建剩余项目；
8. 绕过 UI 直接 IPC：归档项目 / 不存在项目 / 重复项目 / 少于两个项目 / 空标题 / 未知字段 / snake_case 均被拒绝且不产生记录；无任意 SQL 命令；
9. Bridge 严格契约：伪造非法批量响应被 UI 捕获为 `ipc-contract-violation`，标题与选择保留、无记录写入；
10. 创建成功但列表刷新失败：显示实际创建数量 warning，不清空、不重复创建；恢复后重新加载成功；
11. CSP 0 违规、页面未捕获异常 0、正常窗口无横向溢出。

### 5.3 数据库只读探针结果

| 阶段 | schema | work_items | 创建组 | 成员关系 | 完整性 | 外键违规 | 组大小分布 |
|---|---|---|---|---|---|---|---|
| 主检查后 | 4 | 12（全部 pending） | 4 | 9 | ok | 0 | {2:3, 3:1} |
| 故障注入回滚后 | 4 | 12 | 4 | 9 | ok | 0 | {2:3, 3:1} |
| 重启并再次批量创建后 | 4 | 14（全部 pending） | 5 | 11 | ok | 0 | {2:4, 3:1} |

每次探针均验证：schema_migrations 1–4、无孤儿成员、无空创建组、无工作事项属于多个创建组、工作复制品全部 pending、归档项目历史关联保留。故障注入阶段数量与主阶段完全一致，是“整批回滚、无残留”的直接数据库证据。

### 5.4 截图

见 [T1-04-assets/screenshots](T1-04-assets/screenshots/)：正常窗口、两项目创建、三项目创建、未归属回归、多项目选择对话框、归档竞态批次失败、Bridge 契约违规、最小窗口（844×632）、SQLite trigger 原子回滚、刷新恢复、重启持久化等 14 张真实截图。

---

## 6. 继承回归结果

| 回归 | 结果 |
|---|---|
| T1-01 便携/迁移/异常保护（`verify-release-portable.ps1`） | **106 项：PASS 90 / FAIL 0 / WARN 1（既有 EBWebView 目录 WARN 保留）/ INFO 15，退出码 0** |
| T1-01 异常注入（`verify-release-faults.ps1`） | **73 项：PASS 64 / FAIL 0 / INFO 9，退出码 0** |
| T1-02 UI E2E（`verify-t1-02-ui.ps1`） | **主 73/73 + 最小窗口 12/12 PASS**；三色标题栏真实窗口 API、诊断页 schema 4 / migrations 1–4 通过 |
| T1-03 业务规则 | `cargo test --workspace` 中 T1-03 既有单条创建/归档拒绝/待安排查询测试全部保持通过（仅更新 schema 版本期望）；T1-04 E2E 覆盖未归属/单项目创建与归档历史关联回归。**T1-03 原 UI E2E 脚本以单项目 `<select>` 为控件基线，不适用于 T1-04 多选控件，本轮未修改该脚本、未重采集其证据；T1-03 历史证据与审计状态保持不变。** |

---

## 7. 文档更新

1. `docs/decisions/DECISIONS.md`：新增 **DEC-034**（多项目批量创建整批原子提交，2026-11-24 用户确认）。
2. `docs/requirements/PRD.md`：版本 V0.3.3；5.2 补充整批原子提交规则；新增 **PRD-AT-18**。
3. `docs/architecture/TECHNICAL_DESIGN.md`：新增 5.4.1 创建组表/成员约束/整批事务规则；7.4 补充批量创建事务必须整批原子完成；已确认决策列表新增第 10 项。
4. `docs/development/DEVELOPMENT_PLAN.md`：更新阶段 1 T1-04 状态、详细交付范围、进度更新记录与当前执行结论（T1-03 状态保持原样）。
5. `docs/STATUS.md`：新增 T1-04 开发与自测记录、质量门禁、E2E 与证据、遗留风险。
6. `docs/development/tasks/T1-04-Multi-Project-Independent-Copies.md`：任务说明 + 开发执行结果。
7. `docs/development/tasks/T1-04-Implementation-Design.md`：编码前设计 + 实现偏差说明。
8. 本报告与 `docs/testing/reports/T1-04-assets/`（README、test-counts、14 张 PNG、9 个 JSON 证据）。

未修改：T1-01/T1-02/T1-03 历史审计报告、T1-01/T1-02/T1-03 历史证据 JSON、历史 migration；Schema 版本期望更新仅作用于仍然有效的继承测试/验证脚本。

---

## 8. 已知风险与未完成项

- **未独立审计、未用户验收**：本报告仅为开发代理自测结果；T1-04 状态为“待审计”。
- **T1-03 状态未改变**：T1-03 尚未完成独立审计；PR #8 Open；P2-01（旧提交 `2342828` 仍可经 GitHub API 读取）仍未关闭，待仓库所有者提交 GitHub Support 服务端清理；本轮未重写历史、未强制推送、未删除备份分支/bundle。
- **未创建 main PR**：PR #8 未合并，直接创建会把整个 T1-03 diff 重复带入；T1-04 分支已推送但 PR 等 PR #8 合并后再交付（从更新后的 main 迁移 T1-04 自身提交）。
- **T1-03 原 UI E2E 脚本不再可执行**：控件从单项目单选变为多选；本轮未修改 T1-03 历史脚本/证据，T1-03 业务回归改由 Rust 测试与 T1-04 E2E 场景覆盖。
- **普通 SQLite 未加密**：拥有文件访问权限的人可读取数据库内容；不是加密存储。
- **TOCTOU 残余风险**：按 DEC-029 延期至 Issue #2，T1-04 未修复。
- **计划/优先级/状态流转等未实现**：T1-05、T2、T3、T4、T5 均未开始。
- 最小窗口 E2E 首次运行时发现 WebView2 对 `SetWindowPos` 的布局传播存在时序差异；已在**测试脚本**中加入确定性等待（`waitForViewportSettled`），未修改产品代码。

---

## 9. 停止条件

已完成代码开发、自动化测试、Release E2E、继承回归与文档同步；**立即停止，等待独立代码审计**。未合并 PR #8、未在 PR #8 合并前创建 T1-04 main PR、未进入 T1-05，不自行宣布独立审计或用户验收通过。

---

## 10. 第五轮定向修复（2026-11-24，T104-01～T104-06）

> 本节记录第二轮独立审计发现问题的定向修复与开发自测结果；**不构成独立审计或用户验收通过**。T1-03 状态、P2-01、PR #8 与 DEC-029 / Issue #2 风险均未改变。

### 10.1 Git 基线与提交

- 修复前 HEAD：`2c73ca1ef99246b566750511a1410ce5f4b0334f`（与审计基线一致）。
- 本轮测试先行提交：`b4f641a`。
- 本轮实现与验证工具提交：`e6b3f22`。
- 文档与证据提交：见 Git 日志/最终交付回复；未 squash、未 rebase、未强制推送。
- 分支：`task/T1-04-multi-project-copies`；堆叠基线 `e8205cae22e98afce6480f5a5a0695543a61dee3`；main `018e851e8daf5835391a7b61caf881bc57c2ad42` 未修改；PR #8 Open、未合并。

### 10.2 六项审计问题逐项结果

| 审计编号 | 原问题 | 修改文件 | 修复内容 | 测试证据 | 结果 |
|---|---|---|---|---|---|
| T104-01 | UAT 故障注入/数据库探针路径安全 | `scripts/verify/T1-04UatPath.ps1`、`guard-t1-04-path.ps1`、`t1_04_path_guard.py`、`control-t1-04-fault.py`、`probe-t1-04-db.py`、`verify-t1-04-ui.ps1`、`test-t1-04-path.py` | 复用 T1-03 `CreateFileW`/`GetFileInformationByHandleEx`/`GetFinalPathNameByHandleW`、信任锚、卷身份/文件 ID/最终路径校验；拒绝 Junction、符号链接、其他重解析点及未批准路径；数据库父目录与全部祖先、数据库文件自身、SQLite sidecar 均检查；证据目录固定 `<uat-root>\evidence`，输出只允许其直接 `.json` 子文件；Python 在 `sqlite3.connect()`/写文件前 fail-closed；探针不再输出标题、项目名称或绝对路径 | 真实 Junction 专项 **9 PASS / 0 FAIL / 1 SKIP**（文件符号链接权限不足）；祖先 Junction、叶子重解析点、证据目录 Junction、失败不连接数据库、失败不写外部文件均通过；Release E2E 三阶段探针 62/62 | 已修复 |
| T104-02 | IPC 已提交但响应异常导致重复创建 | `service.rs`、`repository.rs`、`error.rs`、`app_state.rs`、`commands/work_items.rs`、`contracts/workItems.ts`、`bridge/workItems.ts`、`PendingWorkItemsView.svelte`、`inspect-t1-04-ui.mjs` | 客户端为一次逻辑批量操作生成规范 UUID requestId，与标题+项目顺序绑定；IPC/Bridge 失败时保留，内容变化换新，成功确认后清理；Rust Core 在同一 `IMMEDIATE` 写事务内复用 `work_item_creation_groups.id` 为请求标识，相同内容返回既有批次，不同内容返回 `work-item-create-request-conflict`；并发同标识由写事务串行化；无新增 migration | Rust 24/24（同标识返回、标题冲突、项目列表冲突、归档后重试、并发同标识、非法标识）；真实 Release IPC 响应替换后重试：同 requestId，仍 1 组 / 2 副本 / 2 成员；真实 IPC 检查 10 项全通过 | 已修复 |
| T104-03 | TDD Red/Green 阶段证据不足 | `work_item_copies.rs`、`creation_groups_migration.rs`、`Cargo.toml`（测试同步函数 feature） | 先写测试并提交 `b4f641a`；先记录缺失 4 参数 API 的编译 Red；加入最小接口骨架后记录 18 passed / 6 failed 的行为 Red；再实现并记录 Green。并发归档改用 Barrier/Channel + SQLite 测试 UDF 的确定性同步，不使用随机 sleep | `T104-03-red-compile.txt`、`T104-03-red-behavior.txt`、`T104-03-green-work-item-copies.txt`、`T104-03-gate-cargo-test.txt` | 已补齐 |
| T104-04 | Migration 与原子性测试覆盖不足 | `work_item_copies.rs`、`creation_groups_migration.rs` | 新增创建组 INSERT 真实 SQLite trigger 回滚；新增真实 0004 migration 测试：从真实 SQL 读取索引名、预先创建同名冲突索引、真实引擎执行、两张表创建后因索引失败整体回滚；验证 user_version=3、两表不存在、无 version 4、历史行不变；删除冲突索引后成功升级 schema 4 | `creation_group_insert_failure_rolls_back_everything`、`real_0004_migration_failure_rolls_back_all_changes`；migration 6/6 | 已修复 |
| T104-05 | STATUS 与 DEVELOPMENT_PLAN 状态不一致 | `docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md` | 两文档统一为“第五轮定向修复完成；开发与自测完成，等待独立代码审计”；未标记独立审计/用户验收通过；T1-03 状态未改 | 两文档状态一致；T1-04 进度记录已追加 | 已修复 |
| T104-06 | CSP 机器证据字段未正确采集 | `inspect-t1-04-ui.mjs` | 导航/刷新前安装 `securitypolicyviolation` 监听器；记录 blockedURI/violatedDirective/effectiveDirective/originalPolicy/disposition/source/line/column/sample；实际数组写入 JSON；采集失败明确 `collection-failed`，不伪造 0；页面异常与 CSP 分开统计；重新执行 Release E2E | CSP 实际采集 `[]`，`cspCapture.status=captured`；页面异常 0；`T104-06-csp-evidence.json` | 已修复 |

### 10.3 TDD 证据

- 测试先行提交：`b4f641a`。
- 编译 Red：`cargo test -p workmanager-core --test work_item_copies --no-run`，退出码 **101**（缺少 `create_copies` 4 参数 API）。
- 行为 Red：加入最小接口骨架后 `cargo test -p workmanager-core --test work_item_copies -- --nocapture`，退出码 **101**，**18 passed / 6 failed**；6 项失败均为 T104-02 幂等语义（同标识返回既有批次、标题冲突、项目列表冲突、归档后重试、并发同标识、非法标识拒绝）。
- Green：`work_item_copies` **24 passed / 0 failed**；`creation_groups_migration` **6 passed / 0 failed**。
- 已正确的基线覆盖（如创建组 INSERT 回滚、确定性并发同步、真实 0004 冲突回滚）第一次执行即 PASS，如实记录为基线 PASS，未故意破坏生产代码制造虚假 Red。

### 10.4 完整质量门禁（全部真实执行）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | PASS |
| `cargo check --workspace --all-targets` | 0 | PASS |
| `cargo test --workspace --no-fail-fast` | 0 | **158 passed / 0 failed / 0 ignored（20 套件）** |
| `npm run check` | 0 | svelte-check 0 errors/0 warnings；Bridge 27/27；Design Token 22 文件 0 违规、49/49 |
| `npm run build` | 0 | 167 modules |
| `python scripts/verify/test-t1-04-path.py` | 0 | 真实 Junction 专项 9 PASS / 1 SKIP / 0 FAIL |
| `git diff --check` | 0 | 最终提交前复核通过（见最终 Git 记录） |

### 10.5 Windows Release E2E（独立 UAT，虚构数据）

- Release EXE：**10,457,600 字节**，SHA-256 `0bbe1dc43f59644e51126aeb277abd98cb124e506f69f25d35ef767010ab4166`。
- 主 UI/IPC **107/107**；最小窗口 **11/11**（视口 844×632）；SQLite trigger 原子回滚 **13/13**；重启持久化 **15/15**；数据库只读探针 **62/62**；三次真实关闭退出码 **0/0/0**。
- 真实 IPC 幂等重试：第一次真实请求提交 2 项目批次，传输层将响应替换为异常载荷；UI 保留请求标识；第二次保存复用同一 requestId；数据库仍 1 组 / 2 副本 / 2 成员。
- CSP 实际采集 `[]`；页面未捕获异常 0。
- 探针：主阶段 14 工作 / 5 组 / 11 成员；故障回滚后完全一致；重启并再次创建后 16 工作 / 6 组 / 13 成员；外键违规 0、孤儿成员 0、多组副本 0、全部 batch 副本 pending。
- Release migration 失败回滚：真实 schema 3 数据库 + 与 0004 同名冲突索引启动 Release EXE → 原生“WorkManager 启动失败”对话框显示 `migration-failed`，退出码 1；回滚后 `user_version=3`、无 version 4、无两个新表、历史项目/工作事项不变、完整性 ok。证据 `T104-04-release-migration-rollback.txt`。
- 继承回归：T1-01 便携 **106（PASS 90 / FAIL 0 / WARN 1 / INFO 15）**；T1-01 异常注入 **73（PASS 64 / FAIL 0 / INFO 9）**；T1-02 UI **73/73 + 12/12**；全部退出码 0。

### 10.6 证据与剩余风险

- 第五轮证据：`docs/testing/reports/T1-04-assets/evidence/round5/` 与 `screenshots/round5/`；不覆盖历史证据。
- **T1-04 仍未独立审计、未用户验收。**
- **T1-03 状态未改变**；P2-01 仍等待 GitHub Support，旧提交 `2342828` 仍可经 GitHub API 读取；PR #8 仍未合并。
- **DEC-029 / Issue #2 TOCTOU 并发路径替换风险仍按原决策延期**；本轮只治理静态 Junction/重解析点/路径身份校验，不宣称解决并发替换。
- 文件符号链接场景因当前进程无 `SeCreateSymbolicLinkPrivilege` 显式 SKIP，未伪造 PASS。
- 未创建 T1-04 main PR；未开始 T1-05。

### 10.7 最终状态

**T1-04 第五轮定向修复完成，开发与自测结果待独立代码审计。**

---

## 11. 第六轮定向修复（2026-11-24，R2-01～R2-04）

> 本节记录第五轮修复后独立复审所提四项问题的定向修复与开发自测结果；**不构成独立审计或用户验收通过**。T1-03 状态、P2-01、PR #8 与 DEC-029 / Issue #2 风险均未改变。

### 11.1 Git 基线与修复范围

- 修复前 HEAD：`775496591275be833c688397f323d1990367e4d3`（与复审基线一致）。
- 分支：`task/T1-04-multi-project-copies`；T1-03 堆叠基线 `e8205cae22e98afce6480f5a5a0695543a61dee3`；main `018e851e8daf5835391a7b61caf881bc57c2ad42` 未修改；PR #8 Open、未合并。
- 本轮仅修复四项复审问题，**未重新开发 T1-04**：未改 Rust 批量创建业务逻辑、IMMEDIATE 整批原子事务、创建组/成员设计、服务端幂等事务逻辑、已通过的并发同步测试、Migration 业务实现与 Release UI 交互；未新增数据库字段或 migration；未改变 DEC-034 整批原子事务语义。
- 本轮修复提交：`aefa0f6b80fbc0184be74b48dd8bd465c8e19965`（代码 + 测试 + 验证工具 + 证据 + 技术/任务/报告文档；未 rebase / reset / squash / 强制推送；未改写历史提交）；本报告 SHA 同步为该提交后的文档同步提交，见 Git 日志与最终交付报告。

### 11.2 四项问题逐项结果

| 编号 | 原问题 | 修改文件 | 修复内容 | 测试证据 | 结果 |
|---|---|---|---|---|---|
| R2-01 | 路径安全测试自身信任锚与 fail-closed 清理缺陷 | `scripts/verify/test-t1-04-path.py`（重写）、`T1-04UatPath.ps1`、`guard-t1-04-path.ps1`、`guard-t1-04-cleanup.ps1`（新增）、`t1_04_path_guard.py`、`t1_04_path_test_support.py`（新增）、`scripts/verify/README.md` | 创建任何测试目录前调用 `test-root` 原生守卫验证测试根目录信任锚（自身 + 全部已存在祖先 + 重解析点 + 卷身份 + 文件 ID + 真实最终路径）；测试根 / UAT 根 / 数据库目录 / 证据目录创建前后经 `uat-root-target` / `uat-root` 复验；新增真实 Junction 重定向测试根/祖先、UAT 根替换、数据库目录替换、证据目录替换场景（使用测试根内隔离合成信任锚，不替换真实共享测试根）；清理复用 T1-03 `Invoke-T103FailClosedSandboxCleanup`（`guard-t1-04-cleanup.ps1`），身份变化/重解析点/守卫失败时拒绝删除且不得 `ignore_errors`；证据输出固定 `<UAT根>\evidence\<file>.json`，写入前后守卫；删除硬编码 `formalRootTouched:false`，改为正式目录只读身份快照（前后比对）+ 守卫拒绝正式路径证据，无法读取时显式标记证据不足 | `test-t1-04-path.py`：**58 项 / 0 FAIL / 1 SKIP**（文件符号链接权限不足，显式记录，不计 PASS），退出码 0；`path-safety-output.txt`、`path-safety-evidence.json`；Red 原始输出 `path-safety-red.txt` | 已修复 |
| R2-02 | Migration 验证工具绕过原生路径守卫 | `scripts/verify/verify-t1-04-migration-failure.ps1`（重写）、`t1-04-migration-fixture.py`、`test-t1-04-migration-path.py`（新增）、`T1-04UatPath.ps1`、`guard-t1-04-path.ps1`、`t1_04_path_guard.py` | PowerShell 移除 `GetFullPath().StartsWith` 字符串判断：信任锚 → 规划期 UAT 根/数据库目标/证据目录守卫 → 创建后身份复验 → 复制 EXE 与启动 Release 前复验；清理只删除 `migration-failure-uat` 子目录并复用 fail-closed 身份复验（证据目录保留用于证据写入）；Python Fixture `setup()` 在创建文件前执行 `database-target` 守卫、独占创建、创建后执行 `database` 守卫、写入后再次复验身份，通过后才 `sqlite3.connect()`；`probe()` 在只读连接前执行 `database` 守卫，失败不降级、不尝试其他路径 | `test-t1-04-migration-path.py`：**31 项 / 0 FAIL**，退出码 0；`migration-failure-output.txt`、`migration-failure-evidence.json`（真实 Release 回滚：对话框 found、Release 退出码 1、user_version=3、无 version 4/新表、历史数据不变、integrity ok、原生守卫全部 PASS、fail-closed 清理 PASS、证据写入 PASS，脚本退出码 0）；真实 `verify-t1-04-migration-failure.ps1` 退出码 0 | 已修复 |
| R2-03 | Bridge 对批量创建响应业务契约校验不足 | `src/lib/bridge/workItemValidation.ts`、`bridge/workItems.ts`、`scripts/quality/work-item-bridge.test.mjs` | `parseCreatedWorkItemCopies(raw, request)` 接收完整请求上下文 `{requestId,title,projectIds}`：新增 `requestId` 规范小写连字符 UUID 校验、`groupId === requestId`（合法但不同 UUID 拒绝）、每个副本标题等于请求标题规范化结果（R2-03 时为 `.trim()`；R6-01 起改为 Unicode `White_Space`，不改变大小写/内部空白）；保留原有严格字段/数量/项目一一对应/ID 唯一/pending/未知字段拒绝；Bridge 传入完整上下文；不新增依赖 | Node 契约测试原 27 项全部保留并扩展为 **35 项**：Red **24 pass / 11 fail**（缺失检查）→ Green **35/35 PASS**，`bridge-red.txt` / `bridge-green.txt`；`svelte-check` 0 errors / 0 warnings | 已修复 |
| R2-04 | 技术设计、Rust 注释、TypeScript 契约对创建组 ID 来源描述不一致 | `docs/architecture/TECHNICAL_DESIGN.md`、`crates/workmanager-core/src/work_items/model.rs`、`service.rs`、`src/lib/contracts/workItems.ts`、`bridge/workItemValidation.ts`、`docs/development/tasks/T1-04-Implementation-Design.md`、`T1-04-Multi-Project-Independent-Copies.md`、本报告 | 统一描述：客户端生成规范 UUID `requestId`；Rust Core 在 `IMMEDIATE` 写事务内校验并直接复用为 `work_item_creation_groups.id`；相同 requestId 相同标题+项目列表返回既有批次、不同业务参数返回 `work-item-create-request-conflict`、不同 requestId 可创建新批次；工作事项副本 ID 由 Rust Core 生成；不新增数据库字段或 migration；未改变 DEC-034 语义 | 文档/注释一致性复核通过；Rust 测试与 Bridge 契约测试回归通过（`cargo test --workspace` 全绿、Bridge 35/35） | 已修复 |

### 11.3 TDD 与 Red/Green 证据

- 新增路径安全测试先于守卫能力实现执行：`path-safety-red.txt` 记录首次执行在信任锚阶段失败（`未知路径守卫类型：test-root`，退出码 2）——证明测试确实依赖新增原生守卫能力，而非“先实现再写测试”。
- R2-02 新增测试先于 Migration 工具修改执行：`migration-path-red.txt` 记录 **31 项中 16 项失败**，其中 `migrationScript.outputAncestorJunctionRejected` 为 `exit=0 createdUnderJunction=True canaryUnchanged=False`——直接复现旧脚本穿过 Junction 写入并继续执行真实回滚测试的漏洞；`fixture.setup*GuardFailure*` 显示旧 Fixture 在守卫失败时仍调用 `sqlite3.connect()`。
- R2-03 Bridge：先扩展测试并在旧实现上得到 **35 项中 11 项失败**（`bridge-red.txt`），再实现并得到 **35/35 PASS**（`bridge-green.txt`）。
- 未故意破坏生产代码制造 Red；未删除或放宽既有测试；未把 SKIP 伪报为 PASS；验证脚本退出码与被测产品行为分开记录。

### 11.4 完整质量门禁（全部真实执行）

Release EXE（第六轮重建，含 Bridge 变更）：**10,458,112 字节**，SHA-256 `eae180c83cd880cf72063ea353214291a6eebe4c74d920cf09d6adf96022d149`。

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | PASS |
| `cargo check --workspace --all-targets` | 0 | PASS |
| `cargo test --workspace --no-fail-fast` | 0 | **158 passed / 0 failed / 0 ignored（20 套件）** |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge **35/35**；Design Token 22 文件 0 违规、**49/49** |
| `npm run build` | 0 | 167 modules |
| `git diff --check` | 0 | 仅 CRLF 提示，无空白错误 |
| `test-t1-04-path.py` | 0 | **58 项 / 0 FAIL / 1 SKIP** |
| `test-t1-04-migration-path.py` | 0 | **31 项 / 0 FAIL** |
| `verify-t1-04-migration-failure.ps1`（真实 Release） | 0 | `MIGRATION_FAILURE_ROLLBACK=PASS`、`MIGRATION_FAILURE_CLEANUP=PASS`、`MIGRATION_FAILURE_EVIDENCE=PASS` |

原始输出：`T1-04-assets/evidence/round6/gate-*.txt`、`*output.txt`。

### 11.5 Windows Release E2E（第六轮重建 EXE，独立 UAT，虚构数据）

- 主 UI/IPC **107/107**；最小窗口 **11/11**（真实关闭按钮）；真实 SQLite trigger 原子回滚 **13/13**；重启持久化 **15/15**；数据库只读探针 **62/62**；三次真实关闭退出码 **0/0/0**；CSP 实际采集、页面未捕获异常 0。
- 探针：主阶段 14 工作 / 5 创建组 / 11 成员；故障回滚后完全一致（14 / 5 / 11，无残留）；重启并再次批量创建后 16 工作 / 6 创建组 / 13 成员；schema 4、完整性 ok、外键 0 违规、无孤儿成员、无多组副本。
- 证据：`T1-04-assets/evidence/round6/release-e2e-evidence/`（9 个 JSON）与 `screenshots/round6/`（14 张 PNG）；原始输出 `release-e2e-output.txt`。

### 11.6 继承回归（全部真实执行）

- T1-01 便携：**106 项（PASS 90 / FAIL 0 / WARN 1 / INFO 15）**，退出码 0。
- T1-01 异常注入：**73 项（PASS 64 / FAIL 0 / INFO 9）**，退出码 0。
- T1-02 UI E2E：主 **73/73** + 最小窗口 **12/12**，关闭退出码 0。
- T1-03 路径安全专项（`test-t1-03-uat-path.ps1`）：原 60 项全部保留 + F1/F2 新增 31 项，FAILED=0、SKIPPED=1（显式记录），退出码 0。
- 未修改 T1-03 历史提交/证据；T1-03 审计/验收状态保持原样。

### 11.7 安全证据与剩余风险

- **正式运行目录 `D:\WorkManager`：本机不存在**；测试仅做只读身份快照（前后 `existed=false`、身份一致），未打开、未修改、未写入。`formalRoot.guardRejectedFormalPath` 证明守卫拒绝正式目录路径。
- **测试根目录信任锚：** 每项写操作前重新验证；测试根目录本身从未被替换、重命名或删除；Junction 重定向场景使用测试根内隔离合成信任锚构造。
- **Junction 拒绝原始证据：** `path-safety-evidence.json` / `path-safety-output.txt` 包含真实 `mklink /J` 创建的测试根重定向、祖先 Junction、UAT 根/数据库目录/证据目录替换全部被拒（重解析 tag `0xA0000003`）；`migration-path-evidence.json` 包含旧工具穿过 Junction 写入的 Red 证据与修复后拒绝证据。
- **Canary：** 所有 Junction 目标目录（Canary）内容/目录结构前后完全一致（`canary.allTargetsUnchanged` = true）。
- **清理 fail-closed：** 身份变化、重解析点、清理守卫进程失败三类场景均拒绝删除并保留现场；正常沙箱经 T1-03 安全清理（身份复验 → 跟踪链接删除 → 重解析点扫描 → 身份复验 → 逐条目删除）全部安全移除，无残留。
- **SQLite 连接前原生守卫：** control/probe/Fixture 的守卫失败测试均验证 `sqlite3.connect` 未被调用、无文件写入/目录创建/删除。
- **未解决风险：** DEC-029 / Issue #2 TOCTOU 并发路径替换窗口仍存在；本轮不实施 custom SQLite VFS、不设计新的 Windows 文件系统安全架构、不宣称消除并发替换。P2-01 仍等待 GitHub Support；普通 SQLite 未加密。
- 文件符号链接场景因当前进程无 `SeCreateSymbolicLinkPrivilege` 显式 SKIP，未伪造 PASS。

### 11.8 遗留问题

- **本轮已修复：** R2-01～R2-04 四项。
- **本轮未修复（且不在本轮授权范围）：** DEC-029 / Issue #2 TOCTOU；P2-01（GitHub Support 服务端清理）；T1-05 及后续任务。
- **本轮未验证：** 独立代码审计、用户验收。
- **需要后续独立审计确认：** 本轮守卫/清理能力与测试证据的充分性；R2-04 文档一致性；Release E2E 与继承回归结果。

### 11.9 最终状态

**T1-04 第六轮定向修复完成，开发与自测结果待独立代码审计。**

---

## 12. 第六轮独立审计后定向补正（2026-11-24，R6-01～R6-03）

> 本节记录第六轮独立审计确认三项残余问题后的开发代理定向补正与自测结果；**不构成独立审计或用户验收通过**。T1-03 状态、P2-01、PR #8 与 DEC-029 / Issue #2 风险均未改变。

### 12.1 Git 基线与修复范围

- 修复前 HEAD：`de8f6221d66d0b4240f93a8a4737f8d85b4b1e84`（远程分支一致，工作区 clean）。
- 修复前基线：`775496591275be833c688397f323d1990367e4d3`。
- 分支：`task/T1-04-multi-project-copies`；T1-03 堆叠基线 `e8205cae22e98afce6480f5a5a0695543a61dee3`；远程 main `018e851e8daf5835391a7b61caf881bc57c2ad42` 未修改；PR #8 Open、未合并；未创建 T1-04 main PR。
- 仅修复 R6-01～R6-03：未改 Rust 批量创建业务事务/幂等语义、创建组 ID 来源、数据库 schema/migration、T1-03 历史实现/证据；未新增第三方依赖；未 rebase/reset/squash/force-push。
- 证据独立保存于 `T1-04-assets/evidence/round6-remediation/`，不覆盖 `round6/` 原始证据。

### 12.2 三项问题逐项结果

| 编号 | 原问题 | 修改文件 | 修复内容 | 测试证据 | 结果 |
|---|---|---|---|---|---|
| R6-01 | Rust `str::trim()` 与 JavaScript `String.trim()` 对 Unicode 空白处理不一致（U+0085 / U+FEFF），Bridge 可能拒绝 Rust 已成功提交并返回的合法响应 | `src/lib/contracts/workItemTitle.ts`（新增）、`workItemValidation.ts`、`bridge/workItems.ts`、`contracts/workItems.ts`、`QuickCreateWorkItemDialog.svelte`、`PendingWorkItemsView.svelte`、Rust `model.rs`、`work-item-bridge.test.mjs`、`work-item-title-cross-contract.test.mjs`（新增）、`title_normalization_cross_contract.rs`（新增） | 显式固定 Unicode `White_Space` 25 字符集合；Rust 用逐标量全量断言证明 `char::is_whitespace()` 与集合一致；TS 新增 `normalizeWorkItemTitle` 并用于对话框、requestId 幂等绑定、Bridge 请求/响应；只删首尾、保留内部空白/大小写/U+FEFF，不做 NFC/NFKC；真实 Rust SQLite 保存/读回结果交 Bridge 解析，验证同 requestId 重试返回原批次、无重复副本 | Bridge **48/48 PASS**（原 35 项全部保留 + 13 项 R6-01）；Red 在旧实现上 **42 pass / 4 fail**；Rust 9/9；交叉契约 10 场景 **1/1 PASS**；基线 worktree 交叉 Red 退出码 1 | 已修复 |
| R6-02 | Migration 清理用 `Test-Path` 判断目录存在；悬空 Junction 可能被误判为不存在并标记 `alreadyAbsent`，未做原生身份验证 | `scripts/verify/T1-04MigrationCleanup.ps1`（新增）、`T1-04UatPath.ps1`、`verify-t1-04-migration-failure.ps1`、`test-t1-04-migration-cleanup.ps1`（新增）、`test-t1-04-migration-path.py` | 清理入口先由原生命名句柄识别 absent / 普通目录 / 文件 / Junction / Symbolic Link / 其他 reparse point；悬空 Junction 返回 `danglingJunction` 并 fail-closed；`Test-Path` 只做交叉检查；清理后再次原生确认入口消失并复验 UAT 根身份；不删除 UAT 根/evidence | 真实 Windows 故障注入 **8 PASS / 0 FAIL / 1 SKIP**；外部 Canary 前后 SHA-256 一致；路径专项 **58 项 / 0 FAIL / 1 SKIP**；Migration 路径专项 **31 项 / 0 FAIL**；真实 Release migration 回滚见 12.5 | 已修复 |
| R6-03 | Bridge 注释仍称创建组 ID 由 Rust Core 生成；T1-04 任务文档顶部仍是第五轮状态；缺少统一标题规范化契约 | `workItemValidation.ts`、`T1-04-Implementation-Design.md`、`T1-04-Multi-Project-Independent-Copies.md`、`docs/STATUS.md`、`DEVELOPMENT_PLAN.md`、本报告、`scripts/verify/README.md` | 注释改为“客户端 requestId 经 Rust 校验后直接复用为创建组主键；工作事项 ID 由 Rust Core 生成”；任务状态改为第六轮独立审计后补正完成、等待独立审计；设计文档新增 3.2.1 Unicode `White_Space` 契约（字符集合、内部空白、大小写、NFC/NFKC、交叉契约）；历史轮次记录保留 | 文档/代码一致性复核；svelte-check 0 errors / 0 warnings；`git diff --check` 退出码 0 | 已修复 |

### 12.3 TDD 与 Red/Green 证据

- **R6-01 Bridge：** 先扩展 `work-item-bridge.test.mjs` 并在旧 `.trim()` 实现上执行，得到 **35 项原有通过 + 4 项 R6-01 失败**（U+0085、U+FEFF、混合空白、FEFF-only），退出码 1；实现后用同一命令得到 **48/48 PASS**，退出码 0。原始输出：`r6-01-bridge-red.txt` / `r6-01-bridge-green.txt`。
- **R6-01 Rust：** 新增 25 字符全量集合断言与 U+0085/U+FEFF/内部空白/大小写/NFC 测试；修复前 9/9 通过（Rust 规范本身是权威），证明 Red 位于 JS 侧而不是伪造 Rust 失败。原始输出：`r6-01-rust-baseline-red.txt` / `r6-01-rust-green.txt`。
- **R6-01 真实交叉契约：** 在 `de8f622` 基线 worktree 中执行 Node → Rust SQLite → Bridge 链路，Bridge 拒绝合法服务端标题，退出码 1（`r6-01-cross-contract-red-baseline.txt`）；补正后 10 个场景全部通过，退出码 0（`r6-01-cross-contract-green.txt`）。
- **R6-02：** 先写真实故障注入测试并在旧清理逻辑上执行，6 个场景因原生入口类型 / stopCode 尚未实现而失败（仅全局 Canary 通过，退出码 1，`r6-02-cleanup-red.txt`）；补正后 **8 PASS / 0 FAIL / 1 SKIP**（`r6-02-cleanup-green.txt`）。
- 未故意破坏生产代码制造 Red；未删除/放宽既有测试；未把 SKIP 伪报为 PASS；验证脚本退出码与产品行为分开记录。

### 12.4 完整质量门禁（全部真实执行）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | PASS |
| `cargo check --workspace --all-targets` | 0 | PASS |
| `cargo test --workspace --no-fail-fast` | 0 | **162 passed / 0 failed / 1 ignored**（ignored 为交叉契约 Rust 执行器，由 Node 以 `--ignored` 启动并通过） |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge **48/48**；交叉契约 **1/1**（10 场景）；Design Token 22 文件 0 违规、**49/49** |
| `npm run build` | 0 | 168 modules |
| `git diff --check` | 0 | PASS（仅 CRLF 提示，无空白错误） |
| `test-t1-04-path.py` | 0 | **58 项 / 0 FAIL / 1 SKIP**（证据 JSON 为写前 56 项快照；最后 2 项写后复核见原始输出） |
| `test-t1-04-migration-path.py` | 0 | **31 项 / 0 FAIL**（证据 JSON 为写前 29 项快照；最后 2 项写后复核见原始输出） |
| `test-t1-04-migration-cleanup.ps1` | 0 | **8 PASS / 0 FAIL / 1 SKIP** |
| `verify-t1-04-migration-failure.ps1` | 0 | 真实 Release 回滚 PASS；见 12.5 |

原始输出：`T1-04-assets/evidence/round6-remediation/gate-*.txt`、`r6-*.txt`。

### 12.5 Windows Release E2E 与真实 Migration 回滚

Release EXE（最终重建，全部代码修改后）：**10,458,112 字节**，SHA-256
`4487b3e134d479eb4c71671f561c3008a5b97f72bf7728cf6d08a8ad9d62e7d1`，
构建命令 `npm run tauri build -- --no-bundle`，退出码 0（4m 08s）。

**T1-04 Release UI/IPC E2E（独立 UAT，虚构数据，端口 9355）：**

- 主 UI/IPC **107/107**；最小窗口 **11/11**（真实关闭按钮）；真实 SQLite trigger 原子回滚 **13/13**；重启持久化 **15/15**；数据库只读探针 **62/62**；
- 三次真实关闭退出码 **0/0/0**；CSP 违规 0；页面未捕获异常 0；
- 探针：主阶段 14 工作 / 5 创建组 / 11 成员；故障回滚后完全一致（14 / 5 / 11，无残留）；重启并再次批量创建后 16 工作 / 6 创建组 / 13 成员；schema 4、完整性 ok、外键 0 违规、无孤儿成员、无多组副本；
- 真实 IPC 响应异常后同 requestId 重试仍为 1 个创建组 / 2 个副本；
- 结果：`T1_04_RELEASE_UI_E2E=PASS`，退出码 0；原始输出 `release-e2e-output.txt`，编排 `t1-04-ui-orchestration.json`，截图 `release-pending-after-main-checks.png`，机器可读 JSON 见 `release-e2e-evidence/`。

**真实 Release migration 失败回滚：**

- 真实 schema 3 + 真实 0004 同名冲突索引启动 Release EXE；
- 原生“WorkManager 启动失败”对话框 found=true，Release 退出码 1；
- 回滚后 `user_version=3`、无 version 4、无两张新表、历史项目/工作事项各 1 条不变、`integrity_check=ok`；
- `MIGRATION_FAILURE_ROLLBACK=PASS`、`MIGRATION_FAILURE_CLEANUP=PASS`、`MIGRATION_FAILURE_EVIDENCE=PASS`，脚本退出码 0；
- 原始输出 `migration-failure-output.txt`，证据 JSON `migration-failure-evidence.json`。

### 12.6 安全证据与剩余风险

- **正式运行目录 `D:\WorkManager`：未访问、未修改、未写入。** R6-02 测试只创建 `D:\WorkManager-test-data` 下的唯一测试根；未调用正式目录身份快照。
- **测试根信任锚：** R6-02 测试在任何写入前调用 `Assert-T104UatTrustedRoot`；测试根、UAT 根、Junction 目标、Canary 均在测试根内。
- **悬空 Junction：** 原生入口识别为 Junction、`targetExists=false`，清理返回 `danglingJunction`、`safe=false`、`performed=false`；未删除入口或外部目录；清理后原生复检保留现场。
- **Canary：** R6-02 测试、路径专项、Migration 专项的外部 Canary 前后 SHA-256 均一致；R6-02 汇总哈希见 `r6-02-cleanup-green.txt` 与 `r6-02-canary-comparison.txt`。
- **环境限制：** Windows 10 19045 的 `Test-Path` 对本次真实悬空 Junction 返回 `True`，未复现“`Test-Path` 为 false 后直接 `alreadyAbsent`”的具体分支；测试如实记录，并验证原生识别/fail-closed，未用模拟对象冒充真实 Junction。Symbolic Link 因无 `SeCreateSymbolicLinkPrivilege` 显式 SKIP；其他 reparse point 只验证 tag 映射，未宣称真实注入。
- **未解决风险：** DEC-029 / Issue #2 TOCTOU 并发路径替换窗口仍存在；本轮只修复静态悬空 Junction 存在性判断，不宣称消除并发替换。P2-01 仍等待 GitHub Support；普通 SQLite 未加密。

### 12.7 遗留问题

- **本轮已修复：** R6-01、R6-02、R6-03。
- **本轮未修复（不在授权范围）：** DEC-029 / Issue #2 TOCTOU；P2-01（GitHub Support 服务端清理）；T1-05 及后续任务。
- **本轮未验证：** 独立代码审计、用户验收。
- **需要后续独立审计确认：** Unicode `White_Space` 集合与 Rust 行为一致性、真实交叉契约测试充分性、悬空 Junction fail-closed 与 Canary 证据、文档状态与最终代码一致性。

### 12.8 最终状态

**T1-04 第六轮独立审计后 R6-01～R6-03 补正完成，开发与自测结果待独立代码审计。**
