#!/bin/bash
# tests/qemu/webui-v2.sh — T3b-v2: HTTP-слой веб-мастера v2 через настоящий uhttpd.
#
# Расширение smoke-v2 (T3a-v2) тем, что юниты движка и ubus-смоук проверить НЕ могут:
# путь БРАУЗЕРА. Тот же транспорт, что у web-v2/src/lib/ubus.js — HTTP POST /ubus
# (JSON-RPC) через uhttpd-mod-ubus, плюс раздача Svelte-бандла по /cheburnet/.
#
# Что покрывает:
#   • uhttpd отдаёт index.html и hashed-ассеты бандла (то, что реально в пакете).
#   • ACL-инфорсмент через HTTP: anon может read (status/preflight) и install
#     (гейтится токеном на уровне обработчика), НЕ может admin-методы (set_mode…).
#   • session.login: неверный пароль → отказ; верный → ubus_rpc_session,
#     с которой admin-метод (service_restart) проходит.
#   • Хендлер-валидация сквозь HTTP: install без токена → доменная ошибка,
#     factory_reset с неверным confirm → доменная ошибка (сброс НЕ запускается).
#
# Что НЕ покрывает: рендеринг/клики в браузере (уровень Playwright, отдельно),
# полный install (T3c: install-v2.sh).
#
# NOT hermetic — нужен интернет в VM для apk add uhttpd-mod-ubus.
# Запуск: make qemu-webui-v2. Время: ~3 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

# Пароль root для session.login. Random — VM одноразовая.
ROOT_PASS="cheburnetTest$$$(date +%s)"
ANON_SESSION="00000000000000000000000000000000"

# ─── HTTP / JSON-RPC helpers (как в web-v2/src/lib/ubus.js) ──────────────────
http_ubus() {
    # http_ubus SESSION OBJECT METHOD [JSON_ARGS] → JSON-RPC response целиком
    local session="$1" object="$2" method="$3" args="${4:-{\}}"
    curl -fsS --max-time 15 -X POST "http://127.0.0.1:$HTTP_PORT/ubus" \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$session\",\"$object\",\"$method\",$args]}"
}

# JSON-RPC response → ubus result code (−32002 на RPC-уровне = отказ ACL → 6).
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

assert_ubus() {
    # assert_ubus LABEL EXPECTED_CODE [PY_DATA_CHECK] RESPONSE
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

# ─── bringup ─────────────────────────────────────────────────────────────────
vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

echo "→ apk update + uhttpd/uhttpd-mod-ubus (нужен интернет в VM)"
# До 5 попыток с паузой: user-mode сеть qemu флейкает после boot, а загрузка с
# downloads.openwrt.org из фильтрующих сетей рвётся посреди передачи (EPERM/EOF).
# if, не `[ ... ] && …`: ложное условие вернуло бы 1 и set -e убил бы скрипт (CLAUDE.md).
apk_retry() {
    local label="$1" cmd="$2" i
    for i in 1 2 3 4 5; do
        if vm_ssh "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$i" = 5 ]; then
            echo "  ✗ $label не прошёл за 5 попыток — интернет в VM отсутствует"
            echo "    или downloads.openwrt.org недоступен из этой сети"; exit 1
        fi
        echo "  … $label не прошёл (попытка $i), жду 10с"
        sleep 10
    done
}
apk_retry "apk update" 'apk update -q'
apk_retry "apk add uhttpd" 'apk add --no-interactive uhttpd uhttpd-mod-ubus'

# ─── деплой v2 как пакета: движок + shim + ACL + web-бандл ───────────────────
echo "→ Раскладываю движок v2 и web-бандл (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet \
        /usr/libexec/rpcd /usr/share/rpcd/acl.d /www/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json"                 "/usr/share/rpcd/acl.d/cheburnet.json"
tar -C "$REPO_ROOT/package/cheburnet/files/web" -cf - . \
    | vm_ssh "tar -C /www/cheburnet -xf -"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet"

echo "→ Включаю /ubus endpoint в uhttpd, рестарт rpcd/uhttpd"
vm_ssh "uci set uhttpd.main.ubus_prefix='/ubus' && uci commit uhttpd"
vm_ssh "/etc/init.d/rpcd restart"
vm_ssh "/etc/init.d/uhttpd restart"
sleep 2

