# tests/qemu — VM smoke-тесты для cheburnet-router

Поднимают свежий **OpenWrt-snapshot x86-64** в qemu/KVM, накатывают наш rpcd-handler и проверяют, что он работает на **реальном** busybox-окружении (а не gawk/host-bash, на которых гоняются T1/T2).

## Запуск

| Команда | Что делает | Время | Интернет нужен? |
|---|---|---|---|
| `make qemu` | T3a — hermetic smoke **v1** (заморожен): bringup VM + ubus-вызовы | ~90с | нет |
| `make qemu-v2` | T3a-v2 — hermetic smoke **движка v2** (ucode): 14 методов, граница доверия, rootpass→session.login, family, NAT-зона+nft+teardown | ~2мин | нет* |
| `make qemu-install-v2` | T3c-v2 — **установка через apk** + data-plane против реальных сервисов (dnsmasq-full/https-dns-proxy) | ~5-8мин | **да** (apk) |
| `make qemu-http` | T3b — то же + uhttpd + HTTP/UI-кнопки (v1) | ~3мин | да (apk add) |
| `make qemu-install` | T3c — полный прогон `setup/install.sh` на VM (v1) | ~5-10мин | да (apk + github) |

Все запускаются из корня репо. При падении автоматически выводят последние 60 строк serial-консоли VM и возвращают exit ≠ 0. (*первый запуск качает образ snapshot'а — дальше кэш.)

### T3a-v2 — `smoke-v2.sh` (движок v2, hermetic)

Деплоит движок **как пакет** (shim → `/usr/libexec/rpcd/cheburnet`, engine без `tests/` в
`/usr/share/cheburnet`, ACL из реестра) и проверяет на живом OpenWrt то, что юниты и dry-run'ы
не могут: регистрацию всех 14 ubus-методов, границу доверия сквозь настоящий rpcd (required/
токен-гейт/confirm), `steps/rootpass` на реальном busybox `passwd` + **`session.login` этим
паролем** (ключевое допущение входа в панель), no-op wifi-шага без радио, family on/off на
реальном busybox-uci, NAT-зону + nft-цепочки + `--teardown` на реальном fw4. Не покрывает:
HTTP-слой `/ubus` с ACL-инфорсментом (нужен uhttpd-mod-ubus → интернет, уровень T3b) и полный
install (apk, AWG-сервер).

### T3c-v2 — `install-v2.sh` (установка через apk, нужен интернет)

Ставит DEPENDS пакета из **реального apk-feed** на живой OpenWrt и гоняет data-plane против
**настоящих** сервисов (а не подсунутых руками): проверяет, что `package/cheburnet/Makefile`
DEPENDS вообще резолвятся под arch; `dnsmasq` → `dnsmasq-full` swap; `dns`-шаг (реальный
dnsmasq-full перечитывает наш nftset); `doh`-шаг (реальный https-dns-proxy стартует с нашими
резолверами); preflight на живом `apk --simulate` даёт вердикт. `adblock-lean` (не feed-пакет)
и `kmod-amneziawg` (нет под x86-ядро snapshot) — best-effort с репортом. Туннель/handshake и
adblock-списки — на железе/T3b.

## Что покрывает каждый уровень

### T3a — `smoke.sh` (hermetic)

Гарантирует, что наш handler работает на **реальном** OpenWrt без накатки сетапа:

- `web/rpcd-cheburnet` парсится busybox-ash (а не bash хоста).
- `web/rpcd-acl.json` принимается реальным rpcd (а не только python json.tool).
- rpcd регистрирует cheburnet-объект, `ubus list cheburnet` показывает все 8 методов.
- `ubus call cheburnet get_status` и `install_progress` отдают валидный JSON через ubusd.
- `lib/cheburnet-utils.sh::json_escape` корректен на **busybox-sed/awk**. Это критично: gawk хоста и busybox-awk имеют **разную семантику** gsub-replacement, и одна и та же awk-конструкция выдаёт разное число backslash'ей. Этот gap уже ловили в продакшне и в этом тесте.

T3a НЕ запускает корневой `install.sh`, `apk update/add`, `wget` к github — все файлы кладутся напрямую через ssh+cat.

### T3b — `smoke-http.sh` (требует интернета)

Расширяет T3a: проверяет HTTP-уровень, **то что РЕАЛЬНО делают кнопки в UI**:

- uhttpd-mod-ubus поднят, `/ubus` отвечает на JSON-RPC.
- `web/index.html` отдаётся uhttpd'ом по `/cheburnet/index.html`.
- ACL-инфорсмент: anon-сессия может `get_status`/`install_progress`, но получает `code=6 (PERMISSION_DENIED)` на mode_switch / service_restart / set_blocklist_tier / **factory_reset (даже с confirm="RESET")**.
- session.login через root-пароль возвращает `ubus_rpc_session`.
- Хендлер-уровневая валидация работает без destructive-эффекта: factory_reset с confirm ≠ "RESET" отдаёт error и **НЕ запускает firstboot**, mode_switch с invalid mode → error, install_start без install-токена → "install token not found".
- Sanity в конце: VM ещё жива (никакие тесты случайно не triggered firstboot).

T3b ставит `uhttpd-mod-ubus` через `apk add` — **поэтому нужен интернет в VM** (qemu user-mode netdev → host).

### T3c — `install.sh` (полный install на VM)

Расширяет T3b: вместо «положить только handler» — заливает весь репо в `/opt/cheburnet/` (как это делает корневой `install.sh` на роутере) и **запускает `setup/install.sh` целиком**:

- **Manifest application** — все 17 файлов из `setup/manifest.txt` раскладываются по `/usr/bin/`, `/etc/...`, `/etc/init.d/`, `/etc/hotplug.d/`. Проверяется через `ls /usr/bin/`.
- **Каждый setup-шаг 00-10** запускается на реальном busybox-OpenWrt — POSIX-совместимость, отсутствие bash-измов, корректность `cp`/`chmod`/`crontab`-вызовов.
- **install.log** пишется в `/tmp/cheburnet/install.log`, `state` обновляется на каждом шаге, `done` получает финальный код (`ok` или `fail-NN-stepname`).
- **Поведение при сбое** — install.sh должен корректно записать причину: «упало на конкретном шаге», а не зависнуть.

**Что T3c уже поймал в проде:** регрессии вида «использовал `install -m` вместо `cp+chmod`» — busybox-конфиг OpenWrt не включает `install`-утилиту. Mock-тесты этого не видели; T3a/T3b не покрывают `setup/install.sh`. Это **минимальный обязательный gate** перед каждым релизом.

**Ожидаемый результат на x86-snapshot:** установка проходит до **`01-amneziawg.sh`** и падает там — в snapshot OpenWrt для x86 не собран `kmod-amneziawg` (этот пакет публикуется только под target-архитектуры роутеров: aarch64/MediaTek MT7981 и т.п.). T3c считает это **partial-pass** (`exit 0`), потому что цель уровня — поймать **gen-purpose** регрессии (busybox-несовместимости, баги манифеста, ошибки в порядке шагов), а не реальный happy-path AmneziaWG. Полный happy-path — на железе, ручной smoke перед релизом.

T3c требует **интернет в VM** (apk update + github raw для podkop/adblock-lean инсталлеров).

## Что НЕ покрывает

- **Реальный AmneziaWG happy-path** на target-арке (kmod на mips/arm не доступен в x86-snapshot) — это уровень T3d, ручной smoke на физическом Cudy/Beryl AX перед релизом.
- **Браузерный рендеринг** (CSS, race conditions при кликах, JS errors). Здесь UI-кнопки тестируются «через спину» — мы шлём те же ubus-запросы, что и UI, но не проверяем что они действительно произошли при клике на кнопку. Это покрывается ручным smoke в реальном браузере перед релизом.
- **Реальный Wi-Fi / nft kill-switch на target-арке** (mips/arm/...). VM = x86-64; реальные роутеры — другие архитектуры с другим nft/hostapd. Перед релизом — обязательная проверка на dirty-роутере.

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
- `install.sh` — T3c: полный прогон `setup/install.sh` на VM, анализ итогового состояния.

При падении — лог serial-консоли в `.work/serial.log`. Trap EXIT гарантированно убивает qemu и чистит fifo, даже на Ctrl+C.
