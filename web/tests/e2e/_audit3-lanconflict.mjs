// audit3-lanconflict.mjs — экран LAN-конфликта через перехват ubus-ответа (мок всегда отдаёт
// conflict:false, поэтому подменяем ОДИН ответ на лету, не трогая mock-router.mjs).
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:4317';
const SHOTS = '/tmp/claude-1000/-home-pingvinus-cheburnet-router/7e8bccbe-71a0-4a93-9eaa-9711c7387fe6/scratchpad/audit-shots';
let n = 40;
const shot = async (page, name) => {
  n += 1;
  const fname = `${String(n).padStart(2, '0')}-${name}.png`;
  await page.screenshot({ path: `${SHOTS}/${fname}`, fullPage: true });
  console.log('SHOT', fname);
};
const reset = async () => { await fetch(`${BASE}/__reset`, { method: 'POST' }); };

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
page.on('pageerror', (err) => console.log('PAGE ERROR:', err.message));

await reset();

let rpcId = 1;
await page.route('**/ubus', async (route) => {
  const req = route.request();
  const body = JSON.parse(req.postData());
  const [, object, method] = body.params;
  if (object === 'cheburnet' && method === 'check_lan_conflict') {
    rpcId = body.id;
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ jsonrpc: '2.0', id: body.id, result: [0, {
        conflict: true, lan_cidr: '192.168.1.0/24', wan_cidr: '192.168.1.0/24', suggest_ip: '192.168.50.1',
      }] }),
    });
    return;
  }
  if (object === 'cheburnet' && method === 'apply_lan_ip') {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ jsonrpc: '2.0', id: body.id, result: [0, { new_ip: '192.168.50.1' }] }),
    });
    return;
  }
  await route.continue();
});

await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
await page.waitForSelector('h2');
await shot(page, 'lanconflict-screen');
console.log('Заголовок:', await page.locator('h2').first().textContent());
console.log('Есть индикатор шагов мастера (не должно быть — это спецэкран):',
  await page.locator('.stepper').count());

// Пробуем "Применить" без ввода кода — должна быть понятная ошибка, а не сетевая.
await page.getByRole('button', { name: /Сменить LAN-адрес/ }).click();
await shot(page, 'lanconflict-no-token-error');
console.log('Ошибка:', await page.locator('.warn').last().textContent().catch(() => '(нет)'));

// Заполняем код и применяем
await page.getByLabel('Код установки').fill('TESTTOKEN');
await page.getByRole('button', { name: /Сменить LAN-адрес/ }).click();
await page.waitForTimeout(300);
await shot(page, 'lanconflict-applied');
console.log('Текст успеха виден:', await page.locator('.ok-msg').count());

// Проверим путь "Продолжить без смены"
await reset();
await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
await page.waitForSelector('h2');
await page.getByRole('button', { name: 'Продолжить без смены' }).click();
await shot(page, 'lanconflict-skip-to-preflight');
console.log('Экран после skip:', await page.locator('h2').first().textContent());

await browser.close();
console.log('DONE phase 3 (lanconflict)');
