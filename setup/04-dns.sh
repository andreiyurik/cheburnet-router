#!/bin/sh
# 04-dns.sh — настроить Quad9 DoH через podkop/sing-box.
# При недоступности Quad9 sing-box сам падает на bootstrap_dns (1.1.1.1).
set -e

echo "== 04. DNS (Quad9 DoH) =="

# === 1. UCI podkop DNS ===
uci set podkop.settings.dns_type='doh'
uci set podkop.settings.dns_server='dns.quad9.net/dns-query'
uci set podkop.settings.bootstrap_dns_server='1.1.1.1'
uci commit podkop

# === 2. Sanity: dns-provider на месте (разложен через манифест) ===
[ -x /usr/bin/dns-provider ] || echo "⚠ /usr/bin/dns-provider отсутствует — статус через vpn-mode не будет показывать DNS"

# === 3. Reload podkop для применения нового DNS ===
# Синхронно, плюс короткий poll: ждём пока sing-box перепрочитает конфиг
# и снова откроет listener на 127.0.0.42:53. Без verify предыдущая версия
# делала reload в фон, спала 8 сек и проверяла резолв — на медленной железке
# sing-box ещё доходил, тест падал, а установка катилась дальше с broken DNS.
/etc/init.d/podkop reload >/dev/null 2>&1
_r=0
while [ "$_r" -lt 20 ]; do
    pidof sing-box >/dev/null 2>&1 \
        && nft list table inet PodkopTable >/dev/null 2>&1 \
        && break
    _r=$((_r + 1))
    sleep 1
done

if ! pidof sing-box >/dev/null 2>&1; then
    echo "✗ sing-box упал после reload с новым DNS-конфигом." >&2
    echo "  Часто это значит, что bootstrap_dns_server (1.1.1.1) недоступен" >&2
    echo "  у вашего провайдера. Диагностика:  logread -e sing-box | tail -30" >&2
    exit 1
fi

# === 4. Проверка ===
if /usr/bin/dns-provider status 2>/dev/null | grep -q Quad9; then
    echo "✓ Quad9 DoH активен"
else
    echo "⚠ dns-provider status говорит:"
    /usr/bin/dns-provider status
fi

# Живой тест — резолвим через локальный dnsmasq роутера, а не через хардкод 192.168.1.1
NET_LIB="${CHEBURNET_NET_LIB:-/opt/cheburnet/lib/net-detect.sh}"
[ -f "$NET_LIB" ] || NET_LIB="$(dirname "$0")/../lib/net-detect.sh"
# shellcheck source=../lib/net-detect.sh disable=SC1090,SC1091
. "$NET_LIB"
LAN_IP=$(net_lan_ip 127.0.0.1)

# Retry 5×2c: после reload сервиса sing-box нужно ~5-15 сек чтобы он
# перепрочитал конфиг и снова начал отвечать на DNS-запросы. Один-shot
# проверка раньше промахивалась и печатала ⚠ в логе — после чего скрипт
# ВСЁ РАВНО писал «✓ DNS OK» и установка шла дальше с поломанным DNS.
# Теперь: либо одна из попыток успешна → один честный ✓, либо все упали
# → ✗ и exit 1 (нет смысла продолжать установку с нерабочим DNS — kill-switch
# на следующем шаге заблокирует весь LAN-трафик и юзер останется без интернета).
_dns_ok=0
_i=0
while [ "$_i" -lt 5 ]; do
    if nslookup cloudflare.com "$LAN_IP" 2>/dev/null | grep -q Address; then
        _dns_ok=1
        break
    fi
    _i=$((_i + 1))
    sleep 2
done

if [ "$_dns_ok" = "1" ]; then
    echo "✓ резолвинг работает (через $LAN_IP)"
    echo "✓ DNS OK"
else
    echo "✗ DNS не резолвит cloudflare.com через $LAN_IP после 5 попыток (~10 сек)." >&2
    echo "  Это критично — продолжать установку с неработающим DNS нельзя." >&2
    echo "  Диагностика:  logread | grep sing-box | grep dns" >&2
    exit 1
fi
unset _i _dns_ok
