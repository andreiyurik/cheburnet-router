#!/bin/bash
# setup.sh — интерактивный мастер настройки cheburnet-router.
# Запускайте с вашего ноутбука/компьютера, не с роутера.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
AMNEZIA_REF_URL="https://storage.googleapis.com/amnezia/amnezia.org?m-path=premium&arf=EB5KDKXCJYQYP4MG&coupon=CHEBURNET15"

# Подключаем общий валидатор .conf (тот же, что использует web/rpcd-cheburnet).
# shellcheck source=lib/cheburnet-utils.sh disable=SC1091
. "$REPO_ROOT/lib/cheburnet-utils.sh"
BOLD='\033[1m'; G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'

ok()   { printf "  ${G}✓${N} %s\n" "$1"; }
info() { printf "  → %s\n" "$1"; }
warn() { printf "  ${Y}⚠${N}  %s\n" "$1"; }
die()  { printf "\n  ${R}✗ Ошибка: %s${N}\n\n" "$1" >&2; exit 1; }
hr()   { printf "${BOLD}%s${N}\n" "──────────────────────────────────────────────"; }
ask()  { printf "  %s: " "$1"; }
step() { printf "\n${B}${BOLD}[%s] %s${N}\n\n" "$1" "$2"; }
# Под `set -e` `read` на EOF возвращает 1 и скрипт молча умирает. Это тихая
# смерть под пайпом / автоматизацией / `< inputs.txt`. Используем `read -r X ||
# _eof_die` вместо чистого `read -r X`. Параллельно восстанавливаем stty echo —
# вдруг EOF поймали посреди ввода пароля при отключённом эхе.
_eof_die() {
    stty echo 2>/dev/null || true
    die "ввод оборван (EOF). Запустите скрипт интерактивно или подайте полный набор ответов на stdin."
}

# ══════════════════════════════════════════════════════════════════════
# ЭКРАН 1 — Приветствие и предварительные требования
# ══════════════════════════════════════════════════════════════════════
clear
hr
printf "${BOLD}  cheburnet-router — образовательный OpenWrt-стенд${N}\n"
hr
printf "\n"
printf "  Этот мастер настроит ваш роутер с:\n"
printf "    • AmneziaWG — VPN-туннель с обфускацией\n"
printf "    • Podkop + sing-box — split-routing (.ru напрямую, остальное через VPN)\n"
printf "    • adblock-lean + Hagezi Pro — блокировка рекламы на уровне DNS\n"
printf "    • Quad9 DoH — зашифрованный DNS\n"
printf "    • Three-layer kill switch — защита от утечек\n"
printf "\n"

hr
printf "\n"
printf "  ${BOLD}Перед началом убедитесь что у вас есть:${N}\n\n"
printf "  ✓ Роутер, прошитый на OpenWrt 25.12+\n"
printf "    (инструкция: README.md → Шаг 1 и Шаг 2)\n\n"
printf "  ✓ Файл .conf от AmneziaWG\n"
printf "    Если сервера нет — Amnezia Premium со скидкой 15%% (промокод CHEBURNET15):\n"
printf "    %s\n" "$AMNEZIA_REF_URL"
printf "    (поддерживает развитие проекта)\n\n"
printf "  ✓ Компьютер подключён к роутеру кабелем\n\n"
printf "  ✓ SSH работает: ssh root@192.168.1.1\n\n"
hr
printf "\n  Нажмите Enter чтобы начать, или Ctrl+C для выхода: "
read -r _ || _eof_die

# ══════════════════════════════════════════════════════════════════════
# ШАГ 1 — Адрес роутера
# ══════════════════════════════════════════════════════════════════════
step "1/5" "Адрес роутера"
printf "  Сразу после прошивки OpenWrt роутер доступен по адресу 192.168.1.1.\n"
printf "  Если вы его не меняли — просто нажмите Enter.\n\n"
ask "Адрес роутера [192.168.1.1]"
read -r _input || _eof_die
ROUTER_IP="${_input:-192.168.1.1}"
ROUTER="root@${ROUTER_IP}"

