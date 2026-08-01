// shot-installing.spec.js — снимок экрана «Установка» с предупреждением об обрыве связи
// (против мока — реальный интернет не рвётся). Артефакт для слайдов + защита от регресса текста.
import { test, expect } from '@playwright/test';

const AWG_CONF = `[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
Address = 10.8.0.2/32
[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0`;

test('снимок: экран установки показывает предупреждение об обрыве связи (шаг health-check)', async ({ page, request }) => {
  await request.post('/__reset');
  await page.goto('/cheburnet/?token=TESTTOKEN');
  await page.getByRole('button', { name: 'Продолжить' }).click();
  await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  await page.getByRole('button', { name: 'Установить' }).click();
  await page.getByRole('button', { name: 'Установить' }).click(); // confirm

  // Ждём шаг health-check (усиленный текст) и снимаем.
  await expect(page.getByText('Не вынимайте кабель и не выключайте роутер', { exact: false })).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText('если сервер не ответит, роутер сам всё вернёт назад', { exact: false })).toBeVisible();
  await page.screenshot({ path: '/tmp/cheburnet-shots/10-installing-new-warning.png', fullPage: true });
});
