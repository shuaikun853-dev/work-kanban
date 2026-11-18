# WorkManager 技术架构设计说明书

**版本：** V0.4.1（普通 SQLite 决策版 + UI 架构基线）\
**状态：** 开发设计基线（2026-11-17 已取消应用密码、SQLCipher 和 DPAPI；备份策略仍待确认）\
**基线：**《WorkManager — Windows 本地工作管理软件 PRD V0.3（普通 SQLite 决策版）》\
**目标平台：** Windows 10（建议最低版本 Windows 10 1803）\
**部署方式：** 绿色便携版，默认目录 `D:\WorkManager\`\
**数据原则：** 工作数据本地保存，不上传；应用管理的数据默认全部位于 D
盘\
**设计方法：** Matt Pocock Skills（需求澄清、领域建模、Deep
Modules、ADR、Research、TDD、Vertical Slices）

> 本文是 WorkManager 当前开发设计基线。尚未确认的事项必须在对应功能开始实现前单独确认；不得因此阻塞已获授权的阶段 1 基础设施开发。

------------------------------------------------------------------------

## 已确认的架构与产品决策（更新至 2026-11-17）

以下决策已由用户明确确认，后续设计和代码不得擅自改变：

1. **Windows Toast：** 默认保持纯 D 盘便携模式。只有用户主动开启完整 Windows 通知时，才创建必要的开始菜单快捷方式；创建前说明路径和用途，不得静默写入。
2. **整日跳过复盘：** 只将复盘标记为跳过，不自动放弃或改变任何工作事项状态。放弃工作必须是独立操作。
3. **业务时区：** 固定使用 `Asia/Shanghai`，不跟随 Windows 当前时区变化。工作日历、上班时间、复盘日期和日报日期统一使用该业务时区。
4. **复盘时机：** 在下一个工作日的设定上班时间开始复盘上一个工作日；每 5 分钟提醒一次，完成后停止，18:30 停止当日提醒；未完成则下一个工作日从断点继续。周一复盘周五，不为周六、周日单独创建复盘。
5. **附件清理：** 工作档案到期清理时，只删除 WorkManager 数据库中的附件关联/路径记录；绝不删除、移动或修改磁盘上的原始文件。
6. **数据存储策略：** 第一版采用普通 SQLite，不实现六位数字应用密码、应用锁屏、SQLCipher 或 DPAPI；接受数据库文件未加密的风险。
7. **开源边界：** 项目采用完全自研方式；可以研究开源项目的架构和交互，但不复制、移植其源代码。
8. **本地数据边界：** 工作数据、数据库、缓存、日志、临时文件及 WebView2 用户数据均放在 D 盘便携目录，不上传云端；不得静默写入 C 盘。
9. **UI 原型与前端分层：** 采用用户于 2026-11-18 确认的简洁 Apple 风格、Windows 原生窗口 UI；工作总览和今日工作为两个核心页面，具体规则见 [UI 设计规范](../design/UI-DESIGN-SPEC.md)。

仍待确认的事项包括自动备份、备份轮转和恢复策略，以及具体上班时间默认值和重复工作规则；最终 UI 布局与视觉方向已按 DEC-030 确认。

---

## 0. 文档目标与设计结论

V0.3
已经明确了产品功能和主要技术栈，但还缺少可以直接指导编码的内容：模块接口、数据模型边界、状态流转、事务规则、数据库初始化与启动流程、目录定位、提醒调度、数据清理、备份恢复和验收测试。

本设计文档将 PRD V0.3 转换为可实现、可测试、可审查的技术方案。

### 0.1 核心架构结论

  ----------------------------------------------------------------------------------------------------
  领域                    建议方案                                             状态
  ----------------------- ---------------------------------------------------- -----------------------
  桌面容器                Tauri 2                                              沿用 V0.2

  前端                    Svelte 5 + TypeScript + Vite                         沿用并明确不必引入
                                                                               SvelteKit

  后端                    Rust                                                 沿用

  架构形态                模块化单体 + 独立 Rust Core crate                    建议采纳

  数据库访问              Rust `rusqlite`                                      建议采纳

  数据库                  普通 SQLite，使用 `rusqlite` + bundled SQLite         已确认（DEC-028）

  应用访问                第一版不实现应用密码或应用锁屏                       已确认（DEC-028）

  数据访问边界            前端只能调用业务命令，禁止前端直接执行 SQL           必须

  日期模型                工作日期使用 `YYYY-MM-DD`，事件时间使用 UTC 时间戳   建议采纳

  提醒                    Rust 后台调度器，持久化提醒状态                      建议采纳

  便携路径                从 EXE 所在目录解析数据根目录，禁止静默回退到 C 盘   必须

  Windows Toast           默认纯便携；完整 Toast 仅用户主动开启并授权快捷方式   已确认

  自动备份                SQLite 一致性备份策略尚未确定                        待确认
  ----------------------------------------------------------------------------------------------------

### 0.2 明确不采用的方案

1.  不采用微服务：单机、单用户、本地数据场景没有必要引入网络服务和部署复杂度。
2.  不让 Svelte 页面直接访问 SQLite。
3.  不把业务状态保存在 `localStorage`、IndexedDB 或前端文件中。
4.  不把"复盘跳过"自动等价为"工作放弃"。
5.  不让单一 `work_items.plan_date`
    代表所有每日计划；计划日期必须由每日计划记录表达。
6.  第一版使用 `rusqlite` + 普通 bundled SQLite；不使用 SQLCipher，也不使用 SQLx 作为第一版数据访问层。
7.  不复制或移植任何开源项目的源代码；只研究其架构、产品行为和技术实现思路。

------------------------------------------------------------------------

## 1. 开源项目研究与参考决策

研究参考不是"找一个最像的软件整体复制"，而是按能力分析成熟实现：业务模型、存储、Windows 原生能力、复盘逻辑、拖动排序和测试方法分别研究。

### 1.1 项目对比

| 项目 | 技术与能力 | 许可证 | WorkManager 的研究用途 |
|---|---|---|---|
| [PomeTodo](https://github.com/ShiliuX-Team/pometodo) | Tauri 2、Rust、React、SQLite；本地待办、附件、备份、托盘、提醒 | GPL-3.0-only | 研究 Rust Core 分层、校验、附件安全和备份思路；不复制源代码 |
| [Super Productivity](https://github.com/super-productivity/super-productivity) | Angular；任务计划、工作日志、时间统计、每日/每周总结 | MIT | 研究日报/周报、统计口径和日期边界；不复制源代码 |
| [Chiri](https://github.com/chiriapp/chiri) | Tauri 2、Rust、React；任务、拖动排序、托盘、开机启动 | zlib | 研究 Tauri 2 Windows 集成和排序交互；不复制源代码 |
| [Todofy](https://github.com/salarzeidanlou/todofy) | Tauri 2、Rust、Preact、SQLite；今日/未来/待安排、置顶、提醒、计时 | Source-Available License | 只研究产品行为；不复制或移植代码 |
| [Tauri-SvelteKit-SQLite](https://github.com/Lmedmo/Tauri-SvelteKit-SQLite) | Tauri 1、SvelteKit、SQLx、SQLite | 未确认明确复用许可证 | 只参考通信思路；不复制代码，且 Tauri 1 不是本项目目标版本 |
| [todo-sqlite-sqlx](https://github.com/tauritutorials/todo-sqlite-sqlx) | Tauri 2、SQLx、SQLite 小型示例 | 未确认明确复用许可证 | 仅作学习参考，不作为正式代码来源 |

WorkManager 已明确选择**完全自研**。上表只用于研究架构、产品行为和公开技术思路，不代表允许复制、移植或改写任何项目源代码。第三方依赖库另行进行许可证与供应链审查。

### 1.2 重点研究内容

**PomeTodo：**

-   研究 `crates/todo-core` 的独立核心层组织方式。
-   研究 Rust 侧对输入数据、备份数据的校验方式。
-   研究附件路径校验、原子文件写入和失败清理方式。
-   研究 SQLite 单连接管理、事务和备份处理。
-   只研究其 SQLite 单连接管理、事务、备份校验和附件路径处理；不引入其密钥保护实现。

注意：PomeTodo 的 SQLite 和备份处理方式可作为普通本地数据库的架构研究参考。WorkManager 第一版不采用其 DPAPI/加密相关实现。

PomeTodo 是 GPL-3.0-only。WorkManager 只研究其架构与安全处理思路，不复制或移植其源代码；第三方依赖仍需单独审查许可证。

**Super Productivity：**

-   研究每日总结如何组合当天任务、工作日志和统计数据。
-   研究"工作事项数量"与"按日执行次数"的区别。
-   研究日历边界、跨日和周汇总逻辑。
-   其 MIT 许可证在法律上允许满足条件的代码复用；但 WorkManager 已选择完全自研，因此只研究行为和设计，不复制或移植源代码。

**Chiri：**

-   研究 Tauri 2
    托盘、autostart、single-instance、通知等原生能力接入方式。
-   研究任务拖动排序和可访问性交互。
-   不采用其 CalDAV 同步作为 WorkManager 的数据架构。
-   不采用"前端直接操作数据库"的模式。

**Todofy：**

-   重点研究优先级、手动置顶、后台轮询、重复提醒、计时状态持久化。
-   其许可证明确限制分发软件及其修改版本，因此不把它作为可直接复制代码的来源。

### 1.3 可直接采用的依赖候选

| 依赖 | 用途 | 选择理由 / 验证要求 |
|---|---|---|
| `rusqlite` + `bundled` | 普通 SQLite 访问 | 随应用构建 SQLite，避免依赖目标机器单独安装 SQLite；验证 Windows Release 构建 |
| `rusqlite` 的 `backup` feature | 一致性在线备份 | 使用 SQLite backup API，不直接复制正在写入的 DB 文件；验证恢复后 integrity_check |
| `chrono` | 日期、时间计算 | Rust 侧统一工作日期和时间逻辑；测试时区、跨月、闰年 |
| `uuid` | 主键生成 | 本地生成唯一 ID；测试迁移和批量创建 |
| `serde` | IPC DTO 序列化 | Rust 与 TypeScript 数据交换；测试 JSON 契约 |
| `thiserror` | 结构化错误 | 统一错误码和 UI 错误映射 |
| `svelte-dnd-action` | Svelte 拖动排序 | 仅在对应 UI 任务需要时引入，验证 Svelte 5 兼容性和键盘操作 |
| Tauri 官方插件 | Windows 集成 | 仅按需引入 tray、autostart、single-instance、dialog、opener |

第三方依赖必须在引入前检查许可证、维护状态、Windows 支持和实际必要性。第一版不引入 SQLCipher、DPAPI 或专用密钥管理依赖。

## 2. 总体架构

### 2.1 架构形态

采用**模块化单体（Modular Monolith）**：

-   一个 Windows 桌面进程。
-   一个 Rust 后端。
-   一个本地 SQLite 数据库。
-   一个 Svelte 前端。
-   业务模块在同一个 Rust 进程内通过明确接口协作。
-   不引入 HTTP 服务、远程数据库或微服务。

### 2.2 分层结构

``` text
┌──────────────────────────────────────────────┐
│                 Svelte 5 UI                  │
│                                              │
│ Dashboard / Projects / Work Items / Review   │
│ Reports / History / Settings                 │
└──────────────────────┬───────────────────────┘
                       │ Tauri invoke / events
