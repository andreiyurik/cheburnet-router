// wizard.spec.js — e2e-смоук: полный проход мастера в реальном браузере.
//
// Гоняет СОБРАННЫЙ бандл против мок-роутера (mock-router.mjs): рендер, клики,
// переходы экранов, валидация — то, чего не видят ни vitest (нет DOM-потока),
// ни T3b (нет браузера). Happy-path: preflight → setup → confirm →
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
  await expect(page.getByLabel('Сайты напрямую')).toHaveValue('ru');
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
  // Предупреждение об обрыве связи во время установки — «родитель» не должен пугаться и
  // вынимать кабель (реальный инцидент живого прогона). Ставим ожидание заранее.
  await expect(page.getByText('интернет и Wi-Fi', { exact: false })).toBeVisible();
  await expect(page.getByText('Не выключайте роутер и не вынимайте кабель', { exact: false })).toBeVisible();
  await page.getByRole('button', { name: 'Установить' }).click();

  // Шаг 4: установка → успех (маскот) → панель управления.
  await expect(page.getByText('Шаг 4 из 4')).toBeVisible();
  // Та же успокаивающая подсказка видна и во время самой установки (пока идёт прогресс).
  await expect(page.getByText('Не выключайте роутер и не закрывайте страницу', { exact: false })).toBeVisible();
  await expect(page.getByText('Готово! Роутер настроен')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible({ timeout: 10_000 });
  // Режим показан сегментом с подсвеченным ТЕКУЩИМ состоянием: кнопка-переключатель раньше
  // называла то, куда переключит, и спорила со строкой сводки рядом.
  await expect(page.locator('.segmented button.active')).toHaveText('Дома');
});

// Full-железо: мастер даёт выбор туннеля ПО СИМПТОМУ и предвыбирает VLESS+Reality — самая частая
// поломка в фильтрующей сети — «VPN вообще не поднимается». Здесь же проверяем весь путь Hysteria2,
// включая осознанный опт-ин объявленной скорости (Brutal).
test('мастер на Full-железе: выбор по симптому, дефолт Reality, установка Hysteria2 со скоростью', async ({ page, request }) => {
  await request.post('/__set', { data: { hw: 'full' } });
  await page.goto('/cheburnet/?token=TESTTOKEN');
  await page.getByRole('button', { name: 'Продолжить' }).click();

  // Варианты названы через поломку, а не через протокол; название протокола — подписью.
  await expect(page.getByText('Интернет через VPN вообще не открывается')).toBeVisible();
  await expect(page.getByText('Интернет открывается, но тормозит и рвётся')).toBeVisible();
  await expect(page.getByText('Роутер слабый или хочется максимально быстро')).toBeVisible();
  // Дефолт на подходящем железе — Reality (и поле просит именно vless://).
  await expect(page.getByRole('radio', { name: /Интернет через VPN вообще не открывается/ })).toBeChecked();
  await expect(page.getByLabel('Ссылка vless:// или конфиг sing-box')).toBeVisible();

  // Выбираем «тормозит и рвётся» → поле меняется на hysteria2://.
  await page.getByRole('radio', { name: /Интернет открывается, но тормозит/ }).check();
  await page.getByLabel('Ссылка hysteria2:// или конфиг sing-box')
    .fill('hysteria2://pw@hy2.example.com:443,5000-6000?sni=example.com');

  // Скорость: по умолчанию автоматически; включаем ручной режим — обязано появиться
  // предупреждение, что завышение делает ХУЖЕ (иначе поле вредит молча).
  await expect(page.getByRole('radio', { name: /Подбирать автоматически/ })).toBeChecked();
  await page.getByRole('radio', { name: /Указать вручную/ }).check();
  await expect(page.getByText('связь станет', { exact: false })).toBeVisible();
  await page.getByLabel('Скорость приёма (Мбит/с)').fill('80');
  await page.getByLabel('Скорость отдачи (Мбит/с)').fill('20');

  await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
  await page.getByLabel('Повторите пароль').fill('secret-pass-1');
  await page.getByLabel('Имя сети (SSID)').fill('TestWifi');
  await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
  await page.getByRole('button', { name: 'Установить' }).click();

  // Сводка: протокол и адрес сервера — БЕЗ пароля (он в hy2-ссылке стоит до '@').
  await expect(page.getByText('Hysteria2 → hy2.example.com:443,5000-6000')).toBeVisible();
  await expect(page.getByText('pw@')).toHaveCount(0);
  await page.getByRole('button', { name: 'Установить' }).click();
  await expect(page.getByText('Готово! Роутер настроен')).toBeVisible({ timeout: 15_000 });

  // Аргументы доехали до движка: правильный протокол, правильное поле, объявленная скорость.
  const args = await (await request.get('/__last-install')).json();
  expect(args.protocol).toBe('hysteria2');
  expect(args.hysteria2_conf).toContain('down=80');
  expect(args.hysteria2_conf).toContain('up=20');
  expect('reality_conf' in args).toBe(false);
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

test('панель: VPN-сервер молчит → hero-баннер про мёртвый туннель + путь к замене конфига', async ({ page, request }) => {
  // Установлено, но handshake=null (сервер мёртв/заблокирован) — панель должна с одного взгляда
  // сказать, что не так и что делать, а не прятать проблему в строке таблицы.
  await request.post('/__vpn-down');
  await page.goto('/cheburnet/');
  await expect(page.getByRole('heading', { name: 'Состояние' })).toBeVisible();
  // Баннер называет и поломку, и протокол — иначе на трёх туннелях непонятно, что именно мертво.
  await expect(page.getByText('Туннель не работает (AmneziaWG)', { exact: false })).toBeVisible();
  // Ссылка «вставьте свежий конфиг» ведёт к разделу замены и раскрывает его: блок управления
  // туннелем в панели свёрнут, и без раскрытия якорь прыгал бы в закрытый <details>.
  await page.getByRole('link', { name: 'вставьте свежий конфиг' }).click();
  await expect(page.locator('#tunnel-group')).toHaveJSProperty('open', true);
  await expect(page.getByRole('heading', { name: 'Замена сервера (AmneziaWG)' })).toBeVisible();
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
