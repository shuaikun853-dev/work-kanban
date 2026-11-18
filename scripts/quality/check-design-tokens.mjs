#!/usr/bin/env node
/**
 * WorkManager Design Token 静态检查。
 *
 * 目的（T1-02 独立审计 P2-01）：
 * - 禁止 Feature 页面、通用 UI 组件与相关 UI CSS 散落 raw hex / rgb / rgba / hsl / hsla；
 * - 所有颜色必须来自中央 Design Token 文件 src/lib/ui/tokens.css；
 * - 中央 Token 定义文件本身允许保留原始颜色值（它是颜色的唯一来源）。
 *
 * 检查范围（不豁免任何 Feature / 组件目录）：
 * - src/**\/*.svelte 的 <style> 块；
 * - src/**\/*.svelte 的内联 style 属性（静态文本与简单动态表达式）；
 * - src/**\/*.svelte 的 style: 指令（静态文本与简单动态表达式）；
 * - src/**\/*.css 的全部样式声明。
 * 唯一允许保留原始颜色的文件：src/lib/ui/tokens.css。
 *
 * Svelte 模板分析使用项目已安装的 Svelte Compiler AST（`svelte/compiler` 的 `parse`），
 * 不再用正则模拟 Svelte 语法。动态样式表达式只解析“局部 const 字符串常量 + 简单别名链”：
 * - `const rawColor = "#fff"; style:color={rawColor}` → 违规；
 * - `const alias = rawColor; style:color={alias}` → 违规（别名链）；
 * - `const token = "var(--color-text)"; style:color={token}` → 通过（Design Token）；
 * - 未被用于样式的普通字符串即使包含颜色文本也不会报错。
 * 无法静态求值的表达式（函数调用、条件表达式等）按未知处理，不误报；见函数注释边界。
 *
 * AST 解析失败不会被静默跳过：检查器以退出码 2 明确报错并指出文件与解析错误。
 *
 * 退出码：
 * - 0：通过（无违规）；
 * - 1：发现 raw color 违规；
 * - 2：检查无法执行（根目录 / src 不存在、未扫描到文件，或 Svelte AST 解析失败）。
 *
 * 用法：
 *   node scripts/quality/check-design-tokens.mjs
 *   node scripts/quality/check-design-tokens.mjs --root <repoRoot> --report <output.json>
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { parse as parseSvelte } from 'svelte/compiler';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '..', '..');

/** 中央 Design Token 定义文件（唯一允许出现原始颜色值的文件）。 */
export const TOKEN_FILE_RELATIVE = 'src/lib/ui/tokens.css';

/** 需要检查的文件扩展名。 */
const SCAN_EXTENSIONS = new Set(['.svelte', '.css']);

/** Svelte 模板中承载动态值的节点类型（不同 Svelte 5 AST 版本命名不同）。 */
const MUSTACHE_NODE_TYPES = new Set(['MustacheTag', 'ExpressionTag']);

/** 仅用于简单表达式求值的 TypeScript / 括号包装节点。 */
const TRANSPARENT_EXPRESSION_NODE_TYPES = new Set([
  'TSAsExpression',
  'TSSatisfiesExpression',
  'TSTypeAssertion',
  'TSNonNullExpression',
  'ParenthesizedExpression'
]);

/**
 * raw color 识别规则。
 * 覆盖审计要求的 HEX、RGB/RGBA，并额外覆盖 HSL/HSLA 常见写法。
 */
const COLOR_PATTERNS = [
  {
    kind: 'hex',
    pattern: /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\b/g
  },
  { kind: 'rgb', pattern: /\brgba?\s*\([^)]*\)/gi },
  { kind: 'hsl', pattern: /\bhsla?\s*\([^)]*\)/gi }
];

function toPosix(relativePath) {
  return relativePath.split(path.sep).join('/');
}

/** 用空白替换注释，保留换行以维持行号准确。 */
function stripCssComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, ' '));
}

