<script lang="ts">
  import { onMount } from 'svelte';

  import { ProjectIpcError, listProjects } from '../../bridge/projects';
  import {
    WorkItemIpcError,
    createWorkItem,
    listPendingWorkItems
  } from '../../bridge/workItems';
  import type { ProjectDto } from '../../contracts/projects';
  import type { PendingWorkItemDto } from '../../contracts/workItems';
  import Button from '../../ui/components/Button.svelte';
  import EmptyState from '../../ui/components/EmptyState.svelte';
  import PendingWorkItemList from './PendingWorkItemList.svelte';
  import QuickCreateWorkItemDialog from './QuickCreateWorkItemDialog.svelte';

  interface ViewFailure {
    readonly code: string;
    readonly message: string;
  }

  /** 待安排列表数据（`null` = 尚未成功加载）。 */
  let pendingWorkItems = $state<PendingWorkItemDto[] | null>(null);
  let loading = $state(true);
  let refreshing = $state(false);
  let failure = $state<ViewFailure | null>(null);

  /** 快速创建对话框状态。 */
  let createOpen = $state(false);
  let creating = $state(false);
  let createError = $state<ViewFailure | null>(null);
  let createdNotice = $state<string | null>(null);

  /** 创建对话框的项目选项：只包含未归档项目；安全边界在 Rust Core 事务内，不依赖前端过滤。 */
  let projectOptions = $state<ProjectDto[]>([]);
  let projectsLoading = $state(false);
  let projectsError = $state<string | null>(null);

  const countLabel = $derived(
    pendingWorkItems === null ? '正在读取' : `共 ${pendingWorkItems.length} 项`
  );

  function toFailure(cause: unknown): ViewFailure {
    if (cause instanceof WorkItemIpcError) {
      return { code: cause.code, message: cause.message };
    }
    if (cause instanceof Error && cause.message.trim().length > 0) {
      return { code: 'frontend-unexpected-error', message: cause.message };
    }
    return {
      code: 'frontend-unexpected-error',
      message: '处理工作事项请求时发生未知异常，请重试。'
    };
  }

  /** 权威读取：待安排列表只来自 SQLite，前端不自行插入临时对象。 */
  async function loadPending(showLoading: boolean): Promise<void> {
    if (showLoading) {
      loading = true;
    } else {
      refreshing = true;
    }
    failure = null;

    try {
      pendingWorkItems = await listPendingWorkItems();
    } catch (cause: unknown) {
      failure = toFailure(cause);
    } finally {
      loading = false;
      refreshing = false;
    }
  }

  async function loadProjectOptions(): Promise<void> {
    projectsLoading = true;
    projectsError = null;
    try {
      const projects = await listProjects();
      // 项目选择器只展示未归档项目；已归档项目不得作为新工作的可选项。
      // 这不是安全边界：提交时 Rust Core 会在创建事务内再次校验（DEC-033）。
      projectOptions = projects.filter((project) => !project.isArchived);
    } catch (cause: unknown) {
      projectOptions = [];
      const code =
        cause instanceof ProjectIpcError ? cause.code : 'frontend-unexpected-error';
      projectsError = `项目列表加载失败（错误码：${code}），仍可创建未归属项目。`;
    } finally {
      projectsLoading = false;
    }
  }

  function openCreateDialog(): void {
    if (creating) {
      return;
    }
    createError = null;
    createdNotice = null;
    createOpen = true;
    void loadProjectOptions();
  }

  function closeCreateDialog(): void {
    if (!creating) {
      createOpen = false;
      createError = null;
    }
  }

  async function submitCreate(title: string, projectId: string | null): Promise<void> {
    // 同步守卫：同一个事件循环内的重复点击不会产生第二次创建请求。
    if (creating || !createOpen) {
      return;
    }
    creating = true;
    createError = null;

    try {
      await createWorkItem(title, projectId);
      createOpen = false;
      createdNotice = '工作已创建，待安排列表已从数据库重新读取。';
      await loadPending(false);
    } catch (cause: unknown) {
      createError = toFailure(cause);
      // 项目在列表加载后、提交前被归档/删除：Core 拒绝创建；刷新选项与待安排列表，
      // 让失效项目从选择器消失，并让历史关联的“项目已归档”标识基于数据库最新状态展示。
      if (createError.code === 'project-archived' || createError.code === 'project-not-found') {
        await loadProjectOptions();
        await loadPending(false);
      }
    } finally {
      creating = false;
    }
  }

  onMount(() => {
    void loadPending(true);
  });
