# T1-03 第六轮定向补正 — 证据与修复说明（round6-remediation）

**任务 ID：** T1-03
**轮次：** 第六轮定向补正（按第五轮独立审计报告做最小范围修复，不重新开发 T1-03）
**第五轮独立审计基准：** `6ddae47dd0721d58d5cb11f55e527fc162cedbe9`（PR #8 本轮前 head）
**上一轮（第五轮）修复提交：** `af2421e9207f7b9ac185b0d29c3a98f80b5eb11a`
**本轮修复提交：** `e3bb86b30772159219a8eb16b90e55f3c69f4d59`
**当前 main（同步远端时）：** `9171fe35a7e080097991f547efe37ff5a504257c`（PR base 落后于 main 的问题本轮不处理）
**本地开发分支：** `task/T1-03-quick-create-pending-r4`（= 审计基准）；以非强制快进方式推送到 PR 分支 `task/T1-03-quick-create-pending`
**数据边界：** 只使用虚构文件、Canary 和专用测试目录；未读取/写入真实工作数据；未触碰正式目录 `D:\WorkManager`。

---

## 1. 本轮修复范围（只修复有真实证据的问题）

本轮只处理第五轮审计列出的 P1–P4 与交付证据问题 B1–B5；**未修改 T1-03 产品业务代码**（Rust / 前端 / 迁移 / 业务 UI 未变）、未修改 T1-04/T1-02、未修改 PRD/TECHNICAL_DESIGN/DECISIONS 业务决策、未新增依赖、未重写 Git 历史、未强制推送。

| 项 | 根因 | 修复 |
|---|---|---|
| **P1 / F2** 跟踪链接穿过未跟踪 Junction 删除外部链接 | `Invoke-T103FailClosedSandboxCleanup` 先删除 `TrackedLinks`、后扫描沙箱重解析点；且只做“字面路径在沙箱内”判断。`sandbox\evil` 为指向沙箱外 `external` 的真实 Junction 时，`sandbox\evil\victim-link` 字面在沙箱内，实际解析到沙箱外，删除发生在扫描之前 | 新顺序：①沙箱身份复验 + 沙箱到盘符根父目录链原生校验；②**先验证全部轨迹链接**（只允许沙箱直接子项，记录链接对象自身的卷序列号 + File ID + reparse tag，父链/嵌套不明确一律 `trackedLinkNotDirectChild` fail closed）；③**删除任何对象之前扫描整个沙箱**，除已登记链接外任何重解析点 → `unexpectedReparsePoint` 停止；④只删除身份精确匹配的已登记对象（删除前 native 复核 File ID/卷/tag），删除后 native 复核消失；⑤删除后再扫描，残余 → `residualReparsePoint`；⑥再次复验沙箱身份；⑦才执行逐条目安全递归删除、结束后确认沙箱消失 |
| **P2 / F1** 证据写入身份校验不完整 | `ExpectedRootIdentity` 为可选参数，实际写入缺少身份记录时仍可继续；`EvidenceRoot` 可由内部参数指定任意目录，函数级不变量与注释不一致 | `Write-T103EvidenceFile` 现在**强制**要求启动时记录的证据根目录身份（缺失 → 拒绝写入）；`Assert-T103EvidenceWritePath` 新增 `-RequireRootIdentity` 供写入路径强制；候选证据目录身份与启动记录不一致 → 拒绝。隔离 `EvidenceRoot` 仅保留为专项测试的内部注入能力，并必须显式传入该目录身份记录；不是生产 CLI 参数。默认证据根仍由测试入口在首个写操作前记录 |
| **P3** `verify-t1-03-ui.ps1` 最终摘要写入未走安全守卫 | 原第 420–421 行直接 `Set-Content` 写 `t1-03-ui-orchestration.json`，写入前未复验输出目录身份 | 创建 UAT 输出目录后记录其身份（卷序列号 + File ID + 真实最终路径）；新增 `Write-T103VerifiedOutputFile`（复用原生路径安全检查 + 目录身份复验 + 目标普通单硬链接检查），最终摘要改为经该函数写入；输出目录被替换为 Junction / 目录身份变化时拒绝写入。**DEC-029 检查与写入之间的 TOCTOU 残余风险仍存在，不作已消除声明** |
| **P4** 递归删除部分失败的结果语义 | 递归删除过程中抛异常时统一返回 `recursiveDeletePerformed=false`，无法区分“未开始”和“已开始但未完整结束”，可能掩盖已发生的部分删除 | 结果新增 `recursiveDeleteStarted` / `recursiveDeleteCompleted` / `recursiveDeletePartial`：删除开始前记录 started；异常发生在删除开始之后时返回 `safe=false`、`stopCode=recursiveDeleteFailed`、`recursiveDeleteStarted=true`、`recursiveDeletePartial=true`，`stopReason` 明确说明“已开始但未完整结束、可能已部分删除”。`Remove-T103VerifiedDirectoryTree` 增加仅测试使用的 `FaultHook`，在真实条目删除步骤注入确定性异常 |

