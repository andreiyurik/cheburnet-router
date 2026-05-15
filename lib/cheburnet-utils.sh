# lib/cheburnet-utils.sh — общие pure-функции cheburnet-router.
#
# Source-only: ничего не выполняет, только определяет функции. Не имеет shebang
# (sourcer'ы — POSIX sh / busybox-ash / bats-core).
#
# Подключение:
#   . /opt/cheburnet/lib/cheburnet-utils.sh   # на роутере
#   . lib/cheburnet-utils.sh                   # из репо-чекаута / тестов
#
# Все функции — без side-effects (не читают/пишут глобальное состояние, не
# создают файлов). Это контракт: любое нарушение делает T2-тесты бессмысленными.
# Единственное исключение — awg_pick_version: делает HEAD-запрос к GitHub (но
# без побочных эффектов на ФС/окружение, что мокается через PATH-shim на wget).

# ─────────────────────────────────────────────────────────────────────────────
# JSON
# ─────────────────────────────────────────────────────────────────────────────

# json_escape STRING
# Экранирует произвольную строку для безопасной вставки в JSON-литерал.
# Правила: \ → \\, " → \", tab → \t, \r → пусто, перенос строки → \n.
#
# Реализация на sed (НЕ awk gsub) — у awk gsub-replacement семантика
# расходится между gawk (host) и busybox-awk (роутер): одна и та же
# строка-replacement даёт разное число backslash'ей в выходе. У sed
# правила replacement стандартизованы POSIX и одинаковы во всех
# реализациях (BSD/GNU/busybox). Без этого install_progress генерил
# невалидный JSON на каждой кавычке/backslash'е (BOARD_MODEL="...",
# KERNEL="..." из cheburnet_diag_system) → rpcd ubus-code 2 → UI висел.
# Тест busybox-awk-совместимости — tests/qemu/smoke.sh.
json_escape() {
    printf '%s' "$1" \
        | tr -d '\r' \
        | sed -e 's/\\/\\\\/g' \
              -e 's/"/\\"/g' \
              -e "s/$(printf '\t')/\\\\t/g" \
        | sed -e ':a;N;$!ba;s/\n/\\n/g'
}

# ─────────────────────────────────────────────────────────────────────────────
# Парсер AmneziaWG-конфига (.conf формат wg-quick / awg-quick)
# ─────────────────────────────────────────────────────────────────────────────

# awg_get_iface FIELD FILE
# Печатает первое значение `FIELD = ...` найденное в файле (включая [Interface]
# секцию — она обычно идёт первой). Если поле не найдено — печатает пустую
# строку без ошибки.
#
# КРИТИЧНО про разделение по '=': WireGuard-ключи — base64, длина 44 символа,
# ВСЕГДА оканчиваются padding'ом '=' (а PSK иногда даже '=='). Раньше тут было
# `awk -F' *= *'`, и регексп ' *= *' матчил padding-'=' тоже — base64-ключ
# обрезался по первому '=', UCI получал 43-символьный мусор, awg-tool отвергал
# ключ как "invalid key length", awg0 не поднимался. Чиним: split строго по
# ПЕРВОМУ '=' через sed `s/^[^=]*= *//` — всё, что после первого '=' и пробелов,
# уходит в значение целиком, со всем padding'ом.
#
# tr -d '\r' срезает висячий CR на CRLF-конфигах (юзер скопировал из Windows) —
# иначе значение уезжает в UCI с CR и awg-quick давится при чтении.
awg_get_iface() {
    awk "/^$1[[:space:]]*=/{print; exit}" "$2" \
        | sed 's/^[^=]*= *//; s/[[:space:]]*$//' \
        | tr -d '\r'
}

# awg_get_peer FIELD FILE
# Печатает первое значение `FIELD = ...` после маркера [Peer]. Если [Peer]-секции
# нет или поле в ней отсутствует — печатает пустую строку, не падает.
# См. комментарий в awg_get_iface про split по первому '=' и сохранение
# base64-padding'а.
awg_get_peer() {
    awk "BEGIN{f=0} /^\\[Peer\\]/{f=1; next} f && /^$1[[:space:]]*=/{print; exit}" "$2" \
        | sed 's/^[^=]*= *//; s/[[:space:]]*$//' \
        | tr -d '\r'
}

