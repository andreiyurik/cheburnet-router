#!/bin/bash
# tests/router/install.sh — ШАГ 3: установка на физический роутер конфигом со стенда VPS.
#
#     R_HOST=192.168.1.1 bash tests/router/install.sh awg
#     R_HOST=192.168.1.1 bash tests/router/install.sh reality|hysteria2|hysteria2-hop
#
# Зовёт ТОТ ЖЕ метод ubus, что и веб-мастер (`cheburnet install` с install-токеном), а не свои
# команды: проверяем путь, которым пойдут люди. Отличие от мастера только во вводе — конфиг берётся
# из tests/vps (links.env / awg-client.conf), а не из формы браузера.
#
# ПОЧЕМУ СКРИПТОМ, А НЕ РУКАМИ В ПАНЕЛИ: прогон повторяется много раз (три протокола, до и после
# перезагрузки, после откатa), и ручная копипаста ссылки в форму каждый раз — это и время, и
# несравнимые между собой запуски.
#
# Меняет состояние роутера: network/dhcp/firewall, пароль root, Wi-Fi. Поэтому требует бэкапа
# (шаг 2) и явного согласия (R_YES=1 — для неинтерактивных прогонов).
#
# Пароль root задаётся ОБЯЗАТЕЛЬНО (граница ubus требует ≥ 8 символов): передайте свой в R_ROOT_PASS
# или скрипт сгенерирует и напечатает его. Ключ SSH при этом не отзывается — вход по ключу,
# положенному до установки, продолжает работать, и это единственная страховка от потери доступа.

set -e -u -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PROTO="${1:-awg}"
LINKS="$R_DIR/../vps/links.env"
AWG_CONF_FILE="$R_DIR/../vps/awg-client.conf"
DOMAINS="${R_DOMAINS:-example.com}"

[ -f "$LINKS" ] || { echo "✗ нет $LINKS — поднимите стенд (tests/vps/provision-lab.sh + fetch-links.sh)"; exit 1; }
# shellcheck source=/dev/null
. "$LINKS"

r_init "install-$PROTO"

# Конфиг туннеля: у каждого протокола своё поле в install — имя поля и есть формат конфига.
case "$PROTO" in
    awg)
        [ -f "$AWG_CONF_FILE" ] || r_die "нет $AWG_CONF_FILE — fetch-links.sh его качает со стенда"
        CONF_FIELD="awg_conf"; CONF_VALUE="$(cat "$AWG_CONF_FILE")" ;;
    reality)
        CONF_FIELD="reality_conf"; CONF_VALUE="${VLESS_REALITY:-}" ;;
    hysteria2)
        CONF_FIELD="hysteria2_conf"; CONF_VALUE="${HYSTERIA2:-}" ;;
    hysteria2-hop)
        CONF_FIELD="hysteria2_conf"; CONF_VALUE="${HYSTERIA2_PORT_HOPPING:-}" ;;
    *) r_die "неизвестный протокол «$PROTO» (awg|reality|hysteria2|hysteria2-hop)" ;;
esac
[ -n "$CONF_VALUE" ] || r_die "в links.env нет конфига для «$PROTO» — стенд поднялся не полностью"
# Протокол в install — id тира; hop-вариант отличается только ссылкой, но не протоколом.
PROTO_ID="${PROTO%-hop}"

# Токен установки: доказательство «у меня есть SSH к роутеру». Его создаёт bootstrap (или postinst
# пакета) и движок снимает его по завершении установки — повторная установка требует нового.
TOKEN="$(r_ssh 'cat /etc/cheburnet/install-token 2>/dev/null || true' | tr -d '\r\n')"
if [ -z "$TOKEN" ]; then
    r_warn "install-токена нет — он снимается после успешной установки"
    printf '    Новый: ssh %s "ubus call cheburnet install_token"  (метод для владельца панели)\n' "$R_HOST"
    printf '    Либо повторный bootstrap. Пустая установка поверх настроенной — это не путь.\n'
    r_die "нет install-токена"
fi

# Wi-Fi спрашиваем ровно там, где мастер: только при наличии радио.
STATUS="$(r_ssh 'ubus call cheburnet status 2>/dev/null' || true)"
[ -n "$STATUS" ] || r_die "ubus cheburnet не отвечает — пакет установлен? (bootstrap)"
WIFI=0
printf '%s' "$STATUS" | grep -q '"wireless_present": *true' && WIFI=1

