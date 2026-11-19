<script lang="ts">
  import type { ProjectDto } from '../../contracts/projects';
  import Button from '../../ui/components/Button.svelte';

  interface CreateFailure {
    readonly code: string;
    readonly message: string;
  }

  interface Props {
    open: boolean;
    projects: readonly ProjectDto[];
    projectsLoading?: boolean;
    projectsError?: string | null;
    submitting?: boolean;
    error?: CreateFailure | null;
    onSubmit: (title: string, projectId: string | null) => void;
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
  let selectedProjectId = $state('');
  let touched = $state(false);
  let selectionResetNotice = $state<string | null>(null);

  const trimmedTitle = $derived(title.trim());
  const canSubmit = $derived(trimmedTitle.length > 0 && !submitting);
  const showEmptyHint = $derived(touched && trimmedTitle.length === 0 && !submitting);

  $effect(() => {
    const dialog = dialogElement;
    if (dialog === null) {
      return;
    }

    if (open) {
      if (!dialog.open) {
        title = '';
        selectedProjectId = '';
        touched = false;
        selectionResetNotice = null;
        dialog.showModal();
        queueMicrotask(() => titleInput?.focus());
      }
    } else if (dialog.open) {
      dialog.close();
    }
  });

  // 项目列表刷新后（例如提交时项目刚被归档），若当前选择已不可用，回退为未归属项目，
  // 由用户决定是否重新选择；不会自动提交或静默改写已提交的标题。
  $effect(() => {
    if (!open || selectedProjectId.length === 0) {
      return;
    }
    if (projects.some((project) => project.id === selectedProjectId)) {
      return;
    }
    selectedProjectId = '';
    selectionResetNotice = '所选项目已不可用（可能已被归档），已改为未归属项目。';
  });

  function handleSubmit(event: SubmitEvent): void {
    event.preventDefault();
    touched = true;
    if (!canSubmit) {
      return;
    }
    onSubmit(trimmedTitle, selectedProjectId.length === 0 ? null : selectedProjectId);
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
        只需填写标题即可保存；工作会立即进入待安排。
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

      <label class="field" for="work-item-project">
        <span class="field-label">所属项目（可选）</span>
        <select
          id="work-item-project"
          class="field-select"
          bind:value={selectedProjectId}
          disabled={submitting || projectsLoading}
        >
          <option value="">未归属项目</option>
          {#each projects as project (project.id)}
            <option value={project.id}>{project.name}</option>
          {/each}
        </select>
      </label>
      {#if projectsLoading}
        <p class="field-hint">正在读取可选项目…</p>
      {:else if projectsError}
        <p class="field-hint field-hint--warning">{projectsError}</p>
      {/if}
      {#if selectionResetNotice}
        <p class="field-hint field-hint--warning" role="status">{selectionResetNotice}</p>
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
    width: min(92vw, 460px);
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

  .field-input,
  .field-select {
    width: 100%;
    min-height: 38px;
    padding: 8px 12px;
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius-md);
    background-color: var(--color-surface);
    color: var(--color-text-primary);
    font-size: var(--font-size-body);
  }

  .field-input:focus,
  .field-select:focus {
    border-color: var(--color-accent);
    outline: var(--focus-ring);
    outline-offset: 1px;
  }

  .field-input[aria-invalid='true'] {
    border-color: var(--color-danger);
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
