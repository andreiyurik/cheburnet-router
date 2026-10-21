// legacy-panel.spec.js — e2e: роутер, оставшийся на заморожённом Full-тире (Reality/Hysteria2, ADR 0010).
// Обещания панели: туннель назван своим именем и не объявлен мёртвым без причины; сменить его сервер
// нельзя, а путь один — на AmneziaWG тем же switch_to_awg с автооткатом. И обратное: у роутера на AWG
// никаких следов Full-тира (ни кнопки догрузки, ни «добавить VLESS» в подсказке мёртвого туннеля).

import { test, expect } from '@playwright/test';

test.beforeEach(async ({ request }) => {
  await request.post('/__reset');
});

async function openPanel(page, request, state) {
  await request.post('/__set', { data: { installed: true, ...state } });
  await page.goto('/cheburnet/');
  await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible();
}

async function expandDetails(page) {
  const d = page.locator('details', { has: page.getByText('Подробности', { exact: true }) }).first();
  if (!(await d.evaluate((el) => el.open))) await d.locator('> summary').click();
}

async function expandTunnel(page) {
  const g = page.locator('#tunnel-group');
  if (!(await g.evaluate((el) => el.open))) await g.locator('> summary').click();
  await expect(g).toHaveJSProperty('open', true);
}

for (const [protocol, name] of [['reality', 'VLESS+Reality'], ['hysteria2', 'Hysteria2']]) {
  // Регресс: рабочий Full-туннель показывался «не работает» — панель искала AWG-рукопожатие.
  test(`legacy ${name}: зелёный статус под своим именем, вместо замены сервера — путь на AWG`, async ({ page, request }) => {
    await openPanel(page, request, { protocol });
    await expandTunnel(page);

    await expect(page.getByText(`${name} активен`)).toBeVisible();
    await expect(page.getByText('Туннель не работает')).toHaveCount(0);
    await expandDetails(page);
    await expect(page.getByText(`поднят (${name})`)).toBeVisible();
    await expect(page.getByRole('heading', { name: `${name} больше не поддерживается` })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Заменить конфиг' })).toHaveCount(0);
    await expect(page.getByRole('radio', { name: /Протокол: AmneziaWG/ })).toBeVisible();
    await expect(page.getByRole('radio', { name: /Протокол: (VLESS|Hysteria)/ })).toHaveCount(0);
  });

  test(`мёртвый legacy ${name}: «Что делать» ведёт на AmneziaWG, а не к свежему конфигу`, async ({ page, request }) => {
    await request.post('/__vpn-down');
    await openPanel(page, request, { protocol });

    const banner = page.locator('[data-slot=alert][data-variant=destructive]');
    await expect(banner.getByRole('link', { name: /переключитесь/ })).toBeVisible();
    await expect(banner.getByRole('link', { name: /свежий конфиг/ })).toHaveCount(0);
    const hint = page.getByText('Попробуйте поддерживаемый туннель', { exact: false });
    await expect(hint.getByRole('link', { name: 'AmneziaWG' })).toBeVisible();
  });
}

test('legacy Reality → AmneziaWG: зовётся switch_to_awg с .conf, после успеха панель на AWG', async ({ page, request }) => {
  await openPanel(page, request, { protocol: 'reality' });
  await expandTunnel(page);

  await page.getByLabel('VPN-конфиг (AmneziaWG, файл .conf)').last()
    .fill('[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = p=\nEndpoint = 192.0.2.1:51820\n');
  await page.getByRole('button', { name: 'Переключиться на AmneziaWG' }).click();

  await expect(page.getByText('Переключено на AmneziaWG', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Замена сервера (AmneziaWG)' })).toBeVisible({ timeout: 10_000 });
  const bg = await (await request.get('/__last-bg')).json();
  expect(bg.method).toBe('switch_to_awg');
  expect(bg.args.awg_conf).toContain('[Interface]');
});

test('мёртвый AWG: ни «добавить VLESS», ни смены туннеля — только свежий конфиг и аварийный режим', async ({ page, request }) => {
  await request.post('/__vpn-down');
  await openPanel(page, request, { protocol: 'awg' });

  await expect(page.getByText('Туннель не работает')).toBeVisible();
  await expect(page.getByText('VLESS', { exact: false })).toHaveCount(0);
  await expect(page.getByText('Попробуйте поддерживаемый туннель', { exact: false })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Выключить защиту' })).toBeVisible();
  await expandTunnel(page);
  await expect(page.getByRole('heading', { name: 'Сменить туннель' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Установить компонент' })).toHaveCount(0);
});
