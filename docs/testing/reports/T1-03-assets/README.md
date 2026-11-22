# T1-03 证据索引（第四轮 F1/F2 定向修复后）

本目录保存 T1-03「工作事项快速创建和待安排区域」的开发自测证据。所有测试数据均为虚构内容；
第四轮 UAT 运行目录为专用测试根目录下的一次性新目录 `<uat-root>\t1-03-ui-r4-20261120-181549`
（D 盘隔离目录），未触碰正式运行目录 `D:\WorkManager`，未使用真实用户工作数据；第三轮 UAT 证据
（`<uat-root>\t1-03-ui-r3-20261120-081100`）与第三轮证据文件均**未被覆盖**。

## 内容

| 路径 | 内容 |
|---|---|
| `screenshots/` | **第三轮目录中的 19 张**真实 Release WebView2 截图：正常窗口、最小窗口 860×640、loading/empty/error、快速创建、项目选择器、归档竞态错误、归档项目历史关联、加载失败/契约违规、创建成功但刷新失败/恢复（P3-01）、长标题、关闭重开后持久化。第三、四轮均未修改产品代码与 UI，第四轮 Release E2E 已重新执行并通过同名场景 |
| `evidence/t1-03-ui-evidence.json` | 第三轮实测主 UI/IPC **84 项断言**（含每项 PASS/FAIL 与 detail）、页面异常、CSP 违规、确定性等待与截图清单 |
| `evidence/t1-03-min-window-evidence.json` | 第三轮实测最小窗口 **12 项断言** + 关闭按钮点击记录 |
| `evidence/t1-03-persistence-evidence.json` | 第三轮实测关闭重开持久化 **17 项断言** |
| `evidence/t1-03-uat-path-evidence.json` | **第三轮** UAT 输出目录安全专项 **60 项断言**（P3-02 第三轮：保留原有 23 项 + 37 项 Windows 原生 reparse point / 路径形状 / 无副作用检查；1 项 Symbolic Link 场景因当前进程无创建权限明确记录 SKIP，不计 PASS） |
| `evidence/t1-03-ui-orchestration.json` | 第三轮 E2E 编排汇总：EXE 路径/大小/SHA-256、各阶段退出码与断言计数、数据库探针路径、截图清单、pass |
| `evidence/t1-03-prerequisite.json` | 第三轮重启阶段之前的真实 IPC 数据快照（虚构工作事项与项目） |
| `evidence/t1-03-db-after-main.json` | 第三轮第一次真实关闭后的数据库只读探针（schema/完整性/行数/状态分布/外键） |
| `evidence/t1-03-db-after-restart.json` | 第三轮重新启动并再次关闭后的数据库只读探针（持久化后） |
| `evidence/round3-verification-summary.json` | 第三轮机器可读汇总（保留为历史证据，不覆盖）：质量门禁、路径安全 60 项、Release E2E 84/12/17/25、继承回归、EXE SHA-256、P2-01 当时状态与遗留风险 |
| `evidence/round4/t1-03-uat-path-evidence.json` | **第四轮**路径安全专项实测证据：**93 项检查，FAILED=0，SKIPPED=1**；第三轮 60 项全部保留（`evidence.round3ChecksPreserved`），第四轮新增 31 项全部存在（`evidence.round4NewChecksPresent`）；含 F1 信任锚/真实入口无副作用子进程证据与 F2 清理 fail-closed 故障注入证据 |
| `evidence/round4/t1-03-ui-evidence.json`、`t1-03-min-window-evidence.json`、`t1-03-persistence-evidence.json` | 第四轮重新执行的 Release UI/IPC **84**、最小窗口 **12**、重启持久化 **17** 项实测断言 |
| `evidence/round4/t1-03-ui-orchestration.json`、`t1-03-prerequisite.json`、`t1-03-db-after-main.json`、`t1-03-db-after-restart.json` | 第四轮 E2E 编排汇总（含两次真实关闭退出码 0/0）、重启前 IPC 数据快照、两次数据库只读探针（25 项断言） |
| `evidence/round4/screenshots/` | **第四轮**重新执行 E2E 生成的 19 张真实 Release WebView2 截图（第四轮 UAT 目录实测；与第三轮同名场景） |
| `evidence/round4/round4-verification-summary.json` | **第四轮机器可读汇总**：F1/F2 修复状态、路径安全 93 项、质量门禁退出码与计数、Release E2E 84/12/17/25、继承回归 106/73/T1-02、EXE SHA-256、第四轮分支提交数/资产数/PNG 数/PR 正文与评论扫描、P2-01 服务端清理未完成状态与遗留风险 |
| `evidence/release-regression-portable-summary.json` | 继承 T1-01 便携验证证据（第二轮提交版本；第四轮重新执行结果 TOTAL=106 PASS=90 FAIL=0 WARN=1，见 `round4/round4-verification-summary.json`） |
| `evidence/release-regression-faults-summary.json` | 继承 T1-01 异常注入验证证据（第二轮提交版本；第四轮重新执行结果 TOTAL=73 PASS=64 FAIL=0，见 `round4/round4-verification-summary.json`） |
| `evidence/release-regression-t1-02-ui-orchestration.json` | 继承 T1-02 Release UI E2E 编排证据（第二轮提交版本；第四轮重新执行主检查 73/73、最小窗口 12/12、关闭退出码 0） |
| `test-counts.txt` | 第四轮测试数量、环境、数据库探针关键事实速查 |
| `SANITIZATION.md` | 证据脱敏策略、第四轮扫描范围/结果、旧提交服务端暴露与 GitHub Support 清理材料（P2-01） |

