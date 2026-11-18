/**
 * WorkManager 前端入口（Svelte 5 + Vite，不使用 SvelteKit）。
 *
 * 只负责挂载根组件与引入全局样式；业务数据统一通过受限 Tauri IPC 获取，
 * 不在前端持久化任何状态（无 localStorage / IndexedDB）。
 */
import { mount } from 'svelte';

import App from './App.svelte';
import './app.css';

const target = document.getElementById('app');
if (!(target instanceof HTMLElement)) {
  throw new Error('index.html 中缺少 #app 挂载节点，WorkManager 前端无法启动。');
}

const app = mount(App, { target });

export default app;
