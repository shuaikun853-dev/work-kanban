/**
 * T1-03 / T1-04 工作事项 Bridge 运行时契约测试。
 *
 * 直接加载 src/lib/bridge/workItemValidation.ts（纯 TypeScript，无 Tauri/DOM 依赖），
 * 验证 Bridge 对成功返回值的严格运行时校验：
 * - Rust `WorkItem` 实际序列化 10 字段（含可空 importance/urgency/dueDate/description）；
 * - Rust `PendingWorkItem` 实际序列化 8 字段；
 * - 批量创建必须传入完整请求上下文：请求 requestId 必须是规范小写连字符 UUID，
 *   响应 groupId 必须与之逐字相等（Rust 直接复用请求标识作为创建组主键）；
 * - 请求 title 去除首尾 Unicode White_Space 后必须非空，响应每个副本 title 必须等于
 *   同一规范化结果（不改变大小写、不折叠内部空白、不删除 U+FEFF）；
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
import {
  WORK_ITEM_TITLE_WHITESPACE_CODEPOINTS,
  normalizeWorkItemTitle
} from '../../src/lib/contracts/workItemTitle.ts';

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
//
// 真实后端语义（crates/workmanager-core/src/work_items/service.rs）：
// - 客户端 requestId 必须是规范小写连字符 UUID，Rust 解析后直接复用为创建组主键，
//   因此响应 groupId 必须与请求 requestId 逐字相等，而不是“任意合法 UUID”即可；
// - normalize_title 只删除首尾 Unicode White_Space，因此响应 title 必须等于同一
//   规范化结果；大小写、内部空白与 U+FEFF 都不允许变化。
// ---------------------------------------------------------------------------

const PROJECT_A = '11111111-1111-4111-8111-111111111111';
const PROJECT_B = '22222222-2222-4222-8222-222222222222';
const PROJECT_C = '33333333-3333-4333-8333-333333333333';

/**
 * 调用方为一次逻辑创建操作生成的规范小写 UUID（Rust 直接用作创建组主键）。
 * 含十六进制字母，便于证明大写形式会被拒绝。
 */
const REQUEST_ID = '5f2a7c1e-9b3d-4e5f-8a6b-1c2d3e4f5a6b';

/** 另一个语法合法但与 requestId 不同的 UUID：证明 groupId 必须精确相等。 */
const GROUP_ID = '44444444-4444-4444-8444-444444444444';

/**
 * 请求标题：包含拉丁字母与中间空格，便于验证大小写和内部空白不会被静默折叠。
 * Rust `normalize_title` 只删除首尾 Unicode White_Space，响应必须等于该规范化结果。
 */
const REQUEST_TITLE = 'Review 中核商品价格异常排查';

/** 构造批量创建请求上下文（对应 Bridge `createWorkItemCopies(requestId, title, projectIds)`）。 */
function createdCopiesRequest(overrides = {}) {
  return {
    requestId: REQUEST_ID,
    title: REQUEST_TITLE,
    projectIds: [PROJECT_A, PROJECT_B],
    ...overrides
  };
}

/** 与 Rust `CreatedWorkItemCopies` serde(camelCase) 输出一致的合法夹具（groupId = requestId）。 */
function rustSerializedCreatedCopies(projectIds, overrides = {}) {
  const workItems = projectIds.map((projectId, index) =>
    rustSerializedWorkItem({
      id: `aaaaaaa${index}-aaaa-4aaa-8aaa-aaaaaaaaaaa${index}`,
      projectId,
      title: REQUEST_TITLE
    })
  );
  return { groupId: REQUEST_ID, workItems, ...overrides };
}

