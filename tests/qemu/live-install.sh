#!/bin/bash
# tests/qemu/live-install.sh — T4b: УСПЕШНАЯ установка целиком + перезагрузка поверх неё.
#
# Зачем. T3g (rollback) доказал, что мёртвый сервер не выдаётся за успех. Но обратная,
# главная для пользователя ветка — «health прошёл → commit» — живьём не запускалась НИ РАЗУ:
# для неё нужен рабочий сервер. Здесь он есть (стенд tests/vps/), поэтому проверяем то, чего
# не проверял никто:
#   • оркестратор доходит до commit: install.json записан, одноразовый токен СНЯТ, панель
#     говорит installed=true — и туннель реально работает;
#   • трафик ВЫХОДИТ В ИНТЕРНЕТ через сервер (сверка внешнего адреса с адресом VPS), а не
#     «обвязка применилась»;
#   • после ПЕРЕЗАГРУЗКИ туннель поднимается САМ и трафик снова идёт через сервер. Это и есть
#     обещание «настроил один раз — работает годами», проверенное целиком, а не по частям
#     (T3h проверяет персистентность всего, КРОМЕ самого туннеля: там сервера нет).
#
# Протокол — Hysteria2: он подтверждён насквозь на этом стенде. Reality на пути разработки
# непроверяем (ClientHello переписывается — см. ADR 0004), а AmneziaWG требует ключа владельца.
#
# Нужен поднятый стенд: tests/vps/provision-lab.sh + tests/vps/fetch-links.sh → tests/vps/links.env.
# В CI НЕ входит (зависит от арендованного сервера). ~10-14 мин с KVM.

set -e -u -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINKS="$HERE/../vps/links.env"
[ -f "$LINKS" ] || {
    echo "✗ нет $LINKS — поднимите стенд (tests/vps/README.md) и заберите ссылки fetch-links.sh"
    exit 1; }
# shellcheck source=/dev/null
. "$LINKS"
[ -n "${HYSTERIA2:-}" ] || { echo "✗ в links.env нет HYSTERIA2"; exit 1; }

# Адрес VPS — из самой ссылки: единственный источник, не дублируем руками.
VPS_IP="$(printf '%s' "$HYSTERIA2" | sed -n 's|.*@\([^:/?#]*\).*|\1|p')"
[ -n "$VPS_IP" ] || { echo "✗ не удалось извлечь адрес сервера из ссылки"; exit 1; }
echo "→ Стенд: $VPS_IP (протокол Hysteria2)"

. "$HERE/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; }

vm_check_dns

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }

echo "→ Зависимости (как пакет) + kmod-tun и TLS для DoH"
for pkg in ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus rpcd rpcd-mod-file nftables ip-full \
           https-dns-proxy uhttpd uhttpd-mod-ubus dnsmasq-full kmod-tun libustream-mbedtls ca-bundle; do
    apk_try "apk add $pkg" || { echo "  ✗ не встал $pkg"; exit 1; }
done

# AmneziaWG нужна не для туннеля (он Hysteria2), а чтобы прошёл preflight: в его deps есть
# kmod-amneziawg, и `apk add --simulate` на него отвечает успехом только когда пакет доступен.
# На роутере его ставит bootstrap независимо от выбранного протокола — здесь тот же путь.
echo "→ AmneziaWG (для preflight-deps; туннель будет Hysteria2)"
vm_scp "$REPO_ROOT/vendor/amneziawg-install.sh" "/tmp/awg-install.sh"
awg_ok=0
for attempt in 1 2 3; do
    vm_ssh "sh /tmp/awg-install.sh -n -e > /tmp/awg-install.log 2>&1 || true"
    if vm_ssh "apk list --installed 2>/dev/null | grep -q '^kmod-amneziawg-[0-9]'"; then awg_ok=1; break; fi
    echo "    попытка $attempt не удалась (скачивание ассета), повтор через 15с"
    sleep 15
done
[ "$awg_ok" = "1" ] || { echo "  ✗ kmod-amneziawg не встал — preflight отвергнет установку по deps"; exit 1; }
ok "kmod-amneziawg на месте"

