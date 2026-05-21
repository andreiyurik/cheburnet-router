#!/bin/bash
# tests/qemu/install.sh — T3c полный прогон setup/install.sh на VM.
#
# Цель: имитация того, что делает у пользователя install.sh + веб-мастер,
# но локально на qemu-OpenWrt-snapshot. Это РЕАЛЬНЫЙ install: apk update,
# скачивание podkop/adblock-lean инсталлеров с github, настройка UCI.
# Пакеты amneziawg-tools / kmod-amneziawg на x86 snapshot могут отсутствовать —
# мы это допускаем и помечаем такие шаги как «expected fail on x86».
#
# Что покрывает (что НЕ покрывает T3a/T3b):
#   • Полный путь: setup/manifest.txt раскладывается по /usr/bin, /etc/...
#   • Каждый setup-шаг 00-10 запускается на реальном busybox-OpenWrt.
#   • install.log пишется в /tmp/cheburnet/install.log.
#   • Поведение при сбое шага: install.sh пишет fail-NN-stepname в done.
#
# Что НЕ покрывает:
#   • Реальный AmneziaWG-туннель (нет сервера + нет kmod на x86).
#   • Реальный Wi-Fi 5/2.4 (нет hardware-чипа в VM).
#   • physical button (Cudy/Beryl AX hardware-specific).
#
# Запуск: make qemu-install (нужен интернет для apk + github).
# Время: ~10-15 минут с KVM. При падении — последние 60 строк serial.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

# === Подготовка: интернет должен работать в VM ===
# На свежем snapshot OpenWrt ca-bundle ещё не установлен, поэтому HTTPS-spider
# может фейлиться. Пробуем по очереди: сначала простой DNS-resolve через nslookup
# (apk сам потом поставит ca-bundle через 00-prerequisites), потом HTTP.
echo "→ Проверяю интернет в VM"
if vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'"; then
    echo "  ✓ DNS работает"
else
    echo "✗ DNS не работает в VM — apk update не пройдёт"
    exit 1
fi
if vm_ssh "wget -q --spider --timeout=10 http://downloads.openwrt.org/ 2>&1"; then
    echo "  ✓ HTTP к downloads.openwrt.org работает"
else
    echo "⚠ HTTP-spider не прошёл, но продолжаем — apk update сам диагностирует"
fi

# === Раскладываем репо в /opt/cheburnet (как это делает корневой install.sh) ===
echo "→ Заливаю репо в /opt/cheburnet (имитация install.sh)"
vm_ssh "mkdir -p /opt/cheburnet /tmp/cheburnet /etc/cheburnet /etc/amnezia/amneziawg"

# Tar+ssh — быстрее scp по одному файлу. Исключаем .git/, tests/ (нам незачем
# тащить тесты в VM), docs/ (документация не нужна для установки).
tar -C "$REPO_ROOT" -czf - \
    --exclude='.git' --exclude='tests' --exclude='docs' \
    --exclude='backup' --exclude='assets' --exclude='*.md' \
    setup scripts configs lib web vendor 2>/dev/null \
    | vm_ssh "tar -C /opt/cheburnet -xzf -"

# install.sh ставит rpcd-handler — сейчас не нужен (мы тестируем setup/install.sh,
# а не веб-мастер). Достаточно файлов в /opt/cheburnet.

# === Минимальный «awg0.conf» — синтаксически валидный фейк ===
# 01-amneziawg.sh парсит конфиг и пишет UCI. Реальный туннель не поднимется
# (нет сервера и kmod-amneziawg на x86 snapshot), но парсер должен принять.
# Ключи — base64-валидные «44-char placeholder», адрес — RFC1918.
vm_ssh "cat > /etc/amnezia/amneziawg/awg0.conf" <<'EOF'
[Interface]
Address = 10.7.0.2/32
DNS = 1.1.1.1
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
ListenPort = 51820
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 50
S2 = 100
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:51820
PersistentKeepalive = 25
EOF
vm_ssh "chmod 600 /etc/amnezia/amneziawg/awg0.conf"
echo "  ✓ awg0.conf фейковый (валидный синтаксис, не-рабочий endpoint)"

# === wireless-actual.txt ===
vm_ssh "cat > /opt/cheburnet/configs/wireless-actual.txt" <<'EOF'
WIFI_SSID="cheburnet-test"
WIFI_KEY="testpassword123"
WIFI_COUNTRY="RU"
EOF
echo "  ✓ wireless-actual.txt с тестовыми параметрами"

# === LAN/WAN-conflict sub-test ===
# Перед полным install прогоняем детектор LAN/WAN-конфликта на РЕАЛЬНОМ
# busybox-ash с РЕАЛЬНЫМ jsonfilter. Это критично — mock-тесты T2 гоняются
# на bash хоста + python-jsonfilter, а реальный busybox jsonfilter ИНАЧЕ
# парсит bracket-notation @["ipv4-address"][0].address. Если бы парсил
# неправильно — наш детектор молча возвращал бы «нет конфликта» для всех
# каскадных установок 192.168.1.x в проде, и юзеры натыкались бы на
# safety-net в preflight install.sh (вместо мягкого pre-check'а).
#
# Используем override `ubus` как shell-функции вместо реконфигурирования
# WAN-интерфейса: настоящий WAN в qemu user-mode netdev единственный и
# одновременно служит каналом SSH к VM, переконфигурировать его опасно
# (потеряем SSH-доступ и тест умрёт на timeout'е).
echo
echo "→ LAN-conflict sub-test (детектор + preflight safety net на busybox)"

