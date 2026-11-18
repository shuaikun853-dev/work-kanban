#!/usr/bin/env node
/**
 * WorkManager Design Token 静态检查。
 *
 * 目的（T1-02 第一轮独立审计 P2-01 返工）：
 * - 禁止 Feature 页面、通用 UI 组件与相关 UI CSS 再次散落 raw hex / rgb / rgba / hsl / hsla；
 * - 所有颜色必须来自中央 Design Token 文件 src/lib/ui/tokens.css；
 * - 中央 Token 定义文件本身允许保留原始颜色值（它是颜色的唯一来源）。
 *
 * 检查范围（不豁免任何 Feature / 组件目录）：
 * - src/**\/*.svelte 的 <style> 块；
 * - src/**\/*.svelte 的静态内联 style="..." / style='...' 属性；
 * - src/**\/*.css 的全部样式声明。
 * 唯一允许保留原始颜色的文件：src/lib/ui/tokens.css。
 *
 * 退出码：
 * - 0：通过（无违规）；
 * - 1：发现 raw color 违规；
 * - 2：检查无法执行（根目录 / src 不存在或未扫描到任何文件）。
 *
 * 用法：
 *   node scripts/quality/check-design-tokens.mjs
 *   node scripts/quality/check-design-tokens.mjs --root <repoRoot> --report <output.json>
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '..', '..');

/** 中央 Design Token 定义文件（唯一允许出现原始颜色值的文件）。 */
export const TOKEN_FILE_RELATIVE = 'src/lib/ui/tokens.css';

/** 需要检查的文件扩展名。 */
const SCAN_EXTENSIONS = new Set(['.svelte', '.css']);

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

function stripHtmlComments(text) {
  return text.replace(/<!--[\s\S]*?-->/g, (comment) => comment.replace(/[^\n]/g, ' '));
}

function locate(content, index) {
  const before = content.slice(0, index);
  const line = before.split('\n').length;
  const lastNewline = before.lastIndexOf('\n');
  const column = index - lastNewline;
  return { line, column };
}

function collectMatches(text, filePath, originalContent, offset, source, violations) {
  for (const { kind, pattern } of COLOR_PATTERNS) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      const index = offset + match.index;
      const { line, column } = locate(originalContent, index);
      violations.push({
        file: filePath,
        line,
        column,
        kind,
        raw: match[0].trim(),
        source
      });
    }
  }
}

function scanContent(relativeFile, content, violations) {
  if (relativeFile.endsWith('.css')) {
    collectMatches(
      stripCssComments(content),
      relativeFile,
      content,
      0,
      'css-file',
      violations
    );
    return;
  }

  // .svelte：<style> 块
  const styleBlockPattern = /<style\b[^>]*>([\s\S]*?)<\/style>/gi;
  let styleMatch;
  while ((styleMatch = styleBlockPattern.exec(content)) !== null) {
    const openTagEnd = styleMatch.index + styleMatch[0].indexOf('>') + 1;
    const styleContent = styleMatch[1];
    collectMatches(
      stripCssComments(styleContent),
      relativeFile,
      content,
      openTagEnd,
      'svelte-style-block',
      violations
    );
  }

  // .svelte：静态内联 style 属性
  const markup = stripHtmlComments(content);
  const inlineStylePattern = /\bstyle\s*=\s*(?:"([^"]*)"|'([^']*)')/gi;
  let inlineMatch;
  while ((inlineMatch = inlineStylePattern.exec(markup)) !== null) {
    const value = inlineMatch[1] ?? inlineMatch[2] ?? '';
    const valueStart = inlineMatch.index + inlineMatch[0].indexOf(value);
    collectMatches(value, relativeFile, content, valueStart, 'inline-style-attribute', violations);
  }
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
      console.error(
        `${violation.file}:${violation.line}:${violation.column} ${violation.kind} ` +
          `raw=${JSON.stringify(violation.raw)} source=${violation.source} ` +
          `→ 请改用 src/lib/ui/tokens.css 中的语义 Token`
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