echo "→ Раскладываю движок и регистрирую rpcd-обработчик (как пакет)"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet /usr/libexec/rpcd /usr/share/rpcd/acl.d"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' --exclude='*README.md' \
    -cf - engine | vm_ssh "tar -C /usr/share/cheburnet -xf -"
vm_scp "$REPO_ROOT/package/cheburnet/files/rpcd-cheburnet.sh" "/usr/libexec/rpcd/cheburnet"
vm_scp "$REPO_ROOT/engine/ubus/rpcd-acl.json"                 "/usr/share/rpcd/acl.d/cheburnet.json"
vm_ssh "chmod +x /usr/libexec/rpcd/cheburnet && /etc/init.d/rpcd restart >/dev/null 2>&1; sleep 3"
vm_ssh "ubus list | grep -q '^cheburnet$'" || { echo "  ✗ cheburnet не на шине"; exit 1; }

vm_start_firewall

# Эндпоинт «какой у меня IP»: резолвим один раз, дальше пиним по адресу (маршрут ставится на IP).
ECHO_HOST="api.ipify.org"
ECHO_IP="$(vm_ssh "nslookup $ECHO_HOST 2>/dev/null | awk '/^Address( 1)?: / && \$NF ~ /^[0-9.]+\$/ {print \$NF; exit}'")"
[ -n "$ECHO_IP" ] || { echo "✗ не разрешился $ECHO_HOST"; exit 1; }

# Контроль: без туннеля мы выходим НЕ с адреса VPS — иначе сверка ничего не доказывает.
DIRECT_IP="$(vm_ssh "uclient-fetch -q -T 15 -O - https://$ECHO_HOST/ 2>/dev/null" | tr -d '\r\n ')"
[ -n "$DIRECT_IP" ] || { echo "✗ не узнать внешний адрес без туннеля"; exit 1; }
[ "$DIRECT_IP" != "$VPS_IP" ] || { echo "✗ адрес и без туннеля равен адресу VPS — проверка бессмысленна"; exit 1; }
ok "без туннеля выходим с $DIRECT_IP (≠ $VPS_IP)"

# ─── УСТАНОВКА через ubus, как из мастера ─────────────────────────────────────
echo
echo "→ ПОЛНАЯ установка через ubus (protocol=hysteria2, живой сервер)"
vm_ssh "echo live-install-token > /etc/cheburnet/install-token"
python3 - "$HYSTERIA2" > "$WORK/install-args.json" <<'PY'
import json, sys
print(json.dumps({
    "protocol": "hysteria2",
    "hysteria2_conf": sys.argv[1],
    "root_password": "live-install-pass",
    "domains": ["example.com"],
    "accept_risk": True,
    "token": "live-install-token",
}))
PY
vm_scp "$WORK/install-args.json" /tmp/install-args.json
out="$(vm_ssh "ubus call cheburnet install \"\$(cat /tmp/install-args.json)\"")"
echo "$out" | grep -q 'started' || { bad "install не запустился: $out"; exit 1; }
ok "установка запущена (sing-box догрузится сам, затем шаги и health-check)"

# Завершение ждём через SERIAL-консоль, а не по ssh. Успешная установка МЕНЯЕТ доступ к роутеру:
# ставит пароль root (шаг rootpass идёт только на commit-пути) и уводит весь непрямой трафик в
# туннель. Первый прогон этого теста именно так и «упал»: установка прошла, а ssh по ключу
# перестал пускать — тест ослеп ровно в момент успеха. Консоль — аналог кабеля: она работает
# независимо от маршрутизации и аутентификации.
echo "→ Жду завершения через serial-консоль (ssh после установки может стать недоступен)"
# Маркер СКЛЕИВАЕМ из двух литералов: консоль печатает эхом саму команду, и grep по цельной
# строке находил бы её в ТЕКСТЕ команды, а не в выводе — команда нашла бы сама себя (тот же
# класс ловушки, что `pgrep -f`, см. probe.uc). В эхе будет 'DONE'"_MARK', в выводе — DONE_MARK.
done_ok=0
for _ in $(seq 1 90); do
    vm_serial_send "[ -f /tmp/cheburnet/done ] && echo 'DONE'\"_MARK_\$\$\" || true"
    sleep 4
    if grep -qF "DONE_MARK_" "$SERIAL_LOG" 2>/dev/null; then done_ok=1; break; fi