┌──────────────────────▼───────────────────────┐
│                Tauri Adapter                 │
│                                              │
│ Commands / DTO validation / Event delivery   │
│ Window / Tray / Autostart / Dialog / Opener  │
└──────────────────────┬───────────────────────┘
                       │
┌──────────────────────▼───────────────────────┐
│             WorkManager Core                 │
│                                              │
│ WorkItemService      DailyPlanService        │
│ DailyReviewService   FocusService            │
│ PriorityEngine       CalendarService         │
│ ReportService        RetentionService        │
└──────────────────────┬───────────────────────┘
                       │
┌──────────────────────▼───────────────────────┐
│                Infrastructure                │
│                                              │
│ SQLite Repository / Migration / Backup      │
│ PortablePaths / FileSystem / Scheduler      │
│ Windows Notification / Logging              │
└──────────────────────────────────────────────┘
```

### 2.3 依赖方向

1.  UI 只依赖 Tauri 命令和事件契约。
2.  Tauri 命令只负责参数校验、调用 Core、转换错误和返回 DTO。
3.  Core 不依赖 Svelte、Tauri Window 或具体 Windows UI。
4.  Core 通过小接口访问数据库、时钟、工作日历和文件系统。
5.  Infrastructure 实现这些接口。
6.  数据库连接、SQL 文本和 SQL 参数值不得进入前端或 IPC DTO；前端只调用业务命令。

### 2.4 代码目录建议

``` text
WorkManager/
├── WorkManager.exe
├── resources/
├── data/
│   ├── database/
│   │   └── work.db
│   ├── config/
│   ├── logs/
│   ├── cache/
│   │   └── webview2/
│   ├── temp/
│   └── backups/
│
├── src/
│   ├── app/
│   ├── lib/
│   │   ├── bridge/
│   │   ├── contracts/
│   │   ├── components/
│   │   └── features/
│   │       ├── dashboard/
│   │       ├── projects/
│   │       ├── work-items/
│   │       ├── daily-plan/
│   │       ├── daily-review/
│   │       ├── reports/
│   │       ├── history/
│   │       └── settings/
│   └── main.ts
│
├── src-tauri/
│   ├── src/
│   │   ├── main.rs
│   │   ├── lib.rs
│   │   ├── commands/
│   │   ├── scheduler/
│   │   ├── platform/
│   │   │   └── windows/
│   │   ├── security/
│   │   ├── storage/
│   │   └── app_state.rs
│   ├── migrations/
│   ├── capabilities/
│   └── tauri.conf.json
│
├── crates/
│   └── workmanager-core/
│       └── src/
│           ├── domain/
│           ├── application/
│           ├── ports/
│           └── services/
│
└── docs/
    ├── GLOSSARY.md
    ├── adr/
    ├── architecture/
    ├── database/
    ├── testing/
    └── research/
```

说明：

-   `workmanager-core` 独立于 Tauri，可用普通 Rust 测试运行。
-   `src-tauri` 是 Windows/Tauri 适配层。
-   `src` 只保存 UI 状态，不持有业务数据库。
-   `data` 是运行时数据目录，不纳入源码版本管理。
-   `docs/adr` 保存长期有效、难以逆转的技术决策。

### 2.5 UI 组件化与状态边界

用户确认的 UI 原型和具体视觉规则见 [UI 设计规范](../design/UI-DESIGN-SPEC.md)。前端按以下职责渐进组织：

```text
src/
├── App.svelte                 # 应用组合入口，不承载业务规则
├── app/                       # AppShell、Sidebar、navigation
└── lib/
    ├── ui/                    # tokens.css + 通用 UI 组件
    ├── features/
    │   ├── overview/          # 工作总览
    │   ├── today/             # 今日工作
    │   ├── work-items/        # 工作事项
    │   ├── daily-review/      # 每日复盘
    │   ├── reports/           # 报表
    │   ├── history/           # 历史记录
    │   └── diagnostics/       # 数据库健康检查等诊断页面
    ├── bridge/                # 类型安全的 Tauri 命令封装
    ├── contracts/             # 前后端 DTO 契约
    └── presentation/          # 无副作用的展示格式化函数
