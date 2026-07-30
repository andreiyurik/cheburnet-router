#!/bin/bash
# tests/qemu/install-v2.sh — T3c-v2: установка зависимостей через apk + шаги data-plane
# против РЕАЛЬНЫХ сервисов на живом релизном OpenWrt.
#
# Зачем (чего НЕ покрывают T3a-v2 smoke и юниты):
#   • DEPENDS пакета РЕАЛЬНО резолвятся и ставятся из официальных feed'ов под arch
#     (это единственная проверка package/cheburnet/Makefile — иначе «apk add cheburnet»
#     у пользователя может молча не собраться). Никогда раньше не запускалось.
#   • dns-шаг → РЕАЛЬНЫЙ dnsmasq-full перечитывает конфиг с нашим nftset.
#   • doh-шаг → РЕАЛЬНЫЙ https-dns-proxy стартует с нашими резолверами.
#   smoke-v2 кладёт движок руками и не ставит пакеты — здесь пакеты настоящие.
#
#   • kmod-amneziawg + amneziawg-tools ставятся ТЕМ ЖЕ путём, что на роутере (vendored
#     awg-инсталлятор), и модуль грузится в ядро — проверка vermagic, которая раньше
#     существовала только на железе.
#
# Честные границы (как в T3c v1):
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

# downloads.openwrt.org из фильтрующих сетей рвётся посреди передачи (EPERM/EOF) —
# один флап зеркала не должен красить тест (тот же урок, что apk_retry в webui-v2.sh
# и retry в bootstrap.sh). if, не `[ … ] && …` — ловушка set -e (CLAUDE.md).
apk_try() { # apk_try 'apk add <pkg>' — до 10 попыток, тихо; код возврата честный.
    # 10×10с (было 5×3с): фильтрующая сеть рвёт отдельные файлы посреди передачи с высокой
    # частотой, и пакет с несколькими новыми deps (https-dns-proxy → libcares, resolveip…)
    # перемножает вероятность — 5 коротких попыток дважды красили тест на живом зеркале.
    local cmd="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if vm_ssh "$cmd" >/dev/null 2>&1; then return 0; fi
        sleep 10
    done
    return 1
}

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; vm_ssh "apk update 2>&1 | tail -10"; exit 1; }

# ─── замер расхода флеша ─────────────────────────────────────────────────────
# Порог preflight min_flash_mb осмыслен только если известно, СКОЛЬКО стек реально съедает.
# Меряем ДЕЛЬТУ свободного места (абсолютные цифры x86-VM к роутеру не относятся, дельта — да)
# на тех же данных, что читает gather: df по writable-ФС (/overlay, иначе /).
# Третье ЦЕЛОЕ поле строки данных = Available — так же, как parse_df (устойчиво к busybox-
# переносу длинного имени ФС на отдельную строку, где поля Filesystem просто нет).
free_kb() {
    vm_ssh "df -k /overlay 2>/dev/null || df -k /" \
        | awk 'NR>1 { n=0; for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) { n++; if (n==3) { print $i; exit } } }'
}
FREE_START="$(free_kb)"
echo "  свободно до установки: $((FREE_START / 1024)) МБ"

# ─── DEPENDS пакета (источник правды — package/cheburnet/Makefile) ────────────
# CORE — обязаны ставиться из feed. AWG идёт НЕ из feed: kmod привязан к vermagic сборки ядра,
# и собирает его upstream awg-openwrt под каждый релиз — ставим тем же инсталлятором, что и
# bootstrap на роутере (см. блок ниже).
# Локальный adblock убран: блокировка рекламы/контента — через выбор фильтрующего DoH-резолвера,
# не локальным списком (см. ADR — DNS-фильтрация). Поэтому adblock-lean в DEPENDS больше нет.
CORE_DEPS="ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus rpcd rpcd-mod-file nftables ip-full https-dns-proxy uhttpd uhttpd-mod-ubus"
AWG_DEPS="kmod-amneziawg amneziawg-tools"

