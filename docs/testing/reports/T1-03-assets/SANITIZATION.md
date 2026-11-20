# T1-03 证据脱敏与历史清理说明（P2-01，第四轮复核）

**背景：** 第一轮独立审计发现 T1-03 证据目录包含原始命令日志，日志中出现 Windows 计算机名、
账户名、用户目录和本地绝对路径，违反 AGENTS.md 第 7 节“不提交构建产物、真实数据库、密钥、日志、
用户附件或机器专属路径”的仓库交付规范。

**本轮复核时间：** 2026-11-20（第四轮 F1/F2 定向修复后的证据同步）
**复核范围：** 当前分支可达历史（分支增量）、当前工作区 `docs/testing/reports/T1-03-assets/`（含第四轮
新增 `evidence/round4/`）、远程 branches/tags/pull refs、旧提交服务端可达性、PR #8 描述与全部评论、
本地 backup 分支与 bundle。
**结论摘要：** 当前分支增量历史、当前证据目录（62 个文件）与 PR #8 文本均无具体机器标识命中；
但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 及其 9 个原始日志**仍可通过 GitHub API 读取**，
GitHub 服务端清理**尚未完成**（工单材料已整理，需由仓库所有者提交）。因此 **P2-01 保持未关闭**，
不得宣称历史敏感对象已完全清除。

---

## 1. 处理历史（第一轮 → 第四轮）