/** 断言抛出 `ipc-contract-violation`，且中文错误消息包含全部指定字段路径/关键字。 */
function expectContractViolationWithPath(action, ...pathPatterns) {
  assert.throws(action, (error) => {
    assert.ok(error instanceof WorkItemIpcError, '必须抛出 WorkItemIpcError');
    assert.equal(error.code, CONTRACT_VIOLATION_CODE);
    assert.match(error.message, /不符合契约/);
    assert.match(error.message, /[\u4e00-\u9fa5]/, '错误消息必须包含中文');
    for (const pattern of pathPatterns) {
      assert.match(error.message, pattern);
    }
    return true;
  });
}

test('合法批量创建响应（两项目）通过严格校验', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  const parsed = parseCreatedWorkItemCopies(raw, createdCopiesRequest());
  assert.equal(parsed.groupId, REQUEST_ID);
  assert.equal(parsed.workItems.length, 2);
  assert.deepEqual(
    parsed.workItems.map((item) => item.projectId),
    [PROJECT_A, PROJECT_B]
  );
  assert.ok(parsed.workItems.every((item) => item.lifecycleStatus === 'pending'));
});

test('合法批量创建响应（三项目、乱序返回）通过严格校验', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_C, PROJECT_A, PROJECT_B]);
  const parsed = parseCreatedWorkItemCopies(
    raw,
    createdCopiesRequest({ projectIds: [PROJECT_A, PROJECT_B, PROJECT_C] })
  );
  assert.equal(parsed.workItems.length, 3);
  assert.deepEqual(
    parsed.workItems.map((item) => item.projectId).sort(),
    [PROJECT_A, PROJECT_B, PROJECT_C]
  );
});

test('请求上下文完整一致（requestId 用作 groupId、title 已规范化）时通过校验', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  const parsed = parseCreatedWorkItemCopies(
    raw,
    createdCopiesRequest({ requestId: REQUEST_ID, title: REQUEST_TITLE })
  );
  assert.equal(parsed.groupId, REQUEST_ID);
  assert.ok(parsed.workItems.every((item) => item.title === REQUEST_TITLE));
});

test('批量创建响应的 groupId 必须是规范 UUID', () => {
  for (const groupId of ['', '   ', 'not-a-uuid', 123, null, `${GROUP_ID}-extra`]) {
    expectContractViolation(() =>
      parseCreatedWorkItemCopies(
        rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { groupId }),
        createdCopiesRequest()
      )
    );
  }
});

test('批量创建响应 groupId 与请求 requestId 不一致时被拒绝（即使语法合法的不同 UUID）', () => {
  // Rust 直接复用 requestId 作为创建组主键：任何“合法但不同”的 UUID 都必须拒绝。
  for (const groupId of [GROUP_ID, '66666666-6666-4666-8666-666666666666']) {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { groupId });
    expectContractViolationWithPath(
      () => parseCreatedWorkItemCopies(raw, createdCopiesRequest()),
      /批量创建工作结果\.groupId/,
      /requestId/
    );
  }
});

test('请求 requestId 不是规范小写连字符 UUID 时被拒绝', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  for (const requestId of [
    REQUEST_ID.toUpperCase(), // 大写 UUID：Rust 规范字符串比较不通过
    REQUEST_ID.replaceAll('-', ''), // 无连字符：可被解析但非规范形式
    `{${REQUEST_ID}}`, // 花括号包裹：可被解析但非规范形式
    `urn:uuid:${REQUEST_ID}`, // URN 形式：可被解析但非规范形式
    'not-a-uuid',
    '',
    '   ',
    null,
    123
  ]) {
    expectContractViolationWithPath(
      () => parseCreatedWorkItemCopies(raw, createdCopiesRequest({ requestId })),
      /请求 requestId/
    );
  }
});

test('批量创建响应缺少/多出顶层字段被拒绝', () => {
  for (const field of ['groupId', 'workItems']) {
    const malformed = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    delete malformed[field];
    expectContractViolation(() =>
      parseCreatedWorkItemCopies(malformed, createdCopiesRequest())
    );
  }
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { extra: true }),
      createdCopiesRequest()
    )
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { work_items: [] }),
      createdCopiesRequest()
    )
  );
});

