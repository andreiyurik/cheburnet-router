// live-router.mjs — прогон РЕАЛЬНОГО веб-мастера против живого роутера (не мок).
// Проходит установку как пользователь, снимает скриншот каждого экрана для оценки UX.
//   node tests/e2e/live-router.mjs
import { chromium } from '@playwright/test';
import { mkdirSync } from 'node:fs';

const ROUTER = 'http://192.168.1.1/cheburnet';
const TOKEN = process.env.TOKEN || '5dd20304-c0be-4535-a16e-61c536bba8ad';
const AWG_CONF = '/mnt/c/Users/Fast Station/Downloads/CH(1).conf';
const SHOT = '/tmp/cheburnet-shots';
mkdirSync(SHOT, { recursive: true });

const log = (m) => console.log(`[live] ${m}`);
let n = 0;
async function shot(page, name) {
  const f = `${SHOT}/${String(++n).padStart(2, '0')}-${name}.png`;
  await page.screenshot({ path: f, fullPage: true });
  log(`📸 ${f}`);
}

const browser = await chromium.launch({ args: ['--no-sandbox'] });
const page = await browser.newPage({ viewport: { width: 900, height: 1200 } });
page.on('console', (m) => log(`console.${m.type()}: ${m.text()}`));
page.on('pageerror', (e) => log(`❌ pageerror: ${e.message}`));

try {
  // 1. Preflight
  await page.goto(`${ROUTER}/?token=${TOKEN}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(2500); // preflight-запрос к роутеру
  await shot(page, 'preflight');
  const stepper = await page.locator('.stepper-label').textContent().catch(() => '(нет)');
  log(`индикатор шагов: ${stepper}`);

  await page.getByRole('button', { name: 'Продолжить' }).click();
  await page.waitForTimeout(800);

  // 2. Setup
  await shot(page, 'setup-empty');
  await page.getByLabel('VPN-конфиг').setInputFiles(AWG_CONF).catch(async () => {
    // если поле файла не по label — пробуем прямой input[type=file]
    await page.locator('input[type=file]').setInputFiles(AWG_CONF);
  });
  const domains = await page.getByLabel('Домены прямого доступа').inputValue().catch(() => '?');
  log(`direct-домены по умолчанию: "${domains}"`);
  const tokenVal = await page.getByLabel('Код установки').inputValue().catch(() => '?');
  log(`токен подставлен из ссылки: ${tokenVal ? 'да' : 'нет'}`);

  await page.getByLabel('Пароль администратора (root)').fill('cheburnet-test-1');
  await page.getByLabel('Повторите пароль').fill('cheburnet-test-1');
  // Wi-Fi обязателен при наличии радио — заполняем (иначе валидация не пустит).
  const ssidField = page.getByLabel('Имя сети (SSID)');
  if (await ssidField.isVisible().catch(() => false)) {
    await ssidField.fill('CheburTest');
    await page.getByLabel('Пароль Wi-Fi').fill('wifi-test-1234');
    log('Wi-Fi заполнен (радио присутствует)');
  }
  await shot(page, 'setup-filled');

  await page.getByRole('button', { name: 'Установить' }).click();
  await page.waitForTimeout(1000);

  // 3. Confirm (или сразу installing)
  const confirmVisible = await page.getByText('Проверьте перед установкой').isVisible().catch(() => false);
  if (confirmVisible) {
    await shot(page, 'confirm');
    await page.getByRole('button', { name: 'Установить' }).click();
    await page.waitForTimeout(1000);
  }

  // 4. Installing — следим за живым прогрессом, снимаем несколько кадров
  log('=== установка: слежу за прогрессом ===');
  const seen = new Set();
  for (let i = 0; i < 40; i++) {
    const stepTxt = await page.locator('section p strong').first().textContent().catch(() => '');
    if (stepTxt && !seen.has(stepTxt)) {
      seen.add(stepTxt);
      log(`шаг: ${stepTxt}`);
      await shot(page, `installing-${[...seen].length}`);
    }
    const done = await page.getByText('Готово! Роутер настроен').isVisible().catch(() => false);
    const failed = await page.locator('.warn').first().isVisible().catch(() => false);
    const statusPanel = await page.getByRole('heading', { name: 'Состояние' }).isVisible().catch(() => false);
    if (done || statusPanel) { log('✅ установка завершилась успехом'); break; }
    if (failed) {
      const err = await page.locator('.warn').first().textContent().catch(() => '');
      log(`⚠ возможная ошибка на экране: ${err}`);
    }
    await page.waitForTimeout(3000);
  }
  await page.waitForTimeout(2000);
  await shot(page, 'final');

  // 5. Панель управления (если дошли)
  const onPanel = await page.getByRole('heading', { name: 'Состояние' }).isVisible().catch(() => false);
  if (onPanel) {
    log('=== панель управления ===');
    const rows = await page.locator('ul.status li').allTextContents().catch(() => []);
    rows.forEach((r) => log(`  ${r.replace(/\s+/g, ' ').trim()}`));
    await shot(page, 'panel');
  }

  log(`ИТОГ: экранов пройдено, скриншоты в ${SHOT}`);
} catch (e) {
  log(`❌ исключение: ${e.message}`);
  await shot(page, 'error');
} finally {
  await browser.close();
}
