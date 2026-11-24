/**
 * WorkManager T1-04 多项目独立副本创建 Release UI + IPC 端到端检查。
 *
 * 前提：Release 进程已用 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>`
 * 启动，且 WebView2 已加载页面（独立 UAT 便携目录，数据库为空）。
 *
 * 本脚本通过 Chromium DevTools Protocol 操作真实 Release WebView2：
 * 1. 应用壳/固定六个一级导航不变，待安排为今日工作页次级视图；
 * 2. 多项目选择对话框：选择计数、预计创建数量、0/1/2+ 三种创建语义；
 * 3. 真实 UI 两项目批量创建 → 2 条独立副本；三项目批量创建 → 3 条独立副本；
 * 4. T1-03 回归：未归属创建、单项目创建、归档项目历史关联展示；
 * 5. 对话框打开后项目被归档 → project-archived，整批失败、无部分记录、
 *    失效选择保留且不自动移除；
 * 6. 绕过 UI 直接 IPC：归档项目/不存在项目/重复项目/少于两个项目/空标题/未知字段拒绝；
 * 7. 批量创建期间重复点击保护与选择锁定（CDP 传输层延迟注入，不改产品代码）；
 * 8. Bridge 严格契约：伪造非法批量响应被 UI 捕获为 ipc-contract-violation；
 * 9. 创建成功但列表刷新失败：显示实际创建数量 warning，不重复创建，重新加载后恢复；
 * 10. CSP 违规 0、页面未捕获异常 0、正常窗口无横向溢出；截图与机器可读证据。
 *
 * 本脚本创建的数据保留给“失败原子回滚”与“重启持久化”检查阶段使用。
 *
 * 用法：node scripts/verify/inspect-t1-04-ui.mjs <port> <outputDir>
 */

import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? '9355');
const outputDir = process.argv[3] ?? `D:\\WorkManager-test-data\\t1-04-ui-${Date.now()}`;
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
        right: Math.round(rect.right),
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
 * CDP 传输层故障注入（不改产品代码）：
 * - command 匹配指定 IPC 命令；
 * - mode: 'reject' 返回 Tauri 错误载荷；'malformed' 返回非法成功载荷；
 *   'delay' 真实转发并延迟 delayMs。
 */
async function installIpcFault(command, mode, delayMs = 0) {
  return evaluate(`(() => {
    if (typeof window.__wmOriginalFetch !== 'function') {
      window.__wmOriginalFetch = window.fetch.bind(window);
    }
    window.__wmFaultCommand = ${JSON.stringify(command)};
    window.__wmFaultMode = ${JSON.stringify(mode)};
    window.__wmFaultDelayMs = ${Number(delayMs)};
    if (!window.__wmFaultFetchInstalled) {
      window.__wmFaultFetchInstalled = true;
      window.fetch = function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        workmanager_fault: {
          if (url.indexOf(window.__wmFaultCommand) === -1 || window.__wmFaultMode === 'off') {
            break workmanager_fault;
          }
          if (window.__wmFaultMode === 'reject') {
            return Promise.resolve(new Response(JSON.stringify({
              code: 'ipc-command-failed',
              message: '模拟 IPC 命令失败'
            }), {
              status: 200,
              headers: { 'Content-Type': 'application/json', 'Tauri-Response': 'error' }
            }));
          }
          if (window.__wmFaultMode === 'malformed') {
            return Promise.resolve(new Response(JSON.stringify({
              groupId: 'invalid-group-id',
              workItems: []
            }), {
              status: 200,
              headers: { 'Content-Type': 'application/json', 'Tauri-Response': 'ok' }
            }));
          }
          if (window.__wmFaultMode === 'delay') {
            return new Promise((resolve) => {
              setTimeout(() => resolve(window.__wmOriginalFetch(input, init)), window.__wmFaultDelayMs);
            });
          }
        }
        return window.__wmOriginalFetch(input, init);
      };
    }
    return true;
  })()`);
}

