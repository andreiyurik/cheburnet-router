// Скриншоты новой темы: мастер (setup) и панель, светлая и тёмная. По образцу readme-shots.mjs.
import { chromium } from '@playwright/test';
import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';

const OUT = process.argv[2] || '/tmp/theme-shots';
const AWG_CONF = `[Interface]
PrivateKey = 0000000000000000000000000000000000000000000=
Address = 10.8.1.7/32
DNS = 1.1.1.1
Jc = 4
Jmin = 40
Jmax = 70

[Peer]
PublicKey = 0000000000000000000000000000000000000000000=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0`;

const mock = spawn('node', ['tests/e2e/mock-router.mjs'], { stdio: 'inherit' });
await sleep(1200);

const browser = await chromium.launch({ args: ['--no-sandbox'] });
try {
  for (const scheme of ['light', 'dark']) {
    const page = await browser.newPage({ viewport: { width: 760, height: 900 } });
    await page.emulateMedia({ colorScheme: scheme });
    await page.request.post('http://127.0.0.1:4317/__set', { data: { hw: 'full' } });
    await page.goto('http://127.0.0.1:4317/cheburnet/?token=TESTTOKEN');
    await page.getByText('все 6 проверок пройдены').waitFor();
    await page.screenshot({ path: `${OUT}/preflight-${scheme}.png`, fullPage: true });
    await page.getByRole('button', { name: 'Продолжить' }).click();
    await page.getByRole('radio', { name: /Роутер слабый или хочется максимально быстро/ }).check();
    await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
    await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
    await page.getByLabel('Повторите пароль').fill('secret-pass-1');
    await page.getByLabel('Имя сети (SSID)').fill('MyHomeNet');
    await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
    await page.screenshot({ path: `${OUT}/setup-${scheme}.png`, fullPage: true });
    await page.getByRole('button', { name: 'Установить' }).click();
    await page.getByText('Шаг 3 из 4').waitFor();
    await page.getByRole('button', { name: 'Установить' }).click();
    await page.getByText('Готово! Роутер настроен').waitFor({ timeout: 15_000 });
    await page.getByRole('heading', { name: 'Состояние' }).waitFor({ timeout: 10_000 });
    await sleep(400);
    await page.screenshot({ path: `${OUT}/panel-${scheme}.png`, fullPage: true });
    await page.close();
    // Мок держит состояние в памяти — вернуть «не установлено» перед вторым проходом.
    const reset = await browser.newPage();
    await reset.request.post('http://127.0.0.1:4317/__reset', { data: {} }).catch(() => {});
    await reset.close();
  }
  console.log(`✓ скриншоты в ${OUT}`);
} finally {
  await browser.close();
  mock.kill();
}
