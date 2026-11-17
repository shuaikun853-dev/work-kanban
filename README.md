# WorkManager

Windows 本地工作管理软件。技术验证阶段已按当前决策放行；T1-01 已于 2026-11-17 开始实施（用户授权立即执行），当前进行中。尚未声明任何业务功能已经实现。

## 文档

- [产品需求规格说明书](docs/requirements/PRD.md)
- [技术架构设计说明书](docs/architecture/TECHNICAL_DESIGN.md)
- [已确认决策记录](docs/decisions/DECISIONS.md)
- [开发计划书](docs/development/DEVELOPMENT_PLAN.md)
- [开发与协作规范](AGENTS.md)
- [开发状态](docs/STATUS.md)

## 项目基线

- 目标平台：Windows 10
- 形态：绿色便携桌面应用
- 默认目录：D:\WorkManager
- 业务数据：本地保存，不上传云端
- 技术方向：Tauri 2、Svelte 5、TypeScript、Rust、普通 SQLite

## 当前进度

阶段 0 已按 DEC-028 放行；阶段 1 已获授权但尚未开始执行。T1-01 计划于 2026-11-17 18:00（北京时间）后开始。T0-05 DPAPI 已取消；T0-06 断网与 Windows 系统集成延期至阶段 6，并新增 T6-07 专项验收。请查看 [开发状态](docs/STATUS.md) 和 [开发计划书](docs/development/DEVELOPMENT_PLAN.md)。

本仓库文档区分已确认需求、技术建议、待决事项和真实开发状态。未完成实现与验收的功能不会标记为已完成。
