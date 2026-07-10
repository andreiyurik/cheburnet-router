# package/ — OpenWrt-пакет `cheburnet`

Сборка пакета через **OpenWrt SDK** (apk-based ветка). Пакет — чистые скрипты (движок на ucode,
ubus-обработчик, ACL, веб-мастер), компилировать нечего → `PKGARCH:=all`. Arch-зависимые
зависимости (`kmod-amneziawg` и т.п.) подбирает `apk` при установке.

## Что и куда ставит

| Источник в репо | На роутере | Что это |
|---|---|---|
| `engine/` (без `tests/`, `README.md`, `run-tests.sh`) | `/usr/share/cheburnet/engine/` | движок на ucode |
| `package/cheburnet/files/rpcd-cheburnet.sh` | `/usr/libexec/rpcd/cheburnet` | shim, запускающий обработчик |
| `engine/ubus/rpcd-acl.json` | `/usr/share/rpcd/acl.d/cheburnet.json` | ACL (выведена из реестра) |
| `package/cheburnet/files/web/` | `/www/cheburnet/` | веб-мастер (SPA на Svelte, собранный бандл из `web-v2/`) |

**Почему shim, а не обработчик напрямую.** rpcd сканирует только `/usr/libexec/rpcd/`, но
ubus-обработчик (`engine/ubus/rpcd-cheburnet`) опирается на относительные `import` (`./ubus.uc`)
и `sourcepath`-вычисление пути к движку — он должен жить **внутри дерева движка**. Трёхстрочный
shim `exec ucode -R …` мостит rpcd к нему, сохраняя относительные пути (см.
[engine/ubus](../engine/ubus/README.md)).

## Сборка

Пакет рассчитан на feed-как-`src-link` на корень репозитория: `$(CURDIR)/../..` в Makefile
указывает на корень с `engine/`. Эскиз сборки в CI (см. [.github/workflows/engine.yml](../.github/workflows/engine.yml)):

```sh
# в дереве OpenWrt SDK:
./scripts/feeds ... # или src-link на этот репозиторий
make package/cheburnet/compile V=s
```

> Реальная сборка и установка проверены в `make qemu-install-v2` (живой apk/rpcd/uhttpd) и
> вживую на роутере (GL-MT3000). Локально дополнительно проверяемы юнит-тесты движка
> (`make test-engine`) и lint.

## Зависимости (DEPENDS)

Движок: `ucode` + `ucode-mod-{fs,uci,ubus}`, `rpcd`+`rpcd-mod-file`. Data-plane: `dnsmasq-full`
(nftset), `https-dns-proxy` (DoH — блокировка рекламы/контента реализована выбором фильтрующего
DoH-резолвера, не отдельным пакетом adblock), `kmod-amneziawg`+`amneziawg-tools`, `nftables`+
`ip-full` (policy routing). Веб: `uhttpd`+`uhttpd-mod-ubus` (мост браузер→ubus).