```

约束：

1. `App.svelte` 只负责应用级组合和页面切换；页面逻辑放在对应 Feature 页面容器中。
2. `lib/ui` 只包含可复用视觉组件和 Design Tokens，不包含工作事项业务规则。
3. Feature 页面拥有自己的页面状态和局部组件；禁止跨 Feature 直接依赖对方内部组件。
4. 页面容器通过 `bridge` 调用类型安全的 Tauri 命令；展示组件只通过 typed props 和事件/callback 交互，不直接调用任意 IPC。
5. Rust Core 是业务状态和规则的唯一权威来源；当前工作指针、工作事项生命周期和每日执行记录不能在多个前端页面重复维护。
6. CSS 使用语义化 Token 和 Svelte scoped styles；`app.css` 只负责基础 reset、字体和 Token 引入，禁止全局样式侵入其他 Feature。
7. 逐步迁移当前数据库健康检查界面：先保留其既有行为和诊断能力，再将其移入 diagnostics Feature；不得为了搭建新 UI 而一次性重写或删除已验收的 T1-01 逻辑。
8. 采用小步改动：先稳定 Token 和应用壳，再逐个实现工作总览、今日工作；每次公共组件变更必须检查所有使用方并提供页面截图回归。

```

------------------------------------------------------------------------

## 3. 领域模型与统一术语

以下术语建议写入项目根目录 `GLOSSARY.md`，避免 UI、Rust
类型、数据库字段和开发对话使用不同名称。

  ---------------------------------------------------------------------------------------------------------
  术语                      定义                                                   不应混淆为
  ------------------------- ------------------------------------------------------ ------------------------
  Work Item（工作事项）     用户需要处理的一项长期工作实体                         某一天的执行记录

  Project（项目）           工作事项所属的业务分类                                 每日计划

  Project                   批量关联多个项目时，为每个项目独立创建的工作事项副本   多项目共享同一工作状态
  Instance（项目实例）                                                             

  Daily Plan                某工作日期准备执行的一项工作                           工作事项整体状态
  Item（每日计划项）                                                               

  Daily Review（每日复盘）  用户对某个工作日期实际执行情况的确认过程               工作事项生命周期

  Daily Review              某工作事项在某工作日期的实际结果快照                   工作日志
  Entry（每日复盘明细）                                                            

  Work Log（工作进度日志）  针对工作事项追加的详细进展、问题、解决方案和下一步     每日计划

  Focus Item（当前工作）    当前被用户指定为正在处理的工作事项                     唯一的进行中工作

  Focus Switch              暂时跳过、切换或结束当前工作的历史事件                 工作状态变更
  Event（工作切换事件）                                                            

  Pending                   因跳过工作而产生、尚未确认进度的事件                   工作事项生命周期状态
  Follow-up（待补充进度）                                                          

  Manual Pin（手动置顶）    用户明确设置的全局优先级覆盖                           每日计划排序

  Daily Order（每日顺序）   某一天计划列表内的排序                                 全局手动置顶
  ---------------------------------------------------------------------------------------------------------

### 3.1 工作事项与每日执行必须分离

一个工作事项可以持续多天：

``` text
Work Item: 中核商品价格异常排查
  lifecycle_status = in_progress

Daily Plan:
  2026-11-16: planned
  2026-11-17: planned
  2026-11-18: planned

Daily Review:
  2026-11-16: progressed
  2026-11-17: not_executed
  2026-11-18: completed
```

结果：

-   工作事项数量：1。
-   每日计划次数：3。
-   每日执行结果记录：3。
-   最终完成工作事项数量：1。

任何报表都不能把这三天算成三项独立完成工作。

------------------------------------------------------------------------

## 4. 核心业务状态设计

### 4.1 工作事项生命周期

``` text
待安排
  │ 用户安排到日期
  ▼
未开始
  │ 用户开始处理 / 首次确认有推进
  ▼
进行中
  ├──────── 用户确认完成 ────────► 已完成
  └──────── 用户明确放弃 ────────► 已放弃

已放弃 ── 用户主动恢复 ──► 待安排
```

规则：

-   创建工作事项时默认待安排。
-   加入某个工作日期计划后，可以变为未开始。
-   用户设置为当前工作时，可以在同一事务中变为进行中。
-   每日复盘选择"有推进，未完成"时，可以把未开始更新为进行中。
-   "没做/未执行"不改变整体状态。
-   只有用户明确确认完成，才能变成已完成。
-   只有用户明确放弃，才能变成已放弃。
-   子任务全部勾选，不自动把工作事项变为已完成。
-   完成或放弃时，清除手动置顶；恢复后重新参与自动排序。

### 4.2 每日复盘状态

建议独立使用：

  状态          说明
  ------------- ----------------------
  pending       尚未开始
  in_progress   正在逐项确认
  completed     已完成复盘
  skipped       用户明确跳过本次复盘

复盘结果：

  结果           对工作事项的影响
  -------------- ---------------------------
  completed      整体状态更新为已完成
  progressed     整体状态保持/更新为进行中
  not_executed   不改变整体状态

**重要修正：`skipped` 不能批量把工作事项更新成 `abandoned`。**

如果用户确实希望批量放弃工作，应提供另一个独立操作，展示受影响事项并二次确认。

### 4.3 当前工作和切换

数据库中只允许一条当前工作指针：

``` text
focus_state
  singleton_id = 1
  current_work_item_id = ?
  changed_at = ?
```

设置当前工作时，在同一个数据库事务中：

1.  检查目标工作事项存在且允许开始。
2.  记录上一个当前工作。
3.  更新当前工作指针。
4.  必要时更新目标工作事项状态。
5.  写入工作切换事件。

暂时跳过时：

1.  当前工作指针切换到用户选择的其他工作，或清空。
2.  原工作事项保持进行中。
3.  新增一条 `focus_switch_events`。
4.  事件标记为待补充进度。
5.  用户以后补充进度后，解决对应事件。
6.  多次跳过产生多条事件，不覆盖历史记录。

"待补充进度"通过未解决的切换事件派生，不需要增加一个工作生命周期状态。

### 4.4 两种排序必须分开

**全局优先级：**

-   `pinned_rank`：手动置顶顺序。
-   `importance`：重要程度。
-   `urgency`：紧急程度。
-   `due_date`：只用于展示截止提醒，不参与自动排序。

建议初始评分：

``` text
priority_score = importance + urgency
```

重要程度和紧急程度均使用 1--5，等权处理。

排序规则：

1.  已置顶事项优先。
2.  置顶事项按 `pinned_rank` 排序。
3.  其他事项按 `priority_score DESC`。
4.  同分使用稳定的创建时间和 ID 作为次级排序键。

**每日计划顺序：**

`daily_plan_items.sort_order` 独立保存。

在每日计划列表中拖动，只改变当天顺序；在全局优先级列表中拖动，才改变全局置顶顺序。

这可以避免用户调整今天的执行顺序，却意外改变其他日期和全局优先级。

------------------------------------------------------------------------

## 5. 数据库设计