info "Проверяем подключение к $ROUTER_IP..."
# -n: не читать локальный stdin. Без него ssh слурпает heredoc/pipe и съедает
# ввод, предназначенный для следующего `read` в этом скрипте. Под TTY скрытно
# работает (терминал не отдаёт буфер вперёд), под `< inputs.txt` ломает всё.
if ! ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
         "$ROUTER" 'echo ok' >/dev/null 2>&1; then
    printf "\n"
    warn "Не удалось подключиться автоматически (без пароля)."
    printf "  Это нормально при первом запуске — введите пароль роутера.\n"
    printf "  По умолчанию пароль пустой — просто нажмите Enter.\n\n"
    # БЕЗ -n: ssh здесь интерактивно спросит пароль и читает его с terminal.
    if ! ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
             "$ROUTER" 'echo ok' >/dev/null 2>&1; then
        printf "\n"
        printf "  ${R}Не удалось подключиться.${N}\n\n"
        printf "  Что проверить:\n"
        printf "    • Роутер включён и подключён кабелем к вашему компьютеру\n"
        printf "    • Компьютер получил IP в подсети роутера (обычно 192.168.1.x)\n"
        printf "    • Попробуйте: ping %s\n" "$ROUTER_IP"
        printf "    • В OpenWrt SSH включён по умолчанию — если вы его выключали,\n"
        printf "      зайдите в веб-интерфейс http://%s → System → Administration\n" "$ROUTER_IP"
        die "Нет SSH-доступа к $ROUTER_IP"
    fi
fi
ok "Роутер $ROUTER_IP доступен"

if ! ssh -n -o ConnectTimeout=10 "$ROUTER" 'grep -q OpenWrt /etc/openwrt_release 2>/dev/null'; then
    printf "\n"
    printf "  На %s что-то есть, но это не OpenWrt.\n\n" "$ROUTER_IP"
    printf "  Возможные причины:\n"
    printf "    • Вы подключились не к тому роутеру — проверьте IP\n"
    printf "    • Роутер ещё не перепрошит с GL.iNet/Cudy-стока на OpenWrt\n"
    printf "  Что сделать:\n"
    printf "    • Прошейте OpenWrt 25.12+ по инструкции: README.md → Шаг 2\n"
    die "На $ROUTER_IP не OpenWrt"
fi
ok "OpenWrt подтверждён"

# === Бутстрап SSH-ключа ===
# Дальнейшая установка — rsync репо + ssh-запуск install.sh. Каждый раз вводить
# пароль мучительно: разово копируем публичный ключ, далее всё без пароля.
#
# ВАЖНО: запускаем ssh-copy-id ВСЕГДА (он идемпотентен — если ключ уже стоит,
# выходит без действий с "Number of key(s) added: 0"). Раньше тут была проверка
# `ssh -o BatchMode=yes 'true'` как «уже-работает-без-пароля?», но на свежем
# OpenWrt root-пароль ПУСТОЙ — dropbear пускает вообще без challenge, BatchMode
# проходит без ключа. Дальше setup/install.sh ставит пароль через `passwd root`
# → ключа нет → каждый последующий ssh требует пароля. Скрипт обещал «один раз
# ввели — дальше без пароля», а по факту получалось «каждый чих с паролем».
if [ ! -f "$HOME/.ssh/id_ed25519.pub" ] \
   && [ ! -f "$HOME/.ssh/id_rsa.pub" ] \
   && [ ! -f "$HOME/.ssh/id_ecdsa.pub" ]; then
    printf "\n"
    info "SSH-ключа на компьютере нет — создаю свежий ed25519 (без пароля)."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "cheburnet-router" >/dev/null \
        || die "Не удалось создать SSH-ключ. Установите OpenSSH (apt install openssh-client / brew install openssh) и повторите."
fi

printf "\n"
info "Кладу SSH-ключ на роутер. Если попросит пароль — введите (на свежем OpenWrt — просто Enter)."
printf "\n"
# -f: форсируем добавление, не доверяя проверке "уже-установлен". На свежем
# OpenWrt пустой пароль root делает dropbear лояльным к ЛЮБОМУ auth-методу —
# ssh-copy-id ошибочно решал, что ключ уже стоит, и пропускал реальный copy.
# `< /dev/null`: ssh-copy-id внутри вызывает ssh без -n, и тот съедает
# stdin вызывающей стороны (heredoc/pipe). Отвязка stdin защищает от этого
# под автоматизацией; под TTY безразлично — пароль идёт через /dev/tty.
ssh-copy-id -f -o StrictHostKeyChecking=accept-new "$ROUTER" </dev/null \
    || die "ssh-copy-id не смог скопировать ключ. Проверьте пароль и повторите."

ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$ROUTER" 'true' >/dev/null 2>&1 \
    || die "Ключ скопирован, но вход не работает. Проверьте: ssh $ROUTER 'cat /etc/dropbear/authorized_keys'"

