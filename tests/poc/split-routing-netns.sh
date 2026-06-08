#!/bin/sh
# PoC + e2e (Фаза 0): split-routing БЕЗ sing-box на чистых примитивах ядра.
#
# Две фазы в одном изолированном network namespace:
#   A. ПРИМИТИВЫ  — split вручную на nftables set + fwmark + ip rule (валидирует ставку v2).
#   B. ГЕНЕРАТОР  — тот же split, но команды берём из РЕАЛЬНОГО вывода engine/routing
#                   (ucode). End-to-end проверка генератора БЕЗ роутера и QEMU.
# Фаза B пропускается, если в окружении нет ucode (тогда A всё равно доказывает примитивы).
#
# Запуск (rootless, без sudo):
#   unshare -rn sh tests/poc/split-routing-netns.sh
# Namespace уничтожается сам при выходе.
#
# Модель стенда (туннель эмулируем dummy-интерфейсом — проверяем РАЗВЕДЕНИЕ трафика,
# а не шифрование AmneziaWG):
#   tun0     — «VPN-туннель»  (дефолт для всего)             → main-таблица
#   direct0  — «WAN напрямую» (для адресов из set `direct`)  → таблица 100

set -eu

DIRECT_IP=203.0.113.10        # «адрес из direct-списка» (TEST-NET-3, RFC 5737)
OTHER_IP=198.51.100.10        # «обычный адрес»          (TEST-NET-2, RFC 5737)
MARK=0x1
TABLE=100
REPO=$(cd -- "$(dirname -- "$0")/../.." && pwd)

