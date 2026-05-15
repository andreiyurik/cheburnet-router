# tests/hardware — T4: автотесты на реальном железе

Автоматизированный QA-прогон cheburnet-router на роутере GL.iNet Beryl AX (GL-MT3000) или совместимом, со стоковым OpenWrt 25.12+. Ловит регрессии классов, которые T1–T3 не покрывают: реальный AWG kmod, реальный Wi-Fi, runtime podkop+sing-box, kernel/network interactions.

**Время полного прогона:** ~25–35 минут (зависит от скорости AWG-сервера и интернета). Из них ~8 минут — фаза 4 (фейл-инжекшен с тремя AWG-фолбэками); пропускаемая через `HW_SKIP_BAD_AWG=1`.

## Когда применять

| Когда | Прогон |
|---|---|
| Перед merge в `master` любой PR, трогающей `setup/`, `lib/`, `install.sh`, `web/rpcd-cheburnet` | **обязательно** |
| После любых правок в скриптах установки (даже «косметических») | **обязательно** |
| Перед релиз-тегом | **обязательно** + `manual-release-checklist.md` для физических действий |
| Перед каждым коммитом | не нужно — `make lint && make test` достаточно |

T1 (`make lint`) и T2 (`make test`) гоняй **каждое сохранение** — они быстрые и ловят 80% регрессий. Hardware-тесты — гейт перед merge.

## Отличие от других уровней

| Уровень | Команда | Время | Что ловит |
|---|---|---|---|
| T1 (статика) | `make lint` | <1 с | shellcheck, JSON, manifest |
| T2 (mocks) | `make test` | ~10 с | pure-функции, RPC-handler через PATH-моки |
| T3a (VM smoke) | `make qemu` | ~90 с | OpenWrt snapshot, hermetic |
| T3b (VM HTTP) | `make qemu-http` | ~3 мин | + uhttpd, ACL, JSON-RPC |
| T3c (VM install) | `make qemu-install` | ~5–10 мин | полный setup/install.sh на VM |
| **T4 (hardware)** | **`./run-all.sh root@router`** | **~25 мин** | **реальный AWG kmod, Wi-Fi, podkop+sing-box runtime** |

T3c уходит в фейл на 01-amneziawg (на x86-snapshot нет `kmod-amneziawg`). T4 — единственный уровень, где это работает.

## Preconditions

Перед запуском убедись:

1. **Тестовый роутер** (не основной домашний!) Beryl AX или Cudy TR3000, прошитый ваниль-OpenWrt 25.12+.
2. **SSH-доступ** `ssh root@192.168.1.1` работает (по ключу или паролю).
3. **WAN** воткнут и провайдер выдаёт IPv4. `ping 8.8.8.8` с роутера проходит.
4. **Свой работающий AWG-конфиг** положен в `tests/hardware/fixtures/awg.conf`. Файл `.gitignore`-нут — секрет, не коммитим.
5. На ноутбуке стоят: `ssh`, `scp`, `python3` (нужен для генерации install_start payload).

Если что-то из этого не сходится — раннер упадёт на phase 0 с понятным сообщением.

## Запуск

### Полный прогон

```sh
cd tests/hardware
./run-all.sh root@192.168.1.1                        # master
./run-all.sh root@192.168.1.1 improve/install-robustness  # любая ветка
```

Раннер сам:
1. Делает `firstboot -y && reboot` на роутере (получаем чистое состояние).
2. Прогоняет `phase 0 → 1 → 2 → 3 → 6 → 4`.
3. Печатает markdown-отчёт в stdout + сохраняет в `/tmp/cheburnet-hwtest-YYYYMMDD-HHMMSS.md`.
4. Полный log сохраняется в `/tmp/cheburnet-hwtest-YYYYMMDD-HHMMSS.log`.

### Полезные флаги / env

| Что | Как |
|---|---|
| Не делать firstboot вначале (быстрая повторка) | `./run-all.sh --no-reset root@…` |
| Пропустить долгую фазу 4 (8 мин AWG-фолбэков) | `HW_SKIP_BAD_AWG=1 ./run-all.sh …` |
| Пропустить фазы целиком | `HW_SKIP_PHASES=phase4,phase6 ./run-all.sh …` |
| Переопределить SSID/пароли/страну | `HW_SSID=test HW_WIFI_KEY=… HW_COUNTRY=US HW_ROOT_PASS=… ./run-all.sh …` |

### Прогон отдельной фазы

Полезно при отладке (после фейла одной фазы — повторить её одну):

```sh
./phase1-install.sh root@192.168.1.1 improve/install-robustness
./phase2-webui.sh root@192.168.1.1
./phase4-failures.sh root@192.168.1.1
```

