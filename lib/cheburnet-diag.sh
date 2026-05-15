# lib/cheburnet-diag.sh — диагностические дампы для setup-скриптов.
#
# Source-only: ничего не выполняет, только определяет функции. Без shebang.
#
# Подключение:
#   . /opt/cheburnet/lib/cheburnet-diag.sh    # на роутере
#   . lib/cheburnet-diag.sh                    # из репо-чекаута / тестов
#
# Принцип: одно из двух —
#   (а) cheburnet_diag_system печатается ОДИН раз в начале установки в stdout
#       (системный «паспорт», нужен в каждом отчёте об ошибке);
#   (б) cheburnet_diag_network / cheburnet_diag_runtime вызываются ТОЛЬКО
#       на ветке фейла и пишут в stderr, чтобы не раздувать успешный лог.
#
# Цель — собрать всё, что нужно для удалённого разбора, в один дамп: юзер
# присылает лог установки, и мы сразу видим причину, без переписки
# «пришлите вывод X / Y / Z».

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_diag_network
# ─────────────────────────────────────────────────────────────────────────────
#
# Дампит состояние сетевого стека OpenWrt: UCI-конфиг сети, runtime-state
# netifd, default route, список L2-устройств, последние сообщения netifd.
# Используется setup-скриптами, которые завязаны на резолвинг WAN/LAN
# (например, 07-killswitch.sh при `network_get_device WAN_DEV wan` = пусто).
#
# Аргументы: нет.
# Вывод: stderr (попадает в install.log → видно в веб-логе и в саппорт-ссылке).
cheburnet_diag_network() {
    {
        echo ""
        echo "========== ДИАГНОСТИКА СЕТИ =========="

        echo "--- uci show network (interfaces & devices) ---"
        uci show network 2>/dev/null \
            | grep -E "\.(interface|device)|\.proto=|\.device=|\.ipaddr=|\.netmask=|\.name=" \
            || echo "(uci show network failed)"

        echo "--- ubus call network.interface dump (краткий) ---"
        if command -v ubus >/dev/null 2>&1; then
            ubus call network.interface dump 2>/dev/null \
                | jsonfilter -e '@.interface[*]["interface","up","l3_device","device","proto"]' 2>/dev/null \
                || ubus call network.interface dump 2>/dev/null | head -80 \
                || echo "(ubus call failed)"
        else
            echo "(ubus не найден)"
        fi

        echo "--- ip -4 route show default ---"
        ip -4 route show default 2>/dev/null || echo "(нет default route или ip недоступен)"

        echo "--- /sys/class/net (L2-устройства) ---"
        ls /sys/class/net/ 2>/dev/null | tr '\n' ' '
        echo ""

        echo "--- logread netifd (последние 20 строк) ---"
        if command -v logread >/dev/null 2>&1; then
            logread -e netifd 2>/dev/null | tail -20 || echo "(logread netifd пуст)"
        else
            echo "(logread не найден)"
        fi

        echo "========== /ДИАГНОСТИКА =========="
        echo ""
    } >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_diag_system
# ─────────────────────────────────────────────────────────────────────────────
#
# «Паспорт» железа: версия OpenWrt, board, архитектура, RAM, свободное место
# на rootfs/overlay/tmp. Печатается ОДИН раз в начале установки в stdout —
# это базовый контекст, без которого нельзя интерпретировать ни одну ошибку
# («у юзера 64 МБ flash — adblock не поместится», «mips — нет awg-kmod», и т.п.).
#
# Аргументы: нет.
# Вывод: stdout (попадает в install.log на штатной установке тоже — это норма,
# мы хотим этот блок видеть в любом отчёте, а не только при ошибке).
cheburnet_diag_system() {
    echo "----- системный паспорт -----"

    # OpenWrt релиз / target / arch — критично для подбора пакетов awg-openwrt.
    if [ -r /etc/openwrt_release ]; then
        grep -E '^DISTRIB_(RELEASE|TARGET|ARCH|REVISION)=' /etc/openwrt_release \
            | sed 's/^/  /'
    else
        echo "  (нет /etc/openwrt_release)"
    fi

    # Board model — человекочитаемое имя для саппорта.
    if [ -r /tmp/sysinfo/model ]; then
        echo "  BOARD_MODEL=\"$(cat /tmp/sysinfo/model)\""
    elif [ -r /tmp/sysinfo/board_name ]; then
        echo "  BOARD_NAME=\"$(cat /tmp/sysinfo/board_name)\""
    fi

    echo "  KERNEL=\"$(uname -srm 2>/dev/null || echo unknown)\""

    # RAM — берём из /proc/meminfo, а не free, чтобы не зависеть от busybox-конфига.
    if [ -r /proc/meminfo ]; then
        awk '/^MemTotal|^MemAvailable/ {printf "  %s %s %s\n", $1, $2, $3}' /proc/meminfo
    fi

    # Свободное место. Overlay — куда apk ставит пакеты, важнее всего.
    # tmpfs ('/tmp') нужен для скачивания apk-файлов; забит — install падает.
    echo "  --- df ---"
    df -h / /overlay /tmp 2>/dev/null | sed 's/^/  /' || echo "  (df failed)"

    echo "----- /паспорт -----"
}

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_diag_runtime
# ─────────────────────────────────────────────────────────────────────────────
#
# Компактный снимок системы в момент падения шага. Намеренно короткий
# (~12 строк): фронтенд показывает только последние 12 КБ лога, и большой
# дамп выталкивал бы из видимости саму причину ошибки. Здесь только то,
# что нельзя получить из системного паспорта (он напечатан в начале):
#   • MemAvailable — изменился с момента старта = сигнал об OOM или утечке;
#   • последние error/warn/fail из dmesg и logread — ловят OOM-killer,
#     kernel warnings, отказы apk/wget/modprobe.
# Полные дампы dmesg/logread юзер пришлёт по запросу в Telegram, если
# понадобится — они большие и в 99% случаев не нужны.
#
# Аргументы: нет.
# Вывод: stderr (только на ветке фейла).
# Печатает «релевантный» хвост вывода из команды $1 (dmesg / logread):
# сначала пытается grep'нуть error|warn|fail|oom|killed (последние 5), если
# пусто — даёт последние 5 строк как fallback (хоть какой контекст).
_cheburnet_diag_tail() {
    command -v "$1" >/dev/null 2>&1 || return 0
    _diag_lines=$("$1" 2>/dev/null | grep -iE 'error|warn|fail|oom|killed' | tail -5)
    [ -z "$_diag_lines" ] && _diag_lines=$("$1" 2>/dev/null | tail -5)
    if [ -n "$_diag_lines" ]; then
        echo "  --- $1 (релевантное / последнее) ---"
        printf '%s\n' "$_diag_lines" | sed 's/^/    /'
    fi
    unset _diag_lines
}

cheburnet_diag_runtime() {
    {
        echo ""
        echo "----- снимок при ошибке -----"

        if [ -r /proc/meminfo ]; then
            awk '/^MemAvailable/ {printf "  %s %s %s\n", $1, $2, $3}' /proc/meminfo
        fi

        _cheburnet_diag_tail dmesg
        _cheburnet_diag_tail logread

        echo "----- /снимок -----"
        echo ""
    } >&2
}
