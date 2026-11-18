# T1-01 测试报告：正式工程骨架、便携路径接入与 SQLite 基础设施

> **历史报告说明：** 本报告记录返工前基线 `682ba04` 的自测证据。独立审计随后发现问题并进入返工，修复后的权威结论、专项测试与证据见 [T1-01-AUDIT-FIX-REPORT.md](T1-01-AUDIT-FIX-REPORT.md)。本报告保留为历史记录，未删除。

**任务 ID：** T1-01 \
**报告日期：** 2026-11-17 \
**任务状态：** 待审计（代码与测试完成、测试通过；**尚未通过独立审计，未标记验收完成**） \
**代码提交：** `682ba0438ada466e1cd33879ee2513484d986483`（分支 `task/T1-01-sqlite-foundation`） \
**Pull Request：** [#1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（指向 main；待独立审计，未合并） \
**测试执行者：** DeepSeek Agent（Lead）+ 独立验证子代理（同机独立执行）；两者都不是用户验收或独立审计 \
**独立审计：** 待 ChatGPT 审计（对照 PR、完整 diff、本报告和证据） \
**任务范围声明：** 本任务只完成基础设施（工程骨架、便携路径、SQLite 底座、最小健康检查）。项目/工作事项 CRUD、每日计划、复盘、报表、附件、自动备份、密码/锁屏/SQLCipher/DPAPI 均**未实现**。

---

## 1. 测试环境

| 项目 | 实测值 |
|---|---|
| 操作系统 | Windows 10 家庭中文版 19045（10.0.19045） |
| CPU 架构 | x86_64 |
| Node.js / npm | v22.20.0 / 10.9.3 |
| Rust / Cargo | rustc 1.100.0 (0ef1bc386 2026-11-09) / cargo 1.100.0 |
| Rust 工具链 | stable-x86_64-pc-windows-msvc（CARGO_HOME/RUSTUP_HOME 位于 D 盘） |
| MSVC Build Tools | Visual Studio Build Tools 2022 17.14.37906.3（MSVC 14.44.35207） |
| Windows SDK | 10.0.19041.0（位于本机 D 盘 WindowsKits） |
| WebView2 Runtime | 131.0.2903.86 |
| Git | 2.52.0.windows.1 |
| Python（只读 SQLite 验证） | 3.14.5，sqlite3 3.50.4 |
| 仓库/测试盘符 | 仓库位于 `D:\工作事项看板`；测试数据位于 `D:\WorkManager-test-data`；正式目录 `D:\WorkManager` 不存在且从未被写入 |

> 说明：开发文档记录的版本与本机实测基本一致；本机 Rust/Cargo 未加入当前进程 PATH（
> 用户注册表中已配置 CARGO_HOME/RUSTUP_HOME），执行时显式注入环境变量后再运行，
> 已在报告中保留实际命令语义。

---

## 2. 交付物与依赖版本

### 2.1 工程结构

```text
WorkManager/
├── src/                         # Svelte 5 + TypeScript 前端（不直连 SQLite）
├── src-tauri/                   # Tauri 2 适配层（命令、窗口、WebView2 绝对目录、启动错误）
├── crates/workmanager-core/     # 独立 Rust Core（不依赖 Tauri）：便携路径 + SQLite 基础设施
│   ├── migrations/0001_initial_foundation.sql
│   └── tests/                   # 25 项集成测试
├── scripts/generate-icons.py    # 自绘占位图标（无第三方素材）
├── scripts/verify/              # Release 运行时验证（便携/持久化/异常/UI IPC）
└── docs/                        # 需求/架构/决策/计划/状态/测试报告
```

### 2.2 实际依赖版本（`Cargo.lock` / `package-lock.json` 锁定）

| 依赖 | 实际版本 | 用途 |
|---|---|---|
| tauri | 2.12.6 | 桌面容器 |
| tauri-build | 2.7.5 | 构建期配置/资源 |
| rusqlite | 0.43.0（bundled） | 普通 SQLite 访问 |
| libsqlite3-sys | 0.40.0（bundled SQLite **3.54.1**） | 随应用编译 SQLite |
| serde | 1.0.229 | IPC DTO 序列化 |
| thiserror | 2.0.21 | 结构化错误 |
| chrono | 0.4.45 | UTC 时间戳 |
| svelte | 5.57.3 | 前端框架（runes） |
| vite | 8.3.8 | 前端构建 |
| typescript | 6.0.3 | 类型检查 |
| svelte-check | 4.7.8 | 前端静态检查 |
| @sveltejs/vite-plugin-svelte | 7.3.1 | Svelte/Vite 集成 |
| @tauri-apps/cli | 2.12.5 | Tauri CLI |
| @tauri-apps/api | 2.12.5 | 前端 IPC API |

**未引入**：SvelteKit、SQLCipher、DPAPI、密钥管理、ORM/migration crate、任何遥测/云同步/远程服务依赖。

---

## 3. 数据库设计与实际配置

### 3.1 数据库路径与 schema

- 数据库文件：`<EXE 所在目录>/data/database/work.db`
- schema 版本：`PRAGMA user_version = 1`；同时维护 `schema_migrations` 审计表
- migration 文件：`crates/workmanager-core/migrations/0001_initial_foundation.sql`
- 表：仅 `schema_migrations`、`settings`（T1-01 只建底座，不提前创建项目/工作事项等业务表；集成测试断言不存在 `projects`/`work_items`/`daily_plans`/`daily_reviews`）
- 未写入任何未经用户确认的默认业务设置

### 3.2 PRAGMA 实际值与选择理由

| PRAGMA | 实际值 | 理由 |
|---|---|---|
| `journal_mode` | `wal` | 提升读写并发与崩溃恢复能力；WAL/SHM 位于 D 盘便携目录 |
| `foreign_keys` | `1`（ON） | 外键约束必须真实生效，启动与命令中都会验证 |
| `synchronous` | `2`（FULL） | 单机便携、写入频率不高，优先断电/崩溃后的数据可靠性 |
| `busy_timeout` | `5000` ms | 有界等待锁，避免无限阻塞，同时覆盖短暂并发写 |
| `temp_store` | `2`（MEMORY） | 减少临时数据落盘（不作为加密保证） |
| `integrity_check` | 启动时执行，必须返回 `ok` | 损坏数据库必须 fail-closed |
| `foreign_key_check` | 启动时执行，必须无违规 | 防止在损坏/违规数据上继续迁移或写入 |

### 3.3 初始化、migration 与失败保护

1. 启动解析便携路径 → 创建并验证目录可写（含 WebView2 目录）→ 才创建窗口。
2. 数据库不存在时：在 `data/database/` 下的临时数据库文件完成 migration、完整性检查、外键检查，并切回 `DELETE` 日志模式把 WAL 合并回主文件；随后用 **NTFS 硬链接**把完整数据库原子安装为 `work.db`（目标已存在时失败而不是覆盖），再删除临时文件名。
3. 数据库已存在时：`READ_WRITE` 打开 → 配置并验证 PRAGMA → `integrity_check` + `foreign_key_check` → 读取 `user_version`：
   - 高于应用支持版本 → `schema-version-too-new`，不降级、不覆盖；
   - 低于最新版本 → 逐个 migration 在独立 `IMMEDIATE` 事务中执行（SQL → `schema_migrations` 记录 → `user_version`，全部成功后提交；失败显式回滚），迁移后再次完整性与外键检查。
4. 任何失败都保留原数据库文件；不会自动删除、重建或用空库覆盖。错误按 `database-open-failed`、`database-not-a-database`、`database-corrupt`、`database-integrity-check-failed`、`database-foreign-key-violations`、`schema-version-too-new`、`migration-failed`、`disk-full`、`database-read-only`、`database-path-not-file` 等稳定错误码分类。
5. 正常退出（关闭窗口）时显式关闭 SQLite 连接，触发 WAL checkpoint 并清理 `-wal`/`-shm`；强制结束进程时依靠 SQLite WAL 恢复能力与下次启动完整性检查。

### 3.4 前端数据库边界

- 前端只调用一个受限命令 `get_database_health`，返回数据库状态、schema 版本、便携路径与 migration 记录（仅诊断信息，不含工作内容）。
- 没有 `execute_sql` / `query_sql` / 任意文件读写 / 任意命令执行 IPC；前端依赖中无 SQLite/数据库插件。

---

## 4. 便携路径设计（实测行为）

| 场景 | 期望 | 实测结果 |
|---|---|---|
| Release 数据根目录 | 跟随 EXE：`<exe目录>/data` | PASS：数据库创建于 `...\WorkManager.exe` 同级 `data\database\work.db` |
| WebView2 用户数据 | Rust 侧绝对路径 `<data>/cache/webview2` | PASS：启动后 `...\data\cache\webview2\EBWebView` 真实创建，窗口加载 |
| Release 忽略测试环境变量 | 设置 `WORKMANAGER_TEST_PORTABLE_ROOT` 后仍用 EXE 同级目录 | PASS：诱饵目录仍为空，数据库位于 EXE 同级 |
| Debug/Test | 必须显式指定 D 盘隔离根目录，否则 fail-closed | 单元/集成测试 PASS |
| 盘符限制 | 只允许 D 盘本地路径 | 单元测试 PASS（C/Q/UNC/相对路径被拒绝） |
| 无静默回退 | 不得写 AppData/LocalAppData/Temp/C 盘 | PASS：`%LOCALAPPDATA%\com.workmanager.portable`、`%APPDATA%\com.workmanager.portable` 前后均不存在 |
| 路径被文件阻塞 / 不可写 | 明确错误，不覆盖、不回退 | PASS：`data` 被文件阻塞、`work.db` 为目录、数据库目录 ACL 拒绝写入均启动失败并保留原文件 |
| 正式目录保护 | 测试不得污染 `D:\WorkManager` | PASS：测试全部在 `D:\WorkManager-test-data`；`D:\WorkManager` 不存在；Debug 模式显式拒绝正式目录 |

---

## 5. 测试命令与结果总表

| # | 命令 | 退出码 | 结果摘要 |
|---|---|---|---|
| 1 | `cargo fmt --all -- --check` | 0 | 无差异 |
| 2 | `cargo check --workspace --all-targets` | 0 | 编译通过（release/check 均无错误） |
| 3 | `cargo test --workspace` | 0 | **33 passed / 0 failed / 0 ignored**（8 单元 + 25 集成，见 §6） |
| 4 | `npm run check` | 0 | svelte-check: **0 errors, 0 warnings** |
| 5 | `npm run build` | 0 | vite 8.3.8 构建成功：`dist/index.html` 0.39 kB、CSS 11.65 kB、JS 53.71 kB |
| 6 | `npm run tauri build -- --no-bundle` | 0 | Release 构建成功，产物见 §5.1（首次全量 6m06s，最终增量 2m53s） |
| 7 | `scripts/verify/verify-release-portable.ps1` | 0 | **TOTAL=106 PASS=90 FAIL=0 WARN=1 INFO=15**，OVERALL=PASS |
| 8 | `scripts/verify/verify-release-faults.ps1` | 0 | **TOTAL=59 PASS=51 FAIL=0 WARN=0 INFO=8**，OVERALL=PASS |
| 9 | `node scripts/verify/inspect-release-ui.mjs`（CDP） | 0 | **19/19 断言通过**：真实 WebView2 页面渲染 + 真实 `get_database_health` IPC 返回 + 截图 |
| 10 | 正常关闭后 WAL/SHM 检查（人工） | — | 关闭后仅剩 `work.db`（`-wal`/`-shm` 已清理）；退出码 0 |

### 5.1 Release 构建产物

- 路径：`target/release/workmanager.exe`（Tauri `--no-bundle` 产物按 Cargo 包名小写；正式便携包中 `WorkManager.exe` 的命名与组装属于 T6-01）
- 大小：**9,899,520 字节**
- SHA-256：**`B5CBEC7DEAE067247ECCBA8EA10BED86AF814ED4A324AC482B16651C059E43A0`**
- 版本资源：ProductName `WorkManager`、FileVersion/ProductVersion `0.1.0`
- 构建命令实际输出：`Finished release profile [optimized] target(s) in 2m 53s` / `Built application at: ...\target\release\workmanager.exe`

> 说明：构建前曾出现 `vite build` 失败（Vite 8 不再内置 esbuild，配置中的
> `build.minify: 'esbuild'` 无法加载）。已改为 Vite 8 默认的 `minify: 'oxc'` 后重新构建通过，
> 未引入新依赖；失败与修复过程如实保留（见 §8.1）。

---

## 6. Rust 测试明细（33 项，全部通过）

| 测试文件 | 数量 | 覆盖内容 |
|---|---|---|
| `src/portable_paths.rs`（单元） | 8 | Release EXE 跟随、Release 忽略测试根目录、Debug 必须显式根目录、Debug 拒绝正式目录、非 D 盘/UNC/相对路径拒绝、`..` 拒绝、空环境变量过滤 |
| `tests/database_lifecycle.rs` | 5 | 空库初始化到最新 schema、PRAGMA 实际值（WAL/FULL/5000/MEMORY/foreign_keys）、重复启动幂等且不重跑 migration、重启后虚构 canary 数据持久化、正常关闭 WAL checkpoint 后主文件独立可读、健康检查只读 |
| `tests/migration_rollback.rs` | 5 | 中途失败 migration 回滚且 `user_version` 停在已提交版本、首个 migration 失败保持空 schema/版本 0、非法 migration 集拒绝、内置 migration 不含事务控制语句、初始 schema 不提前创建业务表 |
| `tests/foreign_keys.rs` | 2 | 生产连接 `foreign_keys=ON` 真实拒绝违规插入、`ON DELETE CASCADE` 生效；外键检查能发现违规数据并在启动时 fail-closed |
| `tests/database_fail_closed.rs` | 8 | 垃圾文件不被覆盖、损坏页数据库不被覆盖、schema 版本过高保留数据、`data` 被文件阻塞、`database` 被文件阻塞、`work.db` 为目录、WebView2 目录被文件阻塞、**D 盘目录 ACL 拒绝写入后 fail-closed 且恢复 ACL 后可用** |
| `tests/portable_paths.rs` | 5 | Release 目录布局与写探针清理、两套 Debug 根目录数据隔离、Release 忽略测试根目录参数、测试根目录必须在 D 盘且不在正式目录、Debug 拒绝正式目录 |

关键断言举例：

- `foreign_keys` 真实生效：`INSERT INTO fk_child(parent_id=999)` 被 SQLite 拒绝，子表无残留；删除父行后子行级联删除。
- migration 回滚：自定义版本 2 成功、版本 3 失败后 `user_version=2`，失败 migration 中已执行的 `CREATE TABLE` 被回滚，`schema_migrations` 只记录 2 条。
- 损坏保护：向合法数据库中间页写入 `0xFF` 后，重新初始化返回数据库异常错误码，原文件 SHA-256 前后一致。
- ACL 不确定可写：`icacls /deny <user>:(W)` 后目录可写探针失败 → `directory-not-writable`；恢复 ACL 后重新可写。
- 无污染：所有测试数据库位于 `D:\WorkManager-test-data` 下唯一子目录，测试结束由 `Drop` 只清理自身创建目录；正式目录 `D:\WorkManager` 从未创建或写入。

---

## 7. Release 运行时验证明细

### 7.1 成功路径（脚本 106 项：90 PASS / 0 FAIL / 1 WARN / 15 INFO）

用例均把 `workmanager.exe` 复制为 `WorkManager.exe` 后从 D 盘隔离目录运行：

- **首次启动**：窗口标题 `WorkManager`（约 354 ms 出现）；创建 `data/{database,config,logs,cache/webview2,temp,backups}`；`webview2\EBWebView` profile 真实创建；`work.db` 20,480 字节；`user_version=1`；`integrity_check=ok`；`journal_mode=wal`；`schema_migrations` 1 条；正常关闭 `exit_code=0`。
- **关闭后一致性**：`-wal` 为 0 字节且无未提交数据；关闭后 WAL/SHM 被清理（显式关闭连接生效）；只读打开 `integrity_check=ok`。
- **重启持久化**：写入虚构 canary（`{"value":"release-verify-canary-..."}`）→ 重启窗口正常 → 重启后 canary 仍在、`user_version=1`、`schema_migrations` 仍为 1 条（未重复初始化）、`integrity_check=ok`、`exit_code=0`。
- **Release 忽略测试环境变量**：设置 `WORKMANAGER_TEST_PORTABLE_ROOT=<诱饵>` 启动后，数据库仍在 EXE 同级 `data\database\work.db`，诱饵目录保持为空。
- **C 盘边界抽查**：`%LOCALAPPDATA%\com.workmanager.portable`、`%APPDATA%\com.workmanager.portable` 前后均不存在（PASS）。唯一 WARN 见 §8.2。
- **清理**：无遗留应用进程；用例沙箱目录已清理，证据保存在输出目录。

### 7.2 异常路径（脚本 59 项：51 PASS / 0 FAIL / 8 INFO）

| 故障注入 | 实际行为 | 关键证据 |
|---|---|---|
| `work.db` 替换为非 SQLite 垃圾内容（1024 B） | 启动失败，原生对话框标题「WorkManager 启动失败」，退出码 1；原文件 SHA-256 前后一致；无初始化临时文件；未创建空库 | `database-open-failed`/`database-not-a-database` 类错误信息；文件 SHA-256 一致 |
| `data` 路径被同名文件阻塞 | 启动失败，退出码 1，对话框「WorkManager 启动失败」；阻塞文件 SHA-256 前后一致；无 init 临时文件 | 错误消息「便携数据目录不可用，已停止启动」 |
| `work.db` 为同名目录 | 启动失败，退出码 1；目录仍存在、目录内无任何写入；无 init 临时文件 | 错误类别 `database-path-not-file` |
| 数据库目录 ACL 拒绝当前用户写入（`icacls /deny`） | 启动失败，退出码 1；ACL 在 finally 中恢复并验证可写；未创建 `work.db`；无 init 临时文件 | `directory-not-writable`（拒绝访问 os error 5） |

每个失败用例都通过 UI Automation 捕获对话框标题/文本并保留截图与 `stderr` fatal 日志（例如
「数据库初始化失败，已停止启动，原始数据库未被删除或覆盖。」）。

### 7.3 真实窗口 UI 与 IPC（CDP，19/19 断言通过）

通过 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9333` 连接真实 Release
WebView2 页面，读取渲染后 DOM 并直接调用前端使用的 Tauri 内部 `invoke('get_database_health')`：

- DOM：标题 `WorkManager · 数据库健康检查`、版本 `版本 0.1.0`、绿色「正常（ok）」徽标、完整性「通过（ok）」、「正式便携模式」、migration 1 条、底部 T1-01 范围说明与「普通 SQLite 文件，未加密」提示均渲染成功。
- IPC 返回：`appName=WorkManager`、`appVersion=0.1.0`、`runtimeMode=release`、`schemaVersion=1`、`integrityCheck=ok`、`journalMode=wal`、`foreignKeys=true`、`synchronous=2`、`busyTimeoutMs=5000`、migration 记录 1 条、`databasePath=...\app\data\database\work.db`、`webview2DataDir=...\app\data\cache\webview2`。
- 截图：[T1-01-assets/release-window.png](T1-01-assets/release-window.png)（1100×780）；原始断言 JSON：[T1-01-assets/release-ui-ipc-evidence.json](T1-01-assets/release-ui-ipc-evidence.json)。

### 7.4 正常关闭后的 WAL/SHM 行为（本次修复点）

初版验证发现正常关闭后残留 32,768 B 的 `work.db-shm`（`-wal` 为 0 字节、无未提交数据、重启一致性正常）。
已增加 Tauri `RunEvent::Exit` 处理：退出时显式取出并关闭 SQLite 连接，触发 WAL checkpoint 并删除
`-wal`/`-shm`。修复后实测：关闭后数据库目录只剩 `work.db`；专项脚本中 `shm_cleared_after_close`
与 `shm_after_restart` 均从 WARN 变为 **PASS**。强制结束进程（任务管理器/断电）时不会执行该逻辑，
由 SQLite WAL 恢复与启动完整性检查兜底，报告中保留该边界说明。

---

## 8. 失败记录、已知 WARN 与限制

### 8.1 过程中真实出现并已修复的失败

1. **Vite 8 构建失败**：`vite.config.ts` 中 `build.minify: 'esbuild'` 在 Vite 8.3.8 下报
   `Cannot find package 'esbuild'`（Vite 8 不再内置 esbuild），`npm run build` 退出码 1。
   修复：改为 Vite 8 默认 `minify: 'oxc'`，未新增依赖；随后 `npm run build` 与 Tauri Release 构建通过。
2. **独立验证首轮将 `-shm` 存在误判为 FAIL**（退出码 1）：复核发现 `-wal` 为 0 字节、无未提交数据，
   随即将检查语义修正为「无未提交数据残留」，并进一步在应用侧实现正常退出时显式关闭连接；
   修复后重跑得到权威 PASS 结果。两次运行与判断差异均保留可复核。
3. **Rust 编译期问题**（开发中）：rusqlite 错误码命名、migration 事务需要 `&mut Connection`、
   `Database` 需要 `Debug` 等编译错误，均已修正并通过全部测试（见最终 commit 与测试输出）。

### 8.2 已知 WARN（1 项）

- `%LOCALAPPDATA%\EBWebView` 在本机验证开始前已存在（创建于 2024-07-15，本次运行前后时间戳与
  25 个顶层条目均未变化），不是本次运行创建；WorkManager 专属 C 盘目录不存在。该共享路径的
  历史来源需在发布阶段审计确认（可能来自本机其他 WebView2 应用/早期原型）。
- 另注：本机存在 T0 阶段原型的遗留目录 `%LOCALAPPDATA%\com.workmanager.smoke`（时间戳早于本任务），
  与 T1-01 无关；正式 `com.workmanager.portable` 目录不存在。

### 8.3 本任务未覆盖（如实列明）

- 物理拔除 D 盘、正式 `D:\WorkManager` 路径实跑、管理员级 Process Monitor 文件写入审计（规划在 T6-03/T6-05）。
- 多实例并发与单实例保护（规划在 T6-07）；当前首次初始化用硬链接保证不覆盖已有数据库，但两个进程
  同时首次启动仍存在竞争窗口。
- 大数据量下启动 `integrity_check` 的性能（后续性能任务评估 `quick_check` 或按需检查）。
- Debug 构建 GUI 端到端运行（Debug 路径解析与 fail-closed 已由单元/集成测试覆盖；Release 已端到端验证）。
- Windows Toast、托盘、开机启动、断网验收（T6-04/T6-07）。
- 备份/恢复（OPEN-001/002/003 待用户确认；未实现、未宣称）。
- 任何业务功能（项目/工作事项/每日计划/复盘/报表/附件/清理）。
- 前端自动化单测（未为 T1-01 引入 vitest 依赖；前端逻辑由 `npm run check` 与 CDP 渲染验证覆盖）。

---

## 9. 审计建议检查点

1. 完整 diff 中是否只包含 T1-01 范围；是否存在任意 SQL/任意文件/任意命令 IPC（应只有 `get_database_health`）。
2. `crates/workmanager-core/src/portable_paths.rs`：Release 是否忽略测试环境变量、是否只允许 D 盘、
   是否存在任何 AppData/Temp/C 盘回退分支、失败是否 fail-closed。
3. `database/mod.rs`、`migrations.rs`：migration 是否逐版本事务、失败是否回滚、`user_version` 是否可能错误前进、
   首次初始化是否可能覆盖已有数据库。
4. `src-tauri/src/lib.rs`：窗口是否在便携路径与 WebView2 目录验证之后创建、WebView2 是否使用绝对
   `data_directory`、启动失败是否显示原生错误而不启动窗口。
5. `src/`：前端是否只调用受限命令、是否在 localStorage/IndexedDB 保存业务状态、界面是否如实声明
   未实现业务功能与普通 SQLite 未加密。
6. 复跑 §5 命令与 `scripts/verify` 脚本，核对退出码、EXE SHA-256 与证据 JSON。

---

## 10. 证据位置

- 仓库内（可随 PR 审阅）：
  - 本报告
  - [UI 截图](T1-01-assets/release-window.png)、[CDP 断言 JSON](T1-01-assets/release-ui-ipc-evidence.json)
- 本机证据目录（D 盘，非仓库内容；含完整 summary/report/截图/对话框 JSON/stderr 日志）：
  - 便携/持久化：`D:\WorkManager-test-data\release-verify-20261117-185117\`
  - 异常路径：`D:\WorkManager-test-data\release-verify-20261117-185125\`
  - UI/IPC CDP：`D:\WorkManager-test-data\final-ui-check-20261117-185107\evidence\`
  - 正常退出 WAL/SHM：`D:\WorkManager-test-data\final-sidecar-check-20261117-185058\`
  - 独立验证子代理两轮运行：`D:\WorkManager-test-data\release-verify-20261117-183813\`、
    `D:\WorkManager-test-data\release-verify-faults-20261117-183826\`（首轮 WARN 语义修正前/后均保留）

---

## 11. 结论

T1-01 范围内代码、静态检查、自动化测试、Release 构建与运行时专项验证均已执行且通过：
33 项 Rust 测试全通过；前端 `svelte-check` 0 error/0 warning；Release EXE 可启动、数据目录跟随 EXE、
WebView2 使用 D 盘绝对数据目录、数据库初始化/持久化/损坏保护/回滚/外键/不可写 fail-closed 均通过实测；
未发现本次运行向 C 盘 AppData 写入 WorkManager 业务数据。

**但本报告是开发代理自测证据，不构成独立审计或用户验收。** 任务保持「待审计」状态，
由独立审计核对后决定是否标记验收完成并进入 T1-02。T1-01 只完成基础设施，不代表任何业务功能已完成。
