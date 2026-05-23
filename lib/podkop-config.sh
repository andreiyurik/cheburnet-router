# lib/podkop-config.sh — UCI-конфигурация podkop в одном месте.
#
# Source-only: ничего не выполняет, только определяет функции. Без shebang.
#
# Подключение:
#   . /opt/cheburnet/lib/podkop-config.sh    # на роутере (vpn-mode CLI, setup-шаг)
#   . lib/podkop-config.sh                    # из репо-чекаута
#
# Контракт со «своей» территорией: cheburnet трогает в podkop.* строго 5 полей —
#   • podkop.main.user_domain_list_type='dynamic'          (ensure_main_invariants)
#   • podkop.settings.source_network_interfaces ⊇ 'br-lan' (ensure_main_invariants)
#   • podkop.exclude_ru.enabled = '0' | '1'                (apply_home/apply_travel)
#   • podkop.exclude_ru.user_domains MERGE наших defaults  (apply_home — только если их нет)
#   • podkop.main.* (interface, fully_routed_ips, connection_type) — ТОЛЬКО при первой
#     установке (apply_main_section, вызывается из setup/02-podkop.sh).
# Всё остальное в podkop.* — юзерская территория (LuCI / CLI / UCI), наша панель
# и vpn-mode CLI её не вмешиваются. Подробно — docs/03-podkop-routing.md.
#
# Зачем такой контракт. Раньше apply_home делал `uci delete user_domains`+полный
# `uci set exclude_ru=section` (юзерские .kz/kinopoisk.ru/admin терялись на каждое
# переключение режима), а apply_travel — `uci delete podkop.exclude_ru` (вся секция
# с кастомными community_lists исчезала, и при возврате в HOME мы пересоздавали её
# с нашим minimal-набором). Цикл HOME ⇄ TRAVEL ⇄ HOME через web-кнопку стирал
# у продвинутого юзера всё, что он добавил через LuCI. Теперь — режим = enabled-флаг,
# наши defaults доливаются через merge, юзерское не трогается.
#
# Все мутирующие функции делают `uci commit podkop` сами — вызывающему коду остаётся
# только дёрнуть `/etc/init.d/podkop reload`. Функции, меняющие domain routing
# (apply_home, apply_travel, restore_exclude_ru), дополнительно зовут
# podkop_invalidate_fakeip_cache — без него sing-box после рестарта подтянул бы
# старые fakeip→domain мапинги и продолжал бы маршрутизировать переехавшие
# домены по предыдущим правилам.

# ─────────────────────────────────────────────────────────────────────────────
# podkop_invalidate_fakeip_cache
# ─────────────────────────────────────────────────────────────────────────────
#
# Удаляет persistent fakeip-кэш sing-box.
#
# Зачем. sing-box хранит fakeip→domain мапинги в cache.db и переживает с ним
# restart. Если мы поменяли routing-правила (добавили домен в exclude_ru,
# переключили HOME⇄TRAVEL) и дёрнули `podkop reload` — sing-box поднимет
# старые fakeip-мапинги для уже-известных доменов и продолжит маршрутизировать
# их по СТАРЫМ правилам, пока кэш сам не протухнет. Реальный кейс из 2026-05:
# добавил yastatic.net в exclude_ru → reload → трафик всё равно через VPN,
# 20 мин дебага пока не догадался про этот файл.
#
# Безопасность. cache.db — это только perf-кэш, sing-box пересоздаёт его за
# несколько DNS-запросов. Не трогает routing-правила, nftables, awg, UCI.
# Уже работающий sing-box продолжает работать (cache читается только при
# старте процесса); файл удаляется ДО `podkop reload`, который тут же его
# пере-инициализирует.
#
# Путь переопределяется через PODKOP_SINGBOX_CACHE_DB — нужно для тестов
# (sandbox пишет в свой tmpdir вместо реального /tmp).
podkop_invalidate_fakeip_cache() {
    rm -f "${PODKOP_SINGBOX_CACHE_DB:-/tmp/sing-box/cache.db}"
}

