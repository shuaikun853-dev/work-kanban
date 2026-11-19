# T1-03 证据索引（第二轮定向修复后）

本目录保存 T1-03「工作事项快速创建和待安排区域」的开发自测证据。所有测试数据均为虚构内容；
UAT 运行目录为专用测试根目录下的一次性新目录 `<uat-root>\t1-03-ui-run4`（D 盘隔离目录），
未触碰正式运行目录 `D:\WorkManager`，未使用真实用户工作数据。

## 内容

| 路径 | 内容 |
|---|---|
| `screenshots/` | 19 张真实 Release WebView2 截图：正常窗口、最小窗口 860×640、loading/empty/error、快速创建、项目选择器、归档竞态错误、归档项目历史关联、加载失败/契约违规、创建成功但刷新失败/恢复（P3-01）、长标题、关闭重开后持久化 |
| `evidence/t1-03-ui-evidence.json` | 主 UI/IPC 84 项断言（含每项 PASS/FAIL 与 detail）、页面异常、CSP 违规、确定性等待与截图清单 |
| `evidence/t1-03-min-window-evidence.json` | 最小窗口 12 项断言 + 关闭按钮点击记录 |
| `evidence/t1-03-persistence-evidence.json` | 关闭重开持久化 17 项断言 |
| `evidence/t1-03-uat-path-evidence.json` | UAT 输出目录安全 23 项断言（P3-02） |
| `evidence/t1-03-ui-orchestration.json` | E2E 编排汇总：EXE 路径/大小/SHA-256、各阶段退出码与断言计数、数据库探针路径、截图清单、pass |
| `evidence/t1-03-prerequisite.json` | 重启阶段之前的真实 IPC 数据快照（虚构工作事项与项目） |
| `evidence/t1-03-db-after-main.json` | 第一次真实关闭后的数据库只读探针（schema/完整性/行数/状态分布/外键） |
| `evidence/t1-03-db-after-restart.json` | 重新启动并再次关闭后的数据库只读探针（持久化后） |
| `evidence/release-regression-portable-summary.json` | 继承 T1-01 便携验证（106 项，含既有 1 WARN） |
| `evidence/release-regression-faults-summary.json` | 继承 T1-01 异常注入验证（73 项） |
| `evidence/release-regression-t1-02-ui-orchestration.json` | 继承 T1-02 Release UI E2E 编排证据 |
| `test-counts.txt` | 测试数量、环境、数据库探针关键事实速查 |
| `SANITIZATION.md` | 证据脱敏策略、扫描结果与范围说明（P2-01） |

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

# 3. UAT 输出目录路径安全专项测试
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1

# 4. Release 构建
npm run tauri build -- --no-bundle

# 5. T1-03 Release E2E（主检查 → 最小窗口 → 真实关闭 → DB 探针 → 重启持久化 → 关闭）
#    输出目录必须位于专用测试根目录之下，且必须是新的/空目录（P3-02）。
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-03-ui.ps1 `
    -OutputDir <uat-root>\t1-03-ui-<timestamp>

# 6. 继承回归
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
```

## 重要说明

- 本证据为**开发自测**证据，不构成第二轮独立审计结论或用户验收结论。
- 详细分析、需求映射与遗留风险见 [`../T1-03-REPORT.md`](../T1-03-REPORT.md)。
- **P2-01 修复：** 原始命令日志（包含计算机名、账户名与本地绝对路径）不进入仓库，已全部删除；
  保留的机器可读证据已脱敏。脱敏策略、扫描结果与范围说明见 [`SANITIZATION.md`](SANITIZATION.md)；
  脱敏只替换机器标识与路径，未改动断言数量、结果、错误码、随机 ID 与哈希（11/11 结构一致）。
- **P3-02：** 编排脚本拒绝正式应用目录、专用测试根目录之外的目录、含既有数据库的目录与非空未知目录；
  不会清空/覆盖/删除既有目录，每次测试必须使用新目录。
