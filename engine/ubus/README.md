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
| `status` | read | anon | режим, кол-во direct-доменов, AWG-handshake, сервисы, наличие Wi-Fi (`wireless_present`) + текущий `ssid` |
| `check_lan_conflict` | read | anon | пересечение LAN/WAN-подсетей (`cidr_overlap`) + `suggest_ip` для замены |
| `apply_lan_ip` | write | anon + **токен** | сменить LAN-IP: строгая `valid_lan_ip`, маска сохраняется, отложенный network restart |
| `install` | write | anon + **токен** | фон `install/run.uc` (preflight→snapshot→шаги→health→commit/rollback) |
| `install_progress` | read | anon | шаг + хвост лога + done/result (для poll'а мастера и фоновых операций) |
| `install_cancel` | write | anon + **токен** | прервать установку: kill process-group → дождаться смерти → маркер `cancelled` → откат через `run.uc --rollback` |
| `set_mode` | write | admin | переключить HOME/TRAVEL — переприменить mode-зависимые шаги (dns+firewall) |
| `update_list` | write | admin | `list/fetch.uc` свежий community-список → переприменить dns |
| `service_restart` | write | admin | перезапуск v2-сервиса: `vpn` (ifdown/ifup awg0) / `dns` / `doh` / `adblock` |
| `set_blocklist_tier` | write | admin | hagezi-тир adblock-lean через идемпотентный adblock-шаг (family-URL сохраняется) |
| `set_family_filter` | write | admin | семейный режим (NSFW-блок + SafeSearch) — шаг `steps/family` |
| `replace_awg_conf` | write | admin | замена AWG-конфига: sync-валидация → фон `install/replace_vpn.uc` (авто-rollback) |
| `factory_reset` | write | admin | `confirm:"RESET"` → фон `install/reset.uc` (teardown cheburnet-конфигурации, НЕ firstboot) |

## ACL: два тира

- **`unauthenticated`** — первичная установка из LAN. Мутации (`install`) защищены
  **install-токеном** из bootstrap (`/etc/cheburnet/install-token`): чистое ядро требует, что
  поле `token` — непустая строка, обработчик сверяет **значение** с файлом. Защита от
  LAN-сквоттинга — токен у того, кто запускал bootstrap по SSH.
- **`cheburnet-admin`** — пост-установочное управление (`set_mode`, `update_list`), выдаётся
  авторизованной сессии. Видит все методы (анонимные + admin-only).

Расширенный `status` (анонимный read): режим, домены, handshake, сервисы, `wireless_present`/`ssid`,
`tier`, `family_filter`, `direct_list_loaded`+`imported_domains` (здоровье импортированного списка —
пустой кэш → баннер в UI: direct-домены поедут через туннель, fail-safe).

## Установка: фон + poll

`install` — длинная операция (apk + шаги), держать RPC нельзя. Обработчик пишет полезную
нагрузку (`{awg_conf, root_password, ssid, wifi_key, domains, routing_opts}`, режим 600 —
содержит секреты: приватный ключ AWG + пароль root + ключ Wi-Fi) и запускает
`run.uc` через `setsid` в фоне, возвращая `{status:"started", pid}`. `setsid` отвязывает от
rpcd-сессии (иначе SIGHUP при её закрытии убьёт установку до записи `done`). Мастер поллит
`install_progress`: `done` = run.uc записал код выхода, `result` ∈ `ok`/`fail`/`crashed`.
Проверенный паттерн v1.

Тот же канал фон+poll переиспользуют `replace_awg_conf` (state `replacing-vpn`) и
`factory_reset` (state `resetting`); общий PID-файл — взаимное исключение длинных операций.
`install_cancel` убивает **process-group** (setsid сделал фон лидером группы) и пишет
done-маркер `cancelled`.

Воспроизводимая конфигурация (`/etc/cheburnet/install.json`, **без секретов** — awg_conf и
root_password туда не пишутся) сохраняется при
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