# ─────────────────────────────────────────────────────────────────────────────
# podkop_ensure_main_invariants
# ─────────────────────────────────────────────────────────────────────────────
#
# Self-healing для двух инвариантов, которые легко сломать через LuCI и которые
# при поломке убивают весь VPN-стек:
#   1) podkop.main.user_domain_list_type='dynamic' — без него подkop логирует
#      "Section 'main' does not have any enabled list, skipping" и main-секция
#      пропускается → HOME перестаёт маршрутизировать что-либо (был incident).
#   2) podkop.settings.source_network_interfaces содержит 'br-lan' — без LAN
#      в source-листе podkop не маркирует пакеты с LAN, они проваливаются в
#      forward_lan → KillSwitch DROP → у юзера «нет интернета».
#
# Не трогаем: main.interface (юзер мог легитимно сменить на awg1, если поднял
# второй VPN), main.fully_routed_ips, main.connection_type, любые user-added
# секции (corp_vpn, второй split-tunnel и т.п.).
#
# Вызывается ИЗ apply_home/apply_travel — каждое переключение режима через
# нашу панель сначала чинит инварианты, потом меняет enabled.
podkop_ensure_main_invariants() {
    uci set podkop.main.user_domain_list_type='dynamic'

    # add_list идемпотентен в реальном uci (дубль не добавляет), но всё равно
    # сначала проверяем — иначе журнал CALLS пухнет, и тесты на «не трогаем
    # если уже есть» становятся непрозрачными. POSIX-pattern: пробелы по краям
    # + glob по подстроке с пробелами — устойчиво к prefix/suffix-коллизиям
    # (например, 'br-lan2' не зацепит 'br-lan').
    _ifaces=$(uci -q get podkop.settings.source_network_interfaces 2>/dev/null || true)
    case " $_ifaces " in
        *" br-lan "*) ;;
        *) uci add_list podkop.settings.source_network_interfaces='br-lan' ;;
    esac

    uci commit podkop
    unset _ifaces
}

