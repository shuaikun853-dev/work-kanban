# WorkManager 开发状态

**更新日期：** 2026-11-25（第三次更新：PR #9 已合并、M0-05 完成、M0-06 只读核验完成，Git 基线按最新 main 重测）\
**开发计划：** [DEVELOPMENT_PLAN.md V3.1](development/DEVELOPMENT_PLAN.md)（PR #9 已于 2026-11-25T06:05:45Z 合并，已进入 main）\
**当前里程碑：** M0 — 现有代码收口\
**收口包：** [M0-CLOSEOUT.md](development/M0-CLOSEOUT.md)（Git 基线、两项审计材料包、P2-01 复核、整合方案、最终验收清单）\
**总体状态：** M0 进行中；M0-05 完成、M0-06 只读核验完成；T1-03/T1-04 仍待独立审计与用户验收；M1～M6 尚未启动。
**开发执行原则：** 不要把简单的个人软件开发任务复杂化；优先复用现有实现，只做当前明确需求的最小必要修改，不增加无用代码或无关工作。

---

## 1. 当前 Git 基线

| 分支/PR | 当前事实 | 状态 |
|---|---|---|
| main | `9171fe3` Merge pull request #9（PR #8 的 base 为合并前的 `018e851`） | 最新主分支基线 |
| T1-03 | `task/T1-03-quick-create-pending`，HEAD `e8205cae22e98afce6480f5a5a0695543a61dee3` | PR #8 Open，未合并；`CONFLICTING / DIRTY`；P2-01 合并门禁生效 |
| T1-04 | `task/T1-04-multi-project-copies`，HEAD `4bd69f1e4c715410490496bc9fbe8e2a60623a0f` | 堆叠在 T1-03 上（merge-base = `e8205ca`）；待独立审计；未创建 main PR；不得用堆叠分支绕过 PR #8 |
| 开发理念/计划文档 | `docs/ai-development-principles` → PR #9 | **已合并**（2026-11-25T06:05:45Z），V3.1 计划、STATUS、AGENTS/Skill 规则与 AI 入口已在 main |
| PR #3 | `docs/t1-01-merge-status-sync`，head `a527369` | Open、CONFLICTING；内容已被 PR #6 和 PR #9 覆盖；本轮不关闭、不合并、不删除 |

2026-11-25 重新 fetch 后的 Git 比较结果：main 较 T1-03 领先 12 个提交，T1-03 较 main 领先 25 个；main 较 T1-04 领先 12 个，T1-04 较 main 领先 39 个；T1-04 较 T1-03 领先 14 个。T1-03/T1-04 的代码尚未进入 main。完整基线与冲突分析见 [M0-CLOSEOUT.md](development/M0-CLOSEOUT.md) 第 1、7 节。

### P2-01 合并门禁事实

- 旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 仍可经 GitHub API 读取，相关 9 个原始命令日志仍可列出/下载；GitHub Support 服务端历史清理尚未完成。
- 用户 2026-11-25 确认采用方案 A：P2-01 继续作为 PR #8 的正式合并阻断条件，PR #8 保持 OPEN。
- 只有 GitHub Support 服务端清理完成并重新核验旧 SHA 和 9 个原始命令日志不可访问、取得可核验证据后，才能关闭 P2-01。
- 独立审计可以继续，但审计通过不代表允许合并；禁止 Cherry-pick、替代 PR、强制推送或堆叠分支绕过 PR #8。

## 2. 已完成并进入 main 的工作

| 任务 | 结论 |
|---|---|
| T1-01 SQLite 基础设施与便携路径 | 用户验收完成，PR #1 已合并；DEC-029 的 TOCTOU 残余风险仍未修复，转 Issue #2 |
| T1-02 项目创建、编辑、归档 | 第二轮独立审计通过，用户验收完成，PR #7 已合并 |

以上任务不重新开发。后续只在发现明确缺陷或新需求时定向修改。

## 3. 当前待收口任务

### T1-03：工作事项快速创建和待安排

