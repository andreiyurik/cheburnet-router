#!/bin/bash
# tests/router/verify.sh — проверить АКТИВНЫЙ туннель на физическом роутере насквозь.
#
#     R_HOST=192.168.1.1 R_KEY=~/.ssh/id_ed25519 bash tests/router/verify.sh
#
# Проверяет НЕ «обвязка применилась», а «байты дошли до интернета через сервер»:
#   1. панель считает роутер настроенным и туннель здоровым (единый tunnel_health движка);
#   2. трафик выходит с адреса VPS — сверка внешнего адреса, с пином host-route на туннель;
#   3. крупная загрузка проходит целиком — это и есть проверка PMTU, главный риск на PPPoE.
#
# Протокол НЕ переключает: смотрит, что активно сейчас. Переключение — отдельный шаг (switch.sh),
# потому что оно требует пароля root и меняет состояние, а проверка должна быть безопасной и
# повторяемой сколько угодно раз.
#
# Адрес VPS берём из tests/vps/links.env — единственного источника (руками не дублируем).

set -e -u -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LINKS="$R_DIR/../vps/links.env"
[ -f "$LINKS" ] || { echo "✗ нет $LINKS — поднимите стенд и заберите ссылки (см. RUNBOOK, предусловия)"; exit 1; }
# shellcheck source=/dev/null
. "$LINKS"

# Адрес VPS выводим из любой доступной ссылки: он один и тот же для всех трёх протоколов.
VPS_IP="$(printf '%s' "${HYSTERIA2:-${VLESS_REALITY:-}}" | sed -n 's|.*@\([^:/?#]*\).*|\1|p')"
[ -n "$VPS_IP" ] || { echo "✗ не удалось извлечь адрес VPS из links.env"; exit 1; }

r_init "verify"
printf '  стенд: %s\n' "$VPS_IP"

r_msg "Что говорит панель"
status="$(r_ssh 'ubus call cheburnet status 2>/dev/null' || true)"
[ -n "$status" ] || r_die "ubus cheburnet не отвечает — движок установлен?"

proto="$(printf '%s' "$status" | sed -n 's/.*"protocol": *"\([a-z0-9]*\)".*/\1/p' | head -1)"
health="$(printf '%s' "$status" | sed -n 's/.*"tunnel_health": *"\([a-z]*\)".*/\1/p' | head -1)"
installed="$(printf '%s' "$status" | grep -c '"installed": *true' || true)"
printf '    протокол: %s, здоровье: %s, installed: %s\n' "${proto:-?}" "${health:-?}" "$installed"
r_record "STATUS proto=${proto:-?} health=${health:-?} installed=$installed"

[ "$installed" != "0" ] || r_die "панель говорит installed=false — роутер ещё не настроен (шаг 3 RUNBOOK)"

# Интерфейс туннеля выводим из протокола — как это делает движок (PROTOCOLS.tunnel_if),
# а не угадываем по имени.
case "$proto" in
    awg)                 IFACE=awg0 ;;
    reality|hysteria2)   IFACE=singtun0 ;;
    *) r_die "неизвестный протокол «$proto» — обновите verify.sh под новый тир" ;;
esac
printf '    интерфейс: %s\n' "$IFACE"

if [ "$health" = "up" ]; then
    r_ok "tunnel_health=up (панель не врёт про здоровье)"
else
    r_bad "tunnel_health=$health — туннель не поднят, дальнейшие проверки бессмысленны"
    r_ssh 'logread | grep -iE "sing-box|amneziawg|awg0" | tail -15' | sed 's/^/    /' || true
    r_finish; exit 1
fi

r_msg "Байты доходят до интернета через сервер"
r_exit_ip "$IFACE" "$VPS_IP" || { r_finish; exit 1; }

r_msg "Крупная загрузка (PMTU — главный риск на реальном канале)"
r_pmtu "$IFACE" || {
    printf '    Если оборвалось: это правка mtu в SINGBOX_DEFAULTS (Full) или у AWG-интерфейса,\n'
    printf '    и её нужно заносить ЗАМЕРОМ, а не на глаз. Цифры — в отчёте.\n'
    r_finish; exit 1; }

r_msg "Разделение трафика: direct-домен идёт НЕ через туннель"
# Смысл продукта: выбранные домены остаются прямыми. Проверяем по членству адреса в наборе direct —
# это тот самый мост «домен → IP → nftset», главный шрам прошлой архитектуры.
dom="$(r_ssh "uci -q get dhcp.cheburnet_dns4.domain 2>/dev/null | awk '{print \$1}'")"
if [ -n "$dom" ]; then
    # ДВЕ проверки, а не одна. Членство в наборе — только половина моста: правило направления живёт
    # в ядре и, например, не переживало перезагрузку (живой прогон 2026-08-01). Тогда адрес в наборе
    # был, а помеченный трафик всё равно уходил в туннель — и проверка «есть в наборе» давала
    # ложную зелень на сломанном split-tunnel. Поэтому спрашиваем ядро, куда реально пойдёт пакет.
    ip4="$(r_ssh "nslookup $dom 127.0.0.1 >/dev/null 2>&1 || true; sleep 1
                  nft list set inet fw4 direct 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1")"
    if [ -z "$ip4" ]; then
        r_bad "резолв direct-домена ($dom) не наполнил набор — мост «домен → IP → nftset» не работает"
    else
        r_ok "адрес direct-домена ($dom) попал в набор: $ip4"
        route="$(r_ssh "ip route get $ip4 mark 0x1 2>/dev/null | head -1")"
        if printf '%s' "$route" | grep -q "dev $IFACE"; then
            r_bad "помеченный трафик идёт В ТУННЕЛЬ ($IFACE) — split-tunnel не работает: $route"
            printf '    Обычная причина: нет правила policy-routing (ip rule fwmark) или таблицы direct.\n'
            printf '    Проверьте: ip rule show | grep fwmark; ip route show table 100\n'
        else
            r_ok "помеченный трафик идёт мимо туннеля — split реально работает"
            r_record "SPLIT route=$route"
        fi
    fi
else
    r_warn "direct-домены не настроены — split проверять нечем (в мастере список был пуст?)"
fi

r_msg "Итог"
printf '    Протокол %s проверен насквозь на реальном канале.\n' "$proto"
printf '    Перенесите цифры в ADR 0004 (раздел «Замеры»).\n'
r_finish
