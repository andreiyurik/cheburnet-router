#!/bin/sh
# 01-amneziawg.sh — установить AmneziaWG (kmod + tools + luci-proto), создать awg0.
#
# ПЕРЕД ЗАПУСКОМ: положите ваш .conf в /etc/amnezia/amneziawg/awg0.conf
#   scp configs/awg0.conf root@router:/etc/amnezia/amneziawg/awg0.conf
#
# Скрипт распарсит .conf и создаст UCI-интерфейс awg0 с нужными параметрами.
# Архитектура и версия awg-openwrt определяются автоматически из
# /etc/openwrt_release — работает на любой платформе, для которой есть релиз.
set -e

echo "== 01. AmneziaWG =="

# Подключаем общие pure-функции (awg_get_iface, awg_pick_version и др.)
LIB="${CHEBURNET_LIB:-/opt/cheburnet/lib/cheburnet-utils.sh}"
[ -f "$LIB" ] || LIB="$(dirname "$0")/../lib/cheburnet-utils.sh"
# shellcheck source=../lib/cheburnet-utils.sh disable=SC1090,SC1091
. "$LIB"

CONF=/etc/amnezia/amneziawg/awg0.conf
if [ ! -f "$CONF" ]; then
    echo "ERROR: $CONF не найден." >&2
    echo "Скопируйте конфиг от Amnezia: scp your-awg.conf root@router:$CONF" >&2
    exit 1
fi

# Защитный пояс: нормализуем CRLF → LF на случай, если .conf скопирован
# из Windows-редактора (Notepad/Блокнот сохраняет с \r\n). awg-quick читает
# этот файл напрямую и давится висячим \r — поэтому чиним один раз тут,
# до парсинга и до netifd. Web-флоу делает то же при сохранении (rpcd-cheburnet),
# но для ручного scp защита нужна именно здесь. Безусловная нормализация —
# tr на 2КБ файле дешевле, чем условная проверка.
tr -d '\r' < "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
chmod 600 "$CONF"

# === 1. Установка пакетов ===
# Если модуль уже загружен — пропускаем установку
if lsmod | grep -q '^amneziawg '; then
    echo "→ amneziawg уже установлен, пропускаю установку"
