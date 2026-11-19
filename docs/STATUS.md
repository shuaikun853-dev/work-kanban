# WorkManager 开发状态

**更新日期：** 2026-11-19  
**当前阶段：** 阶段 1：基础架构与工作事项  
**最近完成任务：** T1-02 项目创建、编辑、归档（用户验收完成，PR #7 已合并）  
**当前任务：** T1-03 工作事项快速创建和待安排区域（**第二轮定向修复完成，等待第二轮独立审计**：PR #8 Open，未合并）
**总体状态：** 阶段 0 已放行；阶段 1 进行中。T1-01、T1-02 均已完成用户验收并合并到 `main`。T1-02 第二轮独立审计通过；PR #7 合并提交 `ab6aba32a94d7d091b20f0ab49b25badf26377c4`。T1-03 第一轮独立审计未通过后，已按四项审计问题（P2-01 机器信息/原始日志、P2-02 Rust/TS DTO 契约、P3-01 创建/刷新提示时机、P3-02 UAT 路径安全）完成定向修复、自动化测试、Release 实测与证据脱敏，并重写分支历史清理机器信息；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 等待第二轮独立审计。开发代理不自行宣布审计/验收通过。T1-04 / T1-05 未启动。TOCTOU 仍按 DEC-029 接受并延期至独立安全加固 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复，不作绝对 C 盘写入保证。

## 最新产品决策

2026-11-19，用户确认采用 DEC-033：新建工作事项只能关联未归档项目；项目选择器不展示归档项目，Rust Core 在创建事务内拒绝已归档项目 ID；不归属项目仍允许创建，已有工作历史关联保留。

2026-11-17，用户确认采用 DEC-028：

- 第一版取消六位数字应用密码、SQLCipher 和 DPAPI。
- 使用普通 SQLite，不对数据库文件提供应用层加密。
- 保留 D 盘便携本地存储，不上传工作数据。
- 保留数据库事务、版本化 migration、异常保护和备份恢复。
- 接受普通 SQLite 文件可被拥有文件访问权限的人直接读取的风险。

2026-11-18，用户确认 DEC-029：接受当前路径校验与后续路径字符串写入之间的 TOCTOU 残余风险，T1-01 不实施完整句柄相对改造/custom SQLite VFS；该风险转入[独立安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。风险未修复，程序不得宣称绝对不会写入 C 盘；禁止静默回退 C 盘和已检测违规 fail-closed 规则不变。R3-01/R3-02 已经修复并通过第四轮独立审计；用户于 2026-11-18 明确验收 T1-01。

## UI 设计基线（DEC-030，2026-11-18）

- 用户已确认简洁 Apple 风格、Windows 原生桌面 UI 原型；以工作总览和今日工作作为两个核心页面。
- 设计规范：[UI 设计规范](design/UI-DESIGN-SPEC.md)；原型图：[workmanager-ui-prototype.svg](design/assets/workmanager-ui-prototype.svg)。PR #4 已于 2026-11-18 合并到 main，合并提交 `938f21c`。
- 首页优先展示今日要做、今日已完成、当前工作；复盘与待跟进降为次级信息；禁止堆叠统计图表和无关指标。
- 前端组件分层、Design Tokens、typed Bridge、CSS 隔离和 UI 回归规则已写入 UI 规范、技术架构和 AGENTS.md。
- **T1-02 已进入开发：项目 CRUD + UI 基础应用壳/导航 + 项目管理页面。**
- **T1-02 已验收完成并合并。** 第二轮独立审计通过；用户于 2026-11-19 明确接受；PR #7 合并提交 `ab6aba32a94d7d091b20f0ab49b25badf26377c4`。详见 [第二轮独立审计报告](testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-REPORT.md)、[机器可读审计证据](testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-evidence.json) 和 [用户验收记录](testing/reports/T1-02-USER-ACCEPTANCE.md)。
- **T1-03 第二轮定向修复完成，等待第二轮独立审计。** 任务说明：[T1-03-Quick-Work-Item-Creation.md](development/tasks/T1-03-Quick-Work-Item-Creation.md)；开发设计：[T1-03-Implementation-Design.md](development/tasks/T1-03-Implementation-Design.md)；分支 `task/T1-03-quick-create-pending`；第二轮修复提交 `12b1bdf`（P2-02）、`2d91c92`（P3-01/P3-02），P2-01 历史清理提交 `b6cf344`；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open。报告：[T1-03-REPORT.md](testing/reports/T1-03-REPORT.md)；证据：[T1-03-assets/](testing/reports/T1-03-assets/README.md)。

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
| T1-01 | 正式工程骨架、便携路径接入与 SQLite 基础设施 | **验收完成**（用户 2026-11-18 确认；PR #1 已合并到 main，commit `260e6c0`；TOCTOU 按 DEC-029 接受并延期至 Issue #2） |
| T1-02 | 项目创建、编辑、归档 | **验收完成，PR #7 已合并** |
| T1-03 | 工作事项快速创建和待安排区域 | **第二轮定向修复完成，等待第二轮独立审计**（P2-02/P3-01/P3-02 提交 `12b1bdf`、`2d91c92`；P2-01 历史清理 `b6cf344`；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) Open，未合并） |
| T1-04 | 多项目独立副本创建 | 未开始 |
| T1-05 | 工作事项状态流转和历史记录 | 未开始 |
| T1-06 | 六位数字应用密码与锁屏 | 取消 |
| T1-07 | 首次初始化与 SQLite 异常保护 | 未开始 |