</script>

<section class="pending-view" aria-labelledby="pending-work-title">
  <div class="pending-toolbar">
    <div class="pending-heading">
      <h2 id="pending-work-title">待安排</h2>
      <p class="pending-count">{countLabel}</p>
    </div>
    <Button onclick={openCreateDialog} disabled={creating}>新增工作</Button>
  </div>

  {#if createdNotice}
    <p class="created-notice" role="status">{createdNotice}</p>
  {/if}

  {#if failure !== null}
    <div class="error-panel" role="alert">
      <div class="error-body">
        <p class="error-title">待安排工作加载失败</p>
        <p class="error-message">{failure.message}</p>
        <p class="error-code">错误码：{failure.code}</p>
      </div>
      <Button
        variant="secondary"
        onclick={() => void loadPending(pendingWorkItems === null)}
        disabled={loading || refreshing}
        loading={loading || refreshing}
      >
        重新加载
      </Button>
    </div>
  {:else if loading && pendingWorkItems === null}
    <div class="loading-panel" role="status" aria-live="polite">
      <span class="spinner" aria-hidden="true"></span>
      <span>正在读取待安排工作…</span>
    </div>
  {:else if pendingWorkItems !== null && pendingWorkItems.length === 0}
    <EmptyState
      title="暂无待安排工作"
      description="创建一项工作，它会立即进入待安排，直到你安排具体日期。"
    >
      {#snippet action()}
        <Button onclick={openCreateDialog}>创建第一项工作</Button>
      {/snippet}
    </EmptyState>
  {:else if pendingWorkItems !== null}
    <PendingWorkItemList workItems={pendingWorkItems} />
    {#if refreshing}
      <p class="refresh-hint" role="status">正在同步待安排列表…</p>
    {/if}
  {/if}
</section>

<QuickCreateWorkItemDialog
  open={createOpen}
  projects={projectOptions}
  projectsLoading={projectsLoading}
  projectsError={projectsError}
  submitting={creating}
  error={createError}
  onSubmit={(title, projectId) => void submitCreate(title, projectId)}
  onCancel={closeCreateDialog}
/>

<style>
  .pending-view {
    min-width: 0;
  }

  .pending-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    margin-bottom: var(--space-3);
  }

  .pending-heading {
    display: flex;
    align-items: baseline;
    gap: var(--space-2);
    min-width: 0;
  }

  h2 {
    color: var(--color-text-primary);
    font-size: var(--font-size-section-title);
    font-weight: 600;
  }

  .pending-count {
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
  }

  .created-notice {
    margin-bottom: var(--space-3);
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-success-border);
    border-radius: var(--radius-sm);
    background-color: var(--color-success-bg);
    color: var(--color-success-text);
    font-size: var(--font-size-auxiliary);
  }

  .loading-panel {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-5) var(--space-4);
    border: 1px solid var(--color-divider);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
  }

  .spinner {
    width: 18px;
    height: 18px;
    border: 2px solid var(--color-border-strong);
    border-top-color: var(--color-accent);
    border-radius: 50%;
    animation: pending-spin 0.8s linear infinite;
  }

  @keyframes pending-spin {
    to {
      transform: rotate(360deg);
    }
  }

  .error-panel {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-4);
    border: 1px solid var(--color-danger-border);
    border-radius: var(--radius-lg);
    background-color: var(--color-danger-bg);
  }

  .error-body {
    min-width: 0;
  }

  .error-title {
    color: var(--color-danger-text);
    font-size: var(--font-size-body);
    font-weight: 700;
  }

  .error-message {
    margin-top: 2px;
    color: var(--color-text-primary);
    font-size: var(--font-size-auxiliary);
    overflow-wrap: anywhere;
  }

  .error-code {
    margin-top: var(--space-1);
    color: var(--color-text-secondary);
    font-family: var(--font-mono);
    font-size: var(--font-size-caption);
  }

  .refresh-hint {
    margin-top: var(--space-2);
    color: var(--color-text-secondary);
    font-size: var(--font-size-caption);
  }
</style>
