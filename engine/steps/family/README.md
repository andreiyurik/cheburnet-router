# engine/steps/family — семейный режим (NSFW-блок + SafeSearch)

Один тумблер (`set_family_filter` в веб-панели), две подсистемы. Порт проверенного дизайна v1
(`lib/family-filter.sh`):

1. **NSFW DNS-блок** — Hagezi NSFW-лист (~95 тыс. доменов) добавляется **raw-URL-токеном** к
   `raw_block_lists` в конфиге adblock-lean. В hagezi-тиры NSFW не входит, поэтому отдельный URL,
   а не шорткат. Смену тира токен переживает: [adblock-шаг](../adblock/) сохраняет не-hagezi
   токены (фикс бага v1, где `sed` по всей строке тихо выключал NSFW при смене тира).
2. **Force SafeSearch** — **именованные** uci-секции `cname` в `dhcp` (`cheburnet_ss_*`):
   Google/YouTube/Bing/DuckDuckGo переадресуются на их же SafeSearch-endpoint'ы. Именно
   named-секции: `list cname` в `@dnsmasq[0]` init-скрипт dnsmasq игнорирует (урок v1).
   YouTube — strict (`restrict.youtube.com`).

## Чистое ядро vs импурный apply

- **`family.uc`** — `build_family_plan(current, enabled)` → `{conf_value, uci_ops, changed}` +
  `family_status(current)` (true ⟺ обе подсистемы включены; рассинхрон = «выключено», включение
  идемпотентно дотянет недостающее). Тесты — [tests/](tests/).
- **`apply.uc`** — **router-side, импурно**: stdin `{enabled}`, читает конфиг adblock-lean +
  наличие наших секций (точечно, по ожидаемым именам), пишет diff, перезапускает
  adblock-lean + dnsmasq. Проверяется в QEMU.

## Идемпотентность и чужое

Повторное включение/выключение → пустой план (no-op, демоны не дёргаются). Удаляем **только своё
подмножество** `cheburnet_ss_*` — ручные cname-секции пользователя и чужой софт не трогаем.
Префикс `cheburnet_ss_` исключает коллизии.

Не шаг установки (нет в реестре `install`): дефолт — выключен, включается админом из панели.

## Использование

```sh
echo '{"enabled":true}' | ucode -R engine/steps/family/apply.uc --dry-run
```

## Тесты

`make test-engine`. Покрыто: маппинг имён секций, включение с нуля, идемпотентность обоих
направлений, дотягивание рассинхрона, сохранение тира при выключении, неприкосновенность чужих
секций, сводный статус.
