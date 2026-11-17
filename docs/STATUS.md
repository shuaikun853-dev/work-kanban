# WorkManager 开发状态

**更新日期：** 2026-11-17  
**当前阶段：** 阶段 1：基础架构与工作事项  
**当前任务：** T1-01 正式工程骨架与 SQLite 基础设施  
**总体状态：** 阶段 0 已按用户最新决策放行；阶段 1 已启动。T1-01 独立审计发现问题（2 项 P1、3 项 P2 及 1 项可选安全加固），**当前进入返工**；代码提交 `682ba04` 为返工前基线，分支 `task/T1-01-sqlite-foundation`，PR #1 保持打开、不合并。任务未标记验收完成。

## 最新产品决策

2026-11-17，用户确认采用 DEC-028：

- 第一版取消六位数字应用密码、SQLCipher 和 DPAPI。
- 使用普通 SQLite，不对数据库文件提供应用层加密。
- 保留 D 盘便携本地存储，不上传工作数据。
- 保留数据库事务、版本化 migration、异常保护和备份恢复。
- 接受普通 SQLite 文件可被拥有文件访问权限的人直接读取的风险。

## 阶段 0：技术验证

| 编号 | 验证内容 | 当前结论 | 遗留事项 |
|---|---|---|---|
| T0-01 | Tauri 2 + Svelte 5 Windows 桌面壳 | 通过 | 正式工程中仍需复用并回归构建/IPC |
| T0-02 | EXE 路径解析与 D 盘便携数据根目录 | 基础通过并放行 | 正式 D:/WorkManager 路径、物理拔盘和管理员审计放在发布阶段补测 |
| T0-03 | WebView2 绝对数据目录 | 基础通过并放行 | Process Monitor 级审计放在发布阶段补测 |
| T0-04 | SQLCipher Windows 构建和加密验证 | 取消 | 第一版不使用 SQLCipher；既有验证报告保留为历史记录 |
| T0-05 | DPAPI CurrentUser 密钥保护 | 取消 | 第一版不使用 DPAPI |
| T0-06 | 断网与 Windows 集成可行性 | 延期至阶段 6 | 由 T6-04（完整断网验收）和 T6-07（托盘、开机启动、单实例、通知）完成最终验收 |

阶段 0 放行说明：

- T0-01 已在 Windows 10 实机完成桌面窗口、Svelte 页面、Rust IPC、关闭和重启验证。
- T0-02/T0-03 已完成便携目录、WebView2 绝对路径、持久化、目录移动及多种异常路径验证。
- 物理拔除 D 盘、正式 D:/WorkManager 路径实跑和 Process Monitor 级文件审计尚未完成；这些不再阻塞业务开发，纳入阶段 6 发布验收。
- SQLCipher 和 DPAPI 已由用户明确取消，不再是阶段门禁。
- T0-06 延期到阶段 6，不阻塞 SQLite 和业务模块开发。

## 阶段 1：基础架构与工作事项

| 任务 | 内容 | 状态 |
|---|---|---|
| T1-01 | 正式工程骨架、便携路径接入与 SQLite 基础设施 | 返工（独立审计问题修复中；返工前基线 `682ba04`；PR #1） |
| T1-02 | 项目创建、编辑、归档 | 未开始 |
| T1-03 | 工作事项快速创建和待安排区域 | 未开始 |
| T1-04 | 多项目独立副本创建 | 未开始 |
| T1-05 | 工作事项状态流转和历史记录 | 未开始 |
| T1-06 | 六位数字应用密码与锁屏 | 取消 |
| T1-07 | 首次初始化与 SQLite 异常保护 | 未开始 |

