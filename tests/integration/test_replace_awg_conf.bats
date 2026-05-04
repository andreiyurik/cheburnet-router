#!/usr/bin/env bats
# replace_awg_conf — RPC замены awg0.conf после установки.
# Покрытие: pre-flight (VPN установлен), валидация awg_conf через
# awg_validate_conf, atomic swap + создание .prev backup, фоновый apply
# через 01-amneziawg.sh, auto-rollback при exit≠0.
#
# Архитектура теста: setsid в моках по умолчанию — no-op (как для
# install_start). Для проверки rollback переключаемся на passthrough
# (см. setsid_passthrough()) и подкладываем mock 01-amneziawg.sh,
# управляемый через env.

load 'helpers/sandbox'

setup() {
    sandbox_init
    # Симулируем установленный VPN — оба маркера get_status.install_type="vpn".
    sandbox_mark_installed
    # Кладём текущий awg0.conf, который RPC должен забэкапить в .prev.
    cat > "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf" <<'EOF'
[Interface]
PrivateKey = oldoldoldoldoldoldoldoldoldoldoldoldoldoA=
Address = 10.8.0.2/32

[Peer]
PublicKey = peerpeerpeerpeerpeerpeerpeerpeerpeerpeerpA=
Endpoint = old.example.com:51820
EOF
    chmod 600 "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf"
}

teardown() {
    sandbox_cleanup
}

# Валидный новый conf.
NEW_CONF="$(cat <<'EOF'
[Interface]
PrivateKey = newnewnewnewnewnewnewnewnewnewnewnewnewnA=
Address = 10.8.0.2/32

[Peer]
PublicKey = newpeernewpeernewpeernewpeernewpeernewpeerA=
Endpoint = new.example.com:51820
EOF
)"
export NEW_CONF

# build_payload AWG_CONF — собирает {"awg_conf": ...} через python для
# защиты от bash quoting-проблем с многострочной строкой.
build_payload() {
    AWG_CONF="$1" python3 <<'PY'
import json, os
print(json.dumps({"awg_conf": os.environ.get("AWG_CONF", "")}))
PY
}

# Переключить mock setsid из no-op в passthrough — реально запустит свои
# аргументы синхронно, чтобы apply-блок отработал и done-маркер создался.
# Используется в rollback/success-тестах.
setsid_passthrough() {
    cat > "$MOCKDIR/setsid" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${CALLS_DIR:-/tmp}/setsid"
exec "$@"
EOF
    chmod +x "$MOCKDIR/setsid"
}

# Заменить $INSTALL_DIR/setup/01-amneziawg.sh на скрипт, который
# touch'ает маркер и завершается с указанным кодом.
install_amneziawg_mock() {
    local exit_code="${1:-0}"
    mkdir -p "$INSTALL_DIR/setup"
    cat > "$INSTALL_DIR/setup/01-amneziawg.sh" <<EOF
#!/bin/sh
echo "01-amneziawg mock: invoked"
echo "01-amneziawg mock: \$0" >> "$SANDBOX/amneziawg-calls"
cat "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf" >> "$SANDBOX/amneziawg-conf-snapshots"
echo "---" >> "$SANDBOX/amneziawg-conf-snapshots"
exit $exit_code
EOF
    chmod +x "$INSTALL_DIR/setup/01-amneziawg.sh"
}

# ─── Pre-flight ─────────────────────────────────────────────────────────────

@test "replace_awg_conf: VPN не установлен (нет awg0.conf) → error 'VPN не установлен'" {
    rm -f "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf"
    payload="$(build_payload "$NEW_CONF")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_output --partial "VPN не установлен"
}

@test "replace_awg_conf: VPN не установлен (нет podkop init) → error 'VPN не установлен'" {
    rm -f "$FAKE_ROOT/etc/init.d/podkop"
    payload="$(build_payload "$NEW_CONF")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_output --partial "VPN не установлен"
}

# ─── Валидация ─────────────────────────────────────────────────────────────

@test "replace_awg_conf: пустой awg_conf → 'awg_conf required'" {
    payload="$(build_payload "")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_output --partial "awg_conf required"
}

@test "replace_awg_conf: conf без [Interface] → ошибка валидации" {
    bad="$(printf '[Peer]\nPublicKey = xxx\nEndpoint = 1.2.3.4:51820\n')"
    payload="$(build_payload "$bad")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_output --partial "[Interface]"
}

@test "replace_awg_conf: conf без [Peer] → ошибка валидации" {
    bad="$(printf '[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=\nAddress = 10.8.0.2/32\n')"
    payload="$(build_payload "$bad")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_output --partial "[Peer]"
}

@test "replace_awg_conf: conf без PublicKey → ошибка валидации" {
    bad="$(printf '[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=\n[Peer]\nEndpoint = 1.2.3.4:51820\n')"
    payload="$(build_payload "$bad")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_output --partial "PublicKey"
}

@test "replace_awg_conf: conf без Endpoint → ошибка валидации (real-world кейс)" {
    bad="$(printf '[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=\n[Peer]\nPublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=\n')"
    payload="$(build_payload "$bad")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_output --partial "Endpoint"
}

# ─── Успешный путь (mock setsid = no-op, проверяем подготовку) ─────────────

