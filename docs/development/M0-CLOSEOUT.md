# M0 收口包：Git 基线、状态同步、审计材料与整合方案

**生成日期：** 2026-11-25（Asia/Shanghai）；**状态更新：** 2026-11-27（Asia/Shanghai）\
**对照 main HEAD：** `9171fe3`（PR #9 合并后的最新 main）\
**适用范围：** M0 现有代码收口。不包含任何产品代码修改。

> 后续 AI 执行本文件中的任务时，遵循项目统一原则：不要把简单的个人软件开发任务复杂化；优先复用现有实现，只做当前明确需求的最小必要工作，不增加无用代码或无关流程。必要的数据完整性和安全要求不得省略。

> **本文件不是独立审计报告，也不是用户验收记录。** 它只整理事实、证据位置和一项开发代理只读核验的结论。T1-03、T1-04 的独立审计结论必须由独立审计对话出具，本文件不得被引用为“审计通过”。

> **2026-11-27 状态更新：** 用户当日决定豁免 T1-03 独立审计门禁、终止独立审计，并以 `7e317585` 进入用户验收；T1-04 第六轮独立审计通过（用户状态同步）、等待用户验收。**§1～§9 保留 2026-11-25 的历史快照原文**；2026-11-27 的决策、当前状态与新增核验见第 10 节。当前状态以第 10 节、`docs/STATUS.md` 和 `T1-03-USER-ACCEPTANCE.md` 为准；历史门禁结论不得改写成“审计通过”。

---

## 1. Git 基线（本轮 `git fetch origin --prune` 后实测）

### 1.1 分支与 PR 真实状态

| 对象 | 本轮实测值 | 状态 |
|---|---|---|
| `origin/main` | `9171fe3` Merge pull request #9 | 最新主分支 |
| 合并前 main | `018e851` | PR #8 的 base |
| `task/T1-03-quick-create-pending` | `e8205cae22e98afce6480f5a5a0695543a61dee3` | 与任务书历史基线一致 |
| `task/T1-04-multi-project-copies` | `4bd69f1e4c715410490496bc9fbe8e2a60623a0f` | 与任务书历史基线一致 |
| PR #8 | OPEN，head `e8205ca`，base `018e851`，108 文件，+16053 / −103 | `mergeable=CONFLICTING`，`mergeStateStatus=DIRTY` |
| PR #9 | MERGED，2026-11-25T06:05:45Z | 已进入 main |
| PR #7 / #6 / #5 / #4 / #1 | MERGED | 历史 PR，无变化 |
| PR #3 | OPEN，head `a527369`，6 文件，+64 / −24，CONFLICTING | 历史遗留，内容已被 #6、#9 覆盖，见 §1.3 |
| T1-04 的 main PR | 不存在 | 按 M0-04 要求，T1-03 合并后才创建 |

PR #8 的审查记录：`reviewDecision` 为空，`reviewCount = 0`，`reviewCommentCount = 0`。**GitHub 上不存在对 T1-03 的独立审计记录。**

**2026-11-27 更新：** T1-03 最终 HEAD 已前进到 `7e317585ec273898907f31a158561bc8358f8500`；T1-04 HEAD 仍为 `4bd69f1`。PR #8 当前为 131 个文件、+23,131 / −103，仍 `CONFLICTING / DIRTY`。详见第 10 节。

### 1.2 提交关系

| 比较 | 结果 |
|---|---|
| `main` vs T1-03 | main 领先 12；T1-03 领先 25 |
| `main` vs T1-04 | main 领先 12；T1-04 领先 39 |
| T1-03 vs T1-04 | T1-04 领先 14，T1-03 领先 0 |
| `merge-base(main, T1-03)` | `018e851` |
| `merge-base(main, T1-04)` | `018e851` |
| `merge-base(T1-03, T1-04)` | `e8205ca`（= T1-03 的 HEAD） |

**结论：T1-04 直接堆叠在 T1-03 的 HEAD 上，其 39 个提交 = T1-03 的 25 个 + 自身 14 个。** T1-04 自身 14 个提交才是需要迁移的增量。

### 1.3 PR #3 说明

PR #3（`docs/t1-01-merge-status-sync`）自 2026-11-18 起保持 OPEN 且 CONFLICTING。其目的（T1-01 合并后的状态同步）已由后续合并的 PR #6 及 PR #9 完成。**本轮不关闭、不合并、不删除该 PR**，仅记录其真实状态。

### 1.4 工作区状态

```
?? scripts/verify/__pycache__/          （7 个 .pyc，T1-04 验证脚本的 Python 缓存）
```

- 本地 `main` 落后 `origin/main` 118 个提交（`0 118`），未做本地合并。
- 无 stash、无额外 worktree、无 tag。
- 上述 7 个 `.pyc` 由 T1-04 的验证运行产生。**按要求未删除他任务遗留文件。**
- `origin/main` 的 `.gitignore` 未覆盖 `__pycache__/`；**T1-04 分支自身的 `.gitignore` 增量已包含 `__pycache__/` 与 `*.pyc`**，故 T1-04 合并后工作区自然恢复干净。本轮**故意不在 main 重复该规则**，以免在 T1-04 整合时制造无意义冲突。

---

## 2. M0-05：开发理念、V1 计划与 Skill 规则入库

**状态：完成（2026-11-25）。**

核验事实：

| 项 | 证据 |
|---|---|
| PR #9 已合并 | `mergedAt = 2026-11-25T06:05:45Z`，merge commit `9171fe3` |
| 开发理念 | `docs/development/DEVELOPMENT_PHILOSOPHY.md` 存在于 main（+187 行） |
| V1 开发计划 | `docs/development/DEVELOPMENT_PLAN.md` V3.x 存在于 main（重写 714 行） |
| 任务模板 | `docs/development/DEVELOPMENT_TASK_TEMPLATE.md` 存在于 main（+69 行） |
| AGENTS 强制 Skill 规则 | `AGENTS.md` §0 存在于 main（+93 行） |
| AI 入口一致 | `.clinerules/`、`.cursor/rules/`、`.github/copilot-instructions.md`、`.windsurf/rules/`、`CLAUDE.md`、`GEMINI.md` 均在 main |

以上均为只读核对 main 文件树与 `git diff 018e851..9171fe3` 的结果，未修改任何内容。

---