# ─────────────────────────────────────────────────────────────────────────────
# podkop_apply_main_section
# ─────────────────────────────────────────────────────────────────────────────
#
# Настраивает секцию podkop.main: «всё через AmneziaWG (awg0)».
# Аргумент: $1 — LAN CIDR (например 192.168.1.0/24) для fully_routed_ips.
#           Если пусто — fully_routed_ips не выставляется.
#
# Destructive — но это OK: вызывается ТОЛЬКО при первой установке
# (setup/02-podkop.sh) и при update_podkop RPC (после apk del podkop, когда
# /etc/config/podkop уже сброшен upstream-установщиком). В обоих случаях
# «терять» нечего.
#
# Для рантайм-переключения HOME/TRAVEL эту функцию НЕ зовём — там работают
# apply_home/apply_travel, которые только enabled-флаг трогают.
#
# user_domain_list_type='dynamic' критичен: без него (и без community_lists)
# подkop логирует "Section 'main' does not have any enabled list, skipping"
# и секция main не применяется → весь HOME-режим становится бесполезным.
podkop_apply_main_section() {
    _lan_cidr="$1"

    # Upstream-дефолт = br-lan, но при upgrade подkop'а installer перекачивает
    # /etc/config/podkop через wget — на DPI-сетях он молча падает и settings
    # приезжает пустым. Без source_network_interfaces подkop не маркирует LAN,
    # пакеты проваливаются в forward_lan → KillSwitch DROP → нет интернета.
    uci -q delete podkop.settings.source_network_interfaces 2>/dev/null || true
    uci add_list podkop.settings.source_network_interfaces='br-lan'

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
#
# Non-destructive: если секция exclude_ru уже существует (юзер настраивал её
# через LuCI), не пересоздаём — только включаем (enabled='1') и доливаем
# наши default-домены в user_domains, если их там ещё нет. Юзерские записи
# (.kz, kinopoisk.ru/admin, любые добавленные через LuCI) сохраняются.
podkop_apply_home() {
    podkop_ensure_main_invariants

    # «Секция существует» определяем по наличию connection_type — она
    # выставляется и нами при первом создании, и LuCI при создании через
    # GUI (поле required). Прямой `uci get podkop.exclude_ru` на разных
    # сборках uci ведёт себя по-разному (печатает 'section' или ошибку);
    # проверка по конкретной опции стабильнее.
    if [ -z "$(uci -q get podkop.exclude_ru.connection_type 2>/dev/null)" ]; then
        # Первое создание: минимальный default-набор. Дальше юзер может
        # настраивать через LuCI как угодно, мы не перезатрём.
        uci set podkop.exclude_ru=section
        uci set podkop.exclude_ru.connection_type='exclusion'
        uci set podkop.exclude_ru.user_domain_list_type='dynamic'
        uci add_list podkop.exclude_ru.community_lists='russia_outside'
    fi

    # Источник правды режима — enabled. См. podkop_current_mode.
    uci set podkop.exclude_ru.enabled='1'

    # MERGE наших defaults: добавляем по одному, только если домена ещё нет.
    # `uci get user_domains` возвращает значения через пробел — обрамляем
    # пробелами по краям и матчим " $domain " (защита от prefix/suffix-коллизий
    # типа 'kinopoisk.ru' ⊇ '.ru'). Если юзер удалил vk.com через LuCI —
    # мы его НЕ возвращаем, потому что merge добавляет только если домена нет
    # И вызывается только при `apply_home`; удаление юзером не отслеживается.
    # Это сознательный trade-off: если юзер явно убрал — значит, ему так надо.
    #
    # Состав списка:
    #   .ru .su .xn--p1ai — российские TLD, поддержка .рф (xn--p1ai = punycode).
    #   vk.com           — основной домен ВК (поддомены VK CDN покрыты community_list).
    #   yastatic.net     — primary static CDN Яндекса (JS/CSS/картинки для всех
    #                      yandex.ru-страниц). БЕЗ него yandex.ru/internet и
    #                      многие .ru-страницы Яндекса грузятся 5+ сек: статика
    #                      идёт через VPN, Yandex CDN троттлит non-RU IP до
    #                      таймаута. Реальный кейс из 2026-05.
    #   .yandex.net      — суффикс для поддоменов yandex.net (avatars.mds.,
    #                      api.passport., и т.п.). Apex yandex.net без A-записи,
    #                      покрывать его не нужно — только поддомены.
    _existing=$(uci -q get podkop.exclude_ru.user_domains 2>/dev/null || true)
    for _d in .ru .su .xn--p1ai vk.com yastatic.net .yandex.net; do
        case " $_existing " in
            *" $_d "*) ;;
            *) uci add_list podkop.exclude_ru.user_domains="$_d" ;;
        esac
    done

    uci commit podkop
    podkop_invalidate_fakeip_cache
    unset _existing _d
}