echo "→ Ставлю CORE-зависимости (assert: каждая ставится)"
for pkg in $CORE_DEPS; do
    if apk_try "apk add $pkg"; then
        echo "  ✓ $pkg"
    else
        echo "  ✗ $pkg — НЕ ставится из feed под x86_64"
        vm_ssh "apk add $pkg 2>&1 | tail -5"
        exit 1
    fi
done

echo "→ dnsmasq-full (замена dnsmasq — нужен для nftset)"
# dnsmasq-full конфликтует с dnsmasq (стоит по умолчанию). apk должен заменить;
# если нет — снимаем dnsmasq и ставим заново. Это реальная install-загвоздка.
if apk_try "apk add dnsmasq-full"; then
    echo "  ✓ dnsmasq-full (apk заменил dnsmasq сам)"
elif apk_try "apk del dnsmasq >/dev/null 2>&1; apk add dnsmasq-full"; then
    echo "  ✓ dnsmasq-full (после явного apk del dnsmasq)"
else
    echo "  ✗ dnsmasq-full не ставится"
    vm_ssh "apk add dnsmasq-full 2>&1 | tail -8"
    exit 1
fi
vm_ssh "/etc/init.d/dnsmasq restart >/dev/null 2>&1; sleep 1; /etc/init.d/dnsmasq status | grep -qi running" \
    || { echo "  ✗ dnsmasq не поднялся после замены на full"; exit 1; }
echo "  ✓ dnsmasq-full работает"

FREE_CORE="$(free_kb)"
echo "  → CORE + dnsmasq-full съели $(( (FREE_START - FREE_CORE) / 1024 )) МБ"

echo "→ AmneziaWG тем же путём, что на роутере (vendored awg-инсталлятор → awg-openwrt)"
# Инсталлятор берёт версию из `ubus call system board` и качает ассет `_v<версия>_<arch>` —
# поэтому он работает на РЕЛИЗЕ и не может работать на snapshot (там версия «SNAPSHOT», ассета
# с таким именем нет). Ровно это и было причиной, по которой туннельный стек в QEMU не
# проверялся вовсе, пока тесты жили на snapshot.
#
# rc инсталлятора игнорируем осознанно — как в bootstrap.sh: upstream делает exit 1, когда нет
# ассета luci-proto (нам он не нужен). Проверяем ФАКТ установки нужных двух пакетов.
vm_scp "$REPO_ROOT/vendor/amneziawg-install.sh" "/tmp/awg-install.sh"
vm_ssh "sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
AWG_OK=1
for pkg in $AWG_DEPS; do
    if vm_ssh "apk list --installed 2>/dev/null | grep -q '^$pkg-[0-9]'"; then
        echo "  ✓ $pkg"
    else
        echo "  ✗ $pkg не установлен — нет сборки под OpenWrt $OPENWRT_VERSION у awg-openwrt?"
        vm_ssh "tail -15 /tmp/awg-install.log" || true
        AWG_OK=0
    fi
done
[ "$AWG_OK" = "1" ] || {
    echo "  ✗ AmneziaWG не встала. На роутере это тот же самый шаг bootstrap — значит установка"
    echo "    у пользователя тоже встанет. Если версия пина только что менялась — проверьте,"
    echo "    что у awg-openwrt есть релиз v$OPENWRT_VERSION (см. шапку tests/qemu/lib.sh)."
    exit 1
}

# vermagic: пакет мог поставиться, но модуль не грузиться в это ядро — на роутере это
# «туннель не поднимается» без внятной причины. Ловим здесь, а не на живом железе.
vm_ssh "modprobe amneziawg 2>/dev/null; lsmod | grep -q '^amneziawg'" \
    || { echo "  ✗ модуль amneziawg не загрузился в ядро (vermagic не совпал)"; \
         vm_ssh "modprobe amneziawg 2>&1 | tail -3; dmesg | grep -i amneziawg | tail -5" || true; exit 1; }
vm_ssh "command -v awg >/dev/null" \
    || { echo "  ✗ утилита awg не появилась в PATH (amneziawg-tools встали неполно)"; exit 1; }
