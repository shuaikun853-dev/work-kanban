# T1-03 证据索引（第六轮定向补正后）

本目录保存 T1-03「工作事项快速创建和待安排区域」的开发自测证据。所有测试数据均为虚构内容；
本轮（2026-11-27，第五轮审计 P1–P4 + B1–B5 定向补正）UAT 运行目录为专用测试根目录下的一次性新目录
`<uat-root>\t1-03-ui-r6f-20261127-071753`，未触碰正式运行目录 `D:\WorkManager`，
未使用真实用户工作数据；第三、四、五轮证据均未被覆盖。

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
| `evidence/round5/t1-03-uat-path-evidence.json` | **本轮**路径安全专项实测证据：**115 项检查，FAILED=0，SKIPPED=1**；第三轮 60 项 + 第四轮 31 项全部保留（`evidence.round3ChecksPreserved` / `evidence.round4NewChecksPresent`），本轮新增 21 项全部存在（`evidence.round5NewChecksPresent`）；含 F1 证据写入边界/身份/硬链接/悬空 Junction 与 F2 沙箱入口原生检查（含真实悬空 Junction、`Test-Path=False` 路径）证据 |
| `evidence/round5/t1-03-ui-evidence.json`、`t1-03-min-window-evidence.json`、`t1-03-persistence-evidence.json` | 本轮重新执行的 Release UI/IPC **84**、最小窗口 **12**、重启持久化 **17** 项实测断言（已脱敏） |
| `evidence/round5/t1-03-ui-orchestration.json`、`t1-03-prerequisite.json`、`t1-03-db-after-main.json`、`t1-03-db-after-restart.json` | 本轮 E2E 编排汇总（两次真实关闭退出码 0/0）、重启前 IPC 数据快照、两次数据库只读探针（25 项断言）；已脱敏为 `<uat-root>` / `<repo-root>` 占位 |
| `evidence/round5/round5-verification-summary.json` | **第五轮机器可读汇总**：F1/F2 修复范围、路径安全 115 项、Red 证据、质量门禁、Release E2E 84/12/17/25、Release EXE 重建说明、限制与遗留风险；**B2 已修正时间戳语义**（真实汇总组装时间与证据/修复提交时间分开；历史值保留） |
| `evidence/round6-remediation/round6-verification-summary.json` | **第六轮机器可读汇总**：P1–P4 修复范围、路径安全 128 项、可复现 Red 证据、质量门禁、Release E2E 84/12/17/25、B1–B5 修正、提交数（25/27/28/30）、遗留风险 |
| `evidence/round6-remediation/round6-remediation-notes.md` | **第六轮修复与证据说明**：根因/修复位置、TDD Red→Green、Red 探针复现方法、B2/B4/B5 修正、E2E 尝试记录、Skill 实际使用、遗留风险 |
| `evidence/round6-remediation/red/` | **第六轮 Red 证据**（修复前基线 `e8205ca`，真实 Windows 文件系统对象）：`round6-red-evidence.json` + `round6-red-command-output.sanitized.log.txt`；F1 越界写入/覆盖 Canary、F2 穿过 Junction 删除外部链接、P4 部分删除语义失真 |
| `evidence/round6-remediation/green/` | **第六轮 Green 证据**（与本轮修复后真实执行）：`t1-03-uat-path-evidence.json`（128 项）、最终通过轮次 7 个脱敏 E2E JSON、`round6-e2e-command-output.sanitized.log.txt`；与 Red 证据分开保存 |
| `evidence/release-regression-portable-summary.json` | 继承 T1-01 便携验证证据（第二轮提交版本；第四轮重新执行结果 TOTAL=106 PASS=90 FAIL=0 WARN=1，见 `round4/round4-verification-summary.json`） |
| `evidence/release-regression-faults-summary.json` | 继承 T1-01 异常注入验证证据（第二轮提交版本；第四轮重新执行结果 TOTAL=73 PASS=64 FAIL=0，见 `round4/round4-verification-summary.json`） |
| `evidence/release-regression-t1-02-ui-orchestration.json` | 继承 T1-02 Release UI E2E 编排证据（第二轮提交版本；第四轮重新执行主检查 73/73、最小窗口 12/12、关闭退出码 0） |
| `test-counts.txt` | 第六轮测试数量、环境、数据库探针关键事实速查 |
| `SANITIZATION.md` | 证据脱敏策略（含第六轮 B5 `<uat-root>` 口径修正与扫描结果）、旧提交服务端暴露与 GitHub Support 清理材料（P2-01） |

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

