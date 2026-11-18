/**
 * Design Token 静态检查自身的自动化测试。
 *
 * 对应 T1-02 第一轮独立审计 P2-01 返工要求：
 * - 出现原始颜色（HEX / RGB / RGBA / HSL）时检查必须失败；
 * - 使用 Design Token 时检查通过；
 * - 中央 Token 定义文件中的原始颜色不会被误报；
 * - Feature / 通用组件目录不得被整体豁免。
 *
 * 对应第二轮独立审计 P2-01 漏检修复（Svelte StyleDirective / 动态样式常量）：
 * - style:color / style:background-color 等 StyleDirective 静态原始颜色必须失败；
 * - style:color={const} 与 const 别名链中的硬编码颜色必须失败；
 * - 动态样式引用 var(--color-*) 必须通过；
 * - 未被用于样式的普通字符串即使包含颜色文本也不得误报；
 * - Svelte AST 解析失败必须显式报错，不得静默跳过。
 *
 * 对应第四轮独立审计 P2-01 专项修复：
 * - HTML 原生元素 style 属性名大小写不敏感：STYLE / Style / sTyLe 都必须被检查
 *   （Svelte Compiler 会把它们编译成小写 style 属性）；
 * - 普通 Svelte 组件上的 Style / STYLE 是组件自定义 prop，不得误报；
 * - 条件表达式（三元）的 consequent / alternate 结果分支必须递归检查（支持嵌套），
 *   结果分支中的 Identifier 继续按 const 常量与别名链解析，test 中仅用于比较的字符串不扫描；
 * - 合法 Design Token 与无法静态求值的表达式（函数调用、逻辑表达式等）不得误报。
 *
 * 每项测试都通过真实启动检查器进程（node scripts/quality/check-design-tokens.mjs）
 * 来验证退出码、stdout/stderr 与（必要时的）机器可读报告，不直接测试正则/AST 辅助函数。
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

function makeTokenRoot() {
  return {
    'src/lib/ui/tokens.css': TOKEN_DEFINITION
  };
}

after(() => {
  for (const root of temporaryRoots) {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// 既有检查能力（第一轮审计 P2-01 建立，本轮不得删除或弱化）
// ---------------------------------------------------------------------------

test('使用 Design Token 的组件与 CSS 通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
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
    ...makeTokenRoot(),
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
    ...makeTokenRoot(),
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
    ...makeTokenRoot(),
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
    ...makeTokenRoot(),
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
    ...makeTokenRoot(),
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
  assert.ok(typeof violation.message === 'string' && violation.message.length > 0);
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

// ---------------------------------------------------------------------------
// 第二轮审计 P2-01 漏检修复：Svelte StyleDirective（静态）
// ---------------------------------------------------------------------------

test('style:color 静态硬编码 HEX 导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DirectiveColor.svelte':
      '<div style:color="#ffffff">测试</div>\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /DirectiveColor\.svelte:1:\d+ hex/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /svelte-style-directive/);
  assert.match(result.stderr, /style: 指令/);
});

test('style:background-color 静态硬编码 HEX 导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DirectiveBackground.svelte':
      '<div style:background-color="#007aff">测试</div>\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /DirectiveBackground\.svelte:1:\d+ hex/);
  assert.match(result.stderr, /raw="#007aff"/);
  assert.match(result.stderr, /svelte-style-directive/);
});

test('StyleDirective 自定义 CSS 属性的静态硬编码颜色导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DirectiveCustomProperty.svelte':
      '<div style:--brand-color="#abcdef">测试</div>\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#abcdef"/);
  assert.match(result.stderr, /styleDirective=--brand-color/);
});

// ---------------------------------------------------------------------------
// 第二轮审计 P2-01 漏检修复：StyleDirective 动态表达式与常量解析
// ---------------------------------------------------------------------------

test('动态 style:color={rawColor} 引用硬编码颜色常量导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DynamicConstant.svelte': `<script lang="ts">
  const rawColor: string = "#ffffff";
</script>

<div style:color={rawColor}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /DynamicConstant\.svelte:5:\d+ hex/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /svelte-style-directive-dynamic/);
  assert.match(result.stderr, /constant=rawColor/);
  assert.match(result.stderr, /resolvedConstant=rawColor/);
  assert.match(result.stderr, /常量定义于 2:9/);
});

test('动态 style:color={alias} 引用颜色常量别名链导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DynamicAlias.svelte': `<script lang="ts">
  const rawColor: string = "#abcdef";
  const anotherColor = rawColor;
</script>

<div style:color={anotherColor}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#abcdef"/);
  assert.match(result.stderr, /constant=anotherColor/);
  assert.match(result.stderr, /resolvedConstant=rawColor/);
  assert.match(result.stderr, /anotherColor → rawColor/);
});

test('动态 style:color 直接使用硬编码字面量导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DynamicLiteral.svelte':
      '<div style:color={"#ffffff"}>测试</div>\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /svelte-style-directive-dynamic/);
  assert.match(result.stderr, /动态表达式直接包含原始颜色/);
});

test('动态内联 style 属性引用硬编码颜色常量导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DynamicInlineStyle.svelte': `<script>
  const rawColor = "#123456";
</script>

<div style={rawColor}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#123456"/);
  assert.match(result.stderr, /inline-style-attribute-dynamic/);
  assert.match(result.stderr, /constant=rawColor/);
});

test('动态 StyleDirective 违规报告包含文件、行号、类型、原始值与常量信息', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DynamicReport.svelte': `<script>
  const rawColor = "#ffffff";
</script>

<div style:color={rawColor}>测试</div>
`
  });

  const reportPath = path.join(root, 'dynamic-report.json');
  const result = runChecker(['--root', root, '--report', reportPath]);
  assert.equal(result.status, 1, result.stderr);
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.pass, false);
  assert.equal(report.violations.length, 1);
  const violation = report.violations[0];
  assert.equal(violation.file, 'src/lib/features/demo/DynamicReport.svelte');
  assert.equal(violation.line, 5);
  assert.ok(Number.isInteger(violation.column) && violation.column > 0);
  assert.equal(violation.kind, 'hex');
  assert.equal(violation.raw, '#ffffff');
  assert.equal(violation.source, 'svelte-style-directive-dynamic');
  assert.equal(violation.styleDirective, 'color');
  assert.equal(violation.constant, 'rawColor');
  assert.equal(violation.resolvedConstant, 'rawColor');
  assert.deepEqual(violation.constantLocation, { name: 'rawColor', line: 2, column: 9 });
  assert.match(violation.message, /原始颜色/);
  assert.match(violation.message, /rawColor/);
  assert.match(violation.message, /src\/lib\/ui\/tokens\.css/);
});

// ---------------------------------------------------------------------------
// 第二轮审计 P2-01 漏检修复：合法 Token 与无关字符串不得误报
// ---------------------------------------------------------------------------

test('StyleDirective 使用 Design Token 静态值通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DirectiveToken.svelte': `<div style:color="var(--color-text)">测试</div>
<div style:background-color="var(--color-surface)">测试</div>
<div style:--brand-color="var(--color-accent)">测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
});

test('动态 style:color 引用 var(--color-text) 常量通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DynamicToken.svelte': `<script>
  const tokenColor = "var(--color-text)";
</script>

<div style:color={tokenColor}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
});

test('常量别名链最终指向 Design Token 时通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/DynamicTokenAlias.svelte': `<script>
  const baseColor = "var(--color-text)";
  const aliasColor = baseColor;
</script>

<div style:color={aliasColor}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
});

test('与样式无关的普通字符串即使包含 HEX 也不误报', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/UnrelatedString.svelte': `<script>
  const description = "颜色示例：#ffffff";
  const note = "raw color #abcdef 与 rgba(0, 0, 0, 0.5) 仅用于说明文字";
</script>

<p class={description}>{note}</p>
<div title={description}>说明文本</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
});

test('同一文件中无关颜色字符串不影响合法 Token 动态样式通过', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/Mixed.svelte': `<script>
  const description = "颜色示例：#ffffff";
  const tokenColor = "var(--color-text)";
</script>

<div style:color={tokenColor} class={description}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
});

// ---------------------------------------------------------------------------
// 第二轮审计 P2-01 漏检修复：AST 解析失败必须显式报错
// ---------------------------------------------------------------------------

test('Svelte AST 解析失败时检查器明确报错且退出码为 2', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/Broken.svelte': '<div style:color=\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=ERROR/);
  assert.match(result.stderr, /Svelte AST 解析失败/);
  assert.match(result.stderr, /Broken\.svelte/);
});

// ---------------------------------------------------------------------------
// 第四轮审计 P2-01 专项修复：HTML 原生元素 style 属性名大小写不敏感
// ---------------------------------------------------------------------------

test('HTML 元素上的 STYLE 大写属性包含硬编码 HEX 导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/UpperCaseStyle.svelte':
      '<div STYLE="color: #ffffff">测试</div>\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /UpperCaseStyle\.svelte:1:\d+ hex/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /inline-style-attribute/);
});

test('HTML 元素上的 Style 混合大小写属性包含硬编码 HEX 导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/MixedCaseStyle.svelte': `<div>其他内容</div>
<div Style="background-color: #abcdef">测试</div>
`
  });

  const reportPath = path.join(root, 'mixed-case-style-report.json');
  const result = runChecker(['--root', root, '--report', reportPath]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#abcdef"/);

  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.pass, false);
  assert.equal(report.violations.length, 1);
  const violation = report.violations[0];
  assert.equal(violation.file, 'src/lib/features/demo/MixedCaseStyle.svelte');
  assert.equal(violation.line, 2);
  assert.ok(Number.isInteger(violation.column) && violation.column > 0);
  assert.equal(violation.kind, 'hex');
  assert.equal(violation.raw, '#abcdef');
  assert.equal(violation.source, 'inline-style-attribute');
});

test('大小写变体 style 属性使用合法 Design Token 通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/CaseVariantToken.svelte': `<script>
  const tokenColor = "var(--color-text-primary)";
</script>

<div STYLE="color: var(--color-text-primary)">a</div>
<div Style="background-color: var(--color-surface)">b</div>
<div sTyLe="border-color: var(--color-accent)">c</div>
<div style="color: var(--color-text-primary)">d</div>
<div STYLE={tokenColor}>e</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /violations=0/);
});

test('普通 Svelte 组件自定义属性 Style/STYLE 不得误报', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ComponentCustomProp.svelte':
      '<Widget Style="color: #ffffff" STYLE="background-color: #abcdef" customStyle="rgba(1, 2, 3, 0.5)" />\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /violations=0/);
});

test('大写 STYLE 的动态表达式保留原有常量检测能力', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/UpperCaseDynamicStyle.svelte': `<script>
  const rawColor = "#ffffff";
</script>

<div STYLE={rawColor}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /UpperCaseDynamicStyle\.svelte:5:\d+ hex/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /inline-style-attribute-dynamic/);
  assert.match(result.stderr, /constant=rawColor/);
});

// ---------------------------------------------------------------------------
// 第四轮审计 P2-01 专项修复：条件表达式（三元）结果分支检查
// ---------------------------------------------------------------------------

test('三元表达式包含硬编码 HEX 分支导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalLiteral.svelte': `<script>
  let dark = true;
</script>

<div style:color={dark ? "#ffffff" : "var(--color-text-primary)"} />
`
  });

  const reportPath = path.join(root, 'conditional-literal-report.json');
  const result = runChecker(['--root', root, '--report', reportPath]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /svelte-style-directive-dynamic/);
  assert.match(result.stderr, /conditionalBranch=consequent/);
  assert.match(result.stderr, /条件表达式 consequent 分支/);

  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.violations.length, 1);
  const violation = report.violations[0];
  assert.equal(violation.file, 'src/lib/features/demo/ConditionalLiteral.svelte');
  assert.equal(violation.line, 5);
  assert.equal(violation.kind, 'hex');
  assert.equal(violation.raw, '#ffffff');
  assert.deepEqual(violation.conditionalBranch, ['consequent']);
  assert.match(violation.message, /条件表达式/);
  assert.match(violation.message, /consequent/);
});

test('三元表达式两个结果分支均为硬编码颜色导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalBothBranches.svelte':
      '<div style:color={dark ? "#ffffff" : "rgba(0, 0, 0, 0.5)"} />\n'
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=2/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /raw="rgba\(0, 0, 0, 0\.5\)"/);
  assert.match(result.stderr, /conditionalBranch=consequent/);
  assert.match(result.stderr, /conditionalBranch=alternate/);
});

test('三元表达式结果分支引用硬编码 const 导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalConstant.svelte': `<script>
  const rawColor = "#ffffff";
  let dark = true;
</script>

<div style:color={dark ? rawColor : "var(--color-text-primary)"} />
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /conditionalBranch=consequent/);
  assert.match(result.stderr, /constant=rawColor/);
  assert.match(result.stderr, /常量定义于 2:9/);
});

test('三元表达式结果分支引用 const 别名链导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalAlias.svelte': `<script>
  const rawColor = "#abcdef";
  const aliasColor = rawColor;
  let dark = true;
</script>

<div style:color={dark ? "var(--color-text-primary)" : aliasColor} />
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#abcdef"/);
  assert.match(result.stderr, /conditionalBranch=alternate/);
  assert.match(result.stderr, /constant=aliasColor/);
  assert.match(result.stderr, /resolvedConstant=rawColor/);
  assert.match(result.stderr, /aliasColor → rawColor/);
});

test('嵌套条件表达式结果分支包含硬编码颜色导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalNested.svelte': `<script>
  const rawColor = "#ff0000";
  let dark = true;
  let compact = false;
</script>

<div style:color={dark ? "var(--color-text-primary)" : compact ? rawColor : "var(--color-surface)"} />
`
  });

  const reportPath = path.join(root, 'conditional-nested-report.json');
  const result = runChecker(['--root', root, '--report', reportPath]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#ff0000"/);
  assert.match(result.stderr, /conditionalBranch=alternate\.consequent/);

  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(report.violations.length, 1);
  assert.deepEqual(report.violations[0].conditionalBranch, ['alternate', 'consequent']);
  assert.equal(report.violations[0].constant, 'rawColor');
});

test('条件判断比较字符串包含 HEX 但结果分支全部为 Token 时通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalTestString.svelte': `<script>
  let mode = "light";
</script>

<div style:color={mode === "#ffffff" ? "var(--color-text-primary)" : "var(--color-text-secondary)"} />
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /violations=0/);
});

test('三元表达式两个结果分支都是合法 Token 时通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalTokenBranches.svelte': `<script>
  let dark = true;
</script>

<div style:color={dark ? "var(--color-text-primary)" : "var(--color-surface)"} />
<div style:background-color={dark ? "var(--color-canvas)" : "var(--color-surface)"} />
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /violations=0/);
});

test('条件表达式与无关普通字符串共存时通过检查', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalUnrelatedString.svelte': `<script>
  const description = "颜色说明：#ffffff 与 rgba(0, 0, 0, 0.5)";
  let dark = true;
</script>

<div style:color={dark ? "var(--color-text-primary)" : "var(--color-surface)"} title={description}>{description}</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /violations=0/);
});

test('内联 style 属性中的三元表达式硬编码分支导致检查失败', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalInlineStyle.svelte': `<script>
  let dark = true;
</script>

<div style={dark ? "#ffffff" : "var(--color-text-primary)"}>测试</div>
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /DESIGN_TOKEN_CHECK=FAIL violations=1/);
  assert.match(result.stderr, /raw="#ffffff"/);
  assert.match(result.stderr, /inline-style-attribute-dynamic/);
  assert.match(result.stderr, /conditionalBranch=consequent/);
});

test('条件表达式分支中无法静态求值的表达式仍按未知处理', () => {
  const root = makeRoot({
    ...makeTokenRoot(),
    'src/lib/features/demo/ConditionalUnknown.svelte': `<div style:color={dark ? pickColor() : "var(--color-text-primary)"} />
<div style:color={dark && "#ffffff"} />
`
  });

  const result = runChecker(['--root', root]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /DESIGN_TOKEN_CHECK=PASS/);
  assert.match(result.stdout, /violations=0/);
});
