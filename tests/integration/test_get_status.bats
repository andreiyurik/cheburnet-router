#!/usr/bin/env bats
# Сценарии #1, #2, #3 из спеки T3 (адаптировано под mock-окружение):
# - bootstrap создал токен → get_status должен сообщать install_token_required: true
# - после install_progress / lock-acl токен исчезает → install_token_required: false
# - DNS-probe возвращает корректный dns_up / podkop_up

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

@test "get_status: pre-install (токен на месте) → install_token_required=true, install_type=none" {
    sandbox_set_token "deadbeefcafebabe1234567890abcdef" >/dev/null
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .install_token_required "true"
    assert_json_field "$output" .install_type "none"
    assert_json_field "$output" .installing "false"
}

@test "get_status: post-install (токена нет, awg0.conf+podkop есть) → install_token_required=false, install_type=vpn" {
    sandbox_mark_installed
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .install_token_required "false"
    assert_json_field "$output" .install_type "vpn"
}

@test "get_status: dns_up=false когда dnsmasq не running" {
    sandbox_set_token >/dev/null
    # dnsmasq init.d отсутствует → status fail → dns_up false
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .dns_up "false"
}

@test "get_status: dns_up=true когда dnsmasq running и nslookup отвечает" {
    sandbox_set_token >/dev/null
    # Мокаем dnsmasq init.d как running
    cat > "$FAKE_ROOT/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
echo "Service dnsmasq is running"
EOF
    chmod +x "$FAKE_ROOT/etc/init.d/dnsmasq"
    ETC_INIT_D="$FAKE_ROOT/etc/init.d" run run_rpcd get_status
    assert_success
    assert_json_field "$output" .dns_up "true"
}

@test "get_status: dns_up=false когда dnsmasq running но nslookup падает" {
    sandbox_set_token >/dev/null
    cat > "$FAKE_ROOT/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
echo "Service dnsmasq is running"
EOF
    chmod +x "$FAKE_ROOT/etc/init.d/dnsmasq"
    : > "$FAKE_ROOT/dns-broken"
    ETC_INIT_D="$FAKE_ROOT/etc/init.d" run run_rpcd get_status
    assert_success
    assert_json_field "$output" .dns_up "false"
}

@test "get_status: mode=travel когда секция exclude_ru отсутствует (чистый install)" {
    sandbox_set_token >/dev/null
    # UCI mock без записи exclude_ru → connection_type пуст → travel (нет
    # правила-исключения = full tunnel by default).
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .mode "travel"
}

@test "get_status: mode=home когда секция exclude_ru есть и enabled не выключен" {
    sandbox_set_token >/dev/null
    # Регрессия Problem 1 (non-destructive рефакторинг): podkop_current_mode
    # теперь читает exclude_ru.enabled (а не community_lists), потому что
    # apply_travel больше не удаляет секцию — community_lists остаётся
    # непустым и в travel-режиме тоже. Источник правды — enabled.
    # Если connection_type=exclusion и enabled явно не выставлено,
    # UCI-семантика boolean: отсутствие = true → home.
    uci set podkop.exclude_ru.connection_type=exclusion
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .mode "home"
}

@test "get_status: mode=travel когда секция есть, но enabled=0 (новый non-destructive TRAVEL)" {
    sandbox_set_token >/dev/null
    # apply_travel: секция остаётся (юзерское не теряем), но enabled=0.
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.enabled=0
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .mode "travel"
}

@test "get_status: возвращает валидный JSON" {
    sandbox_set_token >/dev/null
    run run_rpcd get_status
    assert_success
    # Если JSON битый — python кинет exception
    printf '%s' "$output" | python3 -m json.tool >/dev/null
}

# ─── rulesets_health (Problem 2: видимость тихой деградации HOME) ────────────
#
# Healthcheck проверяет состояние sing-box ЧЕРЕЗ Clash API (не через файлы),
# потому что подkop 0.7.17+ кладёт community-list'ы в binary cache.db, а не в
# /tmp/sing-box/rulesets/. См. _ruleset_loaded в web/rpcd-cheburnet.
#
# Моки:
#   • pidof — по умолчанию находит sing-box (FAKE_ROOT/no-sing-box чтобы нет).
#   • curl — на /rules возвращает JSON с russia_outside в payload (FAKE_ROOT/
#     clash-rules-response чтобы переопределить; "MOCK_NO_API" чтобы симулировать
#     недоступный API через rc=28).

@test "rulesets_health: TRAVEL → loaded=true, missing=[] (rulesets не нужны)" {
    sandbox_set_token >/dev/null
    # mode=travel по умолчанию (нет exclude_ru) → проверки не делаем.
    # Не показываем баннер в travel-режиме — нечего проверять.
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .mode "travel"
    assert_json_field "$output" .rulesets_health.russia_outside_loaded "true"
}

@test "rulesets_health: HOME, sing-box работает, API содержит russia_outside → loaded=true" {
    sandbox_set_token >/dev/null
    # HOME: exclude_ru.connection_type есть, enabled пуст = home (UCI-дефолт boolean).
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.community_lists=russia_outside
    # Mock pidof возвращает success по умолчанию; mock curl возвращает дефолтный
    # JSON с russia_outside по умолчанию. Ничего настраивать не нужно.
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .mode "home"
    assert_json_field "$output" .rulesets_health.russia_outside_loaded "true"
}

@test "rulesets_health: HOME, sing-box не запущен → loaded=false, missing содержит tag" {
    sandbox_set_token >/dev/null
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.community_lists=russia_outside
    # Маркер для мока pidof — «sing-box не найден» (свежая установка под DPI,
    # sing-box упал FATAL до старта API).
    touch "$FAKE_ROOT/no-sing-box"
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .rulesets_health.russia_outside_loaded "false"
    assert_output --partial '"russia_outside"'
}

@test "rulesets_health: HOME, sing-box запущен но API недоступен → loaded=false" {
    # Edge case: sing-box процесс живёт, но Clash API ещё не слушает (старт)
    # или биндится на другой IP. Curl с --max-time 3 вернёт rc=28.
    sandbox_set_token >/dev/null
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.community_lists=russia_outside
    echo "MOCK_NO_API" > "$FAKE_ROOT/clash-rules-response"
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .rulesets_health.russia_outside_loaded "false"
}

@test "rulesets_health: HOME, API отвечает но russia_outside НЕ в правилах → loaded=false" {
    # Сценарий полной деградации: sing-box запущен, API работает, но rule_set
    # с russia_outside не в /rules — значит подkop не сгенерил его в конфиг
    # (юзер сломал руками через LuCI / битый upgrade).
    sandbox_set_token >/dev/null
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.community_lists=russia_outside
    # /rules без упоминания russia_outside
    printf '%s' '{"rules":[{"type":"default","payload":"inbound=tproxy-in source_ip_cidr=192.168.1.0/24","proxy":"route(main-out)"}]}' > "$FAKE_ROOT/clash-rules-response"
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .rulesets_health.russia_outside_loaded "false"
}

@test "rulesets_health: HOME без community_lists → loaded=true (юзер сознательно убрал)" {
    # Юзер через LuCI убрал community_lists, оставив только user_domains.
    # Это его выбор — не показываем баннер «не загружено» (нечего проверять).
    sandbox_set_token >/dev/null
    uci set podkop.exclude_ru.connection_type=exclusion
    # community_lists не выставляем
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .mode "home"
    assert_json_field "$output" .rulesets_health.russia_outside_loaded "true"
}
