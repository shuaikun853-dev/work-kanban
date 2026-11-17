# T1-01 第二轮独立审计返工修复报告

**任务 ID：** T1-01 正式工程骨架、便携路径接入与 SQLite 基础设施 \
**报告日期：** 2026-11-17 \
**任务状态：** **返工中 / R2-03 阻塞**（R2-01、R2-02、R2-04 已修复并通过回归；R2-03 真实卷身份已修复，但路径校验 TOCTOU 残余窗口未关闭，等待用户决策；**未标记待审计或验收完成**） \
**第二轮审计对象：** `892b25f9374a52cf74ba5f983f136295a52f2996`（[T1-01-SECOND-AUDIT-REPORT.md](T1-01-SECOND-AUDIT-REPORT.md)） \
**开发分支：** `task/T1-01-sqlite-foundation` \
**返工前分支 HEAD：** `a706dff609424baaf414e9634be5afdd3dd9a673`（含第二轮审计文档提交） \
**修复代码提交：** `a148f0d10eda994d21bb088984228b4e9d6b97ce` \
**Pull Request：** [#1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（保持 Open、不合并；main 未修改；未开始 T1-02） \
**证据文件：** [T1-01-AUDIT-FIX-evidence.json](T1-01-AUDIT-FIX-evidence.json) \
**测试环境：** Windows 10 家庭中文版 19045 x64；Rust 1.100.0 / cargo 1.100.0（MSVC）；Node 22.20.0；WebView2 157.0.4341.46；Tauri 2.12.6；rusqlite 0.43.0 + bundled SQLite 3.54.1；测试数据目录 `D:\WorkManager-test-data`（D 盘隔离）。正式目录 `D:\WorkManager` 验证开始前不存在，全程未创建、修改或删除。

---

## 0. 结论摘要

| 审计问题 | 等级 | 处理结果 | 专项测试 |
|---|---|---|---|
| R2-01 初始化锁后先检查孤儿 WAL，可能误判有效数据库的活动 WAL | P1 | **已修复**：取得锁后先重检主库，只有主库确实缺失才检查孤儿 sidecar | 确定性真实双进程测试（creator + waiter + 父进程）；`database::r2_01_tests` 3 项 PASS；既有 0 字节/孤儿 sidecar 6 项回归 PASS |
| R2-02 Debug/Test 正式目录保护可被同卷 Junction 绕过 | P1 | **已修复**：字符串 + 真实最终路径双重比较；可注入受保护根目录；在创建任何目录/写探针/锁/数据库之前拒绝 | `tests/formal_root_protection.rs` 5 项 PASS；真实目录零写入 |
| R2-03 真实卷身份与 TOCTOU 未充分关闭 | P1 | **部分修复 / 阻塞**：卷 GUID + NT 设备卷身份比对已实现并通过实机测试；TOCTOU 残余窗口未关闭，未宣称绝对保证 | 卷身份交叉核验 + SUBST→C 实机测试 PASS；D 盘卷身份相关回归 4 项 PASS；TOCTOU 保持未关闭并附完整方案 |
| R2-04 GitHub 证据与进度文档过期 | P2 | **已修复**：旧 evidence JSON 标记为历史；新增本报告与机器可读证据；脱敏日志入库；状态/计划/任务文档与 PR 描述同步 | 见第 4、5 节 |

**回归总览：** `cargo test --workspace` = **62 passed / 0 failed**（自上轮 52 项 +10）；Release 便携验证 **106 项 PASS 90 / FAIL 0**；Release 异常注入 **73 项 PASS 64 / FAIL 0**；真实 Release WebView2 UI/IPC/CSP **21/21 断言通过、CSP 违规 0**；Release EXE 大小 **9,980,928 字节**，SHA-256 **`849E803D2456B28DF8BABFE201E187FB0FC45B7104A5E2CD2FD34B1D4366019E`**。

> 重要声明：本报告、自动化测试和 Release 运行时验证都是**开发代理自测证据**，不等于独立审计通过。T1-01 仍为返工中/阻塞，PR #1 不合并，T1-02 不得开始。

---

## 1. R2-01：初始化锁后的 WAL 误判

### 1.1 根因

修复前 `Database::initialize` 在“首次安装”分支中，于取得跨进程初始化锁之后**先**调用 `orphaned_sidecar_error()`，**再**重新检查正式主库是否存在：

- 进程 B 初次检查时主库不存在，进入首次安装分支并等待初始化锁；
- 进程 A 取得锁，创建正式数据库、进入 WAL 模式并写入数据，随后释放锁（A 的连接仍然打开，因此 `work.db-wal` 非空）；
- B 取得锁后先看到非空 `-wal`，误判为“主库缺失 + 孤儿 WAL”，返回 `database-orphaned-sidecar` 拒绝启动；
- 实际上正式主库已经存在且有效。

### 1.2 修复

文件：`crates/workmanager-core/src/database/mod.rs`

- 把取得锁之后的处理收敛到 `open_or_create_after_lock()`，顺序变为：
  1. 先重新执行 `inspect_existing_database()`；
  2. 主库存在：只清理本模块初始化临时文件，正常打开；**不检查孤儿 sidecar**；0 字节异常主库仍 fail-closed；
  3. 主库确实缺失：才检查非空 WAL/journal，存在则 `database-orphaned-sidecar` fail-closed；
  4. 主库、WAL、journal 均不存在：才允许创建全新数据库；
  5. 原有 0 字节主库保护、孤儿 sidecar 保护、`-shm` 清理规则全部保留。
- 锁的获取/释放仍由 `initialize()` 管理；`open_or_create_after_lock()` 的参数仅表达“必须在持锁状态下调用”的约束，并在文档注释中写明。

### 1.3 确定性真实双进程测试

文件：`crates/workmanager-core/src/database/mod.rs`（`#[cfg(test)] mod r2_01_tests`）

测试用 `std::process::Command` 启动**真实独立子进程**（不是线程模拟），并用文件信号 + 跨进程锁保证确定性顺序，不依赖 sleep 时长：

1. 父进程创建 D 盘隔离的 Debug/Test 便携目录（不含数据库）；
2. 子进程 A（creator）先取得初始化锁，写 `a-has-lock` 信号；
3. 父进程等信号后启动子进程 B（waiter）；
4. B 初次检查正式主库不存在，写 `b-inspected` 信号，然后阻塞在初始化锁上；
5. A 看到 `b-inspected` 后在持锁状态下创建正式数据库、进入 WAL 模式、写入虚构 canary（`settings.key='r2-01-canary'`），确认 WAL 非空后写 `a-created` 信号并释放初始化锁；
6. B 取得锁后调用生产代码 `open_or_create_after_lock()`（先重检主库、再决定是否检查孤儿 sidecar）；
7. B 必须正常打开 A 已创建的数据库、canary 保留、integrity=ok、migration 只执行一次；
8. 父进程最终再次 `Database::initialize` 复核 canary、schema、完整性与 migration 记录。

实际结果（详见 [日志](T1-01-assets/second-audit-fix/logs/cargo-test-r2-01-waiter-active-wal.log.txt)）：

```text
r2-01: creator holds active WAL before waiter acquires lock; main_db_bytes=20480 wal_bytes=8272
r2-01-waiter: acquired lock after creator; main_db_exists=true; opened_existing=true;
              orphaned_sidecar=false; canary_preserved=true; integrity=ok; migrations=1
r2-01: PASS — waiter recognized existing database with active WAL; no database-orphaned-sidecar;
       canary preserved; integrity=ok; migrations=1
test result: ok. 3 passed; 0 failed; 0 ignored
```

> 回归保证：若有人把 `orphaned_sidecar_error()` 挪回重检主库之前，waiter 子进程会返回 `database-orphaned-sidecar` 并以非零退出码失败，父进程断言失败。

**既有保护回归：** `tests/zero_byte_database.rs` 6 项全部通过——0 字节主库、0 字节主库 + WAL、主库缺失 + 非空 WAL、主库缺失 + 非空 journal 全部保持 fail-closed 且原文件字节不变（[日志](T1-01-assets/second-audit-fix/logs/cargo-test-zero-byte-database.log.txt)）。

---

## 2. R2-02：Debug/Test 正式目录 Junction 绕过

### 2.1 根因

修复前 Debug/Test 只用输入字符串比较 `is_same_or_child(data_root, D:\WorkManager)`。同卷 Junction 别名（如 `D:\WorkManager-test-data\alias` → `D:\WorkManager`）输入字符串不包含正式目录前缀，因此可以绕过；后续真实路径校验只校验“仍在 D 盘”，没有再次检查是否等于/位于正式目录之下。

### 2.2 修复

文件：`crates/workmanager-core/src/portable_paths.rs`、`crates/workmanager-core/src/error.rs`、`crates/workmanager-core/src/lib.rs`

- 新增 `ensure_not_protected_root()`：
  - 第一步：规范化输入路径（大小写不敏感、统一分隔符）与受保护目录比较（覆盖受保护目录尚不存在的字符串场景）；
  - 第二步：用 Win32 句柄解析**真实最终路径**（`GetFinalPathNameByHandleW`，展开完整祖先链上的 Junction/符号链接）；路径不存在时解析最近已存在祖先；受保护目录存在时同样解析其真实最终路径；命中即返回 `debug-root-is-formal-release`。
  - 该检查发生在 `resolve()`、`ensure_directories()` 和 `Database::initialize()` 的任何目录创建、写探针、初始化锁、数据库写入之前。
- 新增 `PortablePaths::resolve_with_protected_roots()` 作为**测试注入点**：生产 `resolve()` 固定使用默认受保护目录 `D:\WorkManager`；测试注入 D 盘隔离的模拟正式根目录，绝不创建/修改/删除真实 `D:\WorkManager`。
- `PortablePaths` 增加受保护目录字段（`#[serde(skip)]`，不进入前端 DTO）。
- 新增 `DatabaseError::DirectoryBoundaryViolation`（错误码 `database-directory-boundary-violation`），保留底层 portable 错误码，用于数据库写入前的最后边界复验。
- Release 的 EXE 同级便携路径规则不变；受保护目录注入只影响 Debug/Test。

### 2.3 专项测试

文件：`crates/workmanager-core/tests/formal_root_protection.rs`（5 项，全部 PASS；[日志](T1-01-assets/second-audit-fix/logs/cargo-test-r2-02-formal-root-protection.log.txt)）

| 用例 | 断言与结果 |
|---|---|
| `resolve_rejects_junction_alias_to_protected_root` | Junction 别名指向模拟正式目录：resolve 返回 `debug-root-is-formal-release`，消息明确“真实最终路径检查命中”；含“Junction 为祖先、data_root 尚不存在”的嵌套场景；受保护目录零新增条目 |
| `ensure_directories_rejects_junction_created_after_resolve` | resolve 通过后把 data_root 替换为 Junction：ensure_directories 在创建任何目录/写探针前拒绝；受保护目录内无 config/logs/cache/database/写探针 |
| `database_initialize_rejects_swapped_junction_before_creating_lock_or_database` | ensure_directories 通过后再替换：`Database::initialize` 返回 `database-directory-boundary-violation`，保留底层 `debug-root-is-formal-release`；受保护目录无 `.work.db.init.lock`、`work.db`、`database/` 等任何应用数据 |
| `release_mode_ignores_injected_protected_roots` | Release 数据目录仍为 EXE 同级 `data`，注入的受保护目录零写入 |
| `default_protected_root_keeps_rejecting_formal_paths` | 生产默认 `D:\WorkManager` 字符串规则继续拒绝；`D:\WorkManager-test-data` 下测试目录仍允许；真实 `D:\WorkManager` 存在性/条目数快照前后一致 |

**测试隔离：** 模拟正式目录位于 `%WORKMANAGER_TEST_BASE_DIR%\<case>\formal-sim\WorkManager`；测试只创建/删除自身 Junction 与夹具（`JunctionGuard` 只删链接、不递归进入目标）。全程未触碰真实 `D:\WorkManager`。

---

## 3. R2-03：真实卷身份与 TOCTOU

### 3.1 Win32 API 评估

| API | 评估结论 | 本任务用法 |
|---|---|---|
| `GetFinalPathNameByHandleW(VOLUME_NAME_GUID)` | 返回句柄背后对象所在卷的 GUID 路径；由对象管理器解析 Junction/SUBST/挂载点别名，是**物理卷身份**的最直接证据 | **主校验**：目标路径句柄卷 GUID 必须等于 `D:\` 根目录句柄卷 GUID |
| `GetFinalPathNameByHandleW(VOLUME_NAME_NT)` | 返回 `\Device\HarddiskVolumeN` 设备路径，可在卷 GUID 不可用时比较同一物理卷 | **备用/交叉校验**：GUID 不可用时退回 NT 设备卷比较 |
| `GetVolumeNameForVolumeMountPointW` | 把盘符/卷挂载点转换为卷 GUID；对 SUBST 盘符返回失败（SUBST 不是卷挂载点） | 专项测试**独立交叉核验** `D:\` 的卷 GUID 与句柄结果一致 |
| `GetVolumePathNameW` | 只返回路径所在的盘符根或挂载点目录，不提供物理卷身份 | 已评估；不单独作为主校验，原因记录在此 |
| `QueryDosDeviceW` | 把 `D:` 等 DOS 设备名翻译为 NT 目标路径；可用于识别 SUBST 映射 | SUBST 专项测试记录映射目标作为证据 |

### 3.2 实现

文件：`crates/workmanager-core/src/portable_paths.rs`

- 打开目标路径句柄后，用同一句柄取 `VOLUME_NAME_GUID` / `VOLUME_NAME_NT`，并打开 `D:\` 根目录句柄取 D 盘根卷身份；两者不一致即 fail-closed 返回 `path-real-target-not-d`。
- 校验顺序：真实最终路径 → 物理卷身份必须与 D 盘根卷一致 → 最终 DOS 路径必须是 D 盘盘符 → `GetDriveTypeW` 必须是本地固定盘/可移动盘。
- `PortablePaths::validate_write_boundary()`：数据库目录最近已存在祖先的真实路径 + 物理卷身份 + Debug/Test 受保护目录边界；在 `Database::initialize()` 创建初始化锁/数据库之前调用。

### 3.3 实机覆盖情况（如实记录，不伪造）

| 场景 | 结果 | 证据 |
|---|---|---|
| 正常 D 盘本地固定盘 | **允许（实机验证）** | `windows_real_paths::normal_d_drive_layout_passes_real_path_validation` PASS；D 盘卷 GUID 由句柄与 `GetVolumeNameForVolumeMountPointW` 两个独立 API 交叉确认：`\\?\volume{519fbe4e-…}`，NT 设备 `\Device\HarddiskVolume4` |
| D 盘内部 Junction（真实目标仍在 D 盘） | **允许（实机验证）** | `windows_real_paths::junction_within_d_drive_is_allowed_when_real_target_stays_on_d` PASS |
| D 盘 Junction 指向 C 盘 | **拒绝（实机验证）** | `windows_real_paths::junction_from_d_to_c_is_rejected_without_writing_c_drive` PASS；C 盘夹具目录条目数 0 |
| SUBST 将 D: 映射到 C 盘目录 | **本机无法真实构造，已用等价机制实机验证并标注差异** | D: 是真实物理卷，Windows 不允许对已存在盘符执行 SUBST；改用空闲盘符 `Q:` SUBST 到 C 盘目录：Q: 句柄卷 GUID == C 盘卷 GUID（`8ee60a1e-…`）、!= D 盘卷 GUID；`QueryDosDeviceW(Q:)` 返回 `\\??\\C:\\Users\\<redacted>\\AppData\\Local\\…`；`validate_real_storage_path` 返回 `path-real-target-not-d`；`GetVolumeNameForVolumeMountPointW(Q:)` 返回失败（证明 SUBST 不是卷挂载点）。该用例是真实 SUBST 实机测试，但**不等同于 D:→C: 场景本身**。 |
| D 盘路径下的跨卷目录挂载点 | **未实机验证** | 构造真实目录卷挂载点需要管理员权限和额外卷；本任务未在用户机器上修改卷挂载配置，未伪造结果。逻辑上最终真实路径/物理卷身份比对路径与跨卷 Junction/SUBST 相同，仍需后续受控环境实机验证。 |
| 映射网络盘 | **未实机验证** | 本机无网络共享，无法构造真实映射网络盘；仅保留卷类型纯函数测试与 fail-closed 设计。 |

### 3.4 TOCTOU：未关闭的残余风险（阻塞项）

**当前状态：未关闭。** 路径校验（句柄解析真实最终路径 + 物理卷身份）完成后句柄关闭，后续 `create_dir_all`、写探针、初始化锁、SQLite 按路径打开仍然使用路径字符串；校验与实际写入之间非原子。若攻击者能在校验之后、写入之前把目录替换为重解析点，理论上仍可把数据重定向到其他卷。

**已实施的缓解（降低窗口，但不等于消除）：**

1. `resolve()` 对已存在路径做真实路径/物理卷身份校验；
2. `ensure_directories()` 在任何创建之前校验最近已存在祖先，并在创建后对 `data_root` 与全部子目录再次复验；
3. `Database::initialize()` 在创建初始化锁/数据库之前再次执行真实路径 + 物理卷身份 + 受保护目录边界复验；
4. R2-02 专项测试覆盖“ensure_directories 之后替换为 Junction”的场景，证明数据库边界复验会拒绝且零写入。

**明确不宣称：** 不宣称路径校验与写入已绑定同一目录对象；**不宣称任何情况下都不会写入 C 盘**；在用户决定前不将 T1-01 标记验收完成。

**完整改造方案（建议新增安全加固任务，或由用户决定是否纳入 T1-01 扩大范围）：**

1. 使用 `CreateFileW(FILE_FLAG_OPEN_REPARSE_POINT)` / `NtCreateFile` 打开目录链，逐级用句柄相对创建（`ObjectAttributes.RootDirectory`），对每一级比较 `FILE_ATTRIBUTE_REPARSE_POINT` 与真实卷身份，使校验与创建绑定到同一目录对象；
2. SQLite 不支持传入外部文件句柄，需评估：
   - custom SQLite VFS（按已校验句柄转发 Read/Write/Lock/Delete），或
   - “句柄相对创建目录 + 打开前后数据库文件卷身份/文件 ID 复核 + 失败立即停止并保留证据”的受控折衷；
3. 测试方案：并发替换攻击（重命名/Junction 替换、oplock 竞争）下启动 fail-closed 且目标卷零写入；逐级目录句柄链校验；SQLite 打开前后一致性检查；与 0 字节库、孤儿 sidecar、双进程初始化、Release 运行时验证的完整回归。

**阻塞条件：** 需要用户决定——(a) 接受 TOCTOU 残余风险并记录为后续安全加固任务（T1-01 仍不可直接验收，需要独立审计确认风险接受方式），或 (b) 要求 T1-01 内完成句柄相对改造（扩大任务范围与工期）。在用户明确决定前，T1-01 保持返工中/阻塞，不进入 T1-02。

---

## 4. R2-04：GitHub 证据与进度同步

1. **旧证据保留并标记历史：** `docs/testing/reports/T1-01-evidence.json` 保留原有内容，新增 `historical: true` 与 `historicalNote`，明确其记录的是返工前 `682ba04` 基线、33 项测试与旧 Release SHA，不得作为当前验收依据。
2. **新增返工后机器可读证据：** [T1-01-AUDIT-FIX-evidence.json](T1-01-AUDIT-FIX-evidence.json)，记录本轮代码提交、PR HEAD、全部测试命令/退出码/结果、Release SHA-256、已验证/未验证场景、未关闭风险与证据位置。
3. **新增本报告：** 不覆盖历史审计报告与第一轮修复报告。
4. **脱敏日志入库：** `docs/testing/reports/T1-01-assets/second-audit-fix/logs/` 下归档 16 份经过脱敏的原始日志（移除本机用户名、计算机名与仓库绝对路径），包括 cargo、npm、Tauri Release 构建、Release 便携验证、异常注入、真实窗口 UI/IPC/CSP 检查。
5. **同步进度文档：** `docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/tasks/T1-01-SQLite-Foundation.md` 更新为真实状态（返工中 / R2-03 阻塞），并修正“两个进程同时首次启动仍存在初始化竞争窗口”的过期表述（LockFileEx 已串行化首次初始化；应用级单实例仍属 T6-07）。
6. **更新 PR #1 描述：** 移除旧 33 项测试、旧 Release SHA、旧代码提交作为当前结论的描述，替换为本轮代码提交、62 项测试、最新 Release SHA 和 R2-03 阻塞状态。

---

## 5. 完整回归测试结果

| # | 命令 | 退出码 | 结果摘要 | 脱敏日志 |
|---|---|---|---|---|
| 1 | `cargo fmt --all -- --check` | 0 | 无格式差异 | [log](T1-01-assets/second-audit-fix/logs/cargo-fmt-check.log.txt) |
| 2 | `cargo check --workspace --all-targets` | 0 | 编译通过，无警告 | [log](T1-01-assets/second-audit-fix/logs/cargo-check.log.txt) |
| 3 | `cargo test --workspace` | 0 | **62 passed / 0 failed / 0 ignored** | [log](T1-01-assets/second-audit-fix/logs/cargo-test-workspace.log.txt) |
| 4 | `npm run check` | 0 | svelte-check 0 errors / 0 warnings | [log](T1-01-assets/second-audit-fix/logs/npm-check.log.txt) |
| 5 | `npm run build` | 0 | vite 8.3.8 构建成功 | [log](T1-01-assets/second-audit-fix/logs/npm-build.log.txt) |
| 6 | `npm run tauri build -- --no-bundle` | 0 | Release 构建成功，3m49s | [log](T1-01-assets/second-audit-fix/logs/tauri-build.log.txt) |
| 7 | `scripts/verify/verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1 INFO=15 OVERALL=PASS | [log](T1-01-assets/second-audit-fix/logs/verify-release-portable.log.txt) |
| 8 | `scripts/verify/verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9 OVERALL=PASS | [log](T1-01-assets/second-audit-fix/logs/verify-release-faults.log.txt) |
| 9 | `node scripts/verify/inspect-release-ui.mjs`（真实 Release WebView2 + CDP） | 0 | 21/21 断言 PASS；CSP 违规 0；截图；CloseMainWindow 正常关闭 | [log](T1-01-assets/second-audit-fix/logs/inspect-release-ui.log.txt) |

### 5.1 专项测试逐项结果

| 测试 | 数量 | 命令 | 结果 | 日志 |
|---|---|---|---|---|
| R2-01 确定性真实双进程（等待锁 + 活动 WAL） | 3 | `cargo test -p workmanager-core --lib r2_01 -- --nocapture --test-threads=1` | 3 passed / 0 failed | [log](T1-01-assets/second-audit-fix/logs/cargo-test-r2-01-waiter-active-wal.log.txt) |
| R2-02 正式目录 Junction 保护 | 5 | `cargo test -p workmanager-core --test formal_root_protection -- --nocapture --test-threads=1` | 5 passed / 0 failed | [log](T1-01-assets/second-audit-fix/logs/cargo-test-r2-02-formal-root-protection.log.txt) |
| R2-03 真实卷身份（D 盘交叉核验 + SUBST 卷别名） | 3 | `cargo test -p workmanager-core --lib volume -- --nocapture --test-threads=1` | 3 passed / 0 failed | [log](T1-01-assets/second-audit-fix/logs/cargo-test-r2-03-volume-identity.log.txt) |
| 零字节数据库/孤儿 sidecar 保护回归 | 6 | `cargo test -p workmanager-core --test zero_byte_database -- --nocapture --test-threads=1` | 6 passed / 0 failed | [log](T1-01-assets/second-audit-fix/logs/cargo-test-zero-byte-database.log.txt) |
| 双进程首次初始化/锁恢复回归 | 3 | `cargo test -p workmanager-core --test init_concurrency -- --nocapture --test-threads=1` | 3 passed / 0 failed | [log](T1-01-assets/second-audit-fix/logs/cargo-test-init-concurrency.log.txt) |
| D 盘真实路径/Junction 拒绝回归 | 4 | `cargo test -p workmanager-core --test windows_real_paths -- --nocapture --test-threads=1` | 4 passed / 0 failed | [log](T1-01-assets/second-audit-fix/logs/cargo-test-windows-real-paths.log.txt) |

### 5.2 重点回归项对照

| 要求项 | 本轮回执 |
|---|---|
| 零字节数据库保护 | `tests/zero_byte_database.rs` 6 项 PASS，无删改 |
| 0 字节主库 + WAL 保护 | 同上（真实子进程崩溃产生 WAL 后截断主库，主库/WAL SHA-256 前后一致） |
| 孤儿 WAL/journal 保护 | 同上；R2-01 修复后顺序仍为“主库确实缺失才检查 sidecar” |
| 双进程首次初始化 | `tests/init_concurrency.rs` 3 项 PASS |
| 等待锁进程遇到活动 WAL | 新增确定性真实双进程测试 PASS（R2-01） |
| Debug/Test Junction 指向受保护目录 | 新增 `tests/formal_root_protection.rs` 5 项 PASS（resolve/ensure_directories/Database::initialize 三阶段拒绝） |
| D 盘真实卷身份 | `tests/windows_real_paths.rs` 4 项 PASS + 卷 GUID/NT 设备卷交叉核验 PASS |
| Release 忽略测试环境变量 | Release 便携验证 case2 PASS；`tests/portable_paths.rs` 单测覆盖 |
| SQLite 重启持久化 | Release 便携验证 persistence PASS |
| 正常关闭 WAL/SHM 清理 | Release 便携验证 graceful close PASS；UI 检查关闭后数据库目录仅 `.work.db.init.lock` 与 `work.db` |
| CSP 与真实 IPC | 真实 Release WebView2 CDP 21/21 断言 PASS，CSP 违规 0 |

---

## 6. Release 构建与运行时验证

- 产物：`target/release/workmanager.exe`
- 大小：**9,980,928 字节**（上一轮 9,962,496 字节）
- SHA-256：**`849E803D2456B28DF8BABFE201E187FB0FC45B7104A5E2CD2FD34B1D4366019E`**（上一轮 `C863CAC5…67F4`）
- 构建：`npm run tauri build -- --no-bundle`，退出码 0，`Finished release profile [optimized] target(s) in 3m 49s`
- 便携验证：TOTAL=106 / PASS=90 / FAIL=0 / WARN=1 / INFO=15（WARN 为验证前已存在的 `%LOCALAPPDATA%\EBWebView`，本次前后时间戳与条目未变化）
- 异常注入：TOTAL=73 / PASS=64 / FAIL=0 / WARN=0 / INFO=9（含 0 字节数据库、损坏数据库、路径被文件阻塞、work.db 为目录、ACL 拒绝写入）
- UI/IPC/CSP：21/21 断言通过；`noCspViolations=true`；真实 IPC `get_database_health` 返回 schema=1、WAL、FULL、5000、foreignKeys=true、migration 1 条、便携路径正确
- 正常关闭：CloseMainWindow 正常退出，关闭后 `-wal`/`-shm` 已清理
- 证据：[CDP 断言 JSON](T1-01-assets/second-audit-fix/release-ui-ipc-evidence.json)、[真实窗口截图](T1-01-assets/second-audit-fix/release-window-r2.png)、[主窗口截图](T1-01-assets/second-audit-fix/release-main-window-r2.png)

---

## 7. 未关闭风险与限制（如实记录）

1. **【阻塞】TOCTOU 未关闭**：路径校验与后续目录创建/写探针/初始化锁/SQLite 打开之间仍存在竞争窗口；未宣称不会写入 C 盘。完整方案与测试计划见 3.4，等待用户决策。
2. **映射网络盘未实机验证**：本机无网络共享；仅卷类型纯函数测试与 fail-closed 设计。
3. **D 盘路径下的跨卷目录挂载点未实机验证**：需要管理员权限与额外卷；未在用户机器上修改卷挂载配置。
4. **SUBST D:→C: 场景无法在本机构造**：已用 SUBST Q:→C: 实机验证等价 DOS 设备别名机制，并明确标注差异。
5. **非 Windows 降级实现未交叉编译验证**：目标平台 Windows 10。
6. **devCsp 未在 `tauri dev` 下端到端验证**：生产 Release CSP 已通过 CDP 验证（0 违规）。
7. **应用级单实例保护未实现**（T6-07）：首次初始化已由 LockFileEx 串行化；R2-01 修复后等待锁进程不会被活动 WAL 误判。
8. **`%LOCALAPPDATA%\EBWebView` 为验证前已存在的共享目录**（2024-07-15 创建，本次前后未变化）；来源需发布阶段审计确认；WorkManager 专属 C 盘目录不存在。
9. **启动完整性检查性能**：数据库规模增大后启动耗时会增长，后续性能任务评估。
10. **物理拔盘、正式 `D:\WorkManager` 实跑、Process Monitor 文件审计**仍属阶段 6 发布验收。
11. 备份恢复与业务功能均未实现，T1-01 只交付基础设施。

---

## 8. 证据索引

- 机器可读证据：[T1-01-AUDIT-FIX-evidence.json](T1-01-AUDIT-FIX-evidence.json)
- 本轮修复报告：本文件
- 第二轮独立审计报告（历史，未修改）：[T1-01-SECOND-AUDIT-REPORT.md](T1-01-SECOND-AUDIT-REPORT.md)
- 第一轮修复报告（历史，未修改）：[T1-01-AUDIT-FIX-REPORT.md](T1-01-AUDIT-FIX-REPORT.md)
- 返工前历史证据（已标记 historical）：[T1-01-evidence.json](T1-01-evidence.json)
- 脱敏原始日志目录：[T1-01-assets/second-audit-fix/logs/](T1-01-assets/second-audit-fix/logs/)
- CDP 断言与截图：[T1-01-assets/second-audit-fix/](T1-01-assets/second-audit-fix/)

---

## 9. 状态声明

本次返工完成了 R2-01、R2-02、R2-04 的代码修复、专项测试、完整回归、Release 运行时复验和 GitHub 文档/证据同步；R2-03 完成了真实物理卷身份校验与实机验证，但**TOCTOU 残余风险仍未关闭**。

因此：

- T1-01 状态保持 **返工中 / R2-03 阻塞**，**不改为待审计、不标记验收完成**；
- PR #1 保持 Open、不合并；main 不修改；T1-02 不得开始；
- 需要独立审计重新核对本报告、diff、日志与剩余风险，并由用户决定 TOCTOU 延期方案后才能决定下一步；
- 开发代理自测与自动化验证不构成独立审计通过，也不构成用户验收。
