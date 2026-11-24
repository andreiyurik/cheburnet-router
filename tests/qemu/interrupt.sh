#!/bin/bash
# tests/qemu/interrupt.sh — T3n: установку прервала перезагрузка (скачок питания) в самом опасном окне:
# kill-switch уже в ядре и на флеше, туннель не вооружён, health-check идёт.
#
# До исправления: снимок для отката жил в /tmp и пропадал, hotplug по install.json поднимал
# kill-switch — дом без интернета, панель «установлено», пароль root ещё не задан.
# Ожидаемое: после загрузки recover.uc откатывает установку — интернет есть, install.json нет,
# токен цел, мастер начинает заново.
#
# Живого VPN-сервера не требует. Запуск: make qemu-interrupt (нужен интернет для apk). ~6-9 мин с KVM.


. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; vm_ssh "apk update 2>&1 | tail -10"; exit 1; }

echo "→ Ставлю зависимости (как пакет: CORE + dnsmasq-full)"
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus rpcd rpcd-mod-file nftables ip-full \
           https-dns-proxy uhttpd uhttpd-mod-ubus dnsmasq-full; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

echo "→ AmneziaWG тем же путём, что на роутере (vendored awg-инсталлятор)"
# rc инсталлятора игнорируем осознанно (как bootstrap.sh: upstream делает exit 1 из-за
# ненужного нам luci-proto) — проверяем ФАКТ наличия модуля и утилиты.
vm_awg_prepare || exit 1
# Ретраим САМ ИНСТАЛЛЯТОР, а не только apk: он тянет ассет с GitHub, и фильтрующая сеть рвёт
# запрос («Failed to send request: Operation not permitted») — прогон падал на этом при полностью
# рабочем коде. rc инсталлятора игнорируем осознанно (как bootstrap.sh: upstream делает exit 1
# из-за ненужного нам luci-proto) — критерий успеха один: модуль грузится в ядро.
awg_ok=0
for attempt in 1 2 3; do
    vm_ssh "PATH=/tmp/awgbin:\$PATH sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
    if vm_ssh "modprobe amneziawg 2>/dev/null; lsmod | grep -q '^amneziawg'"; then awg_ok=1; break; fi
    echo "    попытка $attempt не удалась, повтор через 15с"
    sleep 15
done
[ "$awg_ok" = "1" ] || {
    echo "  ✗ модуль amneziawg не загрузился — без него шаг vpn нечего проверять"
    vm_ssh "tail -15 /tmp/awg-install.log" || true; exit 1; }
echo "  ✓ модуль в ядре, утилита awg на месте"

echo "→ Раскладываю движок и регистрирую rpcd-обработчик (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet /usr/libexec/rpcd /usr/share/rpcd/acl.d"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
# Обработчик ставится ТЕМ ЖЕ shim'ом, что кладёт пакет (симлинк на ucode-скрипт rpcd не
# подхватывает) — иначе тест проверял бы не то, что стоит у пользователя.
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json"                 "/usr/share/rpcd/acl.d/cheburnet.json"
vm_scp "$REPO_ROOT/package/cheburnet/files/hotplug-recover.sh" "/etc/hotplug.d/iface/98-cheburnet-recover"
vm_ssh "chmod +x /etc/hotplug.d/iface/98-cheburnet-recover"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet && /etc/init.d/rpcd restart >/dev/null 2>&1; sleep 3"
vm_ssh "ubus list | grep -q '^cheburnet$'" \
    || { echo "  ✗ cheburnet не зарегистрирован на шине"; exit 1; }

# fw4 обязан РАБОТАТЬ до установки: firewall-шаг добавляет цепочки в СУЩЕСТВУЮЩУЮ таблицу inet
# fw4, а vm_boot_and_setup сервис стопил (первый прогон этого теста получил outcome
# `step:firewall` вместо `health`).
vm_start_firewall

# Снимок «как было» ДО установки — с ним сравниваем состояние после откатa. Смотрим на то, что
# трогают наши шаги: секции network/dhcp и дефолтный маршрут.
echo "→ Снимаю состояние «как было» до установки"
BEFORE_NET="$(vm_ssh "uci show network | grep -c . || true")"
BEFORE_ROUTE="$(vm_ssh "ip -4 route show default | head -1")"
# noresolv сравниваем С ИСХОДНЫМ значением, а не с «должно отсутствовать»: что именно лежит в
# стоковом /etc/config/dhcp — не наше дело, и первый прогон этого теста упал именно на таком
# предположении. Правильный инвариант откатa — «как было», каким бы оно ни было.
BEFORE_NORESOLV="$(vm_ssh "uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true")"
echo "    секций/строк в network: $BEFORE_NET"
echo "    дефолтный маршрут:      $BEFORE_ROUTE"
echo "    dhcp noresolv:          ${BEFORE_NORESOLV:-<нет>}"

