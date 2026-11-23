# T1-04 开发设计（编码前确认）

**任务：** T1-04 多项目独立副本创建  
**分支：** `task/T1-04-multi-project-copies`（从 T1-03 最新真实 HEAD 堆叠）  
**堆叠基线：** `e8205cae22e98afce6480f5a5a0695543a61dee3`（T1-03 分支 HEAD，PR #8 Open）  
**main 基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`（未包含 T1-03/T1-04）  
**编写时间：** 2026-11-24  
**状态：** 编码前设计。实现必须严格按本设计与权威文档执行；若实现与设计不一致，必须在测试报告或本文件补充说明原因。

本设计依据（按优先级）：

1. 用户 2026-11-24 明确指令：多项目批量创建采用 **A：整批原子提交**，并授权堆叠开发；
2. `docs/development/tasks/T1-04-Multi-Project-Independent-Copies.md`；
3. `docs/requirements/PRD.md` 5.2 / 10.2 / 验收标准（本任务新增 PRD-AT-18）；
4. `docs/decisions/DECISIONS.md`（DEC-007、DEC-033；本任务新增 DEC-034）；
5. `docs/architecture/TECHNICAL_DESIGN.md` 5.1 / 5.4 / 5.5 / 5.6 / 6.1 / 6.2 / 7.4；
6. `docs/design/UI-DESIGN-SPEC.md` V1.1 与原型图；
7. T1-03 实际 Rust Core / Tauri IPC / Bridge / Svelte 实现与测试；
8. `AGENTS.md` 与 T1-01 / T1-02 已合并代码约定。

---

## 1. 范围

交付“多项目独立副本创建”一个纵向切片：

- schema 3 → 4：`work_item_creation_groups`、`work_item_creation_group_members`；
- Rust Core `WorkItemService::create_copies`：整批原子提交；
- Tauri IPC `create_work_item_copies`；
- TS Contracts / Bridge 严格契约；
- Svelte 快速创建对话框多项目选择（0 / 1 / 2+ 语义）；
- 原子性故障注入测试、Windows Release E2E、文档与 GitHub 分支交付。

明确不在范围：T1-05 状态流转与历史；每日计划/排序/优先级/当前工作；复盘、日志、附件、报表、清理、备份恢复；工作事项删除入口；T1-03 遗留 P2-01 / DEC-029 / Issue #2 修复；不改 AppShell/Sidebar/全局 Design Token/T1-01 便携路径实现。

---

## 2. 数据库设计（schema 4）

新增 `crates/workmanager-core/migrations/0004_work_item_creation_groups.sql`，沿用现有 migration 引擎（独立 `IMMEDIATE` 事务、失败回滚、`user_version` 成功后前进）；不修改 0001/0002/0003。

```sql
CREATE TABLE work_item_creation_groups (
    id           TEXT PRIMARY KEY NOT NULL,
    source_title TEXT NOT NULL CHECK (length(trim(source_title)) > 0),
    created_at   TEXT NOT NULL
) STRICT;

CREATE TABLE work_item_creation_group_members (
    group_id     TEXT NOT NULL
                 REFERENCES work_item_creation_groups(id) ON DELETE CASCADE ON UPDATE RESTRICT,
    work_item_id TEXT NOT NULL UNIQUE
                 REFERENCES work_items(id) ON DELETE CASCADE ON UPDATE RESTRICT,
    PRIMARY KEY (group_id, work_item_id)
) STRICT;

-- 创建组按创建时间倒序查询（后续历史/溯源使用），id 为稳定次级键。
CREATE INDEX idx_work_item_creation_groups_created_at
    ON work_item_creation_groups (created_at DESC, id DESC);
```

设计说明：

- `source_title` 保存本次批量创建的规范化来源标题；创建组只是来源记录，不共享工作状态、进度、日志、计划或附件。
- `work_item_id UNIQUE` 保证**每个工作事项最多属于一个创建组**；`PRIMARY KEY (group_id, work_item_id)` 提供按组查询的索引（SQLite 主键自动索引，最左列 `group_id` 可满足组内成员查询），不额外建立重复索引。
- `group_id → work_item_creation_groups` 使用 `ON DELETE CASCADE`：若未来允许清理创建组，只删除组成员关系，不删除工作副本。
- `work_item_id → work_items` 使用 `ON DELETE CASCADE`：删除单个工作事项时只清除该事项自身的成员关联，不影响同组其他副本，也不删除创建组。T1-04 不提供删除入口，删除行为由数据库级测试锁定。
- 外键启用沿用 T1-01 `PRAGMA foreign_keys = ON`；STRICT 表尽早拒绝类型错误。
- `source_title` 允许相同标题重复出现（标题不是业务唯一键）。

---

## 3. Rust Core 设计

### 3.1 模型与类型

`crates/workmanager-core/src/work_items/model.rs` 新增：

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreatedWorkItemCopies {
    pub group_id: String,
    pub work_items: Vec<WorkItem>,
}
```

