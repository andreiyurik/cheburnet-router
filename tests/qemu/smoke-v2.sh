#!/bin/bash
# tests/qemu/smoke-v2.sh — T3a hermetic VM smoke для движка v2 (ucode).
#
# Поднимает свежий OpenWrt snapshot и проверяет то, что юниты и dry-run'ы
# проверить НЕ могут — живой стек: реальный ucode-интерпретатор роутера,
# busybox-уровень (uci/awk/passwd), настоящие ubusd/rpcd, реальный fw4/nft.
# НЕ ходит в интернет: движок кладётся через ssh+cat (tar), apk не зовётся.
#
# Деплой намеренно повторяет раскладку ПАКЕТА (см. package/cheburnet/Makefile):
# движок в /usr/share/cheburnet/engine БЕЗ tests/ и README — ловим случайный
# импорт из tests, который юнит-прогон бы замаскировал.
#
# Что покрывает:
#   • rpcd регистрирует ucode-handler через shim; ubus -v list — все методы REGISTRY.
#   • status/preflight/check_lan_conflict → валидный JSON через настоящий ubusd.
#   • Граница доверия сквозь реальный rpcd: required-поля, токен-гейт, confirm.
#   • steps/rootpass на НАСТОЯЩЕМ busybox passwd + ubus session.login этим
#     паролем (самое слабое допущение v2: дефолтный rpcd даёт root-сессии права).
#   • steps/wifi: честный no-op на VM без радио.
#   • (doh/выбор DNS-провайдера — в T3c-v2: нужен пакет https-dns-proxy с его секцией 'config'.)
#   • steps/firewall: NAT-зона в реальном uci+fw4 reload, цепочки в реальном
#     nft, --teardown вычищает и то и другое.
#
# Что НЕ покрывает (T3b/T3c — отдельно): HTTP-слой /ubus + ACL-инфорсмент
# anon-vs-session, полный install (apk, интернет), реальный AWG-сервер.
#
# Запуск: make qemu-v2  (или ./tests/qemu/smoke-v2.sh из корня репо).
# Время: ~2мин с KVM. При падении — последние 60 строк serial-лога.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

# ─── деплой v2-движка (как пакет: shim + engine без tests/README + ACL) ──────
echo "→ Раскладываю движок v2 (как пакет)"
vm_ssh "command -v rpcd >/dev/null && command -v ubus >/dev/null && command -v ucode >/dev/null" \
    || { echo "✗ snapshot не имеет rpcd/ubus/ucode"; exit 1; }
# fs-модуль ucode обязателен движку (его тянет fw4 — но проверяем явно).
vm_ssh "ucode -e 'import { readfile } from \"fs\"; print(\"fs-ok\")' >/dev/null" \
    || { echo "✗ на snapshot нет ucode-mod-fs"; exit 1; }

vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet \
        /usr/libexec/rpcd /usr/share/rpcd/acl.d"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json"                 "/usr/share/rpcd/acl.d/cheburnet.json"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet"
vm_ssh "/etc/init.d/rpcd restart"
sleep 2

# ─── ассерты: регистрация и read-методы ──────────────────────────────────────
echo "→ assert: ubus cheburnet зарегистрирован"
vm_ssh "ubus list cheburnet >/dev/null" || {
    echo "  logread (последние 30):"; vm_ssh "logread | tail -30"
    exit 1
}

