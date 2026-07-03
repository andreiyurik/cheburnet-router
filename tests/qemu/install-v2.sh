#!/bin/bash
# tests/qemu/install-v2.sh — T3c-v2: установка зависимостей через apk + шаги data-plane
# против РЕАЛЬНЫХ сервисов на живом OpenWrt snapshot.
#
# Зачем (чего НЕ покрывают T3a-v2 smoke и юниты):
#   • DEPENDS пакета РЕАЛЬНО резолвятся и ставятся из официальных feed'ов под arch
#     (это единственная проверка package/cheburnet/Makefile — иначе «apk add cheburnet»
#     у пользователя может молча не собраться). Никогда раньше не запускалось.
#   • dns-шаг → РЕАЛЬНЫЙ dnsmasq-full перечитывает конфиг с нашим nftset.
#   • doh-шаг → РЕАЛЬНЫЙ https-dns-proxy стартует с нашими резолверами.
#   smoke-v2 кладёт движок руками и не ставит пакеты — здесь пакеты настоящие.
#
# Честные границы (как в T3c v1):
#   • kmod-amneziawg на x86-snapshot часто не собран под текущее ядро → ставим
#     best-effort и РЕПОРТИМ, не валим тест (preflight в проде это и ловит).
#   • Реальный туннель/handshake и Wi-Fi-радио — только на железе.
#   • Блокировка рекламы/контента — через выбор фильтрующего DoH-резолвера (не локальным
#     списком), поэтому отдельного adblock-пакета/шага в установке нет.
#
# Запуск: make qemu-install-v2 (нужен интернет для apk). ~5-8 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

# ─── интернет ────────────────────────────────────────────────────────────────
echo "→ Проверяю интернет в VM"
vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    || { echo "✗ DNS не работает в VM — apk update не пройдёт"; exit 1; }
echo "  ✓ DNS работает"

echo "→ apk update"
vm_ssh "apk update" >/dev/null 2>&1 || { echo "✗ apk update упал"; vm_ssh "apk update 2>&1 | tail -10"; exit 1; }

# ─── DEPENDS пакета (источник правды — package/cheburnet/Makefile) ────────────
# CORE — обязаны ставиться из feed; AWG — best-effort (kmod может отсутствовать на x86).
# Локальный adblock убран: блокировка рекламы/контента — через выбор фильтрующего DoH-резолвера,
# не локальным списком (см. ADR — DNS-фильтрация). Поэтому adblock-lean в DEPENDS больше нет.
CORE_DEPS="ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus rpcd rpcd-mod-file nftables ip-full https-dns-proxy uhttpd uhttpd-mod-ubus"
AWG_DEPS="kmod-amneziawg amneziawg-tools"

echo "→ Ставлю CORE-зависимости (assert: каждая ставится)"
for pkg in $CORE_DEPS; do
    if vm_ssh "apk add $pkg" >/dev/null 2>&1; then
        echo "  ✓ $pkg"
    else
        echo "  ✗ $pkg — НЕ ставится из feed под x86_64 snapshot"
        vm_ssh "apk add $pkg 2>&1 | tail -5"
        exit 1
    fi
done

echo "→ dnsmasq-full (замена dnsmasq — нужен для nftset)"
# dnsmasq-full конфликтует с dnsmasq (стоит по умолчанию). apk должен заменить;
# если нет — снимаем dnsmasq и ставим заново. Это реальная install-загвоздка.
if vm_ssh "apk add dnsmasq-full" >/dev/null 2>&1; then
    echo "  ✓ dnsmasq-full (apk заменил dnsmasq сам)"
elif vm_ssh "apk del dnsmasq >/dev/null 2>&1; apk add dnsmasq-full" >/dev/null 2>&1; then
    echo "  ✓ dnsmasq-full (после явного apk del dnsmasq)"
else
    echo "  ✗ dnsmasq-full не ставится"
    vm_ssh "apk add dnsmasq-full 2>&1 | tail -8"
    exit 1
fi
vm_ssh "/etc/init.d/dnsmasq restart >/dev/null 2>&1; sleep 1; /etc/init.d/dnsmasq status | grep -qi running" \
    || { echo "  ✗ dnsmasq не поднялся после замены на full"; exit 1; }
echo "  ✓ dnsmasq-full работает"

echo "→ AWG-зависимости (best-effort — на x86-snapshot kmod может отсутствовать)"
AWG_OK=1
for pkg in $AWG_DEPS; do
    if vm_ssh "apk add $pkg" >/dev/null 2>&1; then
        echo "  ✓ $pkg"
    else
        echo "  ⚠ $pkg недоступен под это ядро — ожидаемо на x86-snapshot (preflight это ловит)"
        AWG_OK=0
    fi
done

# ─── движок как пакет (shim + engine без tests/ + ACL) ───────────────────────
echo "→ Раскладываю движок v2 (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet /usr/libexec/rpcd /usr/share/rpcd/acl.d"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json"                 "/usr/share/rpcd/acl.d/cheburnet.json"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet; /etc/init.d/rpcd restart"
sleep 2

