# WorkManager 开发计划书

**文档版本：** V2.0  
**编制日期：** 2026-11-19  
**文档状态：** 开发执行基线（阶段 0 已放行；T1-01、T1-02 均已验收完成并合并到 main；T1-03 第三轮独立审计未通过，第四轮 F1/F2 定向修复完成，等待第四轮独立审计；P2-01 待 GitHub Support 服务端历史清理后关闭；TOCTOU 按 DEC-029 接受并延期） \
**项目目标：** Windows 10 本地工作管理软件  
**开发方式：** AI Agent 辅助开发 + 独立审计 + 用户验收  
**当前进度：** 阶段 0 已放行；T1-01、T1-02 均已验收完成并合并到 main。T1-03「工作事项快速创建和待安排区域」第一轮独立审计未通过后，已完成三轮定向修复；第三轮独立审计未通过，阻塞项为 F1（测试根目录未验证就创建沙箱）与 F2（Junction 清理失败仍递归删除）。第四轮已修复 F1/F2：测试根目录在任何写操作前完成 Windows 原生信任锚验证，缺失/身份无法确认时 fail closed 且不自动创建；清理在链接删除失败/链接仍存在/未预期 reparse point/身份变化时停止整个沙箱递归删除并保留现场；路径安全专项 93 项（第三轮 60 项全部保留）、FAILED=0、SKIPPED=1（显式记录），质量门禁、Release E2E、路径安全专项与继承回归均通过；第四轮同时修正了第三轮遗留的 UAT 目录/资产数/提交数/PR 正文与评论数不一致。P2-01 复核仍为具体机器标识 0 命中，但旧提交 `2342828` 仍可经 GitHub API 读取（9 个原始日志仍可列出/下载），GitHub Support 服务端清理未完成（需仓库所有者提交工单），**P2-01 仍未关闭**。PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open，main 未修改；T1-04 已按用户 2026-11-24 授权堆叠开发（开发与自测完成，等待独立审计；PR #8 未合并前不创建 T1-04 main PR），T1-05 未启动。TOCTOU 按 DEC-029 接受并延期至[Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，仍未修复。

---

## 1. 文档目的与依据

本计划书把产品需求、技术架构和用户已确认决策转换成可执行、可测试、可审计的开发任务。它是开发任务拆分和进度跟踪的主文档。

### 1.1 权威依据

| 文档 | 用途 |
|---|---|
| [产品需求规格说明书 PRD V0.3.1](../requirements/PRD.md) | 产品范围、业务规则、用户体验和产品验收标准 |
| [技术架构设计说明书 V0.4.1](../architecture/TECHNICAL_DESIGN.md) | 技术栈、模块边界、数据模型、安全、测试与技术任务 |
| [用户决策记录](../decisions/DECISIONS.md) | 已确认决策和待确认事项 |
| [AI Agent 开发规范](../../AGENTS.md) | AI Agent 必须遵守的开发、安全和 Git 规则 |
| [开发状态](../STATUS.md) | 当前进度摘要和阶段状态 |

如文档发生冲突，先暂停受影响的实现，核对用户最新明确决定并更新决策记录；不得自行选择更方便实现的方案。

### 1.2 计划管理原则

1. 阶段 0 已按 DEC-028 放行；阶段 1 业务开发立即开始，剩余系统集成验证在发布阶段补齐。
2. 采用模块化单体：Tauri 2 + Svelte 5 + TypeScript + Rust + 独立 Rust Core + 普通 SQLite。
3. 按可独立演示的纵向切片开发，任务覆盖 UI、IPC、业务层、数据库和测试，不以孤立页面或孤立接口作为交付。
4. 业务规则优先由 Rust Core 实现；前端不得直接访问 SQLite 或执行 SQL。
5. 每个任务必须有明确验收标准、测试证据和 Git 变更记录。
6. 开发代理的自我声明不等于验收结论；由独立审计核验后才能更新为完成。
7. 不一次性让 AI Agent 无边界地持续开发；每轮提示词只授权明确任务和范围。
8. 完全自研，可以研究开源项目的架构与交互，不复制、移植或改写第三方应用源代码。

---

## 2. 产品目标与不可变约束

### 2.1 产品目标

让用户准确知道哪些工作已完成、哪些工作有推进但未完成、哪些工作没有执行、哪些工作仍在进行或待安排，并保留可追溯的每日执行历史。

系统不得为了提高完成率或美化日报而推断工作已经完成。

### 2.2 必须遵守的约束

- 目标平台：Windows 10。
- 部署方式：绿色便携版，默认目录为 D:\WorkManager。
- 整个应用文件夹移动后，必须根据 EXE 新位置重新定位数据库和配置。
- SQLite 数据库、WebView2 用户数据、缓存、日志、临时文件、备份和应用配置全部位于 D 盘便携目录。
- 不得静默写入 C 盘，不得回退到 AppData、LocalAppData 或系统 Temp；D 盘不可用或不可写时必须明确失败。
- 工作数据本地保存，不上传云端；不增加未经批准的遥测、云同步或远程服务依赖。
- 第一版使用普通 SQLite，不实现六位数字应用密码、应用锁屏、SQLCipher 或 DPAPI；明确接受数据库文件未加密的风险。
- 保留 SQLite 事务、版本化 migration、异常保护和备份恢复；不得因取消加密而降低数据完整性要求。
- 工作事项生命周期状态与每日执行结果分离；某天未执行、跳过复盘均不得自动改变工作整体状态。
- 只有用户明确确认，工作事项才能标记为已完成或已放弃。
- 附件只保存原始文件路径，不复制、不读取、不上传附件内容；清理时绝不删除、移动、覆盖或重命名原始文件。
- 工作日期和业务时区统一使用 Asia/Shanghai。
- Windows Toast 默认关闭；只有用户主动授权后，才允许创建所需开始菜单快捷方式。
- 每日执行记录和日报历史摘要保留一年；已完成/已放弃工作档案按确认的三个月规则清理，具体边界待决策。

---

## 3. 技术架构与交付形态

| 层次 | 技术/职责 | 约束 |
|---|---|---|
| 桌面容器 | Tauri 2 | Windows 10 绿色便携版 |
| 前端 | Svelte 5 + TypeScript + Vite | 只负责 UI 和调用业务命令 |
| 适配层 | Tauri Commands / DTO / Events | 参数校验、调用 Core、错误转换 |
| 业务层 | 独立 Rust Core crate | 领域规则、状态流转、事务用例 |
| 数据层 | rusqlite + bundled SQLite | Rust 独占数据库访问，版本化 migration、事务和一致性备份 |
| 本地运行环境 | PortableRuntime / WebView2 | 从 EXE 位置定位 D 盘数据根目录 |
| Windows 集成 | Tray / Autostart / Notification | 遵守纯便携默认策略和用户授权边界 |

建议按领域模块组织：项目、工作事项、每日计划、当前工作、每日复盘、工作日历、提醒、日志、报表、附件、数据清理、安全与设置。

---

## 4. 阶段总览与放行规则

| 阶段 | 名称 | 主要交付 | 当前状态 |
|---|---|---|---|
| 0 | 技术验证 | 桌面壳、便携路径、WebView2 基础验证 | 已放行；SQLCipher/DPAPI 取消，系统集成验证延期至阶段 6 |
| 1 | 基础架构与工作事项 | SQLite、项目、工作事项、状态流转、历史 | 进行中；T1-01、T1-02 已验收完成并合并；**T1-03 第三轮独立审计未通过，第四轮 F1/F2 定向修复完成，等待第四轮独立审计** |
| 2 | 计划、优先级与当前工作 | 每日计划、全局排序、当前工作和切换记录 | 未开始 |
| 3 | 每日复盘与提醒 | 工作日历、复盘、补录、提醒调度 | 未开始 |
| 4 | 日志、搜索与报表 | 工作日志、历史搜索、日报、周报、月报 | 未开始 |
| 5 | 附件、数据清理与备份 | 附件路径、保留策略、清理、备份恢复 | 未开始 |
| 6 | 发布与最终验收 | 便携包、Windows 10 实机、安全、路径和离线验收 | 未开始 |

### 4.1 阶段 0 放行结论

阶段 0 已于 2026-11-17 按用户明确决策 DEC-028 放行，允许开始阶段 1。

放行依据：
- T0-01 桌面壳和 Rust IPC 已在 Windows 10 实机运行通过。
- T0-02/T0-03 的基础便携路径、WebView2 绝对目录、持久化和目录移动验证已通过。
- T0-02/T0-03 的物理拔盘、正式 D:/WorkManager 路径和 Process Monitor 级审计列为阶段 6 发布验收补测项，不阻塞业务开发。
- T0-04 SQLCipher 与 T0-05 DPAPI 因 DEC-028 明确取消，不再实施。
- T0-06 断网完整验证、托盘、开机启动和通知延期至阶段 6。
- 当前没有已知阻止普通 SQLite 业务开发的 P0 技术问题。

阶段 0 放行不代表最终发布验收完成；阶段 6 仍须验证正式路径、系统集成和数据恢复。

## 5. 阶段 0：技术验证（已放行）

**状态：** 已放行（2026-11-17）。历史验证结果保留；未完成的系统级审计在阶段 6 补测。

### T0-01：Tauri 2 + Svelte 5 Windows 桌面壳

**状态：** 验证通过。

- Windows 10 实机可启动桌面窗口。
- Svelte 页面正常加载。
- 前端按钮通过 Tauri IPC 调用 Rust 并返回结果。
- 关闭、重新启动和再次调用 IPC 均通过。
- 已知模板使用 SvelteKit 2；正式项目按技术设计优先采用 Svelte 5 + TypeScript + Vite，不应无理由引入 SvelteKit。

### T0-02：EXE 路径解析与 D 盘便携数据根目录

**状态：** 基础验证通过并放行。

- Release 按 EXE 所在目录解析数据根目录。
- Debug/Test 仅通过测试专用环境变量指定测试根目录。
- 不允许 AppData、LocalAppData 或系统 Temp 回退。
- D 盘路径不可写、路径被文件阻塞和缺失盘符等故障场景已模拟验证。
- 目录移动场景已验证。
- 物理拔除 D 盘、正式 D:/WorkManager 路径实跑和管理员级审计留待阶段 6。

### T0-03：WebView2 绝对数据目录

**状态：** 基础验证通过并放行。

- WebView2 使用 Rust 侧配置的绝对 D 盘数据目录。
- Cookie、LocalStorage 和目录移动后的持久化行为已验证。
- 文件 watcher 与全量哈希审计未发现测试期间旧 C 盘 profile 被修改。
- 本轮未安装 Process Monitor；ProcMon 级子进程文件访问审计留待阶段 6。

### T0-04：SQLCipher Windows 构建和加密验证

**状态：** 取消（DEC-028）。

第一版不使用 SQLCipher。此前独立验证报告作为历史技术实验保留，不纳入产品实现和阶段门禁。

### T0-05：DPAPI CurrentUser 密钥保护

**状态：** 取消（DEC-028）。

第一版不使用 DPAPI，也不创建数据库密钥文件。

### T0-06：断网与 Windows 集成可行性

**状态：** 延期至阶段 6。

- 断网完整运行、托盘、开机启动、单实例和通知在最终发布阶段验证。
- 不阻塞当前 SQLite、项目和工作事项功能开发。

## 6. 阶段 1：基础架构与工作事项

**目标：** 建立可迁移、可恢复的普通 SQLite 数据底座，并交付项目和工作事项的完整生命周期。

