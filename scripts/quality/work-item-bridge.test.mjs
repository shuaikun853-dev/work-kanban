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
  parseCreatedWorkItemCopies,
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

// ---------------------------------------------------------------------------
// 多项目批量创建响应 DTO（Rust CreatedWorkItemCopies：groupId + workItems）
// ---------------------------------------------------------------------------

const PROJECT_A = '11111111-1111-4111-8111-111111111111';
const PROJECT_B = '22222222-2222-4222-8222-222222222222';
const PROJECT_C = '33333333-3333-4333-8333-333333333333';
const GROUP_ID = '44444444-4444-4444-8444-444444444444';

/** 与 Rust `CreatedWorkItemCopies` serde(camelCase) 输出一致的夹具。 */
function rustSerializedCreatedCopies(projectIds, overrides = {}) {
  const workItems = projectIds.map((projectId, index) =>
    rustSerializedWorkItem({
      id: `aaaaaaa${index}-aaaa-4aaa-8aaa-aaaaaaaaaaa${index}`,
      projectId,
      title: '中核商品价格异常排查'
    })
  );
  return { groupId: GROUP_ID, workItems, ...overrides };
}

test('合法批量创建响应（两项目）通过严格校验', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  const parsed = parseCreatedWorkItemCopies(raw, [PROJECT_A, PROJECT_B]);
  assert.equal(parsed.groupId, GROUP_ID);
  assert.equal(parsed.workItems.length, 2);
  assert.deepEqual(
    parsed.workItems.map((item) => item.projectId),
    [PROJECT_A, PROJECT_B]
  );
  assert.ok(parsed.workItems.every((item) => item.lifecycleStatus === 'pending'));
});

test('合法批量创建响应（三项目、乱序返回）通过严格校验', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_C, PROJECT_A, PROJECT_B]);
  const parsed = parseCreatedWorkItemCopies(raw, [PROJECT_A, PROJECT_B, PROJECT_C]);
  assert.equal(parsed.workItems.length, 3);
  assert.deepEqual(
    parsed.workItems.map((item) => item.projectId).sort(),
    [PROJECT_A, PROJECT_B, PROJECT_C]
  );
});

test('批量创建响应的 groupId 必须是规范 UUID', () => {
  for (const groupId of ['', '   ', 'not-a-uuid', 123, null, `${GROUP_ID}-extra`]) {
    expectContractViolation(() =>
      parseCreatedWorkItemCopies(
        rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { groupId }),
        [PROJECT_A, PROJECT_B]
      )
    );
  }
});

test('批量创建响应缺少/多出顶层字段被拒绝', () => {
  for (const field of ['groupId', 'workItems']) {
    const malformed = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    delete malformed[field];
    expectContractViolation(() =>
      parseCreatedWorkItemCopies(malformed, [PROJECT_A, PROJECT_B])
    );
  }
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { extra: true }),
      [PROJECT_A, PROJECT_B]
    )
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { work_items: [] }),
      [PROJECT_A, PROJECT_B]
    )
  );
});

test('批量创建响应 workItems 非数组或数量与请求项目数不一致被拒绝', () => {
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { workItems: null }),
      [PROJECT_A, PROJECT_B]
    )
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A]),
      [PROJECT_A, PROJECT_B]
    )
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]),
      [PROJECT_A, PROJECT_B, PROJECT_C]
    )
  );
});

test('批量创建响应的每个项目必须恰好一个副本', () => {
  // 同一项目出现两次（另一个项目缺失）。
  const duplicated = rustSerializedCreatedCopies([PROJECT_A, PROJECT_A]);
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(duplicated, [PROJECT_A, PROJECT_B])
  );
  // 每个工作副本内部 ID 重复。
  const duplicatedId = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  duplicatedId.workItems[1].id = duplicatedId.workItems[0].id;
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(duplicatedId, [PROJECT_A, PROJECT_B])
  );
  // 返回了请求之外的项目。
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_C]),
      [PROJECT_A, PROJECT_B]
    )
  );
  // 副本项目为 null。
  const unassigned = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  unassigned.workItems[1].projectId = null;
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(unassigned, [PROJECT_A, PROJECT_B])
  );
});

test('批量创建响应中任一副本非 pending 被拒绝', () => {
  for (const status of ['not_started', 'in_progress', 'completed', 'abandoned']) {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    raw.workItems[1].lifecycleStatus = status;
    expectContractViolation(() => parseCreatedWorkItemCopies(raw, [PROJECT_A, PROJECT_B]));
  }
});

test('批量创建响应中任一副本缺字段/多字段被拒绝', () => {
  const missing = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  delete missing.workItems[1].description;
  expectContractViolation(() => parseCreatedWorkItemCopies(missing, [PROJECT_A, PROJECT_B]));

  const extra = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  extra.workItems[0].unexpectedField = true;
  expectContractViolation(() => parseCreatedWorkItemCopies(extra, [PROJECT_A, PROJECT_B]));
});

test('调用方请求项目列表本身不合法时拒绝', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  expectContractViolation(() => parseCreatedWorkItemCopies(raw, [PROJECT_A]));
  expectContractViolation(() => parseCreatedWorkItemCopies(raw, []));
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(rustSerializedCreatedCopies([PROJECT_A, PROJECT_A]), [
      PROJECT_A,
      PROJECT_A
    ])
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(raw, [PROJECT_A, '   '])
  );
  expectContractViolation(() => parseCreatedWorkItemCopies(raw, undefined));
});

test('批量创建响应契约错误包含字段路径且错误码稳定', () => {
  try {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    raw.workItems[1].projectId = PROJECT_C;
    parseCreatedWorkItemCopies(raw, [PROJECT_A, PROJECT_B]);
    assert.fail('必须抛出契约错误');
  } catch (error) {
    assert.ok(error instanceof WorkItemIpcError);
    assert.equal(error.code, 'ipc-contract-violation');
    assert.match(error.message, /批量创建工作结果\.workItems\[1\]\.projectId/);
  }
});
