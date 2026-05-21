#!/usr/bin/env bats
# Контракт lib/podkop-config.sh — единственный источник правды для UCI-логики
# подkop'а. Используется и в setup/02-podkop.sh (одноразово при установке),
# и в scripts/vpn-mode (рантайм-переключение HOME ⇄ TRAVEL), и в RPC
# update_podkop (после reinstall).
#
# Эти тесты охраняют два класса инвариантов:
#
# (А) То, что уже ломалось в проде и НЕ должно вернуться:
#   • podkop.main без user_domain_list_type='dynamic' → секция skip'ается
#     («Section 'main' does not have any enabled list, skipping»),
#     HOME-режим становится бесполезным.
#   • podkop.exclude_ru без community_lists='russia_outside' (при первом
#     создании) → RU-сервисы идут через VPN с не-российским IP → блокировки
#     и капчи.
#
# (Б) Non-destructive контракт (Problem 1, см. AGENTS.md + docs/03):
#   • apply_home не должен удалять user_domains — юзерские .kz/kinopoisk.ru/...
#     обязаны выживать цикл HOME → TRAVEL → HOME.
#   • apply_travel не должен удалять секцию exclude_ru целиком — community_lists
#     и user_domains обязаны выживать.
#   • current_mode читает enabled (а не наличие community_lists), иначе
#     non-destructive рефакторинг ломает детектор режима.
#   • ensure_main_invariants чинит только два известных-ломаемых поля,
#     НЕ перезатирая user-выбор main.interface (юзер мог поднять второй
#     VPN и переключиться на awg1).
#
# Подход: исходим lib/podkop-config.sh в sandbox с PATH-приоритезированным
# mock'ом uci, который журналирует вызовы в $CALLS_DIR/uci. Состояние
# 'set'-ов мок хранит в $FAKE_ROOT/uci-state — это позволяет тестировать
# `uci get` после `uci set`. `add_list`/`delete` в моке — no-op, поэтому
# для merge-логики мы проверяем CALLS-журнал напрямую (что было вызвано,
# а не что хранится).

load 'helpers/sandbox'

setup() {
    sandbox_init
    # shellcheck source=../../lib/podkop-config.sh
    . "$REPO_ROOT/lib/podkop-config.sh"
}

teardown() {
    sandbox_cleanup
}

# Хелпер: проверка что в журнале uci-вызовов есть подстрока. Печатает весь
# журнал при провале — чтобы не гадать «что мок видел».
assert_uci_called() {
    if ! grep -qF "$1" "$CALLS_DIR/uci"; then
        echo "FAIL: uci call missing: $1" >&2
        echo "--- actual calls ---" >&2
        cat "$CALLS_DIR/uci" >&2
        return 1
    fi
}

# Хелпер: подстроки НЕТ в журнале uci-вызовов.
assert_uci_not_called() {
    if grep -qF "$1" "$CALLS_DIR/uci"; then
        echo "FAIL: uci call present but should NOT be: $1" >&2
        echo "--- actual calls ---" >&2
        cat "$CALLS_DIR/uci" >&2
        return 1
    fi
}

# ─── podkop_apply_main_section ────────────────────────────────────────────────

@test "podkop_apply_main_section: connection_type=vpn + interface=awg0" {
    podkop_apply_main_section "192.168.1.0/24"
    assert_uci_called "set podkop.main.connection_type=vpn"
    assert_uci_called "set podkop.main.interface=awg0"
}

@test "podkop_apply_main_section: КРИТИЧНО — user_domain_list_type=dynamic" {
    # Без этой строки секция main подkop'ом игнорируется и HOME-режим
    # перестаёт работать. Был incident в проде. Не удаляйте этот тест.
    podkop_apply_main_section "192.168.1.0/24"
    assert_uci_called "set podkop.main.user_domain_list_type=dynamic"
}

@test "podkop_apply_main_section: fully_routed_ips проставлен из аргумента" {
    podkop_apply_main_section "10.42.0.0/24"
    assert_uci_called "add_list podkop.main.fully_routed_ips=10.42.0.0/24"
}

@test "podkop_apply_main_section: пустой аргумент — fully_routed_ips НЕ выставляется" {
    podkop_apply_main_section ""
    # Должны быть set'ы для connection_type/interface/dynamic, но НЕ должно
    # быть add_list fully_routed_ips=...
    assert_uci_called "set podkop.main.connection_type=vpn"
    if grep -qE "add_list podkop\.main\.fully_routed_ips=" "$CALLS_DIR/uci"; then
        echo "FAIL: fully_routed_ips должен быть пустым при пустом arg" >&2
        cat "$CALLS_DIR/uci" >&2
        return 1
    fi
}

