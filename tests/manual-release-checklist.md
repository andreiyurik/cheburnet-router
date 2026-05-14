# Ручной release-чеклист (Beryl AX / Cudy TR3000)

QEMU-smoke + bats покрывают POSIX/busybox-совместимость, манифест, JSON-валидацию и базовую функциональность. Но **физический Wi-Fi, USB-tether, slider-кнопку, реальный AmneziaWG-handshake и поведение при reboot** проверить можно только на железе. Этот чеклист — single source of truth для такого прохода.

**Когда применять:**
- Перед каждым релизом (тег + публикация)
- После любого изменения в `setup/0X-*.sh` или `lib/cheburnet-*.sh`
- После изменений в `web/rpcd-cheburnet` или hotplug-обработчиках

**Время:** ~2 часа на полный прогон. Если 2 часов нет — обязательны Фазы 1, 4, 5; остальные опциональны.

---

## Что подготовить

- [ ] Beryl AX (или Cudy TR3000/WR3000P/AP3000) — **тестовый**, не основной домашний
- [ ] Второй роутер с интернетом на время теста (или мобильный для ноутбука)
- [ ] Ноутбук с SSH-доступом к 192.168.1.1
- [ ] Свежий `awg.conf` от твоей VPN-подписки (рабочий handshake)
- [ ] Телефон с **AmneziaVPN** и активной подпиской (или free-сервер из приложения)
- [ ] USB-кабель с поддержкой данных (не «только зарядка»)

**Сброс между фазами:**
```sh
ssh root@192.168.1.1 'firstboot -y && reboot'
# ждём 60 сек, переподключаемся
```
`firstboot` очищает `/overlay`, возвращает OpenWrt в дефолт без переустановки. Стандартный сброс.

**Live-наблюдение во время теста** (опционально, в отдельном SSH-окне):
```sh
tail -f /tmp/cheburnet/install.log
# и параллельно:
logread -f | grep -iE 'cheburnet|amnezia|podkop|sing-box|fail|err'
```

---

## Фаза 1: Happy path — установка с нуля (20 мин)

### 1.1. Чистый OpenWrt
- [ ] После `firstboot -y && reboot`: `cat /etc/openwrt_release | grep DISTRIB`
- Ожидаемо: чистый OpenWrt, нет cheburnet-следов в `/opt/`, `/etc/init.d/`, `/etc/config/`

### 1.2. Bootstrap
- [ ] `wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/master/install.sh | sh`
  > ⚠ Если тестируешь конкретную ветку — замени URL на ветку:
  > `https://raw.githubusercontent.com/yurik2718/cheburnet-router/<branch>/install.sh`
- Ожидаемо: репо в `/opt/cheburnet/`, RPC-handler установлен, токен напечатан, URL веб-мастера выведен

### 1.3. Веб-мастер — ввод данных
Открыть `http://192.168.1.1/cheburnet/?token=<TOKEN>` в браузере.
- [ ] Шаг 1: токен авто-подставился (если URL c token=...)
- [ ] Шаг 2: загрузка awg.conf — drag-and-drop или выбор файла
- [ ] Шаг 3: SSID + пароль 12+ символов
- [ ] Шаг 4: пароль администратора (запомни — после установки будет нужен)
- [ ] Кнопка «Начать установку» становится активной только после всех шагов

### 1.4. Прогресс установки
- [ ] Прогресс-бар идёт **только вперёд**, не прыгает назад
- [ ] Названия шагов читаемые («Проверка совместимости роутера», «Настройка VPN-туннеля» и т.п.)
- [ ] В логе видны все 10+ шагов (preflight, 00-prerequisites, 01-amneziawg, …, root-password, lock-acl, done)
- [ ] Общее время — 5-10 мин

### 1.5. Установка успешна
- [ ] `cat /tmp/cheburnet/done` → `ok`
- [ ] `cat /tmp/cheburnet/state` → `[done]`
- [ ] Веб показал success-screen с инструкциями (SSID, URL панели, инструкция «что дальше»)

