#!/usr/bin/env bats
# Тесты парсера AmneziaWG-конфига: awg_get_iface, awg_get_peer,
# awg_endpoint_host, awg_endpoint_port.

load '../helpers/setup'

# ─── awg_get_iface — поля из [Interface] секции ─────────────────────────────

@test "awg_get_iface: PrivateKey из v1.0 минимального конфига" {
    run awg_get_iface PrivateKey "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    # КРИТИЧНО: base64-padding '=' ДОЛЖЕН сохраняться. WG-ключи — это 32 байта =
    # ровно 44 base64-символа, ВСЕГДА с одним '=' в конце. Если падать без '=',
    # awg-tool отвергает ключ как "invalid key length", awg0 не поднимается.
    # Был исторический баг: awk -F' *= *' срезал padding — починили регулярку.
    assert_output 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA='
}

@test "awg_get_iface: PublicKey тоже сохраняет base64 padding" {
    run awg_get_iface PublicKey "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA='
}

@test "awg_get_iface: Address" {
    run awg_get_iface Address "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output '10.8.0.2/32'
}

@test "awg_get_iface: Jc/Jmin/Jmax (AWG v1.0 obfuscation params)" {
    run awg_get_iface Jc "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '4'
    run awg_get_iface Jmin "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '50'
    run awg_get_iface Jmax "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '1000'
}

@test "awg_get_iface: S1/S2/H1-H4 (header obfuscation)" {
    run awg_get_iface S1 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '100'
    run awg_get_iface H4 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '4567890123'
}

@test "awg_get_iface: отсутствующее поле возвращает пустую строку (не падает)" {
    run awg_get_iface S3 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output ''
}

@test "awg_get_iface: S3/S4 присутствуют в v1.5 конфиге" {
    run awg_get_iface S3 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '11'
    run awg_get_iface S4 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '22'
}

@test "awg_get_iface: I1-I5 (Custom Protocol Signature, AWG v1.5)" {
    run awg_get_iface I1 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '<b 0x0102030405>'
    run awg_get_iface I3 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '<r 64>'
    run awg_get_iface I5 "$FIXTURES/awg-v1.5-full.conf"
    assert_output '<r 32>'
}

@test "awg_get_iface: I1-I5 отсутствуют в v1.0 → пусто" {
    run awg_get_iface I1 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output ''
    run awg_get_iface I5 "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output ''
}

@test "awg_get_iface: AWG 2.0 I1 — комбинация тегов '<r N><b 0x...>' с пробелом" {
    # Реальный формат от Amnezia 2.x: I1 — это concat двух тегов через пробел,
    # пробел ВНУТРИ значения должен сохраниться. Это поле и валит netifd
    # на свежих сборках luci-proto-amneziawg — поэтому парсер обязан его
    # извлекать целиком, а не обрезать по пробелу.
    run awg_get_iface I1 "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_success
    assert_output '<r 2><b 0x8580000100010000000000669636c6f756403636f6d00000100010c000010010000105a00444d583737>'
}

@test "awg_get_iface: AWG 2.0 H1-H4 — диапазоны через дефис сохраняются" {
    # У серверов AWG 2.0 H1..H4 не одиночные числа, а range через '-'.
    # Парсер должен брать значение целиком (важно: разделитель полей и
    # разделитель range в значении — оба символа '-' и '=', не путать).
    run awg_get_iface H1 "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_output '1549251754-1566598344'
    run awg_get_iface H4 "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_output '2076762013-2125117854'
}

@test "awg_get_iface: AWG 2.0 S3/S4 присутствуют и парсятся" {
    run awg_get_iface S3 "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_output '54'
    run awg_get_iface S4 "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_output '12'
}

@test "awg_get_iface: AWG 2.0 I2-I5 отсутствуют (только I1 задан) → пусто" {
    # Распространённый реальный кейс: Amnezia-клиент пишет только I1,
    # остальные I2-I5 не задаёт. Скрипт должен видеть пустоту и не
    # пытаться записать в UCI пустые значения.
    run awg_get_iface I2 "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_output ''
    run awg_get_iface I5 "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_output ''
}

# ─── awg_get_peer — поля после [Peer] маркера ──────────────────────────────

@test "awg_get_peer: PublicKey сохраняет base64 padding" {
    run awg_get_peer PublicKey "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA='
}

@test "awg_get_peer: PresharedKey сохраняет base64 padding" {
    run awg_get_peer PresharedKey "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output 'ccccccccccccccccccccccccccccccccccccccccccA='
}

@test "awg_get_peer: Endpoint (IPv4)" {
    run awg_get_peer Endpoint "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '1.2.3.4:51820'
}

@test "awg_get_peer: PersistentKeepalive" {
    run awg_get_peer PersistentKeepalive "$FIXTURES/awg-v1.0-minimal.conf"
    assert_output '25'
}

@test "awg_get_peer: Endpoint с DNS-именем (v1.5 fixture)" {
    run awg_get_peer Endpoint "$FIXTURES/awg-v1.5-full.conf"
    assert_output 'vpn.example.com:51820'
}

@test "awg_get_peer: отсутствующая [Peer] секция → пусто (не падает)" {
    run awg_get_peer PublicKey "$FIXTURES/awg-incomplete-no-peer.conf"
    assert_success
    assert_output ''
    run awg_get_peer Endpoint "$FIXTURES/awg-incomplete-no-peer.conf"
    assert_success
    assert_output ''
}

@test "awg_get_peer: PresharedKey отсутствует — пусто (PSK опционален)" {
    run awg_get_peer PresharedKey "$FIXTURES/awg-ipv6-endpoint.conf"
    assert_success
    assert_output ''
}