test('批量创建响应 workItems 非数组或数量与请求项目数不一致被拒绝', () => {
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B], { workItems: null }),
      createdCopiesRequest()
    )
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A]),
      createdCopiesRequest()
    )
  );
  // 请求 3 个项目但只返回 2 个副本：不得静默接受部分成功。
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]),
      createdCopiesRequest({ projectIds: [PROJECT_A, PROJECT_B, PROJECT_C] })
    )
  );
});

test('批量创建响应的每个项目必须恰好一个副本', () => {
  // 同一项目出现两次（另一个项目缺失）。
  const duplicated = rustSerializedCreatedCopies([PROJECT_A, PROJECT_A]);
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(duplicated, createdCopiesRequest())
  );
  // 每个工作副本内部 ID 重复。
  const duplicatedId = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  duplicatedId.workItems[1].id = duplicatedId.workItems[0].id;
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(duplicatedId, createdCopiesRequest())
  );
  // 返回了请求之外的项目。
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_C]),
      createdCopiesRequest()
    )
  );
  // 副本项目为 null。
  const unassigned = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  unassigned.workItems[1].projectId = null;
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(unassigned, createdCopiesRequest())
  );
});

test('批量创建响应中任一副本非 pending 被拒绝', () => {
  for (const status of ['not_started', 'in_progress', 'completed', 'abandoned']) {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    raw.workItems[1].lifecycleStatus = status;
    expectContractViolation(() => parseCreatedWorkItemCopies(raw, createdCopiesRequest()));
  }
});

test('批量创建响应中任一副本缺字段/多字段被拒绝', () => {
  const missing = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  delete missing.workItems[1].description;
  expectContractViolation(() => parseCreatedWorkItemCopies(missing, createdCopiesRequest()));

  const extra = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  extra.workItems[0].unexpectedField = true;
  expectContractViolation(() => parseCreatedWorkItemCopies(extra, createdCopiesRequest()));
});

test('调用方请求项目列表本身不合法时拒绝', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(raw, createdCopiesRequest({ projectIds: [PROJECT_A] }))
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(raw, createdCopiesRequest({ projectIds: [] }))
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(
      rustSerializedCreatedCopies([PROJECT_A, PROJECT_A]),
      createdCopiesRequest({ projectIds: [PROJECT_A, PROJECT_A] })
    )
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(raw, createdCopiesRequest({ projectIds: [PROJECT_A, '   '] }))
  );
  expectContractViolation(() =>
    parseCreatedWorkItemCopies(raw, createdCopiesRequest({ projectIds: undefined }))
  );
});

test('请求上下文不是对象或缺少上下文时被拒绝', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  for (const request of [null, undefined, 'request', 42, true]) {
    expectContractViolationWithPath(
      () => parseCreatedWorkItemCopies(raw, request),
      /请求/
    );
  }
  // 旧式调用（直接传项目 ID 数组）必须被拒绝，不能静默视为 requestId 缺失后继续。
  expectContractViolationWithPath(
    () => parseCreatedWorkItemCopies(raw, [PROJECT_A, PROJECT_B]),
    /请求 requestId/
  );
});

test('请求 title 类型错误或去除首尾空白后为空时被拒绝', () => {
  const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  for (const title of ['', '   ', '\t\n', null, 123, undefined, {}]) {
    expectContractViolationWithPath(
      () => parseCreatedWorkItemCopies(raw, createdCopiesRequest({ title })),
      /请求 title/
    );
  }
});

test('请求 title 带首尾空白时，响应 title 等于 Unicode White_Space 规范化结果即可通过校验', () => {
  for (const title of [
    `  ${REQUEST_TITLE}  `,
    `\t${REQUEST_TITLE}\n`,
    `\u3000${REQUEST_TITLE}\u3000`
  ]) {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    const parsed = parseCreatedWorkItemCopies(raw, createdCopiesRequest({ title }));
    assert.ok(parsed.workItems.every((item) => item.title === REQUEST_TITLE));
  }
});