# ─── preflight на реальном apk (gather → check) ──────────────────────────────
# check.uc выходит НЕнулём, когда preflight НЕ пройден (на x86-VM так и будет: kmod-amneziawg
# не ставится). Это КОРРЕКТНО — глушим rc (|| true) и проверяем сам вердикт, а не код выхода.
echo "→ preflight на реальной системе (gather + check --json)"
out="$(vm_ssh 'ucode -R /usr/share/cheburnet/engine/preflight/gather.uc | ucode -R /usr/share/cheburnet/engine/preflight/check.uc --json || true')"
echo "$out" | python3 -c '
import json,sys
r = json.load(sys.stdin)
assert "checks" in r and len(r["checks"]) > 0, r
failed = [c.get("id") for c in r["checks"] if not c.get("ok")]
print("    проверок:", len(r["checks"]), "| passed:", r.get("passed"), "| провалены:", failed or "нет")
' || { echo "  ✗ preflight не дал валидный JSON-отчёт"; echo "  $out"; exit 1; }
echo "  ✓ preflight отработал на реальном apk --simulate (вердикт получен)"

# ─── dns-шаг против РЕАЛЬНОГО dnsmasq-full ───────────────────────────────────
echo "→ dns-шаг → реальный dnsmasq-full перечитывает конфиг с nftset"
vm_ssh 'echo "{\"domains\":[\"example.com\",\"example.org\"],\"routing_opts\":{\"ipv6\":false}}" | ucode -R /usr/share/cheburnet/engine/steps/dns/apply.uc' \
    || { echo "  ✗ dns/apply.uc exit != 0"; exit 1; }
vm_ssh 'uci -q get dhcp.cheburnet_dns4.domain | grep -q "example.com"' \
    || { echo "  ✗ ipset-секция не записана в uci"; vm_ssh 'uci -q show dhcp | grep cheburnet || true'; exit 1; }
# Ключевой ассерт: init РЕАЛЬНО превратил секцию в nftset-директиву итогового конфига.
# Урок живого прогона: старая модель (list nftset в секции dnsmasq) писалась в uci «успешно»,
# но init её молча игнорировал — проверка одного uci этот тихий отказ не ловила.
vm_ssh 'grep -q "nftset=/example.com/4#inet#fw4#direct" /var/etc/dnsmasq.conf.*' \
    || { echo "  ✗ nftset-директива не попала в сгенерированный конфиг dnsmasq"; vm_ssh 'grep nftset /var/etc/dnsmasq.conf.* || true'; exit 1; }
vm_ssh '/etc/init.d/dnsmasq status | grep -qi running' \
    || { echo "  ✗ dnsmasq упал после применения нашего конфига (nftset не принят?)"; vm_ssh 'logread | grep -i dnsmasq | tail -10'; exit 1; }
echo "  ✓ dnsmasq-full принял nftset (ipset-секция → директива в конфиге) и работает"

# ─── doh-шаг + выбор DNS-провайдера против РЕАЛЬНОГО https-dns-proxy ──────────
echo "→ doh-шаг (дефолт AdGuard) → реальный https-dns-proxy с нашим резолвером"
vm_ssh 'echo "{}" | ucode -R /usr/share/cheburnet/engine/steps/doh/apply.uc' \
    || { echo "  ✗ doh/apply.uc (дефолт) exit != 0"; exit 1; }
vm_ssh 'uci -q get https-dns-proxy.cheburnet_doh.resolver_url | grep -q "dns.adguard-dns.com"' \
    || { echo "  ✗ дефолтный резолвер не AdGuard"; vm_ssh 'uci show https-dns-proxy'; exit 1; }
echo "  ✓ дефолт = AdGuard (реклама+трекеры)"

echo "→ смена провайдера на adguard-family — чистая замена секции"
vm_ssh 'echo '\''{"provider":"adguard-family"}'\'' | ucode -R /usr/share/cheburnet/engine/steps/doh/apply.uc' \
    || { echo "  ✗ doh/apply (adguard-family) exit != 0"; exit 1; }
vm_ssh 'uci -q get https-dns-proxy.cheburnet_doh.resolver_url | grep -q "family.adguard-dns.com"' \
    || { echo "  ✗ смена провайдера не переписала url"; vm_ssh 'uci show https-dns-proxy'; exit 1; }
sect_n="$(vm_ssh 'uci show https-dns-proxy | grep -c "=https-dns-proxy$"')"
[ "$sect_n" = "1" ] || { echo "  ✗ секций резолвера $sect_n (ожидал 1 — чистая замена, без дублей)"; vm_ssh 'uci show https-dns-proxy'; exit 1; }
echo "  ✓ провайдер переключился, секция одна (идемпотентно)"

echo "→ https-dns-proxy стартует с применённым конфигом"
vm_ssh '/etc/init.d/https-dns-proxy restart >/dev/null 2>&1; sleep 2; /etc/init.d/https-dns-proxy status | grep -qi running' \
    || { echo "  ✗ https-dns-proxy не стартовал с нашим конфигом"; vm_ssh 'logread | grep -i dns-proxy | tail -10'; exit 1; }
echo "  ✓ https-dns-proxy принял конфиг и работает"

# ─── итог ────────────────────────────────────────────────────────────────────
echo
echo "✓ T3c-v2 pass — установка через apk и data-plane на реальных пакетах:"
echo "  CORE-зависимости ставятся из feed, dnsmasq-full↔nftset, https-dns-proxy↔наши резолверы."
if [ "$AWG_OK" = "1" ]; then
    echo "  AmneziaWG-пакеты тоже встали (kmod под это ядро есть)."
else
    echo "  ⚠ AmneziaWG-пакеты недоступны на x86-snapshot (ожидаемо) — туннель проверяется на железе."
fi