async function clearIpcFault() {
  return evaluate(`(() => {
    window.__wmFaultMode = 'off';
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
      lastProbe.value?.database?.schemaVersion === 4
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
  const refreshing = text.includes('正在同步待安排列表');
  const alertElement = main.querySelector('[role="alert"]');
  return {
    mounted: true,
    ready: !loading && !refreshing,
    heading,
    loading,
    refreshing,
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

async function remountPendingViewAndSettle() {
  await clickSwitcher('今日工作');
  await waitFor(
    `document.querySelector('#pending-work-title') === null`,
    8000,
    'pending view unmounted'
  );
  await clickSwitcher('待安排');
  return waitForPendingSettled(20000);
}

async function rowSnapshots() {
  return evaluate(`(() => Array.from(document.querySelectorAll('[data-work-item-id]')).map((row) => ({
    id: row.getAttribute('data-work-item-id'),
    title: ((row.querySelector('.work-item-title') || {}).textContent || '').trim(),
    meta: ((row.querySelector('.work-item-meta') || {}).innerText || '').replace(/\\s+/g, ' ').trim(),
    hasArchivedBadge: row.innerText.includes('项目已归档')
  })))()`);
}

async function createOutcomeNotice() {
  return evaluate(`(() => {
    const element = document.querySelector('[data-create-outcome]');
    if (element === null) return null;
    return {
      kind: element.getAttribute('data-create-outcome'),
      text: (element.innerText || '').replace(/\\s+/g, ' ').trim()
    };
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

/** 多项目复选框选择快照（用于断言选择数量、预计数量、失效选择与模式）。 */
async function dialogSnapshot() {
  return evaluate(`(() => {
    const dialog = document.querySelector('dialog[open]');
    if (dialog === null) return null;
    const selected = dialog.querySelector('[data-selected-project-count]');
    const expected = dialog.querySelector('[data-expected-copy-count]');
    const projectInputs = Array.from(dialog.querySelectorAll('input[data-project-id]'));
    const unassigned = dialog.querySelector('input[data-project-unassigned]');
    return {
      mode: dialog.getAttribute('data-create-mode'),
      selectedCount: selected === null ? null : Number(selected.getAttribute('data-selected-project-count')),
      expectedCount: expected === null ? null : Number(expected.getAttribute('data-expected-copy-count')),
      summaryText: selected === null ? null : (selected.textContent || '').replace(/\\s+/g, ' ').trim(),
      availableProjectIds: projectInputs.map((input) => input.getAttribute('data-project-id')),
      checkedProjectIds: projectInputs
        .filter((input) => input.checked)
        .map((input) => input.getAttribute('data-project-id')),
      unassignedChecked: unassigned === null ? null : unassigned.checked,
      invalidSelectionCount: dialog.querySelectorAll(
        '[data-invalid-project-selections] .invalid-selection__item'
      ).length,
      controlsDisabled: {
        title: (() => { const el = dialog.querySelector('#work-item-title'); return el ? el.disabled : null; })(),
        projectInputs: projectInputs.length > 0 ? projectInputs.every((input) => input.disabled) : null,
        save: (() => {
          const button = Array.from(dialog.querySelectorAll('button')).find(
            (item) => (item.textContent || '').trim() === '保存'
          );
          return button ? button.disabled : null;
        })()
      }
    };
  })()`);
}

async function waitForDialogProjectOptions(projectIds, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await dialogSnapshot();
    if (last !== null && projectIds.every((projectId) => last.availableProjectIds.includes(projectId))) {
      return last;
    }
    await sleep(100);
  }
  throw new Error(
    `Timed out waiting for dialog project options ${JSON.stringify(projectIds)}; last=${JSON.stringify(last)}`
  );
}

async function waitForSelection(selectedCount, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await dialogSnapshot();
    if (last !== null && last.selectedCount === selectedCount) {
      return last;
    }
    await sleep(100);
  }
  throw new Error(
    `Timed out waiting for dialog selection count ${selectedCount}; last=${JSON.stringify(last)}`
  );
}

async function clickProjectCheckbox(projectId) {
  return evaluate(`(() => {
    const input = document.querySelector('dialog[open] input[data-project-id="${projectId}"]');
    if (!(input instanceof HTMLInputElement)) return false;
    if (!input.checked) input.click();
    return true;
  })()`);
}

async function clickInvalidSelectionRemove() {
  return evaluate(`(() => {
    const button = document.querySelector(
      'dialog[open] [data-invalid-project-selections] .invalid-selection__remove'
    );
    if (!button) return false;
    button.click();
    return true;
  })()`);
}

async function openCreateDialog() {
  check('dialog.openFromToolbar', (await clickByText('main', '新增工作', false)) === true);
  await waitFor(`document.querySelector('dialog[open] #work-item-title') !== null`, 5000);
}

async function closeDialogByCancel() {
  check('dialog.cancel', (await clickByText('dialog[open]', '取消')) === true);
  await waitFor(`document.querySelector('dialog[open]') === null`, 5000);
}

async function submitDialogSave() {
  return clickByText('dialog[open]', '保存', true);
}

async function waitDialogClosed(timeoutMs = 15000) {
  return waitFor(`document.querySelector('dialog[open]') === null`, timeoutMs, 'create dialog closed');
}

async function waitForRows(expectedRows, timeoutMs = 15000) {
  return waitFor(
    `document.querySelectorAll('[data-work-item-id]').length === ${expectedRows}`,
    timeoutMs,
    `pending rows === ${expectedRows}`,
    pendingStateExpression
  );
}

const fixturePrefix = 'T1-04 虚构';
const titles = {
  batchTwo: 'T1-04 虚构 两项目价格异常排查',
  batchThree: 'T1-04 虚构 三项目进度同步',
  unassigned: 'T1-04 虚构 未归属快速工作',
  single: 'T1-04 虚构 单项目快速工作',
  duplicate: 'T1-04 虚构 重复提交批次工作',
  archivedLink: 'T1-04 虚构 归档项目历史关联工作',
  archiveRace: 'T1-04 虚构 归档竞态不应创建',
  contractViolation: 'T1-04 虚构 契约违规不应创建',
  refreshFailure: 'T1-04 虚构 刷新失败批次工作',
  bypass: 'T1-04 虚构 绕过 UI 的批量请求'
};
const backup = { pendingAfterMain: 12, groupsAfterMain: 4, membersAfterMain: 9 };

await send('Runtime.enable');
await send('Page.enable');
await send('Log.enable');

const bootMarker = `wm-t1-04-${Date.now()}-${Math.random().toString(16).slice(2)}`;
await send('Page.addScriptToEvaluateOnNewDocument', {
  source: `window.__wmBootMarker = ${JSON.stringify(bootMarker)};
window.__wmCspViolations = [];
document.addEventListener('securitypolicyviolation', (event) => {
  window.__wmCspViolations.push({
    blockedURI: event.blockedURI,
    violatedDirective: event.violatedDirective,
    sample: event.sample
  });
});`
});

await waitFor(
  `document.readyState === 'complete'`,
  15000,
  'initial document readyState complete'
).catch(() => null);
await send('Page.reload', { ignoreCache: true });

let projects = {};
let archivedLinkItem = null;

function writeEvidence(extra = {}) {
  const failed = checks.filter((item) => !item.pass).map((item) => item.name);
  const cspViolations = null;
  const evidence = {
    generatedAt: new Date().toISOString(),
    task: 'T1-04',
    method:
      'CDP against real Release WebView2: real UI batch creation, direct IPC bypass checks, transport-layer fault injection (no product code changes), screenshots, CSP/exception capture',
    port,
    outputDir,
    target: { id: pageTarget.id, title: pageTarget.title, url: pageTarget.url },
    checks,
    failed,
    checkCount: checks.length,
    pageExceptionCount: pageErrors.filter((item) => item.type === 'exception').length,
    pageErrors,
    cspViolations,
    fixtures: { prefix: fixturePrefix, titles },
    projects,
    archivedLinkItemId: archivedLinkItem?.id ?? null,
    backup,
    pass: failed.length === 0,
    ...extra
  };
  const evidencePath = path.join(outputDir, 't1-04-ui-evidence.json');
  fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2), 'utf8');
  return evidencePath;
}

