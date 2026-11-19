/**
 * WorkManager T1-03 关闭 → 重启持久化检查。
 *
 * 前提：
 * - 同一 UAT 便携目录已由主检查创建 4 条虚构待安排工作与 2 个已归档项目；
 * - 应用已通过真实关闭按钮退出；
 * - 编排脚本使用同一 EXE/工作目录重新启动 Release 进程。
 *
 * 检查内容：
 * 1. 重启后待安排列表仍从 SQLite 读取到 4 条记录（标题/项目关联/归档标识正确）；
 * 2. 未归属工作显示“未归属项目”；关联归档项目的历史工作显示项目名称与“项目已归档”；
 * 3. 重启后项目选择器仍只展示未归档项目（本例全部项目已归档，只剩“未归属项目”）；
 * 4. 重启后仍可真实创建新的未归属工作，并立即出现在待安排列表；
 * 5. 点击红色关闭按钮结束进程（由编排脚本验证退出码）。
 *
 * 用法：node scripts/verify/inspect-t1-03-persistence.mjs <port> <outputDir> <prerequisiteJson>
 */

import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? '9346');
const outputDir = process.argv[3] ?? `D:\\WorkManager-test-data\\t1-03-ui-${Date.now()}`;
const prerequisitePath = process.argv[4] ?? path.join(outputDir, 't1-03-prerequisite.json');
fs.mkdirSync(outputDir, { recursive: true });