### 1.6. VPN-туннель работает
```sh
awg show                              # handshake ≤ 3 мин
/etc/init.d/sing-box status           # running
/etc/init.d/podkop status             # running
nft list table inet PodkopTable >/dev/null && echo nft-ok
```
- [ ] Все четыре проверки прошли

### 1.7. Split-routing (HOME-режим)
С устройства, подключённого к новому Wi-Fi:
- [ ] `curl -4 https://api.ipify.org` → **IP VPN-сервера** (не провайдера)
- [ ] Открыть `https://yandex.ru` → должен открыться через **провайдерский IP** (без VPN)
- [ ] Открыть `https://www.google.com` → через **VPN**
- [ ] speedtest.yandex.ru — скорость как у провайдера
- [ ] speedtest.net — скорость может быть ниже, IP сервера другой

### 1.8. Adblock
```sh
nslookup pagead2.googlesyndication.com 192.168.1.1   # должен блокироваться
nslookup google.com 192.168.1.1                       # должен резолвиться нормально
```
- [ ] Реклама блокируется, обычные домены — нет

### 1.9. Wi-Fi WPA3
- [ ] iPhone / современный Android подключается к Wi-Fi с введённым паролем
- [ ] В настройках Wi-Fi на устройстве: тип шифрования WPA3 (или WPA2/WPA3)
- [ ] Старые устройства (Android 8 и ниже) — могут не подключиться, это норма

---

## Фаза 2: Веб-панель управления (15 мин)

Продолжаем с установленной системы. Открыть `http://192.168.1.1/cheburnet/`.

### 2.1. Status display
- [ ] Все блоки показывают данные (тип установки, режим, AWG handshake, podkop, DNS, Adblock)
- [ ] Нет «не доступно» / «нет данных» на работающих компонентах

### 2.2. Switch HOME ↔ TRAVEL
- [ ] Нажать «Переключить в TRAVEL»
- [ ] В SSH: `uci get podkop.main.mode` → `proxy` (или эквивалент TRAVEL-режима)
- [ ] С устройства: `yandex.ru` теперь идёт через VPN
- [ ] Нажать «Переключить в HOME» — split-routing вернулся

### 2.3. Restart services
- [ ] «Перезапустить VPN» — handshake обновился (`awg show` time reset)
- [ ] «Перезапустить adblock» — `/var/run/adblock-lean/abl-blocklist.gz` свежий

### 2.4. Blocklist tier
- [ ] Сменить tier с `pro` на `light`, проверить что список доменов изменился:
  ```sh
  zcat /var/run/adblock-lean/abl-blocklist.gz | wc -l
  ```
- [ ] Вернуть `pro`

### 2.5. Family filter
- [ ] Включить → `nslookup www.youtube.com 192.168.1.1` возвращает `restrict.youtube.com` (или подобное)
- [ ] Выключить → откат

### 2.6. Factory reset (СРАЗУ переходим в Фазу 3)
- [ ] Ввести "RESET" в поле подтверждения
- [ ] Нажать — роутер уходит в firstboot, ждём ~1 мин
- [ ] Переподключиться, OpenWrt чистый

---

## Фаза 3: Failure-сценарии (20 мин)

Между сценариями: `firstboot -y && reboot`.

### 3.1. Preflight: «нет интернета»
- [ ] Bootstrap install.sh
- [ ] **ПЕРЕД** запуском setup/install.sh — отключить WAN-кабель
- [ ] Запустить установку через веб-мастер
- Ожидаемо:
  - [ ] Большой баннер `❌ РОУТЕР НЕ ПОДХОДИТ: НЕТ ДОСТУПА В ИНТЕРНЕТ` в логе
  - [ ] `cat /tmp/cheburnet/done` = `fail-preflight-internet`
  - [ ] `/etc/config/network` НЕ изменён
  - [ ] /usr/bin/ не содержит наших скриптов (манифест не применён)

