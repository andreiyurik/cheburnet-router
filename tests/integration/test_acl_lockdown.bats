#!/usr/bin/env bats
# Сценарии #7, #8 спеки T3 — инвариант ACL.
#
# Реальный rpcd-enforce'ит ACL только в полной OpenWrt-VM (T3b). На уровне
# протокола мы можем гарантировать главное: ACL-файлы (pre-install и тот, что
# setup/install.sh пишет post-install) имеют ПРАВИЛЬНУЮ структуру. Если эти
# инварианты сломаются — атаку через unauth.write словит злоумышленник, не CI.

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

# Извлечь embedded heredoc <<'ACL' из shell-скрипта.
extract_acl_heredoc() {
    sed -n "/<<'ACL'/,/^ACL$/p" "$1" | sed "/<<'ACL'/d;/^ACL$/d"
}

PRE_ACL="$REPO_ROOT/web/rpcd-acl.json"
POST_ACL_RUN="$REPO_ROOT/setup/install.sh"

# ─── Pre-install ACL (web/rpcd-acl.json) ────────────────────────────────────

@test "pre-install ACL: валидный JSON" {
    python3 -m json.tool "$PRE_ACL" >/dev/null
}

@test "pre-install ACL: unauth.read содержит get_status, install_progress, check_lan_conflict" {
    # check_lan_conflict — read-only детект конфликта LAN/WAN, добавлен в
    # unauth: вызывается из web wizard на welcome-экране ДО любой авторизации.
    methods="$(acl_methods "$PRE_ACL" .unauthenticated.read.ubus.cheburnet)"
    [ "$methods" = "check_lan_conflict get_status install_progress" ]
}

@test "pre-install ACL: unauth.write содержит install_start + install_cancel + apply_lan_ip" {
    # apply_lan_ip — destructive (перезапускает сеть), НО гейтится тем же
    # install-токеном, что и install_start. Доступен только до завершения
    # установки (post-install токен удалён → метод сам отказывает).
    methods="$(acl_methods "$PRE_ACL" .unauthenticated.write.ubus.cheburnet)"
    [ "$methods" = "apply_lan_ip install_cancel install_start" ]
}

# Параметризованная проверка: ни один из мутирующих методов НЕ должен попасть
# в unauth.write до установки. Запрещённые методы перечислены явно — если
# завтра в unauth.write попадёт mode_switch, тест #4 покраснеет.
# apply_lan_ip намеренно НЕ в списке: он разрешён в unauth с install-token-
# защитой (как install_start), это сознательная архитектурная декорация.
@test "pre-install ACL: НЕТ запрещённых методов в unauth.write" {
    for forbidden in mode_switch factory_reset set_blocklist_tier service_restart replace_awg_conf; do
        if acl_has "$PRE_ACL" .unauthenticated.write.ubus.cheburnet "$forbidden"; then
            echo "FAIL: '$forbidden' попал в pre-install unauth.write" >&2
            return 1
        fi
    done
}

# ─── Post-install ACL (записан setup/install.sh) ────────────────────────────

@test "post-install ACL: heredoc в setup/install.sh — валидный JSON" {
    extract_acl_heredoc "$POST_ACL_RUN" | python3 -m json.tool >/dev/null
}

@test "post-install ACL: unauth.write ОТСУТСТВУЕТ — мутации только через login" {
    body="$(extract_acl_heredoc "$POST_ACL_RUN")"
    printf '%s' "$body" | python3 -c '
import json, sys
acl = json.load(sys.stdin)
write = acl.get("unauthenticated", {}).get("write")
assert write is None or write == {} or write == {"ubus": {}}, \
    f"unauth.write present in post-install ACL: {write}"
'
}

@test "post-install ACL: unauth.read содержит ТОЛЬКО get_status + install_progress" {
    methods="$(extract_acl_heredoc "$POST_ACL_RUN" \
               | acl_methods_in_stdin .unauthenticated.read.ubus.cheburnet)"
    [ "$methods" = "get_status install_progress" ]
}

@test "post-install ACL: cheburnet-admin.write содержит ВСЕ мутирующие методы" {
    methods="$(extract_acl_heredoc "$POST_ACL_RUN" \
               | acl_methods_in_stdin .cheburnet-admin.write.ubus.cheburnet)"
    expected="factory_reset install_cancel install_start mode_switch replace_awg_conf service_restart set_blocklist_tier set_family_filter"
    [ "$methods" = "$expected" ]
}

@test "post-install ACL: cheburnet-admin.read покрывает get_status + install_progress" {
    methods="$(extract_acl_heredoc "$POST_ACL_RUN" \
               | acl_methods_in_stdin .cheburnet-admin.read.ubus.cheburnet)"
    [ "$methods" = "get_status install_progress" ]
}

# ─── install-токен: post-install контракт ───────────────────────────────────

@test "post-install: setup/install.sh удаляет install-токен (grep'ом по коду)" {
    grep -q "rm -f /etc/cheburnet/install-token" "$POST_ACL_RUN"
}

@test "install.sh создаёт install-токен (32 hex символа, chmod 600)" {
    # Корневой install.sh (web-bootstrap, не setup/install.sh) — генерит
    # одноразовый install-токен на /etc/cheburnet/install-token перед запуском
    # веб-мастера. Раньше этот файл назывался bootstrap.sh — тест отстал
    # от ренейма, теперь поправлен.
    grep -q "head -c 16 /dev/urandom" "$REPO_ROOT/install.sh"
    grep -q 'chmod 600 /etc/cheburnet/install-token' "$REPO_ROOT/install.sh"
}