test('批量创建响应工作副本 title 必须等于请求 title 的规范化结果（大小写/内部空白不得变化）', () => {
  for (const title of [
    'review 中核商品价格异常排查', // 大小写不同
    'Review  中核商品价格异常排查', // 内部双空格
    `${REQUEST_TITLE}（错误附加）`
  ]) {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    raw.workItems[1].title = title;
    expectContractViolationWithPath(
      () => parseCreatedWorkItemCopies(raw, createdCopiesRequest()),
      /批量创建工作结果\.workItems\[1\]\.title/,
      /请求 title/
    );
  }

  const firstWrong = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
  firstWrong.workItems[0].title = 'review 中核商品价格异常排查';
  expectContractViolationWithPath(
    () => parseCreatedWorkItemCopies(firstWrong, createdCopiesRequest()),
    /批量创建工作结果\.workItems\[0\]\.title/
  );
});

test('请求 title 与响应 title 仅大小写或内部空白不同时被拒绝', () => {
  for (const title of [
    'review 中核商品价格异常排查', // 大小写不同
    'Review  中核商品价格异常排查', // 内部双空格
    `${REQUEST_TITLE}（旧）`
  ]) {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    expectContractViolationWithPath(
      () => parseCreatedWorkItemCopies(raw, createdCopiesRequest({ title })),
      /批量创建工作结果\.workItems\[0\]\.title/,
      /请求 title/
    );
  }
});

test('批量创建响应契约错误包含字段路径且错误码稳定', () => {
  try {
    const raw = rustSerializedCreatedCopies([PROJECT_A, PROJECT_B]);
    raw.workItems[1].projectId = PROJECT_C;
    parseCreatedWorkItemCopies(raw, createdCopiesRequest());
    assert.fail('必须抛出契约错误');
  } catch (error) {
    assert.ok(error instanceof WorkItemIpcError);
    assert.equal(error.code, 'ipc-contract-violation');
    assert.match(error.message, /批量创建工作结果\.workItems\[1\]\.projectId/);
  }
});

// ---------------------------------------------------------------------------
// R6-01：Unicode White_Space 标题规范化契约
//
// Rust `normalize_title` 与 TypeScript Bridge 必须使用同一字符集合，只删除首尾
// Unicode White_Space，保留 U+FEFF，不改变大小写或内部空白。JS `String.trim()`
// 对 U+0085（不删除）与 U+FEFF（删除）的行为不同，不能作为契约依据。
// ---------------------------------------------------------------------------

/** 构造“Rust 已规范化并返回”的批量响应；响应标题按服务端结果填写。 */
function rustSerializedCreatedCopiesWithTitle(responseTitle) {
  return {
    groupId: REQUEST_ID,
    workItems: [PROJECT_A, PROJECT_B].map((projectId, index) =>
      rustSerializedWorkItem({
        id: `bbbbbbb${index}-bbbb-4bbb-8bbb-bbbbbbbbbbb${index}`,
        projectId,
        title: responseTitle
      })
    )
  };
}

test('R6-01 权威 Unicode White_Space 字符集合为 25 个字符且不含 U+FEFF', () => {
  assert.deepEqual(WORK_ITEM_TITLE_WHITESPACE_CODEPOINTS, [
    0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x0020, 0x0085, 0x00a0, 0x1680, 0x2000, 0x2001,
    0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029,
    0x202f, 0x205f, 0x3000
  ]);
  assert.equal(WORK_ITEM_TITLE_WHITESPACE_CODEPOINTS.includes(0xfeff), false);
});

