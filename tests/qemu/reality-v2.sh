#!/bin/bash
# tests/qemu/reality-v2.sh — T3d-v2: Full-тир (VLESS+Reality) data-plane WIRING на живом OpenWrt.
#
# Зачем (чего НЕ покрывают юниты и install-v2):
#   • singbox-шаг РЕАЛЬНО применяется на живом netifd/uci: config.json пишется, создаётся
#     интерфейс network.singtun (proto none) + half-routes, sing-box поднимает TUN singtun0,
#     netifd ставит 0.0.0.0/1 + 128.0.0.0/1 dev singtun0 в main-таблицу.
#   • connectivity-probe (reality_connectivity) на ЖИВОЙ системе КОРРЕКТНО валит неработающий
#     туннель (сервер-заглушка недостижим) — подтверждение fail-safe: процесс жив ≠ туннель везёт.
#   • teardown снимает интерфейс+маршрут+сервис начисто (LAN не остаётся без интернета).
#
# ГЕРМЕТИЧНО и БЕЗОПАСНО: рабочий Reality-СЕРВЕР НЕ нужен (и в песочнице недостижим). Тест
# проверяет ВСЮ нашу обвязку (генерация конфига, netifd-маршрут, проба, откат) — то, что мы
# пишем; сам Reality-handshake sing-box (не наш код) тут заведомо не проходит, и это ОЖИДАЕМО:
# проба обязана его отвергнуть. Полный трафик через живой Reality-сервер — только на железе с
# внешним VPS (см. ADR 0004, раздел «что НЕ подтверждено живьём»).
#
# Запуск: make qemu-reality-v2 (нужен интернет для apk). ~4-6 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

echo "→ Проверяю интернет в VM"
vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    || { echo "✗ DNS не работает в VM — apk update не пройдёт"; exit 1; }
echo "  ✓ DNS работает"

apk_try() { # до 10 попыток по 10с, тихо (флап зеркала не красит тест — урок install-v2:
    # 5×3с не хватало, фильтрующая сеть рвёт отдельные файлы с высокой частотой)
    local cmd="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if vm_ssh "$cmd" >/dev/null 2>&1; then return 0; fi
        sleep 10
    done
    return 1
}

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }

# sing-box + TUN-модуль — минимум для Full-тира. ip-full/ucode — движок и маршруты.
echo "→ Ставлю sing-box + зависимости движка"
for pkg in sing-box kmod-tun ucode ucode-mod-fs ucode-mod-uci ip-full; do
    if apk_try "apk add $pkg"; then echo "  ✓ $pkg"; else echo "  ✗ $pkg не ставится из feed"; exit 1; fi
done

echo "→ Раскладываю движок v2 (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"
ENG=/usr/share/cheburnet/engine

# ─── 1. applying singbox шаг: конфиг + netifd-маршрут + TUN ───────────────────
# Сервер-заглушка 10.0.2.99:8443 заведомо недостижим (герметично). Нам важна ОБВЯЗКА,
# не рукопожатие: config.json, uci network.singtun, half-routes, устройство singtun0.
echo "→ Применяю singbox-шаг (dummy-сервер: проверяем обвязку, не туннель)"
LINK="vless://11111111-1111-1111-1111-111111111111@10.0.2.99:8443?security=reality&pbk=lMnOLPmu5a9v-taChNAwhvtZ_uj0QfEuBGtOf1k_phM&sni=www.cloudflare.com&sid=a8128a2d384507a3&flow=xtls-rprx-vision&type=tcp#lab"
vm_ssh "printf '%s' '$LINK' | ucode -R $ENG/steps/singbox/apply.uc" \
    || { echo "  ✗ singbox/apply.uc exit != 0"; exit 1; }
sleep 3

echo "  • config.json написан и валиден для sing-box"
vm_ssh "sing-box check -c /etc/sing-box/config.json" \
    || { echo "  ✗ сгенерированный config.json не проходит sing-box check"; vm_ssh 'cat /etc/sing-box/config.json'; exit 1; }