- 序列化契约与 Tauri 响应一致：恰好 `groupId`、`workItems` 两个字段；
- `workItems` 复用现有 `WorkItem`，字段集合与 `WorkItemDto` 逐字段一致（10 个 camelCase 字段，可空字段输出 `null`）。

### 3.2 服务接口

`WorkItemService::create_copies(database: &mut Database, raw_title: &str, project_ids: &[String]) -> Result<CreatedWorkItemCopies, WorkItemError>`

执行顺序：

1. 标题 trim 与非空校验（`normalize_title`，空 → `work-item-title-empty`）；
2. 项目数量校验：`project_ids.len() >= 2`，否则 `work-item-copies-too-few`；
3. 项目 ID 去重校验：出现重复 → `work-item-copies-duplicate-project`（不得静默去重）；
4. 生成创建组 UUID、每个项目一个独立工作事项 UUID、统一 UTC RFC3339 毫秒时间戳；
5. 在**一个** `Database::write_transaction`（`IMMEDIATE`）内：
   1. **先验证全部项目**（循环全部 `project_id`，不插入任何记录）：
      - 不存在 → `project-not-found`；
      - 已归档 → `project-archived`；
      - 全部未归档才继续；
   2. 插入创建组（`id`、`source_title`、`created_at`）；
   3. 依次插入全部 `work_items`（`project_id` 各自对应、`lifecycle_status = pending`、未设置字段保持 NULL）；
   4. 依次插入全部成员关系（`group_id`、`work_item_id`）；
   5. **事务内读回验证**：
      - 创建组按 ID 读回，`source_title` / `created_at` 必须一致；
      - 每个工作事项按 ID 读回，必须与内存记录逐字段一致；
      - 成员关系读回数量必须等于项目数，且每个成员 `group_id` 正确、`work_item_id` 对应的工作事项 `project_id` 与请求项目一一对应；
      - 任一项不一致 → `work-item-persistence-verification-failed`（回滚）；
   6. 全部成功才提交并返回读回记录。
6. 失败路径由 `write_transaction` 显式回滚；不允许部分成功、静默跳过或补偿删除。

读回查询使用事务连接（`Transaction` 可解引用为 `Connection`），复用现有 `repository::find`。

### 3.3 仓储新增

`work_items/repository.rs` 新增（全部参数绑定）：

- `insert_creation_group(...)`：写入创建组；
- `insert_creation_group_member(...)`：写入成员关系；
- `find_creation_group(...) -> Option<CreationGroupRow>`：事务内读回创建组；
- `list_creation_group_members(...) -> Vec<CreationGroupMemberRow>`：读回成员关系（JOIN `work_items` 取 `project_id`）。

不提供任意 SQL；读回结构体只在 crate 内部使用。

### 3.4 错误码

| 错误 | 错误码 | 中文消息（不含标题/项目名/SQL 参数） |
|---|---|---|
| 标题为空 | `work-item-title-empty`（复用） | 工作标题不能为空，请填写工作标题。 |
| 批量项目数 < 2 | `work-item-copies-too-few`（新增） | 批量创建至少需要两个不同的项目。 |
| 项目 ID 重复 | `work-item-copies-duplicate-project`（新增） | 所选项目存在重复，请重新选择项目后提交。 |
| 项目不存在 | `project-not-found`（复用） | 所选项目不存在或已被删除。请刷新项目列表后重试。 |
| 项目已归档 | `project-archived`（复用） | 所选项目已归档，不能再关联新工作。请选择其他项目或不选择项目。 |
| 读回验证失败 | `work-item-persistence-verification-failed`（复用） | 工作事项已写入但无法读取，请重试或检查数据库状态。 |
| 数据库错误 | 透传 T1-01 结构化错误码 | 现有中文数据库错误消息 |

