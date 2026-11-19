# T1-02 独立审计报告

**审计日期：** 2026-11-18  
**审计对象：** PR #7 / task/T1-02-project-management  
**审计基准 HEAD：** a0aec0032cf3c3ef3ab87513ae93f7a4f4351f69  
**审计结论：** **未通过，进入小范围返工**  
**阻塞任务：** T1-02 不得标记验收完成；T1-03 不得开始；PR #7 不得合并。

## 1. 审计范围

核对 PR #7 相对 main 的代码与文档、PRD、技术设计、DEC、UI 设计规范、T1-02 任务说明，以及 SQLite migration、Rust Core、typed Tauri IPC、Svelte UI、自动化测试、Release 实际运行和 GitHub 交付证据。

审计不改变 PRD、DEC 决策或 UI 基线，也不修改 main。

## 2. 独立实测结果

以下结果由审计环境直接执行，不采用开发代理报告作为唯一依据。

| 验证项 | 实际结果 |
|---|---|
| cargo test --workspace --quiet | **90 passed / 0 failed，退出码 0** |
| cargo fmt --all -- --check | **通过，退出码 0** |
| cargo check --workspace --all-targets | **通过，退出码 0** |
| npm run check | **0 errors / 0 warnings，退出码 0** |
| npm run build | **成功，退出码 0** |
| Release EXE | 10,230,272 bytes |
| Release SHA-256 | DF4469EA067DEE39E10E49F0592FD4A9DAB076F4186FF3E8CF60F8F72EABB7E8 |
| verify-release-portable.ps1 | **106 项：PASS 90 / FAIL 0 / WARN 1 / INFO 15** |
| verify-release-faults.ps1 | **73 项：PASS 64 / FAIL 0 / WARN 0 / INFO 9** |
| Release UI/IPC 第一次独立运行 | 失败：等待“项目空状态”超时 |
| Release UI/IPC 立即重跑 | **73/73 + 最小窗口 12/12 PASS** |
| Release UI/IPC 随后连续 3 次 | **3/3 PASS**；每次主检查 73/73、最小窗口 12/12、CSP 0、无未捕获异常 |

### 2.1 关于第一次 UI E2E 失败

第一次独立运行在 projects.emptyState 阶段出现：

Timed out waiting for: projects empty state

该次运行随后检查测试数据库，确认 projects 表存在且项目数量为 0，未发现产品数据污染。

立即重新执行后通过，随后连续 3 次完整 Release UI E2E 均通过。因此当前证据不足以认定为产品功能缺陷，更接近一次测试/运行环境时序抖动。

但该事件必须保留在审计记录中，不得只保留后续 PASS 结果。建议后续将空状态等待逻辑做成更明确的页面状态等待。

## 3. 已确认通过的功能审计项

### 3.1 Migration / Core

- 0002 migration 将 schema version 1 升级到 2；
- projects 表字段符合当前 PRD / 技术设计；
- T1-01 的 0001 migration 历史未被修改；
- 项目创建、查询、编辑、归档均由 Rust Core 负责；
- 写操作使用 IMMEDIATE 事务并处理失败回滚；
- 归档是 UPDATE，不删除项目记录；
- 已归档项目保持只读并保留在列表；
- 项目 ID 不依赖前端数组下标；
- 项目名称最小必要校验符合当前已确认规则。

### 3.2 IPC / 安全边界

- 项目操作均通过 typed Bridge / DTO；
- 请求 DTO 拒绝未知字段；
- Tauri 命令为 async + spawn_blocking；
- SQLite Connection 不进入前端；
- 未发现任意 SQL IPC；
- Release 真实调用 execute_sql 得到 Command not found；
- T1-01 诊断功能仍可用。

### 3.3 UI / Release

- AppShell / Sidebar / navigation 实际 Release 渲染正常；
- 项目 loading / empty / create / edit / archive / error / long-name / archived 状态均可通过真实 Release UI 验证；
- 860×640 最小窗口无横向溢出，创建弹窗完整可见；
- 最大化/还原真实窗口 API 验证通过；
- Release CSP 违规为 0；
- Release 页面无未捕获异常；
- 未发现网页站点式布局或未经授权的额外仪表盘模块。

