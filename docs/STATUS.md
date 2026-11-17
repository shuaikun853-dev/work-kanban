# WorkManager 开发状态

**更新日期：** 2026-11-17  
**当前阶段：** 阶段 1：基础架构与工作事项  
**当前任务：** T1-01 正式工程骨架与 SQLite 基础设施  
**总体状态：** 阶段 0 已放行；阶段 1 已启动。T1-01 第二轮独立审计返工：R2-01（初始化锁后 WAL 误判）、R2-02（Debug/Test 正式目录 Junction 绕过）、R2-04（证据/进度过期）已修复并通过完整回归；R2-03 的真实物理卷身份校验已实现并通过实机测试，但**路径校验 TOCTOU 残余窗口未关闭**，当前为**返工中 / R2-03 阻塞（等待用户决策）**；最新代码提交 `a148f0d10eda994d21bb088984228b4e9d6b97ce`；分支 `task/T1-01-sqlite-foundation`，PR #1 保持打开、不合并。任务未标记待审计或验收完成。

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
| T1-01 | 正式工程骨架、便携路径接入与 SQLite 基础设施 | 返工中 / R2-03 阻塞（R2-01/R2-02/R2-04 已修复；R2-03 卷身份已修复、TOCTOU 未关闭等待用户决策；最新代码提交 `a148f0d`；PR #1 不合并） |
| T1-02 | 项目创建、编辑、归档 | 未开始 |
| T1-03 | 工作事项快速创建和待安排区域 | 未开始 |
| T1-04 | 多项目独立副本创建 | 未开始 |
| T1-05 | 工作事项状态流转和历史记录 | 未开始 |
| T1-06 | 六位数字应用密码与锁屏 | 取消 |
| T1-07 | 首次初始化与 SQLite 异常保护 | 未开始 |

