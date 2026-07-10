# engine/ — движок управления v2 (ucode)

Control-plane на [ucode](https://ucode.mediatek.org/): настраивает систему и завершается —
**в пути трафика его нет** (трафик идёт только через ядро, см.
[data-plane](../docs/v2/architecture/data-plane.md)). Поэтому логика движка — **чистые
функции**, юнит-тестируемые без роутера за секунды.

Целевая раскладка по модулям — [architecture-v2.md](../docs/architecture-v2.md#-предлагаемая-структура-репозитория).

| Модуль | Роль | Статус |
|---|---|---|
| `routing/` | генерация конфигов split-routing (dnsmasq-nftset + nft + ip rule) | ✅ есть |
| `preflight/` | гейткипер железа/версии/зависимостей (чистая оценка + парсеры + router-side gather) | ✅ есть |
| `rollback/` | snapshot/restore UCI там, где откат чистый (политика clean/dirty + router-side snapshot) | ✅ есть |
| `lib/` | общие хелперы (`assert.uc`, `uci.uc` list-reconcile, `conf.uc` shell-конфиг) | ✅ есть |
| `steps/` | идемпотентные шаги по компонентам | 🟢 `dns/`, `firewall/`, `vpn/`, `doh/`, `adblock/` есть |
| `list/` | импорт и обновление community-списка доменов (чистая сборка + router-side fetch) | ✅ есть |
| `install/` | оркестратор: preflight→snapshot→шаги→health→commit/rollback (политика + router-side run) | ✅ есть |
| `ubus/` | RPC-фасад для web-мастера (чистая валидация/роутинг + rpcd-обработчик + ACL из реестра) | ✅ есть |

## Запуск тестов

```sh
make test-engine     # юнит-тесты движка (ucode), без роутера
make poc-split       # Фаза 0: split через network namespace (примитивы + вывод генератора)
```

Нужен интерпретатор `ucode`. Его установка локально и план для CI — в
[routing/tests/README.md](routing/tests/README.md).