**当前交付物：** [T1-01 开发任务说明与 DeepSeek 提示词](development/tasks/T1-01-SQLite-Foundation.md)、[T1-01 测试报告](testing/reports/T1-01-REPORT.md)（含实际命令、结果与证据）、[Pull Request #1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（待独立审计，不自动合并）。

### T1-01 交付摘要（2026-11-17）

- 正式 Tauri 2 + Svelte 5 + TypeScript + Vite 工程可构建；`workmanager-core`（Rust Core，不依赖 Tauri）与 `src-tauri`（Tauri 适配层）职责分离。
- Release 数据目录跟随 EXE：`<exe目录>/data/database/work.db`；WebView2 绝对数据目录 `<data>/cache/webview2`；仅 D 盘、无 C 盘/AppData/Temp 回退。
- 普通 bundled SQLite 3.54.1：WAL、`foreign_keys=ON`、`synchronous=FULL`、`busy_timeout=5000`、`temp_store=MEMORY`；启动时完整性检查与外键检查。
- schema 版本 1（`schema_migrations`、`settings`）；`PRAGMA user_version` + 编号 SQL migration，每个 migration 独立事务、失败回滚；首次初始化临时库 + 原子安装，绝不覆盖已有数据库。
- 最小健康检查窗口已实现并通过真实 Release WebView2 端到端验证（页面渲染 + `get_database_health` IPC 返回 + 截图）。
- 已执行：`cargo fmt --check` / `cargo check` / `cargo test`（33 项通过）/ `npm run check` / `npm run build` / `npm run tauri build -- --no-bundle`（成功，EXE 9,898,496 字节）/ Release 运行时专项验证（便携 106 项、异常 59 项检查，0 FAIL）/ 重启持久化 / Release 忽略测试环境变量 / D 盘不可写 fail-closed 测试。
- **未实现**：项目与工作事项 CRUD、每日计划、复盘、日报/周报、附件、自动备份、密码/锁屏/SQLCipher/DPAPI。T1-01 只是基础设施，不代表业务功能已实现。

### T1-01 独立审计问题（2026-11-17 进入返工）

独立审计对 PR #1（基线 `682ba04`）提出以下问题，全部在返工中修复：

| 优先级 | 问题 | 返工要求 |
|---|---|---|
| P1 | 已存在的 0 字节 `work.db` 可能被 SQLite 当作空库并自动迁移 | 区分首次安装与已有数据库；异常空文件 fail-closed；不删除/覆盖/重建；考虑 WAL 恢复边界 |
| P1 | 便携路径只校验盘符字符串，未验证实际目标卷与重解析点 | 校验完整路径重解析点、EXE 祖先目录、真实目标卷；拒绝指向 C 盘的 Junction/符号链接与映射网络盘；保留 Debug/Test 规则 |
| P2 | 打开已有数据库时在兼容性/完整性检查前就设置 `journal_mode=WAL` | 先读取版本、完整性、外键与兼容性，健康兼容后才配置运行参数，再迁移并复查 |
| P2 | 每次启动无条件清理 `.work.db.init-*`，未考虑活动进程 | 引入跨进程初始化锁；只在持锁后清理；异常退出后可恢复；并发首次启动不覆盖正式库 |
| P2 | `get_database_health` 为同步命令，完整完整性检查可能阻塞 UI 主线程 | 使用 `spawn_blocking` 异步派发；保持 DTO 契约不变；不暴露数据库连接 |
| 可选 | `tauri.conf.json` 中 `csp = null` | 评估并实施适合本地桌面应用的 CSP，验证不破坏 Svelte/Tauri IPC/WebView2 |

返工完成前 T1-01 不得标记完成。修复报告见 `docs/testing/reports/T1-01-AUDIT-FIX-REPORT.md`。

## 后续阶段

- [ ] 阶段 2：计划、优先级与当前工作。
- [ ] 阶段 3：每日复盘与提醒。
- [ ] 阶段 4：日志、搜索与报表。
- [ ] 阶段 5：附件、数据清理与备份恢复。
- [ ] 阶段 6：发布与最终验收（含新增 T6-07 Windows 系统集成验收）。

## 当前风险与注意事项

1. 普通 SQLite 不提供数据库文件加密；应避免把数据库放入公开共享目录，并依赖 Windows 账户/磁盘访问权限保护本地文件。
2. 备份频率、轮转数量和自动备份默认策略仍待确认；在策略确认前不得声称自动备份已实现。
3. SQLite WAL 模式下不得简单复制正在使用的主数据库文件作为可靠备份；备份实现应使用 SQLite 在线备份 API 或经过验证的一致性快照流程。
4. 正式应用目录移动、物理拔除 D 盘、D:/WorkManager 正式路径实跑和管理员 Process Monitor 审计需在阶段 6 发布验收补测。
5. T0-06 并未取消：完整断网流程由 T6-04 验收；托盘、开机启动、单实例和通知由 T6-07 验收。
6. 业务功能尚未实现；T1-01 只完成基础设施，技术验证与自测通过不等于业务功能完成或独立审计通过。
7. Release 产物当前为 `target/release/workmanager.exe`（Tauri `--no-bundle` 不改名）；正式便携包中 `WorkManager.exe` 的命名与目录组装属于 T6-01，T1-01 运行时验证采用复制重命名后运行。
8. 单实例保护尚未实现（规划在 T6-07）：首次初始化使用硬链接保证不覆盖已有数据库，但两个进程同时首次启动仍存在初始化竞争窗口，需在单实例任务中消除。
9. 启动时执行完整 `PRAGMA integrity_check`；数据库规模增大后启动耗时会增长，后续性能任务需评估改为 `quick_check` 或按需检查。
10. 正常退出时已显式关闭 SQLite 连接（触发 WAL checkpoint 并清理 `-wal`/`-shm`，实测关闭后仅剩 `work.db`）；进程被强制结束（任务管理器/断电）时无法执行该逻辑，依赖 SQLite WAL 恢复与下次启动完整性检查兜底。
11. `%LOCALAPPDATA%\EBWebView` 在本机验证开始前已存在（创建于 2024 年，本次运行前后时间戳与条目未变化）；WorkManager 专属 C 盘目录 `%LOCALAPPDATA%\com.workmanager.portable`、`%APPDATA%\com.workmanager.portable` 不存在。该共享目录的历史来源需在发布阶段审计确认。

## 下一步安排

- T1-01 返工中：按独立审计问题清单修复并补充专项测试；完成后推送修复提交使 PR #1 自动更新，状态改为待审计（不合并 PR、不开始 T1-02）。
- T1-01 返工完成并重新审计通过后，才决定是否进入 T1-02；开发代理不得自行标记验收完成，也不得自动合并 PR。
- T0-05 不再安排开发；T0-06 延期至阶段 6，不得从最终发布验收清单中删除。
- 备份策略（OPEN-001/002/003）未确认前，不实施、也不宣称自动备份。

## 进度口径

- 文档调整完成不等于代码实现完成。
- 代码完成不等于测试通过。
- 测试通过不等于独立审计通过。
- 每个任务只有在测试证据可复核、独立审计通过并同步更新开发计划后，才标记为验收完成。