# ─── статика: бандл реально раздаётся ────────────────────────────────────────
echo "→ assert: uhttpd раздаёт мастер по /cheburnet/"
index="$(curl -fsS --max-time 15 "http://127.0.0.1:$HTTP_PORT/cheburnet/")"
echo "$index" | grep -q "cheburnet" || { echo "  ✗ index.html не похож на мастер"; exit 1; }
asset="$(echo "$index" | grep -o 'assets/index-[^"]*\.js' | head -1)"
[ -n "$asset" ] || { echo "  ✗ в index.html нет ссылки на JS-бандл"; exit 1; }
curl -fsS --max-time 15 -o /dev/null "http://127.0.0.1:$HTTP_PORT/cheburnet/$asset" \
    || { echo "  ✗ JS-бандл ($asset) не отдаётся"; exit 1; }
echo "  ✓ index.html + $asset отдаются"

# ─── ACL: anon-права ровно как в rpcd-acl.json ───────────────────────────────
echo "→ assert: anon read-методы работают через HTTP"
assert_ubus "anon status"    0 "'installed' in d" "$(http_ubus "$ANON_SESSION" cheburnet status)"
assert_ubus "anon preflight" 0 "'checks' in d"    "$(http_ubus "$ANON_SESSION" cheburnet preflight)"

echo "→ assert: anon НЕ может admin-методы (ACL-инфорсмент)"
assert_ubus "anon set_mode → PERMISSION_DENIED"        6 "" "$(http_ubus "$ANON_SESSION" cheburnet set_mode '{"mode":"home"}')"
assert_ubus "anon service_restart → PERMISSION_DENIED" 6 "" "$(http_ubus "$ANON_SESSION" cheburnet service_restart '{"service":"dns"}')"
assert_ubus "anon factory_reset → PERMISSION_DENIED"   6 "" "$(http_ubus "$ANON_SESSION" cheburnet factory_reset '{"confirm":"RESET"}')"

echo "→ assert: anon install разрешён ACL, но гейтится токеном (доменная ошибка)"
assert_ubus "anon install без валидного токена → error" 0 "'error' in d" \
    "$(http_ubus "$ANON_SESSION" cheburnet install '{"awg_conf":"x","root_password":"12345678","token":"WRONG"}')"

# ─── session.login: отказ и успех ────────────────────────────────────────────
echo "→ Ставлю пароль root и проверяю session.login через HTTP"
vm_ssh "printf '%s\n%s\n' '$ROOT_PASS' '$ROOT_PASS' | passwd root >/dev/null 2>&1"

wrong="$(http_ubus "$ANON_SESSION" session login '{"username":"root","password":"WRONG-PASS","timeout":3600}')"
wrong_code="$(echo "$wrong" | ubus_result_code)"
wrong_sess="$(echo "$wrong" | ubus_result_data | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ubus_rpc_session",""))')"
if [ "$wrong_code" = "0" ] && [ -n "$wrong_sess" ]; then
    echo "  ✗ login с неверным паролем выдал сессию"; exit 1
fi
echo "  ✓ login с неверным паролем отвергнут (code=$wrong_code)"

good="$(http_ubus "$ANON_SESSION" session login "{\"username\":\"root\",\"password\":\"$ROOT_PASS\",\"timeout\":3600}")"
SESSION="$(echo "$good" | ubus_result_data | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ubus_rpc_session",""))')"
[ -n "$SESSION" ] || { echo "  ✗ login с верным паролем не дал сессию"; echo "    $good"; exit 1; }
echo "  ✓ session.login выдал сессию"

echo "→ assert: с сессией admin-метод проходит"
assert_ubus "admin service_restart(dns)" 0 "d.get('status') == 'restarted'" \
    "$(http_ubus "$SESSION" cheburnet service_restart '{"service":"dns"}')"

echo "→ assert: хендлер-валидация сквозь HTTP (сброс не запускается без RESET)"
assert_ubus "admin factory_reset(confirm=WRONG) → error" 0 "'error' in d" \
    "$(http_ubus "$SESSION" cheburnet factory_reset '{"confirm":"WRONG"}')"
# ВАЖНО: vm_ssh здесь больше нельзя — busybox passwd ломает новые ssh-подключения
# к VM (урок smoke-v2: rootpass строго последним). Целостность проверяем по HTTP:
# доменная ошибка выше = reset не спавнился, а живой status подтверждает, что
# обработчик и файлы на месте.
assert_ubus "status жив после отклонённого сброса" 0 "'installed' in d" \
    "$(http_ubus "$ANON_SESSION" cheburnet status)"

echo
echo "✅ T3b-v2 ЗЕЛЁНЫЙ: uhttpd раздаёт бандл, ACL держит границу anon/admin,"
echo "   session.login работает, валидация обработчика видна сквозь HTTP."
# cleanup VM делает trap EXIT из vm_lib_init
