# lib/podkop-config.sh — UCI-конфигурация podkop в одном месте.
#
# Source-only: ничего не выполняет, только определяет функции. Без shebang.
#
# Подключение:
#   . /opt/cheburnet/lib/podkop-config.sh    # на роутере (vpn-mode CLI, setup-шаг)
#   . lib/podkop-config.sh                    # из репо-чекаута
#
# Зачем: HOME/TRAVEL-режимы пишет setup/02-podkop.sh (одноразово, при установке)
# И scripts/vpn-mode (рантайм, при переключении кнопкой/командой). Раньше
# обе стороны держали свою копию `uci set podkop.exclude_ru.*` — каждое
# изменение требовало правки в двух местах. Один из таких рассинхронов
# (отсутствие user_domain_list_type='dynamic' в main) ломал HOME-режим
# в проде неделю.
#
# Все функции делают `uci commit podkop` сами — вызывающему коду остаётся
# только дёрнуть `/etc/init.d/podkop reload`.

# ─────────────────────────────────────────────────────────────────────────────
# podkop_apply_main_section
# ─────────────────────────────────────────────────────────────────────────────
#
# Настраивает секцию podkop.main: «всё через AmneziaWG (awg0)».
# Аргумент: $1 — LAN CIDR (например 192.168.1.0/24) для fully_routed_ips.
#           Если пусто — fully_routed_ips не выставляется.
#
# user_domain_list_type='dynamic' критичен: без него (и без community_lists)
# подkop логирует "Section 'main' does not have any enabled list, skipping"
# и секция main не применяется → весь HOME-режим становится бесполезным.
podkop_apply_main_section() {
    _lan_cidr="$1"

    uci set podkop.main.connection_type='vpn'
    uci set podkop.main.interface='awg0'
    uci set podkop.main.user_domain_list_type='dynamic'
    uci -q delete podkop.main.community_lists 2>/dev/null || true
    uci -q delete podkop.main.proxy_config_type 2>/dev/null || true
    uci -q delete podkop.main.proxy_string 2>/dev/null || true
    uci -q delete podkop.main.fully_routed_ips 2>/dev/null || true
    [ -n "$_lan_cidr" ] && uci add_list podkop.main.fully_routed_ips="$_lan_cidr"

    uci commit podkop
    unset _lan_cidr
}

# ─────────────────────────────────────────────────────────────────────────────
# podkop_apply_home
# ─────────────────────────────────────────────────────────────────────────────
#
# HOME-режим: .ru/.su/.рф/vk напрямую, остальное через VPN.
# Создаёт/обновляет секцию podkop.exclude_ru. main НЕ трогает (для HOME
# main уже должен быть настроен через podkop_apply_main_section в шаге 02).
podkop_apply_home() {
    uci set podkop.exclude_ru=section
    uci set podkop.exclude_ru.connection_type='exclusion'
    uci set podkop.exclude_ru.user_domain_list_type='dynamic'
    uci -q delete podkop.exclude_ru.community_lists 2>/dev/null || true
    uci add_list podkop.exclude_ru.community_lists='russia_outside'
    uci -q delete podkop.exclude_ru.user_domains 2>/dev/null || true
    uci add_list podkop.exclude_ru.user_domains='.ru'
    uci add_list podkop.exclude_ru.user_domains='.su'
    uci add_list podkop.exclude_ru.user_domains='.xn--p1ai'
    uci add_list podkop.exclude_ru.user_domains='vk.com'
    uci commit podkop
}

# ─────────────────────────────────────────────────────────────────────────────
# podkop_apply_travel
# ─────────────────────────────────────────────────────────────────────────────
#
# TRAVEL-режим: full tunnel — весь трафик через VPN, без исключений.
# Чистит exclude_ru (user_domains, community_lists, user_domain_list_type).
# Саму секцию не удаляем, чтобы при возврате в HOME её можно было заново
# наполнить через podkop_apply_home без add_section.
podkop_apply_travel() {
    uci -q delete podkop.exclude_ru.community_lists 2>/dev/null || true
    uci -q delete podkop.exclude_ru.user_domains 2>/dev/null || true
    uci -q delete podkop.exclude_ru.user_domain_list_type 2>/dev/null || true
    uci commit podkop
}
