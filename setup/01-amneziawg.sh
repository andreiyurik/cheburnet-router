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

    # Сначала ждём готовности сети — awg_pick_version ниже идёт на github
    # (HEAD-запрос на .apk + GitHub API за latest-тегом). Если WAN ещё не
    # приехал (после reboot DHCP занимает 15-30 сек), wget не разрезолвит
    # хост, функция вернёт пусто, и юзер увидит ложное «нет совместимого
    # релиза» вместо честного «сеть не готова». Раньше эта проверка была
    # ПОСЛЕ awg_pick_version и каскадно отказывалась объяснять реальную причину.
    # Ждём до 60 сек: nameserver в resolv.conf + ping до 8.8.8.8.
    echo "→ ожидаем готовности сети перед скачиванием..."
    _net_ready=0
    for _w in 1 2 3 4 5 6 7 8 9 10 11 12; do
        # ping ИЛИ wget-spider: ICMP режется в части сетей (корпоративные wifi,
        # некоторые мобильные APN, qemu user-mode netdev), но HTTP к OpenWrt-
        # зеркалам в них всё равно работает — это ровно тот канал, по которому
        # пойдёт apk add ниже. Та же логика — в lib/cheburnet-preflight.sh.
        if grep -q '^nameserver' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null \
           && { ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 \
                || wget -q --spider --timeout=5 http://downloads.openwrt.org/ 2>/dev/null; }; then
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

    AWG_VER="$(awg_pick_version "$DISTRIB_RELEASE" "$ARCH")" || AWG_VER=""
    if [ -z "$AWG_VER" ]; then
        echo "✗ Нет совместимого релиза awg-openwrt для OpenWrt ${DISTRIB_RELEASE} / ${ARCH}." >&2
        echo "  Доступные релизы: https://github.com/Slava-Shchipunov/awg-openwrt/releases" >&2
        echo "  Если вашей архитектуры нет — соберите пакет вручную по инструкции из репозитория." >&2
        exit 1
    fi
    echo "  arch=${ARCH}, awg-openwrt=v${AWG_VER}"

    BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${AWG_VER}"

    mkdir -p /etc/amnezia/amneziawg
    cd /tmp
    for PKG in "kmod-amneziawg_v${AWG_VER}" "amneziawg-tools_v${AWG_VER}" "luci-proto-amneziawg_v${AWG_VER}"; do
        FILE="${PKG}_${ARCH}.apk"
        # Один промах wget на GitHub releases CDN (release-assets.github*.com)
        # = установка целиком падает у юзера. 3 попытки с backoff закрывают
        # 99% транзиентных сбоев: DPI throttle, временный timeout, TCP RST
        # после редиректа на blob.core.windows.net. Поймано T4 на alt-сети:
        # один прогон файл не качался, второй прогон через минуту — OK.
        attempt=0
        while [ "$attempt" -lt 3 ]; do
            if wget -q -T 30 -O "$FILE" "$BASE/$FILE"; then break; fi
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 3 ]; then
                echo "✗ download failed after 3 attempts: $FILE"
                echo "  URL: $BASE/$FILE"
                echo "  Проверьте: wget $BASE/$FILE с роутера руками; если падает —"
                echo "  возможно блокировка release-assets.githubusercontent.com у провайдера."
                exit 1
            fi
            echo "  ⚠ download flake (попытка $attempt/3), повтор через $((attempt * 5))s..."
            sleep $((attempt * 5))
        done
    done
    # apk изредка падает с "ADB integrity error" / "download failed"
    # из-за рассинхрона индекса или оборванной закачки с зеркала. Один
    # повтор после apk update закрывает такие транзиентные сбои без
    # ручного вмешательства. Реальный kernel-mismatch ловится ниже через
    # modprobe — гадать о причине по тексту apk не нужно.
    awg_apk_add() {
        apk add --allow-untrusted \
            "./kmod-amneziawg_v${AWG_VER}_${ARCH}.apk" \
            "./amneziawg-tools_v${AWG_VER}_${ARCH}.apk" \
            "./luci-proto-amneziawg_v${AWG_VER}_${ARCH}.apk" 2>&1
    }
    if ! APK_ERR=$(awg_apk_add); then
        echo "  apk add упал, обновляю индексы и повторяю..."
        apk update >/dev/null 2>&1 || true
        if ! APK_ERR=$(awg_apk_add); then
            echo "✗ apk add не удался после повтора. Вывод apk:" >&2
            printf '%s\n' "$APK_ERR" | grep -v '^$' >&2
            # Диагностика причины — DPI на «amneziawg» сейчас редко (это не
            # известный VPN-инструмент в DPI-сигнатурах), но всё же стоит
            # проверить и направить юзера в правильное место.
            command -v cheburnet_apk_fail_advice >/dev/null 2>&1 \
                && cheburnet_apk_fail_advice amneziawg
            exit 1
        fi
    fi
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

