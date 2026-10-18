#!/bin/bash
# tests/qemu/profiles.sh — T3l: AWG 3.1-параметры и профили серверов на живом OpenWrt (без VPN-сервера).
#
# Чего не покрывают юниты (там proto-handler и ядро — подделки):
#   • поля AmneziaWG 3.x доходят по ВСЕЙ цепочке .conf → uci → /lib/netifd/proto/amneziawg.sh →
#     модуль ядра (`awg showconf`), а шаг не печатает «пакет не знает параметров»;
#   • профили через настоящий rpcd: подключение мёртвого сервера откатывается, активный не меняется;
#   • автосмена в настоящем тике сторожа: перебор + откат, гейт «нет WAN — не перебирать».
# Серверы — адреса RFC 5737 (гарантированно молчат): проверяем ровно путь отказа и отката.
# Запуск: make qemu-profiles (нужен интернет для apk). ~5-8 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup
vm_check_dns

echo "→ apk update + зависимости (как пакет)"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus rpcd rpcd-mod-file nftables ip-full; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

echo "→ AmneziaWG тем же путём, что на роутере (vendored awg-инсталлятор)"
vm_scp "$REPO_ROOT/vendor/amneziawg-install.sh" "/tmp/awg-install.sh"
awg_ok=0
for attempt in 1 2 3; do
    vm_ssh "sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
    if vm_ssh "modprobe amneziawg 2>/dev/null; lsmod | grep -q '^amneziawg'"; then awg_ok=1; break; fi
    echo "    попытка $attempt не удалась, повтор через 15с"; sleep 15
done
[ "$awg_ok" = "1" ] || { echo "  ✗ модуль amneziawg не загрузился"; vm_ssh "tail -15 /tmp/awg-install.log" || true; exit 1; }

echo "→ Движок + rpcd-обработчик (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet /usr/libexec/rpcd /usr/share/rpcd/acl.d"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json" "/usr/share/rpcd/acl.d/cheburnet.json"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet && /etc/init.d/rpcd restart >/dev/null 2>&1; sleep 3"
vm_ssh "ubus list | grep -q '^cheburnet$'" || { echo "  ✗ cheburnet не зарегистрирован на шине"; exit 1; }
E=/usr/share/cheburnet/engine

# conf(endpoint, extra) — синтаксически верный AWG-конфиг на молчащий адрес.
conf() {
    printf '[Interface]\nPrivateKey = QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo=\nAddress = 10.13.13.2/32\n'
    printf 'Jc = 4\nJmin = 40\nJmax = 70\nS1 = 78\nS2 = 22\nS3 = 20\nS4 = 16\nH1 = 1234567\nH2 = 2345678\nH3 = 3456789\nH4 = 4567890\n%s' "$2"
    printf '[Peer]\nPublicKey = Bp7uKqLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuU=\nAllowedIPs = 0.0.0.0/0\n'
    printf 'Endpoint = %s:51820\nPersistentKeepalive = 25\n' "$1"
}

echo
echo "→ ПРОВЕРКА 1: proto-handler пакета знает все поля AWG 3.1"
for opt in awg_header_protection_key awg_content_padding_addition awg_rekey_after_time awg_rekey_timeout \
           awg_reject_after_time awg_keepalive_timeout awg_max_handshake_attempts awg_random_trailers awg_disable_cookies; do
    vm_ssh "grep -q '\"$opt\"' /lib/netifd/proto/amneziawg.sh" \
        || { echo "  ✗ установленный amneziawg-tools не знает $opt — пакет старше AWG 3.1"; exit 1; }
done
echo "  ✓ все 9 опций в /lib/netifd/proto/amneziawg.sh"