### 5.1 核心表

  ---------------------------------------------------------------------------------------------------------------------------------------------------------------
  表名                                 主要职责                   关键字段/约束
  ------------------------------------ -------------------------- -----------------------------------------------------------------------------------------------
  `projects`                           项目管理                   `id`、`name`、`is_archived`、时间字段

  `work_items`                         工作事项主体               `project_id`、`title`、`importance`、`urgency`、`lifecycle_status`、`due_date`、`pinned_rank`

  `work_item_creation_groups`          批量创建来源               `id`、`source_title`、`created_at`

  `work_item_creation_group_members`   批量创建组与工作事项关联   `group_id`、`work_item_id`

  `subtasks`                           简单子任务                 `work_item_id`、`title`、`is_completed`、`sort_order`

  `daily_plans`                        某工作日期的计划容器       `work_date` 唯一

  `daily_plan_items`                   某日期计划的工作事项       `daily_plan_id`、`work_item_id`、`sort_order`、标题/项目快照

  `daily_reviews`                      每日复盘主记录             `work_date` 唯一、`status`、`no_work_confirmed`

  `daily_review_entries`               每日实际执行结果快照       `work_date`、结果、工作标题快照、项目快照、简要进度

  `work_logs`                          详细工作进度日志           `work_item_id`、`work_date`、`content`、`problem`、`solution`、`next_step`

  `work_item_history`                  工作事项状态变更历史       `work_item_id`、`event_type`、旧值/新值、时间

  `focus_state`                        唯一当前工作指针           `singleton_id=1`、`current_work_item_id`

  `focus_switch_events`                当前工作切换/跳过事件      来源工作、目标工作、事件类型、待补充状态

  `attachments`                        原始附件路径关联           `work_item_id`、`original_path`、`display_name`、检测状态

  `calendar_days`                      工作日历                   `calendar_date`、`day_type`、`source`、`is_manual_override`

  `settings`                           应用业务设置               `key`、`value_json`、`updated_at`

  `daily_report_snapshots`             日报历史快照               `work_date`、`summary_json`、`generated_at`

  `reminder_state`                     最小提醒调度状态           待复盘日期、下次提醒时间、当天截止时间

  `schema_migrations`                  数据库版本迁移             `version`、`applied_at`
  ---------------------------------------------------------------------------------------------------------------------------------------------------------------

### 5.2 必须采用的快照策略

`daily_plan_items` 和 `daily_review_entries` 不应只保存 `work_item_id`。

原因：工作事项在三个月后可能被清理，但每日计划和每日复盘需要保留一年。

建议保存：

-   `work_item_id`：允许为空，外键使用 `ON DELETE SET NULL`。
-   `project_id`：允许为空，外键使用 `ON DELETE SET NULL`。
-   `work_title_snapshot`：当时的工作标题。
-   `project_name_snapshot`：当时的项目名称。
-   `work_date`：实际工作日期。
-   `outcome`：当天执行结果。
-   `summary_text`：当天简要进度。

这样工作事项档案被清理后，日报、周报、月报仍能还原当时的工作内容。

### 5.3 计划日期的唯一事实来源

不建议在 `work_items` 中保存一个唯一的 `plan_date`
作为所有计划的事实来源。

因为同一工作事项可能出现在多个工作日。

建议：

-   `daily_plans.work_date` 表示计划日期。
-   `daily_plan_items` 表示该日期安排了哪些工作。
-   工作事项本身不需要依赖单一计划日期。
-   UI 展示"下一次计划日期"时，从未来的 `daily_plan_items` 计算。

### 5.4 项目关联规则

建议允许 `work_items.project_id` 为空，表示尚未归属项目的工作。

当用户一次选择多个项目时：

``` text
输入标题：中核商品价格异常排查
选择：项目 A、项目 B

创建：
  work_item_A(project_id=A)
  work_item_B(project_id=B)

创建组：
  creation_group_1
    ├── work_item_A
    └── work_item_B
```

两条工作记录的状态、进度、日志、计划和附件全部独立。

### 5.5 关键索引

建议至少建立：

``` sql
-- 项目和状态过滤
CREATE INDEX idx_work_items_project_status
ON work_items(project_id, lifecycle_status);

-- 全局自动优先级
CREATE INDEX idx_work_items_auto_priority
ON work_items(lifecycle_status, importance, urgency);

-- 每日计划排序
CREATE INDEX idx_daily_plan_items_order
ON daily_plan_items(daily_plan_id, sort_order);

-- 每日复盘查询
CREATE INDEX idx_daily_review_entries_date
ON daily_review_entries(work_date, outcome);

-- 工作日志时间线
CREATE INDEX idx_work_logs_item_time
ON work_logs(work_item_id, created_at);

-- 当前焦点相关事件
CREATE INDEX idx_focus_events_item_time
ON focus_switch_events(from_work_item_id, created_at);
```

实际建表时必须根据最终查询和 `EXPLAIN QUERY PLAN`
验证索引，不为每个字段盲目增加索引。

### 5.6 数据库约束

-   `lifecycle_status` 使用 CHECK 约束。
-   `importance`、`urgency` 限定 1--5。
-   `pinned_rank` 只允许置顶事项拥有，并通过部分唯一索引保证顺序不冲突。
-   `focus_state` 使用固定主键，确保只有一条记录。
-   `daily_plans.work_date` 唯一。
-   同一工作事项同一天的计划项默认唯一。
-   `daily_reviews.work_date` 唯一。
-   同一工作事项同一天只允许一条最终复盘结果。
-   外键必须开启。
-   所有多表状态变更必须在事务中完成。

------------------------------------------------------------------------

## 6. 数据库访问与事务设计

### 6.1 数据库访问边界

前端只能调用业务命令，例如：

``` text
create_work_item
update_work_item
plan_work_item
set_focus_work_item
skip_focus_work_item
record_daily_review_entry
complete_daily_review
get_dashboard_snapshot
search_work_history
```

不提供：

``` text
execute_sql
query_sql
run_arbitrary_statement
```

Rust 后端负责：

-   参数校验。
-   权限和状态校验。
-   业务规则。
-   SQL 参数绑定。
-   事务。
-   错误码转换。
-   历史记录写入。

### 6.2 数据库连接

第一版建议：

-   一个 SQLite 连接。
-   使用 `Mutex<Connection>` 管理连接。
-   数据库操作放入阻塞线程执行，避免阻塞 Tauri 异步运行时。
-   所有写入事务串行化。
-   数据规模增长后再评估读连接池。

不要为了"看起来高级"一开始引入复杂连接池和 ORM。

### 6.3 SQLite 参数建议

SQLite 连接打开后，初始化以下配置：

-   `foreign_keys = ON`
-   `journal_mode = WAL`
-   `synchronous = FULL`
-   `busy_timeout` 设置合理等待时间
-   `temp_store = MEMORY`
-   `temp_store = MEMORY`（用于减少临时数据落盘，不作为加密保证）
-   `secure_delete = ON` 仅在确有需要且完成性能验证后考虑

普通 SQLite 不加密数据库内容。WAL、SHM、临时文件和备份均可能包含可读工作数据；必须将它们放在 D 盘便携目录，并纳入备份、清理和隐私说明。

------------------------------------------------------------------------

## 7. 本地数据保护与异常处理

### 7.1 第一版安全边界

- 第一版不实现六位数字应用密码、应用锁屏、SQLCipher 或 DPAPI。
- 使用普通 SQLite；数据库文件、WAL、SHM 和备份不是加密文件。
- 用户接受拥有相应 Windows 文件访问权限的人可以直接读取数据库文件的风险。
- 工作数据仍只保存在 D 盘便携目录，不上传云端，不接入云同步或未经批准的遥测。
- 不要把本地存储描述成加密存储，也不要声称普通 SQLite 可以防止本机其他用户读取。

### 7.2 首次初始化