| 任务 | 内容 | 核心验收 |
|---|---|---|
| T1-01 | 正式工程骨架、便携路径接入与 SQLite 基础设施 | Tauri 2 + Svelte 5 + TypeScript + Rust 可构建；SQLite 初始化、user_version migration、外键、WAL、事务和测试通过 |
| T1-02 | 项目创建、编辑、归档 | 项目 CRUD；归档不删除工作历史 | **验收完成**（用户接受；PR #7 于 2026-11-19 合并，commit `ab6aba32a94d7d091b20f0ab49b25badf26377c4`） |
| T1-03 | 工作事项快速创建和待安排区域 | 标题快速录入并立即保存；默认待安排；仅可选未归档项目或不归属；待安排列表显示两类记录 | **第三轮独立审计未通过；第四轮 F1/F2 定向修复完成，等待第四轮独立审计**（F1 测试根目录信任锚、F2 清理 fail-closed 已修复并通过真实文件系统对象场景与受控删除失败注入（未修改 Windows ACL、未执行实际 `Access Denied` 测试）；P2-01 仍开放，待 GitHub Support 服务端清理；第四轮修复提交 `d82bdd4`，随后证据/文档同步提交；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open） |
| T1-04 | 多项目独立副本创建（整批原子提交） | 多项目创建时每个项目有独立工作记录、状态、日志和附件关联；整批原子提交 | **开发与自测完成，等待独立审计**（DEC-034 / PRD-AT-18；分支 `task/T1-04-multi-project-copies`；Release E2E 主 96/96 + 最小窗口 11/11 + 故障回滚 13/13 + 持久化 15/15 + 数据库探针 57/57；三次真实关闭退出码 0/0/0；PR #8 未合并，暂不创建 T1-04 main PR） |
| T1-05 | 工作事项状态流转和历史记录 | 待安排、未开始、进行中、已完成、已放弃规则正确；状态变更可追溯 |
| T1-06 | 六位数字应用密码与锁屏 | 取消（DEC-028）；第一版不实现 |
| T1-07 | 首次初始化与 SQLite 异常保护 | 初始化原子性；数据库损坏、migration 失败、磁盘不足时不覆盖原数据 |

### UI 设计基线（文档已确认，不是代码任务）

**状态：** 2026-11-18 用户已确认 UI 原型和视觉方向；设计文档已建立，尚未实现业务 UI 代码。

- 权威规范：[UI 设计规范](../design/UI-DESIGN-SPEC.md)；原型图位于 `docs/design/assets/workmanager-ui-prototype.svg`。
- 核心页面：工作总览、今日工作。首页首先让用户看清今天要做和今天已完成；当前工作单独突出；复盘和待跟进为次级信息。
- 前端架构：应用壳、Design Tokens、通用组件、Feature 页面、typed Bridge、DTO Contracts、纯展示函数分层。
- UI 实现并入对应业务纵向任务，不另造重复业务任务；每次只实现一个页面/一个可验证切片，附截图和回归结果。
- **T1-02 已按 DEC-032 完成自定义无边框标题栏与三色真实窗口控制**；项目管理 UI 使用已确认的 Design Tokens、AppShell、Sidebar 和紧凑桌面布局。
- **T1-03 第三轮独立审计未通过；第四轮 F1/F2 定向修复完成，等待第四轮独立审计。** 第一轮实现提交 `be8d9c2`；第二轮修复提交 `12b1bdf`（P2-02）、`2d91c92`（P3-01/P3-02）；P2-01 证据脱敏与分支历史清理提交 `b6cf344`；第三轮修复提交 `b6a54591b783049142cbbffecd107ec9086723eb`；第三轮审计基准 HEAD `489d8689484c2cf744893bd3ee08dc7b25b5c8b8`；第四轮 F1/F2 修复提交 `d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（随后为第四轮证据/文档同步提交，分支相对 main 共 22 个提交）。F1/F2 已修复并通过真实文件系统对象场景与受控删除失败注入（未修改 Windows ACL、未执行实际 `Access Denied` 测试）（信任锚写前 fail closed、清理失败不递归删除）；路径安全专项 93 项（第三轮 60 项全部保留、SKIPPED=1 显式记录）；P2-01 旧提交 `2342828` 仍可经 GitHub API 读取、GitHub Support 服务端清理未完成，**P2-01 未关闭**；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) Open。详见 [T1-03-REPORT.md](../testing/reports/T1-03-REPORT.md) 与第四轮汇总 `docs/testing/reports/T1-03-assets/evidence/round4/round4-verification-summary.json`。

### T1-01 详细范围

**当前状态（2026-11-18）：** 第四轮独立审计通过，且用户已明确验收；**T1-01 验收完成**。R2-01/R2-02/R2-04 修复逻辑复核成立；R3-01（D 根卷信任锚未独立验证，P1）已修复：生产路径用 `GetVolumeNameForVolumeMountPointW` + 根目录句柄 `VOLUME_NAME_GUID/NT` + `QueryDosDeviceW` + D/C 同卷拒绝独立验证 D 根，失败返回 `path-root-trust-anchor-invalid` 并 fail-closed；R3-02（真实双进程初始化锁测试同步确定性，P2）已修复：waiter 只在底层 `LockFileEx` 明确返回锁竞争后才发信号，并走完整 `Database::initialize()`，creator 收到确认后才建库，10/10 多轮真实进程测试通过。修复代码提交：R3-01 `ae1eb65`、R3-02 `4942eb0`。TOCTOU 残余风险未修复，但用户已按 DEC-029 接受延期至[独立安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，不作为 T1-01 单独阻塞项。详见 [T1-01-R3-FIX-REPORT.md](../testing/reports/T1-01-R3-FIX-REPORT.md) 与 [第三轮独立审计报告](../testing/reports/T1-01-THIRD-AUDIT-REPORT.md)。用户已验收 T1-01。PR #1 已于 2026-11-18 合并到 main（commit `260e6c0`）；T1-02 已完成开发与自测，当前“待审计”，详见 [T1-02 测试与交付报告](../testing/reports/T1-02-REPORT.md)。

**实际实现范围：**

- 正式仓库从文档仓库升级为可构建的 Tauri 2 + Svelte 5 + TypeScript + Vite 工程（未引入 SvelteKit）。
- 独立 `workmanager-core` Rust crate（不依赖 Tauri）：便携路径解析、SQLite 连接/PRAGMA/migration/完整性检查/健康快照；`src-tauri` 作为 Tauri 适配层，只暴露 `get_database_health` 一个受限命令。
- 便携路径：Release 数据根目录跟随 EXE（`<exe目录>/data`）；Debug/Test 必须显式设置 `WORKMANAGER_TEST_PORTABLE_ROOT`；仅允许 D 盘；不静默回退到 AppData/LocalAppData/Temp/C 盘；目录被文件阻塞、不可写、符号链接或含 `..` 时 fail-closed。
- 二次返工新增：Debug/Test 正式目录保护同时比较规范化输入路径与 Win32 真实最终路径（受保护根目录可注入测试，测试用 D 盘隔离目录模拟正式根，绝不触碰真实 `D:\WorkManager`）；真实物理卷身份用句柄 `VOLUME_NAME_GUID` / `VOLUME_NAME_NT` 与 `D:\` 根卷比对（不再只比较盘符），并在 `resolve()`、`ensure_directories()`、`Database::initialize()` 的目录创建/写探针/初始化锁/数据库写入之前 fail-closed。
- 二次返工新增：首次初始化取得跨进程锁后**先重新检查正式主库**，只有主库确实缺失时才检查孤儿 WAL/journal；等待锁进程不会把另一个进程已创建数据库的活动 WAL 误判为孤儿（确定性真实双进程测试覆盖）。
- 三次返工新增（R3-01）：D 盘根卷作为信任锚被独立验证——生产函数 `volume_mount_point_guid()`（`GetVolumeNameForVolumeMountPointW`）要求 D 根是真实卷挂载点，根目录句柄 `VOLUME_NAME_GUID` 必须与挂载点 GUID 一致，`query_dos_device_target()`（`QueryDosDeviceW`）必须映射到 `\Device\HarddiskVolumeN` 真实 NT 设备卷且与句柄 `VOLUME_NAME_NT` 一致，D 根卷 GUID 不得等于 C 根卷 GUID；任一步失败返回 `path-root-trust-anchor-invalid`，在创建目录/写探针/初始化锁/数据库之前 fail-closed。该检查由 `validate_real_storage_path()` → `ensure_volume_is_d_volume()` → `verify_root_volume_trust()` 生产调用链使用。
- 三次返工新增（R3-02）：真实双进程初始化锁测试改为“底层锁竞争确认”同步——`#[cfg(test)]` 观察点只在 `LockFileEx` 明确返回锁竞争时通知，waiter 走完整 `Database::initialize()` 并在真实竞争后才发信号；creator 收到竞争确认后才创建数据库与活动 WAL，父进程确认后才放锁；专项测试 10/10 多轮稳定通过，观察点不进入生产构建、不是 IPC、不改变锁语义。
- WebView2 使用 Rust 侧绝对数据目录 `<data>/cache/webview2`（运行时验证 `EBWebView` profile 真实创建于该目录）。
- SQLite：`rusqlite` 0.43.0 + bundled SQLite 3.54.1；WAL、`foreign_keys=ON`、`synchronous=FULL`、`busy_timeout=5000`、`temp_store=MEMORY`；启动时 `PRAGMA integrity_check` 与 `foreign_key_check`；正常退出时显式关闭连接并清理 WAL/SHM。
- schema 版本 1（`0001_initial_foundation`：`schema_migrations`、`settings`）；`PRAGMA user_version` + 每个 migration 独立 IMMEDIATE 事务，失败回滚；首次初始化在临时数据库完成 schema 与检查后用硬链接原子安装，绝不覆盖已有数据库。
- 最小健康检查窗口：显示 WorkManager 名称/版本、数据库状态、schema 版本、完整性、PRAGMA 配置、便携路径与 migration 记录；明确标注"仅基础设施预览，业务功能尚未实现"。
- 本任务未实现：项目/工作事项 CRUD、每日计划、复盘、报表、附件、自动备份、密码/锁屏/SQLCipher/DPAPI。

阶段验收：
- 项目和工作事项可独立创建、编辑、归档。
- 多项目批量创建不会共享同一条可变工作记录。
- 状态变更符合 PRD，子任务全部勾选不会自动完成工作。
- 数据库迁移、事务、外键和错误路径测试通过。
- 不存在应用密码、SQLCipher、DPAPI 或密钥文件依赖。


### T1-02 详细范围与实际交付（2026-11-19，审计、用户验收与合并完成）

**当前状态：** **验收完成**。用户明确接受已记录；PR #7 已合并到 main（commit `ab6aba32a94d7d091b20f0ab49b25badf26377c4`）。  
**分支：** `task/T1-02-project-management`；基线 main `0cafde6`；PR #7 已合并到 main，合并提交 `ab6aba32a94d7d091b20f0ab49b25badf26377c4`。  
**测试报告：** [T1-02-REPORT.md](../testing/reports/T1-02-REPORT.md)；机器可读证据：[T1-02-evidence.json](../testing/reports/T1-02-evidence.json)；返工修复报告：[T1-02-AUDIT-FIX-REPORT.md](../testing/reports/T1-02-AUDIT-FIX-REPORT.md)。

**实际实现范围：**

