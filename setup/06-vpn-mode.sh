#!/bin/sh
# 06-vpn-mode.sh — пост-install info для vpn-mode CLI.
#
# /usr/bin/vpn-mode разложен по manifest'у. HOME-режим уже применён через
# podkop_apply_home в setup/02-podkop.sh. Состояние HOME/TRAVEL живёт в UCI
# подkop'а (persistent через sysupgrade), отдельной инициализации не нужно.
set -e

echo "== 06. vpn-mode CLI =="

[ -x /usr/bin/vpn-mode ] || { echo "✗ /usr/bin/vpn-mode отсутствует (манифест?)"; exit 1; }

echo "✓ vpn-mode OK"
echo "  Переключение режимов:"
echo "    vpn-mode home    — .ru/.su/.рф напрямую, остальное через VPN"
echo "    vpn-mode travel  — весь трафик через VPN"
echo "    vpn-mode status  — текущий режим"