# === 6. Ждём awg0 = UP + первый handshake. Условие готовности — handshake,
# а не просто UP-интерфейс: UP без handshake это «туннель есть, но крипта
# не сошлась с сервером», что в proto-handler ловится тем же EINVAL.
# На Cudy TR3000 (MT7530 switch) после network restart link проходит
# DOWN→UP цикл (~10–20 сек), и только после этого netifd инициализирует awg0.
awg_wait_ready() {
    _max="$1"
    _elapsed=0
    while [ "$_elapsed" -lt "$_max" ]; do
        if ip -4 addr show awg0 2>/dev/null | grep -q inet \
           && awg show awg0 latest-handshakes 2>/dev/null \
                | awk '{ if ($2+0 > 0) ok=1 } END { exit !ok }'; then
            return 0
        fi
        sleep 2
        _elapsed=$((_elapsed + 2))
    done
    return 1
}

AWG_OK=0
DROPPED=""   # человекочитаемое описание полей, которые пришлось снять
awg_wait_ready 60 && AWG_OK=1

# Fallback 1 — без I1.
# I1 (CPS-decoy, AWG 2.0) — единственное поле с нестандартным синтаксисом
# '<r N><b 0x...>' и пробелом внутри значения. Падает в двух типичных
# сценариях, неразличимых снаружи:
#   • proto-handler в свежих luci-proto-amneziawg валит netifd на нём
#     ("Unable to modify interface: Invalid argument"), хотя kmod значения
#     принимает (видно в `awg show`).
#   • self-hosted VPS с устаревшим серверным amneziawg-go не знает CPS,
#     handshake не доходит даже если интерфейс UP.
# По доке Amnezia I1-I5 опциональны со стороны клиента — если их не слать,
# просто не уходят decoy-пакеты, обфускация чуть слабее, но handshake идёт.
if [ "$AWG_OK" = "0" ] && [ -n "$I1" ]; then
    echo "⚠ awg0 не готов за 60 сек — пробую без I1..."
    # `uci -q delete` возвращает 1 если ключа нет; с `set -e` это убивает
    # шаг. На "грязных" UCI-состояниях (повторный install после фейла) I1
    # уже может быть удалён предыдущим запуском. Защита-в-глубину.
    uci -q delete network.awg0.awg_i1 2>/dev/null || true
    uci commit network
    ifdown awg0 2>/dev/null; sleep 2; ifup awg0
    if awg_wait_ready 30; then
        AWG_OK=1
        DROPPED="I1"
    fi
fi

# Fallback 2 — дополнительно без S3/S4.
# S3/S4 (AWG 2.0) — это «junk-байты» внутри handshake-пакета. На сервере
# с legacy amneziawg-go (AWG 1.0) этих полей нет, и если клиент шлёт их —
# сервер видит handshake неверной длины и молча отбрасывает. Снимаем S3/S4
# на клиенте → формат пакета становится 1.0-совместимым.
# Минусы: чуть слабее обфускация против DPI. Лечится обновлением сервера
# (см. docs/09-troubleshooting.md «AmneziaWG: handshake не идёт»).
if [ "$AWG_OK" = "0" ] && { [ -n "$S3" ] || [ -n "$S4" ]; }; then
    echo "⚠ всё ещё не готов — пробую без S3/S4 (похоже на legacy AWG 1.0 сервер)..."
    # Все три могут быть уже удалены фолбэком 1 или отсутствовать в конфиге;
    # `set -e` на их exit-1 убивает фолбэк-цепочку до её завершения.
    uci -q delete network.awg0.awg_i1   2>/dev/null || true
    uci -q delete network.awg0.awg_s3   2>/dev/null || true
    uci -q delete network.awg0.awg_s4   2>/dev/null || true
    uci commit network
    ifdown awg0 2>/dev/null; sleep 2; ifup awg0
    if awg_wait_ready 30; then
        AWG_OK=1
        DROPPED="I1+S3+S4"
    fi
fi

