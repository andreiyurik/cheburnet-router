# Ручной release-чеклист — Beryl AX (или Cudy TR3000)

Подробный QA-чеклист для проверки cheburnet **с полного нуля до рабочего состояния**, со всеми функциями. Применять перед каждым релизом и после каждого изменения в `setup/`, `lib/`, или web-UI.

QEMU-smoke + bats покрывают POSIX/busybox-совместимость и базовую функциональность. Но **физический Wi-Fi, USB-tether, физический slider HOME/TRAVEL, реальный AmneziaWG-handshake и поведение при reboot** — проверить можно только на железе. Этот документ — single source of truth для такого прохода.

**Полный прогон:** ~2.5 часа. Если 2.5 часов нет — обязательны **Фазы 0, 1, 2, 6**; остальные опциональны.

---

## Что приготовить (до начала)

### Hardware
- [ ] **Beryl AX** (GL-MT3000) или **Cudy TR3000** — тестовый, не основной домашний
- [ ] **Резервный роутер с интернетом** на время теста (или мобильный hotspot для ноутбука)
- [ ] Ethernet-кабель (минимум один)
- [ ] USB-кабель с **поддержкой данных** (не «только зарядка»)
- [ ] Телефон с **AmneziaVPN** установленным и **активной подпиской** (или free-сервер из приложения)
- [ ] Опционально: второе тестовое устройство (Android + iOS — для проверки Wi-Fi)

### Software
- [ ] Ноутбук с установленным:
  - SSH-клиент (`ssh`, `scp`)
  - Браузер (Firefox/Chrome, для веб-мастера)
  - Терминал с поддержкой длинных вкладок (Tmux, screen, iTerm2)
- [ ] Свежий **awg.conf** от твоей рабочей VPN-подписки (handshake должен идти)
- [ ] Известный root-пароль или готовность задать новый
- [ ] Возможность отключать WAN-кабель физически (для Phase 4)

### Сетевое окружение
- [ ] Тестовый роутер подключаешь ↔ Ethernet к WAN-источнику (Ростелеком/мобильный/другой роутер)
- [ ] LAN-кабель: тестовый роутер ↔ ноутбук, чтобы был SSH-доступ когда упадёт Wi-Fi
- [ ] Не вмешиваешь в реальную домашнюю сеть — Wi-Fi конфликта SSID не должно быть

---

## ⚡ Главная команда — сброс между фазами

```sh
ssh root@192.168.1.1 'firstboot -y && reboot'
sleep 90
ssh-keygen -R 192.168.1.1     # стереть старый host key с ноутбука
```

**Что делает `firstboot -y`:**
- Очищает overlay-раздел `/overlay/upper/`
- Все установленные пакеты после прошивки — удаляются
- Все uci-конфиги, hostkey'и, custom-файлы — стираются
- При следующем boot ядро откатывается к factory-defaults самого OpenWrt-образа

**Сколько ждать:** 60–90 сек до полного boot.

**Когда применять:** между Phase 0, 1, 4, 5 (каждый раз перед новым сценарием).

**Когда НЕ применять:** между Phase 2 и Phase 3 (тестируем поведение установленной системы), между Phase 6 и Phase 7 (steady state продолжается).

---

## 🪟 Если тестируешь нашу ветку (не master)

В нашем `install.sh:24` зашита ссылка на master-tarball. Чтобы тестировать ветку — нужно **временно** её подменить.

**На ноутбуке (один раз перед тестированием):**

```sh
cd ~/cheburnet-router
git checkout improve/install-robustness     # или твоя ветка
git status                                   # должно быть clean

# Временно правим URL в install.sh
sed -i.bak 's|refs/heads/master|refs/heads/improve/install-robustness|' install.sh
git add install.sh
git commit -m "test: temp REPO_TAR → branch (revert before merge)"
git push -u origin improve/install-robustness
```

**После полного теста (или если фейл и нужно вернуться):**

