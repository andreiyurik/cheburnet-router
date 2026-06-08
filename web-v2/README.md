# web-v2/ — веб-мастер на Svelte (v2)

Статический SPA на **Svelte** (+ Vite), который отдаёт роутер по `/cheburnet/`. Общается с
[движком](../engine/) через **ubus RPC** (объект `cheburnet`). Проводит обычного человека через
настройку за несколько экранов с минимумом вопросов (см.
[web-wizard.md](../docs/v2/architecture/web-wizard.md)).

> Живёт в `web-v2/`, чтобы не задеть работающий v1 (`web/`) во время strangler-миграции. Когда
> v1 выводится — переезжает в `web/`.

## Экраны (MVP)

```
boot → preflight → setup → installing → status
```

1. **Preflight** — `cheburnet preflight`: показывает вердикт гейткипера (подходит ли железо) до
   любых изменений.
2. **Setup** — AWG-конфиг (вставка/файл), домены прямого доступа (необязательно), install-токен.
   Шлёт `cheburnet install {awg_conf, domains, token}`.
3. **Installing** — фоновая установка: `install` запускает, экран поллит `install_progress`
   (шаг + журнал) до `done` (см. [engine/ubus](../engine/ubus/) — фон+poll).
4. **Status** — `cheburnet status`: режим, домены, handshake, сервисы; автообновление.

> **Граница MVP.** Wi-Fi и пароль роутера — отдельные шаги движка, которых пока нет (в v2 движок
> ставит vpn→dns→doh→adblock→firewall). UI намеренно не просит того, что бэкенд не умеет.
> Управление (`set_mode`/`update_list`) — admin-методы: с анонимной сессией придёт
> PERMISSION_DENIED; кнопки на экране статуса показывают это честно. Вход (root) — следующая
> итерация. QR-ввод AWG — тоже последующее улучшение.

## Сборка

```sh
npm install
npm run build      # → ../package/cheburnet/files/web/ (готовый бандл несёт пакет)
npm run dev        # локальная разработка; ubus-вызовы нужно проксировать на роутер
```

`vite.config.js` собирает прямо в каталог пакета (`base: './'` — относительные пути под
`/cheburnet/`), чтобы OpenWrt-пакет всегда нёс готовый UI без node в SDK. Исходники — здесь,
собранный результат коммитится в `package/cheburnet/files/web/`.

## ubus-клиент

`src/lib/ubus.js` — тонкий клиент ubus JSON-RPC поверх `uhttpd-mod-ubus` (`/ubus`). До установки
ходит с нулевой сессией (ACL пакета даёт анониму read + install; мутация гейтится install-токеном).
Доменные ошибки движка (`{error}`) и коды ubus поднимаются как понятные исключения для UI.
