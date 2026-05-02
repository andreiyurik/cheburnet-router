#!/usr/bin/env bats
# Контракт lib/net-detect.sh — определение LAN-параметров с правильными
# fallback'ами. Используется в шести местах (02-podkop, 04-dns, 07-killswitch,
# install.sh, rpcd-cheburnet, bootstrap.sh) — если поведение разойдётся,
# kill-switch может оказаться тихо-дырявым (не сматчит правильную подсеть).
#
# Ключевые инварианты:
#   • net_lan_ip: CIDR-форма OpenWrt 25.12+ ("192.168.1.1/24") должна срезаться
#     до чистого IP. Иначе nslookup/ping этого "адреса" будет фейлиться.
#   • net_lan_ip: при пустом uci использует fallback из аргумента.
#   • net_lan_cidr: при пустом netifd падает на ipcalc.sh, при пустом всём —
#     возвращает exit 1 (а не пустую строку — иначе вызывающий не отличит
#     «не определилось» от «определилось как пусто»).

load 'helpers/sandbox'

setup() {
    sandbox_init
    # shellcheck source=../../lib/net-detect.sh
    . "$REPO_ROOT/lib/net-detect.sh"
}

teardown() {
    sandbox_cleanup
}

# ─── net_lan_ip ──────────────────────────────────────────────────────────────

@test "net_lan_ip: CIDR-форма (OpenWrt 25.12+) срезается до чистого IP" {
    # Наш mock uci сохраняет set'ы в STATE-файл и потом отдаёт через get.
    uci set network.lan.ipaddr=192.168.1.1/24
    result="$(net_lan_ip 'fallback-not-used')"
    [ "$result" = "192.168.1.1" ]
}

@test "net_lan_ip: plain IP (старые сборки) остаётся как есть" {
    uci set network.lan.ipaddr=10.0.0.1
    result="$(net_lan_ip 'fallback-not-used')"
    [ "$result" = "10.0.0.1" ]
}

@test "net_lan_ip: нестандартная подсеть из CIDR корректно парсится" {
    uci set network.lan.ipaddr=192.168.42.1/16
    result="$(net_lan_ip 'fallback-not-used')"
    [ "$result" = "192.168.42.1" ]
}

@test "net_lan_ip: при отсутствии uci-значения возвращает fallback" {
    # Подменяем uci на тот, что для всех get'ов возвращает exit 1 (mimics
    # «нет такой записи»). Делаем это через подмену в начале PATH.
    cat > "$MOCKDIR/uci" <<'EOF'
#!/bin/sh
# Mock for net_lan_ip fallback test: never returns anything.
echo "$@" >> "${CALLS_DIR:-/tmp}/uci"
exit 1
EOF
    chmod +x "$MOCKDIR/uci"

    result="$(net_lan_ip '192.168.99.1')"
    [ "$result" = "192.168.99.1" ]
}

@test "net_lan_ip: при отсутствии uci И пустом fallback — печатает пусто" {
    cat > "$MOCKDIR/uci" <<'EOF'
#!/bin/sh
echo "$@" >> "${CALLS_DIR:-/tmp}/uci"
exit 1
EOF
    chmod +x "$MOCKDIR/uci"

    result="$(net_lan_ip '')"
    [ -z "$result" ]
}

# ─── net_lan_cidr ────────────────────────────────────────────────────────────

@test "net_lan_cidr: при пустых netifd И ipcalc — возвращает exit 1" {
    # Наш sandbox не имеет /lib/functions/network.sh и ipcalc.sh, так что
    # положительный путь не сработает. Проверяем именно отрицательный
    # контракт: функция должна вернуть exit 1, а не «успешно вернуть пусто».
    cat > "$MOCKDIR/uci" <<'EOF'
#!/bin/sh
echo "$@" >> "${CALLS_DIR:-/tmp}/uci"
exit 1
EOF
    chmod +x "$MOCKDIR/uci"

    run net_lan_cidr
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "net_lan_cidr: с ipcalc.sh-mock'ом успешно собирает CIDR" {
    # Кладём mock ipcalc.sh, имитирующий busybox-варианты.
    cat > "$MOCKDIR/ipcalc.sh" <<'EOF'
#!/bin/sh
# Принимает: <ip> <mask>. Печатает NETWORK= и PREFIX= (это формат busybox).
# Считаем только для тестового кейса 192.168.1.1 / 255.255.255.0 — проще не нужно.
ip="$1"; mask="$2"
case "$ip/$mask" in
    "192.168.1.1/255.255.255.0")
        echo "IP=192.168.1.1"
        echo "NETMASK=255.255.255.0"
        echo "NETWORK=192.168.1.0"
        echo "PREFIX=24"
        ;;
    *)
        # неизвестная комбинация — возвращаем пусто, имитируем фейл
        :
        ;;
esac
EOF
    chmod +x "$MOCKDIR/ipcalc.sh"

    # Полный путь fallback'а: uci.ipaddr=192.168.1.1, netmask=255.255.255.0,
    # ipcalc собирает 192.168.1.0/24.
    uci set network.lan.ipaddr=192.168.1.1
    uci set network.lan.netmask=255.255.255.0

    run net_lan_cidr
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.0/24" ]
}

@test "net_lan_cidr: CIDR-форма ipaddr корректно срезается перед ipcalc" {
    # Если uci отдаёт "192.168.1.1/24" (OpenWrt 25.12+), функция должна
    # перед передачей в ipcalc.sh срезать "/24". Иначе ipcalc упадёт.
    cat > "$MOCKDIR/ipcalc.sh" <<'EOF'
#!/bin/sh
# Этот mock падает если в IP есть слэш — это и есть проверка контракта.
case "$1" in
    */*) echo "ERROR: ipaddr with mask passed to ipcalc: $1" >&2; exit 1;;
    *)   echo "NETWORK=192.168.1.0"; echo "PREFIX=24" ;;
esac
EOF
    chmod +x "$MOCKDIR/ipcalc.sh"

    uci set network.lan.ipaddr=192.168.1.1/24
    uci set network.lan.netmask=255.255.255.0

    run net_lan_cidr
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.0/24" ]
}