## 复现命令

```powershell
# 1. 质量门禁
cargo fmt --all -- --check
cargo check --workspace --all-targets
cargo test --workspace
npm run check
npm run build
git diff --check

# 2. Bridge DTO 严格契约专项测试
node --test scripts\quality\work-item-bridge.test.mjs

# 3. UAT 输出目录路径安全专项测试（第四轮：测试根目录信任锚 + 清理 fail-closed）
#    第四轮证据写入新文件，不覆盖第三轮证据：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1 `
    -EvidencePath docs\testing\reports\T1-03-assets\evidence\round4\t1-03-uat-path-evidence.json

# 4. Release 构建
npm run tauri build -- --no-bundle

# 5. T1-03 Release E2E（主检查 → 最小窗口 → 真实关闭 → DB 探针 → 重启持久化 → 关闭）
#    输出目录必须位于专用测试根目录之下，且必须是新的/空目录（P3-02/F1）。
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1 `
    -OutputDir <uat-root>\t1-03-ui-r4-<timestamp>

# 6. 继承回归
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
```

## 重要说明

- 本证据为**开发自测**证据，不构成第四轮独立审计结论或用户验收结论。
- 详细分析、需求映射与遗留风险见 [`../T1-03-REPORT.md`](../T1-03-REPORT.md)。
- **F1（第四轮）：** 测试脚本在任何写操作之前用 Windows 原生句柄验证真实测试根目录（存在、真实目录、
  全部已存在祖先组件、最终路径、卷身份、正式目录排除），缺失或身份无法确认时 fail closed 且不自动
  创建；用真实 Junction 把测试根替换为外部 Canary 目录启动真实入口子进程，验证任何写操作之前拒绝执行、
  Canary 内容/目录结构不变、不创建沙箱。
- **F2（第四轮）：** 清理前复验沙箱身份、逐个删除并复验跟踪链接、扫描未预期 reparse point、再次复验身份；
  任一条件不满足立即停止整个沙箱递归删除，保留现场并输出可定位 WARN/FAIL。删除失败由 `FaultHook` 在
  `beforeLinkDelete` 阶段抛出确定性异常，属于受控故障注入；未修改 Windows ACL，也未实际测试 ACL `Access Denied`。
  链接重建、未跟踪链接、身份替换与失败后 Canary 复检使用真实文件系统对象验证。
- **P2-01 尚未关闭：** 当前 T1-03 证据目录、当前分支增量历史与 PR #8 文本已完成脱敏复核（具体机器标识 0 命中）；
  但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 的 9 个原始日志仍可通过 GitHub API 读取，
  GitHub 服务端清理需由仓库所有者提交 Support 工单。**不得把分支历史清理等同于服务端清理完成**；
  脱敏策略、扫描结果、Support 材料与遗留风险见 [`SANITIZATION.md`](SANITIZATION.md)。
- **TOCTOU 剩余风险：** 信任锚/路径校验与后续写操作之间仍存在 TOCTOU 并发替换窗口，未消除
  （DEC-029 / Issue #2 仍适用），详见测试报告。
- **证据时效：** 第四轮重新执行了 T1-03 Release E2E、路径安全专项与三类继承回归；第四轮证据位于
  `evidence/round4/`，第三轮证据文件保持原样。继承回归的详细证据 JSON 沿用第二轮提交版本，
  第四轮重新执行的计数与退出码记录在 `evidence/round4/round4-verification-summary.json` 与测试报告中。
  产品代码未变，Release EXE 与第二/三轮一致（10,352,128 字节，SHA-256 `3f12bbce…fa9e3`）。
- Symbolic Link 专项受当前进程权限限制（非管理员、未启用开发者模式，缺少 `SeCreateSymbolicLinkPrivilege`）
  无法创建真实目录符号链接；该场景在路径安全专项中明确记录为 **SKIP（不计 PASS）**，Junction 场景全部真实创建并验证拒绝。