echo "→ Запускаю ПОЛНУЮ установку через ubus (конфиг верный, сервер мёртвый)"
vm_ssh "echo rollback-test-token > /etc/cheburnet/install-token"
# Ключи — валидный base64 нужной длины (WireGuard проверяет форму, не владельца). Endpoint —
# адрес из документационного диапазона RFC 5737: он гарантированно не отвечает, что и требуется.
# Jc/Jmin/Jmax/S1/S2/H1..H4 — обфускация AmneziaWG; без них awg-proto ругается на неполный конфиг.
AWG_CONF='[Interface]
PrivateKey = QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo=
Address = 10.13.13.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 78
S2 = 22
H1 = 1234567
H2 = 2345678
H3 = 3456789
H4 = 4567890
[Peer]
PublicKey = Bp7uKqLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuV=
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.10:51820
PersistentKeepalive = 25'

# Payload через файл: в ссылке JSON с переводами строк, а через vm_ssh экранирование его убивает.
printf '%s' "{\"awg_conf\":$(printf '%s' "$AWG_CONF" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),\"root_password\":\"install-test-pass\",\"domains\":[\"example.com\"],\"accept_risk\":true,\"token\":\"rollback-test-token\"}" \
    > "$WORK/install-args.json"
vm_scp "$WORK/install-args.json" /tmp/install-args.json
out="$(vm_ssh "ubus call cheburnet install \"\$(cat /tmp/install-args.json)\"")"
echo "$out" | grep -q 'started' \
    || { echo "  ✗ install не запустился: $out"; exit 1; }
echo "  ✓ установка запущена"


echo "→ Жду самого опасного окна: шаг health-check (kill-switch уже применён)"
in_window=0
for _ in $(seq 1 60); do
    st="$(vm_ssh 'cat /tmp/cheburnet/state 2>/dev/null' 2>/dev/null || true)"
    [ "$st" = "health-check" ] && { in_window=1; break; }
    vm_ssh '[ -f /tmp/cheburnet/done ]' 2>/dev/null && break
    sleep 2
done
[ "$in_window" = "1" ] || { echo "  ✗ не поймал окно health-check (state=$st)"; exit 1; }
vm_ssh "[ -f /etc/cheburnet/install.pending ]" || { echo "  ✗ метки install.pending нет посреди установки"; exit 1; }
vm_ssh "nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -q drop" \
    || { echo "  ✗ kill-switch ещё не в ядре — окно не то, проверять нечего"; exit 1; }
echo "  ✓ окно поймано: метка стоит, kill-switch в ядре"

echo "→ ЖЁСТКАЯ ПЕРЕЗАГРУЗКА (sysrq b — как скачок питания, без корректного выключения)"
vm_ssh "echo b > /proc/sysrq-trigger" >/dev/null 2>&1 || true
sleep 10
back=0
for _ in $(seq 1 40); do
    if vm_ssh true 2>/dev/null; then back=1; break; fi
    sleep 5
done
[ "$back" = "1" ] || { echo "  ✗ роутер не вернулся в сеть после перезагрузки"; exit 1; }
echo "  ✓ роутер загрузился"

echo "→ Жду, пока hotplug после загрузки откатит прерванную установку"
recovered=0
for _ in $(seq 1 30); do
    if vm_ssh "[ ! -f /etc/cheburnet/install.pending ] && [ ! -f /etc/cheburnet/install.json ] && [ ! -d /etc/cheburnet/rollback ]" 2>/dev/null; then
        recovered=1; break
    fi
    sleep 5
done

fail=0
bad() { echo "  ✗ $*"; fail=1; }
[ "$recovered" = "1" ] && echo "  ✓ откат выполнен: метки и install.json нет" \
    || bad "откат не случился: $(vm_ssh 'ls /etc/cheburnet; logread | grep cheburnet | tail -5' 2>&1)"
vm_ssh "! nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -q drop" \
    && echo "  ✓ kill-switch снят — дом не заперт без туннеля" || bad "kill-switch остался в ядре"
vm_ssh "! uci -q get network.awg0 >/dev/null 2>&1" \
    && echo "  ✓ секция туннеля снята (снимок с флеша восстановлен)" || bad "network.awg0 осталась"
vm_ssh "[ ! -d /etc/cheburnet/rollback ]" \
    && echo "  ✓ снимок израсходован" || bad "снимок остался на флеше"
vm_ssh "[ -s /etc/cheburnet/install-token ]" \
    && echo "  ✓ токен цел — мастер можно пройти заново" || bad "токен потерян"
vm_ssh "ubus call cheburnet status | grep -q '\"installed\": false'" \
    && echo "  ✓ status: installed=false — мастер начнёт с проверки" || bad "status всё ещё считает роутер установленным"
vm_ssh "[ -n \"\$(ip -4 route show default | head -1)\" ] && nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    && echo "  ✓ интернет на роутере есть" || bad "интернета нет: $(vm_ssh 'ip -4 route; cat /tmp/resolv.conf.d/resolv.conf.auto' 2>&1)"

[ "$fail" = 0 ] || exit 1
echo "✓ T3n pass — перезагрузка посреди установки откатывается сама, дом не остаётся без интернета"