## 3. M0-06：T1-01 数据库基础设施只读核验

### 3.1 核验口径（重要限制）

**本轮为纯只读源码与文档核验，未在本机重新执行任何 cargo / npm / Windows Release 测试。** 因此本结论的证据来源是：main 当前源码、main 上的 Migration 文件、main 上的历史测试代码、main 上的历史独立审计报告与用户验收记录。

这一点与 T1-01 第四轮独立审计自身声明的证据边界一致（该报告同样声明“未在该主机重新执行 cargo/npm/Release 测试，测试结果依据已提交的 Windows 10 脱敏日志与机器可读证据复核”）。

**不得**将本节结论表述为“已重新执行全部测试”。

### 3.2 逐项核验结果（main @ `9171fe3`）

| 核验项 | 代码位置 | 结论 |
|---|---|---|
| 数据库初始化 | `database/mod.rs::Database::initialize` | 通过。写边界复验 → 目录存在性 → 只读检查已有文件（`symlink_metadata`）→ 区分“已有库 / 0 字节库 / 首次安装”三条路径 |
| 首次安装原子性 | `mod.rs::create_new_database` / `install_initialized_database` | 通过。临时库完成 migration 与检查后以 `hard_link` 原子安装；目标已存在返回 `ConcurrentInitialization`，绝不覆盖 |
| Migration 执行 | `database/migrations.rs::apply_migrations` | 通过。按 `user_version` 过滤待执行版本，结束后强制校验版本等于 `LATEST_SCHEMA_VERSION` |
| Migration 事务与回滚 | `migrations.rs::apply_one_migration` | 通过。每个 migration 独立 `IMMEDIATE` 事务；SQL、`schema_migrations` 写入、`user_version` 更新同一事务；任一失败显式 `rollback()`，版本不前进 |
| Migration 定义校验 | `migrations.rs::validate_migration_set` | 通过。要求从 1 连续、无空 SQL、定义数量与声明最新版本一致 |
| 版本过高 fail-closed | `mod.rs::open_existing_database` 步骤 4 | 通过。**先**判定版本兼容、**后**才应用 `journal_mode=WAL` 等持久化 PRAGMA，被拒绝的库保持原样 |
| 完整性检查 | `database/connection.rs::run_integrity_check` | 通过。`PRAGMA integrity_check` 唯一结果必须为 `ok`，否则报错 |
| 外键检查 | `connection.rs::run_foreign_key_check` / `count_foreign_key_violations` | 通过。初始化后、打开已有库时、迁移后均执行 |
| 0 字节异常库 | `mod.rs::empty_existing_database_error` | 通过。**从不交给 SQLite 打开**，避免 SQLite 把 0 字节当空库并丢弃残留 WAL；主文件与 WAL 原样保留 |
| 孤儿 WAL / journal | `mod.rs::orphaned_sidecar_error` | 通过。主库缺失但存在非空 `-wal` / `-journal` 时 fail-closed，不当作首次安装 |
| 并发首次初始化 | `database/init_lock.rs` + `open_or_create_after_lock` | 通过。跨进程初始化锁；持锁后**先重检主库**再判断孤儿 sidecar（审计 R2-01 修复） |
| 临时文件清理边界 | `mod.rs::remove_stale_initialization_files` | 通过。仅匹配 `.work.db.init-*` 前缀，且只在持锁时调用 |
| 异常不覆盖原数据 | — | 通过。无任何“失败后删除或重建正式库”的路径；文档与实际代码一致 |

`LATEST_SCHEMA_VERSION = 2`，`MIGRATIONS` 仅含 `0001_initial_foundation.sql`、`0002_projects.sql`。

### 3.3 main 上已有的针对性测试代码

| 测试文件 | 覆盖点（函数名） |
|---|---|
| `database_fail_closed.rs` | `garbage_database_file_is_never_overwritten`、`corrupted_database_image_is_never_overwritten`、`schema_version_newer_than_application_fails_closed_and_keeps_data`、`database_path_that_is_a_directory_fails_closed`、目录被文件占位不落 C 盘 |
| `migration_rollback.rs` | `failed_migration_rolls_back_and_keeps_previous_version`、`failure_in_first_migration_leaves_empty_schema_and_version_zero`、`invalid_migration_set_is_rejected_before_touching_database` |
| `zero_byte_database.rs` | `zero_byte_existing_database_is_not_treated_as_first_install`、含 WAL 残留 fail-closed 且保留 WAL、主库缺失但有 WAL/journal 残留、`-shm` 残留清理 |
| `init_concurrency.rs` | `two_processes_concurrent_first_initialization_is_safe`、活动进程临时库不被删除 |
| `database_precheck_order.rs` | 预检查顺序：版本过高/损坏库在应用持久化 PRAGMA 前不被修改 |
| `database_lifecycle.rs` | 初始化、幂等、重启持久化、WAL checkpoint、健康检查只读 |
| `foreign_keys.rs` | 生产连接真实启用外键、违规可检出 |
| `formal_root_protection.rs` | 正式目录保护、Junction 交换拒绝 |

### 3.4 历史证据

- `docs/testing/reports/T1-01-FOURTH-AUDIT-REPORT.md` — 第四轮独立审计结论：通过（R3-01、R3-02 关闭）。
- `docs/testing/reports/T1-01-USER-ACCEPTANCE.md` — 2026-11-18 用户明确“接受”，T1-01 验收完成。
- `docs/testing/reports/T1-01-AUDIT-FIX-REPORT.md`、`T1-01-R3-FIX-REPORT.md`、`T1-01-SECOND-AUDIT-REPORT.md`、`T1-01-THIRD-AUDIT-REPORT.md` 及 `T1-01-assets/` 下的日志与证据。
- PR #1 已合并（`2026-11-18T02:07:51Z`）。

### 3.5 明确的能力边界

- main 只包含 Migration `0001`、`0002`。`0003`（T1-03）、`0004`（T1-04）**不在 main**，不属于本次 T1-01 核验范围。
- 仍存在的已知缺口：**DEC-029 TOCTOU 未修复**（路径校验与后续写入之间的竞争窗口），按用户决定转 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。不得声称“绝对不会写入 C 盘”。
- 普通 SQLite 未加密（DEC-028），拥有文件访问权限者可读。

### 3.6 M0-06 结论

