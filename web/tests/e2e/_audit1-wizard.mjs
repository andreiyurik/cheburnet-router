// audit1-wizard.mjs — ручной обход мастера установки глазами нетехнического пользователя.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:4317';
const SHOTS = '/tmp/claude-1000/-home-pingvinus-cheburnet-router/7e8bccbe-71a0-4a93-9eaa-9711c7387fe6/scratchpad/audit-shots';
let n = 0;
const shot = async (page, name) => {
  n += 1;
  const fname = `${String(n).padStart(2, '0')}-${name}.png`;
  await page.screenshot({ path: `${SHOTS}/${fname}`, fullPage: true });
  console.log('SHOT', fname);
};
const reset = async () => { await fetch(`${BASE}/__reset`, { method: 'POST' }); };
const setState = async (st) => { await fetch(`${BASE}/__set`, { method: 'POST', body: JSON.stringify(st) }); };

const AWG_CONF = `[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=\nEndpoint = vpn.example.com:51820\nAllowedIPs = 0.0.0.0/0`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
page.on('console', (msg) => { if (msg.type() === 'error') console.log('CONSOLE ERROR:', msg.text()); });
page.on('pageerror', (err) => console.log('PAGE ERROR:', err.message));

await reset();

// --- 1. Первый визит без токена в ссылке (человек просто открыл IP роутера, а не перешёл по ссылке) ---
await page.goto(`${BASE}/cheburnet/`);
await page.waitForSelector('h2', { timeout: 5000 });
await shot(page, 'preflight-no-token');

// Проверка ролей/заголовков доступности
const h1 = await page.textContent('h1');
console.log('h1:', h1);

await page.getByRole('button', { name: 'Продолжить' }).click();
await shot(page, 'setup-default-no-token');

// Пытаемся отправить пустую форму сразу — что видит человек, который просто жмёт кнопку?
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'setup-empty-submit-error');
console.log('Ошибка при пустой форме:', await page.locator('.warn').last().textContent().catch(() => '(нет .warn)'));

// Заполняем по одному полю, проверяя порядок ошибок (какая ошибка первая — понятна ли она?)
await page.getByLabel('VPN-конфиг').fill('это не конфиг а просто текст');
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'setup-bad-conf-error');
console.log('Ошибка невалидного конфига:', await page.locator('.warn').last().textContent());

await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
await page.getByLabel('Пароль администратора (root)').fill('123');
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'setup-short-pass-error');
console.log('Ошибка короткого пароля:', await page.locator('.warn').last().textContent());

await page.getByLabel('Пароль администратора (root)').fill('correct-horse-1');
await page.getByLabel('Повторите пароль').fill('correct-horse-2');
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'setup-mismatch-pass-error');
console.log('Ошибка несовпадения паролей:', await page.locator('.warn').last().textContent());

// Wi-Fi: SSID заполнен, пароль пустой
await page.getByLabel('Пароль администратора (root)').fill('correct-horse-1');
await page.getByLabel('Повторите пароль').fill('correct-horse-1');
await page.getByLabel('Имя сети (SSID)').fill('MyHome');
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'setup-wifi-key-missing-error');
console.log('Ошибка Wi-Fi без пароля:', await page.locator('.warn').last().textContent());

// Заполняем Wi-Fi пароль слишком короткий
await page.getByLabel('Пароль Wi-Fi').fill('1234');
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'setup-wifi-key-short-error');
console.log('Ошибка короткого Wi-Fi пароля:', await page.locator('.warn').last().textContent());

// Валидный Wi-Fi пароль, но токен отсутствует (нет ссылки token)
await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'setup-no-token-error');
console.log('Ошибка без токена:', await page.locator('.warn').last().textContent());

// Экстремальный ввод: очень длинный список доменов + emoji + html-тег в SSID
await page.getByLabel('Код установки').fill('TESTTOKEN');
await page.getByLabel('Сайты напрямую').fill(Array.from({ length: 500 }, (_, i) => `site${i}.example.com`).join('\n'));
await page.getByLabel('Имя сети (SSID)').fill('<script>alert(1)</script>🎉'.slice(0, 32));
await shot(page, 'setup-extreme-input-filled');
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'confirm-after-extreme-input');
console.log('URL после сабмита:', page.url());
console.log('Заголовок текущего экрана:', await page.locator('h2').first().textContent().catch(() => '(нет h2)'));

await browser.close();
console.log('DONE phase 1');
