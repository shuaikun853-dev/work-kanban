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

- `WorkItemService::create_copies(database, raw_title, project_ids) -> CreatedWorkItemCopies`：
  1. `normalize_title` / 批量项目数量 / 重复项目校验（失败不触碰数据库）；
  2. 生成创建组 UUID、每个项目独立工作副本 UUID、统一 UTC 时间戳；
  3. 在同一个 `Database::write_transaction`（`IMMEDIATE`）内：**先循环验证全部项目**（存在且未归档）→ 插入创建组 → 插入全部 `work_items`（`pending`，未设置字段 NULL）→ 插入全部成员关系 → 按 ID 读回创建组、全部副本、全部成员关系并逐项比对 → 全部一致才提交；
  4. 任一步失败由事务显式回滚；读回不一致返回 `work-item-persistence-verification-failed`。
- 新增稳定错误码：`work-item-copies-too-few`、`work-item-copies-duplicate-project`；复用 `work-item-title-empty`、`project-not-found`、`project-archived`、`work-item-persistence-verification-failed`、数据库错误码。
- 错误消息不含工作标题、项目名称或 SQL 参数；本模块不写日志。

### 3.3 Tauri IPC

- 新增命令 `create_work_item_copies`，参数 `input: CreateWorkItemCopiesRequest { title, projectIds }`：
  - serde camelCase、`deny_unknown_fields`；`projectIds` 必须是字符串数组；
  - 复用 `WorkItemDto`（Rust `WorkItem`）与 `CommandError`；响应 `{ groupId, workItems }`；
  - `async` + `spawn_blocking`；命令层只做 DTO/转发/错误转换，不实现业务规则；不暴露 SQL/文件/命令接口。
- `WorkItemContext::create_work_item_copies` 在 `Arc<Mutex<Option<Database>>>` 下调用 Core；数据库关闭时返回结构化错误。
- `src-tauri/src/lib.rs` 注册新命令；启动/退出逻辑未修改。

### 3.4 TypeScript Contracts / Bridge

- `contracts/workItems.ts`：新增 `CREATE_WORK_ITEM_COPIES_COMMAND`、`CreateWorkItemCopiesInput`、`CreatedWorkItemCopiesDto`。
- `bridge/workItemValidation.ts`：新增 `parseCreatedWorkItemCopies(raw, requestedProjectIds)`，严格验证：
  - 顶层恰好 `{groupId, workItems}`；
  - `groupId` 为规范 UUID；
  - 请求项目列表 ≥ 2、非空、不重复；
  - `workItems` 数量与请求项目数一致；
  - 每项通过既有 `parseWorkItem`（10 字段、无缺失/额外字段、`pending`）；
  - 每个请求项目恰好出现一次（不重复/不缺失/不替换）、工作事项 ID 唯一；
  - 任一项违反 → `ipc-contract-violation`。
- `bridge/workItems.ts`：新增 `createWorkItemCopies(title, projectIds)`；失败载荷统一转 `WorkItemIpcError`。
- `scripts/quality/work-item-bridge.test.mjs`：批量契约测试由 17 项扩展为 **27 项**，仍使用 Node 内置 `node:test`，未新增依赖。

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
