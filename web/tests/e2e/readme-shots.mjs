// readme-shots.mjs — скриншоты интерфейса для README (через герметичный mock-router).
// Снимает экран настройки и панель управления, светлую и тёмную, с реального собранного
// бандла — то, что видит пользователь.
//   node tests/e2e/readme-shots.mjs <out-dir>
//
// Правила кадра (README — это витрина, а не отладочный дамп):
//   • ширина окна = ширина контента + поля, иначе по бокам пустой фон в треть картинки;
//   • deviceScaleFactor 2 — GitHub ужимает картинку до 720px, на 1x текст мылится;
//   • кадр обрезан по смыслу (clip до нужного блока), без подвала и служебных кнопок;
//   • панель снимается ПОСЛЕ входа и с заполненным списком — иначе витрина показывает
//     пустое серое поле и «Войдите, чтобы увидеть список», то есть продукт в худшем виде.
import { chromium } from '@playwright/test';
import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';

const OUT = process.argv[2] || '/tmp/readme-shots';
// E2E_PORT — как в mock-router.mjs (в WSL mirrored-режиме 4317 бывает занят со стороны Windows).
const BASE = `http://127.0.0.1:${process.env.E2E_PORT ?? 4317}`;
// Контент мастера — max-w-xl (576px) плюс поля: 640 даёт воздух, но не пустоту по краям.
const VIEWPORT = { width: 640, height: 900 };
const ADMIN_PASS = 'panel-pass-1'; // мок принимает этот пароль (см. mock-router.mjs)
const AWG_CONF = `[Interface]
PrivateKey = 0000000000000000000000000000000000000000000=
Address = 10.8.1.7/32
DNS = 1.1.1.1
Jc = 4
Jmin = 40
Jmax = 70

[Peer]
PublicKey = 0000000000000000000000000000000000000000000=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0`;

const mock = spawn('node', ['tests/e2e/mock-router.mjs'], { stdio: 'inherit' });
await sleep(1200);

// shot — кадр от верха страницы до низа указанного элемента: снимок кончается на смысловой
// границе, а не на случайной высоте окна или на подвале со ссылками.
async function shot(page, path, last, pad = 20) {
  // Курсор уводим за кадр: иначе элемент под мышью снимается с подсветкой наведения и
  // выглядит наполовину выбранным.
  await page.mouse.move(0, 0);
  // КВИРК Playwright: boundingBox() отдаёт координаты относительно ОКНА, а clip при fullPage
  // ждёт координаты СТРАНИЦЫ. После fill() страница прокручена — кадр обрезался бы у шапки.
  const box = await last.evaluate((el) => {
    const r = el.getBoundingClientRect();
    return { y: r.top + window.scrollY, height: r.height };
  });
  await page.screenshot({
    path,
    fullPage: true,
    clip: { x: 0, y: 0, width: VIEWPORT.width, height: Math.ceil(box.y + box.height + pad) },
  });
}

const browser = await chromium.launch({ args: ['--no-sandbox'] });
try {
  for (const scheme of ['light', 'dark']) {
    const suffix = scheme === 'dark' ? '-dark' : '';
    const page = await browser.newPage({
      viewport: VIEWPORT,
      deviceScaleFactor: 2,
      colorScheme: scheme,
    });
    await page.request.post(`${BASE}/__reset`, { data: {} });
    // Железо, которое тянет Full-тир: на скриншоте видно все три туннеля живыми. На слабом мок
    // запирает два из трёх, и README показывал бы две недоступные строки вместо главной ценности.
    await page.request.post(`${BASE}/__set`, { data: { hw: 'full' } });
    await page.goto(`${BASE}/cheburnet/?token=TESTTOKEN`);
    await page.getByText('все 6 проверок пройдены').waitFor();
    await page.getByRole('button', { name: 'Продолжить' }).click();

    // Экран настройки — с заполненными полями (как у реального пользователя). Дефолт на таком
    // железе — Reality; для кадра берём AmneziaWG, рекомендованный в README.
    await page.getByRole('radio', { name: /Роутер слабый или хочется максимально быстро/ }).check();
    await page.getByLabel('VPN-конфиг').fill(AWG_CONF);
    await page.getByLabel('Пароль администратора (root)').fill('secret-pass-1');
    await page.getByLabel('Повторите пароль').fill('secret-pass-1');
    await page.getByLabel('Имя сети (SSID)').fill('MyHomeNet');
    await page.getByLabel('Пароль Wi-Fi').fill('wifi-pass-1');
    // Кадр мастера кончается на поле конфига: главное здесь — выбор туннеля ПО СИМПТОМУ,
    // а не вся форма на два экрана.
    await shot(page, `${OUT}/web-installer${suffix}.png`, page.getByText('По формату похоже на конфиг', { exact: false }));

    // Дальше до панели управления.
    await page.getByRole('button', { name: 'Установить' }).click();
    await page.getByText('Шаг 3 из 4').waitFor();
    await page.getByRole('button', { name: 'Установить' }).click();
    await page.getByText('Готово! Роутер настроен').waitFor({ timeout: 15_000 });
    await page.getByRole('button', { name: 'Открыть панель управления' }).click();
    await page.getByRole('heading', { name: 'Состояние' }).waitFor({ timeout: 10_000 });

    // Вход + свой список: витрина показывает рабочую панель, а не приглашение войти.
    await page.getByRole('button', { name: 'Войти' }).click();
    await page.getByRole('dialog').getByLabel('Пароль').fill(ADMIN_PASS);
    await page.getByRole('dialog').getByRole('button', { name: 'Войти' }).click();
    const list = page.getByLabel('Сайты напрямую — ваш список');
    await list.waitFor();
    await list.fill('ru\nexample.com\nexample.org');
    await page.getByRole('button', { name: 'Сохранить список' }).click();
    await page.getByText('Сохранено:', { exact: false }).waitFor({ timeout: 10_000 });
    // Перезагрузка убирает строку-результат («Сохранено: …»): витрина показывает спокойное
    // состояние, а не кадр посреди действия. Сессия живёт в sessionStorage и переживает reload.
    await page.reload();
    await page.getByRole('heading', { name: 'Состояние' }).waitFor({ timeout: 10_000 });
    await sleep(500); // дорисовка статусных строк и подгрузка списка

    // Кадр панели кончается на подписи под кнопками — на смысловой границе, а не на
    // полуобрезанном заголовке следующего раздела. Подвал со ссылками в витрину не идёт.
    await shot(page, `${OUT}/web-mgmt${suffix}.png`, page.getByText('добавит к вашему community-список', { exact: false }));
    await page.close();
  }
  console.log(`✓ скриншоты в ${OUT}`);
} finally {
  await browser.close();
  mock.kill();
}
