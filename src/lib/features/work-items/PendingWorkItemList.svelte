<script lang="ts">
  import type { PendingWorkItemDto } from '../../contracts/workItems';
  import PendingWorkItemRow from './PendingWorkItemRow.svelte';

  interface Props {
    workItems: readonly PendingWorkItemDto[];
  }

  let { workItems }: Props = $props();
</script>

<ul class="work-item-list" aria-label="待安排工作列表" data-pending-list>
  {#each workItems as workItem (workItem.id)}
    <li class="work-item-list__item">
      <PendingWorkItemRow {workItem} />
    </li>
  {/each}
</ul>

<style>
  .work-item-list {
    margin: 0;
    padding: 0;
    overflow: hidden;
    border: 1px solid var(--color-divider);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
    list-style: none;
  }

  .work-item-list__item + .work-item-list__item {
    border-top: 1px solid var(--color-divider-subtle);
  }
</style>