/** 从完整文件内容计算 1-based 行号/列号。 */
function locate(content, index) {
  const before = content.slice(0, index);
  const line = before.split('\n').length;
  const lastNewline = before.lastIndexOf('\n');
  const column = index - lastNewline;
  return { line, column };
}

/** 在文本中查找 raw color，返回出现位置（相对文本起点）。 */
function findColorMatches(text) {
  const matches = [];
  for (const { kind, pattern } of COLOR_PATTERNS) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      matches.push({ kind, raw: match[0].trim(), index: match.index });
    }
  }
  return matches;
}

function defaultMessage(source, raw) {
  const scope = {
    'css-file': 'CSS 样式声明',
    'svelte-style-block': '<style> 块',
    'inline-style-attribute': '内联 style 属性',
    'svelte-style-directive': 'style: 指令'
  }[source];
  return `${scope ?? '样式声明'}包含原始颜色 ${JSON.stringify(raw)}；请改用 src/lib/ui/tokens.css 中的语义 Token`;
}

/**
 * 扫描一段样式文本中的 raw color，并按原始文件偏移报告违规。
 * `offset` 必须对应 originalContent 中 text 的真实起始位置。
 */
function collectMatches(text, filePath, originalContent, offset, source, violations, extra = {}) {
  for (const match of findColorMatches(text)) {
    const { line, column } = locate(originalContent, offset + match.index);
    violations.push({
      file: filePath,
      line,
      column,
      kind: match.kind,
      raw: match.raw,
      source,
      message: defaultMessage(source, match.raw),
      ...extra
    });
  }
}

/** 解开括号/TypeScript 包装节点，返回内部表达式。 */
function unwrapExpression(node) {
  let current = node;
  while (current && TRANSPARENT_EXPRESSION_NODE_TYPES.has(current.type)) {
    current = current.expression;
  }
  return current ?? null;
}

/**
 * 从表达式提取静态字符串值。
 * 支持字符串字面量、无插值模板字符串，以及 TS `as`/`satisfies` 与括号包装。
 * 无法静态求值时返回 null（不误报）。
 */
function extractStaticString(node) {
  const expression = unwrapExpression(node);
  if (expression === null) {
    return null;
  }
  if (expression.type === 'Literal' && typeof expression.value === 'string') {
    return { value: expression.value, node: expression };
  }
  if (expression.type === 'TemplateLiteral') {
    if (expression.expressions.length !== 0) {
      return null;
    }
    const value = expression.quasis
      .map((quasi) => quasi.value.cooked ?? quasi.value.raw ?? '')
      .join('');
    return { value, node: expression };
  }
  return null;
}

/** 表达式是否是单个标识符引用；返回标识符名或 null。 */
function extractIdentifierReference(node) {
  const expression = unwrapExpression(node);
  if (expression !== null && expression.type === 'Identifier') {
    return { name: expression.name, node: expression };
  }
  return null;
}

/**
 * 收集 <script> / <script context="module"> 顶层的 const 字符串常量。
 * 只处理简单声明：const name = "literal" / const name = otherIdentifier。
 * let/var、函数调用、条件表达式等不猜值，避免误报。
 */
function collectTopLevelStringConstants(statements, content, constants) {
  for (const statement of statements) {
    if (!statement || statement.type !== 'VariableDeclaration' || statement.kind !== 'const') {
      continue;
    }
    for (const declarator of statement.declarations) {
      if (
        !declarator ||
        !declarator.id ||
        declarator.id.type !== 'Identifier' ||
        !declarator.init
      ) {
        continue;
      }
      const name = declarator.id.name;
      const definition = locate(content, declarator.id.start);
      const staticValue = extractStaticString(declarator.init);
      if (staticValue !== null) {
        constants.set(name, {
          type: 'literal',
          value: staticValue.value,
          definition: { name, ...definition }
        });
        continue;
      }
      const reference = extractIdentifierReference(declarator.init);
      if (reference !== null) {
        constants.set(name, { type: 'alias', target: reference.name, definition: { name, ...definition } });
      }
    }
  }
}

