# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: wizard.spec.js >> мастер: неверный токен установки → доменная ошибка движка на экране
- Location: tests/e2e/wizard.spec.js:58:1

# Error details

```
Error: locator.click: Target page, context or browser has been closed
Call log:
  - waiting for getByRole('button', { name: 'Продолжить' })

```

# Test source

```ts
  1  | // wizard.spec.js — e2e-смоук: полный проход мастера в реальном браузере.
  2  | //
  3  | // Гоняет СОБРАННЫЙ бандл против мок-роутера (mock-router.mjs): рендер, клики,
  4  | // переходы экранов, валидация — то, чего не видят ни vitest (нет DOM-потока),
  5  | // ни T3b-v2 (нет браузера). Happy-path: preflight → setup → confirm →
  6  | // installing → панель управления.
  7  | 
  8  | import { test, expect } from '@playwright/test';
  9  | 
  10 | const AWG_CONF = `[Interface]
  11 | PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
  12 | Address = 10.8.0.2/32
  13 | [Peer]
  14 | PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
  15 | Endpoint = vpn.example.com:51820
  16 | AllowedIPs = 0.0.0.0/0`;
  17 | 
  18 | test('мастер: полный проход от проверки до панели управления', async ({ page }) => {
  19 |   // Токен в ссылке — как её печатает bootstrap.
  20 |   await page.goto('/cheburnet/?token=TESTTOKEN');
  21 | 
  22 |   // Шаг 1: проверка роутера. Индикатор шагов и результат preflight.
  23 |   await expect(page.getByText('Шаг 1 из 4')).toBeVisible();
  24 |   await expect(page.getByText('все 6 проверок пройдены')).toBeVisible();
  25 |   await page.getByRole('button', { name: 'Продолжить' }).click();
  26 | 
  27 |   // Шаг 2: настройка. Дефолты: direct-список 'ru', токен из ссылки.
  28 |   await expect(page.getByText('Шаг 2 из 4')).toBeVisible();
  29 |   await expect(page.getByLabel('Домены прямого доступа')).toHaveValue('ru');
  30 |   await expect(page.getByLabel('Код установки')).toHaveValue('TESTTOKEN');
  31 | 
  32 |   await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  33 | 
  34 |   // Валидация: короткий пароль → понятная ошибка, установка не уходит.
  35 |   await page.getByLabel('Пароль администратора (root)').fill('short');
  36 |   await page.getByRole('button', { name: 'Установить' }).click();
  37 |   await expect(page.getByText('Пароль роутера — минимум 8 символов.')).toBeVisible();
  38 | 
  39 |   await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  40 |   await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  41 |   await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  42 |   await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  43 |   await page.getByRole('button', { name: 'Установить' }).click();
  44 | 
  45 |   // Шаг 3: подтверждение. Сводка без секретов: endpoint туннеля и число доменов.
  46 |   await expect(page.getByText('Шаг 3 из 4')).toBeVisible();
  47 |   await expect(page.getByText('vpn.example.com:51820')).toBeVisible();
  48 |   await expect(page.getByText('TestWifi (пароль задан)')).toBeVisible();
  49 |   await page.getByRole('button', { name: 'Установить' }).click();
  50 | 
  51 |   // Шаг 4: установка → успех (маскот) → панель управления.
  52 |   await expect(page.getByText('Шаг 4 из 4')).toBeVisible();
  53 |   await expect(page.getByText('Готово! Роутер настроен')).toBeVisible({ timeout: 15_000 });
  54 |   await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible({ timeout: 10_000 });
  55 |   await expect(page.getByText('HOME (split)')).toBeVisible();
  56 | });
  57 | 
  58 | test('мастер: неверный токен установки → доменная ошибка движка на экране', async ({ page }) => {
  59 |   await page.goto('/cheburnet/?token=WRONG-TOKEN');
> 60 |   await page.getByRole('button', { name: 'Продолжить' }).click();
     |                                                          ^ Error: locator.click: Target page, context or browser has been closed
  61 |   await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  62 |   await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  63 |   await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  64 |   await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  65 |   await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  66 |   await page.getByRole('button', { name: 'Установить' }).click();
  67 |   await page.getByRole('button', { name: 'Установить' }).click(); // confirm
  68 | 
  69 |   // Движок отверг токен → мастер показывает ошибку, не «зависает» на прогрессе.
  70 |   await expect(page.getByText('неверный install-токен')).toBeVisible({ timeout: 10_000 });
  71 | });
  72 | 
```