**当前交付物：** [T1-01 开发任务说明](development/tasks/T1-01-SQLite-Foundation.md)、[第二轮返工修复报告](testing/reports/T1-01-SECOND-AUDIT-FIX-REPORT.md)、[返工后机器可读证据](testing/reports/T1-01-AUDIT-FIX-evidence.json)、[第一轮返工报告](testing/reports/T1-01-AUDIT-FIX-REPORT.md)（历史）、[第二轮独立审计报告](testing/reports/T1-01-SECOND-AUDIT-REPORT.md)（历史审计依据）、[Pull Request #1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（返工中、不合并）。

### T1-01 交付摘要（2026-11-17，第二轮返工后）

- 正式 Tauri 2 + Svelte 5 + TypeScript + Vite 工程可构建；`workmanager-core`（Rust Core，不依赖 Tauri）与 `src-tauri`（Tauri 适配层）职责分离。
- Release 数据目录跟随 EXE：`<exe目录>/data/database/work.db`；WebView2 绝对数据目录 `<data>/cache/webview2`；仅 D 盘、无 C 盘/AppData/Temp 回退；Win32 真实最终路径校验 + **物理卷身份校验（卷 GUID / NT 设备卷）**（拒绝 D→C Junction、SUBST 卷别名、映射网络盘、UNC）。
- 普通 bundled SQLite 3.54.1：WAL、`foreign_keys=ON`、`synchronous=FULL`、`busy_timeout=5000`、`temp_store=MEMORY`；启动时完整性检查与外键检查；已有数据库先做只读预检查（版本/完整性/外键/兼容性）后才应用持久化 PRAGMA。
- schema 版本 1（`schema_migrations`、`settings`）；`PRAGMA user_version` + 编号 SQL migration，每个 migration 独立事务、失败回滚；首次初始化临时库 + 硬链接原子安装 + 跨进程初始化锁；0 字节库/孤儿 WAL/journal 均 fail-closed 且保留原文件。
- 最小健康检查窗口已实现并通过真实 Release WebView2 端到端验证（页面渲染 + 异步 `get_database_health` IPC 返回 + 截图 + CSP 0 违规）。
- 已执行（第二轮返工后）：`cargo fmt --check` / `cargo check` / `cargo test --workspace`（**62 项通过**，新增 10 项）/ `npm run check` / `npm run build` / `npm run tauri build -- --no-bundle`（成功，EXE **9,980,928 字节**，SHA-256 **`849E803D…019E`**）/ Release 运行时专项验证（便携 106 项 PASS 90 / FAIL 0；异常注入 **73 项** PASS 64 / FAIL 0）/ 真实窗口 UI/IPC/CSP 21/21 / 重启持久化 / Release 忽略测试环境变量 / D 盘真实卷身份与 SUBST 卷别名测试。
- 新增专项：R2-01 确定性真实双进程“等待锁进程遇到活动 WAL”测试；R2-02 正式目录 Junction 别名绕过测试（resolve / ensure_directories / Database::initialize 三阶段拒绝）；R2-03 卷 GUID 与 NT 设备卷身份交叉核验 + 真实 SUBST→C 实机测试。
- **未实现**：项目与工作事项 CRUD、每日计划、复盘、日报/周报、附件、自动备份、密码/锁屏/SQLCipher/DPAPI。T1-01 只是基础设施，不代表业务功能已实现。
- **阻塞：** R2-03 的路径校验 TOCTOU 残余窗口未关闭，未宣称“任何情况下都不会写入 C 盘”；等待用户决定延期加固方案，详见[第二轮返工修复报告](testing/reports/T1-01-SECOND-AUDIT-FIX-REPORT.md)。

### T1-01 第一轮独立审计问题（2026-11-17，第一轮返工已完成；第二轮复审发现新问题）

独立审计对 PR #1（返工前基线 `682ba04`）提出以下问题，已全部修复并补充专项测试（详见 [修复报告](testing/reports/T1-01-AUDIT-FIX-REPORT.md)）：

| 优先级 | 问题 | 修复状态 |
|---|---|---|
| P1 | 已存在的 0 字节 `work.db` 可能被 SQLite 当作空库并自动迁移 | 已修复：`database-empty-existing-file` / `database-orphaned-sidecar` fail-closed，原文件与 WAL 字节不变；6 项专项测试 |
| P1 | 便携路径只校验盘符字符串，未验证实际目标卷与重解析点 | 已修复：Win32 句柄真实最终路径 + 卷类型校验；D→C Junction 在写入前拒绝；4 项 Windows 实机测试 |
| P2 | 打开已有数据库时在兼容性/完整性检查前就设置 `journal_mode=WAL` | 已修复：严格预检查顺序；被拒数据库 SHA-256 与 DELETE 模式不变；3 项专项测试 |
| P2 | 每次启动无条件清理 `.work.db.init-*`，未考虑活动进程 | 已修复：`LockFileEx` 跨进程初始化锁；仅持锁清理；真实双进程并发测试通过 |
| P2 | `get_database_health` 为同步命令，完整完整性检查可能阻塞 UI 主线程 | 已修复：async 命令 + `spawn_blocking`；DTO 契约不变；真实 async runtime 单测 + Release CDP 通过 |
| 可选 | `tauri.conf.json` 中 `csp = null` | 已实施生产 CSP + devCsp；Release WebView2 重载后 0 条 CSP 违规，UI/IPC 正常 |

上述内容记录第一轮返工对原始问题的修复，不代表最新代码已经通过审计。

### T1-01 第二轮独立审计返工结果（2026-11-17）

依据 [第二轮独立审计报告](testing/reports/T1-01-SECOND-AUDIT-REPORT.md)（审计基准 `892b25f`）完成返工，修复代码提交 `a148f0d10eda994d21bb088984228b4e9d6b97ce`，详见 [第二轮返工修复报告](testing/reports/T1-01-SECOND-AUDIT-FIX-REPORT.md) 与 [返工后机器可读证据](testing/reports/T1-01-AUDIT-FIX-evidence.json)。

| 优先级 | 审计问题 | 返工结论 | 关键证据 |
|---|---|---|---|
| P1 | 初始化锁后先检查孤儿 WAL，再重检正式数据库，可能误判有效数据库的活动 WAL | **已修复**：取得锁后先重检主库，只有主库确实缺失才检查非空 WAL/journal；保留 0 字节库与孤儿 sidecar 保护 | 确定性真实双进程测试 3 项 PASS；零字节/孤儿 sidecar 回归 6 项 PASS |
| P1 | Debug/Test 正式目录保护仅比较字符串，同卷 Junction 可指向正式目录绕过保护 | **已修复**：字符串 + 真实最终路径双重比较；受保护根目录可注入测试；创建目录/写探针/锁/数据库之前拒绝 | `tests/formal_root_protection.rs` 5 项 PASS；真实 `D:\WorkManager` 零触碰 |
| P1 | 真实卷身份与路径 TOCTOU 尚未充分关闭；SUBST/卷挂载点未专门验证 | **部分修复 / 阻塞**：卷 GUID + NT 设备卷身份校验已实现并实机测试；TOCTOU 残余窗口未关闭，等待用户决策 | D 盘卷身份两 API 交叉核验 PASS；SUBST→C 实测 PASS；跨卷挂载点/映射网络盘标注未验证 |
| P2 | PR 描述、旧 evidence JSON、STATUS 风险描述过期；测试原始日志只在开发机 | **已修复**：旧 evidence 标记 historical；新增机器可读证据与脱敏日志；更新 STATUS/计划/任务说明/PR 描述 | 本轮文档与 `docs/testing/reports/T1-01-assets/second-audit-fix/` |

**门禁：** T1-01 当前为返工中 / R2-03 阻塞（等待用户决策）；PR #1 不合并、main 不修改、T1-02 不得开始；任务不得标记待审计或验收完成。

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
8. 应用级单实例保护尚未实现（规划在 T6-07），因此允许多个 WorkManager 实例运行。数据库首次初始化已由 `LockFileEx` 跨进程锁串行化；R2-01 修复后，等待锁的进程会先重检正式主库，不会把另一个进程已创建数据库的活动 WAL 误判为孤儿文件（已由确定性真实双进程测试覆盖）。应用级单实例仍待 T6-07。
9. 启动时执行完整 `PRAGMA integrity_check`；数据库规模增大后启动耗时会增长，后续性能任务需评估改为 `quick_check` 或按需检查。
10. 正常退出时已显式关闭 SQLite 连接（触发 WAL checkpoint 并清理 `-wal`/`-shm`，实测关闭后仅剩 `work.db`）；进程被强制结束（任务管理器/断电）时无法执行该逻辑，依赖 SQLite WAL 恢复与下次启动完整性检查兜底。
11. `%LOCALAPPDATA%\EBWebView` 在本机验证开始前已存在（创建于 2024 年，本次运行前后时间戳与条目未变化）；WorkManager 专属 C 盘目录 `%LOCALAPPDATA%\com.workmanager.portable`、`%APPDATA%\com.workmanager.portable` 不存在。该共享目录的历史来源需在发布阶段审计确认。
12. **【阻塞】路径校验 TOCTOU 未关闭：** 真实最终路径与物理卷身份校验和后续目录创建、写探针、初始化锁、SQLite 按路径打开之间仍非原子，存在理论竞争窗口。已把校验前移、创建后复验，并在 `Database::initialize()` 创建锁/数据库之前再次执行边界复验；但未宣称“任何情况下都不会写入 C 盘”。彻底改造需句柄相对创建 + custom SQLite VFS（或受控折衷方案），完整方案与测试计划见[第二轮返工修复报告 §3.4](testing/reports/T1-01-SECOND-AUDIT-FIX-REPORT.md)。等待用户决定是否接受延期加固。
13. 真实卷身份校验已实现：目标路径句柄的 `VOLUME_NAME_GUID` / `VOLUME_NAME_NT` 必须与 `D:\` 根卷身份一致，不再只比较盘符。已实机验证：正常 D 盘、D 盘内部 Junction、D→C Junction；SUBST 用空闲盘符→C 盘实测（D: 为真实物理卷，无法构造 D:→C:）。**未实机验证**：真实映射网络盘（本机无网络共享）、D 盘路径下的真实跨卷目录挂载点（需管理员权限与额外卷）；未伪造结果。非 Windows 降级实现未做交叉编译验证（目标平台 Windows 10）。
14. 本轮新增测试引入 `Database::initialize()` 的数据库目录边界复验（数据库增量锁/写库之前）；异常的 ACL/文件阻塞等既有故障码由 Release 异常注入 73 项回归覆盖，未发现回归。

## 下一步安排

- T1-01 第二轮审计返工结果：R2-01、R2-02、R2-04 已修复并通过回归；R2-03 真实卷身份已修复实机测试通过，但路径校验 TOCTOU 残余窗口未关闭，当前为返工中 / R2-03 阻塞，等待用户决策。最新代码提交 `a148f0d`，分支 `task/T1-01-sqlite-foundation`，[PR #1](https://github.com/shuaikun853-dev/work-kanban/pull/1)；见[第二轮返工修复报告](testing/reports/T1-01-SECOND-AUDIT-FIX-REPORT.md)与[返工后机器可读证据](testing/reports/T1-01-AUDIT-FIX-evidence.json)。PR 不合并，main 不修改，T1-02 不得开始，任务不得标记待审计或验收完成。
- 需要用户决定：接受 TOCTOU 残余风险并按后续安全加固任务处理，或要求 T1-01 内完成句柄相对改造。决定后再由独立审计重新核对修复 diff、证据与剩余风险。
- 重新审计通过并同步更新开发计划后，才决定是否进入 T1-02；开发代理不得自行开始 T1-02。
- T0-05 不再安排开发；T0-06 延期至阶段 6，不得从最终发布验收清单中删除。
- 备份策略（OPEN-001/002/003）未确认前，不实施、也不宣称自动备份。

## 进度口径

- 文档调整完成不等于代码实现完成。
- 代码完成不等于测试通过。
- 测试通过不等于独立审计通过。
- 每个任务只有在测试证据可复核、独立审计通过并同步更新开发计划后，才标记为验收完成。