错误消息不得包含标题、项目名称或 SQL 参数；不 panic 代替业务错误；本模块不写日志。

---

## 4. Tauri IPC 契约

### 4.1 命令

| 命令 | 请求 | 返回 |
|---|---|---|
| `create_work_item_copies` | `{ input: CreateWorkItemCopiesRequest }` | `{ groupId, workItems: WorkItemDto[] }` |

请求 DTO：

```rust
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateWorkItemCopiesRequest {
    pub title: String,
    pub project_ids: Vec<String>,   // JSON: projectIds
}
```

```json
{
  "title": "中核商品价格异常排查",
  "projectIds": ["project-a", "project-b"]
}
```

- serde camelCase；`deny_unknown_fields`；`projectIds` 必填且必须是字符串数组（`null`/缺省/字符串均被拒绝）；
- 业务校验（标题、数量、去重、项目状态、事务）全部在 Rust Core，命令层不实现业务规则；
- 复用现有 `WorkItemDto`（Rust `WorkItem`）与 `CommandError`；
- `async` 命令 + `spawn_blocking`；不暴露任意 SQL / 文件 / 命令。

### 4.2 适配层

- `src-tauri/src/commands/work_items.rs`：新增请求 DTO、命令与单测；
- `src-tauri/src/app_state.rs`：`WorkItemContext::create_work_item_copies`，数据库关闭时返回结构化错误；
- `src-tauri/src/lib.rs`：注册 `create_work_item_copies`；
- `CommandError` 已能承载新增错误码（`From<WorkItemError>`），无需新增 DTO 字段。

---

## 5. TypeScript Bridge 设计

### 5.1 契约（`src/lib/contracts/workItems.ts`）

```ts
export const CREATE_WORK_ITEM_COPIES_COMMAND = 'create_work_item_copies' as const;

export interface CreateWorkItemCopiesInput {
  readonly title: string;
  readonly projectIds: readonly string[];
}

export interface CreatedWorkItemCopiesDto {
  readonly groupId: string;
  readonly workItems: readonly WorkItemDto[];
}
```

### 5.2 Bridge（`src/lib/bridge/workItems.ts`）

```ts
export async function createWorkItemCopies(
  title: string,
  projectIds: readonly string[]
): Promise<CreatedWorkItemCopiesDto>
```

- 调用 `invoke('create_work_item_copies', { input: { title, projectIds } })`；
- 失败载荷统一转换为 `WorkItemIpcError`（复用现有逻辑）；
- 成功返回值必须通过 `parseCreatedWorkItemCopies(raw, projectIds)`。

### 5.3 严格运行时校验（`src/lib/bridge/workItemValidation.ts`）

`parseCreatedWorkItemCopies(raw, requestedProjectIds)` 必须验证：

1. 响应是严格对象，恰好 `groupId`、`workItems` 两个字段（缺字段/未知字段拒绝）；
2. `groupId` 是非空、规范的 UUID 字符串；
3. `requestedProjectIds` 为非空字符串数组且无重复（请求本身不合法 → 契约违规，不进行部分解析）；
4. `workItems` 是数组，长度等于请求项目数；
5. 每个元素通过现有 `parseWorkItem` 严格校验（10 字段、无缺失/额外字段、状态 `pending`）；
6. 每个副本 `projectId` 非空，且必须属于请求项目集合；
7. 每个请求项目恰好出现一次（不重复、不缺失、不替换为其他项目）；
8. 工作事项 ID 全部唯一；
9. 任一项失败抛出稳定错误码 `ipc-contract-violation` 的 `WorkItemIpcError`，不静默忽略。

本模块保持无 Tauri / DOM 依赖，便于 `node:test` 直接加载。

---

## 6. Svelte UI 设计

### 6.1 组件树（不新增一级导航）

```text
src/lib/features/today/TodayPage.svelte（不变）
└── lib/features/work-items/PendingWorkItemsView.svelte（修改：批量创建编排）
    ├── PendingWorkItemList / PendingWorkItemRow（不变）
    └── QuickCreateWorkItemDialog.svelte（修改：单项目选择 → 多项目选择）
        ├── 工作标题输入（必填、trim、自动聚焦；创建中禁用）
        ├── 多项目选择列表（仅未归档项目；checkbox 列表 + “未归属项目”清除选择）
        ├── 已选择数量 / 预计创建数量提示
        ├── 失效选择提示（保留选择、标记不可用、要求用户主动移除）
        ├── 提交中状态（禁用输入/选择/重复点击/取消）
        ├── 保存 / 取消
        └── 错误提示（中文消息 + 稳定错误码）
```

