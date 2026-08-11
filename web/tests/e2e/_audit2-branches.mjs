// audit2-branches.mjs — ветки: LAN-конфликт, слабое/неподдерживаемое железо, отказы установки, отмена.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:4317';
const SHOTS = '/tmp/claude-1000/-home-pingvinus-cheburnet-router/7e8bccbe-71a0-4a93-9eaa-9711c7387fe6/scratchpad/audit-shots';
let n = 20;
const shot = async (page, name) => {
  n += 1;
  const fname = `${String(n).padStart(2, '0')}-${name}.png`;
  await page.screenshot({ path: `${SHOTS}/${fname}`, fullPage: true });
  console.log('SHOT', fname);
};
const reset = async () => { await fetch(`${BASE}/__reset`, { method: 'POST' }); };
const setState = async (st) => { await fetch(`${BASE}/__set`, { method: 'POST', body: JSON.stringify(st) }); };

const AWG_CONF = `[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=\nEndpoint = vpn.example.com:51820\nAllowedIPs = 0.0.0.0/0`;

const fillHappy = async (page) => {
  await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
page.on('pageerror', (err) => console.log('PAGE ERROR:', err.message));

// --- Слабое железо: как ведёт себя чекбокс и кнопка "на свой страх и риск" вживую ---
await reset();
await setState({ hw: 'weak' });
await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
await page.waitForSelector('h2');
await shot(page, 'weak-hw-preflight');
// Пробуем кликнуть по красной кнопке БЕЗ галочки (должна быть disabled)
const riskyBtn = page.getByRole('button', { name: 'Всё равно установить' });
console.log('Красная кнопка disabled без галочки:', await riskyBtn.isDisabled());
await page.getByRole('checkbox').check();
await shot(page, 'weak-hw-checked');
console.log('Красная кнопка disabled после галочки:', await riskyBtn.isDisabled());

// --- Неподдерживаемое железо ---
await reset();
await setState({ hw: 'unsupported' });
await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
await page.waitForSelector('h2');
await shot(page, 'unsupported-hw-preflight');

// --- LAN-конфликт: сеть роутера пересекается с WAN ---
// mock's check_lan_conflict всегда возвращает {conflict:false}; сымитировать нечем без правки
// мока — но посмотрим на LanConflict.svelte напрямую через ручной проброс состояния приложения
// невозможен без сети. Пропускаем эту ветку в скрипте, отметим отдельно как нужно смотреть код.

// --- Установка: health-check провален (сервер не ответил) ---
await reset();
await fetch(`${BASE}/__fail-health`, { method: 'POST' });
await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
await page.getByRole('button', { name: 'Продолжить' }).click();
await fillHappy(page);
await page.getByRole('button', { name: 'Установить' }).click();
await shot(page, 'confirm-before-install');
await page.getByRole('button', { name: 'Установить' }).click();
await page.waitForSelector('text=Запускаю', { timeout: 3000 }).catch(() => {});
await shot(page, 'installing-running');
await page.waitForSelector('text=VPN-сервер не ответил', { timeout: 15000 });
await shot(page, 'installing-fail-health');
console.log('Кнопки на экране провала:', await page.locator('button').allTextContents());

// Копировать журнал (проверяем, что не падает и меняет текст кнопки)
const copyBtn = page.getByRole('button', { name: 'Копировать журнал' });
if (await copyBtn.count() > 0) {
  await copyBtn.click();
  await page.waitForTimeout(300);
  await shot(page, 'installing-fail-copied');
  console.log('Текст кнопки после копирования:', await copyBtn.textContent());
}

// --- Отмена установки (реальный клик на "Отменить установку") ---
await reset();
await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
await page.getByRole('button', { name: 'Продолжить' }).click();
await fillHappy(page);
await page.getByRole('button', { name: 'Установить' }).click();
await page.getByRole('button', { name: 'Установить' }).click();
await page.waitForSelector('text=Отменить установку', { timeout: 5000 });
// confirm() dialog — подтверждаем
page.once('dialog', async (d) => { console.log('DIALOG:', d.message()); await d.accept(); });
await page.getByRole('button', { name: 'Отменить установку' }).click();
await shot(page, 'installing-cancelling');

// --- Перезагрузка страницы В ПРОЦЕССЕ установки (частый инстинкт нетерпеливого пользователя) ---
await reset();
await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
await page.getByRole('button', { name: 'Продолжить' }).click();
await fillHappy(page);
await page.getByRole('button', { name: 'Установить' }).click();
await page.getByRole('button', { name: 'Установить' }).click();
await page.waitForSelector('text=Запускаю, text=Настройка VPN', { timeout: 3000 }).catch(() => {});
await page.waitForTimeout(500);
await page.reload();
await page.waitForTimeout(500);
await shot(page, 'reload-during-install');
console.log('Экран после reload во время установки:', await page.locator('h2').first().textContent().catch(() => '(нет h2)'));
console.log('Текст страницы после reload:', (await page.locator('main').textContent()).slice(0, 300));

await browser.close();
console.log('DONE phase 2');
