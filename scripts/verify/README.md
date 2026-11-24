# Release 运行时验证脚本（T1-01 / T1-02 / T1-03 / T1-04）

本目录保存 WorkManager 正式 Release 构建的**运行时**验证工具。单元/集成测试由
`cargo test` 覆盖，这里验证“真实 EXE + 真实 WebView2 窗口 + 真实便携目录”的行为。

## 前置条件

- Windows 10，已执行 `npm run tauri build -- --no-bundle`，产物为
  `target\release\workmanager.exe`（Tauri `--no-bundle` 产出为 Cargo 包名小写；
  用例会复制并重命名为 `WorkManager.exe` 以模拟正式便携包形态）。
- 系统 Python 3（含标准库 `sqlite3`）在 `PATH` 中，用于只读校验数据库。
- 测试数据只能放在 D 盘隔离目录（默认 `D:\WorkManager-test-data`），
  绝不允许写入正式运行目录 `D:\WorkManager` 或 C 盘。

## 脚本

| 文件 | 用途 |
|---|---|
| `VerifyCommon.ps1` | 公共库：进程启动/停止、主窗口等待、UI Automation 读取并关闭原生错误对话框、截图、目录快照、SHA-256、python SQLite 只读探针、summary/report 汇总。当前 schema 期望版本为 **4**。 |
| `verify-release-portable.ps1` | 成功路径（106 项检查）：便携目录创建、WebView2 `EBWebView` profile、SQLite PRAGMA/版本/完整性、正常关闭、重启持久化（虚构 canary）、Release 忽略 `WORKMANAGER_TEST_PORTABLE_ROOT`、C 盘边界抽查。schema 版本期望为 **4**（0001–0004）。 |
| `verify-release-faults.ps1` | 异常路径（73 项检查）：垃圾数据库文件、`data` 被文件阻塞、`work.db` 为同名目录、数据库目录 ACL 拒绝写入。要求启动失败、显示“WorkManager 启动失败”对话框、退出码非 0、原文件字节不变、无初始化临时文件残留。 |
| `inspect-release-ui.mjs` | T1-01 诊断页回归：通过 CDP 从应用壳进入“设置 → 数据库诊断”，读取渲染后 DOM、调用 `get_database_health` IPC、截图并输出 JSON 断言（24 项；schema 期望 4，migrations 1–4）。 |
| `verify-t1-02-ui.ps1` | **T1-02 真实 Release UI/IPC 端到端编排**：启动 Release → 主检查（73 项）→ 调整到最小窗口 860×640 → 最小窗口检查（12 项，含关闭按钮断言）→ 验证进程真实退出；从证据 JSON 汇总断言数量并输出截图与 JSON 证据。任一检查失败退出码为 1。 |
| `inspect-t1-02-ui.mjs` | T1-02 主 UI/IPC 检查（由编排脚本调用）：先等待 reload 新文档 boot marker、应用壳和 IPC 就绪，再验证 loading/空/错误态、真实 UI 创建/编辑/归档、长名称、归档后操作消失、诊断页、CSP、最大化/还原窗口 API；项目管理空状态断言改为“Loading 确定性结束后再判断终态”，失败时写页面状态/IPC/异常/截图诊断 JSON。schema 断言为 4，诊断页 migrationRows 期望 1–4。 |
| `inspect-t1-02-min-window.mjs` | T1-02 最小窗口检查（由编排脚本调用）：视口/布局无横向溢出、弹窗完整可见；点击红色关闭圆点后由 Node 进程把包含 `minWindow.closeButtonClicked` 的 **12 项断言**写入证据 JSON，进程真实退出由编排脚本 ExitCode 独立验证。 |
| `verify-t1-03-ui.ps1` | **T1-03 历史 Release UI/IPC/持久化端到端编排**（第四轮 F1/F2 基线）：主检查 → 最小窗口 → 数据库只读探针 → 重启持久化 → 再探针。该脚本以单项目 `<select>` 控件为交互基线，**不适用于 T1-04 多选控件**；T1-03 历史证据不修改，T1-03 业务规则回归改由 Rust 测试与 T1-04 E2E 场景覆盖。 |
| `inspect-t1-03-ui.mjs` / `inspect-t1-03-min-window.mjs` / `inspect-t1-03-persistence.mjs` | T1-03 历史检查脚本（随 T1-03 UI 控件基线保留，未修改；不参与 T1-04 回归）。 |
| `probe-t1-03-db.py` | T1-03 数据库只读探针（标准库 sqlite3）：schema/完整性/项目/工作事项分布；不修改数据。保留为 T1-03 历史工具。 |
| `T1-03UatPath.ps1` | UAT 输出目录安全校验与 fail-closed 清理模块（T1-03 P3-02 + F1/F2）：专用测试根目录信任锚、Windows 原生句柄重解析点/最终路径/卷身份校验、fail-closed 沙箱清理。**T1-04 复用该设施，未修改。** |
| `T1-04UatPath.ps1` | **T1-04 第五轮路径安全扩展**：复用 T1-03 原生句柄与信任锚；额外校验数据库文件自身、父目录/全部祖先、SQLite sidecar、UAT 根目录、卷身份、最终路径；证据目录固定为 `<uat-root>\evidence`。只读校验，不创建/删除文件。 |
| `guard-t1-04-path.ps1` | 上述模块的 CLI 守卫（database / evidence-dir / evidence-file）；stdout 只输出结构化 JSON，失败退出码 3，供 Python 在连接 SQLite/写文件前调用。 |
| `t1_04_path_guard.py` | Python 适配层：调用 PowerShell 原生守卫；进程失败/超时/JSON 无法解析/缺少 `ok=true` 全部 fail-closed，抛 `PathGuardError`。 |
| `test-t1-04-path.py` | Windows 真实 Junction/重解析点专项：正常 UAT 允许；祖先 Junction/叶子重解析点/证据目录 Junction 拒绝；失败时不连接数据库、不写外部文件；文件符号链接无权限时显式 SKIP。 |
| `verify-t1-04-migration-failure.ps1` | **Release migration 失败回滚专项**：构造真实 schema 3 隔离 UAT + 真实 0004 同名冲突索引，启动 Release EXE，验证原生启动失败对话框、非零退出码、回滚后 user_version=3、无新表/version 4、历史数据不变；`t1-04-migration-fixture.py` 提供真实 migration SQL fixture 与只读探针。 |
| `test-t1-03-uat-path.ps1` | T1-03 UAT 路径安全专项测试（第四轮 93 项）：第三轮 60 项全部保留；1 项 Symbolic Link 场景因权限限制显式 SKIP、不计 PASS。 |
| `verify-t1-04-ui.ps1` | **T1-04 真实 Release UI/IPC/原子回滚/持久化端到端编排**：启动 Release → 多项目 E2E 主检查（107 项）→ 最小窗口 860×640（11 项，含真实关闭按钮）→ 关闭 → 原生路径守卫后数据库只读探针 → 关闭时向 UAT 数据库安装真实 SQLite trigger 制造第二条副本插入失败 → 重新启动验证整批回滚且无残留（13 项）→ 移除 trigger → 再次启动验证 14 条记录/创建组持久化并再批量创建（15 项）→ 关闭 → 最终探针（62 项数据库检查）。故障注入只作用于 D 盘独立 UAT 数据库，不进入正式数据目录。 |
| `inspect-t1-04-ui.mjs` | T1-04 主 UI/IPC 检查（由编排脚本调用）：应用壳/导航不变、多项目选择对话框、两项目/三项目真实 UI 批量创建、T1-03 回归、真实 IPC 响应异常后的 requestId 幂等重试、重复提交保护与提交中锁定、归档竞态整批失败、绕过 UI 直接 IPC、Bridge 严格契约违规、创建成功但刷新失败三态、CSP 实际采集/异常/截图。 |
| `inspect-t1-04-min-window.mjs` | T1-04 最小窗口检查：等待窗口尺寸变化真实传播到 WebView2 布局；待安排列表无横向溢出、多项目选择对话框完整可见；最后点击真实关闭按钮（进程退出由编排脚本验证）。 |
| `inspect-t1-04-fault.mjs` | T1-04 原子回滚证据：UAT 数据库已安装真实 SQLite trigger（项目 C 的第二条工作副本插入真实 ABORT），通过真实 UI 批量创建 A+C 必须整批失败、UI 显示数据库错误、标题/选择保留、无部分记录。 |
| `inspect-t1-04-persistence.mjs` | T1-04 重启持久化：同一 UAT 目录重启后 14 条记录与创建组持久化、归档历史关联保留、选择器只含未归档项目；重启后再批量创建 A+B（16 工作 / 6 组 / 13 成员）；最后真实关闭。 |
| `probe-t1-04-db.py` | T1-04 数据库只读探针：schema/完整性/schema_migrations、创建组与成员关系行数、组成员数量分布、孤儿成员、多组工作事项、外键违规；不输出标题/项目名称/绝对路径；不修改任何数据；先经原生路径守卫。 |
| `control-t1-04-fault.py` | T1-04 UAT 故障注入控制器：仅在 `D:\WorkManager-test-data\` 下独立 UAT 安装/移除测试 trigger；先经原生路径守卫，拒绝正式目录；不进入产品代码、不是生产故障开关。 |

## 用法

```powershell
# 成功路径 + 异常路径（默认使用仓库相对路径的 Release EXE）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1

