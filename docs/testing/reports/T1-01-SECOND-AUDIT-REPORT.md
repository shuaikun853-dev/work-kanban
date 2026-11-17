# T1-01 第二轮独立审计报告

**审计日期：** 2026-11-17  
**审计对象：** PR #1 最新 HEAD `892b25f9374a52cf74ba5f983f136295a52f2996`  
**基线：** `main` @ `5a55b8d04e79d19cae67067e3fef09140c3fe501`  
**PR：** [#1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（Open、未合并）  
**审计结论：** **不通过，T1-01 继续返工；不得合并 PR，不得开始 T1-02。**

---

## 1. 本轮已核实的 GitHub 状态

- PR #1：Open，merged=false，base=main，head=`892b25f9374a52cf74ba5f983f136295a52f2996`。
- 分支相对 main：ahead 8、behind 0；PR 当前 67 个变更文件。
- GitHub Actions workflow runs：当前 HEAD 未返回 PR workflow run。
- Commit combined status：没有已配置的状态检查。
- PR reviews、inline review threads：当前没有 GitHub review 记录。
- 最新修复报告已存在：`docs/testing/reports/T1-01-AUDIT-FIX-REPORT.md`。
- 本轮检查是 GitHub 源码静态审计；DeepSeek 报告的 Windows 本机测试退出码和本机日志尚未由本审计环境重新执行/复核。

## 2. 上一轮问题复核

| 上一轮问题 | 本轮结论 |
|---|---|
| 已有 0 字节 work.db 被当作空库 | 代码修复有效：先检查文件大小，异常空文件不交给 SQLite 打开 |
| 0 字节主库与 WAL/journal 边界 | 代码修复有效：保留异常主库及非空 sidecar，fail-closed |
| 已有数据库预检查顺序 | 代码修复有效：先检查版本、完整性、外键和兼容性，再应用 WAL 等运行参数 |
| 健康检查阻塞 UI | 代码修复有效：async command + spawn_blocking，未暴露 Connection/任意 SQL |
| 初始化临时文件清理竞争 | 基础修复有效：增加 LockFileEx 跨进程锁；但发现下述新的锁后检查顺序缺陷 |

## 3. 未关闭问题

### R2-01：正式数据库已创建时，孤立 sidecar 检查可能误判有效 WAL

**等级：P1（必须修复）**

代码位置：[database/mod.rs](https://github.com/shuaikun853-dev/work-kanban/blob/task/T1-01-sqlite-foundation/crates/workmanager-core/src/database/mod.rs#L96-L118)。

当前首次安装分支的顺序是：

1. 初次检查时数据库不存在；
2. 等待并取得初始化锁；
3. 先调用 `orphaned_sidecar_error()`；
4. 再次检查正式数据库是否已由其他进程创建。

这会产生竞争窗口：进程 B 初次检查时看到数据库不存在并等待锁；进程 A 创建数据库、打开 WAL 并写入，随后释放锁；B 获得锁后，在重新检查主库之前看到非空 `work.db-wal`，错误地返回 `database-orphaned-sidecar`。此时主数据库其实存在且有效。

当前双进程测试只验证两个子进程同时初始化成功，没有覆盖“等待者取得锁时，主库已存在且已有活动 WAL”的情况。

**修复要求：**

- 取得锁后，先重新执行 `inspect_existing_database()`。
- 只有确认主库仍不存在时，才调用 `orphaned_sidecar_error()`。
- 增加确定性双进程回归测试：等待进程初次观察到主库缺失并阻塞；另一个进程创建主库并产生非空 WAL；等待进程取得锁后必须识别并打开现有主库，不能把正常 WAL 判为孤儿文件。
- 同时保留真正“主库缺失 + 非空 WAL/journal”必须 fail-closed 的测试。

### R2-02：Debug/Test 的正式目录保护可被同卷 Junction 绕过

**等级：P1（必须修复）**

代码位置：[portable_paths.rs](https://github.com/shuaikun853-dev/work-kanban/blob/task/T1-01-sqlite-foundation/crates/workmanager-core/src/portable_paths.rs#L225-L260)。

当前 Debug/Test 对 `D:\WorkManager` 的保护使用输入字符串的 `is_same_or_child(data_root, FORMAL_RELEASE_ROOT)`。后续 `validate_real_storage_path()` 只确认真实目标仍在 D 盘且卷类型允许，没有再检查解析后的真实目标是否等于/位于正式目录下。

因此，指向正式目录的 D 盘 Junction 可能绕过字符串检查，导致 Debug/Test 写入正式数据目录。

**修复要求：**

- Debug/Test 的正式目录保护必须比较规范化后的真实目标路径，而不是仅比较用户输入路径。
- 在创建任何目录、写探针、锁文件或数据库之前完成该保护。
- 增加“测试路径 Junction 指向受保护目录”的回归测试。
- 测试不得创建、覆盖或清理真实的 `D:\WorkManager`。建议把受保护根目录抽象为可注入测试参数，用 D 盘隔离目录模拟正式根，再验证 Junction 别名被拒绝。
- Release 的 EXE 同级数据路径规则不得被改变。

### R2-03：真实卷身份验证与 TOCTOU 风险尚未完全关闭

**等级：P1（严格 D 盘边界尚未证明）**

代码使用 `GetFinalPathNameByHandleW(VOLUME_NAME_DOS)` 解析最终 DOS 路径，再从盘符调用 `GetDriveTypeW`。这已经覆盖本机实际验证过的 D→C Junction，但返工报告明确承认 SUBST/卷挂载点没有专门识别或实机验证。

此外，真实路径句柄在校验函数返回时关闭，后续仍使用路径字符串执行 `create_dir_all`、写探针和数据库打开，存在检查与使用之间的 TOCTOU 窗口。

**修复/验收要求：**

- 用卷 GUID 或 NT 设备卷身份比较目标目录与实际 D: 根卷，不能只依据最终 DOS 盘符和 `GetDriveTypeW`。
- 对 SUBST、卷挂载点、映射网络盘分别增加测试或明确记录无法构造的环境限制。
- 对 TOCTOU：优先使用稳定目录句柄/句柄相对操作，使验证与后续创建/打开指向同一目录对象；若本任务不实现，必须明确标记为未关闭的存储边界风险，不得宣称绝对保证“任何情况下都不会写 C 盘”，并等待用户确认是否接受延期。
- 不能以“后续阶段再处理”自动覆盖用户当前的 D 盘本地存储要求。

### R2-04：GitHub 交付证据和进度文档存在过期内容

**等级：P2（提交下一轮修复前必须同步）**

已核实的具体不一致：

1. PR #1 描述仍指向初始代码提交 `682ba04`，写着 33 项 Rust 测试和旧 Release SHA；与最新修复报告的 52 项测试、最新 Release SHA 不一致。
2. `docs/testing/reports/T1-01-evidence.json` 仍记录旧 `codeCommit=682ba04`、33 passed 和旧 Release SHA。原始 Markdown 报告已标记历史，但 JSON 没有清晰的历史标记。
3. `docs/STATUS.md` 第 93 行仍称“两个进程同时首次启动仍存在初始化竞争窗口”，与新增 LockFileEx 机制冲突。当前确实还没有应用级单实例保护，但应区分“允许多实例”与“首次初始化已串行化”。
4. 最新 HEAD 没有 GitHub Actions workflow run 或 commit status checks；修复报告引用的 `D:\工作事项看板\test-artifacts\audit-final-*.log` 仅存在开发机，未归档到 GitHub。

**修复要求：**

- 更新 PR #1 描述，列出最新代码 SHA、最新 HEAD、最新测试结果、Release SHA 和审计状态。
- 保留旧 `T1-01-evidence.json` 作为返工前历史证据；新增 `T1-01-AUDIT-FIX-evidence.json`，记录最新代码提交、PR HEAD、52 项 Rust 测试、Release 脚本结果、Release SHA、已知限制。
- 修正 STATUS.md 的并发风险表述。
- 上传脱敏后的专项测试日志，或提供可复现的 Windows CI 运行记录。不得上传用户数据、凭据或机器敏感信息。

## 4. 当前通过项与未覆盖项

### 代码层面已确认

- SQLite 0 字节数据库保护与 sidecar fail-closed 逻辑。
- 已有数据库预检查顺序。
- Tauri 健康检查异步派发。
- IPC 仍只暴露受限健康检查命令。
- Rust Core 与 Tauri Adapter 的边界仍然清晰。
- CSP 已配置，Release CDP 证据 JSON 显示违规列表为空。

### 仍需如实记录

- 映射网络盘没有真实实机验证。
- devCsp 没有在 `tauri dev` 下端到端验证。
- TOCTOU 尚未关闭。
- 非 Windows 降级实现没有交叉编译验证（目标平台为 Windows 10）。
- 本审计没有在用户 Windows 机器上重跑全部命令；当前无 GitHub Actions 结果，测试运行结论仍以开发机报告为证据。

## 5. 当前状态与门禁

- T1-01：**返工中**。
- PR #1：保持 Open，不合并。
- main：不修改。
- T1-02：不得开始。
- 只有上述 P1 问题修复、P2 文档/证据同步完成、回归测试通过并重新独立审计通过后，才能将 T1-01 标记为“验收完成”。