else
    echo "→ скачиваем и ставим kmod-amneziawg + tools"

    # Автодетект архитектуры пакетов awg-openwrt:
    # Формат тэга = ${DISTRIB_ARCH}_${DISTRIB_TARGET с / → _}
    # Пример: aarch64_cortex-a53 + mediatek/filogic → aarch64_cortex-a53_mediatek_filogic
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    if [ -z "${DISTRIB_ARCH:-}" ] || [ -z "${DISTRIB_TARGET:-}" ] || [ -z "${DISTRIB_RELEASE:-}" ]; then
        echo "✗ Не удалось определить архитектуру/версию роутера." >&2
        echo "  Проверьте: cat /etc/openwrt_release" >&2
        exit 1
    fi
    ARCH="${DISTRIB_ARCH}_$(echo "$DISTRIB_TARGET" | tr '/' '_')"

    # Версия пакетов awg-openwrt: пробуем v$DISTRIB_RELEASE, fallback v25.12.2
    AWG_VER="$(awg_pick_version "$DISTRIB_RELEASE" "$ARCH")" || AWG_VER=""
    if [ -z "$AWG_VER" ]; then
        echo "✗ Нет совместимого релиза awg-openwrt для OpenWrt ${DISTRIB_RELEASE} / ${ARCH}." >&2
        echo "  Доступные релизы: https://github.com/Slava-Shchipunov/awg-openwrt/releases" >&2
        echo "  Если вашей архитектуры нет — соберите пакет вручную по инструкции из репозитория." >&2
        exit 1
    fi
    echo "  arch=${ARCH}, awg-openwrt=v${AWG_VER}"

    BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${AWG_VER}"

    # После перезагрузки роутера WAN-DHCP приходит через 15–30 сек, только тогда
    # dnsmasq получает серверы. Если браузерный мастер стартует раньше — wget
    # не может разрезолвить github.com и падает с "download failed".
    # Ждём до 60 сек: nameserver в resolv.conf + ping до 8.8.8.8.
    echo "→ ожидаем готовности сети перед скачиванием..."
    _net_ready=0
    for _w in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if grep -q '^nameserver' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null \
           && ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            _net_ready=1
            break
        fi
        echo "  ожидание сети... (${_w}/12, по 5 сек)"
        sleep 5
    done
    if [ "$_net_ready" = "0" ]; then
        echo "✗ Нет доступа к интернету через 60 сек." >&2
        echo "  Возможные причины:" >&2
        echo "  • WAN-кабель не подключён или провайдер не даёт DHCP" >&2
        echo "  • IPv6-only WAN без IPv4 (проверьте настройки провайдера)" >&2
        echo "  Диагностика:" >&2
        ip route 2>&1 >&2 || true
        cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null >&2 || echo "  (resolv.conf пустой)" >&2
        exit 1
    fi
    echo "  ✓ сеть готова"

    mkdir -p /etc/amnezia/amneziawg
    cd /tmp
    for PKG in "kmod-amneziawg_v${AWG_VER}" "amneziawg-tools_v${AWG_VER}" "luci-proto-amneziawg_v${AWG_VER}"; do
        FILE="${PKG}_${ARCH}.apk"
        wget -q -T 30 -O "$FILE" "$BASE/$FILE" || { echo "download failed: $FILE"; exit 1; }
    done
    APK_ERR=$(apk add --allow-untrusted \
                  "./kmod-amneziawg_v${AWG_VER}_${ARCH}.apk" \
                  "./amneziawg-tools_v${AWG_VER}_${ARCH}.apk" \
                  "./luci-proto-amneziawg_v${AWG_VER}_${ARCH}.apk" 2>&1) || {
        echo "✗ apk add не удался. Вероятная причина: kmod-amneziawg v${AWG_VER} собран" >&2
        echo "  для другого ядра, чем запущено на роутере ($(uname -r))." >&2
        echo "  Попробуйте обновить прошивку до OpenWrt 25.12.x через LuCI и запустить установку заново." >&2
        echo "  Детали ошибки apk:" >&2
        printf '%s\n' "$APK_ERR" | grep -v '^$' >&2
        exit 1
    }
    if ! modprobe amneziawg; then
        echo "✗ modprobe amneziawg завершился с ошибкой." >&2
        echo "  kmod-amneziawg v${AWG_VER} установлен, но не совместим с текущим ядром ($(uname -r))." >&2
        echo "  Диагностика: dmesg | tail -20" >&2
        exit 1
    fi
fi

# === 2. Парсим .conf ===
PRIV=$(awg_get_iface PrivateKey "$CONF")
ADDR=$(awg_get_iface Address    "$CONF")
JC=$(awg_get_iface Jc           "$CONF")
JMIN=$(awg_get_iface Jmin       "$CONF")
JMAX=$(awg_get_iface Jmax       "$CONF")
S1=$(awg_get_iface S1           "$CONF")
S2=$(awg_get_iface S2           "$CONF")
# v1.5 опциональные параметры (могут отсутствовать в v1.0 конфигах):
S3=$(awg_get_iface S3           "$CONF")
S4=$(awg_get_iface S4           "$CONF")
H1=$(awg_get_iface H1           "$CONF")
H2=$(awg_get_iface H2           "$CONF")
H3=$(awg_get_iface H3           "$CONF")
H4=$(awg_get_iface H4           "$CONF")
# I1-I5 — Custom Protocol Signature (AWG v1.5), опционально:
I1=$(awg_get_iface I1           "$CONF")
I2=$(awg_get_iface I2           "$CONF")
I3=$(awg_get_iface I3           "$CONF")
I4=$(awg_get_iface I4           "$CONF")
I5=$(awg_get_iface I5           "$CONF")

PUB=$(awg_get_peer PublicKey           "$CONF")
PSK=$(awg_get_peer PresharedKey        "$CONF")
EP=$(awg_get_peer Endpoint             "$CONF")
KA=$(awg_get_peer PersistentKeepalive  "$CONF")
# Split endpoint host:port (поддерживает IPv6 [::1]:51820)
EP_HOST=$(awg_endpoint_host "$EP")
EP_PORT=$(awg_endpoint_port "$EP")

