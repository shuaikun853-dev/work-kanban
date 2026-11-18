# T1-01 第四轮独立审计报告

**审计日期：** 2026-11-18  
**审计对象：** PR #1，R3 修复代码提交及当前分支证据  
**审计时 PR HEAD：** `ae14bff1f1fd0166b1bfc79ef2ab6c097f865a37`  
**R3-01 代码提交：** `ae1eb65a00e0d36907f8769d1421aef17a73023f`  
**R3-02 代码提交：** `4942eb0c60bf43fd3d1371fbf427f5b0d043ebc1`  
**main：** `5a55b8d04e79d19cae67067e3fef09140c3fe501`  
**PR：** [#1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（Open、未合并）  
**审计结论：** **R3-01（P1）与 R3-02（P2）代码审查通过；T1-01 独立审计通过，待用户验收。** TOCTOU 按 DEC-029 接受并延期，仍未修复。

---

## 1. 审计范围与方法

本轮聚焦第三轮审计遗留的两项问题：

- R3-01：D 盘根卷作为信任锚，但自身未独立验证。
- R3-02：真实双进程初始化锁测试未能严格证明 waiter 已在 creator 持锁期间观察到锁竞争。

本轮核对了：

- R3-01/R3-02 两个代码提交及其父子关系；
- `portable_paths.rs`、`init_lock.rs`、`database/mod.rs` 的当前分支源码；
- R3 专项修复报告、机器可读证据、专项测试日志、10 轮稳定性日志和 workspace 回归日志；
- PR #1 当前描述、分支 HEAD、main HEAD、任务状态及 DEC-029。

**执行证据边界：** 本审计环境未连接开发者 Windows 10 主机，未在该主机重新执行 cargo/npm/Release 测试。测试结果依据仓库已提交的 Windows 10 脱敏日志与机器可读证据复核；这是独立代码/证据审查，不冒充独立实机重放。当前 PR HEAD 没有 GitHub Actions workflow runs，也没有 commit status checks 或 PR review 记录。

---

## 2. R3-01：D 盘根卷信任锚（P1）

<badge>审计通过</badge>

### 2.1 代码复核

生产路径现在通过 `d_drive_volume_identity()` 调用 `verify_root_volume_trust(D:\\)`，不再直接把未经独立验证的 D 根句柄作为信任基准。

生产信任锚按顺序执行：

1. `GetDriveTypeW`：保留固定盘/可移动盘白名单，拒绝网络盘、光驱、RAM disk 和无效盘符。
2. `GetVolumeNameForVolumeMountPointW("D:\\")`：必须取得卷 GUID；API 失败直接返回 `path-root-trust-anchor-invalid`。
3. 打开 D 根目录句柄，读取 `VOLUME_NAME_GUID` / `VOLUME_NAME_NT`；句柄 GUID 必须与挂载点 GUID 一致。
4. `QueryDosDeviceW("D:")`：读取当前 DOS 设备映射；映射必须解析为 NT 设备卷，且与根句柄 `VOLUME_NAME_NT` 一致。SUBST 的 `\\??\\C:\\...` 路径别名被拒绝。
5. 取得 C 根卷 GUID，D/C GUID 相同则拒绝。

以上函数位于生产代码，不是仅供测试的 helper。调用链：

```text
resolve() / ensure_directories() / Database::initialize()
  -> validate_real_storage_path()
  -> ensure_volume_is_d_volume()
  -> d_drive_volume_identity()
  -> verify_root_volume_trust(D:\\)
```

信任锚验证发生在目录创建、写探针、初始化锁和 SQLite 写入之前。任一关键 API 失败均 fail-closed。既有最终路径解析、目标卷身份比较、Junction 检查和卷类型白名单仍保留。

### 2.2 专项证据复核

日志：[`cargo-test-r3-01-trust-anchor.log.txt`](T1-01-assets/r3-fix/logs/cargo-test-r3-01-trust-anchor.log.txt)

- 命令：`cargo test -p workmanager-core --lib r3_01 -- --nocapture --test-threads=1`
- 记录退出码：0
- 记录结果：6 passed / 0 failed

| 场景 | 证据性质 | 结果 |
|---|---|---|
| 正常 D 根：挂载点 GUID、句柄 GUID、NT 设备映射一致；D 与 C GUID 不同 | Windows 10 实机 | PASS |
| SUBST Q:→C: 作为候选根 | Windows 10 实机 | PASS；信任锚阶段拒绝，QueryDosDevice 显示 `\\??\\C:\\...` |
| 挂载点 GUID 与句柄 GUID 不一致 | 注入模拟 | PASS；拒绝 |
| D/C GUID 相同 | 注入模拟 | PASS；拒绝 |
| DOS 路径别名、NT 设备身份不匹配 | 注入模拟 + 真实 D 映射对照 | PASS |
| 卷挂载点 API 对普通目录失败、非法根路径/UNC | 真实 API 失败行为 | PASS；fail-closed |

实机证据记录：D 根挂载点 GUID 与句柄 GUID 一致，NT 设备映射为 `\\Device\\HarddiskVolume4`；C 根 GUID 不同。

### 2.3 限制与判断

- 真实 D:→C: SUBST 未实机构造；本机 D: 是真实卷，使用真实 Q:→C: SUBST 夹具验证同类机制，并明确区分证据性质。
- 真实映射网络盘、D 路径下真实跨卷目录挂载点未实机验证。
- D/C 同卷场景通过纯校验注入覆盖，不伪称真实同卷机器环境。

这些限制已如实记录，不推翻当前生产信任锚代码逻辑。**R3-01 关闭。**

---

## 3. R3-02：双进程锁竞争测试确定性（P2）

<badge>审计通过</badge>

### 3.1 观察器实现复核

`init_lock.rs` 新增 `#[cfg(test)] test_contention_observer`：

- 仅在测试构建中编译，不进入 Release/生产构建；
- 不是 Tauri IPC，也没有运行时配置开关；
- 未安装回调时为无操作；
- 只有 `try_lock_exclusive()` 返回 `Ok(false)` 时才调用观察器；
- Windows 实现仅在 `LockFileEx` 失败且 `GetLastError() == ERROR_LOCK_VIOLATION`（33）时返回 `Ok(false)`；
- 观察器只报告已发生的锁竞争，不改变加锁、重试或释放语义。

Microsoft API 语义与实现一致：`LOCKFILE_FAIL_IMMEDIATELY` 要求无法取得锁时立即返回；系统错误码 33 是 `ERROR_LOCK_VIOLATION`，表示文件区域已被其他进程锁定。

### 3.2 双进程同步链复核

当前测试使用真实独立 creator/waiter 子进程：

1. creator 先取得初始化锁，写入 `a-has-lock`。
2. creator 在收到 `b-lock-contention` 前不创建数据库。
3. waiter 安装测试观察器，调用完整 `Database::initialize()`。
4. 底层 `LockFileEx` 明确返回锁竞争后，观察器才写 `b-lock-contention`。
5. creator 收到该信号后才创建正式数据库、进入 WAL、写入虚构 canary，并保持锁与数据库连接。
6. 父进程确认 waiter 竞争信号、主库、非空 WAL 和 creator 仍运行后，才通知 creator 释放锁。
7. waiter 随后取得锁，通过完整初始化路径识别已有主库并打开。
8. 最终检查 canary、migration 数量和 integrity。

旧的“先写 b-inspected、再尝试加锁”竞态已消除。同步顺序由真实锁竞争结果与跨进程信号保证，不依赖固定 sleep 安排进程先后。

### 3.3 专项证据复核

日志：[`cargo-test-r3-02-lock-contention.log.txt`](T1-01-assets/r3-fix/logs/cargo-test-r3-02-lock-contention.log.txt)

- 命令：`cargo test -p workmanager-core --lib r2_01 -- --nocapture --test-threads=1`
- 记录退出码：0
- 记录结果：3 passed / 0 failed（包含子进程辅助测试与夹具测试）

关键日志记录：

- waiter 信号包含 `try_lock_exclusive=busy`；
- creator 持锁期间主库 20,480 B、WAL 8,272 B；
- waiter 通过完整 `Database::initialize()`；
- `created_new=false`；
- `orphaned_sidecar=false`；
- canary 保留；
- `integrity=ok`；
- migration 记录 1 条。

稳定性日志：[`cargo-test-r3-02-stability-10x.log.txt`](T1-01-assets/r3-fix/logs/cargo-test-r3-02-stability-10x.log.txt)

- 10 次独立测试进程运行；
- 10/10 退出码 0；
- 每轮均记录真实 busy 信号、活动 WAL 和成功打开已有数据库；
- 未发现孤儿 WAL 误判或测试超时。

### 3.4 非阻塞观察项

`Database::initialize()` 当前使用生产默认锁等待上限 5 秒；本轮测试没有单独覆盖一个更长的测试专用等待上限。已提交的 10 轮日志每轮约 0.26–0.36 秒，距离 5 秒上限有明显余量，因此不构成本轮阻塞项。若未来在更慢的 CI/磁盘环境出现偶发超时，可增加不改变生产默认值的测试专用 timeout 注入。

**R3-02 关闭。**

---

## 4. 完整回归与证据边界

已提交的开发机 Windows 10 日志记录：

| 检查 | 记录结果 |
|---|---|
| `cargo fmt --all -- --check` | 退出码 0 |
| `cargo check --workspace --all-targets` | 退出码 0，无警告 |
| `cargo test --workspace` | 68 passed / 0 failed / 0 ignored |
| `npm run check` | 0 errors / 0 warnings |
| `npm run build` | 成功 |
| `npm run tauri build -- --no-bundle` | 退出码 0 |
| Release 便携验证 | 106 项，FAIL=0，WARN=1 |
| Release 异常注入 | 73 项，FAIL=0，WARN=0 |
| Release WebView2 UI/IPC/CSP | 21/21 断言通过，CSP 违规 0 |

Release EXE 记录：

- 路径：`target/release/workmanager.exe`
- 大小：9,993,216 字节
- SHA-256：`41A8F6B4759107625487FE605820FAABF20D312A560AE9765949027D100F7800`

以上测试数据来自开发代理提交的原始脱敏日志。本轮未独立重跑 Windows 构建或 Release 测试；当前仓库也没有关联的 GitHub Actions workflow run 或 commit status checks。

---

## 5. 历史问题与残余风险

| 问题 | 当前处置 |
|---|---|
| 第一轮 P1/P2：零字节库、路径真实卷、预检查顺序、初始化锁、UI 阻塞 | 前序审计后已修复并有专项回归 |
| R2-01 锁后活动 WAL 误判 | 已修复；R3-02 进一步补强确定性测试 |
| R2-02 Debug/Test Junction 绕过正式目录保护 | 已修复 |
| R2-04 证据/进度同步 | 已修复 |
| R3-01 D 根信任锚 | 本轮审计通过 |
| R3-02 锁竞争测试确定性 | 本轮审计通过 |
| TOCTOU | 按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，**未修复** |
| 真实映射网络盘、真实跨卷挂载点、真实 D:→C: SUBST | 未实机验证，已如实披露 |
| 非 Windows 降级实现、devCsp | 未交叉编译/未端到端验证 |
| `%LOCALAPPDATA%\\EBWebView` | 验证前已存在的共享目录，来源待阶段 6 审计 |
| 单实例、备份恢复、业务功能 | 分别按 T6-07、OPEN-001/002/003 和后续业务任务处理 |

DEC-029 只接受 TOCTOU 延期，不代表风险修复。不得宣称任何情况下都不会写入 C 盘；禁止静默回退 C 盘，已检测到的边界违规继续 fail-closed。

---

## 6. GitHub 状态与最终结论

- 开发分支：`task/T1-01-sqlite-foundation`
- PR #1：Open、未合并
- 审计时 PR HEAD：`ae14bff1f1fd0166b1bfc79ef2ab6c097f865a37`
- main：仍为 `5a55b8d04e79d19cae67067e3fef09140c3fe501`
- 未推送 main；未合并 PR；未开始 T1-02。

**第四轮独立审计结论：通过。**

R3-01 与 R3-02 的代码修复和已提交专项证据满足本轮审计要求。T1-01 当前状态更新为：**独立审计通过，待用户验收**。这不等于用户已验收，也不等于 PR 已合并。

在用户明确验收前：
- 不得将任务标记为“验收完成”；
- PR #1 保持打开、不合并；
- 不修改 main；
- 不开始 T1-02。
