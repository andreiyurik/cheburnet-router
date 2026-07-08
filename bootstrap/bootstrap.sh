#!/bin/sh
# bootstrap.sh — тонкий установщик cheburnet (v2): kmod-amneziawg → пакет cheburnet → токен → URL.
#
# Запуск на роутере (OpenWrt 25.12+, apk-based), одной командой по SSH или `sh bootstrap.sh`.
# Намеренно тонкий: вся хрупкая логика — в движке на ucode (см. docs/v2/architecture/bootstrap.md),
# здесь только доставить два пакета и напечатать ссылку мастера. POSIX/busybox-ash, shellcheck-clean.
#
# Почему два источника пакетов, а не один feed:
#   - kmod-amneziawg — модуль ЯДРА, привязан к vermagic конкретной сборки ядра. Собирать его самим
#     под каждую OpenWrt-версию×target — неподъёмная матрица для соло-мейнтейнера. Его уже собирает
#     upstream awg-openwrt под каждый стоковый релиз; берём оттуда (их инсталлятор сам детектит
#     version/target/arch). Мы НЕ владеем этими данными — импортируем (принцип проекта).
#   - cheburnet — arch-независимый (ucode+shell+web, PKGARCH=all), поэтому один .apk на всех, лежит
#     в наших GitHub Releases и ПОДПИСАН: apk проверяет подпись против публичного ключа, который
#     ставится в /etc/apk/keys (kmod из awg-openwrt — unsigned, это ограничение upstream).
#     Остальные зависимости (dnsmasq-full, https-dns-proxy, nftables, …) apk тянет из штатного
#     официального feed OpenWrt.
set -eu

# --- Источники (env-override для CI/QEMU; в проде — дефолты) --------------------------------------
# Наш репозиторий: bootstrap и pinned-копия awg-инсталлятора берутся из одного origin (raw GH).
SRC_BASE="${CHEBURNET_SRC_BASE:-https://raw.githubusercontent.com/andreiyurik/cheburnet-router/master}"
# cheburnet-пакет — с GitHub Releases (latest/download отдаёт ассет последнего релиза по
# стабильному URL).
RELEASE_BASE="${CHEBURNET_RELEASE_BASE:-https://github.com/andreiyurik/cheburnet-router/releases/latest/download}"
PKG_FILE="${CHEBURNET_PKG:-cheburnet.apk}"
# Публичный ключ подписи пакета cheburnet: apk проверяет .apk против /etc/apk/keys.
# Лежит в репо рядом с bootstrap — тот же origin доверия, что и сам скрипт.
KEY_URL="${CHEBURNET_KEY_URL:-$SRC_BASE/bootstrap/cheburnet.pem}"
# Инсталлятор kmod-amneziawg. По умолчанию — НАША vendored-копия (pinned, ревьюится в нашем репо),
# а не master awg-openwrt: воспроизводимость и один origin доверия. Обновление копии — vendor/README.md.
AWG_INSTALL_URL="${CHEBURNET_AWG_INSTALL_URL:-$SRC_BASE/vendor/amneziawg-install.sh}"

ETC="/etc/cheburnet"

log()  { echo "→ $*"; }
die()  { echo "✗ $*" >&2; exit 1; }

# fetch URL DEST — uclient-fetch штатен на OpenWrt; wget — fallback. Пустой файл считаем провалом.
fetch() {
    uclient-fetch -qO "$2" "$1" 2>/dev/null || wget -qO "$2" "$1" || return 1
    [ -s "$2" ] || return 1
}

WORK="$(mktemp -d)" || die "не создать временную папку"
# Чистим за собой в любом исходе. trap на EXIT — единственный путь очистки (set -e может прервать).
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- 0. Среда: v2 требует apk (OpenWrt 25.12+) ---------------------------------------------------
command -v apk >/dev/null 2>&1 \
    || die "нужен OpenWrt 25.12+ (пакетный менеджер apk). На более старых — установщик v1."

# --- 1. Скачать ВСЁ до установки чего-либо: fail-closed, без половинчатой установки ---------------
# Если хоть один артефакт недоступен (нет Release, нет сети, битое зеркало) — умираем ДО того,
# как на роутере что-то изменилось. Урок ревью: kmod-до-проверки-пакета оставлял полуустановку.
log "скачиваю установочные файлы"
fetch "$AWG_INSTALL_URL" "$WORK/awg-install.sh" \
    || die "не скачать awg-инсталлятор ($AWG_INSTALL_URL) — проверьте доступ к сети/зеркалу"