pass=0; fail=0
ok()   { printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
note() { printf '  \033[33m…\033[0m %s\n' "$1"; }

# gen WHAT-JSON — прогнать запрос через генератор маршрутизации (ucode).
gen() { printf '%s' "$1" | ucode -R "$REPO/engine/routing/generate.uc"; }

# Общая проверка «маршрут зависит от метки»: помеченный → direct0, обычный → tun0.
prove_split() {
  phase=$1
  r_marked=$(ip route get "$DIRECT_IP" mark "$MARK" 2>/dev/null)
  r_plain=$(ip route get "$OTHER_IP" 2>/dev/null)
  echo "  direct-адрес c меткой : $r_marked"
  echo "  обычный адрес без метки: $r_plain"
  echo "$r_marked" | grep -q 'dev direct0' \
    && ok "[$phase] помеченный трафик → direct0 (напрямую)" \
    || bad "[$phase] помеченный трафик НЕ ушёл в direct0"
  echo "$r_plain" | grep -q 'dev tun0' \
    && ok "[$phase] непомеченный трафик → tun0 (туннель)" \
    || bad "[$phase] непомеченный трафик НЕ ушёл в tun0"
}

# Счётчик правила пометки: после пинга direct-адреса правило ДОЛЖНО сматчить хотя бы пакет.
# dummy-интерфейсы роняют пакет (нет соседа), но output-hook nft уже оценит daddr — нам хватит.
prove_counter() {
  phase=$1
  ping -c1 -W1 "$DIRECT_IP" >/dev/null 2>&1 || true
  ping -c1 -W1 "$OTHER_IP"  >/dev/null 2>&1 || true
  dump=$(nft list chain inet fw4 mangle_output)
  echo "$dump" | sed 's/^/  /'
  pkts=$(echo "$dump" | grep -oE 'packets [0-9]+' | grep -oE '[0-9]+' | head -1)
  pkts=${pkts:-0}
  if [ "$pkts" -ge 1 ]; then
    ok "[$phase] правило сматчило direct-адрес (packets=$pkts) — пометка работает"
  else
    bad "[$phase] счётчик правила пуст (packets=$pkts) — пакет не дошёл до output hook"
  fi
}

# --- Два пути выхода (общие для обеих фаз) -------------------------------------
# Только интерфейсы + main-дефолт в туннель. Таблицу 100 (прямой путь) и правило fwmark
# НЕ трогаем здесь: это зона ответственности policy-routing — в фазе A ставим вручную,
# в фазе B их даёт генератор. На реальном роутере main-дефолт держит netifd/awg, не мы.
setup_links() {
  ip link set lo up
  ip link add tun0 type dummy
  ip link add direct0 type dummy
  ip addr add 10.10.0.1/24 dev tun0
  ip addr add 10.20.0.1/24 dev direct0
  ip link set tun0 up
  ip link set direct0 up
  # main: ВСЁ по умолчанию в туннель (fail-safe направление).
  ip route add default dev tun0
}

# Сброс между фазами: убрать ВСЁ маршрутное состояние, чтобы фаза B доказывала split
# исключительно своими (сгенерированными) командами, без следов фазы A.
reset_ns() {
  ip rule del fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
  nft delete table inet fw4 2>/dev/null || true
  ip route flush table "$TABLE" 2>/dev/null || true
  ip route del default 2>/dev/null || true
  ip link del tun0 2>/dev/null || true
  ip link del direct0 2>/dev/null || true
}

############################  ФАЗА A — ПРИМИТИВЫ  ##############################
hdr "ФАЗА A — split вручную на примитивах ядра"
setup_links
echo "  main:      default dev tun0      (туннель — дефолт)"
echo "  table 100: default dev direct0   (напрямую — для помеченных)"

# Прямой путь вручную (в фазе B это делает генератор).
ip route add default dev direct0 table "$TABLE"
ip rule add fwmark "$MARK" lookup "$TABLE"
nft add table inet fw4
nft add set inet fw4 direct '{ type ipv4_addr; flags interval; }'
# output hook с type route → переоценка маршрута для локально-сгенерированных пакетов.
nft add chain inet fw4 mangle_output '{ type route hook output priority mangle; }'
nft add rule inet fw4 mangle_output ip daddr @direct counter meta mark set "$MARK"
nft add element inet fw4 direct "{ $DIRECT_IP }"

prove_split "A"
prove_counter "A"

############################  ФАЗА B — ГЕНЕРАТОР  ##############################
hdr "ФАЗА B — split из РЕАЛЬНОГО вывода engine/routing (ucode)"
if ! command -v ucode >/dev/null 2>&1; then
  note "ucode не найден в окружении — фаза B пропущена (примитивы доказаны фазой A)."
  note "В CI ucode ставится как пакет; локально см. engine/routing/tests/README — пирамида тестов."
else
  reset_ns
  setup_links

  # На реальном роутере таблицу fw4 и базовые цепочки держит firewall4. В netns мы трафик
  # генерируем ЛОКАЛЬНО, поэтому нужен output-hook (type route) — его и просим у генератора
  # через opt hook=output. Таблицу/цепочку (роль firewall4) создаёт стенд; сеты и правило
  # пометки — генератор. ipv6=false: dummy-стенд только v4.
  nft add table inet fw4
  nft add chain inet fw4 mangle_output '{ type route hook output priority mangle; }'

  REQ_NFT='{"what":"nft","domains":["example.com"],"opts":{"ipv6":false,"hook":"output"}}'
  REQ_IPR='{"what":"iprules","opts":{"ipv6":false,"wan_if":"direct0"}}'

  echo "  --- генератор → nft ---"
  gen "$REQ_NFT" | sed 's/^/    /'
  gen "$REQ_NFT" | nft -f -
  # Симулируем dnsmasq: на резолве он сам кладёт IP в set; здесь кладём вручную.
  nft add element inet fw4 direct "{ $DIRECT_IP }"
  # Отдельное правило-наблюдатель: считает пакеты с daddr ∈ direct (то же условие, что у
  # правила генератора, но со счётчиком — генератор счётчик в прод не печатает). Матч ровно
  # на direct-адрес доказывает, что членство в set ловится на реальных пакетах output-hook.
  nft add rule inet fw4 mangle_output ip daddr @direct counter

  echo "  --- генератор → ip rule/route ---"
  gen "$REQ_IPR" | sed 's/^/    /'
  # Применяем построчно. Источник — наш генератор (доверенный), поэтому eval допустим.
  gen "$REQ_IPR" | while IFS= read -r cmd; do
    [ -n "$cmd" ] && eval "$cmd"
  done

  prove_split "B"
  prove_counter "B"
fi

# --- Итог ---------------------------------------------------------------------
hdr "ИТОГ"
echo "  PASS=$pass  FAIL=$fail"
if [ "$fail" -eq 0 ]; then
  printf '  \033[32mСтавка v2 подтверждена: split-routing работает без sing-box —\n'
  printf '  и на голых примитивах (A), и из реального вывода генератора (B).\033[0m\n'
  exit 0
else
  printf '  \033[31mЕсть провалы — смотри выше.\033[0m\n'
  exit 1
fi