```sh
cd ~/cheburnet-router
sed -i 's|refs/heads/improve/install-robustness|refs/heads/master|' install.sh
git add install.sh
git commit -m "test: revert REPO_TAR back to master"
git push
```

Везде ниже где написано `master/install.sh` — подставь свою ветку, например `improve/install-robustness/install.sh`.

---

## Phase 0 — приведение к чистому OpenWrt

**Цель:** получить заведомо чистое состояние, как у нового пользователя.

### 0.1. Сброс OpenWrt-overlay

```sh
ssh root@192.168.1.1 'firstboot -y && reboot'
sleep 90
ssh-keygen -R 192.168.1.1
```

### 0.2. Подключиться по SSH к чистой системе

```sh
ssh root@192.168.1.1
# Беспарольный вход или просит установить пароль — это норма для чистого OpenWrt
```

### 0.3. Проверить что система чистая

- [ ] `cat /etc/openwrt_release | grep DISTRIB` — версия OpenWrt свежая, не SNAPSHOT
- [ ] `ls /opt/cheburnet 2>/dev/null` — пусто (cheburnet ещё не ставился)
- [ ] `ls /etc/amnezia 2>/dev/null` — пусто
- [ ] `ls /etc/init.d/podkop /etc/init.d/sing-box /etc/init.d/adblock-lean 2>/dev/null` — отсутствуют
- [ ] `ls /usr/bin/vpn-mode 2>/dev/null` — отсутствует
- [ ] `df -h /overlay` — свободно ≥100 МБ (Beryl AX имеет 128/256 МБ flash в зависимости от ревизии)

### 0.4. Проверить интернет

- [ ] WAN-кабель воткнут, провайдер выдал IP: `ip addr show $(uci get network.wan.device) | grep inet`
- [ ] DNS работает: `nslookup github.com` возвращает IP
- [ ] HTTPS работает: `wget -qO /dev/null --spider https://raw.githubusercontent.com && echo OK`

Если хоть один пункт не сошёлся — **stop**, сначала разберись с базовым OpenWrt.

---

## Phase 1 — Happy path (~25 мин)

**Цель:** провести юзера от bootstrap до полностью рабочего cheburnet, проверить все основные функции.

### 1.1. Установить root-пароль (если не задан)

```sh
ssh root@192.168.1.1 'passwd'
# Задать пароль (например, временный для тестов: cheburnet-test)
```

Это нужно потому что веб-мастер требует пароль для авторизации.

### 1.2. Запустить bootstrap

```sh
ssh root@192.168.1.1 \
  'wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/master/install.sh | sh'
```

(Замени `master` на твою ветку, если тестируешь ветку.)

**Ожидаемый вывод (последние строки):**
```
✓ ubus cheburnet зарегистрирован
╔══════════════════════════════════════════════════════╗
║   ✓ Установка завершена                              ║
╚══════════════════════════════════════════════════════╝
  Откройте в браузере:
  →  http://192.168.1.1/cheburnet/?token=XXXXX
```

- [ ] Команда завершилась успешно (exit 0)
- [ ] URL с токеном напечатан
- [ ] `ls /opt/cheburnet/` — папки `setup/`, `scripts/`, `lib/`, `web/` на месте

### 1.3. Открыть веб-мастер

В браузере: `http://192.168.1.1/cheburnet/?token=<TOKEN из вывода>`

- [ ] Страница открывается, тёмная тема, заголовок «cheburnet-router»
- [ ] Токен автоматически принят (нет шага «введи токен»)
- [ ] Видны шаги мастера: AWG-конфиг → Wi-Fi → пароль администратора

### 1.4. Загрузить awg.conf

- [ ] Drag-and-drop своего awg.conf, ИЛИ нажми «Выбрать файл» → выбери
- [ ] Видна валидация: «✓ конфиг принят, endpoint X.X.X.X:NNNN»
- [ ] Кнопка «Дальше» активна

