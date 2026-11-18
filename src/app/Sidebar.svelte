<script lang="ts">
  import {
    PRIMARY_NAVIGATION,
    activePrimaryPage,
    type PageId,
    type PrimaryPageId
  } from './navigation';

  interface Props {
    activePage: PageId;
    onNavigate: (page: PrimaryPageId) => void;
  }

  let { activePage, onNavigate }: Props = $props();
</script>

<nav class="sidebar" aria-label="主导航">
  <ul class="nav-list">
    {#each PRIMARY_NAVIGATION as item (item.id)}
      {@const active = activePrimaryPage(activePage) === item.id}
      <li>
        <button
          type="button"
          class="nav-item"
          class:nav-item--active={active}
          aria-current={active ? 'page' : undefined}
          onclick={() => onNavigate(item.id)}
        >
          <svg
            class="nav-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.7"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            {#if item.icon === 'overview'}
              <path d="M4 10.5 12 4l8 6.5" />
              <path d="M6 9.5V20h12V9.5" />
            {:else if item.icon === 'today'}
              <path d="M5 4h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z" />
              <path d="M8 11l2.5 2.5L16 8" />
              <path d="M8 16h8" />
            {:else if item.icon === 'upcoming'}
              <path d="M5 5h14a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z" />
              <path d="M8 3v4" />
              <path d="M16 3v4" />
              <path d="M4 10h16" />
            {:else if item.icon === 'history'}
              <path d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z" />
              <path d="M12 7v5l3.5 2" />
            {:else if item.icon === 'reports'}
              <path d="M4 20V11" />
              <path d="M10 20V5" />
              <path d="M16 20v-6" />
              <path d="M3 20h18" />
            {:else}
              <path d="M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z" />
              <path d="M12 2v3" />
              <path d="M12 19v3" />
              <path d="M2 12h3" />
              <path d="M19 12h3" />
              <path d="M4.9 4.9 7.1 7.1" />
              <path d="M16.9 16.9l2.2 2.2" />
              <path d="M19.1 4.9 16.9 7.1" />
              <path d="M7.1 16.9 4.9 19.1" />
            {/if}
          </svg>
          <span class="nav-label">{item.label}</span>
        </button>
      </li>
    {/each}
  </ul>

  <p class="sidebar-note">本地工作管理 · 数据不上传</p>
</nav>

<style>
  .sidebar {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    flex: 0 0 196px;
    width: 196px;
    min-height: 0;
    padding: var(--space-4) var(--space-3);
    border-right: 1px solid var(--color-divider);
    background-color: var(--color-sidebar);
    overflow-y: auto;
  }

  .nav-list {
    display: flex;
    flex-direction: column;
    gap: 2px;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    width: 100%;
    min-height: 40px;
    padding: 9px 12px;
    border: 0;
    border-radius: var(--radius-md);
    background-color: transparent;
    color: var(--color-text-primary);
    font-size: var(--font-size-body);
    text-align: left;
    cursor: pointer;
    transition:
      background-color var(--duration-fast) ease,
      color var(--duration-fast) ease;
  }

  .nav-item:hover {
    background-color: var(--color-nav-hover-bg);
  }

  .nav-item--active {
    background-color: var(--color-accent-soft);
    color: var(--color-accent-strong);
    font-weight: 600;
  }

  .nav-item--active:hover {
    background-color: var(--color-accent-soft);
  }

  .nav-icon {
    flex: 0 0 18px;
    width: 18px;
    height: 18px;
    color: var(--color-text-secondary);
  }

  .nav-item--active .nav-icon {
    color: var(--color-accent);
  }

  .nav-label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .sidebar-note {
    padding: var(--space-3) var(--space-2) 0;
    color: var(--color-text-secondary);
    font-size: var(--font-size-caption);
    line-height: 1.5;
  }

  @media (max-width: 960px) {
    .sidebar {
      flex-basis: 176px;
      width: 176px;
    }
  }
</style>
