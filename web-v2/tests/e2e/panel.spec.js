// panel.spec.js — e2e панели управления: Full-тир (opt-in), переключение и замена туннеля,
// объявленная скорость Hysteria2, модалка входа. Ветки, которые не исполняет ни vitest (нет DOM),
// ни wizard.spec (happy-path мастера): стейт-машина busy/poll в Status.svelte и протокол-зависимый
// выбор ubus-метода.

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

test('панель: кнопка догрузки ставит компонент и открывает переключение', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: false });

  // Слабое железо кнопку не видит (гейт full_capable) — здесь она обязана быть.
  const btn = page.getByRole('button', { name: 'Установить компонент' });
  await expect(btn).toBeVisible();
  await btn.click();

  // Фон + поллинг → успех: подсказка про переключение, а после refresh статус
  // full_installed=true открывает блок «Сменить туннель» с ОБОИМИ Full-протоколами.
  await expect(page.getByText('Компонент установлен. Ниже появился блок', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Сменить туннель' })).toBeVisible({ timeout: 10_000 });
  // Оба варианта предложены как ВЫБОР (одно поле ссылки на всех): три похожих поля подряд
  // провоцировали вставку ссылки в чужое.
  await expect(page.getByRole('radio', { name: /Протокол: VLESS\+Reality/ })).toBeVisible();
  await expect(page.getByRole('radio', { name: /Протокол: Hysteria2/ })).toBeVisible();

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('install_full_tier');
});

test('панель: сбой догрузки → честное сообщение, текущий туннель не тронут', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: false, bgResult: 'fail' });

  await page.getByRole('button', { name: 'Установить компонент' }).click();
  await expect(page.getByText('Не удалось скачать компонент', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText('Текущий туннель не затронут', { exact: false })).toBeVisible();
  // Кнопка снова доступна для повтора.
  await expect(page.getByRole('button', { name: 'Установить компонент' })).toBeEnabled();
});

test('панель: переключение AWG→Reality — успех меняет протокол на месте', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg' });

  await expect(page.getByRole('heading', { name: 'Сменить туннель' })).toBeVisible();
  await page.getByRole('radio', { name: /Протокол: VLESS\+Reality/ }).check();
  await page.getByLabel('Ссылка vless:// или конфиг sing-box')
    .fill('vless://uuid@reality.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Переключиться на VLESS+Reality' }).click();

  await expect(page.getByText('Переключено на VLESS+Reality — туннель работает.')).toBeVisible({ timeout: 15_000 });
  // После refresh протокол reality → секция замены становится Reality-вариантом.
  await expect(page.getByRole('heading', { name: 'Замена сервера (VLESS+Reality)' })).toBeVisible({ timeout: 10_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('switch_to_reality');
});

test('панель: переключение AWG→Hysteria2 зовёт свой метод со своим аргументом', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg' });

  await page.getByRole('radio', { name: /Протокол: Hysteria2/ }).check();
  await page.getByLabel('Ссылка hysteria2:// или конфиг sing-box')
    .fill('hysteria2://pw@hy2.example.com:443?sni=example.com');
  await page.getByRole('button', { name: 'Переключиться на Hysteria2' }).click();

  await expect(page.getByText('Переключено на Hysteria2 — туннель работает.')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Замена сервера (Hysteria2)' })).toBeVisible({ timeout: 10_000 });

  // Имя аргумента = имя формата: движок принимает hysteria2_conf, и подменять его нечем.
  const bg = await (await request.get('/__last-bg')).json();
  expect(bg.method).toBe('switch_to_hysteria2');
  expect(bg.args.hysteria2_conf).toContain('hysteria2://');
  expect('reality_conf' in bg.args).toBe(false);
});

// Brutal: скорость канала — осознанный опт-ин владельца, и она обязана ДОЕХАТЬ до движка.
// Если бы UI её терял, человек включал бы ручной режим впустую и не понимал, почему ничего не изменилось.
test('панель: объявленная скорость дописывается в ссылку Hysteria2', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg' });

  await page.getByRole('radio', { name: /Протокол: Hysteria2/ }).check();
  await page.getByLabel('Ссылка hysteria2:// или конфиг sing-box')
    .fill('hysteria2://pw@hy2.example.com:443?sni=example.com');
  // Настройка скорости обязана быть ЗДЕСЬ ЖЕ, рядом с полем: раньше она стояла ниже кнопки
  // переключения, и человек нажимал раньше, чем её видел.
  await page.getByRole('radio', { name: /Указать вручную/ }).check();
  await expect(page.getByText('связь станет', { exact: false })).toBeVisible();
  await page.getByLabel('Скорость приёма (Мбит/с)').fill('80');
  await page.getByLabel('Скорость отдачи (Мбит/с)').fill('20');
  await page.getByRole('button', { name: 'Переключиться на Hysteria2' }).click();

  await expect(page.getByText('Переключено на Hysteria2', { exact: false })).toBeVisible({ timeout: 15_000 });
  const bg = await (await request.get('/__last-bg')).json();
  expect(bg.args.hysteria2_conf).toContain('down=80');
  expect(bg.args.hysteria2_conf).toContain('up=20');
});