### 1.5. Wi-Fi-параметры

- [ ] SSID: `cheburnet-test-N` (любое имя)
- [ ] Пароль: минимум 12 символов (например `test-password-12345`)
- [ ] Страна: RU (или твоя)
- [ ] Кнопка «Дальше» активна

### 1.6. Root-пароль

- [ ] Пароль администратора — тот же, что задал в шаге 1.1 (или новый)
- [ ] Подтверждение совпадает
- [ ] Кнопка «Начать установку» активна

### 1.7. Прогресс установки (~5-10 мин)

Нажми «Начать установку». Должен начаться прогресс-бар.

- [ ] Прогресс-бар идёт **только вперёд**, не прыгает назад
- [ ] Названия шагов читаемые: «Проверка совместимости роутера», «Настройка VPN-туннеля (AmneziaWG)», «Маршрутизация по странам (podkop)», «Блокировка рекламы», «Настройка безопасного DNS», «Настройка Wi-Fi», ...
- [ ] В логе ниже бара видны строки выполнения шагов
- [ ] **preflight** проходит (✓ preflight OK)
- [ ] **00-prerequisites** проходит (✓ prerequisites OK)
- [ ] **01-amneziawg** проходит, в логе видно `✓ awg0 interface UP: 100.x.x.x/32` и `✓ handshake: N sec ago`
- [ ] **02-podkop** проходит, `✓ podkop OK`
- [ ] **03-adblock** проходит, `✓ блок-лист загружен: ~N доменов`
- [ ] **04-dns** проходит, `✓ Quad9 DoH активен`
- [ ] **05-wifi** проходит, `✓ Wi-Fi поднят`
- [ ] **06-vpn-mode** проходит
- [ ] **07-killswitch** проходит
- [ ] **08-watchdog** проходит
- [ ] **09-ssh-hardening** проходит
- [ ] **10-quality** проходит
- [ ] Финальный экран success: SSID/URL панели/инструкции

### 1.8. Проверка done-state

В отдельном SSH-окне (LAN-кабелем, потому что Wi-Fi сейчас в стадии reboot):

```sh
cat /tmp/cheburnet/done    # → ok
cat /tmp/cheburnet/state   # → [done]
```

- [ ] `done = ok`
- [ ] `state = [done]`

### 1.9. Все сервисы запущены

```sh
awg show awg0 | head -10                 # handshake ≤ 3 мин
/etc/init.d/podkop status                # running
/etc/init.d/sing-box status              # running
/etc/init.d/adblock-lean status          # disabled (это OK — стартует по hotplug)
/etc/init.d/dnsmasq status               # running
/etc/init.d/firewall status              # running
nft list table inet PodkopTable >/dev/null && echo "nft-podkop OK"
```

- [ ] awg show — handshake свежий, transfer increments
- [ ] podkop, sing-box, dnsmasq, firewall — running
- [ ] nft PodkopTable — присутствует

### 1.10. Split-routing работает (HOME-режим)

Подключись с устройства (телефон/ноут) к новому Wi-Fi `cheburnet-test-N`.

```sh
# С устройства (не с роутера!):
curl -4 https://api.ipify.org && echo               # IP VPN-сервера
curl -4 https://2ip.ru/api/v1/IP                    # должен открыться через провайдерский IP
nslookup yandex.ru                                  # реальный IP (5.x.x.x или 87.x.x.x), НЕ FakeIP 198.18.x.x
nslookup google.com                                 # FakeIP (198.18.x.x) — это правильно для HOME
```

- [ ] api.ipify.org возвращает IP **VPN-сервера** (не провайдера)
- [ ] yandex.ru открывается, идёт **через провайдерский IP** (split-routing)
- [ ] google.com / youtube.com открывается через VPN
- [ ] yandex.ru резолвится в **реальный** IP (не FakeIP)
- [ ] google.com резолвится в **FakeIP** (198.18.x.x) — норма для HOME

