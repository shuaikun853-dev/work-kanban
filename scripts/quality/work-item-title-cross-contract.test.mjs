/**
 * R6-01 真实 Rust / Bridge 标题交叉契约测试。
 *
 * 不是分别测试两个独立函数：
 * 1. Node 把原始标题以 UTF-32 码点传给 Rust 集成测试执行器；
 * 2. Rust 测试通过真实 `WorkItemService::create_copies` + 真实 SQLite 保存并读回，
 *    同一 requestId 重试两次，证明返回原批次且没有重复副本；
 * 3. Node 把 Rust Core 实际返回的 groupId / 项目 ID / 工作事项 ID / 标题 / 时间戳
 *    组装为真实 DTO，交给 Bridge `parseCreatedWorkItemCopies` 严格校验；
 * 4. 断言 Bridge 接受该合法响应，且每个标题等于 Node 侧同一 Unicode White_Space
 *    规范化的结果。修复前该测试会因 JS `trim()` 的 U+0085 / U+FEFF 差异失败。
 *
 * 运行：node --test scripts/quality/work-item-title-cross-contract.test.mjs
 * Rust 执行器标记 #[ignore]，仅由本脚本以 --ignored 启动。
 */

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { parseCreatedWorkItemCopies } from '../../src/lib/bridge/workItemValidation.ts';
import { normalizeWorkItemTitle } from '../../src/lib/contracts/workItemTitle.ts';

const REPO_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const CASES_ENV = 'WORKMANAGER_TITLE_CROSS_CONTRACT_CASES';
const CARGO = process.env.CARGO ?? 'cargo.exe';

const CASES = [
  {
    id: 'u0085-edges',
    requestTitle: '\u0085Review 中核商品价格异常排查\u0085'
  },
  {
    id: 'ufeff-edges',
    requestTitle: '\uFEFFReview 中核商品价格异常排查\uFEFF'
  },
  {
    id: 'u3000-edges',
    requestTitle: '\u3000Review 中核商品价格异常排查\u3000'
  },
  {
    id: 'tab-edges',
    requestTitle: '\tReview 中核商品价格异常排查\t'
  },
  {
    id: 'crlf-edges',
    requestTitle: '\r\nReview 中核商品价格异常排查\n\r'
  },
  {
    id: 'ascii-edges',
    requestTitle: '  Review 中核商品价格异常排查  '
  },
  {
    id: 'internal-spaces',
    requestTitle: 'Review  中核  商品价格异常排查'
  },
  {
    id: 'internal-tab',
    requestTitle: 'Review\t中核\t商品价格异常排查'
  },
  {
    id: 'mixed-unicode',
    requestTitle: '\t\u0085\u3000Review 中核商品价格异常排查\u3000\u0085\n'
  },
  {
    id: 'ufeff-only',
    requestTitle: '\uFEFF'
  }
];

function encodeTitle(title) {
  return Array.from(title, (character) =>
    character.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
  ).join(',');
}

function decodeTitle(encoded) {
  if (encoded === '') {
    return '';
  }
  return encoded
    .split(',')
    .map((codePoint) => String.fromCodePoint(Number.parseInt(codePoint, 16)))
    .join('');
}

function loadRustResult() {
  const payload = CASES.map((item) => `${item.id}=${encodeTitle(item.requestTitle)}`).join(';');
  const result = spawnSync(
    CARGO,
    [
      'test',
      '-p',
      'workmanager-core',
      '--test',
      'title_normalization_cross_contract',
      '--',
      '--ignored',
      '--nocapture'
    ],
    {
      cwd: REPO_ROOT,
      env: { ...process.env, [CASES_ENV]: payload },
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024
    }
  );
  if (result.error !== undefined) {
    throw new Error(`无法启动 Rust 交叉契约执行器：${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(
      `Rust 交叉契约执行器失败（exit=${String(result.status)}）\n` +
        `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }
  return result.stdout;
}

function parseRustOutput(output) {
  const results = new Map();
  let current = null;
  let done = false;
  for (const line of output.split(/\r?\n/)) {
    const fields = line.split('\t');
    if (fields[0] === 'CROSS_CONTRACT_CASE') {
      current = { id: fields[1], groupId: '', items: [], retryPassed: false };
      results.set(current.id, current);
      continue;
    }
    if (fields[0] === 'CROSS_CONTRACT_GROUP' && current !== null) {
      current.groupId = fields[1];
      continue;
    }
    if (fields[0] === 'CROSS_CONTRACT_ITEM' && current !== null) {
      current.items.push({
        projectId: fields[1],
        id: fields[2],
        title: decodeTitle(fields[3]),
        createdAt: fields[4],
        updatedAt: fields[5]
      });
      continue;
    }
    if (fields[0] === 'CROSS_CONTRACT_RETRY=PASS' && current !== null) {
      current.retryPassed = true;
      continue;
    }
    if (line === 'CROSS_CONTRACT_DONE') {
      done = true;
    }
  }
  assert.equal(done, true, 'Rust 执行器必须输出完成标记');
  return results;
}

test('R6-01 Rust Core 真实保存/返回标题与 Bridge 规范化完全一致', () => {
  const rustResults = parseRustOutput(loadRustResult());
  assert.equal(rustResults.size, CASES.length, '每个 Node 用例必须有 Rust 返回结果');

  for (const titleCase of CASES) {
    const rust = rustResults.get(titleCase.id);
    assert.ok(rust !== undefined, `缺少 Rust 用例结果：${titleCase.id}`);
    assert.equal(rust.groupId.length > 0, true, 'Rust 必须返回 groupId');
    assert.equal(rust.retryPassed, true, `同一 requestId 重试必须返回原批次：${titleCase.id}`);
    assert.equal(rust.items.length, 2, `两个项目必须各一个副本：${titleCase.id}`);

    const expectedTitle = normalizeWorkItemTitle(titleCase.requestTitle);
    for (const item of rust.items) {
      assert.equal(
        item.title,
        expectedTitle,
        `Rust 返回标题必须等于 TypeScript 规范化结果：${titleCase.id}`
      );
    }

    const raw = {
      groupId: rust.groupId,
      workItems: rust.items.map((item) => ({
        id: item.id,
        projectId: item.projectId,
        title: item.title,
        lifecycleStatus: 'pending',
        importance: null,
        urgency: null,
        dueDate: null,
        description: null,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      }))
    };
    const parsed = parseCreatedWorkItemCopies(raw, {
      requestId: rust.groupId,
      title: titleCase.requestTitle,
      projectIds: rust.items.map((item) => item.projectId)
    });
    assert.equal(parsed.groupId, rust.groupId);
    assert.equal(parsed.workItems.length, 2);
    assert.ok(
      parsed.workItems.every((item) => item.title === expectedTitle),
      `Bridge 必须接受合法服务端响应且不误报创建失败：${titleCase.id}`
    );
    console.log(`CROSS_CONTRACT_BRIDGE=PASS case=${titleCase.id}`);
  }
});
