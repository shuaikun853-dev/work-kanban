<script lang="ts">
  import { onMount } from 'svelte';

  import { DatabaseHealthError, fetchDatabaseHealth } from '../../bridge/databaseHealth';
  import { DATABASE_HEALTH_COMMAND } from '../../contracts/databaseHealth';
  import type { DatabaseHealthResponse } from '../../contracts/databaseHealth';
  import {
    describeRuntimeMode,
    formatBeijingTime,
    formatByteSize
  } from '../../presentation/healthFormat';
  import PageHeader from '../../ui/components/PageHeader.svelte';

  /** 加载失败时展示给用户的结构化信息。 */
  interface HealthLoadFailure {
    readonly code: string;
    readonly message: string;
  }

  let health = $state<DatabaseHealthResponse | null>(null);
  let failure = $state<HealthLoadFailure | null>(null);
  let loading = $state(true);

  /** 请求序号：只接受最新一次请求的结果，避免快速重试时旧响应覆盖新状态。 */
  let requestToken = 0;

  const database = $derived(health === null ? null : health.database);
  const migrations = $derived(database === null ? [] : database.appliedMigrations);
  const runtimeMode = $derived(health === null ? null : describeRuntimeMode(health.runtimeMode));

  function toLoadFailure(cause: unknown): HealthLoadFailure {
    if (cause instanceof DatabaseHealthError) {
      return { code: cause.code, message: cause.message };
    }

    if (cause instanceof Error && cause.message.trim().length > 0) {
      return { code: 'frontend-unexpected-error', message: cause.message };
    }

    return {
      code: 'frontend-unexpected-error',
      message: '加载数据库健康信息时发生未知异常，请重试。'
    };
  }

  /**
   * 页面加载时与“重新检查”按钮共用的一次性健康检查。
   *
   * 内部捕获所有异常（含 IPC 失败与契约校验失败），因此返回的 Promise
   * 不会 reject；页面代码使用 `void loadHealth()` 也不会产生未处理 rejection。
   */
  async function loadHealth(): Promise<void> {
    const token = ++requestToken;
    loading = true;
    failure = null;

    try {
      const response = await fetchDatabaseHealth();
      if (token !== requestToken) {
        return;
      }
      health = response;
    } catch (cause: unknown) {
      if (token !== requestToken) {
        return;
      }
      health = null;
      failure = toLoadFailure(cause);
    } finally {
      if (token === requestToken) {
        loading = false;
      }
    }
  }

  onMount(() => {
    void loadHealth();
  });
</script>

<svelte:head>
  <title>数据库诊断 · WorkManager</title>
</svelte:head>

<PageHeader
  title="数据库诊断"
  subtitle="只读检查 SQLite 连接、完整性、PRAGMA 配置与便携路径；不会修改业务数据。"
