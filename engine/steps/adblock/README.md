# engine/steps/adblock — блокировка рекламы через DNS (adblock-lean)

`adblock-lean` скармливает dnsmasq списки рекламных/трекерных доменов → dnsmasq отвечает
**NXDOMAIN** на них для всей сети, без приложений на каждом устройстве
([adblock](../../../docs/v2/concepts/adblock.md)). Часть той же цепочки DNS, что
[nftset-пометка](../../../docs/v2/concepts/dnsmasq-nftset.md) и [DoH](../doh/).

## Баланс, не паранойя

По умолчанию **`hagezi:pro`** — реклама + трекеры, сбалансированно. Не «аггро»-фильтрация:
цель — «у бабушки ничего не отвалилось», а не максимум блокировок. Список меняется
(`opts.blocklists`).

## Два места конфигурации

1. **`/etc/adblock-lean/config`** — shell-стиль файл (не UCI). Управляем `raw_block_lists`
   (и доп. `config_vars`). Редактируем идемпотентно через [`lib/conf.uc set_var`](../../lib/conf.uc):
   меняем только нашу переменную, чужие строки сохраняем.
2. **dnsmasq `addnmount`** (UCI) — без записей `/bin/busybox` и `/var/run/adblock-lean/abl-blocklist.gz`
   dnsmasq **не имеет прав** читать gz-блок-лист: adblock-lean логирует *"Missing addnmount
   entries"* и список не подхватывается (урок v1). Добавляем минимальным diff, чужие addnmount
   не трогаем.

## Чистое ядро vs импурный apply

- **`adblock.uc`** — `build_adblock_plan(current, opts)` → новый текст config + uci addnmount-операции.
  **Чистая функция**, тесты — [tests/](tests/).
- **`apply.uc`** — **router-side**: читает config-файл и addnmount из uci, пишет config (если
  изменился), применяет addnmount (`uci batch`), запускает adblock-lean и перезапускает dnsmasq. QEMU.
- **`plan.uc`** — CLI чистого ядра: current-снимок (stdin) → план, без применения.

## Идемпотентность

- **config** — `set_var` меняет текст, только если присваивание иное; повтор при готовом
  состоянии → `config_changed=false` (apply файл не трогает).
- **addnmount** — минимальный diff: добавляем недостающее, ничего не удаляем (owned ⊆ desired).
  Всё на месте → пустой план.

## Использование

```sh
echo '{"current":{"config":"","addnmount":[]}}' | ucode -R engine/steps/adblock/plan.uc
ucode -R engine/steps/adblock/apply.uc --dry-run   # на роутере: читает config/uci сам
```

## Граница

Установку самого `adblock-lean` (его init-скрипт) и формат списков (`hagezi:*`) держит upstream;
boot-autostart/триггеры обновления — деплойная нюансировка (в v1 — hotplug на ifup awg0),
уточняется в QEMU. Этот шаг владеет конфигом списка и правами dnsmasq на чтение.

## Тесты

`make test-engine`. Покрыто: установка `raw_block_lists`, сохранение чужих переменных,
идемпотентность config, addnmount (чистая система / частично / чужие записи не трогаем),
кастомный список и доп. config_vars.
