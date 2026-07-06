// playwright.config.js — e2e-смоук мастера против мок-роутера (см. tests/e2e).
//   npm run test:e2e
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 30_000,
  use: {
    baseURL: 'http://127.0.0.1:4317',
    // chromium в WSL/CI без user-namespaces требует --no-sandbox; тест герметичный.
    launchOptions: { args: ['--no-sandbox'] },
  },
  webServer: {
    command: 'node tests/e2e/mock-router.mjs',
    port: 4317,
    reuseExistingServer: true,
  },
});
