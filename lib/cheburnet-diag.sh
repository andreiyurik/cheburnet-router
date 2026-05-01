# lib/cheburnet-diag.sh — диагностические дампы для setup-скриптов.
#
# Source-only: ничего не выполняет, только определяет функции. Без shebang.
#
# Подключение:
#   . /opt/cheburnet/lib/cheburnet-diag.sh    # на роутере
#   . lib/cheburnet-diag.sh                    # из репо-чекаута / тестов
#
# Принцип: вся диагностика пишет в stderr и вызывается ТОЛЬКО на ветке фейла,
# чтобы не раздувать install.log при штатной установке. Цель — собрать всё,
# что нужно для удалённого разбора, в один дамп: юзер присылает лог установки,
# и мы сразу видим причину, без переписки «пришлите вывод X / Y / Z».

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
