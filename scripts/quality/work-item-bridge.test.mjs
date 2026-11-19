/**
 * T1-03 工作事项 Bridge 运行时契约测试。
 *
 * 直接加载 src/lib/bridge/workItemValidation.ts（纯 TypeScript，无 Tauri/DOM 依赖），
 * 验证 Bridge 对成功返回值的严格运行时校验：
 * - Rust `WorkItem` 实际序列化 10 字段（含可空 importance/urgency/dueDate/description）；
 * - Rust `PendingWorkItem` 实际序列化 8 字段；
 * - 缺少必需字段、字段类型错误、非法 lifecycleStatus、未知字段一律拒绝；
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

/** 与 Rust `WorkItem` serde(camelCase) 输出一致的 10 字段夹具（可空字段均为 null）。 */
function rustSerializedWorkItem(overrides = {}) {
  return {
    id: '9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a002',
    projectId: null,
    title: '整理中核商品数据',
    lifecycleStatus: 'pending',
    importance: null,
    urgency: null,
    dueDate: null,
    description: null,
    createdAt: '2026-11-19T10:00:00.000Z',
    updatedAt: '2026-11-19T10:00:00.000Z',
    ...overrides
  };
}

/** 与 Rust `PendingWorkItem` serde(camelCase) 输出一致的 8 字段夹具。 */
function rustSerializedPendingWorkItem(overrides = {}) {
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

function expectContractViolation(action) {
  assert.throws(action, (error) => {
    assert.ok(error instanceof WorkItemIpcError, '必须抛出 WorkItemIpcError');
    assert.equal(error.code, CONTRACT_VIOLATION_CODE);
    assert.match(error.message, /不符合契约/);
    return true;
  });
}

// ---------------------------------------------------------------------------
// 创建响应 DTO（Rust WorkItem，10 字段）
// ---------------------------------------------------------------------------

test('完整合法创建 DTO（10 字段，四个可空字段为 null）通过校验', () => {
  const raw = rustSerializedWorkItem();
  const parsed = parseWorkItem(raw);
  assert.deepEqual(parsed, raw);
  assert.deepEqual(Object.keys(parsed).sort(), [
    'createdAt',
    'description',
    'dueDate',
    'id',
    'importance',
    'lifecycleStatus',
    'projectId',
    'title',
    'updatedAt',
    'urgency'
  ]);
});

test('创建 DTO 的四个可空字段为 NULL 时语义正确保留', () => {
  const parsed = parseWorkItem(rustSerializedWorkItem());
  assert.equal(parsed.importance, null);
  assert.equal(parsed.urgency, null);
  assert.equal(parsed.dueDate, null);
  assert.equal(parsed.description, null);
  assert.equal(parsed.projectId, null);
});

test('创建 DTO 的可空字段具有合法值时通过校验', () => {
  const raw = rustSerializedWorkItem({
    projectId: '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000',
    importance: 3,
    urgency: 5,
    dueDate: '2026-12-31',
    description: '虚构描述：已补齐可选字段'
  });
  const parsed = parseWorkItem(raw);
  assert.deepEqual(parsed, raw);
});

test('创建 DTO 缺少任一字段都被拒绝（10 字段逐一验证）', () => {
  for (const field of Object.keys(rustSerializedWorkItem())) {
    const malformed = rustSerializedWorkItem();
    delete malformed[field];
    expectContractViolation(() => parseWorkItem(malformed));
  }
});

test('创建 DTO 数字字段类型/范围错误被拒绝', () => {
  for (const importance of ['3', 3.5, {}, [], true, 0, 6, -1]) {
    expectContractViolation(() =>
      parseWorkItem(rustSerializedWorkItem({ importance }))
    );
  }
  for (const urgency of ['5', 2.5, {}, 0, 6]) {
    expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ urgency })));
  }
});

test('创建 DTO 可空字段类型错误被拒绝', () => {
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ projectId: 123 })));
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ dueDate: 20261231 })));
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ dueDate: {} })));
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ description: [] })));
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ importance: 'null' })));
});