done
[ "$done_ok" = "1" ] || { bad "установка не завершилась за 7,5 минут"
    vm_serial_send "cat /tmp/cheburnet/state; tail -20 /tmp/cheburnet/install.log"
    sleep 3; tail -40 "$SERIAL_LOG"; exit 1; }
ok "установка завершилась (маркер done виден на консоли)"

# ДАЛЬШЕ ВСЁ ЧЕРЕЗ КОНСОЛЬ, а не ssh. После успешной установки роутер уводит весь непрямой
# трафик в туннель, а в этой VM один сетевой интерфейс — то есть LAN и WAN совпадают (br-lan),
# и путь тестового ssh-клиента перестаёт быть «локальным». На реальном роутере LAN и WAN
# разные, и клиент из LAN остаётся прямым, поэтому это ограничение стенда, а не дефект.
# Консоль — аналог кабеля: работает независимо от маршрутизации и аутентификации.
#
# serial_check <имя> <shell-условие> — печатает CHK_<имя>_OK при успехе. Маркер склеен из двух
# литералов, иначе grep найдёт его в ЭХЕ команды, а не в выводе (ловушка «команда нашла себя»).
serial_check() {
    local name="$1" cond="$2"
    : > "$WORK/serial-probe.marker"
    vm_serial_send "if $cond; then echo 'CHK'\"_${name}_OK\"; else echo 'CHK'\"_${name}_BAD\"; fi"
    local i=0
    while [ "$i" -lt 12 ]; do
        if grep -qF "CHK_${name}_OK" "$SERIAL_LOG" 2>/dev/null; then return 0; fi
        if grep -qF "CHK_${name}_BAD" "$SERIAL_LOG" 2>/dev/null; then return 1; fi
        i=$(( i + 1 )); sleep 2
    done
    return 2   # не ответила — считаем провалом, но с другим кодом (видно в сообщении)
}
serial_show() { vm_serial_send "$1"; sleep 3; tail -12 "$SERIAL_LOG"; }

echo "→ ПРОВЕРКА 0: установка завершилась УСПЕХОМ (код 0)"
serial_check rc0 "grep -qx 0 /tmp/cheburnet/done" \
    || { bad "установка не отрапортовала успех — commit-ветку проверять не на чем"
         serial_show "cat /tmp/cheburnet/reason; tail -12 /tmp/cheburnet/install.log"; exit 1; }
ok "код выхода 0 — впервые проверяется ветка commit"

echo "→ ПРОВЕРКА 1: конфигурация записана, протокол верный"
serial_check cfg "grep -q hysteria2 /etc/cheburnet/install.json" \
    || { bad "install.json не сохранил protocol=hysteria2"; serial_show "cat /etc/cheburnet/install.json"; exit 1; }
ok "install.json записан с protocol=hysteria2"

echo "→ ПРОВЕРКА 2: одноразовый токен СНЯТ (пропуск использован)"
# На откате токен ОСТАЁТСЯ (проверено в T3g), на успехе обязан исчезнуть — иначе он продолжает
# пускать install любого в LAN.
serial_check tok "[ ! -f /etc/cheburnet/install-token ]" \
    || { bad "токен остался после успешной установки — пропуск продолжает действовать"; exit 1; }
ok "токен снят"

echo "→ ПРОВЕРКА 3: пароль root применён (шаг rootpass идёт только на commit-пути)"
serial_check pw "grep -q '^root:\\$' /etc/shadow" \
    || { bad "пароль root не установлен — commit-путь прошёл не полностью"; exit 1; }
ok "пароль root установлен"

