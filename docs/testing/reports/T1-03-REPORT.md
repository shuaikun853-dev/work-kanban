# T1-03 工作事项快速创建和待安排区域 — 测试与交付报告

**任务 ID：** T1-03
**任务名称：** 工作事项快速创建和待安排区域
**当前状态：** **第三轮 P2-01/P3-02 定向修复完成，等待第三轮独立审计；P2-01 服务端清理未完成、保持未关闭**（PR #8 保持 Open，未合并；main 未修改）
**开发分支：** `task/T1-03-quick-create-pending`
**目标分支：** `main`
**开发基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`（T1-02 已验收合并后的 main）
**第一轮审计基准 HEAD：** `2342828852abee43ab56610e7d1fa91a02310bfe`
**第二轮审计基准 HEAD：** `bad0688ee9de5e07f769d64d7fc44e3f182a960d`
**Pull Request：** [PR #8](https://github.com/shuaikun853-dev/work-kanban/pull/8)（指向 main，保持 Open，等待第三轮独立审计）
**报告生成时间：** 2026-11-19（第二轮）；2026-11-20 第三轮更新（Asia/Shanghai）
**测试环境：** Windows 10 家庭中文版 10.0.19045；Windows PowerShell 5.1.19041.6456；rustc 1.100.0 / cargo 1.100.0；Node.js v22.20.0 / npm 10.9.3；Python 3.14.5
**测试数据：** 全部为虚构内容；UAT 使用专用测试根目录下的一次性新目录（`<uat-root>\t1-03-ui-r3-20261120-075440`），未触碰正式运行目录 `D:\WorkManager`，未使用真实用户工作数据

---

## 0. 第三轮修复摘要（2026-11-20，本轮变更）

第三轮只处理第二轮独立审计后仍保持未关闭的两项：P2-01（原始日志/机器信息/GitHub 历史对象清理）与 P3-02（Windows UAT 路径安全，Junction/Symbolic Link 绕过）。不修改已通过第二轮审计的 P2-02、P3-01 实现，不重构业务代码，不修改 PRD/TECHNICAL_DESIGN/DECISIONS 业务决策，不新增业务功能。

| 问题 | 本轮修复 | 关键证据 |
|---|---|---|
| **P2-01** 历史敏感对象清理 | 重新扫描分支增量历史（18 提交 / 5,773 次文件树扫描）、当前证据目录（33 文件，含 19 PNG）、18 个远程 refs（tags 0 个）、PR #8 描述/评论；按第三轮实测刷新 T1-03 证据；整理 GitHub Support 清理材料；**未再次重写历史、未强制推送** | 分支增量敏感值命中 **0**；当前证据敏感值命中 **0**；PR 文本敏感类别/旧日志文件名/35 条采样行命中 **0**；但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 及其 9 个原始日志**仍可经 GitHub API 读取（HTTP 200）** → **P2-01 未关闭**，等待 GitHub Support |
| **P3-02** Windows 路径安全（Junction/Symbolic Link） | `T1-03UatPath.ps1` 改为 Windows 原生句柄检查（`CreateFileW` + `GetFileInformationByHandleEx` + `GetFinalPathNameByHandleW`）：拒绝未批准 reparse point、校验真实最终路径与卷身份、UNC/设备/相对路径 fail closed；`verify-t1-03-ui.ps1` 在创建目录、复制 EXE、启动应用前重复校验 | 路径安全专项 **60 项（原有 23 + 新增 37），0 FAIL**；7 类真实 Junction 场景全部拒绝；1 项 Symbolic Link 场景因当前进程无创建权限记录 **SKIP（不计 PASS）**；失败场景无副作用/canary 不变；Release E2E 退出码 0 |

**第三轮关键结论：** P3-02 所有可执行专项测试通过（Symbolic Link 因权限限制 SKIP 并如实记录）；原有 T1-03 业务测试与继承 Release 回归无回归；P2-01 当前分支与 PR 文本脱敏复核通过，但**服务端历史对象清理未完成**，P2-01 不得关闭。TOCTOU 剩余风险未消除并如实记录。

### 0.1 第二轮修复摘要（历史，2026-11-19）

第一轮独立审计结论：未通过。本轮只修复审计指出的四项问题，不扩大开发范围、不新增业务功能、不修改 PRD/TECHNICAL_DESIGN/DECISIONS 中的业务决策、不修改 DEC-028/DEC-029/DEC-033、不新增依赖。

| 问题 | 修复内容 | 关键证据 |
|---|---|---|
| **P2-01** 原始日志与机器信息提交 | 删除 `T1-03-assets/logs/` 下 9 个原始命令日志；对 11 个 JSON 证据脱敏（计算机名/账户名/用户目录/仓库与 UAT 绝对路径）；新增 `SANITIZATION.md`；重写本任务分支历史并 `--force-with-lease` 推送 | `T1-03-assets/SANITIZATION.md`；脱敏扫描 0 命中；分支新增历史深度扫描 0 命中；证据结构一致性 11/11 |
| **P2-02** Rust / TypeScript DTO 契约不一致 | `WorkItemDto` 统一为 Rust 实际序列化的 10 字段（含可空 `importance`/`urgency`/`dueDate`/`description`）；Bridge 改为严格契约：缺字段、类型错误、非法状态、未知字段全部拒绝；Rust 增加完整字段/可空值/字段名集合序列化测试；Node 契约测试扩展到 17 项 | Rust 124/124；Bridge 17/17；E2E 真实创建响应经严格 Bridge 校验通过（全部创建流程） |
| **P3-01** 创建成功提示时机不准确 | `loadPending()` 返回成功/失败；创建成功后先显示“正在刷新”，刷新成功后才显示“列表已更新/已从数据库更新”；刷新失败显示独立 warning 并允许“重新加载”，不重复创建 | E2E：延迟刷新时中间态提示、成功态提示、`pending-create-refresh-failure.png` / `pending-create-refresh-recovered.png`；同标题仅 1 条 |
| **P3-02** UAT 脚本缺少数据库复用保护 | 新增 `T1-03UatPath.ps1`：`GetFullPath` 规范化后限制在 `D:\WorkManager-test-data\`，拒绝正式目录、根目录外、`..` 越界、已含数据库目录、非空未知目录；不删除/不覆盖；新增 23 项路径安全专项测试 | `test-t1-03-uat-path.ps1` 23/23 PASS；`t1-03-uat-path-evidence.json` |

### 0.2 第二轮历史清理记录（P2-01，历史）

- **重写前 HEAD（第一轮审计基准）：** `2342828852abee43ab56610e7d1fa91a02310bfe`
- **重写后 docs/evidence 提交：** `b6cf344abc1693e7031427f8963c27474c0b59f9`
- **重写原因：** 原 docs/evidence 提交包含原始命令日志与机器标识；只重写本任务分支的 docs/evidence 提交，未重写 main。
- **推送方式：** `git push --force-with-lease=task/T1-03-quick-create-pending:2342828852abee43ab56610e7d1fa91a02310bfe origin task/T1-03-quick-create-pending`
- **本地恢复引用：** 分支 `backup/t1-03-r1-audit-baseline`（仅本地，未推送）；bundle 备份在仓库外 `test-artifacts/r1-backup/t1-03-r1-audit-baseline-2342828.bundle`（gitignored）。
- **清理验证：** 本分支新增/修改文件的历史深度扫描（15 个提交、84 个文件状态）机器标识命中 0；`T1-03-assets/logs/` 路径在分支 `018e851..HEAD` 历史中不可达。
- **残留风险：** GitHub 服务端对不可达对象可能保留有限缓存；不能宣称服务端所有临时副本立即物理删除。main 基线既有的 T1-01/T1-02 历史证据存在同类机器信息（非本 PR 新增，按本轮“不扩大修改范围”未修改），作为残留风险记录。

---

## 1. 实际实现范围（T1-03 主体）

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
- **P2-02 契约：** `WorkItem` serde camelCase 恰好输出 10 字段；`projectId`/`importance`/`urgency`/`dueDate`/`description` 未设置时输出 JSON `null`（不省略字段）；Rust 测试锁定字段名集合与值类型。

### 1.3 Tauri IPC

新增 `src-tauri/src/commands/work_items.rs` 与 `app_state.rs` 的 `WorkItemContext`：

| 命令 | 请求 | 返回 |
|---|---|---|
| `create_work_item` | `{ input: { title, projectId } }`（`deny_unknown_fields`） | `WorkItemDto`（10 字段） |
| `list_pending_work_items` | 无参数 | `PendingWorkItemDto[]`（每项 8 字段） |

- serde camelCase；`projectId` 显式 `null` 表示未归属（缺省也按 `null` 处理，前端显式传 `null`）；
- 所有数据库操作在 `spawn_blocking` 执行；错误统一 `{code, message}`（含 `work-item-title-empty` / `project-not-found` / `project-archived`）；
- 未新增任意 SQL/文件/命令 IPC。

### 1.4 前端 Contracts / Bridge / UI

- `src/lib/contracts/workItems.ts`：命令名、DTO、请求类型唯一契约来源；`WorkItemDto` 已与 Rust 统一为 10 字段。
- `src/lib/bridge/workItemValidation.ts`：纯运行时严格校验（可被 Node 直接加载）：
  - 必填字段缺失、类型错误、非法 `lifecycleStatus`、**未定义字段**一律拒绝（`ipc-contract-violation`）；
  - `importance`/`urgency` 为 `null` 或 1–5 整数；`dueDate` 为 `null` 或非空字符串；`description` 为 `null` 或字符串；
  - 待安排列表的项目字段语义一致性校验保留。
- `src/lib/bridge/workItems.ts`：`invoke` 封装 + 失败载荷转 `WorkItemIpcError`。
- UI：
  - `TodayPage.svelte`：新增“今日工作 | 待安排”次级视图切换（**不新增一级侧边栏导航**，Sidebar/AppShell/Design Tokens 未修改）；
  - `PendingWorkItemsView.svelte`：页面容器，负责 loading / empty / error / list / 创建 / 权威刷新；**P3-01：创建成功、列表刷新成功、刷新失败三态分开**；
  - `PendingWorkItemList.svelte`：稳定工作事项 ID 作为 keyed each key；
  - `PendingWorkItemRow.svelte`：标题优先、项目辅助信息、未归属显示“未归属项目”、归档历史显示“项目已归档”；
  - `QuickCreateWorkItemDialog.svelte`：仅标题 + 可选未归档项目 + 取消/保存；提交中禁用；错误显示中文消息与稳定错误码；项目在提交前被归档时刷新选项并回退为未归属项目。

---

## 2. 需求 → 实现/证据映射

| 需求 | 实现 | 自动化证据 |
|---|---|---|
| 仅标题即可创建，默认待安排 | `WorkItemService::create` 默认 `pending` | `work_items.rs::creates_pending_work_item_with_title_only`；E2E `create.unassignedRowVisible` / `ipc.unassignedPersisted` |
| 标题 trim；空/纯空白拒绝 | `normalize_title` + DB CHECK 双保险 | `work_items.rs` 标题测试；E2E `ipc.emptyTitleRejected` |
| 相同标题不同 ID、不覆盖 | 无唯一约束；每次新 UUID | `identical_titles_create_distinct_work_items`；E2E 重复提交保护仅 1 条 |
| ID 由 Rust Core 生成 | `Uuid::new_v4()` | `creates_pending_work_item_with_title_only` 校验 UUID；前端无 ID 生成代码 |
| 未归属项目允许创建 | `Option<String>` + 可空外键 | `creates_unassigned_work_item_and_lists_it`；E2E `pending-unassigned.png` |
| 未归档项目可关联 | 事务内 `is_archived = 0` 校验 | `creates_work_item_linked_to_unarchived_project`；E2E `create.linkedRowShowsProjectName` |
| 不存在项目拒绝 | `project-not-found` | `rejects_unknown_project_id_without_writing_rows`；E2E `ipc.missingProjectRejected` |
| **已归档项目拒绝（DEC-033）** | 同一 IMMEDIATE 事务内校验 | 领域测试 + 并发测试；E2E `race.projectArchivedErrorShown` / `ipc.archivedProjectRejectedEvenWithoutUiFilter` |
| 项目选择器只展示未归档项目 | 前端过滤 `isArchived === false` | E2E `create.selectorOnlyUnarchivedProjects` 等 |
| 归档不删除/改写既有工作关联 | 归档只更新 projects；FK RESTRICT；LEFT JOIN | `preserves_existing_link_after_project_archived`；E2E `archivedProject.historyLinkStillListed` |
| 待安排只返回 pending | SQL `WHERE lifecycle_status = ?1` | `pending_query_excludes_other_lifecycle_statuses` |
| 排序稳定、可测试 | `created_at DESC, id DESC` | `pending_query_ordering_is_stable` |
| 关闭重开数据仍在 | SQLite 持久化 | `database_persists_work_items_across_reopen`；E2E 重启阶段 17/17 + DB 探针 |
| camelCase / 未知字段拒绝 | 请求 serde；响应严格契约 | Rust 命令契约测试 6 项；E2E `ipc.unknownFieldRejected` / `ipc.snakeCaseProjectIdRejected` |
| **Rust/TS 完整 DTO 一致（P2-02）** | 10 字段 `WorkItemDto` + 严格校验 | Rust 2 项完整序列化测试；Bridge 17/17（含字段缺失/类型/NULL/未知字段）；真实创建响应经 Bridge 校验 |
| Bridge 运行时校验 | `workItemValidation.ts` | Node 17/17；E2E 传输层伪造非法 DTO → `ipc-contract-violation` |
| 重复提交保护 | 同步守卫 + 提交中禁用 | E2E `create.doubleSubmitCreatesSingleRecord` |
| 创建成功后重新读取后端列表 | `loadPending` 权威刷新 | E2E 每次创建后行数/数据库探针一致 |
| **创建/刷新提示时机（P3-01）** | 三态分离；刷新成功后才提示已更新 | E2E 延迟刷新中间态/成功态、刷新失败 warning、重试恢复、无重复创建 |
| **UAT 路径安全（P3-02）** | Windows 原生句柄：拒绝未批准 Junction/Symbolic Link/其他 reparse point；真实最终路径 + 卷身份校验；专用根目录/正式目录/旧库/非空目录限制；无法确认时 fail closed | 路径安全专项 **60 项 0 FAIL（原有 23 + 新增 37；1 项 Symbolic Link 因权限限制 SKIP、不计 PASS）**；7 类真实 Junction 场景全部拒绝；失败场景无副作用；编排脚本对不安全目录退出码 2 |

---

## 3. 文件清单（本轮与 T1-03 相关）

### 第三轮修复新增/修改（相对第二轮审计基准）

| 文件 | 变更 |
|---|---|
| `scripts/verify/T1-03UatPath.ps1` | 重写为 Windows 原生句柄路径校验（P3-02）：`CreateFileW` + `GetFileInformationByHandleEx`（重解析属性/文件 ID/卷序列号）+ `GetFinalPathNameByHandleW`；测试根目录及全部已存在组件重解析点拒绝、真实最终路径/卷身份校验、UNC/设备/相对/非法路径 fail closed；保留原有字符串与内容复用保护 |
| `scripts/verify/test-t1-03-uat-path.ps1` | 保留原有 23 项并新增 37 项（合计 60）：真实 Junction 7 类场景、UNC/设备/非法字符/尾部点空白/保留设备名/缺失测试根目录、无副作用与清理语义、证据自检；1 项 Symbolic Link 因权限限制记 SKIP（不计 PASS） |
| `scripts/verify/verify-t1-03-ui.ps1` | 在创建 UAT 目录后、创建 app 目录后、复制 EXE 前后、每次启动应用前重复执行原生路径校验；更新安全约束注释与 TOCTOU 剩余风险说明（P3-02） |
| `docs/testing/reports/T1-03-assets/evidence/*.json` | 按第三轮实测刷新主 UI/最小窗口/持久化/编排/前置快照/数据库探针证据；路径安全证据更新为 60 项；新增 `round3-verification-summary.json` 机器可读第三轮汇总 |
| `docs/testing/reports/T1-03-assets/SANITIZATION.md` | 重写为第三轮复核：扫描范围/结果、旧提交服务端暴露未解决、GitHub Support 清理材料、占位符与遗留风险（P2-01） |
| `docs/testing/reports/T1-03-assets/README.md`、`test-counts.txt` | 第三轮证据索引、复现命令、测试数量与环境（P2-01/P3-02） |
| `docs/testing/reports/T1-03-REPORT.md`、`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/tasks/T1-03-Quick-Work-Item-Creation.md` | 第三轮修复状态、命令、结果、证据与遗留风险记录 |

第三轮**未修改产品代码**（Rust/前端/迁移/业务 UI 均未改动），Release EXE 与第二轮一致。

### 第二轮修复新增/修改（相对第一轮审计基准）

| 文件 | 变更 |
|---|---|
| `docs/testing/reports/T1-03-assets/**` | 删除原始日志；JSON 脱敏；截图/证据更新为第二轮 Release 实测；新增 `SANITIZATION.md`、`t1-03-uat-path-evidence.json`、2 张刷新失败/恢复截图 |
| `crates/workmanager-core/src/work_items/model.rs` | 增加 10 字段序列化契约说明（P2-02） |
| `src-tauri/src/commands/work_items.rs` | 新增完整字段/可空值序列化测试（P2-02） |
| `src/lib/contracts/workItems.ts` | `WorkItemDto` 10 字段 + NULL 语义 + 严格契约说明（P2-02） |
| `src/lib/bridge/workItemValidation.ts` | 严格对象校验（缺字段/未知字段/可空数字/可空字符串）（P2-02） |
| `scripts/quality/work-item-bridge.test.mjs` | 17 项严格契约测试（P2-02） |
| `src/lib/features/work-items/PendingWorkItemsView.svelte` | 创建成功/刷新成功/刷新失败三态与重试（P3-01） |
| `scripts/verify/inspect-t1-03-ui.mjs` | 新增延迟刷新中间态、刷新失败、重试、无重复创建、严格 DTO 覆盖；计数 84 |
| `scripts/verify/inspect-t1-03-min-window.mjs`、`inspect-t1-03-persistence.mjs` | 适配第二轮数据量（5/6 条） |
| `scripts/verify/T1-03UatPath.ps1` | 新增 UAT 输出目录安全校验（P3-02） |
| `scripts/verify/test-t1-03-uat-path.ps1` | 新增 23 项 UAT 路径安全专项测试（P3-02） |
| `scripts/verify/verify-t1-03-ui.ps1` | 接入路径安全校验；数据库探针期望更新（P3-02 + 数据量） |
| `docs/testing/reports/T1-03-REPORT.md`、`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/tasks/T1-03-Quick-Work-Item-Creation.md`、`scripts/verify/README.md` | 第二轮修复状态、命令、结果与证据记录 |

T1-03 主体文件（migration、Rust Core、IPC、Bridge、UI、E2E 脚本等）见第一轮实现提交 `be8d9c2`。

---

## 4. 测试执行结果（第三轮 2026-11-20，全部真实执行）

### 4.0 第三轮质量门禁与关键结果

| 命令/测试 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | 通过 |
| `cargo test --workspace` | 0 | **124 passed / 0 failed**（18 个测试二进制） |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 0 违规、49/49 |
| `npm run build` | 0 | 构建成功（167 modules） |
| `git diff --check` | 0 | 无空白错误 |
| `scripts/verify/test-t1-03-uat-path.ps1` | 0 | **60 项：FAILED=0，SKIPPED=1（Symbolic Link 权限限制，明确记录、不计 PASS）** |
| `scripts/verify/verify-t1-03-ui.ps1` | 0 | 主 84/84、最小窗口 12/12、持久化 17/17、数据库探针 25/25；两次真实关闭退出码 0 |
| `scripts/verify/verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1（既有 WARN）INFO=15 |
| `scripts/verify/verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 |
| `scripts/verify/verify-t1-02-ui.ps1` | 0 | 主 73/73；最小窗口 12/12；关闭退出码 0 |

第三轮 Release E2E 使用新 UAT 目录 `<uat-root>\t1-03-ui-r3-20261120-081100`；Release EXE 与第二轮一致：
**10,352,128 字节**，SHA-256 **`3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`**（本轮只改验证脚本/文档，产品代码未变）。
开发代理内部对抗性复核（非独立审计）：99 项模块级路径注入 + 17 项编排脚本拒绝集成用例 + 6 项补充检查，0 绕过；复核发现的 Low/Info 形状缺口（尾部点/空白组件、COM0/CONIN$/CONOUT$ 保留名、测试根目录信任锚优先校验）已在最终实现与专项测试中补强；TOCTOU 窗口被实际演示为未消除并记录为剩余风险。机器可读汇总见 `T1-03-assets/evidence/round3-verification-summary.json`。以下 4.1–4.6 为第二轮执行细节（历史记录；产品代码未变，第三轮已重新执行并通过）。

### 4.1 第二轮质量门禁（历史）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | Finished dev profile |
| `cargo test --workspace` | 0 | **124 passed / 0 failed** |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 49/49（22 文件 0 违规） |
| `npm run build` | 0 | 构建成功 |
| `git diff --check` | 0 | 无空白错误（仅 Git 行尾转换 warnings 时也退出 0） |
| `node --test scripts/quality/work-item-bridge.test.mjs` | 0 | **17 passed / 0 failed** |
| `powershell -File scripts/verify/test-t1-03-uat-path.ps1` | 0 | **23/23 PASS** |

### 4.2 Rust 测试分解（124 passed）

| 测试二进制 | 数量 | 说明 |
|---|---|---|
| `workmanager` lib 单测 | 11 | Tauri 适配层（含 T1-03 命令契约 6 项、WorkItemContext 1 项、P2-02 完整序列化 2 项中的 2 项） |
| `workmanager-core` lib 单测 | 32 | 含工作事项 model 5 项 / error 2 项 |
| `work_items.rs` | 16 | 创建/查询/DEC-033/归档保留/排序/外键/并发边界 |
| `work_items_migration.rs` | 4 | 2→3 升级保留数据、重复打开、失败回滚、表约束 |
| 既有 T1-01/T1-02 测试 | 61 | 含 schema 3 期望更新 |
| 合计 | **124** | 基线 90 + T1-03 新增 34；0 failed |

### 4.3 T1-03 Windows Release E2E（第二轮，独立 UAT 目录）

编排命令（P3-02 生效后必须使用专用测试根目录下的新目录）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1 `
    -OutputDir <UAT_ROOT>\t1-03-ui-run4 -Port 9365
```

Release 产物：`target\release\workmanager.exe`，**10,352,128 字节**，
SHA-256 **`3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`**。

| 阶段 | 结果 | 证据 |
|---|---|---|
| 主 UI/IPC 检查 | **84/84 PASS**，exit 0 | `evidence/t1-03-ui-evidence.json` |
| 最小窗口 860×640 + 真实关闭 | **12/12 PASS**，第一次关闭退出码 **0** | `evidence/t1-03-min-window-evidence.json` |
| 关闭 → 重启持久化 | **17/17 PASS**，第二次关闭退出码 **0** | `evidence/t1-03-persistence-evidence.json` |
| 数据库只读探针（关闭后/重启后） | **25/25 PASS** | `evidence/t1-03-db-after-main.json`、`evidence/t1-03-db-after-restart.json` |
| UAT 路径安全专项 | **23/23 PASS** | `evidence/t1-03-uat-path-evidence.json` |
| 汇总 | `T1_03_RELEASE_UI_E2E=PASS` | `evidence/t1-03-ui-orchestration.json` |

数据库探针关键事实（第二轮）：

- 第一次关闭后：`user_version=3`、`integrity_check=ok`、`work_items=5 / pending=5 / 其他状态=0`、未归属 4、关联归档项目 1、外键违规 0；项目 2 个且均归档；
- 重启并再次创建后关闭：`work_items=6 / pending=6 / 其他状态=0`、未归属 5、关联归档项目 1、外键违规 0。

主检查覆盖（第二轮新增/保留）：应用壳与六个一级导航不变、今日工作 → 待安排次级视图、真实异步 loading、空状态、真实 UI 创建未归属/关联未归档项目工作、**创建成功→正在刷新→刷新成功提示时机**、**创建成功但列表刷新失败 warning + 重试 + 不重复创建**、重复提交保护、项目归档竞态错误、绕过 UI 直接 IPC 的后端拒绝、**严格 10 字段 DTO 运行时校验（真实创建响应）**、传输层故障注入（加载失败/重试、Bridge 契约违规）、长标题布局、CSP 0 违规、页面未捕获异常 0、正常窗口无横向溢出。

### 4.4 继承 Release 回归（第二轮，新 EXE）

| 脚本 | 退出码 | 结果 |
|---|---|---|
| `verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 **WARN=1（保留既有 WARN，未改动测试逻辑）** INFO=15，OVERALL=PASS |
| `verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9，OVERALL=PASS |
| `verify-t1-02-ui.ps1` | 0 | 主检查 73/73；最小窗口 12/12；关闭退出码 0；CSP 0；页面异常 0 |

### 4.5 P2-01 脱敏与历史对象复核（第三轮）

| 检查 | 结果 |
|---|---|
| 当前 `T1-03-assets/` 敏感值扫描（33 文件：13 UTF-8 文本 + 1 BOM JSON + 19 PNG，含 PNG 文本块） | **敏感值命中 0**；唯一用户目录前缀出现在 `SANITIZATION.md` 的占位符示例（`C:\Users\<user>`，不含具体账户，非敏感） |
| 分支增量历史深度扫描（`018e851..HEAD`，18 提交 / 5,773 次文件树扫描） | 分支**新增**敏感值命中 **0**；5 条原始命中为本轮文档中的分类描述/占位符文本（`T1-03-REPORT.md`、`SANITIZATION.md`），不含具体机器标识 |
| 原始命令日志是否仍在仓库当前树 | 否（`T1-03-assets/logs/` 不存在，9 个文件在分支增量历史中不可达） |
| 远程 branches / tags / pull refs | 18 个 ref、tags 0 个；无任何远程 ref 含旧提交 `2342828`；`refs/pull/8/head` 为当前 HEAD，`refs/pull/8/merge` 父提交仅 main 基线 + 当前 HEAD |
| PR #8 描述与评论 | 第三轮修复提交前：body 2,091 字符 / SHA-256 `4621bf70…5f660`、2 条评论，扫描 0 命中；**PR 更新后（第三轮状态 + 说明评论）：body 3,001 字符 / SHA-256 `b46e6198…5891`、3 条 issue 评论、0 review comment、0 review，复扫敏感类别 0、旧日志文件名 0** |
| 旧提交服务端可达性 | **未清理**：旧提交 `2342828` commit API HTTP 200；旧 SHA 的 contents API 仍可列出 9 个原始日志（HTTP 200） |
| 本地 backup/bundle | 仅本地 `backup/t1-03-r1-audit-baseline` 与 gitignored bundle，未推送 |

脱敏策略、扫描细节、旧提交暴露与 GitHub Support 清理材料见 [`T1-03-assets/SANITIZATION.md`](T1-03-assets/SANITIZATION.md)。

### 4.6 全仓机器标识扫描（残余风险说明，第三轮）

- 当前 `T1-03-assets/`：敏感值命中 **0**。
- 仓库基线 main 中既有的 T1-01/T1-02 历史证据与日志仍含同类机器信息（954 条原始命中 / 53 个路径，属 main 既有内容，非本 PR 新增；本轮按“不修改 main”要求未处理），作为遗留风险记录。
- 旧提交 `2342828` 的 9 个原始日志仍可经 GitHub 服务端读取（P2-01 未关闭，等待 GitHub Support）。
- 说明：扫描模式在运行时由环境变量动态生成，未硬编码机器标识；只记录类别/计数，不输出具体值。

---

## 5. Windows Release 实测步骤与结果（第二轮步骤；第三轮已重新执行并通过）

在专用测试根目录下的全新 UAT 目录（虚构数据）实际执行：

| 步骤 | 结果 | 证据 |
|---|---|---|
| 1. Release 程序启动（新 EXE） | PASS（主窗口 1100×780，应用壳渲染） | 主检查 84/84 |
| 2. 创建未归属工作（含刷新提示时机） | PASS（延迟刷新时提示“正在刷新”；刷新成功后提示“已从数据库更新”） | `pending-unassigned.png`、主检查 timing 断言 |
| 3. 创建关联有效项目的工作 | PASS（选择器展示未归档项目） | `pending-linked-project.png` |
| 4. 归档一个项目 | PASS（项目记录保留） | `setup.projectArchived` |
| 5. 归档项目不再出现在新建选择器 | PASS（选项仅剩未归属项目） | `race.archivedProjectRemovedFromSelector` |
| 6. 直接向 IPC 传归档项目 ID | PASS：`project-archived`，未创建记录 | `ipc.archivedProjectRejectedEvenWithoutUiFilter` |
| 7. 该项目之前关联的工作仍存在 | PASS（显示项目名称 + “项目已归档”） | `pending-archived-project.png` |
| 8. 创建成功但列表刷新失败 | PASS：warning 提示、不重复创建、重新加载后恢复 | `pending-create-refresh-failure.png`、`pending-create-refresh-recovered.png` |
| 9. 关闭程序（真实红色关闭按钮） | PASS（退出码 0） | 编排 JSON `firstCloseExitCode=0` |
| 10. 重新启动同一目录并验证持久化 | PASS（5 条既有工作仍在；重启后新建 1 条；数据库/UI 一致） | `pending-after-restart.png`、`t1-03-db-after-restart.json` |
| 11. UAT 目录安全（P3-02 第三轮） | PASS：C 盘/正式目录/根目录外/`..` 越界/旧数据库/非空目录拒绝；真实 Junction（测试根本身/中间组件/输出目录/指向正式目录/指向 C 盘/指向根内）全部拒绝；校验失败时不创建/不复制/不写数据库；既有内容未被删除或覆盖 | `t1-03-uat-path-evidence.json`（60 项） |

固定窗口（默认 1100×780）与最小支持窗口（860×640）截图见 `screenshots/`；最小窗口下无横向溢出、无内容遮挡、按钮可点击、长标题省略且保留完整 `title` 属性；CSP 0 违规、页面未捕获异常 0。

---

## 6. 截图索引（`docs/testing/reports/T1-03-assets/screenshots/`，19 张）

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
| **`pending-create-refresh-failure.png`** | **P3-01：创建成功但列表刷新失败的 warning + 错误面板 + 重试入口** |
| **`pending-create-refresh-recovered.png`** | **P3-01：重新加载成功后的恢复状态** |
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
  t1-03-ui-evidence.json                      # 第三轮主 UI/IPC 84 项断言 + 截图/异常/CSP
  t1-03-min-window-evidence.json              # 第三轮最小窗口 12 项断言 + 关闭点击
  t1-03-persistence-evidence.json             # 第三轮重启持久化 17 项断言
  t1-03-uat-path-evidence.json                # UAT 路径安全 60 项（原有 23 + 新增 37；1 项 SKIP 不计 PASS）
  t1-03-ui-orchestration.json                 # 第三轮编排汇总（退出码、计数、EXE SHA、截图清单）
  t1-03-prerequisite.json                     # 第三轮重启阶段前的真实 IPC 数据快照（虚构）
  t1-03-db-after-main.json                    # 第三轮关闭后数据库只读探针
  t1-03-db-after-restart.json                 # 第三轮重启后数据库只读探针
  round3-verification-summary.json            # 第三轮机器可读汇总（门禁/路径/E2E/回归/EXE SHA/P2-01 状态）
  release-regression-portable-summary.json    # 继承便携验证详细证据（第二轮提交版本；第三轮复跑 106 项结果见 round3 汇总）
  release-regression-faults-summary.json      # 继承异常注入详细证据（第二轮提交版本；第三轮复跑 73 项结果见 round3 汇总）
  release-regression-t1-02-ui-orchestration.json # 继承 T1-02 UI E2E（第二轮提交版本；第三轮复跑通过）
test-counts.txt                               # 第三轮测试数量/环境/数据库探针关键事实速查
SANITIZATION.md                               # 第三轮脱敏扫描、旧提交服务端暴露与 GitHub Support 清理材料
```

说明：原始命令日志（包含计算机名/账户名/本地绝对路径）已按 P2-01 要求从仓库删除，当前证据 JSON/文本已脱敏；
第三轮复核确认旧提交 `2342828` 及 9 个原始日志仍可经 GitHub 服务端读取，**P2-01 未关闭**，需 GitHub Support
处理（材料见 `T1-03-assets/SANITIZATION.md` 第 4 节）。截图目录沿用第二轮同名实测截图（产品 UI/代码未变；
第三轮 E2E 重新执行并通过）。

---

## 8. 明确未实现 / 未修改

- 未实现 T1-04 多项目独立副本创建；T1-05 生命周期状态流转与历史；每日计划/未来 7 天；重要/紧急评分、全局优先级、手动置顶与排序；当前工作指针、切换、暂时跳过；每日复盘、提醒、工作日志、附件、报表、清理、备份恢复。
- 未新增一级侧边栏导航；未修改 AppShell / Sidebar / 全局 Design Tokens。
- 未修改 `list_projects` 契约（仍返回全部项目，含归档项目）；归档项目过滤仅用于选择器展示，安全边界在 Rust Core 事务内。
- 未修改 T1-01 便携路径/数据库初始化逻辑；继承验证脚本仅更新 schema 断言。
- 未新增运行时第三方依赖；未新增前端测试框架依赖（使用 Node 内置 `node:test`）。
- 未修改 PRD、TECHNICAL_DESIGN、DECISIONS 中的业务决策；未修改 DEC-028/DEC-029/DEC-033。

---

## 9. 遗留风险与已知限制

1. **尚未经过第三轮独立审计与用户验收**：本报告只是开发自测证据，不等于审计/验收结论。
2. **普通 SQLite 未加密**（DEC-028 已接受）：拥有文件访问权限的人可读取数据库内容。
3. **TOCTOU 残余风险**：按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复；不得宣称任何情况下不会写入 C 盘。
4. **P2-01 未关闭（服务端清理未完成）**：当前分支增量历史、工作区证据与 PR #8 文本脱敏复核 0 命中；但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 及其 9 个原始日志仍可经 GitHub API 读取（HTTP 200），GitHub Support 服务端清理尚未完成（工单材料见 `T1-03-assets/SANITIZATION.md` 第 4 节，需仓库所有者提交）；不得宣称 P2-01 已完成。仓库基线 main 中既有 T1-01/T1-02 同类机器信息（954 条原始命中 / 53 个路径，非本 PR 新增）未修改，作为遗留风险。
5. **待安排排序固定**为 `created_at DESC, id DESC`；不提供手动排序/优先级（后续任务）。
6. **P3-02（第三轮）**：已实现基于 Windows 文件句柄的重解析点/真实最终路径/卷身份检查，并通过 60 项本地专项测试（7 类真实 Junction 全部拒绝；1 项 Symbolic Link 因权限限制 SKIP、不计 PASS）；但路径校验与后续创建目录/复制 EXE/启动应用/写数据库之间仍存在 **TOCTOU 剩余窗口**，未消除，按 DEC-029 / Issue #2 记录，不得宣称已消除并发替换风险。
7. **刷新失败测试**通过 CDP 传输层故障注入实现（不修改产品代码）；真实磁盘/数据库故障路径仍由 Rust/数据库错误处理与异常注入回归覆盖。
8. 继承验证脚本的 schema 版本断言已改为 3；历史 T1-01/T1-02 报告中的数字为当时历史结果，本报告记录第三轮重新执行结果（产品代码未变，Release EXE 与第二轮一致）。

---

## 10. Git / PR 交付信息

- 分支：`task/T1-03-quick-create-pending`（PR #8 原分支）
- 基线：`018e851e8daf5835391a7b61caf881bc57c2ad42`
- 预编码设计提交：`9c091567351c4290b9f6ec1cea59f1e0d5f7bf6b`
- 第一轮实现提交：`be8d9c2e9c78710690de189936d6ee65f48ed8df`
- 第一轮审计基准 HEAD：`2342828852abee43ab56610e7d1fa91a02310bfe`（已被安全重写）
- 重写后 docs/evidence 提交（P2-01）：`b6cf344abc1693e7031427f8963c27474c0b59f9`
- 第二轮修复提交：
  - P2-02 `12b1bdf026f01688c79ba438165a97a652e086a1`（Rust/TS DTO 契约）
  - P3-01 + P3-02 `2d91c92301713597ccfc1c0ddc2d83a479f572d4`（提示时机、UAT 路径安全、E2E）
- 第三轮 P2-01/P3-02 修复提交：`b6a54591b783049142cbbffecd107ec9086723eb`；本轮文档复核提交：PR #8 后续提交（**第三轮未重写历史、未强制推送**）
- 本报告与第二轮脱敏证据的 docs 提交：分支后续提交（PR 时间线可见）
- PR：[#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) → `main`，保持 Open
- main：未修改（`018e851e8daf5835391a7b61caf881bc57c2ad42`）；PR 未合并

---

## 11. 当前状态与停止条件

**T1-03 第三轮 P2-01/P3-02 定向修复完成，等待第三轮独立审计。**

- 已完成：P2-01 重新扫描（分支增量历史/当前证据/远程 refs/PR #8 文本）与 GitHub Support 材料整理；P3-02 Windows 原生句柄路径安全修复与 60 项专项测试（7 类真实 Junction 全部拒绝；Symbolic Link 因权限限制 SKIP 并记录）；质量门禁、T1-03 Release E2E、T1-02 UI 回归、便携回归、异常注入回归全部通过；第三轮证据与文档同步。
- 未完成且不得由开发代理自行宣布：**P2-01 服务端历史对象清理（GitHub Support 未处理，P2-01 保持未关闭）**、第三轮独立审计通过、用户验收完成、PR 合并。
- 剩余风险：TOCTOU 未消除（DEC-029 / Issue #2）；main 基线既有 T1-01/T1-02 机器信息未修改（需单独授权）；普通 SQLite 未加密（DEC-028）。
- 按任务要求停止：不合并 PR #8、不修改 main、不开始 T1-04/T1-05、未获授权不再次执行全仓库历史重写或强制推送。