# 自定义 EXE / 输出目录（输出目录必须在 D 盘）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1 `
    -ExePath D:\path\to\workmanager.exe `
    -OutputDir D:\WorkManager-test-data\release-verify-manual
```

UI/IPC 检查需要先以远程调试参数启动 Release 进程：

```powershell
$appDir = 'D:\WorkManager-test-data\ui-check\app'
New-Item -ItemType Directory -Path $appDir -Force | Out-Null
Copy-Item target\release\workmanager.exe (Join-Path $appDir 'WorkManager.exe') -Force
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9333'
$process = Start-Process -FilePath (Join-Path $appDir 'WorkManager.exe') -WorkingDirectory $appDir -PassThru
node scripts\verify\inspect-release-ui.mjs 9333 D:\WorkManager-test-data\ui-check\evidence
$null = $process.CloseMainWindow(); $process.WaitForExit(20000)
```

T1-02 / T1-04 完整 Release UI/IPC 验证（一条命令编排，包含截图、最小窗口与关闭按钮退出检查）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-04-ui.ps1
# 也可指定：-ExePath <path> -OutputDir D:\WorkManager-test-data\t1-04-ui-manual -Port 9355
# T1-04 后续实例使用 Port+1 / Port+2（默认 9356 / 9357）作为远程调试端口。
# -OutputDir 必须是专用测试根目录 D:\WorkManager-test-data\ 下的新目录/空目录；
# 已存在的非空目录、含数据库目录、正式目录、根目录外路径都会被拒绝（退出码 2）。
```

说明：Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时可能误解析中文；本目录新增/修改的 `.ps1` 均以 UTF-8 with BOM 保存（修改后必须保留 BOM，否则 PowerShell 5.1 会按本地代码页解码并破坏脚本结构）。

## Design Token 静态检查（P2-01 门禁）

`src/lib/ui/tokens.css` 是颜色的唯一来源；Feature 页面、通用 UI 组件和相关 UI CSS 不得散落原始颜色。

| 命令 | 用途 |
|---|---|
| `node scripts/quality/check-design-tokens.mjs` | 扫描 `src/**/*.svelte` 的 `<style>` 块与静态内联 `style="..."`、`src/**/*.css`（中央 Token 文件除外），识别 HEX/RGB/RGBA/HSL/HSLA 原始颜色；发现违规则退出码 1，检查无法执行退出码 2。不允许忽略整个 Feature/UI 目录。 |
| `node --test scripts/quality/design-tokens.test.mjs` | 静态检查自身的正反向测试：违规 HEX/RGB/RGBA/HSL 必须失败、使用 Token 必须通过、Token 定义文件不得误报、目录不得整体豁免、真实仓库必须通过。 |
| `node --test scripts/quality/work-item-bridge.test.mjs` | 工作事项 Bridge 运行时严格契约测试（**27 项**，T1-04 起含批量创建响应）：完整 10 字段 DTO、四个可空字段 NULL/合法值、缺字段、数字/可空字段类型错误、非法 lifecycleStatus、未知字段、列表语义一致性、批量响应数量/项目一一对应/ID 唯一/全部 pending、非法请求项目列表；拒绝时抛 `ipc-contract-violation`。直接加载 `src/lib/bridge/workItemValidation.ts`，不新增前端测试框架依赖。 |
| `npm run check` | 依次执行 `svelte-check`、工作事项 Bridge 契约测试、Design Token 静态检查与上述正反向测试；任一失败则质量门禁失败。 |

可选参数：`--root <repoRoot>` 指定扫描根目录，`--report <file>` 输出机器可读 JSON（`filesScanned`、`scannedFiles`、`violations`、`pass`）。检查结论与截图证据见 `docs/testing/reports/T1-02-AUDIT-FIX-assets/`。

退出码约定：`0` = 全部检查通过（允许 WARN/INFO）；`1` = 存在 FAIL；`2` = 前置条件不满足
（EXE 不存在、python 不可用、输出目录非法）。脚本不会伪造 PASS：无法执行的检查会
如实记录为 FAIL/INFO，并保留可复核证据。

## 当前验证结果

### T1-04（2026-11-24 第五轮，开发与自测完成，等待独立审计）

Release 产物：`target\release\workmanager.exe`，**10,457,600 字节**，
SHA-256 `0bbe1dc43f59644e51126aeb277abd98cb124e506f69f25d35ef767010ab4166`。

| 脚本 | 退出码 | 结果 |
|---|---|---|
| `verify-t1-04-ui.ps1`（UAT `<uat-root>`） | 0 | 主 UI/IPC **107/107**；最小窗口 **11/11**；真实 SQLite trigger 原子回滚 **13/13**；重启持久化 **15/15**；数据库只读探针 **62/62**；三次真实关闭退出码 **0/0/0**；CSP 实际采集 0；未捕获异常 0 |
| `test-t1-04-path.py`（真实 Junction） | 0 | 9 PASS / 0 FAIL / 1 SKIP（文件符号链接权限不足，显式记录） |
| Release migration failure（真实 schema 3 + 0004 索引冲突） | 1（预期失败） | 原生“WorkManager 启动失败”对话框；回滚后 user_version=3、无新表/version 4、历史数据不变；验证脚本判定 PASS/退出码 0 |
| `verify-release-portable.ps1`（继承回归） | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1（保留既有 WARN） INFO=15 |
| `verify-release-faults.ps1`（继承回归） | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9 |
| `verify-t1-02-ui.ps1`（继承回归） | 0 | 主 UI/IPC **73/73**；最小窗口 **12/12**；关闭按钮后进程退出码 0；CSP 0；页面异常 0 |
| `scripts/quality/work-item-bridge.test.mjs` | 0 | **27/27** Bridge 严格契约测试通过 |
| `scripts/quality/check-design-tokens.mjs` | 0 | 0 违规（22 文件，由 `npm run check` 执行） |
| `scripts/quality/design-tokens.test.mjs` | 0 | 49/49 正反向测试通过 |

数据库探针：主检查后 14 工作 / 5 创建组 / 11 成员；故障回滚后完全一致；重启并再次批量创建后 16 / 6 / 13；schema 4、完整性 ok、外键 0 违规。真实 IPC 响应异常后同 requestId 重试仍为 1 个创建组 / 2 个副本 / 2 条成员关系。

### T1-03（2026-11-20 第四轮 F1/F2 历史记录，保留原文，未修改）

该轮 Release 产物为 T1-03 分支构建（10,352,128 字节，SHA-256 `3f12bbce…fa9e3`）；主 UI/IPC 84/84、最小窗口 12/12、持久化 17/17、数据库探针 25/25、路径安全专项 93 项（SKIPPED=1 已记录）、继承回归通过。T1-03 当前仍未完成独立审计，P2-01 未关闭，PR #8 Open；详细内容与证据见
`docs/testing/reports/T1-03-REPORT.md` 与 `docs/testing/reports/T1-03-assets/`（第四轮证据位于 `evidence/round4/`，不覆盖第三轮证据）。

说明：当前 schema 版本期望为 **4**（0001 foundation + 0002 projects + 0003 work_items + 0004 work_item_creation_groups）；应用会在数据库目录保留跨进程初始化锁文件 `.work.db.init.lock`（仅 PID/时间戳诊断），异常路径检查允许该文件存在；`.work.db.init-*` 临时数据库仍必须为空。

T1-04 的截图、脱敏 JSON 证据见 `docs/testing/reports/T1-04-assets/`；T1-02 历史证据保留在 `docs/testing/reports/T1-02-assets/` 与 `docs/testing/reports/T1-02-AUDIT-FIX-assets/`。
