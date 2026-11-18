<script lang="ts">
  import { onMount } from 'svelte';

  import {
    ProjectIpcError,
    archiveProject,
    createProject,
    listProjects,
    updateProject
  } from '../../bridge/projects';
  import type { ProjectDto } from '../../contracts/projects';
  import Button from '../../ui/components/Button.svelte';
  import EmptyState from '../../ui/components/EmptyState.svelte';
  import PageHeader from '../../ui/components/PageHeader.svelte';
  import ConfirmArchiveDialog from './ConfirmArchiveDialog.svelte';
  import ProjectFormDialog from './ProjectFormDialog.svelte';
  import ProjectList from './ProjectList.svelte';

  interface LoadFailure {
    readonly code: string;
    readonly message: string;
  }

  type FormState = { readonly mode: 'create' } | { readonly mode: 'edit'; readonly project: ProjectDto };

  let projects = $state<ProjectDto[] | null>(null);
  let loading = $state(true);
  let refreshing = $state(false);
  let failure = $state<LoadFailure | null>(null);

  let form = $state<FormState | null>(null);
  let submitting = $state(false);
  let formError = $state<string | null>(null);

  let archiveTarget = $state<ProjectDto | null>(null);
  let archiveSubmitting = $state(false);
  let archiveError = $state<string | null>(null);

  const busy = $derived(refreshing || submitting || archiveSubmitting);
  const formMode = $derived(form?.mode ?? 'create');
  const formInitialName = $derived(form?.mode === 'edit' ? form.project.name : '');

  function toFailure(cause: unknown): LoadFailure {
    if (cause instanceof ProjectIpcError) {
      return { code: cause.code, message: cause.message };
    }
    if (cause instanceof Error && cause.message.trim().length > 0) {
      return { code: 'frontend-unexpected-error', message: cause.message };
    }
    return {
      code: 'frontend-unexpected-error',
      message: '处理项目请求时发生未知异常，请重试。'
    };
  }

  async function loadProjectList(showLoading: boolean): Promise<void> {
    if (showLoading) {
      loading = true;
    } else {
      refreshing = true;
    }
    failure = null;

    try {
      projects = await listProjects();
    } catch (cause: unknown) {
      failure = toFailure(cause);
    } finally {
      loading = false;
      refreshing = false;
    }
  }

  /**
   * 写操作成功后的权威刷新：重新从 Rust Core 读取项目列表。
   * 前端不自行推导排序或归档状态，避免出现与数据库不一致的副本。
   */
  async function reloadAfterMutation(): Promise<void> {
    try {
      projects = await listProjects();
      failure = null;
    } catch (cause: unknown) {
      failure = toFailure(cause);
    }
  }

  onMount(() => {
    void loadProjectList(true);
  });

  function openCreateDialog(): void {
    formError = null;
    form = { mode: 'create' };
  }

  function openEditDialog(project: ProjectDto): void {
    formError = null;
    form = { mode: 'edit', project };
  }

  function closeFormDialog(): void {
    if (!submitting) {
      form = null;
      formError = null;
    }
  }

  function openArchiveDialog(project: ProjectDto): void {
    archiveError = null;
    archiveTarget = project;
  }

  function closeArchiveDialog(): void {
    if (!archiveSubmitting) {
      archiveTarget = null;
      archiveError = null;
    }
  }

  async function submitForm(name: string): Promise<void> {
    if (form === null || submitting) {
      return;
    }

    const current = form;
    submitting = true;
    formError = null;
    try {
      if (current.mode === 'create') {
        await createProject(name);
      } else {
        await updateProject(current.project.id, name);
      }
      form = null;
      await reloadAfterMutation();
    } catch (cause: unknown) {
      formError = toFailure(cause).message;
    } finally {
      submitting = false;
    }
  }

  async function confirmArchive(): Promise<void> {
    if (archiveTarget === null || archiveSubmitting) {
      return;
    }

    archiveSubmitting = true;
    archiveError = null;
    try {
      await archiveProject(archiveTarget.id);
      archiveTarget = null;
      await reloadAfterMutation();
    } catch (cause: unknown) {
      archiveError = toFailure(cause).message;
    } finally {
      archiveSubmitting = false;
    }
  }
</script>

<svelte:head>
  <title>项目管理 · WorkManager</title>
</svelte:head>

<PageHeader
  title="项目管理"
  subtitle="创建、编辑和归档项目；归档只隐藏项目，不删除已有工作历史。"
>
  {#snippet actions()}
    <Button onclick={openCreateDialog}>新建项目</Button>
  {/snippet}
</PageHeader>

{#if failure !== null}
  <div class="error-panel" role="alert">
    <div class="error-body">
      <p class="error-title">项目列表加载失败</p>
      <p class="error-message">{failure.message}</p>
      <p class="error-code">错误码：{failure.code}</p>
    </div>
    <Button
      variant="secondary"
      onclick={() => void loadProjectList(projects === null)}
      disabled={loading || refreshing}
      loading={loading || refreshing}
    >
      重新加载
    </Button>
  </div>
{/if}

{#if loading && projects === null}
  <div class="loading-panel" role="status" aria-live="polite">
    <span class="spinner" aria-hidden="true"></span>
    <span>正在读取项目…</span>
  </div>
{:else if projects !== null && projects.length === 0}
  <EmptyState title="暂无项目" description="创建第一个项目，开始整理你的工作。">
    {#snippet action()}
      <Button onclick={openCreateDialog}>创建第一个项目</Button>
    {/snippet}
  </EmptyState>
{:else if projects !== null}
  <ProjectList
    projects={projects}
    {busy}
    onEdit={openEditDialog}
    onArchive={openArchiveDialog}
  />
  {#if refreshing}
    <p class="refresh-hint" role="status">正在同步项目列表…</p>
  {/if}
{/if}

<ProjectFormDialog
  open={form !== null}
  mode={formMode}
  initialName={formInitialName}
  submitting={submitting}
  errorMessage={formError}
  onSubmit={(name) => void submitForm(name)}
  onCancel={closeFormDialog}
/>

<ConfirmArchiveDialog
  open={archiveTarget !== null}
  projectName={archiveTarget?.name ?? ''}
  submitting={archiveSubmitting}
  errorMessage={archiveError}
  onConfirm={() => void confirmArchive()}
  onCancel={closeArchiveDialog}
/>

<style>
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
    animation: project-spin 0.8s linear infinite;
  }

  @keyframes project-spin {
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
    margin-bottom: var(--space-4);
    padding: var(--space-4);
    border: 1px solid #f3c6c1;
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