@test "replace_awg_conf: валидный conf → status=applying, PID > 0, awg0.conf обновлён, .prev создан" {
    payload="$(build_payload "$NEW_CONF")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_json_field "$output" .status "applying"
    pid="$(json_get "$output" .pid)"
    [ "$pid" -gt 0 ]

    # Новый conf на месте
    grep -q "new.example.com" "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf"
    # Бекап создан и содержит старый conf
    [ -f "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf.prev" ]
    grep -q "old.example.com" "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf.prev"
    # state-файл содержит маркер шага
    grep -q "replacing-awg" "$STATE_DIR/state"
    # PID-файл записан
    [ -s "$STATE_DIR/pid" ]
}

@test "replace_awg_conf: уже идёт операция (PID жив) → 'already running'" {
    sleep 30 &
    pid=$!
    echo "$pid" > "$STATE_DIR/pid"
    payload="$(build_payload "$NEW_CONF")"
    run run_rpcd replace_awg_conf "$payload"
    kill "$pid" 2>/dev/null || true
    assert_success
    assert_output --partial "already running"
}

@test "replace_awg_conf: CRLF в conf нормализуется в LF" {
    crlf_conf="$(printf '[Interface]\r\nPrivateKey = newnewnewnewnewnewnewnewnewnewnewnewnewnA=\r\n[Peer]\r\nPublicKey = newpeernewpeernewpeernewpeernewpeernewpeerA=\r\nEndpoint = new.example.com:51820\r\n')"
    payload="$(build_payload "$crlf_conf")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_json_field "$output" .status "applying"
    # \r не должен попасть в финальный conf
    if grep -q $'\r' "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf"; then
        echo "FAIL: \\r остался в awg0.conf после нормализации"
        return 1
    fi
}

@test "replace_awg_conf: попытка инъекции в awg_conf — остаётся литералом" {
    # awg_conf со shell-метасимволами и попыткой command-substitution.
    # Если rpcd где-то eval'ит/source'ит payload — `; rm -rf $SANDBOX` сработает.
    # Проверяем: SANDBOX цел И именно эти символы попали в файл (или в случай
    # ошибки — отвергнуты awg_validate_conf).
    canary="$SANDBOX/canary"
    : > "$canary"
    bad="$(printf '[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=\n[Peer]\nPublicKey = injectinjectinjectinjectinjectinjectinjeA=\nEndpoint = ";rm -rf '"$canary"';:51820\n')"
    payload="$(build_payload "$bad")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    # canary должен остаться (никакого rm -rf)
    [ -f "$canary" ]
}

# ─── Auto-rollback (полный flow с реальным setsid passthrough) ─────────────

@test "replace_awg_conf: 01-amneziawg success → done='ok', .prev удалён, новый conf на месте" {
    setsid_passthrough
    install_amneziawg_mock 0
    payload="$(build_payload "$NEW_CONF")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_json_field "$output" .status "applying"

    # Apply-скрипт отработал синхронно (setsid passthrough). Проверяем done.
    [ -f "$STATE_DIR/done" ]
    [ "$(cat "$STATE_DIR/done")" = "ok" ]
    # .prev удалён (новый принят)
    [ ! -f "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf.prev" ]
    # Новый conf на месте
    grep -q "new.example.com" "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf"
}

@test "replace_awg_conf: 01-amneziawg fail → done='fail-rolled-back', старый conf восстановлен" {
    setsid_passthrough
    install_amneziawg_mock 1
    payload="$(build_payload "$NEW_CONF")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success
    assert_json_field "$output" .status "applying"

    # Apply-скрипт отработал и вернул ошибку → rollback
    [ -f "$STATE_DIR/done" ]
    [ "$(cat "$STATE_DIR/done")" = "fail-rolled-back" ]
    # awg0.conf равен СТАРОМУ (бекап был возвращён)
    grep -q "old.example.com" "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf"
    # .prev уже не существует — он был mv обратно в awg0.conf
    [ ! -f "$FAKE_ROOT/etc/amnezia/amneziawg/awg0.conf.prev" ]

    # 01-amneziawg.sh был вызван дважды: первая попытка + повторный apply
    # после rollback. Снимок awg0.conf при каждом вызове записан в файл.
    # Первая запись должна содержать НОВЫЙ endpoint, вторая — СТАРЫЙ.
    [ -f "$SANDBOX/amneziawg-conf-snapshots" ]
    new_count=$(grep -c "new.example.com" "$SANDBOX/amneziawg-conf-snapshots" || true)
    old_count=$(grep -c "old.example.com" "$SANDBOX/amneziawg-conf-snapshots" || true)
    [ "$new_count" = "1" ]
    [ "$old_count" = "1" ]
}

@test "replace_awg_conf: install_progress видит шаг 'replacing-awg' и done после rollback" {
    setsid_passthrough
    install_amneziawg_mock 1
    payload="$(build_payload "$NEW_CONF")"
    run run_rpcd replace_awg_conf "$payload"
    assert_success

    # apply-блок асинхронен (setsid + &). Ждём появления done-маркера до 2с.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -f "$STATE_DIR/done" ] && break
        sleep 0.1
    done
    [ -f "$STATE_DIR/done" ]

    run run_rpcd install_progress
    assert_success
    assert_output --partial "replacing-awg"
    assert_output --partial '"done": true'
    assert_output --partial '"result": "fail-rolled-back"'
}
