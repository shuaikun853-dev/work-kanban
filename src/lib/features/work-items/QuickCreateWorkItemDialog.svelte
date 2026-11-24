<script lang="ts">
  import type { ProjectDto } from '../../contracts/projects';
  import { normalizeWorkItemTitle } from '../../contracts/workItemTitle';
  import Button from '../../ui/components/Button.svelte';

  interface CreateFailure {
    readonly code: string;
    readonly message: string;
  }

  interface Props {
    open: boolean;
    /** 可选的未归档项目（安全边界在 Rust Core 事务内，前端过滤只用于展示）。 */
    projects: readonly ProjectDto[];
    projectsLoading?: boolean;
    projectsError?: string | null;
    submitting?: boolean;
    error?: CreateFailure | null;
    /** 0 个项目 = 未归属；1 个项目 = 单条创建；2+ 个项目 = 批量创建独立副本。 */
    onSubmit: (title: string, projectIds: string[]) => void;
    onCancel: () => void;
  }

  let {
    open,
    projects,
    projectsLoading = false,
    projectsError = null,
    submitting = false,
    error = null,
    onSubmit,
    onCancel
  }: Props = $props();

  let dialogElement = $state<HTMLDialogElement | null>(null);
  let titleInput = $state<HTMLInputElement | null>(null);
  let title = $state('');
  /** 已选择的项目 ID；空数组表示“未归属项目”。 */
  let selectedProjectIds = $state<string[]>([]);
  /** 选择时记住项目名称，供项目后来失效时仍能向用户展示原选择（不自动删除）。 */
  let knownProjectNames = $state<Record<string, string>>({});
  let touched = $state(false);

  /** 使用与 Rust Core 相同的 Unicode White_Space 规则，不能使用 JS `trim()`。 */
  const normalizedTitle = $derived(normalizeWorkItemTitle(title));
  const availableProjectIds = $derived(new Set(projects.map((project) => project.id)));
  /** 项目列表成功刷新后仍不在可选列表中的已选项目：保留展示，禁止自动移除。 */
  const invalidProjectIds = $derived(
    !projectsLoading && projectsError === null
      ? selectedProjectIds.filter((projectId) => !availableProjectIds.has(projectId))
      : []
  );
  const hasInvalidSelection = $derived(invalidProjectIds.length > 0);
  const expectedCopyCount = $derived(
    selectedProjectIds.length === 0 ? 1 : selectedProjectIds.length
  );
  const createMode = $derived(
    selectedProjectIds.length === 0
      ? 'unassigned'
      : selectedProjectIds.length === 1
        ? 'single'
        : 'copies'
  );
  const selectionSummary = $derived(
    selectedProjectIds.length === 0
      ? '未选择项目，将创建 1 项未归属工作'
      : selectedProjectIds.length === 1
        ? '已选择 1 个项目，将创建 1 项独立工作'
        : `已选择 ${selectedProjectIds.length} 个项目，将创建 ${selectedProjectIds.length} 项独立工作`
  );
  const canSubmit = $derived(
    normalizedTitle.length > 0 &&
      !submitting &&
      !projectsLoading &&
      !hasInvalidSelection
  );
  const showEmptyHint = $derived(touched && normalizedTitle.length === 0 && !submitting);

  $effect(() => {
    const dialog = dialogElement;
    if (dialog === null) {
      return;
    }

    if (open) {
      if (!dialog.open) {
        title = '';
        selectedProjectIds = [];
        knownProjectNames = {};
        touched = false;
        dialog.showModal();
        queueMicrotask(() => titleInput?.focus());
      }
    } else if (dialog.open) {
      dialog.close();
    }
  });

  function projectLabel(projectId: string): string {
    const name = knownProjectNames[projectId];
    if (typeof name === 'string' && name.length > 0) {
      return name;
    }
    return `项目 ${projectId.slice(0, 8)}…`;
  }

  function clearProjects(): void {
    if (submitting) {
      return;
    }
    selectedProjectIds = [];
  }

  function toggleProject(project: ProjectDto): void {
    if (submitting || projectsLoading) {
      return;
    }
    if (selectedProjectIds.includes(project.id)) {
      selectedProjectIds = selectedProjectIds.filter((projectId) => projectId !== project.id);
      return;
    }
    knownProjectNames = { ...knownProjectNames, [project.id]: project.name };
    selectedProjectIds = [...selectedProjectIds, project.id];
  }

  /** 失效项目必须由用户主动移除；不提供自动删除或自动替换。 */
  function removeInvalidProject(projectId: string): void {
    if (submitting) {
      return;
    }
    selectedProjectIds = selectedProjectIds.filter((selected) => selected !== projectId);
  }

  function handleSubmit(event: SubmitEvent): void {
    event.preventDefault();
    touched = true;
    if (!canSubmit) {
      return;
    }
    onSubmit(normalizedTitle, [...selectedProjectIds]);
  }

  function requestCancel(): void {
    if (!submitting) {
      onCancel();
    }
  }
