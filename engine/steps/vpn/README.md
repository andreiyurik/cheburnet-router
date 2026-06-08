# engine/steps/vpn — AmneziaWG-туннель (awg0)

Пользователь приносит `.conf` от VPN-провайдера; шаг парсит его и приводит UCI-интерфейс
`awg0` + peer-секцию к желаемому состоянию ([amneziawg](../../../docs/v2/concepts/amneziawg.md)).
`awg0` — дефолт-маршрут для всего, что не помечено `direct`.

## Инвариант из v1 (не потерять)

> **`route_allowed_ips='0'`** — маршрутизацией управляет **ядро**
> ([policy-routing](../../../docs/v2/concepts/policy-routing.md)), не netifd. Если включить,
> получим два конкурирующих маршрутизатора и конфликт. Это **требование**, а не опция —
> зафиксировано отдельным тестом.

`allowed_ips` навязываем full (`0.0.0.0/0`, `::/0`): туннель принимает весь трафик, а
*направление* решает policy routing. Поле `AllowedIPs` из `.conf` намеренно игнорируем.

## Чистое ядро vs импурный apply

- **`vpn.uc`** — `parse_awg_conf` (INI → объект), `split_endpoint` (`host:port` / `[ipv6]:port`),
  `build_vpn_plan` (→ uci teardown/setup). **Чистые функции**, тесты — [tests/](tests/).
- **`apply.uc`** — **router-side**: teardown (`uci -q delete`, отсутствие — норма) → setup
  (`uci batch`) → `commit network` → `network reload` (netifd поднимает awg0). QEMU.
- **`plan.uc`** — CLI чистого ядра: `.conf` со stdin → uci-операции, без применения.

## Граница доверия и валидация

`.conf` — **вход пользователя** → валидируем (CLAUDE.md). Нет обязательных полей
(`PrivateKey`/`Address`/`PublicKey`/`Endpoint`) или битый `Endpoint` → `plan.ok=false`,
ошибки, шаг **не трогает сеть**. Обфускация (`Jc`,`Jmin`,`Jmax`,`S1..S4`,`H1..H4`,`I1..I5`)
— опциональна: пишем `awg_<lc>` только для присутствующих полей (иначе netifd не поднимет
интерфейс — урок v1). Base64-ключи с `=` не ломают парсер (split по первому `=`).

## Идемпотентность

`delete`-before-`set`: teardown удаляет интерфейс и peer-секцию, setup создаёт заново →
повторный запуск сходится к тому же состоянию (нет дублей `add_list`). Peer — **именованная**
секция (`<iface>_peer` типа `amneziawg_<iface>`) → дружелюбна к `uci batch` (не нужен
сгенерированный id анонимной секции, как в v1).

## Использование

```sh
cat awg0.conf | ucode -R engine/steps/vpn/plan.uc           # показать uci-план
cat awg0.conf | ucode -R engine/steps/vpn/apply.uc --dry-run
```

## Тесты

`make test-engine`. Покрыто: split_endpoint (v4/v6/мусор), парсер (секции, inline-комментарии,
base64-`=`), обфускация только присутствующая, **инвариант `route_allowed_ips=0`**, peer
(endpoint/PSK/forced allowed_ips/keepalive), dual-stack Address, teardown, валидация входа,
кастомное имя интерфейса.