@test "podkop_apply_main_section: чистит проксь-конфиг и старые fully_routed_ips" {
    # Эти delete'ы важны при ПЕРЕзапуске (idempotency): иначе старые
    # значения останутся накопленными.
    podkop_apply_main_section "192.168.1.0/24"
    assert_uci_called "delete podkop.main.proxy_config_type"
    assert_uci_called "delete podkop.main.proxy_string"
    assert_uci_called "delete podkop.main.fully_routed_ips"
}

@test "podkop_apply_main_section: коммитит podkop" {
    podkop_apply_main_section "192.168.1.0/24"
    assert_uci_called "commit podkop"
}

# ─── podkop_ensure_main_invariants ────────────────────────────────────────────

@test "ensure_main_invariants: ставит user_domain_list_type=dynamic" {
    podkop_ensure_main_invariants
    assert_uci_called "set podkop.main.user_domain_list_type=dynamic"
}

@test "ensure_main_invariants: добавляет br-lan если его нет в source_network_interfaces" {
    # Пусто → должен добавить
    podkop_ensure_main_invariants
    assert_uci_called "add_list podkop.settings.source_network_interfaces=br-lan"
}

@test "ensure_main_invariants: НЕ добавляет br-lan если он уже в списке" {
    # Симулируем что br-lan уже есть (uci get вернёт строку с br-lan)
    uci set podkop.settings.source_network_interfaces='br-lan'
    : > "$CALLS_DIR/uci"   # сбрасываем журнал после pre-setup'а
    podkop_ensure_main_invariants
    # set user_domain_list_type должен быть, но add_list source_network_interfaces — нет
    assert_uci_called "set podkop.main.user_domain_list_type=dynamic"
    assert_uci_not_called "add_list podkop.settings.source_network_interfaces"
}

@test "ensure_main_invariants: КРИТИЧНО — НЕ трогает main.interface" {
    # Юзер мог поднять второй VPN и переключить interface=awg1 через LuCI.
    # Наша панель не должна возвращать interface обратно на awg0 при
    # каждом mode_switch. apply_main_section — да (это первая установка
    # или явный update_podkop), ensure_main_invariants — нет.
    podkop_ensure_main_invariants
    assert_uci_not_called "set podkop.main.interface"
    assert_uci_not_called "delete podkop.main.interface"
}

@test "ensure_main_invariants: НЕ трогает fully_routed_ips / connection_type" {
    # Та же логика: только два конкретных поля.
    podkop_ensure_main_invariants
    assert_uci_not_called "podkop.main.fully_routed_ips"
    assert_uci_not_called "set podkop.main.connection_type"
}

@test "ensure_main_invariants: коммитит podkop" {
    podkop_ensure_main_invariants
    assert_uci_called "commit podkop"
}

# ─── podkop_apply_home (первое создание) ──────────────────────────────────────

@test "apply_home (first time): создаёт секцию exclude_ru с default-набором" {
    # Секции нет → должны её создать с минимальным defaults + russia_outside
    # + 4 user_domain.
    podkop_apply_home
    assert_uci_called "set podkop.exclude_ru=section"
    assert_uci_called "set podkop.exclude_ru.connection_type=exclusion"
    assert_uci_called "set podkop.exclude_ru.user_domain_list_type=dynamic"
}

@test "apply_home (first time): КРИТИЧНО — community_lists=russia_outside" {
    # Без этого community-листа RU-сервисы идут через VPN. Это **противоположный**
    # эффект от заявленного «.ru напрямую». Контр-интуитивное имя:
    # russia_outside = «исключения ВНЕ России (наружу пускаем РФ)»,
    # russia_inside = «всё что внутри России» — НЕ путать.
    podkop_apply_home
    assert_uci_called "add_list podkop.exclude_ru.community_lists=russia_outside"
}

@test "apply_home (first time): добавляет все 4 default user_domains" {
    # Помимо community-листа держим явные TLD-исключения как страховку:
    # community_list может временно не загрузиться (sing-box DNS hiccup),
    # тогда .ru/.su/.рф всё равно резолвятся напрямую.
    podkop_apply_home
    assert_uci_called "add_list podkop.exclude_ru.user_domains=.ru"
    assert_uci_called "add_list podkop.exclude_ru.user_domains=.su"
    assert_uci_called "add_list podkop.exclude_ru.user_domains=.xn--p1ai"
    assert_uci_called "add_list podkop.exclude_ru.user_domains=vk.com"
}

@test "apply_home: ставит enabled=1" {
    # enabled — источник правды режима (см. podkop_current_mode).
    podkop_apply_home
    assert_uci_called "set podkop.exclude_ru.enabled=1"
}