### 1.11. Adblock работает

С устройства:
```sh
nslookup pagead2.googlesyndication.com 192.168.1.1   # должен заблокироваться (0.0.0.0 или подобное)
nslookup youtube.com 192.168.1.1                      # должен резолвиться нормально
```

- [ ] Рекламные домены блокируются
- [ ] Обычные домены — нет

### 1.12. Wi-Fi на разных диапазонах (Beryl AX)

Beryl AX поддерживает **2.4 ГГц + 5 ГГц** (в некоторых ревизиях — и 6 ГГц). Проверь:

```sh
# На роутере:
iw dev | grep -E "Interface|ssid|channel|txpower"
```

- [ ] Видны минимум 2 интерфейса (phy0-ap0 на 2.4 GHz, phy1-ap0 на 5 GHz)
- [ ] Оба broadcast'ят правильный SSID
- [ ] С iPhone — подключение к 5 GHz, проверка WPA3 (Настройки → Wi-Fi → ⓘ возле сети → Безопасность: WPA3)
- [ ] С Android — подключение к 5 GHz
- [ ] С устройства поддерживающего только 2.4 GHz (старый IoT, smart-bulb) — должен подключиться к 2.4 GHz

### 1.13. DNS-приватность (DoH)

```sh
# На роутере:
ps | grep https-dns-proxy
ss -tlnp | grep :443 || ss -tlnp | grep dnsmasq
nslookup -port=5053 google.com 127.0.0.1
```

- [ ] https-dns-proxy запущен, dnsmasq использует его как upstream
- [ ] DNS-запросы идут через DoH к Quad9

---

## Phase 2 — Веб-панель управления (~15 мин)

Продолжаем с установленной системы. **Не firstboot'ить.** Открыть `http://192.168.1.1/cheburnet/` (без токена — уже не нужен).

### 2.1. Auth + status display

- [ ] Запрашивает root-пароль для входа (тот что задавал в шаге 1.6)
- [ ] После логина видны блоки: «Тип установки», «Режим», «AmneziaWG tunnel», «podkop + sing-box», «DNS», «Adblock», «Wi-Fi»
- [ ] Все статусы зелёные/жёлтые/красные с понятными иконками
- [ ] handshake-age читается человеко-понятно («12с», «5м 03с»)

### 2.2. Переключение HOME ↔ TRAVEL

- [ ] Нажать «Переключить в TRAVEL»
- [ ] В SSH: `uci get podkop.main.mode` или эквивалент — изменился
- [ ] С устройства: `curl -4 https://2ip.ru/api/v1/IP` — теперь возвращает IP **VPN-сервера** (yandex.ru тоже через VPN)
- [ ] Нажать «Переключить в HOME» обратно
- [ ] Проверить откат: 2ip.ru снова через провайдера

### 2.3. Restart-кнопки

- [ ] Restart VPN — `awg show` показывает handshake обнулённый и заново появившийся через 1-2 сек
- [ ] Restart adblock — `/var/run/adblock-lean/abl-blocklist.gz` свежий timestamp
- [ ] Restart sing-box — процесс новый PID

### 2.4. Blocklist tier

- [ ] Сменить tier с `pro` на `light` → проверь:
  ```sh
  zcat /var/run/adblock-lean/abl-blocklist.gz | wc -l
  ```
  Количество доменов изменилось.
- [ ] Вернуть `pro`

### 2.5. Family filter

- [ ] Включить → с устройства `nslookup www.youtube.com 192.168.1.1` возвращает `restrict.youtube.com` (или подобное)
- [ ] Выключить → откат

### 2.6. Просмотр install-log в браузере

- [ ] Открыть лог установки в панели — все 10 шагов видны
- [ ] Лог скроллится, последние записи внизу
- [ ] Скриншот можно сохранить (для отчёта в Telegram)

### 2.7. Factory reset (СРАЗУ переходим в Phase 3)