ok "SSH-ключ на роутере — дальше всё пойдёт автоматически"

# ══════════════════════════════════════════════════════════════════════
# Пре-чек: LAN/WAN-конфликт подсетей
# ══════════════════════════════════════════════════════════════════════
# Типичный сценарий — каскад: главный роутер (Keenetic, Mi Router и т.п.)
# выдаёт нашему OpenWrt-роутеру WAN-IP 192.168.1.X через DHCP, а LAN
# OpenWrt по умолчанию тоже на 192.168.1.1. Ядро не может маршрутизировать,
# клиенты не выходят в инет. Если не починить ДО запуска install.sh —
# user введёт VPN-конфиг, пароль, Wi-Fi-настройки, дойдёт до preflight,
# получит фейл и потеряет все введённые данные.
#
# Здесь чиним заранее: detect → prompt → apply → wait reconnect. Если
# конфликта нет — блок проходится молча.
#
# Алгоритм детекта inline (не через ssh source, потому что net-detect.sh
# ещё не на роутере — rsync будет дальше). Идентичен net_detect_lan_conflict
# из lib/net-detect.sh.
info "Проверяю, не конфликтуют ли подсети LAN и WAN роутера..."
# heredoc БЕЗ кавычек у EOF — а тут наоборот, кавычки ставим, чтобы $ и
# подстановки не интерпретировались локально. Все переменные внутри
# вычисляются на роутере. Вывод: пусто (нет конфликта) или
# "WAN_IP LAN_IP SUGGEST_IP".
_conflict_info=$(ssh -n "$ROUTER" 'sh -s' <<'REMOTE'
_wan_ip=$(ubus call network.interface.wan status 2>/dev/null \
          | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
[ -n "$_wan_ip" ] || exit 0
_lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
_lan_ip=${_lan_ip%%/*}
[ -n "$_lan_ip" ] || exit 0
_wan_pfx=$(echo "$_wan_ip" | cut -d. -f1-3)
_lan_pfx=$(echo "$_lan_ip" | cut -d. -f1-3)
[ "$_wan_pfx" = "$_lan_pfx" ] || exit 0
for _try in 2 3 4 8 9 10 11; do
    if [ "192.168.${_try}" != "$_wan_pfx" ]; then
        echo "$_wan_ip $_lan_ip 192.168.${_try}.1"
        exit 0
    fi
done
REMOTE
)

if [ -n "$_conflict_info" ]; then
    # shellcheck disable=SC2086  # сознательный word-split для разбора 3 токенов
    set -- $_conflict_info
    _wan_ip="$1"; _lan_ip="$2"; _new_ip="$3"
    _shared_octet=$(echo "$_wan_ip" | cut -d. -f3)
    _new_octet=$(echo "$_new_ip" | cut -d. -f3)

    printf "\n"
    warn "Найден конфликт подсетей роутера:"
    printf "    • WAN роутера: %s   (получен от главного роутера)\n" "$_wan_ip"
    printf "    • LAN роутера: %s   (по умолчанию OpenWrt)\n" "$_lan_ip"
    printf "    • Оба в подсети 192.168.%s.x — в этой конфигурации\n" "$_shared_octet"
    printf "      роутер не сможет маршрутизировать трафик из LAN в инет.\n\n"
    printf "  Это нормально для каскада «главный роутер → OpenWrt-роутер».\n"
    printf "  Чиним заменой LAN-адреса OpenWrt-роутера.\n\n"
    printf "  ${BOLD}Что произойдёт:${N}\n"
    printf "    1. Поменяю LAN-IP роутера: %s → ${BOLD}%s${N}\n" "$_lan_ip" "$_new_ip"
    printf "    2. Роутер перезапустит сеть (~10 секунд) —\n"
    printf "       ssh-соединение временно прервётся, это нормально.\n"
    printf "    3. Вы отсоедините и подсоедините кабель к ноутбуку,\n"
    printf "       чтобы он получил новый IP в подсети 192.168.%s.x.\n" "$_new_octet"
    printf "    4. Скрипт продолжит установку по новому адресу.\n\n"
    printf "  Продолжить? [Enter = да, Ctrl+C = отмена]: "
    read -r _ || _eof_die

    info "Меняю LAN-IP роутера на $_new_ip..."
    # Apply через ssh. Тот же setsid-приём, что в net_apply_new_lan_ip
    # (на этом этапе lib/net-detect.sh ещё не на роутере, делаем inline).
    # &&-цепочка → setsid: ssh-команда возвращается до того, как network
    # restart порвёт соединение, поэтому потери rc не страшно.
    ssh -n "$ROUTER" "
        uci set network.lan.ipaddr=$_new_ip
        uci commit network
        setsid sh -c 'sleep 3; /etc/init.d/network restart' \
            </dev/null >/dev/null 2>&1 &
    " || warn "ssh вернул не-ноль — возможно соединение уже оборвано рестартом сети, это ОК"

    ROUTER_IP="$_new_ip"
    ROUTER="root@${ROUTER_IP}"

    printf "\n"
    printf "  ${BOLD}Сейчас сделайте на ноутбуке (один из вариантов):${N}\n"
    printf "    • Кабель: отсоедините от ноутбука и подсоедините снова\n"
    printf "    • Wi-Fi:  отключитесь от сети роутера и подключитесь снова\n"
    printf "    (NetworkManager / Windows / macOS получат новый IP\n"
    printf "    в подсети 192.168.%s.x автоматически после переподключения)\n\n" "$_new_octet"
    printf "  Нажмите Enter когда переподключились: "
    read -r _ || _eof_die

    # Retry-loop. 30 × 2 сек = 60 сек на восстановление связи.
    # Покрывает медленный NetworkManager renew (типично 5-15 сек),
    # Windows-style ленивый DHCP (до 30 сек), повторное согласование Wi-Fi.
    info "Жду доступности роутера на новом адресе $ROUTER_IP..."
    _ok=0
    _i=0
    while [ "$_i" -lt 30 ]; do
        if ssh -n -o ConnectTimeout=3 -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new \
                "$ROUTER" 'true' 2>/dev/null; then
            _ok=1; break
        fi
        sleep 2
        _i=$((_i + 1))
    done

    if [ "$_ok" -ne 1 ]; then
        printf "\n"
        printf "  ${R}Не удалось подключиться к роутеру на новом адресе.${N}\n\n"
        printf "  Что проверить:\n"
        printf "    • Кабель воткнут (или Wi-Fi подключён) — линк горит на роутере?\n"
        printf "    • Ноутбук получил IP в подсети 192.168.%s.x:\n" "$_new_octet"
        printf "        Linux:   ${BOLD}ip addr | grep inet${N}\n"
        printf "        macOS:   ${BOLD}ifconfig | grep inet${N}\n"
        printf "        Windows: ${BOLD}ipconfig${N}\n"
        printf "    • Если IP старый (192.168.%s.x) — release/renew DHCP вручную:\n" "$_shared_octet"
        printf "        Linux:   ${BOLD}sudo nmcli con down <name> && sudo nmcli con up <name>${N}\n"
        printf "        macOS:   System Settings → Network → ваш интерфейс → Renew DHCP Lease\n"
        printf "        Windows: ${BOLD}ipconfig /release && ipconfig /renew${N}\n"
        printf "    • Когда подключитесь — запустите setup.sh снова,\n"
        printf "      ответьте ${BOLD}%s${N} на «Адрес роутера».\n" "$_new_ip"
        die "Роутер недоступен на $_new_ip"
    fi

    ok "Роутер отвечает по новому адресу $ROUTER_IP — конфликт устранён"
    unset _conflict_info _wan_ip _lan_ip _new_ip _shared_octet _new_octet _ok _i
fi
unset _conflict_info

# ══════════════════════════════════════════════════════════════════════
# ШАГ 2 — VPN-конфиг
# ══════════════════════════════════════════════════════════════════════
step "2/5" "Файл AmneziaWG-конфигурации (.conf)"
printf "  AmneziaWG-конфиг — это небольшой файл с параметрами подключения\n"
printf "  к вашему VPN-серверу. Без него стенд не поднимется.\n\n"
printf "  ${BOLD}Где взять (рекомендуем):${N}\n"
printf "    Amnezia Premium со скидкой 15%% (промокод CHEBURNET15) → 5 минут до конфига:\n"
printf "    ${B}%s${N}\n" "$AMNEZIA_REF_URL"
printf "    (поддерживает развитие проекта)\n\n"
printf "    В приложении Amnezia: Настройки → Сервер → Поделиться →\n"
printf "    Экспорт конфигурации → скачайте файл .conf\n\n"
printf "  ${BOLD}Альтернатива — свой VPS:${N}\n"
printf "    Установите AmneziaWG через приложение Amnezia на свой VPS,\n"
printf "    потом так же экспортируйте .conf\n\n"
ask "Путь к файлу .conf (например: ~/Downloads/amnezia.conf)"
read -r _input || _eof_die
CONF_PATH="${_input/#\~/$HOME}"
if [ -z "$CONF_PATH" ]; then
    die "Путь к файлу не может быть пустым — повторите запуск мастера"
fi
if [ ! -f "$CONF_PATH" ]; then
    printf "\n"
    printf "  Что проверить:\n"
    printf "    • Скопируйте точный путь из файлового менеджера\n"
    printf "    • Используйте ~/ для домашней папки или полный путь\n"
    printf "    • На macOS — перетащите файл в окно терминала, путь подставится\n"
    die "Файл не найден: $CONF_PATH"
fi
if ! AWG_ERR=$(awg_validate_conf "$CONF_PATH"); then
    printf "\n"
    printf "  В файле отсутствует: ${BOLD}%s${N}\n\n" "$AWG_ERR"
    printf "  Скорее всего вы экспортировали публичную или обрезанную часть\n"
    printf "  вместо полной конфигурации.\n\n"
    printf "  Откуда берётся правильный конфиг:\n"
    printf "    • Приложение Amnezia VPN → Настройки → Сервер → Поделиться →\n"
    printf "      Экспорт конфигурации → файл .conf\n"
    printf "    • Минимальный набор полей: [Interface]/PrivateKey, [Peer]/PublicKey/Endpoint\n"
    die "Неполный AmneziaWG-конфиг"
fi
ok "Конфиг найден и выглядит правильно"

# ══════════════════════════════════════════════════════════════════════
# ШАГ 3 — Пароль администратора роутера
# ══════════════════════════════════════════════════════════════════════
step "3/5" "Пароль администратора роутера (root)"
printf "  Сейчас на свежем OpenWrt пароль root пуст — это значит, что любой\n"
printf "  в LAN может зайти в LuCI или SSH и стать админом.\n"
printf "  Придумайте надёжный пароль — он понадобится для входа в веб-управление\n"
printf "  и (опционально) восстановительного SSH-доступа.\n\n"

while :; do
    printf "  Пароль root (минимум 8 символов): "
    stty -echo 2>/dev/null || true
    read -r ROOT_PASS || _eof_die
    stty echo 2>/dev/null || true
    printf "\n"
    [ "${#ROOT_PASS}" -ge 8 ] || { warn "Слишком короткий — минимум 8 символов."; continue; }

    printf "  Повторите пароль: "
    stty -echo 2>/dev/null || true
    read -r ROOT_PASS2 || _eof_die
    stty echo 2>/dev/null || true
    printf "\n"
    [ "$ROOT_PASS" = "$ROOT_PASS2" ] || { warn "Не совпадает, попробуйте ещё раз."; continue; }
    unset ROOT_PASS2
    break
done
ok "Пароль root принят"

# ══════════════════════════════════════════════════════════════════════
# ШАГ 4 — Wi-Fi
# ══════════════════════════════════════════════════════════════════════
step "4/5" "Настройка Wi-Fi"
printf "  Придумайте имя и пароль для домашней Wi-Fi сети.\n"
printf "  Все устройства подключённые к этой сети получат настройки\n"
printf "  автоматически — ничего не нужно настраивать на каждом телефоне/ноутбуке.\n\n"
ask "Название сети (SSID)"
read -r WIFI_SSID || _eof_die
[ -n "$WIFI_SSID" ]      || die "Название сети не может быть пустым"
[ ${#WIFI_SSID} -le 32 ] || die "Название не может быть длиннее 32 символов"

# Wi-Fi пароль — single entry. Сознательно НЕ дублируем как root: опечатка
# здесь не критична (после установки пароль меняется в одно действие через
# /cheburnet/ или ssh с ключом), а лишний ввод — это лишнее трение. macOS,
# Windows, iOS, админки роутеров — все спрашивают Wi-Fi пароль один раз.
printf "  Пароль Wi-Fi (минимум 8 символов): "
stty -echo 2>/dev/null || true
read -r WIFI_KEY || _eof_die
stty echo 2>/dev/null || true
printf "\n"
[ ${#WIFI_KEY} -ge 8 ] || die "Пароль должен быть не короче 8 символов"

ok "Wi-Fi: SSID='$WIFI_SSID'"

# ══════════════════════════════════════════════════════════════════════
# ШАГ 5 — Подтверждение и установка
# ══════════════════════════════════════════════════════════════════════
step "5/5" "Подтверждение"

hr
printf "${BOLD}  Итог — что будет установлено:${N}\n"
hr
printf "\n"
printf "  Роутер:    %s\n" "$ROUTER_IP"
printf "  VPN-файл:  %s\n" "$(basename "$CONF_PATH")"
printf "  Wi-Fi:     %s (WPA2/WPA3-mixed)\n\n" "$WIFI_SSID"
printf "  Компоненты:\n"
printf "    ✓ AmneziaWG — VPN-туннель с обфускацией\n"
printf "    ✓ Podkop + sing-box — .ru/.su/.рф напрямую, остальное через VPN\n"
printf "    ✓ Hagezi Pro — блокировка 200к+ рекламных доменов\n"
printf "    ✓ Quad9 DoH — зашифрованный DNS\n"
printf "    ✓ Kill switch — при падении VPN трафик блокируется\n"
printf "    ✓ Watchdog — авто-перезапуск VPN при зависании\n"
printf "\n"
hr
printf "\n  Продолжить? [Enter = да, Ctrl+C = отмена]: "
read -r _ || _eof_die

# ── Сохраняем конфиги ──────────────────────────────────────────────────
printf "\n"

# Heredoc без quoted-EOF интерполировал бы $ ` \ внутри WIFI_KEY — типичный
# Wi-Fi пароль вроде `S3$nake!` ехал бы на роутер уже изуродованным.
# POSIX single-quote escape: ' → '\''. Файл потом source'ится install.sh.
shq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
umask 077
{
    printf 'WIFI_SSID=%s\n' "$(shq "$WIFI_SSID")"
    printf 'WIFI_KEY=%s\n'  "$(shq "$WIFI_KEY")"
} > "$REPO_ROOT/configs/wireless-actual.txt"
umask 022
ok "Wi-Fi конфиг сохранён"

cp "$CONF_PATH" "$REPO_ROOT/configs/awg0.conf"
chmod 600 "$REPO_ROOT/configs/awg0.conf"
ok "VPN конфиг сохранён"

# ── Развёртывание на роутере ───────────────────────────────────────────
# Раньше тут вызывался setup/full-deploy.sh, который делал десятки
# ssh-команд (по команде на каждый scp + по команде на каждый шаг).
# Теперь оркестратор один — setup/install.sh — и живёт он на роутере.
# Алгоритм: один rsync/scp репо в /opt/cheburnet/, один ssh-вызов install.sh.
printf "\n  ${BOLD}Запускаем установку. Прогресс — на экране, длительность зависит от канала.${N}\n\n"

# Замер времени от старта rsync до конца setup/install.sh — то, что юзер
# реально «ждёт». Хардкодное «~12 минут» врало в обе стороны: на быстром
# канале реальная длительность 3–4 минуты, на медленном — все 15.
INSTALL_START_TS=$(date +%s)

INSTALL_DIR="/opt/cheburnet"
info "Копирую репозиторий на роутер в $INSTALL_DIR"
ssh -n "$ROUTER" "mkdir -p '$INSTALL_DIR' /etc/amnezia/amneziawg /tmp/cheburnet"

# Если rsync/tar/scp оборвётся посреди транзакции (сеть моргнула, Ctrl-C,
# kill из-за timeout) — /opt/cheburnet останется в half-state. Следующий
# install.sh поверх частичных файлов даёт cryptic ошибки. Trap снимает
# мусор на ошибке; снимаем сам trap после deployment чтобы фейлы install.sh
# не стирали install.log — он нужен для пост-мортема.
# wireless-actual.txt (Wi-Fi пароль в plaintext) убираем локально на любом выходе.
_cleanup_local() { rm -f "$REPO_ROOT/configs/wireless-actual.txt"; }
trap '_cleanup_local; ssh -n -o ConnectTimeout=5 "$ROUTER" "rm -rf $INSTALL_DIR" 2>/dev/null || true' INT TERM ERR

# rsync только если он есть С ОБЕИХ СТОРОН. Раньше тут была проверка только
# на ноуте — но rsync через ssh нуждается в rsync и на удалённой стороне.
# На дефолтном busybox-OpenWrt rsync нет, ветка падала с «connection unexpectedly closed».
# tar|ssh работает везде, скорость сопоставимая (gz + одна ssh-сессия).
# Исключаем .git/, tests/, docs/ — они не нужны на роутере и съедают место.
if command -v rsync >/dev/null 2>&1 \
   && ssh -n "$ROUTER" 'command -v rsync >/dev/null 2>&1'; then
    rsync -a --delete \
        --exclude='.git' --exclude='tests' --exclude='docs' \
        --exclude='backup' --exclude='assets' --exclude='*.md' \
        "$REPO_ROOT/" "$ROUTER:$INSTALL_DIR/"
else
    tar -C "$REPO_ROOT" -czf - \
        --exclude='.git' --exclude='tests' --exclude='docs' \
        --exclude='backup' --exclude='assets' --exclude='*.md' \
        . | ssh "$ROUTER" "tar -C '$INSTALL_DIR' -xzf -"
fi

# AWG-конфиг кладётся в каноническое место (где его ждёт 01-amneziawg.sh).
# Через `ssh ... cat`, не scp: OpenSSH ≥9.0 по умолчанию делает scp поверх
# sftp-протокола, а на busybox-OpenWrt нет /usr/libexec/sftp-server →
# падало с «sftp-server: not found». ssh+cat работает на любом sshd.
ssh "$ROUTER" 'umask 077 && cat > /etc/amnezia/amneziawg/awg0.conf' \
    < "$REPO_ROOT/configs/awg0.conf"

# Root-пароль передаём через короткоживущий файл (chmod 600), как и веб-мастер.
# Не светим в args/env — иначе виден в `ps`/`history`. printf | ssh даёт пароль
# на stdin без интерполяции на стороне сервера.
printf '%s' "$ROOT_PASS" | ssh "$ROUTER" \
    'umask 077 && cat > /tmp/cheburnet/root_pass && chmod 600 /tmp/cheburnet/root_pass'
unset ROOT_PASS

trap - INT TERM ERR
ok "Файлы скопированы — запускаю установку"
printf "\n"
ssh -t "$ROUTER" "$INSTALL_DIR/setup/install.sh"

# Plaintext Wi-Fi пароль на ноуте больше не нужен — на роутер он уехал, дальше держать незачем.
_cleanup_local

# ══════════════════════════════════════════════════════════════════════
# Финал
# ══════════════════════════════════════════════════════════════════════
INSTALL_END_TS=$(date +%s)
INSTALL_ELAPSED=$((INSTALL_END_TS - INSTALL_START_TS))
if [ "$INSTALL_ELAPSED" -ge 60 ]; then
    INSTALL_ELAPSED_STR="$((INSTALL_ELAPSED / 60))м $((INSTALL_ELAPSED % 60))с"
else
    INSTALL_ELAPSED_STR="${INSTALL_ELAPSED}с"
fi

printf "\n"
hr
printf "${G}${BOLD}  ✓ Роутер настроен! Заняло: %s${N}\n" "$INSTALL_ELAPSED_STR"
hr
printf "\n"
printf "${BOLD}Что делать дальше:${N}\n\n"
printf "  1. Подключитесь к Wi-Fi: ${BOLD}%s${N}\n" "$WIFI_SSID"
printf "  2. Откройте ${BOLD}yandex.ru/internet${N}\n"
printf "     Российский сервис — должен работать напрямую\n\n"
printf "  3. Откройте ${BOLD}speedtest.net${N}\n"
printf "     Откроется через VPN-туннель\n\n"
hr
printf "\n"
printf "${BOLD}Управление через SSH:${N}\n\n"
printf "  Подключиться к роутеру:  ${BOLD}ssh root@%s${N}\n\n" "$ROUTER_IP"
printf "  vpn-mode status    — текущий режим\n"
printf "  vpn-mode home      — .ru напрямую + остальное через VPN\n"
printf "  vpn-mode travel    — весь трафик через VPN\n"
printf "  vpn-mode status    — статус VPN-туннеля и режима\n"
printf "\n"
hr
printf "\n"
