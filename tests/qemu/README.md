# tests/qemu — VM smoke-тесты для cheburnet-router

Поднимают свежий **OpenWrt-snapshot x86-64** в qemu/KVM, накатывают наш rpcd-handler и проверяют, что он работает на **реальном** busybox-окружении (а не gawk/host-bash, на которых гоняются T1/T2).

## Запуск

| Команда | Что делает | Время | Интернет нужен? |
|---|---|---|---|
| `make qemu` | T3a — hermetic smoke: bringup VM + ubus-вызовы | ~90с | нет |
| `make qemu-http` | T3b — то же + uhttpd + HTTP/UI-кнопки | ~3мин | да (apk add) |

Оба запускаются из корня репо. При падении автоматически выводят последние 60 строк serial-консоли VM и возвращают exit ≠ 0.

## Что покрывает каждый уровень

### T3a — `smoke.sh` (hermetic)

Гарантирует, что наш handler работает на **реальном** OpenWrt без накатки сетапа:

- `web/rpcd-cheburnet` парсится busybox-ash (а не bash хоста).
- `web/rpcd-acl.json` принимается реальным rpcd (а не только python json.tool).
- rpcd регистрирует cheburnet-объект, `ubus list cheburnet` показывает все 8 методов.
- `ubus call cheburnet get_status` и `install_progress` отдают валидный JSON через ubusd.
- `lib/cheburnet-utils.sh::json_escape` корректен на **busybox-sed/awk**. Это критично: gawk хоста и busybox-awk имеют **разную семантику** gsub-replacement, и одна и та же awk-конструкция выдаёт разное число backslash'ей. Этот gap уже ловили в продакшне и в этом тесте.

T3a НЕ запускает `bootstrap.sh`, `apk update/add`, `wget` к github — все файлы кладутся напрямую через ssh+cat.

### T3b — `smoke-http.sh` (требует интернета)

Расширяет T3a: проверяет HTTP-уровень, **то что РЕАЛЬНО делают кнопки в UI**:

- uhttpd-mod-ubus поднят, `/ubus` отвечает на JSON-RPC.
- `web/index.html` отдаётся uhttpd'ом по `/cheburnet/index.html`.
- ACL-инфорсмент: anon-сессия может `get_status`/`install_progress`, но получает `code=6 (PERMISSION_DENIED)` на mode_switch / service_restart / set_blocklist_tier / **factory_reset (даже с confirm="RESET")**.
- session.login через root-пароль возвращает `ubus_rpc_session`.
- Хендлер-уровневая валидация работает без destructive-эффекта: factory_reset с confirm ≠ "RESET" отдаёт error и **НЕ запускает firstboot**, mode_switch с invalid mode → error, install_start без install-токена → "install token not found".
- Sanity в конце: VM ещё жива (никакие тесты случайно не triggered firstboot).

T3b ставит `uhttpd-mod-ubus` через `apk add` — **поэтому нужен интернет в VM** (qemu user-mode netdev → host).

## Что НЕ покрывает

- **Реальный setup/01-09 happy-path** (apk add amneziawg, sing-box, awg-quick) — это T3c, manual smoke перед релизом. Требует много времени и большого диска в VM.
- **Браузерный рендеринг** (CSS, race conditions при кликах, JS errors). Здесь UI-кнопки тестируются «через спину» — мы шлём те же ubus-запросы, что и UI, но не проверяем что они действительно произошли при клике на кнопку. Это покрывается ручным smoke в реальном браузере перед релизом.
- **Реальный AmneziaWG / Wi-Fi / nft на target-арке** (mips/arm/...). VM = x86-64; реальные роутеры — другие архитектуры с другим busybox/nft. Перед релизом — обязательная проверка на dirty-роутере.

## Артефакты

`tests/qemu/.work/` (в .gitignore) содержит:

- `openwrt-snapshot.img.gz` — кешированный образ (15 МБ).
- `disk.img` — пересоздаётся из `.gz` каждый запуск (никакого state'а от прошлых прогонов).
- `id_ed25519` / `id_ed25519.pub` — переиспользуемый SSH-ключ для VM.
- `serial.log` — лог serial-консоли (полезен при падении).
- `cmd.fifo` — fifo для отправки команд в serial. Удаляется trap'ом на выходе.

Очистить кеш целиком: `rm -rf tests/qemu/.work` (только образ перекачается заново).

## Как обновить SHA256 при апгрейде snapshot

OpenWrt snapshot — это rolling-сборка, upstream может обновиться в любой момент. Если SHA256 в `lib.sh` не совпадает с реальным — тест падает с понятной ошибкой `SHA256 mismatch`.

Чтобы прибить новый pin:

```sh
sha256sum tests/qemu/.work/openwrt-snapshot.img.gz
```

Скопировать первое поле в `IMG_SHA256` в `tests/qemu/lib.sh`. **Только после ручной проверки** что новая сборка ничего критичного не сломала (например, не сменилась версия busybox-awk на что-то ещё).

## Архитектура

- `lib.sh` — общая инфра: paths, deps, image-prep, qemu-launch, serial+ssh helpers, boot+setup, deploy. Source-only.
- `smoke.sh` — T3a-asserts поверх lib.sh.
- `smoke-http.sh` — T3b: HTTP/JSON-RPC asserts поверх lib.sh.

При падении — лог serial-консоли в `.work/serial.log`. Trap EXIT гарантированно убивает qemu и чистит fifo, даже на Ctrl+C.
