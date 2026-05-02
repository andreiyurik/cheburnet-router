# AGENTS — контекст для AI-ассистентов и maintainer'ов

Краткий ориентир для AI-моделей (Claude, GPT, Cursor) и инженеров после паузы. Обычным пользователям — [README.md](./README.md).

Принцип файла: здесь только то, что **нельзя получить из кода / `git log` / `ls`**. Всё остальное (структура папок, история коммитов, дерево файлов на роутере) AI узнаёт сам через tool'ы. Карты файлов и changelog'и здесь намеренно отсутствуют.

## Что это за проект

**Образовательный OpenWrt-стенд для пользователя из РФ** на роутере GL.iNet Beryl AX (GL-MT3000) или Cudy TR3000 (и др. на MediaTek MT7981) с ванильной OpenWrt 25.12.2. Цели: обход блокировок (.ru-сервисы напрямую с RU IP, остальное через VPN), блокировка рекламы, защита от утечек, шифрованный DNS.

Целевая аудитория — **бабушка/родители**, не разработчик. Открыл `http://192.168.1.1/cheburnet/`, заполнил 5 полей в браузере, получил рабочий роутер за 10 минут. CLI (`./setup.sh`) — для опытных пользователей и разработчиков.

Акценты: **простота для пользователя, надёжность (годы без обслуживания), приватность, образовательность глав docs/**.

## Стек технологий

| Компонент | Роль | Док |
|---|---|---|
| OpenWrt 25.12.2 | Базовая ОС, пакетный менеджер **apk** | https://openwrt.org/docs/ |
| AmneziaWG 2.0 | VPN-туннель с обфускацией (форк WireGuard) | [docs/02](docs/02-amneziawg.md) |
| Podkop 0.7.14 + sing-box 1.12.17 | Policy-based routing (TProxy + DNS-маршрутизация) | [docs/03](docs/03-podkop-routing.md) |
| adblock-lean 0.8.1 | Блокировка рекламы через dnsmasq (~200k Hagezi Pro) | [docs/04](docs/04-adblock.md) |
| dnsmasq + Quad9 DoH | Локальный DNS + зашифрованный upstream | [docs/05](docs/05-dns.md) |
| hostapd / wpad-mbedtls | Wi-Fi AP, WPA2/WPA3-mixed | [docs/06](docs/06-wifi.md) |
| nftables (fw4) | Kill switch и общий firewall | [docs/08](docs/08-killswitch.md) |
| CLI `vpn-mode` | Управление режимами HOME ⇄ TRAVEL | [docs/07](docs/07-modes.md) |

DNS-режим — **DoH, не FakeIP**. Если в диагностике видишь «Proxy traffic is not routed via FakeIP» — это **ожидаемо**.

## СТРОГО ЗАПРЕЩЕНО ДЛЯ ИИ

> **AI-агентам категорически запрещено делать `git commit` и `git push` — даже если пользователь явно просит.**
> Вносить изменения в файлы — можно. Коммитить и пушить — нельзя никогда. Если пользователь просит — отказаться и попросить его сделать самостоятельно.

## Точки входа

Два пути установки сходятся в одной точке — `setup/install.sh` на роутере:

- **Веб-мастер (для пользователя):** `bootstrap.sh` (на роутере) → ставит `web/rpcd-cheburnet` + ACL + UI + install-токен → пользователь открывает URL → RPC `install_start` → `setup/install.sh`.
- **CLI (для разработчиков):** `setup.sh` (на ноутбуке) → диалог → rsync репо в `/opt/cheburnet/` + scp `.conf` → ssh-вызов `setup/install.sh`.

`setup/install.sh` сам: применяет `setup/manifest.txt` (single source of truth для копирования файлов на роутер), затем запускает 11 пронумерованных шагов `setup/0X-*.sh`. Прогресс — в `/tmp/cheburnet/{state,done,install.log}`.

## Workflow для ИИ

1. **Сначала проверь `lib/`.** Прежде чем писать функцию для UCI/сети/диагностики — посмотри, нет ли в `lib/`. Регрессии «правил в одном месте, забыл в другом» уже стоили багов в проде.
2. **Не ломай защитные слои.** Three-layer kill-switch (см. `docs/08`). Кажется «лишний» — перечитай threat model.
3. **Podkop перегенерирует sing-box конфиг.** Не правь `/etc/sing-box/config.json` напрямую — потеряется. Правь UCI podkop'а через `lib/podkop-config.sh`.
4. **POSIX sh + busybox-совместимо** для всего что идёт на роутер. Хост-тулинг (`setup.sh`, `tests/lint.sh`) — bash. Всё shellcheck-clean.
5. **Никаких coreutils-only утилит** на роутере (`install -m`, `seq`, GNU-only флаги `find`/`sed`). Тестируй на busybox через `make qemu-install` если правка касается `setup/`.
6. **Логируй через `logger -t`.** Пользователь смотрит `logread -e <tag>`. **Не возвращай OK-логирование** — было раз, log-snapshot забивался шумом.
7. **Добавил файл в `scripts/` или `configs/`?** — добавь строку в `setup/manifest.txt`. CI поймает несоответствие (`manifest sanity/coverage`).
8. **Документация в `docs/`** — на русском, инженерный тон, mermaid-схемы. Конвенции видны из существующих глав.

## Важные инварианты (не нарушать)

Каждый инвариант — с **«почему»**, потому что без причины следующий AI решит, что строка лишняя.

- **`route_allowed_ips=0` на AWG-пире — intentional.** Routing делает podkop, не AWG-интерфейс. Если включить — у нас два роутера, конфликт.
- **`fully_routed_ips=<LAN_CIDR>` в секции `main`** — source-based routing для всего LAN. CIDR определяется через `net_lan_cidr` из `lib/net-detect.sh`, **не** хардкодь `192.168.1.0/24`. На нестандартных подсетях хардкод приводит к тихо-дырявому kill-switch.
- **`user_domain_list_type='dynamic'` в секции `main` обязателен.** Без него подkop логирует `Section 'main' does not have any enabled list, skipping` и **HOME-режим не работает**. Был incident в проде. Строка живёт в `lib/podkop-config.sh::podkop_apply_main_section`.
- **`community_lists='russia_outside'` в `exclude_ru` — НЕ путать с `russia_inside`.** Названия контринтуитивные: `russia_outside` = «исключения вне России (РФ пускаем напрямую)». Без community-листа RU-сервисы пойдут через VPN с не-российским IP → блокировки и капчи.
- **`sae-mixed` требует `wpad-mbedtls`**, а не `wpad-basic-mbedtls` (в ванильном OpenWrt — basic).
- **Cron-задачи логируют ТОЛЬКО аномалии.** `awg-watchdog`, `conntrack-monitor`, `dns-healthcheck` молчат при норме. busybox crond тоже молчит (`uci system.system.cronloglevel='8'`). Если пользователь говорит «`logread -e conntrack-monitor` пустой» — это **не баг**, это значит `<80%`. **Не возвращай OK-логирование** — log-snapshot забьётся шумом за день.
- **`setup/manifest.txt` — single source of truth.** Setup-шаги (`08-watchdog.sh` и т.д.) больше **не копируют файлы**, проверяют только `[ -x /usr/bin/X ]` и настраивают сервисы/cron. Если файла нет в манифесте — его не будет на роутере. CI охраняет (`manifest sanity/coverage`).
- **`lib/podkop-config.sh`** (`podkop_apply_main_section/_home/_travel`) — единственный источник правды для UCI-логики podkop. Используется и в `02-podkop.sh` (установка), и в `vpn-mode` (рантайм). **Не дублируй** `uci set podkop.exclude_ru.*` — был баг с рассинхроном.
- **`lib/net-detect.sh`** (`net_lan_ip`, `net_lan_cidr`) — определение LAN с правильным fallback (netifd → uci+ipcalc.sh, CIDR-стрип `192.168.1.1/24` → `192.168.1.1`). **Не дублируй** `${LAN_IP%%/*}` — оборачивай в эти функции.
- **`setup/install.sh` использует `cp + chmod`, не `install -m`.** Busybox-конфиг OpenWrt **не включает** утилиту `install`. Поймали в QEMU smoke на свежем snapshot.
- **`vendor/` устаревает.** Vendored snapshot'ы upstream-инсталлеров (podkop, adblock-lean) используются как fallback при DPI-блокировке `raw.githubusercontent.com`. Структурный долг — нет автоматического обновления. При значимых обновлениях upstream — обновлять руками.
- **Beryl AX slider:** GPIO `hi=HOME`, `lo=TRAVEL`. Slider читается через `vpn-mode detect` при загрузке.
- **Cudy TR3000 button:** нажатие → `vpn-mode toggle` через `/etc/hotplug.d/button/10-vpn-mode`. State в `/etc/vpn-mode.state`, restore на boot через `/etc/init.d/vpn-mode`.

## Где смотреть проблемы

Авторитетный гайд: [docs/09-troubleshooting.md → Логи](docs/09-troubleshooting.md#логи--куда-смотреть). Cheat sheet: [docs/commands.md → Логи](docs/commands.md#-логи-что-где-смотреть).

Минимум для отладки: `logread -f` (live) | `logread -e <tag>` (фильтр) | `/root/logs/system-YYYY-MM-DD.log` (история 14 дней) | `awg show awg0` + `vpn-mode status` + `/etc/init.d/sing-box status` (live-state) | `/tmp/cheburnet/install.log` + `/tmp/cheburnet/done` (логи установки).

При баге пользователя: первым делом проси `vpn-mode status` + `awg show awg0 | grep handshake` + `logread | tail -200`. Этого хватает в 90% случаев.

## Тесты

Четыре уровня. Чем выше — тем больше покрытия и тем дороже.

| Уровень | Команда | Время | Что проверяет |
|---|---|---|---|
| T1 — статика | `make lint` | <1с | shellcheck, JSON, manifest sanity/coverage |
| T2 — unit + mock | `make test` | ~10с | 154 теста: lib/* + rpcd-cheburnet против моков |
| T3a — VM smoke | `make qemu` | ~90с | rpcd на реальном OpenWrt-snapshot, без интернета |
| T3b — VM + HTTP/UI | `make qemu-http` | ~3мин | + uhttpd, ACL, JSON-RPC. Нужен интернет |
| T3c — полный install | `make qemu-install` | ~5-10мин | `setup/install.sh` целиком на VM. **Release-gate**, не PR-gate |

**Правила прогона:**
- Каждое сохранение → T1 + T2.
- Правка `lib/` / `web/` / `setup/` / `bootstrap.sh` → дополнительно T3a.
- Правка handler'а / ACL / UI → T3b.
- **Правка `setup/install.sh`, `setup/manifest.txt`, `setup/0X-*.sh`** → обязательно T3c. Mock-тесты этого не покрывают (на хосте есть `install -m`, на роутере нет).
- Перед релизом — manual smoke на реальном Cudy/Beryl AX (T3c проходит до 01-amneziawg и падает там — на x86-snapshot нет `kmod-amneziawg`).

CI: `.github/workflows/`. PR — только T1+T2 (~30с). Push в main — полный CI (~10-15 мин). T3c артефакты при падении — `serial.log`, retention 7 дней.

Подробнее — `tests/qemu/README.md`.

## Контакты / источники

- Реф-ссылка проекта (Amnezia Premium): https://storage.googleapis.com/amnezia/amnezia.org?m-path=premium&arf=EB5KDKXCJYQYP4MG — единственное место с реф-кодом. При смене менять также в `README.md`, `web/index.html`, `setup.sh`.
- Upstream: [podkop](https://github.com/itdoginfo/podkop), [adblock-lean](https://github.com/lynxthecat/adblock-lean), [OpenWrt](https://openwrt.org/).