</script>

<dialog
  bind:this={dialogElement}
  class="quick-create-dialog"
  aria-labelledby="work-item-dialog-title"
  aria-describedby="work-item-dialog-description"
  data-create-mode={createMode}
  oncancel={(event) => {
    event.preventDefault();
    requestCancel();
  }}
  onclick={(event) => {
    if (event.target === dialogElement) {
      requestCancel();
    }
  }}
>
  <form class="dialog-form" onsubmit={handleSubmit}>
    <div class="dialog-body">
      <h2 id="work-item-dialog-title" class="dialog-title">快速创建工作</h2>
      <p id="work-item-dialog-description" class="dialog-description">
        只需填写标题即可保存；选择一个项目创建单条工作，选择多个项目将为每个项目创建独立副本。
      </p>

      <label class="field" for="work-item-title">
        <span class="field-label">工作标题</span>
        <input
          bind:this={titleInput}
          bind:value={title}
          id="work-item-title"
          class="field-input"
          type="text"
          autocomplete="off"
          spellcheck="false"
          placeholder="例如：整理中核商品数据"
          disabled={submitting}
          aria-invalid={showEmptyHint}
          aria-describedby={showEmptyHint ? 'work-item-title-hint' : undefined}
          onblur={() => {
            touched = true;
          }}
        />
      </label>
      {#if showEmptyHint}
        <p class="field-hint field-hint--error" id="work-item-title-hint">工作标题不能为空。</p>
      {/if}

      <fieldset class="field project-field" disabled={submitting || projectsLoading}>
        <legend class="field-label">所属项目（可选，可多选）</legend>
        <div class="project-options" id="work-item-project-options">
          <label class="project-option">
            <input
              type="checkbox"
              class="project-option__checkbox"
              checked={selectedProjectIds.length === 0}
              aria-label="未归属项目"
              data-project-unassigned
              onclick={(event) => {
                event.preventDefault();
                clearProjects();
              }}
            />
            <span class="project-option__label">未归属项目</span>
          </label>
          {#each projects as project (project.id)}
            <label class="project-option">
              <input
                type="checkbox"
                class="project-option__checkbox"
                checked={selectedProjectIds.includes(project.id)}
                data-project-id={project.id}
                onclick={(event) => {
                  event.preventDefault();
                  toggleProject(project);
                }}
              />
              <span class="project-option__label">{project.name}</span>
            </label>
          {/each}
        </div>
      </fieldset>

      <p class="selection-summary" role="status">
        <span data-selected-project-count={selectedProjectIds.length}>{selectionSummary}</span>
        <span class="selection-summary__expected" data-expected-copy-count={expectedCopyCount}>
          预计创建 {expectedCopyCount} 项
        </span>
      </p>

      {#if projectsLoading}
        <p class="field-hint">正在读取可选项目…</p>
      {:else if projectsError}
        <p class="field-hint field-hint--warning">{projectsError}</p>
      {/if}

      {#if hasInvalidSelection}
        <div class="invalid-selection" role="alert" data-invalid-project-selections>
          <p class="invalid-selection__title">以下已选项目已不可用（可能已被归档或删除）：</p>
          <ul class="invalid-selection__list">
            {#each invalidProjectIds as projectId (projectId)}
              <li class="invalid-selection__item">
                <span class="invalid-selection__name">{projectLabel(projectId)}</span>
                <button
                  type="button"
                  class="invalid-selection__remove"
                  disabled={submitting}
                  onclick={() => removeInvalidProject(projectId)}
                >
                  移除
                </button>
              </li>
            {/each}
          </ul>
          <p class="invalid-selection__hint">请主动移除失效项目或调整选择后重新提交；不会自动创建剩余项目。</p>
        </div>
      {/if}

      {#if error}
        <div class="dialog-error" role="alert">
          <p>{error.message}</p>
          <p class="dialog-error-code">错误码：{error.code}</p>
        </div>
      {/if}
    </div>

    <div class="dialog-actions">
      <Button variant="secondary" onclick={requestCancel} disabled={submitting}>取消</Button>
      <Button type="submit" loading={submitting} disabled={!canSubmit}>保存</Button>
    </div>
  </form>
</dialog>

<style>
  .quick-create-dialog {
    width: min(92vw, 480px);
    max-height: 90vh;
    margin: auto;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xl);
    background-color: var(--color-surface);
    box-shadow: var(--shadow-dialog);
    color: var(--color-text-primary);
  }

  .quick-create-dialog::backdrop {
    background-color: var(--color-backdrop);
  }

  .dialog-form {
    display: flex;
    flex-direction: column;
  }

  .dialog-body {
    padding: var(--space-6) var(--space-6) var(--space-2);
    overflow-y: auto;
  }

  .dialog-title {
    font-size: var(--font-size-section-title);
    font-weight: 700;
    letter-spacing: -0.01em;
  }

  .dialog-description {
    margin-top: var(--space-1);
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-top: var(--space-5);
  }

  .field-label {
    color: var(--color-text-primary);
    font-size: var(--font-size-auxiliary);
    font-weight: 600;
  }

  .field-input {
    width: 100%;
    min-height: 38px;
    padding: 8px 12px;
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius-md);
    background-color: var(--color-surface);
    color: var(--color-text-primary);
    font-size: var(--font-size-body);
  }

  .field-input:focus {
    border-color: var(--color-accent);
    outline: var(--focus-ring);
    outline-offset: 1px;
  }

  .field-input[aria-invalid='true'] {
    border-color: var(--color-danger);
  }

  .project-field {
    margin: 0;
    padding: 0;
    border: 0;
    min-width: 0;
  }

  .project-options {
    display: flex;
    flex-direction: column;
    gap: 2px;
    max-height: 188px;
    padding: 6px;
    overflow-y: auto;
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius-md);
    background-color: var(--color-surface);
  }

  .project-option {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: 6px 8px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: var(--font-size-body);
  }

  .project-option:hover {
    background-color: var(--color-surface-hover);
  }

  .project-option__checkbox {
    width: 15px;
    height: 15px;
    margin: 0;
    accent-color: var(--color-accent);
    flex: none;
  }

  .project-option__checkbox:focus-visible {
    outline: var(--focus-ring);
    outline-offset: var(--focus-ring-offset);
  }

  .project-option__label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .selection-summary {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-2);
    margin-top: var(--space-3);
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
  }

  .selection-summary__expected {
    color: var(--color-accent-strong);
    font-weight: 600;
  }

  .invalid-selection {
    margin-top: var(--space-3);
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-warning-border);
    border-radius: var(--radius-sm);
    background-color: var(--color-warning-bg);
    color: var(--color-warning-text);
    font-size: var(--font-size-auxiliary);
  }

  .invalid-selection__title {
    font-weight: 600;
  }

  .invalid-selection__list {
    margin: var(--space-1) 0 0;
    padding: 0;
    list-style: none;
  }

  .invalid-selection__item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
    padding: 2px 0;
  }

  .invalid-selection__name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .invalid-selection__remove {
    padding: 1px 6px;
    border: 1px solid var(--color-warning-border);
    border-radius: var(--radius-pill);
    background-color: var(--color-surface);
    color: var(--color-warning-text);
    font-size: var(--font-size-caption);
    cursor: pointer;
  }

  .invalid-selection__remove:focus-visible {
    outline: var(--focus-ring);
    outline-offset: var(--focus-ring-offset);
  }

  .invalid-selection__hint {
    margin-top: var(--space-1);
    color: var(--color-warning-text);
    font-size: var(--font-size-caption);
  }

  .field-hint {
    margin-top: 6px;
    color: var(--color-text-secondary);
    font-size: var(--font-size-caption);
  }

  .field-hint--error {
    color: var(--color-danger-text);
  }

  .field-hint--warning {
    color: var(--color-warning-text);
  }

  .dialog-error {
    margin-top: var(--space-3);
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-danger-border);
    border-radius: var(--radius-sm);
    background-color: var(--color-danger-bg);
    color: var(--color-danger-text);
    font-size: var(--font-size-auxiliary);
    overflow-wrap: anywhere;
  }

  .dialog-error-code {
    margin-top: 2px;
    color: var(--color-text-secondary);
    font-family: var(--font-mono);
    font-size: var(--font-size-caption);
  }

  .dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    padding: var(--space-4) var(--space-6) var(--space-5);
  }
</style>
