# engine/steps/singbox — VLESS+Reality через sing-box (Full-тир)

Тяжёлый тир для устойчивости к DPI на мощном железе (см.
[0004-multi-protocol-tiers](../../../docs/v2/decisions/0004-multi-protocol-tiers.md)).
Пользователь приносит подключение к своему Reality-серверу — ссылкой `vless://…` (её отдают
панели вроде 3x-ui / Hiddify) или сырым JSON-конфигом sing-box (advanced). Шаг разбирает вход,
генерирует `/etc/sing-box/config.json` и включает сервис. `singtun0` — дефолт-маршрут для всего,
что не помечено `direct` (как `awg0` в Light-тире).

## Инвариант (тот же смысл, что `route_allowed_ips='0'` у AWG)

> **`auto_route: false`** — маршрутизацией управляет **ядро**
> ([policy-routing](../../../docs/v2/concepts/policy-routing.md)), а **не** sing-box. sing-box
> лишь презентует TUN-интерфейс `singtun0`; помеченный трафик в него направляет тот же
> firewall/routing-слой, что и для `awg0`. Так туннель становится **взаимозаменяемым**
> (Light ↔ Full) без переписывания data-plane.

`auto_detect_interface: true` — серверное соединение sing-box уходит в реальный WAN, не
зацикливаясь обратно в TUN.

## Почему sing-box возвращается (осознанно)

ADR 0001 убрал sing-box из v1 ради образовательности (no black box). Full-тир возвращает его
**опционально**, под новый приоритет «устойчивость к DPI», там где AmneziaWG не проходит.
Light-тир (AWG в ядре) остаётся дефолтом и образовательным сердцем; sing-box — фолбэк, гейтится
preflight'ом по железу.

## Чистое ядро vs импурный apply

- **`singbox.uc`** — `parse_vless_link` (`vless://` → поля), `build_singbox_config` (поля →
  конфиг-объект), `parse_input` (диспетч ссылка/JSON), `build_singbox_plan` (→ config + uci).
  **Чистые функции**, тесты — [tests/](tests/).
- **`apply.uc`** — **router-side**: атомарная запись `config.json` (tmp+rename) → uci-включение
  сервиса (`sing-box.main`) → `enable`+`restart`. `--teardown` выключает сервис и убирает конфиг. QEMU.
- **`plan.uc`** — CLI чистого ядра: вход со stdin → конфиг + uci-операции, без применения.

## Граница доверия и валидация

Вход — **пользовательский** → валидируем (CLAUDE.md). Reality требует `uuid`/`host`/`port`/
`pbk`/`sni`; `security`, если задан, обязан быть `reality` (Full = только Reality, ADR 0004).
`sid`/`fp`/`flow` опциональны (дефолты `xtls-rprx-vision` / `chrome`; пустой `sid` → ключа нет).
Нет обязательного поля или битый JSON → `plan.ok=false`, шаг **не трогает систему**.

## Идемпотентность

Именованная секция `sing-box.main` + `delete`-before-`set` → повторный запуск сходится к тому
же состоянию. Конфиг пишется атомарно (`*.tmp` → `mv`), чтобы sing-box не прочитал полу-файл.

## Использование

```sh
echo 'vless://…' | ucode -R engine/steps/singbox/plan.uc            # конфиг + uci-план
echo 'vless://…' | ucode -R engine/steps/singbox/apply.uc --dry-run
ucode -R engine/steps/singbox/apply.uc --teardown                   # снять
```

## Тесты

`make test-engine`. Покрыто: разбор `vless://` (uuid/host/port/query, urldecode, `[ipv6]:port`),
валидация (нет pbk/sni, не-reality, битый port), генерация outbound (поля, port-число),
**инвариант `auto_route=false`**, дефолты flow/fp, опциональный `sid`, диспетч ссылка/JSON/мусор,
план (uci enable + conffile, teardown), битый JSON не кидает наружу.

## Не здесь (отдельные фазы)

- **preflight-гейт** Full-тира (AES-arch / RAM / sing-box ставится) — `engine/preflight`.
- **Маршрутизация** в `singtun0` и kill-switch — `engine/steps/firewall` (параметр tunnel-iface).
- **Автофолбэк** AWG→Reality (runtime-детект обрыва) — будущая фаза.
- **Живая проверка** (реальный sing-box + Reality-сервер, замер throughput/RAM) — QEMU/железо.
