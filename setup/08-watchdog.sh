#!/bin/sh
# 08-watchdog.sh — установить awg-watchdog (мониторинг свежести handshake + авто-рестарт).
set -e

echo "== 08. AWG Watchdog =="

# === 1. Копируем скрипт ===
if [ -f /tmp/scripts/awg-watchdog ]; then
    cp /tmp/scripts/awg-watchdog /usr/bin/awg-watchdog
    chmod +x /usr/bin/awg-watchdog
    echo "→ установлен /usr/bin/awg-watchdog"
else
    echo "⚠ /tmp/scripts/awg-watchdog не найден"
    exit 1
fi

# === 2. conntrack-monitor ===
echo "→ устанавливаем conntrack-monitor"
if [ -f /tmp/scripts/conntrack-monitor ]; then
    cp /tmp/scripts/conntrack-monitor /usr/bin/conntrack-monitor
    chmod +x /usr/bin/conntrack-monitor
    echo "  установлен /usr/bin/conntrack-monitor"
else
    echo "  ⚠ /tmp/scripts/conntrack-monitor не найден — пропускаю"
fi

# === 3. Cron ===
# На свежем роутере crontab пустой → `crontab -l` ничего не печатает.
# `grep -v PATTERN` на пустом вводе возвращает exit 1 (нечего выводить),
# и под `set -e` весь шаг падает молча после строки "настраиваем cron".
# Ломалось у пользователя на чистой OpenWrt 25.12.2: ровно эта регрессия.
# Поэтому: `|| true` на pipe (на случай пустого crontab) и `-e` агрегирует
# три pattern'а в один grep вместо трёх chained-вызовов.
echo "→ настраиваем cron"
{
    crontab -l 2>/dev/null \
        | grep -v -e awg-watchdog -e conntrack-monitor -e podkop-weekly \
        || true
    echo "* * * * * /usr/bin/awg-watchdog"
    echo "*/15 * * * * /usr/bin/conntrack-monitor"
    # Еженедельный перезапуск podkop/sing-box в 4:00 пн (MSK) —
    # предотвращает накопление состояния
    echo "0 4 * * 1 /etc/init.d/podkop restart 2>&1 | logger -t podkop-weekly"
} > /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp
/etc/init.d/cron restart >/dev/null

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
