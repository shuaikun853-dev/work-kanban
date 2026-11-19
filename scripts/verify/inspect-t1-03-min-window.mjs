/**
 * WorkManager T1-03 最小支持窗口布局检查 + 标题栏关闭按钮真实验证。
 *
 * 前提：Release 进程已启动（已由主检查创建 4 条虚构待安排工作），
 * 外部编排脚本已把窗口调整到最小支持尺寸 860×640。
 *
 * 检查内容：
 * 1. 实际视口接近 860×640；
 * 2. 今日工作 → 待安排视图在最小窗口下无横向溢出、行内容可见；
 * 3. 超长工作标题在最小窗口下不撑破布局，按钮仍在视口内可点击；
 * 4. 快速创建对话框完整落在最小窗口内，标题输入、项目选择、保存/取消均可见；
 * 5. 最后点击红色关闭圆点（真实 Tauri 窗口 API），进程退出由编排脚本验证。
 *
 * 用法：node scripts/verify/inspect-t1-03-min-window.mjs <port> <outputDir>
 */

import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? '9345');
const outputDir = process.argv[3] ?? `D:\\WorkManager-test-data\\t1-03-ui-${Date.now()}`;
fs.mkdirSync(outputDir, { recursive: true });

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

const overflowProbeExpression = `(() => {
  const root = document.documentElement;
  const clientWidth = root.clientWidth;
  const offenders = Array.from(document.querySelectorAll('body *'))
    .map((element) => {
      const rect = element.getBoundingClientRect();
      return {
        tag: element.tagName,
        cls: typeof element.className === 'string' ? element.className.slice(0, 60) : '',
        text: (element.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 40),
        left: Math.round(rect.left),
        right: Math.round(rect.right),
        width: Math.round(rect.width),
        scrollWidth: element.scrollWidth,
        clientWidth: element.clientWidth
      };
    })
    .filter((item) => item.right > clientWidth + 1 || item.scrollWidth > item.clientWidth + 1)
    .slice(0, 10);
  return {
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    docScrollWidth: root.scrollWidth,
    clientWidth,
    bodyScrollWidth: document.body.scrollWidth,
    overflow: root.scrollWidth > clientWidth + 1 || document.body.scrollWidth > clientWidth + 1,
    offenders
  };
})()`;

async function settledOverflowProbe() {
  let probe = null;
  for (let attempt = 0; attempt < 10; attempt += 1) {
    probe = await evaluate(overflowProbeExpression);
    if (!probe.overflow) return probe;
    await sleep(150);
  }
  return probe;
}

await send('Runtime.enable');
await send('Page.enable');

let closeClicked = false;
let viewport = null;
let dialogLayout = null;

function buildEvidence(extra = {}) {
  const failed = checks.filter((item) => !item.pass).map((item) => item.name);
  const evidence = {
    generatedAt: new Date().toISOString(),
    task: 'T1-03',
    method:
      'CDP at minimum supported window size 860x640: app-shell wait, 待安排 view layout checks, long-title layout check, quick-create dialog bounds, real titlebar close button click; process exit verified by orchestration',
    port,
    target: { id: pageTarget.id, title: pageTarget.title, url: pageTarget.url },
    viewport,
    dialogLayout,
    checks,
    failed,
    checkCount: checks.length,
    closeClicked,
    processExitVerifiedBy:
      'scripts/verify/verify-t1-03-ui.ps1（t1-03-ui-orchestration.json firstCloseExitCode）',
    pass: failed.length === 0 && closeClicked === true,
    ...extra
  };
  const evidencePath = path.join(outputDir, 't1-03-min-window-evidence.json');
  fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2), 'utf8');
  evidence.evidencePath = evidencePath;
  return evidence;
}

