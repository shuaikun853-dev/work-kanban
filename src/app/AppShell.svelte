<script lang="ts">
  import type { Snippet } from 'svelte';

  import WindowTitlebar from '../lib/WindowTitlebar.svelte';
  import Sidebar from './Sidebar.svelte';
  import type { PageId, PrimaryPageId } from './navigation';

  interface Props {
    activePage: PageId;
    onNavigate: (page: PrimaryPageId) => void;
    children: Snippet;
  }

  let { activePage, onNavigate, children }: Props = $props();
</script>

<div class="app-shell">
  <WindowTitlebar />

  <div class="app-body">
    <Sidebar {activePage} {onNavigate} />

    <main class="app-content" id="main-content">
      {@render children()}
    </main>
  </div>
</div>

<style>
  .app-shell {
    display: flex;
    flex-direction: column;
    height: 100vh;
    min-height: 0;
    overflow: hidden;
    background-color: var(--color-canvas);
  }

  .app-body {
    display: flex;
    flex: 1 1 auto;
    min-height: 0;
  }

  .app-content {
    flex: 1 1 auto;
    min-width: 0;
    padding: var(--space-6) var(--space-8) var(--space-8);
    overflow-y: auto;
    background-color: var(--color-canvas);
  }

  @media (max-width: 1024px) {
    .app-content {
      padding: var(--space-5) var(--space-5) var(--space-6);
    }
  }

  @media (max-width: 900px) {
    .app-content {
      padding: var(--space-4) var(--space-4) var(--space-6);
    }
  }
</style>
