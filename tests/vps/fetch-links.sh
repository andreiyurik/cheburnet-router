#!/usr/bin/env bash
# tests/vps/fetch-links.sh — забрать клиентский конфиг AmneziaWG поднятого стенда в tests/vps/awg-client.conf.
#
#     bash tests/vps/fetch-links.sh root@<ip-вашего-vps> [путь-к-ssh-ключу]
#
# Конфиг несёт приватный ключ клиента и поэтому НЕ коммитится (.gitignore). Отдельный скрипт, а не
# «скопируйте руками»: конфиг нужен и `make qemu-live-install`, и tests/router/, а копипаста из
# терминала регулярно приезжает обрезанной.

set -e -u -o pipefail

HOST="${1:-}"
KEY="${2:-}"
AWG_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/awg-client.conf"

[ -n "$HOST" ] || { echo "использование: $0 root@<vps> [ssh-key]"; exit 1; }

SSH_ARGS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[ -n "$KEY" ] && SSH_ARGS+=(-i "$KEY" -o IdentitiesOnly=yes)

echo "→ Забираю клиентский конфиг AmneziaWG с $HOST"
# Права 600 ДО записи ключа: приватный ключ не лежит ни мгновения с umask-правами.
: > "$AWG_LOCAL"
chmod 600 "$AWG_LOCAL"
if ! ssh "${SSH_ARGS[@]}" "$HOST" 'cat /root/cheburnet-lab/awg/client.conf' > "$AWG_LOCAL" 2>/dev/null \
   || ! grep -q '^\[Interface\]' "$AWG_LOCAL"; then
    rm -f "$AWG_LOCAL"
    echo "✗ не прочитать /root/cheburnet-lab/awg/client.conf — стенд поднят? (provision-lab.sh)"
    exit 1
fi
echo "  ✓ $AWG_LOCAL (режим 600, не коммитится)"

echo ""
echo "Дальше: make qemu-live-install или tests/router/RUNBOOK.md (живой роутер)"
