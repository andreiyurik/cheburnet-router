# engine/list — импорт community-списка доменов прямого доступа

Принцип **«не владеть данными»**: список доменов прямого доступа импортируем из maintained-
community, а не ведём руками (architecture-v2). Движок периодически тянет его и регенерит
конфиг dnsmasq/nftset через [routing](../routing/) → [DNS-шаг](../steps/dns/).

## Семантика (якорь v1 — важно)

> Импортируемый список = домены, которые идут **НАПРЯМУЮ** (в обход туннеля), как и
> пользовательский direct-список. Перепутать «direct» и «через туннель» — источник багов.

Fail-safe страхует: промах списка/детекта → трафик уйдёт в **туннель** (безопасно), а не
утечёт. Поэтому импорт «слишком малого» списка не опасен (просто меньше прямых исключений).

## Чистое ядро vs импурный fetch

- **`list.uc`** — `parse_list` (форматы plain и hosts: `0.0.0.0 domain`), `assemble`
  (слияние user + imported, нормализация/валидация через **routing**, дедуп, rejected, stats),
  `looks_like_list` (есть ли ≥N валидных — защита от мусора). **Чистые**, тесты — [tests/](tests/).
- **`fetch.uc`** — **router-side**: скачивает список, проверяет `looks_like_list` ДО замены и
  атомарно обновляет кэш; иначе оставляет прежний (лучше старый рабочий список, чем затереть
  мусором — урок про cached-fallback из v1). QEMU.
- **`assemble.uc`** — CLI чистого ядра: `{user, imported_text}` (stdin) → домены + stats.

## Где это стыкуется

`assemble().domains` → `routing.build_plan(domains)` → DNS-шаг (nftset) + firewall (пометка).
Обновление по расписанию (cron) и регенерацию конфигов оркеструет установочный движок/ubus
(следующие фазы) — здесь сборка списка и безопасная загрузка.

## Использование

```sh
echo '{"user":["mine.example"],"imported_text":"a.example\n0.0.0.0 b.example\n"}' \
  | ucode -R engine/list/assemble.uc
ucode -R engine/list/fetch.uc https://example.org/direct-list.txt   # на роутере
```

## Тесты

`make test-engine`. Покрыто: parse_list (plain/hosts/смешанный/комментарии), assemble
(слияние, регистронезависимый дедуп, мусор→rejected, stats, пустые входы), looks_like_list
(список проходит, 404/пусто/ниже-порога — нет).
