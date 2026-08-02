#!/bin/bash
# tests/router/switch.sh — ШАГ 4: сменить активный туннель на уже настроенном роутере.
#
#     R_HOST=192.168.1.1 bash tests/router/switch.sh reality
#     R_HOST=192.168.1.1 bash tests/router/switch.sh hysteria2|hysteria2-hop|awg
#
# Зовёт ТЕ ЖЕ методы, что кнопки панели (switch_to_reality / switch_to_hysteria2 / switch_to_awg):
# конфиг нового туннеля приносится, а домены/DNS/режим берутся из сохранённой конфигурации.
# У каждого метода внутри снапшот → применить → проба → commit или АВТООТКАТ, поэтому неудачное
# переключение обязано вернуть прежний рабочий туннель — это и проверяется прогоном.
#
# Переход на Full-протокол требует бинаря sing-box. Он НЕ ставится этим скриптом руками: за него
# отвечает install_full_tier (та же кнопка панели), и вызывается он здесь только при отсутствии
# бинаря — чтобы проверялся именно продуктовый путь догрузки, а не наш обход.

set -e -u -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PROTO="${1:-}"
LINKS="$R_DIR/../vps/links.env"
AWG_CONF_FILE="$R_DIR/../vps/awg-client.conf"

[ -n "$PROTO" ] || { echo "использование: $0 awg|reality|hysteria2|hysteria2-hop"; exit 1; }
[ -f "$LINKS" ] || { echo "✗ нет $LINKS — поднимите стенд (tests/vps/)"; exit 1; }
# shellcheck source=/dev/null
. "$LINKS"

case "$PROTO" in
    awg)
        [ -f "$AWG_CONF_FILE" ] || { echo "✗ нет $AWG_CONF_FILE"; exit 1; }
        METHOD="switch_to_awg";       FIELD="awg_conf";       VALUE="$(cat "$AWG_CONF_FILE")" ;;
    reality)
        METHOD="switch_to_reality";   FIELD="reality_conf";   VALUE="${VLESS_REALITY:-}" ;;
    hysteria2)
        METHOD="switch_to_hysteria2"; FIELD="hysteria2_conf"; VALUE="${HYSTERIA2:-}" ;;
    hysteria2-hop)
        METHOD="switch_to_hysteria2"; FIELD="hysteria2_conf"; VALUE="${HYSTERIA2_PORT_HOPPING:-}" ;;
    *) echo "✗ неизвестный протокол «$PROTO»"; exit 1 ;;
esac
[ -n "$VALUE" ] || { echo "✗ в links.env нет конфига для «$PROTO»"; exit 1; }

r_init "switch-$PROTO"

before="$(r_ssh 'ubus call cheburnet status 2>/dev/null' || true)"
[ -n "$before" ] || r_die "ubus cheburnet не отвечает"
prev="$(printf '%s' "$before" | sed -n 's/.*"protocol": *"\([a-z0-9]*\)".*/\1/p' | head -1)"
printf '  сейчас активен: %s\n' "${prev:-?}"
r_record "SWITCH from=${prev:-?} to=$PROTO"

# Full-протоколам нужен бинарь. Ставим его продуктовым методом панели, а не своим apk add.
case "$PROTO" in
    reality|hysteria2|hysteria2-hop)
        if r_ssh 'command -v sing-box >/dev/null 2>&1'; then
            r_ok "sing-box уже установлен"
        else
            r_msg "Догружаю Full-тир (install_full_tier — кнопка панели)"
            # Метод АСИНХРОННЫЙ: возвращает {"status":"started"} и качает пакет в фоне. Проверять
            # наличие бинаря сразу после вызова бессмысленно — так и было, и читалось как «Full-тир
            # недоступен на этом роутере». Ждём до 3 минут (apk тянет ~10 МБ с зеркала).
            out="$(r_ssh 'ubus call cheburnet install_full_tier 2>&1' || true)"
            printf '%s' "$out" | grep -q 'started' \
                || { printf '%s\n' "$out" | sed 's/^/    /'; r_die "install_full_tier не запустился"; }
            got_sb=0
            for _ in $(seq 1 36); do
                if r_ssh 'command -v sing-box >/dev/null 2>&1'; then got_sb=1; break; fi
                sleep 5
            done
            [ "$got_sb" = "1" ] \
                || { r_ssh 'tail -20 /tmp/cheburnet/install.log 2>/dev/null' | sed 's/^/    /' || true
                     r_die "sing-box не встал за 3 минуты — Full-тир недоступен"; }
            r_ok "sing-box установлен ($(r_ssh 'sing-box version 2>/dev/null | head -1'))"
        fi ;;
esac

# Если целевой протокол УЖЕ активен — это не переключение, а замена сервера, и у движка для неё
# отдельный метод (switch_to_* честно отказывает: «меняйте сервер через замену конфига»). Так
# проверяется, в частности, port hopping: протокол тот же, ссылка другая.
want="${PROTO%-hop}"
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

# Ожидаемый протокол в статусе: hop-вариант — это тот же hysteria2, отличается только ссылка (want
# вычислен выше, там же выбирается метод замены сервера).
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
