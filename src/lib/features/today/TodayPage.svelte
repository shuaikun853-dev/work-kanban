<script lang="ts">
  import PageHeader from '../../ui/components/PageHeader.svelte';
</script>

<svelte:head>
  <title>今日工作 · WorkManager</title>
</svelte:head>

<PageHeader title="今日工作" subtitle="当前工作、待完成和已完成" />

<div class="stage-note" role="status">
  <p class="stage-title">今日工作业务数据尚未接入</p>
  <p class="stage-text">
    T1-02 不包含工作事项创建与执行记录。本页不展示虚构工作事项；今日工作将在后续任务按已确认的 UI 规范接入真实数据。
  </p>
</div>

<style>
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
