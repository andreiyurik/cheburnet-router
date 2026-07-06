# 🧭 07. Управление режимами (HOME / TRAVEL)

> [!note]
> **Документация текущей реализации (v1)** — то, что работает сегодня. Целевая архитектура проекта: [architecture-v2.md](architecture-v2.md) · [база знаний v2](v2/README.md). См. [индекс документации](README.md).

## TL;DR

Два режима: **HOME** (split-routing — основной трафик через VPN, RU-сервисы напрямую) и **TRAVEL** (full-tunnel — всё через VPN без исключений). Переключение через web-UI (`http://192.168.1.1/cheburnet/`) или CLI (`vpn-mode home/travel/status`). Состояние хранится в UCI подkop'а — persistent через перезагрузки и sysupgrade автоматически.

## Два режима — что они делают

### HOME (основной)

Трафик разделяется:
- **Через VPN (AWG → Switzerland):** всё по умолчанию — google.com, github.com, youtube.com, etc.
- **Напрямую (WAN):** домены в `russia_outside` community-list, `.ru/.su/.рф` TLD, `vk.com`. Эти сервисы лучше работают с реального IP.

Подходит для **повседневного использования**: быстрый доступ к .ru-сайтам без VPN-оверхеда, всё остальное — защищённо через туннель.

### TRAVEL (full tunnel)

**Абсолютно весь** трафик LAN-клиентов идёт через AWG → Switzerland. Никаких исключений.

Подходит для:
- **Поездок в недоверенные сети** (отельный/кафешный Wi-Fi, аэропорт, коворкинг)
- **Максимальной приватности** когда неважны скорости .ru-ресурсов
- **Отладки** (упростить routing для диагностики)

### Техническая разница

Режимы отличаются содержимым UCI-секции `podkop.exclude_ru`:

| Параметр | HOME | TRAVEL |
|---|---|---|
| `connection_type` | `exclusion` | `exclusion` |
| `community_lists` | `russia_outside` | *(пусто)* |
| `user_domains` | `.ru .su .xn--p1ai vk.com yastatic.net .yandex.net` | *(пусто)* |

В TRAVEL списки просто пустые — podkop видит «секция без активных списков» и пропускает её. В sing-box'е остаётся **одно** route-правило: `source_ip_cidr=192.168.1.0/24 → main-out (awg0)`.

## Команда `vpn-mode`

```bash
vpn-mode home        # включить HOME
vpn-mode travel      # включить TRAVEL
vpn-mode status      # показать текущее состояние
```

### Пример использования

Домашний сценарий (one-time):
```bash
ssh root@192.168.1.1 vpn-mode home
```
Роутер помнит этот режим в UCI подkop'а — переживает перезагрузку и sysupgrade.

Перед поездкой:
```bash
ssh root@192.168.1.1 vpn-mode travel
```

На ноутбуке удобно сделать aliases:
```bash
# в ~/.bashrc или ~/.zshrc
alias vpn-home='ssh root@192.168.1.1 vpn-mode home'
alias vpn-travel='ssh root@192.168.1.1 vpn-mode travel'
alias vpn-status='ssh root@192.168.1.1 vpn-mode status'
```

### Что делает под капотом

`apply_home()` — UCI-манипуляция:
```sh
uci set podkop.exclude_ru.connection_type='exclusion'
uci add_list podkop.exclude_ru.community_lists='russia_outside'
uci add_list podkop.exclude_ru.user_domains='.ru'
uci add_list podkop.exclude_ru.user_domains='.su'
uci add_list podkop.exclude_ru.user_domains='.xn--p1ai'
uci add_list podkop.exclude_ru.user_domains='vk.com'
uci commit podkop
/etc/init.d/podkop reload
```

`apply_travel()` — удаляет списки, делая секцию неактивной:
```sh
uci -q delete podkop.exclude_ru.community_lists
uci -q delete podkop.exclude_ru.user_domains
uci commit podkop
/etc/init.d/podkop reload
```

`current_mode` определяется по наличию `community_lists` в UCI — отдельного state-файла нет, source of truth один.

## Состояние после перезагрузки

Состояние режима живёт в `/etc/config/podkop` (UCI), который **по умолчанию** сохраняется через sysupgrade. После перезагрузки подkop стартует, читает свой UCI и применяет соответствующий режим автоматически — нашего init.d-сервиса для этого не требуется.

## Переключение по домашней автоматизации

Для продвинутых сценариев — автоматическое переключение на TRAVEL когда ноутбук покидает домашнюю сеть:

**На macOS / Linux ноутбук** — hook на смену Wi-Fi SSID:
```bash
# Пример: в /etc/NetworkManager/dispatcher.d/90-vpn-mode
#!/bin/sh
if [ "$CONNECTION_ID" = "HomeNetwork" ]; then
    ssh -o BatchMode=yes root@192.168.1.1 vpn-mode home
else
    ssh -o BatchMode=yes root@192.168.1.1 vpn-mode travel
fi
```

**Готовые интеграции:** Home Assistant с SSH-shell-команду, Tailscale-based triggers, etc. В этом репозитории не реализованы, но несложно добавить для своих нужд.

## Проверь себя

1. **Можно ли добавить третий режим (например, «VPN выключен»)?**
   <details><summary>Ответ</summary>
   Технически да — добавить в `vpn-mode` ещё одну функцию `apply_off()`, которая удаляет `fully_routed_ips` из секции `main`. Но это меняет смысл архитектуры: вы получаете роутер без VPN, что противоречит цели проекта (если VPN не нужен — проще отдельный роутер). Рекомендую не добавлять.
   </details>

2. **Почему убрали slider/кнопку для переключения режимов?**
   <details><summary>Ответ</summary>
   Hardware-кнопки/слайдеры есть не у всех роутеров (только Beryl AX и Cudy TR3000), а поведение fragile (GPIO debounce, hardware-specific события). Web-UI и CLI работают одинаково на любом железе, состояние атомарно и журналируемо. Целевая аудитория проекта (родители/бабушка) ходит через web — hardware-кнопка для них не была полезным сценарием.
   </details>

## 📚 Глубже изучить

- [docs/03-podkop-routing.md](03-podkop-routing.md) — как устроен split-routing на уровне sing-box