echo "  ✓ модуль amneziawg загружен в ядро, утилита awg на месте"

FREE_AWG="$(free_kb)"
# В КБ, а не в МБ: kmod+tools весят сотни килобайт, и целочисленное деление печатало «0 МБ» —
# цифра, из которой нельзя понять, поставилось ли вообще что-нибудь.
echo "  → AWG-пакеты съели $(( FREE_CORE - FREE_AWG )) КБ"

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
# check.uc выходит НЕнулём, когда preflight НЕ пройден — на x86-VM это возможно (например,
# по флешу или отсутствию радио). Это КОРРЕКТНО: глушим rc (|| true) и проверяем сам вердикт,
# а не код выхода — тест про то, что preflight отработал на реальной системе.
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
# Формат строки зависит от версии init: старый — домен-на-строку
# (nftset=/example.com/4#...), новый init склеивает домены одной директивой
# (nftset=/example.com/example.org/4#...). Ассертим суть: example.com в nftset-строке
# нашего сета — оба домена проверяем по отдельности, порядок склейки не фиксируем.
vm_ssh 'grep -qE "nftset=.*/example\.com/.*4#inet#fw4#direct" /var/etc/dnsmasq.conf.* && grep -qE "nftset=.*/example\.org/.*4#inet#fw4#direct" /var/etc/dnsmasq.conf.*' \
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

# ─── firewall: правила ПЕРЕЖИВАЮТ fw4 reload (регрессия живого бага) ──────────
# На реальном роутере (GL-MT3000, 2026-07-03) обнаружено: ручная nft-инъекция цепочек
# теряла правила при ЛЮБОМ fw4 reload (hotplug awg0 при install, правка LuCI, ребут) —
# kill-switch тихо умирал. Фикс: правила в /etc/nftables.d/, fw4 включает их при каждом
# reload. Этот ассерт ловит регресс: применяем firewall, дёргаем reload, правила на месте.
echo "→ подготовка: возвращаю fw4 (vm_boot_and_setup его стопил) + ssh-правило"
# Как в smoke-v2: шаг добавляет цепочки в СУЩЕСТВУЮЩУЮ таблицу inet fw4 — на
# остановленном firewall её нет. Старый fw4 прощал reload из stopped-состояния
# (создавал таблицу), новые сборки — нет: apply падал именно здесь. ssh-доступ
# страхуем постоянным uci-правилом (переживает reload'ы, в отличие от nft-инъекции).
vm_ssh 'uci add firewall rule >/dev/null
        uci set firewall.@rule[-1].name="qemu-ssh"
        uci set firewall.@rule[-1].src="*"
        uci set firewall.@rule[-1].proto="tcp"
        uci set firewall.@rule[-1].dest_port="22"
        uci set firewall.@rule[-1].target="ACCEPT"
        uci commit firewall
        /etc/init.d/firewall start >/dev/null 2>&1; sleep 2
        nft list table inet fw4 >/dev/null' \
    || { echo "  ✗ fw4 не поднялся"; vm_ssh 'logread | tail -15'; exit 1; }
vm_ssh true || { echo "  ✗ ssh потерян после старта fw4"; exit 1; }

echo "→ firewall-шаг: правила в nftables.d переживают fw4 reload"
vm_ssh 'echo "{\"domains\":[\"example.com\"],\"routing_opts\":{\"wan_if\":\"eth0\"},\"fw_opts\":{\"tunnel_if\":\"awg0\"}}" | ucode -R /usr/share/cheburnet/engine/steps/firewall/apply.uc' \
    || { echo "  ✗ firewall/apply.uc exit != 0"; exit 1; }
vm_ssh '[ -f /etc/nftables.d/10-cheburnet.nft ]' \
    || { echo "  ✗ файл /etc/nftables.d/10-cheburnet.nft не создан"; exit 1; }
vm_ssh 'nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -q drop' \
    || { echo "  ✗ kill-switch не в ядре после apply"; vm_ssh 'nft list chain inet fw4 cheburnet_ks'; exit 1; }
