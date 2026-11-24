#!/usr/bin/env bash
# tests/qemu/upgrade.sh — T3m: обновление поверх НАСТРОЕННОГО роутера тем путём, что у пользователя:
# релизный пакет FROM_VERSION → «настроено» → текущий bootstrap ставит новый пакет поверх.
# Проверяет, что обновление не трогает настройки и не роняет data-plane.
#
# Запуск: make qemu-upgrade (нужен интернет). ~6-9 мин с KVM.
#   FROM_VERSION=3.3.0 — с какого релиза обновляемся;
#   NEW_PKG=путь.apk   — новый пакет (собранный SDK); по умолчанию — последний релиз с GitHub.
set -uo pipefail

. "$(dirname "$0")/lib.sh"

: "${FROM_VERSION:=3.3.0}"
: "${NEW_PKG:=}"
REPO_URL="https://github.com/andreiyurik/cheburnet-router"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup
vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }
vm_start_firewall

echo "→ AmneziaWG (зависимость старого пакета) тем же путём, что bootstrap"
vm_awg_prepare || exit 1
for attempt in 1 2 3; do
    vm_ssh "PATH=/tmp/awgbin:\$PATH sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
    vm_ssh "apk list --installed 2>/dev/null | grep -q '^kmod-amneziawg-[0-9]' && apk list --installed 2>/dev/null | grep -q '^amneziawg-tools-[0-9]'" && break
    [ "$attempt" = 3 ] && { echo "  ✗ AmneziaWG не встала"; vm_ssh "tail -6 /tmp/awg-install.log" || true; vm_github_diag; exit 1; }
    sleep 15
done

echo "→ Ставлю релиз $FROM_VERSION, как его ставили пользователи"
vm_ssh "curl -fsSL --connect-timeout 15 -m 120 -o /tmp/old.apk $REPO_URL/releases/download/v$FROM_VERSION/cheburnet.apk" \
    || { echo "  ✗ не скачать релиз v$FROM_VERSION"; vm_github_diag; exit 1; }
apk_try "apk add --allow-untrusted /tmp/old.apk" \
    || { echo "  ✗ релиз $FROM_VERSION не встал:"; vm_ssh "apk add --allow-untrusted /tmp/old.apk 2>&1 | tail -8"; exit 1; }
pkg_version() { vm_ssh "apk list --installed cheburnet 2>/dev/null | sed -n 's/^cheburnet-\([^ ]*\) .*/\1/p'"; }
old_ver="$(pkg_version)"
echo "  ✓ стоит cheburnet $old_ver"

# «Настроено»: шаги, которым живой VPN-сервер не нужен (как в reboot.sh), и install.json —
# то, из чего движок восстанавливает себя и что обновление обязано не тронуть.
ENGINE=/usr/share/cheburnet/engine
echo "→ Довожу до «настроено» движком $old_ver"
vm_ssh "echo '{\"domains\":[\"example.com\"],\"dns_provider\":\"adguard\"}' | ucode -R $ENGINE/steps/dns/apply.uc" \
    || { echo "  ✗ dns-шаг упал"; exit 1; }
vm_ssh "echo '{\"dns_provider\":\"adguard\"}' | ucode -R $ENGINE/steps/doh/apply.uc" \
    || { echo "  ✗ doh-шаг упал"; exit 1; }
vm_ssh "rm -f /etc/cheburnet/install-token; echo '{\"protocol\":\"awg\",\"dns_provider\":\"adguard\",\"user_domains\":[\"example.com\"],\"domains\":[\"example.com\"],\"routing_opts\":{\"mode\":\"home\",\"wan_if\":\"eth0\",\"tunnel_if\":\"awg0\"}}' > /etc/cheburnet/install.json"
vm_ssh "echo '{\"domains\":[\"example.com\"],\"routing_opts\":{\"wan_if\":\"eth0\"},\"fw_opts\":{\"tunnel_if\":\"awg0\"}}' | ucode -R $ENGINE/steps/firewall/apply.uc" \
    || { echo "  ✗ firewall-шаг упал"; exit 1; }