try {
  await waitFor(
    `document.readyState === 'complete' && document.querySelector('.app-shell') !== null && document.querySelectorAll('nav.sidebar button').length === 6`,
    15000,
    'app shell rendered'
  );

  viewport = await evaluate(`({
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    outerWidth: window.outerWidth,
    outerHeight: window.outerHeight
  })`);
  check(
    'minWindow.sizeNear860x640',
    viewport.innerWidth >= 840 && viewport.innerWidth <= 900 && viewport.innerHeight >= 600,
    JSON.stringify(viewport)
  );

  // 今日工作 → 待安排。
  check('minWindow.navigateToday', (await clickByText('nav.sidebar', '今日工作', false)) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '今日工作'`, 5000);
  check('minWindow.pendingEntryVisible', (await clickByText('.view-switcher', '待安排', true)) === true);
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === 4`, 15000);
  await sleep(400);

  const pendingProbe = await settledOverflowProbe();
  check(
    'minWindow.pendingNoHorizontalOverflow',
    pendingProbe.overflow === false,
    JSON.stringify(pendingProbe)
  );

  const pendingLayout = await evaluate(`(() => {
    const rows = Array.from(document.querySelectorAll('[data-work-item-id]'));
    const toolbarButton = Array.from(document.querySelectorAll('main button')).find(
      (button) => (button.textContent || '').trim() === '新增工作'
    );
    const longRow = rows.find((row) => (row.innerText || '').includes('T1-03-LONG-TITLE'));
    const longTitleElement = longRow ? longRow.querySelector('.work-item-title') : null;
    return {
      rowCount: rows.length,
      archivedBadgeCount: rows.filter((row) => (row.innerText || '').includes('项目已归档')).length,
      createButtonVisible:
        toolbarButton !== undefined &&
        toolbarButton.getBoundingClientRect().width > 0 &&
        toolbarButton.getBoundingClientRect().right <= window.innerWidth + 1,
      longRowVisible: longRow !== undefined,
      longTitleEllipsized:
        longTitleElement !== null && longTitleElement.scrollWidth > longTitleElement.clientWidth,
      longTitleFullAttribute:
        longTitleElement !== null ? longTitleElement.getAttribute('title') !== null : false,
      firstRowRight: rows.length > 0 ? Math.round(rows[0].getBoundingClientRect().right) : null
    };
  })()`);
  check(
    'minWindow.pendingRowsVisible',
    pendingLayout.rowCount === 4 && pendingLayout.archivedBadgeCount === 1,
    JSON.stringify(pendingLayout)
  );
  check('minWindow.createButtonClickable', pendingLayout.createButtonVisible === true);
  check(
    'minWindow.longTitleEllipsizedWithoutClippingLayout',
    pendingLayout.longRowVisible === true &&
      pendingLayout.longTitleEllipsized === true &&
      pendingLayout.longTitleFullAttribute === true,
    JSON.stringify(pendingLayout)
  );
  await screenshot('pending-min.png');

  // 快速创建对话框必须完整落在最小窗口内。
  check('minWindow.openCreateDialog', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open]') !== null`, 5000);
  await waitFor(
    `document.querySelectorAll('dialog[open] #work-item-project option').length === 1`,
    8000,
    'project selector loaded (all projects archived)'
  );
  dialogLayout = await evaluate(`(() => {
    const dialog = document.querySelector('dialog[open]');
    if (!dialog) return null;
    const rect = dialog.getBoundingClientRect();
    const titleInput = dialog.querySelector('#work-item-title');
    const projectSelect = dialog.querySelector('#work-item-project');
    const saveButton = Array.from(dialog.querySelectorAll('button')).find(
      (button) => (button.textContent || '').trim() === '保存'
    );
    const cancelButton = Array.from(dialog.querySelectorAll('button')).find(
      (button) => (button.textContent || '').trim() === '取消'
    );
    const within = (element) => {
      if (!element) return false;
      const box = element.getBoundingClientRect();
      return box.width > 0 && box.height > 0 && box.top >= -1 && box.left >= -1 &&
        box.right <= window.innerWidth + 1 && box.bottom <= window.innerHeight + 1;
    };
    return {
      top: Math.round(rect.top),
      left: Math.round(rect.left),
      right: Math.round(rect.right),
      bottom: Math.round(rect.bottom),
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      fullyVisible:
        rect.top >= -1 && rect.left >= -1 && rect.right <= window.innerWidth + 1 && rect.bottom <= window.innerHeight + 1,
      titleInputVisible: within(titleInput),
      projectSelectVisible: within(projectSelect),
      saveVisible: within(saveButton),
      cancelVisible: within(cancelButton)
    };
  })()`);
  check(
    'minWindow.dialogFullyVisible',
    dialogLayout?.fullyVisible === true,
    JSON.stringify(dialogLayout)
  );
  check(
    'minWindow.dialogControlsVisible',
    dialogLayout?.titleInputVisible === true &&
      dialogLayout?.projectSelectVisible === true &&
      dialogLayout?.saveVisible === true &&
      dialogLayout?.cancelVisible === true,
    JSON.stringify(dialogLayout)
  );
  await screenshot('create-dialog-min.png');
  check('minWindow.cancelDialog', (await clickByText('dialog[open]', '取消')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 5000);

  // 最后点击真实窗口关闭按钮；点击后页面立即销毁，但 Node 进程仍可写证据文件。
  closeClicked = await evaluate(`(() => {
    const button = document.querySelector('.window-control--close');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`).catch(() => false);
  check('minWindow.closeButtonClicked', closeClicked === true);

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
  check('minWindow.scriptCompleted', false, String(error));
  await screenshot('min-window-failure.png').catch(() => null);
  try {
    const evidence = buildEvidence({ scriptError: String(error) });
    console.error(`MIN_WINDOW_EVIDENCE=${evidence.evidencePath}`);
  } catch {
    // 证据写盘失败不应掩盖原始错误。
  }
}

await sleep(500);
socket.close();
process.exit(checks.some((item) => !item.pass) || !closeClicked ? 1 : 0);