### 1.1 关键代码位置

- `scripts/verify/T1-03UatPath.ps1`
  - 新增 `Get-T103ValidatedTrackedLinkRecords`（删除前全量验证 + 记录对象身份）
  - 重写 `Invoke-T103FailClosedSandboxCleanup`（新顺序、精确对象删除、残余扫描、started/completed/partial 语义）
  - `Remove-T103VerifiedDirectoryTree` 增加测试注入 `-FaultHook`
  - `Assert-T103EvidenceWritePath` / `Write-T103EvidenceFile` 强制证据根身份
  - 新增 `Write-T103VerifiedOutputFile`（P3 摘要写入守卫）
- `scripts/verify/test-t1-03-uat-path.ps1`
  - 新增真实故障注入与回归检查（见第 2 节）；新增 `Round6ExpectedNewCheckNames` 硬校验 `evidence.round6NewChecksPresent`
  - `Test-EvidenceWriteRejected` 现在显式传入注入证据目录身份
  - 合成测试根 Junction 不再登记为跟踪链接（符合“跟踪链接只允许沙箱直接子项”）；未跟踪重解析点用例在 fail-closed 停止后显式清理仍存在的跟踪链接
  - `Format-EvidencePath` 统一 `<uat-root>`；新增 `evidence.uatRootPlaceholderUnified` 检查，机器标识扫描规则未放宽
- `scripts/verify/verify-t1-03-ui.ps1`
  - 创建输出目录后记录身份并 fail closed；最终摘要经 `Write-T103VerifiedOutputFile` 写入；成功时打印 `PASS summary.writeGuard`
  - 验证脚本环境时序加固（非产品代码）：`Set-WindowSize` 有限重试并检查真实客户区尺寸，避免 Tauri 启动后回写初始窗口尺寸造成的 `minWindow.sizeNear860x640` 环境性抖动（见第 5 节）
- `scripts/verify/probe-round6-red.ps1`（新增）：第六轮 Red 探针，见第 3 节

---

## 2. TDD Red → Green 与新增测试（真实 Windows 文件系统对象）

本轮的实现顺序按 TDD 进行：先写失败测试并实际运行确认 Red，再实现最小修复，再运行同一套件确认 Green。Red/Green 实际执行记录保存在机器本地 `test-artifacts/round6-t103/`（gitignored，不入库），可从下方命令与提交复核。

| 轮次 | Red 观察（真实执行） | Green |
|---|---|---|
| P1 / F2 | 旧实现结果：`safe=false`、`stopCode=unexpectedReparsePoint`、`victimLinkStillPresent=False`（外部链接已被穿过 Junction 删除） | `f2.trackedLinkThroughJunctionRejectedBeforeDelete` / `...ExternalTargetIntact` / `...SandboxPreserved` 全部 PASS |
| P4 | 修复前基线（e8205ca）真实 sharing violation：7 个条目删除到剩 1 个，旧结果 `recursiveDeletePerformed=false`、无 started 字段、`stopCode=unexpectedCleanupError`（Red 由第 3 节探针复现） | `f2.recursiveDeletePartialFailureReported` / `...RealDeletionsObserved` PASS |
| P2 / F1 | 旧实现缺少身份时仍写入成功（文件被创建）；`f1.evidenceDefaultRootTrusted` 因缺少身份强制不变量失败 | `f1.evidenceWriteMissingRootIdentityRejected` / `f1.evidenceDefaultRootWriteMissingRootIdentityRejected` / `f1.evidenceWriteWithPinnedRootIdentitySucceeds` PASS |
| P3 | `Write-T103VerifiedOutputFile` 不存在（CommandNotFound），摘要守卫测试失败 | `f3.outputSummaryGuardNormalWriteSucceeds` / `...RejectsJunctionSwap` / `...RejectsIdentityChange` PASS |
| B5 | 证据中残留固定测试根原始名称，`evidence.uatRootPlaceholderUnified` FAIL | 统一 `<uat-root>` 后 PASS；机器标识扫描规则仍包含计算机名/账户名/用户目录/仓库路径 |

