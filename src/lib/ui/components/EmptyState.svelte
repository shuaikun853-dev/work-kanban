<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Props {
    title: string;
    description: string;
    action?: Snippet;
  }

  let { title, description, action }: Props = $props();
</script>

<div class="empty-state" role="status">
  <p class="empty-title">{title}</p>
  <p class="empty-description">{description}</p>
  {#if action}
    <div class="empty-action">{@render action()}</div>
  {/if}
</div>

<style>
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-8) var(--space-5);
    border: 1px dashed var(--color-border-strong);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
    text-align: center;
  }

  .empty-title {
    color: var(--color-text-primary);
    font-size: var(--font-size-section-title);
    font-weight: 600;
  }

  .empty-description {
    max-width: 460px;
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
  }

  .empty-action {
    margin-top: var(--space-2);
  }
</style>