1. 解析 EXE 所在目录和便携数据根目录。
2. 检查 D 盘数据目录可写。
3. 创建 `data/database`、`data/logs`、`data/cache`、`data/temp`、`data/backups` 等目录。
4. 如果数据库不存在，使用临时数据库文件执行 schema migrations。
5. 完成必要初始化和完整性检查后，原子地将初始化结果放到正式数据库路径。
6. 初始化失败时保留诊断信息，不留下可被误认为有效数据库的半成品。
7. 创建默认业务设置并启动 Core 服务。

### 7.3 正常启动

1. 解析便携根目录。
2. 检查数据库文件是否存在。
3. 若数据库不存在且属于明确的首次安装，才允许创建新库。
4. 若数据库存在但无法打开、格式不符或完整性检查失败，进入错误/恢复流程；不得自动删除、重建或覆盖。
5. 检查并按版本执行数据库 migration。
6. 初始化 Core 服务并展示工作总览。

### 7.4 SQLite 与事务规则

- 使用参数化 SQL，禁止拼接用户输入构造 SQL。
- 所有多表写入必须在同一明确事务中完成。
- migration 使用 `PRAGMA user_version` 管理版本，并在事务中执行；migration 失败时回滚。
- 外键约束必须启用：`PRAGMA foreign_keys = ON`。
- 推荐 WAL 模式，设置合理的 `busy_timeout`；`synchronous` 根据可靠性和性能测试确定，默认优先数据可靠性。
- 读写异常、磁盘空间不足和数据库损坏时保留原始文件，显示明确错误。
- 数据库初始化、migration 和恢复操作不得静默创建一个空库替代已有数据库。
- 备份使用 SQLite 在线备份 API 或经过验证的一致性快照，不得简单复制正在使用的主数据库文件。

### 7.5 日志与隐私

日志不得记录完整工作标题、客户信息、工作日志正文、附件内容或 SQL 参数值。日志可以记录任务 ID、错误类别、时间和必要的非敏感诊断信息。

## 8. D 盘便携目录与路径控制

### 8.1 数据根目录

建议：

``` text
portable_root = current_exe().parent()
data_root = portable_root / "data"
```

默认：

``` text
D:\WorkManager\
```

移动到：

``` text
D:\Tools\WorkManager\
```

后，程序仍从新的 EXE 目录定位 `data`。

建议要求运行目录所在盘符为 D；如果不满足，直接提示用户，不静默退回
`%APPDATA%`、`%LOCALAPPDATA%` 或 C 盘临时目录。

### 8.2 WebView2

Tauri 默认数据目录不能满足动态便携路径的严格要求。

建议在 Rust 侧创建主窗口时，使用 `WebviewWindowBuilder::data_directory`
指定绝对路径：

``` text
D:\WorkManager\data\cache\webview2\
```

不要仅使用 `tauri.conf.json` 中相对默认用户数据目录的
`dataDirectory`，因为本项目需要跟随 EXE 移动。

### 8.3 应用数据位置

  数据                位置
  ------------------- --------------------------
  SQLite 数据库       `data/database/work.db`
  WebView2 用户数据   `data/cache/webview2/`
  日志                `data/logs/`
  临时文件            `data/temp/`
  备份                `data/backups/`
  运行配置            `data/config/`

工作日历、提醒时间、工作计划等业务设置优先保存在 SQLite 数据库中。普通 SQLite 未加密，任何导出的 JSON/CSV 或数据库备份同样按可读数据管理。

所有临时文件必须显式创建在 D 盘 `data/temp`，不得直接使用系统默认 Temp
路径。

### 8.4 Windows 系统集成例外

-   开机启动可能写入 Windows 注册表。
-   Windows 通知可能要求开始菜单快捷方式。
-   WebView2 运行组件由 Windows 管理。
-   系统日志和注册表不属于 WorkManager 业务数据。

但是开始菜单快捷方式属于应用创建的文件，不能未经用户同意就写入 C
盘用户目录。该项必须作为独立授权选项。

### 8.5 便携移动后的启动项修复

1.  用户从新位置手动启动 EXE。
2.  程序获取当前 EXE 绝对路径。
3.  检查开机启动配置是否仍指向旧路径。
4.  通过 Tauri autostart 管理器重新注册当前路径。
5.  不删除用户的数据库和备份文件。

------------------------------------------------------------------------

## 9. 每日复盘与提醒调度

### 9.1 工作日历模型

`calendar_days` 建议字段：

-   `calendar_date`
-   `day_type`：workday / restday / normal
-   `source`：official / manual / default
-   `is_manual_override`
-   `note`
-   `updated_at`

优先级：

``` text
用户手动设置
    >
官方导入的中国大陆节假日/调休
    >
普通周一至周五规则
```

如果某日期没有官方数据，允许使用普通周历推断，但应能区分"官方确认"和"默认推断"。

### 9.2 上一个工作日算法

不能使用简单的 `today - 1 day`。

建议：

``` text
find_previous_workday(today):
  从 today - 1 天开始向前查找
  查询 calendar_days / 默认周历
  返回最近一个 workday
```

如果存在尚未完成的历史复盘，优先继续最早的未完成复盘日期。

### 9.3 复盘流程

``` text
待复盘
  │
  ▼
逐项展示昨日计划
  │
  ├── 已完成
  ├── 有推进，未完成
  ├── 未执行
  └── 补录计划外工作
  │
  ▼
用户确认
  │
  ▼
生成日报快照
```

补录计划外工作时：

-   允许新增工作事项。
-   允许关联项目。
-   记录该事项在复盘日期的实际结果。
-   不覆盖其他工作事项的历史执行记录。

### 9.4 "昨天没有工作"

点击后：

-   将当日复盘标记为完成。
-   如果当天有计划项，为这些计划项生成 `not_executed` 快照。
-   不修改工作事项的生命周期状态。
-   生成"无工作/无执行"的日报信息。

### 9.5 “跳过整日复盘”

**用户已确认：跳过复盘只跳过复盘，不自动放弃任何工作。**

只把 `daily_reviews.status` 更新为 `skipped`。

不自动把工作事项更新为已放弃，也不改变工作事项的其他生命周期状态。

如果需要放弃工作，单独提供明确的批量放弃操作和二次确认。

### 9.6 提醒调度器

Rust 后台调度器负责复盘提醒，但提醒时机必须遵循用户确认的工作日规则：

1. 业务时区固定为 `Asia/Shanghai`。
2. 只为上一个工作日创建/继续复盘；周一对应上周五，周六、周日不生成独立复盘。
3. 在设定的上班时间开始提醒。具体上班时间由设置提供，不在设计阶段硬编码未经确认的默认值。
4. 复盘尚未完成时，每 5 分钟提醒一次；用户完成复盘后立即停止。
5. 当日 18:30 停止提醒。18:30 只是提醒时段截止，不在该时间弹出“下班复盘”。
6. 到 18:30 仍未完成的复盘，保留原进度；下一个工作日从断点继续，不重复询问已经确认的条目。
7. 应用启动晚于上班时间且存在待复盘时，立即补发一次提醒。
8. 电脑从睡眠恢复时，只触发一次补偿提醒，不连续补发所有错过的提醒。
9. 已完成或用户明确跳过的复盘不再重复提醒；整日跳过只改变复盘状态，不改变工作事项生命周期状态。

调度器应持久化待复盘日期、已确认条目、下一次提醒时间和当日提醒截止时间。程序重启后从持久化状态恢复，避免重复提醒或丢失复盘进度。

通知内容只使用通用提示，例如：

> 有一项上一工作日复盘待处理

系统通知只显示通用提醒，不显示客户、项目或工作标题。