echo "→ ПРОВЕРКА 2: поля AWG 3.1 доходят до модуля ядра (.conf → uci → proto → awg showconf)"
AWG31='HeaderProtectionKey = 2GuHslRmlqkLNgYPKK4Nqt2z8uMwPKfzzy9xbnGkiFw=
RekeyAfterTime = 120
RekeyTimeout = 5
RejectAfterTime = 180
KeepaliveTimeout = 10
MaxHandshakeAttempts = 18
'
conf 192.0.2.10 "$AWG31" > "$WORK/awg31.conf"
vm_scp "$WORK/awg31.conf" /tmp/awg31.conf
APPLY="$(vm_ssh "ucode -R $E/steps/vpn/apply.uc --no-arm < /tmp/awg31.conf 2>&1")"
echo "$APPLY" | sed 's/^/    /'
if echo "$APPLY" | grep -q 'ВНИМАНИЕ'; then echo "  ✗ шаг считает поля неподдерживаемыми"; exit 1; fi
vm_ssh "uci -q get network.awg0.awg_header_protection_key" | grep -q '2GuHsl' \
    || { echo "  ✗ HeaderProtectionKey не записан в uci"; vm_ssh "uci show network.awg0"; exit 1; }
SHOW="$(vm_ssh "awg showconf awg0 2>&1")"
for k in HeaderProtectionKey RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts; do
    echo "$SHOW" | grep -qi "^$k" \
        || { echo "  ✗ $k не дошёл до ядра"; echo "$SHOW" | grep -v -i key | sed 's/^/    /'; exit 1; }
done
echo "  ✓ ядро держит все 6 полей (awg showconf)"
# Модуль с HeaderProtectionKey требует S1..S4 ≥ 12 и иначе отвергает ВЕСЬ конфиг — движок обязан
# отбить такой конфиг сам, до применения, с причиной (поймано первым прогоном этого теста).
conf 192.0.2.10 "$AWG31" | grep -v '^S3 = ' > "$WORK/no-s3.conf"
vm_scp "$WORK/no-s3.conf" /tmp/no-s3.conf
OUT="$(vm_ssh "ucode -R $E/steps/vpn/apply.uc --no-arm < /tmp/no-s3.conf 2>&1; echo rc=\$?")"
echo "$OUT" | grep -q 'S3 не меньше 12' && echo "$OUT" | grep -q 'rc=1' \
    || { echo "  ✗ неполный конфиг с защитой заголовков не отбит: $OUT"; exit 1; }
echo "  ✓ конфиг с HeaderProtectionKey без S3 отбит до применения, с причиной"
vm_ssh "ucode -R $E/steps/vpn/apply.uc --teardown >/dev/null 2>&1"

echo "→ Подготовка: «установленный» роутер на сервере A (молчит) + два профиля"
vm_ssh "printf '%s' '{\"protocol\":\"awg\",\"routing_opts\":{}}' > /etc/cheburnet/install.json"
conf 192.0.2.10 "" > "$WORK/a.conf"; conf 192.0.2.11 "" > "$WORK/b.conf"
vm_scp "$WORK/a.conf" /tmp/a.conf; vm_scp "$WORK/b.conf" /tmp/b.conf
vm_ssh "ucode -R $E/steps/vpn/apply.uc --no-arm < /tmp/a.conf >/dev/null 2>&1"
# ubus из-под root на роутере — без ACL; JSON собираем python'ом (переводы строк в конфиге).
add() { python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"awg_conf":open(sys.argv[2]).read()}))' "$1" "$2" > "$WORK/add.json"
        vm_scp "$WORK/add.json" /tmp/add.json; vm_ssh "ubus call cheburnet add_profile \"\$(cat /tmp/add.json)\""; }
add "Германия" "$WORK/a.conf" >/dev/null
OUT="$(add "Нидерланды" "$WORK/b.conf")"
echo "$OUT" | grep -q 'Нидерланды' || { echo "  ✗ add_profile: $OUT"; exit 1; }
# stat в стоковом busybox OpenWrt нет — права читаем из ls -l.
vm_ssh "ls -l /etc/cheburnet/profiles/p1.conf | grep -q '^-rw-------'" || { echo "  ✗ .conf профиля не 600"; exit 1; }
echo "  ✓ два профиля через rpcd, .conf — 600"

echo "→ ПРОВЕРКА 3: подключение молчащего сервера откатывается, прежний конфиг на месте"
OUT="$(vm_ssh "ubus call cheburnet activate_profile '{\"id\":\"p2\"}'")"
echo "$OUT" | grep -q started || { echo "  ✗ activate_profile: $OUT"; exit 1; }
for _ in $(seq 1 30); do vm_ssh '[ -f /tmp/cheburnet/done ]' 2>/dev/null && break; sleep 3; done
[ "$(vm_ssh 'cat /tmp/cheburnet/done')" != "0" ] || { echo "  ✗ замена на мёртвый сервер отрапортовала успех"; exit 1; }
[ "$(vm_ssh 'uci -q get network.awg0_peer.endpoint_host')" = "192.0.2.10" ] \
    || { echo "  ✗ после отката endpoint не прежний"; vm_ssh "uci show network.awg0_peer"; exit 1; }
