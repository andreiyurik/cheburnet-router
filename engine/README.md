# engine/ — движок управления v2 (ucode)

Control-plane на [ucode](https://ucode.mediatek.org/): настраивает систему и завершается —
**в пути трафика его нет** (трафик идёт только через ядро, см.
[data-plane](../docs/v2/architecture/data-plane.md)). Поэтому логика движка — **чистые
функции**, юнит-тестируемые без роутера за секунды.

Целевая раскладка по модулям — [architecture-v2.md](../docs/architecture-v2.md#-предлагаемая-структура-репозитория).
Строится по фазам (strangler-fig), параллельно живому v1.

| Модуль | Роль | Статус |
|---|---|---|
| `routing/` | генерация конфигов split-routing (dnsmasq-nftset + nft + ip rule) | ✅ есть |
| `preflight/` | гейткипер железа/версии/зависимостей (чистая оценка + router-side gather) | ✅ есть (gather — next) |
| `lib/` | общие хелперы (тест-раннер `assert.uc` и т.п.) | ✅ есть |
| `steps/` | идемпотентные шаги по компонентам | ⏳ следующая фаза |
| `rollback/` | snapshot/restore UCI там, где откат чистый | ⏳ |
| `list/` | импорт и обновление community-списка доменов | ⏳ |

## Запуск тестов

```sh
make test-engine     # юнит-тесты движка (ucode), без роутера
make poc-split       # Фаза 0: split через network namespace (примитивы + вывод генератора)
```

Нужен интерпретатор `ucode`. Его установка локально и план для CI — в
[routing/tests/README.md](routing/tests/README.md).
