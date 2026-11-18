import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/**
 * WorkManager 正式工程使用 Svelte 5 + TypeScript + Vite，不引入 SvelteKit。
 * 该配置只启用 Svelte 文件的 TypeScript 预处理，供 vite 与 svelte-check 共用。
 *
 * @type {import('@sveltejs/vite-plugin-svelte').SvelteConfig}
 */
export default {
  preprocess: vitePreprocess()
};
