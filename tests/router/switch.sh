#!/bin/bash
# tests/router/switch.sh — ШАГ 4: уход роутера с legacy Full-тира (Reality/Hysteria2, ADR 0010) на AWG,
# а на AWG — замена сервера тем же конфигом со стенда.
#
#     R_HOST=192.168.1.1 bash tests/router/switch.sh
#
# Зовёт ТЕ ЖЕ методы, что кнопки панели (switch_to_awg / replace_awg_conf): внутри снапшот →
# применить → рукопожатие → commit или АВТООТКАТ, поэтому неудачная смена обязана вернуть прежний
# рабочий туннель — это и проверяется прогоном.

set -e -u -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PROTO="awg"
AWG_CONF_FILE="$R_DIR/../vps/awg-client.conf"

[ -s "$AWG_CONF_FILE" ] || { echo "✗ нет $AWG_CONF_FILE — поднимите стенд (tests/vps/)"; exit 1; }
METHOD="switch_to_awg"; FIELD="awg_conf"; VALUE="$(cat "$AWG_CONF_FILE")"

r_init "switch-$PROTO"

before="$(r_ssh 'ubus call cheburnet status 2>/dev/null' || true)"
[ -n "$before" ] || r_die "ubus cheburnet не отвечает"
prev="$(printf '%s' "$before" | sed -n 's/.*"protocol": *"\([a-z0-9]*\)".*/\1/p' | head -1)"
printf '  сейчас активен: %s\n' "${prev:-?}"
r_record "SWITCH from=${prev:-?} to=$PROTO"

# Если целевой протокол УЖЕ активен — это не переключение, а замена сервера, и у движка для неё
# отдельный метод (switch_to_* честно отказывает: «меняйте сервер через замену конфига»).
want="$PROTO"
if [ "$prev" = "$want" ]; then
    METHOD="replace_${want}_conf"
    printf '  протокол уже активен → замена сервера (%s)\n' "$METHOD"
fi

r_confirm "Переключение туннеля на «$PROTO». При неудаче ожидается автооткат на «$prev»."

r_msg "Переключаю: $METHOD"
TMP_ARGS="$(mktemp)"
FIELD="$FIELD" VALUE="$VALUE" python3 -c '
import json, os
print(json.dumps({os.environ["FIELD"]: os.environ["VALUE"]}, ensure_ascii=False))' > "$TMP_ARGS"
r_scp "$TMP_ARGS" /tmp/cheburnet-switch-args.json
rm -f "$TMP_ARGS"

out="$(r_ssh "ubus call cheburnet $METHOD \"\$(cat /tmp/cheburnet-switch-args.json)\" 2>&1; rm -f /tmp/cheburnet-switch-args.json" || true)"
printf '%s' "$out" | grep -q 'started' || { printf '%s\n' "$out" | sed 's/^/    /'; r_die "$METHOD не запустился"; }

r_msg "Жду исход (снапшот → применить → проба → commit либо автооткат)"
r_wait_op 450 || true
r_record "OP result=$R_OP_RESULT reason=${R_OP_REASON:-} step=${R_OP_STEP:-}"
printf '    исход: %s%s\n' "$R_OP_RESULT" "$([ -n "$R_OP_REASON" ] && printf ' (%s)' "$R_OP_REASON")"

after="$(r_ssh 'ubus call cheburnet status 2>/dev/null' || true)"
now="$(printf '%s' "$after" | sed -n 's/.*"protocol": *"\([a-z0-9]*\)".*/\1/p' | head -1)"
health="$(printf '%s' "$after" | sed -n 's/.*"tunnel_health": *"\([a-z]*\)".*/\1/p' | head -1)"
r_record "RESULT proto=$now health=$health"

# Ожидаемый протокол в статусе (want вычислен выше, там же выбирается метод замены сервера).
if [ "$now" = "$want" ] && [ "$health" = "up" ]; then
    r_ok "активен $now, здоровье up"
    printf '    Дальше: bash tests/router/verify.sh — проверка насквозь.\n'
    r_finish
elif [ "$now" = "$prev" ]; then
    r_bad "переключение не удалось — вернулся прежний туннель «$prev» (автооткат сработал)"
    printf '    Это КОРРЕКТНОЕ поведение при недостижимом протоколе: роутер остался в интернете.\n'
    printf '    Отличить «наш баг» от «протокол не проходит у провайдера» помогает лог ниже.\n'
    r_ssh 'logread | grep -iE "cheburnet|sing-box" | tail -20' | sed 's/^/    /' || true
    r_finish; exit 1
else
    r_bad "состояние после переключения непонятное: протокол=$now, здоровье=$health"
    r_ssh 'logread | grep -iE "cheburnet|sing-box" | tail -20' | sed 's/^/    /' || true
    r_finish; exit 1
fi