/**
 * 解析常量引用链，返回最终字符串常量及其定义位置。
 * 循环别名返回 null（不猜值）。
 */
function resolveConstantString(name, constants, seen = new Set()) {
  if (seen.has(name)) {
    return null;
  }
  seen.add(name);
  const entry = constants.get(name);
  if (!entry) {
    return null;
  }
  if (entry.type === 'literal') {
    return { value: entry.value, holderName: name, definition: entry.definition, chain: [...seen] };
  }
  if (entry.type === 'alias') {
    const resolved = resolveConstantString(entry.target, constants, seen);
    if (resolved !== null) {
      return { ...resolved, chain: [...seen] };
    }
  }
  return null;
}

/** 递归遍历 Svelte AST（带 visited 保护，跳过 loc/parent）。 */
function walkAst(node, visitor, visited = new WeakSet()) {
  if (node === null || typeof node !== 'object') {
    return;
  }
  if (Array.isArray(node)) {
    for (const child of node) {
      walkAst(child, visitor, visited);
    }
    return;
  }
  if (visited.has(node)) {
    return;
  }
  visited.add(node);
  if (typeof node.type === 'string') {
    visitor(node);
  }
  for (const [key, value] of Object.entries(node)) {
    if (key === 'loc' || key === 'parent' || key === 'metadata') {
      continue;
    }
    if (value !== null && typeof value === 'object') {
      walkAst(value, visitor, visited);
    }
  }
}

/**
 * 分析被用于样式的动态表达式：
 * - 直接字面量（如 style:color={"#fff"}）→ 违规；
 * - 局部 const 字符串常量 / 别名链（如 style:color={rawColor}）→ 违规；
 * - Design Token 字符串（如 "var(--color-text)"）→ 通过；
 * - 其它无法静态求值的表达式 → 未知，不误报。
 */
function analyzeStyleExpression(expression, filePath, content, constants, violations, options) {
  if (!expression) {
    return;
  }
  const usage = locate(content, expression.start);
  const dynamicExtra = {
    ...(options.styleDirective !== undefined ? { styleDirective: options.styleDirective } : {})
  };

  const staticValue = extractStaticString(expression);
  if (staticValue !== null) {
    for (const match of findColorMatches(staticValue.value)) {
      violations.push({
        file: filePath,
        line: usage.line,
        column: usage.column,
        kind: match.kind,
        raw: match.raw,
        source: options.source,
        message: `${options.label}中的动态表达式直接包含原始颜色 ${JSON.stringify(match.raw)}；请改用 src/lib/ui/tokens.css 中的语义 Token`,
        ...dynamicExtra
      });
    }
    return;
  }

  const reference = extractIdentifierReference(expression);
  if (reference === null) {
    return;
  }
  const resolved = resolveConstantString(reference.name, constants);
  if (resolved === null) {
    return;
  }
  for (const match of findColorMatches(resolved.value)) {
    const chainText = resolved.chain.join(' → ');
    violations.push({
      file: filePath,
      line: usage.line,
      column: usage.column,
      kind: match.kind,
      raw: match.raw,
      source: options.source,
      constant: reference.name,
      resolvedConstant: resolved.holderName,
      constantLocation: resolved.definition,
      message:
        `${options.label}中的动态表达式引用常量 ${reference.name}` +
        `（解析链 ${chainText}）包含原始颜色 ${JSON.stringify(match.raw)}；` +
        `常量定义于 ${resolved.definition.line}:${resolved.definition.column}，` +
        '请改用 src/lib/ui/tokens.css 中的语义 Token',
      ...dynamicExtra
    });
  }
}

/** 处理 style: 指令（静态文本 + 动态表达式）。 */
function scanStyleDirective(node, filePath, content, constants, violations) {
  const styleDirective = node.name;
  const parts = Array.isArray(node.value) ? node.value : [];
  for (const part of parts) {
    if (part.type === 'Text') {
      collectMatches(part.data, filePath, content, part.start, 'svelte-style-directive', violations, {
        styleDirective
      });
      continue;
    }
    if (MUSTACHE_NODE_TYPES.has(part.type)) {
      analyzeStyleExpression(part.expression, filePath, content, constants, violations, {
        source: 'svelte-style-directive-dynamic',
        label: `style:${styleDirective} 指令`,
        styleDirective
      });
    }
  }
}