## 10. Windows 托盘、开机启动和通知

### 10.1 托盘

使用 Tauri 2 的 tray-icon 能力。

菜单建议：

-   打开 WorkManager
-   今日工作
-   立即复盘
-   手动到岗
-   退出

点击窗口关闭按钮时默认隐藏到托盘，不等于退出进程。

### 10.2 开机启动

使用 Tauri 官方 autostart 插件。

必须验证：

-   当前用户登录后可以启动。
-   便携目录移动后可以修复启动路径。
-   禁用开机启动后能清理对应注册项。
-   不在启动参数中传递工作内容或其他敏感业务数据。

### 10.3 单实例

使用 single-instance 能力。

第二次启动时：

-   不创建第二个数据库连接。
-   将现有主窗口恢复。
-   如果已有主窗口，则恢复现有窗口，不创建第二个数据库连接。
-   不重复启动后台调度器。

### 10.4 Windows Toast 的便携限制

Tauri 官方 notification 插件的 Windows 支持说明是"只对已安装应用有效"。

Windows 桌面 Toast 通常还需要：

-   Start Menu 快捷方式。
-   AppUserModelID。
-   Windows 通知接口。

并且桌面应用不能依靠 Windows Toast 自身完成定时调度，必须由 WorkManager
进程在后台到点发送。

因此，不能在尚未验证的情况下直接把 `tauri-plugin-notification`
当作便携版必然可用的能力。

提供两种通知模式：

- **纯便携模式（默认）：** 应用内提醒 + 托盘提醒，不创建开始菜单快捷方式。
- **完整 Windows 通知模式（用户主动开启）：** 用户已同意在主动开启该模式时，创建带 AppUserModelID 的开始菜单快捷方式，再启用并验证 Toast。

不得在首次启动或默认运行过程中静默创建快捷方式。设置界面必须说明快捷方式的实际路径和用途，并允许用户关闭该模式、清理由 WorkManager 创建的快捷方式。

------------------------------------------------------------------------

## 11. 日报、周报和月报统计

### 11.1 统计口径

必须同时区分：

1.  工作事项数量：按唯一工作事项统计。
2.  每日计划次数：按日期和工作事项组合统计。
3.  每日执行次数：按每日复盘明细统计。
4.  工作完成数量：只统计生命周期进入已完成的工作事项。

### 11.2 日报

来源：

-   `daily_plan_items`
-   `daily_review_entries`
-   `daily_reviews`
-   `daily_report_snapshots`

日报包括：

-   当日计划事项数量。
-   已完成事项数量。
-   有推进但未完成数量。
-   未执行数量。
-   计划外工作。
-   项目分布。
-   简要进度。

如果当日复盘被跳过，应明确标记"复盘未确认"，不能生成看起来完整的执行结果。

### 11.3 周报/月报

建议同时提供两套统计：

-   **工作事项口径：** 期间涉及多少个不同工作事项，多少个最终完成。
-   **执行次数口径：** 期间发生多少次每日计划和执行记录。

例如一项工作推进五天：

-   工作事项数量：1。
-   每日执行次数：5。
-   完成工作事项数量：1。

完成率不能把这两个口径混成一个数字。

周报和月报优先从一年内保留的每日快照计算，不依赖已经清理的工作事项档案。

------------------------------------------------------------------------

## 12. 附件管理

### 12.1 存储方式

WorkManager 只保存用户原始文件路径，不复制文件内容。

字段建议：

-   `id`
-   `work_item_id`
-   `original_path`
-   `display_name`
-   `added_at`
-   `last_checked_at`
-   `exists_status`

### 12.2 添加附件

1.  使用原生文件选择对话框。
2.  Rust 后端校验路径和文件存在性。
3.  保存绝对路径。
4.  不读取文件内容。
5.  不上传文件。

### 12.3 打开附件

通过系统默认程序打开原始文件。

文件不存在时：

-   显示路径失效。
-   允许用户重新选择。
-   更新路径记录。
-   不删除旧文件。

### 12.4 清理

工作事项档案按三个月规则到期清理时，只删除 WorkManager 数据库中的附件关联和原始路径记录。

**绝对禁止**调用 `remove_file`、文件系统删除 API 或其他方式删除、移动、覆盖、重命名用户磁盘上的原始附件。附件内容不复制、不读取、不上传。

------------------------------------------------------------------------

## 13. 数据保留与清理

### 13.1 建议保留规则

  数据                   保留期限         清理规则
  ---------------------- ---------------- ----------------------------------------
  未完成工作             长期             不自动删除
  进行中工作             长期             不自动删除
  已完成工作             3 个日历月       删除工作档案及关联详细日志
  已放弃工作             3 个日历月       删除工作档案及关联详细日志
  工作事项详细进度日志   随工作档案       工作档案清理时删除
  附件路径关联           随工作档案       只删数据库关联，原始文件永久保留
  每日计划快照           1 年             到期清理
  每日复盘明细           1 年             到期清理
  每日日报快照           1 年             到期清理
  周报/月报              由每日快照派生   不必重复保存，除非用户需要固定历史版本

"3 个月"建议按日历月计算，而不是固定 90 天；最终边界规则需确认。

### 13.2 清理顺序

1.  计算到期工作事项。
2.  生成清理预览。
3.  根据备份策略执行备份或确认。
4.  开启数据库事务。
5.  删除已到期工作事项。
6.  通过外键规则清理详细日志、历史记录和附件关联。
7.  保留每日计划和每日复盘中的标题/项目快照。
8.  删除超过一年的每日快照。
9.  记录本次清理结果。
10. 提交事务。

### 13.3 关键外键策略

-   `work_logs.work_item_id`：`ON DELETE CASCADE`。
-   `work_item_history.work_item_id`：`ON DELETE CASCADE`。
-   `attachments.work_item_id`：`ON DELETE CASCADE`。
-   `daily_plan_items.work_item_id`：`ON DELETE SET NULL`。
-   `daily_review_entries.work_item_id`：`ON DELETE SET NULL`。
-   每日快照必须保留标题和项目名称，不能依赖已删除的外键对象。

### 13.4 清理安全

提供：

-   清理预览。
-   清理执行结果。
-   受影响记录数量。
-   清理失败日志。
-   事务回滚。

不允许清理失败后继续删除剩余数据并假装成功。

------------------------------------------------------------------------

## 14. 备份与数据库升级

### 14.1 SQLite 备份方案

备份是数据可靠性要求，但自动备份的频率、轮转数量和默认启用方式仍待用户确认。

实施要求：
- 备份目录默认位于 `data/backups/`。
- 使用 `rusqlite::backup` 在线备份 API，或经验证可包含 WAL 状态的一致性快照方案；禁止简单复制正在运行的 `work.db` 作为可靠备份。
- 备份写入临时文件，完成后执行 `PRAGMA integrity_check`；验证通过后再原子重命名为正式备份。
- 恢复前保留当前数据库副本；恢复后执行完整性检查和 schema 版本检查。
- 备份文件是普通 SQLite 文件，不加密；必须如实提示并保存在 D 盘便携目录。
- 不得在备份文件名、日志或错误信息中写入客户信息或工作内容。


### 14.2 备份与保留期限的冲突

必须注意：

如果一个完整数据库备份保留了已完成工作，而主数据库已经按三个月规则删除该工作，那么备份仍可能让已到期数据继续存在。

因此"备份保留 7 天"并不能自动满足"数据必须按三个月/一年规则清理"。

需要明确：

-   备份是否属于数据保留范围。
-   清理到期数据时是否同步重建所有备份。
-   恢复旧备份后是否立即重新执行保留策略。
-   是否允许把备份导出到 D 盘之外。

