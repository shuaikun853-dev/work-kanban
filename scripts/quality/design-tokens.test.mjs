/**
 * Design Token 静态检查自身的自动化测试。
 *
 * 对应 T1-02 第一轮独立审计 P2-01 返工要求：
 * - 出现原始颜色（HEX / RGB / RGBA / HSL）时检查必须失败；
 * - 使用 Design Token 时检查通过；
 * - 中央 Token 定义文件中的原始颜色不会被误报；
 * - Feature / 通用组件目录不得被整体豁免。
 */

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const CHECKER_PATH = path.join(SCRIPT_DIR, 'check-design-tokens.mjs');
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');

const TOKEN_DEFINITION = `:root {
  --color-surface: #ffffff;
  --color-accent: #007aff;
  --shadow-card: 0 1px 2px rgba(15, 23, 42, 0.04);
}
`;

const COMPONENT_WITH_TOKEN = `<div class="card">ok</div>

<style>
  .card {
    background-color: var(--color-surface);
    color: var(--color-text-primary);
    box-shadow: var(--shadow-card);
  }
</style>
`;

const temporaryRoots = [];

function makeRoot(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wm-design-tokens-'));
  temporaryRoots.push(root);
  for (const [relativePath, content] of Object.entries(files)) {
    const absolutePath = path.join(root, relativePath);
    fs.mkdirSync(path.dirname(absolutePath), { recursive: true });
    fs.writeFileSync(absolutePath, content, 'utf8');
  }
  return root;
}

function runChecker(args) {
  return spawnSync(process.execPath, [CHECKER_PATH, ...args], {
    encoding: 'utf8',
    timeout: 30000
  });
}

after(() => {
  for (const root of temporaryRoots) {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('使用 Design Token 的组件与 CSS 通过检查', () => {
  const root = makeRoot({
    'src/lib/ui/tokens.css': TOKEN_DEFINITION,
    'src/lib/features/demo/DemoPage.svelte': COMPONENT_WITH_TOKEN,
    'src/app.css': 'body { background-color: var(--color-canvas); }\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /violations=0/);
});

test('Svelte <style> 块中的 HEX 原始颜色导致检查失败', () => {
  const root = makeRoot({
    'src/lib/ui/tokens.css': TOKEN_DEFINITION,
    'src/lib/features/demo/Widget.svelte': `<div>demo</div>

<style>
  .widget {
    color: #ffffff;
  }
</style>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /src\/lib\/features\/demo\/Widget\.svelte:5:12 hex/);
});

test('内联 style 属性中的 RGBA 原始颜色导致检查失败', () => {
  const root = makeRoot({
    'src/lib/ui/tokens.css': TOKEN_DEFINITION,
    'src/lib/features/demo/Inline.svelte':
      '<div style="background-color: rgba(0, 0, 0, 0.5)">demo</div>\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /Inline\.svelte:1:\d+ rgb/);
  assert.match(result.stderr, /inline-style-attribute/);
});

test('Feature/UI CSS 文件中的 RGB/HSL 原始颜色不得被目录豁免', () => {
  const root = makeRoot({
    'src/lib/ui/tokens.css': TOKEN_DEFINITION,
    'src/lib/ui/components/legacy.css': '.legacy { color: rgb(1, 2, 3); }\n',
    'src/lib/features/demo/demo.css': '.demo { color: hsla(210, 40%, 20%, 0.5); }\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /legacy\.css:1:\d+ rgb/);
  assert.match(result.stderr, /demo\.css:1:\d+ hsl/);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=2/);
});

test('中央 Token 定义文件中的原始颜色不会被误报', () => {
  const root = makeRoot({
    'src/lib/ui/tokens.css': TOKEN_DEFINITION,
    'src/app.css': 'body { background-color: var(--color-canvas); }\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /files=1 /);

  const reportPath = path.join(root, 'token-report.json');
  const reportResult = runChecker(['--root', root, '--report', reportPath]);
  assert.equal(reportResult.status, 0, reportResult.stderr);
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.pass, true);
  assert.equal(report.filesScanned, 1);
  assert.deepEqual(report.violations, []);
  assert.equal(report.scannedFiles.includes('src/lib/ui/tokens.css'), false);
});

test('检查报告包含可复核的文件、行号、类型与原始值', () => {
  const root = makeRoot({
    'src/lib/ui/tokens.css': TOKEN_DEFINITION,
    'src/lib/features/demo/Report.svelte': `<style>
  .a {
    border-color: #f3c6c1;
  }
</style>
`
  });

  const reportPath = path.join(root, 'violations.json');
  const result = runChecker(['--root', root, '--report', reportPath]);
  assert.equal(result.status, 1, result.stderr);
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.pass, false);
  assert.equal(report.violations.length, 1);
  const violation = report.violations[0];
  assert.equal(violation.file, 'src/lib/features/demo/Report.svelte');
  assert.equal(violation.line, 3);
  assert.equal(violation.kind, 'hex');
  assert.equal(violation.raw, '#f3c6c1');
  assert.equal(violation.source, 'svelte-style-block');
});

test('--root 不存在 src/ 时检查以错误码 2 失败而不是静默通过', () => {
  const emptyRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'wm-design-tokens-empty-'));
  temporaryRoots.push(emptyRoot);

  const result = runChecker(['--root', emptyRoot]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=ERROR/);
});

test('真实仓库当前代码通过 Design Token 静态检查', () => {
  const result = runChecker(['--root', REPO_ROOT]);
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  const match = result.stdout.match(/files=(\d+) violations=0/);
  assert.ok(match, result.stdout);
  assert.ok(Number(match[1]) >= 15, `扫描文件数异常：${match[1]}`);
});