**只读核验通过：main 当前代码已具备 T1-01 声明并已验收的数据库初始化、migration 执行/事务/失败回滚、完整性检查与异常保护能力，且这些能力与 main 上已有测试代码和历史独立审计/验收记录一致。**

**本次核验未重新运行 Windows 测试，不构成对运行结果的重新验证。** 未发现需要单独提出补充任务的新缺口。

---

## 4. M0-01：T1-03 第四轮独立审计材料包

### 4.1 审计对象

| 项 | 值 |
|---|---|
| 分支 | `task/T1-03-quick-create-pending` |
| 审计对象 HEAD | `e8205cae22e98afce6480f5a5a0695543a61dee3` |
| base | `origin/main` @ `018e851`（PR #8 base 未变） |
| F1/F2 修复提交 | `d82bdd47ae7c3c27fb4383d72ee16a131c89036d` |
| 证据同步提交 | `5ab1f49ac16705126d6c27dcaf091990d38a8b3f` |
| 证据同步后的 3 个提交 | `d7199e3`、`0dda956`、`e8205ca`（文档 + 证据元数据修正，见下） |
| PR | #8 OPEN，未合并 |

从 `5ab1f49` 到 `e8205ca` 的 3 个提交（`d7199e3`、`0dda956`、`e8205ca`）**没有改动任何产品代码（Rust/TypeScript/Svelte/SQL），也没有改动验证脚本逻辑**，但**不只是改散文**：它们同时修正了证据元数据，涉及以下 10 个文件：

```
docs/STATUS.md
docs/development/DEVELOPMENT_PLAN.md
docs/development/tasks/T1-03-Quick-Work-Item-Creation.md
docs/testing/reports/T1-03-REPORT.md
docs/testing/reports/T1-03-assets/README.md
docs/testing/reports/T1-03-assets/SANITIZATION.md
docs/testing/reports/T1-03-assets/evidence/round4/round4-verification-summary.json
docs/testing/reports/T1-03-assets/evidence/round4/t1-03-uat-path-evidence.json
docs/testing/reports/T1-03-assets/test-counts.txt
scripts/verify/README.md
```

其中 `round4-verification-summary.json`、`t1-03-uat-path-evidence.json`、`test-counts.txt` 属于**证据文件**。本文件 §4.3 引用的数字来自 `e8205ca` 这一最新版本。**审计时应直接核对 `5ab1f49..e8205ca` 的 diff，自行判断这些元数据修正是否改变了证据含义**，不要以本文件的转述替代原始 diff。

### 4.2 材料清单（均在 T1-03 分支内）

| 材料 | 位置 |
|---|---|
| 开发与验证报告 | `docs/testing/reports/T1-03-REPORT.md` |
| 第四轮机器可读汇总 | `docs/testing/reports/T1-03-assets/evidence/round4/round4-verification-summary.json` |
| 测试数量与环境 | `docs/testing/reports/T1-03-assets/test-counts.txt` |
| 路径安全 93 项证据 | `docs/testing/reports/T1-03-assets/evidence/round4/t1-03-uat-path-evidence.json` |
| Release E2E 证据（UI/最小窗口/持久化/编排/DB 前后） | `docs/testing/reports/T1-03-assets/evidence/round4/` 下 7 个 JSON |
| 19 张实测截图 | `docs/testing/reports/T1-03-assets/evidence/round4/screenshots/` |
| 脱敏说明与 P2-01 工单材料 | `docs/testing/reports/T1-03-assets/SANITIZATION.md` |
| 证据目录说明 | `docs/testing/reports/T1-03-assets/README.md` |
| 历史（第二/三轮）证据 | `T1-03-assets/evidence/` 根目录（第三轮保留未覆盖） |

### 4.3 第四轮自测数字（开发代理自测，非审计结论）

| 项 | 结果 |
|---|---|
| 路径安全专项 | 93 项，FAIL 0，SKIP 1 |
| — 其中第三轮保留 | 60 项（`round3ChecksPreserved=true`） |
| — 其中第四轮新增 | 31 项 |
| Release 主 UI/IPC | 84 / 84 |
| 最小窗口 860×640 | 12 / 12 |
| 重启持久化 | 17 / 17 |
| 数据库只读探针 | 25 / 25 |
| `cargo test --workspace` | 124 passed / 0 failed（18 个测试二进制） |
| Bridge 测试 | 17 / 17 |
| `npm run check` / `npm run build` | exit 0 / exit 0（svelte-check 0 error 0 warning） |
| 继承回归 | portable 106（FAIL 0，WARN 1）、faults 73（FAIL 0）、T1-02 UI 73+12 |
| DB 事实 | `user_version=3`、`integrity_check=ok`、`journal_mode=wal`、`schema_migrations=1,2,3`、外键违规 0 |

### 4.4 审计时必须接受的证据边界

1. **受控 FaultHook 不等于真实 Windows ACL 拒绝测试。** F2 的“删除失败”由测试钩子在 `beforeLinkDelete` 阶段抛出确定性异常触发；`windowsAclModified=false`、`actualOsAccessDeniedTested=false`。它只证明 fail-closed 分支被正确执行，不能证明真实 ACL `Access Denied` 场景。
2. **Symbolic Link 场景为 SKIP，不算 PASS。** 当前进程无 `SeCreateSymbolicLinkPrivilege`，`mklink /D` 退出码 1。不得把 SKIP 计为通过。
3. 路径安全专项中的真实对象是 Windows Junction（`mklink /J`），不是 Symbolic Link。
4. T1-02 UI E2E 首次执行出现环境性超时，无并发负载下重跑通过；产品代码与 T1-02 脚本未修改。审计需自行判断该记录的充分性。
5. TOCTOU 残余风险未消除（DEC-029 / Issue #2）。

### 4.5 当前阻塞与状态

- **P2-01 未关闭**（见 §6），PR #8 不得合并。
- PR #8 在本轮 fetch 后为 `CONFLICTING / DIRTY`：main 因 PR #9 前进 12 个提交，与本分支文档冲突（见 §7）。
- **不存在** T1-03 独立审计报告文件，PR #8 无任何 review 记录。
- 状态（2026-11-25 快照）：**待第四轮独立审计**。本文件不对此作出结论。
- **2026-11-27 更新：** 用户已终止 T1-03 独立审计并豁免合并门禁，T1-03 以 `7e317585` 进入用户验收；豁免不等于审计通过。详见第 10 节。

