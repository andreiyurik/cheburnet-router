#!/bin/sh
# 11-travel.sh — sanity-check скриптов для TRAVEL-режима (WISP + captive portal).
# Файлы разложены через setup/manifest.txt — здесь только проверяем что бинари
# на месте и печатаем шпаргалку.
set -e

echo "== 11. Travel mode helpers =="

for BIN in /usr/bin/travel-connect /usr/bin/travel-portal /usr/bin/travel-vpn-on; do
    if [ -x "$BIN" ]; then
        echo "→ $BIN на месте"
    else
        echo "✗ $BIN отсутствует (манифест?)"
        exit 1
    fi
done

echo "✓ travel-mode scripts OK"
echo
echo "В поездке:"
echo "  travel-connect \"HotelWiFi\" \"password\"   # подключиться к upstream"
echo "  travel-portal                            # принять отельный portal"
echo "  vpn-mode travel                          # full tunnel"
echo "  travel-connect --off                     # отключиться"