Каждая фаза самодостаточна и принимает `ROUTER [BRANCH]`.

### Granular debug — точечная проверка через lib.sh

Если фаза упала на одной проверке и хочется руками поэкспериментировать:

```sh
. tests/hardware/lib.sh
hw_init root@192.168.1.1

check_awg_handshake_fresh          # одиночный check
check_sing_box_config_has_ru_exclusion
check_dns_yandex_real_ip

# полный список — grep '^check_' tests/hardware/lib.sh
```

Каждый `check_*` — самодостаточная функция: дёргает данные через SSH, печатает `[PASS]` или `[FAIL] : <причина>`, возвращает 0/1. AI-friendly workflow для итеративного debug'а.

## Порядок фаз

```
phase0 (clean state)        — verify firstboot landed
   ↓
phase1 (bootstrap + install) — wget|sh, RPC install_start, ждать done=ok
   ↓
phase2 (web RPC handlers)    — ubus call cheburnet {get_status, mode_switch, ...}
   ↓
phase3 (CLI tools)           — vpn-mode, dns-provider, awg-watchdog, log-snapshot
   ↓
phase6 (reboot + steady)     — reboot, 30s wait, re-verify everything
   ↓
phase4 (failure injection)   — DESTRUCTIVE: bad AWG endpoint → fail-01-amneziawg
```

Фаза 4 — последняя по двум причинам:
- Она destructive (firstboot внутри, бутстрап с битым конфигом, install падает).
- Её результат не зависит от установленного cheburnet — может работать в изоляции.

Фаза 6 поставлена ДО фазы 4: ей нужен живой install из фазы 1; если бы 4 шла раньше, для 6 пришлось бы делать повторную инсталляцию.

## Регрессионные тесты (что специально ловим)

В `phase1-install.sh` после успешной установки запускаются **5 приоритетных регрессий** — каждая защищает реальный user-report:

| Check | Регрессия | Что ломается без неё |
|---|---|---|
| `check_sing_box_config_has_ru_exclusion` | **user-4** | podkop тихо не сгенерил .ru правила → yandex.ru через FakeIP/VPN |
| `check_sing_box_installed` | **user-1** | `apk add sing-box` тихо упал EPERM → podkop работает, sing-box нет |
| `check_wpad_installed` | **user-1** | wpad-replacement (basic→mbedtls) оставил систему без wpad → Wi-Fi WPA сломан |
| `check_podkop_user_domain_list_type_dynamic` | **AGENTS.md инвариант** | HOME-режим silently не работает (был прод-инцидент) |
| `check_podkop_fully_routed_ips_matches_lan` | **AGENTS.md инвариант** | Хардкод `192.168.1.0/24` → kill-switch дырявый на нестандартных подсетях |

Плюс остальные UCI-инварианты (`exclude_ru.community_lists=russia_outside`, `route_allowed_ips=0`).

## Что НЕ покрывается (manual-only)

T4 — потолок автоматизации без физического вмешательства. Для остального остаётся [`tests/manual-release-checklist.md`](../manual-release-checklist.md):

- **Физический slider HOME/TRAVEL** (GPIO на корпусе Beryl AX)
- **USB-tether** с реальным телефоном с AmneziaVPN (фаза 5 в manual)
- **Wi-Fi connect с реальных устройств** (WPA3, 2.4/5/6 ГГц, разные клиенты)
- **LED-индикаторы, температура под нагрузкой, power-cycle**
- **Long-uptime / stress** (фаза 8 в manual)

Эти классы остаются «выгляни глазами» при release-прогоне.

## Если фаза упала

1. Открой markdown-отчёт `/tmp/cheburnet-hwtest-*.md` — там по каждой упавшей проверке записана причина в одну строку.
2. Открой полный лог `/tmp/cheburnet-hwtest-*.log` — там виден контекст (что было до падения, состояние state-файла, install.log).
3. Повтори одну фазу: `./phaseN-*.sh root@router`.
4. Точечный debug: `. lib.sh && hw_init root@router && check_<name>`.
5. SSH на роутер: `ssh root@router 'cat /tmp/cheburnet/install.log | tail -100'`, `logread | tail -100`.

## Совместимость

| Роутер | Статус |
|---|---|
| GL.iNet Beryl AX (GL-MT3000) | Поддерживается, основной таргет |
| Cudy TR3000 | Должен работать (MediaTek MT7981, та же платформа) — не валидирован T4 |
| GL.iNet MT-3000 (без AX) | Поддерживается, slider/LED-чек'и могут отличаться |
| x86-OpenWrt | Не работает (нет AWG kmod, нет Wi-Fi) — используй T3c |
| Прочее | Не тестировалось |