vm_ssh "cat > /tmp/lan-conflict-subtest.sh" <<'TESTSCRIPT'
#!/bin/sh
# Sub-test для qemu-install: проверяет что net_detect_lan_conflict и
# cheburnet_preflight_lan_conflict работают на реальном OpenWrt
# (busybox-ash + busybox jsonfilter). ubus подменён как shell-функция
# чтобы детерминированно контролировать вход без переконфигурирования
# реального WAN-интерфейса VM.
#
# ВАЖНО: НЕ ставим `set -e` — наши тестируемые функции при детекте
# конфликта корректно возвращают rc=1, и busybox-ash в этом случае
# прибивает скрипт прямо внутри `out=$(net_detect_lan_conflict)` ДО того
# как мы успеваем проверить $rc и $out. Поэтому собственный fail-handling
# через явные `if [ rc != expected ]; exit 1`.

. /opt/cheburnet/lib/net-detect.sh
. /opt/cheburnet/lib/cheburnet-preflight.sh

# ── scenario 1: WAN не поднят → нет конфликта ────────────────────────────
# Перенаправляем stdout детектора в переменную и rc в отдельную, чтобы
# `set +e` не нужен: явный if проверяет оба значения вручную.
ubus() { echo '{"up":false,"ipv4-address":[]}'; }
out=$(net_detect_lan_conflict); rc=$?
if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
    echo "  ✗ scenario 1 (WAN down): rc=$rc out='$out' (ожидали rc=0, пусто)"
    exit 1
fi
echo "  ✓ scenario 1: WAN не поднят → нет конфликта"

# ── scenario 2: WAN+LAN в одной /24 → конфликт, suggest 192.168.2.1 ──────
ubus() { echo '{"up":true,"ipv4-address":[{"address":"192.168.1.50","mask":24}]}'; }
uci set network.lan.ipaddr=192.168.1.1/24
uci commit network
out=$(net_detect_lan_conflict); rc=$?
expected="192.168.1.50 192.168.1.1 192.168.2.1"
if [ "$rc" -ne 1 ] || [ "$out" != "$expected" ]; then
    echo "  ✗ scenario 2 (same /24): rc=$rc out='$out' (ожидали rc=1 '$expected')"
    exit 1
fi
echo "  ✓ scenario 2: WAN+LAN в 192.168.1.0/24 → конфликт, suggest 192.168.2.1"

# ── scenario 3: WAN занимает .2.x → suggest пропускает к .3.1 ────────────
ubus() { echo '{"up":true,"ipv4-address":[{"address":"192.168.2.55","mask":24}]}'; }
uci set network.lan.ipaddr=192.168.2.1/24
uci commit network
out=$(net_detect_lan_conflict); rc=$?
expected="192.168.2.55 192.168.2.1 192.168.3.1"
if [ "$rc" -ne 1 ] || [ "$out" != "$expected" ]; then
    echo "  ✗ scenario 3 (suggest skip): rc=$rc out='$out' (ожидали rc=1 '$expected')"
    exit 1
fi
echo "  ✓ scenario 3: WAN в 192.168.2.x → suggest пропускает занятый октет"