### 14.3 数据库升级

使用版本化 migration：

``` text
migrations/
  0001_initial_schema.sql
  0002_add_focus_events.sql
  0003_add_daily_snapshots.sql
```

升级流程：

1.  验证当前数据库可正常打开。
2.  创建迁移前备份（如果备份策略已启用）。
3.  开启事务。
4.  按版本顺序执行 migration。
5.  更新 schema version。
6.  执行完整性和关键约束检查。
7.  提交事务。
8.  失败则回滚，保留原库和备份。

任何数据库迁移失败都不能自动创建空数据库覆盖旧数据。

------------------------------------------------------------------------

## 15. 测试与验收设计

采用 TDD 的 Red → Green → Refactor
原则，但测试必须围绕认可的业务接口，而不是内部实现细节。

### 15.1 关键测试边界

  测试边界             能捕获的问题
  -------------------- ---------------------------------------------
  WorkItemService      工作状态流转、完成/放弃规则、批量创建独立性
  DailyReviewService   复盘状态、逐项确认、补录、跳过规则
  FocusService         唯一当前工作、切换事件、待补充进度
  PriorityEngine       重要/紧急评分、手动置顶和稳定排序
  CalendarService      节假日、调休、上一个工作日
  ReportService        工作事项数与执行次数统计口径
  RetentionService     三个月/一年清理和快照保留
  Database             SQLite 打开、schema migration、事务、完整性检查和备份恢复
  PortableRuntime      D 盘目录、WebView2 数据目录、移动后恢复
  WindowsIntegration   托盘、开机启动、通知、文件打开

### 15.2 已完成的技术可行性验证

- Tauri 2 + Svelte 5 + Rust 在 Windows 10 实机运行，窗口和 IPC 往返通过。
- PortablePaths 已验证 EXE 路径解析、D 盘目录、目录移动和多种不可用/不可写异常。
- WebView2 已验证绝对 D 盘数据目录及 Cookie/LocalStorage 持久化。
- T0-02/T0-03 的物理拔盘、正式 D:/WorkManager 路径和 Process Monitor 级审计仍需在发布阶段补测。
- SQLCipher 和 DPAPI 不属于第一版技术路线，相关 T0-04/T0-05 已按 DEC-028 取消。
- 断网完整验证、托盘、开机启动和通知延期至发布阶段。

阶段 1 的新增技术测试以普通 SQLite 为基础：Windows Release 构建、migration、事务、外键、异常回滚、数据库完整性检查和一致性备份/恢复。

### 15.3 业务测试

必须覆盖：

-   一个工作事项连续跨多个工作日。
-   一项工作同一天多次补充详细日志。
-   同一标题关联多个项目后互不影响。
-   暂时跳过多次，历史事件不丢失。
-   完成当前工作后清空当前工作指针。
-   工作未执行不改变整体状态。
-   复盘跳过不放弃工作。
-   周末和调休工作日处理正确。
-   未完成复盘跨日继续。
-   无工作日正确生成空执行日报。
-   任务被清理后，每日快照仍可查询。
-   附件路径失效后不删除原文件。
-   备份恢复后数据库仍能通过完整性检查。

------------------------------------------------------------------------

## 16. 开发阶段与 Tracer-Bullet 任务

每个开发任务都必须贯穿
UI、IPC、业务层、数据库和测试，形成可以独立演示的纵向切片。

### 阶段 0：技术验证（已放行）

- [x] T0-01：Tauri 2 + Svelte 5 Windows 桌面壳。
- [x] T0-02：EXE 路径解析与 D 盘便携数据根目录（基础验证通过；发布阶段补测）。
- [x] T0-03：WebView2 绝对数据目录（基础验证通过；发布阶段补测）。
- [取消] T0-04：SQLCipher Windows 构建和错误密钥测试（DEC-028）。
- [取消] T0-05：DPAPI CurrentUser 密钥保护（DEC-028）。
- [延期至阶段 6] T0-06：断网完整流程由 T6-04 验收；托盘、开机启动、单实例和通知由 T6-07 验收。

### 阶段 1：基础数据和工作事项

- [ ] T1-01：正式工程骨架、便携路径接入与普通 SQLite 基础设施。
- [ ] T1-02：项目创建、编辑、归档。
- [ ] T1-03：工作事项快速创建和待安排区域。
- [ ] T1-04：多项目独立副本创建。
- [ ] T1-05：工作事项状态流转和历史记录。
- [取消] T1-06：六位数字应用密码与锁屏（DEC-028）。
- [ ] T1-07：首次初始化与 SQLite 异常保护。


### 阶段 2：计划、排序和当前工作

-   [ ] T2-01：每日计划创建和工作事项安排。
-   [ ] T2-02：全局自动优先级。
-   [ ] T2-03：手动置顶和全局排序持久化。
-   [ ] T2-04：每日计划独立排序。
-   [ ] T2-05：当前工作指针和切换事件。
-   [ ] T2-06：跳过工作后的待补充进度。

### 阶段 3：每日复盘和提醒

-   [ ] T3-01：中国大陆工作日历和手动覆盖。
-   [ ] T3-02：上一个工作日计算。
-   [ ] T3-03：逐项复盘和执行结果快照。
-   [ ] T3-04：计划外工作补录。
-   [ ] T3-05：无工作确认和整日跳过。
-   [ ] T3-06：上班时间开始提醒、每 5 分钟重复、18:30 停止；未完成则下个工作日续接。
-   [ ] T3-07：跨日未完成复盘恢复。

### 阶段 4：日志、搜索和报表

-   [ ] T4-01：详细工作日志追加。
-   [ ] T4-02：历史工作搜索。
-   [ ] T4-03：日报快照。
-   [ ] T4-04：周报统计。
-   [ ] T4-05：月报统计。
-   [ ] T4-06：工作事项数和每日执行次数双口径验证。

### 阶段 5：附件、清理和备份

-   [ ] T5-01：原始附件路径关联。
-   [ ] T5-02：附件存在性检查和重新选择。
-   [ ] T5-03：三个月工作档案清理。
-   [ ] T5-04：一年每日快照清理。
-   [ ] T5-05：普通 SQLite 一致性备份和恢复。
-   [ ] T5-06：迁移失败回滚和数据恢复验证。

### 阶段 6：发布

-   [ ] T6-01：绿色便携包构建。
-   [ ] T6-02：移动目录后启动项修复。
-   [ ] T6-03：D 盘写入审计。
-   [ ] T6-04：Windows 10 实机验收。
-   [ ] T6-05：安全和异常恢复测试。
-   [ ] T6-06：发布说明、许可证清单和用户数据说明。
-   [ ] T6-07：Windows 系统集成验收（托盘、开机启动启停与路径修复、单实例、纯便携提醒及用户主动启用的 Windows Toast）。

------------------------------------------------------------------------

## 17. 建议建立的 ADR

以下决策属于影响较大、后续变更成本较高的事项，建议用户确认后形成单独
ADR。

  -------------------------------------------------------------------------------------------
  ADR                     标题                               需要记录的决定
  ----------------------- ---------------------------------- --------------------------------
  ADR-0001                模块化单体与 Rust Core             为什么选择独立 Rust
                                                             Core，而不是把业务都写进 Tauri
                                                             commands

  ADR-0002                Rust 独占 SQLite 数据库访问        为什么不采用前端 SQL 插件

  ADR-0003                普通 SQLite 与本地数据边界           为什么第一版不实现应用密码和数据库加密

  ADR-0004                工作事项、每日计划和执行快照分离   为什么三类数据必须独立

  ADR-0005                便携数据根目录与 WebView2 绝对路径 为什么不使用默认 AppData

  ADR-0006                工作日期与时间戳分离               时区、工作日历和日报日期规则

  ADR-0007                复盘跳过不等于放弃工作             避免误操作造成生命周期变更

  ADR-0008                通知模式与便携版限制               Toast、托盘提醒和 C
                                                             盘快捷方式的取舍

  ADR-0009                数据保留和备份的一致性             防止备份绕过数据清理规则
  -------------------------------------------------------------------------------------------

