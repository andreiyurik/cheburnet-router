#!/usr/bin/env bats
# Контракт lib/podkop-config.sh — единственный источник правды для UCI-логики
# подkop'а. Используется и в setup/02-podkop.sh (одноразово при установке),
# и в scripts/vpn-mode (рантайм-переключение HOME ⇄ TRAVEL).
#
# Эти тесты охраняют ровно те инварианты, которые уже один раз ломались
# в проде:
#   • podkop.main без user_domain_list_type='dynamic' → секция skip'ается
#     («Section 'main' does not have any enabled list, skipping»),
#     HOME-режим становится бесполезным.
#   • podkop.exclude_ru без community_lists='russia_outside' → RU-сервисы
#     (Сбер, госуслуги, Яндекс) идут через VPN с не-российским IP →
#     блокировки и капчи.
#   • TRAVEL-режим должен СТЕРЕТЬ исключения, иначе full-tunnel не full.
#
# Подход: исходим lib/podkop-config.sh в sandbox с PATH-приоритезированным
# mock'ом uci, который журналирует вызовы в $CALLS_DIR/uci. Затем grep'ом
# проверяем, что нужные строки попали в журнал.

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

# ─── podkop_apply_home ────────────────────────────────────────────────────────

@test "podkop_apply_home: exclusion-секция exclude_ru с dynamic list" {
    podkop_apply_home
    assert_uci_called "set podkop.exclude_ru.connection_type=exclusion"
    assert_uci_called "set podkop.exclude_ru.user_domain_list_type=dynamic"
}

@test "podkop_apply_home: КРИТИЧНО — community_lists=russia_outside" {
    # Без этого community-листа RU-сервисы идут через VPN. Это **противоположный**
    # эффект от заявленного «.ru напрямую». Контр-интуитивное имя:
    # russia_outside = «исключения ВНЕ России (наружу пускаем РФ)»,
    # russia_inside = «всё что внутри России» — НЕ путать.
    podkop_apply_home
    assert_uci_called "add_list podkop.exclude_ru.community_lists=russia_outside"
}

@test "podkop_apply_home: явные user_domains для RU-TLD и vk.com" {
    # Помимо community-листа держим явные TLD-исключения как страховку:
    # community_list может временно не загрузиться (sing-box DNS hiccup),
    # тогда .ru/.su/.рф всё равно резолвятся напрямую.
    podkop_apply_home
    assert_uci_called "add_list podkop.exclude_ru.user_domains=.ru"
    assert_uci_called "add_list podkop.exclude_ru.user_domains=.su"
    assert_uci_called "add_list podkop.exclude_ru.user_domains=.xn--p1ai"
    assert_uci_called "add_list podkop.exclude_ru.user_domains=vk.com"
}

@test "podkop_apply_home: чистит старые списки (idempotency)" {
    # При повторном вызове старые user_domains не должны накапливаться.
    podkop_apply_home
    assert_uci_called "delete podkop.exclude_ru.community_lists"
    assert_uci_called "delete podkop.exclude_ru.user_domains"
}

@test "podkop_apply_home: коммитит podkop" {
    podkop_apply_home
    assert_uci_called "commit podkop"
}

# ─── podkop_apply_travel ──────────────────────────────────────────────────────

@test "podkop_apply_travel: удаляет секцию exclude_ru целиком" {
    # TRAVEL = full tunnel. Удаляем всю секцию — только так podkop перестаёт
    # генерировать direct-out в sing-box. Очистка полей без удаления секции
    # недостаточна: podkop видит connection_type='exclusion' и вставляет прямой
    # маршрут. Был incident в проде (HOME и TRAVEL давали идентичный sing-box).
    podkop_apply_travel
    assert_uci_called "delete podkop.exclude_ru"
}

@test "podkop_apply_travel: коммитит podkop" {
    podkop_apply_travel
    assert_uci_called "commit podkop"
}

@test "podkop_apply_travel: подkop_apply_home воссоздаёт секцию после travel" {
    # podkop_apply_home использует `uci set podkop.exclude_ru=section`, что
    # воссоздаёт секцию если её нет — возврат HOME после TRAVEL корректен.
    podkop_apply_travel
    podkop_apply_home
    assert_uci_called "set podkop.exclude_ru=section"
    assert_uci_called "add_list podkop.exclude_ru.community_lists=russia_outside"
}

# ─── HOME ⇄ TRAVEL композиция ────────────────────────────────────────────────

@test "сценарий: TRAVEL → HOME → TRAVEL восстанавливает корректное состояние" {
    # Это эмуляция цикла кнопкой: пользователь несколько раз дёрнул режим.
    # Главное — после возвращения в HOME все списки на месте.
    podkop_apply_travel
    podkop_apply_home
    podkop_apply_travel

    # Последний должен быть стирающим travel; смотрим что хвост журнала
    # содержит delete'ы exclude_ru, а не добавления.
    tail_calls="$(tail -10 "$CALLS_DIR/uci")"
    if ! echo "$tail_calls" | grep -qE "delete podkop\.exclude_ru$"; then
        echo "FAIL: финальный travel не удалил секцию exclude_ru" >&2
        echo "--- last 10 calls ---" >&2
        echo "$tail_calls" >&2
        return 1
    fi
}
