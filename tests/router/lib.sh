#!/bin/bash
# tests/router/lib.sh — общая обвязка проверок на ФИЗИЧЕСКОМ роутере (source-only).
#
#     . "$(dirname "$0")/lib.sh"
#     r_init                       # проверить доступ, показать, с чем работаем
#     r_ssh 'команда'              # выполнить на роутере
#     r_backup                     # снять sysupgrade -b ПЕРЕД первым изменением
#     r_record "строка"            # дописать факт в отчёт прогона
#
# ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ tests/qemu/lib.sh: там VM, которую можно убить и создать заново, здесь —
# чужое рабочее устройство. Отсюда три правила, вшитые в код, а не в инструкцию:
#   1. первое изменение только ПОСЛЕ бэкапа конфигов (r_backup), путь назад — одной командой;
#   2. деструктивные шаги требуют явного согласия (R_YES=1), иначе останавливаемся;
#   3. каждый факт пишется в файл отчёта, а не только в терминал — через неделю «помню, что
#      работало» не является результатом.
#
# Доступ: R_HOST (обязателен; без «user@» подставляется root — на роутере других учёток нет),
# R_PORT (22), R_KEY (путь к ssh-ключу), R_PASS не поддерживаем
# намеренно — пароль в командной строке утекает в историю и в ps.

set -e -u -o pipefail

R_HOST="${R_HOST:-}"
R_PORT="${R_PORT:-22}"
R_KEY="${R_KEY:-}"
R_YES="${R_YES:-0}"

R_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R_RESULTS="$R_DIR/results"
R_REPORT=""

r_msg()  { printf '\n\033[1m→ %s\033[0m\n' "$1"; }
r_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; r_record "OK   $1"; }
r_bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; r_record "FAIL $1"; }
r_warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; r_record "WARN $1"; }
r_die()  { r_bad "$1"; exit 1; }

R_SSH_ARGS=()
R_SCP_ARGS=()

# r_record — дописать строку в отчёт прогона. Отчёт создаётся r_init; до него пишем в /dev/null,
# чтобы вызов из r_die не падал сам.
r_record() {
    [ -n "$R_REPORT" ] || return 0
    printf '%s  %s\n' "$(date -u '+%H:%M:%S')" "$1" >> "$R_REPORT"
}

# r_init <имя-прогона> — проверить доступ и открыть отчёт.
r_init() {
    local name="${1:-run}"
    [ -n "$R_HOST" ] || { echo "✗ задайте R_HOST=<адрес роутера> (и R_KEY=<ssh-ключ> при необходимости)"; exit 1; }

    # На роутере других учёток нет, а «root@» в адресе забывают — тогда ssh молча идёт под
    # локальным именем пользователя и это читается как «нет доступа». Подставляем root сами.
    case "$R_HOST" in *@*) ;; *) R_HOST="root@$R_HOST" ;; esac

    # Два набора, а не один с подменой: у ssh порт это -p, у scp -P, и в массиве флаг с портом
    # лежат отдельными элементами — подмена по строке «-p 22» не срабатывала молча, а scp начинал
    # считать номер порта именем файла.
    local common=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
    [ -n "$R_KEY" ] && common+=(-i "$R_KEY" -o IdentitiesOnly=yes)
    R_SSH_ARGS=("${common[@]}" -p "$R_PORT")
    # -O: OpenWrt не несёт sftp-server, а scp с OpenSSH 9 по умолчанию идёт через SFTP и падает
    # «/usr/libexec/sftp-server: not found».
    R_SCP_ARGS=(-O "${common[@]}" -P "$R_PORT")

    mkdir -p "$R_RESULTS"
    R_REPORT="$R_RESULTS/$(date -u '+%Y-%m-%d')-$name.md"
    {
        echo "# Прогон «$name» — $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo ""
        echo "Роутер: \`$R_HOST:$R_PORT\`"
        echo ""
        echo '```'
    } >> "$R_REPORT"

    r_msg "Проверяю доступ к роутеру $R_HOST:$R_PORT"
    # Причину провала печатаем как есть: чаще всего это не «нет доступа», а сменившийся host key
    # (заводской сброс генерирует новый), и общее сообщение уводит на полчаса не туда.
    local err
    if ! err="$(r_ssh true 2>&1)"; then
        printf '%s\n' "$err" | sed 's/^/    /'
        printf '    Проверьте по порядку:\n'
        printf '      • host key: заводской сброс генерирует новый → ssh-keygen -R %s\n' "${R_HOST#*@}"
        printf '      • линк: адрес роутера может отвечать ЧЕРЕЗ VPN/туннель на вашей машине —\n'
        printf '        тогда ping и «порт открыт» приходят от чужого устройства, а кабель мёртв.\n'
        printf '        Отключите туннель на хосте и сверьте, что маршрут до роутера идёт в кабель.\n'
        r_die "нет доступа по ssh к $R_HOST"
    fi
    local id; id="$(r_ssh 'cat /tmp/sysinfo/model 2>/dev/null; . /etc/openwrt_release 2>/dev/null; echo $DISTRIB_RELEASE $DISTRIB_TARGET' | tr '\n' ' ')"
    r_ok "доступ есть: $id"
    printf '  отчёт: %s\n' "$R_REPORT"
}

