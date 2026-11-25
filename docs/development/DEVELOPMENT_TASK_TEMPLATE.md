# WorkManager 开发任务提示词模板

> 新建任务说明、编写交给 DeepSeek Harness / Claude Code / Codex / 其他 AI 的开发提示词时，复制本模板并填写具体任务。不要删除“强制开发理念与 Skill”部分。

## 任务信息

- 任务 ID：
- 任务名称：
- 所属阶段（M0～M6）：
- 当前分支 / 基线 commit：
- 任务状态：
- 依赖任务：
- 目标结果：

## 强制开发理念与 Skill（不得删除）

本项目是用户个人使用的 Windows 本地软件，不是商业化产品。只实现用户当前明确需要的功能，不为假设用户、未来需求、企业级场景或所有理论边界过度设计。

开始编码前必须阅读：

1. 根目录 `AGENTS.md`
2. `docs/development/DEVELOPMENT_PHILOSOPHY.md`
3. `docs/development/DEVELOPMENT_PLAN.md`（确认所属阶段、任务依赖和范围边界）
4. 本任务说明及必要的 PRD、DECISIONS、TECHNICAL_DESIGN、UI-DESIGN-SPEC 相关章节

本任务必须实际加载两套 Skill：

- **Ponytail**（默认 full）：<https://github.com/DietrichGebert/ponytail/blob/main/skills/ponytail/SKILL.md>。负责最小完整实现、复用现有能力、避免无用代码和过度设计。
- **Matt Pocock Skills / Implement**：<https://github.com/mattpocock/skills/blob/main/skills/engineering/implement/SKILL.md>。负责工程实现流程；按需加载 TDD、Bug 诊断和 Code Review 子 Skill。

如果宿主不支持 Skill 调用，读取 GitHub 上对应 Markdown 原文；无法读取时如实说明，不得虚报。

## 本次任务范围

### 必须完成
- [填写本次明确要求]

### 明确不做
- [列出不在本次授权范围内的功能、重构和假设性场景]

### 允许修改的文件/模块
- [填写；如允许范围未知，先检查并列出，不要擅自扩大]

## 实施要求

1. 先检查工作区、分支、基线 commit 和现有实现；不要覆盖用户未提交的改动。
2. 找到真实调用链并优先复用已有组件、函数、服务和依赖。
3. 采用最小完整实现，不增加没有当前用例支撑的抽象、包装层、配置项、依赖或“为以后准备”的代码。
4. 不顺带重构无关模块；如发现范围外问题，单独报告，不擅自处理。
5. 不牺牲信任边界校验、错误处理、数据完整性、安全和用户明确要求。
6. 对非平凡逻辑在合适的公共接口处添加小而有效的测试；简单改动不为测试数量而增加测试。
7. 运行与本次改动相关的质量检查；记录真实命令、退出码和结果。
8. 检查最终 diff，确认没有无用代码、范围蔓延或未经批准的依赖。

## 验收标准

- [填写可观察、可验证的结果；只列本次需要验证的标准]

## 交付与停止条件

- 修改文件：
- 测试/检查命令及结果：
- 实际加载的 Skill 和上游 commit SHA：
- Commit SHA / PR：
- 未实现或未测试的内容：
- 遗留风险：
- 合并门禁状态：是否涉及 PR #8 / P2-01；是否已满足独立审计、用户验收和 P2-01 服务端清理验证（见 AGENTS.md 8.6）

完成本任务要求的工作后，按项目当前流程更新文档并停止。不得自行开始下一个任务，不得擅自合并任何 PR。
