#!/bin/sh
# 10-quality.sh — базовые системные настройки.
set -e

echo "== 10. System settings =="

# === 1. Timezone ===
echo "→ timezone → UTC (универсальное время, не зависит от страны пользователя)"
echo "  Чтобы перевести в своё время: откройте LuCI → System → System → Timezone."
uci set system.@system[0].timezone='UTC0'
uci set system.@system[0].zonename='UTC'
uci commit system
/etc/init.d/system reload
echo "  date (UTC): $(date)"

# === 2. /etc/sysupgrade.conf — protect-list разложен манифестом ===
if [ -f /etc/sysupgrade.conf ]; then
    echo "→ /etc/sysupgrade.conf на месте, protect-list:"
    grep -v '^#' /etc/sysupgrade.conf | grep -v '^$' | head -15
else
    echo "  ⚠ /etc/sysupgrade.conf отсутствует — protect-list не обновлён"
fi

# === 3. conntrack тайм-ауты — предотвращение переполнения таблицы ===
# Симптом переполнения: VPN замедляется в 100x через 1-2 недели, лечится ребутом.
[ -x /usr/bin/conntrack-tune ] || echo "  ⚠ /usr/bin/conntrack-tune отсутствует"

# Применяем немедленно
/usr/bin/conntrack-tune 2>/dev/null && echo "→ conntrack-tune применён" || true

# Прописываем в sysctl.conf чтобы пережить ребут
# (sysctl.d/11-nf-conntrack.conf нельзя редактировать — теряется при sysupgrade)
cat >> /etc/sysctl.conf <<'SYSCTL'

# conntrack-tune: оптимальные тайм-ауты для VPN-шлюза (cheburnet-router)
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_close_wait=60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=60
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout_stream=60
SYSCTL
echo "  записано в /etc/sysctl.conf"

# @reboot cron — применяем сразу после загрузки (перекрываем sysctl.d).
# `crontab -l` на свежем роутере пустой → `grep -v` на пустом вводе exit 1
# → `set -e` убивает шаг. Защищаем `|| true` (та же регрессия что в 08).
{
    crontab -l 2>/dev/null | grep -v conntrack-tune || true
    echo "@reboot sleep 10 && /usr/bin/conntrack-tune"
} > /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp
# busybox crond перечитывает /etc/crontabs/root по уведомлению от `crontab`
# — отдельный `service cron restart` тут лишний (08-watchdog уже включил
# и запустил cron перед этим шагом).
echo "  cron @reboot OK"

echo
echo "✓ Quality OK"
