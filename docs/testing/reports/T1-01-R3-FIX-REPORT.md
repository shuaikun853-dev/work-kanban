# T1-01 第三轮审计 R3 专项修复报告

**任务 ID：** T1-01 正式工程骨架、便携路径接入与 SQLite 基础设施 \
**报告日期：** 2026-11-18 \
**任务状态：** **待独立审计**（R3-01、R3-02 已修复并通过完整回归；TOCTOU 残余风险按 DEC-029 接受并延期至 Issue #2，未修复、未宣称绝对 C 盘写入保证；开发代理自测不等同独立审计通过） \
**第三轮审计对象：** PR #1 HEAD `eaf6ef7013a5f669c152e57bf4da94bc77367b85`（[T1-01-THIRD-AUDIT-REPORT.md](T1-01-THIRD-AUDIT-REPORT.md)） \
**返工前分支 HEAD：** `e3ec2ff2daffd28e21fbd51e984753c087345cfe`（含第三轮审计文档与 DEC-029 决策提交） \
**R3-01 修复提交：** `ae1eb65a00e0d36907f8769d1421aef17a73023f` \
**R3-02 修复提交：** `4942eb0c60bf43fd3d1371fbf427f5b0d043ebc1` \
**开发分支：** `task/T1-01-sqlite-foundation` \
**Pull Request：** [#1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（保持 Open、不合并；main 未修改；未开始 T1-02） \
**机器可读证据：** [T1-01-R3-FIX-evidence.json](T1-01-R3-FIX-evidence.json) \
**测试环境：** Windows 10 家庭中文版 19045 x64；Rust 1.100.0 / cargo 1.100.0（MSVC）；Node 22.20.0；WebView2 157.0.4341.60；Tauri 2.12.6；rusqlite 0.43.0 + bundled SQLite 3.54.1；测试数据目录 `D:\WorkManager-test-data`（D 盘隔离）。正式目录 `D:\WorkManager` 验证前后均不存在，全程未创建、修改或删除。

---

## 0. 结论摘要

| 审计问题 | 等级 | 修复情况 | 专项测试 |
|---|---|---|---|
| R3-01 D 盘根卷作为信任锚但自身未独立验证 | P1 | **已修复**：生产路径独立验证 D 根为真实卷挂载点、挂载点/句柄 GUID 一致、QueryDosDevice 映射为真实 NT 设备卷且与句柄设备身份一致、D 根与 C 根不同卷；任一步失败 `path-root-trust-anchor-invalid` fail-closed | **PASS**：6 项专项测试（含真实 D 盘、真实 SUBST Q:→C: 候选根、注入模拟 GUID 不一致/同卷/DOS 别名、API 失败） |
| R3-02 真实双进程初始化锁测试的同步确定性不足 | P2 | **已修复**：waiter 只有在底层 `LockFileEx` 明确返回锁竞争后才发确认信号，并改用完整 `Database::initialize()` 路径；creator 收到确认后才建库；父进程确认活动 WAL 后放锁 | **PASS**：专项测试 3 项；完整断言链通过；**10/10 连续多轮重复运行通过** |
| TOCTOU（R2-03 遗留） | — | 按 DEC-029 用户接受残余风险，转入 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)；**未修复**，不宣称绝不写入 C 盘 | 不在本轮范围 |

**回归总览：** `cargo test --workspace` = **68 passed / 0 failed**（上轮 62，新增 6 项 R3-01 测试，R3-02 为原有测试替换增强）；Release 便携验证 **106 项 PASS 90 / FAIL 0**；Release 异常注入 **73 项 PASS 64 / FAIL 0**；真实 Release WebView2 UI/IPC/CSP **21/21 断言通过、CSP 违规 0**。Release EXE：**9,993,216 字节**，SHA-256 **`41A8F6B4759107625487FE605820FAABF20D312A560AE9765949027D100F7800`**。

> 重要：本报告与自动化测试是**开发代理自测证据**，不等于独立审计通过；T1-01 只能标记“待独立审计”，不得标记验收完成。

---

## 1. R3-01：D 盘根卷信任锚独立验证

### 1.1 问题根因

