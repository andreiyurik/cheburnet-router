# bootstrap/ — тонкий установщик (feed + apk)

Один скрипт `bootstrap.sh` (~30 строк POSIX/busybox): подключает [OpenWrt-feed](../docs/v2/architecture/bootstrap.md)
cheburnet, ставит пакет через `apk` и печатает URL веб-мастера + install-токен.

**Намеренно тонкий.** Вся хрупкая логика (preflight, шаги, rollback) — в [движке на ucode](../engine/),
а не здесь. Это нормально и не противоречит уходу от bash: убираем bash из *логики*, а не из
загрузчика, для которого shell на OpenWrt универсален.

## Что делает

1. **Подключает feed** — пишет URL в `/etc/apk/repositories.d/cheburnet.list` и скачивает
   публичный ключ в `/etc/apk/keys/` (apk проверяет подпись пакетов).
2. **`apk add cheburnet`** — `apk` сам подбирает пакет под arch и тянет зависимости (отсюда
   «универсальность»). preflight-гейткипер внутри пакета честно откажет на негодном железе.
3. **Генерит install-токен** в `/etc/cheburnet/install-token` (600) — доказательство «я владелец
   роутера (есть SSH)» для первичной установки из веб-мастера. Метод `install` ([engine/ubus](../engine/ubus/))
   требует его; движок удаляет токен по завершении установки.
4. **Печатает** `http://<LAN-IP>/cheburnet/` (LAN-IP — динамически, не хардкодим подсеть) и токен.

## Запуск

```sh
# На роутере (OpenWrt 25.12+, apk-based), по SSH:
sh bootstrap.sh
```

Переопределяемо через env (тестовый feed в QEMU/CI):
`CHEBURNET_FEED_URL`, `CHEBURNET_FEED_KEY_URL`.

> Финальные URL feed'а и ключ фиксируются в фазе **пакет + feed + CI** (публикация при git-теге).
> Регистрация на шине, сборка пакета и реальный `apk add` проверяются в **QEMU**.