vm_ssh "ubus call cheburnet list_profiles" | grep -q '"active": "p2"' \
    && { echo "  ✗ откатившийся сервер числится активным"; exit 1; }
echo "  ✓ откат: endpoint 192.0.2.10, p2 активным не стал"
vm_ssh "ubus call cheburnet delete_profile '{\"id\":\"p2\"}'" | grep -q 'Германия' \
    || { echo "  ✗ неактивный профиль не удалился"; exit 1; }
vm_ssh "[ ! -f /etc/cheburnet/profiles/p2.conf ]" || { echo "  ✗ .conf удалённого профиля остался"; exit 1; }
add "Нидерланды" "$WORK/b.conf" >/dev/null
echo "  ✓ удаление неактивного профиля стирает его .conf"

echo "→ ПРОВЕРКА 4: автосмена в настоящем тике сторожа"
# Активный p1, автосмена вкл, двое мёртвых тиков уже насчитано — этот тик решает. install.json
# убираем: недоустановленный data-plane дал бы инвариантам свою починку, а она приоритетнее.
vm_ssh "sed -i 's/\"active\": *null/\"active\": \"p1\"/; s/\"auto\": *false/\"auto\": true/' /etc/cheburnet/profiles.json"
vm_ssh "grep -q '\"auto\": *true' /etc/cheburnet/profiles.json" || { echo "  ✗ не удалось включить автосмену"; vm_ssh "cat /etc/cheburnet/profiles.json"; exit 1; }
vm_ssh "rm -f /etc/cheburnet/install.json; echo '{\"dead\":2,\"tried\":[]}' > /tmp/cheburnet/failover.json; logread -c 2>/dev/null || true"
WAN_IF="$(vm_ssh "ucode -R $E/invariants/gather.uc | jsonfilter -e '@.wan_if'")"
if vm_ssh "ping -c 1 -W 3 -I $WAN_IF 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 -I $WAN_IF 8.8.8.8 >/dev/null 2>&1"; then
    echo "    WAN пингуется — ждём попытку перейти на «Нидерланды» и откат"
    vm_ssh "UPTIME_S=9999 ucode -R $E/watchdog/tick.uc"
    LOG="$(vm_ssh 'logread -e cheburnet-watchdog')"
    echo "$LOG" | sed 's/^/    /'
    echo "$LOG" | grep -q 'пробую «Нидерланды»' || { echo "  ✗ сторож не попробовал следующий сервер"; exit 1; }
    echo "$LOG" | grep -q '«Нидерланды» тоже не ответил' || { echo "  ✗ нет записи об откате"; exit 1; }
    [ "$(vm_ssh 'uci -q get network.awg0_peer.endpoint_host')" = "192.0.2.10" ] \
        || { echo "  ✗ после неудачной автосмены endpoint не прежний"; exit 1; }
    echo "  ✓ попытка + откат, прежний сервер на месте"
else
    echo "    WAN не пингуется (ICMP в QEMU user-net закрыт хостом) — ждём гейт «нет домашнего интернета»"
    vm_ssh "UPTIME_S=9999 ucode -R $E/watchdog/tick.uc"
    LOG="$(vm_ssh 'logread -e cheburnet-watchdog')"
    echo "$LOG" | sed 's/^/    /'
    echo "$LOG" | grep -q 'нет домашнего интернета' || { echo "  ✗ гейт по WAN не сработал"; exit 1; }
    vm_ssh "! grep -q 'автосмена сервера' /tmp/cheburnet/install.log 2>/dev/null" \
        || { echo "  ✗ без WAN сторож всё равно что-то переключал"; exit 1; }
    echo "  ✓ без интернета серверы не перебираются"
fi

echo
echo "✓ qemu-profiles: AWG 3.1 доходит до ядра, профили и автосмена откатываются честно"