---

## 5. M0-02：T1-04 第六轮独立审计材料包

### 5.1 审计对象

| 项 | 值 |
|---|---|
| 分支 | `task/T1-04-multi-project-copies` |
| 审计对象 HEAD | `4bd69f1e4c715410490496bc9fbe8e2a60623a0f` |
| T1-03 堆叠基线 | `e8205ca` |
| R6 补正提交 | `ada85906c033a98b2e942bd5ff37e09ec119e723` |
| 第六轮修复提交 | `aefa0f6`（R6 前置）、`ada8590`（R6 补正） |
| 自身增量提交 | `e8205ca..4bd69f1` 共 14 个 |
| main PR | **不存在**（按 M0-04，T1-03 合并后才创建） |

审计对象是 T1-04 **自身 14 个提交**，不是 T1-03 已交付的 25 个提交；但审计需确认堆叠未篡改 T1-03 已交付内容。

### 5.2 材料清单（均在 T1-04 分支内）

| 材料 | 位置 |
|---|---|
| 开发与验证报告 | `docs/testing/reports/T1-04-REPORT.md` |
| R6 补正机器可读汇总 | `docs/testing/reports/T1-04-assets/evidence/round6-remediation/evidence-summary.json` |
| R6 补正证据说明 | `docs/testing/reports/T1-04-assets/evidence/round6-remediation/README.md` |
| R6-01 标题规范化 Red/Green | `round6-remediation/r6-01-{rust,bridge,cross-contract}-{red,green}*.txt` |
| R6-02 清理悬空 Junction Red/Green | `round6-remediation/r6-02-cleanup-{red,green}.txt`、`r6-02-canary-comparison.txt` |
| 路径安全 58 项 | `round6-remediation/r6-02-path-safety.txt`、`path-safety-evidence.json` |
| Migration 路径 31 项 | `round6-remediation/r6-02-migration-path.txt`、`migration-path-evidence.json` |
| Release migration 失败回滚 | `round6-remediation/migration-failure-output.txt` / `.json` |
| Release UI E2E | `round6-remediation/release-e2e-output.txt`、`release-e2e-evidence/`、`t1-04-ui-orchestration.json` |
| 质量门禁输出 | `round6-remediation/gate-*.txt` |
| Git 证据 | `round6-remediation/git-{baseline,log,diff.patch,diff-stat,diff-check}.txt` |
| 第六轮原始证据（未覆盖） | `round6/` |
| 第五轮证据（未覆盖） | `round5/` |
| 13 张第六轮截图 | `docs/testing/reports/T1-04-assets/screenshots/round6/` |

### 5.3 R6-01 / R6-02 / R6-03 对照

| 项 | 内容 | 证据 |
|---|---|---|
| R6-01 | Rust 与 TypeScript 统一 Unicode `White_Space` 25 字符集合；U+0085 两端删除、U+FEFF 两端保留；内部空白原样保留 | Bridge 48/48；交叉契约 10 场景 1/1；Rust 契约 9 passed |
| R6-02 | Migration 清理对悬空 Junction 的原生句柄识别与 fail-closed（`danglingJunction` / `entryIsJunction`） | 清理用例 8 PASS / 0 FAIL / 1 SKIP；canary 前后 SHA-256 相同 |
| R6-03 | Bridge 注释与任务文档状态同步 | `git-diff.patch`、`git-diff-stat.txt` |

### 5.4 第六轮补正自测数字（开发代理自测，非审计结论）

| 项 | 结果 |
|---|---|
| `cargo test --workspace` | 162 passed / 0 failed / 1 ignored（ignored 为 Node 以 `--ignored` 调用的 Rust 交叉契约执行器） |
| Bridge（Node） | 48 / 48（Red 基线 42 passed / 4 failed） |
| 标题交叉契约 | 1 / 1，10 场景（Red 基线 exit 1） |
| 路径安全专项 | 58 项，FAIL 0，SKIP 1 |
| Migration 路径专项 | 31 项，FAIL 0 |
| Migration 清理故障注入 | 8 PASS / 0 FAIL / 1 SKIP |
| Release UI E2E | 107 / 11 / 13 / 15 / 62，FAIL 0，关闭退出码 0/0/0，CSP 违规 0 |
| Release migration 失败回滚 | Release exit 1、`user_version=3`、`version4Rows=0`、`newTables=0`、`integrity_check=ok` → PASS |
| 质量门禁 | cargo fmt / check / test、npm check / build、git diff --check 全部 exit 0 |
| Release EXE | 10,458,112 字节，SHA-256 `4487b3e1…62e7d1` |

### 5.5 审计时必须接受的证据边界

1. **真实 Symbolic Link 创建被 OS 权限拒绝，记录为 SKIP，不算 PASS**（`SeCreateSymbolicLinkPrivilege` 缺失）。
2. **其他 reparse point 只做了 tag 映射验证**，未做真实文件系统注入，不得宣称已覆盖。
3. 本机 Windows 10 19045 上，真实悬空 Junction 的普通 `Test-Path` 返回 `True`，因此“`Test-Path` 返回 false 后走 `alreadyAbsent`”这一具体分支**未在本环境复现**；原生句柄识别与 fail-closed 已用真实 Junction 验证，未用 mock 冒充。
4. `path-safety-evidence.json`（56 项）与 `migration-path-evidence.json`（29 项）是**写证据前的快照**；最终 58 / 31 以对应 `.txt` 为准。
5. TOCTOU 残余风险未消除（DEC-029 / Issue #2）。
6. R6 补正汇总记录 `pullRequest.mergeStateStatus = CLEAN`（2026-11-24）；**该值在 PR #9 合并后已变为 `DIRTY`**，属于 main 前进导致的文档冲突，不代表代码问题。

### 5.6 当前状态

- **不存在** T1-04 独立审计报告文件。
- 状态（2026-11-25 快照）：**待第六轮补正后的独立审计**。本文件不对此作出结论。
- **2026-11-27 更新：** 第六轮独立审计通过（用户 2026-11-27 状态同步），T1-04 等待用户验收；本分支未包含该审计报告文件。详见第 10 节。

---

## 6. P2-01 独立追踪（本轮重新核验）

### 6.1 本轮实测（2026-11-25，只读 HTTP GET）

