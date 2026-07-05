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
#     в наших GitHub Releases (ставится --allow-untrusted: MVP без подписи, как и kmod из awg-openwrt;
#     доверие — HTTPS к тому же origin, что и bootstrap). Остальные зависимости (dnsmasq-full,
#     https-dns-proxy, nftables, …) apk тянет из штатного официального feed OpenWrt.
set -eu

# --- Источники (env-override для CI/QEMU; в проде — дефолты) --------------------------------------
# Наш репозиторий: bootstrap и pinned-копия awg-инсталлятора берутся из одного origin (raw GH).
SRC_BASE="${CHEBURNET_SRC_BASE:-https://raw.githubusercontent.com/yurik2718/cheburnet-router/master}"
# cheburnet-пакет — с GitHub Releases (latest/download отдаёт ассет последнего релиза по
# стабильному URL).
RELEASE_BASE="${CHEBURNET_RELEASE_BASE:-https://github.com/yurik2718/cheburnet-router/releases/latest/download}"
PKG_FILE="${CHEBURNET_PKG:-cheburnet.apk}"
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

# --- 1. kmod-amneziawg + amneziawg-tools через awg-openwrt (packages-only) ------------------------
# -n: НЕ настраивать awg-интерфейс (его поднимет движок cheburnet из .conf юзера — иначе конфликт).
# -e: не спрашивать про русский языковой пакет. Итог: неинтерактивная установка только пакетов.
log "ставлю kmod-amneziawg (через awg-openwrt, подбор под ядро)"
fetch "$AWG_INSTALL_URL" "$WORK/awg-install.sh" \
    || die "не скачать awg-инсталлятор ($AWG_INSTALL_URL) — проверьте доступ к сети/зеркалу"
# Их скрипт сам детектит version/target/arch и качает совпадающий по vermagic kmod с GitHub Release.
# Провал (нет сборки под вашу версию, нет сети) → ненулевой код → set -e прервёт: fail-closed, без
# половинчатой установки. preflight движка тоже перепроверит deps перед стартом мастера.
sh "$WORK/awg-install.sh" -n -e \
    || die "awg-openwrt не смог поставить kmod-amneziawg под вашу OpenWrt-версию (см. лог выше)"

# --- 2. Пакет cheburnet: локальная установка .apk (MVP — без подписи) -----------------------------
log "ставлю пакет cheburnet"
fetch "$RELEASE_BASE/$PKG_FILE" "$WORK/cheburnet.apk" \
    || die "не скачать пакет ($RELEASE_BASE/$PKG_FILE)"

# apk update — чтобы штатный feed знал про зависимости (dnsmasq-full, https-dns-proxy, …).
apk update || die "apk update не прошёл — недоступно зеркало OpenWrt (см. docs/install-blocked.md)"
# --allow-untrusted: пакет пока без подписи (MVP). Доверие — HTTPS к нашему GitHub Release (тот же
# origin, что и сам bootstrap); kmod из awg-openwrt тоже ставится unsigned — единый уровень доверия.
# Зависимости apk тянет из штатного feed; kmod-amneziawg уже стоит (шаг 1) → зависимость удовлетворена.
apk add --allow-untrusted "$WORK/cheburnet.apk" || die "apk add cheburnet не прошёл (зависимости?)"

# --- 3. Install-токен: доказывает «я владелец роутера (есть SSH)» для первичной установки ---------
# Мастер требует токен в методе install (engine/ubus); движок удаляет его по завершении установки —
# повторно поставить можно только новым запуском bootstrap.
mkdir -p "$ETC"
umask 077
TOKEN="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || tr -dc 'a-f0-9' < /dev/urandom | head -c 32)"
printf '%s\n' "$TOKEN" > "$ETC/install-token"

# --- 4. Куда идти дальше. LAN-IP определяем динамически — не хардкодим подсеть (урок v1) ----------
LAN_IP="$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"
echo
log "готово. Откройте веб-мастер в браузере:"
echo "    http://$LAN_IP/cheburnet/?token=$TOKEN"
log "если ссылка с токеном не открывается — откройте http://$LAN_IP/cheburnet/ и введите токен вручную:"
echo "    $TOKEN"
