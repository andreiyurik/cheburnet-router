# engine/preflight — гейткипер железа/версии/зависимостей

Перед **любыми** изменениями движок проверяет, потянет ли железо стек, и честно отказывает
с понятным сообщением — вместо «списка поддерживаемых моделей» проверяем **свойства**
([reliability](../../docs/kb/architecture/reliability.md),
[hardware-requirements](../../docs/kb/reference/hardware-requirements.md)).

## Что проверяется

| id | severity | Проверка | Почему |
|---|---|---|---|
| `arch` | hard | arch ∈ {arm, aarch64, mips, mipsel, x86_64} | под неё есть бинари зависимостей |
| `openwrt` | hard | версия ≥ 25.12 | apk-based, API/пакеты совместимы |
| `flash` | soft | свободно ≥ 16 МБ | пакеты + конфиги влезут |
| `ram` | soft | `MemTotal` ≥ 112 МБ | dnsmasq + awg не упадут под нагрузкой |
| `deps` | hard | `kmod-amneziawg`, `https-dns-proxy`, `dnsmasq` **ставятся** | **главный чек** — иначе install упрётся на середине |
| `lan_wan` | hard | LAN и WAN не пересекаются | не отрезать себе доступ |

Пороги ориентировочные — уточняются по QEMU-замерам (Фаза 0). Переопределяются полем
`requirements` во входном JSON.

**Пороги сравниваются с фактами, а не с паспортом железа.** `MemTotal` меньше физической планки
на kernel-reserve (плата 128 МБ → 118–124 МБ), а свободный overlay 32-МБ платы ≈ 21 МБ. Порог,
равный «паспортным» 128/32, отказывал бы ровно тому железу, которое README называет
поддерживаемым (поймано на живом роутере со 120 МБ).

### hard vs soft: что можно пропустить осознанно

- **hard** — пропуску не подлежит: без нужной arch/версии/пакетов `apk` просто не найдёт файлы,
  а пересечение LAN/WAN отрежет доступ. «Разрешить на свой страх и риск» тут обещало бы невозможное.
- **soft** — железо впритык: установка может пройти, а упавший шаг откатится. Провалены **только**
  soft → отчёт несёт `overridable: true`, и владелец вправе установить как есть:
  `check.uc --allow-soft` (гейт по `hard_failed == 0`), в RPC — `install.accept_risk`.
  След решения остаётся: `«!»` в отчёте, предупреждение в `install.log`, список `forced` в
  `install.json` → постоянная плашка в панели. Подробно — [hardware-requirements](../../docs/kb/reference/hardware-requirements.md).

## Разделение: оценка (чистая) vs сбор фактов (router-side)

Ради тестируемости логика разрезана на два слоя:

```
   router-side gather (импурный)              preflight.uc (чистый)
   ─────────────────────────────              ─────────────────────
   ubus call system board   → arch, version
   /proc/meminfo            → ram      ──┐
   df /overlay              → flash      ├─► facts(JSON) ─► evaluate() ─► report ─► exit 0/1
   uci get network.lan/wan  → cidr       │
   apk add --simulate <dep> → installable┘
```

- **`preflight.uc`** — `evaluate(facts, req)` + хелперы `cmp_version`, `cidr_overlap`,
  `render_report`, `suggest_lan` (кандидат LAN-IP вне WAN-подсети — для ubus
  `check_lan_conflict`) и `valid_lan_ip` (граница доверия `apply_lan_ip`: строго 192.168.X.Y,
  host 1..254). **Чистые функции** → юнит-тесты без роутера ([tests/](tests/)).
- **`parse.uc`** — парсеры системного вывода (`parse_meminfo`, `parse_df`, `parse_arch`,
  `parse_board`, `parse_iface_cidr`). Тоже **чистые** → юнит-тесты на захваченных сэмплах
  (вкл. busybox-перенос длинного имени ФС в `df`).
- **`gather.uc`** — **импурный, router-side**: запускает команды (`uname`, `df`, `ubus`,
  `apk add --simulate`, чтение `/proc/meminfo`) и скармливает их вывод парсерам → facts-JSON.
  Тонкий, без логики разбора. Проверяется в QEMU, не юнитами — **осознанная граница**.
  Команда недоступна/упала → поле `null/false` → гейткипер блокирует (fail-closed), не пропускает.

`apk add --simulate <pkg>` (dry-run, ничего не ставит) — то, чем gather узнаёт
`deps_installable`: доступен ли пакет под текущую arch/feed **до** реальной установки.

## Использование

```sh
# Полный путь на роутере: собрать факты → вынести вердикт.
ucode -R engine/preflight/gather.uc | ucode -R engine/preflight/check.uc

# Или подать факты напрямую (так гоняем на хосте/в тестах):
echo '{"arch":"aarch64","openwrt_version":"25.12.0","flash_free_mb":100,
       "ram_total_mb":256,"deps_installable":{"kmod-amneziawg":true,
       "https-dns-proxy":true,"dnsmasq":true},
       "lan_cidr":"192.168.1.0/24","wan_cidr":"10.0.0.0/24"}' \
  | ucode -R engine/preflight/check.uc          # exit 0 = подходит, 1 = отказ
#   --json        → машинный отчёт для ubus/UI
#   --allow-soft  → soft-провалы (флеш/RAM) не блокируют; hard — по-прежнему отказ
```

**Гейткипер:** при `exit 1` движок не должен трогать систему. Так self-install нельзя
запустить на негодном железе и оставить его в полу-настроенном состоянии.

## Тесты

`make test-engine` (юнит, без роутера). Покрыто: сравнение версий (вкл. SNAPSHOT),
пересечение CIDR (вложенность/соседство/мусор), каждый провал по отдельности, кастомные
пороги, рендер отчёта, разбивка hard/soft и `overridable`, калибровка порогов (регресс:
роутер со 128 МБ RAM и 21 МБ свободного флеша обязан проходить). Проводка `accept_risk`
до реального гейта — host-тесты `engine/install/tests/test_run_paths.uc`.