- [ ] Ввести `RESET` в поле подтверждения
- [ ] Нажать «Сбросить» — роутер уходит в firstboot
- [ ] Ждём ~90 сек, переподключаемся → OpenWrt чистый

---

## Phase 3 — CLI tools (~10 мин)

После Phase 2 факторного сброса — повтори Phase 1 (быстро, без детальной проверки), чтобы вернуться в рабочее состояние с cheburnet.

### 3.1. vpn-mode

```sh
vpn-mode home
sleep 3
nslookup yandex.ru 127.0.0.1     # реальный IP
vpn-mode travel
sleep 3
nslookup yandex.ru 127.0.0.1     # FakeIP (через VPN)
vpn-mode home
```

- [ ] `vpn-mode home/travel` переключают
- [ ] `vpn-mode status` показывает текущий режим
- [ ] `vpn-mode airport` (если поддерживается в релизе) — все домены direct, без VPN

### 3.2. dns-provider

```sh
dns-provider
# должен показать текущий: Quad9
```

- [ ] CLI отдаёт правильный текущий DNS

### 3.3. Diagnostic команды

```sh
log-snapshot                     # снимок логов
net-benchmark                    # скорость через VPN vs direct
awg-watchdog                     # принудительный запуск, должен report'ить «OK»
```

- [ ] Все команды работают, не падают
- [ ] Вывод осмысленный

---

## Phase 4 — Failure-сценарии (~25 мин)

Между сценариями: `firstboot -y && reboot`.

### 4.1. Preflight: «нет интернета»

- [ ] firstboot, bootstrap (но не запускай установку из веба!)
- [ ] **Перед** нажатием «Начать установку» — физически отключи WAN-кабель
- [ ] Запусти установку через веб-мастер
- Ожидаемо:
  - [ ] В логе большой банер `❌ РОУТЕР НЕ ПОДХОДИТ: НЕТ ДОСТУПА В ИНТЕРНЕТ`
  - [ ] `cat /tmp/cheburnet/done` = `fail-preflight-internet`
  - [ ] `/etc/config/network` НЕ изменён (нет awg0)
  - [ ] /usr/bin/ не содержит наших скриптов
- [ ] Воткни WAN обратно перед следующим сценарием

### 4.2. AWG: битый endpoint (тест fallback-логики)

- [ ] `firstboot && reboot`, bootstrap
- [ ] В awg.conf замени Endpoint на `192.0.2.1:51820` (TEST-NET-1, не отвечает)
- [ ] Запусти установку
- Ожидаемо:
  - [ ] preflight, 00-prerequisites проходят
  - [ ] 01-amneziawg ставит пакеты, поднимает awg0
  - [ ] Ждёт handshake 60 сек — не доходит
  - [ ] Пробует **Fallback 1** (без I1) — не помогает
  - [ ] Пробует **Fallback 2** (без S3/S4) — не помогает
  - [ ] Пробует **Fallback 3** (нормализация H-диапазонов) — не помогает (потому что endpoint неотвечающий)
  - [ ] Выводит масштабную диагностику (`awg show`, masked uci-dump, logread netifd, kmod-amneziawg-status)
  - [ ] `cat /tmp/cheburnet/done` = `fail-01-amneziawg`

### 4.3. AWG: H-диапазоны (если есть AWG 2.0-конфиг)

Если у тебя есть self-hosted Amnezia с AWG 2.0-конфигом (`H1 = NUM-NUM` формат):

- [ ] `firstboot && reboot`, bootstrap
- [ ] Используй AWG 2.0-конфиг
- [ ] Запусти установку
- Ожидаемо:
  - [ ] Если базовый handshake идёт сразу — Fallback'и не запускаются (всё ок)
  - [ ] Если handshake не идёт — должен сработать **Fallback 3** (нормализация H-диапазонов)
  - [ ] В success-сообщении видно: `ℹ Применён fallback: сняты поля AWG 2.0 (H-ranges→singles)`

