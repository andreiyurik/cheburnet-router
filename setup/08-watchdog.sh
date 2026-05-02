#!/bin/sh
# 08-watchdog.sh — установить awg-watchdog (мониторинг свежести handshake + авто-рестарт).
set -e

echo "== 08. AWG Watchdog =="

# === 1. Sanity: awg-watchdog и conntrack-monitor разложены манифестом ===
[ -x /usr/bin/awg-watchdog ] || { echo "✗ /usr/bin/awg-watchdog отсутствует (манифест?)"; exit 1; }
[ -x /usr/bin/conntrack-monitor ] || echo "  ⚠ /usr/bin/conntrack-monitor отсутствует — мониторинг conntrack пропущен"

# === 3. Cron ===
# На свежем роутере crontab пустой → `crontab -l` ничего не печатает.
# `grep -v PATTERN` на пустом вводе возвращает exit 1 (нечего выводить),
# и под `set -e` весь шаг падает молча после строки "настраиваем cron".
# Поэтому: `|| true` на pipe (на случай пустого crontab) и `-e` агрегирует
# три pattern'а в один grep вместо трёх chained-вызовов.
#
# Дополнительно: на чистой OpenWrt 25.12+ `/etc/crontabs/` создаётся ТОЛЬКО
# при первом старте crond. Если демон ещё не запускался — `crontab file`
# падает с ENOENT, и шаг падает. Создаём директорию руками + не считаем
# отсутствие /etc/init.d/cron фатальным (cron-задачи запишутся, демон
# подхватит при первом старте/ребуте).
echo "→ настраиваем cron"
mkdir -p /etc/crontabs
{
    crontab -l 2>/dev/null \
        | grep -v -e awg-watchdog -e conntrack-monitor -e podkop-weekly \
        || true
    echo "* * * * * /usr/bin/awg-watchdog"
    [ -x /usr/bin/conntrack-monitor ] && echo "*/15 * * * * /usr/bin/conntrack-monitor"
    # Еженедельный перезапуск podkop/sing-box в 4:00 пн (MSK) —
    # предотвращает накопление состояния
    echo "0 4 * * 1 /etc/init.d/podkop restart 2>&1 | logger -t podkop-weekly"
} > /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp
if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron restart >/dev/null 2>&1 || echo "  ⚠ cron restart вернул ошибку (демон подхватит при ребуте)"
else
    echo "  ⚠ /etc/init.d/cron отсутствует — задачи записаны, но демон не запущен"
fi

# === 4. Первый прогон ===
echo "→ тестовый прогон awg-watchdog:"
/usr/bin/awg-watchdog
echo "exit=$?"

echo "✓ watchdog OK"
echo
echo "Мониторить работу можно через:"
echo "  logread -e awg-watchdog      # handshake watchdog"
echo "  logread -e conntrack-monitor # заполненность conntrack (раз в 15 мин)"
echo "  cat /tmp/awg-watchdog/fails  # счётчик подряд-рестартов awg0"