## 4. 审计发现

### P2-01：新 UI 仍存在 Design Token 规范之外的原始颜色值

**状态：未修复，阻塞 T1-02 审计通过。**

UI 设计规范要求颜色统一由 Design Tokens 提供；但本次代码中仍存在以下原始颜色：

- src/app/Sidebar.svelte:123 — rgba(0, 122, 255, 0.07)
- src/lib/features/projects/ConfirmArchiveDialog.svelte:98 — rgba(15, 23, 42, 0.28)
- src/lib/features/projects/ConfirmArchiveDialog.svelte:131 — #f3c6c1
- src/lib/features/projects/ProjectFormDialog.svelte:144 — rgba(15, 23, 42, 0.28)
- src/lib/features/projects/ProjectFormDialog.svelte:214 — #f3c6c1
- src/lib/features/projects/ProjectsPage.svelte:271 — #f3c6c1
- src/lib/ui/components/Button.svelte:76 — #ffffff
- src/lib/ui/components/Button.svelte:108 — rgba(255, 255, 255, 0.45)
- src/lib/ui/components/Button.svelte:109 — #ffffff

这不是当前视觉结果错误，而是设计系统实施不完整，会造成后续主题、状态颜色和组件复用时的语义分散。

**要求：**

1. 不改变当前视觉效果；
2. 将上述颜色全部收敛到语义 Design Tokens；
3. 不修改 DEC-030 / DEC-031 / DEC-032；
4. 不通过删除组件或降低视觉验证标准解决；
5. 增加至少一项静态检查，确保新的 Feature/UI 代码不得再次出现 raw hex/rgb/rgba 颜色；
6. token 定义本身可以保留原始色值，禁止的是组件层散落 raw color；
7. 完成后重新执行完整回归和 Release UI 验证。

### P3-01：Tauri lib.rs 存在过期注释

src-tauri/src/lib.rs 中仍有“目前只有数据库健康检查”之类的历史描述，但当前已经存在项目 IPC。

不影响运行，但会误导后续开发和审计。应在本次返工顺手修正，不扩大架构范围。

### P3-02：Release UI E2E 首次运行出现一次空状态等待抖动

第一次运行失败，随后立即重跑并连续 3 次通过。

当前不作为产品功能失败处理，但要求在返工后保留该事件记录，并考虑将项目空状态等待改成更明确的页面初始化状态等待。

## 5. 已接受 / 非本轮阻塞风险

- DEC-029：路径校验与实际路径写入之间的 TOCTOU 已由用户明确接受并延期至 Issue #2；
- 普通 SQLite 未加密：DEC-028 已确认；
- 备份恢复策略仍待用户确认；
- 正式 D:\WorkManager 实跑、ProcMon、物理拔盘等属于阶段 6；
- 应用级单实例属于 T6-07；
- T1-03 / T1-04 / T1-05 未实现且本次没有越界实现。

## 6. 审计门禁

在 P2-01 修复前：

- T1-02 = **返工**
- PR #7 = **保持 Open**
- 不合并 PR #7
- 不修改 main
- 不开始 T1-03
- 不标记 T1-02 验收完成

P2-01 修复后必须重新执行：

cargo fmt --all -- --check  
cargo check --workspace --all-targets  
cargo test --workspace  
npm run check  
npm run build  
npm run tauri build -- --no-bundle  
verify-release-portable.ps1  
verify-release-faults.ps1  
Release UI/IPC + 最小窗口 E2E

并重新提交修复报告与机器可读证据。

## 7. 审计结论

T1-02 的功能实现、数据库、Core、IPC、Release 和 UI 主流程整体成立，本次独立实测没有发现 P0/P1 产品功能问题。

但 P2-01 属于已确认 UI 设计系统的实施门禁，不能在未修复的情况下直接标记“审计通过”。

**因此当前结论：T1-02 独立审计未通过，进入小范围返工。**

修复完成并重新审计通过后，才能将状态改为“待用户验收”；用户验收完成后才能合并 PR #7，并在此之后启动 T1-03。
