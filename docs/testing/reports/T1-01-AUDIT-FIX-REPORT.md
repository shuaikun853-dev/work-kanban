# T1-01 独立审计问题修复报告（返工）

**任务 ID：** T1-01 正式工程骨架、便携路径接入与 SQLite 基础设施 \
**报告日期：** 2026-11-17 \
**任务状态：** 待审计（返工修复与测试完成；**尚未通过重新独立审计，未标记验收完成**） \
**修复代码提交：** `abf3e5ae6c265c468121b8c13af1806a4afdf0de`（分支 `task/T1-01-sqlite-foundation`，PR #1 自动更新） \
**返工前基线：** `682ba04`（独立审计对象）；PR 修复前 HEAD `9fc728e` \
**Pull Request：** [#1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（保持打开、不合并；未推送 main；未开始 T1-02） \
**测试环境：** Windows 10 19045 x64；Rust 1.100.0 / cargo 1.100.0（MSVC）；Node 22.20.0；WebView2 131.0.2903.86；Tauri 2.12.6；rusqlite 0.43.0 + bundled SQLite 3.54.1；测试数据目录 `D:\WorkManager-test-data`（D 盘隔离）；正式目录 `D:\WorkManager` 不存在、全程未写入。

---

## 0. 结论摘要

独立审计提出的 5 项问题（2×P1、3×P2）与 1 项可选安全加固已全部实施并补充专项测试：

| 优先级 | 审计问题 | 修复结果 | 专项测试 |
|---|---|---|---|
| P1 | 0 字节已有数据库被 SQLite 当作空库自动迁移 | 已修复：`database-empty-existing-file` fail-closed；另补主库缺失但残留 WAL/journal 的 `database-orphaned-sidecar` fail-closed | `tests/zero_byte_database.rs`（6 项） |
| P1 | 便携路径只校验盘符字符串，未验证真实卷/重解析点 | 已修复：Win32 句柄解析真实最终路径 + 卷类型校验；D→C Junction 在写入前拒绝 | `tests/windows_real_paths.rs`（4 项）+ 2 个单元测试 |
| P2 | 已有数据库在兼容性/完整性检查前设置 `journal_mode=WAL` | 已修复：严格预检查顺序；被拒数据库 SHA-256 与 `journal_mode=DELETE` 均不变 | `tests/database_precheck_order.rs`（3 项） |
| P2 | 无条件清理 `.work.db.init-*`，无跨进程初始化锁 | 已修复：`LockFileEx` 跨进程初始化锁；仅持锁清理；崩溃后自动恢复 | `tests/init_concurrency.rs`（2 个场景，真实双进程） |
| P2 | `get_database_health` 同步执行完整性检查可能阻塞 UI | 已修复：async 命令 + `spawn_blocking`；DTO 契约不变 | `src-tauri` 单元测试（真实 async runtime + spawn_blocking） |
| 可选 | `csp = null` | 已实施生产 CSP + devCsp；真实 Release WebView2 重载后 **0 条 CSP 违规**，UI/IPC 正常 | `inspect-release-ui.mjs`（21 项断言） |

最终回归：**`cargo test --workspace` = 52 passed / 0 failed**；`cargo fmt --check`、`cargo check --workspace --all-targets`、`npm run check`（0 error/0 warning）、`npm run build`、`npm run tauri build -- --no-bundle` 全部退出码 0。Release 运行时验证：便携路径 106 项（PASS 90 / FAIL 0 / WARN 1）、异常注入 **73 项（PASS 64 / FAIL 0 / WARN 0）**、真实窗口 CDP 21/21 断言通过。新 Release EXE SHA-256：`C863CAC5DEE29CD7A5DB25DA3B4610023CB8C4BF59DD97534764BC7D96FA67F4`。

---

## 1. P1：零字节数据库保护

### 1.1 根因与边界验证

修复前 `Database::initialize` 只区分“文件存在/不存在”，已存在的 0 字节 `work.db` 会被交给 SQLite 打开；SQLite 把 0 字节文件视为合法空数据库，于是自动执行 migration，相当于把异常空文件当作首次安装。

返工前先用本机实验确认 WAL 边界（证据：`D:\WorkManager-test-data\wal-probe2-*`、`wal-recovery-probe-*`）：

1. 用独立进程在 WAL 模式写入数据后 `os._exit(7)` 模拟崩溃：主库 4096 B、WAL 16512 B。
2. 将主库截断为 0 字节、保留 16512 B WAL：用 SQLite 打开后 `integrity_check=ok`、`user_version=0`、无任何表，**WAL 文件被删除**。

结论：**“0 字节主库 + 非空 WAL”不是 SQLite 可自动恢复的状态**，打开它只会把空库当真并丢弃 WAL。因此正确策略是 **fail-closed 且不打开文件**，同时保留主库/WAL 原样供用户从备份恢复或人工处理。

### 1.2 实现

文件：`crates/workmanager-core/src/database/mod.rs`、`src/error.rs`

- `initialize` 先用只读 `symlink_metadata` 区分首次安装与已有数据库；已有数据库按 A/B 两种异常分支处理：
  - **A. 0 字节主库** → 返回 `database-empty-existing-file`（新错误变体 `EmptyExistingDatabase`）。错误消息包含 0 字节事实、是否检测到非空 WAL、以及“不会删除/截断/覆盖、不会当作首次安装、不会自动重建；请从备份恢复或用户确认后手动处理”。
  - **B. 主库缺失但存在非空 `-wal` / `-journal`** → 返回 `database-orphaned-sidecar`（新错误变体 `OrphanedSidecar`），原样保留 sidecar 字节。
- 仅在“主库、WAL、journal 均不存在”时，才在持有初始化锁后清理孤立 `-shm`（运行时索引，不含已提交数据），避免不匹配的共享内存头阻止新库创建。
- 任何异常分支都不会进入 `create_new_database`，不会产生半初始化数据库或正式空库。

### 1.3 专项测试（`crates/workmanager-core/tests/zero_byte_database.rs`，6 项全部通过）

环境：Windows 10 本机，测试数据 `D:\WorkManager-test-data\zero-byte-*`。 \
命令与退出码：`cargo test -p workmanager-core --test zero_byte_database -- --nocapture` → **退出码 0，`test result: ok. 6 passed; 0 failed`**。

| 测试目的 | 实际结果 | 原文件是否保持不变 | 证据 |
|---|---|---|---|
| 已存在 0 字节 work.db 必须 fail-closed，且不当作首次安装、不生成 schema/临时库 | 错误码 `database-empty-existing-file`，消息含“0 字节”；主文件仍 0 字节；无 WAL/SHM；无 `.work.db.init-*`；数据目录无新增业务文件 | **是**：SHA-256 `e3b0c442…b855` 前后一致（空文件哈希） | 测试打印 `zero-byte-existing: code=database-empty-existing-file sha256=e3b0c44298fc…b855` |
| 用户确认删除异常空文件后，首次初始化仍可正常恢复 | `created_new=true`、`schema=1` | 测试自行删除其创建的 0 字节文件（模拟用户确认） | `zero-byte-existing: recovery-after-user-removal created_new=true schema=1` |
| 0 字节主库 + 崩溃残留 WAL 必须 fail-closed 且 WAL 不被 SQLite 丢弃 | 子进程崩溃写 WAL（主库 4096 B / WAL 16512 B）→ 截断主库为 0 → `database-empty-existing-file`；主库仍 0，WAL 保留 | **是**：主库 SHA-256 `e3b0c442…b855`、WAL SHA-256 `6a029b92…9cac` 前后一致；WAL 文件存在 | `zero-byte-wal: crash-state main=4096 wal=16512`；`zero-byte-wal: code=database-empty-existing-file main_sha256=… wal_sha256=…` |
| 主库缺失 + 非空 WAL 必须 fail-closed，不创建新库 | `database-orphaned-sidecar`（消息含 WAL）；未创建 work.db | **是**：崩溃产生的 WAL 16512 B、SHA-256 `647d7b31…6661` 前后一致 | `orphaned-wal: main_missing=true wal_size=16512 wal_sha256=647d7b31…` |
| 主库缺失 + 非空 journal 必须 fail-closed | `database-orphaned-sidecar`（消息含 journal） | **是**：journal 63 B、SHA-256 `5e526357…823f` 前后一致 | `orphaned-journal: main_missing=true journal_size=63 journal_sha256=5e526357…` |
| 孤立 `-shm`（无主库/WAL）不阻止首次初始化，并在持锁后清理 | 首次初始化成功：`created_new=true schema=1 integrity=ok journal_mode=wal` | 该用例无主库，测试后由 `TestDir` 清理 | `stale-shm: stale_shm_size=32768 main_missing=true`；`stale-shm: initialized created_new=true schema=1 integrity=ok journal_mode=wal` |

> 说明：测试 3 的“0 字节主库 + 有效 WAL”由独立子进程真实崩溃产生，再由测试截断主库构造；**不支持的自动 WAL 恢复路径已被专门测试**（结果是 SQLite 会丢弃 WAL，因此应用选择拒绝打开并保留证据）。

---

## 2. P1：D 盘真实路径 / 卷校验

### 2.1 实现（`crates/workmanager-core/src/portable_paths.rs`，+384 行）

- 新增真实最终路径解析：`CreateFileW(FILE_READ_ATTRIBUTES, FILE_FLAG_BACKUP_SEMANTICS)` → `GetFinalPathNameByHandleW(VOLUME_NAME_DOS)`（正确处理缓冲区不足二次调用；RAII `HandleGuard` 保证 `CloseHandle`）；**不使用 `std::fs::canonicalize` 单点判断**，句柄解析天然展开完整祖先链上的 Junction/符号链接。
- 真实卷校验：最终路径必须是本地盘符，盘符必须为 D，且 `GetDriveTypeW` ∈ {`DRIVE_FIXED`, `DRIVE_REMOVABLE`}；拒绝 `DRIVE_REMOTE`（映射网络盘）、`DRIVE_CDROM`、`DRIVE_RAMDISK`、`DRIVE_NO_ROOT_DIR`、UNC/卷 GUID/设备路径。
- 接入点：
  - `resolve()`：对已存在的 EXE 所在目录、`data_root` 做真实卷校验（不存在的路径保留原纯字符串 D 盘规则，兼容既有单元测试）；
  - `ensure_directories()`：在**任何** `create_dir_all` / 写探针**之前**校验便携根目录 + `data_root` 最近已存在祖先；创建后再对 `data_root` 与 7 个子目录（含 database、cache/webview2）复验；之后才写探针。
- 新增稳定错误码：`path-real-location-unavailable`、`path-real-target-not-d`（D→C Junction 等）、`path-not-local-volume`（网络盘/UNC/非 FIXED-REMOVABLE 卷）。错误消息均说明“已停止启动，不会回退到 C 盘、AppData 或系统 Temp”。
- 保留全部原有规则：Release 忽略 `WORKMANAGER_TEST_PORTABLE_ROOT`、Debug/Test 必须显式 D 盘隔离根目录、拒绝 `..`、Debug 拒绝正式目录 `D:\WorkManager`、目录写探针。

### 2.2 实机测试（`crates/workmanager-core/tests/windows_real_paths.rs`，4 项全部通过）

环境：Windows 10 本机；D 盘测试目录 `D:\WorkManager-test-data\realpath-*`；C 盘夹具仅测试临时目录 `%LOCALAPPDATA%\WorkManager-junction-test-*`（Drop guard 清理）。 \
命令与退出码：`cargo test -p workmanager-core --test windows_real_paths -- --nocapture` → **退出码 0，`test result: ok. 4 passed; 0 failed`**。

| 测试目的 | 实际结果 | C 盘目标是否产生应用数据 | 证据（真实输出摘要） |
|---|---|---|---|
| 正常 D 盘目录仍可运行 | `resolve`/`ensure_directories` 成功，数据库目录可写（写入-读回-删除探针） | 不适用 | `[normal] resolve OK…`；`[normal] ensure_directories OK…`；`[normal] database 目录可写…` |
| **D→C Junction 作为便携根目录**：模拟从 Junction 路径启动 | `resolve(Release, link\WorkManager.exe)` → `path-real-target-not-d`；`ensure_directories()` → `path-real-target-not-d`（写入前拒绝） | **否**：C 夹具目录条目数 = 0 | `[case A] resolve(...) -> code = path-real-target-not-d`；`[assert] C 盘夹具目录内条目数 = 0（期望 0）` |
| **Junction 位于 EXE 目录的祖先链**（link-ancestor\app-sub\WorkManager.exe） | `resolve` → `path-real-target-not-d`（真实目标 C 盘）；`ensure_directories` → 同样拒绝 | **否**：C 夹具仅存在测试自己创建的空子目录，无任何应用数据 | `[ancestor-A] resolve(...) -> code = path-real-target-not-d`；`[ancestor-B] ensure_directories() -> code = path-real-target-not-d`；`[assert] C 盘夹具目录条目 = ["app-sub"]（期望仅 ["app-sub"]）` |
| D 盘内部 Junction（真实目标仍在 D 盘）允许通过 | `ensure_directories` 成功，数据目录为真实 D 盘目标 | 不适用 | `[same-volume] 允许通过：真实数据目录 = D:\WorkManager-test-data\…\real-target\data` |

清理验证（真实输出）：`[cleanup] Junction 链接已删除（只删链接，未触碰目标内容）`；`[cleanup] C 盘测试夹具目录已删除`；`[cleanup] 已验证 Junction 与 C 盘夹具均已清理`。测试结束后 `C:\Users\...\AppData\Local\WorkManager-junction-test-*` 残留数为 0，`D:\WorkManager` 未被创建。

另新增 2 个单元测试（`portable_paths.rs`，`cargo test -p workmanager-core portable_paths` 退出码 0，10 passed）：
- `only_fixed_and_removable_volumes_are_allowed`：`DRIVE_FIXED/REMOVABLE → true`；`DRIVE_REMOTE/CDROM/RAMDISK/NO_ROOT_DIR/0 → false`；
- `real_final_path_drive_letters_are_parsed_conservatively`：`\\?\D:`/`D:`→D；`\\?\UNC\…`、`Volume{GUID}`、`\\.\PhysicalDrive0`→拒绝。

**未实机验证项（如实记录）：** 本机没有网络共享，**映射网络盘 `DRIVE_REMOTE` 仅做了逻辑级纯函数测试，未做真实网络盘实机验证**；光驱/内存盘同理。非 Windows 降级实现仅保证编译路径，本机未交叉编译验证（目标平台为 Windows 10）。

---

## 3. P2：已有数据库预检查顺序

### 3.1 实现（`database/mod.rs`、`database/connection.rs`）

`open_existing_database` 改为严格顺序：

1. 打开连接（只读语义的 `READ_WRITE` 打开，不修改数据库；仅设置连接级非持久 `busy_timeout`）；
2. 读取 `PRAGMA user_version`；
3. `PRAGMA integrity_check`；
4. `PRAGMA foreign_key_check`；
5. 判断 schema 兼容性：高于支持版本立即返回 `schema-version-too-new`，**不再执行任何持久化配置**；
6. 只有健康且兼容才调用 `configure_runtime`：`foreign_keys=ON`、`journal_mode=WAL`（持久化）、`synchronous=FULL`、`temp_store=MEMORY` 并 `verify`；
7. 执行 migration（内部再次校验版本防止竞态）；
8. 迁移后复查完整性与外键。

`connection.rs` 的 `configure` 被拆分为 `set_busy_timeout`（连接级）与 `configure_runtime`（持久化/运行期），并在文档注释中写明调用时机约束，防止后续代码再犯同类顺序错误。

### 3.2 专项测试（`crates/workmanager-core/tests/database_precheck_order.rs`，3 项全部通过）

命令与退出码：`cargo test -p workmanager-core --test database_precheck_order -- --nocapture` → **退出码 0，`test result: ok. 3 passed; 0 failed`**。

| 测试目的 | 实际结果 | 原文件 SHA-256 是否不变 | journal_mode / 数据 | 证据 |
|---|---|---|---|---|
| DELETE 模式 + `user_version=999` 的已有数据库启动必须失败且不被修改 | 错误码 `schema-version-too-new` | **是**：`283dc2907be730ccc7fffb388d374864048f1fc6b0a38a4d37d5b13f85f50c1f` 前后一致，大小 8192 B 不变 | 仍为 `delete`；`user_version=999`；虚构数据行完整可读；未创建 WAL/journal | `precheck-version-too-new: before sha256=283dc290… size=8192 journal_mode=delete user_version=999` |
| DELETE 模式损坏数据库（中间页 0xFF）启动必须失败且不被提前修改 | 错误码 `database-integrity-check-failed` | **是**：`b365545f343348b2c28c8cfbcd7b2d2b8f06bc84e0465e1bdc0a61aeed2686a1` 前后一致，大小 966656 B 不变 | 仍为 `delete`；未创建 WAL/journal | `precheck-corrupt-delete: before sha256=b365545f… size=966656 journal_mode=delete`；`precheck-corrupt-delete: code=database-integrity-check-failed` |
| 健康 DELETE 模式数据库在预检查通过后才升级为 WAL，数据保留 | 初始化成功，`journal_mode=wal`、`schema_version=1`、`integrity=ok`，虚构 canary 保留 | 升级属于预期写入 | 由 DELETE 升级为 WAL | `precheck-healthy-delete-upgrade: journal_mode=wal schema_version=1 canary_preserved=true` |

---

## 4. P2：临时数据库初始化竞争（跨进程锁）

### 4.1 实现（新增 `database/init_lock.rs`；`database/mod.rs` 接入）

- 使用 `data/database/.work.db.init.lock` + Windows `LockFileEx`（`LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY`）锁定首字节，实现**跨进程独占初始化锁**。
- **首次初始化**：必须先成功取得锁（最长等待 5 秒；超时返回 `database-initialization-locked` fail-closed，可安全重试），取得锁后才允许：重新检查数据库是否存在、清理 `.work.db.init-*`、创建临时库并 hard-link 安装正式库。
- **打开已有数据库**：只做非阻塞“尽力加锁”；取得锁才清理遗留临时文件；未取得锁绝不删除任何文件。因此不会删除活动进程正在使用的临时数据库。
- **崩溃恢复**：锁由操作系统维护，进程正常退出、panic、被强杀时自动释放；无需 PID 心跳或超时清理。锁文件本身永久保留（0/小体积诊断信息），不删除以避免破坏锁语义。
- 错误码：`database-initialization-locked`、`database-initialization-lock-failed`。

### 4.2 专项测试（`crates/workmanager-core/tests/init_concurrency.rs`，2 个场景 + 1 个子进程辅助 = 3 项通过）

命令与退出码：`cargo test -p workmanager-core --test init_concurrency -- --nocapture --test-threads=1` → **退出码 0，`test result: ok. 3 passed; 0 failed`**。 \
测试通过 `std::env::current_exe()` + `--exact child_helper` 启动**真实独立子进程**，不是线程模拟。

| 测试目的 | 实际结果 | 证据 |
|---|---|---|
| 两个真实进程同时首次初始化 | 两子进程均成功（退出码 0）；最终只有 1 个 `work.db`；无初始化临时文件；`integrity=ok`；`schema_migrations` 恰好 1 条；父进程再次初始化 `created_new=false` | `init-concurrency: spawned pids 28456 and 20320; releasing start trigger`；`init-concurrency: both children succeeded; single work.db; integrity=ok; migrations=1; temp_files=none` |
| 活动进程的临时数据库不得被删除；锁被占用时 fail-closed；强杀后锁自动释放并可清理遗留 | 子进程持锁并创建活动临时库；父进程 `InitializationLock::acquire(400ms)` → `database-initialization-locked`；父进程随后以已有库启动成功且活动临时文件仍存在；强杀子进程后父进程可重新取得锁，重启清理遗留临时文件；`integrity=ok`；虚构 canary 保留 | `init-active-temp: child pid=41016 holds lock; active temp=…\.work.db.init-41016-active.tmp`；`init-active-temp: lock_busy_code=database-initialization-locked; active temp preserved; after-kill lock recovered; temp cleaned; integrity=ok; canary_preserved=true` |

另加“失败进程可安全重试”：上表中父进程在锁超时失败后，子进程被杀即可重新初始化成功，即失败后重试路径被实际覆盖。

---

## 5. P2：数据库命令异步派发（不阻塞 UI 线程）

### 5.1 实现（`src-tauri/src/commands/mod.rs`、`src-tauri/src/app_state.rs`）

- `get_database_health` 改为 `async` 命令，接收 `tauri::AppHandle`，通过 `app.state::<AppState>()` 取得一个只含 `Arc<PortablePaths>` + `Arc<Mutex<Option<Database>>>` 的 `DatabaseHealthContext`（`Send + 'static`），然后使用 `tauri::async_runtime::spawn_blocking(move || context.run_health_check()).await` 执行完整 `PRAGMA integrity_check`。
- 主线程只做命令派发；同步 rusqlite 操作全部在阻塞线程池执行；Mutex 只在线程池内短暂持有；不把 `Connection` 或任意 SQL 传给前端；IPC DTO 字段与修复前完全一致（前端无需改动）。
- 应用退出时仍通过 `shutdown()` 显式关闭连接（WAL checkpoint、清理 `-wal`/`-shm`）。

### 5.2 测试

- `cargo test -p workmanager --lib -- --nocapture` → **退出码 0，`test result: ok. 1 passed`**：
  `app_state::tests::health_check_runs_on_blocking_pool_and_returns_unchanged_contract`。该测试构造真实 Debug/Test 便携目录与 SQLite 数据库，经**真实 Tauri async runtime** 调用 `spawn_blocking`，断言返回 DTO（appName/appVersion/runtimeMode/status/schemaVersion/journalMode/foreignKeys/busyTimeout/databasePath）与修复前契约一致，并验证上下文可 `Send`。
- Release 端到端：CDP 直接调用真实 `get_database_health`（见 §7），返回 schema=1、WAL、FULL、5000、foreignKeys=true、migration 1 条、便携路径正确。

---

## 6. 可选安全加固：CSP

`src-tauri/tauri.conf.json` 由 `"csp": null` 改为：

- 生产 `csp`：`default-src 'self'; connect-src ipc: http://ipc.localhost; img-src 'self' data: asset: http://asset.localhost; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'`
- 开发 `devCsp`：额外允许 `http://localhost:1420`、`ws://localhost:1420` 与内联脚本（Vite HMR），不放宽生产策略。

验证方式（真实 Release WebView2 + CDP）：
1. `Page.addScriptToEvaluateOnNewDocument` 注入 `securitypolicyviolation` 收集器；
2. `Page.reload` 重新加载真实页面；
3. 等待 Svelte 渲染完成并再次调用 IPC；
4. 读取 `window.__wmCspViolations`。

实际结果（证据 JSON 见 §10）：`noCspViolations=true`、`csp.violations=[]`，页面 21/21 断言全部通过（含 UI 渲染、IPC 返回、版本、路径）。**未在 Debug/`tauri dev` 下做 CSP 端到端验证**（devCsp 已配置但未实跑）；这属于未覆盖项，生产 Release 已验证。

---

## 7. 新增/变更测试清单与逐项实际结果

| 测试文件 | 数量 | 目的 | 命令 | 退出码 | 结果 |
|---|---|---|---|---|---|
| `crates/workmanager-core/tests/zero_byte_database.rs` | 6 | 0 字节库保护、WAL/journal 孤儿边界、孤立 SHM | `cargo test -p workmanager-core --test zero_byte_database -- --nocapture` | 0 | 6 passed / 0 failed |
| `crates/workmanager-core/tests/database_precheck_order.rs` | 3 | 预检查顺序与“拒绝前不修改” | `cargo test -p workmanager-core --test database_precheck_order -- --nocapture` | 0 | 3 passed / 0 failed |
| `crates/workmanager-core/tests/init_concurrency.rs` | 3（含 1 个子进程辅助入口） | 双进程并发首次初始化、锁忙/崩溃恢复、活动临时库保护 | `cargo test -p workmanager-core --test init_concurrency -- --nocapture --test-threads=1` | 0 | 3 passed / 0 failed |
| `crates/workmanager-core/tests/windows_real_paths.rs` | 4 | D 盘真实卷、Junction（根/祖先链）、D→C 拒绝、C 盘零写入、清理 | `cargo test -p workmanager-core --test windows_real_paths -- --nocapture` | 0 | 4 passed / 0 failed |
| `crates/workmanager-core/src/portable_paths.rs`（单元，+2） | 10 | 原 8 项 + 卷类型白名单 + 最终路径盘符解析 | `cargo test -p workmanager-core portable_paths` | 0 | 10 passed / 0 failed |
| `src-tauri/src/app_state.rs`（单元，+1） | 1 | 真实 Tauri async runtime + `spawn_blocking` + DTO 契约 | `cargo test -p workmanager --lib -- --nocapture` | 0 | 1 passed / 0 failed |
| `scripts/verify/verify-release-faults.ps1`（扩展） | +13” 检查 | 新增“已存在 0 字节 work.db”故障注入用例 | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1` | 0 | 73 项：64 PASS / 0 FAIL / 0 WARN / 9 INFO |
| `scripts/verify/inspect-release-ui.mjs`（扩展） | +2 断言 | 注入 CSP 违规收集器 + 重载页面验证 | `node scripts\verify\inspect-release-ui.mjs …` | 0 | 21/21 断言 PASS，CSP 违规 0 |

所有测试数据均使用虚构内容，位于 `D:\WorkManager-test-data` 下唯一目录；每条新测试在完成断言后清理自身创建的 D 盘目录（Windows Junction 用例额外独立清理 C 盘测试夹具，且验证 C 盘目标目录不产生应用数据）。

---

## 8. 完整回归测试结果

| # | 命令 | 退出码 | 结果摘要 |
|---|---|---|---|
| 1 | `cargo fmt --all -- --check` | 0 | 无格式差异 |
| 2 | `cargo check --workspace --all-targets` | 0 | 编译通过，无警告 |
| 3 | `cargo test --workspace` | 0 | **52 passed / 0 failed**：workmanager lib 1、core lib 10、database_fail_closed 8、database_lifecycle 5、database_precheck_order 3、foreign_keys 2、init_concurrency 3、migration_rollback 5、portable_paths 5、windows_real_paths 4、zero_byte_database 6 |
| 4 | `npm run check` | 0 | svelte-check 0 errors, 0 warnings |
| 5 | `npm run build` | 0 | vite 构建成功 |
| 6 | `npm run tauri build -- --no-bundle` | 0 | Release 构建成功（3m35s） |
| 7 | `scripts/verify/verify-release-portable.ps1` | 0 | 106 项：PASS 90 / FAIL 0 / WARN 1 / INFO 15；唯一 WARN 仍是**验证前已存在**的 `%LOCALAPPDATA%\EBWebView`（2024 年创建、本次前后未变化，非本次创建） |
| 8 | `scripts/verify/verify-release-faults.ps1` | 0 | **73 项：PASS 64 / FAIL 0 / WARN 0 / INFO 9**（新增 0 字节数据库用例全部 PASS） |
| 9 | `node scripts/verify/inspect-release-ui.mjs`（CDP） | 0 | **21/21 断言 PASS**：真实 WebView2 渲染 + 真实 IPC + CSP 违规 0 + 截图 |

**修复前后对比：** 便携路径检查由 106 项（90/0/1/15）保持；异常路径脚本由 59 项增至 73 项且 0 FAIL；Rust 测试由 33 项增至 52 项且 0 FAIL；前端检查保持 0 error/0 warning。

---

## 9. Release 构建与运行时验证（最终产物）

- 产物：`target\release\workmanager.exe`
- 大小：**9,962,496 字节**
- SHA-256：**`C863CAC5DEE29CD7A5DB25DA3B4610023CB8C4BF59DD97534764BC7D96FA67F4`**
- 构建命令：`npm run tauri build -- --no-bundle`（退出码 0；`Finished release profile [optimized] target(s) in 3m 35s`）
- 运行时证据目录（本机 D 盘，非仓库）：
  - 便携/持久化：`D:\WorkManager-test-data\release-verify-20261117-200747\`
  - 异常注入（含 0 字节库）：`D:\WorkManager-test-data\release-verify-20261117-200754\`
  - 真实窗口 UI/IPC/CSP：`D:\WorkManager-test-data\audit-fix-final-ui-20261117-200735\evidence\`
- 0 字节数据库故障用例实际结果（Release）：
  - 启动失败，原生对话框标题「WorkManager 启动失败」，退出码 1；
  - 错误码 `database-empty-existing-file`，消息含“0 字节（异常空文件）…不会把异常空文件当作首次安装”；
  - 原文件保持 0 字节，SHA-256 `E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855` 前后一致；
  - 未创建 WAL/SHM；数据库目录仅原 `work.db` 与初始化锁文件，未生成任何 schema；
  - 未残留 `.work.db.init-*`；应用自行正常退出（未强杀）。
- 真实窗口截图：[audit-fix-release-window.png](T1-01-assets/audit-fix-release-window.png)；原始 CDP 断言：[audit-fix-release-ui-ipc-evidence.json](T1-01-assets/audit-fix-release-ui-ipc-evidence.json)。

---

## 10. 未覆盖项、限制与风险（如实记录）

1. **映射网络盘/UNC 未实机验证**：本机无网络共享；`DRIVE_REMOTE` 仅纯函数级测试。`GetDriveTypeW` 逻辑已实现，但“真实映射网络盘”路径未端到端验证。
2. **非 Windows 平台未交叉编译验证**：目标平台为 Windows 10；`#[cfg(not(windows))]` 降级实现仅代码审阅，本机仅安装 MSVC target。
3. **TOCTOU 残余风险**：真实卷校验与目录创建/写探针之间非原子。已把校验前移并在创建后复验，但若攻击者能在校验后、使用前把目录替换为 Junction，仍存在理论窗口；彻底修复需句柄相对打开（`FILE_OPEN_REPARSE_POINT`/`NtCreateFile` + 句柄链校验），建议后续安全加固任务处理。
4. **盘符别名（SUBST / 卷挂载点）**：`subst D: C:\foo` 这类进程级映射未被专门识别（卷类型可能仍报 FIXED）；建议后续用 `VOLUME_NAME_NT`/卷序列号比对 D: 根与目标卷，并补充正/负测试。
5. **CSP 仅在 Release 端到端验证**：`devCsp` 已配置但未在 `tauri dev` 实跑验证。
6. **锁文件与诊断信息**：`data/database/.work.db.init.lock` 是新增的持久锁文件（42 字节，仅 PID/时间戳，不含用户数据）；异常路径验证脚本已将其视为允许条目。
7. **既有已知项不变**：`%LOCALAPPDATA%\EBWebView` 为验证前已存在的共享目录（来源需发布阶段确认）；单实例保护仍待 T6-07；启动完整性检查的性能、物理拔盘/ProcMonitor 审计、备份恢复、业务功能等仍未覆盖（与原报告一致）。
8. 本次未新增/删除任何现有测试，未降低任何测试要求；原有 33 项 Rust 测试全部保留并通过。

---

## 11. 证据位置

- 仓库内：
  - 本报告
  - [最终 Release 窗口截图](T1-01-assets/audit-fix-release-window.png)、[CDP UI/IPC/CSP 断言 JSON](T1-01-assets/audit-fix-release-ui-ipc-evidence.json)
  - 原始测试报告：[T1-01-REPORT.md](T1-01-REPORT.md)（历史证据，未删除；其结论已被本报告修订）
- 本机 D 盘证据目录（非仓库内容）：
  - 专项 cargo 测试日志：`D:\工作事项看板\test-artifacts\audit-final-*.log`
  - Release 运行时汇总：`D:\WorkManager-test-data\release-verify-20261117-200747\summary.json`、`...\release-verify-20261117-200754\summary.json`
  - 真实窗口证据：`D:\WorkManager-test-data\audit-fix-final-ui-20261117-200735\evidence\`

---

## 12. 状态声明

本次返工已完成代码修复、专项测试、完整回归与 Release 运行时复验，所有可复核证据已归档。**但开发代理自测与自动化验证不等于独立审计通过**：T1-01 保持「待审计」状态，需由独立审计（ChatGPT）核对修复 diff、测试证据与剩余风险后，才可决定是否关闭任务或进入 T1-02。PR #1 未合并、main 未推送、T1-02 未开始。