# ─── awg_endpoint_host / awg_endpoint_port ─────────────────────────────────

@test "awg_endpoint_host: IPv4 host:port" {
    run awg_endpoint_host '1.2.3.4:51820'
    assert_success
    assert_output '1.2.3.4'
}

@test "awg_endpoint_port: IPv4 host:port" {
    run awg_endpoint_port '1.2.3.4:51820'
    assert_success
    assert_output '51820'
}

@test "awg_endpoint_host: DNS-имя host:port" {
    run awg_endpoint_host 'vpn.example.com:51820'
    assert_output 'vpn.example.com'
}

@test "awg_endpoint_port: DNS-имя host:port" {
    run awg_endpoint_port 'vpn.example.com:51820'
    assert_output '51820'
}

@test "awg_endpoint_host: IPv6 [::1]:port → '[::1]'" {
    # Bracket-формат — стандарт wg-quick для IPv6. Скобки сохраняются.
    run awg_endpoint_host '[::1]:51820'
    assert_success
    assert_output '[::1]'
}

@test "awg_endpoint_port: IPv6 [::1]:port → '51820'" {
    run awg_endpoint_port '[::1]:51820'
    assert_success
    assert_output '51820'
}

@test "awg_endpoint_host: IPv6 со скобками и полным адресом" {
    run awg_endpoint_host '[2001:db8::cafe]:51820'
    assert_output '[2001:db8::cafe]'
    run awg_endpoint_port '[2001:db8::cafe]:51820'
    assert_output '51820'
}

@test "awg_endpoint: round-trip из реального конфига (IPv6 fixture)" {
    ep="$(awg_get_peer Endpoint "$FIXTURES/awg-ipv6-endpoint.conf")"
    [ "$ep" = '[2001:db8::1]:51820' ]
    [ "$(awg_endpoint_host "$ep")" = '[2001:db8::1]' ]
    [ "$(awg_endpoint_port "$ep")" = '51820' ]
}

# ─── awg_validate_conf — entry-point валидация ───────────────────────────────
# Цель: поймать обрезанный конфиг до того, как 01-amneziawg.sh потратит
# 30 секунд на скачивание и установку apk-пакетов (kmod-amneziawg ~3 МБ).
# Используется обоими entry-point'ами: setup.sh (CLI) и web/rpcd-cheburnet.

@test "awg_validate_conf: полный v1.0 конфиг → success, тишина" {
    run awg_validate_conf "$FIXTURES/awg-v1.0-minimal.conf"
    assert_success
    assert_output ''
}

@test "awg_validate_conf: полный v1.5 конфиг → success" {
    run awg_validate_conf "$FIXTURES/awg-v1.5-full.conf"
    assert_success
    assert_output ''
}

@test "awg_validate_conf: AWG 2.0 конфиг с combined-tag I1 → success" {
    # Регрессия-страховка: пробел внутри значения I1 не должен сбивать
    # entry-point валидацию. Если парсер где-то разрежет по пробелу —
    # awg_validate_conf может ложно поругаться на отсутствие нужного поля.
    run awg_validate_conf "$FIXTURES/awg-v2.0-cps-combined.conf"
    assert_success
    assert_output ''
}

@test "awg_validate_conf: отсутствует файл → ошибка с понятным сообщением" {
    run awg_validate_conf "/nonexistent/foo.conf"
    assert_failure
    [[ "$output" == *"file not found"* ]]
}

@test "awg_validate_conf: нет [Interface] секции → ошибка указывает поле" {
    cat > "$BATS_TEST_TMPDIR/no-iface.conf" <<EOF
[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
Endpoint = 1.2.3.4:51820
EOF
    run awg_validate_conf "$BATS_TEST_TMPDIR/no-iface.conf"
    assert_failure
    [[ "$output" == *"[Interface]"* ]]
}

@test "awg_validate_conf: нет PrivateKey → ошибка указывает поле" {
    cat > "$BATS_TEST_TMPDIR/no-priv.conf" <<EOF
[Interface]
Address = 10.8.0.2/32
[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
Endpoint = 1.2.3.4:51820
EOF
    run awg_validate_conf "$BATS_TEST_TMPDIR/no-priv.conf"
    assert_failure
    [[ "$output" == *PrivateKey* ]]
}

@test "awg_validate_conf: нет [Peer] секции → ошибка указывает поле" {
    run awg_validate_conf "$FIXTURES/awg-incomplete-no-peer.conf"
    assert_failure
    [[ "$output" == *"[Peer]"* ]]
}

@test "awg_validate_conf: нет PublicKey в [Peer] → ошибка указывает поле" {
    cat > "$BATS_TEST_TMPDIR/no-pub.conf" <<EOF
[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=
[Peer]
Endpoint = 1.2.3.4:51820
EOF
    run awg_validate_conf "$BATS_TEST_TMPDIR/no-pub.conf"
    assert_failure
    [[ "$output" == *PublicKey* ]]
}

@test "awg_validate_conf: нет Endpoint в [Peer] → ошибка указывает поле (РЕАЛЬНЫЙ кейс)" {
    # Самый частый «обрезанный» конфиг: пользователь экспортирует только
    # публичную часть пира без endpoint'а. Раньше этот случай проходил
    # entry-point валидацию и падал на 01-amneziawg.sh после ~30 сек установки.
    cat > "$BATS_TEST_TMPDIR/no-ep.conf" <<EOF
[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=
[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=
EOF
    run awg_validate_conf "$BATS_TEST_TMPDIR/no-ep.conf"
    assert_failure
    [[ "$output" == *Endpoint* ]]
}
