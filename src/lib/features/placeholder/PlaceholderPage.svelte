<script lang="ts">
  import PageHeader from '../../ui/components/PageHeader.svelte';

  interface Props {
    title: string;
    description: string;
  }

  let { title, description }: Props = $props();
</script>

<svelte:head>
  <title>{title} · WorkManager</title>
</svelte:head>

<PageHeader {title} subtitle={description} />

<div class="stage-note" role="status">
  <p class="stage-title">该页面尚未进入开发阶段</p>
  <p class="stage-text">
    当前只完成 T1-02 项目管理纵向切片。本页不展示虚构数据，具体功能将在开发计划对应的后续任务中实现。
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
