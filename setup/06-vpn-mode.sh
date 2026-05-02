#!/bin/sh
# 06-vpn-mode.sh — настроить vpn-mode CLI и поддержку физической кнопки.
#
# Файлы (vpn-mode, hotplug-handler, init.d-сервис) уже разложены по местам
# через setup/manifest.txt в setup/install.sh. Здесь только активируем
# init.d и применяем дефолтный режим.
set -e

echo "== 06. vpn-mode CLI + кнопка =="

# === 1. Sanity: бинари на месте ===
[ -x /usr/bin/vpn-mode ] || { echo "✗ /usr/bin/vpn-mode отсутствует (манифест?)"; exit 1; }

# === 2. Init.d-автозапуск ===
if [ -x /etc/init.d/vpn-mode ]; then
    /etc/init.d/vpn-mode enable
    echo "→ init.d/vpn-mode включён в автозагрузку"
else
    echo "⚠ /etc/init.d/vpn-mode отсутствует — режим не будет восстанавливаться при перезагрузке"
fi

# === 3. Режим по умолчанию ===
# Если режим ещё не задан — применяем home (безопасный дефолт)
if [ ! -f /etc/vpn-mode.state ]; then
    /usr/bin/vpn-mode home
    echo "→ режим по умолчанию: home"
else
    echo "→ режим уже задан: $(cat /etc/vpn-mode.state)"
fi

echo
echo "✓ vpn-mode OK"
echo "  Переключение режимов:"
echo "    vpn-mode home    — .ru/.su/.рф напрямую, остальное через VPN"
echo "    vpn-mode travel  — весь трафик через VPN"
echo "    vpn-mode status  — текущий режим"