- **数据库：** 新增 migration `0002_projects.sql`，schema version 1 → 2；`projects(id TEXT PK, name, is_archived, created_at, updated_at)` + 归档/排序索引；使用现有 `PRAGMA user_version` + `schema_migrations` 事务化 migration 机制，未修改 T1-01 的 0001 历史。
- **Rust Core：** 新增 `projects` 模块（model / repository / service / error）；`Database::write_transaction` 提供 `IMMEDIATE` 写事务与失败回滚；项目 ID 由 Core 生成 UUID；名称 trim 后非空校验；列表未归档在前；归档为 UPDATE 标记、非删除、幂等；已归档项目拒绝编辑并保留在列表。
- **Tauri IPC：** `list_projects` / `create_project` / `update_project` / `archive_project`；typed request/response DTO、`deny_unknown_fields`、camelCase 契约、稳定 `{code,message}` 错误；无任意 SQL / 任意文件 / 任意命令接口；数据库连接不进入前端。
- **前端：** 建立 `lib/ui/tokens.css`、通用 Button/PageHeader/EmptyState、`app/AppShell` + `Sidebar` + `navigation.ts`；项目管理 Feature（列表/新建/编辑/归档/loading/空/错误/长名称/归档态）；设置页作为项目管理与数据库诊断入口；诊断页迁移自旧 App.svelte 且功能不变；工作总览/今日工作为结构页并明确标注业务数据未接入，不展示虚构数据。
- **DEC-032 标题栏：** 保留并整合会话前工作区未提交的自定义无边框标题栏实现；红色关闭、黄色最小化、绿色最大化/还原调用真实 Tauri Window API，并在 Release 实测（最大化视口 1100→1920→1100；关闭按钮后进程真实退出码 0）。
- **测试：** 项目领域集成测试 15 项、名称模型单测 4 项、Tauri 适配层测试 3 项；`cargo test --workspace` **90 passed / 0 failed**；原有 T1-01 测试全部保留，仅将 schema 版本期望更新到 v2。
- **Release 验证：** `cargo fmt --check`、`cargo check --workspace --all-targets`、`cargo test --workspace`、`npm run check`、`npm run build`、`npm run tauri build -- --no-bundle` 全部退出码 0；真实 Release UI/IPC **连续 5 次全部通过**（每次主检查 **73/73**、最小窗口 **12/12**、CSP 0、未捕获异常 0、关闭按钮真实退出）；继承便携验证 **106 项 0 FAIL**、异常注入 **73 项 0 FAIL**；诊断页 UI 回归 **24/24**。返工后 Release EXE 10,230,784 字节，SHA-256 `51BBBA8DD17103D742E1BD4A85B83377F7578D34584F2206F30EDFEC8D3DC7F6`。
- **P2-01 修复：** 审计点名 9 处 + 静态检查覆盖范围内 23 处，共 32 处组件/UI CSS 原始颜色收敛为语义 Design Token（新增 20 个 Token，视觉不变）；新增 `scripts/quality/check-design-tokens.mjs` 与 8 项正反向自测并接入 `npm run check`（18 文件 / 0 违规 / 8/8 PASS）。
- **P3-01 修复：** `src-tauri/src/lib.rs` 过期命令注释更新；未改命令注册、IPC 或 DTO。
- **P3-02 修复：** Release UI E2E 改为确定性等待（boot marker / IPC 就绪 / 应用壳 / 项目 loading 终态）并保留失败诊断；只改测试脚本，不改产品业务逻辑；空状态断言保留。
- **统计口径：** 主检查 73 正确；最小窗口实际执行 12 项，旧证据 JSON 因关闭按钮前写盘只持久化 11 项（审计报告 12/12 正确）；返工后 12 项全部写入证据 JSON。
- **截图/证据：** `docs/testing/reports/T1-02-assets/`（正常/最小窗口、loading、空、多项目、长名称、归档确认、归档后、错误状态、诊断页）。
- **未实现：** T1-03 工作事项创建、T1-04 多项目独立副本、T1-05 状态流转、每日计划、复盘、报表、附件、备份恢复、TOCTOU 安全加固。
- **已知风险：** 项目名称唯一性/删除恢复/排序偏好等 PRD 未定义行为未实现；归档历史关联测试使用测试探针表模拟未来 work_items；仓库仍无前端组件测试/视觉回归框架；TOCTOU 按 DEC-029 未修复并延期至 Issue #2；普通 SQLite 未加密；备份策略未确认。

**审计与验收结果：** 第一轮审计发现的 P2-01 / P3-01 / P3-02 均已修复；第二轮独立审计于 2026-11-19 通过；用户于 2026-11-19 明确接受；PR #7 已合并到 main。T1-03 仍未开始，需用户单独授权。报告见 `docs/testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-REPORT.md`，用户验收记录见 `docs/testing/reports/T1-02-USER-ACCEPTANCE.md`。

### T1-03 详细范围与实际交付（2026-11-19 第二轮修复 + 2026-11-20 第三轮 P2-01/P3-02 + 第四轮 F1/F2 修复完成，等待第四轮独立审计）

