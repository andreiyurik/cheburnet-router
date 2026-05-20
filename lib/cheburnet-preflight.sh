# lib/cheburnet-preflight.sh — жёсткие preflight-проверки совместимости железа.
#
# Source-only, без shebang. Подключение:
#   . /opt/cheburnet/lib/cheburnet-preflight.sh
#
# Принцип: каждая функция — отдельная проверка. Печатает большой баннер в stdout
# на провале (попадает в install.log и видно во веб-консоли), возвращает 1.
# Вызов сверху (setup/install.sh) при provale пишет fail-preflight-<reason>
# в $DONE и делает exit 1.
#
# Пороговые значения сознательно мягче минимумов из README — мы хотим отсекать
# заведомо мёртвые конфигурации (16 МБ flash, 128 МБ RAM), а не балансировать
# на грани. README остаётся источником правды для рекомендаций пользователю.

# ─────────────────────────────────────────────────────────────────────────────
# Внутренний хелпер: большой баннер «РОУТЕР НЕ ПОДХОДИТ».
# Печатает шапку и подвал с моделями; в середину вставляется текст конкретной
# причины (передаётся как stdin).
#
# Использование:
#   {
#       echo "Свободно на /overlay: 5 МБ"
#       echo "Требуется минимум: 30 МБ"
#   } | _preflight_banner_unsupported "НЕ ХВАТАЕТ FLASH-ПАМЯТИ"
#
# Намеренно без box-рамки (║…║): busybox printf считает ширину в БАЙТАХ,
# а кириллица в UTF-8 — 2 байта/символ, поэтому %.56s обрезает посреди буквы
# и рамка съезжает. Простые горизонтальные линии устойчивы к любому контенту.
# ─────────────────────────────────────────────────────────────────────────────
_preflight_banner_unsupported() {
    _reason="$1"
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "  ❌ РОУТЕР НЕ ПОДХОДИТ ДЛЯ CHEBURNET-ROUTER"
    echo ""
    echo "  ${_reason}"
    echo ""
    while IFS= read -r _line; do
        echo "    ${_line}"
    done
    echo ""
    echo "  ПРОВЕРЕННЫЕ МОДЕЛИ (подробности в README):"
    echo "    • Cudy TR3000 v1 ⭐  — travel-форм-фактор"
    echo "    • Cudy WR3000P v1   — стационарный 4×GbE + 2.5 GbE WAN"
    echo "    • Cudy AP3000 v1    — больше flash для overlay"
    echo "    • GL.iNet Beryl AX  — мощное железо, кулер"
    echo ""
    echo "  Минимум: OpenWrt 25.12+, 256 МБ RAM, 64 МБ flash."
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo ""
    unset _reason _line
}

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_preflight_flash — проверяет, что на /overlay (там, куда apk ставит
# пакеты) есть минимум 30 МБ свободного места. Это с запасом покрывает 16/32 МБ
# роутеры (~5–15 МБ свободно), и пропускает 64 МБ-и-выше (~50+ МБ свободно).
#
# Возвращает 1 + печатает баннер, если не хватает места. Иначе echo на stdout
# короткую строку с фактом и return 0.
# ─────────────────────────────────────────────────────────────────────────────
cheburnet_preflight_flash() {
    _target="/overlay"
    [ -d "$_target" ] || _target="/"

    _avail_kb=$(df -P "$_target" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$_avail_kb" ]; then
        echo "⚠ не удалось определить свободное место на $_target — пропускаю проверку"
        unset _target _avail_kb
        return 0
    fi

    _avail_mb=$((_avail_kb / 1024))
    echo "  свободно на $_target: ${_avail_mb} МБ"

    if [ "$_avail_mb" -lt 30 ]; then
        {
            echo "На вашем роутере свободно ${_avail_mb} МБ"
            echo "на /overlay — это flash-память, куда apk ставит"
            echo "пакеты. Подкоп один требует 15 МБ; вместе с"
            echo "AmneziaWG и adblock-lean нужно ~30+ МБ."
            echo ""
            echo "Скорее всего у роутера всего 16 МБ flash —"
            echo "программно это не обойти."
            echo ""
            echo "ЧТО МОЖНО СДЕЛАТЬ:"
            echo "  Есть альтернативный гайд — VPN + split-"
            echo "  routing без подкопа на штатных OpenWrt-"
            echo "  пакетах (dnsmasq + pbr, ~300 КБ):"
            echo "    docs/router-too-small.md"
        } | _preflight_banner_unsupported "НЕ ХВАТАЕТ FLASH-ПАМЯТИ"
        unset _target _avail_kb _avail_mb
        return 1
    fi
    unset _target _avail_kb _avail_mb
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_preflight_ram — проверяет MemTotal ≥ 200 МБ. Это отсекает
# 128 МБ-физических роутеров (MemTotal ~115 МБ), пропускает 256 МБ
# (MemTotal ~235 МБ) и выше. MemTotal стабилен (в отличие от MemAvailable),
# можно безопасно сверять с порогом.
# ─────────────────────────────────────────────────────────────────────────────
cheburnet_preflight_ram() {
    if [ ! -r /proc/meminfo ]; then
        echo "⚠ нет /proc/meminfo — пропускаю проверку RAM"
        return 0
    fi

    _total_kb=$(awk '/^MemTotal/ {print $2; exit}' /proc/meminfo)
    [ -n "$_total_kb" ] || { echo "⚠ не удалось прочитать MemTotal"; return 0; }

    _total_mb=$((_total_kb / 1024))
    echo "  MemTotal: ${_total_mb} МБ"

    if [ "$_total_mb" -lt 200 ]; then
        {
            echo "У роутера ${_total_mb} МБ RAM (MemTotal)."
            echo "Минимум для подкопа + sing-box + adblock —"
            echo "256 МБ физических (~235 МБ MemTotal)."
            echo ""
            echo "На 128 МБ-моделях sing-box или dnsmasq будут"
            echo "падать по OOM-killer'у при первой нагрузке."
            echo "Это аппаратное ограничение."
        } | _preflight_banner_unsupported "НЕ ХВАТАЕТ RAM"
        unset _total_kb _total_mb
        return 1
    fi
    unset _total_kb _total_mb
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_preflight_internet — ждёт до 60 сек готовности интернета
# (DNS-резолв + ping). Без этого все последующие шаги падают на apk update.
# Логика идентична wait-loop'у в 01-amneziawg.sh, но вынесена сюда, чтобы
# отказать на 15-й секунде, а не через 30 секунд работы 01-го шага.
# ─────────────────────────────────────────────────────────────────────────────
cheburnet_preflight_internet() {
    for _w in 1 2 3 4 5 6 7 8 9 10 11 12; do
        # Двойной критерий «интернет есть»: nameserver в resolv.conf
        # И (ICMP-ping ИЛИ HTTP-spider). Один ping недостаточен — некоторые
        # сети (qemu user-mode netdev, корпоративные wifi, некоторые мобильные
        # APN) режут ICMP, но прекрасно пропускают HTTP. wget-spider к стабильному
        # OpenWrt-зеркалу — тот же канал, по которому пойдёт apk update дальше,
        # поэтому проверяет ровно то, что нам нужно.
        if grep -q '^nameserver' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null \
           && { ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 \
                || wget -q --spider --timeout=5 http://downloads.openwrt.org/ 2>/dev/null; }; then
            echo "  интернет: есть"
            unset _w
            return 0
        fi
        echo "  ожидание сети... (${_w}/12, по 5 сек)"
        sleep 5
    done
    {
        echo "За 60 секунд не получили ни ICMP-эха на 8.8.8.8,"
        echo "ни HTTP-ответа от downloads.openwrt.org —"
        echo "и/или нет nameserver в /tmp/resolv.conf.d/."
        echo ""
        echo "Возможные причины:"
        echo "  • WAN-кабель не подключён или провайдер не дал DHCP"
        echo "  • IPv6-only WAN без IPv4 (часть apk-зеркал требует IPv4)"
        echo "  • DNS-серверы не отвечают"
        echo ""
        echo "Это НЕ аппаратное ограничение роутера —"
        echo "почините связь и запустите установку повторно."
    } | _preflight_banner_unsupported "НЕТ ДОСТУПА В ИНТЕРНЕТ"
    unset _w
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_preflight_lan_conflict — safety net против конфликта LAN/WAN
# подсетей (типичный сценарий каскада: главный роутер 192.168.1.X выдаёт нам
# WAN в той же подсети, где у нас LAN).
#
# ВАЖНО про роль этой проверки:
#   Реальный фикс конфликта делается ДО запуска install.sh — в setup.sh (CLI)
#   и в web wizard (welcome-экран → check_lan_conflict RPC). Там мы можем
#   корректно прервать сетевое соединение, проинструктировать пользователя
#   переподключить кабель/Wi-Fi, и продолжить по новому адресу.
#
#   А здесь, посреди install.sh, чинить конфликт НЕЛЬЗЯ: rrwrap network restart
#   мид-install оборвёт ssh-сессию пользователя и/или браузер-страницу веб-
#   мастера, и оба клиента окажутся в неопределённом состоянии (страница на
#   старом IP, маршрута на новый нет, ничего не понятно).
#
# Поэтому здесь — только ДЕТЕКТ + ПОНЯТНАЯ ОШИБКА с инструкцией ручного фикса.
# Срабатывает в редком случае: WAN получил DHCP-аренду уже ПОСЛЕ старта
# install.sh (на момент pre-check WAN ещё не был готов). Это бывает на
# медленных uplink-провайдерах или сразу после reboot.
#
# Требует net_detect_lan_conflict из lib/net-detect.sh (caller обязан
# подсорсить его до preflight-цепочки).
# ─────────────────────────────────────────────────────────────────────────────
cheburnet_preflight_lan_conflict() {
    if ! command -v net_detect_lan_conflict >/dev/null 2>&1; then
        echo "⚠ net_detect_lan_conflict недоступна — пропускаю проверку LAN/WAN-конфликта"
        return 0
    fi

    if _info=$(net_detect_lan_conflict); then
        # net_detect_lan_conflict возвращает 0 = «нет конфликта или нельзя определить»
        return 0
    fi

    # Конфликт. _info = "WAN_IP LAN_IP SUGGEST_IP"
    # shellcheck disable=SC2086  # сознательная word-split для разбора 3 токенов
    set -- $_info
    _wan_ip="$1"
    _lan_ip="$2"
    _suggest_ip="$3"
    {
        echo "WAN-интерфейс роутера получил IP ${_wan_ip},"
        echo "а LAN — ${_lan_ip}. Они в одной /24-подсети,"
        echo "роутер не сможет корректно маршрутизировать трафик:"
        echo "ядро не знает, через какой интерфейс слать пакеты."
        echo ""
        echo "Обычно мастер ловит этот конфликт ДО запуска установки —"
        echo "значит WAN получил адрес уже после старта install.sh."
        echo ""
        echo "ЧТО ДЕЛАТЬ ВРУЧНУЮ:"
        echo "  1. На роутере (через SSH):"
        echo "       uci set network.lan.ipaddr=${_suggest_ip}"
        echo "       uci commit network"
        echo "       /etc/init.d/network restart"
        echo "  2. Переподключить кабель/Wi-Fi на компьютере (для нового IP)."
        echo "  3. Запустить установку повторно — теперь по адресу:"
        echo "       http://${_suggest_ip}/cheburnet/   (веб)"
        echo "       ./setup.sh                          (CLI, ответьте ${_suggest_ip} на «Адрес роутера»)"
    } | _preflight_banner_unsupported "КОНФЛИКТ ПОДСЕТЕЙ LAN И WAN"
    unset _info _wan_ip _lan_ip _suggest_ip
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_preflight_arch — проверяет, что есть совместимый релиз
# awg-openwrt для этой архитектуры/версии OpenWrt. Делает это раз в самом
# начале (а не в шаге 01), чтобы юзер с экзотической архитектурой получил
# понятный отказ за 10 сек, а не после успешной установки prerequisites.
#
# Требует, чтобы lib/cheburnet-utils.sh был уже подключён (для awg_pick_version).
# ─────────────────────────────────────────────────────────────────────────────
cheburnet_preflight_arch() {
    if ! command -v awg_pick_version >/dev/null 2>&1; then
        echo "⚠ awg_pick_version недоступна — пропускаю проверку архитектуры"
        return 0
    fi

    # Читаем DISTRIB_* В SUBSHELL — чтобы они не утекли в окружение caller'а
    # (setup/install.sh + все дочерние setup-шаги). Без subshell первый source
    # экспортирует их неявно, и потом любой setup-шаг видит «откуда-то взявшиеся»
    # переменные, что путает диагностику и ломает тесты, которые ожидают
    # чистое окружение.
    # shellcheck disable=SC1091
    _release=$( . /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_RELEASE" )
    _arch_raw=$( . /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_ARCH" )
    _target_raw=$( . /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_TARGET" )
    if [ -z "$_release" ] || [ -z "$_arch_raw" ] || [ -z "$_target_raw" ]; then
        echo "⚠ /etc/openwrt_release неполный — пропускаю проверку архитектуры"
        unset _release _arch_raw _target_raw
        return 0
    fi

    _arch="${_arch_raw}_$(echo "$_target_raw" | tr '/' '_')"
    echo "  arch=${_arch}, openwrt=${_release}"

    if awg_pick_version "$_release" "$_arch" >/dev/null; then
        unset _release _arch _arch_raw _target_raw
        return 0
    fi

    {
        echo "Для архитектуры ${_arch}"
        echo "и OpenWrt ${_release} нет готового релиза"
        echo "awg-openwrt — kmod-amneziawg не на чем поставить."
        echo ""
        echo "Это бывает на свежих snapshot-сборках OpenWrt"
        echo "(kmod собран под другое ядро) или на редких"
        echo "архитектурах. Доступные релизы:"
        echo "  github.com/Slava-Shchipunov/awg-openwrt/releases"
    } | _preflight_banner_unsupported "НЕТ ПАКЕТА AMNEZIAWG ДЛЯ ЭТОГО РОУТЕРА"
    unset _release _arch _arch_raw _target_raw
    return 1
}
