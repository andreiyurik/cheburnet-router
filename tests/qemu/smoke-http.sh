#!/bin/bash
# tests/qemu/smoke-http.sh — T3b VM smoke с HTTP/ubus.
#
# Расширение T3a: всё что в smoke.sh ПЛЮС — что РЕАЛЬНО делают кнопки в UI,
# через тот же путь что у браузера: HTTP-POST на /ubus с JSON-RPC payload.
#
# Что покрывает (а T3a — нет):
#   • uhttpd-mod-ubus поднимается и слушает /ubus.
#   • web/index.html действительно отдаётся uhttpd'ом по /cheburnet/.
#   • ACL-инфорсмент: anon может read-методы, не может mode_switch /
#     service_restart / set_blocklist_tier / factory_reset.
#   • Login через session.login возвращает ubus_rpc_session.
#   • Хендлер-уровневая валидация: factory_reset c неправильным confirm
#     возвращает error (НЕ запускает firstboot), mode_switch на invalid
#     mode возвращает error, install_start без токена — "install token
#     not found".
#   • JSON-RPC round-trip через реальный uhttpd→ubusd→rpcd→хендлер→sed→…
#
# Что НЕ покрывает:
#   • Рендеринг (CSS, onclick handlers, race conditions в браузере).
#   • Полный setup/01-09. Это уровень T3c (manual pre-release smoke).
#
# В отличие от smoke.sh, ЭТОТ скрипт NOT hermetic — нужен интернет
# для apk update + apk add uhttpd-mod-ubus.
#
# Запуск: make qemu-http
# Время: ~3 мин с KVM (apk занимает основное время).

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

# Корневой пароль для session.login. Генерим random — даже если тест упадёт
# и оставит роль активной, она привязана к этой VM, которая будет уничтожена.
ROOT_PASS="cheburnetTest$$$(date +%s)"
ANON_SESSION="00000000000000000000000000000000"

# ─── HTTP / JSON-RPC helpers ─────────────────────────────────────────────────
http_ubus() {
    # http_ubus SESSION OBJECT METHOD [JSON_ARGS]
    # Возвращает целиком JSON-RPC response (для дальнейшего парсинга).
    local session="$1" object="$2" method="$3" args="${4:-{\}}"
    curl -fsS --max-time 15 -X POST "http://127.0.0.1:$HTTP_PORT/ubus" \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$session\",\"$object\",\"$method\",$args]}"
}

