<script lang="ts">
  import type { PendingWorkItemDto } from '../../contracts/workItems';

  interface Props {
    workItem: PendingWorkItemDto;
  }

  let { workItem }: Props = $props();

  const projectLabel = $derived(
    workItem.projectId === null ? '未归属项目' : (workItem.projectName ?? '未归属项目')
  );
</script>

<article class="work-item-row" data-work-item-id={workItem.id}>
  <div class="work-item-main">
    <p class="work-item-title" title={workItem.title}>{workItem.title}</p>
    <p class="work-item-meta">
      <span
        class="work-item-project"
        class:work-item-project--unassigned={workItem.projectId === null}
      >
        {projectLabel}
      </span>
      {#if workItem.projectIsArchived}
        <span class="archived-badge">项目已归档</span>
      {/if}
    </p>
  </div>
</article>

<style>
  .work-item-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-4);
    padding: var(--space-3) var(--space-4);
    transition: background-color var(--duration-fast) ease;
  }

  .work-item-row:hover {
    background-color: var(--color-surface-hover);
  }

  .work-item-main {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .work-item-title {
    overflow: hidden;
    color: var(--color-text-primary);
    font-size: var(--font-size-item-title);
    font-weight: 600;
    line-height: 1.4;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .work-item-meta {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
  }

  .work-item-project {
    overflow-wrap: anywhere;
  }

  .work-item-project--unassigned {
    color: var(--color-text-secondary);
  }

  .archived-badge {
    padding: 1px 8px;
    border: 1px solid var(--color-warning-border);
    border-radius: var(--radius-pill);
    background-color: var(--color-warning-bg);
    color: var(--color-warning-text);
    font-size: var(--font-size-caption);
    font-weight: 600;
    white-space: nowrap;
  }
</style>