| 核验项 | 结果 |
|---|---|
| 旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` | `GET /commits/{sha}` → **HTTP 200，仍可读取** |
| 该提交内 `docs/testing/reports/T1-03-assets/logs/` 原始日志 | **9 / 9 全部 HTTP 200 可下载** |
| 9 个日志合计字节 | **147,009 字节**（与历史记录完全一致） |

9 个仍可访问的日志文件：

```
cargo-check-all-targets.log.txt
cargo-fmt-check.log.txt
cargo-test-workspace.log.txt
git-diff-check.log.txt
npm-build.log.txt
npm-check.log.txt
release-build.log.txt
release-e2e-t1-03-run2.log.txt
release-regression-all.log.txt
```

### 6.2 结论

- **服务端历史清理未完成。** 本轮取得的是“旧对象仍可访问”的正向证据，与历史记录一致。
- **P2-01 保持 OPEN，不得关闭。**
- 历史证据 `round4-verification-summary.json` 记录 `supportTicketFiled = false`；GitHub Support 工单提交状态**仍无法核验**。不得宣称已提交、也不得宣称已完成清理。
- **2026-11-27 复核：** GitHub Support 工单尚未提交，服务端清理未开始；P2-01 继续 OPEN。
- 本轮未做任何强制推送、历史重写、分支删除、Cherry-pick 或替代 PR。

### 6.3 关闭条件（未满足）

1. 仓库所有者提交并完成 GitHub Support 服务端清理。
2. 重新核验旧 SHA 不可访问。
3. 重新核验 9 个原始日志不可列出/下载。
4. 取得可核验证据并记录到 STATUS 与审计证据。

**注意：P2-01 不阻塞 T1-03/T1-04 的用户验收，只阻塞 PR #8 合并。**

---

## 7. T1-03 / T1-04 整合方案

### 7.1 main 在 PR #8 base 之后的变化（`018e851..9171fe3`）

12 个提交，17 个文件，**全部是文档与 AI 入口文件**：`.clinerules/`、`.cursor/rules/`、`.github/copilot-instructions.md`、`.windsurf/rules/`、`AGENTS.md`、`CLAUDE.md`、`GEMINI.md`、`README.md`、`docs/STATUS.md`、`docs/architecture/TECHNICAL_DESIGN.md`、`docs/decisions/DECISIONS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/DEVELOPMENT_PHILOSOPHY.md`、`docs/development/DEVELOPMENT_TASK_TEMPLATE.md`、`docs/development/archive/`（2 个新归档）、`docs/requirements/PRD.md`。

**没有一行产品代码、验证脚本或 migration 变动。** 因此 T1-03/T1-04 的代码基线没有被 main 破坏。

### 7.2 冲突分析（`git merge-tree --write-tree` 实测）

main + T1-03 冲突文件（5 个，全部文档）：

```
README.md
docs/STATUS.md
docs/decisions/DECISIONS.md
docs/development/DEVELOPMENT_PLAN.md
docs/requirements/PRD.md
```

main + T1-04 冲突文件（6 个，全部文档）：在上表基础上增加 `docs/architecture/TECHNICAL_DESIGN.md`。

**交叉验证：** main 变更文件与 T1-03 变更文件的重叠 = 5 个，其中非 `.md`/`.mdc` 文件 = **0**；与 T1-04 自身变更文件的重叠 = 5 个，非文档文件 = **0**。

**结论：不存在 Rust / TypeScript / Svelte / SQL / Tauri command / Bridge / 前端组件层面的冲突。全部冲突都是 PR #9 重写文档与本任务文档更新之间的内容冲突。**

### 7.3 Migration 依赖

| 版本 | main | T1-03 | T1-04 | 说明 |
|---|---|---|---|---|
| `0001_initial_foundation.sql` | 有 | 有 | 有 | 未改动 |
| `0002_projects.sql` | 有 | 有 | 有 | 未改动 |
| `0003_work_items.sql` | 无 | 有 | 有 | **T1-03 与 T1-04 的 blob 完全相同**：`41aa76c0afc3c83339e77bd018b3062a3424d73c` |
| `0004_work_item_creation_groups.sql` | 无 | 无 | 有 | 仅 T1-04 |

- T1-04 的 14 个提交**从未修改** `0001`、`0002`、`0003`。
- 版本号无冲突，顺序天然为 0001 → 0002 → 0003 → 0004。
- `LATEST_SCHEMA_VERSION` 需按 2 → 3（T1-03）→ 4（T1-04）前进；`validate_migration_set` 会强制该一致性。
- T1-03 合并后 main 的 `user_version` 为 3；T1-04 合并后为 4。回滚验证已覆盖 3→0 与 4→3 场景。

### 7.4 Tauri Commands / Bridge / 前端文件冲突

T1-04 堆叠在 T1-03 上，二者共同修改同一批文件（`src-tauri/src/commands/work_items.rs`、`src-tauri/src/app_state.rs`、`src/lib/bridge/workItems.ts`、`src/lib/contracts/workItems.ts`、`PendingWorkItemsView.svelte`、`QuickCreateWorkItemDialog.svelte`）。因为 T1-04 是在 T1-03 之上增量修改，**T1-03 先合入 main 后，这些文件在 main 上的状态就等于 T1-03 的状态，T1-04 的增量可无冲突叠加上去**。这与 §7.2 的 merge-tree 结果一致。

### 7.5 现有测试与历史证据是否受影响

- main 的 12 个提交未触碰任何测试代码或验证脚本，**T1-03/T1-04 的既有测试与证据未被破坏**。
- 但**文档层面**受影响：`DEVELOPMENT_PLAN.md` 已被重写为 V3.0/V3.1 的 M0～M6 结构，`STATUS.md` 已被重写。T1-03/T1-04 分支上的这些文档仍基于旧 V2.0 结构，合并时必须人工改写为 M0～M6 口径，**不得自动合并**（自动合并会退回旧路线描述）。
- 分支上的 `docs/testing/reports/T1-03-REPORT.md`、`T1-04-REPORT.md` 及 `*-assets/` 证据目录与 main 无重叠，可原样带入。

### 7.6 最小风险整合顺序

**前置门禁（2026-11-27 更新）：**

1. M0-01：T1-03 第四轮独立审计通过 —— **已由用户 2026-11-27 豁免并终止；豁免不等于审计通过。**
2. M0-02：T1-04 第六轮独立审计通过（用户 2026-11-27 状态同步）。
3. 用户验收通过（T1-03 先验收，T1-04 随后）。
4. M0-03：P2-01 服务端清理完成并取得可核验证据。

**步骤：**

**S1 — T1-03 文档预对齐（在 T1-03 分支或其集成分支上）**
把 `README.md`、`docs/STATUS.md`、`docs/decisions/DECISIONS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/requirements/PRD.md` 的 T1-03 改动重写到 V3.x / M0～M6 口径，逐段保留 T1-03 的技术事实（F1/F2、93 项、SKIP、P2-01）。**只改文档，不改代码。**
理由：把冲突解决放在可控的单一提交里，而不是留到 GitHub 合并按钮上。

**S2 — 合并 PR #8**
由用户执行。三种方式按风险从低到高：merge commit → squash → rebase。建议 **merge commit**，保持 T1-03 的 25 个提交与历史证据 SHA（`d82bdd4`、`5ab1f49`、`e8205ca`）在 main 上可追溯，因为审计报告与证据 JSON 直接引用了这些 SHA。
合并后核验：main 上 `LATEST_SCHEMA_VERSION=3`、`schema_migrations` 含 1,2,3、`cargo test --workspace` 通过。

**S3 — 从更新后的 main 建立 T1-04 集成分支**
```
git switch -c task/T1-04-integration origin/main
git cherry-pick e8205ca..4bd69f1e4c715410490496bc9fbe8e2a60623a0f
```
仅迁移 T1-04 自身 14 个提交。**禁止把 T1-03 的 25 个提交再带入一次。**
预期冲突：仅 `docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/architecture/TECHNICAL_DESIGN.md`、`docs/decisions/DECISIONS.md`、`docs/requirements/PRD.md`、`README.md`。
核验无重复：`git diff origin/main..task/T1-04-integration -- <T1-03 专属文件>` 应只剩 T1-04 的增量。

**S4 — T1-04 独立 PR**
base = 更新后的 main，只含 T1-04 的 14 个提交（+ 必要文档对齐提交）。合并后核验 `user_version=4`、`0004` 已应用、`cargo test --workspace` 与 Bridge 测试通过。

**S5 — M0 收尾**
重跑 `cargo test --workspace`、`npm run check`、`npm run build`、`git diff --check`，确认 `git status` 干净，更新 STATUS/DEVELOPMENT_PLAN，才可标记 M0 完成。

### 7.7 禁止事项（再次明确）

- 不得在 T1-03 合并前把 T1-04 的 migration 或产品代码以任何形式带入 main。
- 不得用 T1-04 的堆叠分支绕过 PR #8。
- 不得 Cherry-pick 到其他 PR、不得创建替代 PR 绕过门禁。
- 不得强制推送、不得删除分支或回滚他人提交。
- 不得由 AI Agent 自行合并任何 PR。

---

## 8. M0 最终验收清单（当前真实状态）

| # | 条件 | 状态（2026-11-27） | 依据 |
|---|---|---|---|
| 1 | T1-03 第四轮独立审计通过 | **用户豁免/终止（不等于通过）** | 用户 2026-11-27 终止独立审计并豁免合并门禁；PR #8 仍无审计报告，`reviewCount=0` |
| 2 | T1-04 第六轮独立审计通过 | **已满足（用户 2026-11-27 状态同步）** | 本分支未包含该审计报告文件；状态按用户同步记录，等待用户验收 |
| 3 | 必要的定向修复已经完成 | **开发侧已完成** | T1-03 F1/F2（`d82bdd4`）及第六轮 P1–P4/B1–B5；T1-04 R6-01～R6-03（`ada8590`） |
| 4 | T1-03 用户验收通过 | **已满足（用户 2026-11-27 明确确认）** | 验收基线 `7e317585`；用户明确回复“验收通过”；逐项结果未提供，未伪造勾选 |
| 5 | T1-04 用户验收通过 | **未满足** | 无验收记录，等待用户验收 |
| 6 | P2-01 服务端清理验证通过 | **未满足** | 旧 SHA HTTP 200；9/9 日志可下载；GitHub Support 工单尚未提交 |
| 7 | T1-03 正式进入 main | **未满足** | PR #8 OPEN / `CONFLICTING / DIRTY`，base `018e851` 落后 main `9171fe3` |
| 8 | T1-04 正式进入 main | **未满足** | 无 main PR，仍堆叠在 T1-03 `e8205ca` 上 |
| 9 | 数据库 Migration 顺序正确 | **已满足（分析层面）** | 0001→0002→0003→0004 无版本冲突；0003 blob 两分支一致 |
| 10 | main 文档与实际代码状态一致 | **部分满足** | 2026-11-27 已同步 STATUS、DEVELOPMENT_PLAN 与本文件；合并后仍需再次同步 |
| 11 | Git 工作区干净 | **未满足** | T1-03 主工作区仍有未跟踪的 `scripts/verify/__pycache__/`，按要求未删除 |
| 12 | 没有遗留未经说明的代码或数据库问题 | **已说明** | DEC-029 TOCTOU（Issue #2）、DEC-028 未加密、P2-01、Symbolic Link SKIP、Windows ACL 未测试、文档冲突，均在本文件与 STATUS 中列明 |

**M0 尚未完成。** 第 5、6、7、8 项未满足前不得启动 M1（第 1 项已由用户豁免、第 2 项按用户同步为通过、第 4 项用户验收已满足）。

---

## 9. 本轮实际执行的核验

> **本节为 2026-11-25 的历史命令记录，数字与 SHA 不代表 2026-11-27 状态；最新事实见第 10 节。**

全部为只读命令，未修改远端。以下是本文件所有事实的来源。

| # | 命令 / 操作 | 结果 |
|---|---|---|
| 1 | `git fetch origin --prune` | `018e851..9171fe3 main`；远端分支列表刷新 |
| 2 | `git log --oneline -1 origin/main` | `9171fe3 Merge pull request #9` |
| 3 | `git rev-parse origin/task/T1-03-…` / `…T1-04-…` | `e8205ca…` / `4bd69f1…` |
| 4 | `git rev-list --left-right --count main...T1-03` | `12 25` |
| 5 | `git rev-list --left-right --count main...T1-04` | `12 39` |
| 6 | `git rev-list --left-right --count T1-03...T1-04` | `0 14` |
| 7 | `git merge-base` × 3 组 | `018e851` / `018e851` / `e8205ca` |
| 8 | `git merge-tree --write-tree --name-only origin/main origin/task/T1-03-…` | exit 1；冲突仅 5 个文档文件 |
| 9 | `git merge-tree --write-tree --name-only origin/main origin/task/T1-04-…` | exit 1；冲突仅 6 个文档文件 |
| 10 | `git diff --name-only 018e851..origin/main` ∩ 分支变更文件 | 非文档重叠 **0** |
| 11 | `git rev-parse <ref>:…migrations/0003_work_items.sql` × 2 | 同一 blob `41aa76c…` |
| 12 | `git log --oneline e8205ca..T1-04 -- migrations/000[123]…` | 空（T1-04 未改 0001～0003） |
| 13 | `gh pr list --state all` / `gh pr view 8` / `gh pr view 3` | PR #8 OPEN/DIRTY/0 review；PR #9 MERGED；PR #3 OPEN |
| 14 | `git status --porcelain -uall` | 仅 7 个未跟踪 `.pyc`；无 stash |
| 15 | `git diff origin/main..T1-04 -- .gitignore` | T1-04 新增 `__pycache__/`、`*.pyc` |
| 16 | `GET /repos/…/commits/2342828852ab…`（REST） | **HTTP 200**，仍可读 |
| 17 | `GET /repos/…/contents/…/logs/<9 files>?ref=2342828…` | **9/9 HTTP 200**，合计 147,009 字节 |
| 18 | `git diff --check` | exit 0 |
| 19 | `git ls-tree` / `Select-String` 核对 main 数据库源码与测试函数名 | 见 §3 |
| 20 | `gh api` / REST 解析上游 Skill 最新提交 | 见附录 |