# ─────────────────────────────────────────────────────────────────────────────
# podkop_apply_travel
# ─────────────────────────────────────────────────────────────────────────────
#
# TRAVEL-режим: full tunnel — весь трафик через VPN, без исключений.
#
# Non-destructive: НЕ удаляем секцию exclude_ru, только выставляем enabled='0'.
# Юзерские user_domains, дополнительные community_lists, любые правки через LuCI
# остаются нетронутыми — при возврате в HOME юзер получит то же, что было.
#
# Если секции вообще нет (свежая установка до первого apply_home) — no-op:
# отсутствие секции exclude_ru уже эквивалентно travel-режиму (нет правила-
# исключения → весь трафик в туннель).
podkop_apply_travel() {
    podkop_ensure_main_invariants

    if [ -n "$(uci -q get podkop.exclude_ru.connection_type 2>/dev/null)" ]; then
        uci set podkop.exclude_ru.enabled='0'
        uci commit podkop
        # Все exclude_ru-домены теперь идут в туннель (раньше шли direct):
        # fakeip-мапинги «domain → direct-out» в кэше уже не валидны.
        podkop_invalidate_fakeip_cache
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# podkop_save_user_domains / podkop_save_community_lists / podkop_restore_exclude_ru
# ─────────────────────────────────────────────────────────────────────────────
#
# Backup и восстановление юзерских настроек секции exclude_ru через apk del +
# reinstall подkop'а (используется в update_podkop RPC). Upstream-installer
# itdoginfo/podkop при свежей установке кладёт дефолтный /etc/config/podkop,
# который перезатирает юзерские user_domains (.kz, kinopoisk.ru) и кастомные
# community_lists. Без backup'а юзер теряет все свои добавления через LuCI
# при каждом клике «🔄 Обновить podkop» — это ломает non-destructive контракт
# веб-панели (см. шапку файла).
#
# podkop_save_user_domains:
#   Печатает в stdout текущие user_domains (space-separated). Пусто если
#   нет секции или список пустой.
#
# podkop_save_community_lists:
#   То же для community_lists.
#
# podkop_restore_exclude_ru "<saved-domains>" "<saved-lists>":
#   Мерджит сохранённые значения в текущий exclude_ru — дубликаты не
#   добавляются (case-check с обрамлением пробелами, та же логика что в
#   apply_home merge). Если секции нет — no-op (caller должен сначала дёрнуть
#   apply_home/_travel). Коммитит podkop.
podkop_save_user_domains() {
    uci -q get podkop.exclude_ru.user_domains 2>/dev/null || true
}

podkop_save_community_lists() {
    uci -q get podkop.exclude_ru.community_lists 2>/dev/null || true
}

podkop_restore_exclude_ru() {
    _saved_domains="$1"
    _saved_lists="$2"

    if [ -z "$(uci -q get podkop.exclude_ru.connection_type 2>/dev/null)" ]; then
        unset _saved_domains _saved_lists
        return 0
    fi

    _existing=$(uci -q get podkop.exclude_ru.user_domains 2>/dev/null || true)
    for _d in $_saved_domains; do
        case " $_existing " in
            *" $_d "*) ;;
            *) uci add_list podkop.exclude_ru.user_domains="$_d" ;;
        esac
    done

    _existing=$(uci -q get podkop.exclude_ru.community_lists 2>/dev/null || true)
    for _l in $_saved_lists; do
        case " $_existing " in
            *" $_l "*) ;;
            *) uci add_list podkop.exclude_ru.community_lists="$_l" ;;
        esac
    done

    uci commit podkop
    podkop_invalidate_fakeip_cache
    unset _saved_domains _saved_lists _existing _d _l
}

# ─────────────────────────────────────────────────────────────────────────────
# podkop_current_mode
# ─────────────────────────────────────────────────────────────────────────────
#
# Печатает текущий режим: "home" или "travel". Источник правды —
# podkop.exclude_ru.enabled. Раньше смотрели на наличие community_lists, но это
# ломалось при non-destructive рефакторе: секция теперь не удаляется при TRAVEL,
# и community_lists остаётся непустым — старый детектор всегда возвращал бы home.
#
# Семантика enabled:
#   • '0'  → travel (явно выключено)
#   • '1'  → home   (явно включено)
#   • ''   → home   (UCI-дефолт для boolean-опций = true; так подkop сам
#                    интерпретирует отсутствие enabled)
#   • секции нет вообще → travel (нет правила-исключения = full tunnel)
podkop_current_mode() {
    _ct=$(uci -q get podkop.exclude_ru.connection_type 2>/dev/null || true)
    if [ -z "$_ct" ]; then
        echo travel
        unset _ct
        return
    fi
    _enabled=$(uci -q get podkop.exclude_ru.enabled 2>/dev/null || true)
    unset _ct
    case "$_enabled" in
        0) echo travel ;;
        *) echo home ;;
    esac
    unset _enabled
}
