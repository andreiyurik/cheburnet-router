#!/bin/bash
# tests/qemu/smoke.sh — T3a hermetic VM smoke test.
#
# Проверяет, что наш rpcd-cheburnet поднимается на реальном OpenWrt snapshot
# (busybox-ash + busybox-awk + busybox-sed + настоящий ubusd/rpcd) и отвечает
# валидным JSON через ubus. НЕ ходит в интернет: bootstrap.sh (apk update,
# wget с github) не запускается, файлы кладутся напрямую через ssh+cat.
#
# Что покрывает (а на mock-уровне T2 — нет):
#   • Скрипт rpcd-cheburnet парсится busybox-ash, не bash'ем хоста.
#   • rpcd-acl.json принимается реальным rpcd (а не только python json.tool).
#   • rpcd регистрирует cheburnet-объект, ubus list показывает 9 методов.
#   • get_status / install_progress отдают валидный JSON через ubusd.
#   • json_escape работает на busybox-awk/-sed (а не gawk хоста — это
#     разные реализации с разной semantic'ой gsub-replacement, мы поймали
#     именно этот gap).
#
# Что НЕ покрывает (для уровня T3b — smoke-http.sh):
#   • HTTP-слой (uhttpd-mod-ubus + /ubus endpoint).
#   • UI-кнопки → ubus через JSON-RPC.
#   • ACL-инфорсмент anon-vs-authed.
#   • Полный setup/01-09 happy-path — это T3c, требует интернета и реальных
#     пакетов, делается вручную перед релизом.
#
# Запуск: make qemu  (или прямо ./tests/qemu/smoke.sh из корня репо).
# Время: ~90с с KVM, ~5-10мин на TCG. При падении — лог serial-консоли
# в .work/serial.log + последние 60 строк выводятся при exit.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup
vm_deploy_handler

# ─── ассерты ─────────────────────────────────────────────────────────────────
echo "→ assert: ubus cheburnet зарегистрирован"
vm_ssh "ubus list cheburnet >/dev/null" || {
    echo "  logread (последние 30):"; vm_ssh "logread | tail -30"
    exit 1
}

echo "→ assert: ubus list cheburnet — все 9 методов"
# Каждый метод в `ubus -v list` идёт строкой `<TAB>"name":{args}`. Берём имя
# до первого `"` после имени — иначе текстовый парсер слипает имя метода
# с именами аргументов.
methods="$(vm_ssh 'ubus -v list cheburnet' \
    | sed -nE 's/^[[:space:]]+"([^"]+)":.*$/\1/p' \
    | sort | tr '\n' ' ' | sed 's/ $//')"
expected="factory_reset get_status install_cancel install_progress install_start mode_switch replace_awg_conf service_restart set_blocklist_tier"
[ "$methods" = "$expected" ] || {
    echo "  expected: $expected"
    echo "  actual:   $methods"
    exit 1
}

echo "→ assert: get_status → валидный JSON"
out="$(vm_ssh 'ubus call cheburnet get_status')"
echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || { echo "  output: $out"; exit 1; }

echo "→ assert: install_progress → валидный JSON, step=idle"
out="$(vm_ssh 'ubus call cheburnet install_progress')"
step="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["step"])')"
[ "$step" = "idle" ] || { echo "  step=$step  full: $out"; exit 1; }

echo "→ assert: json_escape на busybox — round-trip кавычки/backslash/UTF-8"
# Тот же контракт, что в tests/unit/test_json_escape.bats, но на РЕАЛЬНОМ
# busybox-окружении. На host'е (gawk) старая awk-реализация проходила
# round-trip; на роутере (busybox-awk) — нет, из-за разной семантики
# gsub-replacement. После переписи на sed работает на обоих.
input='BOARD="🚀"\test'
expected='BOARD=\"🚀\"\\test'
actual="$(vm_ssh ". /opt/cheburnet/lib/cheburnet-utils.sh && json_escape '$input'")"
[ "$actual" = "$expected" ] || {
    echo "  input:    $input"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    exit 1
}

echo
echo "✓ T3a smoke pass — bringup + rpcd-cheburnet работают на реальном OpenWrt snapshot."
