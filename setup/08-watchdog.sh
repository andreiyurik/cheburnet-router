#!/bin/sh
# 08-watchdog.sh — установить awg-watchdog (мониторинг свежести handshake + авто-рестарт).
set -e

echo "== 08. AWG Watchdog =="

# === 1. Sanity: awg-watchdog и conntrack-monitor разложены манифестом ===
[ -x /usr/bin/awg-watchdog ] || { echo "✗ /usr/bin/awg-watchdog отсутствует (манифест?)"; exit 1; }
[ -x /usr/bin/conntrack-monitor ] || echo "  ⚠ /usr/bin/conntrack-monitor отсутствует — мониторинг conntrack пропущен"

# === 2. Cron ===
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
        | grep -v -e awg-watchdog -e conntrack-monitor -e dns-healthcheck \
                  -e log-snapshot -e podkop-weekly \
        || true
    echo "* * * * * /usr/bin/awg-watchdog"
    [ -x /usr/bin/conntrack-monitor ] && echo "*/15 * * * * /usr/bin/conntrack-monitor"
    # DNS автофейловер Quad9 ⇄ Cloudflare. Скрипт сам кэширует state в /tmp,
    # 5 минут — компромисс между «быстро среагировать на падение upstream»
    # и «не штормить DoH-резолверы».
    [ -x /usr/bin/dns-healthcheck ] && echo "*/5 * * * * /usr/bin/dns-healthcheck"
    # Снапшот логов раз в сутки в 23:55 — чтобы не терять контекст инцидентов
    # (logd ring-buffer переполняется за часы под нагрузкой).
    [ -x /usr/bin/log-snapshot ] && echo "55 23 * * * /usr/bin/log-snapshot"
    # Еженедельный перезапуск podkop/sing-box в 4:00 пн (MSK) —
    # предотвращает накопление состояния
    echo "0 4 * * 1 /etc/init.d/podkop restart 2>&1 | logger -t podkop-weekly"
} > /tmp/cron.tmp
crontab /tmp/cron.tmp
rm /tmp/cron.tmp

# === 3. Тише, crond ===
# По умолчанию OpenWrt запускает busybox crond с loglevel=5 (NOTICE) — это
# пишет в logd КАЖДЫЙ запуск задачи: при `* * * * * awg-watchdog` это
# 1440 строк в день при нулевой полезной нагрузке. Сами скрипты логируют
# только аномалии (через `logger -t`), поэтому ставим демон на 8 (только
# критические ошибки самого crond), а собственные сообщения скриптов
# попадают в logd напрямую и не страдают.
uci set system.@system[0].cronloglevel='8'
uci commit system

if [ -x /etc/init.d/cron ]; then
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron restart >/dev/null 2>&1 || echo "  ⚠ cron restart вернул ошибку (демон подхватит при ребуте)"
else
    echo "  ⚠ /etc/init.d/cron отсутствует — задачи записаны, но демон не запущен"
fi

# === 4. Первый прогон ===
# С `set -e` падение watchdog сразу провалит шаг — `echo exit=$?` после
# вызова всегда печатает "exit=0" и ничего не сообщает. AGENTS.md инвариант
# «cron логирует только аномалии» относится к самой задаче, не к этому
# одноразовому диагностическому прогону, но шум всё равно не нужен.
echo "→ тестовый прогон awg-watchdog:"
/usr/bin/awg-watchdog

echo "✓ watchdog OK"
echo
echo "Мониторить работу можно через:"
echo "  logread -e awg-watchdog      # handshake watchdog"
echo "  logread -e conntrack-monitor # заполненность conntrack (раз в 15 мин)"
echo "  cat /tmp/awg-watchdog/fails  # счётчик подряд-рестартов awg0"
