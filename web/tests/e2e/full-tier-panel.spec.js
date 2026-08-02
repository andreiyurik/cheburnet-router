// full-tier-panel.spec.js — e2e: запасные туннели (Full-тир) в панели.
//
// Продуктовая рамка: у человека сломано что-то конкретное, и панель обязана вести к тому туннелю,
// который ЭТУ поломку лечит (ADR 0004, три оси покрытия). Проверяем именно это:
//   • на РАБОТАЮЩЕМ Full-туннеле панель не кричит «не работает» (регресс: судила по AWG-рукопожатию,
//     которого у VLESS/Hysteria2 нет, и вела заменять AWG-конфиг — движок такую замену не принимает);
//   • когда активный туннель мёртв, панель ведёт к запасному пути ровно в этот момент;
//   • с AmneziaWG подсказка НЕ предлагает Hysteria2: он тоже UDP и упал бы вместе с AWG;
//   • мёртвый Full-туннель ведёт к своей починке (своя ссылка), а не к AWG-конфигу;
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

// Управление туннелем свёрнуто (details#tunnel-group) — раскрываем кликом, как человек.
async function expandTunnel(page) {
  const g = page.locator('#tunnel-group');
  if (!(await g.evaluate((el) => el.open))) await g.locator('> summary').click();
  await expect(g).toHaveJSProperty('open', true);
}