组件边界：`PendingWorkItemsView` 负责加载、项目选项刷新、创建编排与成功/刷新状态机；对话框只维护标题、选择与展示状态，通过 `onSubmit(title, projectIds)` 回调上报。

### 6.2 创建语义

| 已选择项目数 | 调用 | 预计创建数量 |
|---|---|---|
| 0 | `create_work_item(title, null)` | 1（未归属） |
| 1 | `create_work_item(title, projectId)` | 1（单项目） |
| 2+ | `create_work_item_copies(title, projectIds)` | N |

UI 显示“已选择 N 个项目，将创建 X 项独立工作”；未选择时显示“未选择项目，将创建 1 项未归属工作”。

### 6.3 状态流与失败处理

```text
打开对话框 → 加载未归档项目（失败显示轻量提示，不影响已加载选项）
选择/取消项目 → 更新已选择数量与预计创建数量
保存（同步守卫防止重复提交）
  ├─ 0/1 项目 → 单条创建接口
  └─ 2+ 项目 → 批量创建接口
      ├─ 成功：关闭对话框 → 提示“已创建 N 项工作，正在刷新…” → 从后端重新读取待安排列表
      │        ├─ 刷新成功：提示“已创建 N 项独立工作，待安排列表已从数据库更新”
      │        └─ 刷新失败：提示 warning + 实际创建数量，只允许重新加载，不得再次创建
      └─ 失败：保留标题与全部原始选择；显示错误码；刷新项目列表
               ├─ 项目已归档/不存在：整批失败；失效项目在对话框中保留并标记“已失效”，
               │  禁止自动移除后创建剩余项目；用户必须主动移除/调整后重新提交
               └─ 其他错误：保留选择，显示错误，用户可重试
```

- 项目列表刷新后**不再**执行 T1-03 的“自动回退为未归属项目”逻辑；失效选择必须由用户主动移除。
- 只要存在失效选择就禁用提交，并显示明确提示。
- 创建期间 `submitting=true`：标题输入、项目 checkbox、保存、取消均禁用；同步守卫防止同一事件循环重复提交。
- 失败场景下项目列表刷新失败时，保留当前错误与选择，用户可重试刷新；Core 事务校验仍是最终安全边界。

### 6.4 视觉与测试钩子

- 沿用现有 Design Tokens、对话框、按钮、错误面板、提示样式；不新增 Token/依赖；
- 保留 T1-03 已有稳定选择器（`#work-item-title`、`.dialog-error`、`.dialog-error-code`、`[data-create-outcome]`、`[data-work-item-id]`）；
- 新增测试钩子（仅 `data-*` 属性，不改变视觉）：`#work-item-project-options`、`input[data-project-id]`、`[data-selected-project-count]`、`[data-expected-copy-count]`、`[data-invalid-project-selections]`、`[data-create-mode]`（`unassigned` / `single` / `copies`）。

---

## 7. 测试计划

### 7.1 Rust / SQLite

新增 `crates/workmanager-core/tests/work_item_copies.rs`（真实 SQLite + Rust Core）：

1. 两项目 → 两个副本（独立 UUID、project_id 正确、pending、组与成员完整）；
2. 三项目 → 三个副本；
3. 相同标题再次批量创建 → 新组、新副本，历史不变；
4. 空标题拒绝（无写入）；
5. 项目数 0 / 1 拒绝（`work-item-copies-too-few`，无写入）；
6. 重复 project_id 拒绝（`work-item-copies-duplicate-project`，无写入）；
7. 任意项目不存在 → 整批回滚（无组、无成员、无副本；有效项目也不得留下副本）；
8. 任意项目已归档 → 整批回滚；
9. 只有第二个项目无效时也必须整批失败（证明不是只校验第一个项目）；
10. 故障注入（真实 SQLite trigger）：第二条 work_item 插入失败 → 全部回滚；
11. 故障注入：第二条成员关系插入失败 → 全部回滚；
12. 故障注入：读回验证不一致（trigger 修改标题）→ 全部回滚且错误码 `work-item-persistence-verification-failed`；
13. 失败后无创建组/无成员/无副本残留；
14. 失败前已有历史数据（项目、T1-03 单条工作、既有创建组）逐行不变；
15. 并发归档与批量创建（IMMEDIATE 事务）不产生已归档项目的新副本，且整批失败无部分记录；并发竞态循环；
16. 重启后组、成员、副本全部持久化；
17. 错误消息不回显标题/项目名/SQL。