**当前交付物：** [T1-01 开发任务说明](development/tasks/T1-01-SQLite-Foundation.md)、[T1-02 开发任务说明](development/tasks/T1-02-Project-Management.md)、[T1-02 测试与交付报告](testing/reports/T1-02-REPORT.md)、[T1-02 机器可读证据](testing/reports/T1-02-evidence.json)、[T1-02 返工修复报告](testing/reports/T1-02-AUDIT-FIX-REPORT.md)、[T1-02 返工修复机器可读证据](testing/reports/T1-02-AUDIT-FIX-evidence.json)、[T1-02 第二轮独立审计报告](testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-REPORT.md)、[T1-02 第二轮审计机器证据](testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-evidence.json)、[T1-02 用户验收清单](testing/reports/T1-02-USER-ACCEPTANCE.md)、[T1-03 开发任务说明](development/tasks/T1-03-Quick-Work-Item-Creation.md)、[T1-03 开发设计](development/tasks/T1-03-Implementation-Design.md)、[T1-03 测试与交付报告](testing/reports/T1-03-REPORT.md)、[T1-03 截图与机器可读证据](testing/reports/T1-03-assets/README.md)、[T1-03 PR #8](https://github.com/shuaikun853-dev/work-kanban/pull/8)、[R3 专项修复报告](testing/reports/T1-01-R3-FIX-REPORT.md)、[R3 机器可读证据](testing/reports/T1-01-R3-FIX-evidence.json)、第二轮返工报告与证据、[第三轮独立审计报告](testing/reports/T1-01-THIRD-AUDIT-REPORT.md)、[TOCTOU 后续安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)、历史审计/返工报告、[Pull Request #1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（T1-01 已用户验收并合并）；[第四轮独立审计报告](testing/reports/T1-01-FOURTH-AUDIT-REPORT.md)、[T1-01 用户验收记录](testing/reports/T1-01-USER-ACCEPTANCE.md)。

### T1-01 历史交付摘要（2026-11-17，第二轮返工后；R3 最终结果见下文）

- 正式 Tauri 2 + Svelte 5 + TypeScript + Vite 工程可构建；`workmanager-core`（Rust Core，不依赖 Tauri）与 `src-tauri`（Tauri 适配层）职责分离。
- Release 数据目录跟随 EXE：`<exe目录>/data/database/work.db`；WebView2 绝对数据目录 `<data>/cache/webview2`；仅 D 盘、无 C 盘/AppData/Temp 回退；已实现 Win32 真实最终路径和目标卷身份校验，实测拒绝 D→C Junction，并实测 SUBST Q:→C: 场景。**截至该历史快照，D 根卷自身的独立信任锚验证仍有 R3-01 待修复；该问题已在 R3 后续修复并经第四轮独立审计通过。映射网络盘、真实跨卷挂载点仍未实机验证。**
- 普通 bundled SQLite 3.54.1：WAL、`foreign_keys=ON`、`synchronous=FULL`、`busy_timeout=5000`、`temp_store=MEMORY`；启动时完整性检查与外键检查；已有数据库先做只读预检查（版本/完整性/外键/兼容性）后才应用持久化 PRAGMA。
- schema 版本 1（`schema_migrations`、`settings`）；`PRAGMA user_version` + 编号 SQL migration，每个 migration 独立事务、失败回滚；首次初始化临时库 + 硬链接原子安装 + 跨进程初始化锁；0 字节库/孤儿 WAL/journal 均 fail-closed 且保留原文件。
- 最小健康检查窗口已实现并通过真实 Release WebView2 端到端验证（页面渲染 + 异步 `get_database_health` IPC 返回 + 截图 + CSP 0 违规）。
- 已执行（第二轮返工后）：`cargo fmt --check` / `cargo check` / `cargo test --workspace`（**62 项通过**，新增 10 项）/ `npm run check` / `npm run build` / `npm run tauri build -- --no-bundle`（成功，EXE **9,980,928 字节**，SHA-256 **`849E803D…019E`**）/ Release 运行时专项验证（便携 106 项 PASS 90 / FAIL 0；异常注入 **73 项** PASS 64 / FAIL 0）/ 真实窗口 UI/IPC/CSP 21/21 / 重启持久化 / Release 忽略测试环境变量 / D 盘真实卷身份与 SUBST 卷别名测试。
- 新增专项：R2-01 确定性真实双进程“等待锁进程遇到活动 WAL”测试；R2-02 正式目录 Junction 别名绕过测试（resolve / ensure_directories / Database::initialize 三阶段拒绝）；R2-03 卷 GUID 与 NT 设备卷身份交叉核验 + 真实 SUBST→C 实机测试。
- **未实现**：项目与工作事项 CRUD、每日计划、复盘、日报/周报、附件、自动备份、密码/锁屏/SQLCipher/DPAPI。T1-01 只是基础设施，不代表业务功能已实现。
- **已接受的残余风险（DEC-029）：** R2-03 TOCTOU 未关闭，用户接受 T1-01 暂不实施句柄相对改造，并转入[Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。这不是修复；不得宣称任何情况下都不会写入 C 盘。该历史快照形成时仍需修复 R3-01 P1、补强 R3-02 P2；两项后续均已修复并经第四轮独立审计通过，用户已验收 T1-01。

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

- T1-01 第四轮独立审计及用户验收均已通过，当前状态 **验收完成**；T1-01 代码与 UI 设计文档均已合并到 main。
- **T1-02 项目管理：已完成。** 第二轮独立审计通过、用户已于 2026-11-19 明确接受，PR #7 已合并到 main（`ab6aba32a94d7d091b20f0ab49b25badf26377c4`）。
- **T1-03 第二轮定向修复完成，等待第二轮独立审计。** 分支 `task/T1-03-quick-create-pending`；第一轮实现提交 `be8d9c2`；第二轮修复提交 `12b1bdf`（P2-02）、`2d91c92`（P3-01/P3-02）；P2-01 证据脱敏与分支历史清理提交 `b6cf344`；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open，不合并；详细测试与证据见 [T1-03-REPORT.md](testing/reports/T1-03-REPORT.md)。
- TOCTOU 残余风险按 DEC-029 接受并延期至[Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复、不得宣称绝不写入 C 盘；未经用户另行授权不得开始完整句柄相对改造/custom SQLite VFS。
- 备份策略（OPEN-001/002/003）未确认前，不实施、也不宣称自动备份。
- 最小化提醒/Toast、托盘、单实例等系统集成仍按计划在阶段 6（T6-07）验收。

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
- **当前状态：T1-01 验收完成（用户于 2026-11-18 明确确认）。** PR #1 已合并到 main（commit `260e6c0`）；UI 设计文档 PR #4 已合并（commit `938f21c`）；T1-02 尚未开始。
- TOCTOU 按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复；其余未实机验证场景详见第四轮审计报告。


## T1-01 用户验收结果（2026-11-18）

- 用户明确回复“接受”，确认接受 T1-01 当前交付，包括第四轮独立审计结论及 DEC-029 中已接受但未修复的 TOCTOU 残余风险。
- **T1-01：验收完成。** 验收记录见 [T1-01-USER-ACCEPTANCE.md](testing/reports/T1-01-USER-ACCEPTANCE.md)。
- 验收记录形成时 PR #1 仍为 Open、未合并；之后 PR #1 于 2026-11-18 合并到 main（commit `260e6c0`）。
- T1-02 已启动，当前处于开发中；完成后进入待审计。
- TOCTOU 继续由 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2) 跟踪，仍未修复；不得宣称绝对不会写入 C 盘。


## T1-01 PR 合并结果（2026-11-18）

- T1-01 用户验收完成后，PR #1 于 2026-11-18 10:07（北京时间）合并到 main。
- 合并提交：`260e6c07802a297529d8bda1e2d9239fca90fc10`。
- **T1-01 代码现已进入 main；T1-02 已于 2026-11-18 启动开发。**

## T1-02 交付结果（2026-11-19，独立审计、用户验收及 PR 合并全部完成）

**任务：** 项目创建、编辑、归档。  
**分支：** `task/T1-02-project-management`（基于 main `0cafde6`）；[PR #7](https://github.com/shuaikun853-dev/work-kanban/pull/7)，**已合并**；合并提交 `ab6aba32a94d7d091b20f0ab49b25badf26377c4`。  
**状态：** **验收完成**。第二轮独立审计通过；用户于 2026-11-19 明确接受；PR #7 已合并到 main。T1-03 尚未开始，等待单独启动指示。

### 实现范围

- **Migration：** 新增 `0002_projects.sql`，schema version 1 → 2；`projects(id, name, is_archived, created_at, updated_at)`；沿用 T1-01 的 `user_version` + 事务化 migration，未修改 0001 历史。
- **Rust Core：** `crates/workmanager-core/src/projects/`（model/repository/service/error）；`Database::write_transaction` 提供 `IMMEDIATE` 写事务与失败回滚；项目 ID 由 Core 生成 UUID；归档为 UPDATE 标记，不删除记录；已归档项目只读并保留在列表。
- **Tauri IPC：** `list_projects`、`create_project`、`update_project`、`archive_project`，typed 请求/响应 DTO + 稳定 `{code,message}` 错误；无任意 SQL / 任意文件接口。
- **前端：** Design Tokens、AppShell、Sidebar、navigation、typed Bridge/DTO Contracts；设置 → 项目管理页面含列表、新建、编辑、归档、loading/空/错误状态、长名称处理；数据库诊断页迁移后功能保留；工作总览/今日工作为结构页并明确标注业务数据未接入（不展示虚构数据）。
- **保留整合：** 会话开始前工作区未提交的 DEC-032 自定义标题栏实现已纳入分支并在 Release 实测（最大化/还原、关闭按钮真实退出）。
- **未实现：** T1-03 / T1-04 / T1-05、每日计划、复盘、报表、附件、备份恢复、TOCTOU 加固。

### 第一轮独立审计问题修复（2026-11-18）

- **P2-01：** 审计点名 9 处 + 静态检查覆盖范围内 23 处，共 **32 处**组件/UI CSS 原始颜色收敛为语义 Design Token（新增 20 个 Token，取值与修改前一致，视觉不变）；新增 `scripts/quality/check-design-tokens.mjs` 与 8 项正反向自测并接入 `npm run check`（18 文件 / 0 违规 / 8/8 PASS）。
- **P3-01：** `src-tauri/src/lib.rs` 过期命令注释已更新为数据库健康检查 + 项目 CRUD；未改命令注册、IPC 或 DTO。
- **P3-02：** Release UI E2E 改为确定性等待（reload 新文档 boot marker、应用壳 + Tauri IPC 就绪、项目 Loading 终态）并保留失败诊断；只改测试脚本，不改产品业务逻辑，空状态与最小窗口断言保留。
- **统计口径：** 主检查 73 项正确；最小窗口实际执行 12 项（旧证据 JSON 因关闭按钮前写盘只持久化 11 项，审计报告 12/12 正确）；返工后 12 项全部写入证据 JSON，并由编排记录进程真实退出码。
- **修复提交：** `881e755`（P2-01 Design Token）、`c3593e6`（P3-01 过期注释）、`a9e4198`（P3-02 E2E 稳定性）、`8e215f8`（证据与文档）。
- 详细证据：[T1-02-AUDIT-FIX-REPORT.md](testing/reports/T1-02-AUDIT-FIX-REPORT.md)、[T1-02-AUDIT-FIX-evidence.json](testing/reports/T1-02-AUDIT-FIX-evidence.json)、[T1-02-AUDIT-FIX-assets/](testing/reports/T1-02-AUDIT-FIX-assets/README.md)。

### 验证结果（详见 [T1-02-REPORT.md](testing/reports/T1-02-REPORT.md)）

| 项目 | 结果 |
|---|---|
| `cargo fmt --all -- --check` | PASS |
| `cargo check --workspace --all-targets` | PASS（无 warning） |
| `cargo test --workspace` | **90 passed / 0 failed** |
| `npm run check` | svelte-check 0 errors / 0 warnings；Design Token 检查 18 文件 / 0 违规；Token 自测 8/8 |
| `npm run build` | PASS |
| `npm run tauri build -- --no-bundle` | PASS |
| Release UI/IPC（真实窗口 + 真实 IPC，连续 5 次） | **每次 主检查 73/73 + 最小窗口 12/12**，关闭按钮真实退出（退出码 0），CSP 0，未捕获异常 0 |
| 继承便携验证 | **106 项，90 PASS / 0 FAIL / 1 WARN（既有 EBWebView 历史目录）** |
| 继承异常注入 | **73 项，64 PASS / 0 FAIL** |
| T1-01 诊断页 UI 回归（新 EXE） | 24/24 |
| Release EXE | **10,230,784 字节**；SHA-256 `51BBBA8DD17103D742E1BD4A85B83377F7578D34584F2206F30EDFEC8D3DC7F6` |

### 已知风险 / 未覆盖

- 第一轮独立审计首次失败运行（`projects empty state` 超时）的原始日志不在仓库中；本次基线复现尝试 2/2 通过、未能复现，P3-02 按测试等待策略问题处理，未发现产品逻辑缺陷。
- 项目名称唯一性、删除/恢复、排序偏好等 PRD 未定义行为未实现。
- 归档历史关联测试使用测试探针表模拟未来 work_items；正式关联属于 T1-03。
- 仓库仍无前端组件测试/视觉回归框架；UI 证据来自真实 Release CDP 脚本与截图。
- Design Token 静态检查不覆盖 Svelte `style:` 指令与脚本动态颜色（当前代码无此用法）。
- TOCTOU 按 DEC-029 未修复，延期至 Issue #2；普通 SQLite 未加密；备份策略未确认。
- **T1-03 未开始。**


## T1-02 第二轮独立审计结论（2026-11-19）

- **独立审计结论：通过。** 审计代码基线 `8123e0354bc3d3393944a323ecd59f709ac3b051`；P2-01 第五轮专项复核通过，组件 `style` prop 不再误报，原生 HTML 大小写属性与条件分支回归未退化。
- **独立回归：** `cargo fmt --all -- --check`、`cargo check --workspace --all-targets`、`cargo test --workspace`（90/90）、`npm run check`（0 errors / 0 warnings，18 文件 0 违规，49/49）、`npm run build`（156 modules）均通过；Release UI E2E 连续 5/5 通过，每次主检查 73/73、最小窗口 12/12、CSP 0、页面未捕获异常 0、关闭进程退出码 0。
- **当时门禁：** 第二轮独立审计通过后进入待用户验收；用户随后于 2026-11-19 明确接受，PR #7 已合并。当前 T1-02 验收完成；T1-03 尚未启动。
- 审计报告：[T1-02 第二轮独立审计报告](testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-REPORT.md)；机器证据：[T1-02 第二轮审计证据](testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-evidence.json)；用户验收清单：[T1-02-USER-ACCEPTANCE.md](testing/reports/T1-02-USER-ACCEPTANCE.md)。


## T1-02 用户验收结论（2026-11-19）

- **用户结论：接受 T1-02。** 用户于 2026-11-19 在当前对话明确回复“接受 T1-02”。
- **状态：** 用户验收通过，PR #7 已合并到 main，合并提交 `ab6aba32a94d7d091b20f0ab49b25badf26377c4`；T1-02 标记为验收完成。T1-03 尚未启动，等待用户单独指示。
- **验收记录：** [T1-02-USER-ACCEPTANCE.md](testing/reports/T1-02-USER-ACCEPTANCE.md)。用户整体接受结论已记录；对话未逐项回填清单，不伪造逐项操作记录。


## T1-02 最终交付状态（2026-11-19）

- **最终状态：验收完成。** 第二轮独立审计通过；用户明确回复“接受 T1-02”；PR #7 已合并。
- **合并提交：** `ab6aba32a94d7d091b20f0ab49b25badf26377c4`；当前 `main` HEAD 与该提交一致。
- **下一任务：** T1-03 工作事项快速创建和待安排区域，当前未开始；等待用户单独启动指示。


## T1-03 开发启动记录（2026-11-19）

- 用户已明确授权启动 T1-03「工作事项快速创建和待安排区域」。
- 开发分支：`task/T1-03-quick-create-pending`；基线 main：`018e851e8daf5835391a7b61caf881bc57c2ad42`。
- 任务说明：`docs/development/tasks/T1-03-Quick-Work-Item-Creation.md`。
- 当前状态：开发准备中；归档项目是否允许被新建工作选择待用户确认。确认前不擅自实现该规则。
- T1-04、T1-05 均未启动；本任务完成自测后进入独立审计，不自行合并 PR。


## T1-03 项目归属规则确认（2026-11-19）

用户明确确认：**新建工作事项不允许选择已归档项目**。已记录为 DEC-033，并同步更新 PRD V0.3.2 与 T1-03 任务说明。实现时，前端只展示未归档项目，Rust Core 必须在创建事务内拒绝已归档项目 ID；不归属项目仍可创建；既有工作事项的项目历史关联必须保留。

## T1-03 开发与自测结果（2026-11-19，待独立审计）

**任务：** 工作事项快速创建和待安排区域（T1-03）。
**分支：** `task/T1-03-quick-create-pending`（基线 `018e851`）；实现提交 `be8d9c2e9c78710690de189936d6ee65f48ed8df`；[PR #8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 指向 main，保持 **Open**。
**状态：** **待独立审计**。代码、自动化测试、Windows Release 实测与证据已完成；开发代理不自行宣布审计通过或用户验收完成；未合并 PR、未修改 main。

### 实现范围

- **Migration：** 新增 `0003_work_items.sql`，schema version 2 → 3；`work_items` 表含稳定 ID、可空 `project_id`（外键 `ON DELETE RESTRICT`）、标题 CHECK、生命周期五值 CHECK、可空 `importance/urgency`（1–5 或 NULL）、可空 `due_date/description`、时间戳与待安排索引；未修改 0001/0002。
- **Rust Core：** 新增 `crates/workmanager-core/src/work_items/`（model/repository/service/error）；标题 trim 后非空；Core 生成 UUID；默认 `pending`；相同标题独立记录；**DEC-033：项目存在性与 `is_archived = 0` 校验与插入在同一个 `IMMEDIATE` 事务内**；待安排查询只返回 `pending`，含未归属与归档项目历史关联；归档不改写既有 `project_id`。
- **Tauri IPC：** `create_work_item`、`list_pending_work_items`；serde camelCase、请求 `deny_unknown_fields`、`spawn_blocking`、结构化错误 `work-item-title-empty` / `project-not-found` / `project-archived`。
- **前端：** 今日工作页下“待安排”次级视图（**不新增一级导航**、未修改 AppShell/Sidebar/Design Tokens）+ 快速创建对话框（仅标题 + 可选未归档项目 + 保存/取消）；loading/empty/error/list 状态；重复提交保护；创建成功后从后端重新读取；归档竞态错误提示并刷新选项；归档项目历史关联显示“项目已归档”。
- **验证工具：** T1-03 Release E2E（主检查 70 项、最小窗口 12 项、重启持久化 17 项、数据库探针 25 项）、Bridge 运行时契约 Node 测试 10 项（接入 `npm run check`）。

### 验证结果

| 项目 | 结果 |
|---|---|
| `cargo fmt --all -- --check` | PASS（退出码 0） |
| `cargo check --workspace --all-targets` | PASS（退出码 0） |
| `cargo test --workspace` | **123 passed / 0 failed**（基线 90 + 新增 33） |
| `npm run check` | PASS（svelte-check 0/0；Bridge 10/10；Design Token 49/49） |
| `npm run build` | PASS |
| T1-03 Release 主 UI/IPC | **70/70 PASS** |
| T1-03 最小窗口 860×640 + 真实关闭 | **12/12 PASS**，进程退出码 **0** |
| T1-03 关闭重开持久化 | **17/17 PASS**，进程退出码 **0** |
| T1-03 数据库只读探针 | **25/25 PASS**（关闭后/重启后） |
| 继承便携验证 | **106 项，90 PASS / 0 FAIL / 1 WARN** |
| 继承异常注入 | **73 项，64 PASS / 0 FAIL** |
| 继承 T1-02 Release UI E2E | 主 73/73；最小窗口 12/12；关闭退出码 0 |
| Release EXE | **10,351,616 字节**；SHA-256 `22af942fe2817388596118fc7cb66f34fce4e8c5e2367fe1a2942dc13dd66b23` |

### 证据

- 测试报告：[T1-03-REPORT.md](testing/reports/T1-03-REPORT.md)
- 证据索引与截图：[T1-03-assets/](testing/reports/T1-03-assets/README.md)
- 预编码设计：[T1-03-Implementation-Design.md](development/tasks/T1-03-Implementation-Design.md)
- PR：[#8](https://github.com/shuaikun853-dev/work-kanban/pull/8)

### 遗留风险 / 未覆盖

- 普通 SQLite 未加密（DEC-028 已接受）；TOCTOU 按 DEC-029 未修复并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。
- 待安排排序固定为 `created_at DESC, id DESC`；手动排序/优先级/状态流转/计划/复盘/附件/报表/备份恢复属于后续任务，本任务未实现。
- 继承验证脚本仅更新 schema 版本断言（2 → 3），未改变产品行为。
- **下一步：** 等待独立审计；审计通过前不合并 PR、不开始 T1-04/T1-05。

## T1-03 第二轮定向修复结果（2026-11-19，等待第二轮独立审计）

**任务：** T1-03 工作事项快速创建和待安排区域 — 第一轮独立审计四项问题定向修复。
**当前状态：** **第二轮定向修复完成，等待第二轮独立审计**。PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open；main 未修改。

### 修复内容

| 审计问题 | 修复 | 验证 |
|---|---|---|
| **P2-01** 原始日志与机器信息提交 | 删除 `T1-03-assets/logs/`（9 个原始日志）；11 个 JSON 证据脱敏；新增 `SANITIZATION.md`；重写本任务分支 docs/evidence 提交并 `--force-with-lease` 推送（旧 HEAD `2342828` → 新 HEAD `b6cf344`；本地恢复分支/bundle 保留） | 当前证据扫描 0 命中；脱敏前后结构一致性 11/11；分支新增历史深度扫描 0 命中 |
| **P2-02** Rust / TS DTO 契约不一致 | `WorkItemDto` 统一为 Rust 实际 10 字段；Bridge 严格拒绝缺字段/类型错误/非法状态/未知字段；Rust 完整序列化测试；Node 契约测试 17 项 | Rust 124/124；Bridge 17/17；真实 E2E 创建响应严格校验通过 |
| **P3-01** 创建成功提示时机不准确 | 创建成功/列表刷新成功/刷新失败三态分离；刷新成功后才提示已更新；失败显示 warning + 重试；不重复创建 | E2E 中间态/成功态/失败/重试/无重复创建断言；2 张新截图 |
| **P3-02** UAT 脚本缺少数据库复用保护 | 新增 `T1-03UatPath.ps1`：规范化路径、限定专用测试根目录、拒绝正式目录/根目录外/`..` 越界/已知数据库/非空目录；不删除/不覆盖 | 路径安全专项 23/23 PASS；不安全目录编排退出码 2 |

### 验证结果

| 项目 | 结果 |
|---|---|
| `cargo fmt --all -- --check` / `cargo check --workspace --all-targets` | PASS（退出码 0） |
| `cargo test --workspace` | **124 passed / 0 failed** |
| `npm run check` | PASS（svelte-check 0/0；Bridge 17/17；Design Token 49/49） |
| `npm run build` | PASS |
| Bridge DTO 专项（`node --test scripts/quality/work-item-bridge.test.mjs`） | **17/17 PASS** |
| UAT 路径安全专项（`test-t1-03-uat-path.ps1`） | **23/23 PASS** |
| T1-03 Release 主 UI/IPC（新 EXE） | **84/84 PASS** |
| T1-03 最小窗口 + 真实关闭 | **12/12 PASS**，退出码 0 |
| T1-03 关闭重开持久化 | **17/17 PASS**，退出码 0 |
| T1-03 数据库只读探针 | **25/25 PASS**（main 后 5 条 / 重启后 6 条；外键 0 违规） |
| 继承便携验证 | **106 项，90 PASS / 0 FAIL / 1 WARN 保留** |
| 继承异常注入 | **73 项，64 PASS / 0 FAIL** |
| 继承 T1-02 UI E2E | 主 73/73；最小窗口 12/12；关闭退出码 0 |
| Release EXE | **10,352,128 字节**；SHA-256 `3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3` |

### 证据与 Git

- 报告：[T1-03-REPORT.md](testing/reports/T1-03-REPORT.md)
- 证据：[T1-03-assets/](testing/reports/T1-03-assets/README.md)（19 张截图、11 个脱敏 JSON、脱敏说明）
- 第二轮修复提交：`12b1bdf`（P2-02）、`2d91c92`（P3-01/P3-02）；历史清理提交 `b6cf344`
- PR：[#8](https://github.com/shuaikun853-dev/work-kanban/pull/8)（Open，不合并）

### 遗留风险

- 尚未第二轮独立审计/用户验收；普通 SQLite 未加密（DEC-028）；TOCTOU 按 DEC-029 延期至 Issue #2。
- 仓库基线 main 中既有 T1-01/T1-02 历史证据仍含同类机器信息（非本 PR 新增，未扩大修改）。
- GitHub 不可达对象可能保留有限缓存；不能宣称服务端立即物理删除。