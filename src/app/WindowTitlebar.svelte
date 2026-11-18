<script lang="ts">
  import { onMount } from 'svelte';

  import { isTauri } from '@tauri-apps/api/core';
  import type { UnlistenFn } from '@tauri-apps/api/event';
  import { getCurrentWindow } from '@tauri-apps/api/window';

  const currentWindow = getCurrentWindow();

  let desktopRuntime = $state(false);
  let maximized = $state(false);
  let actionError = $state('');

  async function refreshMaximizedState(): Promise<void> {
    if (!desktopRuntime) {
      return;
    }

    try {
      maximized = await currentWindow.isMaximized();
    } catch {
      actionError = '无法读取当前窗口状态。';
    }
  }

  async function runWindowAction(
    action: () => Promise<void>,
    refreshState = true
  ): Promise<void> {
    actionError = '';

    try {
      await action();
      if (refreshState) {
        await refreshMaximizedState();
      }
    } catch {
      actionError = '窗口操作失败，请重试或重新启动 WorkManager。';
    }
  }

  function closeWindow(): void {
    void runWindowAction(() => currentWindow.close(), false);
  }

  function minimizeWindow(): void {
    void runWindowAction(() => currentWindow.minimize(), false);
  }

  function toggleMaximize(): void {
    void runWindowAction(() => currentWindow.toggleMaximize());
  }

  /**
   * 无边框窗口使用 Tauri 原生拖动 API。
   * 双击非按钮区域时切换最大化；按钮自身不会触发拖动。
   */
  function handleTitlebarMouseDown(event: MouseEvent): void {
    if (!desktopRuntime || event.button !== 0) {
      return;
    }

    if (event.target instanceof Element && event.target.closest('button')) {
      return;
    }

    if (event.detail === 2) {
      toggleMaximize();
      return;
    }

    void currentWindow.startDragging().catch(() => {
      actionError = '无法拖动 WorkManager 窗口。';
    });
  }

  /** 工具栏内支持左右方向键切换三个窗口控制按钮。 */
  function handleTitlebarKeyDown(event: KeyboardEvent): void {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
      return;
    }

    const controls = Array.from(
      (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>(
        '.window-control:not(:disabled)'
      )
    );
    const currentIndex = controls.findIndex((control) => control === document.activeElement);

    if (currentIndex < 0 || controls.length === 0) {
      return;
    }

    event.preventDefault();
    const direction = event.key === 'ArrowRight' ? 1 : -1;
    const nextIndex = (currentIndex + direction + controls.length) % controls.length;
    controls[nextIndex]?.focus();
  }

  onMount(() => {
    if (!isTauri()) {
      return;
    }

    desktopRuntime = true;

    let disposed = false;
    let unlistenResize: UnlistenFn | undefined;

    void (async () => {
      await refreshMaximizedState();

      try {
        const unlisten = await currentWindow.onResized(() => {
          void refreshMaximizedState();
        });

        if (disposed) {
          unlisten();
        } else {
          unlistenResize = unlisten;
        }
      } catch {
        // 窗口按钮仍会在每次操作后刷新状态；监听器仅用于同步系统级缩放。
      }
    })();

    return () => {
      disposed = true;
      unlistenResize?.();
    };
  });
</script>

<div
  class="window-titlebar"
  role="toolbar"
  aria-label="WorkManager 窗口标题栏"
  aria-orientation="horizontal"
  tabindex="-1"
  onmousedown={handleTitlebarMouseDown}
  onkeydown={handleTitlebarKeyDown}
>
  <div class="window-titlebar__brand">
    <div class="window-titlebar__controls" role="group" aria-label="窗口控制">
      <button
        class="window-control window-control--close"
        type="button"
        aria-label="关闭 WorkManager"
        title="关闭"
        disabled={!desktopRuntime}
        onclick={closeWindow}
      ></button>
      <button
        class="window-control window-control--minimize"
        type="button"
        aria-label="最小化窗口"
        title="最小化"
        disabled={!desktopRuntime}
        onclick={minimizeWindow}
      ></button>
      <button
        class="window-control window-control--maximize"
        type="button"
        aria-label={maximized ? '还原窗口' : '最大化窗口'}
        title={maximized ? '还原' : '最大化'}
        disabled={!desktopRuntime}
        onclick={toggleMaximize}
      ></button>
    </div>

    <span class="window-titlebar__app-name">WorkManager</span>
  </div>

  <span class="visually-hidden" role="status" aria-live="polite">{actionError}</span>
</div>

<style>
  .window-titlebar {
    display: flex;
    align-items: center;
    flex: 0 0 60px;
    height: 60px;
    min-height: 60px;
    padding: 0 20px;
    border-bottom: 1px solid var(--color-border);
    background: #fbfcfe;
    user-select: none;
    -webkit-user-select: none;
  }

  .window-titlebar__brand {
    display: flex;
    align-items: center;
    gap: 24px;
    min-width: 0;
    height: 100%;
  }

  .window-titlebar__controls {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .window-control {
    display: block;
    flex: 0 0 13px;
    width: 13px;
    height: 13px;
    padding: 0;
    border: 0;
    border-radius: 50%;
    cursor: pointer;
    transition:
      filter 120ms ease,
      transform 120ms ease;
  }

  .window-control:hover:not(:disabled) {
    filter: brightness(0.92);
  }

  .window-control:active:not(:disabled) {
    transform: scale(0.9);
  }

  .window-control:focus-visible {
    outline: 2px solid var(--color-accent);
    outline-offset: 3px;
  }

  .window-control:disabled {
    cursor: default;
    opacity: 0.58;
  }

  .window-control--close {
    background: #ff5f57;
  }

  .window-control--minimize {
    background: #febc2e;
  }

  .window-control--maximize {
    background: #28c840;
  }

  .window-titlebar__app-name {
    color: var(--color-text);
    font-size: 14px;
    font-weight: 700;
    letter-spacing: -0.01em;
    white-space: nowrap;
  }
</style>
