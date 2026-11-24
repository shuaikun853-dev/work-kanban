# T1-04 第六轮独立审计后定向补正证据（round6-remediation）

本目录独立保存 R6-01 / R6-02 / R6-03 的开发代理自测证据，不覆盖
`../round6/` 的第六轮原始证据，也不构成独立审计或用户验收。

## R6-01 标题 Unicode White_Space 规范化

| 文件 | 内容 |
|---|---|
| `r6-01-rust-baseline-red.txt` | 新增 Rust 契约测试在修复前的执行结果（9 passed；证明 Rust `char::is_whitespace()` 已与 25 字符集合一致，Red 位于 JavaScript 侧） |
| `r6-01-rust-green.txt` | 同一组 Rust 测试在补正后的真实输出（9 passed / 0 failed） |
| `r6-01-bridge-red.txt` | 新增 13 项 Bridge 用例在旧 `.trim()` 实现上的真实输出（35 项原有通过，R6-01 中 U+0085、U+FEFF 等 4 项失败，退出码 1） |
| `r6-01-bridge-green.txt` | 补正后 Bridge 全量 **48/48 PASS**，退出码 0 |
| `r6-01-cross-contract-red-baseline.txt` | 在 `de8f622` 基线 worktree 中执行真实 Rust/Bridge 交叉契约测试的 Red 原始输出（Bridge 拒绝合法服务端标题，退出码 1） |
| `r6-01-cross-contract-green.txt` | 补正后真实 Rust SQLite 保存/读回 → Bridge 解析交叉测试 **1/1 PASS**，10 个标题场景全部通过，退出码 0 |

关键验证逻辑：

- Rust 与 TypeScript 固定同一 Unicode `White_Space` 字符集合（25 个字符）；
- U+0085 两端删除，U+FEFF 两端保留；TAB、CR/LF、U+3000、ASCII 空格两端删除；
- 内部多空格、内部 TAB、大小写与 combining sequence 原样保留；
- 真实 `create_copies` 同一 requestId 连续两次返回原批次，不重复写副本；
- Rust 返回的实际标题交给 Bridge；Bridge 不因规范化差异误报合法响应。

## R6-02 Migration 清理悬空 Junction 防护

| 文件 | 内容 |
|---|---|
| `r6-02-cleanup-red.txt` | 新增真实 Windows 故障注入测试在补正前的 Red 输出（6 个场景因原生入口类型 / stopCode 尚未实现而失败，仅全局 Canary 通过；退出码 1） |
| `r6-02-cleanup-green.txt` | 补正后 **8 PASS / 0 FAIL / 1 SKIP**，退出码 0；真实 Junction 入口、悬空 Junction、Canary 与清理后身份检查全部覆盖 |
| `r6-02-path-safety.txt` | T1-04 路径安全专项 **58 项 / 0 FAIL / 1 SKIP**，退出码 0（其中最后 2 项 `evidence.writeSucceeded` / `evidence.machineIdentifiersRedacted` 在证据 JSON 写入后复核） |
| `r6-02-migration-path.txt` | T1-04 Migration 路径专项 **31 项 / 0 FAIL**，退出码 0（同样有最后 2 项写后复核） |
| `path-safety-evidence.json` | 路径专项写证据前的 56 项检查快照；最终 58 项以 `r6-02-path-safety.txt` 为准 |
| `migration-path-evidence.json` | Migration 路径专项写证据前的 29 项检查快照；最终 31 项以 `r6-02-migration-path.txt` 为准 |
| `r6-02-canary-comparison.txt` | Canary 前后 SHA-256 对比（R6-02 测试、路径专项、Migration 专项） |

环境限制（如实记录）：

- Windows 10 19045 上，本次真实悬空 Junction 的普通 `Test-Path` 返回 `True`，
  未在当前环境复现“`Test-Path` 返回 false 后直接 `alreadyAbsent`”的具体分支；
  测试仍记录真实 `Test-Path` 结果，并验证原生句柄识别为 Junction、清理返回
  `danglingJunction` 且 fail-closed，未使用模拟对象冒充真实 Junction。
- 当前进程无 `SeCreateSymbolicLinkPrivilege`，真实 Symbolic Link 创建显式 SKIP；
  未把 SKIP 伪报为 PASS。其他 reparse point 只验证 tag 映射，未宣称完成真实
  其他重解析点文件系统注入。

## R6-03 文档与注释

| 文件 | 内容 |
|---|---|
| `git-diff-stat.txt` / `git-diff.patch` | 补正完整 Git diff（提交前生成） |
| `git-diff-check.txt` | `git diff --check` 原始输出与退出码 |
| `git-log.txt` | 补正提交记录与远程同步状态 |

## 质量门禁与 Release

| 文件 | 内容 |
|---|---|
| `gate-cargo-fmt.txt` | `cargo fmt --all -- --check` |
| `gate-cargo-check.txt` | `cargo check --workspace --all-targets` |
| `gate-cargo-test.txt` | `cargo test --workspace --no-fail-fast` |
| `gate-npm-check.txt` | `npm run check`（svelte-check + Bridge 48 + 交叉契约 + Design Token） |
| `gate-npm-build.txt` | `npm run build` |
| `release-build.txt` | Release EXE 构建输出 |
| `release-exe.sha256` | Release EXE 大小与 SHA-256 |
| `release-e2e-output.txt` | T1-04 Release UI/IPC E2E 原始输出 |
| `migration-failure-output.txt` | 真实 Release migration 失败回滚原始输出 |
| `migration-failure-evidence.json` | 真实 Release migration 失败回滚证据 JSON |
| `evidence-summary.json` | 本目录证据汇总（测试计数、EXE 哈希、Git 状态、遗留风险） |
| `git-diff.patch` / `git-diff-stat.txt` / `git-log.txt` | 修复提交 `ada8590` 的完整 diff、统计与提交信息；diff 证据仅做行尾空白规范化以满足仓库 `git diff --check`，语义内容不变 |
| `t1-04-ui-orchestration.json` | Release E2E 编排汇总（107/11/13/15/62、关闭退出码 0/0/0） |

所有路径类证据均经过既有脱敏；测试根显示为 `<test-root>`，正式目录显示为
`<formal-root>`。正式目录 `<formal-root>` 未访问、未写入。
