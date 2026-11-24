/**
 * 工作标题规范化契约（Rust Core 与 TypeScript 共用的权威字符集合）。
 *
 * 权威规则：只删除标题首尾属于 Unicode `White_Space` 属性的字符，内部字符
 * 原样保留；不改变大小写，不进行 NFC / NFKC 或其他 Unicode 规范化。
 *
 * 必须与 Rust `normalize_title` 完全一致。Rust 的 `char::is_whitespace()` 使用
 * Unicode `White_Space` 属性；本模块显式列出同一集合，避免依赖 JavaScript
 * `String.trim()` 的不同定义：
 * - JavaScript `trim()` 会删除 U+FEFF，而 Unicode `White_Space` 不包含它；
 * - JavaScript `trim()` 不删除 U+0085，而 Unicode `White_Space` 包含它。
 *
 * 集合中的字符全部位于 BMP，因此按 UTF-16 code unit 检查首尾不会误伤代理对；
 * 非 BMP 字符不属于该集合。
 */

/** Unicode `White_Space` 属性的 25 个字符（与 Rust `char::is_whitespace()` 一致）。 */
export const WORK_ITEM_TITLE_WHITESPACE_CODEPOINTS = [
  0x0009, // CHARACTER TABULATION
  0x000a, // LINE FEED
  0x000b, // LINE TABULATION
  0x000c, // FORM FEED
  0x000d, // CARRIAGE RETURN
  0x0020, // SPACE
  0x0085, // NEXT LINE
  0x00a0, // NO-BREAK SPACE
  0x1680, // OGHAM SPACE MARK
  0x2000, // EN QUAD
  0x2001, // EM QUAD
  0x2002, // EN SPACE
  0x2003, // EM SPACE
  0x2004, // THREE-PER-EM SPACE
  0x2005, // FOUR-PER-EM SPACE
  0x2006, // SIX-PER-EM SPACE
  0x2007, // FIGURE SPACE
  0x2008, // PUNCTUATION SPACE
  0x2009, // THIN SPACE
  0x200a, // HAIR SPACE
  0x2028, // LINE SEPARATOR
  0x2029, // PARAGRAPH SEPARATOR
  0x202f, // NARROW NO-BREAK SPACE
  0x205f, // MEDIUM MATHEMATICAL SPACE
  0x3000 // IDEOGRAPHIC SPACE
] as const;

const WORK_ITEM_TITLE_WHITESPACE = new Set<number>(WORK_ITEM_TITLE_WHITESPACE_CODEPOINTS);

/**
 * 删除标题首尾的 Unicode `White_Space` 字符。
 *
 * - 不删除 U+FEFF（ZERO WIDTH NO-BREAK SPACE），它不属于 `White_Space`；
 * - 不改变内部空白、大小写或任何其他字符；
 * - 返回新字符串，不修改入参。
 */
export function normalizeWorkItemTitle(value: string): string {
  let start = 0;
  let end = value.length;

  while (start < end && WORK_ITEM_TITLE_WHITESPACE.has(value.charCodeAt(start))) {
    start += 1;
  }
  while (end > start && WORK_ITEM_TITLE_WHITESPACE.has(value.charCodeAt(end - 1))) {
    end -= 1;
  }

  return value.slice(start, end);
}