echo "→ assert: ubus -v list — все методы из REGISTRY"
methods="$(vm_ssh 'ubus -v list cheburnet' \
    | sed -nE 's/^[[:space:]]+"([^"]+)":.*$/\1/p' \
    | sort | tr '\n' ' ' | sed 's/ $//')"
# Ожидаемый список выводим из rpcd-acl.json (юнит-тест держит его синхронным с
# REGISTRY) — литеральный список здесь дважды отставал от движка при добавлении методов.
expected="$(python3 -c '
import json
acl = json.load(open("'"$REPO_ROOT"'/engine/ubus/rpcd-acl.json"))
ms = set()
for role in acl.values():
    for sec in ("read", "write"):
        ms |= set(role.get(sec, {}).get("ubus", {}).get("cheburnet", []))
print(" ".join(sorted(ms)))')"
[ "$methods" = "$expected" ] || {
    echo "  expected: $expected"
    echo "  actual:   $methods"
    exit 1
}

echo "→ assert: status → валидный JSON, installed=false, wireless_present=false"
out="$(vm_ssh 'ubus call cheburnet status')"
echo "$out" | python3 -c '
import json,sys
s = json.load(sys.stdin)
assert s["installed"] is False, s
assert s["wireless_present"] is False, "у VM нет радио, а status говорит обратное"
assert s["installing"] is False, s
' || { echo "  output: $out"; exit 1; }

echo "→ assert: preflight → валидный JSON-отчёт (gather на реальном busybox)"
out="$(vm_ssh 'ubus call cheburnet preflight')"
echo "$out" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert "checks" in r and len(r["checks"]) > 0, r
' || { echo "  output: $out"; exit 1; }

echo "→ assert: check_lan_conflict → валидный JSON, conflict=false (WAN нет)"
out="$(vm_ssh 'ubus call cheburnet check_lan_conflict')"
echo "$out" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert r["conflict"] is False, r
' || { echo "  output: $out"; exit 1; }

# ─── ассерты: граница доверия сквозь настоящий rpcd ──────────────────────────
echo "→ assert: install без root_password → отказ валидации"
out="$(vm_ssh 'ubus call cheburnet install '\''{"awg_conf":"x","token":"t"}'\'' ')"
echo "$out" | grep -q 'root_password required' \
    || { echo "  output: $out"; exit 1; }

echo "→ assert: токен-гейт — нет файла токена → понятная ошибка"
out="$(vm_ssh 'ubus call cheburnet install '\''{"awg_conf":"x","root_password":"longenough","token":"t"}'\'' ')"
echo "$out" | grep -q 'токен не найден' \
    || { echo "  output: $out"; exit 1; }

echo "→ assert: токен-гейт — неверное значение → отказ"
vm_ssh 'echo qemu-test-token > /etc/cheburnet/install-token'
out="$(vm_ssh 'ubus call cheburnet install '\''{"awg_conf":"x","root_password":"longenough","token":"WRONG"}'\'' ')"
echo "$out" | grep -q 'неверный install-токен' \
    || { echo "  output: $out"; exit 1; }

echo "→ assert: factory_reset с неверным confirm → отказ"
out="$(vm_ssh 'ubus call cheburnet factory_reset '\''{"confirm":"nope"}'\'' ')"
echo "$out" | grep -q 'RESET' \
    || { echo "  output: $out"; exit 1; }

echo "→ assert: install_cancel без установки → «отменять нечего»"
out="$(vm_ssh 'ubus call cheburnet install_cancel '\''{"token":"qemu-test-token"}'\'' ')"
echo "$out" | grep -q 'отменять нечего' \
    || { echo "  output: $out"; exit 1; }

# ─── factory_reset живьём: отрабатывает и НЕ рушит сеть ──────────────────────
# Регрессия инцидента d4bd0bf/reset: `network reload` вместо restart оставлял роутер без
# интернета после сброса. Единственный «оплаченный» инцидент, не закреплённый тестом:
# здесь reset на живом netifd (идемпотентный teardown на чистой системе) + сеть/rpcd живы.
echo "→ assert: factory_reset (confirm=RESET) — отрабатывает, сеть и rpcd живы"
out="$(vm_ssh 'ubus call cheburnet factory_reset '\''{"confirm":"RESET"}'\'' ')"
echo "$out" | grep -q 'started' \
    || { echo "  output: $out"; exit 1; }
# reset делает network restart → ssh может мигнуть; ждём done-маркер с ретраями.
reset_done=0
for _ in $(seq 1 20); do
    if vm_ssh '[ -f /tmp/cheburnet/done ]' 2>/dev/null; then reset_done=1; break; fi
    sleep 2
done
[ "$reset_done" = "1" ] || { echo "  ✗ reset не записал done-маркер за 40с"; exit 1; }
vm_ssh 'grep -q "^0$" /tmp/cheburnet/done' \
    || { echo "  ✗ reset завершился ненулевым кодом"; vm_ssh 'cat /tmp/cheburnet/install.log 2>/dev/null | tail -10'; exit 1; }
vm_ssh 'ubus call cheburnet status | grep -q installed' \
    || { echo "  ✗ rpcd/status мёртв после reset"; exit 1; }
echo "  ✓ reset отработал, ssh/rpcd живы (network restart не оборвал VM)"
# reset снёс /etc/cheburnet вместе с токеном — восстанавливаем для следующих ассертов.
vm_ssh 'mkdir -p /etc/cheburnet && echo qemu-test-token > /etc/cheburnet/install-token'

# ─── steps/wifi: честный no-op без радио ─────────────────────────────────────
echo "→ assert: wifi-шаг на VM без радио — no-op с кодом 0"
out="$(vm_ssh 'echo '\''{"ssid":"Test","key":"password123"}'\'' | ucode -R /usr/share/cheburnet/engine/steps/wifi/apply.uc')" \
    || { echo "  FAIL: wifi/apply.uc exit != 0 на VM без радио"; exit 1; }
echo "$out" | grep -q 'нет' \
    || { echo "  output: $out"; exit 1; }

# Примечание: doh-шаг (выбор DNS-провайдера) пишет uci https-dns-proxy, секция 'config' которого
# создаётся пакетом — поэтому он проверяется в T3c-v2 (install-v2.sh, пакет установлен), а не
# здесь (hermetic, без apk).

# ─── steps/firewall: NAT-зона + цепочки на РЕАЛЬНОМ fw4/nft + teardown ───────
echo "→ подготовка: возвращаю fw4 (vm_boot_and_setup его стопил) + ssh-правило"
# Наш шаг добавляет цепочки в СУЩЕСТВУЮЩУЮ таблицу inet fw4 — на остановленном
# firewall её нет в ядре. Поднимаем сервис; ssh-доступ страхуем ПОСТОЯННЫМ
# uci-правилом (тестовая обвязка VM): apply делает fw4 reload, который стёр бы
# одноразовое nft-правило, а uci-правило переживает любые reload'ы.
vm_ssh 'uci add firewall rule >/dev/null
        uci set firewall.@rule[-1].name="qemu-ssh"
        uci set firewall.@rule[-1].src="*"
        uci set firewall.@rule[-1].proto="tcp"
        uci set firewall.@rule[-1].dest_port="22"
        uci set firewall.@rule[-1].target="ACCEPT"
        uci commit firewall
        /etc/init.d/firewall start >/dev/null 2>&1; sleep 2
        nft list table inet fw4 >/dev/null' \
    || { echo "  FAIL: fw4 не поднялся"; vm_ssh 'logread | tail -15'; exit 1; }
vm_ssh true || { echo "  FAIL: ssh потерян после старта fw4"; exit 1; }

echo "→ assert: firewall apply — NAT-зона в uci, цепочки в nft (реальный fw4)"
# kill-switch на eth0 безопасен для теста: он в forward-цепочке, а ssh к VM —
# input; established-трафик проходит по ct state.
vm_ssh 'echo '\''{"domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}'\'' | ucode -R /usr/share/cheburnet/engine/steps/firewall/apply.uc' \
    || { echo "  FAIL: firewall/apply.uc exit != 0"; vm_ssh 'logread | tail -20'; exit 1; }
vm_ssh 'uci -q get firewall.cheburnet_vpn >/dev/null' \
    || { echo "  FAIL: uci-зона cheburnet_vpn не создана"; vm_ssh 'uci show firewall | tail -20'; exit 1; }
vm_ssh 'uci -q get firewall.cheburnet_lan_vpn >/dev/null' \
    || { echo "  FAIL: forwarding lan→vpn не создан"; exit 1; }
vm_ssh 'nft list table inet fw4 | grep -q cheburnet_mark' \
    || { echo "  FAIL: цепочка cheburnet_mark не загружена в ядро"; vm_ssh 'nft list table inet fw4 | head -30'; exit 1; }
vm_ssh 'nft list table inet fw4 | grep -q cheburnet_ks' \
    || { echo "  FAIL: kill-switch цепочка не загружена"; exit 1; }

echo "→ assert: firewall apply повторно — идемпотентен (exit 0, без дублей зон)"
vm_ssh 'echo '\''{"domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}'\'' | ucode -R /usr/share/cheburnet/engine/steps/firewall/apply.uc' \
    || { echo "  FAIL: повторный firewall apply exit != 0"; exit 1; }
zone_n="$(vm_ssh 'uci show firewall | grep -o "cheburnet_vpn=zone" | wc -l')"
[ "$zone_n" = "1" ] || { echo "  FAIL: зона продублирована ($zone_n)"; exit 1; }

echo "→ assert: firewall --teardown — снимает и nft-цепочки, и NAT-зону"
vm_ssh 'echo '\''{"domains":[],"routing_opts":{"wan_if":"eth0"}}'\'' | ucode -R /usr/share/cheburnet/engine/steps/firewall/apply.uc --teardown' \
    || { echo "  FAIL: --teardown exit != 0"; exit 1; }
vm_ssh 'uci -q get firewall.cheburnet_vpn >/dev/null' \
    && { echo "  FAIL: зона осталась после teardown"; exit 1; }
vm_ssh 'nft list table inet fw4 | grep -q cheburnet_mark' \
    && { echo "  FAIL: цепочка осталась после teardown"; exit 1; }

# ─── steps/rootpass + session.login — ПОСЛЕДНИМИ и ОДНОЙ ssh-сессией ─────────
# Смена пароля root меняет аутентификацию VM — после неё новые ssh-подключения
# могут не подняться (наблюдали отказ pubkey после busybox passwd). Поэтому:
# riskiest-last + всё в одном vm_ssh: apply → login → диагностика passwd/shadow,
# чтобы при провале причина была в выводе, а не за потерянным ssh.
echo "→ assert: rootpass на реальном passwd → ubus session.login этим паролем"
# Самое слабое допущение v2 (вход в панель): дефолтный rpcd пускает root по
# паролю и выдаёт сессию. Если здесь падает — login-модалка мастера не работает.
out="$(vm_ssh '
  echo "{\"root_password\":\"qemu-test-pass1\"}" | ucode -R /usr/share/cheburnet/engine/steps/rootpass/apply.uc || echo ROOTPASS_FAIL
  echo "--- diag: учётка root после passwd ---"
  grep "^root:" /etc/passwd
  grep "^root:" /etc/shadow | cut -c1-20
  echo "--- session.login ---"
  ubus call session login "{\"username\":\"root\",\"password\":\"qemu-test-pass1\",\"timeout\":300}" || echo LOGIN_CALL_FAIL
')"
echo "$out" | grep -q "ROOTPASS_FAIL" && { echo "  FAIL: rootpass/apply.uc"; echo "$out"; exit 1; }
echo "$out" | grep -q "ubus_rpc_session" \
    || { echo "  FAIL: session.login не выдал сессию"; echo "$out"; exit 1; }

echo
echo "✓ T3a-v2 smoke pass — движок v2 работает на реальном OpenWrt snapshot:"
echo "  rpcd/ubus/ACL, граница доверия, wifi no-op,"
echo "  NAT-зона + nft + teardown, rootpass+session.login."