# Fallback 3 — нормализация H-диапазонов (AWG 2.0 → single values).
# Свежие self-hosted Amnezia-серверы (с ~2025 года) генерят .conf с
# диапазонами в H1-H4 (формат "NUM-NUM"). Это AWG 2.0-фича для рандомизации
# header-байтов в каждом пакете. Если на клиенте (amneziawg-tools/proto-
# handler/kmod в openwrt) поддержка диапазонов ещё не доехала или
# рассинхронизирована — handshake не сходится при том что awg0 UP.
# Берём первое значение из каждого диапазона: single value входит в
# «диапазон допустимых» на сервере, handshake идёт. Минусы: рандомизации
# header-байтов больше нет, обфускация ослабевает на эту фичу.
# Случай реальный: юзер с self-hosted Amnezia на VPS, серверный conf
# содержал H1=213093219-313093218 (и далее), tunnel UP но трафик не шёл.
if [ "$AWG_OK" = "0" ]; then
    case "${H1}${H2}${H3}${H4}" in
        *-*)
            echo "⚠ всё ещё не готов — нормализую H-диапазоны до single values (AWG 2.0 → 1.0)..."
            [ -n "$H1" ] && uci set network.awg0.awg_h1="${H1%%-*}"
            [ -n "$H2" ] && uci set network.awg0.awg_h2="${H2%%-*}"
            [ -n "$H3" ] && uci set network.awg0.awg_h3="${H3%%-*}"
            [ -n "$H4" ] && uci set network.awg0.awg_h4="${H4%%-*}"
            uci commit network
            ifdown awg0 2>/dev/null; sleep 2; ifup awg0
            if awg_wait_ready 30; then
                AWG_OK=1
                DROPPED="${DROPPED:+${DROPPED}+}H-ranges→singles"
            fi
            ;;
    esac
fi

if [ "$AWG_OK" = "1" ]; then
    addr=$(ip -4 addr show awg0 | awk '/inet/{print $2}')
    hs=$(awg show awg0 | awk -F': ' '/latest handshake/{print $2; exit}')
    echo "✓ awg0 interface UP: $addr"
    [ -n "$hs" ] && echo "✓ handshake: $hs"
    if [ -n "$DROPPED" ]; then
        echo ""
        echo "ℹ Применён fallback: сняты поля AWG 2.0 ($DROPPED)."
        echo "  Скорее всего, ваш amneziawg-сервер не поддерживает эти параметры"
        echo "  (legacy-сборка amneziawg-go) — самим AmneziaWG-туннелем это не ломает,"
        echo "  но обфускация чуть слабее. Лечение и подробности —"
        echo "  docs/09-troubleshooting.md, раздел «AmneziaWG: handshake не идёт»."
    fi
    exit 0
fi

echo "⚠ awg0 не готов даже после fallback'ов."
# Восстанавливаем исходный UCI: fallback'и не помогли, значит проблема не в
# I1/S3/S4/H-ranges. Не оставляем пользователя с куцым профилем — если он
# потом починит сервер/сеть и сделает `ifup awg0`, поднимется полный набор.
# Опираемся на переменные $I1/$S3/$S4/$H1-$H4 из парсинга .conf выше —
# это и есть «исходное» значение, которое мы клали в UCI до fallback'ов.
_h_has_ranges=0
case "${H1}${H2}${H3}${H4}" in *-*) _h_has_ranges=1 ;; esac
if [ -n "$I1" ] || [ -n "$S3" ] || [ -n "$S4" ] || [ "$_h_has_ranges" = "1" ]; then
    echo "→ восстанавливаю UCI awg0 (I1/S3/S4/H-ranges) до исходных значений из .conf..."
    [ -n "$I1" ] && uci set network.awg0.awg_i1="$I1"
    [ -n "$S3" ] && uci set network.awg0.awg_s3="$S3"
    [ -n "$S4" ] && uci set network.awg0.awg_s4="$S4"
    if [ "$_h_has_ranges" = "1" ]; then
        [ -n "$H1" ] && uci set network.awg0.awg_h1="$H1"
        [ -n "$H2" ] && uci set network.awg0.awg_h2="$H2"
        [ -n "$H3" ] && uci set network.awg0.awg_h3="$H3"
        [ -n "$H4" ] && uci set network.awg0.awg_h4="$H4"
    fi
    uci commit network
fi
unset _h_has_ranges
echo "Диагностика:"
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
echo ""
echo "Если 'awg show' выше показывает все параметры, а 'ip addr' — DOWN,"
echo "это баг proto-handler в этой версии awg-openwrt, а не вашего конфига."
echo "Если интерфейс UP, но handshake пуст — проблема на стороне сервера,"
echo "сверьте Jc/S1/S2/H1-H4 на клиенте и VPS, проверьте 'amneziawg-go --version'"
echo "на сервере. Подробности — docs/09-troubleshooting.md."
exit 1
