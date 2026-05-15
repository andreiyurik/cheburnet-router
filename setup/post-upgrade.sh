#!/bin/sh
# post-upgrade.sh — восстановить пакеты после sysupgrade'а OpenWrt.
#
# Эта часть нашего стека НЕ сохраняется стандартным sysupgrade'ом:
#   - Out-of-tree apk-пакеты (AmneziaWG, podkop, sing-box, adblock-lean, sqm-scripts)
#   - wpad-mbedtls (заменяет wpad-basic-mbedtls после апгрейда)
#
# А ЭТО уже preserve'ится (благодаря нашему /etc/sysupgrade.conf):
#   - /usr/bin/vpn-* dns-* awg-watchdog log-snapshot sqm-tune
#   - /etc/amnezia/amneziawg/awg0.conf (критично, содержит ключи)
#   - /etc/config/* (все UCI: podkop, wireless, firewall, sqm...)
#   - /etc/crontabs/root (все наши cron-записи)
#
# Idempotent: можно запускать многократно.
set -e

echo "=== post-upgrade: восстанавливаем пакеты после sysupgrade ==="

# === 1. apk update ===
echo "→ apk update"
apk update 2>&1 | tail -3

# === 2. wpad-mbedtls (заменяем базовый для поддержки WPA3) ===
if ! apk list --installed 2>/dev/null | grep -q wpad-mbedtls; then
    echo "→ wpad-basic-mbedtls → wpad-mbedtls"
    apk del wpad-basic-mbedtls 2>/dev/null || true
    apk add wpad-mbedtls
fi

# === 3. AmneziaWG (kmod + tools + luci-proto) ===
if ! lsmod | grep -q '^amneziawg '; then
    echo "→ AmneziaWG пакеты"

    # Подключаем общую awg_pick_version — ту же, что использует 01-amneziawg.sh.
    # Без неё этот блок дублировал цикл fallback-версий и потенциально
    # расходился при добавлении новых версий апстрима.
    # shellcheck source=/dev/null
    . /opt/cheburnet/lib/cheburnet-utils.sh
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    if [ -z "${DISTRIB_ARCH:-}" ] || [ -z "${DISTRIB_TARGET:-}" ] || [ -z "${DISTRIB_RELEASE:-}" ]; then
        echo "✗ Не удалось определить архитектуру/версию роутера." >&2
        exit 1
    fi
    ARCH="${DISTRIB_ARCH}_$(echo "$DISTRIB_TARGET" | tr '/' '_')"

    AWG_VER="$(awg_pick_version "$DISTRIB_RELEASE" "$ARCH")" || AWG_VER=""
    if [ -z "$AWG_VER" ]; then
        echo "✗ Нет совместимого релиза awg-openwrt для OpenWrt ${DISTRIB_RELEASE} / ${ARCH}." >&2
        exit 1
    fi
    echo "  arch=${ARCH}, awg-openwrt=v${AWG_VER}"

    BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${AWG_VER}"
    cd /tmp
    for PKG in "kmod-amneziawg_v${AWG_VER}" "amneziawg-tools_v${AWG_VER}" "luci-proto-amneziawg_v${AWG_VER}"; do
        FILE="${PKG}_${ARCH}.apk"
        wget -q -O "$FILE" "$BASE/$FILE" || { echo "download failed: $FILE"; exit 1; }
    done
    apk add --allow-untrusted "./kmod-amneziawg_v${AWG_VER}_${ARCH}.apk" \
                              "./amneziawg-tools_v${AWG_VER}_${ARCH}.apk" \
                              "./luci-proto-amneziawg_v${AWG_VER}_${ARCH}.apk"
    modprobe amneziawg
fi

# === 4. Podkop + sing-box ===
if [ ! -x /etc/init.d/podkop ]; then
    echo "→ podkop + sing-box"
    UPSTREAM_URL="https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"
    VENDOR_FILE="${CHEBURNET_VENDOR:-/opt/cheburnet/vendor}/podkop-install.sh"
    if wget -qO /tmp/podkop-install.sh --timeout=20 "$UPSTREAM_URL" 2>/dev/null && \
       [ -s /tmp/podkop-install.sh ]; then
        :
    elif [ -f "$VENDOR_FILE" ]; then
        echo "  ⚠ upstream недоступен — использую vendored-копию ($VENDOR_FILE)"
        cp "$VENDOR_FILE" /tmp/podkop-install.sh
    else
        echo "✗ Не удалось получить podkop installer ни с upstream, ни локально." >&2
        exit 1
    fi
    # `yes n` шлёт бесконечный поток "n" — устойчиво к любому числу y/n-вопросов
    # подкоповского установщика. См. 02-podkop.sh — здесь та же причина.
    yes n | sh /tmp/podkop-install.sh 2>&1 | tail -5
fi

# === 5. adblock-lean ===
if [ ! -x /etc/init.d/adblock-lean ]; then
    echo "→ adblock-lean"
    UPSTREAM_URL="https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh"
    VENDOR_FILE="${CHEBURNET_VENDOR:-/opt/cheburnet/vendor}/abl-install.sh"
    if uclient-fetch -q --timeout=20 "$UPSTREAM_URL" -O /tmp/abl-install.sh 2>/dev/null && \
       [ -s /tmp/abl-install.sh ]; then
        :
    elif [ -f "$VENDOR_FILE" ]; then
        echo "  ⚠ upstream недоступен — использую vendored-копию ($VENDOR_FILE)"
        cp "$VENDOR_FILE" /tmp/abl-install.sh
    else
        echo "✗ Не удалось получить adblock-lean installer ни с upstream, ни локально." >&2
        exit 1
    fi
    sh /tmp/abl-install.sh -v release
fi

# === 6. sqm-scripts ===
apk add --no-interactive sqm-scripts 2>&1 | tail -2 || true

# === 7. Перезапуск сервисов (берут сохранённые конфиги) ===
echo "→ перезапуск сервисов"
/etc/init.d/network reload
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/podkop restart >/dev/null 2>&1 &
sleep 5
/etc/init.d/dnsmasq restart
/etc/init.d/adblock-lean start >/dev/null 2>&1
wifi reload

# === 8. Финальная проверка ===
echo
echo "=== СТАТУС ==="
echo "AWG: $(awg show awg0 2>/dev/null | awk '/latest handshake/{print; exit}' || echo 'interface not up — check logread')"
echo "Podkop: $(/etc/init.d/sing-box status 2>&1 | head -1)"
echo "Adblock: $(/etc/init.d/adblock-lean status 2>&1 | head -1)"
echo "VPN mode: $(/usr/bin/vpn-mode status 2>&1 | head -1)"
echo
echo "✓ post-upgrade выполнен"
echo
echo "Если что-то не работает:"
echo "  - logread -t podkop | tail"
echo "  - awg show awg0"
echo "  - /etc/init.d/podkop restart"