vm_ssh "grep -q '\"auto_route\": false' /etc/sing-box/config.json" \
    || { echo "  ✗ инвариант auto_route=false потерян"; exit 1; }

echo "  • netifd: секции network.singtun + route в uci"
vm_ssh "uci -q get network.singtun >/dev/null && uci -q get network.cheburnet_str0 >/dev/null && uci -q get network.cheburnet_str1 >/dev/null" \
    || { echo "  ✗ uci-секции singtun/routes не созданы"; vm_ssh 'uci -q show network | grep -E "singtun|cheburnet_str" || true'; exit 1; }

echo "  • sing-box поднял TUN-устройство singtun0"
vm_ssh "ip link show singtun0 >/dev/null 2>&1" \
    || { echo "  ✗ устройство singtun0 не появилось"; vm_ssh 'logread | grep -i sing-box | tail -8'; exit 1; }

echo "  • netifd поставил half-routes 0.0.0.0/1 + 128.0.0.0/1 dev singtun0"
vm_ssh "ip route show | grep -q '0.0.0.0/1 dev singtun0' && ip route show | grep -q '128.0.0.0/1 dev singtun0'" \
    || { echo "  ✗ half-routes в туннель не установлены"; vm_ssh 'ip route show | grep -E "singtun|0.0.0.0/1" || true'; exit 1; }
echo "  ✓ обвязка Full-тира применена на живом netifd/uci (конфиг + маршрут + TUN)"

# ─── 2. connectivity-probe отвергает неработающий туннель (fail-safe) ─────────
# Сервер недостижим → байты через туннель не идут → reality_connectivity ОБЯЗАН вернуть false.
# Это суть надёжности: «процесс жив» тут true (pgrep sing-box), но проба смотрит на ТРАФИК.
echo "→ connectivity-probe на живой системе — должен ОТВЕРГНУТЬ мёртвый туннель"
cat > "$WORK/probe-check.uc" <<'UC'
import { reality_connectivity } from "/usr/share/cheburnet/engine/install/probe.uc";
printf("%s\n", reality_connectivity("singtun0") ? "UP" : "DOWN");
UC
vm_scp "$WORK/probe-check.uc" "/tmp/probe-check.uc"
probe="$(vm_ssh 'ucode -R /tmp/probe-check.uc 2>/dev/null')"
[ "$probe" = "DOWN" ] \
    || { echo "  ✗ проба вернула '$probe' — ожидался DOWN (мёртвый туннель принят за рабочий!)"; exit 1; }
echo "  ✓ проба корректно отвергла неработающий туннель (fail-safe: трафик ≠ pgrep)"

# ─── 3. teardown снимает всё начисто (LAN не остаётся без интернета) ──────────
echo "→ Teardown singbox-шага"
vm_ssh "ucode -R $ENG/steps/singbox/apply.uc --teardown" \
    || { echo "  ✗ teardown exit != 0"; exit 1; }
sleep 2
vm_ssh "! uci -q get network.singtun >/dev/null && ! uci -q get network.cheburnet_str0 >/dev/null" \
    || { echo "  ✗ uci-секции singtun не удалены teardown'ом"; exit 1; }
vm_ssh "! ip route show | grep -q '0.0.0.0/1 dev singtun0'" \
    || { echo "  ✗ half-route в туннель остался после teardown (LAN был бы без интернета!)"; exit 1; }
vm_ssh "! pgrep -x sing-box >/dev/null" \
    || { echo "  ✗ sing-box не остановлен teardown'ом"; exit 1; }
echo "  ✓ teardown снял интерфейс, маршрут и сервис начисто"

echo ""
echo "✓ T3d-v2 REALITY WIRING ЗЕЛЁНЫЙ: конфиг+netifd-маршрут+TUN применяются, проба отвергает"
echo "  мёртвый туннель (fail-safe), teardown чистит. Полный трафик — на железе с внешним VPS."
