# bootstrap/ — тонкий установщик (awg-kmod + пакет из Releases)

Один скрипт `bootstrap.sh` (~50 строк POSIX/busybox): ставит kmod-amneziawg через
[awg-openwrt](../vendor/README.md), ставит пакет cheburnet из наших GitHub Releases
(`--allow-untrusted`) и печатает URL веб-мастера + install-токен. Архитектура — [docs/v2/architecture/bootstrap.md](../docs/v2/architecture/bootstrap.md).

**Намеренно тонкий.** Вся хрупкая логика (preflight, шаги, rollback) — в [движке на ucode](../engine/),
а не здесь. Это нормально и не противоречит уходу от bash: убираем bash из *логики*, а не из
загрузчика, для которого shell на OpenWrt универсален.

## Что делает

1. **Скачивает всё до установки чего-либо** (fail-closed): vendored awg-инсталлятор и
   `cheburnet.apk` из GitHub Releases. Любой недоступный артефакт → скрипт умирает, роутер не тронут.
2. **kmod-amneziawg + amneziawg-tools** — через pinned-копию инсталлятора awg-openwrt
   (`-n -e`: только пакеты, без настройки интерфейса). Модуль ядра привязан к vermagic —
   собирать его сами не можем, импортируем у upstream.
3. **`apk add --allow-untrusted cheburnet.apk`** — apk-tools 3 доверяет пакетам только через
   подписанный индекс репо (APKINDEX), не через подпись одиночного файла, поэтому локальный `.apk`
   ставим `--allow-untrusted` (аутентичность держит HTTPS с Release, как и unsigned kmod из
   awg-openwrt). Зависимости (dnsmasq-full, https-dns-proxy, …) apk тянет из штатного подписанного
   feed OpenWrt. preflight-гейткипер внутри пакета честно откажет на негодном железе.
4. **Генерит install-токен** в `/etc/cheburnet/install-token` (600) — доказательство «я владелец
   роутера (есть SSH)» для первичной установки из веб-мастера. Метод `install` ([engine/ubus](../engine/ubus/))
   требует его; движок удаляет токен по завершении установки.
5. **Печатает** `http://<LAN-IP>/cheburnet/?token=…` (LAN-IP — динамически, не хардкодим подсеть).

## Запуск

```sh
# На роутере (OpenWrt 25.12+, apk-based), по SSH:
sh bootstrap.sh
```

Переопределяемо через env (локальное зеркало в QEMU/CI):
`CHEBURNET_SRC_BASE` (raw-база репо: awg-инсталлятор), `CHEBURNET_RELEASE_BASE`
(база Release-ассетов), `CHEBURNET_PKG` (имя .apk), `CHEBURNET_AWG_INSTALL_URL`
(точечные переопределения).

> Пакет НЕ подписываем: apk-tools 3 проверяет подпись только у индекса репозитория, а мы раздаём
> одиночный `.apk` с Release → ставим `--allow-untrusted`. Настоящий подписанный feed (свой
> APKINDEX на GitHub Pages) — возможная будущая фаза.