**未执行**：`cargo fmt/check/test`、`npm run check`、`npm run build`、任何 Windows Release / UI E2E / 路径安全脚本。因此本文件不对运行结果作任何新声明。

### 本轮未做

- 未修改任何产品代码、验证脚本或 migration。
- 未修改任何历史审计报告。
- 未合并、未关闭任何 PR；未关闭 P2-01；未强制推送；未删除任何分支或文件。
- 未修改 T1-03 / T1-04 分支（只在本地新建文档分支）。

### 当时记录的下一步（2026-11-25 快照）

> 以下为 2026-11-25 记录的历史下一步；2026-11-27 的实际进展与当前顺序见第 10 节。

1. 独立审计对话对 M0-01（T1-03 @ `e8205ca`）出具第四轮审计结论。
2. 独立审计对话对 M0-02（T1-04 @ `4bd69f1`）出具第六轮审计结论。
3. 审计问题（如有）定向修复，重新自测，更新证据。
4. 用户验收 T1-03。
5. 仓库所有者推进 GitHub Support 清理；完成后重新核验旧 SHA 与 9 个日志不可访问，关闭 P2-01。
6. 按 §7.6 执行 S1→S5。
7. M0 全部满足后，从统一 main 启动 M1；M1-02 开发前必须先就 OPEN-012 向用户确认。