@test "apply_home: коммитит podkop" {
    podkop_apply_home
    assert_uci_called "commit podkop"
}

# ─── podkop_apply_home (non-destructive поверх существующей секции) ───────────

@test "apply_home: НЕ пересоздаёт секцию если connection_type уже есть" {
    # Юзер настроил exclude_ru через LuCI. apply_home должен только включить
    # её и долить наши defaults, не trampling её существующие поля.
    uci set podkop.exclude_ru=section
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.user_domain_list_type=dynamic
    : > "$CALLS_DIR/uci"
    podkop_apply_home
    # set connection_type/user_domain_list_type вызываются только в первом
    # создании — после pre-setup'а их быть не должно
    assert_uci_not_called "set podkop.exclude_ru.connection_type"
    assert_uci_not_called "set podkop.exclude_ru.user_domain_list_type=dynamic"
    assert_uci_not_called "set podkop.exclude_ru=section"
    # Зато enabled=1 — обязательно
    assert_uci_called "set podkop.exclude_ru.enabled=1"
}

@test "apply_home: НЕ удаляет user_domains (юзерские .kz сохраняются)" {
    # Сценарий: юзер через LuCI добавил .kz и kinopoisk.ru/admin в user_domains
    # секции exclude_ru. После apply_home их обязательно сохранить — иначе
    # каждое переключение в HOME из web-панели затирало бы его кастом.
    podkop_apply_home
    # Старая реализация делала `uci delete user_domains` перед add_list —
    # это убивало юзерские записи. В новой такого быть не должно.
    assert_uci_not_called "delete podkop.exclude_ru.user_domains"
}

@test "apply_home: НЕ удаляет community_lists (юзерские расширения сохраняются)" {
    # Аналогично user_domains: юзер мог добавить второй community_list
    # (например russia_inside для своих экспериментов). apply_home не трогает.
    podkop_apply_home
    assert_uci_not_called "delete podkop.exclude_ru.community_lists"
}

@test "apply_home: MERGE — НЕ добавляет .ru если он уже в user_domains" {
    # Юзер уже имеет .ru в user_domains (от прошлого apply_home или сам ввёл
    # через LuCI). Повторный apply_home не должен дублировать (реальный uci
    # add_list это сам игнорирует, но мы хотим явный контроль — не дёргать).
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.user_domains='.ru .su .xn--p1ai vk.com'
    : > "$CALLS_DIR/uci"
    podkop_apply_home
    assert_uci_not_called "add_list podkop.exclude_ru.user_domains=.ru"
    assert_uci_not_called "add_list podkop.exclude_ru.user_domains=.su"
    assert_uci_not_called "add_list podkop.exclude_ru.user_domains=.xn--p1ai"
    assert_uci_not_called "add_list podkop.exclude_ru.user_domains=vk.com"
}

@test "apply_home: MERGE — добавляет недостающий .xn--p1ai" {
    # Юзер удалил .xn--p1ai через LuCI (например, не нужен .рф). apply_home,
    # которое его вернёт — это сознательный trade-off (контракт: «наши 4
    # defaults всегда есть в HOME, явное удаление через LuCI не сохраняем»).
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.user_domains='.ru .su vk.com'
    : > "$CALLS_DIR/uci"
    podkop_apply_home
    assert_uci_called "add_list podkop.exclude_ru.user_domains=.xn--p1ai"
    assert_uci_not_called "add_list podkop.exclude_ru.user_domains=.ru"
}

@test "apply_home: зовёт ensure_main_invariants (self-heal main каждое включение)" {
    # Каждое переключение режима — шанс «дочинить» main.user_domain_list_type
    # если кто-то снял через LuCI.
    podkop_apply_home
    assert_uci_called "set podkop.main.user_domain_list_type=dynamic"
}

# ─── podkop_apply_travel ──────────────────────────────────────────────────────

@test "apply_travel: НЕ удаляет секцию exclude_ru (юзерское остаётся)" {
    # КРИТИЧНО для non-destructive контракта. Старая реализация делала
    # `uci delete podkop.exclude_ru` — юзерские user_domains и community_lists
    # пропадали навсегда. Новая — только enabled='0'.
    uci set podkop.exclude_ru.connection_type=exclusion
    : > "$CALLS_DIR/uci"
    podkop_apply_travel
    # Регрессия: если кто-то восстановил `uci delete podkop.exclude_ru`
    # без пометки .X на конце — этот тест поймёт.
    if grep -E "delete podkop\.exclude_ru($| )" "$CALLS_DIR/uci" >/dev/null; then
        echo "FAIL: apply_travel удаляет секцию exclude_ru — нарушение non-destructive контракта" >&2
        cat "$CALLS_DIR/uci" >&2
        return 1
    fi
}