test('панель: без ручного режима скорость в ссылку НЕ попадает (остаётся BBR)', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg' });

  await page.getByRole('radio', { name: /Протокол: Hysteria2/ }).check();
  await page.getByLabel('Ссылка hysteria2:// или конфиг sing-box')
    .fill('hysteria2://pw@hy2.example.com:443?sni=example.com');
  await page.getByRole('button', { name: 'Переключиться на Hysteria2' }).click();

  await expect(page.getByText('Переключено на Hysteria2', { exact: false })).toBeVisible({ timeout: 15_000 });
  const bg = await (await request.get('/__last-bg')).json();
  expect(bg.args.hysteria2_conf).not.toContain('down=');
  expect(bg.args.hysteria2_conf).not.toContain('up=');
});

test('панель: переключение не удалось → fail-safe-сообщение, протокол остался AWG', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg', bgResult: 'fail' });

  await page.getByRole('radio', { name: /Протокол: VLESS\+Reality/ }).check();
  await page.getByLabel('Ссылка vless:// или конфиг sing-box')
    .fill('vless://uuid@dead.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Переключиться на VLESS+Reality' }).click();

  // Ключевое обещание UI: прежний туннель возвращён автоматически.
  await expect(page.getByText('прежний туннель (AmneziaWG) возвращён автоматически', { exact: false }))
    .toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Замена сервера (AmneziaWG)' })).toBeVisible();
});

test('панель: при protocol=reality замена конфига зовёт replace_reality_conf, не awg', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'reality' });

  await expect(page.getByRole('heading', { name: 'Замена сервера (VLESS+Reality)' })).toBeVisible();
  await page.getByLabel('Ссылка vless:// или конфиг sing-box').first()
    .fill('vless://uuid@new.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Заменить конфиг' }).click();

  await expect(page.getByText('Новый сервер применён (VLESS+Reality)', { exact: false })).toBeVisible({ timeout: 15_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('replace_reality_conf');
  expect(calls).not.toContain('replace_awg_conf');
});

test('панель: при protocol=hysteria2 замена зовёт replace_hysteria2_conf', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'hysteria2' });

  await page.getByLabel('Ссылка hysteria2:// или конфиг sing-box').first()
    .fill('hysteria2://pw@new.example.com:8443?sni=example.com');
  await page.getByRole('button', { name: 'Заменить конфиг' }).click();

  await expect(page.getByText('Новый сервер применён (Hysteria2)', { exact: false })).toBeVisible({ timeout: 15_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('replace_hysteria2_conf');
  expect(calls).not.toContain('replace_reality_conf');
});

// Результат действия обязан появляться У СВОЕЙ кнопки. Раньше он печатался единственным абзацем
// под «Опасной зоной»: человек нажимал кнопку в начале страницы, а итог был через два экрана вниз —
// то есть невидим. Ассертим не «текст есть где-то», а СОСЕДСТВО с рядом кнопок.
test('панель: результат действия печатается рядом с кнопкой, а не в конце страницы', async ({ page, request }) => {
  await openPanel(page, request, {});

  await page.getByRole('button', { name: 'Обновить список доменов' }).click();
  const note = page.locator('.row:has-text("Обновить список доменов") + p');
  await expect(note).toHaveText(/Список обновлён/);

  // И оно НЕ уехало в опасную зону: там своё сообщение (о сбросе), чужих быть не должно.
  await expect(page.locator('h3.danger-h ~ p', { hasText: 'Список обновлён' })).toHaveCount(0);
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
  // Конкретика от самого действия сохраняется (сколько доменов подтянулось), а не заменяется
  // безликим «готово» — admin() ставит дефолтный текст только если действие своего не дало.
  await page.getByRole('button', { name: 'Обновить список доменов' }).click();
  await expect(page.getByText('Список обновлён:', { exact: false })).toBeVisible();
});
