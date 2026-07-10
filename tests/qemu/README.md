# tests/qemu — VM smoke-тесты для cheburnet-router

Поднимают свежий **OpenWrt-snapshot x86-64** в qemu/KVM, накатывают движок и проверяют, что он
работает на **реальном** busybox-окружении (а не gawk/host-bash, на которых гоняются T1/T2).

## Запуск

| Команда | Что делает | Время | Интернет нужен? |
|---|---|---|---|
| `make qemu-v2` | T3a — hermetic smoke движка: ubus-методы, граница доверия, rootpass→session.login, family, NAT-зона+nft+teardown | ~2мин | нет* |
| `make qemu-webui-v2` | T3b — + uhttpd + HTTP/UI: раздача Svelte-бандла, ACL anon-vs-admin, session.login | ~3мин | да (apk add uhttpd-mod-ubus) |
| `make qemu-install-v2` | T3c — установка через **apk** + data-plane против реальных сервисов (dnsmasq-full/https-dns-proxy) | ~5-8мин | да (apk) |

Все запускаются из корня репо. При падении автоматически выводят последние 60 строк
serial-консоли VM и возвращают exit ≠ 0. (*первый запуск качает образ snapshot'а — дальше кэш.)

### T3a — `smoke-v2.sh` (hermetic)

Деплоит движок **как пакет** (shim → `/usr/libexec/rpcd/cheburnet`, engine без `tests/` в
`/usr/share/cheburnet`, ACL из реестра) и проверяет на живом OpenWrt то, что юниты и dry-run'ы
не могут: регистрацию ubus-методов, границу доверия сквозь настоящий rpcd (required/токен-гейт/
confirm), `steps/rootpass` на реальном busybox `passwd` + **`session.login` этим паролем**
(ключевое допущение входа в панель), no-op wifi-шага без радио, family on/off на реальном
busybox-uci, NAT-зону + nft-цепочки + `--teardown` на реальном fw4. Не покрывает: HTTP-слой
`/ubus` с ACL-инфорсментом (уровень T3b) и полный install (apk, AWG-сервер).

T3a НЕ зовёт `apk`/`wget` к github — все файлы кладутся напрямую через ssh+cat, интернет не нужен.

### T3b — `webui-v2.sh` (требует интернета)

Путь **браузера**, а не прямых ubus-вызовов: `uhttpd` + `uhttpd-mod-ubus` раздают собранный
Svelte-бандл (`index.html` + hashed asset) и принимают JSON-RPC на `/ubus`. Проверяет:

- ACL-инфорсмент: anon-сессия может читать (`status`/`install_progress`), но получает `code=6`
  (`PERMISSION_DENIED`) на `set_mode`/`service_restart`/`factory_reset`.
- `install` гейтится install-токеном (см. [[../../docs/v2/architecture/reliability|reliability]]).
- `session.login` — отказ на неверном пароле, успех на верном (root-пароль из `steps/rootpass`).
- После входа admin-методы (`service_restart`) проходят; `factory_reset` с неверным `confirm`
  отдаёт доменную ошибку, не запускает reset.

Ставит `uhttpd-mod-ubus` через `apk add` — **поэтому нужен интернет в VM**.

### T3c — `install-v2.sh` (установка через apk, нужен интернет)

Ставит DEPENDS пакета из **реального apk-feed** на живой OpenWrt и гоняет data-plane против
**настоящих** сервисов (а не подсунутых руками): проверяет, что `package/cheburnet/Makefile`
DEPENDS вообще резолвятся под arch; `dnsmasq` → `dnsmasq-full` swap; `dns`-шаг (реальный
dnsmasq-full перечитывает наш nftset); `doh`-шаг (реальный https-dns-proxy стартует с нашими
резолверами); preflight на живом `apk --simulate` даёт вердикт. `kmod-amneziawg` (нет под
x86-ядро snapshot) — ожидаемый partial-fail, репортится честно. Реальный AWG-туннель/handshake
и Wi-Fi-радио — вне охвата QEMU, проверяются на железе (см.
[docs/v2/meta/release-checklist.md](../../docs/v2/meta/release-checklist.md)).

## Что НЕ покрывает

- **Реальный AmneziaWG/VLESS happy-path** на целевой arch (kmod на mips/arm недоступен в
  x86-snapshot) — ручной smoke на физическом роутере перед релизом.
- **Браузерный рендеринг** (CSS, race conditions при кликах, JS-ошибки). T3b шлёт те же
  ubus-запросы, что и UI, но не кликает по кнопкам в реальном движке рендеринга.
- **Реальный Wi-Fi / nft kill-switch на целевой arch.** VM = x86-64; реальные роутеры — другие
  архитектуры с другим nft/hostapd.

## Артефакты

`tests/qemu/.work/` (в .gitignore) содержит:

- `openwrt-snapshot.img.gz` — кешированный образ (15 МБ).
- `disk.img` — пересоздаётся из `.gz` каждый запуск (никакого state'а от прошлых прогонов).
- `id_ed25519` / `id_ed25519.pub` — переиспользуемый SSH-ключ для VM.
- `serial.log` — лог serial-консоли (полезен при падении).
- `cmd.fifo` — fifo для отправки команд в serial. Удаляется trap'ом на выходе.

Очистить кеш целиком: `rm -rf tests/qemu/.work` (только образ перекачается заново).

## Как обновить SHA256 при апгрейде snapshot

OpenWrt snapshot — это rolling-сборка, upstream может обновиться в любой момент. Если SHA256 в
`lib.sh` не совпадает с реальным — тест падает с понятной ошибкой `SHA256 mismatch`.

Чтобы прибить новый pin:

```sh
sha256sum tests/qemu/.work/openwrt-snapshot.img.gz
```

Скопировать первое поле в `IMG_SHA256` в `tests/qemu/lib.sh`. **Только после ручной проверки**,
что новая сборка ничего критичного не сломала (например, не сменилась версия busybox-awk).

## Архитектура

- `lib.sh` — общая инфра: paths, deps, image-prep, qemu-launch, serial+ssh helpers, boot+setup, deploy. Source-only.
- `smoke-v2.sh` — T3a-asserts поверх lib.sh.
- `webui-v2.sh` — T3b: HTTP/JSON-RPC asserts поверх lib.sh.
- `install-v2.sh` — T3c: DEPENDS + data-plane на реальных сервисах.

При падении — лог serial-консоли в `.work/serial.log`. Trap EXIT гарантированно убивает qemu и
чистит fifo, даже на Ctrl+C.
