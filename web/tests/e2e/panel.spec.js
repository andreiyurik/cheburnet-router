// panel.spec.js — e2e панели управления: Full-тир (opt-in), переключение и замена туннеля,
// уход с заморожённой Hysteria2, серверы AWG, модалка входа. Ветки, которые не исполняет ни vitest (нет DOM),
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

// Управление туннелем и опасная зона свёрнуты (details.group): панель делает восемь разных вещей,
// и развёрнуто по умолчанию только то, ради чего сюда заходят. Тест раскрывает их так же, как
// человек — кликом по заголовку.
async function expand(page, id) {
  const g = page.locator(`#${id}`);
  if (!(await g.evaluate((el) => el.open))) await g.locator('> summary').click();
  await expect(g).toHaveJSProperty('open', true);
}

test('панель: кнопка догрузки ставит компонент и открывает переключение', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: false });
  await expand(page, 'tunnel-group');

  // Слабое железо кнопку не видит (гейт full_capable) — здесь она обязана быть.
  const btn = page.getByRole('button', { name: 'Установить компонент' });
  await expect(btn).toBeVisible();
  await btn.click();

  // Фон + поллинг → успех: подсказка про переключение, а после refresh статус
  // full_installed=true открывает блок «Сменить туннель» с VLESS+Reality.
  await expect(page.getByText('Компонент установлен. Ниже появился блок', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Сменить туннель' })).toBeVisible({ timeout: 10_000 });
  await expect(page.getByRole('radio', { name: /Протокол: VLESS\+Reality/ })).toBeVisible();
  // Заморожённая Hysteria2 (ADR 0009) среди вариантов не появляется.
  await expect(page.getByRole('radio', { name: /Протокол: Hysteria2/ })).toHaveCount(0);

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('install_full_tier');
});

test('панель: сбой догрузки → честное сообщение, текущий туннель не тронут', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: false, bgResult: 'fail' });
  await expand(page, 'tunnel-group');

  await page.getByRole('button', { name: 'Установить компонент' }).click();
  await expect(page.getByText('Не удалось скачать компонент', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText('Текущий туннель не затронут', { exact: false })).toBeVisible();
  // Кнопка снова доступна для повтора.
  await expect(page.getByRole('button', { name: 'Установить компонент' })).toBeEnabled();
});

test('панель: переключение AWG→Reality — успех меняет протокол на месте', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg' });
  await expand(page, 'tunnel-group');

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

test('панель: переключение не удалось → fail-safe-сообщение, протокол остался AWG', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'awg', bgResult: 'fail' });
  await expand(page, 'tunnel-group');

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
  await expand(page, 'tunnel-group');

  await expect(page.getByRole('heading', { name: 'Замена сервера (VLESS+Reality)' })).toBeVisible();
  await page.getByLabel('Ссылка vless:// или конфиг sing-box').first()
    .fill('vless://uuid@new.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Заменить конфиг' }).click();

  await expect(page.getByText('Новый сервер применён (VLESS+Reality)', { exact: false })).toBeVisible({ timeout: 15_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('replace_reality_conf');
  expect(calls).not.toContain('replace_awg_conf');
});