/** 处理内联 style 属性（静态文本 + 动态表达式）。 */
function scanInlineStyleAttribute(node, filePath, content, constants, violations) {
  const parts = Array.isArray(node.value) ? node.value : [];
  for (const part of parts) {
    if (part.type === 'Text') {
      collectMatches(part.data, filePath, content, part.start, 'inline-style-attribute', violations);
      continue;
    }
    if (MUSTACHE_NODE_TYPES.has(part.type)) {
      analyzeStyleExpression(part.expression, filePath, content, constants, violations, {
        source: 'inline-style-attribute-dynamic',
        label: '内联 style 属性'
      });
    }
  }
}

/** 解析 Svelte 文件；解析失败必须显式报错，不能静默跳过。 */
function parseSvelteOrThrow(relativeFile, content) {
  try {
    return parseSvelte(content, {
      filename: relativeFile,
      modernAst: true,
      onwarn: () => {}
    });
  } catch (error) {
    throw new Error(
      `Svelte AST 解析失败（${relativeFile}）：${error instanceof Error ? error.message : String(error)}`
    );
  }
}

function scanSvelteContent(relativeFile, content, violations) {
  const ast = parseSvelteOrThrow(relativeFile, content);
  if (!ast || ast.html === undefined) {
    // 只有 Svelte 5 modern AST 提供 html/style directive 节点；不能静默跳过模板检查。
    throw new Error(
      `Svelte AST 解析结果缺少模板节点（${relativeFile}），当前安装的 Svelte compiler AST 版本不受检查器支持`
    );
  }

  // <style> 块：使用编译器解析出的 CSS 原文与起始偏移，保持原有违规报告格式。
  const styleContent = ast.css && ast.css.content;
  if (styleContent && typeof styleContent.styles === 'string' && styleContent.styles.length > 0) {
    collectMatches(
      stripCssComments(styleContent.styles),
      relativeFile,
      content,
      styleContent.start,
      'svelte-style-block',
      violations
    );
  }

  // 收集 <script> / <script context="module"> 顶层 const 字符串常量（含别名链）。
  const constants = new Map();
  for (const script of [ast.module, ast.instance]) {
    if (script && script.content && Array.isArray(script.content.body)) {
      collectTopLevelStringConstants(script.content.body, content, constants);
    }
  }

  // 遍历模板 AST：style: 指令与内联 style 属性。
  walkAst(ast.html, (node) => {
    if (node.type === 'StyleDirective') {
      scanStyleDirective(node, relativeFile, content, constants, violations);
    } else if (node.type === 'Attribute' && node.name === 'style') {
      scanInlineStyleAttribute(node, relativeFile, content, constants, violations);
    }
  });
}

function scanContent(relativeFile, content, violations) {
  if (relativeFile.endsWith('.css')) {
    collectMatches(stripCssComments(content), relativeFile, content, 0, 'css-file', violations);
    return;
  }
  scanSvelteContent(relativeFile, content, violations);
}

function walkFiles(root, directory, files) {
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  for (const entry of entries) {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      continue;
    }
    if (entry.isDirectory()) {
      walkFiles(root, absolutePath, files);
      continue;
    }
    if (!entry.isFile()) {
      continue;
    }
    if (!SCAN_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) {
      continue;
    }
    files.push(absolutePath);
  }
}

/**
 * 扫描一个仓库根目录下的 Design Token 合规性。
 * @param {string} root 仓库根目录（其下必须有 src/）。
 * @returns {{root: string, tokenFile: string, filesScanned: number, scannedFiles: string[], violations: Array, pass: boolean}}
 */
