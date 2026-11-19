/**
 * WorkManager T1-03 工作事项快速创建 / 待安排 Release UI + IPC 端到端检查。
 *
 * 前提：Release 进程已用 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>`
 * 启动，且 WebView2 已加载页面（使用独立 UAT 便携目录，数据库为空）。
 *
 * 本脚本通过 Chromium DevTools Protocol 操作真实 Release WebView2：
 * 1. 验证应用壳、固定六个一级导航（不新增一级导航）与今日工作 → 待安排次级视图入口；
 * 2. 真实异步 IPC 下的 loading / empty / list 状态与截图；
 * 3. 通过真实 UI 创建未归属工作、关联未归档项目的工作；相同标题独立记录；
 * 4. 重复提交保护（同步双点击只产生一条记录）；
 * 5. 项目选择器只展示未归档项目；
 * 6. 对话框打开期间项目被归档 → Core 返回 `project-archived`，UI 显示错误并刷新选项；
 * 7. 绕过 UI 直接调用 IPC：归档项目 / 不存在项目 / 空标题 / 未知字段均被后端拒绝；
 * 8. CDP 故障注入（不改产品代码）：待安排列表加载失败 + 重试、Bridge 契约违规校验；
 * 9. 关联归档项目的历史工作仍在待安排列表并显示“项目已归档”；
 * 10. CSP 0 违规、页面无未捕获异常、正常窗口无横向溢出；保留截图与机器可读证据。
 *
 * 本脚本创建的数据保留给“关闭 → 重启 → 持久化”检查阶段使用。
 *
 * 用法：node scripts/verify/inspect-t1-03-ui.mjs <port> <outputDir>
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
        if (page) {
          return page;
        }
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
const deterministicWaits = [];

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
  if (!message.id || !pending.has(message.id)) {
    return;
  }
  const handlers = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) {
    handlers.reject(new Error(JSON.stringify(message.error)));
  } else {
    handlers.resolve(message.result);
  }
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
  return Boolean(pass);
}

async function waitFor(expression, timeoutMs = 12000, label = expression, stateExpression = null) {
  const deadline = Date.now() + timeoutMs;
  let lastState = null;
  while (Date.now() < deadline) {
    try {
      if (await evaluate(expression)) {
        return true;
      }
    } catch {
      // 页面切换期间执行上下文可能短暂失效，继续轮询。
    }
    if (stateExpression !== null) {
      try {
        lastState = await evaluate(stateExpression);
      } catch {
        // 保留上一轮快照即可。
      }
    }
    await sleep(120);
  }
  const stateSuffix =
    lastState === null ? '' : `; lastState=${JSON.stringify(lastState).slice(0, 800)}`;
  throw new Error(`Timed out waiting for: ${label}${stateSuffix}`);
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

function clickSwitcher(label) {
  return clickByText('.view-switcher', label, true);
}

function clickNav(label) {
  return clickByText('nav.sidebar', label, false);
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
    offenders
  };
})()`;

async function checkNoOverflow(name) {
  const probe = await evaluate(overflowProbeExpression);
  const pass =
    probe.docScrollWidth <= probe.clientWidth + 1 &&
    probe.bodyScrollWidth <= probe.clientWidth + 1;
  check(name, pass, JSON.stringify(probe));
  return pass;
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

/**
 * CDP 故障注入：在页面的 fetch 传输层拦截指定 IPC 命令（不改产品代码）。
 *
 * Tauri 2 的 `window.__TAURI_INTERNALS__.invoke` 由初始化脚本通过
 * Object.defineProperty 定义为不可写属性，无法直接替换；但 invoke 内部使用全局
 * fetch 访问 `http://ipc.localhost/<command>`，因此可以在传输层伪造 IPC 响应，
 * 用于验证未触发真实错误时的 UI 错误/契约违规状态。
 *
 * mode:
 * - 'reject'：返回 Tauri-Response: error + JSON 错误载荷（模拟加载失败）；
 * - 'malformed'：返回 Tauri-Response: ok + 不符合 DTO 契约的 JSON（验证 Bridge 运行时校验）。
 */
