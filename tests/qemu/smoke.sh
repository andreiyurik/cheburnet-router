#!/bin/bash
# tests/qemu/smoke.sh — T3a hermetic VM smoke test.
#
# Проверяет, что наш rpcd-cheburnet поднимается на реальном OpenWrt snapshot
# (busybox-ash + busybox-awk + busybox-sed + настоящий ubusd/rpcd) и отвечает
# валидным JSON через ubus. НЕ ходит в интернет: install.sh (apk update,
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
#   • lib/family-filter.sh — on/off/status/idempotency на РЕАЛЬНОМ
#     busybox-uci (add_list/del_list/commit) и busybox-awk (rewrite
#     raw_block_lists). Mock в T2 не покрывает busybox-специфики.
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

echo "→ assert: ubus list cheburnet — все 13 методов"
# Каждый метод в `ubus -v list` идёт строкой `<TAB>"name":{args}`. Берём имя
# до первого `"` после имени — иначе текстовый парсер слипает имя метода
# с именами аргументов.
# +apply_lan_ip + check_lan_conflict — pre-install детект и автофикс
# конфликта подсетей LAN/WAN (см. lib/net-detect.sh + docs/test-lan-conflict.md).
# +update_podkop — post-install RPC для апгрейда устаревших инсталляций
# (старый URL .srs → 404), Problem 3 в feat/podkop-non-destructive.
methods="$(vm_ssh 'ubus -v list cheburnet' \
    | sed -nE 's/^[[:space:]]+"([^"]+)":.*$/\1/p' \
    | sort | tr '\n' ' ' | sed 's/ $//')"
expected="apply_lan_ip check_lan_conflict factory_reset get_status install_cancel install_progress install_start mode_switch replace_awg_conf service_restart set_blocklist_tier set_family_filter update_podkop"
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

# ─── family-filter end-to-end: реальный busybox-uci + busybox-awk ────────────
#
# Главные риски, которые mock-уровень T2 НЕ ловит и которые ловит этот блок:
#   • busybox-uci семантика add_list/del_list/commit (точное совпадение
#     значений — чужие cname не трогаем);
#   • busybox-awk на _family_filter_rewrite (та же история, что мы один раз
#     уже ловили на json_escape — gawk-vs-busybox semantic gap);
#   • idempotency on/on не дублирует ни NSFW URL в raw_block_lists, ни
#     cname'ы в dhcp.@dnsmasq[0];
#   • family_filter_status суммирует обе подсистемы (true ⟺ обе включены).
#
# adblock-lean сам не нужен: мокаем /etc/adblock-lean/config одной строкой
# raw_block_lists=, чего достаточно, чтобы _family_filter_rewrite (awk +
# mktemp + mv) имела над чем работать. uci, однако, настоящий — busybox.

# Считаем ВХОЖДЕНИЯ подстроки, не строки: busybox-uci печатает list-элементы
# всеми в одной строке через пробел, и в /etc/adblock-lean/config raw_block_lists
# тоже хранится в одной строке. grep -c посчитал бы 1 даже если бы URL/cname
# продублировался — ассерт оказался бы фальшиво-зелёным. grep -o ... | wc -l
# считает каждое вхождение отдельно.

echo "→ assert: family-filter — on, NSFW URL и cname'ы добавлены"
vm_ssh 'mkdir -p /etc/adblock-lean && printf '\''raw_block_lists="hagezi:pro"\n'\'' > /etc/adblock-lean/config'
vm_ssh '. /opt/cheburnet/lib/family-filter.sh && family_filter_on' \
    || { echo "  FAIL: family_filter_on exit-code != 0"; exit 1; }
nsfw_n="$(vm_ssh 'grep -o nsfw-onlydomains.txt /etc/adblock-lean/config | wc -l')"
[ "$nsfw_n" = "1" ] \
    || { echo "  FAIL: ожидал 1 NSFW URL в raw_block_lists, нашёл $nsfw_n"; vm_ssh 'cat /etc/adblock-lean/config'; exit 1; }
# Sentinel: forcesafesearch.google.com встречается ровно 2 раза (google.com + www.google.com).
ss_n="$(vm_ssh 'uci show dhcp | grep -o forcesafesearch.google.com | wc -l')"
[ "$ss_n" = "2" ] \
    || { echo "  FAIL: ожидал 2 forcesafesearch-cname, нашёл $ss_n"; vm_ssh 'uci show dhcp'; exit 1; }

echo "→ assert: family-filter — status=true когда обе подсистемы включены"
st="$(vm_ssh '. /opt/cheburnet/lib/family-filter.sh && family_filter_status')"
[ "$st" = "true" ] \
    || { echo "  FAIL: family_filter_status='$st' (ожидал true)"; exit 1; }

echo "→ assert: family-filter — повторный on idempotent (не дублирует)"
vm_ssh '. /opt/cheburnet/lib/family-filter.sh && family_filter_on'
nsfw_n2="$(vm_ssh 'grep -o nsfw-onlydomains.txt /etc/adblock-lean/config | wc -l')"
[ "$nsfw_n2" = "1" ] \
    || { echo "  FAIL: NSFW URL продублировался после второго on (count=$nsfw_n2, ожидал 1)"; vm_ssh 'cat /etc/adblock-lean/config'; exit 1; }
ss_n2="$(vm_ssh 'uci show dhcp | grep -o forcesafesearch.google.com | wc -l')"
[ "$ss_n2" = "2" ] \
    || { echo "  FAIL: cname-список продублировался — count=$ss_n2, ожидал 2"; vm_ssh 'uci show dhcp'; exit 1; }

echo "→ assert: family-filter — off вычищает обе подсистемы"
vm_ssh '. /opt/cheburnet/lib/family-filter.sh && family_filter_off' \
    || { echo "  FAIL: family_filter_off exit-code != 0"; exit 1; }
nsfw_n_off="$(vm_ssh 'grep -o nsfw-onlydomains.txt /etc/adblock-lean/config | wc -l')"
[ "$nsfw_n_off" = "0" ] \
    || { echo "  FAIL: после off остались NSFW URL (count=$nsfw_n_off)"; vm_ssh 'cat /etc/adblock-lean/config'; exit 1; }
ss_n_off="$(vm_ssh 'uci show dhcp | grep -o forcesafesearch.google.com | wc -l')"
[ "$ss_n_off" = "0" ] \
    || { echo "  FAIL: после off остались forcesafesearch-cname (count=$ss_n_off)"; vm_ssh 'uci show dhcp'; exit 1; }
st_off="$(vm_ssh '. /opt/cheburnet/lib/family-filter.sh && family_filter_status')"
[ "$st_off" = "false" ] \
    || { echo "  FAIL: family_filter_status='$st_off' после off (ожидал false)"; exit 1; }

echo
echo "✓ T3a smoke pass — bringup + rpcd-cheburnet работают на реальном OpenWrt snapshot."