export function scanDesignTokens(root = DEFAULT_ROOT) {
  const absoluteRoot = path.resolve(root);
  const srcDir = path.join(absoluteRoot, 'src');
  if (!fs.existsSync(srcDir) || !fs.statSync(srcDir).isDirectory()) {
    throw new Error(`检查根目录下不存在 src/：${srcDir}`);
  }

  const files = [];
  walkFiles(absoluteRoot, srcDir, files);
  files.sort((left, right) => left.localeCompare(right));

  const scannedFiles = [];
  const violations = [];
  for (const absoluteFile of files) {
    const relativeFile = toPosix(path.relative(absoluteRoot, absoluteFile));
    if (relativeFile === TOKEN_FILE_RELATIVE) {
      // 中央 Token 定义文件是颜色的唯一来源，允许保留原始颜色。
      continue;
    }
    const content = fs.readFileSync(absoluteFile, 'utf8');
    scannedFiles.push(relativeFile);
    scanContent(relativeFile, content, violations);
  }

  if (scannedFiles.length === 0) {
    throw new Error(`没有扫描到任何 .svelte / .css 文件：${srcDir}`);
  }

  violations.sort(
    (left, right) =>
      left.file.localeCompare(right.file) || left.line - right.line || left.column - right.column
  );

  return {
    root: absoluteRoot,
    tokenFile: TOKEN_FILE_RELATIVE,
    filesScanned: scannedFiles.length,
    scannedFiles,
    violations,
    pass: violations.length === 0
  };
}

function parseArguments(argv) {
  const options = { root: DEFAULT_ROOT, report: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--root') {
      options.root = path.resolve(argv[index + 1] ?? '');
      index += 1;
    } else if (argument === '--report') {
      options.report = path.resolve(argv[index + 1] ?? '');
      index += 1;
    } else {
      throw new Error(`未知参数：${argument}`);
    }
  }
  return options;
}

function main() {
  let options;
  try {
    options = parseArguments(process.argv.slice(2));
  } catch (error) {
    console.error(`DESIGN_TOKEN_CHECK=ERROR ${error.message}`);
    process.exitCode = 2;
    return;
  }

  let result;
  try {
    result = scanDesignTokens(options.root);
  } catch (error) {
    console.error(`DESIGN_TOKEN_CHECK=ERROR ${error.message}`);
    process.exitCode = 2;
    return;
  }

  const report = {
    task: 'T1-02',
    generatedAt: new Date().toISOString(),
    purpose: '禁止 Feature/UI 组件散落原始颜色；中央 Token 文件除外',
    method: 'Svelte Compiler AST + CSS scan + simple const string resolution',
    root: result.root,
    tokenFile: result.tokenFile,
    filesScanned: result.filesScanned,
    scannedFiles: result.scannedFiles,
    violations: result.violations,
    pass: result.pass
  };

  if (options.report !== null) {
    fs.mkdirSync(path.dirname(options.report), { recursive: true });
    fs.writeFileSync(options.report, JSON.stringify(report, null, 2), 'utf8');
  }

  if (!result.pass) {
    console.error(`DESIGN_TOKEN_CHECK=FAIL violations=${result.violations.length}`);
    for (const violation of result.violations) {
      const extra = [
        violation.source,
        violation.styleDirective !== undefined ? `styleDirective=${violation.styleDirective}` : null,
        violation.constant !== undefined ? `constant=${violation.constant}` : null,
        violation.resolvedConstant !== undefined ? `resolvedConstant=${violation.resolvedConstant}` : null,
        violation.constantLocation !== undefined
          ? `constantLocation=${violation.constantLocation.line}:${violation.constantLocation.column}`
          : null
      ]
        .filter((item) => item !== null)
        .join(' ');
      console.error(
        `${violation.file}:${violation.line}:${violation.column} ${violation.kind} ` +
          `raw=${JSON.stringify(violation.raw)} ${extra} → ${violation.message}`
      );
    }
    process.exitCode = 1;
    return;
  }

  console.log(
    `DESIGN_TOKEN_CHECK=PASS files=${result.filesScanned} violations=0 tokenFile=${result.tokenFile}`
  );
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
