// wizard.spec.js — e2e-смоук: полный проход мастера в реальном браузере.
//
// Гоняет СОБРАННЫЙ бандл против мок-роутера (mock-router.mjs): рендер, клики,
// переходы экранов, валидация — то, чего не видят ни vitest (нет DOM-потока),
// ни T3b-v2 (нет браузера). Happy-path: preflight → setup → confirm →
// installing → панель управления.

import { test, expect } from '@playwright/test';

// Мок-роутер держит состояние установки в памяти — сбрасываем перед каждым тестом.
test.beforeEach(async ({ request }) => {
  await request.post('/__reset');
});

const AWG_CONF = `[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
Address = 10.8.0.2/32
[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0`;

test('мастер: полный проход от проверки до панели управления', async ({ page }) => {
  // Токен в ссылке — как её печатает bootstrap.
  await page.goto('/cheburnet/?token=TESTTOKEN');

  // Шаг 1: проверка роутера. Индикатор шагов и результат preflight.
  await expect(page.getByText('Шаг 1 из 4')).toBeVisible();
  await expect(page.getByText('все 6 проверок пройдены')).toBeVisible();
  await page.getByRole('button', { name: 'Продолжить' }).click();

  // Шаг 2: настройка. Дефолты: direct-список 'ru'; токен из ссылки — поле свёрнуто
  // в подтверждение (лишний технический вопрос человеку не задаём), «Изменить» раскрывает.
  await expect(page.getByText('Шаг 2 из 4')).toBeVisible();
  await expect(page.getByLabel('Сайты напрямую, без VPN')).toHaveValue('ru');
  await expect(page.getByText('Код установки получен из ссылки')).toBeVisible();
  await page.getByRole('button', { name: 'Изменить' }).click();
  await expect(page.getByLabel('Код установки')).toHaveValue('TESTTOKEN');

  await page.getByLabel('VPN-конфиг').fill(AWG_CONF);

  // Валидация: короткий пароль → понятная ошибка, установка не уходит.
  await page.getByLabel('Пароль администратора (root)').fill('short');
  await page.getByRole('button', { name: 'Установить' }).click();
  await expect(page.getByText('Пароль роутера — минимум 8 символов.')).toBeVisible();

  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  await page.getByRole('button', { name: 'Установить' }).click();

  // Шаг 3: подтверждение. Сводка без секретов: endpoint туннеля и число доменов.
  await expect(page.getByText('Шаг 3 из 4')).toBeVisible();
  await expect(page.getByText('vpn.example.com:51820')).toBeVisible();
  await expect(page.getByText('TestWifi (пароль задан)')).toBeVisible();
  await page.getByRole('button', { name: 'Установить' }).click();

  // Шаг 4: установка → успех (маскот) → панель управления.
  await expect(page.getByText('Шаг 4 из 4')).toBeVisible();
  await expect(page.getByText('Готово! Роутер настроен')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText('Дома — выбранные сайты напрямую').first()).toBeVisible();
});

test('мастер: health-check не прошёл → адресная диагностика «VPN-сервер не ответил»', async ({ page, request }) => {
  // Мок переключается в режим «движок откатился по health» — UI должен сказать про VPN-сервер
  // и подписку, а не безликое «установка не удалась» (главная находка UX-ревью).
  await request.post('/__fail-health');
  await page.goto('/cheburnet/?token=TESTTOKEN');
  await page.getByRole('button', { name: 'Продолжить' }).click();
  await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  await page.getByRole('button', { name: 'Установить' }).click();
  await page.getByRole('button', { name: 'Установить' }).click(); // confirm

  await expect(page.getByText('VPN-сервер не ответил — туннель не поднялся.')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText('подписка у VPN-провайдера закончилась', { exact: false })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Загрузить другой конфиг' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Скачать журнал' })).toBeVisible();
});

test('мастер: неверный токен установки → доменная ошибка движка на экране', async ({ page }) => {
  await page.goto('/cheburnet/?token=WRONG-TOKEN');
  await page.getByRole('button', { name: 'Продолжить' }).click();
  await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  await page.getByRole('button', { name: 'Установить' }).click();
  await page.getByRole('button', { name: 'Установить' }).click(); // confirm

  // Движок отверг токен → мастер показывает ошибку, не «зависает» на прогрессе.
  await expect(page.getByText('неверный install-токен')).toBeVisible({ timeout: 10_000 });
});
