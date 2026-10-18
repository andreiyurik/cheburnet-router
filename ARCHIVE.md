# Архив: Hysteria2 в cheburnet-router

> [!warning] Ветка заморожена
> Это снимок проекта на момент, когда Hysteria2 была поддерживаемым протоколом. Ветка **не
> развивается и не получает исправлений**. Код в ней рабочий на дату заморозки, но с каждым
> месяцем расходится с `master`. Неизменная точка — тег **`hysteria2-final`**.

## Что здесь есть

Hysteria2 — второй протокол Full-тира (поверх sing-box, общий шаг `engine/steps/singbox`,
общий TUN `singtun0`, общая проба связи с VLESS+Reality). Ниша: канал, который **теряет пакеты**
(мобильный интернет, дальний Wi-Fi). Замер в QEMU: при 5 % потерь держал около 100 % скорости
против 9–14 % у TCP-туннеля.

- разбор ссылок `hysteria2://` (port hopping, salamander-обфускация, `insecure`, `pinSHA256`
  отвергается честно) — `parse_hysteria2_link` в `engine/steps/singbox/singbox.uc`;
- сборка конфига sing-box, объявление полосы Brutal (по умолчанию BBR) — `build_hysteria2_config`;
- методы ubus `switch_to_hysteria2` / `replace_hysteria2_conf`, выбор в мастере и панели;
- тесты: `engine/steps/singbox/tests/test_hysteria2.uc`, `make qemu-hysteria`, `make qemu-netem`
  (замер QUIC против TCP под потерями), E2E со стендом VPS (`tests/vps/`).

## В каком состоянии

На дату заморозки (2026-10-18), OpenWrt 25.12.5, sing-box-tiny из официального feed:
`make qemu-hysteria` и `make qemu-reality` зелёные, E2E на физическом роутере через VPS был
подтверждён раньше (ADR 0004). `make qemu-netem` к этому моменту падал из-за нехватки места
в образе VM (512 МБ) — стенд, а не код.

## Почему заморожено

[ADR 0009](https://github.com/andreiyurik/cheburnet-router/blob/master/docs/kb/decisions/0009-freeze-hysteria2.md)
в `master`. Коротко: один мейнтейнер, Hysteria2 на той же UDP-оси, что AmneziaWG (падают вместе —
запасным путём не является), а Full-тир не влезает в свободный флеш типичного роутера.

## Как оживить или сделать свой протокол на этой основе

Швы, через которые протокол встроен в систему (всё — в этой ветке):

| Где | Что |
|---|---|
| `engine/install/install.uc` → `PROTOCOLS` | шаг, интерфейс туннеля, ключ конфига в payload |
| `engine/steps/singbox/singbox.uc` | разбор входа → outbound sing-box (`parse_input`) |
| `engine/install/run.uc` | установка/смена туннеля, health-check, откат |
| `engine/install/probe.uc` | проба связи через туннель (общая для Full-тира) |
| `engine/ubus/ubus.uc` + `rpcd-cheburnet` | методы `switch_to_*` / `replace_*_conf` |
| `web/src/lib/logic.js` → `PROTOCOLS` | подписи, формат, проверка ввода в панели и мастере |
| `tests/qemu/hysteria.sh` | обвязка на живом OpenWrt без внешнего сервера |

Шрамы и решения записаны в комментариях кода и в `docs/kb/concepts/hysteria2.md`,
`docs/kb/decisions/0004-multi-protocol-tiers.md`.
