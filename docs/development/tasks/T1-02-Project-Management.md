# T1-02：项目创建、编辑、归档

**任务状态：** 待审计（第一轮独立审计问题已修复并完成自测；等待第二轮独立审计，不得标记验收完成）  
**启动日期：** 2026-11-18  
**自测完成日期：** 2026-11-18  
**返工修复完成日期：** 2026-11-18  
**所属阶段：** 阶段 1：基础架构与工作事项  
**前置任务：** T1-01 已验收完成并已合并到 main  
**开发分支：** `task/T1-02-project-management`  
**目标分支：** `main`  
**Pull Request：** [#7](https://github.com/shuaikun853-dev/work-kanban/pull/7)（保持 Open，不合并）  
**测试报告：** [T1-02-REPORT.md](../../testing/reports/T1-02-REPORT.md)  
**返工修复报告：** [T1-02-AUDIT-FIX-REPORT.md](../../testing/reports/T1-02-AUDIT-FIX-REPORT.md)  
**机器可读证据：** [T1-02-evidence.json](../../testing/reports/T1-02-evidence.json)  
**返工修复机器可读证据：** [T1-02-AUDIT-FIX-evidence.json](../../testing/reports/T1-02-AUDIT-FIX-evidence.json)

## 1. 权威依据

开发前必须阅读并以以下文档为准：

1. `docs/requirements/PRD.md`
2. `docs/architecture/TECHNICAL_DESIGN.md`
3. `docs/decisions/DECISIONS.md`
4. `docs/design/UI-DESIGN-SPEC.md`
5. `docs/design/assets/workmanager-ui-prototype.svg`
6. `docs/development/DEVELOPMENT_PLAN.md`
7. `docs/STATUS.md`
8. `AGENTS.md`

如文档与当前代码冲突，先核对最新已确认决策；不得自行改变 PRD、DEC 决策或 UI 基线。

## 2. 本任务目标

交付“项目创建、编辑、归档”的完整纵向切片，包括：

- SQLite migration / 数据模型
- Rust Core 项目领域逻辑
- Tauri typed IPC / DTO
- Svelte UI
- 自动化测试
- Windows Release 实际运行验证
- GitHub 开发进度、测试证据和 PR

项目归档不得删除项目历史，也不得删除或自动修改其已有工作事项历史。

## 3. UI 实施范围

本任务正式开始 UI 业务开发，但**不得重新设计 UI**。

必须直接采用已确认的 UI 设计系统：

- 浅色桌面 UI；
- 已确认的 Design Tokens；
- 固定应用壳与左侧一级导航；
- Windows 原生桌面形态；
- 紧凑、模块化、信息密度克制；
- 通用组件、Feature 页面、typed Bridge 分层；
- 不增加未经确认的仪表盘、图表、统计卡片或装饰模块。

T1-02 至少完成：

1. 稳定的 AppShell / Sidebar / navigation 基础结构；
2. Design Tokens 和基础通用组件的最小集合；
3. 项目管理 Feature 页面；
4. 新建项目；
5. 编辑项目；
6. 归档项目；
7. 项目列表中的空状态、加载状态、错误状态；
8. 归档后的项目仍可用于历史数据展示，但不能作为新工作事项的正常可选项目（具体行为必须以 PRD/后续任务定义为准，不得提前扩展工作事项业务）。

**不要在本任务实现 T1-03 工作事项创建、T1-04 多项目创建或 T1-05 状态流转。**

### 3.1 全局窗口标题栏（DEC-032，UI Shell 前置切片）

- 按用户 2026-11-18 确认的 DEC-032，Windows 10 主窗口使用 Tauri 2 自定义无边框标题栏（`decorations: false`）。
- 红/黄/绿三个圆点分别真实调用关闭、最小化、最大化/还原窗口 API；保留拖动、双击最大化、窗口缩放、最小尺寸和键盘可访问性。
- 该切片在本次 T1-02 分支中保留并完成 Release 实测：最大化视口 1100→1920→1100；点击关闭按钮后进程真实退出（退出码 0）。

## 4. 数据与业务边界

- Rust Core 是项目状态和业务规则的唯一权威来源。
- 前端不得直接访问 SQLite。
- 不允许任意 SQL IPC。
- 项目 CRUD 必须通过 typed Bridge / DTO 调用 Rust Core。
- 项目 ID 必须稳定、不可使用前端数组下标作为业务身份。
- 项目归档必须保留项目记录及已有历史关联。
- 不得因为归档项目而删除、覆盖或重建已有工作历史。
- 不得提前实现工作事项、每日计划、复盘、报表等未授权业务。
- 不得引入新的云服务、遥测、账户体系或第三方同步能力。
- 不得引入未经授权的新依赖；如确有必要，先在报告中说明必要性、许可证、Windows 兼容性和替代方案。

## 5. Migration

T1-01 的 schema version 1 保持兼容。

本任务新增项目相关 migration，必须：

- 使用现有 migration 机制；
- 在事务中执行；
- 升级失败时回滚；
- 不修改或破坏已有数据库；
- 升级后执行完整性 / 外键检查；
- 新旧数据库均可正常启动。

项目表结构以技术设计中的项目模型为基础。未在 PRD/技术设计中定义的业务字段不要擅自扩展；如果实现确实需要新的纯技术字段，应在测试报告和 PR 中说明原因。

## 6. 测试要求

至少覆盖：

### Core / 数据库

- 创建项目成功；
- 查询项目；
- 编辑项目；
- 归档项目；
- 归档不删除项目记录；
- 归档不删除已有历史关联；
- 重启后项目数据保持；
- migration 从 T1-01 schema version 1 正确升级；
- migration 失败回滚；
- 非法/空项目名称等输入边界按正式业务规则处理；
- 多项目 CRUD 操作互不污染。

### UI / IPC

- 项目列表真实读取 Rust Core 数据；
- 新建、编辑、归档均通过 typed IPC；
- 加载 / 空状态 / 错误状态可见；
- 不存在任意 SQL IPC；
- AppShell / Sidebar / navigation 不破坏现有诊断页面；
- 长项目名称、无项目数据、归档项目等边界布局正常。

### Release

至少运行：

`cargo fmt --all -- --check`  
`cargo check --workspace --all-targets`  
`cargo test --workspace`  
`npm run check`  
`npm run build`  
`npm run tauri build -- --no-bundle`

并进行 Windows Release 实际运行验证。

UI 变更必须提供：

- 工作总览截图；
- 今日工作截图；
- 项目管理页面截图；
- 固定窗口尺寸和最小支持窗口尺寸检查；
- 无横向溢出、遮挡、错位、不可点击区域。

如果当前工作总览/今日工作仍未具备真实业务数据能力，不得伪造完成截图；可记录“结构回归截图/尚未接入业务数据”，并保持事实准确。

## 7. GitHub 交付

- 从最新 `main` 创建 `task/T1-02-project-management`；
- 不直接推送 `main`；
- 不修改或重写 T1-01 历史；
- 不开始 T1-03；
- 完成代码后提交测试报告：`docs/testing/reports/T1-02-REPORT.md`；
- 更新 `docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md` 和本任务说明；
- 推送任务分支；
- 创建 PR 指向 `main`；
- PR 合并前状态只能为“待审计”，不得自行标记“验收完成”。

最终报告必须提供：

- 实际实现范围；
- 修改文件；
- migration 版本；
- 测试命令、退出码、实际结果；
- Release SHA-256；
- commit SHA；
- PR 链接 / HEAD；
- UI 截图；
- 未覆盖测试；
- 遗留风险。

## 8. 明确禁止

- 不重新设计已经确认的 UI；
- 不把网页 UI 做成网页站点式布局；
- 不复制第三方项目代码；
- 不实现 T1-03/T1-04/T1-05；
- 不修改 PRD 和已确认 DEC；
- 不删除已有测试；
- 不降低测试标准；
- 不推送 main；
- 不合并自己的 PR；
- 不把“代码完成”写成“验收完成”。

**完成代码和自测后停止，等待独立审计。**

---

## 9. 实际交付结果（2026-11-18，待审计）

**代码提交：** `b8962b5`（Core + migration）、`2b3035d`（Tauri IPC）、`14a542e`（UI）、`30666c8`（验证脚本）。

**实际完成：**

- migration 0002：`projects` 表（id、name、is_archived、created_at、updated_at），schema version 1 → 2；T1-01 migration 历史未修改。
- Rust Core `projects/` 模块：模型、名称校验、参数化 SQL 仓储、应用服务、`IMMEDIATE` 写事务与失败回滚。
- Tauri typed IPC：`list_projects` / `create_project` / `update_project` / `archive_project`；请求 DTO 拒绝未知字段；无任意 SQL / 任意文件接口。
- 前端：Design Tokens、AppShell、Sidebar、navigation、typed Bridge、DTO Contracts；项目管理列表/新建/编辑/归档/loading/空/错误/长名称/归档态；诊断页迁移且功能不变。
- 归档为 UPDATE 标记，不删除项目记录；已归档项目只读并保留在列表；重复归档幂等。
- 测试：`cargo test --workspace` 90 passed / 0 failed；`npm run check` / `npm run build` / `cargo fmt --check` / `cargo check` 均通过。
- Release：`target\release\workmanager.exe` 10,230,272 字节，SHA-256 `DF4469EA067DEE39E10E49F0592FD4A9DAB076F4186FF3E8CF60F8F72EABB7E8`。
- Release UI/IPC：主检查 73/73、最小窗口 12/12（旧证据 JSON 因关闭按钮前写盘只持久化 11 项；该口径问题已在返工中修复）、关闭按钮真实退出；继承便携验证 106 项 0 FAIL、异常注入 73 项 0 FAIL；诊断页 24/24。
- 截图与日志：`docs/testing/reports/T1-02-assets/`。

**未实现（保持任务边界）：** T1-03 工作事项、T1-04 多项目副本、T1-05 状态流转、每日计划、复盘、报表、附件、备份恢复、TOCTOU 加固。

**结论：** 开发与自测完成，但第一轮独立审计发现 P2-01 UI Design Token 规范问题，**状态改为返工**。修复完成并重新审计通过前，不得标记验收完成，不合并 PR #7，不开始 T1-03。详见 `docs/testing/reports/T1-02-INDEPENDENT-AUDIT-REPORT.md`。


## 10. 第一轮独立审计结果（2026-11-18）

- **审计结论：未通过，进入小范围返工。**
- P2-01：项目 UI / 通用 UI 组件存在散落 raw hex/rgb/rgba 颜色值，未完全遵守 Design Token 规范。
- P3-01：`src-tauri/src/lib.rs` 存在过期的命令说明注释。
- P3-02：Release UI E2E 第一次独立运行出现一次空状态等待超时；立即重跑并随后连续 3 次完整运行通过，暂不认定为产品缺陷，但要求保留证据并考虑增强测试等待逻辑。
- 独立实测：`cargo test --workspace` 90 passed / 0 failed；`cargo fmt` / `cargo check` / `npm run check` / `npm run build` 全部退出码 0；Release SHA-256 与交付报告一致；便携 106 项、异常 73 项均 0 FAIL；Release UI E2E 在首次抖动后连续 4 次通过。
- PR #7 保持 Open，不合并；main 不修改；T1-03 不开始。
- 权威审计报告：`docs/testing/reports/T1-02-INDEPENDENT-AUDIT-REPORT.md`。

## 11. 返工修复结果（2026-11-18，待第二轮独立审计）

**当前状态：** **待审计**。第一轮独立审计 P2-01 / P3-01 / P3-02 已修复并完成重新自测；开发代理
不自行宣布审计通过或验收完成，第一轮独立审计报告未修改。

**修复内容：**

- **P2-01（Design Token）：** 审计点名 9 处原始颜色全部改为语义 Token；另把静态检查覆盖范围内
  同类散落颜色一并收敛，共 **32 处**（含 T1-01 诊断页 18 处、DEC-032 标题栏 4 处、`app.css` 1 处），
  新增 **20 个**语义 Token，取值与修改前渲染值一致（视觉无变化）；新增
  `scripts/quality/check-design-tokens.mjs` 静态检查与 `design-tokens.test.mjs` 8 项正反向测试，
  并接入 `npm run check`；实际检查 18 个文件、0 违规。
- **P3-01（过期注释）：** `src-tauri/src/lib.rs` 命令说明更新为数据库健康检查 + 项目 CRUD 5 个命令；
  未改命令注册、IPC 名称或 DTO。
- **P3-02（E2E 稳定性）：** 只改测试脚本——新增 reload 新文档 boot marker、应用壳 + Tauri IPC 就绪、
  项目 Loading 终态 4 项确定性等待，失败时写页面状态/IPC/异常/截图诊断 JSON；保留空状态断言；
  未改产品业务逻辑。最终 EXE 上 **连续 5 次完整 E2E 全部通过**（每次主检查 73/73、最小窗口 12/12）。
- **统计口径：** 主检查 73 项、最小窗口实际执行 12 项；旧证据 JSON 因“关闭按钮前写盘”只持久化
  11 项，审计报告 12/12 正确。返工后 12 项全部进入证据 JSON，编排脚本另行验证进程真实退出。

**回归结果（最终 EXE）：** `cargo fmt --check` / `cargo check` / `cargo test`（90 passed） /
`npm run check` / `npm run build` / Release 构建全部退出码 0；便携 106 项、异常注入 73 项 0 FAIL；
诊断页 24/24；CSP 0；未捕获异常 0。Release EXE 10,230,784 字节，
SHA-256 `51BBBA8DD17103D742E1BD4A85B83377F7578D34584F2206F30EDFEC8D3DC7F6`。

**证据：** [T1-02-AUDIT-FIX-REPORT.md](../../testing/reports/T1-02-AUDIT-FIX-REPORT.md)、
[T1-02-AUDIT-FIX-evidence.json](../../testing/reports/T1-02-AUDIT-FIX-evidence.json)、
[T1-02-AUDIT-FIX-assets/](../../testing/reports/T1-02-AUDIT-FIX-assets/README.md)。

**未开始/未修改：** T1-03 未开始；PRD、DEC-028～DEC-032、UI 布局、三色窗口按钮、项目业务逻辑、
T1-01 基础架构、migration 历史均未修改；main 未修改；PR #7 未合并。