### 4.4. install-via-tether БЕЗ телефона (негативный тест)

- [ ] `firstboot && reboot`, bootstrap
- [ ] Запомни текущий WAN: `uci get network.wan.device` (обычно `eth1`)
- [ ] Запусти `/opt/cheburnet/scripts/install-via-tether.sh` БЕЗ подключённого телефона
- Ожидаемо:
  - [ ] «Ищу USB-tethered интерфейс (usb0)...»
  - [ ] Ждёт 30 сек, выводит диагностику про rndis_host для Android и cdc_ether для iPhone
  - [ ] exit 1
  - [ ] `uci get network.wan.device` всё ещё = исходному (trap НЕ должен был сработать на этом этапе)

---

## Phase 5 — install-via-tether реальный (~15 мин)

**Главный сценарий**: если у юзера провайдер блокирует sing-box (или fully blocks apk-зеркала), он использует USB-tether с AmneziaVPN на телефоне.

### 5.1. Подготовка телефона

- [ ] AmneziaVPN установлен, подключён к VPN-серверу
- [ ] USB-tethering включён:
  - Android: Настройки → Точка доступа и модем → USB-модем
  - iOS: Личная точка доступа → Разрешить другим + подключить USB

### 5.2. Сброс роутера и bootstrap

- [ ] `firstboot -y && reboot`, ждём 90 сек, переподключение
- [ ] Bootstrap без запуска установки: `wget -qO- ...install.sh | sh`

### 5.3. Подключи телефон USB-кабелем к Beryl AX

- [ ] USB-кабель в USB-порт Beryl AX
- [ ] Ждём 15 сек
- [ ] `ip link show usb0` → состояние **UP** с MAC-адресом

### 5.4. Запусти магическую кнопку

```sh
/opt/cheburnet/scripts/install-via-tether.sh
```

Ожидаемо:
- [ ] Скрипт находит `usb0`
- [ ] Сохраняет исходные `network.wan.{device,proto}` в `/tmp/cheburnet/wan-*.bak`
- [ ] Переключает WAN на usb0 (DHCP)
- [ ] Получает интернет через телефон («✓ Интернет работает через телефон»)
- [ ] Запускает `/opt/cheburnet/setup/install.sh`
- [ ] Установка идёт **через телефон** (видно в счётчике использования мобильного трафика)
- [ ] После установки: trap **автоматически** восстанавливает WAN

### 5.5. Проверка восстановления WAN

```sh
uci get network.wan.device       # должно быть = исходному (eth1 для Cudy/Beryl)
ip route show default            # default через провайдерский WAN
curl -4 https://api.ipify.org    # IP VPN-сервера (cheburnet работает через AWG)
```

- [ ] WAN восстановлен
- [ ] Cheburnet работает через VPN-туннель

### 5.6. Аварийный сценарий: Ctrl-C во время install через tether

- [ ] (Опционально, второй прогон) `firstboot && reboot`, bootstrap, подключи телефон
- [ ] Запусти `install-via-tether.sh`
- [ ] Когда установка ушла в шаг 02-podkop — нажми **Ctrl-C**
- Ожидаемо:
  - [ ] Trap отрабатывает: «→ Восстанавливаю исходный WAN-конфиг...»
  - [ ] `uci get network.wan.device` = исходное (НЕ usb0)
  - [ ] `cat /tmp/cheburnet/done` = `fail-02-podkop` (или другой текущий шаг)

---

## Phase 6 — Reboot + steady state (~15 мин)

После Phase 1 или Phase 5 на успешно установленной системе (БЕЗ firstboot).

### 6.1. Холодный ребут

```sh
ssh root@192.168.1.1 'reboot'
sleep 90
ssh root@192.168.1.1
```

### 6.2. Все сервисы сами поднялись