test('рабочий Reality: панель не врёт про «туннель не работает»', async ({ page, request }) => {
  await openPanel(page, request, { installed: true, protocol: 'reality', fullCapable: true, fullInstalled: true });
  await expandTunnel(page);

  await expect(page.getByText('Туннель не работает')).toHaveCount(0);
  await expect(page.getByText('VLESS+Reality активен')).toBeVisible();
  // Строка сводки говорит про туннель, а не про молчащий AWG-сервер.
  await expect(page.getByText('поднят (VLESS+Reality)')).toBeVisible();
  await expect(page.getByText('нет ответа от сервера')).toHaveCount(0);
  // Починка предлагается правильная — замена Reality-ссылки, не AWG-конфига.
  await expect(page.getByRole('heading', { name: 'Замена сервера (VLESS+Reality)' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Замена сервера (AmneziaWG)' })).toHaveCount(0);
});

// Тот же регресс для второго Full-протокола: у Hysteria2 рукопожатия тоже нет.
test('рабочий Hysteria2: свой зелёный статус и своя починка', async ({ page, request }) => {
  await openPanel(page, request, { installed: true, protocol: 'hysteria2', fullCapable: true, fullInstalled: true });
  await expandTunnel(page);

  await expect(page.getByText('Hysteria2 активен')).toBeVisible();
  await expect(page.getByText('поднят (Hysteria2)')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Замена сервера (Hysteria2)' })).toBeVisible();
  await expect(page.getByLabel('Ссылка hysteria2:// или конфиг sing-box')).toBeVisible();
});

test('мёртвый AWG на подходящем железе: панель ведёт доустановить компонент', async ({ page, request }) => {
  await request.post('/__vpn-down');
  await openPanel(page, request, { installed: true, protocol: 'awg', fullCapable: true, fullInstalled: false });

  await expect(page.getByText('Туннель не работает (AmneziaWG)')).toBeVisible();
  // Главный сценарий Full-тира: подсказка про UDP + ссылка на блок догрузки.
  const hint = page.getByText('режет сам протокол AmneziaWG', { exact: false });
  await expect(hint).toBeVisible();
  // Ссылка обязана не просто вести к якорю, но и РАСКРЫТЬ свёрнутый блок: иначе якорь прыгал бы
  // в закрытый <details> и человек оказывался бы на пустом месте.
  await hint.getByRole('link', { name: 'добавить VLESS+Reality' }).click();
  await expect(page.locator('#tunnel-group')).toHaveJSProperty('open', true);
  await expect(page.getByRole('heading', { name: /Запасные туннели/ })).toBeVisible();
});

test('мёртвый AWG, компонент уже стоит: ведёт переключиться, а не ставить заново', async ({ page, request }) => {
  await request.post('/__vpn-down');
  await openPanel(page, request, { installed: true, protocol: 'awg', fullCapable: true, fullInstalled: true });

  const hint = page.getByText('дело, скорее всего, не в сервере', { exact: false });
  await expect(hint).toBeVisible();
  await expect(hint.getByRole('link', { name: 'VLESS+Reality' })).toBeVisible();
  // КЛЮЧЕВОЕ: Hysteria2 в подсказке «не открывается» быть НЕ должно — он работает по UDP, как и
  // AmneziaWG, значит сеть, которая режет UDP, ломает их вместе. Предлагать его тут = гонять по кругу.
  await expect(hint.getByRole('link', { name: 'Hysteria2' })).toHaveCount(0);
  // Но в общем блоке «Сменить туннель» он доступен — как осознанный выбор, а не как лечение.
  await expandTunnel(page);
  await expect(page.getByRole('radio', { name: /Протокол: Hysteria2/ })).toBeVisible();
});

test('мёртвый Reality: починка — свежая ссылка, есть куда уйти', async ({ page, request }) => {
  await request.post('/__vpn-down');
  await openPanel(page, request, { installed: true, protocol: 'reality', fullCapable: true, fullInstalled: true });

  // Ищем сам абзац-баннер (getByText поймал бы <strong> внутри него, и ссылок в нём нет).
  const banner = page.locator('p.banner', { hasText: 'Туннель не работает (VLESS+Reality)' });
  await expect(banner).toBeVisible();
  await expect(banner.getByRole('link', { name: /свежий конфиг/ })).toBeVisible();
  // С Full-туннеля предлагаем и второй Full, и возврат на лёгкий AmneziaWG.
  const hint = page.locator('p.note', { hasText: 'дело, скорее всего, не' });
  await expect(hint.getByRole('link', { name: 'Hysteria2' })).toBeVisible();
  await expect(hint.getByRole('link', { name: 'AmneziaWG' })).toBeVisible();
});

test('мало RAM: честно объясняем, почему запасных туннелей нет', async ({ page, request }) => {
  await openPanel(page, request, { installed: true, protocol: 'awg', fullCapable: false, fullInstalled: false });
  await expandTunnel(page);

  await expect(page.getByText('на этом роутере недоступны', { exact: false })).toBeVisible();
  await expect(page.getByText('от 256 МБ оперативной памяти', { exact: false })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Установить компонент' })).toHaveCount(0);
});

// Флеш — единственная причина, которую человек может устранить сам, поэтому подсказка адресная:
// раньше кнопка флеш вообще не проверяла и обещала то, что валилось на apk «No space left».
test('мало флеша: причина названа и сказано, как её устранить', async ({ page, request }) => {
  await openPanel(page, request, {
    installed: true, protocol: 'awg', fullCapable: false, fullInstalled: false,
    fullMissing: ['flash'],
  });
  await expandTunnel(page);

  await expect(page.getByText('не хватает свободного места', { exact: false })).toBeVisible();
  await expect(page.getByText('extroot', { exact: false })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Установить компонент' })).toHaveCount(0);
});

test('догрузка не влезла на флеш: советуем освободить место, а не проверять интернет', async ({ page, request }) => {
  await openPanel(page, request, {
    installed: true, protocol: 'awg', fullCapable: true, fullInstalled: false,
    bgResult: 'fail', bgReason: 'no-space',
  });
  await expandTunnel(page);

  await page.getByRole('button', { name: 'Установить компонент' }).click();
  await expect(page.getByText('Не хватило места на роутере', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText('Текущий туннель не затронут', { exact: false })).toBeVisible();
});

test('догрузка не скачалась: прежний совет про интернет остаётся', async ({ page, request }) => {
  await openPanel(page, request, {
    installed: true, protocol: 'awg', fullCapable: true, fullInstalled: false,
    bgResult: 'fail', bgReason: 'download',
  });
  await expandTunnel(page);

  await page.getByRole('button', { name: 'Установить компонент' }).click();
  await expect(page.getByText('Не удалось скачать компонент', { exact: false })).toBeVisible({ timeout: 15_000 });
});
