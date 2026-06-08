# engine/rollback — точечный откат (кирпич 3 надёжности)

Транзакция вокруг рискованного шага: **snapshot UCI → применить → health-check →
commit / restore** ([reliability](../../docs/v2/architecture/reliability.md)). Если шаг
сломал доступ (например, network/firewall), health-check падает → возвращаем прежний UCI.

## Честная граница: clean vs dirty

> Притворяться, что откатили то, что не откатывается, — **хуже**, чем честно сказать.

- **Clean (транзакция):** uci-конфиги (`network`, `dhcp`, `firewall`, `https-dns-proxy`) —
  откат через snapshot/restore файлов чистый.
- **Dirty (НЕ транзакция):** загруженный kmod, изменённое состояние сети/линка, запущенный
  сервис — чисто не откатываются. Их **не маскируем** под транзакцию: для них safe-fail +
  понятная ошибка на стороне шага. Неизвестную цель считаем грязной (безопаснее).

`classify()` и `plan_snapshot()` отказываются строить транзакцию для грязных целей — это
зафиксировано тестами.

## Чистое ядро vs импурный snapshot

- **`rollback.uc`** — `protected_configs`, `is_clean_config`, `classify`, `plan_snapshot`
  (отказ для грязных целей), `decide(health)` → `commit`/`rollback` (fail-safe: не-ok → откат).
  **Чистые функции**, тесты — [tests/](tests/).
- **`snapshot.uc`** — **router-side, импурно**: `save`/`restore`/`commit` копирует
  `/etc/config/<c>` защищаемых конфигов в снимок и обратно + reload сервисов. QEMU.

## Поток транзакции

```sh
ucode -R engine/rollback/snapshot.uc save           # снимок перед рискованным шагом
#   ... применить шаг (engine/steps/<...>/apply.uc) ...
#   ... health-check ...
# health ok:
ucode -R engine/rollback/snapshot.uc commit          # выбросить снимок
# health fail:
ucode -R engine/rollback/snapshot.uc restore         # вернуть прежний UCI + reload
```

Оркестрация (кто вызывает save→apply→health→commit/restore) — задача установочного движка /
ubus-обработчика (следующие фазы). Этот модуль даёт примитив снимка и политику «что чистое».

## Тесты

`make test-engine`. Покрыто: классификация clean/dirty, реестр защищаемых конфигов (копия),
`plan_snapshot` (дефолт/подмножество/отказ для грязной цели), `decide` (commit/rollback,
fail-safe на null).