新增检查（12 项目标 + 1 项汇总自校验；路径安全套件总数 115 → 128）：

1. `f2.trackedLinkThroughJunctionRejectedBeforeDelete`
2. `f2.trackedLinkThroughJunctionExternalTargetIntact`
3. `f2.trackedLinkThroughJunctionSandboxPreserved`
4. `f2.recursiveDeletePartialFailureReported`
5. `f2.recursiveDeletePartialFailureRealDeletionsObserved`
6. `f1.evidenceWriteMissingRootIdentityRejected`
7. `f1.evidenceDefaultRootWriteMissingRootIdentityRejected`
8. `f1.evidenceWriteWithPinnedRootIdentitySucceeds`
9. `f3.outputSummaryGuardNormalWriteSucceeds`
10. `f3.outputSummaryGuardRejectsJunctionSwap`
11. `f3.outputSummaryGuardRejectsIdentityChange`
12. `evidence.uatRootPlaceholderUnified`
13. `evidence.round6NewChecksPresent`

复现命令（Windows 10 / Windows PowerShell 5.1）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1 `
  -EvidencePath docs\testing\reports\T1-03-assets\evidence\round6-remediation\green\t1-03-uat-path-evidence.json
```

结果：`UAT_PATH_CHECK_TOTAL=128 ORIGINAL=23 ROUND3_PRESERVED=60 ROUND4_NEW_TARGET=31 ROUND6_NEW_TARGET=12 SKIPPED=1 FAILED=0`，退出码 0；`T1_03_UAT_PATH_SECURITY=PASS`。原 115 项检查名称全部保留（第三轮 60 + 第四轮 31 + 第五轮 21 硬校验继续通过）。

**SKIP（不计 PASS）：** `native.symbolicLinkToExternalRejected` —— 当前非管理员进程无 `SeCreateSymbolicLinkPrivilege`，`mklink /D` 退出码 1；该场景未执行。
**未测试：** Windows ACL `Access Denied` 场景未实际执行，不得表述为已测试。

---

## 3. Red 证据：修复前基线 e8205ca 的真实复现（B3）

第五轮审计指出旧的 Red 证据不可复核：`test-artifacts/f1f2/baseline-evidence.json` 被 Git 忽略，且旧 `red-probe.ps1` 实际调用的是**修复后的函数**。本轮用新的、已提交的探针脚本修复该问题：

**脚本：** `scripts/verify/probe-round6-red.ps1`（已提交，可重复执行）
**命令：** `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\probe-round6-red.ps1`
**基线的忠实性保证：** 探针用 `git archive e8205cae22e98afce6480f5a5a0695543a61dee3` 解压基线完整文件树到专用测试目录，并用 `git rev-parse <baseline>:scripts/verify/T1-03UatPath.ps1` 与 `git hash-object <解压文件>` 比对 blob SHA（`fafd320753ae1efd39055bd53e95f221b4b50be6`）一致后才执行；**不加载当前修复后脚本冒充修复前实现**。
**机器可读证据：** `red/round6-red-evidence.json`
**脱敏后的原始命令输出：** `red/round6-red-command-output.sanitized.log.txt`

复现结果（`redConfirmed=true`）：

