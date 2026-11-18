# WorkManager 开发状态

**更新日期：** 2026-11-18  
**当前阶段：** 阶段 1：基础架构与工作事项  
**最近完成任务：** T1-01 正式工程骨架与 SQLite 基础设施（用户验收完成）  
**下一候选任务：** T1-02 项目创建、编辑、归档（尚未开始，等待单独启动指示）  
**总体状态：** 阶段 0 已放行；阶段 1 已启动。T1-01 的 R3-01（P1）与 R3-02（P2）已修复，第四轮独立审计通过，用户于 2026-11-18 明确验收，**T1-01 验收完成**。TOCTOU 按 DEC-029 接受并延期至独立安全加固 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，仍未修复，不作绝对 C 盘写入保证。分支 `task/T1-01-sqlite-foundation`；PR #1 保持打开、未合并；main 未修改；T1-02 未开始。

## 最新产品决策

2026-11-17，用户确认采用 DEC-028：

- 第一版取消六位数字应用密码、SQLCipher 和 DPAPI。
- 使用普通 SQLite，不对数据库文件提供应用层加密。
- 保留 D 盘便携本地存储，不上传工作数据。
- 保留数据库事务、版本化 migration、异常保护和备份恢复。
- 接受普通 SQLite 文件可被拥有文件访问权限的人直接读取的风险。

