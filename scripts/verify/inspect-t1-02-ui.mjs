/**
 * WorkManager T1-02 项目管理 Release UI/IPC 端到端检查。
 *
 * 前提：Release 进程已用 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>`
 * 启动，且 WebView2 已加载页面。
 *
 * 本脚本通过 Chromium DevTools Protocol 操作真实 Release WebView2：
 * 1. 验证应用壳、固定侧边栏、标题栏三色窗口按钮和页面导航；
 * 2. 进入“设置 → 项目管理”，在真实异步 IPC 下验证 loading 状态、空状态；
 * 3. 通过真实 UI 操作创建 / 编辑 / 归档项目，并用直接 IPC 调用核对 Rust Core 数据；
 * 4. 构造项目已归档 → 编辑失败的真实错误路径，验证页面错误提示；
 * 5. 验证长项目名称不横向溢出、归档项目无编辑/归档操作；
 * 6. 验证数据库诊断页（T1-01 功能未破坏）与 CSP 0 违规；
 * 7. 验证三个彩色窗口按钮真实调用窗口 API（最大化/还原），并保存截图与 JSON 证据。
 *
 * 本脚本不修改产品代码；loading 状态通过 CDP CPU 限速让真实异步 IPC loading
 * 可以被稳定观察与截图，属于测试测量手段，不改变业务行为。
 *
 * 用法：node scripts/verify/inspect-t1-02-ui.mjs <port> <outputDir>
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

/**
 * 轮询等待应用状态。第四参数 stateExpression 用于超时时保留最后一次页面状态，
 * 避免只留下 “Timed out waiting for ...” 而无法定位页面当时处于 Loading / Error / 其它页面。
 */
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

function clickNav(label) {
  return clickByText('nav.sidebar', label, false);
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
      return {
        ok: false,
        error: typeof error === 'string' ? error : (error && (error.message || JSON.stringify(error))) || String(error)
      };
    }
  })()`);
}

/**
 * 确定性等待 Tauri IPC 就绪：页面壳渲染不代表 IPC/DTO 已经可用，
 * 必须在做项目管理状态断言前先确认受限命令真实可调用。
 */
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
  throw new Error(
    `Tauri IPC 未在 ${timeoutMs}ms 内就绪: ${JSON.stringify(lastProbe).slice(0, 600)}`
  );
}

/**
 * 项目管理页面的确定性终态探针：
 * - page 尚未切到“项目管理”或仍在 Loading 时返回 ready=false；
 * - Loading 结束后，一次返回空状态 / 列表 / 错误三者之一，供断言使用。
 * 这样断言不再以“某段文本是否恰好出现”作为唯一超时依据。
 */
const projectsStateExpression = `(() => {
  const main = document.querySelector('main');
  if (main === null) {
    return { mounted: false, ready: false, page: null };
  }
  const heading = ((document.querySelector('h1') || {}).textContent || '').trim();
  if (heading !== '项目管理') {
    return { mounted: true, ready: false, page: heading };
  }
  const text = main.innerText || '';
  const loading = text.includes('正在读取项目');
  const alertElement = main.querySelector('[role="alert"]');
  return {
    mounted: true,
    ready: !loading,
    page: heading,
    loading,
    empty: text.includes('暂无项目'),
    rows: document.querySelectorAll('[data-project-id]').length,
    error: alertElement !== null,
    errorText: alertElement
      ? (alertElement.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 300)
      : null
  };
})()`;

async function waitForProjectsSettled(timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let lastState = null;
  while (Date.now() < deadline) {
    try {
      lastState = await evaluate(projectsStateExpression);
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
    `Timed out waiting for: projects loading settled; lastState=${JSON.stringify(lastState).slice(0, 800)}`
  );
}

/**
 * 失败时保留页面状态、IPC、CSP/异常与截图，写入机器可读文件。
 * 这是 P3-02 要求的“超时后保留有用的页面状态、IPC 和测试日志”，不改变产品行为。
 */
async function captureFailureDiagnostics(label) {
  const diagnostics = {
    generatedAt: new Date().toISOString(),
    task: 'T1-02',
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
      bodyText: (document.body.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 1200),
      hasAppShell: document.querySelector('.app-shell') !== null,
      navCount: document.querySelectorAll('nav.sidebar button').length,
      loadingPanel: document.querySelector('.loading-panel') !== null,
      errorPanel: document.querySelector('[role="alert"]') !== null,
      projectRows: document.querySelectorAll('[data-project-id]').length,
      dialogOpen: document.querySelector('dialog[open]') !== null,
      tauriInternals: typeof window.__TAURI_INTERNALS__?.invoke === 'function'
    }))()`);
  } catch (error) {
    diagnostics.page = { error: String(error) };
  }

  try {
    diagnostics.ipc.listProjects = await directIpc('list_projects');
  } catch (error) {
    diagnostics.ipc.listProjects = { error: String(error) };
  }
  try {
    diagnostics.ipc.databaseHealth = await directIpc('get_database_health');
  } catch (error) {
    diagnostics.ipc.databaseHealth = { error: String(error) };
  }
  try {
    diagnostics.screenshot = await screenshot(`failure-${label}.png`);
  } catch {
    diagnostics.screenshot = null;
  }

  diagnostics.filePath = path.join(outputDir, `t1-02-ui-failure-${label}.json`);
  fs.writeFileSync(diagnostics.filePath, JSON.stringify(diagnostics, null, 2), 'utf8');
  return diagnostics;
}