### 3.2. Битый AmneziaWG-endpoint
- [ ] `firstboot && reboot`, bootstrap
- [ ] В awg.conf заменить Endpoint на `192.0.2.1:51820` (TEST-NET-1, не отвечает)
- [ ] Запустить установку
- Ожидаемо:
  - [ ] Шаг 01-amneziawg.sh ставит пакеты успешно (preflight, apk add работают)
  - [ ] Ждёт handshake 60 сек, пробует fallback'и (без I1 → без S3/S4)
  - [ ] Финально фейлится с диагностикой («awg show», masked uci-dump, logread netifd)
  - [ ] `cat /tmp/cheburnet/done` = `fail-01-amneziawg`

### 3.3. install-via-tether БЕЗ телефона (негативный тест)
- [ ] `firstboot && reboot`, bootstrap
- [ ] Запомнить текущий WAN: `uci get network.wan.device` (например, `eth1`)
- [ ] Запустить `/opt/cheburnet/scripts/install-via-tether.sh` БЕЗ подключённого телефона
- Ожидаемо:
  - [ ] «Ищу usb0 (до 30 сек)» с диагностикой про rndis_host (Android) и cdc_ether (iPhone)
  - [ ] exit 1 через 30 сек
  - [ ] `uci get network.wan.device` всё ещё = исходное значение (trap не должен был сработать, потому что бекап не успел)

---

## Фаза 4: install-via-tether — реальный тест (15 мин)

Этот тест валидирует «магическую кнопку» для DPI-блокированных пользователей.

### 4.1. Подготовка телефона
- [ ] AmneziaVPN установлен и подключён к серверу
- [ ] USB-tethering включён:
  - Android: Настройки → Точка доступа → USB-модем
  - iOS: Личная точка доступа → разрешить, подключить USB

### 4.2. Сброс и подключение
- [ ] `firstboot -y && reboot`, bootstrap (на этом этапе через обычный WAN)
- [ ] Подключить телефон USB-кабелем к Beryl AX
- [ ] Подождать 15 сек
- [ ] В SSH: `ip link show usb0` → UP
- [ ] Запомнить исходный WAN: `uci get network.wan.device`

### 4.3. Запуск магической кнопки
- [ ] `/opt/cheburnet/scripts/install-via-tether.sh`
- Ожидаемо:
  - [ ] Скрипт находит usb0
  - [ ] Сохраняет исходные network.wan.{device,proto}
  - [ ] Переключает WAN на usb0
  - [ ] Видит интернет через телефон («✓ Интернет работает через телефон»)
  - [ ] Запускает `/opt/cheburnet/setup/install.sh` — установка идёт через телефон
  - [ ] После установки: trap восстанавливает WAN
  - [ ] `uci get network.wan.device` после = исходное значение

### 4.4. После tether-установки
- [ ] Отключить телефон, проверить:
  ```sh
  uci get network.wan.device       # = исходное (eth1 для Cudy/Beryl)
  ip route show default            # default через провайдерский WAN
  curl -4 https://api.ipify.org    # IP VPN-сервера (cheburnet работает)
  ```

### 4.5. Аварийный сценарий: tether-установка упала посередине
- [ ] (опционально) Прервать установку через Ctrl-C во время работы install.sh
- [ ] Проверить: trap всё равно восстановил WAN
- [ ] `uci get network.wan.device` = исходное

---

## Фаза 5: Reboot + steady state (10 мин)

После Фазы 1 или Фазы 4 (на успешно установленной системе, БЕЗ firstboot).

### 5.1. Холодный ребут
- [ ] `reboot`, ждём 90 сек
- [ ] SSH обратно

### 5.2. Все сервисы поднялись сами
```sh
awg show                              # handshake ≤ 1 мин после reboot
/etc/init.d/podkop status             # running
/etc/init.d/sing-box status           # running
/etc/init.d/dnsmasq status            # running
/etc/init.d/firewall status           # running
```
- [ ] Все проверки прошли

