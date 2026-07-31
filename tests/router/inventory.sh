#!/bin/bash
# tests/router/inventory.sh — ШАГ 1: инвентаризация физического роутера. ТОЛЬКО ЧТЕНИЕ.
#
#     R_HOST=192.168.1.1 R_KEY=~/.ssh/id_ed25519 bash tests/router/inventory.sh
#
# Зачем это первым и отдельно: пока неизвестно, что за железо, планировать нечего. Full-тир
# (VLESS+Reality, Hysteria2) требует sing-box и отсекается нашим preflight'ом при нехватке флеша
# или RAM — на типовом роутере с 16 МБ он откажет, и это правильное поведение. Узнать об этом
# нужно ДО того, как что-то менять.
#
# Ничего не устанавливает и не правит: ни одной команды, меняющей состояние. Поэтому безопасно
# запускать на рабочем домашнем роутере в любой момент.

set -e -u -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

r_init "inventory"

r_msg "Железо и прошивка"
r_ssh 'ubus call system board 2>/dev/null || echo "(ubus недоступен)"' | sed 's/^/    /'
r_record "BOARD $(r_ssh 'ubus call system board 2>/dev/null | tr -d "\n " | head -c 300')"

r_msg "Память и флеш"
mem="$(r_ssh "awk '/MemTotal/{printf \"%d\", \$2/1024}' /proc/meminfo")"
memfree="$(r_ssh "awk '/MemAvailable/{printf \"%d\", \$2/1024}' /proc/meminfo")"
# Свободный флеш считаем по writable-ФС (как gather.uc): /overlay, иначе /.
flash="$(r_ssh "(df -k /overlay 2>/dev/null || df -k /) | awk 'NR>1{for(i=1;i<=NF;i++) if (\$i ~ /^[0-9]+\$/) {n++; if (n==3) {printf \"%d\", \$i/1024; exit}}}'")"
printf '    RAM:   %s МБ всего, %s МБ свободно\n' "$mem" "$memfree"
printf '    Флеш:  %s МБ свободно\n' "$flash"
r_record "RAM ${mem}MB total / ${memfree}MB free; FLASH ${flash}MB free"

r_msg "Что уже стоит из нашего стека"
for pkg in cheburnet dnsmasq-full https-dns-proxy kmod-amneziawg amneziawg-tools sing-box sing-box-tiny; do
    if r_ssh "apk list --installed 2>/dev/null | grep -q '^$pkg-[0-9]'"; then
        printf '    ✓ %s\n' "$pkg"
    else
        printf '    — %s\n' "$pkg"
    fi
done

r_msg "Сеть: LAN, WAN, есть ли уже туннели"
r_ssh 'echo "-- интерфейсы:"; ip -4 -br addr show 2>/dev/null | head -12
       echo "-- маршрут по умолчанию:"; ip -4 route show default
       echo "-- WAN по uci:"; uci -q get network.wan.proto 2>/dev/null || echo "(секции wan нет)"' | sed 's/^/    /'

r_msg "Вердикт preflight (наш гейткипер железа)"
# Движок мог быть ещё не установлен — тогда честно говорим, что вердикт будет после установки.
if r_ssh '[ -x /usr/share/cheburnet/engine/preflight/gather.uc ] || [ -f /usr/share/cheburnet/engine/preflight/gather.uc ]' 2>/dev/null; then
    out="$(r_ssh 'ucode -R /usr/share/cheburnet/engine/preflight/gather.uc 2>/dev/null | ucode -R /usr/share/cheburnet/engine/preflight/check.uc 2>&1' || true)"
    printf '%s\n' "$out" | sed 's/^/    /'
    r_record "PREFLIGHT $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"
    if printf '%s' "$out" | grep -q 'ОТКАЗ'; then
        r_warn "preflight ОТКАЗЫВАЕТ на этом железе — установка будет остановлена (это гейткипер, не баг)"
    elif printf '%s' "$out" | grep -q 'ПРОПУЩЕН'; then
        r_warn "preflight пройдёт только «на свой риск» — стабильность не гарантируется"
    else
        r_ok "preflight: железо подходит"
    fi
else
    r_warn "движок ещё не установлен — вердикт preflight будет доступен после bootstrap"
    printf '    Полезно уже сейчас: Full-тир требует ≥ 44 МБ свободного флеша и ≥ 256 МБ RAM.\n'
    if [ "${flash:-0}" -lt 44 ] || [ "${mem:-0}" -lt 256 ]; then
        r_warn "по этим цифрам Full-тир (Reality/Hysteria2) на роутере НЕ поднимется — остаётся AmneziaWG"
    else
        r_ok "по цифрам железо тянет и Full-тир"
    fi
fi

r_msg "Итог"
printf '    Дальше: tests/router/RUNBOOK.md, шаг 2 (бэкап).\n'
printf '    Ничего не изменено — это был read-only прогон.\n'
r_finish
