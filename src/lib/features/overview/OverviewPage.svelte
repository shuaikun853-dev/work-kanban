<script lang="ts">
  import PageHeader from '../../ui/components/PageHeader.svelte';
</script>

<svelte:head>
  <title>工作总览 · WorkManager</title>
</svelte:head>

<PageHeader title="工作总览" subtitle="今天要做、今天已完成和当前工作" />

<div class="stage-note" role="status">
  <p class="stage-title">工作总览业务数据尚未接入</p>
  <p class="stage-text">
    T1-02 只交付应用壳与项目管理纵向切片。本页当前不展示虚构任务、统计指标或图表；工作总览将在后续任务中按已确认的 UI 规范接入真实数据。
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
