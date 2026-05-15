#!/bin/sh
# restore.sh — восстановить снимок на чистый OpenWrt-роутер.
#
# Предполагается что пакеты уже установлены (через setup/*).
# Этот скрипт только накатывает UCI-конфиги, скрипты и секреты.
#
# Пример:
#   ./backup/restore.sh backup/snapshots/20260417-120000 root@192.168.1.1
set -e

SNAP="${1:?Usage: $0 <snapshot-dir> root@<router-ip>}"
ROUTER="${2:?Usage: $0 <snapshot-dir> root@<router-ip>}"

[ -d "$SNAP" ] || { echo "ERROR: $SNAP не директория"; exit 1; }

echo "=== restore из $SNAP → $ROUTER ==="

# === 1. UCI ===
if [ -f "$SNAP/uci-export.txt" ]; then
    echo "→ UCI import"
    scp -q "$SNAP/uci-export.txt" "$ROUTER":/tmp/uci-restore.txt
    ssh "$ROUTER" 'uci import < /tmp/uci-restore.txt && uci commit && rm /tmp/uci-restore.txt'
fi

# === 2. Custom scripts ===
echo "→ custom scripts"
for F in vpn-mode dns-provider dns-healthcheck awg-watchdog log-snapshot sqm-tune; do
    if [ -f "$SNAP/usr-bin/$F" ]; then
        scp -q "$SNAP/usr-bin/$F" "$ROUTER":/usr/bin/$F
        ssh "$ROUTER" "chmod +x /usr/bin/$F"
    fi
done

# === 3. Секреты ===
if [ -f "$SNAP/secrets/awg0.conf" ]; then
    echo "→ awg0.conf"
    ssh "$ROUTER" 'mkdir -p /etc/amnezia/amneziawg'
    scp -q "$SNAP/secrets/awg0.conf" "$ROUTER":/etc/amnezia/amneziawg/awg0.conf
    ssh "$ROUTER" 'chmod 600 /etc/amnezia/amneziawg/awg0.conf'
fi

# === 4. Adblock-lean ===
if [ -f "$SNAP/adblock-lean/config" ]; then
    echo "→ adblock-lean config"
    ssh "$ROUTER" 'mkdir -p /etc/adblock-lean'
    scp -q "$SNAP/adblock-lean/config" "$ROUTER":/etc/adblock-lean/config
fi

# === 5. Crontab ===
if [ -s "$SNAP/crontab.txt" ]; then
    echo "→ crontab"
    scp -q "$SNAP/crontab.txt" "$ROUTER":/tmp/crontab.txt
    ssh "$ROUTER" 'crontab /tmp/crontab.txt; rm /tmp/crontab.txt'
fi

# === 6. Перезагрузка сервисов ===
echo "→ restart сервисов"
ssh "$ROUTER" '/etc/init.d/network reload; \
    /etc/init.d/firewall reload; \
    /etc/init.d/podkop restart >/dev/null 2>&1 & \
    /etc/init.d/dnsmasq restart; \
    /etc/init.d/adblock-lean restart; \
    wifi reload; \
    sleep 5'

echo
echo "✓ Restore готов."
echo "Проверьте статус: ssh $ROUTER 'awg show awg0; vpn-mode status'"