# Случайные секреты: сначала ЧИТАЕМ фиксированный кусок /dev/urandom, потом фильтруем и режем.
# Привычный `tr -dc … < /dev/urandom | head -c N` под `pipefail` убивает скрипт: head уходит после
# N байт, tr получает SIGPIPE, и статус пайпа становится 141 — падение без единого сообщения.
rand_str() { head -c 256 /dev/urandom | tr -dc "$1" | cut -c "1-$2"; }
ROOT_PASS="${R_ROOT_PASS:-cheb-$(rand_str 'a-zA-Z0-9' 12)}"
WIFI_KEY="${R_WIFI_KEY:-cheb-wifi-$(rand_str 'a-z0-9' 8)}"
SSID="${R_SSID:-cheburnet-test}"

r_msg "Что будет установлено"
printf '    протокол:      %s (%s)\n' "$PROTO_ID" "$PROTO"
printf '    direct-домены: %s\n' "$DOMAINS"
[ "$WIFI" = "1" ] && printf '    Wi-Fi:         SSID «%s» (пароль будет в отчёте)\n' "$SSID"
printf '    пароль root:   %s\n' "$ROOT_PASS"
r_record "INSTALL proto=$PROTO_ID domains=$DOMAINS ssid=$([ "$WIFI" = 1 ] && echo "$SSID" || echo -)"
r_record "CREDS root_pass=$ROOT_PASS wifi_key=$([ "$WIFI" = 1 ] && echo "$WIFI_KEY" || echo -)"

r_confirm "Установка изменит network/dhcp/firewall, пароль root и Wi-Fi на $R_HOST. Бэкап снят (шаг 2)?"

# Payload собираем питоном в JSON: в конфигах есть переводы строк, '&' и '#', и любое ручное
# экранирование через ssh их рано или поздно испортит (ловилось на ссылках с port hopping).
PAYLOAD="$(CONF_FIELD="$CONF_FIELD" CONF_VALUE="$CONF_VALUE" PROTO_ID="$PROTO_ID" \
    TOKEN="$TOKEN" ROOT_PASS="$ROOT_PASS" DOMAINS="$DOMAINS" \
    SSID="$SSID" WIFI_KEY="$WIFI_KEY" WIFI="$WIFI" python3 -c '
import json, os
a = {
    "protocol": os.environ["PROTO_ID"],
    os.environ["CONF_FIELD"]: os.environ["CONF_VALUE"],
    "root_password": os.environ["ROOT_PASS"],
    "domains": [d.strip() for d in os.environ["DOMAINS"].split(",") if d.strip()],
    "token": os.environ["TOKEN"],
}
if os.environ["WIFI"] == "1":
    a["ssid"] = os.environ["SSID"]
    a["wifi_key"] = os.environ["WIFI_KEY"]
print(json.dumps(a, ensure_ascii=False))')"

TMP_ARGS="$(mktemp)"
printf '%s' "$PAYLOAD" > "$TMP_ARGS"
r_scp "$TMP_ARGS" /tmp/cheburnet-install-args.json
rm -f "$TMP_ARGS"

r_msg "Запускаю установку (тот же метод, что у мастера)"
out="$(r_ssh 'ubus call cheburnet install "$(cat /tmp/cheburnet-install-args.json)"; rm -f /tmp/cheburnet-install-args.json')"
printf '%s' "$out" | grep -q 'started' || r_die "install не запустился: $out"
r_ok "установка запущена"

r_msg "Жду завершения (health-check — самый долгий этап)"
r_wait_op 450 || true
RESULT="$R_OP_RESULT"; REASON="$R_OP_REASON"; STEP="$R_OP_STEP"
r_record "OP result=$RESULT reason=${REASON:-} step=${STEP:-}"

[ "$RESULT" != "timeout" ] || { r_bad "установка не завершилась за 7.5 минут (последний шаг: ${STEP:-?})"
    r_ssh 'tail -30 /tmp/cheburnet/install.log 2>/dev/null' | sed 's/^/    /' || true
    r_finish; exit 1; }

if [ "$RESULT" = "ok" ]; then
    r_ok "установка успешна (протокол $PROTO_ID)"
    r_msg "Итог"
    printf '    Дальше: bash tests/router/verify.sh — проверка насквозь через стенд.\n'
    printf '    Пароль root и ключ Wi-Fi записаны в отчёт (он не коммитится).\n'
    r_finish
else
    r_bad "установка не удалась: result=$RESULT, причина=${REASON:-?} (шаг $STEP)"
    printf '    Это НЕ обязательно баг: откат по health-check — правильное поведение при мёртвом\n'
    printf '    сервере или недоступном протоколе. Смотрим лог, чтобы отличить одно от другого.\n'
    r_ssh 'tail -40 /tmp/cheburnet/install.log 2>/dev/null' | sed 's/^/    /' || true
    r_finish; exit 1
fi