async function setDialogInput(value) {
  return evaluate(`(() => {
    const input = document.querySelector('dialog[open] #project-name');
    if (!(input instanceof HTMLInputElement)) return false;
    input.value = ${JSON.stringify(value)};
    input.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
  })()`);
}

async function projectRows() {
  return evaluate(`(() => Array.from(document.querySelectorAll('[data-project-id]')).map((row) => ({
    id: row.getAttribute('data-project-id'),
    text: (row.innerText || '').replace(/\\s+/g, ' ').trim(),
    hasEdit: Array.from(row.querySelectorAll('button')).some((b) => (b.textContent || '').trim() === '编辑'),
    hasArchive: Array.from(row.querySelectorAll('button')).some((b) => (b.textContent || '').trim() === '归档'),
    hasArchivedBadge: (row.innerText || '').includes('已归档'),
    titleAttr: (() => {
      const name = row.querySelector('.project-name');
      return name ? name.getAttribute('title') : null;
    })()
  })))()`);
}

async function clickRowAction(projectId, label) {
  return evaluate(`(() => {
    const wantedId = ${JSON.stringify(projectId)};
    const wantedLabel = ${JSON.stringify(label)};
    const row = Array.from(document.querySelectorAll('[data-project-id]')).find(
      (item) => item.getAttribute('data-project-id') === wantedId
    );
    if (!row) return false;
    const button = Array.from(row.querySelectorAll('button')).find(
      (item) => (item.textContent || '').trim() === wantedLabel
    );
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`);
}

await send('Runtime.enable');
await send('Page.enable');
await send('Log.enable');

// 确定 reload 后的新文档身份：addScriptToEvaluateOnNewDocument 只注入新文档，
// 因此 boot marker 匹配即证明后续断言不在“旧文档尚未被 reload 替换”的窗口中执行。
const bootMarker = `wm-t1-02-${Date.now()}-${Math.random().toString(16).slice(2)}`;

// CSP 收集器与 boot marker 都必须在页面加载前注入；随后重载页面并等待应用壳渲染。
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

// 先等待当前文档加载完成再主动 reload，避免在首次加载尚未稳定时发出 reload。
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