2026-11-18，用户确认 DEC-029：接受当前路径校验与后续路径字符串写入之间的 TOCTOU 残余风险，T1-01 不实施完整句柄相对改造/custom SQLite VFS；该风险转入[独立安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。风险未修复，程序不得宣称绝对不会写入 C 盘；禁止静默回退 C 盘和已检测违规 fail-closed 规则不变。R3-01/R3-02 已经修复并通过第四轮独立审计；用户于 2026-11-18 明确验收 T1-01。

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
| T1-01 | 正式工程骨架、便携路径接入与 SQLite 基础设施 | **验收完成**（用户 2026-11-18 确认；PR #1 仍待单独合并；TOCTOU 按 DEC-029 接受并延期至 Issue #2） |
| T1-02 | 项目创建、编辑、归档 | 未开始 |
| T1-03 | 工作事项快速创建和待安排区域 | 未开始 |
| T1-04 | 多项目独立副本创建 | 未开始 |
| T1-05 | 工作事项状态流转和历史记录 | 未开始 |
| T1-06 | 六位数字应用密码与锁屏 | 取消 |
| T1-07 | 首次初始化与 SQLite 异常保护 | 未开始 |

**当前交付物：** [T1-01 开发任务说明](development/tasks/T1-01-SQLite-Foundation.md)、[R3 专项修复报告](testing/reports/T1-01-R3-FIX-REPORT.md)、[R3 机器可读证据](testing/reports/T1-01-R3-FIX-evidence.json)、第二轮返工报告与证据、[第三轮独立审计报告](testing/reports/T1-01-THIRD-AUDIT-REPORT.md)、[TOCTOU 后续安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)、历史审计/返工报告、[Pull Request #1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（独立审计通过，待用户验收；保持打开、不合并）；[第四轮独立审计报告](testing/reports/T1-01-FOURTH-AUDIT-REPORT.md)、[T1-01 用户验收记录](testing/reports/T1-01-USER-ACCEPTANCE.md)。

### T1-01 历史交付摘要（2026-11-17，第二轮返工后；R3 最终结果见下文）

- 正式 Tauri 2 + Svelte 5 + TypeScript + Vite 工程可构建；`workmanager-core`（Rust Core，不依赖 Tauri）与 `src-tauri`（Tauri 适配层）职责分离。
- Release 数据目录跟随 EXE：`<exe目录>/data/database/work.db`；WebView2 绝对数据目录 `<data>/cache/webview2`；仅 D 盘、无 C 盘/AppData/Temp 回退；已实现 Win32 真实最终路径和目标卷身份校验，实测拒绝 D→C Junction，并实测 SUBST Q:→C: 场景。**D 根卷自身的独立信任锚验证仍有 R3-01 待修复；映射网络盘、真实跨卷挂载点未实机验证。**
- 普通 bundled SQLite 3.54.1：WAL、`foreign_keys=ON`、`synchronous=FULL`、`busy_timeout=5000`、`temp_store=MEMORY`；启动时完整性检查与外键检查；已有数据库先做只读预检查（版本/完整性/外键/兼容性）后才应用持久化 PRAGMA。
- schema 版本 1（`schema_migrations`、`settings`）；`PRAGMA user_version` + 编号 SQL migration，每个 migration 独立事务、失败回滚；首次初始化临时库 + 硬链接原子安装 + 跨进程初始化锁；0 字节库/孤儿 WAL/journal 均 fail-closed 且保留原文件。
- 最小健康检查窗口已实现并通过真实 Release WebView2 端到端验证（页面渲染 + 异步 `get_database_health` IPC 返回 + 截图 + CSP 0 违规）。
- 已执行（第二轮返工后）：`cargo fmt --check` / `cargo check` / `cargo test --workspace`（**62 项通过**，新增 10 项）/ `npm run check` / `npm run build` / `npm run tauri build -- --no-bundle`（成功，EXE **9,980,928 字节**，SHA-256 **`849E803D…019E`**）/ Release 运行时专项验证（便携 106 项 PASS 90 / FAIL 0；异常注入 **73 项** PASS 64 / FAIL 0）/ 真实窗口 UI/IPC/CSP 21/21 / 重启持久化 / Release 忽略测试环境变量 / D 盘真实卷身份与 SUBST 卷别名测试。
- 新增专项：R2-01 确定性真实双进程“等待锁进程遇到活动 WAL”测试；R2-02 正式目录 Junction 别名绕过测试（resolve / ensure_directories / Database::initialize 三阶段拒绝）；R2-03 卷 GUID 与 NT 设备卷身份交叉核验 + 真实 SUBST→C 实机测试。
- **未实现**：项目与工作事项 CRUD、每日计划、复盘、日报/周报、附件、自动备份、密码/锁屏/SQLCipher/DPAPI。T1-01 只是基础设施，不代表业务功能已实现。
- **已接受的残余风险（DEC-029）：** R2-03 TOCTOU 未关闭，用户接受 T1-01 暂不实施句柄相对改造，并转入[Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。这不是修复；不得宣称任何情况下都不会写入 C 盘。T1-01 当前仍需修复 R3-01 P1，并补强 R3-02 P2 后重新独立审计。

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
| P1 | 真实卷身份与路径 TOCTOU 尚未充分关闭；SUBST/卷挂载点未专门验证 | **部分修复**：目标卷身份比较已实现；TOCTOU 未修复，用户按 DEC-029 接受并延期到 Issue #2；D 根信任锚另有 R3-01 P1 待修复 | D 盘卷身份两 API 交叉核验 PASS；SUBST→C 实测 PASS；跨卷挂载点/映射网络盘标注未验证 |
| P2 | PR 描述、旧 evidence JSON、STATUS 风险描述过期；测试原始日志只在开发机 | **已修复**：旧 evidence 标记 historical；新增机器可读证据与脱敏日志；更新 STATUS/计划/任务说明/PR 描述 | 本轮文档与 `docs/testing/reports/T1-01-assets/second-audit-fix/` |

**门禁（第二轮返工历史记录）：** TOCTOU 已按 DEC-029 接受并延期；R3-01/R3-02 已在第三轮返工中处理（见下节）。

### T1-01 第三轮独立审计 R3 返工结果（2026-11-18）

依据 [第三轮独立审计报告](testing/reports/T1-01-THIRD-AUDIT-REPORT.md)（审计对象 PR #1 HEAD `eaf6ef7`）与 DEC-029 完成返工，修复代码提交：R3-01 `ae1eb65a00e0d36907f8769d1421aef17a73023f`、R3-02 `4942eb0c60bf43fd3d1371fbf427f5b0d043ebc1`；详见 [R3 专项修复报告](testing/reports/T1-01-R3-FIX-REPORT.md) 与 [R3 机器可读证据](testing/reports/T1-01-R3-FIX-evidence.json)。

| 优先级 | 审计问题 | 返工结论 | 关键证据 |
|---|---|---|---|
| P1 | R3-01 D 盘根卷作为信任锚但自身未独立验证 | **已修复**：生产路径独立验证 D 根为真实卷挂载点（`GetVolumeNameForVolumeMountPointW`）、挂载点 GUID 与根目录句柄 `VOLUME_NAME_GUID` 一致、`QueryDosDeviceW` 映射必须是真实 NT 设备卷且与句柄 `VOLUME_NAME_NT` 一致、D 根与 C 根不同卷；任一步失败 `path-root-trust-anchor-invalid` fail-closed，且在创建目录/写探针/初始化锁/数据库之前生效 | 专项测试 6 项 PASS：真实 D 盘（D 挂载点 GUID=`\\?\volume{519fbe4e-…}` 与句柄一致、NT=`\device\harddiskvolume4`、D≠C）；真实 SUBST Q:→C: 候选根在信任锚阶段拒绝；注入模拟 GUID 不一致/D==C/ DOS 别名拒绝；API 失败 fail-closed |
| P2 | R3-02 真实双进程初始化锁测试同步确定性不足 | **已修复**：waiter 只有底层 `LockFileEx` 明确返回锁竞争后才发 `b-lock-contention`，并改用完整 `Database::initialize()`；creator 收到竞争确认后才创建数据库与活动 WAL；父进程确认后才放锁。观察点仅 `#[cfg(test)]` 存在，不进入生产、不是 IPC、不改变锁语义 | 专项测试 3 项 PASS；**10/10 连续多轮真实进程运行通过**；`main_db_bytes=20480`、`wal_bytes=8272`、`orphaned_sidecar=false`、`integrity=ok`、`migrations=1` |
| — | TOCTOU 残余风险 | 按 DEC-029 **已接受并延期，未修复**：不在 T1-01 内实施完整句柄相对改造/custom SQLite VFS，转入 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)；不得宣称任何情况下都不会写入 C 盘 | DEC-029；本轮未扩大修改范围 |

**回归结果（R3 返工后）：** `cargo test --workspace` **68 passed / 0 failed**（上轮 62，新增 6 项）；Release 便携验证 **106 项 PASS 90 / FAIL 0**；异常注入 **73 项 PASS 64 / FAIL 0**；真实窗口 UI/IPC/CSP **21/21、CSP 0 违规**；Release EXE **9,993,216 字节**，SHA-256 **`41A8F6B4759107625487FE605820FAABF20D312A560AE9765949027D100F7800`**。

**第三轮审计当时的门禁（历史记录）：** 当时 T1-01 尚待独立审计；第四轮复核及用户验收现已通过，T1-01 当前为验收完成。PR #1 仍未合并，main 未修改；T1-02 未开始。TOCTOU 按 DEC-029 作为已接受但未修复的残余风险单独追踪。

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
8. 应用级单实例保护尚未实现（规划在 T6-07），因此允许多个 WorkManager 实例运行。数据库首次初始化已由 `LockFileEx` 跨进程锁串行化；R2-01 修复等待锁进程的 WAL 误判，R3-02 进一步用“底层锁竞争确认信号 + 完整 `Database::initialize()` + 10/10 多轮真实双进程测试”补强测试证据。应用级单实例仍待 T6-07。
9. 启动时执行完整 `PRAGMA integrity_check`；数据库规模增大后启动耗时会增长，后续性能任务需评估改为 `quick_check` 或按需检查。
10. 正常退出时已显式关闭 SQLite 连接（触发 WAL checkpoint 并清理 `-wal`/`-shm`，实测关闭后仅剩 `work.db`）；进程被强制结束（任务管理器/断电）时无法执行该逻辑，依赖 SQLite WAL 恢复与下次启动完整性检查兜底。
11. `%LOCALAPPDATA%\EBWebView` 在本机验证开始前已存在（创建于 2024 年，本次运行前后时间戳与条目未变化）；WorkManager 专属 C 盘目录 `%LOCALAPPDATA%\com.workmanager.portable`、`%APPDATA%\com.workmanager.portable` 不存在。该共享目录的历史来源需在发布阶段审计确认。
12. **【已接受残余风险 DEC-029】路径校验 TOCTOU 未关闭：** 真实最终路径/卷身份校验与后续目录创建、写探针、初始化锁、SQLite 按路径打开之间仍非原子，存在理论竞争窗口。用户于 2026-11-18 明确接受该风险在 T1-01 内不彻底关闭，转入[独立安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。当前实现的前置校验、创建后复验和数据库初始化前复验仍保留；但不得宣称“任何情况下都不会写入 C 盘”，也不得静默回退 C 盘。后续加固需先提交句柄相对操作 + SQLite VFS/受控折衷方案设计和 PoC，未经用户另行授权不得启动。
13. **D 根卷信任锚已独立验证（R3-01 已修复）：** 生产路径现在用 `GetVolumeNameForVolumeMountPointW` 验证 D: 是真实卷挂载点、与 D 根目录句柄 `VOLUME_NAME_GUID` 一致、`QueryDosDeviceW("D:")` 映射为真实 NT 设备卷且与句柄 `VOLUME_NAME_NT` 一致、D 根与 C 根不同卷；任一步失败返回 `path-root-trust-anchor-invalid` 并在写入前 fail-closed。实测：正常 D 盘（D 挂载点 GUID=`\\?\volume{519fbe4e-…}`，NT=`\device\harddiskvolume4`，QueryDosDevice=`\Device\HarddiskVolume4`，C 盘为不同卷）、真实 SUBST Q:→C: 候选根被拒绝。**未实机验证**：真实映射网络盘、D 盘路径下真实跨卷目录挂载点、真实 D:→C: SUBST（D: 为真实物理卷无法构造）；非 Windows 降级实现未交叉编译验证。
14. 既有安全规则未变：卷类型白名单、目标真实最终路径检查、目标句柄卷身份比较、Junction 检查、0 字节库/孤儿 sidecar/数据库边界 fail-closed 全部保留；R3 返工后 Release 异常注入 73 项回归无回归。

## 下一步安排

- T1-01 第四轮独立审计及用户验收均已通过，当前状态 **验收完成**；R3-01/R3-02 代码与证据复核通过。审计报告见 [T1-01-FOURTH-AUDIT-REPORT.md](testing/reports/T1-01-FOURTH-AUDIT-REPORT.md)，用户验收记录见 [T1-01-USER-ACCEPTANCE.md](testing/reports/T1-01-USER-ACCEPTANCE.md)。PR #1 保持打开、未合并，main 未修改，T1-02 尚未开始。
- T1-01 已验收完成；PR #1 合并和 T1-02 启动均作为独立执行步骤，等待单独指示。
- TOCTOU 残余风险按 DEC-029 接受并延期至[Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复、不得宣称绝不写入 C 盘；未经用户另行授权不得开始完整句柄相对改造/custom SQLite VFS。
- 重新审计通过并同步更新开发计划后，才决定是否进入 T1-02；开发代理不得自行开始 T1-02。
- T0-05 不再安排开发；T0-06 延期至阶段 6，不得从最终发布验收清单中删除。
- 备份策略（OPEN-001/002/003）未确认前，不实施、也不宣称自动备份。

## 进度口径

- 文档调整完成不等于代码实现完成。
- 代码完成不等于测试通过。
- 测试通过不等于独立审计通过。
- 每个任务只有在测试证据可复核、独立审计通过并同步更新开发计划后，才标记为验收完成。


## 第四轮独立审计结果（2026-11-18）

- [第四轮独立审计报告](testing/reports/T1-01-FOURTH-AUDIT-REPORT.md)：R3-01 P1 与 R3-02 P2 代码审查及已提交测试证据复核通过。
- R3-01：生产信任锚调用链、D/C 卷 GUID 比较、QueryDosDevice 映射检查及 fail-closed 顺序通过复核。
- R3-02：观察器仅在 `cfg(test)` 编译；仅底层 `LockFileEx` 明确返回锁竞争时通知；waiter 走完整 `Database::initialize()`；10/10 稳定性日志通过复核。
- 审计证据来自已提交 Windows 10 脱敏日志；本轮未在开发机独立重放，GitHub 当前无 Actions/status checks。
- **当前状态：T1-01 验收完成（用户于 2026-11-18 明确确认）。** PR #1 保持打开、未合并；main 未修改；T1-02 尚未开始。
- TOCTOU 按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复；其余未实机验证场景详见第四轮审计报告。


## T1-01 用户验收结果（2026-11-18）

- 用户明确回复“接受”，确认接受 T1-01 当前交付，包括第四轮独立审计结论及 DEC-029 中已接受但未修复的 TOCTOU 残余风险。
- **T1-01：验收完成。** 验收记录见 [T1-01-USER-ACCEPTANCE.md](testing/reports/T1-01-USER-ACCEPTANCE.md)。
- PR #1 仍保持 Open、未合并；本次验收记录不自动执行合并，main 保持不变。
- T1-02 尚未开始，等待单独启动指示。
- TOCTOU 继续由 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2) 跟踪，仍未修复；不得宣称绝对不会写入 C 盘。
