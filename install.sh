#!/bin/sh
# install.sh — развернуть веб-мастер cheburnet-router на свежем OpenWrt.
#
# ЗАПУСКАЕТСЯ НА САМОМ РОУТЕРЕ, не с ноутбука.
#
# Разовая команда для установки (из терминала ноутбука):
#   ssh root@192.168.1.1 'wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/master/install.sh | sh'
#
# Или вручную на роутере:
#   wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/master/install.sh | sh
#
# После выполнения откройте в браузере:
#   http://<IP_роутера>/cheburnet/
#
# Всё остальное — настройку VPN, Wi-Fi, adblock — мастер сделает сам.
#
# Тело скрипта обёрнуто в main() — вызов в самом конце. Это защищает от
# частичной загрузки: если `wget | sh` оборвётся, shell не дойдёт до `main "$@"`
# и НИ ОДНА строка не выполнится, даже если файл скачался наполовину.
set -e

REPO_TAR="https://codeload.github.com/yurik2718/cheburnet-router/tar.gz/refs/heads/master"
INSTALL_DIR="/opt/cheburnet"
WEB_DIR="/www/cheburnet"
RPCD_BIN="/usr/libexec/rpcd/cheburnet"
RPCD_ACL="/usr/share/rpcd/acl.d/cheburnet.json"
STEPS_TOTAL=8

# === helpers ==========================================================
# shell_timeout <sec> <cmd> [args...]
# Запускает cmd, прибивает через sec секунд, если ещё жив. Чисто-shell, не
# требует /usr/bin/timeout — в BusyBox install-image OpenWrt 25.12 его нет,
# а ставить coreutils-timeout через apk было бы курицей-и-яйцом (мы как раз
# и оборачиваем apk таймаутом). Возврат: код возврата cmd, либо 124 если убит.
shell_timeout() {
    sec="$1"; shift
    "$@" &
    cmd_pid=$!
    # Watchdog: раз в секунду проверяет kill -0; если cmd сама завершилась —
    # выходит сразу, не сжигая остаток дедлайна.
    (
        i=0
        while [ "$i" -lt "$sec" ]; do
            sleep 1
            kill -0 "$cmd_pid" 2>/dev/null || exit 0
            i=$((i + 1))
        done
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep 2
        kill -KILL "$cmd_pid" 2>/dev/null
    ) &
    wait "$cmd_pid" 2>/dev/null
    rc=$?
    # POSIX: процесс, убитый сигналом N, даёт wait-код 128+N. SIGTERM=15 → 143.
    [ "$rc" -gt 128 ] && return 124
    return "$rc"
}

# with_retry <timeout_sec> <attempts> <label> <cmd> [args...]
# Оборачивает cmd в shell_timeout, повторяет до <attempts> раз.
with_retry() {
    timeout_sec="$1"
    attempts="$2"
    label="$3"
    shift 3
    i=1
    while [ "$i" -le "$attempts" ]; do
        if shell_timeout "$timeout_sec" "$@"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            echo "      ⚠ $label: попытка $i/$attempts не уложилась в ${timeout_sec}с — повтор..."
        fi
        i=$((i + 1))
    done
    return 1
}

step() {
    echo
    echo "[$1/$STEPS_TOTAL] $2"
}

ok() {
    echo "      ✓ $1"
}

fail_msg() {
    echo "      ✗ $1"
}

# Wrapper'ы для команд с файловым перенаправлением — нужны, чтобы перенаправление
# применилось к самой команде, а не к with_retry (иначе warnings о повторе уйдут
# в файл и пользователь их не увидит).
_apk_install_base() {
    apk add --no-interactive uhttpd-mod-ubus rpcd jsonfilter >/tmp/apk-out 2>&1
}

_wget_src() {
    wget -qO source.tar.gz "$REPO_TAR"
}

