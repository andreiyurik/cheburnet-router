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
