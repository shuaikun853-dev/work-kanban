<script lang="ts">
  import AppShell from './app/AppShell.svelte';
  import type { PageId, PrimaryPageId } from './app/navigation';
  import DiagnosticsPage from './lib/features/diagnostics/DiagnosticsPage.svelte';
  import OverviewPage from './lib/features/overview/OverviewPage.svelte';
  import PlaceholderPage from './lib/features/placeholder/PlaceholderPage.svelte';
  import ProjectsPage from './lib/features/projects/ProjectsPage.svelte';
  import SettingsPage from './lib/features/settings/SettingsPage.svelte';
  import TodayPage from './lib/features/today/TodayPage.svelte';

  /**
   * 应用级组合入口：只负责当前页面切换。
   * 页面业务状态、数据加载与命令调用属于各 Feature 页面容器；
   * Rust Core 是业务状态的唯一权威来源。
   */
  let activePage = $state<PageId>('overview');

  function navigate(page: PrimaryPageId): void {
    activePage = page;
  }
</script>

<svelte:head>
  <title>WorkManager</title>
</svelte:head>

<AppShell {activePage} onNavigate={navigate}>
  {#if activePage === 'overview'}
    <OverviewPage />
  {:else if activePage === 'today'}
    <TodayPage />
  {:else if activePage === 'upcoming'}
    <PlaceholderPage title="未来 7 天" description="未来七个自然日的计划" />
  {:else if activePage === 'history'}
    <PlaceholderPage title="历史记录" description="历史工作、每日执行情况和进度" />
  {:else if activePage === 'reports'}
    <PlaceholderPage title="报告" description="日报、周报和月报" />
  {:else if activePage === 'settings'}
    <SettingsPage
      onOpenProjects={() => {
        activePage = 'projects';
      }}
      onOpenDiagnostics={() => {
        activePage = 'diagnostics';
      }}
    />
  {:else if activePage === 'projects'}
    <ProjectsPage />
  {:else if activePage === 'diagnostics'}
    <DiagnosticsPage />
  {/if}
</AppShell>