r_ssh() { ssh "${R_SSH_ARGS[@]}" "$R_HOST" "$@"; }
r_scp() { scp "${R_SCP_ARGS[@]}" "$1" "$R_HOST:$2"; }

# r_backup — снять бэкап конфигов ПЕРЕД первым изменением. Возврат: одной командой, она печатается.
# Не «на всякий случай»: наши шаги правят network/dhcp/firewall, и человеку нужен путь назад,
# который не зависит от нашего же кода откатa.
r_backup() {
    r_msg "Снимаю бэкап конфигурации роутера (путь назад)"
    mkdir -p "$R_RESULTS"
    local out="$R_RESULTS/backup-$(date -u '+%Y-%m-%d-%H%M').tar.gz"
    r_ssh 'sysupgrade -b - 2>/dev/null' > "$out" || r_die "sysupgrade -b не сработал"
    [ -s "$out" ] || r_die "бэкап получился пустым — не продолжаем"
    r_ok "бэкап: $out ($(du -h "$out" | cut -f1))"
    printf '  вернуть всё как было:\n    cat %s | ssh %s "sysupgrade -r -"\n' "$out" "$R_HOST"
    r_record "BACKUP $out"
}

# r_confirm <что произойдёт> — согласие на деструктивный шаг. R_YES=1 пропускает вопрос
# (для неинтерактивных прогонов), но НЕ прячет предупреждение.
r_confirm() {
    printf '\n\033[33m⚠ %s\033[0m\n' "$1"
    if [ "$R_YES" = "1" ]; then
        printf '  (R_YES=1 — продолжаю без вопроса)\n'
        return 0
    fi
    printf '  Введите YES для продолжения: '
    local a; read -r a
    [ "$a" = "YES" ] || { echo "  отменено"; exit 1; }
}