# awg_endpoint_host ENDPOINT
# Из строки вида "host:port" или "[ipv6]:port" печатает host-часть.
awg_endpoint_host() {
    printf '%s\n' "${1%:*}"
}

# awg_endpoint_port ENDPOINT
# Из строки "host:port" или "[ipv6]:port" печатает port-часть.
awg_endpoint_port() {
    printf '%s\n' "${1##*:}"
}

# awg_validate_conf FILE
# Проверяет, что .conf содержит минимальный набор полей, без которых
# 01-amneziawg.sh упадёт ПОСЛЕ скачивания и установки трёх apk-пакетов
# (~3 МБ, ~30 сек) с непонятным "ERROR: .conf parse failed". Цель —
# поймать обрезанный конфиг на entry-point'е (rpcd / setup.sh) и сразу
# показать пользователю, что именно не хватает.
#
# Печатает имя первого недостающего поля в stdout, return 1.
# При успехе молчит, return 0.
awg_validate_conf() {
    _conf="$1"
    [ -f "$_conf" ] || { printf '%s\n' "file not found: $_conf"; return 1; }
    grep -q '^\[Interface\]' "$_conf" || { printf '%s\n' '[Interface] section'; return 1; }
    [ -n "$(awg_get_iface PrivateKey "$_conf")" ] || { printf '%s\n' 'PrivateKey in [Interface]'; return 1; }
    grep -q '^\[Peer\]' "$_conf"      || { printf '%s\n' '[Peer] section'; return 1; }
    [ -n "$(awg_get_peer PublicKey "$_conf")" ]   || { printf '%s\n' 'PublicKey in [Peer]'; return 1; }
    [ -n "$(awg_get_peer Endpoint  "$_conf")" ]   || { printf '%s\n' 'Endpoint in [Peer]'; return 1; }
    unset _conf
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Выбор версии awg-openwrt-пакета
# ─────────────────────────────────────────────────────────────────────────────

# awg_pick_version PREFERRED ARCH
# Подбирает релиз awg-openwrt в порядке убывания надёжности:
#   1) v$PREFERRED ($DISTRIB_RELEASE) — kmod гарантированно собран под то же
#      ядро, что у юзера. Это ровно то совпадение, которое мы хотим.
#   2) latest-релиз awg-openwrt из GitHub API — если апстрим ушёл вперёд
#      раньше нас (новый OpenWrt вышел, у юзера именно он), latest всё равно
#      ближе по ядру, чем любая «зашитая на момент написания» константа.
# Печатает выбранную версию в stdout, return 0. Если ни один из путей не
# подошёл — return 1, ничего не печатает (вызывающий покажет понятную ошибку).
#
# Жёсткого хардкод-fallback'а нет сознательно: он быстро устаревает, а на
# свежем ядре всё равно не работает (modprobe отлогирует kernel-mismatch).
# Лучше честно отказать с указанием ссылки, чем пытаться поставить заведомо
# несовместимое.
#
# Парсинг tag_name из API — на grep+sed (не jsonfilter), чтобы функция
# работала и до шага 00 (на голом busybox), и в bats-тестах без extra-mock'ов.
# Поле "tag_name" в ответе GitHub releases уникально на верхнем уровне.
# wget-вызовы мокаются в тестах через PATH-shim.
awg_pick_version() {
    _preferred="$1"
    _arch="$2"

    if [ -n "$_preferred" ]; then
        _url="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${_preferred}/kmod-amneziawg_v${_preferred}_${_arch}.apk"
        if wget -q --spider --timeout=15 "$_url" 2>/dev/null; then
            printf '%s\n' "$_preferred"
            unset _preferred _arch _url
            return 0
        fi
    fi

    _api='https://api.github.com/repos/Slava-Shchipunov/awg-openwrt/releases/latest'
    _latest=$(wget -q -O - --timeout=15 "$_api" 2>/dev/null \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]*"' \
        | head -1 \
        | sed 's|.*"v\([^"]*\)"|\1|')

    # latest = preferred → уже пробовали выше, второй раз не дёргаем сеть.
    if [ -n "$_latest" ] && [ "$_latest" != "$_preferred" ]; then
        _url="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${_latest}/kmod-amneziawg_v${_latest}_${_arch}.apk"
        if wget -q --spider --timeout=15 "$_url" 2>/dev/null; then
            printf '%s\n' "$_latest"
            unset _preferred _arch _url _api _latest
            return 0
        fi
    fi

    unset _preferred _arch _url _api _latest
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Валидаторы пользовательского ввода (для rpcd-cheburnet)
# ─────────────────────────────────────────────────────────────────────────────

# cheburnet_valid_mode VAL  → 0 если "home" | "travel", иначе 1.
cheburnet_valid_mode() {
    case "$1" in
        home|travel) return 0 ;;
        *)           return 1 ;;
    esac
}

# cheburnet_valid_tier VAL  → 0 если допустимый Hagezi-тир, иначе 1.
# Список синхронизирован с https://github.com/hagezi/dns-blocklists.
cheburnet_valid_tier() {
    case "$1" in
        light|normal|pro|pro.plus|ultimate|tif|tif.medium|tif.mini|multi.pro|fake)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# cheburnet_valid_factory_confirm VAL  → 0 если строго "RESET", иначе 1.
# Защита от случайного срабатывания factory_reset.
cheburnet_valid_factory_confirm() {
    [ "$1" = "RESET" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Диагностика apk-fail (DPI / IPv6 / общие проблемы зеркала)
# ─────────────────────────────────────────────────────────────────────────────
#
# Кейс из реальных логов (юзер 1): `apk add ... sing-box ...` падает на
# «wget: Failed to send request: Operation not permitted» внутри apk, при
# том что apk update и установка других пакетов с того же зеркала
# прекрасно работают. Это узор «провайдер фильтрует конкретные имена
# на DPI» (sing-box / V2Ray / xray и т.п. — VPN-инструменты).
#
# Простая инструментальная проверка: сравнить ответ зеркала на два URL'а
# с одного хоста — один с «подозрительным» именем в пути, другой с
# нейтральным. Если первый блокируется до уровня HTTP, а второй
# возвращает 404 — провайдер режет по имени.
#
# Диагностика — два wget --spider запроса (~5-15 сек), без модификации
# системного состояния.

# cheburnet_apk_fail_advice [MARKER]
#
# Юзер вызвал `apk add MARKER` и оно упало. Эта функция:
#   1) делает два wget --spider запроса к OpenWrt-зеркалу: один с именем
#      пакета в URL, второй с нейтральным именем — оба к 404-страницам;
#   2) по их исходам различает три случая: DPI на имя файла, общая
#      недоступность зеркала, или временный mirror-lag;
#   3) печатает в stdout диагностику (попадает в install.log), в stderr —
#      human-readable «ЧТО ДЕЛАТЬ» с командами обхода.
#
# Раньше это были две функции с 4 return-кодами (0/2/3/99) — слой
# абстракции, который никто не использовал: все callsites просто хотели
# «упало → расскажи юзеру что делать». Объединено в одну.
#
# MARKER — имя пакета (по умолчанию sing-box) для подстановки в suspect-URL.
cheburnet_apk_fail_advice() {
    _marker="${1:-sing-box}"

    # Читаем DISTRIB_* в subshell — не утекают в окружение caller'а
    # (см. lib/cheburnet-preflight.sh::cheburnet_preflight_arch).
    # shellcheck disable=SC1091
    _release=$( . /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_RELEASE" )
    _arch=$(    . /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_ARCH"    )

    echo ""
    echo "─── ДИАГНОСТИКА (что блокируется: зеркало, IPv6, или имя пакета) ───"

    if [ -z "$_release" ] || [ -z "$_arch" ]; then
        echo "  ? Не могу определить arch/release для диагностики"
        echo "─── /ДИАГНОСТИКА ───"
        _verdict="unknown"
    else
        _base="https://downloads.openwrt.org/releases/${_release}/packages/${_arch}/packages"
        _suspect_url="${_base}/${_marker}-cheburnet-diag-noexist.apk"
        _control_url="${_base}/cheburnet-diag-noexist.apk"

        _suspect_out=$(wget --spider --timeout=10 "$_suspect_url" 2>&1 || true)
        _control_out=$(wget --spider --timeout=10 "$_control_url" 2>&1 || true)

        # busybox wget на 404 печатает «404» / «response: 404». На сетевом
        # отказе (refused / EPERM / TLS reject / DPI-RST) — печатает
        # «can't connect», «Failed to send request», «Operation not permitted»
        # без упоминания HTTP-статуса. По этому маркеру и различаем.
        if printf '%s' "$_suspect_out" | grep -qE '404|response: 4[0-9][0-9]'; then
            _suspect_kind=http
        else
            _suspect_kind=netfail
        fi
        if printf '%s' "$_control_out" | grep -qE '404|response: 4[0-9][0-9]'; then
            _control_kind=http
        else
            _control_kind=netfail
        fi

        echo "  control-URL ($_control_url):  $_control_kind"
        echo "  suspect-URL (...${_marker}...): $_suspect_kind"

        case "${_suspect_kind}/${_control_kind}" in
            http/http)
                echo "  ✅ ВЕРДИКТ: зеркало нормально отвечает на оба URL'а — DPI не виден."
                echo "  Похоже, у вас был временный сбой скачивания (mirror lag)."
                _verdict=mirror_ok
                ;;
            netfail/http)
                echo ""
                echo "  ⚠ ВЕРДИКТ: запросы с '${_marker}' в URL блокируются вашим провайдером."
                echo "    Control-URL без этого имени проходит, suspect-URL — нет."
                echo "    Это техника DPI на имя файла, известна у части провайдеров."
                _verdict=dpi_on_name
                ;;
            netfail/netfail)
                echo ""
                echo "  ✗ ВЕРДИКТ: зеркало downloads.openwrt.org вообще недоступно."
                echo "    Это общая сетевая проблема, не специфика '${_marker}'."
                _verdict=mirror_down
                ;;
            *)
                echo "  ? Неоднозначный результат."
                _verdict=unknown
                ;;
        esac
        echo "─── /ДИАГНОСТИКА ───"
    fi

    {
        echo ""
        echo "ЧТО ДЕЛАТЬ:"
        case "$_verdict" in
            mirror_ok)
                echo "  Диагностика показывает, что зеркало вам доступно."
                echo "  Это был, вероятно, временный сбой скачивания (mirror lag)."
                echo "  Подождите 1-2 минуты и запустите setup.sh снова."
                ;;
            dpi_on_name)
                echo "  Обход — установка через мобильный интернет с AmneziaVPN."
                echo "  Самый простой путь — одной командой:"
                echo ""
                echo "    /opt/cheburnet/scripts/install-via-tether.sh"
                echo ""
                echo "  Скрипт сам всё переключит. Перед запуском:"
                echo "    1. На телефоне установите и подключите AmneziaVPN"
                echo "       (https://amnezia.org)."
                echo "    2. Включите USB-tethering (Android: Настройки → Точка доступа"
                echo "       → USB-модем; iOS: Personal Hotspot, подключите USB)."
                echo "    3. Подключите телефон USB-кабелем к USB-порту роутера."
                echo ""
                echo "  Полная инструкция: docs/install-blocked.md"
                ;;
            mirror_down)
                echo "  Зеркало OpenWrt полностью недоступно. Варианты:"
                echo "    1. Подождите 1-2 минуты — возможен временный сбой зеркала."
                echo "    2. Проверьте интернет: wget -q --spider http://downloads.openwrt.org"
                echo "    3. Если у провайдера криво настроен IPv6, попробуйте отключить:"
                echo "         uci set network.wan.ipv6='0' && uci commit network"
                echo "         /etc/init.d/network reload"
                echo "    4. Если ничего не помогло — установка через мобильный:"
                echo "         /opt/cheburnet/scripts/install-via-tether.sh"
                echo "       (см. docs/install-blocked.md)"
                ;;
            *)
                echo "  Диагностика не дала однозначного результата."
                echo "  Универсальный обход — установка через мобильный:"
                echo "    /opt/cheburnet/scripts/install-via-tether.sh"
                echo "  Подробности: docs/install-blocked.md"
                ;;
        esac
    } >&2
}