新增 `crates/workmanager-core/tests/creation_groups_migration.rs`：

- schema 3 → 4 升级（真实含项目与工作事项的 schema 3 数据库）：数据保留、版本 4、migration 记录 1–4、外键/完整性通过；
- 重复打开不重复执行 migration；
- 注入 0004 失败：回滚、`user_version` 保持 3、无半成品表、旧数据保留；
- STRICT/外键/唯一约束/删除行为测试：
  - 同一 work_item 不能加入第二个创建组；
  - 删除单个工作事项只清除自身成员关系，同组其他副本与创建组保留；
  - 删除创建组只清除成员关系，不删除工作副本；
  - `source_title` 空白被拒绝。

更新受 schema 版本影响的既有测试：`work_items_migration.rs`（4、migrations 1–4）、`migration_rollback.rs`（最新表集合与“未提前创建”列表）、`projects.rs`（LATEST_SCHEMA_VERSION 4 与健康版本期望）。

### 7.2 Tauri IPC（`src-tauri` 单测）

- 请求 DTO：camelCase、必填、未知字段/蛇形字段/null 拒绝；
- 响应 DTO：恰好 `groupId`、`workItems`；`workItems` 每项 10 字段 camelCase、可空字段 null；
- 新增错误码映射；
- `WorkItemContext` 真实数据库：两项目批量创建、组/成员落库、归档项目整批失败无部分记录、数据库关闭结构化错误；
- 命令注册检查（`lib.rs`）。

### 7.3 Bridge / Node

扩展 `scripts/quality/work-item-bridge.test.mjs`：批量响应合法（2/3 项）通过；缺字段/额外字段/groupId 非法/非数组/数量不符/项目不对应/项目重复/ID 重复/非 pending 全部拒绝。

### 7.4 Windows Release E2E（新增 `scripts/verify/verify-t1-04-ui.ps1` 等）

复用 T1-03 的 UAT 路径安全设施（`T1-03UatPath.ps1`）与 Release 启动/CDP 模式；新 UAT 目录，虚构数据：

1. 应用壳/六个一级导航不变；待安排视图正常；
2. 创建两个虚构未归档项目，通过真实 UI 多选两个项目 → 创建 2 项独立副本；
3. 再用三个项目 → 创建 3 项独立副本；
4. 未归属创建回归（0 项目，T1-03 语义）；
5. 单项目创建回归（1 项目，T1-03 语义）；
6. 对话框选择计数、预计创建数量显示；
7. 重复提交保护（延迟注入下同步双点击只产生一次批量创建）；
8. 对话框打开后归档其中一个项目 → 返回 `project-archived`，整批失败，无部分记录；失效选择保留、UI 不自动移除；
9. 绕过 UI 直接 IPC：归档项目、不存在项目、重复项目、少于 2 个项目、空标题、未知字段均被拒绝；
10. 失败原子回滚证据（UAT 数据库注入测试 trigger，非正式数据目录）：第二个副本插入失败 → 整批回滚，数据库无组/成员/副本残留；
11. 最小窗口 860×640 截图与布局检查；红色关闭按钮真实退出码 0；
12. 重启持久化：组、成员、副本与 UI 列表一致；
13. 数据库只读探针：schema 4、创建组/成员数量与 UI/请求一致、无孤儿成员、无多组副本、外键干净；
14. 继承回归：T1-02 UI E2E、便携验证、异常注入验证。

### 7.5 质量门禁命令

```bash
cargo fmt --all -- --check
cargo check --workspace --all-targets
cargo test --workspace
npm run check
npm run build
git diff --check
```

全部真实执行并保留命令、退出码、测试数量和证据路径。

---

## 8. 文件修改清单（计划）