async function installListPendingFault(mode) {
  return evaluate(`(() => {
    if (typeof window.__wmOriginalFetch !== 'function') {
      window.__wmOriginalFetch = window.fetch.bind(window);
    }
    window.__wmListFaultMode = ${JSON.stringify(mode)};
    if (!window.__wmListFaultFetchInstalled) {
      window.__wmListFaultFetchInstalled = true;
      window.fetch = function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        if (url.indexOf('list_pending_work_items') !== -1 && window.__wmListFaultMode !== 'off') {
          if (window.__wmListFaultMode === 'reject') {
            return Promise.resolve(new Response(JSON.stringify({
              code: 'ipc-command-failed',
              message: '模拟待安排列表加载失败'
            }), {
              status: 200,
              headers: { 'Content-Type': 'application/json', 'Tauri-Response': 'error' }
            }));
          }
          if (window.__wmListFaultMode === 'malformed') {
            return Promise.resolve(new Response(JSON.stringify([
              {
                id: 42,
                projectId: null,
                projectName: null,
                projectIsArchived: false,
                title: '契约违规返回值',
                lifecycleStatus: 'pending',
                createdAt: 't',
                updatedAt: 't'
              }
            ]), {
              status: 200,
              headers: { 'Content-Type': 'application/json', 'Tauri-Response': 'ok' }
            }));
          }
        }
        return window.__wmOriginalFetch(input, init);
      };
    }
    return true;
  })()`);
}

async function clearListPendingFault() {
  return evaluate(`(() => {
    window.__wmListFaultMode = 'off';
    return true;
  })()`);
}

async function waitForIpcReady(timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let lastProbe = null;
  while (Date.now() < deadline) {
    lastProbe = await directIpc('get_database_health');
    if (
      lastProbe.ok === true &&
      lastProbe.value?.database?.status === 'ok' &&
      lastProbe.value?.database?.schemaVersion === 3
    ) {
      return lastProbe;
    }
    await sleep(200);
  }
  throw new Error(`Tauri IPC 未在 ${timeoutMs}ms 内就绪: ${JSON.stringify(lastProbe).slice(0, 600)}`);
}

/** 待安排视图确定性终态：Loading 结束后的空/列表/错误之一。 */
const pendingStateExpression = `(() => {
  const main = document.querySelector('main');
  if (main === null) return { mounted: false, ready: false };
  const heading = (document.querySelector('#pending-work-title') || {}).textContent || null;
  if (heading === null) return { mounted: true, ready: false, heading: null };
  const text = main.innerText || '';
  const loading = text.includes('正在读取待安排工作');
  const alertElement = main.querySelector('[role="alert"]');
  return {
    mounted: true,
    ready: !loading,
    heading,
    loading,
    empty: text.includes('暂无待安排工作'),
    rows: document.querySelectorAll('[data-work-item-id]').length,
    error: alertElement !== null,
    errorText: alertElement
      ? (alertElement.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 400)
      : null
  };
})()`;

async function waitForPendingSettled(timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let lastState = null;
  while (Date.now() < deadline) {
    try {
      lastState = await evaluate(pendingStateExpression);
    } catch {
      await sleep(120);
      continue;
    }
    if (lastState?.mounted === true && lastState.ready === true) {
      return lastState;
    }
    await sleep(120);
  }
  throw new Error(
    `Timed out waiting for pending view settled; lastState=${JSON.stringify(lastState).slice(0, 800)}`
  );
}

