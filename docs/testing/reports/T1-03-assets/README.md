# T1-03 证据索引

本目录保存 T1-03「工作事项快速创建和待安排区域」的开发自测证据。所有测试数据均为虚构内容；
UAT 运行目录为 `<uat-root>\t1-03-ui-run2`（D 盘隔离目录），未触碰正式运行目录
`D:\WorkManager`，未使用真实用户工作数据。

## 内容

| 路径 | 内容 |
|---|---|
| `screenshots/` | 17 张真实 Release WebView2 截图：正常窗口、最小窗口 860×640、loading/empty/error、快速创建、项目选择器、归档竞态错误、归档项目历史关联、加载失败/契约违规、长标题、关闭重开后持久化 |
| `evidence/t1-03-ui-evidence.json` | 主 UI/IPC 70 项断言（含每项 PASS/FAIL 与 detail）、页面异常、CSP 违规、确定性等待与截图清单 |
| `evidence/t1-03-min-window-evidence.json` | 最小窗口 12 项断言 + 关闭按钮点击记录 |
| `evidence/t1-03-persistence-evidence.json` | 关闭重开持久化 17 项断言 |
| `evidence/t1-03-ui-orchestration.json` | E2E 编排汇总：EXE 路径/大小/SHA-256、各阶段退出码与断言计数、数据库探针路径、截图清单、pass |
| `evidence/t1-03-prerequisite.json` | 重启阶段之前的真实 IPC 数据快照（虚构工作事项与项目） |
| `evidence/t1-03-db-after-main.json` | 第一次真实关闭后的数据库只读探针（schema/完整性/行数/状态分布/外键） |
| `evidence/t1-03-db-after-restart.json` | 重新启动并再次关闭后的数据库只读探针（持久化后） |
| `evidence/release-regression-portable-summary.json` | 继承 T1-01 便携验证（106 项）原始 summary |
| `evidence/release-regression-faults-summary.json` | 继承 T1-01 异常注入验证（73 项）原始 summary |
| `evidence/release-regression-t1-02-ui-orchestration.json` | 继承 T1-02 Release UI E2E 编排证据 |
| `test-counts.txt` | 测试数量、环境、数据库探针关键事实速查 |

## 复现命令

```powershell
# 1. 质量门禁
cargo fmt --all -- --check
cargo check --workspace --all-targets
cargo test --workspace
npm run check
npm run build
git diff --check

# 2. Release 构建
npm run tauri build -- --no-bundle

# 3. T1-03 Release E2E（主检查 → 最小窗口 → 真实关闭 → DB 探针 → 重启持久化 → 关闭）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1 `
    -OutputDir <uat-root>\t1-03-ui-<timestamp>

# 4. 继承回归
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
```

## 重要说明

- 本证据为**开发自测**证据，不构成独立审计结论或用户验收结论。
- 详细分析、需求映射与遗留风险见 [`../T1-03-REPORT.md`](../T1-03-REPORT.md)。
- **P2-01 修复（2026-11-19）：** 原始命令日志（包含 Windows 计算机名、账户名与本地绝对路径）
  不进入仓库，已全部删除；保留的机器可读证据做了脱敏：计算机名/账户名替换为占位符，
  仓库路径替换为 `<repo-root>`，UAT 根路径替换为 `<uat-root>`，系统/Python 路径替换为
  `<windows-root>` / `<python-exe>`。产品默认部署路径 `D:\WorkManager`（DEC-002）作为产品
  需求路径保留。脱敏策略与扫描结果见 [`SANITIZATION.md`](SANITIZATION.md)；脱敏只替换机器
  标识与路径，未改动断言数量、结果、错误码、随机 ID 与哈希。
