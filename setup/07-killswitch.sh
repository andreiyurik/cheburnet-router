#!/bin/sh
# 07-killswitch.sh — правила KillSwitch для защиты от утечек при падении VPN.
#
# Применяем правила напрямую через nft (мгновенно, без разрыва активных
# соединений), параллельно сохраняем в UCI для персистентности после reboot.
# Полный `firewall reload` здесь не нужен и вреден: он на 1-3 минуты
# перестраивает весь inet fw4 (Lua-компилятор + atomic nftables replace +
# hotplug-обработчики), что выглядит как «зависло» в установщике. Цепочка
# forward_lan уже создана на шаге 01-amneziawg.
set -e

echo "== 07. Kill switch =="

# === Подключаем хелперы ===
FW4_LIB="${CHEBURNET_FW4_LIB:-/opt/cheburnet/lib/cheburnet-fw4.sh}"
[ -f "$FW4_LIB" ] || FW4_LIB="$(dirname "$0")/../lib/cheburnet-fw4.sh"
# shellcheck source=../lib/cheburnet-fw4.sh disable=SC1090,SC1091
. "$FW4_LIB"

DIAG_LIB="${CHEBURNET_DIAG_LIB:-/opt/cheburnet/lib/cheburnet-diag.sh}"
[ -f "$DIAG_LIB" ] || DIAG_LIB="$(dirname "$0")/../lib/cheburnet-diag.sh"
# shellcheck source=../lib/cheburnet-diag.sh disable=SC1090,SC1091
. "$DIAG_LIB"

NET_LIB="${CHEBURNET_NET_LIB:-/opt/cheburnet/lib/net-detect.sh}"
[ -f "$NET_LIB" ] || NET_LIB="$(dirname "$0")/../lib/net-detect.sh"
# shellcheck source=../lib/net-detect.sh disable=SC1090,SC1091
. "$NET_LIB"

# === 1. Параметры из netifd ===
# LAN-подсеть для IPv4-фильтра. Не хардкодим 192.168.1.0/24 — иначе на
# нестандартных подсетях правило не сматчится и kill-switch будет тихо
# дырявым. net_lan_cidr делает netifd → uci+ipcalc fallback.
LAN_CIDR=$(net_lan_cidr) || {
    echo "✗ Не удалось определить LAN-подсеть из uci." >&2
    cheburnet_diag_network
    exit 1
}

# /lib/functions/network.sh для последующего network_get_device.
# net_lan_cidr его уже подсорсил, но повторный source безопасен
# (idempotent функции) — оставляем явный вызов для читаемости.
# shellcheck disable=SC1091
. /lib/functions/network.sh
network_flush_cache

# WAN- и LAN-устройства для nft-фильтров. На разных платформах имена различаются
# (wan, eth1, wan@eth0; br-lan, br0) — резолвим через netifd, не угадываем.
# Цепочка: netifd runtime → UCI config → fail. UCI-fallback нужен потому,
# что netifd на свежем boot мог ещё не успеть поднять линк, и резолвинг
# через network_get_device возвращает пусто; имя L2-устройства из конфига
# при этом уже доступно.
WAN_DEV=""
network_get_device WAN_DEV wan 2>/dev/null || true
if [ -z "$WAN_DEV" ]; then
    WAN_DEV=$(uci -q get network.wan.device || true)
fi
if [ -z "$WAN_DEV" ]; then
    echo "✗ Не удалось определить WAN-устройство (ни через netifd, ни через uci network.wan.device)." >&2
    cheburnet_diag_network
    exit 1
fi

LAN_DEV=""
network_get_device LAN_DEV lan 2>/dev/null || true
if [ -z "$LAN_DEV" ]; then
    LAN_DEV=$(uci -q get network.lan.device || true)
fi
if [ -z "$LAN_DEV" ]; then
    echo "✗ Не удалось определить LAN-устройство (ни через netifd, ни через uci network.lan.device)." >&2
    cheburnet_diag_network
    exit 1
fi

echo "→ LAN=$LAN_CIDR (dev=$LAN_DEV), WAN-dev=$WAN_DEV"

# === 2. UCI: пишем правила в /etc/config/firewall для персистентности.
# При reboot fw4 регенерирует весь ruleset из UCI и наши правила вернутся
# в forward_lan на штатном месте.
# Cleanup перед add: чтобы повторный запуск установщика не плодил дубликаты
# и чинил повреждённые правила (один паттерн ловит и IPv4, и IPv6 версии).
cheburnet_uci_delete_rules_by_name "KillSwitch-IPv[46]-LAN-direct-egress"

uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='KillSwitch-IPv4-LAN-direct-egress'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].family='ipv4'
uci set firewall.@rule[-1].src_ip="$LAN_CIDR"
uci set firewall.@rule[-1].proto='all'
uci set firewall.@rule[-1].target='DROP'

uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='KillSwitch-IPv6-LAN-direct-egress'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].proto='all'
uci set firewall.@rule[-1].target='DROP'

uci commit firewall

# === 3. nft: применяем правила НАПРЯМУЮ в живой ruleset. ===
echo "→ применяю правила в nft (мгновенно, без firewall reload)..."

cheburnet_fw4_apply_rule forward_lan \
    "KillSwitch-IPv4-LAN-direct-egress" \
    "ip saddr $LAN_CIDR oifname \"$WAN_DEV\" counter drop"

# Без iifname-фильтра правило дропало бы ВЕСЬ IPv6, выходящий через WAN-dev —
# в т.ч. трафик роутера-самого-себя (apk update по AAAA, NTPv6). Ограничиваем
# его пакетами, пришедшими с LAN-bridge: ровно то, что в UCI-аналоге задано
# как src='lan' dest='wan' family='ipv6'.
cheburnet_fw4_apply_rule forward_lan \
    "KillSwitch-IPv6-LAN-direct-egress" \
    "meta nfproto ipv6 iifname \"$LAN_DEV\" oifname \"$WAN_DEV\" counter drop"

# === 4. Проверка ===
if nft list chain inet fw4 forward_lan 2>/dev/null | grep -q KillSwitch; then
    echo "✓ KillSwitch правила активны:"
    nft list chain inet fw4 forward_lan 2>/dev/null \
        | grep -i killswitch | sed 's/^/    /'
else
    echo "✗ правила не видны в nft" >&2
    exit 1
fi

echo "✓ Kill switch OK"
