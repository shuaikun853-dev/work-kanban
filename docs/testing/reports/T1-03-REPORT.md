# T1-03 工作事项快速创建和待安排区域 — 测试与交付报告

**任务 ID：** T1-03
**任务名称：** 工作事项快速创建和待安排区域
**当前状态：** **第五轮独立审计未通过（P1/F2 跟踪链接穿过未跟踪 Junction、P2/F1 证据写入身份不完整、P3 最终摘要写入未走守卫、P4 递归删除部分失败语义）；本轮 P1–P4 与 B1–B5 定向补正完成，等待第六轮独立审计；P2-01 服务端清理未完成、保持 OPEN**（PR #8 保持 Open，未合并；main 未修改）
**开发分支：** `task/T1-03-quick-create-pending`（本地开发工作区分支 `task/T1-03-quick-create-pending-r4`，与审计基准同 SHA）
**目标分支：** `main`
**开发基线：** `018e851e8daf5835391a7b61caf881bc57c2ad42`（T1-02 已验收合并后的 main）；当前远端 main 为 `9171fe35a7e080097991f547efe37ff5a504257c`（PR #8 base 落后于 main 的问题本轮不处理）
**第一轮审计基准 HEAD：** `2342828852abee43ab56610e7d1fa91a02310bfe`
**第二轮审计基准 HEAD：** `bad0688ee9de5e07f769d64d7fc44e3f182a960d`
**第三轮审计基准 HEAD：** `489d8689484c2cf744893bd3ee08dc7b25b5c8b8`
**第四轮审计基准 HEAD：** `e8205cae22e98afce6480f5a5a0695543a61dee3`
**第四轮修复提交：** `d82bdd47ae7c3c27fb4383d72ee16a131c89036d`
**第五轮审计基准 HEAD：** `6ddae47dd0721d58d5cb11f55e527fc162cedbe9`（本轮开发前 PR #8 HEAD）
**第五轮修复提交：** `af2421e9207f7b9ac185b0d29c3a98f80b5eb11a`
**本轮（第六轮）修复提交：** `e3bb86b30772159219a8eb16b90e55f3c69f4d59`；随后为本轮证据/文档同步提交（最终 HEAD，`origin/main..HEAD` = **30** 个提交；本文件内的自身 SHA 无法自引用，见 PR #8 时间线）
**Pull Request：** [PR #8](https://github.com/shuaikun853-dev/work-kanban/pull/8)（指向 main，保持 Open，等待第六轮独立审计）
**报告生成时间：** 2026-11-19（第二轮）；2026-11-20 第三/四轮更新；2026-11-26 第五轮更新；2026-11-27 第六轮定向补正更新（Asia/Shanghai）
**测试环境：** Windows 10 家庭中文版 10.0.19045；Windows PowerShell 5.1.19041.6456；rustc 1.100.0 / cargo 1.100.0；Node.js v22.20.0 / npm 10.9.3；Python 3.14.5
**测试数据：** 全部为虚构内容；UAT 使用专用测试根目录下的一次性新目录（本轮 `<uat-root>\t1-03-ui-r6f-20261127-071753`；第五轮 `<uat-root>\t1-03-ui-r5b-20261126-183147`；第四轮 `<uat-root>\t1-03-ui-r4-20261120-181549`；第三轮 `<uat-root>\t1-03-ui-r3-20261120-081100`），未触碰正式运行目录，未使用真实用户工作数据

---

## 本轮（第六轮）定向补正摘要（2026-11-27，按第五轮独立审计 P1–P4 + B1–B5）

第五轮独立审计基准 HEAD `6ddae47`。本轮只做第五轮审计报告列出的最小范围补正：**未重新开发 T1-03、未修改产品业务代码（Rust/前端/迁移/业务 UI 未变）、未修改 T1-04/T1-02、未修改 PRD/TECHNICAL_DESIGN/DECISIONS 业务决策、未新增依赖、未重写历史、未强制推送**。

| 问题 | 根因 | 本轮修复 | 关键证据 |
|---|---|---|---|
| **P1 / F2** 跟踪链接穿过未跟踪 Junction 删除外部链接 | 清理函数先删除 `TrackedLinks`、**之后**才扫描沙箱重解析点；且只做“字面路径在沙箱内”判断。`sandbox\evil` 为指向沙箱外 `external` 的真实 Junction 时，`sandbox\evil\victim-link` 字面在沙箱内、实际解析到沙箱外，删除发生在扫描之前 | 新顺序：①沙箱身份复验 + 沙箱到盘符根父目录链原生校验；②**先验证全部跟踪链接**（只允许沙箱直接子项；记录链接对象自身卷序列号 + File ID + reparse tag；嵌套/父链不明 → `trackedLinkNotDirectChild` fail closed）；③**删除任何对象前扫描整个沙箱**，除已登记链接外出现任何重解析点 → `unexpectedReparsePoint` 停止；④只删除身份精确匹配的已登记对象（删除前原生复核，删除后原生确认消失）；⑤删除后再次扫描，残余 → `residualReparsePoint`；⑥再次复验沙箱身份；⑦才执行逐条目安全递归删除并确认沙箱消失 | 新增 3 项真实故障注入（`sandbox\evil` 与 `external\victim-link` 均为真实 `mklink /J`）：修复前实测删除外部 victim-link 后 `safe=false/stopCode=unexpectedReparsePoint`；修复后 `trackedLinkNotDirectChild`、`recursiveDeleteStarted=false`，victim-link 仍存在、victim-target Canary 内容与 SHA-256 不变、沙箱/evil/sentinel 保留 |
| **P2 / F1** 证据写入身份校验不完整 | `ExpectedRootIdentity` 为可选参数；实际写入缺少启动身份记录时仍可继续；`EvidenceRoot` 可通过内部参数指定任意目录，函数级不变量与注释不一致 | `Write-T103EvidenceFile` 强制要求启动时记录的证据根目录身份（缺失 → 拒绝写入）；`Assert-T103EvidenceWritePath` 新增 `-RequireRootIdentity`；目录身份变化 → 拒绝。隔离 `EvidenceRoot` 仅保留为专项测试内部注入能力，必须显式传入该目录身份记录，不是生产 CLI 参数 | 新增 3 项：注入目录缺身份拒绝（不写文件）、默认证据根缺身份拒绝（不写文件）、显式身份正常写入成功；原身份替换测试继续通过 |
| **P3** `verify-t1-03-ui.ps1` 最终摘要写入未走安全守卫 | 原第 420–421 行直接 `Set-Content` 写 `t1-03-ui-orchestration.json`，写入前未复验输出目录身份 | 创建 UAT 输出目录后记录其身份（卷序列号 + File ID + 真实最终路径）；新增 `Write-T103VerifiedOutputFile`（原生路径安全检查 + 输出目录身份复验 + 目标普通单硬链接检查），最终摘要经该函数写入；输出目录被替换为 Junction 或身份变化时拒绝写入 | 新增 3 项：正常写入成功；输出目录被 rename + 真实 Junction 替换 → 拒绝且外部 Canary SHA-256 不变、未写入外部目录；输出目录 rename + 重建（File ID 变化）→ 按启动身份拒绝且不写文件。**DEC-029 TOCTOU 残余风险仍存在，未消除** |
| **P4** 递归删除部分失败的结果语义 | 递归删除过程中抛异常时统一返回 `recursiveDeletePerformed=false`，无法区分“未开始”与“已开始但未完整结束”，可能掩盖已发生的部分删除 | 结果新增 `recursiveDeleteStarted` / `recursiveDeleteCompleted` / `recursiveDeletePartial`；异常发生在删除开始之后时 `safe=false`、`stopCode=recursiveDeleteFailed`、`started=true`、`completed=false`、`partial=true`，`stopReason` 明确“已开始但未完整结束、可能已部分删除”；`Remove-T103VerifiedDirectoryTree` 增加仅测试使用的 `FaultHook` | 新增 2 项真实目录树故障注入：第 2 个条目删除注入失败，结果 `recursiveDeleteStarted=true / recursiveDeletePartial=true / recursiveDeletePerformed=false`；真实条目已删除 1 个、沙箱保留。修复前基线（e8205ca）真实 sharing violation 复现：7 条删到 1 条但旧结果仍 `recursiveDeletePerformed=false` 且无 started 字段 |
| **B1–B5** 交付证据问题 | PR #8 正文停在第四轮；round5 汇总 `generatedAt` 早于其包含的证据/修复提交；Red 证据被 Git 忽略且旧探针调用修复后函数；旧报告 22 个提交过时；证据残留固定测试根原始名称 | 本轮更新 PR #8 正文 + 新增进度评论（保留历史评论）；round5 汇总拆分为真实 `pathEvidenceGeneratedAt` / `releaseE2EEvidenceGeneratedAt` / `fixCommitCommittedAt` / 真实汇总组装时间并保留 `historicalGeneratedAt`；提交可重复执行的 `scripts/verify/probe-round6-red.ps1`（git archive e8205ca + blob SHA 校验 + 真实文件系统对象）与脱敏 Red/Green 证据；按最终 HEAD 重算提交数（25/27/28/30）；固定测试根统一 `<uat-root>` 并加强扫描检查 | 见第 4.10 节与 `evidence/round6-remediation/`（`round6-verification-summary.json`、`round6-remediation-notes.md`、`red/`、`green/`） |

**新增测试：** 12 项目标检查 + 1 项汇总自校验；路径安全专项 **128 项（原 115 项全部保留：原 23 + 第三轮 60 + 第四轮 31 + 第五轮 21 硬校验继续通过），FAILED=0，SKIPPED=1（Symbolic Link 权限限制）**，退出码 0；第 4.10 节列明细。

**Release E2E：** 最终通过轮次 `<uat-root>\t1-03-ui-r6f-20261127-071753`：主 UI/IPC **84/84**、最小窗口 **12/12**、重启持久化 **17/17**、数据库只读探针 **25/25**；两次真实关闭退出码 **0/0**；CSP 0、页面未捕获异常 0；最终摘要写入 `PASS summary.writeGuard`。共 5 次真实尝试：1 次并发负载下应用壳渲染超时、2 次最小窗口尺寸时序竞态（其余断言均通过）、补丁后 2 次连续 PASS；失败尝试如实记录、不计入通过结果。**说明：** 为消除已验证的验证脚本时序竞态，本轮只在 `verify-t1-03-ui.ps1` 中对 `Set-WindowSize` 做有限重试 + 真实客户区尺寸核对（测试脚本加固，非产品代码；产品 UI 未修改）。

**Red 证据（可复核）：** 新探针以 `git archive e8205cae22e98afce6480f5a5a0695543a61dee3` 解压修复前完整文件树，并用 git blob SHA（`fafd3207…be6`）校验后才执行基线脚本，**不使用修复后函数冒充修复前实现**。真实复现：F1 基线脚本把 34,904 字节证据写到仓库证据目录之外并覆盖守卫 Canary；F2 基线清理穿过未跟踪 Junction 删除外部 victim-link；P4 基线递归删除真实部分失败后仍报告 `recursiveDeletePerformed=false`。证据：`evidence/round6-remediation/red/round6-red-evidence.json` 与脱敏原始输出 `round6-red-command-output.sanitized.log.txt`；Green 证据单独保存在 `green/`。

**Red/Green 与 Skill：** 按 TDD 先写失败测试并真实运行确认 Red（P1/P2/P3 在修复前实现上失败；P4 修复前基线由探针复现），再最小实现，再运行同一套件确认 Green。实现遵循 **Ponytail**（最小完整改动、复用既有原生句柄/路径链/递归删除原语，不新增通用嵌套链接机制）与 **Matt Pocock Implement**（按审计清单控制范围、调用 TDD、完成后 review）；实际使用的 Skill 文件、版本与应用位置见 `evidence/round6-remediation/round6-remediation-notes.md` 第 9 节。

**本轮结论：** P1–P4 修复与 B1–B5 证据修正完成，真实 Windows 文件系统对象/真实故障注入回归通过；质量门禁全部退出码 0（cargo 124/124、npm check svelte-check 0/0 + Bridge 17/17 + Design Token 49/49、npm build 167 modules、Bridge 17/17、git diff --check）。**P2-01 仍未关闭；DEC-029 / Issue #2 的 TOCTOU 风险仍存在；未执行 Windows ACL `Access Denied` 测试；Symbolic Link 场景 SKIP。状态：待第六轮独立审计，不自行宣布审计/验收通过。**

---

## 第五轮 F1/F2 最小修复摘要（2026-11-26，历史）

第四轮独立审计发现两项问题：**F1 EvidencePath 证据文件写入缺少边界与身份保护**、**F2 沙箱入口使用 `Test-Path` 判断存在性，悬空 Junction 场景会绕过后续 Windows 原生路径身份检查**。本轮只做这两项最小修复：未重新开发 T1-03、未修改产品代码（Rust/前端/迁移/业务 UI 未变）、未修改 PRD/技术设计/决策记录、未新增依赖、未重写历史、未强制推送。

| 问题 | 根因 | 本轮修复 | 关键证据 |
|---|---|---|---|
| **F1** `-EvidencePath` 可写到证据目录之外并覆盖业务文件 | 证据 JSON 直接 `Set-Content -Path $EvidencePath`；父目录不存在时 `New-Item -Force` 自动创建；没有规范化、边界、真实最终路径、目录身份、重解析点或目标文件身份检查；相对路径按当前目录解析 | `T1-03UatPath.ps1` 新增 `Assert-T103EvidenceWritePath` / `Write-T103EvidenceFile`：相对路径按仓库根目录解析并拒绝 UNC/设备路径；证据目录必须存在、是真实目录、真实最终路径与字面一致、卷身份一致；请求路径每个已存在组件必须是普通目录（拒绝 Junction / Symbolic Link / 悬空链接）；真实最终路径必须严格位于证据目录内（非字符串前缀）；已存在目标文件必须是普通文件且只有 1 个硬链接；启动时记录证据目录身份（卷序列号 + File ID + 真实最终路径），写入时比对；任一检查失败 fail closed，不创建、不覆盖 | 路径安全专项 **115 项（FAILED=0、SKIPPED=1）**；F1 新增 12 项：正常写入、相对越界、`..` 遍历、绝对越界、Junction 绕过、悬空 Junction、硬链接数据库别名、证据目录身份替换、正式数据库目标、原生检查失败、默认证据目录、Canary 完整性；修复前 Red 实测：证据曾写到仓库证据目录之外的 `test-artifacts\f1f2\baseline-evidence.json`（34,904 字节），并覆盖业务 Canary 文件（SHA-256 改变）、自动创建越界目录 |
| **F2** 悬空 Junction 可绕过沙箱入口原生检查 | 清理 `finally` 分支用 `elseif (-not (Test-Path -LiteralPath $sandbox))` 直接判定“入口不存在”，返回 `safe=true / sandboxAlreadyAbsent`，完全跳过后续原生身份检查。Windows PowerShell 5.1 对悬空 Junction **本身**的 `Test-Path` 返回 True，但对**悬空 Junction 之下的路径**返回 False；沙箱路径的祖先为悬空 Junction 时即可绕过 | 新增 `Get-T103EntryNativeState`（入口本身 + 父目录的 `FILE_FLAG_OPEN_REPARSE_POINT` 原生状态：存在性、ReparsePoint、Tag、目录属性、卷序列号、File ID）与 `Invoke-T103SandboxCleanupEntrypoint`：不再使用 `Test-Path`；先检查入口本身与父目录，再用 `Get-T103NativePathChain` 检查全部已存在祖先；仅当原生检查确认入口确实不存在时才按原有业务规则返回 `sandboxAlreadyAbsent`；入口是 Junction / 悬空 Junction、父目录是重解析点、身份不明、原生检查失败一律 fail closed 且不执行递归删除；测试脚本的链接存在性辅助函数同步改为原生检查 | F2 新增 8 项：正常入口身份检查通过、真实不存在、正常 Junction、悬空 Junction（tag `0xA0000003`）、`Test-Path=False` 的悬空 Junction 路径、父目录重解析点、身份不明、原生检查失败；失败场景 `recursiveDeletePerformed=false`；`Test-Path=False` 场景修复后 `stopCode=sandboxParentIsReparsePoint`；外部 Canary 内容/哈希不变；无递归删除 |
| **证据/文档** | 第四轮审计后状态未同步 | 新增 `evidence/round5/`（不覆盖 round3/round4）；更新本报告、STATUS、DEVELOPMENT_PLAN、证据索引与测试数量 | 第三轮 60 项 + 第四轮 31 项检查名称仍硬校验保留；本轮 21 项新检查硬校验存在 |

**本轮结论：** F1/F2 最小修复完成，真实 Windows 文件系统对象回归通过（真实目录、真实 Junction、真实悬空 Junction、真实硬链接、真实文件哈希与 Canary）。符号链接场景仍因权限限制如实 SKIP；**未执行 Windows ACL `Access Denied` 测试**，F1/F2 的“原生检查失败”用例使用“路径组件是文件”的真实 Win32 失败（不是 ACL 拒绝），不得混写。**DEC-029 / Issue #2 的并发替换 TOCTOU 风险未消除**，本轮不作任何已消除声明。

**Red/Green 与 Skill：** 修复前用真实文件系统与真实脚本入口证明 F1 越界写入；F2 用真实悬空 Junction 证明旧分支表达式 `-not (Test-Path ...)` 会返回 `sandboxAlreadyAbsent`（跳过原生检查），修复后同一对象返回 fail-closed。实现遵循 Ponytail（最小改动、复用既有原生句柄与路径链、不新增依赖）与 Matt Pocock Implement/TDD（先证明问题 → 最小实现 → 同一 seam 回归测试）。

---

## 0. 第四轮 F1/F2 定向修复摘要（2026-11-20，历史）

第三轮独立审计结论为**未通过**，阻塞项为 F1（测试根目录未验证就创建测试沙箱）与 F2（Junction 清理失败后仍递归删除），并要求同步修复证据/文档一致性。第四轮只修复这两项及证据一致性：**未修改产品代码**、未新增业务功能、未修改 PRD/TECHNICAL_DESIGN/DECISIONS 业务决策、未重写历史、未强制推送。

| 问题 | 本轮修复 | 关键证据 |
|---|---|---|
| **F1** 测试根目录未验证就写入沙箱 | `test-t1-03-uat-path.ps1` 在任何写操作之前调用 `Assert-T103UatTrustedTestRoot`：Windows 原生句柄验证测试根目录存在、是真实目录、全部已存在祖先组件、拒绝未批准重解析点、真实最终路径与预期一致、卷身份一致、不在正式目录内；缺失/身份无法确认时 fail closed，**绝不自动创建测试根目录**。新增真实 Junction 根替换 + 外部 Canary 的真实入口子进程无副作用测试；`-TestRootOverride` 只用于故障注入且不能执行完整套件；`verify-t1-03-ui.ps1` 同样在任何写操作前验证信任锚 | 路径安全专项 **93 项（FAILED=0，SKIPPED=1）**；第三轮 60 项全部保留；F1 子进程 exit=2、Canary 内容/目录结构不变、无沙箱/无默认证据写入 |
| **F2** 清理失败后仍递归删除 | 新增 fail-closed 沙箱清理：清理前复验沙箱身份（卷序列号 + 文件 ID + 真实最终路径），逐个删除并复验跟踪链接，扫描沙箱确认无未预期 reparse point，再次复验身份；任一条件不满足立即停止（不执行整个沙箱递归删除），保留现场并输出可定位 WARN/FAIL。仅全部通过后才执行逐条目校验的安全递归删除，绝不跟随链接进入外部目录 | 4 类失败场景（删除失败由受控 FaultHook 在 `beforeLinkDelete` 阶段抛出确定性异常，未修改 Windows ACL、未实际执行 ACL 拒绝/`Access Denied` 测试；链接重建/未跟踪链接/身份替换使用真实文件系统对象验证）全部 `stopCode` 命中、`recursiveDeletePerformed=false`、沙箱与外部 Canary 保留；正常清理 SAFE |

**第四轮关键结论：** F1/F2 修复完成且真实 Junction/Canary 文件系统场景与受控删除失败注入测试通过（未执行实际 Windows ACL 拒绝测试）；第三轮 60 项路径安全检查零回归；质量门禁、T1-03 Release E2E、继承便携/异常注入/T1-02 UI 回归全部通过（T1-02 UI 首次执行出现环境性失败，无并发负载单独重跑通过）；2026-11-20 重新扫描的分支/资产/PR 数据已同步到本报告与证据。**P2-01 仍未关闭**（旧提交与 9 个原始日志仍可经 GitHub API 读取），TOCTOU 剩余风险未消除。开发代理不自行宣布审计/验收通过。

### 0.1 第三轮修复摘要（历史，2026-11-20）

第三轮只处理第二轮独立审计后仍保持未关闭的两项：P2-01（原始日志/机器信息/GitHub 历史对象清理）与 P3-02（Windows UAT 路径安全，Junction/Symbolic Link 绕过）。该轮扫描口径为当时 HEAD=`bad0688`（18 提交 / 5,773 次文件树扫描；提交数在第三轮文档复核后为 20），历史数字仅作轮次记录，**当前第四轮数值见第 0 节与第 4.7/4.8 节**。第三轮修复结果为：P3-02 原生句柄校验完成（60 项路径安全专项），P2-01 复核通过但服务端清理未完成。第三轮修复提交 `b6a54591b783049142cbbffecd107ec9086723eb`。

### 0.2 第二轮修复摘要（历史，2026-11-19）

第一轮独立审计结论：未通过。本轮只修复审计指出的四项问题，不扩大开发范围、不新增业务功能、不修改 PRD/TECHNICAL_DESIGN/DECISIONS 中的业务决策、不修改 DEC-028/DEC-029/DEC-033、不新增依赖。

| 问题 | 修复内容 | 关键证据 |
|---|---|---|
| **P2-01** 原始日志与机器信息提交 | 删除 `T1-03-assets/logs/` 下 9 个原始命令日志；对 11 个 JSON 证据脱敏（计算机名/账户名/用户目录/仓库与 UAT 绝对路径）；新增 `SANITIZATION.md`；重写本任务分支历史并 `--force-with-lease` 推送 | `T1-03-assets/SANITIZATION.md`；脱敏扫描 0 命中；分支新增历史深度扫描 0 命中；证据结构一致性 11/11 |
| **P2-02** Rust / TypeScript DTO 契约不一致 | `WorkItemDto` 统一为 Rust 实际序列化的 10 字段（含可空 `importance`/`urgency`/`dueDate`/`description`）；Bridge 改为严格契约：缺字段、类型错误、非法状态、未知字段全部拒绝；Rust 增加完整字段/可空值/字段名集合序列化测试；Node 契约测试扩展到 17 项 | Rust 124/124；Bridge 17/17；E2E 真实创建响应经严格 Bridge 校验通过（全部创建流程） |
| **P3-01** 创建成功提示时机不准确 | `loadPending()` 返回成功/失败；创建成功后先显示“正在刷新”，刷新成功后才显示“列表已更新/已从数据库更新”；刷新失败显示独立 warning 并允许“重新加载”，不重复创建 | E2E：延迟刷新时中间态提示、成功态提示、`pending-create-refresh-failure.png` / `pending-create-refresh-recovered.png`；同标题仅 1 条 |
| **P3-02** UAT 脚本缺少数据库复用保护 | 新增 `T1-03UatPath.ps1`：`GetFullPath` 规范化后限制在 `D:\WorkManager-test-data\`，拒绝正式目录、根目录外、`..` 越界、已含数据库目录、非空未知目录；不删除/不覆盖；新增 23 项路径安全专项测试 | `test-t1-03-uat-path.ps1` 23/23 PASS；`t1-03-uat-path-evidence.json` |

### 0.3 第二轮历史清理记录（P2-01，历史）

- **重写前 HEAD（第一轮审计基准）：** `2342828852abee43ab56610e7d1fa91a02310bfe`
- **重写后 docs/evidence 提交：** `b6cf344abc1693e7031427f8963c27474c0b59f9`
- **重写原因：** 原 docs/evidence 提交包含原始命令日志与机器标识；只重写本任务分支的 docs/evidence 提交，未重写 main。
- **推送方式：** `git push --force-with-lease=task/T1-03-quick-create-pending:2342828852abee43ab56610e7d1fa91a02310bfe origin task/T1-03-quick-create-pending`
- **本地恢复引用：** 分支 `backup/t1-03-r1-audit-baseline`（仅本地，未推送）；bundle 备份在仓库外 `test-artifacts/r1-backup/t1-03-r1-audit-baseline-2342828.bundle`（gitignored）。
- **清理验证：** 本分支新增/修改文件的历史深度扫描（15 个提交、84 个文件状态）机器标识命中 0；`T1-03-assets/logs/` 路径在分支 `018e851..HEAD` 历史中不可达。
- **残留风险：** GitHub 服务端对不可达对象可能保留有限缓存；不能宣称服务端所有临时副本立即物理删除。main 基线既有的 T1-01/T1-02 历史证据存在同类机器信息（非本 PR 新增，按本轮“不扩大修改范围”未修改），作为残留风险记录。

---

## 1. 实际实现范围（T1-03 主体）

### 1.1 数据库（schema 2 → 3）

新增 `crates/workmanager-core/migrations/0003_work_items.sql`，沿用现有 migration 引擎（独立 `IMMEDIATE` 事务、失败回滚、`user_version` 成功后前进）；未修改 0001/0002。

```sql
CREATE TABLE work_items (
    id               TEXT PRIMARY KEY NOT NULL,
    project_id       TEXT REFERENCES projects(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    title            TEXT NOT NULL CHECK (length(trim(title)) > 0),
    lifecycle_status TEXT NOT NULL DEFAULT 'pending'
                     CHECK (lifecycle_status IN
                         ('pending', 'not_started', 'in_progress', 'completed', 'abandoned')),
    importance       INTEGER CHECK (importance IS NULL OR (importance BETWEEN 1 AND 5)),
    urgency          INTEGER CHECK (urgency IS NULL OR (urgency BETWEEN 1 AND 5)),
    due_date         TEXT,
    description      TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
) STRICT;

CREATE INDEX idx_work_items_status_created_at
    ON work_items (lifecycle_status, created_at DESC, id DESC);
CREATE INDEX idx_work_items_project_status
    ON work_items (project_id, lifecycle_status);
```

- `project_id` 允许 NULL（未归属）；外键 `ON DELETE RESTRICT`，项目/工作事项均不允许级联删除。
- 生命周期五值按 PRD 5.3 预留 CHECK；T1-03 只写入 `pending`，流转属于 T1-05。
- `importance`/`urgency` 未设置保持 NULL，不伪造评分；本任务不提供填写入口。`pinned_rank` 属于后续排序任务，本 migration 不提前创建。
- 标题不是唯一键，相同标题允许独立记录。
- `LATEST_SCHEMA_VERSION` 由 2 更新为 3，`MIGRATIONS` 追加 0003。

### 1.2 Rust Core

新增 `crates/workmanager-core/src/work_items/`（model / repository / service / error），并从 crate 根导出。

- `WorkItemService::create(database, raw_title, project_id)`：
  - 标题 `trim` 后非空，否则 `work-item-title-empty`；
  - **在同一个 `IMMEDIATE` 写事务内**校验项目：不存在 → `project-not-found`，`is_archived = 1` → `project-archived`（DEC-033）；
  - Rust Core 生成 UUID v4；默认 `lifecycle_status = 'pending'`；时间戳 UTC RFC3339 毫秒；
  - 插入后在同一事务内按 ID 读回权威记录。
- `WorkItemService::list_pending(database)`：`LEFT JOIN projects`，只查询 `lifecycle_status = 'pending'`，按 `created_at DESC, id DESC` 稳定排序；返回项目名称与归档标记，未归属项 `project_id/project_name = None`。
- 所有 SQL 参数绑定；不记录工作标题/项目名称/SQL 参数；无 panic 代替业务错误。
- **P2-02 契约：** `WorkItem` serde camelCase 恰好输出 10 字段；`projectId`/`importance`/`urgency`/`dueDate`/`description` 未设置时输出 JSON `null`（不省略字段）；Rust 测试锁定字段名集合与值类型。

### 1.3 Tauri IPC

新增 `src-tauri/src/commands/work_items.rs` 与 `app_state.rs` 的 `WorkItemContext`：

| 命令 | 请求 | 返回 |
|---|---|---|
| `create_work_item` | `{ input: { title, projectId } }`（`deny_unknown_fields`） | `WorkItemDto`（10 字段） |
| `list_pending_work_items` | 无参数 | `PendingWorkItemDto[]`（每项 8 字段） |

- serde camelCase；`projectId` 显式 `null` 表示未归属（缺省也按 `null` 处理，前端显式传 `null`）；
- 所有数据库操作在 `spawn_blocking` 执行；错误统一 `{code, message}`（含 `work-item-title-empty` / `project-not-found` / `project-archived`）；
- 未新增任意 SQL/文件/命令 IPC。

### 1.4 前端 Contracts / Bridge / UI

- `src/lib/contracts/workItems.ts`：命令名、DTO、请求类型唯一契约来源；`WorkItemDto` 已与 Rust 统一为 10 字段。
- `src/lib/bridge/workItemValidation.ts`：纯运行时严格校验（可被 Node 直接加载）：
  - 必填字段缺失、类型错误、非法 `lifecycleStatus`、**未定义字段**一律拒绝（`ipc-contract-violation`）；
  - `importance`/`urgency` 为 `null` 或 1–5 整数；`dueDate` 为 `null` 或非空字符串；`description` 为 `null` 或字符串；
  - 待安排列表的项目字段语义一致性校验保留。
- `src/lib/bridge/workItems.ts`：`invoke` 封装 + 失败载荷转 `WorkItemIpcError`。
- UI：
  - `TodayPage.svelte`：新增“今日工作 | 待安排”次级视图切换（**不新增一级侧边栏导航**，Sidebar/AppShell/Design Tokens 未修改）；
  - `PendingWorkItemsView.svelte`：页面容器，负责 loading / empty / error / list / 创建 / 权威刷新；**P3-01：创建成功、列表刷新成功、刷新失败三态分开**；
  - `PendingWorkItemList.svelte`：稳定工作事项 ID 作为 keyed each key；
  - `PendingWorkItemRow.svelte`：标题优先、项目辅助信息、未归属显示“未归属项目”、归档历史显示“项目已归档”；
  - `QuickCreateWorkItemDialog.svelte`：仅标题 + 可选未归档项目 + 取消/保存；提交中禁用；错误显示中文消息与稳定错误码；项目在提交前被归档时刷新选项并回退为未归属项目。

---

## 2. 需求 → 实现/证据映射

| 需求 | 实现 | 自动化证据 |
|---|---|---|
| 仅标题即可创建，默认待安排 | `WorkItemService::create` 默认 `pending` | `work_items.rs::creates_pending_work_item_with_title_only`；E2E `create.unassignedRowVisible` / `ipc.unassignedPersisted` |
| 标题 trim；空/纯空白拒绝 | `normalize_title` + DB CHECK 双保险 | `work_items.rs` 标题测试；E2E `ipc.emptyTitleRejected` |
| 相同标题不同 ID、不覆盖 | 无唯一约束；每次新 UUID | `identical_titles_create_distinct_work_items`；E2E 重复提交保护仅 1 条 |
| ID 由 Rust Core 生成 | `Uuid::new_v4()` | `creates_pending_work_item_with_title_only` 校验 UUID；前端无 ID 生成代码 |
| 未归属项目允许创建 | `Option<String>` + 可空外键 | `creates_unassigned_work_item_and_lists_it`；E2E `pending-unassigned.png` |
| 未归档项目可关联 | 事务内 `is_archived = 0` 校验 | `creates_work_item_linked_to_unarchived_project`；E2E `create.linkedRowShowsProjectName` |
| 不存在项目拒绝 | `project-not-found` | `rejects_unknown_project_id_without_writing_rows`；E2E `ipc.missingProjectRejected` |
| **已归档项目拒绝（DEC-033）** | 同一 IMMEDIATE 事务内校验 | 领域测试 + 并发测试；E2E `race.projectArchivedErrorShown` / `ipc.archivedProjectRejectedEvenWithoutUiFilter` |
| 项目选择器只展示未归档项目 | 前端过滤 `isArchived === false` | E2E `create.selectorOnlyUnarchivedProjects` 等 |
| 归档不删除/改写既有工作关联 | 归档只更新 projects；FK RESTRICT；LEFT JOIN | `preserves_existing_link_after_project_archived`；E2E `archivedProject.historyLinkStillListed` |
| 待安排只返回 pending | SQL `WHERE lifecycle_status = ?1` | `pending_query_excludes_other_lifecycle_statuses` |
| 排序稳定、可测试 | `created_at DESC, id DESC` | `pending_query_ordering_is_stable` |
| 关闭重开数据仍在 | SQLite 持久化 | `database_persists_work_items_across_reopen`；E2E 重启阶段 17/17 + DB 探针 |
| camelCase / 未知字段拒绝 | 请求 serde；响应严格契约 | Rust 命令契约测试 6 项；E2E `ipc.unknownFieldRejected` / `ipc.snakeCaseProjectIdRejected` |
| **Rust/TS 完整 DTO 一致（P2-02）** | 10 字段 `WorkItemDto` + 严格校验 | Rust 2 项完整序列化测试；Bridge 17/17（含字段缺失/类型/NULL/未知字段）；真实创建响应经 Bridge 校验 |
| Bridge 运行时校验 | `workItemValidation.ts` | Node 17/17；E2E 传输层伪造非法 DTO → `ipc-contract-violation` |
| 重复提交保护 | 同步守卫 + 提交中禁用 | E2E `create.doubleSubmitCreatesSingleRecord` |
| 创建成功后重新读取后端列表 | `loadPending` 权威刷新 | E2E 每次创建后行数/数据库探针一致 |
| **创建/刷新提示时机（P3-01）** | 三态分离；刷新成功后才提示已更新 | E2E 延迟刷新中间态/成功态、刷新失败 warning、重试恢复、无重复创建 |
| **UAT 路径安全（P3-02）** | Windows 原生句柄：拒绝未批准 Junction/Symbolic Link/其他 reparse point；真实最终路径 + 卷身份校验；专用根目录/正式目录/旧库/非空目录限制；无法确认时 fail closed | 路径安全专项 **60 项 0 FAIL（原有 23 + 新增 37；1 项 Symbolic Link 因权限限制 SKIP、不计 PASS）**；7 类真实 Junction 场景全部拒绝；失败场景无副作用；编排脚本对不安全目录退出码 2 |

---

## 3. 文件清单（本轮与 T1-03 相关）

### 本轮（第六轮）修复新增/修改（相对第五轮审计基准 `6ddae47`）

| 文件 | 变更 |
|---|---|
| `scripts/verify/T1-03UatPath.ps1` | P1/F2：新增 `Get-T103ValidatedTrackedLinkRecords`（删除前全量验证跟踪链接：只允许沙箱直接子项，记录链接对象卷序列号 + File ID + reparse tag）；重写 `Invoke-T103FailClosedSandboxCleanup`（父目录链原生校验 → 先验证全部链接 → 删除前全沙箱扫描 → 精确对象删除 + 逐链接原生复验 → 残余扫描 → 身份复验 → 安全递归删除）；`Remove-T103VerifiedDirectoryTree` 增加仅测试 `-FaultHook`。P2/F1：`Assert-T103EvidenceWritePath` 增加 `-RequireRootIdentity`，`Write-T103EvidenceFile` 强制要求启动时证据根身份。P3：新增 `Write-T103VerifiedOutputFile`（原生路径检查 + 输出目录身份复验 + 普通单硬链接检查）。P4：结果新增 `recursiveDeleteStarted` / `recursiveDeleteCompleted` / `recursiveDeletePartial`（失败在删除开始后返回 `recursiveDeleteFailed` 并说明部分删除） |
| `scripts/verify/test-t1-03-uat-path.ps1` | 新增 12 项目标检查 + `evidence.round6NewChecksPresent` 汇总硬校验（F2 外部跟踪链接 3 项、P4 部分删除 2 项、F1 身份必需 3 项、P3 摘要守卫 3 项、B5 占位 1 项）；`Test-EvidenceWriteRejected` 显式传入注入证据目录身份；合成测试根 Junction 不再登记为跟踪链接；未跟踪重解析点用例在 fail-closed 停止后显式清理仍存在的跟踪链接；`Format-EvidencePath` 统一 `<uat-root>`；新增 B5 扫描模式与 `evidence.uatRootPlaceholderUnified` |
| `scripts/verify/verify-t1-03-ui.ps1` | 创建 UAT 输出目录后记录身份（失败 fail closed）；最终摘要改为经 `Write-T103VerifiedOutputFile` 写入（原生路径复验 + 目录身份复验），成功打印 `PASS summary.writeGuard`；验证脚本时序加固：`Set-WindowSize` 有限重试 + `GetClientRect` 真实客户区核对（仅测试脚本，产品 UI 未修改） |
| `scripts/verify/probe-round6-red.ps1` | **新增**：可重复执行的第六轮 Red 探针。`git archive` 修复前基线 + git blob SHA 校验；基线测试脚本入口与基线清理函数在真实 Windows 文件系统对象上复现 F1 越界写入/覆盖 Canary、F2 穿过 Junction 删除外部链接、P4 真实部分删除后语义失真；输出机器可读 JSON + 脱敏原始命令输出；仅使用虚构文件与专用测试目录 |
| `docs/testing/reports/T1-03-assets/evidence/round6-remediation/` | **新增**（不覆盖 round5）：`red/`（Red 证据 JSON + 脱敏原始输出）、`green/`（128 项路径安全证据 + 最终通过轮次 7 个脱敏 E2E JSON + E2E 脱敏命令输出）、`round6-verification-summary.json` 机器可读汇总、`round6-remediation-notes.md`（根因/修复/Red-Green/B1–B5/尝试记录/遗留风险） |
| `docs/testing/reports/T1-03-assets/evidence/round5/round5-verification-summary.json` | B2：修正时间戳语义（真实 `generatedAt` 组装时间 + `pathEvidenceGeneratedAt` / `releaseE2EEvidenceGeneratedAt` / `fixCommitCommittedAt`，旧值保留 `historicalGeneratedAt`）；证据文件内容未覆盖 |
| 历史证据脱敏补正（B5） | `evidence/t1-03-uat-path-evidence.json`（2 处）、`evidence/round4/t1-03-uat-path-evidence.json`（3 处）、`evidence/round5/t1-03-uat-path-evidence.json`（3 处）固定测试根原始名称替换为 `<uat-root>`；只改路径占位，检查结果/计数不变 |
| `docs/testing/reports/T1-03-REPORT.md`、`T1-03-assets/test-counts.txt`、`T1-03-assets/SANITIZATION.md`、`T1-03-assets/README.md`、`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/tasks/T1-03-Quick-Work-Item-Creation.md` | 第六轮状态、测试结果、Red/Green 证据、提交数（B4）、脱敏口径（B5）与遗留风险同步（不覆盖历史轮次记录） |

本轮**未修改产品业务代码**（Rust/前端/迁移/业务 UI 均未改动）；Release EXE 沿用第五轮按本分支 schema 3 重建的构建（10,352,128 字节，SHA-256 `f46c9b0c…2b68`），本轮只重新执行 E2E 回归；构建产物不入库。

### 第五轮修复新增/修改（相对第四轮审计基准 `e8205ca`，历史）

| 文件 | 变更 |
|---|---|
| `scripts/verify/T1-03UatPath.ps1` | F1：新增 `Assert-T103EvidenceWritePath` / `Write-T103EvidenceFile`（证据目录真实身份、真实最终路径、祖先链、重解析点、硬链接、边界，fail closed）；F2：新增 `Get-T103EntryNativeState`、`New-T103CleanupStopResult`、`Invoke-T103SandboxCleanupEntrypoint`（原生入口检查，替代 `Test-Path` 分支）；原生读取 `FileStandardInfo.NumberOfLinks`；`Get-T103NativePathChain` 增加 `-AllowFinalFile`（仅证据文件最终组件允许普通文件，中间组件仍必须是目录） |
| `scripts/verify/test-t1-03-uat-path.ps1` | 入口在任何写操作前记录证据目录身份；证据写入改为 `Write-T103EvidenceFile` 并比对身份；新增 21 项真实文件系统 F1/F2 回归（相对/`..`/绝对越界、Junction、悬空 Junction、硬链接、身份替换、正式数据库、原生检查失败；正常入口、真实不存在、正常/悬空 Junction、父目录重解析点、身份不明、原生检查失败）；链接存在性辅助函数改为原生检查；第三/四轮 91 项检查名称继续硬校验，新增 `evidence.round5NewChecksPresent` |
| `docs/testing/reports/T1-03-assets/evidence/round5/` | **新增**本轮证据（不覆盖 round3/round4）：115 项路径安全证据、`round5-verification-summary.json` |
| `docs/testing/reports/T1-03-assets/README.md`、`test-counts.txt` | 本轮证据索引、复现命令、测试数量与环境 |
| `docs/testing/reports/T1-03-REPORT.md`、`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md` | 本轮最小修复状态、测试结果、证据与遗留风险 |

本轮**未修改产品代码**（Rust/前端/迁移/业务 UI 均未改动）。工作区原有 `target\release\workmanager.exe` 是 schema 4（T1-04）构建，与本分支 schema 3 期望不符，因此按本分支重新构建后用于原有 T1-03 Release E2E 回归；构建产物不入库。

### 第四轮修复新增/修改（相对第三轮审计基准 `489d868`）

| 文件 | 变更 |
|---|---|
| `scripts/verify/T1-03UatPath.ps1` | 新增信任锚验证 `Assert-T103UatTrustedTestRoot`（与普通输出目录校验分离：存在性/真实目录/全部祖先/重解析点/最终路径一致性/卷身份/正式目录排除，缺失不自动创建，fail closed）；新增目录身份记录与比对、无跟随重解析点目录树扫描、fail-closed 沙箱清理 `Invoke-T103FailClosedSandboxCleanup`（身份复验→链接逐个删除并复验→未预期 reparse point 扫描→身份复验→逐条目校验递归删除）；故障注入辅助 |
| `scripts/verify/test-t1-03-uat-path.ps1` | 入口在任何写操作前完成信任锚验证并记录沙箱身份；新增 F1 真实 Junction 根替换/外部 Canary/缺失根/注入参数无副作用子进程测试，F2 正常清理/删除失败注入/链接重建/未跟踪 reparse point/身份替换/失败后 Canary 复检；第三轮 60 项全部保留并硬校验（`evidence.round3ChecksPreserved`），第四轮新增 31 项硬校验（`evidence.round4NewChecksPresent`）；清理改为 fail-closed 且清理安全检查计入退出码 |
| `scripts/verify/verify-t1-03-ui.ps1` | 在任何写操作之前验证专用测试根目录信任锚（F1 防御纵深）；更新安全约束注释 |
| `docs/testing/reports/T1-03-assets/evidence/round4/` | **新增**第四轮证据（不覆盖第三轮）：路径安全证据（93 项）、脱敏后的 UAT 证据 JSON（主 UI/最小窗口/持久化/编排/前置快照/两次数据库探针）、第四轮 19 张实测截图、`round4-verification-summary.json` 机器可读汇总 |
| `docs/testing/reports/T1-03-assets/SANITIZATION.md`、`README.md`、`test-counts.txt` | 第四轮扫描口径与结果、证据索引、测试数量与 P2-01 未关闭状态 |
| `docs/testing/reports/T1-03-REPORT.md`、`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/tasks/T1-03-Quick-Work-Item-Creation.md`、`README.md`、`scripts/verify/README.md` | 第四轮修复状态、命令、结果、证据与遗留风险记录；修正第三轮遗留的 UAT 目录/资产数/提交数/PR 评论数不一致 |

第四轮**未修改产品代码**（Rust/前端/迁移/业务 UI 均未改动），Release EXE 与第二/三轮一致。

### 第三轮修复新增/修改（相对第二轮审计基准）

| 文件 | 变更 |
|---|---|
| `scripts/verify/T1-03UatPath.ps1` | 重写为 Windows 原生句柄路径校验（P3-02）：`CreateFileW` + `GetFileInformationByHandleEx`（重解析属性/文件 ID/卷序列号）+ `GetFinalPathNameByHandleW`；测试根目录及全部已存在组件重解析点拒绝、真实最终路径/卷身份校验、UNC/设备/相对/非法路径 fail closed；保留原有字符串与内容复用保护 |
| `scripts/verify/test-t1-03-uat-path.ps1` | 保留原有 23 项并新增 37 项（合计 60）：真实 Junction 7 类场景、UNC/设备/非法字符/尾部点空白/保留设备名/缺失测试根目录、无副作用与清理语义、证据自检；1 项 Symbolic Link 因权限限制记 SKIP（不计 PASS） |
| `scripts/verify/verify-t1-03-ui.ps1` | 在创建 UAT 目录后、创建 app 目录后、复制 EXE 前后、每次启动应用前重复执行原生路径校验；更新安全约束注释与 TOCTOU 剩余风险说明（P3-02） |
| `docs/testing/reports/T1-03-assets/evidence/*.json` | 按第三轮实测刷新主 UI/最小窗口/持久化/编排/前置快照/数据库探针证据；路径安全证据更新为 60 项；新增 `round3-verification-summary.json` 机器可读第三轮汇总 |
| `docs/testing/reports/T1-03-assets/SANITIZATION.md` | 重写为第三轮复核：扫描范围/结果、旧提交服务端暴露未解决、GitHub Support 清理材料、占位符与遗留风险（P2-01） |
| `docs/testing/reports/T1-03-assets/README.md`、`test-counts.txt` | 第三轮证据索引、复现命令、测试数量与环境（P2-01/P3-02） |
| `docs/testing/reports/T1-03-REPORT.md`、`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/tasks/T1-03-Quick-Work-Item-Creation.md` | 第三轮修复状态、命令、结果、证据与遗留风险记录 |

第三轮**未修改产品代码**（Rust/前端/迁移/业务 UI 均未改动），Release EXE 与第二轮一致。

### 第二轮修复新增/修改（相对第一轮审计基准）

| 文件 | 变更 |
|---|---|
| `docs/testing/reports/T1-03-assets/**` | 删除原始日志；JSON 脱敏；截图/证据更新为第二轮 Release 实测；新增 `SANITIZATION.md`、`t1-03-uat-path-evidence.json`、2 张刷新失败/恢复截图 |
| `crates/workmanager-core/src/work_items/model.rs` | 增加 10 字段序列化契约说明（P2-02） |
| `src-tauri/src/commands/work_items.rs` | 新增完整字段/可空值序列化测试（P2-02） |
| `src/lib/contracts/workItems.ts` | `WorkItemDto` 10 字段 + NULL 语义 + 严格契约说明（P2-02） |
| `src/lib/bridge/workItemValidation.ts` | 严格对象校验（缺字段/未知字段/可空数字/可空字符串）（P2-02） |
| `scripts/quality/work-item-bridge.test.mjs` | 17 项严格契约测试（P2-02） |
| `src/lib/features/work-items/PendingWorkItemsView.svelte` | 创建成功/刷新成功/刷新失败三态与重试（P3-01） |
| `scripts/verify/inspect-t1-03-ui.mjs` | 新增延迟刷新中间态、刷新失败、重试、无重复创建、严格 DTO 覆盖；计数 84 |
| `scripts/verify/inspect-t1-03-min-window.mjs`、`inspect-t1-03-persistence.mjs` | 适配第二轮数据量（5/6 条） |
| `scripts/verify/T1-03UatPath.ps1` | 新增 UAT 输出目录安全校验（P3-02） |
| `scripts/verify/test-t1-03-uat-path.ps1` | 新增 23 项 UAT 路径安全专项测试（P3-02） |
| `scripts/verify/verify-t1-03-ui.ps1` | 接入路径安全校验；数据库探针期望更新（P3-02 + 数据量） |
| `docs/testing/reports/T1-03-REPORT.md`、`docs/STATUS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/development/tasks/T1-03-Quick-Work-Item-Creation.md`、`scripts/verify/README.md` | 第二轮修复状态、命令、结果与证据记录 |

T1-03 主体文件（migration、Rust Core、IPC、Bridge、UI、E2E 脚本等）见第一轮实现提交 `be8d9c2`。

---

## 4. 测试执行结果（第三～六轮，全部真实执行）

### 4.0 第三轮质量门禁与关键结果

| 命令/测试 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | 通过 |
| `cargo test --workspace` | 0 | **124 passed / 0 failed**（18 个测试二进制） |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 0 违规、49/49 |
| `npm run build` | 0 | 构建成功（167 modules） |
| `git diff --check` | 0 | 无空白错误 |
| `scripts/verify/test-t1-03-uat-path.ps1` | 0 | **60 项：FAILED=0，SKIPPED=1（Symbolic Link 权限限制，明确记录、不计 PASS）** |
| `scripts/verify/verify-t1-03-ui.ps1` | 0 | 主 84/84、最小窗口 12/12、持久化 17/17、数据库探针 25/25；两次真实关闭退出码 0 |
| `scripts/verify/verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1（既有 WARN）INFO=15 |
| `scripts/verify/verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 |
| `scripts/verify/verify-t1-02-ui.ps1` | 0 | 主 73/73；最小窗口 12/12；关闭退出码 0 |

第三轮 Release E2E 使用新 UAT 目录 `<uat-root>\t1-03-ui-r3-20261120-081100`；Release EXE 与第二轮一致：
**10,352,128 字节**，SHA-256 **`3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`**（本轮只改验证脚本/文档，产品代码未变）。
开发代理内部对抗性复核（非独立审计）：99 项模块级路径注入 + 17 项编排脚本拒绝集成用例 + 6 项补充检查，0 绕过；复核发现的 Low/Info 形状缺口（尾部点/空白组件、COM0/CONIN$/CONOUT$ 保留名、测试根目录信任锚优先校验）已在最终实现与专项测试中补强；TOCTOU 窗口被实际演示为未消除并记录为剩余风险。机器可读汇总见 `T1-03-assets/evidence/round3-verification-summary.json`。以下 4.1–4.6 为第二轮执行细节（历史记录；产品代码未变，第三轮已重新执行并通过）。

### 4.1 第二轮质量门禁（历史）

| 命令 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | Finished dev profile |
| `cargo test --workspace` | 0 | **124 passed / 0 failed** |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 49/49（22 文件 0 违规） |
| `npm run build` | 0 | 构建成功 |
| `git diff --check` | 0 | 无空白错误（仅 Git 行尾转换 warnings 时也退出 0） |
| `node --test scripts/quality/work-item-bridge.test.mjs` | 0 | **17 passed / 0 failed** |
| `powershell -File scripts/verify/test-t1-03-uat-path.ps1` | 0 | **23/23 PASS** |

### 4.2 Rust 测试分解（124 passed）

| 测试二进制 | 数量 | 说明 |
|---|---|---|
| `workmanager` lib 单测 | 11 | Tauri 适配层（含 T1-03 命令契约 6 项、WorkItemContext 1 项、P2-02 完整序列化 2 项中的 2 项） |
| `workmanager-core` lib 单测 | 32 | 含工作事项 model 5 项 / error 2 项 |
| `work_items.rs` | 16 | 创建/查询/DEC-033/归档保留/排序/外键/并发边界 |
| `work_items_migration.rs` | 4 | 2→3 升级保留数据、重复打开、失败回滚、表约束 |
| 既有 T1-01/T1-02 测试 | 61 | 含 schema 3 期望更新 |
| 合计 | **124** | 基线 90 + T1-03 新增 34；0 failed |

### 4.3 T1-03 Windows Release E2E（第二轮，独立 UAT 目录）

编排命令（P3-02 生效后必须使用专用测试根目录下的新目录）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1 `
    -OutputDir <UAT_ROOT>\t1-03-ui-run4 -Port 9365
```

Release 产物：`target\release\workmanager.exe`，**10,352,128 字节**，
SHA-256 **`3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`**。

| 阶段 | 结果 | 证据 |
|---|---|---|
| 主 UI/IPC 检查 | **84/84 PASS**，exit 0 | `evidence/t1-03-ui-evidence.json` |
| 最小窗口 860×640 + 真实关闭 | **12/12 PASS**，第一次关闭退出码 **0** | `evidence/t1-03-min-window-evidence.json` |
| 关闭 → 重启持久化 | **17/17 PASS**，第二次关闭退出码 **0** | `evidence/t1-03-persistence-evidence.json` |
| 数据库只读探针（关闭后/重启后） | **25/25 PASS** | `evidence/t1-03-db-after-main.json`、`evidence/t1-03-db-after-restart.json` |
| UAT 路径安全专项 | **23/23 PASS** | `evidence/t1-03-uat-path-evidence.json` |
| 汇总 | `T1_03_RELEASE_UI_E2E=PASS` | `evidence/t1-03-ui-orchestration.json` |

数据库探针关键事实（第二轮）：

- 第一次关闭后：`user_version=3`、`integrity_check=ok`、`work_items=5 / pending=5 / 其他状态=0`、未归属 4、关联归档项目 1、外键违规 0；项目 2 个且均归档；
- 重启并再次创建后关闭：`work_items=6 / pending=6 / 其他状态=0`、未归属 5、关联归档项目 1、外键违规 0。

主检查覆盖（第二轮新增/保留）：应用壳与六个一级导航不变、今日工作 → 待安排次级视图、真实异步 loading、空状态、真实 UI 创建未归属/关联未归档项目工作、**创建成功→正在刷新→刷新成功提示时机**、**创建成功但列表刷新失败 warning + 重试 + 不重复创建**、重复提交保护、项目归档竞态错误、绕过 UI 直接 IPC 的后端拒绝、**严格 10 字段 DTO 运行时校验（真实创建响应）**、传输层故障注入（加载失败/重试、Bridge 契约违规）、长标题布局、CSP 0 违规、页面未捕获异常 0、正常窗口无横向溢出。

### 4.4 继承 Release 回归（第二轮，新 EXE）

| 脚本 | 退出码 | 结果 |
|---|---|---|
| `verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 **WARN=1（保留既有 WARN，未改动测试逻辑）** INFO=15，OVERALL=PASS |
| `verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9，OVERALL=PASS |
| `verify-t1-02-ui.ps1` | 0 | 主检查 73/73；最小窗口 12/12；关闭退出码 0；CSP 0；页面异常 0 |

### 4.5 P2-01 脱敏与历史对象复核（第三轮）

| 检查 | 结果 |
|---|---|
| 当前 `T1-03-assets/` 敏感值扫描（33 文件：13 UTF-8 文本 + 1 BOM JSON + 19 PNG，含 PNG 文本块） | **敏感值命中 0**；唯一用户目录前缀出现在 `SANITIZATION.md` 的占位符示例（`C:\Users\<user>`，不含具体账户，非敏感） |
| 分支增量历史深度扫描（`018e851..HEAD`，18 提交 / 5,773 次文件树扫描） | 分支**新增**敏感值命中 **0**；5 条原始命中为本轮文档中的分类描述/占位符文本（`T1-03-REPORT.md`、`SANITIZATION.md`），不含具体机器标识 |
| 原始命令日志是否仍在仓库当前树 | 否（`T1-03-assets/logs/` 不存在，9 个文件在分支增量历史中不可达） |
| 远程 branches / tags / pull refs | 18 个 ref、tags 0 个；无任何远程 ref 含旧提交 `2342828`；`refs/pull/8/head` 为当前 HEAD，`refs/pull/8/merge` 父提交仅 main 基线 + 当前 HEAD |
| PR #8 描述与评论 | 第三轮修复提交前：body 2,091 字符 / SHA-256 `4621bf70…5f660`、2 条评论，扫描 0 命中；**PR 更新后（第三轮状态 + 说明评论）：body 3,001 字符 / SHA-256 `b46e6198…5891`、3 条 issue 评论、0 review comment、0 review，复扫敏感类别 0、旧日志文件名 0** |
| 旧提交服务端可达性 | **未清理**：旧提交 `2342828` commit API HTTP 200；旧 SHA 的 contents API 仍可列出 9 个原始日志（HTTP 200） |
| 本地 backup/bundle | 仅本地 `backup/t1-03-r1-audit-baseline` 与 gitignored bundle，未推送 |

脱敏策略、扫描细节、旧提交暴露与 GitHub Support 清理材料见 [`T1-03-assets/SANITIZATION.md`](T1-03-assets/SANITIZATION.md)。

### 4.6 全仓机器标识扫描（残余风险说明，第三轮）

- 当前 `T1-03-assets/`：敏感值命中 **0**。
- 仓库基线 main 中既有的 T1-01/T1-02 历史证据与日志仍含同类机器信息（954 条原始命中 / 53 个路径，属 main 既有内容，非本 PR 新增；本轮按“不修改 main”要求未处理），作为遗留风险记录。
- 旧提交 `2342828` 的 9 个原始日志仍可经 GitHub 服务端读取（P2-01 未关闭，等待 GitHub Support）。
- 说明：扫描模式在运行时由环境变量动态生成，未硬编码机器标识；只记录类别/计数，不输出具体值。

### 4.7 第四轮执行结果（2026-11-20，全部真实执行）

| 命令/测试 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | 通过 |
| `cargo test --workspace` | 0 | **124 passed / 0 failed**（18 个测试二进制） |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 0 违规、49/49 |
| `npm run build` | 0 | 构建成功（167 modules） |
| `node --test scripts/quality/work-item-bridge.test.mjs` | 0 | 17/17 passed |
| `git diff --check` | 0 | 无空白错误 |
| `scripts/verify/test-t1-03-uat-path.ps1`（第四轮证据路径） | 0 | **93 项：FAILED=0，SKIPPED=1（Symbolic Link 权限限制，明确记录、不计 PASS）**；第三轮 60 项全部保留；F1/F2 新增 31 项全部存在；信任锚 PASS；沙箱清理 SAFE（11 步、无遗留） |
| `scripts/verify/verify-t1-03-ui.ps1`（UAT `<uat-root>\t1-03-ui-r4-20261120-181549`） | 0 | 主 84/84、最小窗口 12/12、持久化 17/17、数据库探针 25/25；两次真实关闭退出码 0/0；CSP 0；页面异常 0 |
| `scripts/verify/verify-release-portable.ps1` | 0 | TOTAL=106 PASS=90 FAIL=0 WARN=1（既有 WARN）INFO=15 |
| `scripts/verify/verify-release-faults.ps1` | 0 | TOTAL=73 PASS=64 FAIL=0 WARN=0 INFO=9 |
| `scripts/verify/verify-t1-02-ui.ps1` | 0 | 主 73/73；最小窗口 12/12；关闭退出码 0（首次执行出现窗口尺寸/加载超时的环境性失败，在无并发负载下单独重跑通过；产品代码与 T1-02 验证脚本未修改） |

第四轮 Release EXE 与第二/三轮一致：**10,352,128 字节**，SHA-256 **`3f12bbce1c8abb2244d65e814264662f56a982caf1875103a821cb17e8bfa9e3`**（本轮只改验证脚本/文档，产品代码未变）。

F1/F2 第四轮专项证据摘要（详见 `evidence/round4/t1-03-uat-path-evidence.json`）：

- F1：入口在写操作前完成信任锚验证；真实 Junction 替换测试根 + 外部 Canary 的真实入口子进程 exit=2、拒绝执行、Canary 文件内容与目录结构不变、未创建沙箱、未写默认证据、默认测试根目录未被触碰；测试根缺失场景 exit=2 且未自动创建；`-TestRootOverride` 注入到合法普通目录也不会执行完整套件。
- F2：正常清理 SAFE；4 类故障场景（删除失败由受控 FaultHook 在 `beforeLinkDelete` 阶段抛出确定性异常、未修改 Windows ACL且未实测 `Access Denied`；删除后链接重建、未跟踪 reparse point、清理前身份替换使用真实文件系统对象验证）分别得到 `trackedLinkDeleteFailed` / `trackedLinkStillExists` / `unexpectedReparsePoint` / `sandboxIdentityChanged`，全部 `recursiveDeletePerformed=false`、沙箱与外部目标保留；失败后重新检查 5 个外部 Canary 全部不变。
- 第三轮 60 项检查全部保留（`evidence.round3ChecksPreserved` 通过）；第四轮新增 31 项全部存在（`evidence.round4NewChecksPresent` 通过）。

### 4.8 第四轮 P2-01 脱敏与历史对象复扫（2026-11-20）

扫描时点：第四轮证据同步提交（`origin/main..HEAD` = 22 个提交）；扫描模式由运行环境动态生成、不硬编码。第三轮遗留的 UAT 目录（`075440` → 正确值 `081100`）、资产数（33 → 34，第四轮共 62）、提交数（18 → 20 → 22）、PR 评论数（3 → 4）与正文统计已按本轮实测统一修正。

| 检查 | 结果 |
|---|---|
| 当前 `T1-03-assets/` 敏感值扫描（62 文件：38 PNG、21 JSON、3 文本，含 PNG 文本块） | **具体机器标识命中 0**；`C:\Users\` 仅出现在脱敏说明的占位符示例（`C:\Users\<user>`），不含具体账户 |
| 分支增量历史深度扫描（`018e851..HEAD`，22 提交 / 7269 次文件树扫描 / 449 个唯一 blob） | 新增具体机器标识命中 **0**；第三轮口径可比的原始命中 17 条，全部为文档分类描述/占位符/通用路径文本 |
| 原始命令日志是否仍在仓库当前树 | 否（`T1-03-assets/logs/` 不存在，当前 HEAD 树文件数 0，分支增量历史中不可达） |
| 远程 branches / tags / pull refs | **18 个 ref、tags 0 个**：8 branches + 7 pull heads + 2 pull merges + HEAD；无任何远程 ref 指向旧提交 `2342828`；`refs/pull/8/head` 为本分支 HEAD；旧提交不是当前 HEAD 祖先（`merge-base --is-ancestor` 退出码 1） |
| PR #8 描述与评论 | 第四轮更新后：正文 **3,957 字符 / SHA-256 `725d5df32469c4873e6b347b07039122a3996ff65bda341a0ee6b248f43e0ae0`**；**4 条 issue 评论**（新增第三轮审计结论评论）、0 review comment、0 review；具体机器标识命中 0；旧日志文件名命中 1（仅第三轮审计结论评论中的旧对象说明引用，非日志正文）；旧提交 SHA 引用 3（公开 SHA，非机器标识） |
| 旧提交服务端可达性 | **未清理**：旧提交 `2342828` commit API HTTP 200；旧 SHA 的 contents API 仍可列出 9 个原始日志（HTTP 200，合计 147,009 字节） |
| 本地 backup/bundle | 仅本地 `backup/t1-03-r1-audit-baseline` 与 gitignored bundle（3,633,177 字节），未推送 |
| main 基线既有同类信息 | 属 main 既有内容、非本 PR 新增（如 T1-02 证据中 1 处仓库路径与 `origin/main` 同 blob）；本轮未修改 |

脱敏策略、扫描细节、旧提交暴露与 GitHub Support 清理材料见 [`T1-03-assets/SANITIZATION.md`](T1-03-assets/SANITIZATION.md)。

### 4.9 本轮（2026-11-26）执行结果（F1/F2 最小修复，全部真实执行）

| 命令/测试 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | 通过 |
| `cargo test --workspace` | 0 | **124 passed / 0 failed**（18 个测试二进制） |
| `npm run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 0 违规、49/49 |
| `npm run build` | 0 | 构建成功（167 modules） |
| `node --test scripts/quality/work-item-bridge.test.mjs` | 0 | 17/17 passed |
| `git diff --check` | 0 | 无空白错误 |
| `scripts/verify/test-t1-03-uat-path.ps1 -EvidencePath docs\testing\reports\T1-03-assets\evidence\round5\t1-03-uat-path-evidence.json` | 0 | **115 项：FAILED=0，SKIPPED=1（Symbolic Link 权限限制，明确记录、不计 PASS）**；第三轮 60 项 + 第四轮 31 项全部保留；本轮 21 项全部存在；信任锚 PASS；沙箱清理 SAFE（11 步、无遗留） |
| `scripts/verify/verify-t1-03-ui.ps1 -OutputDir <uat-root>\t1-03-ui-r5b-20261126-183147 -Port 9371` | 0 | 主 84/84、最小窗口 12/12、持久化 17/17、数据库探针 25/25；两次真实关闭退出码 0/0；CSP 0；页面异常 0；19 张截图（未复制入仓，见下） |

**本轮 F1（证据写入边界）实测（详见 `evidence/round5/t1-03-uat-path-evidence.json`）：**

- 正常写入注入证据目录（含新建子目录）成功并回读内容一致；
- 相对路径越界（相对仓库根解析后仍在证据目录外）、`..` 穿越、证据目录外绝对路径全部拒绝，且未创建文件；
- 证据目录内真实 Junction、真实悬空 Junction（tag `0xA0000003`）全部拒绝，链接目标 Canary 未变；
- 已存在目标文件是业务数据库的**真实硬链接**（`NumberOfLinks=2`）时拒绝，业务文件 SHA-256 不变；
- 证据目录被替换（rename + 重建，真实 File ID 变化）后按启动时身份记录拒绝；
- 正式数据库目标 `D:\WorkManager\data\database\work.db` 拒绝，`D:\WorkManager` 前后均不存在；
- 请求路径组件是文件（真实原生路径检查失败）时 fail closed，未写入子路径；
- 全部拒绝用例后业务数据库与守护 Canary 内容/哈希不变。

**本轮 F2（沙箱入口原生检查）实测：**

- 正常入口：原生身份检查通过（`sandbox.identityVerified`、`tree.noUnexpectedReparsePoint`、`sandbox.identityReVerified`），逐条目安全递归删除；
- 真实不存在：原生检查确认后按原规则返回 `sandboxAlreadyAbsent`，不创建目录；
- 正常 Junction：`sandboxEntryIsReparsePoint`（tag `0xA0000003`），不递归、目标 Canary 不变、链接保留；
- 悬空 Junction（入口本身）：原生识别链接本身，`sandboxEntryIsReparsePoint`，不递归、链接保留；
- 悬空 Junction 之下的路径（`Test-Path=False`）：旧表达式本会返回 `sandboxAlreadyAbsent`；修复后 `sandboxParentIsReparsePoint`，`recursiveDeletePerformed=false`，悬空链接仍存在；
- 父目录是 Junction：`sandboxParentIsReparsePoint`，不创建目标子目录、链接保留；
- 身份不明：`sandboxIdentityChanged`，沙箱与 sentinel 保留；
- 原生路径检查失败（组件是文件）：`sandboxEntryNativeCheckFailed`，不递归。

**Red 证据（修复前，真实文件系统）：**

- F1：直接调用旧写入逻辑把证据写到仓库证据目录之外成功（`test-artifacts\f1f2\baseline-evidence.json`，34,904 字节，SHA-256 `570142DD…33A`），并覆盖业务 Canary 文件（SHA-256 `34C1181F…180` → `66347408…568`）、自动创建越界父目录；
- F2：真实悬空 Junction 之下路径 `Test-Path=False`；旧分支表达式 `-not (Test-Path -LiteralPath $sandbox)` 返回 True（本会 `sandboxAlreadyAbsent`），修复后同一对象返回 `sandboxParentIsReparsePoint`。Windows PowerShell 5.1 对悬空 Junction **本身**的 `Test-Path` 返 True，因此本轮不声称“悬空 Junction 本身 Test-Path 必为 False”；绕过成立的是**其下路径**。

**Release EXE 与首次 E2E 失败说明：** 工作区原有 `target\release\workmanager.exe` 是 schema 4（T1-04）构建（`user_version=4`、migrations 1–4），与 T1-03 schema 3 期望不符，首次 E2E 因此失败（exit 1）；本轮按本分支重新构建（**10,352,128 字节**，SHA-256 `f46c9b0cb3c9d094475cab6abd8276276126f2ea0d2e5b38b6d6a4fbf92b2b68`）后重跑通过。构建产物不入库；首次失败尝试保留在机器本地 UAT 目录，不计为本轮结果。

**证据：** 本轮 7 个 E2E JSON 已脱敏复制到 `evidence/round5/`（`<uat-root>` / `<repo-root>` 占位）；19 张截图未复制入仓（产品 UI 未修改，第四轮截图仍有效，截图保留在机器本地 UAT 目录）。本轮未执行 Windows ACL `Access Denied` 测试；Symbolic Link 场景仍 SKIP。

### 4.10 本轮（第六轮，2026-11-27）执行结果（P1–P4 + B1–B5，全部真实执行）

| 命令/测试 | 退出码 | 结果 |
|---|---|---|
| `cargo fmt --all -- --check` | 0 | 无差异 |
| `cargo check --workspace --all-targets` | 0 | 通过 |
| `cargo test --workspace` | 0 | **124 passed / 0 failed**（18 个测试二进制） |
| `npm.cmd run check` | 0 | svelte-check 0 errors / 0 warnings；Bridge 17/17；Design Token 22 文件 0 违规、49/49 |
| `npm.cmd run build` | 0 | 构建成功（167 modules） |
| `node --test scripts/quality/work-item-bridge.test.mjs` | 0 | 17/17 passed |
| `git diff --check` | 0 | 无空白错误 |
| `scripts/verify/test-t1-03-uat-path.ps1 -EvidencePath docs\testing\reports\T1-03-assets\evidence\round6-remediation\green\t1-03-uat-path-evidence.json` | 0 | **128 项：FAILED=0，SKIPPED=1（Symbolic Link 权限限制，明确记录、不计 PASS）**；原 115 项全部保留；第六轮 12 项目标检查 + 汇总自校验全部存在；信任锚 PASS；沙箱清理 SAFE（15 步：身份 + 父链 + 链接全量验证 + 删除前扫描 + 精确删除 + 残余扫描 + 身份复验 + 递归删除 started/completed） |
| `scripts/verify/verify-t1-03-ui.ps1 -OutputDir <uat-root>\t1-03-ui-r6f-20261127-071753 -Port 9395` | 0 | 主 UI/IPC 84/84、最小窗口 12/12、持久化 17/17、数据库探针 25/25；两次真实关闭退出码 0/0；CSP 0；页面未捕获异常 0；19 张截图（未复制入仓）；`PASS summary.writeGuard` |
| `scripts/verify/probe-round6-red.ps1` | 0 | `R6_RED_PROBE=PASS`、`redConfirmed=true`：修复前基线 F1 越界写入/覆盖 Canary、F2 穿过 Junction 删除外部链接、P4 部分删除语义失真均真实复现（详见 `red/round6-red-evidence.json`） |

**P1 / F2 实测（`evidence/round6-remediation/green/t1-03-uat-path-evidence.json`）：**

- `f2.trackedLinkThroughJunctionRejectedBeforeDelete`：真实 `sandbox\evil(Junction)->external` + `external\victim-link(Junction)->victim-target`，把 `sandbox\evil\victim-link` 传入 `TrackedLinks` → `safe=false`、`stopCode=trackedLinkNotDirectChild`、`recursiveDeleteStarted=false`、`recursiveDeletePerformed=false`；**在删除任何对象之前失败**；
- `f2.trackedLinkThroughJunctionExternalTargetIntact`：victim-link 仍存在，victim-target Canary 内容与 SHA-256 不变；
- `f2.trackedLinkThroughJunctionSandboxPreserved`：沙箱、evil Junction、sentinel 均保留；
- 原有 F2 回归（正常清理、删除失败注入、链接重建、未跟踪重解析点、身份替换、入口/父目录/悬空 Junction）全部继续 PASS；跟踪链接只允许沙箱直接子项的收紧已同步修正测试自身对“合成测试根 Junction”的登记方式和未跟踪重解析点用例的自清理顺序。

**P2 / F1 实测：**

- `f1.evidenceWriteMissingRootIdentityRejected`：注入隔离证据目录 + 不提供启动身份 → 拒绝（消息含“身份”），未创建文件；
- `f1.evidenceDefaultRootWriteMissingRootIdentityRejected`：默认证据根 + 不提供启动身份 → 拒绝，未创建文件；
- `f1.evidenceWriteWithPinnedRootIdentitySucceeds`：显式传入该隔离目录身份 → 正常写入并回读一致（保留独立测试隔离 EvidenceRoot 的能力）；
- 原有相对/`..`/绝对越界、Junction、悬空 Junction、硬链接、目录身份替换、正式目录、原生检查失败等拒绝用例继续 PASS。

**P3 实测：**

- `f3.outputSummaryGuardNormalWriteSucceeds`：正常 UAT 输出目录经守卫写入摘要成功；
- `f3.outputSummaryGuardRejectsJunctionSwap`：输出目录 rename 后替换为真实 Junction 指向外部目录 → 拒绝（关键词“重解析点/身份”），外部目录未出现摘要文件、外部 Canary SHA-256 不变；
- `f3.outputSummaryGuardRejectsIdentityChange`：输出目录 rename + 重建（真实 File ID 变化）→ 按启动身份拒绝且不写文件；
- Release E2E 中 `PASS summary.writeGuard` 证明生产编排路径确实经过该守卫。**DEC-029：检查与写入之间的并发替换窗口仍存在，未消除。**

**P4 实测：**

- `f2.recursiveDeletePartialFailureReported`：第 2 个真实条目删除时受控异常 → `safe=false`、`stopCode=recursiveDeleteFailed`、`recursiveDeleteStarted=true`、`recursiveDeleteCompleted=false`、`recursiveDeletePerformed=false`、`recursiveDeletePartial=true`、`stopReason` 含“部分删除”；
- `f2.recursiveDeletePartialFailureRealDeletionsObserved`：真实删除至少 1 个条目、沙箱保留；
- 修复前基线复现（探针）：真实 sharing violation 下 7 个条目删到剩 1 个，旧结果仍 `recursiveDeletePerformed=false` 且无 `recursiveDeleteStarted` 字段。

**Release E2E 尝试记录（失败尝试不计入通过结果，全部真实执行）：**

1. `t1-03-ui-r6-20261127-071251`：exit 1。与 Red 探针/基线套件并发执行时应用壳渲染超时（`hasAppShell=false`）、首次关闭进程未退出；判定为并发负载环境性失败。
2. `t1-03-ui-r6c-20261127-071613`、`t1-03-ui-r6d-20261127-071634`：exit 1。主 UI 84/84、持久化 17/17、数据库 25/25、关闭 0/0 均通过，仅 `minWindow.sizeNear860x640` 失败（窗口保持默认 1100×780）；同轮最小窗口其余 11 项布局断言全部通过，确认是应用启动后回写初始窗口尺寸与单次 `SetWindowPos` 的时序竞态，属验证脚本环境问题。
3. 验证脚本加固（仅 `scripts/verify/verify-t1-03-ui.ps1`）：`Set-WindowSize` 有限重试 + `GetClientRect` 真实客户区核对；不涉及产品代码/UI 修改。
4. `t1-03-ui-r6e-20261127-071732`、`t1-03-ui-r6f-20261127-071753`：连续两次 exit 0、`T1_03_RELEASE_UI_E2E=PASS`；最终采用 r6f 证据（已脱敏复制到 `green/`）。

**B2 / B4 / B5 修正：**

- B2：`evidence/round5/round5-verification-summary.json` 原 `generatedAt=2026-11-26T10:20:23Z` 早于其包含的路径证据（`10:20:23.6531600Z`）、E2E 证据（`10:32:09.2478282Z`）与修复提交（`18:37:26+08:00`），已拆分为真实 evidence 时间 + 真实汇总组装时间，旧值保留在 `historicalGeneratedAt`；历史证据文件内容未覆盖。
- B4：`origin/main..e8205ca=25`、`..6ddae47=27`、`..e3bb86b=28`、`..最终 HEAD=30`；旧报告 22 个提交不再作为当前状态引用。
- B5：固定测试根统一 `<uat-root>`；新增 `evidence.uatRootPlaceholderUnified` 检查；历史证据 3 个文件共 8 处占位修正（只改路径、不改结果）；机器标识扫描规则未放宽；T1-03 证据目录固定测试根原始名称命中 0。

---

## 5. Windows Release 实测步骤与结果（第二轮步骤；第三、四、五、六轮已重新执行并通过）

在专用测试根目录下的全新 UAT 目录（虚构数据）实际执行：

| 步骤 | 结果 | 证据 |
|---|---|---|
| 1. Release 程序启动（新 EXE） | PASS（主窗口 1100×780，应用壳渲染） | 主检查 84/84 |
| 2. 创建未归属工作（含刷新提示时机） | PASS（延迟刷新时提示“正在刷新”；刷新成功后提示“已从数据库更新”） | `pending-unassigned.png`、主检查 timing 断言 |
| 3. 创建关联有效项目的工作 | PASS（选择器展示未归档项目） | `pending-linked-project.png` |
| 4. 归档一个项目 | PASS（项目记录保留） | `setup.projectArchived` |
| 5. 归档项目不再出现在新建选择器 | PASS（选项仅剩未归属项目） | `race.archivedProjectRemovedFromSelector` |
| 6. 直接向 IPC 传归档项目 ID | PASS：`project-archived`，未创建记录 | `ipc.archivedProjectRejectedEvenWithoutUiFilter` |
| 7. 该项目之前关联的工作仍存在 | PASS（显示项目名称 + “项目已归档”） | `pending-archived-project.png` |
| 8. 创建成功但列表刷新失败 | PASS：warning 提示、不重复创建、重新加载后恢复 | `pending-create-refresh-failure.png`、`pending-create-refresh-recovered.png` |
| 9. 关闭程序（真实红色关闭按钮） | PASS（退出码 0） | 编排 JSON `firstCloseExitCode=0` |
| 10. 重新启动同一目录并验证持久化 | PASS（5 条既有工作仍在；重启后新建 1 条；数据库/UI 一致） | `pending-after-restart.png`、`t1-03-db-after-restart.json` |
| 11. UAT 目录安全（P3-02 第三轮） | PASS：C 盘/正式目录/根目录外/`..` 越界/旧数据库/非空目录拒绝；真实 Junction（测试根本身/中间组件/输出目录/指向正式目录/指向 C 盘/指向根内）全部拒绝；校验失败时不创建/不复制/不写数据库；既有内容未被删除或覆盖 | `t1-03-uat-path-evidence.json`（60 项） |

固定窗口（默认 1100×780）与最小支持窗口（860×640）截图见 `screenshots/`；最小窗口下无横向溢出、无内容遮挡、按钮可点击、长标题省略且保留完整 `title` 属性；CSP 0 违规、页面未捕获异常 0。

---

## 6. 截图索引（第三轮 `screenshots/` 19 张；第四轮 `evidence/round4/screenshots/` 19 张）

| 截图 | 内容 |
|---|---|
| `today-entry.png` | 今日工作页面 + “今日工作 / 待安排”次级视图入口（一级导航仍为 6 项） |
| `pending-loading.png` | 待安排真实异步 loading 状态 |
| `pending-empty.png` | 待安排空状态 + 创建入口 |
| `create-dialog.png` | 快速创建对话框（仅标题 + 可选项目） |
| `pending-unassigned.png` | 创建未归属工作后的待安排列表 |
| `create-dialog-projects.png` | 项目选择器只展示未归档项目 |
| `pending-linked-project.png` | 关联未归档项目的工作 |
| `create-error-project-archived.png` | 项目在提交前被归档：`project-archived` 错误 + 选项刷新 |
| `pending-archived-project.png` | 历史关联保留并显示“项目已归档” |
| `pending-load-error.png` | 列表加载失败 + 重新加载 |
| `pending-contract-violation.png` | Bridge 运行时契约违规被 UI 捕获（`ipc-contract-violation`） |
| **`pending-create-refresh-failure.png`** | **P3-01：创建成功但列表刷新失败的 warning + 错误面板 + 重试入口** |
| **`pending-create-refresh-recovered.png`** | **P3-01：重新加载成功后的恢复状态** |
| `pending-long-title.png` | 超长标题单行省略，无横向溢出 |
| `pending-min.png` | 最小窗口 860×640 待安排列表 |
| `create-dialog-min.png` | 最小窗口快速创建对话框完整可见 |
| `pending-after-restart.png` | 关闭重开后的待安排列表（持久化） |
| `create-dialog-after-restart.png` | 重启后选择器仍只含未归档项目 |
| `pending-after-restart-new-item.png` | 重启后仍可创建新工作并立即出现 |

第四轮重新执行 Release E2E 时在 `<uat-root>\t1-03-ui-r4-20261120-181549` 生成同名场景的 19 张实测截图，已存入
`evidence/round4/screenshots/`（不覆盖第三轮截图）；产品 UI/代码未变。第五轮、第六轮重新执行 E2E 生成的 19 张同名场景截图未复制入仓（产品 UI 未修改，第三/四轮截图仍有效），截图保留在机器本地 UAT 目录；第六轮最终通过的 UAT 目录为 `<uat-root>\t1-03-ui-r6f-20261127-071753`。

---

## 7. 证据文件索引（`docs/testing/reports/T1-03-assets/`）

```text
evidence/
  t1-03-ui-evidence.json                      # 第三轮主 UI/IPC 84 项断言 + 截图/异常/CSP
  t1-03-min-window-evidence.json              # 第三轮最小窗口 12 项断言 + 关闭点击
  t1-03-persistence-evidence.json             # 第三轮重启持久化 17 项断言
  t1-03-uat-path-evidence.json                # 第三轮 UAT 路径安全 60 项（1 项 SKIP 不计 PASS）
  t1-03-ui-orchestration.json                 # 第三轮编排汇总（退出码、计数、EXE SHA、截图清单）
  t1-03-prerequisite.json                     # 第三轮重启阶段前的真实 IPC 数据快照（虚构）
  t1-03-db-after-main.json                    # 第三轮关闭后数据库只读探针
  t1-03-db-after-restart.json                 # 第三轮重启后数据库只读探针
  round3-verification-summary.json            # 第三轮机器可读汇总（保留历史，不覆盖）
  release-regression-portable-summary.json    # 继承便携验证详细证据（第二轮提交版本；第四轮复跑 106 项结果见 round4 汇总）
  release-regression-faults-summary.json      # 继承异常注入详细证据（第二轮提交版本；第四轮复跑 73 项结果见 round4 汇总）
  release-regression-t1-02-ui-orchestration.json # 继承 T1-02 UI E2E（第二轮提交版本；第四轮复跑通过）
  round4/t1-03-uat-path-evidence.json         # 第四轮路径安全 93 项（第三轮 60 项保留；F1/F2 新增 31 项；SKIP=1）
  round4/t1-03-ui-evidence.json               # 第四轮主 UI/IPC 84 项断言
  round4/t1-03-min-window-evidence.json       # 第四轮最小窗口 12 项断言
  round4/t1-03-persistence-evidence.json      # 第四轮重启持久化 17 项断言
  round4/t1-03-ui-orchestration.json          # 第四轮编排汇总（两次关闭退出码 0/0、84/12/17/25）
  round4/t1-03-prerequisite.json              # 第四轮重启前 IPC 数据快照（虚构）
  round4/t1-03-db-after-main.json             # 第四轮关闭后数据库只读探针
  round4/t1-03-db-after-restart.json          # 第四轮重启后数据库只读探针
  round4/round4-verification-summary.json     # 第四轮机器可读汇总（F1/F2/门禁/E2E/回归/扫描/P2-01）
  round4/screenshots/                         # 第四轮 19 张真实 Release WebView2 截图
  round5/t1-03-uat-path-evidence.json         # 第五轮路径安全 115 项（F1 证据写入边界 + F2 沙箱入口原生检查；SKIP=1）
  round5/t1-03-ui-evidence.json               # 第五轮主 UI/IPC 84 项断言（脱敏）
  round5/t1-03-min-window-evidence.json       # 第五轮最小窗口 12 项断言（脱敏）
  round5/t1-03-persistence-evidence.json      # 第五轮重启持久化 17 项断言（脱敏）
  round5/t1-03-ui-orchestration.json          # 第五轮编排汇总（两次关闭退出码 0/0、84/12/17/25；脱敏）
  round5/t1-03-prerequisite.json              # 第五轮重启前 IPC 数据快照（虚构；脱敏）
  round5/t1-03-db-after-main.json             # 第五轮关闭后数据库只读探针（脱敏）
  round5/t1-03-db-after-restart.json          # 第五轮重启后数据库只读探针（脱敏）
  round5/round5-verification-summary.json     # 第五轮机器可读汇总（B2 已修正时间戳语义；历史证据内容未覆盖）
  round6-remediation/round6-verification-summary.json  # 第六轮机器可读汇总（P1–P4 修复、128 项路径安全、Red/Green、门禁、E2E、B1–B5、遗留风险）
  round6-remediation/round6-remediation-notes.md       # 第六轮修复/证据说明（根因、TDD Red-Green、Skill 使用、E2E 尝试记录、范围与限制）
  round6-remediation/red/round6-red-evidence.json      # 第六轮 Red 证据（修复前基线 e8205ca 真实复现：F1/F2/P4）
  round6-remediation/red/round6-red-command-output.sanitized.log.txt  # Red 探针脱敏原始命令输出
  round6-remediation/green/t1-03-uat-path-evidence.json               # 第六轮路径安全 128 项绿色证据
  round6-remediation/green/t1-03-ui-evidence.json、t1-03-min-window-evidence.json、t1-03-persistence-evidence.json  # 第六轮最终通过轮次 E2E 实测断言（脱敏）
  round6-remediation/green/t1-03-ui-orchestration.json、t1-03-prerequisite.json、t1-03-db-after-main.json、t1-03-db-after-restart.json  # 第六轮 E2E 编排汇总/快照/数据库探针（脱敏）
  round6-remediation/green/round6-e2e-command-output.sanitized.log.txt # 第六轮最终通过轮次 E2E 脱敏命令输出
test-counts.txt                               # 第六轮测试数量/环境/数据库探针关键事实速查
SANITIZATION.md                               # 脱敏扫描（含第六轮 B5 补正）、旧提交服务端暴露与 GitHub Support 清理材料
```

说明：原始命令日志（包含计算机名/账户名/本地绝对路径）已按 P2-01 要求从仓库删除，当前证据 JSON/文本已脱敏；
第五轮复核与第六轮补正确认旧提交 `2342828` 及 9 个原始日志仍可经 GitHub 服务端读取，**P2-01 未关闭**，需 GitHub Support
处理（材料见 `T1-03-assets/SANITIZATION.md` 第 4 节）。第三、四、五、六轮均未修改产品 UI/业务代码，第二/三轮同名场景截图保留；
第四轮重新执行 E2E 生成的截图位于 `evidence/round4/screenshots/`，未覆盖第三轮截图；第五/六轮截图未复制入仓。
第六轮 B5 补正只把历史证据中的固定测试根原始名称替换为 `<uat-root>`（不改任何检查结果/计数），并加强脱敏扫描规则与专项检查。

---

## 8. 明确未实现 / 未修改

- 未实现 T1-04 多项目独立副本创建；T1-05 生命周期状态流转与历史；每日计划/未来 7 天；重要/紧急评分、全局优先级、手动置顶与排序；当前工作指针、切换、暂时跳过；每日复盘、提醒、工作日志、附件、报表、清理、备份恢复。
- 未新增一级侧边栏导航；未修改 AppShell / Sidebar / 全局 Design Tokens。
- 未修改 `list_projects` 契约（仍返回全部项目，含归档项目）；归档项目过滤仅用于选择器展示，安全边界在 Rust Core 事务内。
- 未修改 T1-01 便携路径/数据库初始化逻辑；继承验证脚本仅更新 schema 断言。
- 未新增运行时第三方依赖；未新增前端测试框架依赖（使用 Node 内置 `node:test`）。
- 未修改 PRD、TECHNICAL_DESIGN、DECISIONS 中的业务决策；未修改 DEC-028/DEC-029/DEC-033。

---

## 9. 遗留风险与已知限制

1. **尚未经过第六轮独立审计与用户验收**：第五轮独立审计结论为未通过（P1–P4）；本报告只是第六轮定向补正的开发自测证据，不等于审计/验收结论。
2. **普通 SQLite 未加密**（DEC-028 已接受）：拥有文件访问权限的人可读取数据库内容。
3. **TOCTOU 残余风险**：按 DEC-029 接受并延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，未修复；不得宣称任何情况下不会写入 C 盘。
4. **P2-01 未关闭（服务端清理未完成）**：当前分支增量历史、工作区证据与 PR #8 文本脱敏复核具体机器标识 0 命中；但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 及其 9 个原始日志仍可经 GitHub API 读取（HTTP 200），GitHub Support 服务端清理尚未完成（工单材料见 `T1-03-assets/SANITIZATION.md` 第 4 节，需仓库所有者提交）；不得宣称 P2-01 已完成。仓库基线 main 中既有 T1-01/T1-02 同类机器信息（属 main 既有内容，非本 PR 新增）未修改，作为遗留风险。
5. **待安排排序固定**为 `created_at DESC, id DESC`；不提供手动排序/优先级（后续任务）。
6. **F1/F2（第四轮）**：测试脚本在任何写操作前验证真实测试根目录信任锚，缺失/身份无法确认时 fail closed 且不自动创建；清理在任何链接删除失败、链接仍存在、未预期 reparse point、身份变化时停止整个沙箱递归删除并保留现场；其中删除失败分支仅由受控 FaultHook 模拟，未修改 Windows ACL、未实际测试 ACL `Access Denied`。但信任锚/路径校验与后续写操作之间仍存在 **TOCTOU 剩余窗口**，未消除，按 DEC-029 / Issue #2 记录，不得宣称已消除并发替换风险。
7. **刷新失败测试**通过 CDP 传输层故障注入实现（不修改产品代码）；真实磁盘/数据库故障路径仍由 Rust/数据库错误处理与异常注入回归覆盖。
8. 继承验证脚本的 schema 版本断言已改为 3；历史 T1-01/T1-02 报告中的数字为当时历史结果，本报告记录本轮重新执行结果（产品代码未变）。
9. **F1（本轮）**：证据写入的“检查”与 `Set-Content` 写入之间仍存在并发替换窗口（DEC-029 / Issue #2），本轮用“启动时记录证据目录身份 + 写入时原生复验 + 最终路径/边界检查”缩小窗口，但**未消除**，不得宣称已消除并发替换风险。
10. **F2（本轮）**：`Test-Path` 判断已从沙箱清理入口移除；F1/F2 的“原生检查失败”用例是“路径组件是文件”的真实 Win32 失败，**未执行 Windows ACL `Access Denied` 测试**；Symbolic Link 场景因当前进程无 `SeCreateSymbolicLinkPrivilege` 仍记录 SKIP、不计 PASS。
11. **F2（第六轮）**：跟踪链接现在只允许“已确认沙箱的直接子项”，不支持任意嵌套；无法确认安全的嵌套路径一律 fail closed（这是按本轮审计要求采取的最小实现，非通用嵌套链接机制）。删除前全沙箱扫描、删除后残余扫描与身份复验均已实现，但扫描与删除之间仍存在 **DEC-029 接受的并发替换窗口**，未消除。
12. **P3（第六轮）**：`verify-t1-03-ui.ps1` 最终摘要写入前的原生路径检查/目录身份复验与随后 `Set-Content` 之间仍存在并发替换窗口（DEC-029 / Issue #2），未消除；本轮只缩小窗口并增加真实故障注入回归，不宣称已消除。
13. **E2E 环境性失败已如实记录**：第六轮共 5 次真实 E2E 尝试，1 次并发负载下应用壳渲染超时、2 次最小窗口尺寸时序竞态（其余断言通过）；验证脚本增加有限重试与真实客户区核对后连续 2 次通过。失败尝试不计入通过结果；该加固只改验证脚本，不改产品 UI/业务代码。

---

## 10. Git / PR 交付信息

- 分支：`task/T1-03-quick-create-pending`（PR #8 原分支；本轮本地开发工作区分支 `task/T1-03-quick-create-pending-r4`，与第五轮审计基准同 SHA）
- 基线：`018e851e8daf5835391a7b61caf881bc57c2ad42`
- 预编码设计提交：`9c091567351c4290b9f6ec1cea59f1e0d5f7bf6b`
- 第一轮实现提交：`be8d9c2e9c78710690de189936d6ee65f48ed8df`
- 第一轮审计基准 HEAD：`2342828852abee43ab56610e7d1fa91a02310bfe`（已被安全重写）
- 重写后 docs/evidence 提交（P2-01）：`b6cf344abc1693e7031427f8963c27474c0b59f9`
- 第二轮修复提交：
  - P2-02 `12b1bdf026f01688c79ba438165a97a652e086a1`（Rust/TS DTO 契约）
  - P3-01 + P3-02 `2d91c92301713597ccfc1c0ddc2d83a479f572d4`（提示时机、UAT 路径安全、E2E）
- 第三轮 P2-01/P3-02 修复提交：`b6a54591b783049142cbbffecd107ec9086723eb`；第三轮文档复核提交：`489d8689484c2cf744893bd3ee08dc7b25b5c8b8`（第三轮审计基准 HEAD，**第三轮未重写历史、未强制推送**）
- 第四轮 F1/F2 修复提交：`d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（仅验证脚本/测试脚本 + UI 编排信任锚；**未修改产品代码、未重写历史、未强制推送**）
- 第四轮证据/文档同步提交：`5ab1f49ac16705126d6c27dcaf091990d38a8b3f` 及其后的元数据修正提交
- 第五轮审计基准 HEAD：`6ddae47dd0721d58d5cb11f55e527fc162cedbe9`；第五轮修复提交：`af2421e9207f7b9ac185b0d29c3a98f80b5eb11a`
- **第六轮修复提交：** `e3bb86b30772159219a8eb16b90e55f3c69f4d59`（P1–P4 + B5 代码/测试/验证脚本；**未修改产品代码、未重写历史、未强制推送**）
- **第六轮证据/文档同步提交：** 紧随修复提交之后（PR #8 时间线可见；其自身 SHA 无法在本文件内自引用）
- **提交数（B4，最终 HEAD 上重算）：** `origin/main..e8205ca` = **25**；`origin/main..6ddae47` = **27**；`origin/main..e3bb86b` = **28**；`origin/main..最终 HEAD` = **30**。22 等旧记录保留为历史事实，不再作为当前状态引用
- 推送：`git push origin HEAD:task/T1-03-quick-create-pending`（非强制快进推送，未使用 force push）
- PR：[#8](https://github.com/shuaikun853-dev/work-kanban/pull/8) → `main`，保持 Open（未合并）；正文已更新为第六轮状态并新增进度评论，历史评论保留
- main：未修改（当前远端 main `9171fe35a7e080097991f547efe37ff5a504257c`；PR base 落后于 main 的问题本轮不处理，未 rebase、未改历史）

---

## 11. 当前状态与停止条件

**T1-03 第五轮独立审计未通过（P1/F2 跟踪链接穿过未跟踪 Junction、P2/F1 证据写入身份、P3 摘要写入守卫、P4 部分删除语义）；本轮 P1–P4 + B1–B5 定向补正完成，状态：待第六轮独立审计。**

- 已完成：F2 跟踪链接先全量验证/只允许沙箱直接子项、删除前全沙箱扫描、精确对象删除 + 原生复验、删除后残余扫描与身份复验、递归删除 started/completed/partial 语义；F1 证据写入强制启动身份记录（隔离 EvidenceRoot 仅内部测试注入）；P3 最终摘要写入原生路径检查 + 输出目录身份复验守卫；B1–B5 证据/文档修正（PR、时间戳、可复核 Red 证据、提交数、`<uat-root>` 脱敏）。路径安全专项 **128 项、FAILED=0、SKIPPED=1**；质量门禁全部退出码 0；T1-03 Release E2E 84/12/17/25、关闭 0/0、Guards PASS。
- 未完成且不得由开发代理自行宣布：**P2-01 服务端历史对象清理（GitHub Support 未处理，保持 OPEN）**、第六轮独立审计复核通过、用户验收完成、PR 合并。
- 剩余风险：TOCTOU 未消除（DEC-029 / Issue #2）；未执行 Windows ACL `Access Denied` 测试；Symbolic Link 场景 SKIP；main 基线既有 T1-01/T1-02 机器信息未修改（需单独授权）；普通 SQLite 未加密（DEC-028）。
- 按任务要求停止：不合并 PR #8、不修改 main、不开始 T1-04/T1-05、未获授权不再次执行全仓库历史重写或强制推送；不自行宣布审计/验收通过。
