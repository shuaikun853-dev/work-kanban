# T1-03 开发设计（编码前确认）

**任务：** T1-03 工作事项快速创建和待安排区域  
**分支：** `task/T1-03-quick-create-pending`  
**基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`（T1-02 已验收合并）  
**编写时间：** 2026-11-19  
**状态：** 编码前设计；实现必须严格按本设计与权威文档执行。若实现与设计不一致，必须在本文件或测试报告中说明原因。

本设计依据（按优先级）：

1. 用户 2026-11-19 明确指令与 DEC-033（新工作只能关联未归档项目）；
2. `docs/development/tasks/T1-03-Quick-Work-Item-Creation.md`；
3. `docs/requirements/PRD.md` V0.3.2（PRD-AT-01、PRD-AT-17）；
4. `docs/architecture/TECHNICAL_DESIGN.md`（5.1、5.4、5.6、6.1、6.2、7.4）；
5. `docs/design/UI-DESIGN-SPEC.md` V1.1 与原型图；
6. `AGENTS.md` 与 T1-01 / T1-02 已合并代码约定。

---

## 1. 范围

本任务只交付“工作事项快速创建 + 待安排列表”一个纵向切片：

- schema 2 → 3 migration：新增 `work_items` 表；
- Rust Core `work_items` 领域模块：创建、待安排查询、稳定错误码；
- Tauri typed IPC：`create_work_item`、`list_pending_work_items`；
- TypeScript Contracts / Bridge（运行时返回值校验）；
- 今日工作页面下的“待安排”次级视图 + 快速创建对话框；
- 自动化测试、Windows Release 实测、截图与证据、GitHub 交付。

明确不在范围（不得实现）：T1-04 多项目副本、T1-05 状态流转与历史、每日计划、优先级评分/排序、当前工作指针、跳过/补录、复盘、日志、附件、报表、清理、备份恢复。不新增一级导航，不修改 T1-01/T1-02 已验收行为，不修改 AppShell/Sidebar/全局 Design Tokens。

---

## 2. 数据模型（schema 3）

新增 `crates/workmanager-core/migrations/0003_work_items.sql`。沿用现有 migration 引擎：独立 `IMMEDIATE` 事务、失败回滚、`user_version` 只在成功后前进；不修改 0001/0002。

```sql
CREATE TABLE work_items (
    id               TEXT PRIMARY KEY NOT NULL,
    project_id       TEXT REFERENCES projects(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    title            TEXT NOT NULL CHECK (length(trim(title)) > 0),
    lifecycle_status TEXT NOT NULL DEFAULT 'pending'
                     CHECK (lifecycle_status IN
                         ('pending', 'not_started', 'in_progress', 'completed', 'abandoned')),
    importance       INTEGER CHECK (importance IS NULL OR (importance BETWEEN 1 AND 5)),
    urgency          INTEGER CHECK (urgency IS NULL OR (urgency BETWEEN 1 AND 5)),
    due_date         TEXT,
    description      TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
) STRICT;

CREATE INDEX idx_work_items_status_created_at
    ON work_items (lifecycle_status, created_at DESC, id DESC);
CREATE INDEX idx_work_items_project_status
    ON work_items (project_id, lifecycle_status);
```

设计说明：

- `project_id` 可空并显式 `ON DELETE RESTRICT`：未归属工作合法；项目/工作都不允许级联删除。
- `lifecycle_status` 五值对应 PRD 5.3 的五种状态；内部代码 `pending` / `not_started` / `in_progress` / `completed` / `abandoned`，本任务只写入 `pending`；状态流转属于 T1-05。
- `importance` / `urgency` / `due_date` / `description` 允许 NULL，表示“尚未设置”，不伪造默认评分；本任务不提供填写入口。`pinned_rank` 属于 T2-02/T2-03 手动排序，不在本 migration 提前创建。
- 不建立标题唯一约束（PRD 5.2：同一标题不代表同一条工作记录）。
- 表使用 STRICT；所有时间戳为 UTC RFC3339 毫秒字符串，展示由前端按业务时区处理。
- 排序（待安排）固定为 `created_at DESC, id DESC`：创建时间倒序、稳定 ID 次级键；不支持手动排序。

---

## 3. Rust Core 设计

### 3.1 模块结构

`crates/workmanager-core/src/work_items/`：

| 文件 | 职责 |
|---|---|
| `model.rs` | `WorkItem`、`PendingWorkItem`、`normalize_title`、生命周期常量 |
| `repository.rs` | 参数化 SQL：插入、按 ID 查询、待安排 JOIN 查询、项目状态查询 |
| `service.rs` | 业务规则与事务边界：创建（同一 `IMMEDIATE` 写事务内校验项目）、待安排列表 |
| `error.rs` | `WorkItemError` 与稳定错误码 |
| `mod.rs` | 模块导出 |

`lib.rs` 导出 `WorkItem`、`PendingWorkItem`、`WorkItemError`、`WorkItemService`、`WORK_ITEM_STATUS_PENDING` 等。

### 3.2 创建流程（`WorkItemService::create`）

1. `normalize_title(raw)`：`trim()` 后必须非空；空/纯空白返回 `work-item-title-empty`。内部空白保留，不限制长度。
2. `project_id` 输入为 `Option<String>`；`None` = 未归属。
3. 在 `Database::write_transaction`（`IMMEDIATE`）中：
   1. 若 `project_id = Some(id)`：同一事务内 `SELECT is_archived FROM projects WHERE id = ?`；
      - 不存在 → `project-not-found`（回滚）；
      - `is_archived = 1` → `project-archived`（回滚）；
      - 未归档 → 允许。
   2. Rust Core 生成 UUID v4 作为工作事项 ID；`lifecycle_status = pending`；时间戳 UTC RFC3339 毫秒。
   3. 插入 `work_items`；再在事务内按 ID 读回，返回数据库中的最终记录。
4. 项目存在性/归档状态检查与插入处于同一个 `IMMEDIATE` 事务：即使前端项目列表加载后项目被归档，提交时也会被拒绝；并发归档与创建由 SQLite 写锁串行化，不会产生“已归档项目的新关联”。

### 3.3 待安排查询（`WorkItemService::list_pending`）

```sql
SELECT w.id, w.project_id, p.name, p.is_archived, w.title,
       w.lifecycle_status, w.created_at, w.updated_at
FROM work_items w
LEFT JOIN projects p ON p.id = w.project_id
WHERE w.lifecycle_status = ?1
ORDER BY w.created_at DESC, w.id DESC
```

- 参数绑定 `lifecycle_status = 'pending'`；
- 有项目/无项目都返回；项目归档后历史关联保留，`project_is_archived = true` 供 UI 轻量提示；
- 只返回 `pending`，不混入其他状态。

### 3.4 错误码

| 错误 | 错误码 | 中文消息（不包含工作标题/SQL 参数） |
|---|---|---|
| 标题为空 | `work-item-title-empty` | 工作标题不能为空，请填写工作标题。 |
| 项目不存在 | `project-not-found` | 项目不存在或已被删除。请刷新项目列表后重试。 |
| 项目已归档 | `project-archived` | 所选项目已归档，不能再关联新工作。请选择其他项目或不选择项目。 |
| 数据库错误 | 透传 T1-01 结构化错误码 | 现有中文数据库错误消息 |

不 panic 代替业务错误；不把工作标题、项目名称、SQL 参数写入日志（本模块不写日志）。

---

## 4. Tauri IPC 契约

### 4.1 命令

| 命令 | 请求 | 返回 |
|---|---|---|
| `create_work_item` | `{ input: CreateWorkItemRequest }` | `WorkItemDto` |
| `list_pending_work_items` | 无参数 | `PendingWorkItemDto[]` |

### 4.2 DTO（serde `rename_all = "camelCase"`；请求 `deny_unknown_fields`）

`CreateWorkItemRequest`：

```json
{ "title": "整理中核商品数据", "projectId": null }
```

- `title: String`（必填）；
- `projectId: Option<String>`：显式 `null` 表示未归属；字段缺省同样按 `null` 处理（serde Option 语义），文档明确要求前端显式传 `null`。

`WorkItemDto`（创建返回）：

```json
{
  "id": "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001",
  "projectId": null,
  "title": "整理中核商品数据",
  "lifecycleStatus": "pending",
  "createdAt": "2026-11-19T10:00:00.000Z",
  "updatedAt": "2026-11-19T10:00:00.000Z"
}
```

`PendingWorkItemDto`（待安排列表项）：

```json
{
  "id": "9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001",
  "projectId": null,
  "projectName": null,
  "projectIsArchived": false,
  "title": "整理中核商品数据",
  "lifecycleStatus": "pending",
  "createdAt": "2026-11-19T10:00:00.000Z",
  "updatedAt": "2026-11-19T10:00:00.000Z"
}
```

- 未归属时 `projectId` / `projectName` 为 `null`，`projectIsArchived = false`；
- 关联归档项目时 `projectName` 仍返回项目名称，`projectIsArchived = true`。

失败统一 `{ "code": "...", "message": "..." }`（现有 `CommandError`）。

### 4.3 适配层

- `src-tauri/src/commands/work_items.rs`：只做 DTO、参数转发、`spawn_blocking`、错误转换；不写业务规则。
- `src-tauri/src/app_state.rs`：新增 `WorkItemContext`（`Arc<Mutex<Option<Database>>>`），暴露 `create_work_item` / `list_pending_work_items`；数据库关闭时返回结构化错误。
- `CommandError` 增加 `From<WorkItemError>`。
- `src-tauri/src/lib.rs` 注册两个命令。
- 不提供任意 SQL / 文件 / 命令 IPC。

---

## 5. 前端设计

### 5.1 组件树（不新增一级导航）

```text
src/App.svelte（不变）
└── app/AppShell.svelte（不变）
    └── lib/features/today/TodayPage.svelte（修改：仅增加次级视图切换）
        ├── PageHeader（标题“今日工作”；副标题随次级视图变化；不新增一级导航）
        ├── 次级视图切换（今日工作 | 待安排，role=tablist；不进入 Sidebar）
        ├── 今日工作视图：保留现有“执行记录尚未接入”说明（不新增业务数据）
        └── lib/features/work-items/PendingWorkItemsView.svelte
            ├── 区域工具栏：区域标题“待安排” + 数量 + Button“新增工作”
            ├── loading 面板（role=status）
            ├── 错误面板（role=alert + 错误码 + “重新加载”）
            ├── EmptyState（暂无待安排工作 + 创建入口）
            ├── PendingWorkItemList.svelte
            │   └── each PendingWorkItemRow.svelte（key = 稳定工作事项 ID）
            └── QuickCreateWorkItemDialog.svelte（可复用独立快速创建组件）
                ├── 工作标题输入框（必填、trim、自动聚焦）
                ├── 可选项目选择器（仅未归档项目 + “未归属项目”）
                ├── 保存 / 取消
                ├── 提交中状态（禁用重复提交）
                └── 错误提示（中文消息 + 稳定错误码）
```

组件边界：页面容器（`PendingWorkItemsView`）负责加载/创建/刷新和状态机；展示组件（List/Row/Dialog）只展示与回调，不直接调用桥接命令。所有颜色/间距/圆角来自现有 Design Tokens，不新增 Token、不引入新依赖。

### 5.2 页面状态流

```text
进入“今日工作” → 默认“今日工作”视图（不加载业务数据）
切到“待安排” → loading → 成功：empty / list；失败：error(可重试)
点“新增工作” → 打开对话框
  ├─ 并行加载未归档项目（失败不阻塞未归属创建，显示轻量提示）
  ├─ 保存：title.trim() 为空 → 前端提示不提交
  ├─ 保存中：submitting=true，保存按钮禁用，重复点击被同步守卫拦截
  ├─ 成功：关闭对话框 → 重新从后端读取待安排列表（权威刷新）
  ├─ 失败：保留对话框，展示错误码/消息；若项目被归档/不存在则刷新项目选项并清除失效选择
  └─ 取消：关闭，不写数据
项目列表加载后、提交前项目被归档 → Core 返回 project-archived → UI 显示错误，不新增记录
关联归档项目的历史工作 → 列表保留，显示项目名称 + “项目已归档”轻量标识
```

### 5.3 技术分层文件

| 文件 | 职责 |
|---|---|
| `src/lib/contracts/workItems.ts` | DTO、命令名、请求类型（唯一前后端契约来源） |
| `src/lib/bridge/workItemValidation.ts` | 纯运行时校验/解析（可被 Node 测试直接加载） |
| `src/lib/bridge/workItems.ts` | `invoke` 封装、错误转 `WorkItemIpcError` |
| `src/lib/features/work-items/QuickCreateWorkItemDialog.svelte` | 快速创建对话框 |
| `src/lib/features/work-items/PendingWorkItemsView.svelte` | 待安排 view 容器（加载/创建/刷新/错误） |
| `src/lib/features/work-items/PendingWorkItemList.svelte` | 列表容器（keyed each） |
| `src/lib/features/work-items/PendingWorkItemRow.svelte` | 单行展示（标题优先、项目辅助、归档标识） |
| `src/lib/features/today/TodayPage.svelte` | 次级视图入口（仅此一处修改 Today 页） |

UI 规则：工作标题优先显示；项目信息弱化为辅助信息；无项目显示“未归属项目”；归档项目显示轻量“项目已归档”；长标题单行省略并保留 `title` 全文；列表使用细分隔线、紧凑行高；loading/empty/error/submit 均有明确状态；不展示任何虚构工作数据。

---

## 6. 测试计划

### 6.1 Rust / SQLite（`crates/workmanager-core/tests/work_items.rs`、`work_items_migration.rs`）

migration：

1. schema 2 → 3 升级成功；`user_version = 3`、`schema_migrations` 记录 1/2/3；
2. 升级前写入的项目（含归档项目）全部保留；
3. 重复打开数据库（已是最新版本）安全、不重复执行 migration；
4. 注入失败的 migration 3：事务回滚、`user_version` 停在 2、不留下 `work_items` 表、原项目保留；
5. 外键检查/完整性检查通过；migration SQL 不包含事务控制语句（沿用现有引擎测试）。

领域：

6. 仅标题创建成功；状态 `pending`；UUID 由 Core 生成且格式有效；
7. 标题首尾空白规范化；内部空白保留；
8. 空/纯空白标题拒绝（`work-item-title-empty`），数据库无记录；
9. 相同标题连续创建产生不同 ID、两条独立记录；
10. 未设置字段为 NULL（不伪造 importance/urgency/due_date/description）；
11. 未归属创建成功，查询返回 `project_id = NULL`；
12. 有效未归档项目关联成功，项目名称正确；
13. 不存在项目拒绝（`project-not-found`），无记录；
14. 已归档项目拒绝（`project-archived`），无记录；
15. 项目归档后既有工作关联保留（`project_id` 不变、仍可查询、`project_is_archived = true`）；
16. 待安排查询只返回 `pending`，不混入其他四种状态；
17. 排序稳定：`created_at DESC, id DESC`；
18. 并发边界：归档事务先提交后创建必须失败；创建事务先提交后归档保留关联；并发创建/归档不产生违反 DEC-033 的新关联；
19. 外键 RESTRICT：有工作关联的项目不能被直接删除；工作事项 `project_id` 指向不存在项目时 FK 拒绝；
20. 默认状态约束：不指定 `lifecycle_status` 的直接插入得到 `pending`；
21. 错误消息不回显工作标题/项目名称。

### 6.2 Tauri IPC（`src-tauri` 单测）

22. `CreateWorkItemRequest` camelCase 解析、`projectId: null`、缺省字段、未知字段拒绝；
23. `WorkItemDto` / `PendingWorkItemDto` serde camelCase 字段名与 `null` 序列化；
24. `CommandError` 正确传递 `work-item-title-empty` / `project-archived` 错误码；
25. `WorkItemContext` 真实数据库生命周期（创建、列表、归档后拒绝、数据库关闭结构化错误）。

### 6.3 前端 / Bridge

26. 新增 `scripts/quality/work-item-bridge.test.mjs`：对`workItemValidation.ts`做 Node 运行时校验测试（合法 DTO 通过；缺字段/类型错误/非法状态/非数组/null 处理抛 `ipc-contract-violation`）；不新增测试框架依赖，接入 `npm run check`；
27. `npm run check`（svelte-check + Design Token 检查 + 既有测试 + 新 Bridge 契约测试）；
28. `npm run build`。

### 6.4 Windows Release 实测（`scripts/verify/verify-t1-03-ui.ps1` + 三个 CDP 检查脚本）

在独立 UAT 目录（`D:\WorkManager-test-data\t1-03-ui-*`）使用虚构数据：

1. Release 启动；应用壳/6 个一级导航/无新增一级导航；
2. 今日工作 → 待安排入口；空状态；真实异步 loading；真实创建未归属工作；未归属标识；
3. 重复提交保护（同步双点击只产生一条记录）；
4. 真实创建关联未归档项目的工作；选择器只出现未归档项目；
5. 对话框打开期间项目被归档 → 保存返回 `project-archived`，UI 显示错误；
6. 直接 IPC 传归档项目 ID → 后端拒绝 `project-archived`（绕过前端）；
7. 直接 IPC 传空标题 → `work-item-title-empty`；未知字段拒绝；不存在项目 `project-not-found`；
8. 加载失败 + 重试（CDP 故障注入，不修改产品代码）；Bridge 契约违规被 UI 捕获并显示 `ipc-contract-violation`；
9. 关联归档项目的历史工作仍在待安排列表并显示“项目已归档”；
10. 页面无未捕获异常、CSP 0 违规、正常窗口与最小窗口（860×640）无横向溢出/遮挡/标题裁切，按钮可点击；
11. 最小窗口截图 + 点击红色关闭按钮后进程真实退出；
12. 重新启动同一便携目录：工作事项持久化；列表内容、项目名称、归档标识正确；重启后仍可创建；
13. 数据库位于 UAT 便携目录（`<uat>\app\data\database\work.db`），`user_version = 3`，数据行数与 UI 一致（只读 Python sqlite3 探针）；
14. 继承回归：`verify-release-portable.ps1`、`verify-release-faults.ps1`、`verify-t1-02-ui.ps1`（schema 期望更新为 3）、数据库诊断页。

### 6.5 质量门禁命令

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

## 7. 明确不做 / 回归控制

- 不新增一级导航、不改 AppShell/Sidebar/设计 Token、不重写 TodayPage 既有占位说明以外的内容；
- 不修改 `list_projects` 契约（仍返回全部项目，含归档项目）；前端选择器只过滤可选项，安全边界在 Rust Core 事务内；
- 不修改 T1-01 便携路径/数据库初始化逻辑；仅把受 schema 版本影响的测试/验证脚本期望从 2 更新为 3；
- 不引入 ORM、migration crate 或其他第三方依赖；不新增前端测试框架依赖；
- 不记录工作标题、项目名称或 SQL 参数到日志；测试数据全部虚构。
