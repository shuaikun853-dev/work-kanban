# T1-04 开发设计（编码前确认）

**任务：** T1-04 多项目独立副本创建  
**分支：** `task/T1-04-multi-project-copies`（从 T1-03 最新真实 HEAD 堆叠）  
**堆叠基线：** `e8205cae22e98afce6480f5a5a0695543a61dee3`（T1-03 分支 HEAD，PR #8 Open）  
**main 基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`（未包含 T1-03/T1-04）  
**编写时间：** 2026-11-24  
**状态：** 编码前设计（第五轮 T104-01～T104-06、第六轮 R2-01～R2-04 修复后已按实际实现补充说明，见第 12 节）。实现必须严格按本与权威文档执行；若实现与设计不一致，必须在测试报告或本文件补充说明原因。

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

`WorkItemService::create_copies(database: &mut Database, request_id: &str, raw_title: &str, project_ids: &[String]) -> Result<CreatedWorkItemCopies, WorkItemError>`

执行顺序：

1. 标题 trim 与非空校验（`normalize_title`，空 → `work-item-title-empty`）；
2. 客户端 `request_id` 必须是规范小写连字符 UUID（`Uuid::parse_str` 后 `hyphenated()` 与原文逐字相等），否则 `work-item-create-request-id-invalid`；该标识直接作为创建组主键，不新增 schema 字段；
3. 项目数量校验：`project_ids.len() >= 2`，否则 `work-item-copies-too-few`；
4. 项目 ID 去重校验：出现重复 → `work-item-copies-duplicate-project`（不得静默去重）；
5. 为每个项目生成一个独立工作事项 UUID（由 Rust Core 生成）与统一 UTC RFC3339 毫秒时间戳；创建组 ID 直接复用客户端 requestId，不另行生成创建组 UUID；
6. 在**一个** `Database::write_transaction`（`IMMEDIATE`）内：
   1. 先按请求标识读取既有创建组：相同标题与项目列表 → 原样返回既有批次，不写任何行；不同标题/项目列表 → `work-item-create-request-conflict`；不存在才继续；
   2. **先验证全部项目**（循环全部 `project_id`，不插入任何记录）：
      - 不存在 → `project-not-found`；
      - 已归档 → `project-archived`；
      - 全部未归档才继续；
   3. 插入创建组（`id` = 请求标识、`source_title`、`created_at`）；
   4. 依次插入全部 `work_items`（`project_id` 各自对应、`lifecycle_status = pending`、未设置字段保持 NULL）；
   5. 依次插入全部成员关系（`group_id`、`work_item_id`）；
   6. **事务内读回验证**：
      - 创建组按 ID 读回，`source_title` / `created_at` 必须一致；
      - 每个工作事项按 ID 读回，必须与内存记录逐字段一致；
      - 成员关系读回数量必须等于项目数，且每个成员 `group_id` 正确、`work_item_id` 对应的工作事项 `project_id` 与请求项目一一对应；
      - 任一项不一致 → `work-item-persistence-verification-failed`（回滚）；
   7. 全部成功才提交并返回读回记录。
7. 失败路径由 `write_transaction` 显式回滚；不允许部分成功、静默跳过或补偿删除。

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
| 请求标识非规范 UUID | `work-item-create-request-id-invalid`（第五轮新增） | 创建请求标识无效，请重新发起创建。 |
| 同请求标识不同内容 | `work-item-create-request-conflict`（第五轮新增） | 该创建请求与已处理的内容不一致，请重新发起创建。 |
| 数据库错误 | 透传 T1-01 结构化错误码 | 现有中文数据库错误消息 |

错误消息不得包含标题、项目名称、请求标识或 SQL 参数；不 panic 代替业务错误；本模块不写日志。

### 3.5 幂等请求标识（第五轮 T104-02）

**结论：复用现有 `work_item_creation_groups.id` 作为客户端请求标识，不新增字段或 migration。**

理由与约束：

1. `work_item_creation_groups.id` 已是 `TEXT PRIMARY KEY`，UUID 语义与客户端请求标识一致；
2. 服务端在同一 `IMMEDIATE` 写事务内先按请求标识读取创建组：
   - 不存在 → 执行正常整批创建，组主键直接写入该请求标识；
   - 存在且标题、项目列表完全一致 → 读回组内工作副本并按请求项目顺序返回，不写任何行；
   - 存在但标题或项目列表不同 → `work-item-create-request-conflict`，不覆盖、不追加；
3. 幂等读取发生在项目归档校验之前：已提交批次的项目后来归档时，重试仍返回既有结果，而不是 `project-archived`；
4. 同一请求标识的两个并发请求由 SQLite `IMMEDIATE` 写事务串行化，第一个提交后第二个读取既有批次，只能存在一个批次；
5. 不再需要单独的 `request_id` 列或唯一索引，也不需要新增 schema 版本；
6. 组内每个工作副本的 ID 仍由 Rust Core 生成独立 UUID v4，与 `requestId` 无关；创建组主键才复用 `requestId`；
7. 组内成员 JOIN 行数与原始成员行数交叉校验；内部不一致 fail-closed 为 `work-item-persistence-verification-failed`，绝不静默重建。

前端请求标识生命周期：

- 第一次批量提交时用 `crypto.randomUUID()`（缺失时用 `crypto.getRandomValues` 生成 UUID v4）生成；
- 与规范化标题、项目顺序绑定；
- IPC 失败、Bridge 契约解析失败或用户重试时保留；
- 用户修改标题或项目选择后生成新标识；
- 只有服务端成功响应通过 Bridge 严格校验后才清理；
- 不得因响应解析失败自动换新标识，也不得让不同创建操作共享同一标识。

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
    pub request_id: String,          // JSON: requestId，规范 UUID
    pub title: String,
    pub project_ids: Vec<String>,   // JSON: projectIds
}
```

