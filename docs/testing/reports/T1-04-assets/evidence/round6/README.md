# T1-04 第六轮定向修复证据（round6）

本目录保存 T1-04 第六轮定向修复（R2-01～R2-04）的原始命令输出与机器可读证据。
所有测试均使用 `D:\WorkManager-test-data` 下的独立 UAT 目录与虚构数据；正式运行
目录 `D:\WorkManager` 仅做只读身份快照（本机不存在），未打开、未修改、未写入。

## 证据清单

| 文件 | 内容 |
|---|---|
| `environment.txt` | 机器/工具链（Python、Node、cargo、PowerShell）、分支、基线 HEAD、时间 |
| `release-exe.sha256` | 第六轮重建 Release EXE 的大小与 SHA-256 |
| `bridge-baseline-subagent.txt` | R2-03 修改前 Bridge 基线（27/27 PASS） |
| `bridge-red.txt` | R2-03 新增测试 + 旧实现：Red 原始输出（35 项中 11 项失败） |
| `bridge-green.txt` | R2-03 实现后 Green 原始输出（35/35 PASS） |
| `bridge-svelte-check.txt` | Bridge 变更后 `svelte-check` 输出（0 errors / 0 warnings） |
| `path-safety-red.txt` | R2-01 新测试首次执行（守卫能力未实现，Red/前置失败） |
| `path-safety-output.txt` / `path-safety-evidence.json` | R2-01 专项最终执行原始输出与机器可读证据（58 项 / 0 FAIL / 1 SKIP；Junction 拒绝、Canary 前后一致、清理 fail-closed、正式目录只读快照） |
| `migration-path-red.txt` | R2-02 新测试在旧工具上的 Red 原始输出（含祖先 Junction 被接受并写入的漏洞证据） |
| `migration-path-output.txt` / `migration-path-evidence.json` | R2-02 专项最终执行原始输出与机器可读证据（31 项 / 0 FAIL） |
| `migration-failure-output.txt` / `migration-failure-evidence.json` | 真实 Release migration 失败回滚（原生守卫 PASS、退出码 1 回调滚不变量、fail-closed 清理 PASS、证据写入 PASS） |
| `tdd-*.txt` | R2-01/R2-02 测试先行 Red 与修复后 Green 记录（与上面输出一致，便于审计定位） |
| `gate-*.txt` | 质量门禁原始输出：`cargo fmt` / `cargo check` / `cargo test` / `npm run check` / `npm run build` / `git diff --check` |
| `release-e2e-output.txt` | 第六轮重建 EXE 后的 T1-04 Release E2E 原始输出（主 UI/IPC、最小窗口、原子回滚、重启持久化、数据库探针） |
| `release-e2e-evidence/` | E2E 机器可读证据 JSON 与截图（从 UAT 证据目录复制） |
| `inherited-*.txt` | 继承回归原始输出：T1-01 便携、T1-01 异常注入、T1-02 UI E2E、T1-03 路径安全专项 |
| `git-diff.patch` / `git-diff-stat.txt` | 本轮修复的完整 Git diff 与统计（不含本证据目录） |
| `test-counts.txt` | 新增/保留测试数量、PASS/FAIL/SKIP 与退出码汇总 |

## 复现命令（Windows PowerShell 5.1）

```powershell
# 1) 构建 Release（含 npm run build）
npm run tauri build -- --no-bundle

# 2) 质量门禁
cargo fmt --all -- --check
cargo check --workspace --all-targets
cargo test --workspace --no-fail-fast
npm run check
npm run build
git diff --check

# 3) R2-01 路径安全专项（证据必须写到 <UAT根>\evidence\<file>.json）
python -X utf8 scripts\verify\test-t1-04-path.py `
    --evidence D:\WorkManager-test-data\t1-04-path-evidence-r6-<timestamp>\evidence\t1-04-path-evidence.json

# 4) R2-02 Migration 路径专项
python -X utf8 scripts\verify\test-t1-04-migration-path.py `
    --evidence D:\WorkManager-test-data\t1-04-path-evidence-r6-<timestamp>\evidence\t1-04-migration-path-evidence.json

# 5) 真实 Release migration 失败回滚
$out = "D:\WorkManager-test-data\t1-04-migration-failure-r6-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-04-migration-failure.ps1 `
    -OutputDir $out -EvidencePath "$out\evidence\t1-04-migration-failure-evidence.json"

# 6) Release E2E / 原子回滚 / 持久化
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-04-ui.ps1

# 7) 继承回归
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-portable.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-release-faults.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\verify-t1-02-ui.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify\test-t1-03-uat-path.ps1
```

安全说明：证据 JSON 中的绝对路径已替换为 `<test-root>` / `<formal-root>` /
`<repo-root>` 等占位符，不包含机器名/用户名等机器标识；Junction 目标 Canary
前后一致。

残余风险：DEC-029 / Issue #2 的 TOCTOU 并发路径替换窗口仍存在；本轮只治理静态
Junction / 重解析点 / 路径身份校验，不宣称消除并发替换。普通 SQLite 未加密。
