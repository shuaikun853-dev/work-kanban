<script lang="ts">
  import Button from '../../ui/components/Button.svelte';
  import PageHeader from '../../ui/components/PageHeader.svelte';

  interface Props {
    onOpenProjects: () => void;
    onOpenDiagnostics: () => void;
  }

  let { onOpenProjects, onOpenDiagnostics }: Props = $props();
</script>

<svelte:head>
  <title>设置 · WorkManager</title>
</svelte:head>

<PageHeader title="设置" subtitle="项目管理与本地数据库诊断入口" />

<div class="settings-groups">
  <section class="settings-group" aria-labelledby="settings-projects-heading">
    <h2 id="settings-projects-heading" class="group-title">项目管理</h2>
    <div class="setting-row">
      <div class="setting-copy">
        <p class="setting-name">项目</p>
        <p class="setting-description">
          创建、编辑和归档项目。归档只隐藏项目，不删除项目记录或已有工作历史。
        </p>
      </div>
      <Button variant="secondary" onclick={onOpenProjects}>打开项目管理</Button>
    </div>
  </section>

  <section class="settings-group" aria-labelledby="settings-diagnostics-heading">
    <h2 id="settings-diagnostics-heading" class="group-title">诊断</h2>
    <div class="setting-row">
      <div class="setting-copy">
        <p class="setting-name">数据库健康检查</p>
        <p class="setting-description">
          查看 SQLite 完整性、schema 版本、便携路径和已应用 migration；只读诊断，不修改业务数据。
        </p>
      </div>
      <Button variant="secondary" onclick={onOpenDiagnostics}>打开数据库诊断</Button>
    </div>
  </section>
</div>

<style>
  .settings-groups {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    max-width: 760px;
  }

  .settings-group {
    border: 1px solid var(--color-divider);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
    box-shadow: var(--shadow-card);
    overflow: hidden;
  }

  .group-title {
    padding: var(--space-3) var(--space-4);
    border-bottom: 1px solid var(--color-divider);
    background-color: var(--color-surface-muted);
    color: var(--color-text-secondary);
    font-size: var(--font-size-caption);
    font-weight: 700;
    letter-spacing: 0.03em;
  }

  .setting-row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-4);
  }

  .setting-copy {
    flex: 1 1 320px;
    min-width: 0;
  }

  .setting-name {
    color: var(--color-text-primary);
    font-size: var(--font-size-item-title);
    font-weight: 600;
  }

  .setting-description {
    margin-top: 2px;
    color: var(--color-text-secondary);
    font-size: var(--font-size-auxiliary);
    line-height: 1.6;
  }
</style>