------------------------------------------------------------------------

## 18. 风险清单

  -------------------------------------------------------------------------------------------
  风险                           等级                    应对
  ------------------------------ ----------------------- ------------------------------------
  便携版 Windows Toast 受限      高                      P0
                                                         验证；明确是否允许开始菜单快捷方式

  D 盘强约束与系统集成文件冲突   高                      路径审计；对所有 C 盘例外逐项授权

  普通 SQLite 文件未加密         已接受                  明确告知本机文件访问权限边界；数据库放在用户控制的 D 盘目录

  SQLite 备份不一致/无法恢复    高                      使用在线备份 API、完整性检查和实际恢复测试                           

  备份文件保留已到期数据         高                      清理策略必须覆盖备份

  日历和时区混用                 高                      工作日期使用 date-only；时区单独配置

  复盘跳过误放弃工作             高                      复盘状态与生命周期完全分离

  WebView2 默认路径写入 C 盘     高                      Rust builder 设置绝对目录；ProcMon
                                                         验证

  前端和 Rust DTO 不一致         中                      统一契约和编译测试

  大量无必要抽象                 中                      使用 Deep Modules；只有真实 seam
                                                         才引入 adapter
  -------------------------------------------------------------------------------------------

------------------------------------------------------------------------

## 19. 第一轮设计确认与待决事项

本节区分用户已确认的决定和仍待确认的问题。推荐方案不自动等于用户决定。

### Q1：Windows 开始菜单快捷方式

**已确认**

默认保持纯 D 盘便携模式。只有用户主动开启完整 Windows Toast 时，才创建必要的开始菜单快捷方式；创建前说明路径和用途，不得静默写入。

### Q2：整日跳过复盘

**已确认**

跳过复盘只修改 `daily_reviews.status`；不自动放弃工作。如果要放弃工作，另设独立操作并二次确认。

### Q3：工作日期和业务时区

**已确认**

固定使用 `Asia/Shanghai`，不跟随 Windows 当前时区变化。工作日历、上班时间、复盘日期和日报日期统一使用该业务时区。

### Q4：复盘提醒时机

**已确认**

在下一个工作日的设定上班时间开始复盘上一个工作日；每 5 分钟提醒一次，完成后停止，18:30 停止当日提醒；未完成则下一个工作日从断点继续。周一复盘周五，不为周六、周日单独创建复盘。

### Q5：新工作是否允许暂时不归属项目

**已确认**

允许。新工作默认可以进入未归属/待安排区域；批量选择多个项目时，每个项目生成独立工作事项副本。

### Q6：重要程度和紧急程度评分

**已确认**

重要程度和紧急程度均使用 1--5，初始评分为 `importance + urgency`。截止日期不参与自动排序；用户拖动全局列表后使用持久化手动置顶顺序。

### Q7：应用密码与数据库加密

**已确认（DEC-028，2026-11-17）**

第一版不实现六位数字应用密码、应用锁屏、SQLCipher 或 DPAPI。使用普通 SQLite，用户接受数据库文件未加密、拥有文件访问权限的人可以直接读取的风险。数据仍必须本地保存，不上传云端。

### Q8：开源代码使用边界

**已确认**

完全自研。可以研究开源项目的架构和产品行为，但不复制、移植或改写其源代码。

### Q9：D 盘备份策略

**待确认**

备份和恢复必须实现，但自动/手动备份方式、频率、轮转数量、恢复确认流程，以及备份中的过期数据如何同步清理，仍需用户确认。备份为普通 SQLite 文件，不加密。

### Q10：应用锁定后是否继续发送复盘提醒？

**已取消**

第一版不实现应用锁定；提醒仍应遵守通用通知隐私原则，不在系统通知中展示工作标题、客户或项目名称。

### Q11：重复工作

**待确认**

周期任务规则仍待确认。最终 UI 布局、主题和核心页面信息层级已由用户于 2026-11-18 按 DEC-030 确认，详见 [UI 设计规范](../design/UI-DESIGN-SPEC.md)。

## 20. 参考资料

### Matt Pocock Skills

-   [mattpocock-skills-zh-CN](https://github.com/vinvcn/mattpocock-skills-zh-CN)
-   [grill-with-docs](https://github.com/vinvcn/mattpocock-skills-zh-CN/tree/main/skills/engineering/grill-with-docs)
-   [domain-modeling](https://github.com/vinvcn/mattpocock-skills-zh-CN/tree/main/skills/engineering/domain-modeling)
-   [codebase-design](https://github.com/vinvcn/mattpocock-skills-zh-CN/tree/main/skills/engineering/codebase-design)
-   [research](https://github.com/vinvcn/mattpocock-skills-zh-CN/tree/main/skills/engineering/research)
-   [tdd](https://github.com/vinvcn/mattpocock-skills-zh-CN/tree/main/skills/engineering/tdd)
-   [to-tickets](https://github.com/vinvcn/mattpocock-skills-zh-CN/tree/main/skills/engineering/to-tickets)

### UI Design Skills

- [macos-design-skill](https://github.com/ceorkm/macos-design-skill)（MIT）：桌面应用布局、渐进式披露、系统原生集成。
- [claude-apple-design-system](https://github.com/rukkiecodes/claude-apple-design-system)（MIT）：语义化 Design Tokens、单一强调色、细分隔线和组件一致性。

仅借鉴设计原则，不复制代码、素材或组件实现。

### 开源项目

-   [PomeTodo](https://github.com/ShiliuX-Team/pometodo)
-   [Super
    Productivity](https://github.com/super-productivity/super-productivity)
-   [Chiri](https://github.com/chiriapp/chiri)
-   [Todofy](https://github.com/salarzeidanlou/todofy)
-   [svelte-dnd-action](https://github.com/isaacHagoel/svelte-dnd-action)
-   [Tauri + SvelteKit +
    SQLite](https://github.com/Lmedmo/Tauri-SvelteKit-SQLite)
-   [Tauri + SQLite +
    SQLx](https://github.com/tauritutorials/todo-sqlite-sqlx)

### 官方技术文档

-   [Tauri Windows
    prerequisites](https://v2.tauri.app/start/prerequisites/)
-   [Tauri
    WebviewWindowBuilder](https://docs.rs/tauri/latest/tauri/webview/struct.WebviewWindowBuilder.html)
-   [Tauri Windows
    notifications](https://v2.tauri.app/plugin/notification/)
-   [Tauri system tray](https://v2.tauri.app/learn/system-tray/)
-   [rusqlite online backup
    API](https://docs.rs/rusqlite/latest/rusqlite/backup/)
-   [Microsoft
    CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
-   [Microsoft
    CryptUnprotectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptunprotectdata)
-   [Microsoft desktop Toast
    AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/enable-desktop-toast-with-appusermodelid)

------------------------------------------------------------------------

**当前结论：** 本文 V0.3.2 已合并截至 2026-11-16 的用户确认决策，作为技术设计基线；自动备份、备份轮转与恢复策略等仍待确认。正式业务开发前必须完成 P0 技术验证。本文不代表功能已经实现，也不应被视为所有细节均已批准的最终架构。