# 3. 第六轮 Red 探针（修复前基线 e8205ca，真实文件系统对象；输出 Red 证据）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\probe-round6-red.ps1

# 4. UAT 输出目录路径安全专项测试（第六轮：F2 跟踪链接/清理顺序 + F1 身份 + P3 摘要守卫 + P4 语义）
#    本轮证据写入新文件，不覆盖第三/四/五轮证据：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1 `
    -EvidencePath docs\testing\reports\T1-03-assets\evidence\round6-remediation\green\t1-03-uat-path-evidence.json

# 5. Release 构建
npm run tauri build -- --no-bundle

# 6. T1-03 Release E2E（主检查 → 最小窗口 → 真实关闭 → DB 探针 → 重启持久化 → 关闭）
#    输出目录必须位于专用测试根目录之下，且必须是新的/空目录（P3-02/F1）；最终摘要经原生守卫写入。
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1 `
    -OutputDir <uat-root>\t1-03-ui-r6-<timestamp>

# 7. 继承回归
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
```

## 重要说明

- 本证据为**开发自测**证据，不构成第六轮独立审计结论或用户验收结论。
- 详细分析、需求映射与遗留风险见 [`../T1-03-REPORT.md`](../T1-03-REPORT.md)。
- **P1 / F2（第六轮）：** 沙箱清理先验证全部跟踪链接（只允许已确认沙箱的直接子项，记录对象卷序列号 +
  File ID + reparse tag）；删除任何对象之前扫描整个沙箱，出现非登记重解析点立即 fail closed；只删除身份
  精确匹配的已登记链接对象并原生复验消失；删除后再次扫描残余重解析点；再次复验沙箱身份后才执行逐条目
  安全递归删除。不支持任意嵌套链接，无法确认安全的嵌套路径直接拒绝。
- **P2 / F1（第六轮）：** 证据写入必须提供启动时记录的证据根目录身份（缺失/身份变化均拒绝写）；
  隔离 `EvidenceRoot` 仅保留为专项测试内部注入能力并需显式传入身份，不是生产 CLI 参数。
- **P3（第六轮）：** `verify-t1-03-ui.ps1` 最终摘要写入前重新执行原生路径检查并复验输出目录身份；
  输出目录被替换为 Junction / 身份变化时拒绝写入。**DEC-029 TOCTOU 残余风险仍存在，未消除。**
- **P4（第六轮）：** 递归删除结果区分 `recursiveDeleteStarted` / `recursiveDeleteCompleted` /
  `recursiveDeletePartial`；删除开始后异常返回 `recursiveDeleteFailed` 并如实说明可能已部分删除。
- **F1/F2（第四、五轮，历史）：** 测试根目录信任锚、证据写入边界、沙箱入口原生检查仍保留并通过；
  其中清理删除失败由 `FaultHook` 受控注入（未修改 Windows ACL、未实测 `Access Denied`）。
- **TOCTOU 与限制：** 未执行 Windows ACL `Access Denied` 测试；Symbolic Link 场景 SKIP；DEC-029 /
  Issue #2 的并发替换 TOCTOU 风险未消除，本轮不作已消除声明。
- **P2-01 尚未关闭：** 当前 T1-03 证据目录、当前分支增量历史与 PR #8 文本已完成脱敏复核（具体机器标识 0 命中、
  固定测试根原始名称 0 命中）；但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 的 9 个原始日志仍可通过
  GitHub API 读取，GitHub 服务端清理需由仓库所有者提交 Support 工单。**不得把分支历史清理等同于服务端清理完成**；
  脱敏策略、扫描结果、Support 材料与遗留风险见 [`SANITIZATION.md`](SANITIZATION.md)。
- **证据时效：** 本轮重新执行了路径安全专项（128 项）与 T1-03 Release E2E，并新增可重复执行的 Red 探针；
  本轮证据位于 `evidence/round6-remediation/`（Red/Green 分开），第三、四、五轮证据保持原样。
  19 张本轮截图未复制入仓（产品 UI 未修改，第三/四轮截图仍有效），截图保留在机器本地 UAT 目录。
  产品业务代码未变，Release EXE 沿用第五轮按本分支 schema 3 重建的构建（10,352,128 字节，
  SHA-256 `f46c9b0c…2b68`）。
- Symbolic Link 专项受当前进程权限限制（非管理员、未启用开发者模式，缺少 `SeCreateSymbolicLinkPrivilege`）
  无法创建真实目录符号链接；该场景在路径安全专项中明确记录为 **SKIP（不计 PASS）**，Junction 场景全部真实创建并验证拒绝。