| 轮次 | 处理 | 结果 |
|---|---|---|
| 第一轮实现 | 原始命令日志作为 docs/evidence 的一部分提交，由旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe`（第一轮审计基准 HEAD）引入 | 9 个 `T1-03-assets/logs/*.log.txt` 进入分支历史 |
| 第二轮修复 | 删除 9 个原始日志；对 11 个 JSON 证据做机器标识/路径替换；只重写本任务分支 docs/evidence 提交并使用 `--force-with-lease` 推送（旧 HEAD `2342828` → 新 HEAD `b6cf344`，未重写 main）；本地保留 `backup/t1-03-r1-audit-baseline` 分支与仓库外 bundle | 当前分支增量历史与工作区扫描 0 命中；旧提交对象仍在 GitHub 服务端可读 |
| 第三轮复核 | 重新扫描分支增量历史、当前证据目录、PR #8 文本与全部远程 refs；按第三轮实测结果刷新 T1-03 证据；整理 GitHub Support 清理材料；**未再次执行任何历史重写或强制推送** | 当前分支与证据目录无机器标识命中；但 UAT 目录/资产计数/提交数等文档数据与实测不一致（第三轮独立审计指出） |
| 第四轮复核 | 修复 F1/F2 后重新扫描当前分支增量历史、当前证据目录（含第四轮 `evidence/round4/`）、全部远程 refs、PR #8 描述与全部 4 条评论、旧提交服务端可达性；按第四轮实测刷新全部证据与文档；**未再次重写历史、未强制推送、未删除备份分支/bundle** | 见第 2、3 节；P2-01 仍等待服务端清理 |

## 2. 第四轮扫描范围与结果

扫描时点：第四轮证据同步提交前的已推送修复提交 `d82bdd47ae7c3c27fb4383d72ee16a131c89036d`
（`origin/main..HEAD` = 22 个提交；扫描时 HEAD 为第四轮证据同步提交，当前 HEAD 见 GitHub / PR #8）。
扫描模式在运行时由环境变量（计算机名、账户名、用户目录）与仓库根路径**动态生成**，不硬编码进仓库。

| 扫描项 | 范围 | 结果 |
|---|---|---|
| 当前证据目录 | `docs/testing/reports/T1-03-assets/` 共 62 个文件（38 PNG、21 JSON、3 文本/说明；第三轮基线 34 + 第四轮新增 28） | 具体机器标识**命中 0**；PNG 文本块扫描命中 0；`C:\Users\` 前缀仅出现在脱敏说明的**占位符示例**（`C:\Users\<user>`），不含具体账户，判定为非敏感 |
| 分支增量历史 | `018e851e8daf5835391a7b61caf881bc57c2ad42..HEAD`（扫描时 HEAD 为第四轮证据同步提交），22 个提交、7269 次文件树扫描、449 个唯一 blob | 分支**新增**具体机器标识命中 **0**；第三轮口径可比的原始命中 17 条，全部为文档分类描述/占位符/通用路径文本（`T1-03-REPORT.md`、`SANITIZATION.md`、`test-t1-03-uat-path.ps1` 中的说明文字），不含具体机器标识 |
| 旧提交内容 | 旧提交 `2342828` 差异与 9 个原始日志内容（仅统计类别，不落盘原文） | 旧提交新增 9 个日志、147,009 字节；类别命中：计算机名、账户名、用户目录、`C:\Users`、仓库绝对路径（只记录类别与计数，不记录具体值） |
| 当前工作区原始日志 | `T1-03-assets/logs/` | 不存在；当前 HEAD 树中该路径文件数为 0；分支增量历史中不可达 |
| PR #8 文本 | 扫描时正文 3,957 字符 / SHA-256 `725d5df32469c4873e6b347b07039122a3996ff65bda341a0ee6b248f43e0ae0`、4 条 issue 评论、0 条 review comment、0 条 review，合并扫描共 6 个 scope | 具体机器标识类别命中 **0**；旧日志文件名命中 **1**（第三轮审计结论评论 `comment#4` 中作为旧对象说明的引用，非日志正文）；旧提交 SHA 出现 3 次（正文 1 + 评论 3 与 4 各 1，均为公开 SHA 引用）；未下载/未写入任何旧日志正文 |
| 远程 refs | `git ls-remote origin` 共 18 个 ref：8 个 branches、7 个 `refs/pull/*/head`、2 个 `refs/pull/*/merge`、HEAD；tags：**0 个** | 所有可本地验证的远程 ref 均**不是**旧提交 `2342828` 的后代；`refs/pull/8/head` = 当前分支 HEAD；无远程 ref 指向旧提交；旧提交不是当前 HEAD 祖先（`git merge-base --is-ancestor` 退出码 1） |
| 本地 backup / bundle | 分支 `backup/t1-03-r1-audit-baseline`、`test-artifacts/r1-backup/t1-03-r1-audit-baseline-2342828.bundle`（3,633,177 字节） | 均**仅本地**，未推送；bundle 已被 `.gitignore` 忽略且未被 git 跟踪；两者保留供复核，不得推送 |
| 仓库基线（main）遗留 | 全仓当前基线中既有 T1-01/T1-02 证据与日志 | 存在同类机器信息（属 main 既有内容，非本 PR 新增；其中 `docs/testing/reports/T1-02-SECOND-INDEPENDENT-AUDIT-evidence.json` 含 1 处仓库路径，与 `origin/main` 同 blob，非本 PR 引入）；本轮**不修改 main**，作为遗留风险记录 |

说明：以上扫描仅保存类别、计数、提交 SHA、repo 相对路径等可复核信息；具体机器标识、账户名、
用户目录与原始日志行文**未写入任何仓库文件或证据 JSON**。

## 3. 旧提交与服务端暴露（未解决）

- 旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 仍可通过 GitHub API 直接读取（`GET /repos/{owner}/{repo}/commits/{sha}` 返回 HTTP 200）。
- 通过旧 SHA 的 contents API（`GET /repos/{owner}/{repo}/contents/docs/testing/reports/T1-03-assets/logs?ref=23428288...`）仍可列出 **9 个原始日志文件**（HTTP 200，合计 147,009 字节），即原始日志内容仍可按旧 SHA 下载。
- 这说明第二轮“分支历史已重写”只解决了当前分支可达历史问题，**没有**清除 GitHub 服务端保留的不可达提交对象、PR 旧头引用缓存或页面/归档缓存。
- 只有 GitHub Support（或 GitHub 服务端 GC/安全流程）才能清理这些对象与缓存；本仓库无权直接删除服务端不可达对象。
- **P2-01 未关闭。** 关闭条件：GitHub Support 确认处理完成，且通过旧 SHA 重新验证原始日志不可访问。

## 4. GitHub Support 清理请求材料（待仓库所有者提交）

> 工单必须由仓库所有者（`shuaikun853-dev`）通过 GitHub 官方渠道提交；开发代理不擅自提交，
> 也不得在 Support 要求删除 PR 或全仓库重写时擅自执行，须先报告影响范围。

| 项目 | 内容 |
|---|---|
| 仓库 | `shuaikun853-dev/work-kanban` |
| 受影响 PR | PR #8 `task/T1-03-quick-create-pending` → `main`（保持 OPEN，不合并） |
| 引入原始日志的旧提交 | `2342828852abee43ab56610e7d1fa91a02310bfe`（第一轮审计基准 HEAD，父提交 `be8d9c2e9c78710690de189936d6ee65f48ed8df`） |
| 已完成的分支历史重写 | 仅重写本任务分支 docs/evidence 提交并 `--force-with-lease` 推送：旧 HEAD `2342828` → 重写后 `b6cf344abc1693e7031427f8963c27474c0b59f9`；**未重写 main**；旧对象仅本地 backup 分支/bundle 保留；第三轮修复提交 `b6a54591b783049142cbbffecd107ec9086723eb`；第四轮修复提交 `d82bdd47ae7c3c27fb4383d72ee16a131c89036d`（**均未重写历史、未强推**） |
| 暴露信息类别 | 9 个原始命令日志（构建/测试/Release E2E 输出），其中含：Windows 计算机名、Windows 账户名、用户目录绝对路径、仓库本地绝对路径（共 147,009 字节；具体值不在此列出） |
| 需要清理的服务端对象/缓存 | 旧提交 `2342828` 及其树/Blob 对象；PR #8 旧 head/时间线中对旧提交的引用与缓存；提交页面/archive/tarball 缓存；搜索索引与 API 缓存 |
| 期望处理方式 | 优先保留 PR #8 正文与评论（已完成脱敏），在可行范围内解除其对旧敏感提交的内部引用，并清理上述缓存/服务端对象；如必须删除 PR 或再次全仓库历史重写，请先说明影响范围，由仓库所有者决定 |
| 当前状态 | **材料已整理，工单尚未提交；未获 Support 确认。** |

## 5. 脱敏占位符

| 原始内容类型 | 占位符 |
|---|---|
| Windows 计算机名 | `<computer-name>` |
| Windows 账户名 / 用户标识 | `<user>` / `<redacted>` |
| 用户目录（`C:\Users\<user>`） | `<user-profile>` |
| 仓库检出绝对路径 | `<repo-root>` |
| UAT 测试根路径（`D:\WorkManager-test-data`） | `<uat-root>` |
| 非 D 盘测试输入路径（路径安全测试） | `<non-d-drive-root>` |
| 测试根目录外的测试输入路径 | `<outside-test-root>` |
| Windows 系统目录（`C:\WINDOWS`） | `<windows-root>` |
| Python 可执行文件绝对路径 | `<python-exe>` |
| 其他盘符绝对路径根 | `<drive-root>` |

说明：产品默认部署路径 `D:\WorkManager` 与专用测试根目录 `D:\WorkManager-test-data` 是 PRD/DEC-002
和验证脚本中公开定义的固定路径，不是本机专属路径，在文档中保留字面值；UAT 证据中的具体
一次性运行目录统一写为 `<uat-root>\<run-name>`。第四轮 UAT 运行目录为
`<uat-root>\t1-03-ui-r4-20261120-181549`。

## 6. 复核方法

- 机器标识模式在扫描时由运行环境变量（计算机名、账户名、用户目录）与仓库根路径**动态生成**，不硬编码进仓库。
- 分支增量历史：逐提交扫描树中全部文本文件（`git cat-file blob` 只读内存扫描，不落盘）；当前证据目录：UTF-8/系统编码双解码 + PNG 文本块解析；PR 文本：GitHub API 只读拉取后内存扫描。
- 旧提交原始日志：仅按类别统计匹配数量，原文不落盘、不输出。
- 复现命令与测试数量见 `test-counts.txt` 与 [`../T1-03-REPORT.md`](../T1-03-REPORT.md)；第四轮机器可读汇总见 `evidence/round4/round4-verification-summary.json`。

## 7. 范围与遗留风险

- 第四轮只处理 F1/F2（UAT 测试根目录信任锚、清理 fail-closed）与证据/文档一致性，不扩大修改范围。
- **P2-01 未关闭**：旧提交对象与原始日志仍可由旧 SHA 读取，GitHub Support 尚未处理；不得把分支历史清理等同于服务端清理完成。
- 仓库基线 main 中既有的 T1-01/T1-02 历史证据存在同类机器信息（非本 PR 新增）；按本轮授权未修改，需要单独授权才能处理。
- GitHub 对不可达对象可能保留有限缓存/服务端保留期；Support 完成后仍需用旧 SHA 重新验证不可访问，才能关闭 P2-01。