**当前状态：** **第三轮独立审计未通过；第四轮 F1/F2 定向修复完成，等待第四轮独立审计**。第一轮四项审计问题已完成三轮定向修复；第三轮仅处理 P2-01/P3-02，第三轮审计未通过后第四轮只处理 F1/F2（测试根目录信任锚、清理 fail-closed）与证据/文档一致性：F1/F2 已修复并通过真实文件系统对象场景与受控删除失败注入（未修改 Windows ACL、未执行实际 `Access Denied` 测试），P2-01 复核通过但旧提交 `2342828` 仍可经 GitHub API 读取、GitHub Support 服务端清理未完成，**P2-01 仍未关闭**；PR 保持 Open，未合并；main 未修改。
**分支：** `task/T1-03-quick-create-pending`；基线 main `018e851`；第一轮实现提交 `be8d9c2e9c78710690de189936d6ee65f48ed8df`；第二轮修复提交 `12b1bdf026f01688c79ba438165a97a652e086a1`（P2-02）、`2d91c92301713597ccfc1c0ddc2d83a479f572d4`（P3-01/P3-02）；P2-01 历史清理提交 `b6cf344abc1693e7031427f8963c27474c0b59f9`；第三轮修复提交 `b6a54591b783049142cbbffecd107ec9086723eb`；第三轮审计基准 HEAD `489d8689484c2cf744893bd3ee08dc7b25b5c8b8`；第四轮 F1/F2 修复提交 `d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（随后为第四轮证据/文档同步提交，分支相对 main 共 22 个提交）。
**Pull Request：** [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8)（Open，等待第四轮独立审计）。
**测试报告：** [T1-03-REPORT.md](../testing/reports/T1-03-REPORT.md)；证据：[T1-03-assets/](../testing/reports/T1-03-assets/README.md)；预编码设计：[T1-03-Implementation-Design.md](tasks/T1-03-Implementation-Design.md)。

**实际实现范围：**

- **数据库：** 新增 migration `0003_work_items.sql`，schema version 2 → 3；`work_items`（稳定 ID、可空 `project_id` + `ON DELETE RESTRICT`、标题 CHECK、生命周期五值 CHECK、可空 `importance/urgency` 1–5、可空 `due_date/description`、创建/更新时间、待安排查询索引）；沿用现有 `user_version` + 事务化 migration，未修改 0001/0002。
- **Rust Core：** 新增 `crates/workmanager-core/src/work_items/`（model/repository/service/error）；仅标题即可创建；标题 trim 后非空；Core 生成 UUID；默认 `pending`；相同标题独立记录；**DEC-033：项目存在性与归档校验与插入在同一个 `IMMEDIATE` 写事务内**（`project-not-found` / `project-archived`）；待安排查询只返回 `pending`，含未归属与归档项目历史关联，排序 `created_at DESC, id DESC`；**P2-02：** `WorkItem` 序列化契约锁定为 10 个 camelCase 字段（可空字段输出 null）。
- **Tauri IPC：** `create_work_item` / `list_pending_work_items`；serde camelCase、请求 `deny_unknown_fields`、`spawn_blocking`、稳定 `{code,message}` 错误；无任意 SQL / 文件 / 命令接口。
- **前端：** `lib/contracts/workItems.ts`、`lib/bridge/workItems.ts` + `workItemValidation.ts`（**P2-02 严格运行时契约**：缺字段/类型错误/非法状态/未知字段拒绝）；今日工作页下“待安排”次级视图（**不新增一级导航**、未修改 AppShell/Sidebar/Design Tokens）+ 独立快速创建组件；选择器只展示未归档项目；loading/empty/error/list、重复提交保护、创建成功后从后端重新读取、归档竞态错误提示、归档历史关联“项目已归档”标识；**P3-01：** 创建成功/列表刷新成功/刷新失败三态分离，刷新失败可重试且不重复创建。
- **验证工具：** T1-03 Release E2E（第二轮主检查 84 / 最小窗口 12 / 重启持久化 17 / 数据库只读探针 25）、UAT 路径安全专项 23 项、Bridge 严格契约 Node 测试 17 项接入 `npm run check`；继承便携（106 项，保留 1 WARN）、异常注入（73 项）、T1-02 UI E2E 回归通过。
- **统计（第二轮）：** `cargo test --workspace` **124 passed / 0 failed**（基线 90 + 新增 34）；`npm run check`（svelte-check 0/0；Bridge 17/17；Design Token 49/49）；Release EXE **10,352,128 字节**，SHA-256 `3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`。
- **未实现：** T1-04 多项目独立副本、T1-05 状态流转、每日计划、优先级/手动排序、当前工作指针、复盘、日志、附件、报表、清理、备份恢复、TOCTOU 加固。未新增一级导航；未修改 T1-01/T1-02 已验收行为。
- **已知风险：** 普通 SQLite 未加密；TOCTOU 按 DEC-029 未修复；待安排排序固定；开发自测不等于独立审计/用户验收；main 既有 T1-01/T1-02 历史证据仍含同类机器信息（非本 PR 新增）。

### T1-03 第二轮定向修复记录（2026-11-19）

第一轮独立审计未通过，四项问题与修复：

| 问题 | 修复内容 | 验证 |
|---|---|---|
| **P2-01** 原始日志与机器信息提交 | 删除 `T1-03-assets/logs/` 9 个原始日志；11 个 JSON 证据脱敏；新增 `SANITIZATION.md`；重写本任务分支 docs/evidence 提交（旧 HEAD `2342828` → 新 HEAD `b6cf344`）并 `--force-with-lease` 推送；本地恢复分支 `backup/t1-03-r1-audit-baseline` 与仓库外 bundle 保留 | 当前证据扫描 0 命中；脱敏前后结构一致性 11/11；分支新增历史深度扫描 0 命中 |
| **P2-02** Rust / TS DTO 契约不一致 | `WorkItemDto` 与 Rust 统一为 10 字段；Bridge 严格拒绝缺字段/类型错误/非法状态/未知字段；Rust 完整字段与可空值序列化测试；Node 契约测试 17 项 | Rust 124/124；Bridge 17/17；真实 E2E 创建响应严格校验通过 |
| **P3-01** 创建成功提示时机不准确 | 三态分离：创建成功/刷新成功/刷新失败；刷新成功后才提示已更新；失败 warning + 重试；不重复创建 | E2E 中间态、成功态、失败、重试、无重复创建断言；2 张新截图 |
| **P3-02** UAT 脚本缺少数据库复用保护 | 新增 `T1-03UatPath.ps1`：规范化路径、限定专用测试根目录、拒绝正式目录/根目录外/`..` 越界/已知数据库/非空目录；脚本不删除/不覆盖 | 路径安全专项 23/23 PASS；不安全目录编排退出码 2 |

第二轮质量门禁与实测：`cargo fmt` / `cargo check` / `cargo test`（124/124）/ `npm run check` / `npm run build` / `git diff --check` 全部通过；T1-03 Release E2E 84/84 + 12/12 + 17/17 + 数据库探针 25/25；路径安全 23/23；继承便携 106 项、异常注入 73 项、T1-02 UI E2E 全部通过。状态：**等待第二轮独立审计**；不合并 PR、不修改 main、不开始 T1-04/T1-05。

#### T1-03 第三轮定向修复记录（2026-11-20）

第二轮独立审计仍未关闭 P2-01/P3-02；第三轮只修复这两项，仅修改验证脚本与文档，不新增业务功能、不修改产品代码（Release EXE 与第二轮一致）。

| 问题 | 修复 | 验证 |
|---|---|---|
| **P2-01** 机器信息/原始日志历史对象 | 复核当前分支与 PR #8 文本脱敏：当前 T1-03-assets 33 个文件（含 19 张 PNG）敏感值命中 0；分支增量 `018e851..HEAD` 18 个提交 / 5,773 次文件树扫描，分支新增敏感值命中 0；远端 18 个 ref（8 分支 + 7 pull heads + 2 pull merges + HEAD）、无 tag、无 ref 指向旧提交；PR #8 正文 2,091 字符 / SHA-256 `4621bf70…f660`、2 条 issue 评论、0 条 review，敏感类别/旧日志文件名/抽样原始行命中 0。**旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 仍可经 GitHub API 读取（HTTP 200），其新增的 9 个原始 T1-03 命令日志（共 147,009 字节）仍可列出/下载**；旧提交不可从 HEAD 到达，仅本地备份分支 `backup/t1-03-r1-audit-baseline` 与 gitignored 本地 bundle 引用，均未推送。GitHub Support 服务端清理未完成（工单材料已准备，需仓库所有者提交） | 分支历史/PR 文本复扫通过；旧 SHA 暴露检查未通过 → **P2-01 保持 OPEN/未关闭**；Support 清理完成后必须做旧 SHA 暴露复检 |
| **P3-02** UAT 路径安全（重解析点/最终路径/卷身份） | `scripts/verify/T1-03UatPath.ps1` 改用 Windows 原生句柄 API：`CreateFileW` + `GetFileInformationByHandleEx`（`FILE_ATTRIBUTE_TAG_INFO` / `FILE_ID_INFO`）+ `GetFinalPathNameByHandleW`，使用 `FILE_FLAG_BACKUP_SEMANTICS` + `FILE_FLAG_OPEN_REPARSE_POINT`；拒绝测试根自身及盘符根→输出目录每个已存在路径分量上的未批准 Junction/符号链接/其他重解析点，校验真实最终路径位于 `D:\WorkManager-test-data` 内且在 `D:\WorkManager` 外，校验卷序列号（FileIdInfo）与盘符根/测试根一致；拒绝 UNC/设备/相对路径/非法字符/保留名/末尾点或空格；缺失输出父目录仅允许在已校验的安全存在祖先下；身份无法确认时 fail-closed；已批准重解析点白名单为空。`verify-t1-03-ui.ps1` 在创建 UAT 根后、创建应用目录后、复制 EXE 前后、每次应用启动前（数据库写入前）原生复验。TOCTOU 窗口已记录但**未消除**（DEC-029 / Issue #2 仍适用） | `test-t1-03-uat-path.ps1`：原 23 项保留 + 新增真实 Junction/重解析点/无副作用检查 = **60 项，FAILED=0；SKIPPED=1 显式记录且不计为 PASS**（非管理员进程缺少 SeCreateSymbolicLinkPrivilege、未启用开发者模式，`mklink /D` 退出码 1）；真实 `mklink /J` 覆盖测试根自身、测试根路径分量、中间分量、输出目录、指向正式根、指向 C 盘、指向测试根内部共 7 类全部拒绝（重解析 tag `0xA0000003`）；无副作用检查：canary/假 DB/EXE/编排产物不变、Junction 目标未被触碰、正式根未创建、清理仅删链接（非递归）；退出码 0 |

- **第三轮质量门禁（全部退出码 0）：** `cargo fmt --all -- --check`；`cargo check --workspace --all-targets`；`cargo test --workspace` = **124 passed / 0 failed**（18 个测试套件）；`npm run check` = svelte-check 0 errors / 0 warnings + Bridge 17/17 + Design Token 22 文件 / 0 违规 + 49/49；`npm run build`；`git diff --check`。
- **P3-02 路径安全专项：** 60 项（原 23 + 新增 37），FAILED=0，SKIPPED=1（符号链接创建权限不足，已记录，不计为 PASS），退出码 0。
- **第三轮 Release E2E：** 主 UI/IPC **84/84**、最小窗口 **12/12**、重启持久化 **17/17**、数据库只读探针 **25/25**；两次真实关闭退出码 0；CSP 违规 0。
- **继承回归（全部退出码 0）：** 便携 **106 项 PASS 90 / FAIL 0 / WARN 1（既有 WARN 保留）**；异常注入 **73 项 PASS 64 / FAIL 0**；T1-02 UI E2E 主 73/73 + 最小窗口 12/12 + 关闭退出码 0。
- **Release EXE：** 10,352,128 字节，SHA-256 `3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`（产品代码未变，与第二轮一致）。

**第三轮状态：** P3-02 已修复并完成本地验证，等待第三轮独立审计；P2-01 保持 OPEN/未关闭（旧提交 `2342828` 仍可经 GitHub API 读取，GitHub Support 服务端清理未完成，需仓库所有者提交工单）。PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open；main 未修改（基线 `018e851`）；T1-04/T1-05 未启动。第三轮修复提交：`b6a54591b783049142cbbffecd107ec9086723eb`（第三轮文档复核提交 `489d868`）。TOCTOU 未消除，DEC-029 延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2) 仍适用。开发代理不自行宣布审计/验收通过。

#### T1-03 第四轮定向修复记录（2026-11-20）

第三轮独立审计结论为**未通过**，阻塞项为 F1（`test-t1-03-uat-path.ps1` 未先验证真实测试根目录就 `New-Item -Force` 创建沙箱）与 F2（Junction 删除失败后仍无条件 `Remove-Item -Recurse -Force`），并要求修正证据/文档一致性。第四轮只修复 F1/F2 与证据一致性，仅修改验证脚本/测试脚本/文档，不新增业务功能、不修改产品代码（Release EXE 与第二/三轮一致）。

| 问题 | 修复 | 验证 |
|---|---|---|
| **F1** 测试根目录未验证就创建测试沙箱 | 新增 `Assert-T103UatTrustedTestRoot` 信任锚（与普通输出目录校验分离）：Windows 原生句柄验证测试根存在、真实目录、全部已存在祖先组件、拒绝未批准重解析点、真实最终路径与预期一致、卷身份一致、不在正式目录内；缺失/身份无法确认时 fail closed，**不自动创建测试根目录**；入口在创建沙箱前完成验证；`verify-t1-03-ui.ps1` 在任何写操作前同样验证。新增真实 Junction 根替换 + 外部 Canary 的真实入口子进程无副作用测试；`-TestRootOverride` 注入参数仅用于故障注入、不影响默认路径且不能执行完整套件 | 路径安全专项 93 项（FAILED=0、SKIPPED=1）；F1 子进程 exit=2、Canary 内容/目录结构不变、未创建沙箱/未写默认证据、测试根缺失未自动创建 |
| **F2** 清理失败后仍递归删除 | 新增 fail-closed 沙箱清理：清理前复验沙箱身份（卷序列号 + 文件 ID + 真实最终路径），逐个删除并复验跟踪链接，扫描沙箱无未预期 reparse point，再次复验身份；任一条件不满足立即停止整个沙箱递归删除，保留现场并输出可定位 WARN/FAIL；仅全部通过后执行逐条目校验的安全递归删除，绝不跟随链接进入外部目录 | 4 类故障场景（删除失败由受控 FaultHook 模拟且未修改 Windows ACL/未实测 Access Denied；其余 3 类使用真实文件系统对象验证）全部在递归删除前停止、`recursiveDeletePerformed=false`、沙箱与外部 Canary 保留；失败后 5 个 Canary 复检不变；正常清理 SAFE |
| **证据一致性** | 重新采集分支 HEAD/main/提交数/分支增量扫描数/资产文件数/PNG 数/PR 正文长度与 SHA-256/PR 评论数/远程 refs/旧 SHA 可访问状态；修正第三轮遗留的 UAT 目录（`075440` → `081100`）、资产数（33 → 34，第四轮共 62）、提交数（18 → 20 → 22）、PR 评论数（3 → 4）等不一致 | 文档、证据与 PR 文本使用同一轮真实扫描结果；第四轮证据写入 `evidence/round4/`，不覆盖第三轮证据 |

- **第四轮质量门禁（全部退出码 0）：** `cargo fmt --all -- --check`；`cargo check --workspace --all-targets`；`cargo test --workspace` = **124 passed / 0 failed**（18 个测试套件）；`npm run check` = svelte-check 0 errors / 0 warnings + Bridge 17/17 + Design Token 22 文件 / 0 违规 + 49/49；`npm run build`（167 modules）；`node --test scripts/quality/work-item-bridge.test.mjs` 17/17；`git diff --check`。
- **F1/F2 路径安全专项：** **93 项**（第三轮 60 项全部保留 + 第四轮新增 31 项），FAILED=0，SKIPPED=1（符号链接创建权限不足，已记录，不计为 PASS），退出码 0；主套件沙箱清理 SAFE、无遗留。
- **第四轮 Release E2E：** 主 UI/IPC **84/84**、最小窗口 **12/12**、重启持久化 **17/17**、数据库只读探针 **25/25**；两次真实关闭退出码 0；CSP 违规 0；页面未捕获异常 0；新 UAT 目录 `<uat-root>\t1-03-ui-r4-20261120-181549`，未覆盖第三轮证据目录。
- **继承回归（全部退出码 0）：** 便携 **106 项 PASS 90 / FAIL 0 / WARN 1（既有 WARN 保留）**；异常注入 **73 项 PASS 64 / FAIL 0**；T1-02 UI E2E 主 73/73 + 最小窗口 12/12 + 关闭退出码 0（首次执行出现窗口尺寸/加载超时的环境性失败，无并发负载单独重跑通过；产品代码与 T1-02 验证脚本未修改）。
- **Release EXE：** 10,352,128 字节，SHA-256 `3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`（产品代码未变）。

**第四轮状态：** F1/F2 已修复并完成本地验证，等待第四轮独立审计；P2-01 保持 OPEN/未关闭（旧提交 `2342828` 仍可经 GitHub API 读取，GitHub Support 服务端清理未完成，需仓库所有者提交工单）。PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open；main 未修改（基线 `018e851`）；T1-04/T1-05 未启动。第四轮修复提交：`d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（随后为第四轮证据/文档同步提交）。TOCTOU 未消除，DEC-029 延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2) 仍适用。开发代理不自行宣布审计/验收通过。

### T1-04 详细范围与实际交付（2026-11-24，开发与自测完成，等待独立审计）

**当前状态：** **开发与自测完成，等待独立代码审计**。开发代理不自行宣布独立审计或用户验收通过；T1-03 的独立审计/验收状态保持原样（尚未完成独立审计）。
**授权：** 用户 2026-11-24 明确授权在 T1-03 未完成独立审计的情况下进行堆叠开发，并要求保留 T1-03 状态、不得宣称 T1-03 已完成。
**分支：** `task/T1-04-multi-project-copies`，从 T1-03 最新真实 HEAD `e8205cae22e98afce6480f5a5a0695543a61dee3` 堆叠创建；PR #8 于 2026-11-24 核实为 Open、未合并；main 基线 `018e851e8daf5835391a7b61caf881bc57c2ad42` 未修改。
**Pull Request：** 暂不创建指向 main 的 T1-04 PR（PR #8 未合并，直接创建会把 T1-03 变更重复带入）；只推送独立任务分支。
**测试报告：** [T1-04-REPORT.md](../testing/reports/T1-04-REPORT.md)；证据：[T1-04-assets/](../testing/reports/T1-04-assets/README.md)；预编码设计：[T1-04-Implementation-Design.md](tasks/T1-04-Implementation-Design.md)。

