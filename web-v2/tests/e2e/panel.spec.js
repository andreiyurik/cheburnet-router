// panel.spec.js — e2e панели управления: Full-тир (opt-in), переключение и замена туннеля,
// модалка входа. Ветки, которые не исполняет ни vitest (нет DOM), ни wizard.spec (happy-path
// мастера): стейт-машина busy/poll в Status.svelte и протокол-зависимый выбор метода.

import { test, expect } from '@playwright/test';

test.beforeEach(async ({ request }) => {
  await request.post('/__reset');
});

// Панель на установленной системе с нужным состоянием Full-тира.
async function openPanel(page, request, state) {
  await request.post('/__set', { data: { installed: true, ...state } });
  await page.goto('/cheburnet/');
  await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible();
}

test('панель: кнопка «Включить VLESS+Reality» ставит sing-box и открывает переключение', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: false });

  // Слабое железо кнопку не видит (гейт full_capable) — здесь она обязана быть.
  const btn = page.getByRole('button', { name: 'Включить VLESS+Reality' });
  await expect(btn).toBeVisible();
  await btn.click();

  // Фон + поллинг → успех: подсказка про переключение, а после refresh статус
  // full_installed=true превращает секцию в форму «Переключиться на VLESS+Reality».
  await expect(page.getByText('sing-box установлен. Чтобы переключиться', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Переключиться на VLESS+Reality' })).toBeVisible({ timeout: 10_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('install_full_tier');
});

test('панель: сбой установки sing-box → честное сообщение, AWG не тронут', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: false, bgResult: 'fail' });

  await page.getByRole('button', { name: 'Включить VLESS+Reality' }).click();
  await expect(page.getByText('Не удалось скачать sing-box', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText('AmneziaWG не затронут', { exact: false })).toBeVisible();
  // Кнопка снова доступна для повтора.
  await expect(page.getByRole('button', { name: 'Включить VLESS+Reality' })).toBeEnabled();
});

test('панель: переключение AWG→Reality — успех меняет протокол на месте', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg' });

  await expect(page.getByRole('heading', { name: 'Переключиться на VLESS+Reality' })).toBeVisible();
  await page.getByLabel('Ссылка vless:// или конфиг sing-box')
    .fill('vless://uuid@reality.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Переключиться на VLESS+Reality' }).click();

  await expect(page.getByText('Переключено на VLESS+Reality — туннель работает.')).toBeVisible({ timeout: 15_000 });
  // После refresh протокол reality → секция замены становится Reality-вариантом.
  await expect(page.getByRole('heading', { name: 'Замена Reality-сервера' })).toBeVisible({ timeout: 10_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('switch_to_reality');
});

test('панель: переключение не удалось → fail-safe-сообщение, протокол остался AWG', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg', bgResult: 'fail' });

  await page.getByLabel('Ссылка vless:// или конфиг sing-box')
    .fill('vless://uuid@dead.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Переключиться на VLESS+Reality' }).click();

  // Ключевое обещание UI: прежний туннель возвращён автоматически.
  await expect(page.getByText('прежний туннель (AmneziaWG) возвращён автоматически', { exact: false }))
    .toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Замена VPN-конфига' })).toBeVisible();
});

test('панель: при protocol=reality замена конфига зовёт replace_reality_conf, не awg', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'reality' });

  await expect(page.getByRole('heading', { name: 'Замена Reality-сервера' })).toBeVisible();
  await page.getByLabel('Новая ссылка vless:// или конфиг')
    .fill('vless://uuid@new.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Заменить конфиг' }).click();

  await expect(page.getByText('Новый Reality-сервер применён', { exact: false })).toBeVisible({ timeout: 15_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('replace_reality_conf');
  expect(calls).not.toContain('replace_awg_conf');
});

test('панель: admin-метод без сессии → модалка входа; неверный пароль → счётчик; верный → успех', async ({ page, request }) => {
  await openPanel(page, request, { adminLocked: true });

  // Действие отбито PERMISSION_DENIED → вместо голой ошибки открывается вход.
  await page.getByRole('button', { name: 'Обновить список доменов' }).click();
  await expect(page.getByRole('heading', { name: 'Вход в управление' })).toBeVisible();

  // Кнопок «Войти» на странице две (linklike под панелью и в модалке) — скоупим модалкой.
  const modal = page.locator('.modal');

  // Неверный пароль — понятный счётчик попыток.
  await modal.getByLabel('Пароль').fill('wrong-pass');
  await modal.getByRole('button', { name: 'Войти' }).click();
  await expect(page.getByText('Пароль не подошёл (попытка 1 из 3)', { exact: false })).toBeVisible();

  // Верный — сессия получена, действие можно повторить.
  await modal.getByLabel('Пароль').fill('panel-pass-1');
  await modal.getByRole('button', { name: 'Войти' }).click();
  await expect(page.getByText('Вход выполнен — повторите действие.')).toBeVisible();
  // admin() после успеха fn() перезаписывает action на «<label> — готово.» — ассертим её.
  await page.getByRole('button', { name: 'Обновить список доменов' }).click();
  await expect(page.getByText('Обновление списка — готово.', { exact: false })).toBeVisible();
});
