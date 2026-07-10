# tests/

Тестовая инфраструктура `cheburnet-router`. Пирамида уровней описана в `CLAUDE.md`.

## Структура

```
tests/
├── lint.sh                       # T1 — единая точка статики (CI + локально)
├── poc/split-routing-netns.sh    # Фаза 0 PoC: split-routing на nft/ip в network namespace
└── qemu/                         # T3 — живой OpenWrt в qemu/KVM
    ├── lib.sh                    # общая инфра (образ snapshot'а, serial-консоль)
    ├── smoke-v2.sh                # T3a: hermetic smoke движка (rpcd, ubus, fw4)
    ├── install-v2.sh              # T3c: DEPENDS + data-plane через реальный apk-feed
    └── webui-v2.sh                # T3b: HTTP-слой веб-мастера (uhttpd, ACL, сессии)
```

Юнит-тесты движка (чистая логика на ucode) живут рядом с кодом в `engine/` — см.
[engine/README.md](../engine/README.md) и `make test-engine`.

## T1 — статика

```bash
make lint
```

Один скрипт `tests/lint.sh`, гоняется одинаково локально и в CI (`.github/workflows/lint.yml`):
shellcheck (POSIX-режим) на shell-скриптах, `sh -n`/`ucode -c` safety-net, JSON-валидация ACL.

### Если shellcheck ругается

Не глуши `# shellcheck disable=...` без объяснения. Известная легитимная причина:
`SC3043` (`local`) на скриптах для роутера — busybox-ash поддерживает `local`, POSIX — нет.
Подавляй с пометкой "busybox-ash supports local". Всё остальное — чини, не глуши.

## T2 — юниты движка

```bash
make test-engine
```

Чистая логика на ucode (preflight, генерация конфигов, шаги установки) — без роутера, секунды.
Discovery через `find` в `engine/run-tests.sh`, каждый модуль движка держит тесты рядом с собой
(`engine/<module>/tests/`). Подробности и конвенции — `engine/README.md`.

## Фаза 0 — PoC split-routing

```bash
make poc-split
```

Прогоняет реальный вывод генератора routing (`engine/routing/`) через `nft`/`ip` в rootless
network namespace — проверяет, что сгенерированные правила реально работают в ядре, а не только
проходят юнит-ассерты.

## T3 — QEMU (живой OpenWrt)

```bash
make qemu-v2           # T3a: hermetic smoke, без интернета, ~2 мин
make qemu-webui-v2     # T3b: + HTTP/ubus через uhttpd, нужен интернет, ~3 мин
make qemu-install-v2   # T3c: DEPENDS + data-plane на реальном apk-feed, ~5-8 мин
```

Поднимают OpenWrt-snapshot x86-64 в qemu/KVM и гоняют движок на **реальном** busybox-окружении
(не host-bash/gawk, на которых работают T1/T2). Детали и что именно каждый уровень покрывает —
[tests/qemu/README.md](qemu/README.md). Гейтят CI: `qemu-v2-smoke` на каждый push/PR,
`qemu-install-v2` — release-gate (нужен интернет, не гоняется на PR).

## T4 — живой роутер

Ручной прогон на реальном железе перед тегом — не автоматизирован (physical Wi-Fi, реальный
AWG-handshake, reboot). См. [docs/v2/meta/release-checklist.md](../docs/v2/meta/release-checklist.md).