```sh
awg show awg0 | head -10                   # handshake ≤ 1 мин после reboot
/etc/init.d/podkop status                  # running
/etc/init.d/sing-box status                # running
/etc/init.d/dnsmasq status                 # running
/etc/init.d/firewall status                # running
nft list table inet PodkopTable >/dev/null && echo OK
```

- [ ] AWG handshake свежий (< 1 мин)
- [ ] Все service'ы running
- [ ] nft podkop-таблица на месте

### 6.3. С устройства всё работает

- [ ] Wi-Fi подключается **без повторного ввода пароля** (запомнили)
- [ ] `yandex.ru` открывается через провайдера (HOME mode сохранился)
- [ ] `google.com` открывается через VPN
- [ ] Реклама блокируется

### 6.4. Watchdog работает

```sh
crontab -l | grep awg-watchdog          # должен быть в crontab
logread | grep awg-watchdog | tail      # последний запуск свежий (< 1 час)
```

- [ ] Crontab настроен
- [ ] Watchdog запускается регулярно, репортит здоровье

### 6.5. Длительный uptime тест (опционально, 30+ мин)

- [ ] Оставь роутер работать 30 минут
- [ ] Подключи 2-3 устройства, активно поюзай (видео, музыка, мессенджеры)
- [ ] Проверь периодически: `awg show` — handshake обновляется, transfer растёт
- [ ] Через 30 мин: `uptime`, `free -m`, `cat /proc/loadavg` — нагрузка вменяемая, RAM не исчерпан

---

## Phase 7 — Beryl AX hardware-специфика (~15 мин)

### 7.1. Физический slider HOME/TRAVEL

Beryl AX имеет три-позиционный slider на корпусе.

- [ ] Переключи slider в позицию **TRAVEL**
- [ ] `logread | tail -20 | grep vpn-mode` — должен показать «переключение в TRAVEL»
- [ ] С устройства проверь: yandex.ru теперь через VPN-IP
- [ ] Переключи slider в позицию **HOME**
- [ ] Проверь откат

### 7.2. USB-порт для tether (использование после установки)

- [ ] Подключи телефон к USB-порту
- [ ] `ip link show usb0` — UP
- [ ] (Не запускай install-via-tether — это уже сделанная установка, просто проверка что USB-порт живой)

### 7.3. Все Wi-Fi радио активны

```sh
iw dev | grep -E "Interface phy|ssid"
cat /sys/kernel/debug/ieee80211/phy0/aphy0/channel 2>/dev/null
```

- [ ] phy0 (2.4 GHz) — broadcast'ит
- [ ] phy1 (5 GHz) — broadcast'ит
- [ ] phy2 (6 GHz, если ревизия поддерживает) — broadcast'ит

### 7.4. Температура под нагрузкой

```sh
# Под одновременной нагрузкой (speedtest + VPN):
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null
# Деление на 1000 даёт °C
```

- [ ] Температура ≤ 80°C под нагрузкой (Beryl AX имеет активный кулер)
- [ ] Кулер слышен под нагрузкой (нормально)

### 7.5. LED-индикаторы

- [ ] Power LED — горит
- [ ] Wi-Fi LED — мигает при активности
- [ ] LAN LED на используемом порту — мигает
- [ ] WAN LED — мигает при активности
- [ ] (Beryl AX-специфично) LED статуса VPN — какой-то индикатор горит когда VPN up

### 7.6. Power-cycle тест

- [ ] Выдерни питание физически
- [ ] Подожди 10 сек
- [ ] Подключи питание обратно
- [ ] Через 90 сек: SSH работает, AWG handshake восстановлен, Wi-Fi доступен

---

## Phase 8 — Stress / longevity (опционально, ~60 мин)

Только если хочется быть уверенным в production-ready.

### 8.1. Одновременные клиенты

- [ ] Подключи 3-5 устройств к Wi-Fi одновременно
- [ ] Каждое активно используй (YouTube, Spotify, мессенджеры)
- [ ] 20 минут наблюдай:
  ```sh
  # На роутере:
  watch -n 5 'awg show awg0 | grep -E "transfer|handshake"; free -m | head -2; cat /proc/loadavg'
  ```
