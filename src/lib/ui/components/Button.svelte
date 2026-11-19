<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Props {
    variant?: 'primary' | 'secondary' | 'danger';
    size?: 'sm' | 'md';
    type?: 'button' | 'submit';
    disabled?: boolean;
    loading?: boolean;
    ariaLabel?: string;
    onclick?: (event: MouseEvent) => void;
    children: Snippet;
  }

  let {
    variant = 'primary',
    size = 'md',
    type = 'button',
    disabled = false,
    loading = false,
    ariaLabel,
    onclick,
    children
  }: Props = $props();
</script>

<button
  {type}
  class="button button--{variant} button--{size}"
  disabled={disabled || loading}
  aria-busy={loading}
  aria-label={ariaLabel}
  {onclick}
>
  {#if loading}
    <span class="button-spinner" aria-hidden="true"></span>
  {/if}
  {@render children()}
</button>

<style>
  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-2);
    min-height: 36px;
    padding: 7px 14px;
    border: 1px solid transparent;
    border-radius: var(--radius-md);
    font-size: var(--font-size-auxiliary);
    font-weight: 600;
    line-height: 1.2;
    white-space: nowrap;
    cursor: pointer;
    transition:
      background-color var(--duration-fast) ease,
      border-color var(--duration-fast) ease,
      color var(--duration-fast) ease;
  }

  .button:disabled {
    cursor: not-allowed;
    opacity: 0.58;
  }

  .button--md {
    min-height: 38px;
    padding: 8px 16px;
    font-size: var(--font-size-body);
  }

  .button--primary {
    border-color: var(--color-accent);
    background-color: var(--color-accent);
    color: var(--color-text-inverse);
  }

  .button--primary:hover:not(:disabled) {
    border-color: var(--color-accent-strong);
    background-color: var(--color-accent-strong);
  }

  .button--secondary {
    border-color: var(--color-border-strong);
    background-color: var(--color-surface);
    color: var(--color-text-primary);
  }

  .button--secondary:hover:not(:disabled) {
    border-color: var(--color-accent-soft-border);
    background-color: var(--color-surface-muted);
  }

  .button--danger {
    border-color: transparent;
    background-color: transparent;
    color: var(--color-danger-text);
  }

  .button--danger:hover:not(:disabled) {
    background-color: var(--color-danger-bg);
  }

  .button-spinner {
    width: 13px;
    height: 13px;
    border: 2px solid var(--color-spinner-track-inverse);
    border-top-color: var(--color-text-inverse);
    border-radius: 50%;
    animation: button-spin 0.75s linear infinite;
  }

  .button--secondary .button-spinner,
  .button--danger .button-spinner {
    border-color: var(--color-border-strong);
    border-top-color: var(--color-accent);
  }

  @keyframes button-spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