# Нормализует JSON-RPC response → ubus result code.
#   {"result":[N, data]}            → N
#   {"error":{"code":-32002,...}}   → 6   (ACL отказ на JSON-RPC уровне)
#   {"error":...} прочее             → -1  (другая RPC-ошибка)
# Та же логика что в web/index.html::rpcRaw().
ubus_result_code() { python3 -c '
import json, sys
r = json.load(sys.stdin)
if "result" in r:
    print(r["result"][0])
elif "error" in r and r["error"].get("code") == -32002:
    print(6)
else:
    print(-1)
'; }

ubus_result_data() { python3 -c '
import json, sys
r = json.load(sys.stdin)
if "result" in r and len(r["result"]) > 1:
    print(json.dumps(r["result"][1]))
else:
    print("{}")
'; }

# Ассерт-утилита: code + (опционально) python-выражение по data.
assert_ubus() {
    local label="$1" expected_code="$2" data_check="${3:-}" response="$4"
    local code; code="$(echo "$response" | ubus_result_code)"
    if [ "$code" != "$expected_code" ]; then
        echo "  ✗ $label: ожидал code=$expected_code, получил $code"
        echo "    response: $response"
        exit 1
    fi
    if [ -n "$data_check" ]; then
        local data; data="$(echo "$response" | ubus_result_data)"
        if ! echo "$data" | python3 -c "import json,sys; d=json.load(sys.stdin); assert ($data_check), 'check failed'" 2>/dev/null; then
            echo "  ✗ $label: data-check '$data_check' не прошёл"
            echo "    data: $data"
            exit 1
        fi
    fi
    echo "  ✓ $label"
}

# ─── bringup (общий с T3a) ───────────────────────────────────────────────────
vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

# ─── HTTP-уровень: uhttpd-mod-ubus + конфиг + web-UI ─────────────────────────
echo "→ apk update + uhttpd-mod-ubus (нужен интернет в VM)"
vm_ssh 'apk update -q' >/dev/null
# uhttpd-mod-ubus: HTTP-bridge для ubus. jsonfilter и rpcd обычно уже стоят
# в snapshot, но на всякий случай — apk add no-op'нет если уже установлено.
vm_ssh 'apk add --no-interactive uhttpd-mod-ubus jsonfilter' >/dev/null

echo "→ Включаю /ubus endpoint в uhttpd"
vm_ssh "uci set uhttpd.main.ubus_prefix='/ubus' && uci commit uhttpd"

echo "→ Раздаю web/index.html в /www/cheburnet/"
vm_ssh "mkdir -p /www/cheburnet"
vm_scp "$REPO_ROOT/web/index.html" "/www/cheburnet/index.html"

vm_deploy_handler

# В проде после установки setup/install.sh заменяет начальный ACL на post-install
# (anon read-only, мутации требуют login через cheburnet-admin role). UI после
# установки работает именно с этой конфигурацией — её мы и тестируем здесь.
echo "→ Подменяю ACL на post-install (anon read-only, admin требует login)"
vm_ssh 'cat > /usr/share/rpcd/acl.d/cheburnet.json' <<'ACL'
{
    "unauthenticated": {
        "description": "cheburnet read-only status (post-install LAN-локально)",
        "read": { "ubus": { "cheburnet": ["get_status", "install_progress"] } }
    },
    "cheburnet-admin": {
        "description": "cheburnet admin (login as root required)",
        "read":  { "ubus": { "cheburnet": ["get_status", "install_progress"] } },
        "write": { "ubus": { "cheburnet": ["install_start", "install_cancel", "mode_switch", "service_restart", "set_blocklist_tier", "factory_reset", "replace_awg_conf"] } }
    }
}
ACL
vm_ssh "/etc/init.d/rpcd restart"
sleep 2

echo "→ Перезапуск uhttpd"
vm_ssh "/etc/init.d/uhttpd restart"
sleep 2

echo "→ Установка пароля root для session.login"
vm_ssh "printf '%s\n%s\n' '$ROOT_PASS' '$ROOT_PASS' | passwd root >/dev/null 2>&1"

echo "→ Жду HTTP на :$HTTP_PORT"
vm_wait_tcp "$HTTP_PORT" 30

# ─── ассерты ─────────────────────────────────────────────────────────────────

echo
echo "── 1. Static страница доступна ──"
# Запрашиваем явно index.html — uhttpd на OpenWrt не всегда делает
# auto-redirect `/path/` → `/path/index.html` по умолчанию.
http_code="$(curl -sS -o /tmp/cheb-http-body --max-time 10 -w '%{http_code}' \
    "http://127.0.0.1:$HTTP_PORT/cheburnet/index.html" 2>&1 || true)"
if [ "$http_code" = "200" ] && grep -q 'cheburnet-router' /tmp/cheb-http-body; then
    echo "  ✓ /cheburnet/index.html отдан uhttpd'ом ($(wc -c < /tmp/cheb-http-body) байт)"
else
    echo "  ✗ /cheburnet/index.html не отдан (HTTP $http_code)"
    echo "  body (первые 200 байт):"
    head -c 200 /tmp/cheb-http-body 2>/dev/null
    echo
    echo "  что в /www/cheburnet/ на VM:"
    vm_ssh "ls -la /www/cheburnet/" 2>&1 || true
    rm -f /tmp/cheb-http-body
    exit 1
fi
rm -f /tmp/cheb-http-body

echo
echo "── 2. Anon read-методы (get_status, install_progress) ──"
resp="$(http_ubus "$ANON_SESSION" cheburnet get_status)"
assert_ubus "anon get_status: code=0" 0 \
    'd.get("install_token_required") in (True, False)' \
    "$resp"

resp="$(http_ubus "$ANON_SESSION" cheburnet install_progress)"
assert_ubus "anon install_progress: code=0, step=idle" 0 \
    'd["step"] == "idle"' \
    "$resp"

echo
echo "── 3. Anon write-методы (mode_switch, factory_reset) — ACL должен запретить ──"
# UBUS_STATUS_PERMISSION_DENIED = 6
resp="$(http_ubus "$ANON_SESSION" cheburnet mode_switch '{"mode":"home"}')"
assert_ubus "anon mode_switch: code=6 (permission denied)" 6 "" "$resp"

# Самое важное место теста: даже с confirm='RESET' anon НЕ должен запустить
# firstboot. ACL должен сработать ДО того как handler увидит confirm.
resp="$(http_ubus "$ANON_SESSION" cheburnet factory_reset '{"confirm":"RESET"}')"
assert_ubus "anon factory_reset(confirm=RESET): code=6 (ACL блокирует ДО handler'а)" 6 "" "$resp"

resp="$(http_ubus "$ANON_SESSION" cheburnet service_restart '{"service":"vpn"}')"
assert_ubus "anon service_restart: code=6" 6 "" "$resp"

resp="$(http_ubus "$ANON_SESSION" cheburnet set_blocklist_tier '{"tier":"pro"}')"
assert_ubus "anon set_blocklist_tier: code=6" 6 "" "$resp"

resp="$(http_ubus "$ANON_SESSION" cheburnet replace_awg_conf '{"awg_conf":"x"}')"
assert_ubus "anon replace_awg_conf: code=6 (ACL блокирует ДО handler'а)" 6 "" "$resp"

echo
echo "── 4. Login через session.login ──"
login_resp="$(http_ubus "$ANON_SESSION" session login \
    "{\"username\":\"root\",\"password\":\"$ROOT_PASS\",\"timeout\":3600}")"
SESSION="$(echo "$login_resp" | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
assert r[0] == 0, f"login code={r[0]} response={r}"
print(r[1]["ubus_rpc_session"])
')" || { echo "  ✗ login failed: $login_resp"; exit 1; }
echo "  ✓ session = ${SESSION:0:8}…"

echo
echo "── 5. Authed: handler-уровневая валидация без destructive-эффекта ──"

# factory_reset с пустым/левым confirm: handler возвращает {"error":...}
# ВНУТРИ data (code=0 от RPC, потому что вызов прошёл, но семантически error).
# КРИТИЧНО: не передавать confirm="RESET" с auth — это реально запустит
# firstboot и убьёт VM.
resp="$(http_ubus "$SESSION" cheburnet factory_reset '{"confirm":""}')"
assert_ubus 'authed factory_reset(confirm=""): handler error в data' 0 \
    'd.get("error", "").startswith("confirm")' \
    "$resp"

resp="$(http_ubus "$SESSION" cheburnet factory_reset '{"confirm":"WRONG"}')"
assert_ubus 'authed factory_reset(confirm=WRONG): handler error в data' 0 \
    'd.get("error", "").startswith("confirm")' \
    "$resp"

resp="$(http_ubus "$SESSION" cheburnet mode_switch '{"mode":"invalid"}')"
assert_ubus 'authed mode_switch(mode=invalid): handler error в data' 0 \
    'd.get("error", "").startswith("mode")' \
    "$resp"

resp="$(http_ubus "$SESSION" cheburnet set_blocklist_tier '{"tier":"definitely-not-a-tier"}')"
assert_ubus 'authed set_blocklist_tier(tier=invalid): handler error' 0 \
    'd.get("error", "").startswith("tier")' \
    "$resp"

# replace_awg_conf под admin-сессией без VPN-установки. На VM в smoke-http
# /etc/amnezia/amneziawg/awg0.conf нет (T3b не делает полный install),
# поэтому handler должен пройти ACL и упереться в pre-flight.
resp="$(http_ubus "$SESSION" cheburnet replace_awg_conf '{}')"
assert_ubus 'authed replace_awg_conf без awg_conf или без VPN: handler error' 0 \
    '"required" in d.get("error", "").lower() or "не установлен" in d.get("error", "")' \
    "$resp"

# replace_awg_conf с обрезанным conf — в любом случае должна быть handler error
# (либо pre-flight «VPN не установлен», либо awg_validate_conf «is missing»).
resp="$(http_ubus "$SESSION" cheburnet replace_awg_conf '{"awg_conf":"[Interface]\nPrivateKey = aaa"}')"
assert_ubus 'authed replace_awg_conf с обрезанным conf: handler error' 0 \
    'd.get("error", "") != ""' \
    "$resp"

echo
echo "── 6. install_start под admin без install-token → handler reject ──"
# В post-install ACL anon не может install_start — это admin-метод. Под
# логином хендлер должен отказать "install token not found", потому что
# /etc/cheburnet/install-token мы не клали.
payload='{"token":"deadbeef","ssid":"X","wifi_key":"longenough","country":"RU","awg_conf":"x","root_pass":"longenough"}'
resp="$(http_ubus "$SESSION" cheburnet install_start "$payload")"
assert_ubus 'authed install_start без token-файла: handler error' 0 \
    '"install token" in d.get("error", "").lower() or "token" in d.get("error", "").lower()' \
    "$resp"

echo
echo "── 7. Sanity: VM всё ещё жива (никакой firstboot не запустился) ──"
# Если firstboot реально случился, uhttpd упал бы вместе с reboot'ом и
# /ubus перестал бы отвечать. Достаточно проверить ubus-call через HTTP —
# не зависит от состояния SSH-сессий. Делаем 5 retry'ев на случай
# временного network glitch'а после серии restart'ов.
ok=0
for i in 1 2 3 4 5; do
    code="$(http_ubus "$ANON_SESSION" cheburnet get_status 2>/dev/null | ubus_result_code 2>/dev/null || echo "")"
    if [ "$code" = "0" ]; then ok=1; break; fi
    sleep 2
done
if [ "$ok" = 1 ]; then
    echo "  ✓ ubus.cheburnet.get_status всё ещё отвечает (попыток: $i)"
else
    echo "  ✗ /ubus не отвечает после 5 попыток — возможно случайно triggered firstboot"
    exit 1
fi

echo
echo "✓ T3b smoke-http pass — UI-кнопки → ubus через HTTP работают, ACL и handler-валидация на месте."
