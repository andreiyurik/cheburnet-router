#!/bin/sh
# bootstrap.sh — тонкий установщик cheburnet (v2): feed → apk add → токен → URL мастера.
#
# Запуск на роутере (OpenWrt 25.12+, apk-based): одной командой по SSH или `sh bootstrap.sh`.
# Намеренно тонкий (~30 строк): вся хрупкая логика — в движке на ucode (см.
# docs/v2/architecture/bootstrap.md), здесь только подключить feed и поставить пакет.
# POSIX/busybox-ash, shellcheck-clean. Финальные FEED_URL/ключ фиксируются в фазе feed+CI.
set -eu

# Где лежит feed и публичный ключ для верификации подписи пакетов. Переопределяемы через env —
# для тестового feed в QEMU/CI. Реальные значения подставит фаза дистрибуции.
FEED_URL="${CHEBURNET_FEED_URL:-https://feed.cheburnet.example/packages}"
FEED_KEY_URL="${CHEBURNET_FEED_KEY_URL:-${FEED_URL%/}/cheburnet.pub}"
REPO_LIST="/etc/apk/repositories.d/cheburnet.list"
KEYS_DIR="/etc/apk/keys"
ETC="/etc/cheburnet"

log() { echo "→ $*"; }

# 1. Подключаем feed. apk сам подберёт пакет под arch и доустановит зависимости — отсюда
#    «универсальность» под подходящие роутеры (см. bootstrap.md).
log "подключаю feed $FEED_URL"
mkdir -p "$(dirname "$REPO_LIST")" "$KEYS_DIR"
echo "$FEED_URL" > "$REPO_LIST"
# Ключ нужен apk для проверки подписи. uclient-fetch штатен на OpenWrt; wget — fallback.
uclient-fetch -qO "$KEYS_DIR/cheburnet.pub" "$FEED_KEY_URL" 2>/dev/null \
    || wget -qO "$KEYS_DIR/cheburnet.pub" "$FEED_KEY_URL" \
    || { echo "✗ не удалось скачать ключ feed ($FEED_KEY_URL)"; exit 1; }

# 2. Ставим пакет. preflight-гейткипер внутри пакета честно откажет на негодном железе.
log "apk add cheburnet"
apk update
apk add cheburnet

# 3. Install-токен: доказывает «я владелец роутера (есть SSH)» для первичной установки из
#    веб-мастера. Мастер требует его в методе install (engine/ubus); движок удаляет токен по
#    завершении установки — повторно поставить можно только новым запуском bootstrap.
mkdir -p "$ETC"
umask 077
TOKEN="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || tr -dc 'a-f0-9' < /dev/urandom | head -c 32)"
printf '%s\n' "$TOKEN" > "$ETC/install-token"

# 4. Куда идти дальше. LAN-IP определяем динамически — не хардкодим подсеть (урок v1:
#    хардкод 192.168.1.1 ломается на нестандартных LAN).
LAN_IP="$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"
echo
log "готово. Откройте веб-мастер в браузере:"
echo "    http://$LAN_IP/cheburnet/"
log "install-токен (введите в мастере):"
echo "    $TOKEN"
