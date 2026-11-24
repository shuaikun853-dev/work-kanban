/**
 * WorkManager T1-04 重启持久化检查（Release UI）。
 *
 * 前提：
 * - 同一 UAT 便携目录已关闭并重新启动 Release；
 * - 主检查创建了 14 条待安排工作、5 个创建组、11 条成员关系；
 * - 故障注入阶段已证明整批回滚且无残留（t1-04-prerequisite.json）。
 *
 * 检查内容：
 * 1. 重启后 14 条工作副本仍存在（全部 pending），归档项目历史关联保留；
 * 2. 多项目选择器仍只展示未归档项目（A/B/C），不展示已归档项目 D；
 * 3. 重启后仍可批量创建：A+B → 2 条新副本，待安排列表变为 16 条；
 * 4. 截图与证据；真实关闭按钮退出由编排脚本验证；
 * 5. 数据库只读探针（编排脚本）验证 16 条工作 / 6 个创建组 / 13 条成员关系持久化。
 *
 * 用法：node scripts/verify/inspect-t1-04-persistence.mjs <port> <outputDir> <prerequisitePath>
 */

import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? '9358');
const outputDir = process.argv[3] ?? `D:\\WorkManager-test-data\\t1-04-ui-persist-${Date.now()}`;
const prerequisitePath = process.argv[4] ?? '';
fs.mkdirSync(outputDir, { recursive: true });

const ROWS_BEFORE = 14;
const ROWS_AFTER = 16;
const NEW_BATCH_TITLE = 'T1-04 虚构 重启后新批次工作';

