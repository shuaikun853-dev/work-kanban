# WorkManager

Windows 本地工作管理软件（绿色便携版）。当前进度：**T1-01 已于 2026-11-18 经第四轮独立审计及用户验收，验收完成**。R3-01/R3-02 修复提交分别为 `ae1eb65`、`4942eb0`；[PR #1](https://github.com/shuaikun853-dev/work-kanban/pull/1) 已于 2026-11-18 合并到 main（commit `260e6c0`）；审计结论见[第四轮独立审计报告](docs/testing/reports/T1-01-FOURTH-AUDIT-REPORT.md)，用户确认见[验收记录](docs/testing/reports/T1-01-USER-ACCEPTANCE.md)。TOCTOU 按 DEC-029 接受并延期至独立[Issue #2](https://github.com/shuaikun853-dev/work-kanban/issues/2)，仍未修复。**T1-02 项目创建、编辑、归档已完成开发与自测，第一轮独立审计问题（P2-01/P3-01/P3-02）已修复并重新回归，当前状态“待审计”（等待第二轮独立审计，PR #7 未合并）**，详见 [T1-02 测试报告](docs/testing/reports/T1-02-REPORT.md) 与 [返工修复报告](docs/testing/reports/T1-02-AUDIT-FIX-REPORT.md)。T1-03 及后续工作事项、每日复盘、报表、附件等业务功能尚未实现；本仓库不表示这些功能已经可用。

## 文档

- [产品需求规格说明书](docs/requirements/PRD.md)
- [技术架构设计说明书](docs/architecture/TECHNICAL_DESIGN.md)
- [已确认决策记录](docs/decisions/DECISIONS.md)
- [开发计划书](docs/development/DEVELOPMENT_PLAN.md)
- [开发状态](docs/STATUS.md)
- [UI 设计规范与原型图](docs/design/UI-DESIGN-SPEC.md)
- [开发与协作规范](AGENTS.md)
- [T1-01 测试报告](docs/testing/reports/T1-01-REPORT.md)
- [T1-02 测试报告](docs/testing/reports/T1-02-REPORT.md) / [第一轮独立审计报告](docs/testing/reports/T1-02-INDEPENDENT-AUDIT-REPORT.md) / [返工修复报告](docs/testing/reports/T1-02-AUDIT-FIX-REPORT.md)

## 项目基线

- 目标平台：Windows 10；形态：绿色便携桌面应用
- 默认目录：`D:\WorkManager`（Release 数据目录跟随 EXE 所在目录）
- 业务数据：本地保存，不上传云端
- 技术栈：Tauri 2、Svelte 5、TypeScript、Vite、Rust、普通 SQLite（`rusqlite` bundled，**未加密**）
- 第一版不包含：应用密码、锁屏、SQLCipher、DPAPI；自动备份策略待用户确认，尚未实现

## 工程结构

```text
WorkManager/
├── src/                         # Svelte 5 前端（只调用受限 Tauri 命令，不直接访问 SQLite）
│   ├── App.svelte               # T1-01 数据库健康检查界面
│   ├── main.ts
│   └── lib/{bridge,contracts,presentation}/
├── src-tauri/                   # Tauri 2 适配层：命令、窗口、WebView2 绝对数据目录、启动错误对话框
│   ├── src/{lib.rs,main.rs,app_state.rs,commands/}
│   ├── capabilities/default.json
│   └── tauri.conf.json
├── crates/workmanager-core/     # 独立 Rust Core（不依赖 Tauri），可普通 cargo test
│   ├── src/portable_paths.rs    # 便携路径：EXE 跟随、D 盘约束、Debug/Test 隔离、fail-closed
│   ├── src/database/            # 连接/PRAGMA、user_version migration、完整性检查、健康快照
│   ├── migrations/*.sql         # 编号 migration（编译期嵌入）
│   └── tests/                   # 初始化、回滚、外键、损坏保护、路径隔离等
├── scripts/
│   ├── generate-icons.py        # 自绘占位应用图标（无第三方素材）
│   └── verify/                  # Release 运行时验证脚本（便携/持久化/异常/UI IPC）
└── docs/                        # 需求、架构、决策、计划、状态、测试报告
```

## 构建与运行

前置条件（本机已验证）：Node.js 22 + npm、Rust stable（MSVC 工具链）、Visual Studio Build Tools 2022、Windows SDK、WebView2 Runtime；工程须位于 D 盘（便携路径规则只接受 D 盘）。

```powershell
npm install

# 开发模式（Debug 构建必须显式指定 D 盘隔离测试根目录，否则 fail-closed）
$env:WORKMANAGER_TEST_PORTABLE_ROOT = 'D:\WorkManager-test-data\dev'
npm run tauri dev

# 静态检查 / 前端构建 / 前端测试（无独立前端单测依赖）
npm run check
npm run build

# Rust 格式化检查 / 编译检查 / 测试
cargo fmt --all -- --check
cargo check --workspace --all-targets
cargo test --workspace

# Release 构建（--no-bundle 产出 target\release\workmanager.exe）
npm run tauri build -- --no-bundle
```

Release 运行时专项验证（真实 EXE、真实 WebView2、真实便携目录；测试数据只写入 `D:\WorkManager-test-data`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1
```

详见 [scripts/verify/README.md](scripts/verify/README.md) 与 [T1-01 测试报告](docs/testing/reports/T1-01-REPORT.md)。

## 数据目录（Release）

```text
<WorkManager.exe 所在目录>/
├── WorkManager.exe
└── data/
    ├── database/work.db     # 普通 SQLite（未加密）
    ├── cache/webview2/      # WebView2 用户数据（Rust 侧绝对路径）
    ├── config/  logs/  temp/  backups/
```

应用不会静默写入 `%APPDATA%`、`%LOCALAPPDATA%`、系统 Temp 或其他盘；D 盘路径不可用或不可写时启动失败并显示明确错误。普通 SQLite 文件未加密，拥有文件访问权限的人可以读取其中内容。

## 测试数据约定

所有测试使用虚构数据，测试目录位于 D 盘隔离目录（默认 `D:\WorkManager-test-data`，可用 `WORKMANAGER_TEST_BASE_DIR` 覆盖），不得在正式目录 `D:\WorkManager` 中运行测试；测试只清理自身创建的文件。