| 场景 | 修复前行为（真实文件系统对象） |
|---|---|
| **F1** | 基线测试脚本入口以 `-EvidencePath <red-case-root>\outside-evidence\guardian-business-canary.json` 真实执行（exit 0），把 **34,904 字节**证据写到仓库证据目录之外并**覆盖守卫 Canary**（SHA-256 `6E340FD4…1191` → `1609F66D…2EF22`），`escapedEvidenceTask=T1-03` |
| **F2** | 基线的 `Invoke-T103FailClosedSandboxCleanup` 在 `sandbox\evil(Junction)->external`、`external\victim-link(Junction)->victim-target`、`TrackedLinks=sandbox\evil\victim-link` 下**真实删除了外部 victim-link**（`victimLinkDeletedByOldCleanup=true`），之后才 `stopCode=unexpectedReparsePoint`；victim-target Canary 内容/SHA-256 不变（删除的是链接本身） |
| **P4** | 基线递归删除遇到真实 sharing violation（子目录内文件被 `FileShare.None` 打开）：7 个条目 → 剩 1 个（`partialDeletionObserved=true`），旧结果仍 `recursiveDeletePerformed=false`、无 `recursiveDeleteStarted` 字段、`stopCode=unexpectedCleanupError` |

探针只使用虚构文件、Canary 和专用测试目录，结束时清理现场（未残留 `round6-red-*` 目录）；输出 JSON 与日志均通过机器标识/固定测试根自检后才落盘。

**Green 证据与 Red 分离：** Green 证据位于 `green/`（路径安全 128 项 + 最终通过轮次 Release E2E 证据），与 `red/` 分开保存，互不覆盖。

---

## 4. B2：round5 汇总时间戳修正

`evidence/round5/round5-verification-summary.json` 原 `generatedAt=2026-11-26T10:20:23Z`，但该文件包含的路径专项证据生成于 `2026-11-26T10:20:23.6531600Z`、Release E2E 证据生成于 `2026-11-26T10:32:09.2478282Z`、修复提交时间为 `2026-11-26T18:37:26+08:00`，旧值不是真实汇总组装时间。

修正方式（**未伪造时间**）：

- `generatedAt`：本次真实汇总组装时间（UTC，写入时由 `Get-Date` 生成）；
- `pathEvidenceGeneratedAt` / `releaseE2EEvidenceGeneratedAt`：分别读取 round5 内两份证据的真实 `generatedAt`；
- `fixCommitCommittedAt`：round5 修复提交的真实提交时间；
- `historicalGeneratedAt`：保留旧值供历史追溯；
- `summaryAssemblyCorrection`：写明修正原因；`round6CorrectionReference` 指向本文件；
- round5 其余字段与全部原始证据文件**未覆盖**（本文件仅做上述最小文本插入）。

---

## 5. Release E2E 结果与尝试记录（诚实记录环境性失败）

最终通过轮次：`<uat-root>\t1-03-ui-r6f-20261127-071753`（机器本地 UAT 目录；证据已脱敏复制到 `green/`）。

| 项目 | 结果 |
|---|---|
| 主 UI/IPC | 84/84（exit 0） |
| 最小窗口 860×640 | 12/12（exit 0；关闭红色圆点后进程退出码 0） |
| 重启持久化 | 17/17（exit 0；关闭退出码 0） |
| 数据库只读探针 | 25/25（关闭后 + 重启后） |
| 两次真实关闭退出码 | 0 / 0 |
| CSP 违规 / 页面未捕获异常 | 0 / 0 |
| 截图 | 19 张（未复制入仓；产品 UI 未修改，保留在机器本地 UAT 目录） |
| 最终摘要写入守卫 | `PASS summary.writeGuard`（原生路径检查 + 输出目录身份复验通过） |
| Release EXE | `target\release\workmanager.exe`，10,352,128 字节，SHA-256 `f46c9b0cb3c9d094475cab6abd8276276126f2ea0d2e5b38b6d6a4fbf92b2b68`（本轮未修改产品代码，构建产物不入库） |

**E2E 尝试记录（全部真实执行，未把失败尝试计入通过结果）：**