main() {

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║   cheburnet-router · web-мастер                      ║"
echo "║   установка на этот роутер                           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo

START_TS=$(date +%s)

# === Sanity checks (pre-flight, без номера шага) ==========================
if [ ! -f /etc/openwrt_release ]; then
    fail_msg "Это не OpenWrt. install.sh запускается только на OpenWrt 25.12+."
    exit 1
fi

if ! command -v apk >/dev/null 2>&1; then
    fail_msg "apk не найден. Нужен OpenWrt 25.12+, где apk — пакетный менеджер."
    echo "        На OpenWrt 23.05/24.10 (с opkg) используйте ./setup.sh с ноутбука."
    exit 1
fi

. /etc/openwrt_release
echo "  Роутер:       $DISTRIB_DESCRIPTION"
echo "  Архитектура:  $(uname -m)"

# Установщик + подкop + awg занимают ~30 MB на /overlay
AVAIL_KB=$(df /overlay | awk 'NR==2{print $4}')
if [ "$AVAIL_KB" -lt 40000 ]; then
    echo "  ⚠ Мало места на /overlay: ${AVAIL_KB}KB. Рекомендуется ≥40MB."
    echo "    Продолжаем, но установка может не поместиться."
fi

# === [1/8] Интернет ====================================================
# wget (BusyBox) — тот же инструмент, которым install.sh был скачан.
# uclient-fetch здесь не используем: на свежем OpenWrt без ca-bundle он
# падает на SSL-валидации даже при рабочем интернете, тогда как wget
# BusyBox по умолчанию SSL не проверяет и проходит.
# URL указываем конкретный файл (не корень) — корень даёт 301-редирект,
# который некоторые сборки BusyBox wget расценивают как ошибку.
step 1 "Проверяю интернет"
if ! wget -qO /dev/null --timeout=10 \
    "https://raw.githubusercontent.com/yurik2718/cheburnet-router/master/install.sh" \
    2>/dev/null; then
    fail_msg "Нет доступа к GitHub. Диагностика:"
    echo
    PING_OK=0
    DNS_OK=0
    echo "  [1/2] ping 8.8.8.8 (IP-связность без DNS):"
    if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "    ✓ ping прошёл"
        PING_OK=1
    else
        echo "    ✗ ping не прошёл — WAN не подключён"
        echo "    → Проверьте кабель провайдера в WAN-порту роутера."
        echo "      Если провайдер требует PPPoE/VLAN — настройте WAN вручную:"
        echo "      http://192.168.1.1 → Network → Interfaces → WAN"
    fi
    echo
    echo "  [2/2] nslookup github.com (DNS):"
    if nslookup github.com >/dev/null 2>&1; then
        echo "    ✓ DNS работает"
        DNS_OK=1
    else
        echo "    ✗ DNS не отвечает — роутер не резолвит имена"
        echo "    → Запустите из SSH на роутере: nslookup github.com 8.8.8.8"
    fi
    echo
    if [ "$PING_OK" = "1" ] && [ "$DNS_OK" = "1" ]; then
        echo "  ⚠ Интернет работает, но GitHub недоступен."
        echo "    HTTPS-соединение с raw.githubusercontent.com не проходит"
        echo "    через вашу сеть — типичная ситуация для части провайдеров"
        echo "    и публичных Wi-Fi с фильтрацией трафика."
        echo
        echo "  Решение: запустите установку через мобильный интернет."
        echo "    После первого запуска роутер сам обеспечит доступ через"
        echo "    зашифрованный туннель."
        echo "    1. На телефоне включите «Режим модема» / «Точка доступа»"
        echo "    2. Подключите WAN-порт роутера к телефону (USB или Wi-Fi)"
        echo "    3. Запустите установку снова"
    fi
    exit 1
fi
ok "интернет есть"

# === [2/8] Индекс пакетов =============================================
# apk легко зависает на mirror'е downloads.openwrt.org: DPI-шейпинг или дальний
# PoP Fastly отдают байты по 5 КБ/с, FIN не приходит, apk ждёт навсегда. Жёсткий
# таймаут + 3 попытки разрывают повисший сокет и заставляют переподключиться.
step 2 "Обновляю индекс пакетов (таймаут 120с, до 3 попыток)"
if ! with_retry 120 3 "apk update" apk update; then
    fail_msg "apk update не прошёл после 3 попыток по 120с."
    echo "        Скорее всего провайдер режет канал до downloads.openwrt.org (DPI-шейпинг)."
    echo "        Проверьте вручную: wget -qO /dev/null https://downloads.openwrt.org/"
    echo "        Установщик идемпотентен — после восстановления сети можно перезапустить."
    exit 1
fi
ok "индексы обновлены"

# === [3/8] Базовые пакеты =============================================
# rpcd обычно предустановлен, jsonfilter — отдельный пакет для парсинга
# ubus-вывода. apk add идемпотентен.
step 3 "Устанавливаю системные зависимости (uhttpd-mod-ubus, rpcd, jsonfilter)"
if ! with_retry 180 3 "apk add" _apk_install_base; then
    tail -10 /tmp/apk-out
    fail_msg "Не удалось установить базовые пакеты после 3 попыток по 180с."
    echo "        Проверьте: apk update && apk search uhttpd-mod-ubus"
    exit 1
fi
APK_SUMMARY=$(grep '^OK:' /tmp/apk-out | tail -1 | sed 's/^OK: //')
ok "${APK_SUMMARY:-пакеты установлены}"

# === [4/8] Скачать исходники ==========================================
# wget tar.gz с codeload.github.com — те же сетевые риски, что и у apk:
# DPI/Fastly могут заворачивать в slow-trickle без FIN. Тот же паттерн.
step 4 "Скачиваю cheburnet-router с GitHub"
rm -rf /tmp/cheburnet-src
mkdir -p /tmp/cheburnet-src
cd /tmp/cheburnet-src
if ! with_retry 90 3 "wget tar.gz" _wget_src; then
    fail_msg "Не удалось скачать исходники с $REPO_TAR"
    echo "        Возможно, codeload.github.com под DPI у вашего провайдера."
    echo "        Установщик идемпотентен — после восстановления сети можно перезапустить."
    exit 1
fi
tar xzf source.tar.gz
SRC=$(find . -maxdepth 1 -type d -name 'cheburnet-router*' | head -1)
[ -n "$SRC" ] || { fail_msg "Не удалось распаковать архив"; exit 1; }
ok "архив получен и распакован"

# === [5/8] Установка файлов ===========================================
step 5 "Устанавливаю файлы"
mkdir -p "$INSTALL_DIR"
cp -r "$SRC/setup"    "$INSTALL_DIR/"
cp -r "$SRC/scripts"  "$INSTALL_DIR/"
cp -r "$SRC/configs"  "$INSTALL_DIR/"
cp -r "$SRC/lib"      "$INSTALL_DIR/"
cp -r "$SRC/web"      "$INSTALL_DIR/"
# vendor/ — запасные копии podkop/adblock-lean инсталлеров на случай,
# если raw.githubusercontent.com заблокирован у пользователя на DPI.
[ -d "$SRC/vendor" ] && cp -r "$SRC/vendor" "$INSTALL_DIR/"
# Все setup-скрипты + установочные тулзы должны быть исполняемые.
chmod +x "$INSTALL_DIR/setup/"*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/"* 2>/dev/null || true
ok "$INSTALL_DIR (исходники)"

mkdir -p "$(dirname "$RPCD_BIN")"
cp "$SRC/web/rpcd-cheburnet" "$RPCD_BIN"
chmod +x "$RPCD_BIN"
ok "$RPCD_BIN (RPC-handler)"

mkdir -p "$(dirname "$RPCD_ACL")"
cp "$SRC/web/rpcd-acl.json" "$RPCD_ACL"
ok "$RPCD_ACL (ACL)"

mkdir -p "$WEB_DIR"
cp "$SRC/web/index.html"      "$WEB_DIR/index.html"
cp "$SRC/web/cheburashka.png" "$WEB_DIR/cheburashka.png"
cp "$SRC/web/favicon.png"     "$WEB_DIR/favicon.png"
ok "$WEB_DIR (веб-UI)"

# Runtime state directory — служебная директория, без отдельной строки.
mkdir -p /tmp/cheburnet
chmod 755 /tmp/cheburnet

# === [6/8] uhttpd =====================================================
# На голом OpenWrt без LuCI option ubus_prefix может быть не установлен.
# Без него браузер не сможет вызывать ubus-методы.
step 6 "Настраиваю uhttpd"
if ! uci -q get uhttpd.main.ubus_prefix >/dev/null; then
    uci set uhttpd.main.ubus_prefix='/ubus'
    uci commit uhttpd
    ok "/ubus endpoint добавлен в конфиг uhttpd"
else
    ok "/ubus endpoint уже настроен"
fi

# === [7/8] Install-token ==============================================
# Защита от LAN-сквоттинга: даже если кто-то откроет /cheburnet/ до того, как
# легитимный пользователь начал установку, install_start откажет без токена.
# 16 случайных байт hex (32 символа) — brute-force невозможен.
step 7 "Генерирую одноразовый токен доступа"
mkdir -p /etc/cheburnet
TOKEN=$(head -c 16 /dev/urandom | hexdump -e '16/1 "%02x"')
printf '%s' "$TOKEN" > /etc/cheburnet/install-token
chmod 600 /etc/cheburnet/install-token
ok "/etc/cheburnet/install-token (32 hex-символа)"

# === [8/8] Перезапуск сервисов ========================================
step 8 "Перезапускаю сервисы"
/etc/init.d/rpcd enable
/etc/init.d/rpcd restart
ok "rpcd"

/etc/init.d/uhttpd enable
/etc/init.d/uhttpd restart
ok "uhttpd"

sleep 2

if ubus list cheburnet >/dev/null 2>&1; then
    ok "ubus cheburnet зарегистрирован"
else
    echo "      ⚠ ubus cheburnet НЕ зарегистрирован. Проверьте:"
    echo "          logread | grep rpcd"
    echo "          sh -x $RPCD_BIN list"
fi

# === Финал ============================================================
# shellcheck source=lib/net-detect.sh disable=SC1090,SC1091
. "$INSTALL_DIR/lib/net-detect.sh"
ROUTER_IP=$(net_lan_ip 192.168.1.1)

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
if [ "$ELAPSED" -ge 60 ]; then
    ELAPSED_STR="$((ELAPSED / 60))м $((ELAPSED % 60))с"
else
    ELAPSED_STR="${ELAPSED}с"
fi

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✓ Установка завершена                              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
echo "  Заняло: $ELAPSED_STR"
echo
echo "  Откройте в браузере (токен подставится сам):"
echo "  →  http://$ROUTER_IP/cheburnet/?token=$TOKEN"
echo
echo "  Если URL c токеном не сработал — откройте без него и"
echo "  введите токен вручную на Шаге 1:"
echo "    Token: $TOKEN"
echo
echo "  Токен — одноразовый, удаляется после успешной установки."
echo "  Веб-мастер настроит VPN, Wi-Fi и adblock сам."
echo

# Cleanup
rm -rf /tmp/cheburnet-src

}

main "$@"