[ -n "$PRIV" ] && [ -n "$PUB" ] && [ -n "$EP_HOST" ] || { echo "ERROR: .conf parse failed"; exit 1; }

echo "→ parsed: Address=$ADDR, Endpoint=$EP_HOST:$EP_PORT, PSK=$([ -n "$PSK" ] && echo yes || echo no)"

# === 2.5. Диагностика: ищем неизвестные поля в [Interface] ===
# Если AmneziaWG в будущем добавит новые поля (X1, X2, ...), наш парсер их
# проигнорирует, awg0 поднимется со старым набором и handshake не пройдёт.
# Чтобы такая ситуация не выглядела как «непонятный баг», громко предупредим
# и попросим прислать лог. Это диагностика, не починка.
KNOWN_FIELDS='PrivateKey|Address|MTU|DNS|ListenPort|FwMark|Table|SaveConfig|PreUp|PostUp|PreDown|PostDown|Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5'
UNKNOWN=$(awk -F' *= *' '
    /^\[Peer\]/ { exit }
    /^\[Interface\]/ { next }
    /^[[:space:]]*(#|;|$)/ { next }
    /=/ { print $1 }
' "$CONF" | tr -d ' \r' | grep -vxE "$KNOWN_FIELDS" || true)

if [ -n "$UNKNOWN" ]; then
    echo "⚠ В $CONF есть НЕИЗВЕСТНЫЕ поля в [Interface]:"
    echo "$UNKNOWN" | sed 's/^/    /'
    echo "  Возможно, это новая версия AmneziaWG-протокола, которую наш парсер"
    echo "  ещё не знает. Если awg0 не поднимется или handshake не пройдёт —"
    echo "  пришлите этот лог в Telegram (@industrialprofi) с пометкой про новые поля."
fi

# === 3. UCI network interface ===
echo "→ создаём UCI network.awg0"
uci -q delete network.awg0 2>/dev/null || true
uci set network.awg0=interface
uci set network.awg0.proto='amneziawg'
uci set network.awg0.private_key="$PRIV"
uci add_list network.awg0.addresses="$ADDR"
uci set network.awg0.mtu='1420'
# Все AWG-параметры обфускации — ОПЦИОНАЛЬНЫ. Записываем только если поле
# действительно присутствует в .conf — иначе proto-handler получает пустую
# строку и netifd не может поднять интерфейс.
[ -n "$JC" ]   && uci set network.awg0.awg_jc="$JC"
[ -n "$JMIN" ] && uci set network.awg0.awg_jmin="$JMIN"
[ -n "$JMAX" ] && uci set network.awg0.awg_jmax="$JMAX"
[ -n "$S1" ]   && uci set network.awg0.awg_s1="$S1"
[ -n "$S2" ]   && uci set network.awg0.awg_s2="$S2"
[ -n "$H1" ]   && uci set network.awg0.awg_h1="$H1"
[ -n "$H2" ]   && uci set network.awg0.awg_h2="$H2"
[ -n "$H3" ]   && uci set network.awg0.awg_h3="$H3"
[ -n "$H4" ]   && uci set network.awg0.awg_h4="$H4"
# v1.5 опциональные параметры
[ -n "$S3" ] && uci set network.awg0.awg_s3="$S3"
[ -n "$S4" ] && uci set network.awg0.awg_s4="$S4"
[ -n "$I1" ] && uci set network.awg0.awg_i1="$I1"
[ -n "$I2" ] && uci set network.awg0.awg_i2="$I2"
[ -n "$I3" ] && uci set network.awg0.awg_i3="$I3"
[ -n "$I4" ] && uci set network.awg0.awg_i4="$I4"
[ -n "$I5" ] && uci set network.awg0.awg_i5="$I5"

# Peer section
while uci -q delete network.@amneziawg_awg0[0]; do :; done
PEER=$(uci add network amneziawg_awg0)
uci set network.${PEER}.description='peer0'
uci set network.${PEER}.public_key="$PUB"
[ -n "$PSK" ] && uci set network.${PEER}.preshared_key="$PSK"
uci add_list network.${PEER}.allowed_ips='0.0.0.0/0'
uci add_list network.${PEER}.allowed_ips='::/0'
uci set network.${PEER}.endpoint_host="$EP_HOST"
uci set network.${PEER}.endpoint_port="$EP_PORT"
uci set network.${PEER}.persistent_keepalive="${KA:-25}"
# КРИТИЧНО: маршрутизацией будет заниматься podkop, не netifd
uci set network.${PEER}.route_allowed_ips='0'

uci commit network

# === 4. Firewall zone 'vpn' ===
echo "→ создаём firewall zone 'vpn'"
# Удаляем старую если есть
idx=$(uci show firewall | awk -F'[][]' '/@zone.*name=.vpn./{print $2; exit}')
[ -n "$idx" ] && uci -q delete firewall.@zone[$idx] || true

uci add firewall zone >/dev/null
uci set firewall.@zone[-1].name='vpn'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='awg0'

# Forwarding lan → vpn
if ! uci show firewall | grep -q "src='lan'.*dest='vpn'" 2>/dev/null; then
    uci add firewall forwarding >/dev/null
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='vpn'
fi

uci commit firewall

# === 5. Restart network (поднять awg0) ===
echo "→ перезапуск сети (на медленных роутерах может занять до минуты)..."
/etc/init.d/network restart 2>&1 | tail -5 || true
/etc/init.d/firewall reload 2>&1 | tail -3 || true

# === 6. Проверка — ждём awg0 до 60 сек.
# На Cudy TR3000 (MT7530 switch) после network restart link проходит
# DOWN→UP цикл (~10–20 сек), и только после этого netifd инициализирует awg0.
AWG_UP=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    sleep 2
    if ip -4 addr show awg0 2>/dev/null | grep -q inet; then
        AWG_UP=1
        break
    fi
done

if [ "$AWG_UP" = "1" ]; then
    echo "✓ awg0 interface UP: $(ip -4 addr show awg0 | awk '/inet/{print $2}')"
else
    echo "⚠ awg0 не поднялся за 60 сек. Диагностика:"
    echo "--- ip addr show awg0 ---"
    ip addr show awg0 2>&1 || true
    echo "--- uci show network.awg0 (секреты замаскированы) ---"
    # ВАЖНО: маскируем ОБА секрета — private_key и preshared_key.
    # Этот дамп пользователь будет скриншотить и присылать в Telegram,
    # поэтому он должен быть безопасен для публичной пересылки.
    {
        uci show network.awg0 2>&1
        uci -q show network.@amneziawg_awg0[0] 2>&1
    } | sed -E "s/(private_key|preshared_key)='[^']*'/\1='<СКРЫТ>'/g" || true
    echo "--- kmod-amneziawg загружен? ---"
    lsmod | grep -E '^amneziawg' || echo "(не загружен)"
    echo "--- logread (amnezia/netifd/awg, последние 40 строк) ---"
    # logread -l 500: ограничиваем ВХОД в grep последними 500 записями syslog,
    # чтобы на забитых роутерах не читать мегабайты с забитой flash.
    logread -l 500 2>/dev/null | grep -iE 'amnezia|netifd|awg' | tail -40 || true
    echo "--- awg show ---"
    awg show 2>&1 || true
    exit 1
fi

# Дадим 10 секунд на первый handshake
echo "→ ждём handshake (до 10 сек)..."
for _ in 1 2 3 4 5; do
    sleep 2
    if awg show awg0 | grep -q 'latest handshake'; then
        hs=$(awg show awg0 | awk '/latest handshake:/{print $3,$4,$5,$6,$7,$8}')
        echo "✓ handshake: $hs"
        exit 0
    fi
done

echo "⚠ handshake не получен за 10 сек — может быть проблема с сервером или параметрами"
echo "  Проверьте: awg show awg0, awg-quick, traceroute до endpoint'а"
exit 0