async function rowSnapshots() {
  return evaluate(`(() => Array.from(document.querySelectorAll('[data-work-item-id]')).map((row) => ({
    id: row.getAttribute('data-work-item-id'),
    title: ((row.querySelector('.work-item-title') || {}).textContent || '').trim(),
    titleAttr: (() => { const el = row.querySelector('.work-item-title'); return el ? el.getAttribute('title') : null; })(),
    meta: ((row.querySelector('.work-item-meta') || {}).innerText || '').replace(/\\s+/g, ' ').trim(),
    hasArchivedBadge: row.innerText.includes('项目已归档')
  })))()`);
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

async function setDialogProject(projectId) {
  return evaluate(`(() => {
    const select = document.querySelector('dialog[open] #work-item-project');
    if (!(select instanceof HTMLSelectElement)) return false;
    select.value = ${JSON.stringify(projectId)};
    select.dispatchEvent(new Event('change', { bubbles: true }));
    return select.value === ${JSON.stringify(projectId)};
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

async function submitDialogSave() {
  return clickByText('dialog[open]', '保存', true);
}

async function switchToPendingAndSettle() {
  await clickSwitcher('待安排');
  return waitForPendingSettled(20000);
}

async function remountPendingViewAndSettle() {
  await clickSwitcher('今日工作');
  await waitFor(
    `document.querySelector('#pending-work-title') === null`,
    8000,
    'pending view unmounted'
  );
  return switchToPendingAndSettle();
}

async function captureFailureDiagnostics(label) {
  const diagnostics = {
    generatedAt: new Date().toISOString(),
    task: 'T1-03',
    label,
    outputDir,
    target: { id: pageTarget.id, title: pageTarget.title, url: pageTarget.url },
    page: null,
    ipc: {},
    pageErrors,
    screenshot: null
  };

  try {
    diagnostics.page = await evaluate(`(() => ({
      readyState: document.readyState,
      title: document.title,
      location: location.href,
      heading: ((document.querySelector('h1') || {}).textContent || '').trim(),
      bodyText: (document.body.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 1500),
      hasAppShell: document.querySelector('.app-shell') !== null,
      navCount: document.querySelectorAll('nav.sidebar button').length,
      pendingHeading: (document.querySelector('#pending-work-title') || {}).textContent || null,
      rows: document.querySelectorAll('[data-work-item-id]').length,
      dialogOpen: document.querySelector('dialog[open]') !== null,
      errorPanel: document.querySelector('[role="alert"]') !== null,
      tauriInternals: typeof window.__TAURI_INTERNALS__?.invoke === 'function'
    }))()`);
  } catch (error) {
    diagnostics.page = { error: String(error) };
  }

  try {
    diagnostics.ipc.listPending = await directIpc('list_pending_work_items');
  } catch (error) {
    diagnostics.ipc.listPending = { error: String(error) };
  }
  try {
    diagnostics.ipc.listProjects = await directIpc('list_projects');
  } catch (error) {
    diagnostics.ipc.listProjects = { error: String(error) };
  }
  try {
    diagnostics.screenshot = await screenshot(`failure-${label}.png`);
  } catch {
    diagnostics.screenshot = null;
  }

  diagnostics.filePath = path.join(outputDir, `t1-03-ui-failure-${label}.json`);
  fs.writeFileSync(diagnostics.filePath, JSON.stringify(diagnostics, null, 2), 'utf8');
  return diagnostics;
}

const fixturePrefix = 'T1-03 虚构';
const longTitle =
  '超长工作标题用于验证待安排列表在最小窗口下不会横向溢出也不会裁切操作按钮' +
  '——这是第二段用于增加长度的虚构工作标题内容——' +
  'T1-03-LONG-TITLE-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ';

await send('Runtime.enable');
await send('Page.enable');
await send('Log.enable');

const bootMarker = `wm-t1-03-${Date.now()}-${Math.random().toString(16).slice(2)}`;

await send('Page.addScriptToEvaluateOnNewDocument', {
  source: `window.__wmBootMarker = ${JSON.stringify(bootMarker)};
window.__wmCspViolations = [];
document.addEventListener('securitypolicyviolation', (event) => {
  window.__wmCspViolations.push({
    blockedURI: event.blockedURI,
    violatedDirective: event.violatedDirective,
    sourceFile: event.sourceFile,
    sample: event.sample
  });
});`
});

await waitFor(
  `document.readyState === 'complete'`,
  15000,
  'initial document readyState complete',
  `({ readyState: document.readyState, hasAppShell: document.querySelector('.app-shell') !== null })`
).catch(() => null);

await send('Page.reload', { ignoreCache: true });

const bootStateExpression = `(() => ({
  readyState: document.readyState,
  bootMarkerMatched: window.__wmBootMarker === ${JSON.stringify(bootMarker)},
  hasAppShell: document.querySelector('.app-shell') !== null,
  navCount: document.querySelectorAll('nav.sidebar button').length,
  tauriInternals: typeof window.__TAURI_INTERNALS__?.invoke === 'function'
}))()`;

let currentProject = null;
let archivedProject = null;
let unassignedWorkItem = null;

try {
  await waitFor(
    `window.__wmBootMarker === ${JSON.stringify(bootMarker)} && document.readyState === 'complete'`,
    30000,
    'reloaded document boot marker',
    bootStateExpression
  );
  deterministicWaits.push('page.reloadNewDocumentBootMarker');

  await waitFor(
    `document.querySelector('.app-shell') !== null && document.querySelectorAll('nav.sidebar button').length === 6 && typeof window.__TAURI_INTERNALS__?.invoke === 'function'`,
    30000,
    'app shell rendered in reloaded document',
    bootStateExpression
  );
  deterministicWaits.push('appShell.renderedWithTauriInternals');

  await waitForIpcReady(20000);
  deterministicWaits.push('ipc.databaseHealthReadySchema3');

  await sleep(300);
  check('shell.rendered', true);

  // 1. 应用壳 / 固定一级导航：不得为待安排新增一级导航。
  const shell = await evaluate(`(() => ({
    title: document.title,
    appName: (document.querySelector('.window-titlebar__app-name') || {}).textContent || null,
    navLabels: Array.from(document.querySelectorAll('nav.sidebar button')).map((item) =>
      (item.textContent || '').replace(/\\s+/g, ' ').trim()
    ),
    heading: (document.querySelector('h1') || {}).textContent || null,
    activeNav: (document.querySelector('nav.sidebar [aria-current="page"]') || {}).textContent || null
  }))()`);
  check('shell.titlebarAppName', shell.appName === 'WorkManager');
  check(
    'shell.sidebarNavigationUnchanged',
    shell.navLabels.length === 6 &&
      shell.navLabels.join('/') === '工作总览/今日工作/未来 7 天/历史记录/报告/设置',
    shell.navLabels.join(' / ')
  );
  check(
    'shell.noNewPrimaryNavigationForPending',
    !shell.navLabels.some((label) => label.includes('待安排')),
    '待安排不得成为一级导航'
  );
  await checkNoOverflow('shell.noHorizontalOverflow');

  // 2. 今日工作 → 待安排次级视图入口（不新增一级导航）。
  check('nav.todayClicked', (await clickNav('今日工作')) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '今日工作'`, 5000);
  const switcher = await evaluate(`(() => ({
    labels: Array.from(document.querySelectorAll('.view-switcher button')).map((item) =>
      (item.textContent || '').replace(/\\s+/g, ' ').trim()
    ),
    pressed: Array.from(document.querySelectorAll('.view-switcher button'))
      .filter((item) => item.getAttribute('aria-pressed') === 'true')
      .map((item) => (item.textContent || '').trim())
  }))()`);
  check(
    'today.secondarySwitcherRendered',
    switcher.labels.length === 2 &&
      switcher.labels[0] === '今日工作' &&
      switcher.labels[1] === '待安排',
    JSON.stringify(switcher)
  );
  check('today.defaultViewIsToday', switcher.pressed.length === 1 && switcher.pressed[0] === '今日工作');
  check(
    'today.executionPlaceholderHonest',
    (await evaluate(`document.querySelector('main').innerText.includes('执行记录尚未接入')`)) === true,
    '今日工作执行记录未接入时不得展示虚构数据'
  );
  await screenshot('today-entry.png');

  // 3. 真实异步 loading：CPU 限速让 Loading 状态可稳定观察（测量手段，不改变产品行为）。
  await send('Emulation.setCPUThrottlingRate', { rate: 20 });
  await sleep(300);
  const loadingProbe = await evaluate(`(async () => {
    const button = Array.from(document.querySelectorAll('.view-switcher button')).find((item) =>
      (item.textContent || '').trim() === '待安排'
    );
    if (!button) return { clicked: false };
    button.click();
    await new Promise((resolve) => queueMicrotask(resolve));
    return {
      clicked: true,
      heading: (document.querySelector('#pending-work-title') || {}).textContent || null,
      loading: document.body.innerText.includes('正在读取待安排工作'),
      statusCount: document.querySelectorAll('[role="status"]').length
    };
  })()`);
  check('pending.entryClicked', loadingProbe.clicked === true);
  check(
    'pending.loadingStateVisible',
    loadingProbe.loading === true && loadingProbe.heading === '待安排',
    JSON.stringify(loadingProbe)
  );
  if (loadingProbe.loading) {
    await screenshot('pending-loading.png');
  }
  await send('Emulation.setCPUThrottlingRate', { rate: 1 });

  // 4. 空状态（真实数据库为空）。
  const emptyState = await waitForPendingSettled(20000);
  deterministicWaits.push('pendingView.loadingSettled');
  check('pending.emptyStateRendered', emptyState.empty === true, JSON.stringify(emptyState));
  check(
    'pending.emptyStateCreateAction',
    (await evaluate(
      `Array.from(document.querySelectorAll('main button')).some((button) => (button.textContent || '').trim() === '创建第一项工作')`
    )) === true
  );
  await checkNoOverflow('pending.emptyNoHorizontalOverflow');
  await screenshot('pending-empty.png');

  const emptyList = await directIpc('list_pending_work_items');
  check(
    'ipc.listPendingEmpty',
    emptyList.ok === true && Array.isArray(emptyList.value) && emptyList.value.length === 0,
    JSON.stringify(emptyList).slice(0, 300)
  );

  // 5. 仅填标题创建未归属工作。
  check('create.openFromToolbar', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-title') !== null`, 5000);
  const createForm = await evaluate(`(() => {
    const dialog = document.querySelector('dialog[open]');
    return {
      title: (dialog.querySelector('.dialog-title') || {}).textContent || null,
      hasTitleInput: dialog.querySelector('#work-item-title') !== null,
      hasProjectSelect: dialog.querySelector('#work-item-project') !== null,
      textInputs: dialog.querySelectorAll('input[type="text"]').length,
      labels: Array.from(dialog.querySelectorAll('.field-label')).map((item) => (item.textContent || '').trim())
    };
  })()`);
  check(
    'create.onlyTitleAndProjectFields',
    createForm.hasTitleInput === true &&
      createForm.hasProjectSelect === true &&
      createForm.textInputs === 1 &&
      createForm.labels.length === 2,
    JSON.stringify(createForm)
  );
  const initialOptions = await dialogProjectOptions();
  check(
    'create.onlyUnassignedOptionWithoutProjects',
    Array.isArray(initialOptions) &&
      initialOptions.length === 1 &&
      initialOptions[0].value === '' &&
      initialOptions[0].label === '未归属项目',
    JSON.stringify(initialOptions)
  );
  await screenshot('create-dialog.png');

  check('create.titleFilled', (await setDialogTitle('整理中核商品数据')) === true);
  check('create.saved', (await submitDialogSave()) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000, 'create dialog closed');
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === 1`, 10000);
  const firstRows = await rowSnapshots();
  check(
    'create.unassignedRowVisible',
    firstRows.length === 1 &&
      firstRows[0].title === '整理中核商品数据' &&
      firstRows[0].meta.includes('未归属项目') &&
      firstRows[0].hasArchivedBadge === false,
    JSON.stringify(firstRows)
  );
  const afterFirstCreate = await directIpc('list_pending_work_items');
  unassignedWorkItem = afterFirstCreate.value?.[0] ?? null;
  check(
    'ipc.unassignedPersisted',
    afterFirstCreate.ok === true &&
      afterFirstCreate.value.length === 1 &&
      afterFirstCreate.value[0].title === '整理中核商品数据' &&
      afterFirstCreate.value[0].projectId === null &&
      afterFirstCreate.value[0].lifecycleStatus === 'pending',
    JSON.stringify(afterFirstCreate.value).slice(0, 400)
  );
  await checkNoOverflow('pending.unassignedNoHorizontalOverflow');
  await screenshot('pending-unassigned.png');

  // 6. 重复提交保护：同一事件循环内同步双点击只产生一条记录。
  check('create.reopenForDoubleSubmit', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-title') !== null`, 5000);
  check('create.doubleSubmitTitleFilled', (await setDialogTitle('重复提交保护验证')) === true);
  const doubleClick = await evaluate(`(() => {
    const button = Array.from(document.querySelectorAll('dialog[open] button')).find(
      (item) => (item.textContent || '').trim() === '保存'
    );
    if (!button) return { clicked: 0 };
    button.click();
    button.click();
    return { clicked: 2 };
  })()`);
  check('create.doubleClickDispatched', doubleClick.clicked === 2);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000, 'double-submit dialog closed');
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === 2`, 10000);
  await sleep(600);
  const afterDoubleSubmit = await directIpc('list_pending_work_items');
  const doubleSubmitCount =
    afterDoubleSubmit.ok === true
      ? afterDoubleSubmit.value.filter((item) => item.title === '重复提交保护验证').length
      : -1;
  check(
    'create.doubleSubmitCreatesSingleRecord',
    doubleSubmitCount === 1,
    `匹配记录数=${doubleSubmitCount}`
  );

  // 7. 项目选择器只展示未归档项目；创建关联未归档项目的工作。
  const projectA = await directIpc('create_project', {
    input: { name: `${fixturePrefix}未归档项目` }
  });
  const projectB = await directIpc('create_project', {
    input: { name: `${fixturePrefix}归档项目` }
  });
  check(
    'setup.projectsCreated',
    projectA.ok === true && projectB.ok === true,
    JSON.stringify({ a: projectA.ok, b: projectB.ok })
  );
  currentProject = projectA.value;
  archivedProject = projectB.value;
  const archiveB = await directIpc('archive_project', { input: { id: archivedProject.id } });
  check('setup.projectArchived', archiveB.ok === true && archiveB.value.isArchived === true);

  check('create.reopenForProjectSelection', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-project') !== null`, 5000);
  await waitFor(
    `document.querySelectorAll('dialog[open] #work-item-project option').length === 2`,
    8000,
    'project options loaded'
  );
  const optionsWithArchived = await dialogProjectOptions();
  check(
    'create.selectorOnlyUnarchivedProjects',
    Array.isArray(optionsWithArchived) &&
      optionsWithArchived.length === 2 &&
      optionsWithArchived[0].value === '' &&
      optionsWithArchived[0].label === '未归属项目' &&
      optionsWithArchived[1].value === currentProject.id &&
      optionsWithArchived[1].label === `${fixturePrefix}未归档项目` &&
      !optionsWithArchived.some((option) => option.value === archivedProject.id),
    JSON.stringify(optionsWithArchived)
  );
  check('create.projectSelected', (await setDialogProject(currentProject.id)) === true);
  check('create.linkedTitleFilled', (await setDialogTitle('关联未归档项目的待安排工作')) === true);
  await screenshot('create-dialog-projects.png');
  check('create.linkedSaved', (await submitDialogSave()) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000);
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === 3`, 10000);
  const linkedRows = await rowSnapshots();
  const linkedRow = linkedRows.find((row) => row.title === '关联未归档项目的待安排工作');
  check(
    'create.linkedRowShowsProjectName',
    linkedRow !== undefined && linkedRow.meta.includes(`${fixturePrefix}未归档项目`),
    JSON.stringify(linkedRow)
  );
  const afterLinkedCreate = await directIpc('list_pending_work_items');
  const linkedItem = afterLinkedCreate.value.find(
    (item) => item.title === '关联未归档项目的待安排工作'
  );
  check(
    'ipc.linkedWorkItemPersisted',
    linkedItem !== undefined &&
      linkedItem.projectId === currentProject.id &&
      linkedItem.projectName === `${fixturePrefix}未归档项目` &&
      linkedItem.projectIsArchived === false,
    JSON.stringify(linkedItem)
  );
  await screenshot('pending-linked-project.png');

  // 8. 竞态：对话框打开后项目被归档，保存必须被 Core 拒绝并显示 project-archived。
  check('race.openDialog', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-project') !== null`, 5000);
  await waitFor(
    `document.querySelectorAll('dialog[open] #work-item-project option').length === 2`,
    8000,
    'project options loaded before race'
  );
  check('race.projectSelected', (await setDialogProject(currentProject.id)) === true);
  check('race.titleFilled', (await setDialogTitle('项目已归档时不应创建的工作')) === true);
  const archiveBehindDialog = await directIpc('archive_project', {
    input: { id: currentProject.id }
  });
  check('race.projectArchivedBehindDialog', archiveBehindDialog.ok === true);
  check('race.saveClicked', (await submitDialogSave()) === true);
  await waitFor(`document.querySelector('dialog[open] .dialog-error') !== null`, 10000, 'dialog error');
  const raceError = await evaluate(`(() => {
    const error = document.querySelector('dialog[open] .dialog-error');
    const code = document.querySelector('dialog[open] .dialog-error-code');
    return {
      message: (error.innerText || '').replace(/\\s+/g, ' ').trim(),
      code: code ? (code.textContent || '').replace(/\\s+/g, ' ').trim() : null,
      dialogStillOpen: document.querySelector('dialog[open]') !== null
    };
  })()`);
  check(
    'race.projectArchivedErrorShown',
    raceError.message.includes('归档') &&
      (raceError.code ?? '').includes('project-archived') &&
      raceError.dialogStillOpen === true,
    JSON.stringify(raceError)
  );
  // 失效项目必须从选择器中消失，且选择回退为未归属项目。
  await waitFor(
    `document.querySelectorAll('dialog[open] #work-item-project option').length === 1`,
    8000,
    'archived project removed from selector'
  );
  const optionsAfterRace = await dialogProjectOptions();
  check(
    'race.archivedProjectRemovedFromSelector',
    optionsAfterRace.length === 1 && optionsAfterRace[0].value === '',
    JSON.stringify(optionsAfterRace)
  );
  await screenshot('create-error-project-archived.png');
  check('race.cancelDialog', (await clickByText('dialog[open]', '取消')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 5000);

  const pendingAfterRace = await waitForPendingSettled(15000);
  check(
    'race.noRecordCreatedForArchivedProject',
    pendingAfterRace.rows === 3,
    JSON.stringify(pendingAfterRace)
  );
  const linkedRowsAfterArchive = await rowSnapshots();
  const archivedLinkedRow = linkedRowsAfterArchive.find((row) => row.id === linkedItem?.id);
  check(
    'archivedProject.historyLinkStillListed',
    archivedLinkedRow !== undefined &&
      archivedLinkedRow.meta.includes(`${fixturePrefix}未归档项目`) &&
      archivedLinkedRow.hasArchivedBadge === true,
    JSON.stringify(archivedLinkedRow)
  );
  await screenshot('pending-archived-project.png');

  // 9. 绕过 UI 直接 IPC：后端仍必须拒绝归档项目 / 不存在项目 / 空标题 / 未知字段。
  const bypassArchived = await directIpc('create_work_item', {
    input: { title: '绕过 UI 的归档项目工作', projectId: archivedProject.id }
  });
  check(
    'ipc.archivedProjectRejectedEvenWithoutUiFilter',
    bypassArchived.ok === false && String(bypassArchived.error).includes('project-archived'),
    String(bypassArchived.error).slice(0, 300)
  );
  const bypassMissingProject = await directIpc('create_work_item', {
    input: {
      title: '不存在项目的工作',
      projectId: '33333333-3333-4333-8333-333333333333'
    }
  });
  check(
    'ipc.missingProjectRejected',
    bypassMissingProject.ok === false && String(bypassMissingProject.error).includes('project-not-found'),
    String(bypassMissingProject.error).slice(0, 300)
  );
  const bypassEmptyTitle = await directIpc('create_work_item', {
    input: { title: '   ', projectId: null }
  });
  check(
    'ipc.emptyTitleRejected',
    bypassEmptyTitle.ok === false && String(bypassEmptyTitle.error).includes('work-item-title-empty'),
    String(bypassEmptyTitle.error).slice(0, 300)
  );
  const bypassUnknownField = await directIpc('create_work_item', {
    input: { title: '未知字段工作', projectId: null, extraField: 1 }
  });
  check(
    'ipc.unknownFieldRejected',
    bypassUnknownField.ok === false,
    String(bypassUnknownField.error).slice(0, 300)
  );
  const bypassSnakeCase = await directIpc('create_work_item', {
    input: { title: '蛇形字段工作', project_id: null }
  });
  check(
    'ipc.snakeCaseProjectIdRejected',
    bypassSnakeCase.ok === false,
    String(bypassSnakeCase.error).slice(0, 300)
  );
  const arbitrarySql = await directIpc('execute_sql', { sql: 'SELECT 1' });
  check('ipc.noArbitrarySqlCommand', arbitrarySql.ok === false);

  const countAfterBypassAttempts = await directIpc('list_pending_work_items');
  check(
    'ipc.rejectedRequestsCreatedNoRows',
    countAfterBypassAttempts.ok === true && countAfterBypassAttempts.value.length === 3,
    JSON.stringify(countAfterBypassAttempts.value?.length)
  );

  // 10. 加载失败 + 重试（CDP 传输层故障注入，不修改产品代码）。
  const patchLoadFailure = await installListPendingFault('reject');
  check('fault.loadFailureInjected', patchLoadFailure === true);
  const errorState = await remountPendingViewAndSettle();
  check(
    'fault.loadErrorStateShown',
    errorState.error === true &&
      (errorState.errorText ?? '').includes('待安排工作加载失败') &&
      (errorState.errorText ?? '').includes('ipc-command-failed'),
    JSON.stringify(errorState)
  );
  await screenshot('pending-load-error.png');

  const restoreFetch = await clearListPendingFault();
  check('fault.transportRestored', restoreFetch === true);
  check('fault.retryClicked', (await clickByText('main', '重新加载', true)) === true);
  const retriedState = await waitForPendingSettled(15000);
  check('fault.retryRecoversList', retriedState.rows === 3, JSON.stringify(retriedState));

  // 11. Bridge 运行时校验：伪造符合 JSON 但不合法的返回值，UI 必须拒绝并显示契约错误。
  const patchContractViolation = await installListPendingFault('malformed');
  check('fault.contractViolationInjected', patchContractViolation === true);
  const contractState = await remountPendingViewAndSettle();
  check(
    'fault.bridgeRuntimeValidationRejectsMalformedPayload',
    contractState.error === true &&
      (contractState.errorText ?? '').includes('待安排工作加载失败') &&
      (contractState.errorText ?? '').includes('ipc-contract-violation'),
    JSON.stringify(contractState)
  );
  await screenshot('pending-contract-violation.png');
  await clearListPendingFault();
  check('fault.retryAfterContractViolation', (await clickByText('main', '重新加载', true)) === true);
  const recoveredState = await waitForPendingSettled(15000);
  check('fault.recoveredAfterContractViolation', recoveredState.rows === 3, JSON.stringify(recoveredState));

  // 12. 长标题布局：单行省略、保留 title 全文、正常窗口无横向溢出。
  check('long.openCreate', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-title') !== null`, 5000);
  check('long.titleFilled', (await setDialogTitle(longTitle)) === true);
  check('long.saved', (await submitDialogSave()) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000);
  await waitFor(`document.querySelectorAll('[data-work-item-id]').length === 4`, 10000);
  const longRows = await rowSnapshots();
  const longRow = longRows.find((row) => row.title === longTitle);
  check(
    'long.titleFullTextAvailable',
    longRow !== undefined && longRow.titleAttr === longTitle,
    `titleAttr=${String(longRow?.titleAttr).slice(0, 60)}…`
  );
  await checkNoOverflow('long.noHorizontalOverflow');
  await screenshot('pending-long-title.png');

  // 13. CSP 与页面异常。
  let cspViolations = [];
  try {
    cspViolations = await evaluate(
      'Array.isArray(window.__wmCspViolations) ? window.__wmCspViolations : []'
    );
  } catch (error) {
    cspViolations = [{ error: String(error) }];
  }
  check(
    'csp.noViolations',
    Array.isArray(cspViolations) && cspViolations.length === 0,
    JSON.stringify(cspViolations)
  );
  check(
    'page.noUncaughtErrors',
    pageErrors.length === 0,
    pageErrors.map((item) => JSON.stringify(item).slice(0, 200)).join(' | ')
  );

  // 14. 供重启持久化阶段核对的数据快照（真实 IPC）。
  const finalList = await directIpc('list_pending_work_items');
  const finalProjects = await directIpc('list_projects');
  check(
    'persistence.prerequisiteState',
    finalList.ok === true &&
      finalList.value.length === 4 &&
      finalProjects.ok === true &&
      finalProjects.value.length === 2 &&
      finalProjects.value.every((project) => project.isArchived === true),
    JSON.stringify({
      workItems: finalList.value?.length,
      projects: finalProjects.value?.length
    })
  );

  fs.writeFileSync(
    path.join(outputDir, 't1-03-prerequisite.json'),
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        task: 'T1-03',
        workItems: finalList.value,
        projects: finalProjects.value,
        currentProject,
        archivedProject,
        unassignedWorkItem,
        longTitle
      },
      null,
      2
    ),
    'utf8'
  );
} catch (error) {
  check('script.completed', false, String(error));
  const diagnostics = await captureFailureDiagnostics('script-error').catch((diagnosticsError) => ({
    error: String(diagnosticsError)
  }));
  if (diagnostics?.filePath) {
    console.error(`FAILURE_DIAGNOSTICS=${diagnostics.filePath}`);
  }
  await screenshot('failure-state.png').catch(() => null);
}