# r_wait_op <секунд> — дождаться исхода фоновой операции движка (install, switch_to_*, replace_*).
# Опрашивает install_progress — ровно то, что делает панель.
#
# ВСЕ операции движка АСИНХРОННЫЕ: метод ubus возвращает {"status":"started","pid":…} сразу, а
# работа идёт в фоне. Прочитанный сразу после вызова статус показывает недоделанное состояние
# (health=down на ещё не поднятом туннеле) и читается как провал продукта — на этом уже потерян
# час. Единственный корректный способ узнать исход — дождаться done в install_progress.
#
# Итог складывается в R_OP_RESULT (ok|fail|cancelled|crashed), R_OP_REASON, R_OP_STEP.
# Ошибку опроса считаем «ещё идёт»: операции перезапускают сеть, и ssh в этот момент мигает.
R_OP_RESULT=""; R_OP_REASON=""; R_OP_STEP=""
r_wait_op() {
    local budget="${1:-450}" waited=0 p
    R_OP_RESULT=""; R_OP_REASON=""; R_OP_STEP=""
    while [ "$waited" -lt "$budget" ]; do
        p="$(r_ssh 'ubus call cheburnet install_progress 2>/dev/null' 2>/dev/null || true)"
        if [ -n "$p" ]; then
            R_OP_STEP="$(printf '%s' "$p" | sed -n 's/.*"step": *"\([^"]*\)".*/\1/p')"
            if printf '%s' "$p" | grep -q '"done": *true'; then
                R_OP_RESULT="$(printf '%s' "$p" | sed -n 's/.*"result": *"\([^"]*\)".*/\1/p')"
                R_OP_REASON="$(printf '%s' "$p" | sed -n 's/.*"reason": *"\([^"]*\)".*/\1/p')"
                printf '\r%-46s\r' ' '
                [ "$R_OP_RESULT" = "ok" ] && return 0 || return 1
            fi
            printf '\r    шаг: %-28s' "$R_OP_STEP"
        fi
        sleep 5; waited=$((waited + 5))
    done
    printf '\r%-46s\r' ' '
    R_OP_RESULT="timeout"
    return 1
}

# r_exit_ip <iface> <ожидаемый-адрес> — вышел ли трафик в интернет ЧЕРЕЗ туннель.
# Пин host-route на туннель — тот же приём, что в connectivity-probe движка: без него запрос
# ушёл бы на WAN и соврал бы «работает».
r_exit_ip() {
    local iface="$1" want="$2" echo_host="api.ipify.org" ip
    ip="$(r_ssh "nslookup $echo_host 2>/dev/null | awk '/^Address( 1)?: / && \$NF ~ /^[0-9.]+\$/ {print \$NF; exit}'")"
    [ -n "$ip" ] || { r_bad "не разрешился $echo_host — DNS на роутере не работает"; return 1; }
    local got
    got="$(r_ssh "ip route replace $ip dev $iface 2>/dev/null
                  uclient-fetch -q -T 20 -O - https://$echo_host/ 2>/dev/null | tr -d '\r\n '
                  ip route del $ip dev $iface 2>/dev/null" | tr -d '\r\n ')"
    if [ "$got" = "$want" ]; then
        r_ok "трафик вышел через сервер ($got = адрес VPS)"
        return 0
    fi
    r_bad "внешний адрес «$got» ≠ «$want» — туннель поднят, но трафик через него не идёт"
    return 1
}

# r_pmtu <iface> — крупная загрузка ЧЕРЕЗ туннель. Ловит фрагментацию: главный риск на PPPoE,
# где симптом «мелкие сайты открываются, крупные висят».
r_pmtu() {
    local iface="$1"
    local url="https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/openwrt-25.12.5-x86-64-generic-ext4-combined.img.gz"
    local host="downloads.openwrt.org" ip
    ip="$(r_ssh "nslookup $host 2>/dev/null | awk '/^Address( 1)?: / && \$NF ~ /^[0-9.]+\$/ {print \$NF; exit}'")"
    [ -n "$ip" ] || { r_bad "не разрешился $host"; return 1; }
    local size
    size="$(r_ssh "ip route replace $ip dev $iface 2>/dev/null
        uclient-fetch -q -T 120 -O - '$url' 2>/dev/null | head -c 11000000 | wc -c
        ip route del $ip dev $iface 2>/dev/null" | tr -d '\r\n ')"
    if [ "${size:-0}" -ge 10000000 ]; then
        r_ok "крупная загрузка прошла ($((size / 1000000)) МБ) — PMTU в порядке"
        return 0
    fi
    r_bad "крупная загрузка оборвалась на ${size:-0} байт — похоже на фрагментацию/PMTU"
    return 1
}

# r_finish — закрыть отчёт и напомнить, где он.
r_finish() {
    [ -n "$R_REPORT" ] || return 0
    { echo '```'; echo ""; } >> "$R_REPORT"
    printf '\n\033[1mОтчёт: %s\033[0m\n' "$R_REPORT"
}