# ── scenario 4: preflight safety net печатает баннер + return 1 ──────────
ubus() { echo '{"up":true,"ipv4-address":[{"address":"192.168.1.50","mask":24}]}'; }
uci set network.lan.ipaddr=192.168.1.1/24
uci commit network
out=$(cheburnet_preflight_lan_conflict 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
    echo "  ✗ scenario 4 (preflight): rc=$rc — ожидали rc=1"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q 'КОНФЛИКТ ПОДСЕТЕЙ'; then
    echo "  ✗ scenario 4 (preflight): баннер 'КОНФЛИКТ ПОДСЕТЕЙ' не найден"
    echo "$out"
    exit 1
fi
echo "  ✓ scenario 4: preflight safety-net печатает баннер + return 1"

# ── cleanup: возвращаем LAN на DHCP, чтобы дальнейший полный install не
# срабатывал на оставленный нами синтетический конфликт ──────────────────
uci -q delete network.lan.ipaddr  >/dev/null 2>&1 || true
uci -q delete network.lan.netmask >/dev/null 2>&1 || true
uci set network.lan.proto=dhcp
uci commit network

echo "  ✓ sub-test пройден, LAN восстановлен в DHCP-режим"
TESTSCRIPT

if ! vm_ssh "sh /tmp/lan-conflict-subtest.sh"; then
    echo "✗ LAN-conflict sub-test FAILED — остановка перед полным install"
    echo "  (детектор/preflight работают на bash моков но не на busybox VM —"
    echo "   разбираемся ДО того как полный install прячет проблему за apk-логами)"
    exit 1
fi

# === Запускаем установку ===
echo
echo "→ Запускаю /opt/cheburnet/setup/install.sh"
echo "  (это займёт ~10 минут с интернетом — apk update, podkop install, adblock install и т.д.)"
echo
echo "─────────────────── install output (live) ───────────────────"

# Запускаем синхронно — нам нужны логи в реальном времени для диагностики.
# В реальной установке install.sh пишет лог в /tmp/cheburnet/install.log,
# мы повторим это же поведение через tee.
vm_ssh "/opt/cheburnet/setup/install.sh 2>&1 | tee /tmp/cheburnet/install.log" \
    > /tmp/qemu-install.log 2>&1 &
INSTALL_PID=$!

# Стримим лог пока install.sh идёт. Большие промежутки тишины (apk download)
# — норма. Используем follow на /tmp/cheburnet/install.log на VM-стороне.
sleep 5
( while kill -0 "$INSTALL_PID" 2>/dev/null; do
      vm_ssh "tail -F /tmp/cheburnet/install.log 2>/dev/null & sleep 5; kill %1 2>/dev/null" 2>/dev/null
      sleep 1
  done ) | head -300 &
TAIL_PID=$!

wait "$INSTALL_PID"
INSTALL_RC=$?
kill "$TAIL_PID" 2>/dev/null || true

echo "─────────────────── install output end ──────────────────────"
echo
echo "→ install.sh exit code: $INSTALL_RC"

# === Анализ ===
echo
echo "→ Анализирую состояние после установки"

# 1. /tmp/cheburnet/done — что там?
done_state="$(vm_ssh 'cat /tmp/cheburnet/done 2>/dev/null || echo "(none)"')"
echo "  /tmp/cheburnet/done = '$done_state'"

# 2. Какой шаг был последним?
last_state="$(vm_ssh 'cat /tmp/cheburnet/state 2>/dev/null || echo "(none)"')"
echo "  /tmp/cheburnet/state (последний шаг) = '$last_state'"

# 3. Попытка определить фактический список шагов которые прошли
echo "  Шаги, которые завершились успехом (по маркеру '✓ ... OK'):"
vm_ssh "grep -E '^✓.*(OK|✓ )' /tmp/cheburnet/install.log 2>/dev/null | head -15" || true

# 4. Шаги, которые упали
echo "  Шаги с warnings/errors:"
vm_ssh "grep -E '^✗|^⚠|✗ |Error|FAIL' /tmp/cheburnet/install.log 2>/dev/null | head -15" || true

# 5. Какие /usr/bin/ команды установлены (через манифест)?
echo "  Установленные нашим манифестом команды в /usr/bin/:"
vm_ssh "ls /usr/bin/ | grep -E '^(vpn-mode|dns-provider|dns-healthcheck|awg-watchdog|conntrack-monitor|conntrack-tune|log-snapshot|net-benchmark|sqm-tune)\$' 2>/dev/null" \
    | sed 's/^/    /' || true

# 6. /etc/sysupgrade.conf на месте?
vm_ssh "[ -f /etc/sysupgrade.conf ] && echo '    ✓ /etc/sysupgrade.conf разложен' || echo '    ✗ /etc/sysupgrade.conf отсутствует'"

# 7. /etc/adblock-lean/config на месте?
vm_ssh "[ -f /etc/adblock-lean/config ] && echo '    ✓ /etc/adblock-lean/config разложен' || echo '    ✗ /etc/adblock-lean/config отсутствует (manifest?)'"

# 8. UCI podkop существует?
vm_ssh "uci show podkop 2>/dev/null | head -5 | sed 's/^/    podkop: /' || echo '    (podkop не установлен — ожидаемо если 02 упал)'" || true

# === Итоговая интерпретация ===
echo
if [ "$INSTALL_RC" -eq 0 ] && [ "$done_state" = "ok" ]; then
    echo "✓ T3c install pass — полная установка прошла успешно."
    exit 0
elif echo "$done_state" | grep -qE "^fail-(preflight-arch|01-amneziawg|05-wifi)"; then
    # Это ожидаемо на x86-snapshot:
    #   • preflight-arch — kmod-amneziawg не собран под x86_64 snapshot-ядро
    #     (6.18 на x86, а awg-openwrt релизы под 25.12.x → 6.12.x). Preflight
    #     ловит это раньше шага 01 — корректное поведение.
    #   • 01-amneziawg — если preflight_arch почему-то прошёл (нашёл какой-то
    #     релиз), modprobe всё равно упадёт на kernel-mismatch.
    #   • 05-wifi — нет Wi-Fi-чипа в VM (но обычно скрипт это сам пропускает).
    echo "⚠ T3c partial pass — упал на $done_state (ожидаемо для x86-VM без AWG/Wi-Fi)."
    echo "  Не-сетевые шаги установки работают. Реальные Cudy/Beryl AX тестируются вручную."
    exit 0
else
    echo "✗ T3c install FAILED — упал на $done_state (НЕ ожидаемо)."
    echo
    echo "Последние 80 строк /tmp/cheburnet/install.log:"
    vm_ssh "tail -80 /tmp/cheburnet/install.log" || true
    exit 1
fi