const prerequisite = JSON.parse(fs.readFileSync(prerequisitePath, 'utf8'));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function findPageTarget() {
  let lastError = null;
  for (let attempt = 0; attempt < 200; attempt += 1) {
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
const pageErrors = [];

socket.addEventListener('message', (event) => {
  let message;
  try {
    message = JSON.parse(event.data);
  } catch {
    return;
  }
  if (message.method === 'Runtime.exceptionThrown') {
    pageErrors.push({ type: 'exception', detail: message.params?.exceptionDetails });
    return;
  }
  if (message.method === 'Log.entryAdded' && message.params?.entry?.level === 'error') {
    pageErrors.push({ type: 'console', detail: message.params.entry });
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

async function waitFor(expression, timeoutMs = 15000, label = expression) {
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

async function dialogProjectOptions() {
  return evaluate(`(() => {
    const select = document.querySelector('dialog[open] #work-item-project');
    if (!(select instanceof HTMLSelectElement)) return null;
    return Array.from(select.options).map((option) => ({
      value: option.value,
      label: (option.textContent || '').trim()
    }));
  })()`);
}

async function rowSnapshots() {
  return evaluate(`(() => Array.from(document.querySelectorAll('[data-work-item-id]')).map((row) => ({
    id: row.getAttribute('data-work-item-id'),
    title: ((row.querySelector('.work-item-title') || {}).textContent || '').trim(),
    meta: ((row.querySelector('.work-item-meta') || {}).innerText || '').replace(/\\s+/g, ' ').trim(),
    hasArchivedBadge: row.innerText.includes('项目已归档')
  })))()`);
}

await send('Runtime.enable');
await send('Page.enable');
await send('Log.enable');

let closeClicked = false;
let rowsAfterRestart = [];

try {
  await waitFor(
    `document.readyState === 'complete' && document.querySelector('.app-shell') !== null && document.querySelectorAll('nav.sidebar button').length === 6`,
    30000,
    'restarted app shell rendered'
  );

  const health = await directIpc('get_database_health');
  check(
    'restart.databaseSchemaStillV3',
    health.ok === true && health.value?.database?.schemaVersion === 3,
    JSON.stringify(health.value?.database?.schemaVersion)
  );

  check('restart.navigateToday', (await clickByText('nav.sidebar', '今日工作', false)) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '今日工作'`, 8000);
  check('restart.pendingEntryVisible', (await clickByText('.view-switcher', '待安排', true)) === true);
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === 4`, 20000);
  rowsAfterRestart = await rowSnapshots();
  check(
    'restart.fourPendingWorkItemsPersisted',
    rowsAfterRestart.length === 4,
    JSON.stringify(rowsAfterRestart.map((row) => row.title))
  );

  const expectedTitles = [
    '整理中核商品数据',
    '重复提交保护验证',
    '关联未归档项目的待安排工作'
  ];
  check(
    'restart.expectedTitlesStillPresent',
    expectedTitles.every((title) => rowsAfterRestart.some((row) => row.title === title)) &&
      rowsAfterRestart.some((row) => row.title.startsWith('超长工作标题用于验证待安排列表')),
    JSON.stringify(rowsAfterRestart.map((row) => row.title))
  );

  const linkedRow = rowsAfterRestart.find(
    (row) => row.title === '关联未归档项目的待安排工作'
  );
  check(
    'restart.archivedProjectLinkPreserved',
    linkedRow !== undefined &&
      linkedRow.meta.includes('T1-03 虚构未归档项目') &&
      linkedRow.hasArchivedBadge === true,
    JSON.stringify(linkedRow)
  );
  check(
    'restart.unassignedLabelPersisted',
    rowsAfterRestart
      .filter((row) => row.title !== '关联未归档项目的待安排工作')
      .every((row) => row.meta.includes('未归属项目')),
    JSON.stringify(rowsAfterRestart.map((row) => row.meta))
  );

  const ipcList = await directIpc('list_pending_work_items');
  check(
    'restart.ipcPendingListPersisted',
    ipcList.ok === true &&
      ipcList.value.length === 4 &&
      ipcList.value.every((item) => item.lifecycleStatus === 'pending'),
    JSON.stringify(ipcList.value?.length)
  );
  const linkedFromIpc = ipcList.value.find(
    (item) => item.title === '关联未归档项目的待安排工作'
  );
  check(
    'restart.ipcArchivedLinkFlags',
    linkedFromIpc !== undefined &&
      linkedFromIpc.projectIsArchived === true &&
      linkedFromIpc.projectName === 'T1-03 虚构未归档项目',
    JSON.stringify(linkedFromIpc)
  );
  await screenshot('pending-after-restart.png');

  // 重启后选择器仍然只展示未归档项目（2 个项目已全部归档，因此只有“未归属项目”）。
  check('restart.openCreateDialog', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-project') !== null`, 8000);
  await waitFor(
    `document.querySelectorAll('dialog[open] #work-item-project option').length === 1`,
    10000,
    'restarted selector only unassigned option'
  );
  const optionsAfterRestart = await dialogProjectOptions();
  check(
    'restart.selectorExcludesArchivedProjects',
    Array.isArray(optionsAfterRestart) &&
      optionsAfterRestart.length === 1 &&
      optionsAfterRestart[0].value === '' &&
      optionsAfterRestart[0].label === '未归属项目',
    JSON.stringify(optionsAfterRestart)
  );
  await screenshot('create-dialog-after-restart.png');

  // 重启后仍可真实创建新的未归属工作。
  check('restart.newTitleFilled', (await setDialogTitle('重启后新建的工作')) === true);
  check('restart.newWorkSaved', (await clickByText('dialog[open]', '保存', true)) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000, 'create dialog closed');
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === 5`, 15000);
  const createdAfterRestart = await directIpc('list_pending_work_items');
  check(
    'restart.newWorkItemPersistedToDatabase',
    createdAfterRestart.ok === true &&
      createdAfterRestart.value.length === 5 &&
      createdAfterRestart.value.some(
        (item) => item.title === '重启后新建的工作' && item.projectId === null
      ),
    JSON.stringify(createdAfterRestart.value?.length)
  );
  const finalRows = await rowSnapshots();
  const newRow = finalRows.find((row) => row.title === '重启后新建的工作');
  check(
    'restart.newWorkItemVisibleWithUnassignedLabel',
    newRow !== undefined && newRow.meta.includes('未归属项目'),
    JSON.stringify(newRow)
  );
  await screenshot('pending-after-restart-new-item.png');
  check('restart.noUncaughtErrors', pageErrors.length === 0, JSON.stringify(pageErrors).slice(0, 400));

  // 点击真实关闭按钮结束进程；退出码由编排脚本验证。
  closeClicked = await evaluate(`(() => {
    const button = document.querySelector('.window-control--close');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`).catch(() => false);
  check('restart.closeButtonClicked', closeClicked === true);
} catch (error) {
  check('restart.scriptCompleted', false, String(error));
  await screenshot('restart-failure.png').catch(() => null);
}

const failed = checks.filter((item) => !item.pass).map((item) => item.name);
const evidence = {
  generatedAt: new Date().toISOString(),
  task: 'T1-03',
  method:
    'Relaunched real Release EXE against the same isolated UAT portable directory; DOM + direct typed IPC verification of persisted pending work items, archived project link flags, unarchived-only selector, post-restart create, then real titlebar close',
  port,
  prerequisite: prerequisitePath,
  rowsAfterRestart,
  pageErrors,
  checks,
  failed,
  closeClicked,
  pass: failed.length === 0 && closeClicked === true
};
const evidencePath = path.join(outputDir, 't1-03-persistence-evidence.json');
fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2), 'utf8');
console.log(
  JSON.stringify(
    { evidencePath, total: checks.length, failed, pass: evidence.pass },
    null,
    2
  )
);

await sleep(500);
socket.close();
if (!evidence.pass) {
  console.error(`PERSISTENCE_ASSERTION_FAILED: ${failed.join(', ')}`);
  process.exit(1);
}
console.log('T1_03_RELEASE_PERSISTENCE_CHECK=PASS');
