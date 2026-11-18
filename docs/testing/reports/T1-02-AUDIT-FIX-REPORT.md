# T1-02 第一轮独立审计问题修复报告

**任务 ID：** T1-02
**任务名称：** 项目创建、编辑、归档
**所属阶段：** 阶段 1：基础架构与工作事项
**任务状态：** **待审计**（第一轮独立审计问题已修复并完成自测；等待第二轮独立审计，不得视为验收完成）
**报告日期：** 2026-11-18
**开发分支：** `task/T1-02-project-management`
**目标分支：** `main`（未修改、未合并）
**Pull Request：** [#7](https://github.com/shuaikun853-dev/work-kanban/pull/7)（保持 Open，不合并）
**审计报告（不修改）：** [T1-02-INDEPENDENT-AUDIT-REPORT.md](T1-02-INDEPENDENT-AUDIT-REPORT.md)
**第一轮审计基准 HEAD：** `a0aec0032cf3c3ef3ab87513ae93f7a4f4351f69`
**本次返工起点 HEAD：** `54f025d0e2d4c95a53604e3d05b6e6764236e600`（仅状态文档对齐提交）
**机器可读修复证据：** [T1-02-AUDIT-FIX-evidence.json](T1-02-AUDIT-FIX-evidence.json)
**证据资产目录：** [T1-02-AUDIT-FIX-assets/](T1-02-AUDIT-FIX-assets/README.md)
**任务测试报告（已同步更新）：** [T1-02-REPORT.md](T1-02-REPORT.md)

> 本报告记录开发代理对第一轮独立审计发现问题的修复与重新自测结果。
> 独立审计报告是独立审计方维护的历史记录，本次未修改其任何内容。
> 开发代理不得自行宣布独立审计通过或用户验收完成；当前状态只能为“待审计”。

---

## 1. 修复范围

第一轮独立审计结论为“未通过，进入小范围返工”，阻塞项与建议项：

| 编号 | 优先级 | 问题 | 本次处理 |
|---|---|---|---|
| P2-01 | P2 | Feature/UI 组件仍存在 Design Token 之外的原始颜色值 | **已修复**；另外补齐静态检查覆盖范围内同类问题，并新增自动化静态检查 + 正反向测试 |
| P3-01 | P3 | `src-tauri/src/lib.rs` 存在过期命令说明注释 | **已修复**；只改注释，不改命令注册、IPC 或 DTO |
| P3-02 | P3 | Release UI E2E 首次运行出现一次 `projects empty state` 等待超时 | **已修复测试等待与诊断策略**；未修改产品业务逻辑；5 次连续完整 E2E 全部通过 |
| 统计口径 | — | 最小窗口测试 11/11 与 12/12 两种记录并存 | **已核实并统一**：脚本实际执行 12 项；旧证据 JSON 因“点击关闭按钮前写盘”只持久化 11 项，已修复脚本与编排统计 |

本次没有修改 PRD、DEC-028～DEC-032、UI 布局、三色窗口控制按钮、项目创建/编辑/归档业务逻辑、
T1-01 已验收基础架构、migration 历史；没有新增 SQL IPC；没有开始 T1-03；没有修改 main 或合并 PR。

---

## 2. P2-01：Design Token 原始颜色修复

### 2.1 审计指出的 9 处已全部消除

| # | 文件 | 原原始颜色 | 替换为语义 Token |
|---|---|---|---|
| 1 | `src/app/Sidebar.svelte` | `rgba(0, 122, 255, 0.07)` | `--color-nav-hover-bg` |
| 2 | `src/lib/features/projects/ConfirmArchiveDialog.svelte` | `rgba(15, 23, 42, 0.28)` | `--color-backdrop` |
| 3 | `src/lib/features/projects/ConfirmArchiveDialog.svelte` | `#f3c6c1` | `--color-danger-border` |
| 4 | `src/lib/features/projects/ProjectFormDialog.svelte` | `rgba(15, 23, 42, 0.28)` | `--color-backdrop` |
| 5 | `src/lib/features/projects/ProjectFormDialog.svelte` | `#f3c6c1` | `--color-danger-border` |
| 6 | `src/lib/features/projects/ProjectsPage.svelte` | `#f3c6c1` | `--color-danger-border` |
| 7 | `src/lib/ui/components/Button.svelte` | `#ffffff`（primary 文字） | `--color-text-inverse` |
| 8 | `src/lib/ui/components/Button.svelte` | `rgba(255, 255, 255, 0.45)`（spinner 轨道） | `--color-spinner-track-inverse` |
| 9 | `src/lib/ui/components/Button.svelte` | `#ffffff`（spinner 头部） | `--color-text-inverse` |

### 2.2 补齐静态检查覆盖范围内的同类散落颜色

P2-01 要求“禁止在 Feature 页面和通用 UI 组件中散落原始颜色”，且静态检查不得通过忽略整个
Feature/通用组件目录来绕过检查。因此除审计点名的 9 处外，本次把新的静态检查实际扫描到的同类问题
全部收敛到 Token（**只替换颜色取值来源，不改布局、字号、间距或交互**）：

| 文件 | 收敛数量 | 说明 |
|---|---:|---|
| `src/app/Sidebar.svelte` | 1 | 审计已点名 |
| `src/lib/features/projects/ConfirmArchiveDialog.svelte` | 2 | 审计已点名 |
| `src/lib/features/projects/ProjectFormDialog.svelte` | 2 | 审计已点名 |
| `src/lib/features/projects/ProjectsPage.svelte` | 1 | 审计已点名 |
| `src/lib/ui/components/Button.svelte` | 3 | 审计已点名 |
| `src/lib/WindowTitlebar.svelte` | 4 | 标题栏背景（复用 `--color-titlebar`）+ DEC-032 三色圆点（新增固定语义 Token） |
| `src/lib/features/diagnostics/DiagnosticsPage.svelte` | 18 | T1-01 诊断页既有样式，取值逐项保留，仅改由 Token 提供 |
| `src/app.css` | 1 | `::selection` 选择背景 |
| **合计** | **32 处** | 组件/UI CSS 中已无 raw hex/rgb/rgba（中央 Token 文件除外） |

诊断页映射（取值全部保持原值）：

| 原值 | Token | 用途 |
|---|---|---|
| `#334155`（3 处） | `--color-code-text` | 行内代码、路径、migration 名等宽文本 |
| `#ffffff` | `--color-text-inverse` | 强调色/危险色实底上的文字与图标 |
| `#ffffff` | `--color-surface` | 错误码 chip 的白色底 |
| `#1e3a8a` | `--color-focus-ring-strong` | 强调色实底按钮上的深色焦点环 |
| `rgba(255, 255, 255, 0.42)` | `--color-spinner-track-inverse-soft` | 诊断页按钮 spinner 轨道（保留 T1-01 历史值） |
| `#cbd5e1` | `--color-spinner-track` | 浅色底加载 spinner 轨道 |
| `#f3c6c1` | `--color-danger-border` | 错误面板边框 |
| `#f0b4ad` | `--color-danger-border-strong` | 错误码 chip 边框 |
| `#7f1d1d` | `--color-danger-text-strong` | 错误详情文字 |
| `#bfe8cc` | `--color-success-border` | 成功徽标边框 |
| `#f2d9a5` | `--color-warning-border` | 警告徽标边框 |
| `#4b5563` | `--color-text-secondary-strong` | 比次级文字更强的说明文字 |
| `#eef1f6` | `--color-divider-subtle` | 表格行细分隔线 |
| `#fbfcfe` | `--color-surface-hover` | 表格行悬停背景（与标题栏背景语义不同，未合并） |

### 2.3 中央 Design Token 文件新增定义

文件：`src/lib/ui/tokens.css`（颜色唯一来源，允许保留原始色值）。新增 20 个语义 Token：

| Token | 值 | 语义用途 |
|---|---|---|
| `--color-backdrop` | `rgba(15, 23, 42, 0.28)` | 模态遮罩 |
| `--color-nav-hover-bg` | `rgba(0, 122, 255, 0.07)` | 侧边导航悬停背景 |
| `--color-selection-bg` | `rgba(0, 122, 255, 0.18)` | 文本选择背景 |
| `--color-text-inverse` | `#ffffff` | 强调色/危险色实底上的反向文字与图标 |
| `--color-spinner-track-inverse` | `rgba(255, 255, 255, 0.45)` | 强调色按钮内 spinner 轨道 |
| `--color-spinner-track-inverse-soft` | `rgba(255, 255, 255, 0.42)` | T1-01 诊断页既有 spinner 轨道（保留原值，不强行合并） |
| `--color-spinner-track` | `#cbd5e1` | 浅色底加载 spinner 轨道 |
| `--color-danger-border` | `#f3c6c1` | 错误面板/错误提示边框 |
| `--color-danger-border-strong` | `#f0b4ad` | 错误码等强错误边框 |
| `--color-danger-text-strong` | `#7f1d1d` | 错误详情强文字 |
| `--color-success-border` | `#bfe8cc` | 成功状态徽标边框 |
| `--color-warning-border` | `#f2d9a5` | 警告状态徽标边框 |
| `--color-text-secondary-strong` | `#4b5563` | 较强次级说明文字 |
| `--color-code-text` | `#334155` | 等宽代码/路径文本 |
| `--color-divider-subtle` | `#eef1f6` | 表格行细分隔线 |
| `--color-surface-hover` | `#fbfcfe` | 表格行悬停背景 |
| `--color-focus-ring-strong` | `#1e3a8a` | 强调色实底按钮焦点环 |
| `--color-window-close` | `#ff5f57` | DEC-032 关闭圆点 |
| `--color-window-minimize` | `#febc2e` | DEC-032 最小化圆点 |
| `--color-window-maximize` | `#28c840` | DEC-032 最大化/还原圆点 |

### 2.4 视觉效果保持

- 每个替换 Token 的取值与替换前组件实际渲染值**逐字节一致**；没有合并不同语义的颜色。
- 两个 spinner 轨道 Token（0.45 / 0.42）分别保留新按钮与 T1-01 诊断页的既有视觉，避免任何
  可感知的 alpha 变化。
- 没有删除样式、组件或断言；没有把颜色转移到其它组件/内联样式/其它文件。
- 修改后 Release UI E2E 每次都重新截图（应用壳、项目管理、诊断页、最小窗口、弹窗等），
  与修复前基线截图对照未发现布局或颜色差异；截图见
  [T1-02-AUDIT-FIX-assets/screenshots/](T1-02-AUDIT-FIX-assets/screenshots/)。

---

## 3. 新增自动化 Design Token 静态检查

### 3.1 检查实现

新增 `scripts/quality/check-design-tokens.mjs`（Node.js 标准库实现，零新增依赖）：

- 扫描范围：
  - `src/**/*.svelte` 的 `<style>` 块；
  - `src/**/*.svelte` 的静态内联 `style="..."` / `style='...'` 属性；
  - `src/**/*.css` 的全部样式声明。
- 唯一豁免文件：`src/lib/ui/tokens.css`（中央 Design Token 定义文件）。
- **没有任何目录级豁免**：Feature 页面、通用 UI 组件、`app.css` 全部纳入扫描。
- 识别 HEX（3/4/6/8 位）、`rgb()`/`rgba()`、`hsl()`/`hsla()`。
- 去除 CSS/HTML 注释后再匹配，避免注释误报；违规输出 `文件:行:列 类型 原始值`。
- 退出码：`0` 通过；`1` 发现违规；`2` 无法执行（根目录/`src` 不存在或未扫描到文件），
  不会在错误路径上静默通过。
- 支持 `--root <dir>` 与 `--report <file>`（机器可读 JSON）。

### 3.2 检查自身自动化测试

新增 `scripts/quality/design-tokens.test.mjs`（Node.js 内置 `node:test`，零新增依赖），8 项测试：

1. 使用 Design Token 的组件与 CSS 通过检查；
2. Svelte `<style>` 块中的 HEX 原始颜色导致检查失败；
3. 内联 `style` 属性中的 RGBA 原始颜色导致检查失败；
4. Feature/UI CSS 文件中的 RGB/HSL 原始颜色不会被目录豁免；
5. 中央 Token 定义文件中的原始颜色不会被误报；
6. 检查报告包含可复核的文件、行号、类型与原始值；
7. `--root` 不存在 `src/` 时以错误码 2 失败而不是静默通过；
8. 真实仓库当前代码通过静态检查。

实际执行结果：**8/8 PASS**（日志 [design-token-tests.log.txt](T1-02-AUDIT-FIX-assets/logs/design-token-tests.log.txt)）。

### 3.3 接入质量流程

`package.json` 更新（不引入新依赖）：

```json
"check": "svelte-check --tsconfig ./tsconfig.json && npm run check:design-tokens && npm run test:design-tokens",
"check:design-tokens": "node scripts/quality/check-design-tokens.mjs",
"test:design-tokens": "node --test scripts/quality/design-tokens.test.mjs"
```

因此 `npm run check` 现在同时执行：Svelte 类型检查 → Design Token 静态检查 → 静态检查正反向测试。
任一失败即整体失败。

### 3.4 实际检查结果

- `DESIGN_TOKEN_CHECK=PASS files=18 violations=0 tokenFile=src/lib/ui/tokens.css`
- 机器可读报告：[design-token-check.json](T1-02-AUDIT-FIX-assets/design-token-check.json)
  （18 个文件、0 违规、含逐文件扫描清单）。
- 日志：[design-token-check.log.txt](T1-02-AUDIT-FIX-assets/logs/design-token-check.log.txt)。

**已知边界（不夸大）：** 本检查针对静态样式声明；Svelte `style:` 指令、由脚本动态计算的颜色、
`<script>` 内的颜色字符串不在静态扫描范围内。当前代码不存在这些用法；如未来出现，应在对应任务中扩展
检查或改用 Token。

---

## 4. P3-01：Tauri 命令说明注释修复

文件：`src-tauri/src/lib.rs`。

修复前：

```rust
//! - 暴露最小受限命令（目前只有数据库健康检查）；
```

修复后：

```rust
//! - 暴露最小受限命令：数据库健康检查（T1-01）与项目列表/创建/编辑/归档（T1-02），
//!   完整注册列表见 [`run`] 中的 `tauri::generate_handler!`；
```

- 实际命令注册列表核对为 5 个：`get_database_health`、`list_projects`、`create_project`、
  `update_project`、`archive_project`。
- 本次**未修改**任何命令注册、IPC 名称、参数/返回 DTO 或业务逻辑；仅更新注释。
- `cargo fmt --all -- --check`、`cargo check --workspace --all-targets`、
  `cargo test --workspace` 均通过（见第 6 节）。

---

## 5. P3-02：Release UI E2E 空状态等待稳定性修复

### 5.1 问题调查结论

按审计要求逐项检查：

1. **项目管理页面初始化流程：** `ProjectsPage` 在 `onMount` 调用 `loadProjectList(true)`，
   设置 `loading = true`；成功/失败/空列表最终都会在 `finally` 中 `loading = false`。
2. **Loading 状态切换逻辑：** 所有分支（成功 / IPC 错误 / 契约错误）都进入终态，
   不存在“永久 Loading”的产品代码路径。
3. **空状态渲染条件：** `projects !== null && projects.length === 0`，只有在 IPC 返回后才渲染；
   产品逻辑本身没有竞态。
4. **旧 E2E 等待逻辑：** 旧脚本在点击“打开项目管理”后直接轮询
   `document.body.innerText.includes('暂无项目')`（12 秒）；没有等待“应用壳 + Tauri IPC 就绪”，
   也没有区分 Loading / 空 / 列表 / 错误终态；并且 `Page.reload` 后可能先对旧文档做判断，
   存在新旧文档切换与首次 WebView2 冷启动的观察时序竞争。
5. **测试数据库初始化时机：** Rust 在创建主窗口前完成便携路径与数据库初始化；
   每次运行使用独立 `D:\WorkManager-test-data` 输出目录，未发现测试数据库与页面读取数据不一致。
6. **IPC 数据加载与前端渲染竞态：** 产品侧未发现竞态；问题在于测试观察时机（在终态出现前就判定失败），
   且失败时没有页面状态/IPC 诊断信息，难以定位。

**根因判断：** 现有证据不足以认定为产品功能缺陷；本次按“测试等待策略 + 观测时序”问题处理。
第一轮审计首次失败更符合测试脚本等待逻辑与首次运行环境时序抖动，而不是业务逻辑错误。该判断的
置信度受以下证据限制：机器 WebView2 已预热，本轮 2 次基线脚本复现尝试均通过，无法复现当次失败；
历史第一次失败运行的原始日志不在仓库中（只有审计报告记录）。详见
[T1-02-INDEPENDENT-AUDIT-REPORT.md](T1-02-INDEPENDENT-AUDIT-REPORT.md) 第 2.1 节。

### 5.2 修复内容（只改测试脚本，不改产品代码）

`scripts/verify/inspect-t1-02-ui.mjs`：

1. **新文档 boot marker 确定性等待：** 在 `addScriptToEvaluateOnNewDocument` 注入唯一 marker，
   主动 reload 后必须匹配 marker 且 `readyState === 'complete'`，才继续断言，消除“旧文档仍存活”
   的观察窗口。
2. **应用壳 + Tauri IPC 就绪等待：** 等待 `.app-shell`、6 个导航按钮与
   `window.__TAURI_INTERNALS__.invoke` 存在，再直接调用 `get_database_health` 确认 IPC 与 schema v2
   真实可用后才进入页面断言。
3. **项目页确定性终态等待：** 新增 `waitForProjectsSettled()`，先等待项目管理页面 Loading 结束，
   再一次性读取终态（空 / 列表 / 错误），然后断言空状态；`projects.emptyStateRendered` 断言保留。
4. **超时保留诊断：** `waitFor` 超时会输出最后一次页面状态；脚本异常时新增
   `captureFailureDiagnostics()`，写入 `t1-02-ui-failure-*.json`（页面文本、标题、loading/error 标志、
   项目行数、Tauri internals、`list_projects`/`get_database_health` IPC 结果、页面异常、截图）。
5. **证据记录：** 证据 JSON 增加 `bootMarker` 与 `deterministicWaits`
   （本次实际为 `page.reloadNewDocumentBootMarker`、`appShell.renderedWithTauriInternals`、
   `ipc.databaseHealthReady`、`projectsPage.loadingSettled`）。

`scripts/verify/inspect-t1-02-min-window.mjs`：

- 等待应用壳时增加 `document.readyState === 'complete'` 条件；
- 关闭按钮点击后，由 Node 进程（页面销毁不影响 Node）把包含 `minWindow.closeButtonClicked` 的
  **12 项断言**写入证据 JSON；进程真实退出仍由编排脚本通过 ExitCode 独立验证。

`scripts/verify/verify-t1-02-ui.ps1`：

- 从两份证据 JSON 直接读取断言数量与失败数写入编排摘要，避免人工抄写统计口径；
- 记录 `mainUiCheckCount`、`mainUiFailedCheckCount`、`minWindowCheckCount`、
  `minWindowFailedCheckCount`、`closeButtonCheckPassed`、`closeExitCode`；
- 证据缺失或关闭按钮断言未记录时判失败。

没有修改产品业务逻辑；没有删除空状态断言；没有跳过/忽略错误；没有自动重试；没有无限延长超时；
超时时间仍为有限值（启动/IOC 就绪 20–30 秒、项目终态 20 秒）。

### 5.3 P3-02 验证结果

- 使用重建后的最终 Release EXE，**连续执行 5 次完整 Release UI/IPC E2E，5/5 全部通过**；
  每次均为主检查 **73/73**、最小窗口 **12/12**、CSP 违规 **0**、页面未捕获异常 **0**、
  关闭按钮后进程退出码 **0**、`projects.emptyStateRendered` PASS。
- 每次运行均保留完整日志与机器可读证据（不是只保留 PASS 摘要）：
  - 日志：`T1-02-AUDIT-FIX-assets/logs/verify-t1-02-ui-run1..5.log.txt`；
  - 证据：`T1-02-AUDIT-FIX-assets/evidence/run1..run5/`；
  - 截图：`T1-02-AUDIT-FIX-assets/screenshots/run1..run5/`。
- 历史第一次失败的记录继续保留在第一轮独立审计报告中，未删除、未改写。
- 另外保留根因调查探针证据（基线脚本 2 次运行均通过、未复现；修改后脚本冒烟 1 次通过；
  返工过程中一次脚本编码失败记录）见
  [T1-02-AUDIT-FIX-assets/evidence/p3-02-probe/](T1-02-AUDIT-FIX-assets/evidence/p3-02-probe/README.md)。

---

## 6. 统计口径核实与统一

### 6.1 主检查：73 项

- 脚本成功路径实际执行 73 条断言；旧证据 `t1-02-ui-evidence.json` 的 `checks` 数组为 73，
  审计报告 73/73 正确。73 不是静态 `check(` 调用点数（直接调用 66 次 + `checkNoOverflow` 辅助
  函数内 1 次 × 调用 7 次 = 73），因此不存在“脚本写多/日志写少”的不一致。
- 本次修复后 5 次运行仍为 73/73，未新增/删除/降低断言。

### 6.2 最小窗口：12 项（11 + 1 口径差异已统一）

- 旧脚本成功路径实际执行 12 条断言，但证据 JSON 在点击关闭按钮**之前**写盘，只持久化了前 11 条；
  第 12 条 `minWindow.closeButtonClicked` 只出现在日志、退出码与编排证据中。
- 因此：开发报告/证据 JSON 的 **11/11 = “JSON 持久化口径”**；审计报告的 **12/12 = “实际执行口径”**。
  两者不是矛盾数字，而是两种口径；审计报告 12/12 正确。
- 本次修复后脚本在点击关闭按钮之后再写证据（Node 进程不随页面销毁退出），**12 项断言全部进入
  `t1-02-min-window-evidence.json`**；编排脚本同时记录 `closeExitCode` 验证进程真实退出。
  5 次运行均为 **12/12**。
- 没有删除断言，也没有降低标准；关闭按钮断言与进程退出验证都保留。

### 6.3 其它统计核对

- `cargo test --workspace`：**90 passed / 0 failed / 0 ignored**，与第一轮审计一致。
- `verify-release-portable.ps1`：**106 项 = PASS 90 / FAIL 0 / WARN 1 / INFO 15**；唯一 WARN 仍是
  验证开始前已存在的 `%LOCALAPPDATA%\EBWebView` 历史目录（非本次创建，时间戳未变）。
- `verify-release-faults.ps1`：**73 项 = PASS 64 / FAIL 0 / WARN 0 / INFO 9**。
- T1-01 诊断页 UI 回归：**24/24**。
- 第一轮审计报告中的“首次失败 → 立即重跑通过 → 随后连续 3 次通过”共 4 次成功运行：
  仓库内没有这些运行的原始日志，只能引用审计报告历史记录（无法独立复核），已在
  [T1-02-INDEPENDENT-AUDIT-REPORT.md](T1-02-INDEPENDENT-AUDIT-REPORT.md) 原样保留。
- 本次返工自测：**5 次连续完整 E2E 全部通过，每次日志与证据均已归档**。

---

## 7. 完整回归测试结果

### 7.1 测试环境

| 项目 | 值 |
|---|---|
| 操作系统 | Windows 10 家庭中文版 10.0.19045（build 19045） |
| Rust | rustc 1.100.0 (0ef1bc386 2026-11-09) / cargo 1.100.0 (3acc79c0c 2026-11-05) |
| Node / npm | v22.20.0 / 10.9.3 |
| PowerShell | Windows PowerShell 5.1.19041.6456 |
| 测试数据目录 | `D:\WorkManager-test-data`（隔离；正式目录 `D:\WorkManager` 未触碰） |
| Release | `target\release\workmanager.exe`，**10,230,784 字节**，SHA-256 **`51BBBA8DD17103D742E1BD4A85B83377F7578D34584F2206F30EDFEC8D3DC7F6`** |

### 7.2 逐命令结果

| 命令 | 退出码 | 实际结果 | 日志 |
|---|---:|---|---|
| `cargo fmt --all -- --check` | 0 | PASS（无输出） | [cargo-fmt-check.log.txt](T1-02-AUDIT-FIX-assets/logs/cargo-fmt-check.log.txt) |
| `cargo check --workspace --all-targets` | 0 | PASS（`Finished dev profile`，无 warning） | [cargo-check.log.txt](T1-02-AUDIT-FIX-assets/logs/cargo-check.log.txt) |
| `cargo test --workspace` | 0 | **90 passed / 0 failed / 0 ignored** | [cargo-test-workspace.log.txt](T1-02-AUDIT-FIX-assets/logs/cargo-test-workspace.log.txt) |
| `npm run check` | 0 | svelte-check **0 errors / 0 warnings**；Design Token 检查 PASS（18 文件 / 0 违规）；Token 测试 **8/8** | [npm-check.log.txt](T1-02-AUDIT-FIX-assets/logs/npm-check.log.txt) |
| `npm run build` | 0 | Vite 构建成功（156 modules；JS 96.13 kB / CSS 26.89 kB） | [npm-build.log.txt](T1-02-AUDIT-FIX-assets/logs/npm-build.log.txt) |
| `npm run tauri build -- --no-bundle` | 0 | Release 构建成功 | [tauri-build.log.txt](T1-02-AUDIT-FIX-assets/logs/tauri-build.log.txt) |
| `node scripts/quality/check-design-tokens.mjs --report ...` | 0 | **DESIGN_TOKEN_CHECK=PASS files=18 violations=0** | [design-token-check.log.txt](T1-02-AUDIT-FIX-assets/logs/design-token-check.log.txt) |
| `node --test scripts/quality/design-tokens.test.mjs` | 0 | **8/8 PASS**（正反向） | [design-token-tests.log.txt](T1-02-AUDIT-FIX-assets/logs/design-token-tests.log.txt) |
| `verify-release-portable.ps1` | 0 | **TOTAL=106 PASS=90 FAIL=0 WARN=1 INFO=15** | [verify-release-portable.log.txt](T1-02-AUDIT-FIX-assets/logs/verify-release-portable.log.txt) |
| `verify-release-faults.ps1` | 0 | **TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9** | [verify-release-faults.log.txt](T1-02-AUDIT-FIX-assets/logs/verify-release-faults.log.txt) |
| `verify-t1-02-ui.ps1`（连续 5 次） | 0 ×5 | 每次 **主检查 73/73 + 最小窗口 12/12**；CSP 0；未捕获异常 0；closeExitCode 0 | [run1](T1-02-AUDIT-FIX-assets/logs/verify-t1-02-ui-run1.log.txt) / [run2](T1-02-AUDIT-FIX-assets/logs/verify-t1-02-ui-run2.log.txt) / [run3](T1-02-AUDIT-FIX-assets/logs/verify-t1-02-ui-run3.log.txt) / [run4](T1-02-AUDIT-FIX-assets/logs/verify-t1-02-ui-run4.log.txt) / [run5](T1-02-AUDIT-FIX-assets/logs/verify-t1-02-ui-run5.log.txt) |
| `inspect-release-ui.mjs`（T1-01 诊断页） | 0 | **24/24**，进程退出码 0 | [inspect-release-ui.log.txt](T1-02-AUDIT-FIX-assets/logs/inspect-release-ui.log.txt) |

### 7.3 Release UI/IPC 逐次结果

| 运行 | 主检查 | 最小窗口 | closeButtonCheck | closeExitCode | CSP | 未捕获异常 | 证据 |
|---|---:|---:|---|---:|---:|---:|---|
| run1 | 73/73 | 12/12 | true | 0 | 0 | 0 | [run1](T1-02-AUDIT-FIX-assets/evidence/run1/t1-02-ui-orchestration.json) |
| run2 | 73/73 | 12/12 | true | 0 | 0 | 0 | [run2](T1-02-AUDIT-FIX-assets/evidence/run2/t1-02-ui-orchestration.json) |
| run3 | 73/73 | 12/12 | true | 0 | 0 | 0 | [run3](T1-02-AUDIT-FIX-assets/evidence/run3/t1-02-ui-orchestration.json) |
| run4 | 73/73 | 12/12 | true | 0 | 0 | 0 | [run4](T1-02-AUDIT-FIX-assets/evidence/run4/t1-02-ui-orchestration.json) |
| run5 | 73/73 | 12/12 | true | 0 | 0 | 0 | [run5](T1-02-AUDIT-FIX-assets/evidence/run5/t1-02-ui-orchestration.json) |

每次运行的主检查证据（73 项 checks、`deterministicWaits`、`pageErrors`）与最小窗口证据
（12 项 checks、`closeClicked`）分别见对应 `evidence/runN/` 目录；5 次运行的 EXE SHA-256
均与最终 Release 一致（`51bbba8d…356ee`）。

完整回归编排汇总：[regression-summary.json](T1-02-AUDIT-FIX-assets/regression-summary.json)
（`overallPass=true`）。

### 7.4 测试数量变化说明

| 项目 | 第一轮审计时 | 本次返工后 | 变化原因 |
|---|---:|---:|---|
| Rust 测试 | 90 | 90 | 未新增/删除 |
| 主 UI/IPC 断言 | 73 | 73 | 未新增/删除/降低 |
| 最小窗口断言 | 12（实际执行） | 12 | 未新增/删除；改为 12 项全部持久化到证据 JSON |
| 便携验证 | 106 | 106 | 未变化 |
| 异常注入 | 73 | 73 | 未变化 |
| T1-01 诊断页 UI | 24 | 24 | 未变化 |
| Design Token 静态检查 | 0 | 新增 1 项检查 + 8 项自测 | P2-01 要求新增自动化检查 |
| Release UI E2E 归档运行次数 | 历史 4 次成功（无原始日志） | 本次 5 次连续成功（日志+证据齐全） | P3-02 要求连续至少 5 次并保留日志 |

---

## 8. 修改文件清单

### 8.1 代码 / 测试 / 脚本

| 文件 | 修改原因 | 主要修改 | 涉及业务逻辑 | 影响既有功能 |
|---|---|---|---|---|
| `src/lib/ui/tokens.css` | P2-01 | 新增 20 个语义颜色 Token（值与既有渲染值一致） | 否 | 否（视觉等价） |
| `src/app/Sidebar.svelte` | P2-01 | 导航悬停背景改用 Token | 否 | 否 |
| `src/app.css` | P2-01 | `::selection` 背景改用 Token | 否 | 否 |
| `src/lib/WindowTitlebar.svelte` | P2-01 | 标题栏背景复用 Token；三色圆点改用固定语义 Token | 否 | 否（颜色值不变） |
| `src/lib/features/diagnostics/DiagnosticsPage.svelte` | P2-01 | 18 处颜色改用 Token（取值不变） | 否 | 否（视觉等价） |
| `src/lib/features/projects/ConfirmArchiveDialog.svelte` | P2-01 | 遮罩与错误边框改用 Token | 否 | 否 |
| `src/lib/features/projects/ProjectFormDialog.svelte` | P2-01 | 遮罩与错误边框改用 Token | 否 | 否 |
| `src/lib/features/projects/ProjectsPage.svelte` | P2-01 | 错误面板边框改用 Token | 否 | 否 |
| `src/lib/ui/components/Button.svelte` | P2-01 | 主按钮文字与 spinner 改用 Token | 否 | 否 |
| `src-tauri/src/lib.rs` | P3-01 | 更新过期命令说明注释 | 否 | 否 |
| `package.json` | P2-01 | 接入 Token 静态检查与自测到 `npm run check` | 否 | 否（仅质量流程） |
| `scripts/quality/check-design-tokens.mjs`（新增） | P2-01 | Design Token 静态检查 | 否 | 否 |
| `scripts/quality/design-tokens.test.mjs`（新增） | P2-01 | 静态检查正反向测试 | 否 | 否 |
| `scripts/verify/inspect-t1-02-ui.mjs` | P3-02 | 确定性等待、失败诊断、证据字段 | 否 | 否（仅测试脚本） |
| `scripts/verify/inspect-t1-02-min-window.mjs` | P3-02 / 统计口径 | 关闭点击后写 12 项证据、readyState 等待 | 否 | 否（仅测试脚本） |
| `scripts/verify/verify-t1-02-ui.ps1` | P3-02 / 统计口径 | 从证据 JSON 汇总断言数量与 close 验证 | 否 | 否（仅测试脚本） |
| `scripts/verify/README.md` | 文档同步 | 更新 12 项口径、确定性等待与 Design Token 检查说明 | 否 | 否 |

### 8.2 文档与证据

| 文件 | 说明 |
|---|---|
| `docs/testing/reports/T1-02-AUDIT-FIX-REPORT.md`（新增） | 本报告 |
| `docs/testing/reports/T1-02-AUDIT-FIX-evidence.json`（新增） | 修复机器可读证据 |
| `docs/testing/reports/T1-02-AUDIT-FIX-assets/`（新增） | 回归日志、证据 JSON、截图、探针记录 |
| `docs/testing/reports/T1-02-REPORT.md` | 同步更新状态、统计口径、修复结果与证据链接 |
| `docs/testing/reports/T1-02-evidence.json` | 同步更新状态、Release 产物、命令结果、E2E 与 Token 证据 |
| `docs/development/tasks/T1-02-Project-Management.md` | 增加返工修复结果，状态改为待审计 |
| `docs/development/DEVELOPMENT_PLAN.md` | 同步任务状态与统计口径，追加进度记录 |
| `docs/STATUS.md` | 同步当前任务状态、验证结果与修复说明 |

`docs/testing/reports/T1-02-INDEPENDENT-AUDIT-REPORT.md` **未修改**。

---

## 9. GitHub 交付

- 分支：`task/T1-02-project-management`
- PR：[#7](https://github.com/shuaikun853-dev/work-kanban/pull/7)（保持 Open，不合并）
- main：未修改
- 推送方式：普通 `git push`，未强制推送
- 修复提交与 PR Head SHA：见 [T1-02-AUDIT-FIX-evidence.json](T1-02-AUDIT-FIX-evidence.json) 的
  `git` 字段及 PR #7 页面（提交后回填）。

---

## 10. 遗留问题与风险

1. **历史失败日志缺口：** 第一轮审计报告记录的“首次运行超时 → 立即重跑 → 连续 3 次通过”没有
   归档原始日志；本次无法独立复核，只能原样引用审计报告历史记录。
2. **冷启动复现限制：** 本轮基线脚本 2 次复现尝试均通过，但机器 WebView2 已预热，
   不能证明审计当时首次运行的冷启动时序；P3-02 结论按“测试等待策略问题”处理，
   未发现、也未修改产品业务逻辑。
3. **静态检查边界：** 不扫描 `style:` 指令与脚本动态颜色；当前代码无此用法。
   后续如引入，需要扩展检查范围（应在对应任务评审）。
4. **前端测试基础设施：** 仓库仍无独立前端组件测试/视觉回归框架；UI 证据来自真实 Release
   CDP 脚本与人工截图复核，与第一轮审计时一致，未降低标准。
5. **PRD 未定义行为未变：** 项目名称唯一性、删除/恢复、排序偏好等仍未实现。
6. **历史遗留风险未变：** TOCTOU 按 DEC-029 接受并延期至 Issue #2；普通 SQLite 未加密；
   备份/恢复策略仍待用户确认（OPEN-001/002/003）。
7. **返工过程记录：** 修改脚本过程中曾出现一次 `.ps1` BOM 丢失导致 PowerShell 5.1 解码失败，
   已在提交前修复并验证；失败日志保留在 `p3-02-probe/`，不隐藏返工过程。
8. **未开始 T1-03；未修改其它阶段业务代码。**

---

## 11. 结论

- 第一轮独立审计提出的 P2-01 / P3-01 / P3-02 已全部处理，统计口径不一致已核实并统一。
- 组件/UI CSS 中审计点名及检查覆盖范围内的原始颜色已全部收敛到语义化 Design Token；
  新增的静态检查会真实失败于违规代码，并已接入 `npm run check`。
- 完整回归全部通过：Rust 90/90、主 UI/IPC 73/73 × 5 次、最小窗口 12/12 × 5 次、
  便携 106 项 0 FAIL、异常注入 73 项 0 FAIL、诊断页 24/24、CSP 0、未捕获异常 0。
- **T1-02 当前状态：待审计。** 开发代理不自行标记“独立审计通过”或“用户验收完成”；
  等待第二轮独立审计。PR #7 保持 Open，T1-03 未开始。