- 分支：`task/T1-03-quick-create-pending`
- 当前 HEAD：`e8205cae22e98afce6480f5a5a0695543a61dee3`
- PR：[ #8 ](https://github.com/shuaikun853-dev/work-kanban/pull/8)，Open，未合并
- PR 状态（2026-11-25 实测）：`mergeable=CONFLICTING`、`mergeStateStatus=DIRTY`；冲突仅涉及 `README.md`、`docs/STATUS.md`、`docs/decisions/DECISIONS.md`、`docs/development/DEVELOPMENT_PLAN.md`、`docs/requirements/PRD.md` 五个文档，无代码、migration、Tauri command、Bridge 或前端组件冲突。`reviewCount=0`、`reviewCommentCount=0`，GitHub 上不存在独立审计记录。
- 当前状态：第四轮 F1/F2 定向修复及自测完成，等待第四轮独立审计。开发与验证报告位于 `task/T1-03-quick-create-pending` 分支的 `docs/testing/reports/T1-03-REPORT.md`（PR #8 合并后进入 main，本分支暂不提供相对链接）。
- F1：测试根目录写入前信任锚验证和 fail-closed 已完成。
- F2：清理失败、链接仍存在、未预期重解析点或身份变化时停止递归清理并保留现场；删除失败使用受控 FaultHook 注入，**不是实际 Windows ACL Access Denied 测试**。
- P2-01：当前分支与证据扫描未发现新的具体机器标识，但旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 仍可经 GitHub API 读取，9 个原始命令日志仍可列出/下载；GitHub Support 服务端清理尚未完成，**P2-01 仍保持 OPEN，PR #8 不得合并**。
- 完成条件（三项并列，缺一不可）：① 第四轮独立审计通过；② 用户验收通过；③ P2-01 服务端清理完成并复核旧 SHA/9 个原始命令日志不可访问。独立审计通过不等于允许合并。

### T1-04：多项目独立副本创建

- 分支：`task/T1-04-multi-project-copies`
- 当前 HEAD：`4bd69f1e4c715410490496bc9fbe8e2a60623a0f`
- 当前状态：第六轮独立审计后的 R6-01～R6-03 定向补正完成，开发与自测完成，等待独立代码审计。开发与验证报告位于 `task/T1-04-multi-project-copies` 分支的 `docs/testing/reports/T1-04-REPORT.md`（本分支暂不提供相对链接）。
- 已实现：多项目独立副本、创建组/成员关系、整批 IMMEDIATE 事务、事务内读回验证、requestId 幂等重试、Migration 0004、路径安全守卫和 Bridge 契约校验。
- 本轮补正：Rust/TypeScript 标题 Unicode White_Space 规范化统一；Migration 清理对悬空 Junction 的原生识别与 fail-closed；Bridge 注释和任务文档状态同步。
- 当前分支仍包含 T1-03 堆叠历史。PR #8 未处理前，不直接创建把 T1-03 diff 重复带入 main 的 T1-04 PR；也不得通过堆叠分支绕过 PR #8 将代码提前带入 main。
- 完成条件：独立审计核验当前准确 HEAD；所有审计问题关闭；用户验收；PR #8 按 P2-01 门禁合并后，只把 T1-04 自身提交迁移到更新后的 main 并创建独立 PR。

---

## 4. M0～M6 新计划状态

| 批次/任务 | 内容 | 当前状态 |
|---|---|---|
| M0-01 | T1-03 第四轮独立审计 | 待独立审计（可与 P2-01 并行） |
| M0-02 | T1-04 第六轮补正后的独立审计 | 待独立审计（可与 P2-01 并行） |
| M0-03 | P2-01 合并门禁独立追踪 | 阻塞中；等待 GitHub Support 服务端历史清理 |
| M0-04 | T1-03/T1-04 按顺序处理 PR 和合并 | 阻塞，依赖 M0-01/M0-02/M0-03 |
| M0-05 | PR #9 开发理念、V1 开发计划和 Skill 规则入库 | **完成**（2026-11-25T06:05:45Z 合并） |
| M0-06 | 核验 T1-01 已有数据库初始化和异常保护 | **只读核验完成**（未重新运行 Windows 测试；仅核对 main 源码、历史测试代码、历史独立审计与用户验收记录） |
| M1 | 完整工作事项管理 | 未开始，M0 完成后启动 |
| M2 | 每日工作管理 | 未开始 |
| M3 | 每日复盘与提醒 | 未开始 |
| M4 | 历史查询与报表 | 未开始 |
| M5 | 附件、清理与备份 | 未开始 |
| M6 | 发布与最终验收 | 未开始 |

## 5. 尚未关闭的风险与决策

### 已知技术风险

1. **DEC-029 TOCTOU：** 路径校验与后续按路径写入之间的竞争窗口尚未消除，按用户决定延期至 [Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)。不得声称绝对不会写入 C 盘。
2. **普通 SQLite 未加密：** 按 DEC-028 使用普通 SQLite；拥有相应文件访问权限的人可以读取数据库内容。
3. **T1-03 P2-01 合并门禁：** 旧 Git 对象和 9 个原始命令日志仍可访问，等待仓库所有者完成 GitHub Support 服务端清理；清理未完成前 PR #8 不得合并。
4. **T1-03/T1-04 尚未合并：** 当前 main 不包含这两项实现，不能把分支代码描述为已发布能力。
5. **绕过门禁风险：** 严格禁止 Cherry-pick、创建替代 PR、强制推送或堆叠分支绕过 PR #8；发现此类操作必须立即停止并报告。

### 待用户确认事项

以下 5 类事项保持 OPEN，AI 不得自行决定；它们只阻塞依赖它们的任务，不阻塞其他已明确功能。

| 用户确认分组 | 待确认事项 | 对应编号 | 影响 |
|---|---|---|---|
| 1 | 备份方式、频率和轮转数量 | OPEN-001 | M5-03 |
| 2 | 备份恢复确认流程及过期数据处理 | OPEN-002、OPEN-003 | M5-03 |
| 3 | 上班时间默认值 | OPEN-004 | M3-04 |
| 4 | 中国大陆节假日、调休日历数据来源和更新机制 | OPEN-006 | M3-01/M3-03 |
| 5 | 三个月保留期限按自然月还是固定天数 | OPEN-007 | M5-02 |
| 待确认（新增） | 已放弃工作恢复后的具体状态和是否重新参与自动排序 | OPEN-012 | M1-02（开发前必须提交用户确认） |

内部状态：OPEN-005（重复/周期任务）已由用户 2026-11-25 明确为第一版排除，不在 V1 开发；OPEN-008（次级页面 UI 细节）沿用已确认 UI 设计系统，不属于阻塞性待确认项。

未确认事项不得由 AI 自行决定，也不得阻塞与其无关的已明确功能。

## 6. 下一步执行顺序

1. T1-03 第四轮独立审计与 T1-04 第六轮补正后的独立审计可继续并行进行，审计对象分别是 `e8205ca` 和 `4bd69f1`；审计通过不等于允许合并。审计材料包见 [M0-CLOSEOUT.md](development/M0-CLOSEOUT.md) 第 4、5 节。
2. P2-01 由仓库所有者在 GitHub Support 服务端清理完成后重新核验旧提交 `2342828852abee43ab56610e7d1fa91a02310bfe` 和 9 个原始命令日志不可访问，取得可核验证据后关闭。2026-11-25 复核结果：旧 SHA 与 9/9 日志（147,009 字节）仍可读取，清理未完成。
3. PR #8 的三项合并条件（独立审计通过、用户验收通过、P2-01 服务端清理验证通过）全部满足后，按 [M0-CLOSEOUT.md](development/M0-CLOSEOUT.md) 第 7.6 节的 S1→S2 执行：先把 T1-03 的 5 个冲突文档改写到 V3.x / M0～M6 口径（只改文档），再由用户合并 PR #8。
4. T1-03 进入 main 后按 S3→S4 执行：从更新后的 main 新建集成分支，`cherry-pick e8205ca..4bd69f1`（仅 14 个 T1-04 自身提交），禁止重复携带 T1-03 的 25 个提交，然后创建并审查 T1-04 独立 PR。
5. 两项 PR 合并后按 S5 收尾：重跑 `cargo test --workspace`、`npm run check`、`npm run build`、`git diff --check`，确认 `git status` 干净，再更新本 STATUS 与 DEVELOPMENT_PLAN。
6. M0 全部完成后，从统一 main 开始 M1，不重做已有功能；M1-02 开发前必须先就 OPEN-012 向用户确认。

> M0-05（PR #9 入库）已于 2026-11-25 完成；M0-06（T1-01 数据库基础设施只读核验）已于 2026-11-25 完成，结论见 [M0-CLOSEOUT.md](development/M0-CLOSEOUT.md) 第 3 节。M0-06 未重新运行 Windows 测试。

---

## 7. 进度口径

- 代码写完 ≠ 测试通过。
- 测试通过 ≠ 独立审计通过。
- 独立审计通过 ≠ 用户验收通过。
- **独立审计通过 ≠ 允许合并；P2-01 未关闭前 PR #8 一律不得合并。**
- PR Open ≠ 已合并；分支上已有代码 ≠ main 已包含。
- 未取得用户决定的方案只能标记为建议或待确认。
- 所有状态变化必须同步更新 DEVELOPMENT_PLAN.md 和 STATUS.md，并保留历史证据。

**当前真实结论：** T1-01、T1-02 已验收并合并；M0-05 完成（PR #9 已合并）；M0-06 只读核验完成（未重新运行测试）；T1-03 和 T1-04 的开发与自测已完成，但仍分别待独立审计与用户验收；P2-01 仍是 PR #8 的合并硬门禁，PR #8 保持 OPEN 且当前为 `CONFLICTING / DIRTY`（文档冲突）；M1～M6 尚未开始。WorkManager 仍处于 M0 现有代码收口阶段。
