#!/usr/bin/env bats
# Контракт LAN/WAN-conflict-детектора и связанных RPC-методов.
#
# Покрывает:
#   • net_detect_lan_conflict (lib/net-detect.sh) — детект конфликта подсетей
#     при каскаде «главный роутер → OpenWrt-роутер».
#   • net_apply_new_lan_ip (lib/net-detect.sh) — applier нового LAN-IP.
#   • check_lan_conflict RPC (web/rpcd-cheburnet) — read-only обёртка
#     детектора, доступна unauth (для welcome-экрана web wizard).
#   • apply_lan_ip RPC (web/rpcd-cheburnet) — применение нового IP с
#     валидацией формата и install-token-гейтингом.
#
# Этот код критически важен для надёжности первой установки: если детектор
# даст false positive — юзер случайно сменит LAN-IP без необходимости и
# потеряет связь с роутером. Если даст false negative — пользователь дойдёт
# до preflight в install.sh, получит abort, потеряет введённые VPN-конфиг,
# пароль и Wi-Fi-настройки.

load 'helpers/sandbox'

setup() {
    sandbox_init
    # Каталог для ubus-mock state (WAN IP-адреса разных тестов)
    mkdir -p "$FAKE_ROOT/ubus-state"
}

teardown() {
    sandbox_cleanup
}

# ─── net_detect_lan_conflict ────────────────────────────────────────────────

# Helper: source net-detect.sh в bats-shell (тестируем функции напрямую,
# без обёртки RPC). При этом сохраняется доступ к mock'ам uci/ubus/jsonfilter
# (они на PATH через sandbox_init).
_source_net_detect() {
    # shellcheck source=../../lib/net-detect.sh
    . "$REPO_ROOT/lib/net-detect.sh"
}

@test "net_detect_lan_conflict: WAN не поднят (нет ipv4-address) → нет конфликта" {
    # Мок ubus возвращает up:false и пустой ipv4-address[] — типичная
    # ситуация: установка началась до того, как DHCP-аренда на WAN пришла.
    _source_net_detect
    run net_detect_lan_conflict
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "net_detect_lan_conflict: разные /24-подсети → нет конфликта" {
    # WAN от провайдера в 10.x, LAN в дефолтных 192.168.1.x — НЕТ конфликта.
    echo "10.0.42.7" > "$FAKE_ROOT/ubus-state/wan-ipv4-address"
    uci set network.lan.ipaddr=192.168.1.1/24

    _source_net_detect
    run net_detect_lan_conflict
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "net_detect_lan_conflict: одна /24 → конфликт, печатает 3 поля" {
    # Каноничный случай: главный роутер 192.168.1.1, выдал нам WAN 192.168.1.42,
    # LAN OpenWrt по умолчанию 192.168.1.1/24. Должен вернуть rc=1 и три поля
    # "WAN_IP LAN_IP SUGGEST_IP".
    echo "192.168.1.42" > "$FAKE_ROOT/ubus-state/wan-ipv4-address"
    uci set network.lan.ipaddr=192.168.1.1/24

    _source_net_detect
    run net_detect_lan_conflict
    [ "$status" -eq 1 ]
    [ "$output" = "192.168.1.42 192.168.1.1 192.168.2.1" ]
}

@test "net_detect_lan_conflict: WAN в 192.168.2.x → suggest пропускает 2, берёт 3" {
    # Каскад в 192.168.2.0/24 (нестандартный главный роутер) и наш LAN тоже
    # случайно перешёл на 192.168.2.1 → детектор должен предложить .3.1,
    # пропустив октет, занятый WAN.
    echo "192.168.2.55" > "$FAKE_ROOT/ubus-state/wan-ipv4-address"
    uci set network.lan.ipaddr=192.168.2.1/24

    _source_net_detect
    run net_detect_lan_conflict
    [ "$status" -eq 1 ]
    [ "$output" = "192.168.2.55 192.168.2.1 192.168.3.1" ]
}

@test "net_detect_lan_conflict: CIDR-форма LAN срезается перед сравнением" {
    # uci может вернуть 192.168.1.1/24 — функция должна срезать /24 ДО того
    # как делать cut -d. -f1-3. Без среза префикс получился бы "192.168.1/24"
    # и не совпал бы с WAN-префиксом.
    echo "192.168.1.100" > "$FAKE_ROOT/ubus-state/wan-ipv4-address"
    uci set network.lan.ipaddr=192.168.1.1/24

    _source_net_detect
    run net_detect_lan_conflict
    [ "$status" -eq 1 ]
    # Проверяем, что LAN_IP в выводе без маски (срез сработал)
    [ "${output#* }" = "192.168.1.1 192.168.2.1" ]
}

# ─── net_apply_new_lan_ip ───────────────────────────────────────────────────

@test "net_apply_new_lan_ip: без аргумента → return 1 + stderr-message" {
    _source_net_detect
    run net_apply_new_lan_ip ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"ip argument required"* ]]
}