@test "apply_travel: устанавливает enabled=0" {
    uci set podkop.exclude_ru.connection_type=exclusion
    : > "$CALLS_DIR/uci"
    podkop_apply_travel
    assert_uci_called "set podkop.exclude_ru.enabled=0"
}

@test "apply_travel: секции нет — no-op для exclude_ru (только ensure_main_invariants)" {
    # Свежий роутер: секция exclude_ru ещё не создавалась. apply_travel
    # не должен пытаться ничего ставить — отсутствие секции эквивалентно
    # full-tunnel-режиму (нет правила-исключения). Но ensure_main_invariants
    # должен отработать (мы всё ещё чиним main).
    podkop_apply_travel
    assert_uci_called "set podkop.main.user_domain_list_type=dynamic"
    assert_uci_not_called "set podkop.exclude_ru.enabled"
}

@test "apply_travel: зовёт ensure_main_invariants" {
    podkop_apply_travel
    assert_uci_called "set podkop.main.user_domain_list_type=dynamic"
}

# ─── podkop_current_mode ──────────────────────────────────────────────────────

@test "current_mode: enabled=1 → home" {
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.enabled=1
    [ "$(podkop_current_mode)" = "home" ]
}

@test "current_mode: enabled=0 → travel" {
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.enabled=0
    [ "$(podkop_current_mode)" = "travel" ]
}

@test "current_mode: enabled пусто, секция есть → home (UCI default = enabled)" {
    # UCI-семантика boolean-опций: отсутствие = true. Если юзер явно
    # не выключил — режим home.
    uci set podkop.exclude_ru.connection_type=exclusion
    # enabled не выставляем
    [ "$(podkop_current_mode)" = "home" ]
}

@test "current_mode: секции нет вообще → travel (full tunnel by default)" {
    # Свежая установка до первого apply_home: нет правила-исключения →
    # весь трафик в туннель → travel.
    [ "$(podkop_current_mode)" = "travel" ]
}

# ─── HOME ⇄ TRAVEL композиция: end-to-end сценарии non-destructive ────────────

@test "сценарий: HOME → TRAVEL → HOME — наши defaults доливаются один раз" {
    # Базовый цикл: пользователь кликнул HOME, потом TRAVEL, потом HOME.
    # Defaults должны быть добавлены при первом HOME, при втором — НЕ должны
    # дублироваться (потому что в state mock'е они уже есть... ну, через
    # uci set, потому что add_list в моке no-op — но всё равно).
    podkop_apply_home
    podkop_apply_travel
    # Сейчас секция должна быть disabled, но connection_type на месте
    [ "$(podkop_current_mode)" = "travel" ]

    : > "$CALLS_DIR/uci"
    podkop_apply_home
    # После TRAVEL→HOME: enabled снова 1
    assert_uci_called "set podkop.exclude_ru.enabled=1"
    # connection_type не должны пересоздавать (секция уже есть)
    assert_uci_not_called "set podkop.exclude_ru.connection_type"
}

@test "сценарий: юзерский .kz сохраняется через цикл HOME → TRAVEL → HOME" {
    # Юзер добавил .kz через LuCI (uci add_list → строка в user_domains).
    # Симулируем: предустанавливаем секцию + user_domains с .kz и нашими defaults.
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.user_domains='.kz .ru .su .xn--p1ai vk.com'
    : > "$CALLS_DIR/uci"

    podkop_apply_travel
    podkop_apply_home

    # apply_travel/home не должны были удалять user_domains
    assert_uci_not_called "delete podkop.exclude_ru.user_domains"
    # apply_home не должно повторно добавлять наши defaults — они уже есть
    assert_uci_not_called "add_list podkop.exclude_ru.user_domains=.ru"
    # Финальный режим — home
    [ "$(podkop_current_mode)" = "home" ]
}

@test "сценарий: кастомная секция (corp_vpn) не тронута mode_switch" {
    # Юзер через LuCI добавил вторую секцию podkop.corp_vpn (свой split-tunnel).
    # Наша панель ни apply_home, ни apply_travel её НЕ трогает.
    uci set podkop.corp_vpn=section
    uci set podkop.corp_vpn.connection_type=proxy
    uci set podkop.corp_vpn.enabled=1
    : > "$CALLS_DIR/uci"

    podkop_apply_travel
    podkop_apply_home

    # Никаких упоминаний corp_vpn в журнале uci-вызовов
    if grep -F "corp_vpn" "$CALLS_DIR/uci" >/dev/null; then
        echo "FAIL: apply_home/travel трогает чужую секцию corp_vpn" >&2
        cat "$CALLS_DIR/uci" >&2
        return 1
    fi
}
