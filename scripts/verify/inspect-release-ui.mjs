/**
 * WorkManager T1-01 Release 窗口 UI/IPC 端到端检查。
 *
 * 前提：Release 进程已用 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>`
 * 启动，且 WebView2 已加载页面。
 *
 * 做法：通过 Chromium DevTools Protocol 连接真实 WebView2 页面：
 * 1. 读取渲染后的 DOM 文本（证明前端真实渲染，而非仅启动进程）；
 * 2. 直接调用 window.__TAURI_INTERNALS__.invoke('get_database_health')，
 *    证明受限 Rust IPC 命令在 Release 中真实可用并返回数据库状态；
 * 3. 截图保存视觉证据；
 * 4. 所有断言写入 evidence JSON，任一失败退出码 1。
 *
 * 用法：node scripts/verify/inspect-release-ui.mjs <port> <outputDir>
 */

import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? '9333');
const outputDir = process.argv[3] ?? `D:\\WorkManager-test-data\\ui-check-${Date.now()}`;
fs.mkdirSync(outputDir, { recursive: true });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function findPageTarget() {
  let lastError = null;
  for (let attempt = 0; attempt < 120; attempt += 1) {
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

socket.addEventListener('message', (event) => {
  let message;
  try {
    message = JSON.parse(event.data);
  } catch {
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

await send('Runtime.enable');
await send('Page.enable');

const readUiState = () =>
  evaluate(`(() => {
    const text = (selector) => {
      const element = document.querySelector(selector);
      return element ? element.innerText.replace(/\\s+/g, ' ').trim() : null;
    };
    return {
      title: document.title,
      href: location.href,
      readyState: document.readyState,
      versionPill: text('.version-pill'),
      heading: text('h1'),
      badges: Array.from(document.querySelectorAll('.badge')).map((element) =>
        element.innerText.replace(/\\s+/g, ' ').trim()
      ),
      pathValues: Array.from(document.querySelectorAll('.path-value')).map((element) =>
        element.innerText.trim()
      ),
      migrationRows: Array.from(document.querySelectorAll('table tbody tr')).map((row) =>
        Array.from(row.querySelectorAll('td')).map((cell) => cell.innerText.trim())
      ),
      footerScope: text('.footer-scope'),
      footerNote: text('.footer-note'),
      hasErrorAlert: document.querySelector('[role="alert"]') !== null,
      bodyText: document.body ? document.body.innerText.replace(/\\s+/g, ' ').trim().slice(0, 3000) : ''
    };
  })()`);

// 等待真实渲染完成（成功徽标或错误卡片出现）。
let uiState = null;
for (let attempt = 0; attempt < 120; attempt += 1) {
  uiState = await readUiState();
  const rendered =
    uiState.readyState === 'complete' &&
    uiState.badges.some((badge) => badge.includes('正常（ok）')) &&
    uiState.pathValues.length >= 3;
  if (rendered || uiState.hasErrorAlert) {
    break;
  }
  await sleep(250);
}

// 直接调用受限 IPC 命令，验证 Release 构建中的真实命令返回。
let ipcResult = null;
let ipcError = null;
try {
  const raw = await evaluate(`(async () => {
    const response = await window.__TAURI_INTERNALS__.invoke('get_database_health');
    return JSON.stringify(response);
  })()`);
  ipcResult = JSON.parse(raw);
} catch (error) {
  ipcError = String(error);
}

const screenshot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
const screenshotPath = path.join(outputDir, 'release-window.png');
fs.writeFileSync(screenshotPath, Buffer.from(screenshot.data, 'base64'));

const database = ipcResult && ipcResult.database ? ipcResult.database : null;

const assertions = {
  pageLoaded: uiState !== null && uiState.readyState === 'complete',
  uiRenderedHealth: uiState !== null && uiState.badges.some((badge) => badge.includes('正常（ok）')),
  noErrorAlert: uiState !== null && uiState.hasErrorAlert === false,
  appNameRendered: uiState !== null && uiState.heading === 'WorkManager',
  versionRendered: uiState !== null && /版本 0\.1\.0/.test(uiState.versionPill ?? ''),
  footerScopeRendered:
    uiState !== null && (uiState.footerScope ?? '').includes('T1-01 基础设施预览'),
  ipcCommandSucceeded: ipcError === null && database !== null,
  ipcAppName: ipcResult !== null && ipcResult.appName === 'WorkManager',
  ipcAppVersion: ipcResult !== null && ipcResult.appVersion === '0.1.0',
  ipcRuntimeModeRelease: ipcResult !== null && ipcResult.runtimeMode === 'release',
  ipcSchemaVersion: database !== null && database.schemaVersion === 1,
  ipcIntegrityOk: database !== null && database.integrityCheck === 'ok',
  ipcJournalModeWal: database !== null && String(database.journalMode).toLowerCase() === 'wal',
  ipcForeignKeysEnabled: database !== null && database.foreignKeys === true,
  ipcBusyTimeout: database !== null && database.busyTimeoutMs === 5000,
  ipcSynchronousFull: database !== null && database.synchronous === 2,
  ipcMigrationRecorded:
    database !== null &&
    Array.isArray(database.appliedMigrations) &&
    database.appliedMigrations.length === 1 &&
    database.appliedMigrations[0].version === 1,
  ipcDatabasePathPortable:
    database !== null &&
    String(database.databasePath).toLowerCase().endsWith('\\app\\data\\database\\work.db'),
  ipcWebview2DirPortable:
    ipcResult !== null &&
    String(ipcResult.webview2DataDir).toLowerCase().endsWith('\\app\\data\\cache\\webview2')
};

const evidence = {
  generatedAt: new Date().toISOString(),
  method:
    'CDP Runtime.evaluate against real Release WebView2 (DOM state + direct Tauri IPC invoke + screenshot)',
  port,
  target: {
    id: pageTarget.id,
    title: pageTarget.title,
    url: pageTarget.url,
    type: pageTarget.type
  },
  uiState,
  ipc: { ok: ipcError === null, error: ipcError, result: ipcResult },
  assertions,
  screenshotPath
};

const evidencePath = path.join(outputDir, 'release-ui-ipc-evidence.json');
fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2), 'utf8');
console.log(JSON.stringify({ evidencePath, screenshotPath, assertions }, null, 2));

socket.close();

const failed = Object.entries(assertions)
  .filter(([, value]) => !value)
  .map(([key]) => key);
if (failed.length > 0) {
  console.error(`ASSERTION_FAILED: ${failed.join(', ')}`);
  process.exit(1);
}
console.log('T1_01_RELEASE_UI_IPC_CHECK=PASS');
