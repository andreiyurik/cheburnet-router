// weak-hardware.spec.js — e2e: установка на роутер слабее рекомендуемого («на свой страх и риск»).
//
// Проверяем ровно то, что нельзя проверить юнитами: что человек ВИДИТ на экране проверки и что
// уезжает в движок. Инварианты:
//   • soft-провалы (флеш/RAM) → объяснения + красная кнопка, но только после галочки;
//   • accept_risk реально доезжает до install (иначе preflight в run.uc откажет второй раз);
//   • hard-провал (arch) → кнопки риска НЕТ вовсе (пакетов под платформу не существует);
//   • панель честно помнит, что роутер поставлен с пропуском проверок.

import { test, expect } from '@playwright/test';

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

test('слабое железо: объяснения → галочка → установка с accept_risk → плашка в панели', async ({ page, request }) => {
  await request.post('/__set', { data: { hw: 'weak' } });
  await page.goto('/cheburnet/?token=TESTTOKEN');

  // Экран проверки: провалы названы, и рядом — что это значит и что делать вместо риска.
  await expect(page.getByText('Роутер слабее рекомендуемого')).toBeVisible();
  await expect(page.getByText('свободный флеш ≈ 12 МБ')).toBeVisible();
  await expect(page.getByRole('heading', { name: /Мало свободного места/ })).toBeVisible();
  await expect(page.getByRole('heading', { name: /Мало оперативной памяти/ })).toBeVisible();
  await expect(page.getByText('extroot', { exact: false })).toBeVisible();

  // Красная кнопка есть, но заблокирована до осознанного согласия.
  const risky = page.getByRole('button', { name: 'Всё равно установить' });
  await expect(risky).toBeDisabled();
  await page.getByRole('checkbox').check();
  await expect(risky).toBeEnabled();
  await risky.click();

  // Дальше обычный мастер, но с напоминанием о принятом решении.
  await expect(page.getByText('Шаг 2 из 4')).toBeVisible();
  await expect(page.getByText('слабее рекомендуемого', { exact: false })).toBeVisible();
  await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  await page.getByRole('button', { name: 'Установить' }).click();

  // Подтверждение повторяет оговорку — последняя точка, где можно передумать.
  await expect(page.getByText('стабильность не', { exact: false })).toBeVisible();
  await page.getByRole('button', { name: 'Установить' }).click();

  // Флаг доехал до движка (иначе его preflight откажет и «кнопка» была бы обманом).
  await expect(page.getByText('Готово! Роутер настроен')).toBeVisible({ timeout: 15_000 });
  const sent = await (await request.get('/__last-install')).json();
  expect(sent.accept_risk).toBe(true);

  // Панель помнит решение — это же первое, что видно на скриншоте статуса при разборе жалоб.
  await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText('установлено по вашему решению', { exact: false })).toBeVisible();
});

test('неподдерживаемая платформа: кнопки риска нет — пропуск обещал бы невозможное', async ({ page, request }) => {
  await request.post('/__set', { data: { hw: 'unsupported' } });
  await page.goto('/cheburnet/?token=TESTTOKEN');

  await expect(page.getByText('Пока установить нельзя', { exact: false })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Всё равно установить' })).toHaveCount(0);
  await expect(page.getByRole('checkbox')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Перепроверить' })).toBeVisible();
});

test('годное железо: ни галочки, ни красной кнопки (риск — не часть обычного пути)', async ({ page }) => {
  await page.goto('/cheburnet/?token=TESTTOKEN');

  await expect(page.getByText('все 6 проверок пройдены')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Всё равно установить' })).toHaveCount(0);
  await expect(page.getByRole('checkbox')).toHaveCount(0);
});
