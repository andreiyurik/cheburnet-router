# Архив: VLESS+Reality (Full-тир на sing-box) в cheburnet-router

> [!warning] Ветка заморожена
> Это снимок проекта на момент, когда VLESS+Reality был поддерживаемым протоколом (Hysteria2 к этому
> моменту уже заморожена — см. тег `hysteria2-final`). Ветка **не развивается и не получает
> исправлений**. Код рабочий на дату заморозки, но с каждым месяцем расходится с `master`.
> Неизменная точка — тег **`reality-final`**.

## Что здесь есть

Full-тир — userspace-туннель на sing-box рядом с AmneziaWG в ядре. Ниша Reality: трафик через VPN
**вообще не проходит** (DPI, активное зондирование, блок UDP). Снаружи туннель выглядит как обычный
HTTPS к настоящему сайту: сервер занимает TLS-рукопожатие чужого домена.

- разбор ссылок `vless://` (urldecode, `[ipv6]:port`, обязательные `pbk`/`sni`) — `parse_vless_link`
  в `engine/steps/singbox/singbox.uc`;
- сборка конфига sing-box: TUN-инбаунд с `auto_route: false` (маршрутом управляет ядро, как у AWG),
  `stack: gvisor` (иначе TCP молча не идёт через fw4) — `build_singbox_config` / `wrap_outbound`;
- `sing-box check` до подмены живого конфига, атомарная запись — `engine/steps/singbox/apply.uc`;
- проба связи через туннель (пин host-route + fetch) — `engine/install/probe.uc`;
- догрузка бинаря `sing-box-tiny` → `sing-box` с ретраями — `engine/install/install-singbox.sh`;
- гейт железа Full-тира (AES-arch, 240 МБ RAM, 44 МБ флеша) — `engine/preflight/preflight.uc`;
- методы `install_full_tier`, `switch_to_reality`, `replace_reality_conf`; выбор по симптому в мастере;
- тесты: `test_singbox.uc`, `make qemu-reality`, стенд VPS `make qemu-live-vps`.

## В каком состоянии

На дату заморозки (2026-10-21), OpenWrt 25.12.5, sing-box-tiny 1.12.x из официального feed:
`make qemu-reality` зелёный (обвязка, проба отвергает мёртвый туннель, teardown, вес бинаря против
порога). Насквозь на пути разработчика Reality не проходил: TLS-инспекция переписывала ClientHello.
Известная внешняя проблема: актуальный xray-core (≥26.7.11) в 3x-ui не принимает клиента sing-box,
лечится откатом сервера на v26.6.27.

## Почему заморожено

[ADR 0010](https://github.com/andreiyurik/cheburnet-router/blob/master/docs/kb/decisions/0010-freeze-full-tier.md)
в `master`. Коротко: внешний бинарь с меняющимся форматом конфига, не помещается во флеш типичного
роутера (44 МБ против ~39 МБ свободных на Cudy TR3000), против принципа «никаких чёрных ящиков».

## Как оживить или сделать свой протокол на этой основе

| Где | Что |
|---|---|
| `engine/install/install.uc` → `PROTOCOLS` | шаг, интерфейс туннеля, ключ конфига в payload |
| `engine/steps/singbox/singbox.uc` | разбор входа → outbound sing-box (`parse_input`) |
| `engine/steps/singbox/apply.uc` | `sing-box check`, атомарная запись, `--no-arm`/`--arm` |
| `engine/install/run.uc` | догрузка бинаря до snapshot, health через пробу, откат с возвратом `config.json` |
| `engine/install/probe.uc` | проба связи через туннель (общая для протоколов на sing-box) |
| `engine/preflight/preflight.uc` | `evaluate_tiers` / `full_hw_missing` — гейт железа |
| `engine/ubus/ubus.uc` + `rpcd-cheburnet` | `install_full_tier`, `switch_to_*`, `replace_*_conf`, поля `status.full_*` |
| `web/src/lib/logic.js` → `PROTOCOLS` | подписи по симптому, проверка формата, фолбэк AWG → Reality |
| `tests/qemu/reality.sh` | обвязка на живом OpenWrt без внешнего сервера |

Шрамы и решения — в комментариях кода и в `docs/kb/concepts/vless-reality.md`,
`docs/kb/decisions/0004-multi-protocol-tiers.md`.