// Роутер на заморожённой Hysteria2 (ADR 0009) уходит обычным switch_to_*: тот же путь с откатом.
test('панель: с legacy Hysteria2 переключение на Reality зовёт switch_to_reality', async ({ page, request }) => {
  await openPanel(page, request, { fullCapable: true, fullInstalled: true, protocol: 'hysteria2' });
  await expand(page, 'tunnel-group');

  await expect(page.getByRole('button', { name: 'Заменить конфиг' })).toHaveCount(0);
  await page.getByRole('radio', { name: /Протокол: VLESS\+Reality/ }).check();
  await page.getByLabel('Ссылка vless:// или конфиг sing-box')
    .fill('vless://uuid@new.example.com:443?security=reality&pbk=k&sni=example.com');
  await page.getByRole('button', { name: 'Переключиться на VLESS+Reality' }).click();

  await expect(page.getByText('Переключено на VLESS+Reality', { exact: false })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Замена сервера (VLESS+Reality)' })).toBeVisible({ timeout: 10_000 });
  const bg = await (await request.get('/__last-bg')).json();
  expect(bg.method).toBe('switch_to_reality');
});

// Результат действия обязан появляться У СВОЕЙ кнопки. Раньше он печатался единственным абзацем
// под «Опасной зоной»: человек нажимал кнопку в начале страницы, а итог был через два экрана вниз —
// то есть невидим. Ассертим не «текст есть где-то», а СОСЕДСТВО с рядом кнопок.
test('панель: результат действия печатается рядом с кнопкой, а не в конце страницы', async ({ page, request }) => {
  await openPanel(page, request, {});

  await page.getByRole('button', { name: 'Обновить готовый список' }).click();
  const note = page.locator('[data-slot=action-note]');
  await expect(note).toHaveText(/Список обновлён/);

  // И оно НЕ уехало в опасную зону: там своё сообщение (о сбросе), чужих быть не должно.
  await expect(page.locator('#danger-group p', { hasText: 'Список обновлён' })).toHaveCount(0);
});

// Диагностика — единственный путь помочь удалённо, и одновременно самый опасный: пакет уходит в
// мессенджер. Проверяем оба обещания UI: содержимое показано ДО скачивания и список вырезанного
// назван. Без этого «мы всё вычистили» — слова, которые пользователь проверить не может.
test('панель: диагностика показывается до отправки и называет вырезанное', async ({ page, request }) => {
  await openPanel(page, request, {});

  // Ссылок на Telegram две (блок поддержки + футер «проблема или идея») — проверяем первую.
  await expect(page.getByRole('link', { name: '@industrialprofi' }).first()).toBeVisible();
  // Кнопки скачивания до сбора нет: скачивать нечего, и пустой файл человек бы отправил.
  await expect(page.getByRole('button', { name: 'Скачать файл' })).toHaveCount(0);

  await page.getByRole('button', { name: 'Собрать диагностику' }).click();

  await expect(page.getByText('Вырезано: ключи туннеля; пароль Wi-Fi', { exact: false }))
    .toBeVisible({ timeout: 10_000 });
  // Текст пакета виден на экране — именно то, что уйдёт в чат.
  await expect(page.locator('[data-slot=log]', { hasText: 'cheburnet — диагностика' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Скачать файл' })).toBeVisible();
});

// Диагностика содержит логи и топологию сети, поэтому она admin-метод: без входа rpcd отбивает
// её так же, как мутации, и панель обязана вести на вход, а не показывать голую ошибку.
test('панель: диагностика без входа ведёт на вход, а не отдаёт логи', async ({ page, request }) => {
  await openPanel(page, request, { adminLocked: true });

  await page.getByRole('button', { name: 'Собрать диагностику' }).click();
  await expect(page.getByRole('heading', { name: 'Вход в управление' })).toBeVisible();
  await expect(page.locator('[data-slot=log]', { hasText: 'cheburnet — диагностика' })).toHaveCount(0);
});

// «Сбросить настройку» люди читают как «удалить программу», а это не так. Плюс сброс раньше
// удалял install-токен, и повторная настройка упиралась в «запустите bootstrap по SSH» — стена для
// того, кто в SSH не ходит. Проверяем оба обещания: текст говорит, что останется, и после сброса
// есть путь в мастер прямо из панели.
test('панель: сброс честно говорит, что останется, и ведёт назад в мастер', async ({ page, request }) => {
  await openPanel(page, request, {});
  await expand(page, 'danger-group');

  await page.getByRole('button', { name: 'Сбросить настройку cheburnet…' }).click();
  // Честность до подтверждения: программа и панель остаются, удаление — отдельная команда.
  await expect(page.getByText('apk del cheburnet', { exact: false })).toBeVisible();
  await expect(page.getByText('Wi-Fi, пароль роутера', { exact: false })).toBeVisible();

  await page.getByLabel('Введите слово RESET для подтверждения').fill('RESET');
  await page.getByRole('button', { name: 'Подтвердить сброс' }).click();

  // Панель ЖДЁТ завершения, а не говорит «запущен» и умывает руки.
  await expect(page.getByText('конфигурация cheburnet снята', { exact: false }))
    .toBeVisible({ timeout: 15_000 });
  // Путь назад: ссылка со свежим токеном, выпущенным сбросом.
  const link = page.getByRole('link', { name: 'открыть мастер настройки' });
  await expect(link).toBeVisible();
  expect(await link.getAttribute('href')).toContain('token=');

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('factory_reset');
  expect(calls).toContain('install_token');
});

// Та же стена стояла и без сброса: установка снимает токен как одноразовый, поэтому «Настроить
// заново» доводило человека до последней кнопки мастера и получало «токен не найден».
test('панель: «Настроить заново» уносит в мастер с токеном, а не в отказ', async ({ page, request }) => {
  await openPanel(page, request, {});

  await page.getByRole('button', { name: 'Настроить заново' }).click();
  await expect(page).toHaveURL(/token=/, { timeout: 10_000 });

  const calls = await (await request.get('/__calls')).json();
  expect(calls).toContain('install_token');
});

test('панель: admin-метод без сессии → модалка входа; неверный пароль → счётчик; верный → успех', async ({ page, request }) => {
  await openPanel(page, request, { adminLocked: true });

  // Действие отбито PERMISSION_DENIED → вместо голой ошибки открывается вход.
  await page.getByRole('button', { name: 'Обновить готовый список' }).click();
  await expect(page.getByRole('heading', { name: 'Вход в управление' })).toBeVisible();

  // Кнопок «Войти» на странице две (блок входа под «Управлением» и в модалке) — скоупим модалкой.
  const modal = page.getByRole('dialog');

  // Неверный пароль — понятный счётчик попыток. Поле при этом НЕ блокируется: опечатка не должна
  // стоить перезагрузки страницы (перебор всё равно отбивает rpcd, а не панель).
  await modal.getByLabel('Пароль').fill('wrong-pass');
  await modal.getByRole('button', { name: 'Войти' }).click();
  await expect(page.getByText('Пароль не подошёл (попытка 1)', { exact: false })).toBeVisible();
  await expect(modal.getByLabel('Пароль')).toBeEnabled();

  // Верный — сессия получена, действие можно повторить.
  await modal.getByLabel('Пароль').fill('panel-pass-1');
  await modal.getByRole('button', { name: 'Войти' }).click();
  await expect(page.getByText('Вход выполнен — повторите действие.')).toBeVisible();
  // Конкретика от самого действия сохраняется (сколько доменов подтянулось), а не заменяется
  // безликим «готово» — admin() ставит дефолтный текст только если действие своего не дало.
  await page.getByRole('button', { name: 'Обновить готовый список' }).click();
  await expect(page.getByText('Список обновлён:', { exact: false })).toBeVisible();
});

// Вход — узкое место панели: пока он был подчёркнутым словом в абзаце, до настроек не доходили
// («панель только смотреть»). Тест держит оба решения: заметный блок и главная кнопка списка,
// которая ведёт КО ВХОДУ, а не стоит серой рядом с активной (серая читается как «сломано»).
test('панель: без сессии — блок входа, «Сохранить список» ведёт ко входу, после входа список правится', async ({ page, request }) => {
  await openPanel(page, request, { adminLocked: true });

  const gate = page.locator('[data-slot=login-gate]');
  await expect(gate).toBeVisible();
  await expect(gate.getByRole('button', { name: 'Войти' })).toBeVisible();

  // Само поле списка без сессии закрыто и объясняет почему: движок не отдаёт список без входа.
  const domains = page.getByLabel('Сайты напрямую — ваш список');
  await expect(domains).toBeDisabled();
  await expect(domains).toHaveAttribute('placeholder', /Войдите/);

  const save = page.getByRole('button', { name: 'Сохранить список' });
  await expect(save).toBeEnabled();
  await save.click();

  const modal = page.getByRole('dialog');
  await expect(modal.getByRole('heading', { name: 'Вход в управление' })).toBeVisible();
  // Курсор сразу в поле пароля: модалку открыл клик, лишний тап по полю на телефоне не нужен.
  await expect(modal.getByLabel('Пароль')).toBeFocused();

  await modal.getByLabel('Пароль').fill('panel-pass-1');
  await modal.getByRole('button', { name: 'Войти' }).click();

  // Вход закрывает блок и сразу подтягивает список (get_domains) — без второго клика.
  await expect(gate).toHaveCount(0);
  await expect(domains).toHaveValue('example.com');

  // Круг замыкается: правка сохраняется, а строка, не похожая на домен, названа, а не проглочена.
  await domains.fill('example.com\nexample.org\n!!!');
  await save.click();
  await expect(page.getByText('Сохранено: своих сайтов 2', { exact: false })).toBeVisible();
  await expect(page.getByText('пропущены: !!!', { exact: false })).toBeVisible();
});

// Серверы («страны»): переключение — фоновая операция с откатом, итог печатается у списка.
// Список стран — только после входа (как и свой список доменов), поэтому сценарии входят.
async function openServers(page, request) {
  await openPanel(page, request, { adminLocked: true });
  await expand(page, 'servers-group');
  await page.locator('#servers-group').getByRole('button', { name: 'Войти' }).click();
  const modal = page.getByRole('dialog');
  await modal.getByLabel('Пароль').fill('panel-pass-1');
  await modal.getByRole('button', { name: 'Войти' }).click();
  await expect(page.locator('[data-slot=profiles]')).toBeVisible();
}

test('панель: серверы — подключить другой, сбой возвращает прежний, активный не удалить', async ({ page, request }) => {
  await openServers(page, request);

  const list = page.locator('[data-slot=profiles]');
  const row = (name) => list.getByRole('listitem').filter({ hasText: name });
  await expect(row('Германия').getByText('подключён')).toBeVisible();
  // Подключённый сервер удалить нельзя — кнопки просто нет.
  await expect(row('Германия').getByRole('button', { name: 'Удалить' })).toHaveCount(0);

  await row('Нидерланды').getByRole('button', { name: 'Подключить' }).click();
  await expect(page.getByText('Подключён «Нидерланды» — трафик идёт через него.')).toBeVisible({ timeout: 15_000 });
  await expect(row('Нидерланды').getByText('подключён')).toBeVisible();

  // Сбой: прежний сервер вернулся, и панель говорит это прямо.
  await request.post('/__set', { data: { bgResult: 'fail' } });
  await row('Германия').getByRole('button', { name: 'Подключить' }).click();
  await expect(page.getByText('Сервер «Германия» не ответил — прежний подключён обратно', { exact: false }))
    .toBeVisible({ timeout: 15_000 });
  await expect(row('Нидерланды').getByText('подключён')).toBeVisible();
});

test('панель: серверы — добавить, поднять приоритет, включить автосмену', async ({ page, request }) => {
  await openServers(page, request);

  await page.getByRole('button', { name: '+ Добавить сервер' }).click();
  await page.getByLabel('Название').fill('Финляндия');
  await page.getByLabel('Конфиг AmneziaWG').fill('[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = p=\nEndpoint = 192.0.2.1:51820\n');
  await page.getByRole('button', { name: 'Сохранить сервер' }).click();
  await expect(page.getByText('Сервер «Финляндия» сохранён.')).toBeVisible();

  const items = page.locator('[data-slot=profiles] > li');
  await expect(items).toHaveCount(3);
  await items.nth(2).getByRole('button', { name: 'Выше по приоритету' }).click();
  await expect(items.nth(1)).toContainText('Финляндия');

  const auto = page.getByRole('checkbox', { name: /Переключаться самому/ });
  await auto.check();
  await expect(page.getByText('Автосмена включена.')).toBeVisible();
  await expect(auto).toBeChecked();
});

test('панель: серверы — отказ сохранить автосмену возвращает галочку', async ({ page, request }) => {
  await openServers(page, request);
  await request.post('/__set', { data: { failoverFails: true } });
  const auto = page.getByRole('checkbox', { name: /Переключаться самому/ });
  await auto.click();
  await expect(page.getByText('не удалось сохранить')).toBeVisible();
  await expect(auto).not.toBeChecked();
});
