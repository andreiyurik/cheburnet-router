# engine/steps/singbox — legacy-шаг Full-тира (sing-box)

Full-тир (VLESS+Reality, Hysteria2) **заморожен** — [ADR 0010](../../../docs/kb/decisions/0010-freeze-full-tier.md),
[ADR 0009](../../../docs/kb/decisions/0009-freeze-hysteria2.md). Новый конфиг sing-box этот шаг не
собирает и не применяет. Разбор ссылок, генерация конфига, догрузка бинаря и тесты — в теге
`reality-final` и ветке `archive/reality`.

Шаг остаётся ради роутеров, которые **уже** работают на Reality или Hysteria2: их туннель должен жить,
чиниться сторожем и сниматься при уходе на AmneziaWG.

## Что умеет

| Режим | Кто зовёт | Что делает |
|---|---|---|
| `--arm` | сторож (`repair: arm`), установка поверх | sing-box мёртв → рестарт сервиса; затем `ifup singtun` — netifd ставит half-routes |
| `--disarm` | аварийный режим (`install/pause.uc`) | `ifdown singtun`: маршрут снят, конфиг и сервис на месте |
| `--teardown` | сброс, уход на AWG (`run.uc`) | стоп/disable сервиса, `ifdown`, удаление секций network и `config.json` |
| без режима | — | честный отказ: «Full-тир больше не поддерживается — используйте AmneziaWG» |

## Инварианты (живы, пока жив хотя бы один legacy-роутер)

- **`auto_route: false`** в живом `config.json`: маршрутом управляет ядро (policy routing), sing-box
  лишь держит TUN `singtun0`. Поэтому firewall, kill-switch и NAT не знают, какой туннель активен.
- **half-routes** `0.0.0.0/1` + `128.0.0.0/1` на интерфейсе `singtun` — специфичнее WAN-дефолта и
  побеждают его, не удаляя. Тот же механизм, что у AWG (`steps/vpn`).
- **`ifdown` до удаления секций network** — иначе netifd оставляет half-route в мёртвый TUN.

## Раскладка

- **`singbox.uc`** — имена артефактов, которыми шаг владеет: TUN, `config.json`, сервис, секции network.
  Их же читают `reset.uc`, сторож и `run.uc` (бэкап `config.json` при уходе на AWG).
- **`apply.uc`** — режимы из таблицы выше. Host-тесты — `engine/install/tests/test_run_paths.uc`.

## Тесты

`make test-engine`: `tests/test_singbox.uc` (имена артефактов) и сценарии `singbox/apply.uc` в
`install/tests/test_run_paths.uc` (`--arm` при живом и мёртвом sing-box, отказ без режима, откат при
уходе на AWG). QEMU для legacy-рантайма нет — см. «Последствия» в ADR 0010.