```json
{
  "requestId": "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a030",
  "title": "中核商品价格异常排查",
  "projectIds": ["project-a", "project-b"]
}
```

- serde camelCase；`deny_unknown_fields`；`requestId` 必填且必须是规范 UUID 字符串；
  `projectIds` 必填且必须是字符串数组（`null`/缺省/字符串均被拒绝）；
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
  readonly requestId: string;
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
  requestId: string,
  title: string,
  projectIds: readonly string[]
): Promise<CreatedWorkItemCopiesDto>
```

- 调用 `invoke('create_work_item_copies', { input: { requestId, title, projectIds } })`；
- `requestId` 由页面容器在“标题 + 项目顺序”未变化时复用，成功确认后清理；
- 失败载荷统一转换为 `WorkItemIpcError`（复用现有逻辑）；
- 成功返回值必须通过 `parseCreatedWorkItemCopies(raw, { requestId, title, projectIds })`。

### 5.3 严格运行时校验（`src/lib/bridge/workItemValidation.ts`）

`parseCreatedWorkItemCopies(raw, request)`（`request: CreatedCopiesRequestContext`）必须验证：

1. 响应是严格对象，恰好 `groupId`、`workItems` 两个字段（缺字段/未知字段拒绝）；
2. `request.requestId` 必须是规范小写连字符 UUID（Rust 拒绝大写/非规范形式）；
3. `groupId` 必须是规范 UUID，且必须与 `request.requestId` 逐字相等（合法但不同的 UUID 也拒绝）；
4. `request.title` 必须是字符串且去除首尾空白后非空；每个副本 `title` 必须等于该 trim 结果（不改变大小写、不折叠内部空白）；
5. `requestedProjectIds` 为非空字符串数组、至少 2 个且无重复（请求本身不合法 → 契约违规，不进行部分解析）；
6. `workItems` 是数组，长度等于请求项目数；
7. 每个元素通过现有 `parseWorkItem` 严格校验（10 字段、无缺失/额外字段、状态 `pending`）；
8. 每个副本 `projectId` 非空，且必须属于请求项目集合；
9. 每个请求项目恰好出现一次（不重复、不缺失、不替换为其他项目）；
10. 工作事项 ID 全部唯一；
11. 任一项失败抛出稳定错误码 `ipc-contract-violation` 的 `WorkItemIpcError`，不静默忽略。

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

---

## 12. 实现记录与偏差说明（2026-11-24）

最终实现与本编码前设计总体一致，以下为需要审计核对的实现事实与少量补充说明：

1. **Tauri 请求包装：** 新命令使用与既有命令一致的 `input` 参数包装（前端发送 `{ input: { requestId, title, projectIds } }`），业务请求 DTO 内容与设计要求一致（camelCase `requestId` / `title` / `projectIds`）；响应直接为 `{ groupId, workItems }`，其中 `groupId` 是服务端校验后直接复用的客户端 `requestId`。
2. **成员关系表字段：** `work_item_creation_group_members` 只包含设计要求的最低字段 `group_id`、`work_item_id`（技术设计 5.1 未要求其他字段）；使用复合主键 `(group_id, work_item_id)` 与 `work_item_id UNIQUE` 实现“每个工作事项最多一个创建组”，不额外增加冗余索引。
3. **“验证全部项目”的实现语义：** Core 在任何插入之前按请求顺序逐个查询全部项目状态；遇到第一个不存在/已归档项目立即返回业务错误并回滚（此时尚未插入任何记录）。该实现满足“不得只检查第一个项目、全部验证通过后才开始插入、任一无效整批失败”的原子性要求，但不会在已发现一个无效项目后继续查询其余项目（对用户可见行为与回滚结果无差异）。审计如需“必须查询全部项目”的更强定义，可在后续任务调整。
4. **时间戳：** 一次批量创建的全部副本与创建组共享同一 UTC RFC3339 毫秒时间戳；待安排排序仍为 `created_at DESC, id DESC`，因此同批次内以稳定 ID 次级排序，顺序稳定。
5. **创建组读回验证：** 提交前在事务内读回创建组（`source_title`/`created_at`）、每个工作副本（逐字段相等）与全部成员关系（数量、group、work_item→project 映射）；成员集合与请求副本集合双向比对，防止多余/缺失成员。读回不一致统一返回 `work-item-persistence-verification-failed`。
6. **故障注入：** Rust 测试使用真实 SQLite `TRIGGER`（第二条副本插入失败、第二条成员关系失败、事务内读回篡改）制造真实数据库错误，不在生产代码增加故障开关。Release E2E 通过 `control-t1-04-fault.py` 仅在 D 盘独立 UAT 数据库安装 `BEFORE INSERT` trigger，验证整批回滚、无残留；未在正式数据目录执行，未修改 Windows ACL。
7. **Bridge 契约：** `parseCreatedWorkItemCopies(raw, request)` 必须获得完整请求上下文（`requestId`、`title`、`projectIds`）：除响应字段/数量/项目一一对应/ID 唯一/pending 外，还验证 `groupId === requestId`（合法但不同 UUID 拒绝）与每个副本 `title === request.title.trim()`；并校验调用方请求项目列表（≥2、非空、不重复）；若调用方传入非法请求列表，即使后端返回成功也按 `ipc-contract-violation` 拒绝，避免“请求与响应不一致被静默接受”。
8. **UI 成功提示：** 单条创建显示“已创建 1 项工作”；批量创建使用 Rust 返回的 `workItems.length` 作为实际数量，不使用前端预计数量。创建成功与列表刷新成功/失败三态沿用 T1-03 的分离策略。
9. **失效选择：** T1-03 的“项目列表刷新后自动回退为未归属项目”逻辑已移除；T1-04 中失效项目选择保留在对话框中，标记为不可用，Submit 被禁用，必须由用户点击“移除”或调整选择后才能再次提交。
10. **测试/验证脚本调整：** schema 3→4 导致 `VerifyCommon.ps1`、`inspect-release-ui.mjs`、`inspect-t1-02-ui.mjs` 的 schema/migration 期望更新；T1-02 诊断页 migrationRows 期望由 1–3 更新为 1–4。T1-03 历史证据 JSON、历史审计报告与 T1-03 分支未修改；T1-03 原 UI E2E 脚本因控件从单选扩展为多选不再作为可执行回归基线（未修改），T1-03 业务规则回归由 Rust 测试与 T1-04 E2E 场景覆盖。
11. **最小窗口 E2E 时序：** 首次 E2E 运行时 WebView2 对 `SetWindowPos` 的布局传播存在时序差异，导致最小窗口检查读取到旧视口。修复仅位于测试脚本（`inspect-t1-04-min-window.mjs` 增加 `waitForViewportSettled` 确定性等待），未修改产品代码；修复后最小窗口 11/11 通过。
12. **实际结果（第二轮交付基线）：** `cargo test --workspace` 149/149；Release E2E 主 96/96 + 最小窗口 11/11 + 故障回滚 13/13 + 持久化 15/15 + 数据库探针 57/57；三次真实关闭退出码 0/0/0。详见 [T1-04-REPORT.md](../../testing/reports/T1-04-REPORT.md)。

### 12.1 第五轮定向修复记录（2026-11-24）

- **T104-01：** 新增 `T1-04UatPath.ps1` / `guard-t1-04-path.ps1` / `t1_04_path_guard.py`，复用 T1-03 Windows 原生句柄、测试根目录信任锚、重解析点拒绝、卷序列号 + 文件 ID + 真实最终路径校验；Python 故障注入控制器与只读探针在任何 `sqlite3.connect()` / 写文件前 fail-closed；证据目录固定 `<uat-root>\evidence`。
- **T104-02：** 客户端 `requestId` 直接复用为 `work_item_creation_groups.id`，服务端写事务内返回既有批次或稳定冲突；真实 IPC 响应异常后同标识重试仍 1 组 / 2 副本 / 2 成员。
- **T104-03～T104-06：** Red/Green 证据、真实 0004 索引冲突回滚、CSP 实际采集、STATUS/DEVELOPMENT_PLAN 状态统一。
- 测试先行提交 `b4f641a`、实现与验证工具提交 `e6b3f22`；最新质量门禁与 Release E2E 结果见报告第 10 节。

### 12.2 第六轮定向修复记录（2026-11-24）

1. **R2-01 路径安全测试自身信任锚与 fail-closed 清理：** `test-t1-04-path.py` 在创建任何测试目录之前调用 `guard-t1-04-path.ps1 -Kind test-root` 验证测试根目录信任锚（自身 + 全部祖先 + 重解析点 + 卷身份 + 文件 ID + 真实最终路径）；测试根 / UAT 根 / 数据库目录 / 证据目录创建前后均通过 `uat-root-target` / `uat-root` 原生守卫复验；清理改为 `guard-t1-04-cleanup.ps1`（复用 T1-03 `Invoke-T103FailClosedSandboxCleanup`），身份变化 / 重解析点 / 守卫失败拒绝删除；证据写入固定 `<UAT根>\evidence\<file>.json` 并写入前后守卫；`formalRootTouched` 硬编码字段替换为正式目录只读身份快照（前后比对 + 守卫拒绝正式路径证据），无法读取时明确标记证据不足。
2. **R2-02 Migration 验证工具原生守卫：** `verify-t1-04-migration-failure.ps1` 不再使用 `GetFullPath().StartsWith` 字符串判断；UAT 根 / 数据库目录 / 数据库文件 / 证据目录在创建、复制 EXE、启动 Release 前通过 T1-04 原生守卫，清理只清理 `migration-failure-uat` 子目录且复用 fail-closed 身份复验（证据目录保留用于写入证据）；`t1-04-migration-fixture.py` setup 在 `sqlite3.connect()` 前执行 `database-target` 守卫、独占创建文件、创建后再执行 `database` 守卫，probe 在只读连接前执行 `database` 守卫且失败不降级。
3. **R2-03 Bridge 严格业务契约：** `parseCreatedWorkItemCopies(raw, request)` 获得完整请求上下文，新增 `groupId === requestId`（合法但不同 UUID 拒绝）与每个副本 `title === request.title.trim()` 校验；Bridge `createWorkItemCopies` 传入完整上下文；Node Bridge 契约测试 27 → 35 项。
4. **R2-04 文档与契约描述统一：** 技术设计 5.4.1、Rust model/service 注释、TypeScript contracts/bridge 注释、任务说明与报告统一为“客户端生成 `requestId`，Rust Core 校验并直接作为创建组主键；工作副本 ID 由 Rust Core 生成；不新增数据库字段或 migration”。未改变 DEC-034 整批原子事务语义；未新增 schema 字段或 migration。
