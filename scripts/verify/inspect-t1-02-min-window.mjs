/**
 * WorkManager T1-02 最小支持窗口回归 + 标题栏关闭按钮真实验证。
 *
 * 前提：Release 进程已启动；外部脚本已把窗口调整到最小支持尺寸 860×640。
 *
 * 检查内容：
 * 1. 实际视口接近 860×640（Tauri minWidth/minHeight）；
 * 2. 工作总览与项目管理页在最小窗口下无横向溢出、关键操作可见；
 * 3. 新建项目对话框在最小窗口内完整可见；
 * 4. 点击红色关闭圆点后进程退出（由编排脚本验证），证明按钮调用真实窗口 API。
 *
 * 用法：node scripts/verify/inspect-t1-02-min-window.mjs <port> <outputDir>
 */

import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? '9334');
const outputDir = process.argv[3] ?? `D:\\WorkManager-test-data\\t1-02-ui-${Date.now()}`;
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
    if (!probe.overflow) {
      return probe;
    }
    await sleep(150);
  }
  return probe;
}

await send('Runtime.enable');
await send('Page.enable');

let closeClicked = false;
try {
  await waitFor(
    `document.querySelector('.app-shell') !== null && document.querySelectorAll('nav button').length === 6`,
    15000,
    'app shell rendered'
  );

  const viewport = await evaluate(`({
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

  // 回到工作总览。
  check('minWindow.navigateOverview', (await clickByText('nav.sidebar', '工作总览', false)) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '工作总览'`, 5000);
  const overviewProbe = await settledOverflowProbe();
  check(
    'minWindow.overviewNoHorizontalOverflow',
    overviewProbe.overflow === false,
    JSON.stringify(overviewProbe)
  );
  await screenshot('overview-min.png');

  // 设置 → 项目管理（两个归档项目仍应存在且布局可用）。
  check('minWindow.navigateSettings', (await clickByText('nav.sidebar', '设置', false)) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '设置'`, 5000);
  check('minWindow.openProjects', (await clickByText('main', '打开项目管理', false)) === true);
  await waitFor(`document.querySelectorAll('[data-project-id]').length === 2`, 12000);
  await sleep(400);
  const projectsProbe = await settledOverflowProbe();
  const layout = await evaluate(`(() => {
    const rows = Array.from(document.querySelectorAll('[data-project-id]'));
    const header = document.querySelector('main .page-header');
    const headerRect = header ? header.getBoundingClientRect() : null;
    return {
      rowCount: rows.length,
      archivedRows: rows.filter((row) => (row.innerText || '').includes('已归档')).length,
      newProjectVisible: Array.from(document.querySelectorAll('main button')).some(
        (button) =>
          (button.textContent || '').trim() === '新建项目' &&
          button.getBoundingClientRect().width > 0 &&
          button.getBoundingClientRect().right <= window.innerWidth + 1
      ),
      headerRight: headerRect ? headerRect.right : null
    };
  })()`);
  check(
    'minWindow.projectsNoHorizontalOverflow',
    projectsProbe.overflow === false,
    JSON.stringify(projectsProbe)
  );
  check(
    'minWindow.projectsArchivedRowsVisible',
    layout.rowCount === 2 && layout.archivedRows === 2,
    JSON.stringify(layout)
  );
  check('minWindow.newProjectButtonVisible', layout.newProjectVisible === true);
  await screenshot('projects-min.png');

  // 新建项目对话框必须完整落在最小窗口内。
  check('minWindow.openCreateDialog', (await clickByText('main', '新建项目', false)) === true);
  await waitFor(`document.querySelector('dialog[open]') !== null`, 5000);
  const dialogLayout = await evaluate(`(() => {
    const dialog = document.querySelector('dialog[open]');
    if (!dialog) return null;
    const rect = dialog.getBoundingClientRect();
    return {
      top: rect.top,
      left: rect.left,
      right: rect.right,
      bottom: rect.bottom,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      fullyVisible:
        rect.top >= 0 && rect.left >= 0 && rect.right <= window.innerWidth + 1 && rect.bottom <= window.innerHeight + 1
    };
  })()`);
  check('minWindow.dialogFullyVisible', dialogLayout?.fullyVisible === true, JSON.stringify(dialogLayout));
  await screenshot('projects-dialog-min.png');
  check('minWindow.cancelDialog', (await clickByText('dialog[open]', '取消')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 5000);

  // 先写证据，再点击关闭按钮（点击后页面会立即销毁，无法继续写文件）。
  const failed = checks.filter((item) => !item.pass).map((item) => item.name);
  const evidence = {
    generatedAt: new Date().toISOString(),
    task: 'T1-02',
    method: 'CDP at minimum supported window size + real titlebar close button click',
    port,
    target: { id: pageTarget.id, title: pageTarget.title, url: pageTarget.url },
    viewport,
    dialogLayout,
    checks,
    failed,
    pass: failed.length === 0
  };
  fs.writeFileSync(
    path.join(outputDir, 't1-02-min-window-evidence.json'),
    JSON.stringify(evidence, null, 2),
    'utf8'
  );

  closeClicked = await evaluate(`(() => {
    const button = document.querySelector('.window-control--close');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`).catch(() => false);
  check('minWindow.closeButtonClicked', closeClicked === true);
  console.log(JSON.stringify({ total: checks.length, failed, pass: failed.length === 0 && closeClicked }, null, 2));
} catch (error) {
  check('minWindow.scriptCompleted', false, String(error));
  await screenshot('min-window-failure.png').catch(() => null);
}

await sleep(500);
socket.close();
process.exit(checks.some((item) => !item.pass) || !closeClicked ? 1 : 0);
