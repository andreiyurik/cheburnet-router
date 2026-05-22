# lib/net-detect.sh — определение LAN-параметров с правильными fallback'ами.
#
# Source-only: ничего не выполняет, только определяет функции. Без shebang.
#
# Подключение:
#   . /opt/cheburnet/lib/net-detect.sh    # на роутере
#   . lib/net-detect.sh                    # из репо-чекаута
#
# Зачем: один и тот же помеченный TODO-костыль `LAN_IP=${LAN_IP%%/*}`
# и каскад «netifd → uci → ipcalc.sh» был размазан по 02-podkop.sh,
# 04-dns.sh, 07-killswitch.sh, setup/install.sh, rpcd-cheburnet, install.sh.
# Если завтра OpenWrt поменяет формат network.lan.ipaddr — править нужно
# было бы в шести местах. Теперь — в одном.

# ─────────────────────────────────────────────────────────────────────────────
# net_lan_ip
# ─────────────────────────────────────────────────────────────────────────────
#
# Возвращает IP-адрес LAN-интерфейса роутера БЕЗ маски.
# Печатает в stdout. Если не получилось — печатает $1 (fallback) или пусто.
#
# OpenWrt 25.12+ хранит network.lan.ipaddr в CIDR-форме (192.168.1.1/24);
# на 23.05/24.10 — без маски (192.168.1.1). Эта функция возвращает чистый
# IP в обоих случаях.
#
# Аргумент: $1 — fallback-значение (опц.), используется если uci не отвечает.
net_lan_ip() {
    _ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
    _ip=${_ip%%/*}
    if [ -z "$_ip" ]; then
        _ip="$1"
    fi
    printf '%s' "$_ip"
    unset _ip
}

# ─────────────────────────────────────────────────────────────────────────────
# net_lan_cidr
# ─────────────────────────────────────────────────────────────────────────────
#
# Возвращает LAN-подсеть в CIDR-форме (например 192.168.1.0/24).
# Печатает в stdout. Если определить не удалось — печатает пустую строку
# и возвращает exit code 1, чтобы вызывающий мог отличить «всё ок» от фейла.
#
# Каскад источников:
#   1. /lib/functions/network.sh → network_get_subnet (штатный helper netifd)
#   2. uci network.lan.ipaddr + netmask → ipcalc.sh (для старых сборок без
#      network.sh или когда netifd ещё не поднял интерфейс)
#
# Не хардкодим 192.168.1.0/24: на нестандартных подсетях (10.0.0.0/24,
# 192.168.10.0/24) хардкод приводит к молчаливо неправильным fw-правилам
# и тихо-дырявому kill-switch.
net_lan_cidr() {
    _cidr=""

    if [ -f /lib/functions/network.sh ]; then
        # shellcheck disable=SC1091
        . /lib/functions/network.sh
        network_flush_cache
        network_get_subnet _cidr lan 2>/dev/null || true
    fi

    if [ -z "$_cidr" ]; then
        _raw=$(uci -q get network.lan.ipaddr 2>/dev/null)
        case "$_raw" in
            */*) _cidr="$_raw" ;;
            ?*)
                # Legacy-формат '192.168.1.1' + отдельный netmask.
                _mask=$(uci -q get network.lan.netmask 2>/dev/null || echo "255.255.255.0")
                if command -v ipcalc.sh >/dev/null 2>&1; then
                    _cidr=$(ipcalc.sh "$_raw" "$_mask" 2>/dev/null \
                        | awk -F= '/^NETWORK/{n=$2} /^PREFIX/{p=$2} END{if(n && p) print n"/"p}')
                fi
                unset _mask
                ;;
        esac
        unset _raw
    fi

    # Нормализация host-bits → network address. На OpenWrt 25.12 netifd из
    # `network_get_subnet lan` возвращает «192.168.1.1/24» (IP/prefix), а не
    # «192.168.1.0/24». nft сам нормализует маску при insert, но в подkop
    # `fully_routed_ips` уходит как есть, и в sing-box route-rule оседает
    # с host-битами. Sing-box CIDR парсит корректно, но для дебага и
    # совпадения с эталонным UCI держим network-форму. Pass-through если
    # _cidr уже в network-форме (на legacy-пути awk уже взял NETWORK).
    if [ -n "$_cidr" ] && command -v ipcalc.sh >/dev/null 2>&1; then
        _norm=$(ipcalc.sh "$_cidr" 2>/dev/null \
            | awk -F= '/^NETWORK/{n=$2} /^PREFIX/{p=$2} END{if(n && p) print n"/"p}')
        [ -n "$_norm" ] && _cidr="$_norm"
        unset _norm
    fi

    if [ -z "$_cidr" ]; then
        unset _cidr
        return 1
    fi

    printf '%s' "$_cidr"
    unset _cidr
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# net_detect_lan_conflict
# ─────────────────────────────────────────────────────────────────────────────
#
# Детектит ситуацию «LAN и WAN роутера в одной /24-подсети». Это типичный
# сценарий каскада: главный роутер (Keenetic, Mi Router, и т.п.) выдаёт нашему
# OpenWrt-роутеру WAN IP 192.168.1.X через DHCP, а наш LAN сам по умолчанию
# на 192.168.1.1/24. Итог: две сетевых интерфейса в одной подсети, ядро
# не знает куда слать пакеты для 192.168.1.x, LAN-клиенты не выходят в инет.
#
# Поведение:
#   return 0, ничего не печатает  — конфликта НЕТ, или нельзя определить
#                                    (WAN не поднят / нет ubus / нет uci).
#                                    Caller считает «всё ок, продолжаем».
#   return 1, печатает 3 слова    — конфликт ЕСТЬ:
#       "<WAN_IP> <LAN_IP> <SUGGESTED_NEW_LAN_IP>"
#
# Способ детекта:
#   1. WAN IP читаем через ubus call network.interface.wan status + jsonfilter.
#      Это правильный способ для OpenWrt 25.12 — корректно работает на DSA,
#      PPPoE, dhcp/dhcpv6 mix-bridges. Альтернатива через `uci get network.wan.device`
#      + `ip addr` ломается на нестандартных device-name'ах и dynamic-named
#      интерфейсах.
#   2. LAN IP — uci network.lan.ipaddr (тут просто, формат стабилен).
#   3. Сравниваем первые 3 октета (/24-префикс). Подавляющее большинство
#      домашних SOHO-роутеров живут в /24 — этого критерия хватает для 99%
#      случаев. /23, /22, /16-подсети у домашних провайдеров встречаются
#      крайне редко; для них юзер увидит ложно-положительный конфликт
#      только если родительский роутер в той же /24 — что само по себе уже
#      проблема, так что детектор всё равно сработает к месту.
#
# Подбор нового LAN-IP:
#   Перебираем 192.168.{2,3,4,8,9,10,11}.1. Эти октеты традиционно свободные
#   в SOHO; 5/6/7 чаще встречаются как корпоративные/гостевые сегменты,
#   поэтому пропущены. Берём первый, не конфликтующий с WAN-префиксом.
#   Если ВСЕ варианты совпали с WAN — return 0 (не пытаемся уйти за пределы
#   192.168.x, чтобы не сломать DHCP-pool в подkop/dnsmasq, которые по
#   умолчанию выдают в этой подсети).
net_detect_lan_conflict() {
    # WAN IP. Если ubus или jsonfilter недоступны — пропускаем (WAN ещё не
    # поднят, проверять нечего). Никогда не валим caller'а из-за infra-причин.
    _wan_ip=$(ubus call network.interface.wan status 2>/dev/null \
              | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    [ -n "$_wan_ip" ] || { unset _wan_ip; return 0; }

    _lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
    _lan_ip=${_lan_ip%%/*}    # на 25.12+ ipaddr хранится в CIDR-форме
    [ -n "$_lan_ip" ] || { unset _wan_ip _lan_ip; return 0; }

    _wan_pfx=$(echo "$_wan_ip" | cut -d. -f1-3)
    _lan_pfx=$(echo "$_lan_ip" | cut -d. -f1-3)
    if [ "$_wan_pfx" != "$_lan_pfx" ]; then
        unset _wan_ip _lan_ip _wan_pfx _lan_pfx
        return 0
    fi

    # Конфликт. Подбираем замену.
    for _try in 2 3 4 8 9 10 11; do
        if [ "192.168.${_try}" != "$_wan_pfx" ]; then
            echo "$_wan_ip $_lan_ip 192.168.${_try}.1"
            unset _wan_ip _lan_ip _wan_pfx _lan_pfx _try
            return 1
        fi
    done

    # Невозможно на практике (7 кандидатов, WAN занимает максимум 1 октет),
    # но на всякий случай — не возвращаем ничего, caller увидит «нет конфликта».
    unset _wan_ip _lan_ip _wan_pfx _lan_pfx _try
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# net_apply_new_lan_ip <new_ip>
# ─────────────────────────────────────────────────────────────────────────────
#
# Меняет LAN-IP роутера на $1 и инициирует отложенный (через 3 сек) рестарт
# сети. Возвращается СРАЗУ — чтобы вызвавший RPC/SSH успел отдать ответ
# клиенту и закрыть сессию до того, как network restart уронит соединение.
#
# Что НЕ трогаем:
#   • DHCP-pool — в OpenWrt он наследуется от LAN-интерфейса автоматически
#     (start/limit относительны), менять отдельно не нужно.
#   • netmask — оставляем /24 (LAN.ipaddr на 25.12 хранится с маской,
#     uci set перезатирает только host-part).
#   • firewall-зоны — br-lan остаётся в LAN-зоне, никаких правил не задето.
#
# Почему setsid + sleep 3 + background:
#   • setsid отвязывает фоновый процесс от controlling terminal (rpcd/ssh).
#     Без этого SIGHUP при закрытии сессии убивает наш restart до того,
#     как он успеет применить новый IP. Та же техника используется в
#     install_start (rpcd-cheburnet) и factory_reset.
#   • sleep 3 даёт caller'у время отдать ответ. Без этого RPC возвращает
#     {"status":"applied"}, но HTTP-ответ ещё в TCP-буфере, и network
#     restart рвёт его до того, как браузер получил тело.
#   • Перенаправления </dev/null >/dev/null 2>&1 нужны setsid'у —
#     без них на busybox-OpenWrt процесс может зависнуть на FD
#     контроль-сессии (наблюдалось при тестах replace_awg_conf).
net_apply_new_lan_ip() {
    _new_ip="$1"
    if [ -z "$_new_ip" ]; then
        echo "net_apply_new_lan_ip: ip argument required" >&2
        unset _new_ip
        return 1
    fi
    uci set network.lan.ipaddr="$_new_ip"
    uci commit network
    setsid sh -c 'sleep 3; /etc/init.d/network restart' \
        </dev/null >/dev/null 2>&1 &
    unset _new_ip
    return 0
}