1. `t1-03-ui-r6-20261127-071251`：exit 1。在 Red 探针/基线套件并发执行期间运行，主 UI 检查等待应用壳渲染超时（`hasAppShell=false`），首次关闭进程未退出；判定为并发负载下的环境性失败，不作通过结果。
2. `t1-03-ui-r6c-20261127-071613`、`t1-03-ui-r6d-20261127-071634`：exit 1。主 UI/IPC 84/84、持久化 17/17、数据库 25/25、关闭 0/0 均通过，仅 `minWindow.sizeNear860x640` 失败（窗口保持默认 1100×780）。对照通过轮次与失败轮次确认：应用启动后 Tauri 可能随后回写初始窗口尺寸，单次 `SetWindowPos` 被覆盖，属于验证脚本时序竞态而非产品 UI 回归（最小窗口其余 11 项布局断言在同一失败轮次仍全部通过）。
3. 验证脚本加固（仅 `scripts/verify/verify-t1-03-ui.ps1`，非产品代码）：`Set-WindowSize` 在有限次数内重试并用 `GetClientRect` 核对真实客户区尺寸，成功后打印 `最小窗口尺寸应用成功（第 N 次尝试）`。
4. `t1-03-ui-r6e-20261127-071732`、`t1-03-ui-r6f-20261127-071753`：连续两次 exit 0、`T1_03_RELEASE_UI_E2E=PASS`，Guard PASS；最终采用 r6f 证据。

---

## 6. B4：提交数修正

独立审计确认旧报告 22 个提交已过时。最终 HEAD 上重新计算（`git rev-list --count origin/main..<rev>`，`origin/main=9171fe35a7e080097991f547efe37ff5a504257c`）：

| 范围 | 提交数 |
|---|---|
| `origin/main..e8205ca`（第五轮审计基准） | **25** |
| `origin/main..6ddae47`（第五轮审计基准 / 本轮开发前 HEAD） | **27** |
| `origin/main..e3bb86b`（本轮修复提交） | **28** |
| `origin/main..最终 HEAD`（本轮修复 + 证据/文档同步提交） | **30** |

历史轮次记录（20/21/22 等）保留为当时事实，不再作为当前状态引用；当前状态文档统一使用最终 HEAD 的 30。PR #8 base 落后于 main 的合并基线问题不在本轮处理（T1-04 依赖 T1-03 堆叠分支，避免 rebase/改历史）。

---

## 7. B5：测试根目录脱敏口径

- `Format-EvidencePath` 现在把固定测试根路径统一映射为 `<uat-root>`（包括其它盘符下的同名虚构拒绝用例路径与大小写变体），并保留原有计算机名/账户名/用户目录/仓库路径替换。
- 路径安全套件新增 `evidence.uatRootPlaceholderUnified` 检查；机器标识扫描模式（计算机名、`USERPROFILE`、仓库根、用户目录前缀、旧日志目录）保持不放宽，并新增对固定测试根原始名称的扫描。
- 历史证据补正：`evidence/t1-03-uat-path-evidence.json`（2 处）、`evidence/round4/t1-03-uat-path-evidence.json`（3 处）、`evidence/round5/t1-03-uat-path-evidence.json`（3 处）中的固定测试根原始名称替换为 `<uat-root>`；**只改路径占位，不改任何检查结果/计数**，替换后均通过 JSON 解析校验。
- `SANITIZATION.md` 已同步更新扫描口径与占位符规则；专用测试根路径不再作为证据/文档中的字面值出现（仅生产脚本常量保留该 PRD/DEC-002 固定路径）。
- 复核扫描：T1-03 证据目录搜索结果中固定测试根原始名称命中 **0**；具体计算机名/账户名/用户目录/仓库绝对路径命中 **0**。main 基线既有 T1-01/T1-02 机器信息未修改（非本 PR 新增，需单独授权）。

---

