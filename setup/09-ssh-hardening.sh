#!/bin/sh
# 09-ssh-hardening.sh — усилить SSH (dropbear):
# - Block-SSH-from-WAN всегда (минимальная защита от внешнего SSH-bruteforce)
# - PasswordAuth=off в dropbear — только если есть ключ в authorized_keys
#
# Поведение зависит от env-переменной CHEBURNET_KEY_REQUIRED:
#   "1" (по умолчанию, standalone-запуск) — требуем ключ, иначе exit 1.
#                                            Защита от блокировки роутера.
#   "0" (вызов из web/run-install.sh)     — не требуем ключ. Block-SSH-from-WAN
#                                            ставится безусловно, password-auth
#                                            выключается только при наличии
#                                            ключа (recovery-доступ через пароль
#                                            сохраняется при необходимости).
set -e

KEY_REQUIRED="${CHEBURNET_KEY_REQUIRED:-1}"

echo "== 09. SSH hardening =="

# === Подключаем хелпер ===
FW4_LIB="${CHEBURNET_FW4_LIB:-/opt/cheburnet/lib/cheburnet-fw4.sh}"
[ -f "$FW4_LIB" ] || FW4_LIB="$(dirname "$0")/../lib/cheburnet-fw4.sh"
# shellcheck source=../lib/cheburnet-fw4.sh disable=SC1090,SC1091
. "$FW4_LIB"

AUTH_KEYS=/etc/dropbear/authorized_keys

# === 0. Safety check ===
if [ "$KEY_REQUIRED" = "1" ] && [ ! -s "$AUTH_KEYS" ]; then
    echo "ERROR: $AUTH_KEYS пуст или отсутствует." >&2
    echo "Добавьте ваш публичный ключ ПЕРЕД запуском этого скрипта:" >&2
    echo "  echo 'ssh-ed25519 ...' >> $AUTH_KEYS" >&2
    exit 1
fi

if [ -s "$AUTH_KEYS" ]; then
    echo "→ найдено ключей в authorized_keys: $(wc -l < "$AUTH_KEYS")"
fi

# === 1. fw4 rule: Block-SSH-from-WAN — БЕЗУСЛОВНО ===
# Пишем в UCI для персистентности (после reboot fw4 регенерирует ruleset
# из UCI), и применяем в живой nft напрямую через хелпер — без полного
# firewall reload (который на слабом железе занимает 1-3 минуты).
# Cleanup-by-name перед add: если правило уже есть, но повреждено руками
# (без target/proto) — починим, не оставим как есть.
echo "→ Block-SSH-from-WAN (REJECT tcp/22 from wan zone)"
cheburnet_uci_delete_rules_by_name "Block-SSH-from-WAN"

uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Block-SSH-from-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].target='REJECT'
uci commit firewall

cheburnet_fw4_apply_rule input_wan \
    "Block-SSH-from-WAN" \
    "tcp dport 22 reject"

# === 2. PasswordAuth=off — только при наличии ключа ===
if [ -s "$AUTH_KEYS" ]; then
    echo "→ выключаем PasswordAuth + RootPasswordAuth в dropbear"
    uci set dropbear.main.PasswordAuth='off'
    uci set dropbear.main.RootPasswordAuth='off'
    uci commit dropbear
    /etc/init.d/dropbear restart >/dev/null 2>&1
    HARDENING_LEVEL="полный (key-only + WAN closed)"
else
    echo "ℹ password-auth оставлен включённым: authorized_keys пуст,"
    echo "  иначе вы потеряли бы recovery-доступ через пароль root."
    echo "  Добавьте свой ssh-key в /etc/dropbear/authorized_keys и запустите"
    echo "  setup/09-ssh-hardening.sh для полного hardening."
    HARDENING_LEVEL="минимальный (WAN closed, password ещё работает с LAN)"
fi

# === 3. Проверка ===
echo "→ проверка"
uci show dropbear | grep -E 'PasswordAuth|Port' || true
nft list chain inet fw4 input_wan 2>/dev/null | grep -i "block-ssh" | head || true

echo "✓ SSH hardening $HARDENING_LEVEL"

# Напоминание про SSH-key — только в standalone-режиме (когда пользователь
# запускает 09 руками и его текущая SSH-сессия может оказаться разорвана).
if [ "$KEY_REQUIRED" = "1" ]; then
    echo
    echo "ВАЖНО: проверьте что вы всё ещё можете зайти по ключу В ДРУГОЙ ССЕССИИ"
    echo "перед тем как закрыть текущую, чтобы не остаться без доступа:"
    echo "  ssh -i ~/.ssh/your-key -o BatchMode=yes root@192.168.1.1 exit"
fi
