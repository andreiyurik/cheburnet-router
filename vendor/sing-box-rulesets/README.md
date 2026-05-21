# vendor/sing-box-rulesets — bootstrap-кеш для первого старта sing-box

Файлы здесь копируются в `/tmp/sing-box/rulesets/` во время установки cheburnet,
**до** первого старта sing-box. Это гарантирует что HOME-режим работает с первой
минуты — даже если у юзера DPI на `github.com` и sing-box не может скачать
свои rule_set'ы сам.

## Что лежит

- `russia_outside.srs` — список из ~37 российских сервисов, которые гео-блокируют
  не-РФ IP (gosuslugi.ru, sberbank.ru, ozon.ru, …). Используется в HOME-режиме
  как exclusion-список «эти домены пускаем через WAN напрямую, не через VPN».
  Источник: [github.com/itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains).

## Когда обновлять

При каждом релизе cheburnet — выполни:

```sh
sh vendor/sing-box-rulesets/update.sh
git add vendor/sing-box-rulesets/
git commit -m 'chore(vendor): refresh sing-box rule_sets'
```

Файлы маленькие (~500 байт), обновляются редко (когда itdoginfo добавляет
новые гео-блокирующие сервисы).

После первой установки sing-box сам обновляет файлы по своему `update_interval`
(раз в день по умолчанию). Vendor нужен только для первого boot — пока ещё нет
работающего AmneziaWG, провайдер с DPI не пускает к github.
