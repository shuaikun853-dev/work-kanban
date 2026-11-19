<script lang="ts">
  import Button from '../../ui/components/Button.svelte';

  interface Props {
    open: boolean;
    projectName: string;
    submitting?: boolean;
    errorMessage?: string | null;
    onConfirm: () => void;
    onCancel: () => void;
  }

  let {
    open,
    projectName,
    submitting = false,
    errorMessage = null,
    onConfirm,
    onCancel
  }: Props = $props();

  let dialogElement = $state<HTMLDialogElement | null>(null);
  let cancelButton = $state<HTMLButtonElement | null>(null);

  $effect(() => {
    const dialog = dialogElement;
    if (dialog === null) {
      return;
    }

    if (open) {
      if (!dialog.open) {
        dialog.showModal();
        queueMicrotask(() => cancelButton?.focus());
      }
    } else if (dialog.open) {
      dialog.close();
    }
  });

  function requestCancel(): void {
    if (!submitting) {
      onCancel();
    }
  }
</script>

<dialog
  bind:this={dialogElement}
  class="confirm-dialog"
  aria-labelledby="confirm-dialog-title"
  aria-describedby="confirm-dialog-description"
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
  <div class="dialog-body">
    <h2 id="confirm-dialog-title" class="dialog-title">归档项目</h2>
    <p id="confirm-dialog-description" class="dialog-description">
      确定归档“<span class="project-name">{projectName}</span>”吗？
    </p>
    <p class="dialog-note">
      归档不会删除项目记录或已有工作历史；归档后的项目仅用于历史数据展示，不再作为新工作事项的常规可选项目。
    </p>
    {#if errorMessage}
      <p class="dialog-error" role="alert">{errorMessage}</p>
    {/if}
  </div>

  <div class="dialog-actions">
    <button bind:this={cancelButton} type="button" class="cancel-button" onclick={requestCancel} disabled={submitting}>
      取消
    </button>
    <Button onclick={onConfirm} loading={submitting}>归档项目</Button>
  </div>
</dialog>

<style>
  .confirm-dialog {
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

  .confirm-dialog::backdrop {
    background-color: var(--color-backdrop);
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
    margin-top: var(--space-2);
    font-size: var(--font-size-body);
  }

  .project-name {
    font-weight: 600;
    overflow-wrap: anywhere;
  }

  .dialog-note {
    margin-top: var(--space-3);
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
    line-height: 1.6;
  }

  .dialog-error {
    margin-top: var(--space-3);
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-danger-border);
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

  .cancel-button {
    min-height: 38px;
    padding: 8px 16px;
    border: 1px solid var(--color-border-strong);
    border-radius: var(--radius-md);
    background-color: var(--color-surface);
    color: var(--color-text-primary);
    font-size: var(--font-size-body);
    font-weight: 600;
    cursor: pointer;
  }

  .cancel-button:hover:not(:disabled) {
    background-color: var(--color-surface-muted);
  }
</style>
