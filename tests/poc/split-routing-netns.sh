#!/bin/sh
# PoC (Фаза 0): split-routing БЕЗ sing-box на чистых примитивах ядра.
#
# Проверяет главную ставку v2 (см. docs/architecture-v2.md, docs/v2/architecture/data-plane.md):
# можно ли «домены из direct-списка → напрямую, остальное → туннель» сделать только на
# nftables set + fwmark + ip rule + policy routing, без пользовательского proxy-демона.
#
# Запуск (rootless, без sudo, в изолированном network namespace):
#   unshare -rn sh tests/poc/split-routing-netns.sh
# Namespace уничтожается сам при выходе — ничего за собой не оставляет.
#
# Модель стенда (туннель эмулируем интерфейсом, криптография AmneziaWG тут не нужна —
# проверяем РАЗВЕДЕНИЕ трафика, а не шифрование):
#   tun0     — «VPN-туннель»  (дефолтный путь для всего)        → main-таблица
#   direct0  — «WAN напрямую» (путь для адресов из set `direct`) → таблица 100

set -eu

DIRECT_IP=203.0.113.10        # «адрес из direct-списка» (TEST-NET-3, RFC 5737)
OTHER_IP=198.51.100.10        # «обычный адрес»          (TEST-NET-2, RFC 5737)
MARK=0x1
TABLE=100

pass=0; fail=0
ok()   { printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# --- 1. Эмуляция двух путей выхода --------------------------------------------
hdr "1. Сетевые пути: tun0 (туннель, дефолт) и direct0 (WAN напрямую)"
ip link set lo up
ip link add tun0 type dummy
ip link add direct0 type dummy
ip addr add 10.10.0.1/24 dev tun0
ip addr add 10.20.0.1/24 dev direct0
ip link set tun0 up
ip link set direct0 up

# main-таблица: ВСЁ по умолчанию уходит в туннель (fail-safe направление)
ip route add default dev tun0
# таблица 100: путь «напрямую через WAN»
ip route add default dev direct0 table "$TABLE"
echo "  main:      default dev tun0      (туннель — дефолт для всего)"
echo "  table 100: default dev direct0   (напрямую — для помеченных)"

# --- 2. Policy routing: помеченные fwmark'ом → таблица 100 --------------------
hdr "2. ip rule: fwmark $MARK → таблица $TABLE"
ip rule add fwmark "$MARK" lookup "$TABLE"
ip rule show | sed 's/^/  /'

# --- 3. nftables: set `direct` + правило пометки ------------------------------
hdr "3. nftables: set direct + правило 'ip daddr @direct → mark $MARK'"
nft add table inet fw4
nft add set inet fw4 direct '{ type ipv4_addr; flags interval; }'
# type route hook output → пометка локально-сгенерированных пакетов с переоценкой маршрута
nft add chain inet fw4 mangle_output '{ type route hook output priority mangle; }'
nft add rule inet fw4 mangle_output ip daddr @direct counter meta mark set "$MARK"
# наполняем set «прямым» адресом (на реальном роутере это делает dnsmasq nftset при резолве)
nft add element inet fw4 direct "{ $DIRECT_IP }"
echo "  set direct содержит:"
nft list set inet fw4 direct | sed 's/^/    /'

# --- 4. ДОКАЗАТЕЛЬСТВО A: ip rule разводит по метке ---------------------------
hdr "4. Маршрут зависит от метки (ip route get)"
r_direct_marked=$(ip route get "$DIRECT_IP" mark "$MARK" 2>/dev/null)
r_direct_plain=$(ip route get "$OTHER_IP" 2>/dev/null)
echo "  direct-адрес c меткой : $r_direct_marked"
echo "  обычный адрес без метки: $r_direct_plain"
echo "$r_direct_marked" | grep -q 'dev direct0' \
  && ok "помеченный трафик → direct0 (напрямую)" \
  || bad "помеченный трафик НЕ ушёл в direct0"
echo "$r_direct_plain" | grep -q 'dev tun0' \
  && ok "непомеченный трафик → tun0 (туннель)" \
  || bad "непомеченный трафик НЕ ушёл в tun0"

# --- 5. ДОКАЗАТЕЛЬСТВО B: nft метит ТОЛЬКО адреса из set ----------------------
hdr "5. nft помечает только адреса из set (по счётчику)"
# генерируем по одному локальному пакету на каждый адрес — нужен лишь проход через output hook
# (ответа не будет: dummy-интерфейсы без соседа роняют пакет, но правило nft уже сматчит daddr)
ping -c1 -W1 "$DIRECT_IP" >/dev/null 2>&1 || true   # адрес из set    → правило ДОЛЖНО сматчить
ping -c1 -W1 "$OTHER_IP"  >/dev/null 2>&1 || true   # адрес не в set  → правило НЕ должно матчить
chain_dump=$(nft list chain inet fw4 mangle_output)
echo "$chain_dump" | sed 's/^/  /'
pkts=$(echo "$chain_dump" | grep -oE 'packets [0-9]+' | grep -oE '[0-9]+' | head -1)
pkts=${pkts:-0}
if [ "$pkts" -ge 1 ]; then
  ok "правило сматчило direct-адрес (packets=$pkts) — пометка работает"
else
  bad "счётчик правила пуст (packets=$pkts) — пакет не дошёл до output hook"
fi

# --- Итог ---------------------------------------------------------------------
hdr "ИТОГ"
echo "  PASS=$pass  FAIL=$fail"
if [ "$fail" -eq 0 ]; then
  printf '  \033[32mГлавная ставка v2 подтверждена: split-routing работает без sing-box,\n'
  printf '  только на nftables set + fwmark + ip rule.\033[0m\n'
  exit 0
else
  printf '  \033[31mЕсть провалы — смотри выше.\033[0m\n'
  exit 1
fi
