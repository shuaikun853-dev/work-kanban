<script lang="ts">
  import { onMount } from 'svelte';

  import { ProjectIpcError, listProjects } from '../../bridge/projects';
  import {
    WorkItemIpcError,
    createWorkItem,
    createWorkItemCopies,
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

  /**
   * 创建成功与列表刷新结果分开记录，避免把“创建成功”误报成“列表已刷新成功”：
   * - success：创建成功且随后从后端重新读取待安排列表成功；
   * - warning：创建成功但列表刷新失败（不得再次创建同一工作，只允许重试读取）。
   *
   * T1-04：批量创建时必须显示后端返回的实际创建数量（而不是前端预计数量）。
   */
  type CreateOutcome = {
    readonly kind: 'success' | 'warning';
    readonly text: string;
  };

  /** 待安排列表数据（`null` = 尚未成功加载）。 */
  let pendingWorkItems = $state<PendingWorkItemDto[] | null>(null);
  let loading = $state(true);
  let refreshing = $state(false);
  let failure = $state<ViewFailure | null>(null);

  /** 快速创建对话框状态。 */
  let createOpen = $state(false);
  let creating = $state(false);
  let createError = $state<ViewFailure | null>(null);
  let createOutcome = $state<CreateOutcome | null>(null);

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

  /**
   * 权威读取：待安排列表只来自 SQLite，前端不自行插入临时对象。
   *
   * 返回 true 表示读取成功；false 表示失败（具体错误写入 `failure`）。
   * 该返回值用于区分“创建成功 + 列表刷新成功”与“创建成功 + 列表刷新失败”，
   * 调用方不得在失败时显示“列表已更新”。
   */
  async function loadPending(showLoading: boolean): Promise<boolean> {
    if (showLoading) {
      loading = true;
    } else {
      refreshing = true;
    }
    failure = null;

    try {
      pendingWorkItems = await listPendingWorkItems();
      return true;
    } catch (cause: unknown) {
      failure = toFailure(cause);
      return false;
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
    createOpen = true;
    void loadProjectOptions();
  }

  function closeCreateDialog(): void {
    if (!creating) {
      createOpen = false;
      createError = null;
    }
  }

  /**
   * 创建编排（T1-04）：
   * - 0 个项目：T1-03 未归属创建工作，调用单条接口；
   * - 1 个项目：T1-03 单项目创建工作，调用单条接口；
   * - 2 个及以上项目：调用批量接口，整批原子创建独立副本（DEC-034）。
   *
   * 失败时保留对话框中的标题与全部原始选择（对话框组件自身状态），
   * 刷新项目列表让失效项目明确标出，但绝不自动移除后创建剩余项目。
   */
  async function submitCreate(title: string, projectIds: string[]): Promise<void> {
    // 同步守卫：同一个事件循环内的重复点击不会产生第二次创建请求。
    if (creating || !createOpen) {
      return;
    }
    creating = true;
    createError = null;

    try {
      let createdCount = 1;
      if (projectIds.length >= 2) {
        const created = await createWorkItemCopies(title, projectIds);
        // 使用后端权威数量，而不是前端预计数量。
        createdCount = created.workItems.length;
      } else {
        await createWorkItem(title, projectIds.length === 1 ? projectIds[0] : null);
      }
      // 创建已成功：立即关闭创建弹窗，并明确告知“正在刷新”，不提前宣称列表已更新。
      createOpen = false;
      createOutcome = {
        kind: 'success',
        text: `已创建 ${createdCount} 项工作，正在从数据库刷新待安排列表…`
      };

      const refreshed = await loadPending(false);
      if (refreshed) {
        createOutcome = {
          kind: 'success',
          text: `已创建 ${createdCount} 项独立工作，待安排列表已从数据库更新。`
        };
      } else {
        // 创建成功但刷新失败：不得再次创建同一工作，只提示用户重试读取。
        createOutcome = {
          kind: 'warning',
          text: `已创建 ${createdCount} 项工作，但待安排列表刷新失败；请使用“重新加载”确认最新状态。`
        };
      }
    } catch (cause: unknown) {
      createError = toFailure(cause);
      // 项目在对话框打开后、提交前被归档/删除：整批已回滚；刷新项目选项，
      // 让失效项目在对话框中继续保留并标记为不可用，由用户主动移除或调整。
      if (createError.code === 'project-archived' || createError.code === 'project-not-found') {
        await loadProjectOptions();
        await loadPending(false);
      }
    } finally {
      creating = false;
    }
  }

  /** 重新读取待安排列表；若此前是“创建成功但刷新失败”，成功后更新状态提示。 */
  async function retryLoad(): Promise<void> {
    const refreshed = await loadPending(pendingWorkItems === null);
    if (!refreshed) {
      if (createOutcome?.kind === 'warning') {
        createOutcome = {
          kind: 'warning',
          text: '工作已创建，但待安排列表刷新仍然失败；请稍后再次重新加载。'
        };
      }
      return;
    }
    if (createOutcome !== null) {
      createOutcome = {
        kind: 'success',
        text: '待安排列表已从数据库重新读取。'
      };
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

  {#if createOutcome}
    <p
      class="created-notice"
      class:created-notice--warning={createOutcome.kind === 'warning'}
      role="status"
      data-create-outcome={createOutcome.kind}
    >
      {createOutcome.text}
    </p>
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
        onclick={() => void retryLoad()}
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
  onSubmit={(title, projectIds) => void submitCreate(title, projectIds)}
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

  .created-notice--warning {
    border-color: var(--color-warning-border);
    background-color: var(--color-warning-bg);
    color: var(--color-warning-text);
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
