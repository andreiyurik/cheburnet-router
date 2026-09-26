import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';
import { fileURLToPath } from 'node:url';

// Сборка в статику, которую отдаёт роутер по /cheburnet/. Кладём прямо в каталог пакета
// (package/cheburnet/files/web) — так пакет всегда несёт готовый UI без node в OpenWrt SDK.
// base: './' → относительные пути к ассетам, чтобы работало под подкаталогом /cheburnet/.
export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  base: './',
  // $lib — алиас, которого ждут компоненты shadcn-svelte (components.json).
  resolve: { alias: { $lib: fileURLToPath(new URL('./src/lib', import.meta.url)) } },
  build: {
    outDir: '../package/cheburnet/files/web',
    emptyOutDir: true,
    // Один маленький бандл важнее код-сплита: меньше запросов, меньше флеша (см. web-wizard.md).
    chunkSizeWarningLimit: 1500,
  },
});