| 文件 | 变更 |
|---|---|
| `crates/workmanager-core/migrations/0004_work_item_creation_groups.sql` | 新增 |
| `crates/workmanager-core/src/database/migrations.rs` | schema 4 + migration 注册 |
| `crates/workmanager-core/src/work_items/model.rs` | `CreatedWorkItemCopies` |
| `crates/workmanager-core/src/work_items/repository.rs` | 创建组/成员写入与读回 |
| `crates/workmanager-core/src/work_items/service.rs` | `create_copies` 原子事务 |
| `crates/workmanager-core/src/work_items/error.rs` | 新增稳定错误码 |
| `crates/workmanager-core/src/work_items/mod.rs`、`src/lib.rs` | 导出 |
| `crates/workmanager-core/tests/work_item_copies.rs` | 新增原子性/领域测试 |
| `crates/workmanager-core/tests/creation_groups_migration.rs` | 新增 migration/约束测试 |
| `crates/workmanager-core/tests/work_items_migration.rs`、`migration_rollback.rs`、`projects.rs` | 更新 schema 版本期望/表集合 |
| `src-tauri/src/commands/work_items.rs` | 请求 DTO + 命令 + 单测 |
| `src-tauri/src/app_state.rs` | `WorkItemContext::create_work_item_copies` + 单测 |
| `src-tauri/src/lib.rs` | 注册命令 |
| `src/lib/contracts/workItems.ts` | 批量契约 |
| `src/lib/bridge/workItems.ts` | `createWorkItemCopies` |
| `src/lib/bridge/workItemValidation.ts` | `parseCreatedWorkItemCopies` |
| `src/lib/features/work-items/QuickCreateWorkItemDialog.svelte` | 多项目选择 |
| `src/lib/features/work-items/PendingWorkItemsView.svelte` | 创建编排 |
| `scripts/quality/work-item-bridge.test.mjs` | 批量契约测试 |
| `scripts/verify/verify-t1-04-ui.ps1`、`inspect-t1-04-ui.mjs`、`inspect-t1-04-min-window.mjs`、`inspect-t1-04-persistence.mjs`、`probe-t1-04-db.py` | 新增 E2E/探针 |
| `scripts/verify/VerifyCommon.ps1`、`inspect-release-ui.mjs`、`inspect-t1-02-ui.mjs` 等 | schema 版本期望 3 → 4（仍有效的脚本） |
| 文档 | PRD / DECISIONS / TECHNICAL_DESIGN / DEVELOPMENT_PLAN / STATUS / T1-04 报告与证据 |

---

## 9. 回归范围

- T1-01：便携路径、数据库初始化、migration 引擎、异常保护、Release 便携验证与异常注入验证；
- T1-02：项目管理 UI E2E、项目 CRUD/归档行为与契约；
- T1-03：单条创建（未归属/单项目）、标题校验、归档项目拒绝、待安排列表与刷新状态（业务规则由 Rust 测试 + T1-04 E2E 场景回归；T1-03 原 UI 脚本控件基线已变更，不作为可执行回归基线，历史证据不修改）；
- schema 4 对既有测试/验证脚本的期望值更新；
- 不修改历史证据 JSON、历史审计报告、T1-03 分支与 main。

---

## 10. GitHub 交付流程

1. 全部质量门禁通过；
2. 检查 `git diff` 与敏感信息（不提交真实数据/数据库/日志/构建产物）；
3. 更新开发计划、STATUS、T1-04 报告与证据；
4. 提交 T1-04 变更（代码 + 测试 + 文档），推送 `task/T1-04-multi-project-copies`；
5. PR #8 未合并 → **不创建指向 main 的 T1-04 PR**，只推送独立分支并报告准确的远端分支名与后续操作；
6. PR #8 合并后 → 从更新后的 main 创建新的 T1-04 交付分支，只迁移 T1-04 自身提交，再创建正式 PR；
7. 不自动合并、不宣布独立审计/用户验收通过、不进入 T1-05。

---

## 11. 风险与未决事项

- **T1-03 尚未独立审计**：本轮堆叠开发不改变 T1-03 状态；T1-04 的自测结论不代表 T1-03 已通过审计或验收。
- T1-04 的迁移测试会在失败注入时触发器改写/回滚真实 SQLite 测试数据库；所有故障注入仅用于 D 盘隔离测试目录与 UAT 目录，不在正式数据目录执行。
- schema 4 会改变继承验证脚本的版本期望；只能更新仍有效的脚本，不能修改历史证据中的真实执行记录。
- 普通 SQLite 未加密；TOCTOU 按 DEC-029 延期至 Issue #2，本任务不修复。