>
  {#snippet actions()}
    <button
      class="refresh-button"
      type="button"
      onclick={() => void loadHealth()}
      disabled={loading}
      aria-busy={loading}
    >
      {#if loading}
        <span class="button-spinner" aria-hidden="true"></span>
      {/if}
      <span>{loading ? '检查中…' : '重新检查'}</span>
    </button>
  {/snippet}
</PageHeader>

<div class="diagnostics-page">
  <section class="card" aria-labelledby="health-heading">
    <div class="card-head">
      <div class="card-heading">
        <h2 id="health-heading">数据库健康</h2>
        <p class="card-subtitle">
          SQLite 连接、完整性检查与 PRAGMA 配置快照（命令
          <code class="inline-code">{DATABASE_HEALTH_COMMAND}</code>）
        </p>
      </div>
    </div>

    {#if loading && health === null}
      <div class="feedback feedback-loading" role="status" aria-live="polite">
        <span class="spinner" aria-hidden="true"></span>
        <div class="feedback-body">
          <h3 class="feedback-title">正在检查数据库…</h3>
          <p class="feedback-detail">
            正在调用本机受限 IPC 命令，只读取健康状态与便携路径，不会修改任何数据。
          </p>
        </div>
      </div>
    {:else if failure !== null}
      <div class="feedback feedback-error" role="alert">
        <span class="alert-mark" aria-hidden="true">!</span>
        <div class="feedback-body">
          <h3 class="feedback-title">无法读取数据库健康信息</h3>
          <p class="feedback-detail">{failure.message}</p>
          <p class="feedback-meta">错误码：<code class="error-code">{failure.code}</code></p>
          <button
            class="retry-button"
            type="button"
            onclick={() => void loadHealth()}
            disabled={loading}
          >
            {#if loading}
              <span class="button-spinner" aria-hidden="true"></span>
            {/if}
            <span>{loading ? '重试中…' : '重新检查'}</span>
          </button>
        </div>
      </div>
    {:else if database !== null}
      <dl class="metrics">
        <div class="metric">
          <dt>数据库状态</dt>
          <dd>
            {#if database.status === 'ok'}
              <span class="badge badge-success">
                <span class="badge-dot" aria-hidden="true"></span>正常（{database.status}）
              </span>
            {:else}
              <span class="badge badge-warning">
                <span class="badge-dot" aria-hidden="true"></span>异常（{database.status}）
              </span>
            {/if}
          </dd>
        </div>

        <div class="metric">
          <dt>当前 Schema 版本</dt>
          <dd>
            <span class="metric-value">{database.schemaVersion}</span>
            {#if database.schemaVersion === database.latestSchemaVersion}
              <span class="metric-sub">已是最新</span>
            {:else}
              <span class="metric-sub metric-warning">低于最新版本</span>
            {/if}
          </dd>
        </div>

        <div class="metric">
          <dt>最新 Schema 版本</dt>
          <dd><span class="metric-value">{database.latestSchemaVersion}</span></dd>
        </div>

        <div class="metric">
          <dt>完整性检查 integrity_check</dt>
          <dd>
            {#if database.integrityCheck === 'ok'}
              <span class="badge badge-success">
                <span class="badge-dot" aria-hidden="true"></span>通过（{database.integrityCheck}）
              </span>
            {:else}
              <span class="badge badge-warning">{database.integrityCheck}</span>
            {/if}
          </dd>
        </div>

        <div class="metric">
          <dt>日志模式 journal_mode</dt>
          <dd><code class="inline-code">{database.journalMode}</code></dd>
        </div>

        <div class="metric">
          <dt>同步级别 synchronous</dt>
          <dd><span class="metric-value">{database.synchronous}</span></dd>
        </div>

        <div class="metric">
          <dt>外键约束 foreign_keys</dt>
          <dd>
            {#if database.foreignKeys}
              <span class="metric-value">已启用</span>
            {:else}
              <span class="metric-value metric-warning">未启用</span>
            {/if}
          </dd>
        </div>

        <div class="metric">
          <dt>等待超时 busy_timeout</dt>
          <dd>
            <span class="metric-value">{database.busyTimeoutMs}</span>
            <span class="metric-sub">毫秒</span>
          </dd>
        </div>

        <div class="metric">
          <dt>临时存储 temp_store</dt>
          <dd><span class="metric-value">{database.tempStore}</span></dd>
        </div>

        <div class="metric">
          <dt>外键违规数</dt>
          <dd>
            <span class="metric-value">{database.foreignKeyViolations}</span>
            <span class="metric-sub">条</span>
          </dd>
        </div>

        <div class="metric">
          <dt>数据库文件大小</dt>
          <dd>
            <span class="metric-value">{formatByteSize(database.databaseFileSizeBytes)}</span>
            <span class="metric-sub">
              {database.databaseFileSizeBytes.toLocaleString('zh-CN')} 字节
            </span>
          </dd>
        </div>

        <div class="metric">
          <dt>检查时间（北京时间）</dt>
          <dd>
            <time datetime={database.checkedAt} title={database.checkedAt}>
              {formatBeijingTime(database.checkedAt)}
            </time>
          </dd>
        </div>
      </dl>
    {:else}
      <div class="feedback feedback-loading" role="status">
        <div class="feedback-body">
          <h3 class="feedback-title">暂无数据库健康数据</h3>
          <p class="feedback-detail">点击“重新检查”获取当前的数据库健康快照。</p>
        </div>
      </div>
    {/if}
  </section>

  {#if health !== null}
    <section class="card" aria-labelledby="paths-heading">
      <div class="card-head">
        <div class="card-heading">
          <h2 id="paths-heading">便携路径诊断</h2>
          <p class="card-subtitle">
            数据库、缓存、日志与 WebView2 数据必须位于 D 盘便携目录；以下路径文本可选中复制。
          </p>
        </div>
      </div>

      <dl class="path-list">
        <div class="path-item">
          <dt>运行模式</dt>
          <dd>
            {#if runtimeMode !== null}
              <span
                class="badge"
                class:badge-success={health.runtimeMode === 'release'}
                class:badge-info={health.runtimeMode !== 'release'}
              >
                <span class="badge-dot" aria-hidden="true"></span>{runtimeMode.label}
              </span>
              <span class="path-hint">{runtimeMode.hint}</span>
            {/if}
          </dd>
        </div>

        <div class="path-item">
          <dt>数据根目录</dt>
          <dd><code class="path-value">{health.dataRoot}</code></dd>
        </div>

        <div class="path-item">
          <dt>数据库路径</dt>
          <dd><code class="path-value">{health.databasePath}</code></dd>
        </div>

        <div class="path-item">
          <dt>WebView2 数据目录</dt>
          <dd><code class="path-value">{health.webview2DataDir}</code></dd>
        </div>
      </dl>
    </section>

    <section class="card" aria-labelledby="migrations-heading">
      <div class="card-head">
        <div class="card-heading">
          <h2 id="migrations-heading">已应用的 Migration</h2>
          <p class="card-subtitle">按版本顺序记录数据库 schema 变更历史，只读展示。</p>
        </div>
        <span class="count-pill">{migrations.length} 条</span>
      </div>

      {#if migrations.length === 0}
        <p class="empty-state">当前数据库尚未记录任何已应用的 migration。</p>
      {:else}
        <div class="table-wrap">
          <table>
            <caption class="visually-hidden">已应用的数据库 migration 记录</caption>
            <thead>
              <tr>
                <th scope="col" class="col-version">版本</th>
                <th scope="col">名称</th>
                <th scope="col" class="col-time">应用时间（北京时间）</th>
              </tr>
            </thead>
            <tbody>
              {#each migrations as migration (migration.version)}
                <tr>
                  <td class="cell-version">{migration.version}</td>
                  <td class="cell-name"><code>{migration.name}</code></td>
                  <td class="cell-time">
                    <time datetime={migration.appliedAt} title={migration.appliedAt}>
                      {formatBeijingTime(migration.appliedAt)}
                    </time>
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </section>
  {/if}

  <p class="diagnostic-note">
    数据库为普通 SQLite 文件，未加密；拥有文件访问权限的人可以读取其中内容。
  </p>
</div>

<style>
  .diagnostics-page {
    display: flex;
    flex-direction: column;
    gap: 18px;
    max-width: 1180px;
  }

  .card {
    padding: 22px 24px 24px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
    box-shadow: var(--shadow-card);
  }

  .card-head {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
  }

  .card-heading {
    min-width: 0;
  }

  h2 {
    font-size: 16px;
    font-weight: 700;
    letter-spacing: -0.005em;
  }

  .card-subtitle {
    margin-top: 4px;
    color: var(--color-text-muted);
    font-size: 12.5px;
    overflow-wrap: anywhere;
  }

  .inline-code {
    display: inline-block;
    padding: 1px 6px;
    border: 1px solid var(--color-border);
    border-radius: 6px;
    background-color: var(--color-surface-muted);
    color: #334155;
    font-family: var(--font-mono);
    font-size: 0.92em;
    overflow-wrap: anywhere;
  }

  .refresh-button,
  .retry-button {
    display: inline-flex;
    flex-shrink: 0;
    align-items: center;
    justify-content: center;
    gap: 8px;
    min-height: 38px;
    padding: 8px 16px;
    border: 1px solid transparent;
    border-radius: 9px;
    background-color: var(--color-accent);
    color: #ffffff;
    font-size: 13.5px;
    font-weight: 600;
    line-height: 1;
    cursor: pointer;
    transition:
      background-color 0.15s ease,
      box-shadow 0.15s ease;
  }

  .refresh-button:hover:not(:disabled),
  .retry-button:hover:not(:disabled) {
    background-color: var(--color-accent-strong);
  }

  .refresh-button:focus-visible,
  .retry-button:focus-visible {
    outline: 2px solid #1e3a8a;
    outline-offset: 2px;
  }

  .refresh-button:disabled,
  .retry-button:disabled {
    cursor: not-allowed;
    opacity: 0.62;
  }

  .button-spinner {
    width: 13px;
    height: 13px;
    border: 2px solid rgba(255, 255, 255, 0.42);
    border-top-color: #ffffff;
    border-radius: 50%;
    animation: spin 0.75s linear infinite;
  }

  .spinner {
    flex-shrink: 0;
    width: 22px;
    height: 22px;
    border: 2.5px solid #cbd5e1;
    border-top-color: var(--color-accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .feedback {
    display: flex;
    align-items: flex-start;
    gap: 14px;
    margin-top: 18px;
    padding: 18px;
    border-radius: var(--radius-md);
  }

  .feedback-loading {
    border: 1px solid var(--color-border);
    background-color: var(--color-surface-muted);
  }

  .feedback-error {
    border: 1px solid #f3c6c1;
    background-color: var(--color-danger-bg);
  }

  .feedback-body {
    min-width: 0;
  }

  .feedback-title {
    color: var(--color-text);
    font-size: 14px;
    font-weight: 700;
  }

  .feedback-error .feedback-title {
    color: var(--color-danger-text);
  }

  .feedback-detail {
    margin-top: 4px;
    color: #4b5563;
    font-size: 13px;
    overflow-wrap: anywhere;
  }

  .feedback-error .feedback-detail {
    color: #7f1d1d;
  }

  .feedback-meta {
    margin-top: 8px;
    color: var(--color-text-muted);
    font-size: 12.5px;
  }

  .error-code {
    display: inline-block;
    padding: 1px 7px;
    border: 1px solid #f0b4ad;
    border-radius: 6px;
    background-color: #ffffff;
    color: var(--color-danger-text);
    font-family: var(--font-mono);
    font-size: 12px;
    overflow-wrap: anywhere;
  }

  .alert-mark {
    display: grid;
    place-items: center;
    flex-shrink: 0;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background-color: var(--color-danger-text);
    color: #ffffff;
    font-size: 14px;
    font-weight: 700;
    line-height: 1;
  }

  .retry-button {
    min-height: 34px;
    margin-top: 12px;
    padding: 7px 14px;
    font-size: 13px;
  }

  .metrics {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 1px;
    margin-top: 18px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    background-color: var(--color-border);
    overflow: hidden;
  }

  .metric {
    min-width: 0;
    padding: 13px 16px 14px;
    background-color: var(--color-surface);
  }

  .metric dt {
    margin-bottom: 6px;
    color: var(--color-text-muted);
    font-size: 11.5px;
    font-weight: 600;
    letter-spacing: 0.03em;
  }

  .metric dd {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    margin: 0;
    color: var(--color-text);
    font-size: 14px;
    overflow-wrap: anywhere;
  }

  .metric-value {
    font-size: 16px;
    font-weight: 700;
    line-height: 1.3;
  }

  .metric-sub {
    color: var(--color-text-muted);
    font-size: 12px;
  }

  .metric-warning {
    color: var(--color-warning-text);
  }

  .badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 10px;
    border: 1px solid transparent;
    border-radius: 999px;
    font-size: 12.5px;
    font-weight: 600;
    line-height: 1.5;
  }

  .badge-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background-color: currentColor;
  }

  .badge-success {
    border-color: #bfe8cc;
    background-color: var(--color-success-bg);
    color: var(--color-success-text);
  }

  .badge-warning {
    border-color: #f2d9a5;
    background-color: var(--color-warning-bg);
    color: var(--color-warning-text);
  }

  .badge-info {
    border-color: var(--color-accent-soft-border);
    background-color: var(--color-accent-soft);
    color: var(--color-accent-strong);
  }

  .path-list {
    display: flex;
    flex-direction: column;
    gap: 14px;
    margin-top: 18px;
  }

  .path-item {
    display: grid;
    grid-template-columns: 132px minmax(0, 1fr);
    gap: 12px;
    align-items: start;
  }

  .path-item dt {
    padding-top: 7px;
    color: var(--color-text-muted);
    font-size: 12.5px;
    font-weight: 600;
  }

  .path-item dd {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 10px;
    min-width: 0;
    margin: 0;
  }

  .path-value {
    display: block;
    flex: 1 1 auto;
    min-width: 0;
    max-width: 100%;
    padding: 7px 10px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background-color: var(--color-surface-muted);
    color: #334155;
    font-family: var(--font-mono);
    font-size: 12.5px;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    word-break: break-all;
    user-select: text;
  }

  .path-hint {
    color: var(--color-text-muted);
    font-size: 12px;
  }

  .count-pill {
    flex-shrink: 0;
    padding: 4px 10px;
    border: 1px solid var(--color-border-strong);
    border-radius: 999px;
    background-color: var(--color-surface-muted);
    color: var(--color-text-muted);
    font-size: 12px;
    font-weight: 600;
  }

  .empty-state {
    margin-top: 18px;
    padding: 20px;
    border: 1px dashed var(--color-border-strong);
    border-radius: var(--radius-md);
    color: var(--color-text-muted);
    font-size: 13px;
    text-align: center;
  }

  .table-wrap {
    margin-top: 18px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  table {
    width: 100%;
    border-collapse: collapse;
    table-layout: fixed;
    font-size: 13px;
  }

  th {
    padding: 10px 14px;
    border-bottom: 1px solid var(--color-border);
    background-color: var(--color-surface-muted);
    color: var(--color-text-muted);
    font-size: 12px;
    font-weight: 600;
    text-align: left;
  }

  td {
    padding: 11px 14px;
    border-bottom: 1px solid #eef1f6;
    color: var(--color-text);
    vertical-align: top;
    overflow-wrap: anywhere;
  }

  tbody tr:last-child td {
    border-bottom: none;
  }

  tbody tr:hover td {
    background-color: #fbfcfe;
  }

  .col-version {
    width: 84px;
  }

  .col-time {
    width: 236px;
  }

  .cell-version {
    color: var(--color-text-muted);
    font-variant-numeric: tabular-nums;
  }

  .cell-name code {
    color: #334155;
    font-family: var(--font-mono);
    font-size: 12.5px;
  }

  .cell-time time {
    color: var(--color-text-muted);
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }

  .diagnostic-note {
    color: var(--color-text-muted);
    font-size: 11.5px;
    line-height: 1.6;
    text-align: center;
  }

  @media (max-width: 820px) {
    .card {
      padding: 18px 16px 20px;
    }

    .col-time {
      width: 180px;
    }
  }

  @media (max-width: 640px) {
    .card-head {
      flex-direction: column;
      align-items: stretch;
    }

    .metrics {
      grid-template-columns: 1fr;
    }

    .path-item {
      grid-template-columns: 1fr;
      gap: 6px;
    }

    .path-item dt {
      padding-top: 0;
    }

    .col-version {
      width: 64px;
    }

    .col-time {
      width: auto;
    }

    th,
    td {
      padding: 9px 10px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner,
    .button-spinner {
      animation-duration: 2.4s;
    }

    .refresh-button,
    .retry-button {
      transition: none;
    }
  }
</style>
