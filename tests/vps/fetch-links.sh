#!/usr/bin/env bash
# tests/vps/fetch-links.sh — забрать ссылки поднятого стенда с VPS в tests/vps/links.env.
#
#     bash tests/vps/fetch-links.sh root@147.45.172.86 [путь-к-ssh-ключу]
#
# links.env содержит credentials сервера и поэтому НЕ коммитится (.gitignore). Отдельный скрипт,
# а не «скопируйте руками», по одной причине: ссылки нужны и `make qemu-live-vps`, и панели, и
# копипаста из терминала регулярно приезжает с переносом строки посередине.

set -e -u -o pipefail

HOST="${1:-}"
KEY="${2:-}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/links.env"

[ -n "$HOST" ] || { echo "использование: $0 root@<vps> [ssh-key]"; exit 1; }

SSH_ARGS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[ -n "$KEY" ] && SSH_ARGS+=(-i "$KEY" -o IdentitiesOnly=yes)

echo "→ Забираю ссылки с $HOST"
raw="$(ssh "${SSH_ARGS[@]}" "$HOST" 'cat /root/cheburnet-lab/links.txt' 2>/dev/null)" \
    || { echo "✗ не прочитать /root/cheburnet-lab/links.txt — стенд поднят? (provision-lab.sh)"; exit 1; }

# Берём только строки KEY=VALUE и ОБЯЗАТЕЛЬНО берём значение в одинарные кавычки: в ссылках есть
# '&' и '#', и без кавычек `. links.env` разваливается на фоновые команды и комментарии
# («command not found» посреди ссылки). Значения — uuid/hex/base64 без одинарных кавычек внутри,
# поэтому такого квотирования достаточно.
printf '%s\n' "$raw" \
    | grep -E '^(VLESS_REALITY|HYSTERIA2|HYSTERIA2_PORT_HOPPING)=' \
    | sed "s/^\([A-Z0-9_]*\)=['\"]*\(.*\)['\"]*$/\1='\2'/" > "$OUT"
chmod 600 "$OUT"

n="$(wc -l < "$OUT")"
[ "$n" -ge 2 ] || { echo "✗ в links.txt нашлось всего $n ссылок — стенд поднялся не полностью"; exit 1; }
echo "  ✓ $n ссылок → $OUT (режим 600, не коммитится)"
echo ""
echo "Дальше: make qemu-live-vps"
