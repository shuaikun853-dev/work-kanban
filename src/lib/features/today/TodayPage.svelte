<script lang="ts">
  import PageHeader from '../../ui/components/PageHeader.svelte';
  import PendingWorkItemsView from '../work-items/PendingWorkItemsView.svelte';

  /**
   * 今日工作页：保持 UI-DESIGN-SPEC V1.1 的单一页面入口。
   * “待安排”作为今日工作页面下的次级视图实现，不新增一级侧边栏导航；
   * 待安排列表与快速创建的业务状态由 Rust Core 管理。
   */
  type TodayView = 'today' | 'pending';

  let activeView = $state<TodayView>('today');
  const subtitle = $derived(
    activeView === 'today'
      ? '当前工作、待完成和已完成'
      : '尚未安排具体日期的待办工作；创建后立即进入待安排。'
  );
</script>

<svelte:head>
  <title>今日工作 · WorkManager</title>
</svelte:head>

<PageHeader title="今日工作" {subtitle} />

<div class="view-switcher" role="group" aria-label="今日工作视图切换">
  <button
    type="button"
    class="view-option"
    aria-pressed={activeView === 'today'}
    onclick={() => {
      activeView = 'today';
    }}
  >
    今日工作
  </button>
  <button
    type="button"
    class="view-option"
    aria-pressed={activeView === 'pending'}
    onclick={() => {
      activeView = 'pending';
    }}
  >
    待安排
  </button>
</div>

{#if activeView === 'today'}
  <div class="stage-note" role="status">
    <p class="stage-title">今日工作的执行记录尚未接入</p>
    <p class="stage-text">
      T1-03 只交付“待安排”工作的快速创建与列表；今日计划、当前工作和完成状态将在后续任务按已确认的 UI
      规范接入真实数据。本页不展示虚构工作事项。
    </p>
  </div>
{:else}
  <PendingWorkItemsView />
{/if}

<style>
  .view-switcher {
    display: inline-flex;
    gap: var(--space-1);
    margin-bottom: var(--space-4);
    padding: 3px;
    border: 1px solid var(--color-divider);
    border-radius: var(--radius-md);
    background-color: var(--color-surface-muted);
  }

  .view-option {
    min-height: 30px;
    padding: 5px 14px;
    border: 0;
    border-radius: var(--radius-sm);
    background-color: transparent;
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
    font-weight: 600;
    cursor: pointer;
    transition:
      background-color var(--duration-fast) ease,
      color var(--duration-fast) ease;
  }

  .view-option:hover {
    color: var(--color-text-primary);
  }

  .view-option[aria-pressed='true'] {
    background-color: var(--color-surface);
    color: var(--color-accent-strong);
  }

  .view-option:focus-visible {
    outline: var(--focus-ring);
    outline-offset: var(--focus-ring-offset);
  }

  .stage-note {
    max-width: 720px;
    padding: var(--space-5);
    border: 1px solid var(--color-divider);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
  }

  .stage-title {
    color: var(--color-text-primary);
    font-size: var(--font-size-item-title);
    font-weight: 600;
  }

  .stage-text {
    margin-top: var(--space-2);
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
    line-height: 1.7;
  }
</style>