try {
  await waitFor(
    `window.__wmBootMarker === ${JSON.stringify(bootMarker)} && document.readyState === 'complete'`,
    30000,
    'reloaded document boot marker',
    bootStateExpression
  );
  deterministicWaits.push('page.reloadNewDocumentBootMarker');

  await waitFor(
    `document.querySelector('.app-shell') !== null && document.querySelectorAll('nav button').length === 6 && typeof window.__TAURI_INTERNALS__?.invoke === 'function'`,
    30000,
    'app shell rendered in reloaded document',
    bootStateExpression
  );
  deterministicWaits.push('appShell.renderedWithTauriInternals');

  await waitForIpcReady(20000);
  deterministicWaits.push('ipc.databaseHealthReady');

  await sleep(300);
  check('shell.rendered', true);

  // 1. 应用壳 / 导航 / 标题栏。
  const shell = await evaluate(`(() => ({
    title: document.title,
    appName: (document.querySelector('.window-titlebar__app-name') || {}).textContent || null,
    windowControls: Array.from(document.querySelectorAll('.window-control')).map((button) => ({
      label: button.getAttribute('aria-label'),
      title: button.getAttribute('title')
    })),
    navLabels: Array.from(document.querySelectorAll('nav.sidebar button')).map((item) =>
      (item.textContent || '').replace(/\\s+/g, ' ').trim()
    ),
    heading: (document.querySelector('h1') || {}).textContent || null,
    activeNav: (document.querySelector('nav.sidebar [aria-current="page"]') || {}).textContent || null,
    titlebarStatus: ((document.querySelector('.window-titlebar [role="status"]') || {}).textContent || '').trim(),
    windowControlsEnabled: Array.from(document.querySelectorAll('.window-control')).every(
      (button) => button.disabled === false
    )
  }))()`);
  check('shell.titlebarAppName', shell.appName === 'WorkManager');
  check(
    'shell.threeWindowControls',
    shell.windowControls.length === 3 &&
      shell.windowControls[0].label === '关闭 WorkManager' &&
      shell.windowControls[1].label === '最小化窗口' &&
      shell.windowControls[2].label === '最大化窗口',
    JSON.stringify(shell.windowControls)
  );
  check('shell.windowControlsEnabled', shell.windowControlsEnabled === true);
  check('shell.titlebarNoActionError', shell.titlebarStatus.length === 0, shell.titlebarStatus);
  check(
    'shell.sidebarNavigation',
    shell.navLabels.length === 6 &&
      shell.navLabels.includes('工作总览') &&
      shell.navLabels.includes('今日工作') &&
      shell.navLabels.includes('设置'),
    shell.navLabels.join(' / ')
  );
  check('shell.defaultOverview', (shell.heading || '').trim() === '工作总览');
  check('shell.overviewActiveNav', (shell.activeNav || '').includes('工作总览'));
  await checkNoOverflow('shell.noHorizontalOverflow');
  await screenshot('overview-normal.png');

  // 2. 今日工作 / 设置页面结构回归。
  check('nav.todayClicked', (await clickNav('今日工作')) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '今日工作'`, 5000);
  check(
    'today.pageRendered',
    (await evaluate(`(document.querySelector('h1') || {}).textContent`)) === '今日工作'
  );
  await checkNoOverflow('today.noHorizontalOverflow');
  await screenshot('today-normal.png');

  check('nav.settingsClicked', (await clickNav('设置')) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '设置'`, 5000);
  const settingsText = await evaluate(
    `document.querySelector('main').innerText.replace(/\\s+/g, ' ')`
  );
  check(
    'settings.pageRendered',
    settingsText.includes('项目管理') && settingsText.includes('数据库健康检查')
  );
  await checkNoOverflow('settings.noHorizontalOverflow');
  await screenshot('settings-normal.png');

  // 3. loading 状态：用 CDP CPU 限速放慢渲染线程，使真实的异步 IPC loading
  //    状态可以被稳定观察与截图；点击后在同一个执行上下文内核实 loading 出现。
  //    这是测量手段，不改变生产代码或业务行为。
  await send('Emulation.setCPUThrottlingRate', { rate: 20 });
  await sleep(300);
  const loadingProbe = await evaluate(`(async () => {
    const button = Array.from(document.querySelectorAll('main button')).find((item) =>
      (item.textContent || '').includes('打开项目管理')
    );
    if (!button) return { clicked: false, loading: false };
    button.click();
    await new Promise((resolve) => queueMicrotask(resolve));
    return {
      clicked: true,
      loading: document.body.innerText.includes('正在读取项目'),
      statusCount: document.querySelectorAll('[role="status"]').length,
      heading: (document.querySelector('h1') || {}).textContent || null
    };
  })()`);
  check('projects.openViaSettings', loadingProbe.clicked === true);
  check(
    'projects.loadingStateVisible',
    loadingProbe.loading === true &&
      loadingProbe.statusCount >= 1 &&
      loadingProbe.heading === '项目管理',
    JSON.stringify(loadingProbe)
  );
  if (loadingProbe.loading) {
    await screenshot('projects-loading.png');
  }
  await send('Emulation.setCPUThrottlingRate', { rate: 1 });

  // P3-02：不再直接等待“暂无项目”文本出现，而是先等待项目管理页面 Loading
  // 确定性结束，再断言空状态；若终态是错误或列表，会带着页面状态失败。
  const projectsState = await waitForProjectsSettled(20000);
  deterministicWaits.push('projectsPage.loadingSettled');
  check(
    'projects.emptyStateRendered',
    projectsState.empty === true,
    JSON.stringify(projectsState)
  );
  check(
    'projects.emptyStateCreateAction',
    (await evaluate(
      `Array.from(document.querySelectorAll('main button')).some((b) => (b.textContent || '').trim() === '创建第一个项目')`
    )) === true
  );
  await checkNoOverflow('projects.emptyNoHorizontalOverflow');
  await screenshot('projects-empty.png');

  // 4. 直接 IPC：确认命令真实可用且不存在任意 SQL IPC。
  const emptyList = await directIpc('list_projects');
  check(
    'ipc.listProjectsEmpty',
    emptyList.ok === true && Array.isArray(emptyList.value) && emptyList.value.length === 0,
    JSON.stringify(emptyList).slice(0, 300)
  );

  const health = await directIpc('get_database_health');
  const healthDatabase = health.ok === true ? health.value?.database : null;
  check('ipc.diagnosticsAlive', health.ok === true && healthDatabase?.status === 'ok');
  check('ipc.schemaVersion3', healthDatabase?.schemaVersion === 3);
  check(
    'ipc.migrations1To3',
    Array.isArray(healthDatabase?.appliedMigrations) &&
      healthDatabase.appliedMigrations.length === 3 &&
      healthDatabase.appliedMigrations[0]?.version === 1 &&
      healthDatabase.appliedMigrations[1]?.version === 2 &&
      healthDatabase.appliedMigrations[2]?.version === 3
  );
  check('ipc.integrityOk', healthDatabase?.integrityCheck === 'ok');

  const arbitrarySql = await directIpc('execute_sql', { sql: 'SELECT 1' });
  check(
    'ipc.noArbitrarySqlCommand',
    arbitrarySql.ok === false,
    String(arbitrarySql.error ?? '').slice(0, 200)
  );

  // 5. 通过真实 UI 创建第一个项目。
  check('projects.createDialogOpened', (await clickByText('main', '新建项目', false)) === true);
  await waitFor(`document.querySelector('dialog[open]') !== null`, 5000);
  check(
    'projects.createDialogRendered',
    await evaluate(`(document.querySelector('dialog[open]') || {}).innerText.includes('新建项目')`)
  );
  check('projects.createInputFilled', (await setDialogInput('T1-02 验收项目')) === true);
  check('projects.createSubmitted', (await clickByText('dialog[open]', '创建项目')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000, 'create dialog closed');
  await waitFor(`document.querySelectorAll('[data-project-id]').length === 1`, 10000);
  check(
    'projects.createRowVisible',
    await evaluate(`document.querySelector('[data-project-id]').innerText.includes('T1-02 验收项目')`)
  );
  const afterCreate = await directIpc('list_projects');
  check(
    'ipc.createPersisted',
    afterCreate.ok === true &&
      afterCreate.value.length === 1 &&
      afterCreate.value[0].name === 'T1-02 验收项目' &&
      afterCreate.value[0].isArchived === false,
    JSON.stringify(afterCreate.value).slice(0, 300)
  );
  const shortProject = afterCreate.value[0];

  // 6. 长项目名称：不横向溢出，且可查看完整名称（title 属性）。
  const longName =
    '超长项目名称用于验证项目管理列表布局不会横向溢出也不会撑破窗口' +
    '——这是第二段用于增加长度的虚构项目名称内容——' +
    'T1-02-LONG-PROJECT-NAME-0123456789-ABCDEFGHIJ';
  check('projects.longCreateDialogOpened', (await clickByText('main', '新建项目', false)) === true);
  await waitFor(`document.querySelector('dialog[open]') !== null`, 5000);
  check('projects.longInputFilled', (await setDialogInput(longName)) === true);
  check('projects.longSubmitted', (await clickByText('dialog[open]', '创建项目')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000);
  await waitFor(`document.querySelectorAll('[data-project-id]').length === 2`, 10000);
  const rowsWithLong = await projectRows();
  const longRow = rowsWithLong.find((row) => row.text.includes('超长项目名称'));
  check(
    'projects.longNameFullTitleAvailable',
    longRow !== undefined && longRow.titleAttr === longName,
    `title=${String(longRow?.titleAttr).slice(0, 40)}…`
  );
  await checkNoOverflow('projects.longNameNoHorizontalOverflow');
  await screenshot('projects-list.png');

  const afterLong = await directIpc('list_projects');
  const longProject = afterLong.value.find((project) => project.name === longName);
  check('ipc.longNamePersisted', longProject !== undefined && afterLong.value.length === 2);

  // 7. 通过真实 UI 编辑项目名称。
  check('projects.editActionClicked', (await clickRowAction(shortProject.id, '编辑')) === true);
  await waitFor(`document.querySelector('dialog[open] #project-name') !== null`, 5000);
  const editPrefill = await evaluate(`document.querySelector('dialog[open] #project-name').value`);
  check('projects.editDialogPrefilled', editPrefill === 'T1-02 验收项目');
  check('projects.editInputChanged', (await setDialogInput('T1-02 验收项目（已编辑）')) === true);
  check('projects.editSubmitted', (await clickByText('dialog[open]', '保存修改')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000);
  await waitFor(
    `Array.from(document.querySelectorAll('[data-project-id]')).some((row) => row.innerText.includes('T1-02 验收项目（已编辑）'))`,
    10000
  );
  check('projects.editRowUpdated', true);
  const afterEdit = await directIpc('list_projects');
  const editedProject = afterEdit.value.find((project) => project.id === shortProject.id);
  check(
    'ipc.editPersisted',
    editedProject !== undefined && editedProject.name === 'T1-02 验收项目（已编辑）',
    JSON.stringify(editedProject)
  );

  // 8. 通过真实 UI 归档项目（确认弹窗 + 归档后操作消失）。
  check('projects.archiveActionClicked', (await clickRowAction(longProject.id, '归档')) === true);
  await waitFor(`document.querySelector('dialog[open]') !== null`, 5000);
  const confirmText = await evaluate(
    `document.querySelector('dialog[open]').innerText.replace(/\\s+/g, ' ')`
  );
  check(
    'projects.archiveConfirmExplainsNonDestructive',
    confirmText.includes('归档项目') &&
      confirmText.includes('不会删除') &&
      confirmText.includes(longName)
  );
  await screenshot('projects-archive-confirm.png');
  check('projects.archiveConfirmed', (await clickByText('dialog[open]', '归档项目')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 10000);
  await waitFor(
    `Array.from(document.querySelectorAll('[data-project-id]')).some((row) => row.getAttribute('data-project-id') === ${JSON.stringify(longProject.id)} && row.innerText.includes('已归档'))`,
    10000
  );
  const rowsAfterArchive = await projectRows();
  const archivedRow = rowsAfterArchive.find((row) => row.id === longProject.id);
  check('projects.archivedBadgeVisible', archivedRow?.hasArchivedBadge === true);
  check(
    'projects.archivedRowHasNoEditOrArchive',
    archivedRow?.hasEdit === false && archivedRow?.hasArchive === false
  );
  const afterArchive = await directIpc('list_projects');
  const archivedFromIpc = afterArchive.value.find((project) => project.id === longProject.id);
  check(
    'ipc.archivePersistedWithoutDeleting',
    archivedFromIpc !== undefined &&
      archivedFromIpc.isArchived === true &&
      afterArchive.value.length === 2,
    JSON.stringify(archivedFromIpc)
  );
  await checkNoOverflow('projects.archivedNoHorizontalOverflow');
  await screenshot('projects-archived.png');

  // 9. 真实错误状态：编辑对话框打开期间项目被归档，保存时必须显示明确错误。
  check('projects.errorScenarioEditOpened', (await clickRowAction(shortProject.id, '编辑')) === true);
  await waitFor(`document.querySelector('dialog[open] #project-name') !== null`, 5000);
  const archivedBehindUi = await directIpc('archive_project', {
    input: { id: shortProject.id }
  });
  check('projects.errorScenarioArchiveViaIpc', archivedBehindUi.ok === true);
  check(
    'projects.errorScenarioSaveClicked',
    (await clickByText('dialog[open]', '保存修改')) === true
  );
  await waitFor(`document.querySelector('dialog[open] [role="alert"]') !== null`, 8000, 'dialog error alert');
  const errorText = await evaluate(
    `document.querySelector('dialog[open] [role="alert"]').innerText.replace(/\\s+/g, ' ')`
  );
  check('projects.errorStateVisible', errorText.includes('已归档') || errorText.includes('归档'));
  check('projects.errorDialogStillOpen', await evaluate(`document.querySelector('dialog[open]') !== null`));
  await screenshot('projects-error.png');
  check('projects.errorDialogCancelled', (await clickByText('dialog[open]', '取消')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 5000);

  // 刷新列表，确认两个项目都已归档且仍然存在。
  check('projects.refreshViaSettings', (await clickNav('设置')) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '设置'`, 5000);
  check('projects.reopenProjects', (await clickByText('main', '打开项目管理', false)) === true);
  await waitFor(`document.querySelectorAll('[data-project-id]').length === 2`, 10000);
  const finalRows = await projectRows();
  check(
    'projects.archivedRecordsStillExistAfterReload',
    finalRows.length === 2 && finalRows.every((row) => row.hasArchivedBadge)
  );

  // 10. 数据库诊断页（T1-01 功能未破坏）。
  check('diagnostics.navigateSettings', (await clickNav('设置')) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '设置'`, 5000);
  check('diagnostics.open', (await clickByText('main', '打开数据库诊断', false)) === true);
  await waitFor(`document.body.innerText.includes('正常（ok）')`, 12000, 'diagnostics health rendered');
  const diagnostics = await evaluate(`(() => ({
    heading: (document.querySelector('h1') || {}).textContent,
    badges: Array.from(document.querySelectorAll('.badge')).map((badge) =>
      badge.innerText.replace(/\\s+/g, ' ').trim()
    ),
    pathValues: Array.from(document.querySelectorAll('.path-value')).map((item) => item.innerText.trim()),
    migrationRows: Array.from(document.querySelectorAll('table tbody tr')).map((row) =>
      Array.from(row.querySelectorAll('td')).map((cell) => cell.innerText.trim())
    ),
    note: (document.querySelector('.diagnostic-note') || {}).textContent || null,
    hasAlert: document.querySelector('[role="alert"]') !== null
  }))()`);
  check('diagnostics.heading', (diagnostics.heading || '').trim() === '数据库诊断');
  check('diagnostics.healthOk', diagnostics.badges.some((badge) => badge.includes('正常（ok）')));
  check('diagnostics.noErrorAlert', diagnostics.hasAlert === false);
  check('diagnostics.threePortablePaths', diagnostics.pathValues.length === 3);
  check(
    'diagnostics.migrationRows',
    diagnostics.migrationRows.length === 3 &&
      diagnostics.migrationRows[0][0] === '1' &&
      diagnostics.migrationRows[1][0] === '2' &&
      diagnostics.migrationRows[2][0] === '3'
  );
  check('diagnostics.unencryptedNote', (diagnostics.note || '').includes('未加密'));
  await checkNoOverflow('diagnostics.noHorizontalOverflow');
  await screenshot('diagnostics.png');

  // 11. 三色窗口按钮必须调用真实窗口 API：最大化 → 视口变化 → 还原。
  const widthBefore = await evaluate('window.innerWidth');
  const maximizeClicked = await evaluate(`(() => {
    const button = document.querySelector('.window-control--maximize');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`);
  await sleep(900);
  const widthMaximized = await evaluate('window.innerWidth');
  check(
    'titlebar.maximizeCallsRealWindowApi',
    maximizeClicked === true && widthMaximized > widthBefore + 40,
    `${widthBefore} → ${widthMaximized}`
  );
  const restoreClicked = await evaluate(`(() => {
    const button = document.querySelector('.window-control--maximize');
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`);
  await sleep(900);
  const widthRestored = await evaluate('window.innerWidth');
  check(
    'titlebar.restoreCallsRealWindowApi',
    restoreClicked === true && Math.abs(widthRestored - widthBefore) <= 40,
    `${widthMaximized} → ${widthRestored} (before ${widthBefore})`
  );

  // 12. CSP 与页面异常。
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
    pageErrors.map((item) => JSON.stringify(item).slice(0, 160)).join(' | ')
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
  task: 'T1-02',
  method:
    'CDP against real Release WebView2: shell/DOM assertions, real UI create/edit/archive flows, direct typed Tauri IPC checks, CPU-throttled real loading state capture, screenshots, CSP collection, maximize/restore window API check',
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
const evidencePath = path.join(outputDir, 't1-02-ui-evidence.json');
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
console.log('T1_02_RELEASE_UI_CHECK=PASS');
