// reality-panel.spec.js — e2e: Full-тир (VLESS+Reality) как ЗАПАСНОЙ путь в панели.
//
// Продуктовая рамка: основной туннель — AmneziaWG; если он не поднимается (сеть режет UDP),
// человек доустанавливает VLESS+Reality и вставляет ссылку своего сервера. Проверяем именно это:
//   • на РАБОТАЮЩЕМ Reality панель не кричит «VPN не работает» (регресс: судила по AWG-рукопожатию,
//     которого у VLESS нет, и вела заменять AWG-конфиг — движок такую замену даже не принимает);
//   • когда AWG мёртв, панель ведёт к запасному пути ровно в этот момент (доустановить/переключить);
//   • мёртвый Reality ведёт к своей починке (ссылка vless://), а не к AWG-конфигу;
//   • слабое железо получает честное объяснение, почему кнопки нет;
//   • провал догрузки различает «нет места» и «нет интернета».

import { test, expect } from '@playwright/test';

test.beforeEach(async ({ request }) => {
  await request.post('/__reset');
});

// Панель открывается сразу, когда роутер уже настроен (installed=true).
async function openPanel(page, request, state) {
  await request.post('/__set', { data: state });
  await page.goto('/cheburnet/');
  await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible();
}

test('рабочий Reality: панель не врёт про «VPN не работает»', async ({ page, request }) => {
  await openPanel(page, request, { installed: true, protocol: 'reality', fullCapable: true, fullInstalled: true });

  await expect(page.getByText('VPN не работает')).toHaveCount(0);
  await expect(page.getByText('VLESS+Reality активен')).toBeVisible();
  // Строка сводки говорит про туннель, а не про молчащий AWG-сервер.
  await expect(page.getByText('поднят (VLESS+Reality)')).toBeVisible();
  await expect(page.getByText('нет ответа от сервера')).toHaveCount(0);
  // Починка предлагается правильная — замена Reality-ссылки, не AWG-конфига.
  await expect(page.getByRole('heading', { name: 'Замена Reality-сервера' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Замена VPN-конфига' })).toHaveCount(0);
});

test('мёртвый AWG на подходящем железе: панель ведёт доустановить Reality', async ({ page, request }) => {
  await request.post('/__vpn-down');
  await openPanel(page, request, { installed: true, protocol: 'awg', fullCapable: true, fullInstalled: false });

  await expect(page.getByText('VPN не работает')).toBeVisible();
  // Главный сценарий Full-тира: подсказка про UDP + ссылка на блок догрузки.
  const hint = page.getByText('режет сам протокол AmneziaWG', { exact: false });
  await expect(hint).toBeVisible();
  await expect(hint.getByRole('link', { name: 'добавить VLESS+Reality' })).toBeVisible();
  await expect(page.getByRole('heading', { name: /VLESS \+ Reality — запасной туннель/ })).toBeVisible();
});

test('мёртвый AWG, sing-box уже стоит: ведёт переключиться, а не ставить заново', async ({ page, request }) => {
  await request.post('/__vpn-down');
  await openPanel(page, request, { installed: true, protocol: 'awg', fullCapable: true, fullInstalled: true });

  const hint = page.getByText('уже установлен', { exact: false });
  await expect(hint).toBeVisible();
  await expect(hint.getByRole('link', { name: 'переключитесь на VLESS+Reality' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Переключиться на VLESS+Reality' })).toBeVisible();
});

test('мёртвый Reality: починка — свежая ссылка или возврат на AmneziaWG', async ({ page, request }) => {
  await request.post('/__vpn-down');
  await openPanel(page, request, { installed: true, protocol: 'reality', fullCapable: true, fullInstalled: true });

  // Ищем сам абзац-баннер (getByText поймал бы <strong> внутри него, и ссылок в нём нет).
  const banner = page.locator('p.banner', { hasText: 'Туннель VLESS+Reality не поднят' });
  await expect(banner).toBeVisible();
  await expect(banner.getByRole('link', { name: /свежую ссылку/ })).toBeVisible();
  await expect(banner.getByRole('link', { name: /вернитесь на AmneziaWG/ })).toBeVisible();
  await expect(page.getByText('VPN не работает')).toHaveCount(0);
});

test('мало RAM: честно объясняем, почему Reality недоступен', async ({ page, request }) => {
  await openPanel(page, request, { installed: true, protocol: 'awg', fullCapable: false, fullInstalled: false });

  await expect(page.getByText('На этом роутере он недоступен', { exact: false })).toBeVisible();
  await expect(page.getByText('от 256 МБ оперативной памяти', { exact: false })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Включить VLESS+Reality' })).toHaveCount(0);
});

// Флеш — единственная причина, которую человек может устранить сам, поэтому подсказка адресная:
// раньше кнопка флеш вообще не проверяла и обещала то, что валилось на apk «No space left».
test('мало флеша: причина названа и сказано, как её устранить', async ({ page, request }) => {
  await openPanel(page, request, {
    installed: true, protocol: 'awg', fullCapable: false, fullInstalled: false,
    fullMissing: ['flash'],
  });

  await expect(page.getByText('не хватает свободного места', { exact: false })).toBeVisible();
  await expect(page.getByText('extroot', { exact: false })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Включить VLESS+Reality' })).toHaveCount(0);
});

test('догрузка не влезла на флеш: советуем освободить место, а не проверять интернет', async ({ page, request }) => {
  await openPanel(page, request, {
    installed: true, protocol: 'awg', fullCapable: true, fullInstalled: false,
    bgResult: 'fail', bgReason: 'no-space',
  });

  await page.getByRole('button', { name: 'Включить VLESS+Reality' }).click();
  await expect(page.getByText('Не хватило места на роутере', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText('AmneziaWG не затронут', { exact: false })).toBeVisible();
});

test('догрузка не скачалась: прежний совет про интернет остаётся', async ({ page, request }) => {
  await openPanel(page, request, {
    installed: true, protocol: 'awg', fullCapable: true, fullInstalled: false,
    bgResult: 'fail', bgReason: 'download',
  });

  await page.getByRole('button', { name: 'Включить VLESS+Reality' }).click();
  await expect(page.getByText('Не удалось скачать sing-box', { exact: false })).toBeVisible({ timeout: 15_000 });
});
