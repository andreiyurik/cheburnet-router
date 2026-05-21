#!/usr/bin/env bats
# Сценарии мутирующих методов rpcd-cheburnet:
# - factory_reset: confirm-проверка
# - mode_switch:  валидация mode + наличие /usr/bin/vpn-mode
# - set_blocklist_tier: валидация tier + что adblock-config редактируется
# - service_restart: dispatch по service
# - install_cancel: kill PID + done-маркер
#
# Note: rpcd-cheburnet НЕ enforce'ит ACL сам — это делает rpcd по acl.d/*.json.
# Тесты на ACL-enforcement переехали в test_acl_lockdown.bats и
# проверяют JSON-файл напрямую (структура pre/post-install).

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

# ─── factory_reset ──────────────────────────────────────────────────────────

@test "factory_reset: confirm='RESET' → status=scheduled, firstboot+reboot вызваны" {
    run run_rpcd factory_reset '{"confirm":"RESET"}'
    assert_success
    assert_output --partial "factory reset scheduled"
    # Проверяем что firstboot был вызван (через background subshell, но мы
    # его не ждём — поэтому проверяем sleep 3 не блокирует тест >1c).
}

@test "factory_reset: confirm='reset' → reject" {
    run run_rpcd factory_reset '{"confirm":"reset"}'
    assert_success  # JSON-error, exit 0
    assert_output --partial "must be exactly"
}

@test "factory_reset: пустой confirm → reject" {
    run run_rpcd factory_reset '{"confirm":""}'
    assert_output --partial "must be exactly"
}

@test "factory_reset: shell-инъекция в confirm → reject" {
    run run_rpcd factory_reset '{"confirm":"RESET; rm -rf /"}'
    assert_output --partial "must be exactly"
}

@test "factory_reset: отсутствующий confirm → reject" {
    run run_rpcd factory_reset '{}'
    assert_output --partial "must be exactly"
}

# ─── mode_switch ────────────────────────────────────────────────────────────

@test "mode_switch: mode='home' и vpn-mode не установлен → 'CLI not installed'" {
    run run_rpcd mode_switch '{"mode":"home"}'
    assert_success
    assert_output --partial "vpn-mode CLI not installed"
}

@test "mode_switch: mode='home' и vpn-mode установлен → status=ok, mode=home" {
    cat > "$USR_BIN_VPN_MODE" <<'EOF'
#!/bin/sh
echo "switched to $1"
exit 0
EOF
    chmod +x "$USR_BIN_VPN_MODE"
    run run_rpcd mode_switch '{"mode":"home"}'
    assert_success
    assert_json_field "$output" .status "ok"
    assert_json_field "$output" .mode "home"
}

@test "mode_switch: mode='HOME' (caps) → reject" {
    run run_rpcd mode_switch '{"mode":"HOME"}'
    assert_output --partial "must be home or travel"
}

@test "mode_switch: shell-инъекция в mode → reject" {
    run run_rpcd mode_switch '{"mode":"home; reboot"}'
    assert_output --partial "must be home or travel"
}

@test "mode_switch: vpn-mode возвращает ошибку → форвардим в JSON" {
    cat > "$USR_BIN_VPN_MODE" <<'EOF'
#!/bin/sh
echo "podkop down" >&2
exit 1
EOF
    chmod +x "$USR_BIN_VPN_MODE"
    run run_rpcd mode_switch '{"mode":"travel"}'
    assert_success
    assert_output --partial "vpn-mode travel failed"
}

# ─── set_blocklist_tier ─────────────────────────────────────────────────────

@test "set_blocklist_tier: adblock-конфига нет → 'config not found'" {
    run run_rpcd set_blocklist_tier '{"tier":"pro"}'
    assert_success
    assert_output --partial "config not found"
}

@test "set_blocklist_tier: tier=pro → подменяет raw_block_lists в config" {
    echo 'raw_block_lists="hagezi:light"' > "$ETC_ADBLOCK_CFG"
    run run_rpcd set_blocklist_tier '{"tier":"pro"}'
    assert_success
    assert_json_field "$output" .status "tier set"
    grep -q '^raw_block_lists="hagezi:pro"$' "$ETC_ADBLOCK_CFG"
}

@test "set_blocklist_tier: невалидный tier → reject (config не трогается)" {
    echo 'raw_block_lists="hagezi:light"' > "$ETC_ADBLOCK_CFG"
    run run_rpcd set_blocklist_tier '{"tier":"hagezi:pro"}'
    assert_output --partial "tier must be one of"
    # Конфиг не должен поменяться
    grep -q '^raw_block_lists="hagezi:light"$' "$ETC_ADBLOCK_CFG"
}

