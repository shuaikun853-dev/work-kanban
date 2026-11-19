<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Props {
    title: string;
    subtitle?: string;
    actions?: Snippet;
  }

  let { title, subtitle, actions }: Props = $props();
</script>

<header class="page-header">
  <div class="page-heading">
    <h1>{title}</h1>
    {#if subtitle}
      <p class="page-subtitle">{subtitle}</p>
    {/if}
  </div>
  {#if actions}
    <div class="page-actions">{@render actions()}</div>
  {/if}
</header>

<style>
  .page-header {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-start;
    justify-content: space-between;
    gap: var(--space-4);
    margin-bottom: var(--space-5);
  }

  .page-heading {
    min-width: 0;
  }

  h1 {
    font-size: var(--font-size-page-title);
    font-weight: 700;
    letter-spacing: -0.02em;
    line-height: 1.2;
  }

  .page-subtitle {
    margin-top: var(--space-1);
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
  }

  .page-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
  }
</style>