**实际实现范围：**

- **数据库：** migration `0004_work_item_creation_groups.sql`，schema version 3 → 4；`work_item_creation_groups`（id/source_title/created_at）与 `work_item_creation_group_members`（group_id、work_item_id；`work_item_id UNIQUE`，每个工作事项最多一个创建组；外键删除行为只清除成员关系，不连带删除其他副本/创建组）；STRICT、查询索引；未修改 0001/0002/0003，migration 失败回滚。
- **Rust Core：** `WorkItemService::create_copies`：标题/数量/重复项目校验；在同一个 SQLite `IMMEDIATE` 写事务内先验证全部项目存在且未归档，再写创建组、全部独立工作副本、全部成员关系，最后事务内读回验证；任一失败整批回滚，不允许部分成功/静默跳过/补偿删除；新增 `work-item-copies-too-few`、`work-item-copies-duplicate-project` 稳定错误码。
- **Tauri IPC：** `create_work_item_copies`（camelCase、`deny_unknown_fields`、`spawn_blocking`，复用 `WorkItemDto` 与 `CommandError`；响应 `{groupId, workItems}`）。
- **Bridge：** 批量响应严格运行时契约——groupId 规范 UUID、数量与请求一致、每个项目恰好一个副本、ID 唯一、全部 pending、无缺失/额外字段；Node 契约测试 17 → 27。
- **UI：** 快速创建对话框由单项目选择扩展为多项目选择；0/1 个项目沿用 T1-03 单条创建，2+ 调用批量接口；显示已选数量与预计创建数量；创建中锁定输入与选择、防重复点击；失败保留标题与原始选择、刷新项目列表并将失效选择标记为不可用（必须用户主动移除，不得自动创建剩余项目）；成功显示后端实际创建数量并从数据库刷新，刷新失败不重复创建。未新增一级导航、全局 Token 或 UI 依赖。
- **验证工具：** 新增 T1-04 Release E2E 编排（主 UI/IPC、最小窗口、真实 SQLite trigger 原子回滚、重启持久化、数据库只读探针）；复用 T1-03 已验证 UAT 路径安全设施；未修改历史证据。

**验证结果（开发自测）：**

- 质量门禁全部退出码 0：`cargo fmt --check`、`cargo check --workspace --all-targets`、`cargo test --workspace` **149 passed / 0 failed**、`npm run check`（svelte-check 0/0、Bridge 27/27、Design Token 22 文件 0 违规、49/49）、`npm run build`（167 modules）、`git diff --check`。
- Release E2E（独立 UAT 目录、虚构数据）：主 **96/96**、最小窗口 **11/11**、故障回滚 **13/13**、重启持久化 **15/15**、数据库探针 **57/57**；三次真实关闭退出码 **0/0/0**；CSP 违规 0、页面未捕获异常 0。
- 数据库探针：主阶段 12 工作 / 4 创建组 / 9 成员；SQLite trigger 故障回滚后完全不变；重启并再次批量创建后 14 / 5 / 11；schema 4、完整性 ok、外键 0 违规。
- Release EXE `10,435,072` 字节，SHA-256 `2d997dea7c44ff323e902478063e01465a42e0544bfd0ff5b05359f38a3f7d79`。
- 继承回归：便携 106 项（PASS 90 / FAIL 0 / WARN 1 既有 / INFO 15）、异常注入 73 项（PASS 64 / FAIL 0 / INFO 9）、T1-02 UI E2E 73/73 + 12/12，全部退出码 0；T1-03 业务规则由既有 Rust 测试与 T1-04 E2E 场景回归（T1-03 原 UI E2E 脚本以单选控件为基线，不适用于多选控件，未修改历史脚本/证据）。

**未实现 / 遗留：** T1-05 状态流转与历史、每日计划/优先级/当前工作、复盘、日志、附件、报表、清理、备份恢复；T1-03 P2-01 与 DEC-029 / Issue #2 TOCTOU 加固不属于 T1-04 范围。独立审计与用户验收未进行；PR #8 未合并时不创建 T1-04 main PR。

**停止条件：** 已停止开发，等待独立代码审计；未合并 PR #8、未创建 T1-04 main PR、未修改 main、未开始 T1-05；不自行宣布独立审计/用户验收通过。
## 7. 阶段 2：计划、优先级与当前工作

**目标：** 交付日常工作安排、稳定排序和当前工作切换。

| 任务 | 内容 | 核心验收 |
|---|---|---|
| T2-01 | 每日计划创建和工作事项安排 | 同一工作可安排到多个日期；计划记录独立 |
| T2-02 | 全局自动优先级 | 重要程度、紧急程度 1–5；初始评分为两者之和 |
| T2-03 | 手动置顶和全局排序持久化 | 手动顺序保存；截止日期不参与自动评分 |
| T2-04 | 每日计划独立排序 | 调整某日顺序不改变全局优先级 |
| T2-05 | 当前工作指针和切换事件 | 同一时刻最多一个当前工作；切换事件完整记录 |
| T2-06 | 跳过工作后的待补充进度 | 原工作保持进行中；历史不覆盖；支持后续补录 |

阶段验收：
- 今日、未来 7 天、待安排和全局工作列表数据准确。
- 全局排序与每日排序互不影响。
- 当前工作指针具备数据库约束和事务保护。
- 多次切换、暂时跳过和补录均保留历史事件。

---

## 8. 阶段 3：每日复盘与提醒

**目标：** 按用户确认的工作日规则，准确复盘上一个工作日。

| 任务 | 内容 | 核心验收 |
|---|---|---|
| T3-01 | 中国大陆工作日历和手动覆盖 | 工作日/休息日可区分；手动设置优先；官方数据来源待确认 |
| T3-02 | 上一个工作日计算 | 周一复盘周五；周末不生成独立复盘；优先恢复最早未完成复盘 |
| T3-03 | 逐项复盘和执行结果快照 | 已完成、有推进未完成、未执行三种结果正确 |
| T3-04 | 计划外工作补录 | 补录归属实际工作日期，不覆盖已有记录 |
| T3-05 | 无工作确认和整日跳过 | “昨天没有工作”记录无执行；跳过复盘不改变工作状态 |
| T3-06 | 提醒调度 | 设定上班时间开始，每 5 分钟提醒，18:30 停止；未完成下个工作日续接 |
| T3-07 | 跨日未完成复盘恢复 | 已确认条目不重复询问；重启、睡眠恢复后不重复补发提醒 |

阶段验收：
- 工作日期和业务时区固定使用 Asia/Shanghai。
- 提醒状态持久化，重启后可恢复。
- 复盘结果与工作事项生命周期状态分离。
- 提醒不在锁屏界面暴露客户、项目或工作标题。
- 上班时间默认值、锁定期间提醒策略等未决项须先确认，不得擅自硬编码。

---

## 9. 阶段 4：日志、搜索与报表

**目标：** 让工作进展可追溯，并准确生成日报、周报和月报。

| 任务 | 内容 | 核心验收 |
|---|---|---|
| T4-01 | 详细工作日志追加 | 记录进度、问题、解决方案和下一步；不覆盖旧日志 |
| T4-02 | 历史工作搜索 | 可按工作、项目、日期和状态检索 |
| T4-03 | 日报快照 | 区分完成、有推进未完成、未执行、计划外补录和复盘状态 |
| T4-04 | 周报统计 | 按自然周和业务时区汇总 |
| T4-05 | 月报统计 | 按自然月汇总 |
| T4-06 | 工作事项数与每日执行次数双口径验证 | 同一工作推进五天仍为一个工作事项、五次执行记录 |

阶段验收：
- 日报自动生成且未确认的复盘明确标记“复盘未确认”。
- 周报、月报能够查看项目分布、执行事实和未完成事项。
- 工作事项数量、计划次数、执行次数和完成数量严格分开。
- 工作档案清理后，历史快照仍能展示当时的标题、项目和执行结果。

---

## 10. 阶段 5：附件、数据清理与备份

**目标：** 安全管理附件路径和数据生命周期，避免误删用户原始文件。

| 任务 | 内容 | 核心验收 |
|---|---|---|
| T5-01 | 原始附件路径关联 | 只保存路径和展示信息，不复制、不读取、不上传内容 |
| T5-02 | 附件存在性检查和重新选择 | 路径失效时提示用户；重新选择后只更新路径记录 |
| T5-03 | 三个月工作档案清理 | 仅清理符合规则的已完成/已放弃工作及其详细日志 |
| T5-04 | 一年每日快照清理 | 每日计划、复盘明细、执行日志和日报历史按期限清理 |
| T5-05 | SQLite 备份和恢复 | 备份策略确认后实施；使用一致性备份、完整性检查和真实恢复测试 |
| T5-06 | 迁移失败回滚和数据恢复验证 | 迁移/清理/恢复失败不破坏原数据 |

阶段验收：
- 任何清理流程都不得删除、移动、覆盖或重命名原始附件。
- 工作档案清理后，一年内的每日快照仍可查询。
- 清理前有预览，清理后有结果记录，失败时事务回滚。
- 备份、轮转和恢复策略未获用户确认前，T5-05 保持阻塞，不得擅自启用自动备份。
- 备份必须处理已到期数据残留问题，不能让旧备份绕过保留期限。

---

## 11. 阶段 6：发布与最终验收

**目标：** 形成可交付、可移动、可验证的 Windows 10 绿色便携版。

| 任务 | 内容 | 核心验收 |
|---|---|---|
| T6-01 | 绿色便携包构建 | Release 包可解压运行，不依赖开发环境 |
| T6-02 | 移动目录后启动项修复 | 从新位置启动后修复路径，不影响数据库和备份 |
| T6-03 | D 盘写入审计 | Process Monitor 核验应用、WebView2、缓存、日志和临时文件 |
| T6-04 | Windows 10 实机与完整断网验收 | 断网完成工作管理、复盘、搜索和报表核心流程 |
| T6-05 | 数据完整性和异常恢复测试 | 数据库损坏、备份恢复、磁盘不足、D 盘不可用、迁移失败和异常退出 |
| T6-06 | 发布说明、许可证清单和用户数据说明 | 说明运行条件、数据位置、隐私边界、限制和已知问题 |
| T6-07 | Windows 系统集成验收 | 托盘行为、开机启动启停与路径修复、单实例、纯便携提醒、用户主动启用的 Toast 及快捷方式清理全部实机验证 |

最终发布门槛：
- PRD 验收标准逐项通过。
- 所有 P0/P1 问题关闭，剩余低优先级问题有明确说明和用户接受记录。
- D 盘写入审计通过，无未授权 C 盘业务数据写入。
- 断网核心流程通过。
- T6-07 的托盘、开机启动、单实例和通知模式全部通过 Windows 10 实机验收。
- SQLite 数据完整性、备份恢复、附件和数据清理验收通过；明确普通 SQLite 未加密。
- Release 构建、安装/解压、移动目录和重启流程有可复核记录。
- 发布版本与 Git commit、测试报告和文档版本对应。

---

## 12. 待确认事项与开发阻塞

以下事项来自决策记录。助手建议不等于用户确认，未确认前不得擅自当作既定需求：