@test "net_apply_new_lan_ip: валидный IP → uci set + commit + setsid restart" {
    _source_net_detect
    run net_apply_new_lan_ip "192.168.7.1"
    [ "$status" -eq 0 ]

    # uci.set был вызван с новым адресом
    assert_mock_called uci "set network.lan.ipaddr=192.168.7.1"
    # uci.commit network — тоже
    assert_mock_called uci "commit network"
    # setsid — да (фоновый рестарт)
    assert_mock_called setsid "sleep 3"
}

# ─── check_lan_conflict RPC ─────────────────────────────────────────────────

@test "check_lan_conflict RPC: нет ubus → conflict:false (graceful degradation)" {
    # Без ubus-state файла мок возвращает {ipv4-address:[]} → детектор
    # должен вернуть «нет конфликта», RPC обёртка — {conflict: false}.
    run run_rpcd check_lan_conflict
    assert_success
    assert_json_field "$output" .conflict "false"
}

@test "check_lan_conflict RPC: разные подсети → conflict:false" {
    echo "10.0.0.5" > "$FAKE_ROOT/ubus-state/wan-ipv4-address"
    uci set network.lan.ipaddr=192.168.1.1/24

    run run_rpcd check_lan_conflict
    assert_success
    assert_json_field "$output" .conflict "false"
}

@test "check_lan_conflict RPC: конфликт → все три поля в JSON" {
    echo "192.168.1.99" > "$FAKE_ROOT/ubus-state/wan-ipv4-address"
    uci set network.lan.ipaddr=192.168.1.1/24

    run run_rpcd check_lan_conflict
    assert_success
    assert_json_field "$output" .conflict "true"
    assert_json_field "$output" .wan_ip "192.168.1.99"
    assert_json_field "$output" .lan_ip "192.168.1.1"
    assert_json_field "$output" .suggest_ip "192.168.2.1"
}

# ─── apply_lan_ip RPC ───────────────────────────────────────────────────────

@test "apply_lan_ip RPC: нет токена в state → 'install token not found'" {
    # Токен НЕ установлен (sandbox_set_token не вызван).
    run run_rpcd apply_lan_ip '{"ip":"192.168.2.1","token":"deadbeefdeadbeefdeadbeefdeadbeef"}'
    assert_success
    assert_output --partial "install token not found"
}

@test "apply_lan_ip RPC: неверный токен → 'invalid install token'" {
    sandbox_set_token "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    run run_rpcd apply_lan_ip '{"ip":"192.168.2.1","token":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    assert_success
    assert_output --partial "invalid install token"
}

@test "apply_lan_ip RPC: пустой ip → ошибка валидации формата" {
    sandbox_set_token "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    run run_rpcd apply_lan_ip '{"ip":"","token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    assert_success
    assert_output --partial "ip must be 192.168"
}

@test "apply_lan_ip RPC: ip вне 192.168.x.y → ошибка валидации" {
    # Защита от подделанного запроса: 10.0.0.1 валиден сам по себе, но мы
    # принимаем ТОЛЬКО 192.168.X.Y чтобы предотвратить случайный кирпич роутера.
    sandbox_set_token "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    run run_rpcd apply_lan_ip '{"ip":"10.0.0.1","token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    assert_success
    assert_output --partial "ip must be 192.168"
}

@test "apply_lan_ip RPC: shell-инъекция в ip отвергается валидацией" {
    sandbox_set_token "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    # Инъекция через ip — попытка пробить uci set. Должна не пройти case-фильтр.
    run run_rpcd apply_lan_ip '{"ip":"192.168.2.1; rm -rf /","token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    assert_success
    assert_output --partial "ip must be 192.168"
}

@test "apply_lan_ip RPC: валидный токен + ip → 'applied' + uci set" {
    sandbox_set_token "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    run run_rpcd apply_lan_ip '{"ip":"192.168.7.1","token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    assert_success
    assert_json_field "$output" .status "applied"
    assert_json_field "$output" .new_ip "192.168.7.1"
    # uci реально вызван с новым адресом — не просто JSON-отчёт
    assert_mock_called uci "set network.lan.ipaddr=192.168.7.1"
    assert_mock_called setsid "sleep 3"
}