## 8. 质量门禁（本轮最终 HEAD 实测，全部真实执行）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | 通过 |
| `cargo test --workspace` | 0 | **124 passed / 0 failed**（18 个测试二进制） |
| `npm.cmd run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 0 违规、49/49 |
| `npm.cmd run build` | 0 | 构建成功（167 modules） |
| `node --test scripts/quality/work-item-bridge.test.mjs` | 0 | 17/17 passed |
| `git diff --check` | 0 | 无空白错误 |

环境说明：Windows PowerShell 5.1 下 `npm` 会解析到 `npm.ps1` 并出现参数异常，本轮显式使用 `npm.cmd` 执行（仅执行方式差异，不涉及产品代码或门禁标准变化）。

---

## 9. Skill 实际使用

| Skill | 来源 / 版本 | 实际应用位置 |
|---|---|---|
| **Ponytail** | https://github.com/DietrichGebert/ponytail，commit `ebd8654c2c627f721eb8f9c0d1bd4090a29f9e10`，`skills/ponytail/SKILL.md`（level: full） | 用“最小完整改动”约束修复：复用既有 `Get-T103NativePathChain` / `Find-T103ReparsePointsInTree` / `Remove-T103VerifiedDirectoryTree` / 原生句柄原语，不新增通用嵌套链接机制；P2 只在既有 `Assert/Write` 上加一个强制开关而不再造路径安全模块；P3 复用既有原生检查原语实现一个最小写入函数；修复前先 grep 全部调用方（`TrackedLinks`、`recursiveDeletePerformed`、`Write-T103EvidenceFile`、`ExpectedRootIdentity`）定位根因；新增非平凡逻辑均配套真实文件系统测试 |
| **Matt Pocock Implement** | https://github.com/mattpocock/skills，commit `6f7f7831a625f040a8e06a0e7954826b87ce775a`，`skills/engineering/implement/SKILL.md` | 按 spec/审计清单逐项实现，控制范围（只做 P1–P4/B1–B5，不重做 T1-03）；按该 Skill 要求调用 `tdd`（red → green）并在完成后进行 review 检查；改动只落在验证脚本/测试/证据/状态文档 |
| **TDD** | 会话 skill catalog `tdd`（与 mattpocock `skills/engineering/tdd/SKILL.md` 同源原则） | 四个修复 seam 均先写失败测试并真实运行确认 Red，再最小实现，再运行同一套件确认 Green；Red/Green 证据分开保存；详见第 2、3 节 |

---

## 10. 遗留风险与明确未处理项

1. **P2-01 仍未关闭**：GitHub Support 服务端历史清理未完成；旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 与 9 个原始日志仍可经 GitHub API 读取。本轮未重写历史、未强制推送、未删除备份分支/bundle，不声称 P2-01 已关闭。
2. **DEC-029 / Issue #2 TOCTOU 仍存在**：证据写入、摘要写入、清理检查与后续文件操作之间仍非原子；本轮只缩小窗口，不作已消除声明。不开发 SQLite VFS，不重构全部 Windows 文件访问，不擅自关闭 Issue #2。
3. **Windows ACL `Access Denied` 未实际测试**：F1/F2 的“原生检查失败”用例使用“路径组件是文件”等真实 Win32 失败，不得表述为 ACL 拒绝。
4. **Symbolic Link 场景 SKIP**：当前非管理员进程无 `SeCreateSymbolicLinkPrivilege`，明确记录 SKIP，不计 PASS。
5. **普通 SQLite 未加密（DEC-028）**：拥有文件访问权限的人可读取数据库内容；未重新引入 SQLCipher。
6. **PR #8 base 落后于 main**：本轮未 rebase、未修改历史、未强制推送，合并基线问题留待后续统一处理（注意 T1-04 依赖 T1-03 堆叠分支）。
7. **main 基线既有机器信息**：T1-01/T1-02 历史证据中的同类机器信息未修改（非本 PR 新增，需单独授权）。
8. **最终状态：待独立审计**。开发代理不自行宣布审计通过或用户验收完成；PR #8 保持 OPEN，不合并。

---

## 11. 本轮明确不在范围内的内容（未擅自扩大）

DEC-029 / Issue #2（TOCTOU 继续延期）、P2-01（不做历史重写/强推/删除备份）、Symbolic Link 权限问题、Windows ACL 测试、SQLite 加密（DEC-028 决策不变）、PR base rebase/历史修改、T1-04/T1-02/PRD/TECHNICAL_DESIGN/已确认业务决策。
