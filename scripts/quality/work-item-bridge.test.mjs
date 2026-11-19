/**
 * T1-03 工作事项 Bridge 运行时契约测试。
 *
 * 直接加载 src/lib/bridge/workItemValidation.ts（纯 TypeScript，无 Tauri/DOM 依赖），
 * 验证 Bridge 对成功返回值的运行时校验：
 * - 合法 DTO / 合法列表通过；
 * - 缺字段、错误类型、非数组、非法 lifecycleStatus、项目字段不一致一律拒绝；
 * - 拒绝时抛出稳定错误码 `ipc-contract-violation` 的 WorkItemIpcError。
 *
 * 不新增前端测试框架依赖，使用 Node 内置 `node:test` / `node:assert`。
 * 运行：node --test scripts/quality/work-item-bridge.test.mjs
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CONTRACT_VIOLATION_CODE,
  WorkItemIpcError,
  parsePendingWorkItemList,
  parseWorkItem
} from '../../src/lib/bridge/workItemValidation.ts';

function validPendingWorkItem(overrides = {}) {
  return {
    id: '9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a001',
    projectId: null,
    projectName: null,
    projectIsArchived: false,
    title: '整理中核商品数据',
    lifecycleStatus: 'pending',
    createdAt: '2026-11-19T10:00:00.000Z',
    updatedAt: '2026-11-19T10:00:00.000Z',
    ...overrides
  };
}

function validWorkItem(overrides = {}) {
  return {
    id: '9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a002',
    projectId: null,
    title: '未归属工作',
    lifecycleStatus: 'pending',
    createdAt: '2026-11-19T10:00:00.000Z',
    updatedAt: '2026-11-19T10:00:00.000Z',
    ...overrides
  };
}

function expectContractViolation(action) {
  assert.throws(action, (error) => {
    assert.ok(error instanceof WorkItemIpcError, '必须抛出 WorkItemIpcError');
    assert.equal(error.code, CONTRACT_VIOLATION_CODE);
    assert.match(error.message, /不符合契约/);
    return true;
  });
}

test('合法未归属待安排 DTO 通过校验并保留 null 语义', () => {
  const parsed = parsePendingWorkItemList([validPendingWorkItem()]);
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].projectId, null);
  assert.equal(parsed[0].projectName, null);
  assert.equal(parsed[0].projectIsArchived, false);
  assert.equal(parsed[0].lifecycleStatus, 'pending');
});

test('合法关联项目（含已归档项目历史关联）DTO 通过校验', () => {
  const parsed = parsePendingWorkItemList([
    validPendingWorkItem({
      projectId: '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000',
      projectName: '虚构归档项目',
      projectIsArchived: true
    })
  ]);
  assert.equal(parsed[0].projectId, '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000');
  assert.equal(parsed[0].projectName, '虚构归档项目');
  assert.equal(parsed[0].projectIsArchived, true);
});

test('空列表通过校验', () => {
  assert.deepEqual(parsePendingWorkItemList([]), []);
});

test('非数组返回值被拒绝', () => {
  expectContractViolation(() => parsePendingWorkItemList({}));
  expectContractViolation(() => parsePendingWorkItemList(null));
});

test('缺失必填字段被拒绝', () => {
  for (const field of [
    'id',
    'projectId',
    'projectName',
    'projectIsArchived',
    'title',
    'lifecycleStatus',
    'createdAt',
    'updatedAt'
  ]) {
    const malformed = validPendingWorkItem();
    delete malformed[field];
    expectContractViolation(() => parsePendingWorkItemList([malformed]));
  }
});

test('字段类型错误被拒绝', () => {
  expectContractViolation(() => parsePendingWorkItemList([validPendingWorkItem({ id: 42 })]));
  expectContractViolation(() => parsePendingWorkItemList([validPendingWorkItem({ title: '   ' })]));
  expectContractViolation(() =>
    parsePendingWorkItemList([validPendingWorkItem({ projectIsArchived: 'false' })])
  );
  expectContractViolation(() =>
    parsePendingWorkItemList([validPendingWorkItem({ createdAt: 1700000000 })])
  );
});

test('非 pending 状态不得混入待安排列表', () => {
  for (const status of ['in_progress', 'completed', 'abandoned', 'not_started', 'unknown']) {
    expectContractViolation(() =>
      parsePendingWorkItemList([validPendingWorkItem({ lifecycleStatus: status })])
    );
  }
});

test('项目字段语义不一致被拒绝', () => {
  // projectId 为 null 但 projectName 非 null。
  expectContractViolation(() =>
    parsePendingWorkItemList([validPendingWorkItem({ projectName: '虚构项目' })])
  );
  // projectId 非 null 但 projectName 为 null。
  expectContractViolation(() =>
    parsePendingWorkItemList([
      validPendingWorkItem({ projectId: '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000' })
    ])
  );
  // 未归属项目却被标记为归档。
  expectContractViolation(() =>
    parsePendingWorkItemList([validPendingWorkItem({ projectIsArchived: true })])
  );
});

test('创建接口返回的工作事项 DTO 通过校验', () => {
  const parsed = parseWorkItem(validWorkItem());
  assert.equal(parsed.id, validWorkItem().id);
  assert.equal(parsed.projectId, null);
  assert.equal(parsed.lifecycleStatus, 'pending');

  const linked = parseWorkItem(
    validWorkItem({ projectId: '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000' })
  );
  assert.equal(linked.projectId, '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000');
});

test('创建接口返回的非法 DTO 被拒绝', () => {
  expectContractViolation(() => parseWorkItem(null));
  expectContractViolation(() => parseWorkItem(validWorkItem({ id: '' })));
  expectContractViolation(() => parseWorkItem(validWorkItem({ projectId: 123 })));
  expectContractViolation(() => parseWorkItem(validWorkItem({ lifecycleStatus: 'completed' })));
  expectContractViolation(() => parseWorkItem(validWorkItem({ title: '' })));
});