# КЛЮЧЕВОЕ: reload (то, что раньше стирало правила) — правила обязаны остаться.
vm_ssh '/etc/init.d/firewall reload >/dev/null 2>&1; sleep 1; nft list chain inet fw4 cheburnet_ks 2>/dev/null | grep -q drop' \
    || { echo "  ✗ РЕГРЕСС: kill-switch исчез после fw4 reload"; vm_ssh 'nft list chain inet fw4 cheburnet_ks; ls /etc/nftables.d/'; exit 1; }
vm_ssh 'nft list chain inet fw4 cheburnet_mark 2>/dev/null | grep -q "@direct"' \
    || { echo "  ✗ РЕГРЕСС: правило пометки исчезло после fw4 reload"; exit 1; }
echo "  ✓ kill-switch + пометка переживают fw4 reload (nftables.d)"

# ─── замер: сколько флеша реально стоит стек ──────────────────────────────────
# Ради этого числа и живёт замер: порог preflight min_flash_mb должен опираться на факт, а не
# на «ощущение». Порог берём из ЕДИНСТВЕННОГО источника правды (preflight.uc), чтобы отчёт не
# разъезжался с кодом при следующей правке.
FREE_END="$(free_kb)"
SPENT_KB=$(( FREE_START - FREE_END ))
# Порог — из блока REQUIREMENTS (Light-тир), а не первым совпадением по файлу: ниже в
# preflight.uc есть FULL_REQUIREMENTS со своим min_flash_mb, а выше — строка комментария с тем
# же именем. Якорь на `const REQUIREMENTS` + требование ЦИФР делает выбор однозначным.
MIN_FLASH="$(awk '
    /^const REQUIREMENTS/ { inblock = 1 }
    inblock && /min_flash_mb:/ && match($0, /[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }
' "$REPO_ROOT/engine/preflight/preflight.uc")"
# Не распарсили порог — это ОШИБКА теста, а не повод напечатать «✓». Молчащая проверка хуже
# отсутствующей: именно так первый прогон отрапортовал «влезает», ничего не сравнив.
case "$MIN_FLASH" in
    ''|*[!0-9]*) echo "  ✗ не удалось прочитать min_flash_mb из preflight.uc (получено: '$MIN_FLASH')"; exit 1 ;;
esac
echo
echo "→ ЗАМЕР расхода флеша (дельта свободного места; движок разложен, web-бандл в пакете)"
echo "    пакеты + движок:      $SPENT_KB КБ (≈ $(( SPENT_KB / 1024 )) МБ)"
echo "    порог preflight:      $MIN_FLASH МБ (min_flash_mb, Light-тир)"
echo "    запас на пороге:      $(( MIN_FLASH - SPENT_KB / 1024 )) МБ"
if [ "$(( SPENT_KB / 1024 ))" -ge "$MIN_FLASH" ]; then
    echo "  ✗ ПОРОГ ЗАНИЖЕН: стек не влезает в заявленный минимум — поднять min_flash_mb"
    exit 1
fi
# Запас < 4 МБ — сигнал, а не провал: на роутере сверху ещё kmod, кэш apk и место под логи.
if [ "$(( MIN_FLASH - SPENT_KB / 1024 ))" -lt 4 ]; then
    echo "  ⚠ запас на пороге меньше 4 МБ — пересмотреть min_flash_mb до следующего релиза"
else
    echo "  ✓ стек влезает в порог с запасом"
fi

# ─── итог ────────────────────────────────────────────────────────────────────
echo
echo "✓ T3c-v2 pass — установка через apk и data-plane на реальных пакетах:"
echo "  CORE-зависимости ставятся из feed, dnsmasq-full↔nftset, https-dns-proxy↔наши резолверы,"
echo "  AmneziaWG встала путём bootstrap'а и модуль загрузился в ядро (vermagic сошёлся)."
echo "  Handshake с живым VPN-сервером — по-прежнему только на железе."