const prerequisite = (() => {
  if (prerequisitePath && fs.existsSync(prerequisitePath)) {
    try {
      return JSON.parse(fs.readFileSync(prerequisitePath, 'utf8'));
    } catch {
      return {};
    }
  }
  return {};
})();

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function findPageTarget() {
  let lastError = null;
  for (let attempt = 0; attempt < 160; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`);
      if (response.ok) {
        const targets = await response.json();
        const page = targets.find(
          (target) => target.type === 'page' && typeof target.webSocketDebuggerUrl === 'string'
        );
        if (page) return page;
        lastError = `no page target yet: ${JSON.stringify(targets)}`;
      } else {
        lastError = `HTTP ${response.status}`;
      }
    } catch (error) {
      lastError = String(error);
    }
    await sleep(250);
  }
  throw new Error(`CDP page target not found on port ${port}. Last error: ${lastError}`);
}

const pageTarget = await findPageTarget();
const socket = new WebSocket(pageTarget.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, { once: true });
  socket.addEventListener('error', reject, { once: true });
});

let nextId = 1;
const pending = new Map();

socket.addEventListener('message', (event) => {
  let message;
  try {
    message = JSON.parse(event.data);
  } catch {
    return;
  }
  if (!message.id || !pending.has(message.id)) return;
  const handlers = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) handlers.reject(new Error(JSON.stringify(message.error)));
  else handlers.resolve(message.result);
});

function send(method, params = {}, timeoutMs = 20000) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`CDP timeout waiting for ${method}`));
    }, timeoutMs);
    pending.set(id, {
      resolve: (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timer);
        reject(error);
      }
    });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true,
    userGesture: true
  });
  if (result.exceptionDetails) {
    throw new Error(`Runtime.evaluate failed: ${JSON.stringify(result.exceptionDetails)}`);
  }
  return result.result.value;
}

const checks = [];
function check(name, pass, detail = '') {
  checks.push({ name, pass: Boolean(pass), detail });
  console.log(`${pass ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`);
}

async function waitFor(expression, timeoutMs = 12000, label = expression) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      if (await evaluate(expression)) return true;
    } catch {
      // ignore transient context loss
    }
    await sleep(120);
  }
  throw new Error(`Timed out waiting for: ${label}`);
}

async function screenshot(name) {
  const shot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
  const filePath = path.join(outputDir, name);
  fs.writeFileSync(filePath, Buffer.from(shot.data, 'base64'));
  return filePath;
}

function clickByText(containerSelector, label, exact = true) {
  return evaluate(`(() => {
    const scope = document.querySelector(${JSON.stringify(containerSelector)});
    if (!scope) return false;
    const wanted = ${JSON.stringify(label)};
    const button = Array.from(scope.querySelectorAll('button')).find((item) => {
      const text = (item.textContent || '').replace(/\\s+/g, ' ').trim();
      return ${exact ? 'text === wanted' : 'text.includes(wanted)'};
    });
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`);
}

async function directIpc(command, args) {
  const call =
    args === undefined
      ? `window.__TAURI_INTERNALS__.invoke(${JSON.stringify(command)})`
      : `window.__TAURI_INTERNALS__.invoke(${JSON.stringify(command)}, ${JSON.stringify(args)})`;
  return evaluate(`(async () => {
    try {
      const value = await ${call};
      return { ok: true, value };
    } catch (error) {
      return { ok: false, error: (() => {
        if (typeof error === 'string') return error;
        if (error instanceof Error) {
          return JSON.stringify({ name: error.name, message: error.message, code: error.code ?? null });
        }
        if (error && typeof error === 'object') {
          try { return JSON.stringify(error); } catch { return String(error); }
        }
        return String(error);
      })() };
    }
  })()`);
}

async function setDialogTitle(value) {
  return evaluate(`(() => {
    const input = document.querySelector('dialog[open] #work-item-title');
    if (!(input instanceof HTMLInputElement)) return false;
    input.value = ${JSON.stringify(value)};
    input.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
  })()`);
}

async function clickProjectCheckbox(projectId) {
  return evaluate(`(() => {
    const input = document.querySelector('dialog[open] input[data-project-id="${projectId}"]');
    if (!(input instanceof HTMLInputElement)) return false;
    if (!input.checked) input.click();
    return true;
  })()`);
}

async function dialogSnapshot() {
  return evaluate(`(() => {
    const dialog = document.querySelector('dialog[open]');
    if (dialog === null) return null;
    const selected = dialog.querySelector('[data-selected-project-count]');
    const expected = dialog.querySelector('[data-expected-copy-count]');
    return {
      mode: dialog.getAttribute('data-create-mode'),
      selectedCount: selected === null ? null : Number(selected.getAttribute('data-selected-project-count')),
      expectedCount: expected === null ? null : Number(expected.getAttribute('data-expected-copy-count')),
      availableProjectIds: Array.from(dialog.querySelectorAll('input[data-project-id]')).map(
        (input) => input.getAttribute('data-project-id')
      )
    };
  })()`);
}

async function waitForSelection(selectedCount, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await dialogSnapshot();
    if (last !== null && last.selectedCount === selectedCount) return last;
    await sleep(100);
  }
  throw new Error(`Timed out waiting for selection ${selectedCount}; last=${JSON.stringify(last)}`);
}

let closeClicked = false;

function buildEvidence(extra = {}) {
  const failed = checks.filter((item) => !item.pass).map((item) => item.name);
  const evidence = {
    generatedAt: new Date().toISOString(),
    task: 'T1-04',
    phase: 'restart-persistence',
    method:
      'Restart same UAT portable directory; verify persisted pending list + archived-project history; create a new batch after restart; real titlebar close button',
    port,
    outputDir,
    prerequisitePath,
    rowsBefore: ROWS_BEFORE,
    rowsAfter: ROWS_AFTER,
    newBatchTitle: NEW_BATCH_TITLE,
    checks,
    failed,
    checkCount: checks.length,
    closeClicked,
    pass: failed.length === 0 && closeClicked === true,
    ...extra
  };
  const evidencePath = path.join(outputDir, 't1-04-persistence-evidence.json');
  fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2), 'utf8');
  evidence.evidencePath = evidencePath;
  return evidence;
}

try {
  await waitFor(
    `document.readyState === 'complete' && document.querySelector('.app-shell') !== null`,
    15000,
    'app shell rendered after restart'
  );
  await waitFor(
    `(async () => {
      try {
        const health = await window.__TAURI_INTERNALS__.invoke('get_database_health');
        return health?.database?.schemaVersion === 4 && health?.database?.status === 'ok';
      } catch { return false; }
    })()`,
    20000,
    'IPC ready with schema 4 after restart'
  );

  check('persistence.navigateToday', (await clickByText('nav.sidebar', '今日工作', false)) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '今日工作'`, 5000);
  check('persistence.pendingEntryClicked', (await clickByText('.view-switcher', '待安排', true)) === true);
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === ${ROWS_BEFORE}`, 15000);
  await waitFor(
    `(() => {
      const text = (document.querySelector('main') || {}).innerText || '';
      return !text.includes('正在读取待安排工作') && !text.includes('正在同步待安排列表');
    })()`,
    15000,
    'pending view settled'
  );

  const persisted = await directIpc('list_pending_work_items');
  const persistedItems = persisted.ok === true ? persisted.value : [];
  check(
    'persistence.fourteenRowsPersistedAsPending',
    persistedItems.length === ROWS_BEFORE &&
      persistedItems.every((item) => item.lifecycleStatus === 'pending'),
    JSON.stringify(persistedItems.length)
  );
  const expectedTitles = [
    prerequisite?.titles?.batchTwo,
    prerequisite?.titles?.batchThree,
    prerequisite?.titles?.unassigned,
    prerequisite?.titles?.single,
    prerequisite?.titles?.duplicate,
    prerequisite?.titles?.doubleSubmit,
    prerequisite?.titles?.archivedLink,
    prerequisite?.titles?.refreshFailure
  ].filter((value) => typeof value === 'string' && value.length > 0);
  check(
    'persistence.expectedTitlesPersisted',
    expectedTitles.length === 8 &&
      expectedTitles.every((title) => persistedItems.some((item) => item.title === title)),
    JSON.stringify(expectedTitles)
  );
  const archivedLink = persistedItems.find(
    (item) => item.id === prerequisite?.archivedLinkItemId
  );
  check(
    'persistence.archivedProjectHistoryLinkPreserved',
    archivedLink !== undefined &&
      archivedLink !== null &&
      archivedLink.projectIsArchived === true &&
      typeof archivedLink.projectName === 'string' &&
      archivedLink.projectName.includes('将归档项目丁'),
    JSON.stringify(archivedLink)
  );

  // 多项目选择器：只展示未归档项目 A/B/C，不展示已归档项目 D。
  check('persistence.openCreateDialog', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-title') !== null`, 5000);
  await waitFor(
    `document.querySelectorAll('dialog[open] input[data-project-id]').length === 3`,
    8000,
    'unarchived project options loaded'
  );
  const dialog = await dialogSnapshot();
  const expectedAvailable = [prerequisite?.projects?.A?.id, prerequisite?.projects?.B?.id, prerequisite?.projects?.C?.id];
  check(
    'persistence.selectorOnlyUnarchivedProjects',
    expectedAvailable.every((id) => typeof id === 'string' && dialog.availableProjectIds.includes(id)) &&
      !dialog.availableProjectIds.includes(prerequisite?.projects?.D?.id),
    JSON.stringify(dialog.availableProjectIds)
  );
  check('persistence.titleFilled', (await setDialogTitle(NEW_BATCH_TITLE)) === true);
  check('persistence.selectProjectA', (await clickProjectCheckbox(prerequisite.projects.A.id)) === true);
  check('persistence.selectProjectB', (await clickProjectCheckbox(prerequisite.projects.B.id)) === true);
  const selection = await waitForSelection(2);
  check(
    'persistence.batchSelectionSummary',
    selection.mode === 'copies' && selection.expectedCount === 2,
    JSON.stringify(selection)
  );
  check('persistence.saveClicked', (await clickByText('dialog[open]', '保存', true)) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 15000, 'dialog closed');
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === ${ROWS_AFTER}`, 15000);
  await waitFor(
    `(() => {
      const element = document.querySelector('[data-create-outcome]');
      return element !== null && (element.innerText || '').includes('已从数据库更新');
    })()`,
    12000,
    'post-restart batch outcome success'
  );
  const outcome = await evaluate(`(() => {
    const element = document.querySelector('[data-create-outcome]');
    return element === null ? null : {
      kind: element.getAttribute('data-create-outcome'),
      text: (element.innerText || '').replace(/\\s+/g, ' ').trim()
    };
  })()`);
  check(
    'persistence.newBatchOutcomeActualCount',
    outcome !== null && outcome.kind === 'success' && outcome.text.includes('已创建 2 项'),
    JSON.stringify(outcome)
  );
  const afterRestartBatch = await directIpc('list_pending_work_items');
  const newCopies = afterRestartBatch.ok === true
    ? afterRestartBatch.value.filter((item) => item.title === NEW_BATCH_TITLE)
    : [];
  check(
    'persistence.newBatchPersistedAfterRestart',
    newCopies.length === 2 &&
      newCopies.every((item) => item.lifecycleStatus === 'pending') &&
      newCopies.map((item) => item.projectId).sort().join(',') ===
        [prerequisite.projects.A.id, prerequisite.projects.B.id].sort().join(','),
    JSON.stringify(newCopies)
  );
  await screenshot('pending-after-restart.png');

  closeClicked = await evaluate(`(() => {
    const button = document.querySelector('.window-control--close');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`).catch(() => false);
  check('persistence.closeButtonClicked', closeClicked === true);

  const evidence = buildEvidence();
  console.log(
    JSON.stringify(
      {
        total: evidence.checkCount,
        failed: evidence.failed,
        pass: evidence.pass,
        evidencePath: evidence.evidencePath
      },
      null,
      2
    )
  );
} catch (error) {
  check('persistence.scriptCompleted', false, String(error));
  await screenshot('persistence-failure.png').catch(() => null);
  try {
    const evidence = buildEvidence({ scriptError: String(error) });
    console.error(`PERSISTENCE_EVIDENCE=${evidence.evidencePath}`);
  } catch {
    // 证据写盘失败不应掩盖原始错误。
  }
}

await sleep(500);
socket.close();
process.exit(checks.some((item) => !item.pass) || !closeClicked ? 1 : 0);