test('创建 DTO 非法 lifecycleStatus 被拒绝', () => {
  for (const status of ['in_progress', 'completed', 'abandoned', 'not_started', 'unknown']) {
    expectContractViolation(() =>
      parseWorkItem(rustSerializedWorkItem({ lifecycleStatus: status }))
    );
  }
});

test('创建 DTO 未知字段被严格拒绝（不静默忽略）', () => {
  expectContractViolation(() =>
    parseWorkItem(rustSerializedWorkItem({ unexpectedField: true }))
  );
  // 典型漂移：后端若返回 snake_case 旧字段，必须被拒绝。
  expectContractViolation(() =>
    parseWorkItem(rustSerializedWorkItem({ importance_score: 3 }))
  );
});

test('创建 DTO 必需字符串字段为空或类型错误被拒绝', () => {
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ id: '' })));
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ title: '   ' })));
  expectContractViolation(() => parseWorkItem(rustSerializedWorkItem({ createdAt: 0 })));
  expectContractViolation(() => parseWorkItem(null));
});

// ---------------------------------------------------------------------------
// 待安排列表 DTO（Rust PendingWorkItem，8 字段）
// ---------------------------------------------------------------------------

test('合法待安排列表 DTO 通过校验（未归属 + 已归档项目）', () => {
  const unassigned = rustSerializedPendingWorkItem();
  const linked = rustSerializedPendingWorkItem({
    id: '9d1c0f6a-5f5e-4a41-9f4b-0f2fc7d1a003',
    projectId: '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000',
    projectName: '虚构归档项目',
    projectIsArchived: true
  });
  const parsed = parsePendingWorkItemList([unassigned, linked]);
  assert.equal(parsed.length, 2);
  assert.equal(parsed[0].projectId, null);
  assert.equal(parsed[0].projectName, null);
  assert.equal(parsed[0].projectIsArchived, false);
  assert.equal(parsed[1].projectName, '虚构归档项目');
  assert.equal(parsed[1].projectIsArchived, true);
});

test('空列表通过校验，非数组返回值被拒绝', () => {
  assert.deepEqual(parsePendingWorkItemList([]), []);
  expectContractViolation(() => parsePendingWorkItemList({}));
  expectContractViolation(() => parsePendingWorkItemList(null));
});

test('待安排列表 DTO 缺少任一字段都被拒绝（8 字段逐一验证）', () => {
  for (const field of Object.keys(rustSerializedPendingWorkItem())) {
    const malformed = rustSerializedPendingWorkItem();
    delete malformed[field];
    expectContractViolation(() => parsePendingWorkItemList([malformed]));
  }
});

test('待安排列表 DTO 未知字段被严格拒绝', () => {
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ importance: 3 })])
  );
});

test('待安排列表 DTO 字段类型错误被拒绝', () => {
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ id: 42 })])
  );
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ title: '   ' })])
  );
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ projectIsArchived: 'false' })])
  );
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ projectName: 5 })])
  );
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ createdAt: 1700000000 })])
  );
});

test('待安排列表 DTO 非 pending 状态被拒绝', () => {
  for (const status of ['in_progress', 'completed', 'abandoned', 'not_started', 'unknown']) {
    expectContractViolation(() =>
      parsePendingWorkItemList([rustSerializedPendingWorkItem({ lifecycleStatus: status })])
    );
  }
});

test('待安排列表 DTO 项目字段语义不一致被拒绝', () => {
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ projectName: '虚构项目' })])
  );
  expectContractViolation(() =>
    parsePendingWorkItemList([
      rustSerializedPendingWorkItem({ projectId: '3f0b8f28-5d5a-4f73-9a52-3a8a0f0f0000' })
    ])
  );
  expectContractViolation(() =>
    parsePendingWorkItemList([rustSerializedPendingWorkItem({ projectIsArchived: true })])
  );
});

test('拒绝时错误信息包含字段路径且错误码稳定', () => {
  try {
    parseWorkItem(rustSerializedWorkItem({ importance: '3' }));
    assert.fail('必须抛出契约错误');
  } catch (error) {
    assert.ok(error instanceof WorkItemIpcError);
    assert.equal(error.code, 'ipc-contract-violation');
    assert.match(error.message, /工作事项\.importance/);
  }
});