| 决策编号 | 待确认事项 | 影响任务 | 处理原则 |
|---|---|---|---|
| OPEN-001/002/003 | 备份方式、轮转、恢复和过期数据清理 | T5-05、T5-06 | 用户确认具体策略后实施；不得声称尚未实现的自动备份已启用 |
| OPEN-004 | 上班时间默认值 | T3-06 | 使用设置项，不硬编码未经确认的默认时间 |
| OPEN-005 | 重复工作/周期任务 | 后续扩展 | 不纳入首版已承诺范围，等待明确规则 |
| OPEN-006 | 节假日/调休日历来源和更新机制 | T3-01 | 不擅自引入在线依赖；先明确数据来源 |
| OPEN-007 | 三个月按日历月还是固定天数 | T5-03 | 清理逻辑编码前必须确认边界 |
| OPEN-008 | 最终 UI 布局、主题与交互 | 各 UI 任务 | 通过阶段原型逐步确认，不擅自扩大范围 |
| OPEN-009 | 应用锁定期间是否继续发送提醒 | — | 已取消：第一版无应用锁定 |
| OPEN-010 | PIN 失败次数、延迟和锁定时长 | — | 已取消：第一版无应用密码 |

---

## 13. 任务状态与完成定义

### 13.1 状态定义

| 状态 | 含义 |
|---|---|
| 未开始 | 尚未开始实施 |
| 进行中 | 已开始开发，尚未提交完整验收 |
| 待测试 | 代码已提交，等待自动化/专项测试 |
| 待审计 | 测试已执行，等待独立审计 |
| 待用户验收 | 独立审计已通过，等待用户实际验收；不得合并 PR 或启动依赖任务 |
| 验收完成 | 独立审计通过、用户明确接受且 PR 已合并；记录合并提交与遗留风险 |
| 验证执行通过（待审计） | 现有验证记录显示测试已通过，但证据归档或补充审计未关闭；不能关闭阶段门禁 |
| 验收完成 | 验收标准全部满足，证据可复核，独立审计通过 |
| 阻塞 | 被未决需求、外部环境或其他任务阻塞 |
| 返工 | 测试或审计发现问题，需要修复并回归 |

### 13.2 只有满足以下条件才能标记“验收完成”

1. 代码变更已提交，Git commit SHA 可追溯。
2. 自动化测试和对应专项测试已执行。
3. 测试命令、运行环境、结果和必要日志已记录。
4. 对应 PRD/技术设计验收标准逐项核对通过。
5. 独立审计没有未关闭的阻塞性问题。
6. 不存在未说明的数据安全、路径、安全边界或兼容性风险。
7. 开发计划书和开发状态文档已同步更新。
8. 如任务说明明确设置用户验收门禁，必须取得用户明确接受并记录；用户验收未完成时保持“待用户验收”。
9. 用户验收通过后按流程合并 PR；合并完成后将任务、开发计划和开发状态同步标记为“验收完成”，记录 merge commit SHA；未经单独授权不得启动下一任务。

“代码已写”“本地能启动”“测试通过”“审计通过”“用户最终验收”必须分开记录，不能互相替代。

### 13.3 每项任务的证据记录

每个任务至少记录：
- 任务 ID 和任务名称；
- 实际实现范围；
- 关联 PR / commit SHA；
- 测试环境和 Windows 版本；
- 执行命令及测试结果；
- 必要的截图、日志、Process Monitor 记录或测试报告；
- 审计结论；
- 未解决问题和风险；
- 完成日期。

测试报告建议放在 docs/testing/reports/，按任务 ID 命名。不得把客户信息、真实工作数据或真实附件路径写入证据。

---

## 14. AI Agent 开发与审计工作流

每个任务均按以下流程执行：

1. **任务授权：** 审计统筹员根据当前阶段和依赖关系生成单任务/小批量开发提示词，明确允许修改的目录、禁止修改的范围和验收标准。
2. **开发前检查：** AI Agent 阅读 PRD、技术设计、决策记录、AGENTS.md、本计划书和当前状态。
3. **方案与影响分析：** 先说明实现方案、数据影响、边界情况和回滚方式；涉及未决事项时先提问。
4. **测试先行：** 对业务逻辑优先使用 TDD；SQLite 事务、migration、便携路径、数据清理和备份恢复执行专项测试。
5. **实现与自测：** 只完成授权任务，不顺带重构无关模块或扩大功能范围。
6. **提交证据：** 提交代码、测试结果、commit SHA 和风险清单。
7. **独立审计：** 核对 diff、测试、验收标准、异常路径、隐私和数据安全。
8. **修复回归：** 有问题则生成针对性修复提示词，修复后重新测试和审计。
9. **更新文档：** 只有独立审计通过后，才在本计划书和 docs/STATUS.md 中标记为验收完成并记录证据。测试执行通过但证据未归档或补充审计未关闭时，必须保留“验证执行通过（待审计）”状态。
10. **阶段放行：** 当前阶段所有任务满足门槛后，才授权下一阶段。

### 14.1 开发提示词生成规则

- 阶段 0 已按 DEC-028 放行；当前从 T1-01 开始按任务依赖逐项开发。
- 不要求 AI 一次性完成整个项目；每份提示词只授权明确任务。
- 每份提示词必须包含：任务 ID、背景、目标、允许范围、禁止事项、接口/数据约束、测试要求、验收标准、交付格式和停止条件。
- AI Agent 不得自行更改 PRD、技术架构、用户决策或任务状态。
- 不允许 AI Agent 自行把未验证任务打勾或跳过审计。

---

## 15. 风险登记

| 风险 | 等级 | 影响 | 控制措施 |
|---|---|---|---|
| 普通 SQLite 文件未加密 | 已接受 | 拥有文件访问权限的人可以直接读取工作数据 | 不将数据库放入共享目录；依赖 Windows 账户和磁盘访问权限；不宣称已加密 |
| 应用或 WebView2 写入 C 盘 | 高 | 违反便携和数据边界 | T0-02/T0-03 与 T6-03 Process Monitor 审计 |
| 数据库损坏或异常时创建空库 | 高 | 可能覆盖原数据 | fail-closed 专项测试 |
| 备份绕过数据保留期限 | 高 | 已到期工作数据残留 | 备份与清理策略统一设计 |
| 复盘与工作生命周期混淆 | 高 | 错误完成/放弃工作 | 独立状态模型和事务测试 |
| 统计混淆工作数量与执行次数 | 中 | 日报/周报/月报失真 | 双口径测试 |
| 附件清理误删原始文件 | 高 | 用户文件不可恢复 | 附件只存路径；专用临时文件测试 |
| AI Agent 超范围修改 | 中 | 架构漂移、引入隐性风险 | 单任务授权、diff 审计、Git 回滚 |

---

## 16. 进度更新记录

