import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// Tauri 开发服务器固定端口；Rust 侧代码变化由 tauri CLI 负责监听，Vite 不需要扫描。
export default defineConfig({
  plugins: [svelte()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      ignored: ['**/src-tauri/**', '**/crates/**']
    }
  },
  build: {
    target: 'chrome110',
    // Vite 8 不再内置 esbuild；使用 Vite 8 默认的 Oxc 压缩器，避免额外依赖。
    minify: 'oxc',
    sourcemap: false
  }
});
