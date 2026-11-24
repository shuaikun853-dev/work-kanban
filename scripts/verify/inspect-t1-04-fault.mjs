/**
 * WorkManager T1-04 失败原子回滚证据（Release UI，真实 SQLite trigger 故障注入）。
 *
 * 前提：
 * - Release 进程已启动在同一 UAT 便携目录；
 * - 编排脚本已在**应用关闭时**向 UAT 数据库安装真实 SQLite TRIGGER：
 *   项目 C 的工作事项插入会真实 ABORT（模拟第二条工作副本写入失败）；
 * - 主检查阶段已创建 12 条待安排工作、4 个创建组（见 t1-04-prerequisite.json）。
 *
 * 检查内容：
 * 1. 待安排列表仍为 12 条；
 * 2. 通过真实 UI 选择两个项目（A + C）提交批量创建；
 * 3. 第二条工作副本真实插入失败 → Rust Core 整批回滚，UI 显示数据库错误；
 * 4. 失败后待安排列表仍为 12 条（无部分成功）；
 * 5. 通过真实关闭按钮退出；数据库只读探针由编排脚本验证无创建组/成员/副本残留。
 *
 * 用法：node scripts/verify/inspect-t1-04-fault.mjs <port> <outputDir> <prerequisitePath>
 */

import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? '9357');
const outputDir = process.argv[3] ?? `D:\\WorkManager-test-data\\t1-04-ui-fault-${Date.now()}`;
const prerequisitePath = process.argv[4] ?? '';
fs.mkdirSync(outputDir, { recursive: true });

const EXPECTED_ROWS = 12;
const FAULT_TITLE = 'T1-04 虚构 原子回滚验证批次';

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
    return {
      mode: dialog.getAttribute('data-create-mode'),
      selectedCount: selected === null ? null : Number(selected.getAttribute('data-selected-project-count')),
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
    phase: 'atomic-rollback-fault-injection',
    method:
      'Real Release UI + real SQLite TRIGGER in isolated UAT database: second work-item insert aborts; verification that whole batch rolls back and no partial rows remain',
    port,
    outputDir,
    prerequisitePath,
    faultTitle: FAULT_TITLE,
    checks,
    failed,
    checkCount: checks.length,
    closeClicked,
    pass: failed.length === 0 && closeClicked === true,
    ...extra
  };
  const evidencePath = path.join(outputDir, 't1-04-fault-evidence.json');
  fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2), 'utf8');
  evidence.evidencePath = evidencePath;
  return evidence;
}

try {
  await waitFor(
    `document.readyState === 'complete' && document.querySelector('.app-shell') !== null`,
    15000,
    'app shell rendered'
  );
  // 等待 IPC 就绪（schema 4）。
  await waitFor(
    `(async () => {
      try {
        const health = await window.__TAURI_INTERNALS__.invoke('get_database_health');
        return health?.database?.schemaVersion === 4 && health?.database?.status === 'ok';
      } catch { return false; }
    })()`,
    20000,
    'IPC ready with schema 4'
  );

  check('fault.navigateToday', (await clickByText('nav.sidebar', '今日工作', false)) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '今日工作'`, 5000);
  check('fault.pendingEntryClicked', (await clickByText('.view-switcher', '待安排', true)) === true);
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === ${EXPECTED_ROWS}`, 15000);
  await waitFor(
    `(() => {
      const text = (document.querySelector('main') || {}).innerText || '';
      return !text.includes('正在读取待安排工作') && !text.includes('正在同步待安排列表');
    })()`,
    15000,
    'pending view settled'
  );

  const projectA = prerequisite?.projects?.A;
  const projectC = prerequisite?.projects?.C;
  check(
    'fault.prerequisiteProjectsPresent',
    projectA !== undefined && projectC !== undefined && Boolean(prerequisitePath),
    JSON.stringify({ projectA: projectA?.id ?? null, projectC: projectC?.id ?? null })
  );

  check('fault.openCreateDialog', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-title') !== null`, 5000);
  await waitFor(
    `document.querySelectorAll('dialog[open] input[data-project-id]').length === 3`,
    8000,
    'project options loaded'
  );
  check('fault.titleFilled', (await setDialogTitle(FAULT_TITLE)) === true);
  check('fault.selectProjectA', (await clickProjectCheckbox(projectA.id)) === true);
  check('fault.selectProjectC', (await clickProjectCheckbox(projectC.id)) === true);
  await waitForSelection(2);

  check(
    'fault.saveDispatched',
    (await clickByText('dialog[open]', '保存', true)) === true
  );
  await waitFor(
    `document.querySelector('dialog[open] .dialog-error') !== null`,
    20000,
    'database error shown after injected second-copy failure'
  );
  const faultError = await evaluate(`(() => {
    const error = document.querySelector('dialog[open] .dialog-error');
    const code = document.querySelector('dialog[open] .dialog-error-code');
    const title = document.querySelector('dialog[open] #work-item-title');
    return {
      message: (error.innerText || '').replace(/\\s+/g, ' ').trim(),
      code: code ? (code.textContent || '').replace(/\\s+/g, ' ').trim() : null,
      dialogStillOpen: document.querySelector('dialog[open]') !== null,
      titlePreserved: title ? title.value === ${JSON.stringify(FAULT_TITLE)} : false
    };
  })()`);
  check(
    'fault.databaseErrorShownAndDialogKept',
    faultError.dialogStillOpen === true &&
      (faultError.code ?? '').includes('database-') &&
      faultError.titlePreserved === true,
    JSON.stringify(faultError)
  );
  const faultSelection = await dialogSnapshot();
  check(
    'fault.selectionRetainedAfterRollback',
    faultSelection.selectedCount === 2,
    JSON.stringify(faultSelection)
  );
  await screenshot('batch-rollback-error.png');

  // 整批回滚：待安排列表仍为 12 条；失败批次不产生任何部分记录。
  await waitFor(
    `document.querySelectorAll('[data-work-item-id]').length === ${EXPECTED_ROWS}`,
    10000,
    'pending rows unchanged after rollback'
  );
  const pendingAfterFault = await directIpc('list_pending_work_items');
  const faultRows = pendingAfterFault.ok === true
    ? pendingAfterFault.value.filter((item) => item.title === FAULT_TITLE)
    : [];
  check(
    'fault.noPartialCopiesInDatabaseOrUi',
    faultRows.length === 0 && pendingAfterFault.value.length === EXPECTED_ROWS,
    JSON.stringify({ matching: faultRows.length, total: pendingAfterFault.value?.length })
  );

  check('fault.cancelDialog', (await clickByText('dialog[open]', '取消')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 5000);

  closeClicked = await evaluate(`(() => {
    const button = document.querySelector('.window-control--close');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`).catch(() => false);
  check('fault.closeButtonClicked', closeClicked === true);

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
  check('fault.scriptCompleted', false, String(error));
  await screenshot('fault-failure.png').catch(() => null);
  try {
    const evidence = buildEvidence({ scriptError: String(error) });
    console.error(`FAULT_EVIDENCE=${evidence.evidencePath}`);
  } catch {
    // 证据写盘失败不应掩盖原始错误。
  }
}

await sleep(500);
socket.close();
process.exit(checks.some((item) => !item.pass) || !closeClicked ? 1 : 0);
