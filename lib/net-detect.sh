# lib/net-detect.sh — определение LAN-параметров с правильными fallback'ами.
#
# Source-only: ничего не выполняет, только определяет функции. Без shebang.
#
# Подключение:
#   . /opt/cheburnet/lib/net-detect.sh    # на роутере
#   . lib/net-detect.sh                    # из репо-чекаута
#
# Зачем: один и тот же помеченный TODO-костыль `LAN_IP=${LAN_IP%%/*}`
# и каскад «netifd → uci → ipcalc.sh» был размазан по 02-podkop.sh,
# 04-dns.sh, 07-killswitch.sh, setup/install.sh, rpcd-cheburnet, install.sh.
# Если завтра OpenWrt поменяет формат network.lan.ipaddr — править нужно
# было бы в шести местах. Теперь — в одном.

# ─────────────────────────────────────────────────────────────────────────────
# net_lan_ip
# ─────────────────────────────────────────────────────────────────────────────
#
# Возвращает IP-адрес LAN-интерфейса роутера БЕЗ маски.
# Печатает в stdout. Если не получилось — печатает $1 (fallback) или пусто.
#
# OpenWrt 25.12+ хранит network.lan.ipaddr в CIDR-форме (192.168.1.1/24);
# на 23.05/24.10 — без маски (192.168.1.1). Эта функция возвращает чистый
# IP в обоих случаях.
#
# Аргумент: $1 — fallback-значение (опц.), используется если uci не отвечает.
net_lan_ip() {
    _ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
    _ip=${_ip%%/*}
    if [ -z "$_ip" ]; then
        _ip="$1"
    fi
    printf '%s' "$_ip"
    unset _ip
}

# ─────────────────────────────────────────────────────────────────────────────
# net_lan_cidr
# ─────────────────────────────────────────────────────────────────────────────
#
# Возвращает LAN-подсеть в CIDR-форме (например 192.168.1.0/24).
# Печатает в stdout. Если определить не удалось — печатает пустую строку
# и возвращает exit code 1, чтобы вызывающий мог отличить «всё ок» от фейла.
#
# Каскад источников:
#   1. /lib/functions/network.sh → network_get_subnet (штатный helper netifd)
#   2. uci network.lan.ipaddr + netmask → ipcalc.sh (для старых сборок без
#      network.sh или когда netifd ещё не поднял интерфейс)
#
# Не хардкодим 192.168.1.0/24: на нестандартных подсетях (10.0.0.0/24,
# 192.168.10.0/24) хардкод приводит к молчаливо неправильным fw-правилам
# и тихо-дырявому kill-switch.
net_lan_cidr() {
    _cidr=""

    if [ -f /lib/functions/network.sh ]; then
        # shellcheck disable=SC1091
        . /lib/functions/network.sh
        network_flush_cache
        network_get_subnet _cidr lan 2>/dev/null || true
    fi

    if [ -z "$_cidr" ]; then
        _raw=$(uci -q get network.lan.ipaddr 2>/dev/null)
        case "$_raw" in
            */*)
                # 25.12+ хранит '192.168.1.1/24' — prefix вытаскиваем из самого
                # ipaddr, БЕЗ обращения к netmask. Раньше код стрипал /NN и шёл
                # к netmask, которой в этом формате нет → fallback на 255.255.255.0
                # → на /16-сетях получали неверный CIDR.
                _ip="${_raw%/*}"
                _pfx="${_raw##*/}"
                if [ -n "$_ip" ] && [ -n "$_pfx" ] && command -v ipcalc.sh >/dev/null 2>&1; then
                    _cidr=$(ipcalc.sh "$_ip/$_pfx" 2>/dev/null \
                        | awk -F= '/^NETWORK/{n=$2} /^PREFIX/{p=$2} END{if(n && p) print n"/"p}')
                fi
                unset _ip _pfx
                ;;
            ?*)
                # Legacy-формат '192.168.1.1' + отдельный netmask.
                _mask=$(uci -q get network.lan.netmask 2>/dev/null || echo "255.255.255.0")
                if command -v ipcalc.sh >/dev/null 2>&1; then
                    _cidr=$(ipcalc.sh "$_raw" "$_mask" 2>/dev/null \
                        | awk -F= '/^NETWORK/{n=$2} /^PREFIX/{p=$2} END{if(n && p) print n"/"p}')
                fi
                unset _mask
                ;;
        esac
        unset _raw
    fi

    if [ -z "$_cidr" ]; then
        unset _cidr
        return 1
    fi

    printf '%s' "$_cidr"
    unset _cidr
    return 0
}
