<script lang="ts">
  import Button from '../../ui/components/Button.svelte';

  interface Props {
    open: boolean;
    mode: 'create' | 'edit';
    initialName?: string;
    submitting?: boolean;
    errorMessage?: string | null;
    onSubmit: (name: string) => void;
    onCancel: () => void;
  }

  let {
    open,
    mode,
    initialName = '',
    submitting = false,
    errorMessage = null,
    onSubmit,
    onCancel
  }: Props = $props();

  let dialogElement = $state<HTMLDialogElement | null>(null);
  let inputElement = $state<HTMLInputElement | null>(null);
  let name = $state('');
  let touched = $state(false);

  const trimmedName = $derived(name.trim());
  const canSubmit = $derived(trimmedName.length > 0 && !submitting);
  const showEmptyHint = $derived(touched && trimmedName.length === 0 && !submitting);

  $effect(() => {
    const dialog = dialogElement;
    if (dialog === null) {
      return;
    }

    if (open) {
      name = initialName;
      touched = false;
      if (!dialog.open) {
        dialog.showModal();
        queueMicrotask(() => {
          inputElement?.focus();
          inputElement?.select();
        });
      }
    } else if (dialog.open) {
      dialog.close();
    }
  });

  function handleSubmit(event: SubmitEvent): void {
    event.preventDefault();
    touched = true;
    if (canSubmit) {
      onSubmit(trimmedName);
    }
  }

  function requestCancel(): void {
    if (!submitting) {
      onCancel();
    }
  }
</script>

<dialog
  bind:this={dialogElement}
  class="project-dialog"
  aria-labelledby="project-dialog-title"
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
      <h2 id="project-dialog-title" class="dialog-title">
        {mode === 'create' ? '新建项目' : '编辑项目'}
      </h2>
      <p class="dialog-description">
        {mode === 'create'
          ? '项目用于归类工作事项；项目名称可以稍后修改。'
          : '修改项目名称不会改变项目 ID，也不会影响已有历史。'}
      </p>

      <label class="field" for="project-name">
        <span class="field-label">项目名称</span>
        <input
          bind:this={inputElement}
          bind:value={name}
          id="project-name"
          class="field-input"
          type="text"
          autocomplete="off"
          spellcheck="false"
          disabled={submitting}
          aria-invalid={showEmptyHint}
          aria-describedby={showEmptyHint ? 'project-name-hint' : undefined}
          onblur={() => {
            touched = true;
          }}
        />
      </label>

      {#if showEmptyHint}
        <p class="field-hint field-hint--error" id="project-name-hint">项目名称不能为空。</p>
      {/if}
      {#if errorMessage}
        <p class="dialog-error" role="alert">{errorMessage}</p>
      {/if}
    </div>

    <div class="dialog-actions">
      <Button variant="secondary" onclick={requestCancel} disabled={submitting}>取消</Button>
      <Button type="submit" loading={submitting} disabled={!canSubmit}>
        {mode === 'create' ? '创建项目' : '保存修改'}
      </Button>
    </div>
  </form>
</dialog>

<style>
  .project-dialog {
    width: min(92vw, 440px);
    max-height: 90vh;
    margin: auto;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xl);
    background-color: var(--color-surface);
    box-shadow: var(--shadow-dialog);
    color: var(--color-text-primary);
  }

  .project-dialog::backdrop {
    background-color: rgba(15, 23, 42, 0.28);
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

  .field-hint {
    margin-top: 6px;
    font-size: var(--font-size-caption);
  }

  .field-hint--error {
    color: var(--color-danger-text);
  }

  .dialog-error {
    margin-top: var(--space-3);
    padding: var(--space-2) var(--space-3);
    border: 1px solid #f3c6c1;
    border-radius: var(--radius-sm);
    background-color: var(--color-danger-bg);
    color: var(--color-danger-text);
    font-size: var(--font-size-auxiliary);
  }

  .dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    padding: var(--space-4) var(--space-6) var(--space-5);
  }
</style>