test('R6-01 每个 Unicode White_Space 字符均在两端被删除', () => {
  for (const codePoint of WORK_ITEM_TITLE_WHITESPACE_CODEPOINTS) {
    const whitespace = String.fromCodePoint(codePoint);
    assert.equal(
      normalizeWorkItemTitle(`${whitespace}标题${whitespace}`),
      '标题',
      `U+${codePoint.toString(16).toUpperCase().padStart(4, '0')} 必须从两端删除`
    );
    assert.equal(
      normalizeWorkItemTitle(whitespace),
      '',
      `U+${codePoint.toString(16).toUpperCase().padStart(4, '0')} 单独成标题时必须为空`
    );
  }
});

const UNICODE_TITLE_CASES = [
  {
    name: 'U+0085 首尾空白',
    requestTitle: '\u0085Review 中核商品价格异常排查\u0085',
    normalizedTitle: 'Review 中核商品价格异常排查'
  },
  {
    name: 'U+FEFF 首尾字符保留',
    requestTitle: '\uFEFFReview 中核商品价格异常排查\uFEFF',
    normalizedTitle: '\uFEFFReview 中核商品价格异常排查\uFEFF'
  },
  {
    name: 'U+3000 首尾空白',
    requestTitle: '\u3000Review 中核商品价格异常排查\u3000',
    normalizedTitle: 'Review 中核商品价格异常排查'
  },
  {
    name: 'TAB 首尾空白',
    requestTitle: '\tReview 中核商品价格异常排查\t',
    normalizedTitle: 'Review 中核商品价格异常排查'
  },
  {
    name: 'CR/LF 首尾空白',
    requestTitle: '\r\nReview 中核商品价格异常排查\n\r',
    normalizedTitle: 'Review 中核商品价格异常排查'
  },
  {
    name: '普通 ASCII 空格首尾空白',
    requestTitle: '  Review 中核商品价格异常排查  ',
    normalizedTitle: 'Review 中核商品价格异常排查'
  },
  {
    name: '内部多个空格原样保留',
    requestTitle: 'Review  中核  商品价格异常排查',
    normalizedTitle: 'Review  中核  商品价格异常排查'
  },
  {
    name: '内部 TAB 原样保留',
    requestTitle: 'Review\t中核\t商品价格异常排查',
    normalizedTitle: 'Review\t中核\t商品价格异常排查'
  },
  {
    name: '混合 Unicode 空白两端完全一致',
    requestTitle: '\t\u0085\u3000Review 中核商品价格异常排查\u3000\u0085\n',
    normalizedTitle: 'Review 中核商品价格异常排查'
  }
];

for (const titleCase of UNICODE_TITLE_CASES) {
  test(`R6-01 标题规范化：${titleCase.name}`, () => {
    const parsed = parseCreatedWorkItemCopies(
      rustSerializedCreatedCopiesWithTitle(titleCase.normalizedTitle),
      createdCopiesRequest({ title: titleCase.requestTitle })
    );
    assert.ok(
      parsed.workItems.every((item) => item.title === titleCase.normalizedTitle),
      `Rust 返回标题与 TypeScript 规范化结果必须完全一致：${JSON.stringify(titleCase.normalizedTitle)}`
    );
  });
}

test('R6-01 U+FEFF 单独作为标题时两端一致保留（不得按 JS trim 判空）', () => {
  const title = '\uFEFF';
  const parsed = parseCreatedWorkItemCopies(
    rustSerializedCreatedCopiesWithTitle(title),
    createdCopiesRequest({ title })
  );
  assert.ok(parsed.workItems.every((item) => item.title === title));
});

test('R6-01 混合空白规范化不改变大小写，也不做 Unicode NFC/NFKC 转换', () => {
  const requestTitle = '\u3000e\u0301 与 中核\u3000';
  const normalizedTitle = 'e\u0301 与 中核';
  const parsed = parseCreatedWorkItemCopies(
    rustSerializedCreatedCopiesWithTitle(normalizedTitle),
    createdCopiesRequest({ title: requestTitle })
  );
  assert.ok(parsed.workItems.every((item) => item.title === normalizedTitle));
});