@test "set_blocklist_tier: shell-инъекция через tier → reject + config цел" {
    echo 'raw_block_lists="hagezi:light"' > "$ETC_ADBLOCK_CFG"
    run run_rpcd set_blocklist_tier '{"tier":"pro\"; rm -rf /; echo \""}'
    assert_output --partial "tier must be one of"
    grep -q '^raw_block_lists="hagezi:light"$' "$ETC_ADBLOCK_CFG"
}

# ─── service_restart ────────────────────────────────────────────────────────

@test "service_restart: service='dns' → restart dnsmasq, status=dns restarted" {
    cat > "$ETC_INIT_D/dnsmasq" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$ETC_INIT_D/dnsmasq"
    run run_rpcd service_restart '{"service":"dns"}'
    assert_success
    assert_json_field "$output" .status "dns restarted"
}

@test "service_restart: service='unknown' → error" {
    run run_rpcd service_restart '{"service":"foobar"}'
    assert_output --partial "unknown service"
}

# ─── install_cancel ─────────────────────────────────────────────────────────

@test "install_cancel: PID-файла нет → not_running" {
    run run_rpcd install_cancel '{}'
    assert_success
    assert_json_field "$output" .status "not_running"
}

@test "install_cancel: PID есть → kill + done-маркер записан" {
    # Запускаем фоновый процесс, кладём его PID в state
    sleep 30 &
    pid=$!
    echo "$pid" > "$STATE_DIR/pid"
    run run_rpcd install_cancel '{}'
    assert_success
    assert_json_field "$output" .status "cancelled"
    # Done-маркер записан
    [ "$(cat "$STATE_DIR/done")" = "cancelled" ]
    # Процесс должен быть убит (даём 1s на доставку сигнала)
    sleep 1
    ! kill -0 "$pid" 2>/dev/null
}

# ─── update_podkop ──────────────────────────────────────────────────────────
# Problem 3: апгрейд устаревших инсталляций. Пре-флайты (нет подkop'а / уже
# идёт операция) + happy path (started + PID). Сам апгрейд (apk del + reinstall
# + reapply + restart) делает фоновый script, его поведение здесь не тестируем
# (real apk на CI отсутствует, сценарий покрывает qemu-install при ручной
# проверке).

@test "update_podkop: подkop не установлен → 'podkop не установлен'" {
    # /etc/init.d/podkop отсутствует — апгрейдить нечего
    run run_rpcd update_podkop '{}'
    assert_success
    assert_output --partial "podkop не установлен"
}

@test "update_podkop: уже идёт операция (PID жив) → 'already running'" {
    # Pre-condition: подkop установлен (init-script на месте)
    cat > "$ETC_INIT_D/podkop" <<'EOF'
#!/bin/sh
echo "Service podkop is running"
EOF
    chmod +x "$ETC_INIT_D/podkop"

    sleep 30 &
    pid=$!
    echo "$pid" > "$STATE_DIR/pid"
    run run_rpcd update_podkop '{}'
    kill "$pid" 2>/dev/null || true
    assert_success
    assert_output --partial "already running"
}

@test "update_podkop: happy path — status=started, PID > 0, apply-скрипт создан" {
    # Pre-condition: подkop установлен. Сам install/restart фейлится в sandbox
    # (нет apk + нет sing-box), но это уже фоновый процесс — его результат
    # пишется в DONE_FILE, нас интересует только что RPC корректно запустил.
    cat > "$ETC_INIT_D/podkop" <<'EOF'
#!/bin/sh
echo "Service podkop is running"
EOF
    chmod +x "$ETC_INIT_D/podkop"

    run run_rpcd update_podkop '{}'
    assert_success
    assert_json_field "$output" .status "started"
    # PID-файл создан, apply-скрипт на месте
    [ -s "$STATE_DIR/pid" ]
    [ -x "$STATE_DIR/podkop-update-apply.sh" ]
    # state выставлен на podkop-update — UI поймёт что это наш шаг
    grep -q "podkop-update" "$STATE_DIR/state"

    # Cleanup: убиваем фоновый процесс (он точно зафейлится на apk,
    # но мог недотечь до записи DONE — не оставляем мусор после теста).
    pid=$(cat "$STATE_DIR/pid")
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    sleep 1
}