修复前 `portable_paths.rs` 的 `d_drive_volume_identity()` 直接打开 `D:\` 句柄并读取其 `VOLUME_NAME_GUID` / `VOLUME_NAME_NT`，然后把目标目录句柄的卷身份与这个参考值比较。这只能证明“目标与当前 `D:\` 句柄指向同一卷”，却没有独立证明 `D:\` 本身是真实的本地卷挂载点。若 `D:` 是 SUBST 等 DOS 设备别名，则参考锚点本身不可信；此外原实现没有比较 `D:` 与 `C:` 是否为同一物理卷。

### 1.2 代码修改（`crates/workmanager-core/src/portable_paths.rs`）

新增生产函数（不是测试 helper，生产路径真实调用）：

1. `volume_mount_point_guid(mount_point)`：调用 `GetVolumeNameForVolumeMountPointW`，要求成功返回卷 GUID 路径；失败（例如 SUBST 盘符返回 `ERROR_INVALID_PARAMETER`）返回 `path-root-trust-anchor-invalid`。
2. `query_dos_device_target(device)`：调用 `QueryDosDeviceW`，取得 DOS 设备名（如 `D:`）的 NT 映射目标；失败 fail-closed。
3. `ensure_mount_point_guid_matches_handle(mount_point_guid, identity, root)`：纯校验，卷挂载点 GUID 必须与根目录句柄 `VOLUME_NAME_GUID` 一致。
4. `ensure_dos_device_maps_to_volume(device_target, identity, root)`：纯校验，`QueryDosDeviceW` 目标必须是 `\Device\HarddiskVolumeN` 形式的 NT 设备卷，且与根目录句柄 `VOLUME_NAME_NT` 一致；SUBST 的 `\??\C:\...` DOS 路径别名必须拒绝。
5. `ensure_root_volume_differs_from_c(root_mount_point_guid, c_mount_point_guid, root)`：纯校验，D 根卷 GUID 不得与 C 根卷 GUID 相同（数据必须位于独立 D 盘卷）。
6. `verify_root_volume_trust(root)`：按顺序执行上述验证 + 保留的卷类型白名单（`GetDriveTypeW` 固定盘/可移动盘），全部通过才返回根卷物理身份。
7. `d_drive_volume_identity()` 改为调用 `verify_root_volume_trust(D:\`)，生产卷身份比较的参考锚点只能来自已通过信任锚验证的 D 根卷。
8. `ensure_volume_is_d_volume()` 原样传播信任锚错误（新增稳定错误码 `path-root-trust-anchor-invalid`），不会在信任锚失败后继续比较或写入。

**生产调用链（证明生产真正使用该检查）：**

```text
PortablePaths::resolve()
  -> validate_real_storage_path(path)
       -> ensure_volume_is_d_volume(...)
            -> d_drive_volume_identity()
                 -> verify_root_volume_trust(D:\)
                      -> volume_mount_point_guid(D:\)               GetVolumeNameForVolumeMountPointW
                      -> volume_identity_for_path(D:\)              VOLUME_NAME_GUID / VOLUME_NAME_NT
                      -> ensure_mount_point_guid_matches_handle()
                      -> query_dos_device_target("D:")              QueryDosDeviceW
                      -> ensure_dos_device_maps_to_volume()
                      -> volume_mount_point_guid(C:\) + ensure_root_volume_differs_from_c()
                      -> query_drive_type() + is_allowed_volume_type()
PortablePaths::ensure_directories() -> validate_real_storage_path(...)（创建目录/写探针之前）
Database::initialize() -> PortablePaths::validate_write_boundary() -> validate_real_storage_path(...)（创建初始化锁/数据库之前）
```

原有安全检查全部保留：卷类型白名单、目标真实最终路径检查、目标句柄卷身份比较、Junction/重解析点检查、fail-closed 行为。

### 1.3 关键设计

- **独立证据链，而不是同一来源自证**：挂载点 API（`GetVolumeNameForVolumeMountPointW`）、根目录句柄（`VOLUME_NAME_GUID`）、DOS 设备映射（`QueryDosDeviceW`）是三个相互独立的 Windows API 来源；三者一致才信任 D 根。
- **SUBST 识别**：真实卷 `QueryDosDeviceW("D:")` 返回 `\Device\HarddiskVolumeN`；SUBST 返回 `\??\C:\...` 的 DOS 路径别名。生产分类函数要求映射目标必须是 NT 设备卷路径且与句柄 `VOLUME_NAME_NT` 相同，因此 SUBST 别名无法通过。
- **D/C 同卷拒绝**：分别用挂载点 API 取得 D 根与 C 根卷 GUID；相同即拒绝（产品要求数据位于独立 D 盘卷）。
- **可注入候选根**：`verify_root_volume_trust(root)` 接收候选根路径，生产固定传 `D:\`；测试用真实 SUBST `Q:` 盘符验证拒绝，不修改真实 D 盘。
- **fail-closed 时机**：信任锚验证位于 `validate_real_storage_path` 内、`resolve()`/`ensure_directories()`/`Database::initialize()` 的目录创建、写探针、初始化锁、数据库打开之前；失败即停止启动。

### 1.4 测试方法与结果

专项测试文件：`crates/workmanager-core/src/portable_paths.rs`（单元测试模块）；命令：

```powershell
cargo test -p workmanager-core --lib r3_01 -- --nocapture --test-threads=1
```

退出码 **0**，**6 passed / 0 failed**（[脱敏日志](T1-01-assets/r3-fix/logs/cargo-test-r3-01-trust-anchor.log.txt)）。

| 测试场景 | 类型 | 预期 | 实际结果 |
|---|---|---|---|
| 正常 D 盘独立卷：挂载点 GUID 与句柄 GUID 一致 | **真实 Windows 10 实机** | 允许 | PASS：D 挂载点 GUID = `\\?\volume{519fbe4e-b7fe-4b36-8393-11eb159db771}`，与句柄 `VOLUME_NAME_GUID` 完全一致；句柄 `VOLUME_NAME_NT` = `\device\harddiskvolume4`；`QueryDosDeviceW(D:)` = `\Device\HarddiskVolume4`；`GetDriveTypeW`=3（固定盘）；C 挂载点 GUID = `\\?\volume{8ee60a1e-b5a7-4feb-bda9-1c9de1e671ae}`，D≠C 不同卷 |
| 正常 D 与 C 为不同卷 | **真实实机** | 允许 | PASS（GUID 比较不同，`ensure_root_volume_differs_from_c` 通过） |
| 候选根为真实 SUBST `Q:` → C 盘目录 | **真实实机**（SUBST 夹具） | 拒绝 | PASS：`verify_root_volume_trust(Q:\)` 返回 `path-root-trust-anchor-invalid`，在 `GetVolumeNameForVolumeMountPointW` 阶段失败（系统错误 87）；`QueryDosDeviceW(Q:)` = `\??\C:\Users\<redacted>\AppData\Local\...`，生产分类函数 `ensure_dos_device_maps_to_volume` 同样拒绝 |
| D 根挂载点 GUID 与句柄 GUID 不一致 | **注入模拟**（非实机） | 拒绝 | PASS：`ensure_mount_point_guid_matches_handle` 返回 `path-root-trust-anchor-invalid`；注入相同 GUID 时通过纯校验 |
| D 根与 C 根 GUID 相同 | **注入模拟**（非实机） | 拒绝 | PASS：`ensure_root_volume_differs_from_c` 拒绝；不同 GUID 时通过 |
| QueryDosDevice 检测到 C 盘路径别名 / 设备不一致 | **注入模拟 + 真实 API 证据** | 拒绝 | PASS：注入 `\??\C:\Users\Public` 与 `\Device\HarddiskVolume99` 均拒绝；真实 D 盘映射 `\Device\HarddiskVolume4` 允许 |
| D 根卷身份 API 调用失败 | **真实 API 失败**（普通目录不是卷挂载点） | fail-closed | PASS：`volume_mount_point_guid(D:\WorkManager-test-data)` 返回 `path-root-trust-anchor-invalid`；非盘符根目录/UNC 作为信任锚均拒绝 |

**明确区分（不混淆证据性质）：**

- **真实 D 盘实机验证**：正常 D 盘信任锚、D/C 不同卷、真实 D 盘的 QueryDosDevice 映射。
- **Q: SUBST 实机验证**：真实 SUBST 盘符作为注入候选根被信任锚阶段拒绝；该 SUBST 目标位于 C 盘，但**不等同于把 D: 改为 SUBST 的实机场景**。
- **注入模拟**：GUID 不一致、D==C 同卷、DOS 别名/设备不一致等纯校验场景由测试注入参数验证，不是实机结果。
- **D:→C: SUBST 本身无法在本机构造**：D: 是真实物理卷，Windows 不允许对已存在盘符执行 SUBST；本报告不声称已验证该实机场景，但生产信任锚逻辑与 Q: SUBST 实机证据共同覆盖了同类 DOS 设备别名机制。

---

## 2. R3-02：真实双进程初始化锁测试同步确定性

### 2.1 原测试为什么存在竞态

修复前的 waiter 子进程流程是：先写 `b-inspected` 信号，**然后**才调用 `InitializationLock::acquire()`。creator 只等待 `b-inspected` 就继续创建数据库并释放锁。操作系统可能在 waiter 写完信号后暂停该进程，使 creator 完成初始化并释放锁之后 waiter 才第一次真正尝试加锁。因此旧测试不能严格证明“waiter 在 creator 持锁期间观察到锁竞争”；另外旧 waiter 直接调用私有 `open_or_create_after_lock()`，没有覆盖完整 `Database::initialize()` 调用链。

### 2.2 新同步机制

1. `init_lock.rs` 新增 **`#[cfg(test)]` 专用锁竞争观察点** `test_contention_observer`：
   - 仅在测试构建中存在，不是生产 API、不是 IPC、没有配置开关；
   - 未安装回调时是空操作，**不改变加锁/等待/重试语义**；
   - 只有在 `LockFileEx` 明确返回 `ERROR_LOCK_VIOLATION`（即真实锁竞争）时，`acquire()` / `try_acquire()` 才调用回调。
2. waiter 子进程安装观察回调后，调用**完整生产 `Database::initialize()`**：
   - 初次检查主库不存在 → 首次安装分支 → `InitializationLock::acquire()` → 第一次底层加锁返回 busy → 观察点写 `b-lock-contention`（内容：PID、`try_lock_exclusive=busy`、锁文件路径）→ 继续正常等待/重试；
   - 取得锁后由生产代码 `open_or_create_after_lock()` 先重检主库，正常打开，不把活动 WAL 判为孤儿。
3. creator 子进程：取得初始化锁 → 写 `a-has-lock` → **等待 `b-lock-contention` 后才创建数据库** → 创建正式库、进入 WAL、写入虚构 canary（WAL 非空）→ 写 `a-created` → 继续持锁等待父进程 `parent-release-lock` → 释放锁。
4. 父进程：等 `a-has-lock` → 启动 waiter → 等 `b-lock-contention`（证明真实竞争）→ 等 `a-created` → 检查 creator 仍持锁运行、主库与活动 WAL 已存在 → 写 `parent-release-lock` → waiter 取得锁并通过完整 `Database::initialize()` 打开已有数据库 → 复核 canary/integrity/migration。
5. 所有等待均有超时；子进程守卫在 panic 时强杀，避免测试永久挂起。同步使用文件信号 + 真实跨进程锁，**不使用固定 sleep 安排进程先后顺序**。

**测试专用观察点是否影响生产？** 观察点代码由 `#[cfg(test)]` 编译，不进入 Release/生产二进制；回调只在底层锁操作已返回竞争之后调用，未改变加锁结果、等待时间或锁文件语义。

### 2.3 验收标准逐项回执

| # | 验收标准 | 回执 |
|---|---|---|
| 1 | Creator 确实持有初始化锁 | PASS：`a-has-lock` 后 creator 等待 `b-lock-contention`，期间未创建数据库；父进程断言锁文件存在且 creator 进程仍在运行 |
| 2 | Waiter 在锁仍被持有时实际尝试获取锁 | PASS：`b-lock-contention` 只在 `LockFileEx` 返回锁竞争时写出；creator 只有在收到该信号后才创建数据库 |
| 3 | Waiter 得到明确的锁竞争结果 | PASS：信号内容 `try_lock_exclusive=busy`（来自底层竞争结果），父进程断言该内容 |
| 4 | Creator 收到 waiter 竞争确认后才继续 | PASS：creator 代码先等 `b-lock-contention` 再调用创建数据库逻辑 |
| 5 | Creator 创建正式数据库并产生有效活动 WAL | PASS：父进程观测 `main_db_bytes=20480`、`wal_bytes=8272`，且 creator 进程仍在运行 |
| 6 | Waiter 获取锁后正确识别已有数据库 | PASS：waiter 通过完整 `Database::initialize()` 打开已有数据库（`created_new=false`） |
| 7 | 不把有效 WAL 误判为孤儿文件 | PASS：waiter stderr 无 `database-orphaned-sidecar`；`orphaned_sidecar=false` |
| 8 | 不重复创建数据库/错误初始化 | PASS：`schema_migrations` 恰好 1 条，migration 只执行一次 |
| 9 | canary、migration、完整性检查全部通过 | PASS：虚构 canary 保留、`integrity=ok`、`applied_migrations=1` |
| 10 | 重复运行稳定，不依赖调度运气 | PASS：专项测试 **10/10 连续多轮真实进程运行通过**（每轮独立 `cargo test` 调用） |

### 2.4 测试命令与结果

```powershell
cargo test -p workmanager-core --lib r2_01 -- --nocapture --test-threads=1
```

退出码 **0**，**3 passed / 0 failed**（1 个真实双进程场景 + 子进程辅助入口 + 隔离夹具检查；[脱敏日志](T1-01-assets/r3-fix/logs/cargo-test-r3-02-lock-contention.log.txt)）。关键输出：

```text
r3-02: waiter observed real lock contention: pid=... try_lock_exclusive=busy lock_file=...\.work.db.init.lock
r3-02: creator holds lock with active WAL before waiter acquires it; main_db_bytes=20480 wal_bytes=8272
r3-02-waiter: full Database::initialize observed real lock contention; acquired lock after creator;
              main_db_exists=true; opened_existing=true; orphaned_sidecar=false;
              canary_preserved=true; integrity=ok; migrations=1
r3-02: PASS — waiter observed real lock contention in Database::initialize; creator created DB+active WAL
       while holding the lock; waiter acquired it after release and opened the existing DB
       (no orphaned-sidecar); canary preserved; integrity=ok; migrations=1
```

**多轮稳定性：** 连续 10 轮独立运行（命令相同，每轮独立启动真实 creator/waiter/父进程）**10/10 全部通过**，无超时、无孤儿 sidecar 误判（[脱敏日志](T1-01-assets/r3-fix/logs/cargo-test-r3-02-stability-10x.log.txt)）。

---

## 3. 完整回归测试结果

| # | 命令 | 退出码 | 结果摘要 | 脱敏日志 |
|---|---|---|---|---|
| 1 | `cargo fmt --all -- --check` | 0 | 无格式差异 | [log](T1-01-assets/r3-fix/logs/cargo-fmt-check.log.txt) |
| 2 | `cargo check --workspace --all-targets` | 0 | 编译通过，无警告 | [log](T1-01-assets/r3-fix/logs/cargo-check.log.txt) |
| 3 | `cargo test --workspace` | 0 | **68 passed / 0 failed / 0 ignored** | [log](T1-01-assets/r3-fix/logs/cargo-test-workspace.log.txt) |
| 4 | `npm run check` | 0 | svelte-check 0 errors / 0 warnings | [log](T1-01-assets/r3-fix/logs/npm-check.log.txt) |
| 5 | `npm run build` | 0 | vite 8.3.8 构建成功 | [log](T1-01-assets/r3-fix/logs/npm-build.log.txt) |
| 6 | `npm run tauri build -- --no-bundle` | 0 | Release 构建成功（4m07s） | [log](T1-01-assets/r3-fix/logs/tauri-build.log.txt) |
| 7 | `scripts/verify/verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1 INFO=15 OVERALL=PASS | [log](T1-01-assets/r3-fix/logs/verify-release-portable.log.txt) |
| 8 | `scripts/verify/verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9 OVERALL=PASS | [log](T1-01-assets/r3-fix/logs/verify-release-faults.log.txt) |
| 9 | `node scripts/verify/inspect-release-ui.mjs`（真实 Release WebView2 + CDP） | 0 | 21/21 断言 PASS；CSP 违规 0；正常关闭后仅 `work.db` + 锁文件 | [log](T1-01-assets/r3-fix/logs/inspect-release-ui.log.txt) |

**R2/既有专项回归（全部 PASS，均含在 workspace 测试或单独日志中）：**

| 回归项 | 数量 | 结果 | 日志 |
|---|---|---|---|
| R2-02 正式目录 Junction 保护（`formal_root_protection`） | 5 | PASS | [log](T1-01-assets/r3-fix/logs/cargo-test-r2-02-junction.log.txt) |
| 零字节库/孤儿 WAL/journal（`zero_byte_database`） | 6 | PASS | [log](T1-01-assets/r3-fix/logs/cargo-test-zero-byte-database.log.txt) |
| 双进程首次初始化/锁恢复（`init_concurrency`） | 3 | PASS | [log](T1-01-assets/r3-fix/logs/cargo-test-init-concurrency.log.txt) |
| D 盘真实路径/Junction 拒绝（`windows_real_paths`） | 4 | PASS | [log](T1-01-assets/r3-fix/logs/cargo-test-windows-real-paths.log.txt) |
| 数据库 fail-closed（`database_fail_closed`） | 8 | PASS | [log](T1-01-assets/r3-fix/logs/cargo-test-database-fail-closed.log.txt) |
| 便携路径/SQLite 初始化其他集成套件（lifecycle/precheck/foreign_keys/migration_rollback/portable_paths） | 20 | PASS | workspace 日志 |
| 真实 Release 便携路径/持久化/忽略测试环境变量 | 106 项 | PASS 90 / FAIL 0 | portable 日志 |
| 真实 Release 路径与数据库异常（损坏库、0 字节库、路径被文件阻塞、work.db 为目录、ACL 拒绝写） | 73 项 | PASS 64 / FAIL 0 | faults 日志 |

**Release 产物：**

- 路径：`target/release/workmanager.exe`
- 大小：**9,993,216 字节**（上一轮 9,980,928）
- SHA-256：**`41A8F6B4759107625487FE605820FAABF20D312A560AE9765949027D100F7800`**
- 构建：`npm run tauri build -- --no-bundle`，退出码 0，`Finished release profile [optimized] target(s) in 4m 07s`
- 运行时：便携验证 WARN 1 仍为验证前已存在的 `%LOCALAPPDATA%\EBWebView`（本次运行前后未变化）；WorkManager 专属 C 盘目录不存在；真实窗口 UI/IPC/CSP 21/21；正常关闭后 `-wal`/`-shm` 已清理。

---

## 4. 未覆盖场景与遗留风险

1. **TOCTOU（已按 DEC-029 接受，未修复）**：真实路径/卷身份校验与后续目录创建、写探针、初始化锁、SQLite 按路径打开之间仍存在理论竞争窗口。本报告**不宣称任何情况下都不会写入 C 盘**。完整加固转入 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未经用户另行授权不启动；禁止静默回退 C 盘、已检测边界违规 fail-closed 的规则不变。
2. **真实 D:→C: SUBST 场景未实机构造**：D: 是真实物理卷，Windows 不允许对已存在盘符执行 SUBST；已用真实 SUBST Q:→C: 验证同一 DOS 设备别名机制，并明确标记证据差异。
3. **真实映射网络盘未实机验证**：本机无网络共享；卷类型白名单与最终路径/卷身份校验按 fail-closed 设计，但未做真实网络盘实机验证。
4. **D 盘路径下的真实跨卷目录挂载点未实机验证**：需要管理员权限与额外卷；未在用户机器上修改卷挂载配置。
5. **非 Windows 降级实现未交叉编译验证**：目标平台 Windows 10。
6. **devCsp 未在 `tauri dev` 下端到端验证**：生产 Release CSP 已通过 CDP 验证（0 违规）。
7. **应用级单实例保护未实现**（T6-07）；首次初始化已由 `LockFileEx` 串行化，R3-02 已强化其测试证据。
8. 物理拔盘、正式 `D:\WorkManager` 实跑、Process Monitor 级文件审计仍属阶段 6 发布验收。
9. 业务功能与备份恢复未实现，T1-01 只交付基础设施。
10. 开发代理自测与自动化验证不等于独立审计通过；需要独立审计重新核对 diff、证据与剩余风险。

---

## 5. 证据索引

- 机器可读证据：[T1-01-R3-FIX-evidence.json](T1-01-R3-FIX-evidence.json)
- 脱敏原始日志目录：[T1-01-assets/r3-fix/logs/](T1-01-assets/r3-fix/logs/)
- 真实窗口 UI/IPC/CSP 证据：[release-ui-ipc-evidence.json](T1-01-assets/r3-fix/release-ui-ipc-evidence.json)、[截图](T1-01-assets/r3-fix/release-window-r3.png)
- 第三轮独立审计报告（历史，未修改）：[T1-01-THIRD-AUDIT-REPORT.md](T1-01-THIRD-AUDIT-REPORT.md)
- 第二轮返工修复报告（历史，未修改）：[T1-01-SECOND-AUDIT-FIX-REPORT.md](T1-01-SECOND-AUDIT-FIX-REPORT.md)
- 第一轮修复报告（历史，未修改）：[T1-01-AUDIT-FIX-REPORT.md](T1-01-AUDIT-FIX-REPORT.md)
- 决策记录 DEC-029：[DECISIONS.md](../../decisions/DECISIONS.md)

---

## 6. 状态声明

- R3-01、R3-02 已完成代码修复、专项测试与完整回归；任务状态最多标记为 **待独立审计**。
- TOCTOU 按 DEC-029 属于**已接受并延期的未修复残余风险**，不得写成已修复，也不得宣称绝对保证不会写入 C 盘。
- PR #1 保持 Open、不合并；main 不修改；T1-02 不得开始。
- 独立审计通过并得到用户验收前，不得将 T1-01 标记为验收完成。
