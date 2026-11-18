# T1-01 第三轮独立审计报告

**审计日期：** 2026-11-18  
**审计对象：** PR #1 最新 HEAD `eaf6ef7013a5f669c152e57bf4da94bc77367b85`  
**本轮代码提交：** `a148f0d10eda994d21bb088984228b4e9d6b97ce`  
**基线 main：** `5a55b8d04e79d19cae67067e3fef09140c3fe501`  
**PR：** [#1](https://github.com/shuaikun853-dev/work-kanban/pull/1)（Open、未合并）  
**审计结论（审计时点）：** **不通过；R2-03 TOCTOU 未关闭，并新增 R3-01 P1 信任锚验证缺口、R3-02 P2 测试确定性缺口。2026-11-18 用户随后按 DEC-029 接受 TOCTOU 残余风险并延期至独立 Issue #2；R3-01/R3-02 仍待处理，PR 不得合并、T1-02 不得开始。**

---

## 1. GitHub 状态与证据范围

- PR #1 最新 HEAD：`eaf6ef7013a5f669c152e57bf4da94bc77367b85`；代码提交为 `a148f0d10eda994d21bb088984228b4e9d6b97ce`，后续提交用于报告、证据和状态文档。
- PR 状态 Open、merged=false；main 仍为 `5a55b8d`。
- 本轮读取了最新 PR 描述、代码 diff、`database/mod.rs`、`portable_paths.rs`、`init_lock.rs`、新增 Junction 测试、第二轮修复报告、机器可读 JSON、脱敏原始日志及 STATUS/开发计划/任务说明。
- 当前 HEAD 未返回 GitHub Actions workflow runs，也没有 commit status checks 或 PR review 记录。16 份脱敏日志已提交 GitHub，但仍是开发代理在其 Windows 10 机器上执行的证据；本审计环境没有在该 Windows 主机重放测试。

## 2. 第二轮问题复核

| 问题 | 本轮结论 | 依据 |
|---|---|---|
| R2-01 锁后活动 WAL 被误判为孤儿 | **修复逻辑成立** | `open_or_create_after_lock()` 先重检主库；主库存在时不检查孤儿 sidecar；主库缺失才检查非空 WAL/journal |
| R2-02 Debug/Test Junction 绕过正式目录保护 | **修复逻辑成立** | `ensure_not_protected_root()` 比较输入规范化路径与句柄解析的真实最终路径；resolve、ensure_directories、数据库初始化前均复验 |
| R2-03 真实卷身份 | **部分成立，新增 P1 验证缺口** | 目标句柄 GUID/NT 身份与 `D:\\` 句柄身份比较，但 D 根本身没有被独立证明为真实卷挂载点/非 C 卷别名 |
| R2-03 TOCTOU | **审计时未解决（P1）；审计后用户按 DEC-029 接受残余风险并延期至 Issue #2** | 句柄校验结束后关闭句柄，目录创建、探针、锁和 SQLite 仍按路径字符串打开 |
| R2-04 文档与证据同步 | **已完成** | 历史 JSON 标记、新 JSON、16 份脱敏日志、STATUS/计划/任务文档和 PR 描述已同步 |

### R2-01 的额外测试说明（非代码逻辑回退）

新测试确实启动真实独立进程，并验证“主库存在 + 活动 WAL + 等待者调用锁后处理函数”时 canary、migration 和 integrity 均正确。

但当前 waiter 在调用 `InitializationLock::acquire()` **之前**就写出 `b-inspected` 信号；creator 只等待该信号，然后创建数据库并释放锁。操作系统调度可能让 waiter 在写信号后暂停，直到 creator 释放锁后才真正第一次尝试加锁。因此日志能证明锁后处理函数面对活动 WAL 时行为正确，但不能严格证明 waiter 在 creator 创建数据库时已经观察到锁竞争/进入等待状态。

建议增加“waiter 的非阻塞 try_acquire 明确返回 None 后再发信号”的同步，或增加测试专用锁竞争观察点；最好让 waiter 走完整 `Database::initialize()` 路径，而不只直接调用私有 `open_or_create_after_lock()`。该项是 P2 测试证据精度问题，不推翻当前锁后处理逻辑。

## 3. 新增问题 R3-01：D:\\ 根卷作为信任锚，但自身未独立验证

**等级：P1（必须补齐验证）**

**代码位置：**
- `crates/workmanager-core/src/portable_paths.rs`：`d_drive_volume_identity()`，约第 948 行。
- `ensure_volume_is_d_volume()`，约第 960 行。
- `validate_real_storage_path()`，约第 1035 行。
- `mount_point_volume_guid()` 与 `query_dos_device_target()` 目前位于测试模块中，约第 1379、1405 行；没有参与生产路径校验。

**当前实现：**

`d_drive_volume_identity()` 直接对 `D:\\` 打开句柄并读取其 `VOLUME_NAME_GUID / VOLUME_NAME_NT`。随后目标目录句柄的卷身份只与这个 D 根句柄身份比较。

这证明了“目标和当前 D:\\ 根目录句柄指向同一卷”，但没有独立证明“当前 D:\\ 根目录本身就是预期的 D 盘本地卷，而不是一个指向 C 盘的 DOS 设备别名/同卷别名”。

本轮代码已经有一个重要线索：SUBST Q:→C: 测试中，目标句柄卷身份与 C 卷相同，而 `GetVolumeNameForVolumeMountPointW(Q:\\)` 返回失败；但该 API 仅在测试辅助函数中调用，没有用于生产校验 D 根。现有测试的 D 根仍是真实独立 D 盘，因此没有覆盖“信任锚 D:\\ 自身被别名化”的情况。

**为什么这是问题：**

卷身份比较的可信度取决于参考卷身份本身。如果参考根目录没有被独立验证，目标与参考根身份相同并不足以证明目标不是 C 卷。当前 `GetDriveTypeW` 只提供固定盘/可移动盘/网络盘等类型分类，不等价于验证 D: 是真实卷挂载点，也不证明 D: 与 C: 是不同卷。

本审计不把“D:→C: 一定能够绕过”当作已证实事实；但当前实现和测试尚未证明它一定会被拒绝，因此不能把真实卷边界认定为完全通过。

**修复与测试要求：**

1. 生产代码独立验证 D 根卷：
   - 对 `D:\\` 调用 `GetVolumeNameForVolumeMountPointW`，要求成功取得卷 GUID；
   - 将该 GUID 与 D 根句柄的 `VOLUME_NAME_GUID` 比较，不一致或 API 失败即 fail-closed；
   - 评估并使用 `QueryDosDeviceW("D:")` 识别 SUBST 的 `\\??\\C:\\...` 映射，不能把它当作普通物理卷；
   - 若产品策略明确禁止 C 卷作为 D 盘存储，还应比较 D 根 GUID 与 C 根 GUID，拒绝两者相同的情形；
   - 保留 D 根卷类型白名单和目标句柄卷身份比较。
2. 将当前只在测试模块中的卷挂载点查询逻辑提取为可复用生产函数。
3. 增加测试：
   - 正常 D 物理卷：允许，句柄 GUID 与挂载点 GUID 一致；
   - SUBST Q:→C: 作为注入的“候选 D 根”：必须在信任锚验证阶段拒绝，不能仅靠目标路径最终盘符检查碰巧拒绝；
   - D 根与 C 根卷身份相同：按 D-only 策略拒绝；
   - 正常 D 与 C 为不同卷：允许。
4. 本机无法把真实 D: 改成 SUBST 时，继续使用可注入参考根的 helper + Q: 实机夹具证明逻辑，并明确标记 D:→C: 未实机验证；不得伪造实机结果。

Microsoft API 依据：
- [GetFinalPathNameByHandleW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew)：返回句柄最终路径，可选择 DOS、卷 GUID 或 NT 设备路径。
- [GetVolumeNameForVolumeMountPointW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumenameforvolumemountpointw)：从驱动器号或挂载目录取得卷 GUID。
- [SUBST 命令](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/subst)：把一个路径关联到驱动器号，说明 DOS 驱动器号本身不必然代表独立物理卷。

## 4. R2-03 TOCTOU：未修复，用户已接受残余风险并延期（DEC-029）

代码和返工报告对残余风险的描述一致：`open_path_handle()` 的句柄在真实路径/卷身份校验后关闭，后续 `create_dir_all`、写探针、初始化锁和 SQLite 仍通过路径字符串操作。当前前置校验、创建后复验和数据库初始化前复验只能缩小窗口，不能把检查与实际写入绑定到同一目录对象。

因此：
- 不得宣称“任何情况下都不会写入 C 盘”；
- 不得把 TOCTOU 标记为已修复；
- 按用户 DEC-029，TOCTOU 不在 T1-01 内彻底加固，转入[独立安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)；
- 该用户风险接受只覆盖 TOCTOU，不覆盖 R3-01/R3-02；R3-01 P1 和 R3-02 P2 仍需处理并重新独立审计；
- 在剩余问题关闭并复审通过前，不得合并 PR 或开始 T1-02。

### 技术范围判断

句柄相对目录创建可使用 Windows 的目录句柄与相对打开机制；但 SQLite 的文件打开、删除、锁和 WAL shared-memory 操作由 VFS 层负责。SQLite 官方 VFS 文档说明，自定义 VFS 不只是替换一次 open，而要实现文件打开、访问、删除、读写、锁等 OS 接口。

因此，不建议让开发代理未经设计评审就仓促编写 custom SQLite VFS。若用户要求在 T1-01 内关闭该风险，应先提交独立技术设计/PoC，明确：
- 目录链如何从可信 D 根句柄开始逐级打开，如何拒绝重解析点；
- 如何将 SQLite 主库、WAL、SHM、journal、锁和删除操作全部绑定到已验证目录对象；
- WAL 锁、共享内存、崩溃恢复和原子替换如何保持 SQLite 语义；
- 如何用并发 Junction 替换/oplock 测试证明目标卷零写入。

参考：[SQLite VFS 官方接口](https://www.sqlite.org/vfs.html)、[NtCreateFile RootDirectory 相对路径语义](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)。

## 5. 证据审查

已在 GitHub 找到：
- 返工后机器可读 JSON，明确状态为 `rework-blocked`，并把 TOCTOU 记录为 `open-blocking`；
- R2-01、R2-02、R2-03 专项日志；
- workspace 测试日志：62 passed / 0 failed / 0 ignored；
- Release 构建日志与 SHA-256 记录；
- 便携验证、异常注入、真实 WebView2 CDP 日志与截图；
- 历史证据文件保留并标记 `historical: true`。

报告中的 Release SHA-256 为：
`849E803D2456B28DF8BABFE201E187FB0FC45B7104A5E2CD2FD34B1D4366019E`

以上证据可复核，但仍是开发代理机器上的执行日志；本轮没有 GitHub Actions 状态检查，也没有独立 Windows 重放。

## 6. 最终状态

| 项目 | 结论 |
|---|---|
| R2-01 代码逻辑 | 修复成立 |
| R2-01 测试确定性 | 需要补强（P2） |
| R2-02 正式目录保护 | 修复成立 |
| R2-03 目标卷身份比较 | 部分成立；新增 R3-01 P1 信任锚验证缺口 |
| R2-03 TOCTOU | 未解决；用户按 DEC-029 接受残余风险并延期至 Issue #2，不作为 T1-01 单独阻塞项 |
| R2-04 证据同步 | 完成 |
| T1-01 | **返工中；R3-01 P1 与 R3-02 P2 待处理；TOCTOU 按 DEC-029 接受并延期** |
| PR #1 | Open，不合并 |
| main | 不修改 |
| T1-02 | 不得开始 |

**下一步门禁：** 用户已明确按 DEC-029 接受 TOCTOU 残余风险，完整加固转入[Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未经另行授权不得开始。T1-01 继续处理 R3-01 P1 和 R3-02 P2；两项修复后重新独立审计。旧机器可读 evidence JSON 中的 `open-blocking` 反映用户决策前的证据生成时点，不代表 DEC-029 之后的当前风险处置状态。


## 7. 用户后续决策：接受 TOCTOU 残余风险（DEC-029，2026-11-18）

用户明确选择“接受现有残余风险”，其含义限定为：

1. 接受当前路径校验与后续目录创建、写探针、初始化锁、SQLite 按路径打开之间仍存在理论 TOCTOU 竞争窗口。
2. 不要求在 T1-01 内实施完整句柄相对改造或 custom SQLite VFS。
3. 将完整技术设计、PoC、实现和竞态测试转入[独立安全加固 Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。该 Issue 仅建立跟踪，未授权自动开始实施。
4. 该风险未被修复；当前不能作出“任何情况下都不会写入 C 盘”的保证。禁止静默回退 C 盘、对已检测边界违规 fail-closed 的要求不变。
5. 本决定不覆盖 R3-01 P1 与 R3-02 P2。它们仍需处理并重新独立审计；在此之前 T1-01 不得验收、PR #1 不得合并、T1-02 不得开始。

第三轮审计结论仍保留为当时的审计结果；DEC-029 只改变 TOCTOU 风险的处置状态，不改变代码事实、测试事实或审计发现。