fetch "$RELEASE_BASE/$PKG_FILE" "$WORK/cheburnet.apk" \
    || die "не скачать пакет ($RELEASE_BASE/$PKG_FILE)"
fetch "$KEY_URL" "$WORK/cheburnet.pem" \
    || die "не скачать ключ подписи ($KEY_URL)"

# --- 2. kmod-amneziawg + amneziawg-tools через awg-openwrt (packages-only) ------------------------
# -n: НЕ настраивать awg-интерфейс (его поднимет движок cheburnet из .conf юзера — иначе конфликт).
# -e: не спрашивать про русский языковой пакет. Итог: неинтерактивная установка только пакетов.
log "ставлю kmod-amneziawg (через awg-openwrt, подбор под ядро)"
# Их скрипт сам детектит version/target/arch и качает совпадающий по vermagic kmod с GitHub Release.
# ВАЖНО (поймано живым прогоном на GL-MT3000): upstream-скрипт ПОСЛЕ kmod+tools дополнительно
# ставит luci-proto-amneziawg (флага «без LuCI» у него нет) и делает exit 1, если этот ассет не
# скачался (нет под версию ИЛИ транзиентный сбой сети). Нам luci-proto НЕ нужен. Поэтому НЕ гейтим
# на коде выхода скрипта, а проверяем ФАКТ: стоят ли реально нужные нам kmod-amneziawg и
# amneziawg-tools. Так частичный успех upstream'а (наш случай) не рушит установку.
sh "$WORK/awg-install.sh" -n -e || true
awg_ok() { apk list --installed 2>/dev/null | grep -q "^$1-[0-9]"; }
if ! awg_ok kmod-amneziawg || ! awg_ok amneziawg-tools; then
    die "AmneziaWG (kmod + tools) не установились — нет сборки kmod под вашу OpenWrt/ядро или нет сети (см. лог awg-openwrt выше)"
fi

# --- 3. Пакет cheburnet: ключ подписи + локальная установка .apk ----------------------------------
log "ставлю пакет cheburnet"
mkdir -p /etc/apk/keys
cp "$WORK/cheburnet.pem" /etc/apk/keys/cheburnet.pem
chmod 644 /etc/apk/keys/cheburnet.pem

# apk update — чтобы штатный feed знал про зависимости (dnsmasq-full, https-dns-proxy, …).
apk update || die "apk update не прошёл — недоступно зеркало OpenWrt (см. docs/install-blocked.md)"
# Подпись .apk проверяется против /etc/apk/keys/cheburnet.pem — подмена пакета не пройдёт.
# Зависимости apk тянет из штатного feed; kmod-amneziawg уже стоит (шаг 2) → зависимость удовлетворена.
apk add "$WORK/cheburnet.apk" || die "apk add cheburnet не прошёл (зависимости?)"

# --- 4. Install-токен: доказывает «я владелец роутера (есть SSH)» для первичной установки ---------
# Мастер требует токен в методе install (engine/ubus); движок удаляет его по завершении установки —
# повторно поставить можно только новым запуском bootstrap.
mkdir -p "$ETC"
umask 077
TOKEN="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || tr -dc 'a-f0-9' < /dev/urandom | head -c 32)"
printf '%s\n' "$TOKEN" > "$ETC/install-token"

# --- 5. Куда идти дальше. LAN-IP определяем динамически — не хардкодим подсеть (урок v1) ----------
LAN_IP="$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"
# Нормализация: ipaddr бывает списком и/или в CIDR-форме ('192.168.1.1/24 …') — берём
# первый адрес и режем маску, иначе ссылка мастера получится битой.
# shellcheck disable=SC2086 # word-splitting намеренный: первый элемент списка
set -- $LAN_IP; LAN_IP="${1%%/*}"
echo
log "готово. Откройте веб-мастер в браузере:"
echo "    http://$LAN_IP/cheburnet/?token=$TOKEN"
log "если ссылка с токеном не открывается — откройте http://$LAN_IP/cheburnet/ и введите токен вручную:"
echo "    $TOKEN"