ks_rules() { vm_ssh "nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -c drop || true"; }
sets_present() {
    local out=""
    for s in direct direct6; do
        if vm_ssh "nft list set inet fw4 $s >/dev/null 2>&1"; then out="$out $s"; fi
    done
    echo "${out# }"
}
json_before="$(vm_ssh 'sha256sum /etc/cheburnet/install.json')"
ks_before="$(ks_rules)"; sets_before="$(sets_present)"
[ "$ks_before" -gt 0 ] && [ -n "$sets_before" ] \
    || { echo "  ✗ data-plane не в ядре ещё ДО обновления — проверять нечего"; exit 1; }
echo "  ✓ настроено: kill-switch drop-правил $ks_before, наборы: $sets_before"

# Новый bootstrap — из рабочей копии; источники через file://, чтобы проверялся этот код, а не master.
echo "→ Обновление: текущий bootstrap поверх настроенного роутера"
vm_ssh "mkdir -p /tmp/src/vendor /tmp/src/bootstrap /tmp/rel"
vm_scp "$REPO_ROOT/bootstrap/bootstrap.sh" /tmp/src/bootstrap/bootstrap.sh
vm_scp "$REPO_ROOT/bootstrap/wget-via-curl.sh" /tmp/src/bootstrap/wget-via-curl.sh
vm_scp "$REPO_ROOT/vendor/amneziawg-install.sh" /tmp/src/vendor/amneziawg-install.sh
if [ -n "$NEW_PKG" ]; then
    vm_scp "$NEW_PKG" /tmp/rel/cheburnet.apk
    REL_BASE="file:///tmp/rel"
else
    REL_BASE="$REPO_URL/releases/latest/download"
fi
vm_ssh "CHEBURNET_SRC_BASE=file:///tmp/src CHEBURNET_RELEASE_BASE=$REL_BASE sh /tmp/src/bootstrap/bootstrap.sh > /tmp/upgrade.log 2>&1" \
    || { echo "  ✗ bootstrap упал при обновлении:"; vm_ssh "tail -20 /tmp/upgrade.log"
         echo "  → сеть самого роутера после настройки:"
         vm_ssh "nslookup github.com 2>&1 | tail -3; ip -4 rule; ip -4 route get 140.82.121.4; curl -sv -m 20 -o /dev/null $REPO_URL 2>&1 | grep -E '^\*|^<' | head -12" || true
         exit 1; }

fail=0
bad() { echo "  ✗ $*"; fail=1; }
new_ver="$(pkg_version)"
[ "$new_ver" != "$old_ver" ] && echo "  ✓ пакет обновлён: $old_ver → $new_ver" || bad "версия не изменилась ($new_ver)"
vm_ssh "apk list --installed 2>/dev/null | grep -q '^curl-[0-9]'" && echo "  ✓ curl стоит (зависимость нового пакета)" || bad "curl не встал"
[ "$(vm_ssh 'sha256sum /etc/cheburnet/install.json')" = "$json_before" ] \
    && echo "  ✓ install.json не тронут" || bad "install.json изменился при обновлении"
ks_after="$(ks_rules)"; sets_after="$(sets_present)"
[ "$ks_after" -gt 0 ] && echo "  ✓ kill-switch в ядре ($ks_after drop-правил)" || bad "kill-switch пропал из ядра"
[ "$sets_after" = "$sets_before" ] && echo "  ✓ наборы на месте: $sets_after" || bad "наборы: было «$sets_before», стало «$sets_after»"
vm_ssh "ubus call cheburnet status | grep -q '\"installed\": true'" \
    && echo "  ✓ status: installed=true" || bad "status не считает систему установленной"
vm_ssh "ubus call cheburnet status | grep -q '\"mode\": \"home\"'" \
    && echo "  ✓ режим сохранён (home)" || bad "режим потерян"
vm_ssh "ucode -R $ENGINE/install/reapply.uc >/dev/null 2>&1" \
    && echo "  ✓ reapply нового движка отрабатывает" || bad "reapply нового движка упал"
# Токен — пропуск в мастер установки. На настроенном роутере его быть не должно: иначе ссылка
# из терминала снова открывает путь переустановки.
vm_ssh "[ ! -e /etc/cheburnet/install-token ]" \
    && echo "  ✓ install-токен не выпущен на настроенном роутере" || bad "обновление выпустило install-токен на настроенном роутере"

[ "$fail" = 0 ] || { echo "  журнал обновления:"; vm_ssh "tail -15 /tmp/upgrade.log"; exit 1; }
echo "✓ T3m pass — обновление $old_ver → $new_ver поверх настроенного роутера не трогает настройки и data-plane"