---

## 10. 2026-11-27 用户决策与状态同步（追加，不覆盖历史）

> 本节追加于 2026-11-25 收口包之后。§1～§9 保留 2026-11-25 的历史快照原文；本节记录用户 2026-11-27 的决策、当前真实状态和本轮准备性核验，不修改任何历史审计结论。

### 10.1 用户决策（2026-11-27）

1. 豁免 T1-03 原定“独立审计必须通过才能合并 PR #8”的条件。
2. 以 `7e317585ec273898907f31a158561bc8358f8500` 作为正式交付基线，直接进入用户验收。
3. 不再进行第七轮或最终独立审计；该决定**不代表独立审计通过**，也**不代表用户验收通过**。
4. P2-01 仍然是 PR #8 的硬性合并阻断条件；GitHub Support 服务端清理未完成之前不得合并 PR #8。
5. 不允许擅自合并 PR #8 或 PR #10。

### 10.2 当前状态总表

| 项目 | 状态 |
|---|---|
| T1-03 | 用户豁免独立审计门禁，进入用户验收 |
| T1-04 | 第六轮独立审计通过，等待用户验收 |
| P2-01 | OPEN，等待 GitHub Support |
| M0-05 | 完成 |
| M0-06 | 只读核验完成 |
| PR #8 | OPEN，不得合并 |
| PR #10 | OPEN，不得合并 |
| M1 | 等待 M0 正式收口 |

### 10.3 T1-03 当前交付与验收准备

