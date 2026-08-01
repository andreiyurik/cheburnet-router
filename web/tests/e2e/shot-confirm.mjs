// shot-confirm.mjs — снимок экрана «Подтверждение» с живого роутера БЕЗ запуска установки
// (доход до Confirm не меняет маршрутизацию — интернет не рвётся). node tests/e2e/shot-confirm.mjs
import { chromium } from '@playwright/test';
import { mkdirSync } from 'node:fs';

const ROUTER = 'http://192.168.1.1/cheburnet';
const TOKEN = process.env.TOKEN;
const AWG_CONF = process.env.AWG_CONF;
const SHOT = '/tmp/cheburnet-shots';
mkdirSync(SHOT, { recursive: true });

const browser = await chromium.launch({ args: ['--no-sandbox'] });
const page = await browser.newPage({ viewport: { width: 900, height: 1200 } });
try {
  await page.goto(`${ROUTER}/?token=${TOKEN}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(2500);
  await page.getByRole('button', { name: 'Продолжить' }).click();
  await page.waitForTimeout(600);
  await page.getByLabel('VPN-конфиг').setInputFiles(AWG_CONF).catch(async () => {
    await page.locator('input[type=file]').setInputFiles(AWG_CONF);
  });
  await page.getByLabel('Пароль администратора (root)').fill('cheburnet-test-1');
  await page.getByLabel('Повторите пароль').fill('cheburnet-test-1');
  const ssid = page.getByLabel('Имя сети (SSID)');
  if (await ssid.isVisible().catch(() => false)) {
    await ssid.fill('CheburTest');
    await page.getByLabel('Пароль Wi-Fi').fill('wifi-test-1234');
  }
  await page.getByRole('button', { name: 'Установить' }).click();
  await page.waitForTimeout(800);
  // Мы на Confirm. НИЧЕГО не жмём дальше — установка не стартует, интернет цел.
  await page.screenshot({ path: `${SHOT}/09-confirm-new-warning.png`, fullPage: true });
  const warn = await page.getByText('Не выключайте роутер и не вынимайте кабель', { exact: false }).isVisible().catch(() => false);
  console.log('[shot] Confirm warning visible:', warn);
} catch (e) {
  console.log('[shot] error:', e.message);
} finally {
  await browser.close();
}
