# T1-03 工作事项快速创建和待安排区域 — 测试与交付报告

**任务 ID：** T1-03
**任务名称：** 工作事项快速创建和待安排区域
**当前状态：** **待独立审计**（开发自测完成；PR 未合并；main 未修改）
**开发分支：** `task/T1-03-quick-create-pending`
**目标分支：** `main`
**开发基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`（T1-02 已验收合并后的 main）
**实现提交：** `be8d9c2e9c78710690de189936d6ee65f48ed8df`（feat(T1-03): quick-create work items and pending list vertical slice）
**预编码设计提交：** `9c091567351c4290b9f6ec1cea59f1e0d5f7bf6b`
**Pull Request：** [PR #8](https://github.com/shuaikun853-dev/work-kanban/pull/8)（指向 main，保持 Open，等待独立审计）
**报告生成时间：** 2026-11-19（Asia/Shanghai）
**测试环境：** Windows 10 家庭中文版 10.0.19045；Windows PowerShell 5.1.19041.6456；rustc 1.100.0 / cargo 1.100.0；Node.js v22.20.0 / npm 10.9.3；Python 3.14.5
**测试数据：** 全部为虚构内容；UAT 目录 `D:\WorkManager-test-data\t1-03-ui-run2` 已清理前保留证据副本；未触碰正式运行目录 `D:\WorkManager`

---

## 1. 实际实现范围

### 1.1 数据库（schema 2 → 3）

新增 `crates/workmanager-core/migrations/0003_work_items.sql`，沿用现有 migration 引擎（独立 `IMMEDIATE` 事务、失败回滚、`user_version` 成功后前进）；未修改 0001/0002。

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

- `project_id` 允许 NULL（未归属）；外键 `ON DELETE RESTRICT`，项目/工作事项均不允许级联删除。
- 生命周期五值按 PRD 5.3 预留 CHECK；T1-03 只写入 `pending`，流转属于 T1-05。
- `importance`/`urgency` 未设置保持 NULL，不伪造评分；本任务不提供填写入口。`pinned_rank` 属于后续排序任务，本 migration 不提前创建。
- 标题不是唯一键，相同标题允许独立记录。
- `LATEST_SCHEMA_VERSION` 由 2 更新为 3，`MIGRATIONS` 追加 0003。

### 1.2 Rust Core

新增 `crates/workmanager-core/src/work_items/`（model / repository / service / error），并从 crate 根导出。

- `WorkItemService::create(database, raw_title, project_id)`：
  - 标题 `trim` 后非空，否则 `work-item-title-empty`；
  - **在同一个 `IMMEDIATE` 写事务内**校验项目：不存在 → `project-not-found`，`is_archived = 1` → `project-archived`（DEC-033）；
  - Rust Core 生成 UUID v4；默认 `lifecycle_status = 'pending'`；时间戳 UTC RFC3339 毫秒；
  - 插入后在同一事务内按 ID 读回权威记录。
- `WorkItemService::list_pending(database)`：`LEFT JOIN projects`，只查询 `lifecycle_status = 'pending'`，按 `created_at DESC, id DESC` 稳定排序；返回项目名称与归档标记，未归属项 `project_id/project_name = None`。
- 所有 SQL 参数绑定；不记录工作标题/项目名称/SQL 参数；无 panic 代替业务错误。

### 1.3 Tauri IPC

新增 `src-tauri/src/commands/work_items.rs` 与 `app_state.rs` 的 `WorkItemContext`：

| 命令 | 请求 | 返回 |
|---|---|---|
| `create_work_item` | `{ input: { title, projectId } }`（`deny_unknown_fields`） | `WorkItemDto` |
| `list_pending_work_items` | 无参数 | `PendingWorkItemDto[]` |

- serde camelCase；`projectId` 显式 `null` 表示未归属（缺省也按 `null` 处理，前端显式传 `null`）；
- 所有数据库操作在 `spawn_blocking` 执行；错误统一 `{code, message}`（含 `work-item-title-empty` / `project-not-found` / `project-archived`）；
- 未新增任意 SQL/文件/命令 IPC。

### 1.4 前端 Contracts / Bridge / UI

- `src/lib/contracts/workItems.ts`：命令名、DTO、请求类型唯一契约来源。
- `src/lib/bridge/workItemValidation.ts`：纯运行时校验（可被 Node 直接加载）；拒绝缺字段/类型错误/非数组/非 `pending` 状态/项目字段语义不一致，抛 `ipc-contract-violation`。
- `src/lib/bridge/workItems.ts`：`invoke` 封装 + 失败载荷转 `WorkItemIpcError`。
- UI：
  - `TodayPage.svelte`：新增“今日工作 | 待安排”次级视图切换（**不新增一级侧边栏导航**，Sidebar/AppShell/Design Tokens 未修改）；
  - `PendingWorkItemsView.svelte`：页面容器，负责 loading / empty / error / list / 创建 / 权威刷新；
  - `PendingWorkItemList.svelte`：稳定工作事项 ID 作为 keyed each key；
  - `PendingWorkItemRow.svelte`：标题优先、项目辅助信息、未归属显示“未归属项目”、归档历史显示“项目已归档”；
  - `QuickCreateWorkItemDialog.svelte`：仅标题 + 可选未归档项目 + 取消/保存；提交中禁用；错误显示中文消息与稳定错误码；项目在提交前被归档时刷新选项并回退为未归属项目。

---

## 2. 需求 → 实现/证据映射

| 需求 | 实现 | 自动化证据 |
|---|---|---|
| 仅标题即可创建，默认待安排 | `WorkItemService::create` 默认 `pending` | `work_items.rs::creates_pending_work_item_with_title_only`；E2E `create.unassignedRowVisible` / `ipc.unassignedPersisted` |
| 标题 trim；空/纯空白拒绝 | `normalize_title` + DB CHECK 双保险 | `work_items.rs::normalizes_...` / `rejects_empty_and_blank_titles...`；E2E `ipc.emptyTitleRejected` |
| 相同标题不同 ID、不覆盖 | 无唯一约束；每次新 UUID | `work_items.rs::identical_titles_create_distinct_work_items`；E2E 创建同一标题两次（重复提交保护验证使用独立标题，重复对由其它用例覆盖） |
| ID 由 Rust Core 生成 | `Uuid::new_v4()` | `creates_pending_work_item_with_title_only` 校验 UUID；前端无 ID 生成代码 |
| 未归属项目允许创建，`project_id = NULL` | `Option<String>` + 可空外键 | `creates_unassigned_work_item_and_lists_it`；E2E `pending-unassigned.png` |
| 未归档项目可关联 | 事务内 `is_archived = 0` 校验 | `creates_work_item_linked_to_unarchived_project`；E2E `create.linkedRowShowsProjectName` |
| 不存在项目拒绝 | `project-not-found` | `rejects_unknown_project_id_without_writing_rows`；E2E `ipc.missingProjectRejected` |
| **已归档项目拒绝（DEC-033）** | 同一 IMMEDIATE 事务内校验 | `rejects_archived_project_id_without_writing_rows`；`create_waits_for_in_flight_archive_transaction_then_rejects`；`concurrent_archive_and_create_never_associate_archived_project`；E2E `race.projectArchivedErrorShown` / `ipc.archivedProjectRejectedEvenWithoutUiFilter` |
| 项目选择器只展示未归档项目 | 前端过滤 `isArchived === false` | E2E `create.selectorOnlyUnarchivedProjects` / `race.archivedProjectRemovedFromSelector` / `restart.selectorExcludesArchivedProjects` |
| 归档不删除/改写既有工作关联 | 归档只更新 projects；FK RESTRICT；查询 LEFT JOIN | `preserves_existing_link_after_project_archived`；`foreign_keys_restrict_project_deletion_and_invalid_links`；E2E `archivedProject.historyLinkStillListed` |
| 待安排只返回 pending | SQL `WHERE lifecycle_status = ?1` | `pending_query_excludes_other_lifecycle_statuses` |
| 排序稳定、可测试 | `created_at DESC, id DESC` | `pending_query_ordering_is_stable` |
| 关闭重开数据仍在 | SQLite 持久化 | `database_persists_work_items_across_reopen`；E2E 重启阶段 17/17 + 数据库探针 |
| camelCase / 未知字段拒绝 | serde 契约 | `commands/work_items.rs` 5 项契约测试；E2E `ipc.unknownFieldRejected` / `ipc.snakeCaseProjectIdRejected` |
| Bridge 运行时校验 | `workItemValidation.ts` | Node 10/10；E2E 传输层伪造非法 DTO → `ipc-contract-violation` |
| 重复提交保护 | 同步守卫 + 提交中禁用 | E2E `create.doubleSubmitCreatesSingleRecord`（同步双点击仅 1 条） |
| 创建成功后重新读取后端列表 | `loadPending(false)` 权威刷新 | E2E 每次创建后行数/数据库探针一致 |

---

## 3. 文件清单

### 新增

| 文件 | 说明 |
|---|---|
| `crates/workmanager-core/migrations/0003_work_items.sql` | schema 3 migration |
| `crates/workmanager-core/src/work_items/{mod,model,repository,service,error}.rs` | 工作事项领域模块 |
| `crates/workmanager-core/tests/work_items.rs` | 领域集成测试 16 项 |
| `crates/workmanager-core/tests/work_items_migration.rs` | migration 专项测试 4 项 |
| `src-tauri/src/commands/work_items.rs` | Tauri typed IPC + 5 项契约测试 |
| `src/lib/contracts/workItems.ts` | 前端 DTO 契约 |
| `src/lib/bridge/workItemValidation.ts` | 运行时校验（Node 可直载） |
| `src/lib/bridge/workItems.ts` | typed Bridge |
| `src/lib/features/work-items/PendingWorkItemsView.svelte` | 待安排页面容器 |
| `src/lib/features/work-items/PendingWorkItemList.svelte` | 列表（keyed each） |
| `src/lib/features/work-items/PendingWorkItemRow.svelte` | 单行展示 |
| `src/lib/features/work-items/QuickCreateWorkItemDialog.svelte` | 快速创建对话框 |
| `scripts/quality/work-item-bridge.test.mjs` | Bridge 契约 Node 测试 10 项 |
| `scripts/verify/inspect-t1-03-ui.mjs` | Release 主 UI/IPC E2E（70 项） |
| `scripts/verify/inspect-t1-03-min-window.mjs` | 最小窗口 + 关闭按钮（12 项） |
| `scripts/verify/inspect-t1-03-persistence.mjs` | 关闭重开持久化（17 项） |
| `scripts/verify/probe-t1-03-db.py` | 数据库只读探针 |
| `scripts/verify/verify-t1-03-ui.ps1` | E2E 编排（含重启阶段） |
| `docs/development/tasks/T1-03-Implementation-Design.md` | 编码前组件树/状态流/文件/IPC/测试计划 |
| `docs/testing/reports/T1-03-REPORT.md` | 本报告 |
| `docs/testing/reports/T1-03-assets/**` | 截图、JSON 证据、原始日志 |

### 修改

| 文件 | 说明 |
|---|---|
| `crates/workmanager-core/src/database/migrations.rs` | `LATEST_SCHEMA_VERSION = 3` + 注册 0003 |
| `crates/workmanager-core/src/lib.rs` | 导出工作事项领域类型 |
| `crates/workmanager-core/tests/migration_rollback.rs` | schema 3 事务回滚测试与表范围断言 |
| `crates/workmanager-core/tests/projects.rs` | T1-02 测试的 schema 期望 2 → 3（行为断言不变） |
| `src-tauri/src/app_state.rs` | `WorkItemContext` + 生命周期测试 1 项 |
| `src-tauri/src/commands/mod.rs` | 注册 work_items 模块 + `From<WorkItemError>` |
| `src-tauri/src/lib.rs` | 注册两个新命令 |
| `src/lib/features/today/TodayPage.svelte` | 次级视图入口（保留原“执行记录未接入”说明） |
| `package.json` | `npm run check` 接入 Bridge 契约测试 |
| `scripts/verify/VerifyCommon.ps1` | schema 期望 2 → 3 |
| `scripts/verify/inspect-release-ui.mjs` / `inspect-t1-02-ui.mjs` | 继承 E2E 的 schema/迁移断言 2 → 3 |
| `scripts/verify/verify-release-portable.ps1` | 注释中的 schema 期望 2 → 3 |
| `scripts/verify/README.md` | 新增 T1-03 验证工具说明 |

---

## 4. 测试执行结果

### 4.1 质量门禁（全部真实执行；原始命令日志不进入仓库，结果汇总与脱敏证据见 `T1-03-assets/`）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无输出（格式正确） |
| `cargo check --workspace --all-targets` | 0 | Finished dev profile |
| `cargo test --workspace` | 0 | **123 passed / 0 failed** |
| `npm run check` | 0 | svelte-check 0 errors/0 warnings；Bridge 10/10；Design Token 49/49 |
| `npm run build` | 0 | 167 modules；`dist/assets/index-*.js 111.02 kB` |
| `git diff --check` | 0 | 仅 Git 行尾转换 warning，无空白错误 |

### 4.2 Rust 测试分解（123 passed）

| 测试二进制 | 数量 | 说明 |
|---|---|---|
| `workmanager` lib 单测 | 10 | Tauri 适配层（含 T1-03 命令契约 5 项、WorkItemContext 1 项） |
| `workmanager-core` lib 单测 | 32 | 含工作事项 model 5 项 / error 2 项 |
| `work_items.rs` | 16 | 创建/查询/DEC-033/归档保留/排序/外键/并发边界 |
| `work_items_migration.rs` | 4 | 2→3 升级保留数据、重复打开、失败回滚、表约束 |
| 既有 T1-01/T1-02 测试 | 61 | 含 `migration_rollback` / `projects` 的 schema 3 期望更新 |
| 合计 | **123** | 基线 90 + T1-03 新增 33；0 failed |

### 4.3 T1-03 Windows Release E2E（独立 UAT 目录）

编排命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1 `
    -OutputDir <UAT_ROOT>\t1-03-ui-run2
```

Release 产物：`target\release\workmanager.exe`，10,351,616 字节，
SHA-256 `22af942fe2817388596118fc7cb66f34fce4e8c5e2367fe1a2942dc13dd66b23`。

| 阶段 | 结果 | 证据 |
|---|---|---|
| 主 UI/IPC 检查 | **70/70 PASS**，exit 0 | `evidence/t1-03-ui-evidence.json` |
| 最小窗口 860×640 + 真实关闭 | **12/12 PASS**，第一次关闭进程退出码 **0** | `evidence/t1-03-min-window-evidence.json`、`evidence/t1-03-ui-orchestration.json` |
| 关闭 → 重启持久化 | **17/17 PASS**，第二次关闭进程退出码 **0** | `evidence/t1-03-persistence-evidence.json` |
| 数据库只读探针（关闭后/重启后） | **25/25 PASS** | `evidence/t1-03-db-after-main.json`、`evidence/t1-03-db-after-restart.json` |
| 汇总 | `T1_03_RELEASE_UI_E2E=PASS` | `evidence/t1-03-ui-orchestration.json` |

数据库探针关键事实（重启后）：

- `user_version = 3`、`integrity_check = ok`、`journal_mode = wal`、`foreign_key_violations = 0`；
- `schema_migrations` 记录版本 1、2、3；
- `work_items_total = 5`、`work_items_pending = 5`、`work_items_other_status = 0`；
- `work_items_null_project = 4`、`work_items_linked_archived = 1`、`work_items_linked_active = 0`；
- `projects_total = 2`、`projects_archived = 2`（归档只改标记，记录保留）；
- 待安排标题与 UI 一致（含超长标题、重启后新建工作）。

主检查覆盖（节选）：应用壳与六个一级导航不变、今日工作 → 待安排次级视图、真实异步 loading、空状态、真实 UI 创建未归属/关联未归档项目工作、重复提交保护、项目归档竞态错误（`project-archived` + 刷新选项）、绕过 UI 直接 IPC 的后端拒绝、传输层故障注入（加载失败/重试、Bridge 契约违规）、长标题布局、CSP 0 违规、页面未捕获异常 0、正常窗口无横向溢出。

### 4.4 继承 Release 回归（受 schema v3 影响的回归项）

| 脚本 | 退出码 | 结果 | 证据 |
|---|---|---|---|
| `verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1 INFO=15，OVERALL=PASS | `evidence/release-regression-portable-summary.json` |
| `verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9，OVERALL=PASS | `evidence/release-regression-faults-summary.json` |
| `verify-t1-02-ui.ps1` | 0 | 主检查 73/73；最小窗口 12/12；关闭退出码 0；CSP 0；页面异常 0 | `evidence/release-regression-t1-02-ui-orchestration.json` |

说明：上述脚本仅更新 schema/迁移断言（2 → 3），未修改产品业务逻辑；T1-01 便携路径/数据库初始化行为、T1-02 项目管理行为均在本次回归中保持通过。

### 4.5 前端 / Bridge 契约测试

- `scripts/quality/work-item-bridge.test.mjs`：10/10，覆盖合法 DTO/列表、空列表、非数组、缺字段、类型错误、非 pending 状态、项目字段语义不一致、创建 DTO 非法值；拒绝时错误码为 `ipc-contract-violation`。
- 已接入 `npm run check`，不新增前端测试框架依赖。

---

## 5. Windows Release 实测步骤与结果（对应任务要求）

在独立 UAT 便携目录 `D:\WorkManager-test-data\t1-03-ui-run2\app`（虚构数据）实际执行：

| 步骤 | 结果 | 证据 |
|---|---|---|
| 1. Release 程序启动 | PASS（主窗口 1100×780，应用壳渲染） | `today-entry.png`、主检查 70/70 |
| 2. 创建未归属工作 | PASS（仅标题，立即进入待安排，显示“未归属项目”） | `pending-unassigned.png`、`t1-03-db-after-main.json` |
| 3. 创建关联有效项目的工作 | PASS（选择器展示未归档项目，项目名称正确） | `pending-linked-project.png` |
| 4. 归档一个项目 | PASS（通过 IPC 归档；项目记录保留） | 主检查 `setup.projectArchived` |
| 5. 归档项目不再出现在新建选择器 | PASS（选项仅剩未归属项目） | `race.archivedProjectRemovedFromSelector` |
| 6. 直接向 IPC 传归档项目 ID | PASS：返回 `project-archived`（中文消息），未创建记录 | 主检查 `ipc.archivedProjectRejectedEvenWithoutUiFilter` |
| 7. 该项目之前关联的工作仍存在 | PASS（待安排列表保留，显示项目名称 + “项目已归档”） | `pending-archived-project.png` |
| 8. 关闭程序（真实红色关闭按钮） | PASS（进程退出码 0） | 编排 JSON `firstCloseExitCode=0` |
| 9. 重新启动同一目录 | PASS（第二次启动，主窗口正常） | `evidence/t1-03-ui-orchestration.json` |
| 10. 验证工作事项持久化 | PASS（4 条既有工作仍在；重启后新建 1 条；数据库 / UI 一致） | `pending-after-restart.png`、`pending-after-restart-new-item.png`、`t1-03-db-after-restart.json` |

固定窗口（默认 1100×780）与最小支持窗口（860×640）截图见 `screenshots/`；最小窗口下无横向溢出、无内容遮挡、按钮可点击、长标题省略且保留完整 `title` 属性；CSP 0 违规、页面未捕获异常 0。

---

## 6. 截图索引（`docs/testing/reports/T1-03-assets/screenshots/`）

| 截图 | 内容 |
|---|---|
| `today-entry.png` | 今日工作页面 + “今日工作 / 待安排”次级视图入口（一级导航仍为 6 项） |
| `pending-loading.png` | 待安排真实异步 loading 状态 |
| `pending-empty.png` | 待安排空状态 + 创建入口 |
| `create-dialog.png` | 快速创建对话框（仅标题 + 可选项目） |
| `pending-unassigned.png` | 创建未归属工作后的待安排列表 |
| `create-dialog-projects.png` | 项目选择器只展示未归档项目 |
| `pending-linked-project.png` | 关联未归档项目的工作 |
| `create-error-project-archived.png` | 项目在提交前被归档：`project-archived` 错误 + 选项刷新 |
| `pending-archived-project.png` | 历史关联保留并显示“项目已归档” |
| `pending-load-error.png` | 列表加载失败 + 重新加载 |
| `pending-contract-violation.png` | Bridge 运行时契约违规被 UI 捕获（`ipc-contract-violation`） |
| `pending-long-title.png` | 超长标题单行省略，无横向溢出 |
| `pending-min.png` | 最小窗口 860×640 待安排列表 |
| `create-dialog-min.png` | 最小窗口快速创建对话框完整可见 |
| `pending-after-restart.png` | 关闭重开后的待安排列表（持久化） |
| `create-dialog-after-restart.png` | 重启后选择器仍只含未归档项目 |
| `pending-after-restart-new-item.png` | 重启后仍可创建新工作并立即出现 |

---

## 7. 证据文件索引（`docs/testing/reports/T1-03-assets/`）

```text
evidence/
  t1-03-ui-evidence.json                      # 主 UI/IPC 70 项断言 + 截图/异常/CSP
  t1-03-min-window-evidence.json              # 最小窗口 12 项断言 + 关闭点击
  t1-03-persistence-evidence.json             # 重启持久化 17 项断言
  t1-03-ui-orchestration.json                 # 编排汇总（退出码、计数、EXE SHA、截图清单）
  t1-03-prerequisite.json                     # 重启阶段前的真实 IPC 数据快照（虚构）
  t1-03-db-after-main.json                    # 关闭后数据库只读探针
  t1-03-db-after-restart.json                 # 重启后数据库只读探针
  release-regression-portable-summary.json    # 继承便携验证 106 项
  release-regression-faults-summary.json      # 继承异常注入 73 项
  release-regression-t1-02-ui-orchestration.json
test-counts.txt                               # 测试数量与基线差分速查
SANITIZATION.md                               # 证据脱敏策略与扫描结果
```

说明：原始命令日志（包含计算机名/账户名/本地绝对路径）已按 P2-01 修复要求从仓库删除；
保留的 JSON/文本证据已脱敏，未改动测试结果、断言数量、错误码与哈希。脱敏策略见
`T1-03-assets/SANITIZATION.md`。

---

## 8. 明确未实现 / 未修改

- 未实现 T1-04 多项目独立副本创建；T1-05 生命周期状态流转与历史；每日计划/未来 7 天；重要/紧急评分、全局优先级、手动置顶与排序；当前工作指针、切换、暂时跳过；每日复盘、提醒、工作日志、附件、报表、清理、备份恢复。
- 未新增一级侧边栏导航；未修改 AppShell / Sidebar / 全局 Design Tokens。
- 未修改 `list_projects` 契约（仍返回全部项目，含归档项目）；归档项目过滤仅用于选择器展示，安全边界在 Rust Core 事务内。
- 未修改 T1-01 便携路径/数据库初始化逻辑；继承验证脚本仅更新 schema 断言。
- 未新增运行时第三方依赖；未新增前端测试框架依赖（使用 Node 内置 `node:test`）。

---

## 9. 遗留风险与已知限制

1. **尚未经过独立审计与用户验收**：本报告只是开发自测证据，不等于审计/验收结论。
2. **普通 SQLite 未加密**（DEC-028 已接受）：拥有文件访问权限的人可读取数据库内容；本任务未改变该事实。
3. **TOCTOU 残余风险**：按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复；不得宣称任何情况下不会写入 C 盘。
4. **待安排排序固定**为 `created_at DESC, id DESC`；不提供手动排序/优先级（后续任务）。
5. **同毫秒创建**时排序由稳定 ID 次级键决定，不保证与用户点击顺序严格一致（不影响正确性）。
6. **快速创建无前端 trim 提交**：由 Rust Core 规范化；前端只校验非空，最终权威规则在 Core。
7. **继承验证脚本的 schema 版本断言**已改为 3；历史 T1-01/T1-02 报告中的 106/73/73/12 数字为当时历史结果，本报告记录的是 T1-03 头部代码下的重新执行结果。
8. 归档竞态 E2E 通过 CDP 直接 IPC 归档实现；真实用户操作路径（设置页归档）与 T1-02 回归一致，未被本任务修改。
9. 列表加载失败/契约违规状态通过 CDP 传输层故障注入验证（不修改产品代码）；该注入仅存在于测试脚本。

---

## 10. Git / PR 交付信息

- 分支：`task/T1-03-quick-create-pending`（已推送，tracking `origin/task/T1-03-quick-create-pending`）
- 基线：`018e851e8daf5835391a7b61caf881bc57c2ad42`
- 实现提交：`be8d9c2e9c78710690de189936d6ee65f48ed8df`
- 预编码设计提交：`9c091567351c4290b9f6ec1cea59f1e0d5f7bf6b`
- 本报告与证据提交：见分支后续 docs 提交（`docs/testing/reports/T1-03-assets/` 与本文档）
- PR：[#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) → `main`，保持 Open
- main：未修改；PR 未合并

---

## 11. 当前状态与停止条件

**状态：待独立审计。**

- 已完成：真实代码实现、数据库 migration 与升级验证、Rust/IPC/前端测试、Release 构建、独立 UAT 目录 Release 实测（含关闭重开持久化）、截图与机器可读证据、文档与 GitHub 分支/PR。
- 未完成且不得由开发代理自行宣布：独立审计通过、用户验收完成、PR 合并。
- 按任务要求，开发代理在 PR 创建后停止，等待独立审计；不开始 T1-04/T1-05，不修改 main。
