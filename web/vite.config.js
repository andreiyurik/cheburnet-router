import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// Сборка в статику, которую отдаёт роутер по /cheburnet/. Кладём прямо в каталог пакета
// (package/cheburnet/files/web) — так пакет всегда несёт готовый UI без node в OpenWrt SDK.
// base: './' → относительные пути к ассетам, чтобы работало под подкаталогом /cheburnet/.
export default defineConfig({
  plugins: [svelte()],
  base: './',
  build: {
    outDir: '../package/cheburnet/files/web',
    emptyOutDir: true,
    // Один маленький бандл важнее код-сплита: меньше запросов, меньше флеша (см. web-wizard.md).
    chunkSizeWarningLimit: 1500,
  },
});