echo "→ ПРОВЕРКА 4: панель говорит installed=true и туннель здоров"
serial_check st "ubus call cheburnet status | grep -q '\"installed\": true'" \
    || { bad "status не сообщает installed=true"; serial_show "ubus call cheburnet status | head -20"; exit 1; }
serial_check hl "ubus call cheburnet status | grep -q '\"tunnel_health\": \"up\"'" \
    || { bad "status не считает туннель здоровым"; serial_show "ubus call cheburnet status | head -20"; exit 1; }
ok "installed=true, tunnel_health=up"

echo "→ ПРОВЕРКА 5: трафик ВЫХОДИТ в интернет через сервер"
# Пин host-route на туннель — тот же приём, что в пробе: без него запрос ушёл бы на WAN и соврал.
serial_check exitip "ip route replace $ECHO_IP dev singtun0 >/dev/null 2>&1; uclient-fetch -q -T 20 -O - https://$ECHO_HOST/ 2>/dev/null | grep -q $VPS_IP" \
    || { bad "внешний адрес не равен адресу VPS — туннель поднят, но трафик через него не идёт"
         serial_show "logread | grep -i sing-box | tail -8"; exit 1; }
ok "внешний адрес = $VPS_IP — байты реально дошли через туннель"

# ─── ПЕРЕЗАГРУЗКА поверх РАБОЧЕЙ установки ───────────────────────────────────
echo
echo "→ ПЕРЕЗАГРУЖАЮ роутер поверх работающей установки"
vm_serial_send "reboot"
sleep 15
# Ждём консоль, а не ssh: после загрузки маршрутизация снова уводит трафик в туннель.
vm_wait_serial "Please press Enter to activate this console" 120 \
    || { bad "роутер не загрузился за 2 минуты"; exit 1; }
vm_serial_send ""
sleep 3
ok "роутер загрузился"

echo "→ ПРОВЕРКА 6: туннель поднялся САМ (без вмешательства)"
# Ждём с лимитом: sing-box стартует по procd, интерфейс появляется через секунды после загрузки.
tun_up=0
for _ in $(seq 1 20); do
    if serial_check tun "ip link show dev singtun0 2>/dev/null | grep -qE '[<,]UP[,>]' && pgrep sing-box >/dev/null 2>&1"; then
        tun_up=1; break
    fi
    sleep 5
done
[ "$tun_up" = "1" ] || {
    bad "туннель НЕ поднялся сам после ребута — для пользователя это «после перезагрузки нет интернета»"
    serial_show "logread | grep -i sing-box | tail -10"; exit 1; }
ok "singtun0 поднят, sing-box работает — автостарт сработал"

echo "→ ПРОВЕРКА 7: трафик СНОВА идёт через сервер после ребута"
serial_check exitip2 "ip route replace $ECHO_IP dev singtun0 >/dev/null 2>&1; uclient-fetch -q -T 25 -O - https://$ECHO_HOST/ 2>/dev/null | grep -q $VPS_IP" \
    || { bad "после ребута трафик через туннель не идёт"; serial_show "logread | grep -i sing-box | tail -10"; exit 1; }
ok "внешний адрес = $VPS_IP — связь через сервер восстановилась сама"

echo "→ ПРОВЕРКА 8: панель после ребута не врёт"
serial_check st2 "ubus call cheburnet status | grep -q '\"tunnel_health\": \"up\"'" \
    || { bad "status после ребута не считает туннель здоровым, хотя трафик идёт"
         serial_show "ubus call cheburnet status | head -20"; exit 1; }
ok "status: tunnel_health=up"

echo
echo "✓ T4b pass — установка доходит до commit и переживает перезагрузку:"
echo "  install.json записан, одноразовый токен снят, пароль root применён, панель честна,"
echo "  трафик выходит через сервер ДО и ПОСЛЕ ребута, туннель поднимается сам."
echo "  Проверки идут через serial-консоль: после установки роутер уводит непрямой трафик в"
echo "  туннель, и на VM с одним интерфейсом ssh-путь теста перестаёт быть локальным."
echo "  Reality на этом пути непроверяем (переписывается ClientHello) — только с живого роутера."