| 项 | 值 |
|---|---|
| 最终交付 HEAD | `7e317585ec273898907f31a158561bc8358f8500` |
| 验收程序 | `D:\WorkManager-UAT-20261127\WorkManager.exe` |
| 程序大小 / SHA-256 | 10,352,128 字节 / `f46c9b0cb3c9d094475cab6abd8276276126f2ea0d2e5b38b6d6a4fbf92b2b68` |
| 数据目录 | `D:\WorkManager-UAT-20261127\data\`（首次启动时由程序创建，未复制正式数据库） |
| 验收清单 | `docs/testing/reports/T1-03-USER-ACCEPTANCE.md`（PR #10 分支） |
| 用户验收 | **进行中，结论待定** |

- 来源 `D:\工作事项看板\target\release\workmanager.exe` 复制后重新计算 SHA-256，与来源及上述值完全一致；原始 Release EXE 未被修改。
- UAT 目录为 2026-11-27 新建的独立目录，未使用 `D:\WorkManager-UAT-20261119`，未触碰正式目录 `D:\WorkManager`。
- 程序未被自动启动，等待用户亲自验收；清单 12 项全部保持未勾选。

### 10.4 PR #8 基线差异与状态

| 项 | 2026-11-27 实测 |
|---|---|
| PR 状态 | OPEN，`mergeable=CONFLICTING`，`mergeStateStatus=DIRTY` |
| head | `7e317585ec273898907f31a158561bc8358f8500` |
| base | `018e851e8daf5835391a7b61caf881bc57c2ad42`（旧 SHA，落后当前 main） |
| 当前 main | `9171fe35a7e080097991f547efe37ff5a504257c` |
| 变更规模 | 131 个文件、+23,131 / −103 |
| 审计门禁 | 用户 2026-11-27 豁免（不等于审计通过） |
| 合并门禁 | 用户验收通过 + P2-01 服务端清理验证通过；两者均未满足 |

基线差异与 `dirty` 状态来自 PR #9 重写文档与 T1-03 分支文档更新的冲突，以及 PR #8 的 base 未随 main 前进。**本轮不处理 rebase、历史重写、强推和合并。**

### 10.5 T1-04 当前事实

- HEAD 仍为 `4bd69f1e4c715410490496bc9fbe8e2a60623a0f`；基于 T1-03 的 `e8205ca` 堆叠，不包含 T1-03 后续 5 个补正/证据提交（`af2421e`、`6ddae47`、`e3bb86b`、`d1aa429`、`7e31758`）；这些提交未改动产品代码，只涉及文档、证据和验证脚本。
- 第六轮独立审计通过（用户 2026-11-27 状态同步），等待用户验收；本分支未包含该审计报告文件。
- T1-04 的审计/验收状态与 T1-03 分开记录，不得混写；T1-04 仍不得通过堆叠分支绕过 PR #8 提前进入 main。

### 10.6 P2-01 复核

- 旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 与 9 个原始命令日志仍可读取（与 2026-11-25 记录一致）。
- 截至 2026-11-27，GitHub Support 工单尚未提交，服务端清理未开始。
- **P2-01 保持 OPEN。** 只有服务端清理完成并重新核验旧 SHA 与 9 个日志不可访问、取得可核验证据后，才能关闭 P2-01。

### 10.7 本轮实际执行范围

- 只读取校验、准备 UAT 目录、复制 Release EXE 并复算 SHA-256。
- 只修改文档：`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/M0-CLOSEOUT.md`，并新增 `docs/testing/reports/T1-03-USER-ACCEPTANCE.md`。
- 未修改产品代码、T1-04 代码/分支、main、历史审计报告；未 rebase、未 cherry-pick、未强推、未合并任何 PR；未运行新的独立审计、未重跑 cargo/npm 全量测试、未重新构建产品。
- 未删除 T1-03 主工作区未跟踪的 `scripts/verify/__pycache__/`；M1 未启动。

### 10.8 尚未解决的 M0 阻塞项

1. T1-03 用户验收未完成（结论待定）。
2. T1-04 用户验收未完成。
3. P2-01 服务端清理未完成（GitHub Support 工单尚未提交）。
4. PR #8 因上述门禁保持 OPEN；PR #10 保持 OPEN。
5. PR #8 base 落后 main 且 `CONFLICTING / DIRTY`；本轮不处理，合并前需按 §7.6 处理。
6. DEC-029 TOCTOU、DEC-028 未加密、Symbolic Link SKIP、Windows ACL 未测试等已知限制仍在。

---

## 附：2026-11-25 本轮使用的上游 Skill 版本

| Skill | 上游文件 | Commit | 提交时间 |
|---|---|---|---|
| Ponytail（`full`） | `DietrichGebert/ponytail` `skills/ponytail/SKILL.md` | `df9e89941d50419fd5bcf1de41e28097f1db49b2` | 2026-10-16 |
| Matt Pocock Implement | `mattpocock/skills` `skills/engineering/implement/SKILL.md` | `6d6a5b9072f47ee7ba1d972d8ce0ee98b7ed4394` | 2026-10-07 |
| Matt Pocock TDD（备用，本轮未执行代码任务） | `mattpocock/skills` `skills/engineering/tdd/SKILL.md` | `3f599139104dfceabc7754eeb91319802f85e042` | 2026-10-07 |

仓库 `main` HEAD 快照：ponytail `ebd8654c2c627f721eb8f9c0d1bd4090a29f9e10`，mattpocock/skills `d65391149dbb5fe76478e76fa8d5122b2aa5a70e`。

2026-11-25 轮次没有代码任务，因此 Ponytail 与 Implement Skill 主要用于约束文档与方案的最小化：不新增文档体系以外的结构、不重构无关代码、不为假设需求预留设计。


## 11. 2026-11-27 T1-03 用户验收结果（最新状态）

> 本节记录用户在 UAT 准备完成后作出的明确验收决定，更新 §8 的当前验收状态；§10 保留为验收启动时的历史快照，不覆盖历史记录。

### 11.1 用户决定

- 用户于 **2026-11-27** 明确回复：**“验收通过”**。
- 验收基线：T1-03 `7e317585ec273898907f31a158561bc8358f8500`。
- 当前结论：**T1-03 总体用户验收通过**。
- T1-03 独立审计仍为用户明确终止并豁免门禁；此决定不代表独立审计通过，也不补写独立审计报告。

### 11.2 逐项记录边界

- 用户给出的是总体验收通过决定，未提供 12 项逐项结果。
- `T1-03-USER-ACCEPTANCE.md` 中 12 个逐项复选框继续保持未勾选；这不代表这些项目失败，只表示没有逐项结果可记录。
- 用户未另行提供问题清单；本记录不推断“没有发现任何问题”。

### 11.3 当前 M0 状态

| 项目 | 当前状态 |
|---|---|
| T1-03 用户验收 | **通过（2026-11-27）** |
| T1-03 独立审计 | 用户终止并豁免，不代表审计通过 |
| T1-04 用户验收 | 待用户验收 |
| P2-01 | OPEN；GitHub Support 工单尚未提交，服务端清理未完成 |
| PR #8 | OPEN；P2-01 仍为硬性合并门禁，且 base 落后 main、`CONFLICTING / DIRTY` |
| PR #10 | OPEN；本轮不合并 |
| M1 | 未启动；等待 M0 收口 |

### 11.4 下一步

1. 继续 T1-04 用户验收，单独记录其验收结论。
2. 仓库所有者提交 GitHub Support 工单，完成 P2-01 服务端清理并核验旧 SHA 与 9 个日志不可访问。
3. P2-01 关闭后，再处理 PR #8 的 base 更新与文档冲突；不通过 cherry-pick、替代 PR、强推或堆叠分支绕过门禁。
4. PR #8 进入 main 后，按既定方案从更新后的 main 整合 T1-04 自身提交；完成 T1-04 验收与 PR 流程。
5. 两项代码进入统一 main 并完成 M0 最终门禁后，才启动 M1。