### 5.3. С устройства — всё работает
- [ ] Wi-Fi подключается (без переввода пароля)
- [ ] yandex.ru через провайдера
- [ ] google.com через VPN
- [ ] Adblock работает

### 5.4. CLI режимы
- [ ] `vpn-mode travel` → yandex.ru тоже через VPN
- [ ] `vpn-mode home` → split-routing обратно
- [ ] `vpn-mode airport` (если поддерживается релизом)

### 5.5. Watchdog
- [ ] `crontab -l | grep awg-watchdog` — расписан
- [ ] `logread | grep awg-watchdog | tail` — последний запуск свежий (< 1 час)

---

## Фаза 6: Beryl AX-специфика (10 мин)

### 6.1. Физический слайдер HOME/TRAVEL
- [ ] Переключить слайдер
- [ ] `logread | tail -20 | grep vpn-mode` — должен показать переключение
- [ ] `uci get podkop.main.mode` — соответствует положению слайдера
- [ ] С устройства проверить что split-routing переключился

### 6.2. USB-порт для tether
- [ ] Подключить телефон ещё раз (после успешной установки) — usb0 должен подниматься
- [ ] Сценарий: «после установки юзер хочет иногда использовать tether» — должен работать без перенастройки

### 6.3. Кулер (если есть)
- [ ] Под нагрузкой (одновременно speedtest + VPN) — кулер работает, температура < 80°C: `cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null`

---

## Recovery — если что-то пошло не так

| Проблема | Решение |
|---|---|
| SSH жив, нужно чистое состояние | `firstboot -y && reboot` |
| SSH мёртв, роутер пингуется | Failsafe mode: ребут с зажатой reset-кнопкой 3 сек, потом SSH на 192.168.1.1 (без пароля) |
| Wi-Fi и SSH мёртвы, но LED горят | LAN-кабель в LAN-порт → ноутбук c фикс. IP 192.168.1.2 → SSH 192.168.1.1 (failsafe) |
| Полный кирпич / boot loop | U-Boot recovery для Beryl AX: см. [gl-inet.com/docs](https://docs.gl-inet.com), TFTP-режим |

## Шаблон результата для отчёта

После прохода вставить в issue / Telegram-отчёт:

```
Test platform: Beryl AX (или Cudy TR3000), OpenWrt X.Y.Z, серийник YYY
Test date: 2026-MM-DD
Tester: @your_handle
Branch tested: improve/install-robustness
Commit:        <git rev-parse HEAD>

Фаза 1 (happy path):           ✓ / ✗  — заметки:
Фаза 2 (веб-панель):           ✓ / ✗  — заметки:
Фаза 3 (failure-modes):        ✓ / ✗  — заметки:
Фаза 4 (install-via-tether):   ✓ / ✗  — заметки:
Фаза 5 (reboot+steady):        ✓ / ✗  — заметки:
Фаза 6 (Beryl AX-specific):    ✓ / ✗  — заметки:

Найденные баги:        <none / см. issue #N>
Регрессии:             <none / см. issue #M>
Известные ограничения: <none / список>

Вердикт: ✅ готов к релизу / ⚠ нужна правка / ✗ не релизить
```

---

## Что НЕ тестируется в этом чеклисте

- **Тонкие настройки adblock-tier'ов внутри** (upstream Hagezi-список, не наш код)
- **Реальная DPI-блокировка пакетов** провайдером (нет такого провайдера для теста — tether-сценарий валидирует механизм)
- **Killswitch при специально провоцированном падении линка** (сложно надёжно за час)
- **Реальная поддержка 2.4G/5G/6G частот** на разных регионах (зависит от регуляторных правил)

Эти вещи покрыты на T1/T2 unit-tests, T3 QEMU-smoke в `tests/`, или вручную при появлении конкретного баг-репорта.
