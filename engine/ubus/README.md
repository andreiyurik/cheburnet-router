# engine/ubus — RPC-фасад движка для веб-мастера

Тонкий слой между [веб-мастером](../../docs/v2/architecture/web-wizard.md) и движком: мастер
зовёт методы по **ubus RPC**, фасад валидирует вход и переадресует работу существующим кирпичам
([preflight](../preflight/), [install/run.uc](../install/), [list](../list/),
[steps](../steps/)) — **не дублируя их логику**.

Это **граница доверия**: вход из RPC валидируем здесь (единственное место — как stdin
пользователя; см. [CLAUDE.md](../../CLAUDE.md) «валидируем только вход из ubus RPC и stdin»).
Внутренним границам движка доверяем.

## Чистое ядро vs импурный обработчик

- **`ubus.uc`** — **чистое ядро** (юнит-тестируется без шины): реестр методов `REGISTRY`,
  `validate_request` (проверка метода/обязательных полей/типов/enum), `list_descriptor`
  (дескриптор протокола rpcd `list`), `acl_split`/`build_acl` (права тиров), `make_error`.
  Источник правды — `REGISTRY`: из него выводятся и `list`, и ACL.
- **`rpcd-cheburnet`** — **импурный обработчик** (ucode-скрипт, проверяется в QEMU): регистрация
  на шине, запуск движковых CLI через `popen`, фон+poll установки. Ставится в
  `/usr/libexec/rpcd/cheburnet`, rpcd подхватывает сам. Наследник v1 `web/rpcd-cheburnet`.
- **`acl.uc`** — CLI: печатает `rpcd-acl.json` из реестра (`ucode -R acl.uc > rpcd-acl.json`).
- **`rpcd-acl.json`** — права, **выведенные из реестра**. Тест сверяет файл с `build_acl()`,
  чтобы код и ACL не разъезжались. Меняешь `REGISTRY` → перегенери файл.

## Методы

| Метод | Тип | Доступ | Что делает |
|---|---|---|---|
| `preflight` | read | anon | `gather.uc \| check.uc --json` → отчёт гейткипера |
| `status` | read | anon | режим, кол-во direct-доменов, AWG-handshake, сервисы |
| `install` | write | anon + **токен** | фон `install/run.uc` (preflight→snapshot→шаги→health→commit/rollback) |
| `install_progress` | read | anon | шаг + хвост лога + done/result (для poll'а мастера) |
| `set_mode` | write | admin | переключить HOME/TRAVEL — переприменить mode-зависимые шаги (dns+firewall) |
| `update_list` | write | admin | `list/fetch.uc` свежий community-список → переприменить dns |

## ACL: два тира

- **`unauthenticated`** — первичная установка из LAN. Мутации (`install`) защищены
  **install-токеном** из bootstrap (`/etc/cheburnet/install-token`): чистое ядро требует, что
  поле `token` — непустая строка, обработчик сверяет **значение** с файлом. Защита от
  LAN-сквоттинга — токен у того, кто запускал bootstrap по SSH.
- **`cheburnet-admin`** — пост-установочное управление (`set_mode`, `update_list`), выдаётся
  авторизованной сессии. Видит все методы (анонимные + admin-only).

## Установка: фон + poll

`install` — длинная операция (apk + шаги), держать RPC нельзя. Обработчик пишет полезную
нагрузку (`{awg_conf, domains, routing_opts}`, режим 600 — содержит приватный ключ) и запускает
`run.uc` через `setsid` в фоне, возвращая `{status:"started", pid}`. `setsid` отвязывает от
rpcd-сессии (иначе SIGHUP при её закрытии убьёт установку до записи `done`). Мастер поллит
`install_progress`: `done` = run.uc записал код выхода, `result` ∈ `ok`/`fail`/`crashed`.
Проверенный паттерн v1.

Воспроизводимая конфигурация (`/etc/cheburnet/install.json`, **без** awg_conf) сохраняется при
установке — из неё `set_mode`/`update_list` переприменяют шаги, не требуя повторного ввода.

## Использование

```sh
# Дескриптор методов (как зовёт rpcd):
ucode -R engine/ubus/rpcd-cheburnet list

# Вызов метода (аргументы JSON'ом на stdin, как от rpcd):
echo '{"mode":"travel"}' | ucode -R engine/ubus/rpcd-cheburnet call set_mode

# Перегенерировать ACL из реестра после правки REGISTRY:
ucode -R engine/ubus/acl.uc > engine/ubus/rpcd-acl.json
```

## Тесты

`make test-engine`. Покрыто чистое ядро: дескриптор `list`, валидация (неизвестный метод,
обязательные поля, типы, enum `mode`, отбрасывание лишних ключей), `requires_token`, вывод ACL
из реестра и **синхронность `rpcd-acl.json` с `build_acl()`**. Импурный обработчик (живой
ubus/uci/awg, регистрация на шине) — слой QEMU, не юниты.