- [ ] Никаких OOM, handshake не отваливается, нагрузка стабильная

### 8.2. Sleep/wake цикл на телефоне

- [ ] Подключи iPhone к Wi-Fi
- [ ] Заблокируй экран на 5 мин
- [ ] Разблокируй — браузер сразу открывает страницы (без задержки на reconnect)
- [ ] То же с Android

### 8.3. Heavy DNS load

- [ ] С устройства открой 50+ вкладок одновременно
- [ ] Проверь что DNS-запросы не теряются:
  ```sh
  logread | grep -i dnsmasq | tail -20
  # Не должно быть errors / drop / overflow
  ```

---

## 🚑 Recovery — если что-то пошло не так

| Что | Команда / действие |
|---|---|
| SSH жив, нужно чистое состояние | `firstboot -y && reboot` |
| SSH мёртв, роутер пингуется | **Failsafe mode**: выдерни питание, воткни обратно — на ранней стадии boot зажми reset 3 сек → SSH 192.168.1.1 без пароля |
| Wi-Fi и SSH мёртвы, LED горят | LAN-кабель в LAN-порт → ноутбук с фикс. IP 192.168.1.2 → SSH 192.168.1.1 (failsafe) |
| Полный кирпич | **U-Boot recovery для Beryl AX**: см. [docs.gl-inet.com](https://docs.gl-inet.com), требует TFTP-сервера и crossover-кабеля |
| Хочу полную переустановку OpenWrt | Скачать .bin с [openwrt.org](https://openwrt.org/toh/gl.inet/gl-mt3000), `sysupgrade -n /tmp/openwrt-X.bin` |

---

## Шаблон отчёта (вставить в issue / Telegram после прохода)

```
=== Cheburnet release test report ===

Test platform: Beryl AX (GL-MT3000), OpenWrt X.Y.Z, серийник YYY
Test date: 2026-MM-DD
Tester: @your_handle
Branch tested: <branch-name>
Commit: <git rev-parse HEAD на момент теста>
Test duration: ~N часов

Phase 0 (factory reset):        ✓ / ✗  — заметки:
Phase 1 (happy path):            ✓ / ✗  — заметки:
Phase 2 (web panel):             ✓ / ✗  — заметки:
Phase 3 (CLI tools):             ✓ / ✗  — заметки:
Phase 4 (failure scenarios):     ✓ / ✗  — заметки:
Phase 5 (install-via-tether):    ✓ / ✗  — заметки:
Phase 6 (reboot + steady state): ✓ / ✗  — заметки:
Phase 7 (Beryl AX specific):     ✓ / ✗  — заметки:
Phase 8 (stress/longevity):      ✓ / ✗  / skip — заметки:

Найденные баги:        <none / см. issue #N / описание>
Регрессии:             <none / см. issue #M / описание>
Известные ограничения: <none / список>
Производительность:    <handshake_avg / Mbps_through_VPN / RAM_usage>

Вердикт: ✅ готов к релизу / ⚠ нужна правка / ✗ не релизить
```

---

## ❌ Что НЕ покрывает этот чеклист

- **Реальная DPI-блокировка от провайдера** — нет такого провайдера у тестера. Tether-сценарий валидирует механизм обхода, не сам провайдер
- **Тонкие настройки blocklist-tier внутри Hagezi** — это upstream, не наш код
- **Killswitch при специально провоцированном падении линка** — сложно надёжно за 2 часа
- **Поддержка всех Wi-Fi-частот в разных регулирующих регионах** — зависит от страны/чипа
- **Долгосрочная стабильность (дни/недели)** — Phase 8 даёт 1 час, но это не «прод»

Эти вещи покрываются на T1/T2 unit-tests, T3 QEMU-smoke в `tests/`, или вручную при появлении конкретного баг-репорта.