| 日期 | 变更 | 说明 |
|---|---|---|
| 2026-11-17 | 建立开发计划 V1.0 | 根据 PRD V0.2、技术设计 V0.3.2 和决策记录建立阶段与任务基线；当时阶段 0 登记为 3/6 |
| 2026-11-17 | 更新开发计划 V1.1 | 根据 DEC-028 取消应用密码、SQLCipher 和 DPAPI；阶段 0 放行，启动阶段 1；T1-01 改为普通 SQLite 基础设施 |
| 2026-11-17 | 更新开发计划 V1.2 | 明确 T1-01 计划 18:00（北京时间）后启动；T0-06 延期至阶段 6，新增 T6-07 验收托盘、开机启动、单实例和通知 |
| 2026-11-17 | T1-01 状态改为进行中 | 用户明确授权立即开始，不再等待 18:00；建立开发分支 `task/T1-01-sqlite-foundation`；本机开发环境已复核 |
| 2026-11-17 | T1-01 代码与测试完成（待审计） | 代码提交 `682ba04`：Tauri 2 + Svelte 5 工程骨架、便携路径、bundled SQLite、user_version migration、失败保护、最小健康检查界面；cargo/npm/Release 构建与运行时专项验证通过；测试报告 `docs/testing/reports/T1-01-REPORT.md`；等待独立审计，未标记验收完成 |
| 2026-11-17 | 创建 T1-01 Pull Request | 推送分支 `task/T1-01-sqlite-foundation` 并创建 [PR #1](https://github.com/shuaikun853-dev/work-kanban/pull/1) 指向 main；未合并、未推送 main；等待独立审计 |
| 2026-11-17 | T1-01 进入返工 | 独立审计提出 2 项 P1、3 项 P2 与 1 项可选 CSP 加固问题：零字节数据库保护、D 盘真实卷/重解析点校验、已有数据库预检查顺序、初始化跨进程锁、数据库命令异步化、CSP；保留原始提交历史，在 `task/T1-01-sqlite-foundation` 新增修复提交 |
| 2026-11-17 | T1-01 返工完成（待重新审计） | 修复提交 `abf3e5a`；新增专项测试，Rust 测试报告 52 项通过；Release 复验报告通过；等待重新独立审计 |
| 2026-11-17 | T1-01 第二轮独立审计未通过 | 最新审计基准 PR #1 HEAD `892b25f`；发现初始化锁后 WAL 检查顺序竞争、Debug/Test Junction 可绕过正式目录保护、真实卷身份/TOCTOU 未充分关闭、PR/机器证据/状态文档过期；记录见 `docs/testing/reports/T1-01-SECOND-AUDIT-REPORT.md`；任务重新进入返工，PR 不合并，不开始 T1-02 |
| 2026-11-17 | T1-01 第二轮审计返工修复（返工中 / R2-03 阻塞） | 修复代码提交 `a148f0d`：R2-01/R2-02/R2-04 返工与 62 项 Rust 测试、Release 复验通过；R2-03 TOCTOU 未关闭 |
| 2026-11-18 | T1-01 第三轮独立审计未通过 | 代码提交 `a148f0d`、审计对象 PR HEAD `eaf6ef7`；R2-01/R2-02/R2-04 修复逻辑复核成立；TOCTOU 未修复，后由用户 DEC-029 接受并延期至 Issue #2；R3-01 P1、R3-02 P2 仍待处理；报告 `docs/testing/reports/T1-01-THIRD-AUDIT-REPORT.md`；PR 不合并，不开始 T1-02 |
| 2026-11-18 | 用户接受 T1-01 TOCTOU 残余风险（DEC-029） | 不在 T1-01 内实施完整句柄相对改造/custom SQLite VFS；风险保留并转入独立安全加固 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。R3-01 P1 与 R3-02 P2 仍须处理后重新独立审计 |
| 2026-11-18 | T1-01 第三轮审计 R3 返工完成（待独立审计） | R3-01 修复提交 `ae1eb65`：生产路径独立验证 D 根卷信任锚（真实卷挂载点 GUID + 句柄 GUID/NT + QueryDosDevice NT 设备映射 + D/C 同卷拒绝），失败 `path-root-trust-anchor-invalid` fail-closed；R3-02 修复提交 `4942eb0`：双进程测试改为“底层锁竞争确认信号 + 完整 Database::initialize”，10/10 多轮稳定通过。完整回归 `cargo test --workspace` 68 passed；Release 便携 106 项、异常注入 73 项 0 FAIL；UI/IPC/CSP 21/21；EXE 9,993,216 字节、SHA-256 `41A8F6B4…7800`。TOCTOU 按 DEC-029 接受延期（未修复）；任务状态置为待独立审计，PR 不合并，不开始 T1-02 |

后续每次阶段、任务状态变化，都应追加记录，并同步更新 docs/STATUS.md。历史记录不得通过覆盖方式抹去。

---

## 17. 当前执行结论

- 当前获授权的执行阶段：**阶段 1：基础架构与工作事项**；T1-01 已于 2026-11-18 经第四轮独立审计、用户验收并合并到 main（PR #1，commit `260e6c0`），状态为**验收完成**。
- **T1-02 项目创建、编辑、归档：已验收完成。** 第二轮独立审计通过、用户明确接受、PR #7 已合并（commit `ab6aba32a94d7d091b20f0ab49b25badf26377c4`）。报告：`docs/testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-REPORT.md`；验收记录：`docs/testing/reports/T1-02-USER-ACCEPTANCE.md`。
- **T1-03 工作事项快速创建和待安排区域：第三轮独立审计未通过；第四轮 F1/F2 定向修复完成，等待第四轮独立审计。** 分支 `task/T1-03-quick-create-pending`，基线 `018e851e8daf5835391a7b61caf881bc57c2ad42`；第一轮实现提交 `be8d9c2e9c78710690de189936d6ee65f48ed8df`；第二轮修复提交 `12b1bdf`（P2-02）、`2d91c92`（P3-01/P3-02）；P2-01 证据脱敏与历史清理 `b6cf344`；第三轮修复提交 `b6a54591b783049142cbbffecd107ec9086723eb`；第三轮审计基准 HEAD `489d8689484c2cf744893bd3ee08dc7b25b5c8b8`；第四轮 F1/F2 修复提交 `d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（随后为第四轮证据/文档同步提交，分支相对 main 共 22 个提交）。DEC-033 已实现并测试。第四轮验证：`cargo test --workspace` 124/124、T1-03 Release E2E 84/84 + 12/12 + 17/17 + 数据库探针 25/25、路径安全专项 93 项（第三轮 60 项全部保留、1 项 SKIP 已记录）、继承回归全部通过；F1/F2 等待第四轮独立审计，P2-01 仍未关闭（旧提交 `2342828` 仍可经 GitHub API 读取，待 GitHub Support 服务端清理）。PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) Open；详细报告见 `docs/testing/reports/T1-03-REPORT.md`。
- **T1-04 多项目独立副本创建：开发与自测完成，等待独立代码审计。** 用户 2026-11-24 确认整批原子提交并记录为 DEC-034 / PRD-AT-18；分支 `task/T1-04-multi-project-copies` 从 T1-03 最新 HEAD `e8205cae…a61dee3` 堆叠创建，main `018e851` 未修改；PR #8 保持 Open，未创建 T1-04 main PR，未开始 T1-05。验证：`cargo test --workspace` 149/149；Release E2E 主 96/96 + 最小窗口 11/11 + 故障回滚 13/13 + 持久化 15/15 + 数据库探针 57/57（三次真实关闭退出码 0/0/0）；继承便携 106 项、异常注入 73 项、T1-02 UI E2E 73/73 + 12/12；Release EXE 10,435,072 字节、SHA-256 `2d997dea…f7d79`。T1-03 仍未完成独立审计，P2-01 仍未关闭。报告：`docs/testing/reports/T1-04-REPORT.md`。
- 阶段 0 已于 2026-11-17 按 DEC-028 放行；T0-04/T0-05 取消，T0-06 延期到阶段 6；T0-06 的验收拆分为 T6-04 和 T6-07。
- 最近完成任务：**T1-02 项目创建、编辑、归档**（用户验收完成，PR #7 已合并）；**T1-03 工作事项快速创建和待安排区域**第三轮独立审计未通过，第四轮 F1/F2 定向修复完成，等待第四轮独立审计（F1 信任锚、F2 清理 fail-closed 已修复并通过真实文件系统对象场景与受控删除失败注入（未修改 Windows ACL、未执行实际 `Access Denied` 测试）；P2-01 仍未关闭，待 GitHub Support 服务端清理；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) Open）。T1-01 任务说明见 `docs/development/tasks/T1-01-SQLite-Foundation.md`；验收记录见 `docs/testing/reports/T1-01-USER-ACCEPTANCE.md`；R3 返工证据见 `docs/testing/reports/T1-01-R3-FIX-REPORT.md` 与 `docs/testing/reports/T1-01-R3-FIX-evidence.json`。
- 参考实现/候选依赖说明：项目 ID 使用 `uuid` crate（MIT/Apache-2.0，技术设计 1.3 已列出）；`serde_json` 仅用于测试 DTO 契约；未引入云服务、遥测、账户或同步依赖。
- 第一版采用普通 SQLite，不实现应用密码、SQLCipher 或 DPAPI。
- UI 设计基线已按 DEC-030 / DEC-031 确认，DEC-032 自定义标题栏已实现并实测；业务 UI 已交付 AppShell、项目管理（T1-02）与今日工作页下的待安排次级视图（T1-03）；今日工作计划/当前工作/完成状态等真实业务数据尚未接入，按后续任务实现。
- D 盘本地存储、不上传数据、事务、版本化 migration、异常保护和备份恢复仍是必须要求。
- 本计划书定义未来工作，不表示尚未开发的功能已经实现。


| 2026-11-18 | T1-01 第四轮独立审计通过（审计当时待用户验收） | 复核 PR #1 HEAD `ae14bff`、R3-01/R3-02 代码提交、生产调用链、专项测试与脱敏日志；两项审计问题通过。TOCTOU 按 DEC-029 接受并延期、未修复。审计报告：`docs/testing/reports/T1-01-FOURTH-AUDIT-REPORT.md`。PR 保持打开、不合并；main 不修改；T1-02 不开始 |


| 2026-11-18 | T1-01 用户验收完成 | 用户明确回复“接受”，确认接受第四轮独立审计结论及 DEC-029 中已接受但未修复的 TOCTOU 残余风险。T1-01 标记验收完成；PR #1 仍 Open、未合并，main 不修改；T1-02 未开始，等待单独启动指示。验收记录：`docs/testing/reports/T1-01-USER-ACCEPTANCE.md` |
| 2026-11-18 | 用户确认 UI 原型与前端架构基线（DEC-030） | 建立 `docs/design/UI-DESIGN-SPEC.md` 和原型图；更新 PRD、技术架构、AGENTS 与开发状态。仅完成文档，不代表 UI 代码或 T1-02 已启动；实现必须按用户授权的对应任务逐步进行。 |
| 2026-11-18 | T1-01 PR #1 合并 | 用户验收后，PR #1 合并到 main，合并提交 `260e6c07802a297529d8bda1e2d9239fca90fc10`；T1-01 代码正式进入 main；T1-02 未开始。 |
| 2026-11-18 | UI 设计文档 PR #4 合并 | UI 原型、设计规范和 AI 前端架构约束已合入 main，合并提交 `938f21c`；T1-02 未开始。 |
| 2026-11-18 | T1-02 开发启动（进行中） | 用户指示启动 T1-02；分支 `task/T1-02-project-management` 基于最新 main `0cafde6`；保留并整合会话前工作区未提交的 DEC-032 自定义标题栏变更。 |
| 2026-11-18 | T1-02 代码与自测完成（待审计） | 提交 `b8962b5`（migration 0002 + Rust Core 项目领域 + 测试）、`2b3035d`（typed Tauri IPC）、`14a542e`（Design Tokens/AppShell/项目管理 UI/诊断页迁移）、`30666c8`（Release 验证脚本）。`cargo test --workspace` 90 passed / 0 failed；`npm run check` / `npm run build` / Release 构建通过；Release UI/IPC 73/73 + 最小窗口 11/11；继承便携 106 项、异常注入 73 项 0 FAIL；EXE 10,230,272 字节，SHA-256 `DF4469EA…B7E8`。TOCTOU 按 DEC-029 未修复；状态置为**待审计**，不开始 T1-03。报告：`docs/testing/reports/T1-02-REPORT.md`。 |
| 2026-11-18 | 创建 T1-02 Pull Request #7 | 推送分支 `task/T1-02-project-management` 并创建 [PR #7](https://github.com/shuaikun853-dev/work-kanban/pull/7) 指向 main；PR 保持 Open、不合并；等待独立审计；不开始 T1-03。 |
| 2026-11-18 | T1-02 第一轮独立审计未通过 | 独立实测 `cargo test --workspace` 90 项通过、Release 便携/异常 0 FAIL；发现 P2-01 UI Design Token 散落 raw color，另记录 P3 注释与一次 E2E 时序抖动。状态改为返工，详见 `docs/testing/reports/T1-02-INDEPENDENT-AUDIT-REPORT.md`；PR #7 不合并，T1-03 不开始。 |
| 2026-11-18 | T1-02 第一轮审计返工修复完成（待第二轮独立审计） | 修复 P2-01：审计点名 9 处 + 静态检查覆盖范围内 23 处，共 32 处组件/UI CSS 原始颜色收敛为语义 Token（新增 20 个，视觉不变）；新增 `scripts/quality/check-design-tokens.mjs` + 8 项正反向测试并接入 `npm run check`（18 文件 0 违规）。修复 P3-01 过期 Tauri 注释。修复 P3-02：E2E 改为 boot marker/IPC 就绪/应用壳/项目 Loading 终态 4 项确定性等待并保留失败诊断，只改测试脚本。统计口径核实：主检查 73 项、最小窗口实际执行 12 项（旧 JSON 仅持久化 11 项，已修复为 12 项全部持久化）。最终 Release EXE 10,230,784 字节、SHA-256 `51BBBA8D…356EE`；连续 5 次完整 E2E 全部通过（每次主 73/73、最小窗口 12/12）；Rust 90/90；便携 106 项、异常注入 73 项 0 FAIL；诊断页 24/24。修复提交 `881e755`（P2-01）、`c3593e6`（P3-01）、`a9e4198`（P3-02）、`8e215f8`（证据与文档）。状态置为**待审计**，等待第二轮独立审计；PR #7 不合并，T1-03 不开始。报告：`docs/testing/reports/T1-02-AUDIT-FIX-REPORT.md`。 |

| 2026-11-19 | T1-02 第二轮独立审计通过（待用户验收） | 审计代码基线 `8123e0354bc3d3393944a323ecd59f709ac3b051`；P2-01 第五轮专项审计通过，P3-01 / P3-02 已核验关闭；独立回归 Rust 90/90、`npm run check`（49/49、18 文件 0 违规）、`npm run build`，Release UI E2E 5/5（每次主 73/73、最小窗口 12/12、CSP 0、页面异常 0、关闭退出码 0）。状态转为待用户验收；PR #7 保持 Open，main 未修改，T1-03 未开始。报告 `docs/testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-REPORT.md`。 |

| 2026-11-19 | T1-02 用户验收通过 | 用户在当前对话明确回复“接受 T1-02”；验收记录 `docs/testing/reports/T1-02-USER-ACCEPTANCE.md` 已更新。PR #7 进入合并流程；合并完成并同步 main 前不开始 T1-03。 |

| 2026-11-19 | T1-02 PR #7 合并，任务验收完成 | 用户已明确接受 T1-02；PR #7 于 2026-11-19 合并到 main，merge commit `ab6aba32a94d7d091b20f0ab49b25badf26377c4`。T1-02 标记验收完成；T1-03 未开始，等待用户单独启动指示。验收记录 `docs/testing/reports/T1-02-USER-ACCEPTANCE.md`。 |


### T1-03 业务规则确认记录（2026-11-19）

用户明确确认：**新建工作事项不允许选择已归档项目。** 该规则形成 DEC-033，并同步更新 PRD V0.3.2 与 T1-03 任务说明。实现要求：前端选择器只显示未归档项目；Rust Core 在创建事务内校验 `is_archived = 0`，对已归档项目返回 `project-archived`；不归属项目仍允许创建；项目归档不得删除或改写既有工作事项的项目关联。

| 2026-11-19 | T1-03 编码前设计确认并提交 | 新增 `docs/development/tasks/T1-03-Implementation-Design.md`（组件树、页面状态流、修改文件清单、数据库模型、IPC 契约、测试计划），提交 `9c09156`；随后按该设计实施。 |
| 2026-11-19 | T1-03 代码实现与开发自测完成（待独立审计） | 实现提交 `be8d9c2`：migration 0003（schema 2 → 3）、Rust Core `work_items` 领域（DEC-033 同事务校验）、Tauri typed IPC（`create_work_item` / `list_pending_work_items`）、前端 Contracts/Bridge/运行时校验、今日工作 → 待安排次级视图与快速创建对话框、T1-03 Release E2E 与继承回归脚本更新。`cargo test --workspace` **123 passed / 0 failed**（基线 90 + 新增 33）；`npm run check`（svelte-check 0/0、Bridge 10/10、Design Token 49/49）；Release E2E **主 70/70 + 最小窗口 12/12 + 重启持久化 17/17 + 数据库探针 25/25**，两次真实关闭退出码 0；继承便携 106 项、异常注入 73 项、T1-02 UI E2E 全部通过；Release EXE 10,351,616 字节、SHA-256 `22af942f…66b23`。状态置为**待独立审计**；PR [#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) 保持 Open，main 未修改，T1-04/T1-05 不开始。报告：`docs/testing/reports/T1-03-REPORT.md`；证据：`docs/testing/reports/T1-03-assets/`。 |

| 2026-11-19 | T1-03 第一轮独立审计未通过，进入定向返工 | 四项问题：P2-01 原始命令日志/机器信息提交；P2-02 Rust `WorkItem` 10 字段与 TS `WorkItemDto` 6 字段不一致且 Bridge 静默忽略未知字段；P3-01 创建成功后提示“列表已刷新”的时机不准确；P3-02 UAT 脚本缺少数据库复用/路径绕过保护。任务状态置为返工；只修复这四项，不扩大范围。 |
| 2026-11-19 | T1-03 第二轮定向修复完成（等待第二轮独立审计） | P2-01：删除 9 个原始日志、脱敏 11 个证据 JSON、新增 `SANITIZATION.md`，重写分支 docs/evidence 提交 `2342828` → `b6cf344` 并 `--force-with-lease` 推送；P2-02：`WorkItemDto` 统一为 10 字段、Bridge 严格契约、Node 17/17；P3-01：创建/刷新成功/刷新失败三态与重试；P3-02：`T1-03UatPath.ps1` + 路径安全专项 23/23。质量门禁：`cargo test` 124/124、npm check、npm build、git diff --check 全部通过；Release E2E 84/84 + 12/12 + 17/17 + 数据库探针 25/25，两次真实关闭退出码 0；继承便携 106 项（1 WARN 保留）、异常注入 73 项、T1-02 UI E2E 全部通过。Release EXE 10,352,128 字节，SHA-256 `3f12bbce…fa9e3`。状态：等待第二轮独立审计；PR #8 Open，未合并；main 未修改；T1-04/T1-05 不开始。报告：`docs/testing/reports/T1-03-REPORT.md`。 |

| 2026-11-20 | T1-03 第三轮 P2-01/P3-02 定向修复完成（待第三轮独立审计） | 第三轮仅修复 P2-01/P3-02，仅改验证脚本与文档、未改产品代码。P3-02：`T1-03UatPath.ps1` 改用 Windows 原生句柄 API（`CreateFileW` + `GetFileInformationByHandleEx` `FILE_ATTRIBUTE_TAG_INFO`/`FILE_ID_INFO` + `GetFinalPathNameByHandleW`，`FILE_FLAG_BACKUP_SEMANTICS` + `FILE_FLAG_OPEN_REPARSE_POINT`），拒绝测试根及每个已存在路径分量的未批准 Junction/符号链接/其他重解析点，校验真实最终路径在 `D:\WorkManager-test-data` 内、`D:\WorkManager` 外及卷序列号一致，未知身份 fail-closed；`verify-t1-03-ui.ps1` 在创建 UAT 根/应用目录、复制 EXE 前后、每次应用启动前原生复验；TOCTOU 窗口记录但未消除（DEC-029 / Issue #2 仍适用）；路径安全专项 **60 项 FAILED=0、SKIPPED=1 已记录（无符号链接创建权限，不计 PASS）**，真实 `mklink /J` 7 类场景全部拒绝且无副作用。P2-01：当前 T1-03-assets 33 文件（19 PNG）敏感值 0 命中；分支增量 18 提交 / 5,773 次扫描 0 命中；PR #8 正文/评论敏感命中 0（正文 2,091 字符、SHA-256 `4621bf70…f660`）；但旧提交 `2342828` 仍可经 GitHub API 读取，9 个原始日志（147,009 字节）仍可列出/下载，GitHub Support 服务端清理未完成，**P2-01 保持 OPEN/未关闭**。质量门禁全部退出码 0：`cargo test --workspace` 124/124（18 套件）、`npm run check`（svelte-check 0/0、Bridge 17/17、Design Token 22 文件 0 违规、49/49）、`npm run build`、`git diff --check`；Release E2E 84/84 + 12/12 + 17/17 + 25/25，两次真实关闭退出码 0；继承便携 106 项（PASS 90 / FAIL 0 / WARN 1 保留）、异常注入 73 项（PASS 64 / FAIL 0）、T1-02 UI E2E 73/73 + 12/12；Release EXE 10,352,128 字节，SHA-256 `3f12bbce…fa9e3`（产品代码未变）。第三轮修复提交：`b6a54591b783049142cbbffecd107ec9086723eb`（另有后续文档复核提交，PR #8 时间线可见）。状态：等待第三轮独立审计；PR #8 Open，未合并；main 未修改；T1-04/T1-05 不开始。 |

| 2026-11-24 | T1-04 开发授权与堆叠基线核实 | 用户明确授权在 T1-03 未完成独立审计的情况下堆叠开发 T1-04，并要求保留 T1-03 审计/验收状态。重新查询 GitHub：PR #8 Open、未合并、headRefOid `e8205cae22e98afce6480f5a5a0695543a61dee3`；main `018e851e8daf5835391a7b61caf881bc57c2ad42` 未包含 T1-03/T1-04；从最新 T1-03 HEAD 创建 `task/T1-04-multi-project-copies`，未修改 main/T1-03 分支、未重写历史。 |
| 2026-11-24 | T1-04 编码前设计提交 | 新增 `docs/development/tasks/T1-04-Multi-Project-Independent-Copies.md` 与 `T1-04-Implementation-Design.md`（业务范围、migration、Core 事务边界、IPC DTO、Bridge 契约、Svelte 组件树/状态流、测试计划、文件清单、回归范围、GitHub 交付流程），提交 `e207ea9`；随后按设计先写失败测试再实现。 |
| 2026-11-24 | T1-04 代码、测试、Release E2E 与文档完成（待独立审计） | 实现提交 `3031552e33e6cae2085a99910b73d769b6aa7a6b`； 实现 migration 0004（schema 3→4）、Rust Core `create_copies` 整批原子事务、Tauri `create_work_item_copies`、Bridge 严格契约、多项目选择 UI 与验证工具。质量门禁：`cargo test --workspace` **149 passed / 0 failed**、npm check（svelte-check 0/0、Bridge 27/27、Design Token 22 文件 0 违规、49/49）、npm build、git diff --check 全部退出码 0；Release E2E 主 96/96 + 最小窗口 11/11 + 故障回滚 13/13 + 持久化 15/15 + 数据库探针 57/57，三次真实关闭退出码 0/0/0；继承便携 106 项（PASS 90 / FAIL 0 / WARN 1 保留）、异常注入 73 项（PASS 64 / FAIL 0）、T1-02 UI E2E 73/73 + 12/12；Release EXE 10,435,072 字节、SHA-256 `2d997dea…f7d79`。DEC-034 / PRD-AT-18 已记录；T1-03 状态未改变；PR #8 保持 Open、未合并；未创建 T1-04 main PR；未开始 T1-05。报告：`docs/testing/reports/T1-04-REPORT.md`；证据：`docs/testing/reports/T1-04-assets/`。 |
| 2026-11-20 | T1-03 第四轮 F1/F2 定向修复完成（待第四轮独立审计） | 第三轮独立审计未通过，阻塞项为 F1（测试根目录未验证就创建沙箱）与 F2（Junction 清理失败仍递归删除），并要求修正证据/文档一致性。第四轮仅改验证脚本/测试脚本/文档，未改产品代码。F1：`test-t1-03-uat-path.ps1` 在任何写操作前调用信任锚 `Assert-T103UatTrustedTestRoot`（原生句柄：存在/真实目录/全部祖先/重解析点拒绝/最终路径一致/卷身份/正式目录排除；缺失或身份无法确认时 fail closed 且不自动创建测试根目录）；新增真实 Junction 根替换 + 外部 Canary 的真实入口子进程无副作用测试；`-TestRootOverride` 仅用于故障注入、不影响默认路径且不能执行完整套件；`verify-t1-03-ui.ps1` 同样在写前验证信任锚。F2：新增 fail-closed 沙箱清理（先复验沙箱身份，再逐个删除并复验跟踪链接、扫描未预期 reparse point、再次复验身份；任一失败立即停止整个沙箱递归删除、保留现场并输出可定位 WARN/FAIL；仅全部通过后逐条目校验安全递归删除），新增 4 类真实文件系统故障注入（删除失败/链接重建/未跟踪链接/身份替换）与失败后 Canary 复检。验证：路径安全专项 **93 项（第三轮 60 项全部保留 + 第四轮新增 31 项）、FAILED=0、SKIPPED=1 已记录（无符号链接创建权限，不计 PASS）**；质量门禁全部退出码 0：`cargo test --workspace` 124/124（18 套件）、`npm run check`（svelte-check 0/0、Bridge 17/17、Design Token 22 文件 0 违规、49/49）、`npm run build`（167 modules）、`node --test` Bridge 17/17、`git diff --check`；Release E2E 主 84/84 + 最小窗口 12/12 + 持久化 17/17 + 数据库探针 25/25，两次真实关闭退出码 0/0，新 UAT 目录 `<uat-root>\t1-03-ui-r4-20261120-181549`；继承便携 106 项（PASS 90 / FAIL 0 / WARN 1 保留）、异常注入 73 项（PASS 64 / FAIL 0）、T1-02 UI E2E 73/73 + 12/12 + 关闭退出码 0（首次执行环境性失败，无并发负载重跑通过）。证据/文档一致性：重新采集分支 HEAD/main/提交数（扫描时 22，含证据同步提交）/分支增量扫描/资产数（62）/PNG 数（38）/PR 正文 3,957 字符 SHA-256 `725d5df3…0ae0`/4 条 issue 评论/18 个远程 refs/tags 0/旧 SHA 可访问状态；修正第三轮遗留的 UAT 目录（075440→081100）、资产数（33→34）、提交数（18→20/21）、PR 评论数（3→4）不一致；第四轮证据位于 `evidence/round4/`，不覆盖第三轮证据。P2-01：旧提交 `2342828` 及 9 个原始日志（147,009 字节）仍可经 GitHub API 读取，GitHub Support 服务端清理未完成，**P2-01 保持 OPEN/未关闭**；本轮未重写历史、未强制推送、未删除备份分支/bundle。第四轮修复提交：`d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（随后为证据/文档同步提交）。状态：等待第四轮独立审计；PR #8 Open，未合并；main 未修改；T1-04/T1-05 不开始。报告：`docs/testing/reports/T1-03-REPORT.md`；第四轮汇总：`docs/testing/reports/T1-03-assets/evidence/round4/round4-verification-summary.json`。 |
