#!/bin/bash
# phase5-routing.sh — split-routing validation на реальном железе.
#
# Проверяет что HOME-режим действительно работает end-to-end:
#   • западные сайты выходят через AmneziaWG (видимый outgoing IP = VPN-сервер)
#   • российские сайты выходят direct WAN (RU-IP, без капчи «не из РФ»)
#   • механизм FakeIP в DNS работает (.ru → 198.18.*, остальное — real IP)
#
# Запускается после phase1 (установка), phase2/3 (UI + CLI). К этому моменту
# AWG-туннель должен быть поднят, sing-box подхватил community-list.
#
# Толерантен к internet-flakiness: 4 из 5 сайтов в каждой группе достаточно;
# любой HTTP-код 2xx/3xx/4xx/5xx считается «соединение прошло» (нас интересует
# routing, не сам сайт); только timeout (000) валит проверку.
#
# Часть теста (lan-traffic-split) требует чтобы ХОСТ был подключён в LAN
# cheburnet'а (default gw = роутер). На типичном setup'е hw-теста — ноут
# инженера ethernet'ом в LAN-порт. Если хост не в LAN — тест пропустится
# с warn'ом, остальные проверки phase5 пройдут.

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

report_init "Phase 5 — Split routing"

check_routing_separation
check_dns_split
check_lan_traffic_split

report_summary
exit $?