const failed = checks.filter((item) => !item.pass).map((item) => item.name);
const evidence = {
  generatedAt: new Date().toISOString(),
  task: 'T1-03',
  method:
    'CDP against real Release WebView2: shell/nav assertions, real pending-view loading/empty/list states, real UI quick-create flows (unassigned + unarchived project), duplicate-submit double click, archived-project race error, direct typed IPC bypass checks, CDP transport-level fault injection for load failure/retry and bridge contract violation, long title layout, screenshots, CSP collection',
  port,
  bootMarker,
  deterministicWaits,
  target: {
    id: pageTarget.id,
    title: pageTarget.title,
    url: pageTarget.url,
    type: pageTarget.type
  },
  screenshots: fs
    .readdirSync(outputDir)
    .filter((name) => name.endsWith('.png'))
    .sort(),
  pageErrors,
  checks,
  failed,
  pass: failed.length === 0
};
const evidencePath = path.join(outputDir, 't1-03-ui-evidence.json');
fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2), 'utf8');
console.log(
  JSON.stringify(
    { evidencePath, total: checks.length, failed, pass: failed.length === 0 },
    null,
    2
  )
);

socket.close();
if (failed.length > 0) {
  console.error(`ASSERTION_FAILED: ${failed.join(', ')}`);
  process.exit(1);
}
console.log('T1_03_RELEASE_UI_CHECK=PASS');