function writePrerequisite() {
  const prerequisite = {
    task: 'T1-04',
    generatedAt: new Date().toISOString(),
    outputDir,
    port,
    projects,
    titles,
    pendingAfterMain: backup.pendingAfterMain,
    groupsAfterMain: backup.groupsAfterMain,
    membersAfterMain: backup.membersAfterMain,
    archivedLinkItemId: archivedLinkItem?.id ?? null,
    expectedGroupTitles: [titles.batchTwo, titles.batchThree, titles.duplicate, titles.refreshFailure]
  };
  const prerequisitePath = path.join(outputDir, 't1-04-prerequisite.json');
  fs.writeFileSync(prerequisitePath, JSON.stringify(prerequisite, null, 2), 'utf8');
  return prerequisitePath;
}

try {
  await waitFor(
    `window.__wmBootMarker === ${JSON.stringify(bootMarker)} && document.readyState === 'complete'`,
    30000,
    'boot marker after reload',
    `({ readyState: document.readyState, hasAppShell: document.querySelector('.app-shell') !== null })`
  );
  await waitForIpcReady(20000);

  // 1. 应用壳 / 固定六个一级导航（不新增一级导航）。
  const shell = await evaluate(`(() => ({
    title: document.title,
    appName: (document.querySelector('.window-titlebar__app-name') || {}).textContent || null,
    navLabels: Array.from(document.querySelectorAll('nav.sidebar button')).map((item) =>
      (item.textContent || '').replace(/\\s+/g, ' ').trim()
    )
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

  // 2. 今日工作 → 待安排次级视图。
  check('nav.todayClicked', (await clickNav('今日工作')) === true);
  await waitFor(`(document.querySelector('h1') || {}).textContent === '今日工作'`, 5000);
  const switcher = await evaluate(`(() => ({
    labels: Array.from(document.querySelectorAll('.view-switcher button')).map((item) =>
      (item.textContent || '').replace(/\\s+/g, ' ').trim()
    )
  }))()`);
  check(
    'today.secondarySwitcherRendered',
    switcher.labels.length === 2 &&
      switcher.labels[0] === '今日工作' &&
      switcher.labels[1] === '待安排',
    JSON.stringify(switcher)
  );
  check('pending.entryClicked', (await clickSwitcher('待安排')) === true);
  const emptyState = await waitForPendingSettled(20000);
  check('pending.emptyStateRendered', emptyState.empty === true, JSON.stringify(emptyState));
  await screenshot('pending-empty.png');

  // 3. 创建两个虚构未归档项目。
  const projectA = await directIpc('create_project', {
    input: { name: `${fixturePrefix}未归档项目甲` }
  });
  const projectB = await directIpc('create_project', {
    input: { name: `${fixturePrefix}未归档项目乙` }
  });
  check(
    'setup.twoProjectsCreated',
    projectA.ok === true && projectB.ok === true,
    JSON.stringify({ a: projectA.ok, b: projectB.ok })
  );
  projects = {
    A: { id: projectA.value.id, name: `${fixturePrefix}未归档项目甲` },
    B: { id: projectB.value.id, name: `${fixturePrefix}未归档项目乙` }
  };

  // 4. 多项目选择对话框：初始状态、选择计数、预计创建数量。
  await openCreateDialog();
  check(
    'dialog.noLegacySingleSelect',
    (await evaluate(`document.querySelector('dialog[open] #work-item-project') === null`)) === true,
    '原单项目 select 已替换为多项目选择'
  );
  const initialDialog = await waitForDialogProjectOptions([projects.A.id, projects.B.id]);
  check(
    'dialog.multiSelectRendered',
    initialDialog.availableProjectIds.length === 2 &&
      (await evaluate(
        `document.querySelectorAll('dialog[open] #work-item-project-options input[data-project-id]').length === 2`
      )) === true,
    JSON.stringify(initialDialog)
  );
  check(
    'dialog.initialSelectionSummary',
    initialDialog.mode === 'unassigned' &&
      initialDialog.selectedCount === 0 &&
      initialDialog.expectedCount === 1 &&
      initialDialog.unassignedChecked === true &&
      (initialDialog.summaryText ?? '').includes('未归属工作'),
    JSON.stringify(initialDialog)
  );

  check('dialog.titleFilledForTwoProjects', (await setDialogTitle(titles.batchTwo)) === true);
  check(
    'dialog.selectProjectA',
    (await clickProjectCheckbox(projects.A.id)) === true
  );
  await waitForSelection(1);
  check(
    'dialog.selectProjectB',
    (await clickProjectCheckbox(projects.B.id)) === true
  );
  const twoSelected = await waitForSelection(2);
  check(
    'dialog.twoProjectSelectionSummary',
    twoSelected.mode === 'copies' &&
      twoSelected.expectedCount === 2 &&
      (twoSelected.summaryText ?? '').includes('2 项独立工作'),
    JSON.stringify(twoSelected)
  );
  await screenshot('create-dialog-multi-projects.png');
  check('dialog.savedTwoProjects', (await submitDialogSave()) === true);
  await waitDialogClosed();
  await waitForRows(2);
  let outcome = await createOutcomeNotice();
  check(
    'create.twoProjectOutcomeShowsActualCount',
    outcome !== null && outcome.kind === 'success' && outcome.text.includes('已创建 2 项'),
    JSON.stringify(outcome)
  );
  const pendingAfterTwo = await waitForPendingSettled(15000);
  check('create.twoProjectRows', pendingAfterTwo.rows === 2, JSON.stringify(pendingAfterTwo));
  const twoCopies = await directIpc('list_pending_work_items');  const twoCopyItems = twoCopies.ok === true ? twoCopies.value.filter((item) => item.title === titles.batchTwo) : [];
  check(
    'create.twoProjectIndependentCopies',
    twoCopyItems.length === 2 &&
      new Set(twoCopyItems.map((item) => item.id)).size === 2 &&
      twoCopyItems.every((item) => item.lifecycleStatus === 'pending') &&
      twoCopyItems.map((item) => item.projectId).sort().join(',') ===
        [projects.A.id, projects.B.id].sort().join(','),
    JSON.stringify(twoCopyItems)
  );
  await screenshot('pending-two-project-copies.png');

  // 5. 三项目批量创建。
  const projectC = await directIpc('create_project', {
    input: { name: `${fixturePrefix}未归档项目丙` }
  });
  check('setup.thirdProjectCreated', projectC.ok === true);
  projects.C = { id: projectC.value.id, name: `${fixturePrefix}未归档项目丙` };

  await openCreateDialog();
  await waitForDialogProjectOptions([projects.A.id, projects.B.id, projects.C.id]);
  check('dialog.titleFilledForThreeProjects', (await setDialogTitle(titles.batchThree)) === true);
  for (const projectId of [projects.A.id, projects.B.id, projects.C.id]) {
    check('dialog.selectThreeProject', (await clickProjectCheckbox(projectId)) === true, projectId);
  }
  const threeSelected = await waitForSelection(3);
  check(
    'dialog.threeProjectSelectionSummary',
    threeSelected.expectedCount === 3 && threeSelected.mode === 'copies',
    JSON.stringify(threeSelected)
  );
  check('dialog.savedThreeProjects', (await submitDialogSave()) === true);
  await waitDialogClosed();
  await waitForRows(5);
  outcome = await createOutcomeNotice();
  check(
    'create.threeProjectOutcomeShowsActualCount',
    outcome !== null && outcome.kind === 'success' && outcome.text.includes('已创建 3 项'),
    JSON.stringify(outcome)
  );
  const threeCopies = await directIpc('list_pending_work_items');
  const threeCopyItems = threeCopies.ok === true ? threeCopies.value.filter((item) => item.title === titles.batchThree) : [];
  check(
    'create.threeProjectIndependentCopies',
    threeCopyItems.length === 3 &&
      new Set(threeCopyItems.map((item) => item.id)).size === 3 &&
      threeCopyItems.every((item) => item.lifecycleStatus === 'pending') &&
      threeCopyItems.map((item) => item.projectId).sort().join(',') ===
        [projects.A.id, projects.B.id, projects.C.id].sort().join(','),
    JSON.stringify(threeCopyItems)
  );
  await screenshot('pending-three-project-copies.png');

  // 6. T1-03 回归：未归属创建工作（0 项目）。
  await openCreateDialog();
  await waitForDialogProjectOptions([projects.A.id]);
  check('regression.unassignedTitleFilled', (await setDialogTitle(titles.unassigned)) === true);
  const unassignedSelection = await dialogSnapshot();
  check(
    'regression.unassignedMode',
    unassignedSelection.mode === 'unassigned' && unassignedSelection.expectedCount === 1,
    JSON.stringify(unassignedSelection)
  );
  check('regression.unassignedSaved', (await submitDialogSave()) === true);
  await waitDialogClosed();
  await waitForRows(6);
  const unassignedItem = await directIpc('list_pending_work_items');
  const unassignedCopy = unassignedItem.ok === true
    ? unassignedItem.value.find((item) => item.title === titles.unassigned)
    : null;
  check(
    'regression.unassignedPersistedWithoutProject',
    unassignedCopy !== undefined && unassignedCopy !== null && unassignedCopy.projectId === null,
    JSON.stringify(unassignedCopy)
  );
  await screenshot('pending-unassigned-regression.png');

  // 7. T1-03 回归：单项目创建工作（1 项目）。
  await openCreateDialog();
  await waitForDialogProjectOptions([projects.A.id]);
  check('regression.singleTitleFilled', (await setDialogTitle(titles.single)) === true);
  check('regression.singleProjectSelected', (await clickProjectCheckbox(projects.A.id)) === true);
  const singleSelection = await waitForSelection(1);
  check(
    'regression.singleMode',
    singleSelection.mode === 'single' && singleSelection.expectedCount === 1,
    JSON.stringify(singleSelection)
  );
  check('regression.singleSaved', (await submitDialogSave()) === true);
  await waitDialogClosed();
  await waitForRows(7);
  const singleItems = await directIpc('list_pending_work_items');
  const singleCopy = singleItems.ok === true
    ? singleItems.value.find((item) => item.title === titles.single)
    : null;
  check(
    'regression.singlePersistedWithProject',
    singleCopy !== undefined && singleCopy !== null && singleCopy.projectId === projects.A.id,
    JSON.stringify(singleCopy)
  );

  // 8. 批量创建期间重复点击保护 + 选择锁定（传输层延迟注入，不改产品代码）。
  await openCreateDialog();
  await waitForDialogProjectOptions([projects.A.id, projects.B.id]);
  check('doubleSubmit.titleFilled', (await setDialogTitle(titles.duplicate)) === true);
  await clickProjectCheckbox(projects.A.id);
  await clickProjectCheckbox(projects.B.id);
  await waitForSelection(2);
  check(
    'doubleSubmit.delayInjected',
    (await installIpcFault('create_work_item_copies', 'delay', 1500)) === true
  );
  const doubleClick = await evaluate(`(() => {
    const button = Array.from(document.querySelectorAll('dialog[open] button')).find(
      (item) => (item.textContent || '').trim() === '保存'
    );
    if (!button) return { clicked: 0 };
    button.click();
    button.click();
    return { clicked: 2 };
  })()`);
  check('doubleSubmit.doubleClickDispatched', doubleClick.clicked === 2);
  const submittingState = await waitFor(
    `(() => {
      const dialog = document.querySelector('dialog[open]');
      if (dialog === null) return false;
      const fieldset = dialog.querySelector('fieldset.project-field');
      const titleInput = dialog.querySelector('#work-item-title');
      const saveButton = Array.from(dialog.querySelectorAll('button')).find(
        (item) => (item.textContent || '').trim() === '保存'
      );
      return (
        fieldset !== null &&
        fieldset.disabled === true &&
        titleInput !== null &&
        titleInput.disabled === true &&
        saveButton !== undefined &&
        saveButton.disabled === true
      );
    })()`,
    8000,
    'submitting state locks project selection and save',
    `(() => {
      const dialog = document.querySelector('dialog[open]');
      if (dialog === null) return { dialogOpen: false };
      const fieldset = dialog.querySelector('fieldset.project-field');
      const titleInput = dialog.querySelector('#work-item-title');
      const saveButton = Array.from(dialog.querySelectorAll('button')).find(
        (item) => (item.textContent || '').trim() === '保存'
      );
      return {
        dialogOpen: true,
        fieldsetDisabled: fieldset ? fieldset.disabled : null,
        titleDisabled: titleInput ? titleInput.disabled : null,
        saveDisabled: saveButton ? saveButton.disabled : null
      };
    })()`
  );
  check('doubleSubmit.locksSelectionWhileSubmitting', submittingState === true);
  await waitDialogClosed(20000);
  await waitForRows(9);
  const duplicateItems = await directIpc('list_pending_work_items');
  const duplicateCopies = duplicateItems.ok === true
    ? duplicateItems.value.filter((item) => item.title === titles.duplicate)
    : [];
  check(
    'doubleSubmit.createsSingleBatchOnly',
    duplicateCopies.length === 2,
    `匹配副本数=${duplicateCopies.length}`
  );
  await clearIpcFault();

  // 9. 归档项目历史关联 + 对话框打开后项目归档竞态。
  const projectD = await directIpc('create_project', {
    input: { name: `${fixturePrefix}将归档项目丁` }
  });
  check('setup.archiveProjectCreated', projectD.ok === true);
  projects.D = { id: projectD.value.id, name: `${fixturePrefix}将归档项目丁` };
  const archivedLinkCreate = await directIpc('create_work_item', {
    input: { title: titles.archivedLink, projectId: projects.D.id }
  });
  check('setup.archivedLinkCreated', archivedLinkCreate.ok === true);
  archivedLinkItem = archivedLinkCreate.value ?? null;
  // 直接 IPC 创建不会自动刷新页面状态：重新挂载待安排视图读取数据库权威列表。
  const remountedAfterDirectCreate = await remountPendingViewAndSettle();
  check(
    'setup.pendingViewRefreshedAfterDirectIpcCreate',
    remountedAfterDirectCreate.rows === 10,
    JSON.stringify(remountedAfterDirectCreate)
  );

  await openCreateDialog();
  await waitForDialogProjectOptions([projects.A.id, projects.D.id]);
  check('archiveRace.titleFilled', (await setDialogTitle(titles.archiveRace)) === true);
  check('archiveRace.selectProjectA', (await clickProjectCheckbox(projects.A.id)) === true);
  check('archiveRace.selectProjectD', (await clickProjectCheckbox(projects.D.id)) === true);
  await waitForSelection(2);
  const archiveBehindDialog = await directIpc('archive_project', {
    input: { id: projects.D.id }
  });
  check('archiveRace.projectArchivedBehindDialog', archiveBehindDialog.ok === true);
  check('archiveRace.saveClicked', (await submitDialogSave()) === true);
  await waitFor(`document.querySelector('dialog[open] .dialog-error') !== null`, 12000, 'batch dialog error');
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
    'archiveRace.wholeBatchRejectedWithProjectArchived',
    raceError.dialogStillOpen === true &&
      (raceError.code ?? '').includes('project-archived') &&
      raceError.message.includes('归档'),
    JSON.stringify(raceError)
  );
  const raceSelection = await dialogSnapshot();
  check(
    'archiveRace.keepsOriginalSelectionAndMarksInvalid',
    raceSelection.selectedCount === 2 &&
      raceSelection.expectedCount === 2 &&
      raceSelection.invalidSelectionCount === 1 &&
      raceSelection.availableProjectIds.includes(projects.A.id) &&
      !raceSelection.availableProjectIds.includes(projects.D.id),
    JSON.stringify(raceSelection)
  );
  await screenshot('create-error-project-archived-batch.png');
  check('archiveRace.removeInvalidSelection', (await clickInvalidSelectionRemove()) === true);
  const afterRemove = await waitForSelection(1);
  check(
    'archiveRace.invalidRemovedOnlyAfterUserAction',
    afterRemove.invalidSelectionCount === 0 && afterRemove.expectedCount === 1,
    JSON.stringify(afterRemove)
  );
  await closeDialogByCancel();
  const pendingAfterRace = await waitForPendingSettled(15000);
  check(
    'archiveRace.noPartialCopiesCreated',
    pendingAfterRace.rows === 10,
    JSON.stringify(pendingAfterRace)
  );
  const archivedLinkRows = await rowSnapshots();
  const archivedLinkRow = archivedLinkRows.find((row) => row.id === archivedLinkItem?.id);
  check(
    'archivedProject.historyLinkStillListedWithBadge',
    archivedLinkRow !== undefined &&
      archivedLinkRow.meta.includes(`${fixturePrefix}将归档项目丁`) &&
      archivedLinkRow.hasArchivedBadge === true,
    JSON.stringify(archivedLinkRow)
  );
  await screenshot('pending-archived-project.png');

  // 10. 绕过 UI 直接 IPC：批量接口仍必须被 Rust Core 拒绝。
  const bypassArchived = await directIpc('create_work_item_copies', {
    input: { title: titles.bypass, projectIds: [projects.A.id, projects.D.id] }
  });
  check(
    'ipc.bypassArchivedProjectRejectedWithWholeBatch',
    bypassArchived.ok === false && String(bypassArchived.error).includes('project-archived'),
    String(bypassArchived.error).slice(0, 300)
  );
  const bypassMissing = await directIpc('create_work_item_copies', {
    input: {
      title: titles.bypass,
      projectIds: [projects.A.id, '77777777-7777-4777-8777-777777777777']
    }
  });
  check(
    'ipc.bypassMissingProjectRejected',
    bypassMissing.ok === false && String(bypassMissing.error).includes('project-not-found'),
    String(bypassMissing.error).slice(0, 300)
  );
  const bypassDuplicate = await directIpc('create_work_item_copies', {
    input: { title: titles.bypass, projectIds: [projects.A.id, projects.A.id] }
  });
  check(
    'ipc.bypassDuplicateProjectsRejected',
    bypassDuplicate.ok === false &&
      String(bypassDuplicate.error).includes('work-item-copies-duplicate-project'),
    String(bypassDuplicate.error).slice(0, 300)
  );
  for (const projectIds of [[projects.A.id], []]) {
    const bypassTooFew = await directIpc('create_work_item_copies', {
      input: { title: titles.bypass, projectIds }
    });
    check(
      'ipc.bypassTooFewProjectsRejected',
      bypassTooFew.ok === false && String(bypassTooFew.error).includes('work-item-copies-too-few'),
      String(bypassTooFew.error).slice(0, 300)
    );
  }
  const bypassEmptyTitle = await directIpc('create_work_item_copies', {
    input: { title: '   ', projectIds: [projects.A.id, projects.B.id] }
  });
  check(
    'ipc.bypassEmptyTitleRejected',
    bypassEmptyTitle.ok === false && String(bypassEmptyTitle.error).includes('work-item-title-empty'),
    String(bypassEmptyTitle.error).slice(0, 300)
  );
  const bypassUnknownField = await directIpc('create_work_item_copies', {
    input: { title: titles.bypass, projectIds: [projects.A.id, projects.B.id], extraField: 1 }
  });
  check(
    'ipc.bypassUnknownFieldRejected',
    bypassUnknownField.ok === false,
    String(bypassUnknownField.error).slice(0, 300)
  );
  const bypassSnakeCase = await directIpc('create_work_item_copies', {
    input: { title: titles.bypass, project_ids: [projects.A.id, projects.B.id] }
  });
  check(
    'ipc.bypassSnakeCaseProjectIdsRejected',
    bypassSnakeCase.ok === false,
    String(bypassSnakeCase.error).slice(0, 300)
  );
  const arbitrarySql = await directIpc('execute_sql', { sql: 'SELECT 1' });
  check('ipc.noArbitrarySqlCommand', arbitrarySql.ok === false);
  const countAfterBypass = await directIpc('list_pending_work_items');
  check(
    'ipc.rejectedRequestsCreatedNoRows',
    countAfterBypass.ok === true && countAfterBypass.value.length === 10,
    JSON.stringify(countAfterBypass.value?.length)
  );

  // 11. Bridge 严格契约：伪造非法批量创建响应必须显示 ipc-contract-violation。
  await openCreateDialog();
  await waitForDialogProjectOptions([projects.A.id, projects.B.id]);
  check('contractViolation.titleFilled', (await setDialogTitle(titles.contractViolation)) === true);
  await clickProjectCheckbox(projects.A.id);
  await clickProjectCheckbox(projects.B.id);
  await waitForSelection(2);
  check(
    'contractViolation.faultInjected',
    (await installIpcFault('create_work_item_copies', 'malformed')) === true
  );
  check('contractViolation.saveClicked', (await submitDialogSave()) === true);
  await waitFor(
    `document.querySelector('dialog[open] .dialog-error') !== null`,
    12000,
    'contract violation error shown'
  );
  const contractError = await evaluate(`(() => {
    const error = document.querySelector('dialog[open] .dialog-error');
    const code = document.querySelector('dialog[open] .dialog-error-code');
    return {
      message: (error.innerText || '').replace(/\\s+/g, ' ').trim(),
      code: code ? (code.textContent || '').replace(/\\s+/g, ' ').trim() : null,
      dialogStillOpen: document.querySelector('dialog[open]') !== null,
      titleValue: (() => { const el = document.querySelector('dialog[open] #work-item-title'); return el ? el.value : null; })()
    };
  })()`);
  check(
    'contractViolation.uiRejectsMalformedPayload',
    contractError.dialogStillOpen === true &&
      (contractError.code ?? '').includes('ipc-contract-violation') &&
      contractError.titleValue === titles.contractViolation,
    JSON.stringify(contractError)
  );
  const contractSelection = await dialogSnapshot();
  check(
    'contractViolation.selectionRetained',
    contractSelection.selectedCount === 2,
    JSON.stringify(contractSelection)
  );
  await screenshot('create-error-contract-violation-batch.png');
  await clearIpcFault();
  await closeDialogByCancel();
  const pendingAfterContract = await waitForPendingSettled(15000);
  check(
    'contractViolation.noRowsCreated',
    pendingAfterContract.rows === 10,
    JSON.stringify(pendingAfterContract)
  );

  // 12. 创建成功 + 列表刷新失败：显示实际数量 warning、不重复创建、重试后恢复。
  await openCreateDialog();
  await waitForDialogProjectOptions([projects.A.id, projects.B.id]);
  check('refreshFailure.titleFilled', (await setDialogTitle(titles.refreshFailure)) === true);
  await clickProjectCheckbox(projects.A.id);
  await clickProjectCheckbox(projects.B.id);
  await waitForSelection(2);
  check(
    'refreshFailure.faultInjected',
    (await installIpcFault('list_pending_work_items', 'reject')) === true
  );
  check('refreshFailure.saveClicked', (await submitDialogSave()) === true);
  await waitDialogClosed();
  await waitFor(
    `(() => {
      const element = document.querySelector('[data-create-outcome]');
      return element !== null && element.getAttribute('data-create-outcome') === 'warning';
    })()`,
    12000,
    'create warning outcome after refresh failure'
  );
  outcome = await createOutcomeNotice();
  check(
    'refreshFailure.warningShowsActualCountAndRefreshFailure',
    outcome !== null &&
      outcome.kind === 'warning' &&
      outcome.text.includes('已创建 2 项') &&
      outcome.text.includes('刷新失败'),
    JSON.stringify(outcome)
  );
  // 先恢复传输层，再直接读取数据库权威数量：证明刷新失败没有导致重复创建。
  await clearIpcFault();
  const countBeforeRetry = await directIpc('list_pending_work_items');
  check(
    'refreshFailure.noDuplicateCreateOnRefreshFailure',
    countBeforeRetry.ok === true && countBeforeRetry.value.length === 12,
    JSON.stringify(countBeforeRetry)
  );
  check('refreshFailure.retryClicked', (await clickByText('main', '重新加载', true)) === true);
  const recovered = await waitForPendingSettled(15000);
  check(
    'refreshFailure.retryRecoversListWithoutDuplicate',
    recovered.rows === 12,
    JSON.stringify(recovered)
  );
  await waitFor(
    `(() => {
      const element = document.querySelector('[data-create-outcome]');
      return element !== null && (element.innerText || '').includes('已从数据库重新读取');
    })()`,
    8000,
    'retry success outcome'
  );
  await screenshot('pending-refresh-recovered.png');

  // 13. CSP / 未捕获异常 / 正常窗口布局。
  const cspViolations = await evaluate(`window.__wmCspViolations || []`);
  check('security.cspViolationsZero', Array.isArray(cspViolations) && cspViolations.length === 0, JSON.stringify(cspViolations));
  const exceptionCount = pageErrors.filter((item) => item.type === 'exception').length;
  check('security.pageExceptionsZero', exceptionCount === 0, JSON.stringify(pageErrors).slice(0, 500));
  const finalPending = await waitForPendingSettled(15000);
  check('final.pendingCount12', finalPending.rows === 12, JSON.stringify(finalPending));
  const finalList = await directIpc('list_pending_work_items');
  check(
    'final.pendingListAllPendingAndExpectedTitles',
    finalList.ok === true &&
      finalList.value.length === 12 &&
      finalList.value.every((item) => item.lifecycleStatus === 'pending') &&
      [titles.batchTwo, titles.batchThree, titles.unassigned, titles.single, titles.duplicate, titles.archivedLink, titles.refreshFailure].every(
        (expectedTitle) => finalList.value.some((item) => item.title === expectedTitle)
      ),
    JSON.stringify(finalList.value?.length)
  );
  await checkNoOverflow('final.normalWindowNoHorizontalOverflow');
  await screenshot('pending-after-main-checks.png');
  check(
    'final.noUnexpectedBatchResidueTitles',
    finalList.ok === true &&
      !finalList.value.some((item) =>
        [titles.archiveRace, titles.contractViolation, titles.bypass].some((bad) => item.title === bad)
      ),
    '失败批次标题不得出现在待安排列表'
  );

  const evidencePath = writeEvidence();
  const prerequisitePath = writePrerequisite();
  console.log(
    JSON.stringify(
      {
        total: checks.length,
        failed: checks.filter((item) => !item.pass).map((item) => item.name),
        evidencePath,
        prerequisitePath
      },
      null,
      2
    )
  );
} catch (error) {
  check('ui.scriptCompleted', false, String(error));
  await screenshot('ui-failure.png').catch(() => null);
  try {
    const evidencePath = writeEvidence({ scriptError: String(error) });
    console.error(`UI_EVIDENCE=${evidencePath}`);
  } catch {
    // 证据写盘失败不应掩盖原始错误。
  }
}

await sleep(300);
socket.close();
process.exit(checks.some((item) => !item.pass) ? 1 : 0);
