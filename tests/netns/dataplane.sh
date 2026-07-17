#!/bin/sh
# dataplane.sh — герметичный тест ПОВЕДЕНИЯ split-routing после установки (форвард-путь).
#
# Отвечает на вопрос «а точно ли трафик разделяется правильно и не утекает?» — детерминированно,
# за секунды, БЕЗ роутера/QEMU и БЕЗ рабочего VPN. Ключевая идея: разделение трафика — это
# ЛОКАЛЬНОЕ решение ядра (nftset-членство + fwmark + ip rule + kill-switch drop), не зависящее от
# VPN-крипты. Туннель подменяем dummy-интерфейсом и НАБЛЮДАЕМ egress через nft-счётчики.
#
# ПОЧЕМУ форвард-путь (а не output, как в poc/split-routing-netns.sh): продакшн метит трафик в
# PREROUTING, а kill-switch живёт в FORWARD-хуке. Локальный трафик их не проходит → kill-switch там
# непроверяем в принципе. Поэтому строим client→router→{wan,tun} и гоним настоящий форвард-трафик.
#
# Всё ROOTLESS (unshare -rn + дочерний netns по PID) — как poc-split, без sudo. Гоняет РЕАЛЬНЫЙ
# вывод движка (tests/netns/emit.uc → build_firewall_plan/render_dnsmasq), а не свою копию правил.
#
#   make test-netns          # или:  sh tests/netns/dataplane.sh
#   NETNS_REQUIRE=1 …         # в CI: отсутствие инструментов = ФЕЙЛ, а не тихий скип
#
# Покрывает: split (direct→WAN, остальное→туннель) для awg0 И singtun0; kill-switch антиутечку
# (туннель упал → непрямой трафик ДРОПается, не течёт в WAN); travel (весь трафик в туннель);
# идентичность data-plane обоих протоколов; реальный dnsmasq: резолв direct-домена → IP попадает
# в @direct → маршрут уходит в WAN (мост «домен→IP→set», главный шрам v1).

set -eu

SELF=$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
REPO=$(cd -- "$(dirname -- "$0")/../.." && pwd)

emit() { printf '%s' "$1" | ucode -R "$REPO/tests/netns/emit.uc"; }

pass=0; fail=0
ok()   { printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
note() { printf '  \033[33m…\033[0m %s\n' "$1"; }

# ---- зависимости / политика скипа ----------------------------------------------------------
# NETNS_REQUIRE=1 (CI): нехватка инструмента = провал (иначе тихий скип = ложно-зелёный CI).
require_or_skip() {
	miss=""
	for t in unshare nsenter ip nft ucode; do
		command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
	done
	if [ -n "$miss" ]; then
		if [ "${NETNS_REQUIRE:-0}" = "1" ]; then
			printf '\033[31mНет инструментов:%s (NETNS_REQUIRE=1)\033[0m\n' "$miss"; exit 1
		fi
		note "Пропуск: нет инструментов:$miss (rootless netns-тест). NETNS_REQUIRE=1 сделает это фейлом."
		exit 0
	fi
	# Проба: доступен ли rootless user+net namespace в этом окружении.
	if ! unshare -rn true 2>/dev/null; then
		if [ "${NETNS_REQUIRE:-0}" = "1" ]; then
			printf '\033[31mrootless unshare -rn недоступен (NETNS_REQUIRE=1)\033[0m\n'; exit 1
		fi
		note "Пропуск: rootless unshare -rn недоступен в этом окружении."
		exit 0
	fi
}

# =================================  ВНУТРИ NETNS (__run)  ====================================
# Каждый сценарий запускается в СВЕЖЕМ unshare -rn (ре-exec ниже) — чистый netns без следов
# предыдущего. Топологию клиента держим в дочернем netns (unshare -n sleep), ссылаемся по PID.

CPID=""
cleanup_child() { [ -n "$CPID" ] && kill "$CPID" 2>/dev/null || true; }

# build_topology TUN MODE — поднять client→router→{wan0,TUN}, загрузить РЕАЛЬНЫЙ вывод движка
# (nft mark+kill-switch, ip rules) для режима MODE, повесить счётчики-наблюдатели egress.
build_topology() {
	tun=$1; mode=$2
	ip link set lo up
	unshare -n sleep 300 & CPID=$!
	# Дождаться, пока ребёнок РЕАЛЬНО войдёт в свой netns: /proc/PID/ns/net существует сразу
	# (указывая на НАШ ns до exec unshare) — ждём, пока inode станет ОТЛИЧНЫМ от нашего, иначе
	# veth уедет в старый ns и «Cannot find device vC» (гонка fork→exec, ловилась не всегда).
	myns=$(readlink "/proc/self/ns/net")
	i=0
	while [ "$(readlink "/proc/$CPID/ns/net" 2>/dev/null)" = "$myns" ] && [ "$i" -lt 100 ]; do
		i=$((i+1)); sleep 0.05
	done

	ip link add vR type veth peer name vC
	ip link set vC netns "$CPID"
	ip addr add 10.0.0.1/24 dev vR; ip link set vR up
	nsenter -t "$CPID" -n ip link set lo up
	nsenter -t "$CPID" -n ip addr add 10.0.0.2/24 dev vC
	nsenter -t "$CPID" -n ip link set vC up
	nsenter -t "$CPID" -n ip route add default via 10.0.0.1

	sysctl -wq net.ipv4.ip_forward=1
	sysctl -wq net.ipv4.conf.all.rp_filter=0

	# Туннель и WAN — dummy: пакет дропается на xmit, но форвард-хук уже оценил oifname (нам хватит).
	ip link add "$tun" type dummy; ip link set "$tun" up; ip addr add 10.88.0.1/24 dev "$tun"
	ip link add wan0 type dummy;   ip link set wan0 up;   ip addr add 10.99.0.1/24 dev wan0

	# main-таблица КАК НА РОУТЕРЕ: туннель выигрывает (metric 10), WAN-дефолт существует как
	# фолбэк (metric 100). Их держит netifd/awg, не наш шаг — поэтому ставит стенд, а не движок.
	ip route add default dev "$tun" metric 10
	ip route add default dev wan0 metric 100

	# --- РЕАЛЬНЫЙ вывод движка: nft (mark + kill-switch) + policy-routing ---
	nft_body=$(emit "{\"what\":\"nft\",\"domains\":[\"x.example\"],\"routing_opts\":{\"ipv6\":false,\"wan_if\":\"wan0\",\"mode\":\"$mode\"},\"fw_opts\":{\"tunnel_if\":\"$tun\"}}")
	printf 'table inet fw4 {\n%s\n}\n' "$nft_body" | nft -f -
	emit "{\"what\":\"ip\",\"domains\":[\"x.example\"],\"routing_opts\":{\"ipv6\":false,\"wan_if\":\"wan0\",\"mode\":\"$mode\"}}" \
		| while IFS= read -r c; do [ -n "$c" ] && eval "$c"; done

	# Счётчики-наблюдатели egress: priority 200 > kill-switch(filter=0) → drop сюда НЕ долетает,
	# значит инкремент c_wan = трафик РЕАЛЬНО ушёл в WAN (утёк). Свои — тест их владелец, не движок.
	nft add counter inet fw4 c_wan
	nft add counter inet fw4 c_tun
	nft -f - <<-NFTEOF
	table inet fw4 {
	  chain test_obs {
	    type filter hook forward priority 200; policy accept;
	    oifname "wan0" counter name c_wan
	    oifname "$tun" counter name c_tun
	  }
	}
	NFTEOF
}

TUN=""          # имя туннель-интерфейса текущего сценария (для ctun)
D=10; O=10      # курсоры адресов: каждый probe — свежий IP (203.0.113.D / 198.51.100.O) →
                # ct state new гарантирован без conntrack-flush (иначе established обошёл бы kill-switch).
cwan() { nft list counter inet fw4 c_wan | grep -oE 'packets [0-9]+' | grep -oE '[0-9]+'; }
ctun() { nft list counter inet fw4 c_tun | grep -oE 'packets [0-9]+' | grep -oE '[0-9]+'; }
zero() { nft reset counter inet fw4 c_wan >/dev/null; nft reset counter inet fw4 c_tun >/dev/null; }
send_direct() { D=$((D+1)); nsenter -t "$CPID" -n ping -c1 -W1 "203.0.113.$D" >/dev/null 2>&1 || true; }
send_other()  { O=$((O+1)); nsenter -t "$CPID" -n ping -c1 -W1 "198.51.100.$O" >/dev/null 2>&1 || true; }

# scenario_home TUN — split + kill-switch (главный сценарий, гоняется для awg0 и singtun0).
scenario_home() {
	TUN=$1
	trap cleanup_child EXIT
	build_topology "$TUN" home
	# @direct = весь 203.0.113.0/24 → любой probe-адрес прямой, но каждый свежий (ct new).
	nft add element inet fw4 direct '{ 203.0.113.0/24 }'

	hdr "HOME / $TUN — туннель UP"
	zero; send_direct
	[ "$(cwan)" -ge 1 ] && ok "[$TUN] direct-адрес → WAN напрямую (c_wan=$(cwan))" \
		|| bad "[$TUN] direct не ушёл в WAN (c_wan=$(cwan))"
	zero; send_other
	{ [ "$(ctun)" -ge 1 ] && [ "$(cwan)" -eq 0 ]; } \
		&& ok "[$TUN] непрямой → туннель, WAN чист (c_tun=$(ctun) c_wan=$(cwan))" \
		|| bad "[$TUN] непрямой распределён неверно (c_tun=$(ctun) c_wan=$(cwan))"

	hdr "HOME / $TUN — KILL-SWITCH (туннель УПАЛ: netifd снял default)"
	ip route del default dev "$TUN" metric 10
	zero; send_other
	[ "$(cwan)" -eq 0 ] \
		&& ok "[$TUN] АНТИУТЕЧКА: непрямой ДРОПнут, НЕ утёк в WAN (c_wan=$(cwan))" \
		|| bad "[$TUN] УТЕЧКА! непрямой ушёл в открытый WAN (c_wan=$(cwan))"
	zero; send_direct
	[ "$(cwan)" -ge 1 ] \
		&& ok "[$TUN] direct продолжает работать при мёртвом туннеле (c_wan=$(cwan))" \
		|| bad "[$TUN] direct сломался при мёртвом туннеле (c_wan=$(cwan))"
}

# scenario_travel — режим «в поездке»: весь трафик в туннель, kill-switch рубит любой выход в WAN.
scenario_travel() {
	TUN=$1
	trap cleanup_child EXIT
	build_topology "$TUN" travel

	hdr "TRAVEL / $TUN — весь трафик в туннель"
	zero; send_other
	{ [ "$(ctun)" -ge 1 ] && [ "$(cwan)" -eq 0 ]; } \
		&& ok "[travel] трафик → туннель, WAN чист (c_tun=$(ctun) c_wan=$(cwan))" \
		|| bad "[travel] трафик не в туннеле (c_tun=$(ctun) c_wan=$(cwan))"

	hdr "TRAVEL / $TUN — KILL-SWITCH (туннель УПАЛ)"
	ip route del default dev "$TUN" metric 10
	zero; send_other
	[ "$(cwan)" -eq 0 ] \
		&& ok "[travel] АНТИУТЕЧКА: при мёртвом туннеле ничего не утекло в WAN (c_wan=$(cwan))" \
		|| bad "[travel] УТЕЧКА в travel! (c_wan=$(cwan))"
}

# scenario_membership — РЕАЛЬНЫЙ dnsmasq: резолв direct-домена наполняет @direct, и маршрут уходит
# в WAN; непрямой домен в set НЕ попадает и идёт в туннель. Мост «домен→IP→set» (главный шрам v1).
# Требует dnsmasq + резолвер (nslookup/dig); нет — скип (в CI NETNS_REQUIRE=1 сделает фейлом).
scenario_membership() {
	TUN=awg0
	trap 'cleanup_child; [ -n "${UP_PID:-}" ] && kill "$UP_PID" 2>/dev/null; [ -n "${CB_PID:-}" ] && kill "$CB_PID" 2>/dev/null' EXIT

	resolver=""
	command -v nslookup >/dev/null 2>&1 && resolver="nslookup"
	[ -z "$resolver" ] && command -v dig >/dev/null 2>&1 && resolver="dig"
	if ! command -v dnsmasq >/dev/null 2>&1 || [ -z "$resolver" ]; then
		if [ "${NETNS_REQUIRE:-0}" = "1" ]; then
			bad "[membership] нет dnsmasq/resolver, а NETNS_REQUIRE=1"; return
		fi
		note "[membership] пропуск: нет dnsmasq и/или nslookup/dig (проверяется в CI)"; return
	fi
	# dnsmasq без nftset-поддержки (сборочный флаг) — не наш баг, а лимит окружения: честный
	# пропуск даже под NETNS_REQUIRE (иначе спутаем сборку дистрибутива с ошибкой data-plane).
	if dnsmasq --version 2>/dev/null | grep -qw 'no-nftset'; then
		note "[membership] пропуск: dnsmasq собран без nftset-поддержки (no-nftset)"; return
	fi

	build_topology "$TUN" home  # @direct пустой — его наполнит dnsmasq на резолве

	# Апстрим-резолвер (авторитетно отвечает на тестовые домены). Отдельный процесс — чтобы путь
	# был «форвард к апстриму», как в проде (dnsmasq наполняет nftset на форварднутом ответе).
	dnsmasq -k -u root -p 5354 --no-resolv --no-hosts --bind-interfaces --listen-address=127.0.0.1 \
		--address=/directtest.example/203.0.113.77 \
		--address=/othertest.example/198.51.100.55 >/dev/null 2>&1 &
	UP_PID=$!
	# Наш dnsmasq: nftset-строку берём из РЕАЛЬНОГО вывода движка (render_dnsmasq).
	nftset_line=$(emit '{"what":"dnsmasq","domains":["directtest.example"],"routing_opts":{"ipv6":false}}')
	dnsmasq -k -u root -p 53 --no-resolv --no-hosts --bind-interfaces \
		--listen-address=10.0.0.1 --listen-address=127.0.0.1 \
		--server=127.0.0.1#5354 --nftset="$nftset_line" >/dev/null 2>&1 &
	CB_PID=$!
	sleep 0.5

	resolve() { # resolve NAME → запрос к нашему dnsmasq (10.0.0.1) из клиента
		if [ "$resolver" = "nslookup" ]; then
			nsenter -t "$CPID" -n nslookup "$1" 10.0.0.1 >/dev/null 2>&1 || true
		else
			nsenter -t "$CPID" -n dig "@10.0.0.1" "$1" +short >/dev/null 2>&1 || true
		fi
	}

	hdr "MEMBERSHIP — реальный dnsmasq наполняет @direct на резолве"
	resolve directtest.example
	resolve othertest.example
	sleep 0.2
	setdump=$(nft list set inet fw4 direct)
	echo "$setdump" | grep -q '203.0.113.77' \
		&& ok "[membership] direct-домен зарезолвлен → IP в @direct (dnsmasq→nftset)" \
		|| bad "[membership] IP direct-домена НЕ попал в @direct: $setdump"
	echo "$setdump" | grep -q '198.51.100.55' \
		&& bad "[membership] непрямой домен ошибочно попал в @direct (лишнее исключение)" \
		|| ok "[membership] непрямой домен НЕ в @direct (исключён только direct-список)"

	# Мост замыкается на маршруте: пакет к зарезолвленному direct-IP уходит в WAN, к непрямому — в туннель.
	zero
	nsenter -t "$CPID" -n ping -c1 -W1 203.0.113.77 >/dev/null 2>&1 || true
	[ "$(cwan)" -ge 1 ] \
		&& ok "[membership] трафик к зарезолвленному direct-IP → WAN (домен→IP→set→маршрут)" \
		|| bad "[membership] direct-IP не ушёл в WAN (c_wan=$(cwan))"
	zero
	nsenter -t "$CPID" -n ping -c1 -W1 198.51.100.55 >/dev/null 2>&1 || true
	[ "$(ctun)" -ge 1 ] \
		&& ok "[membership] трафик к непрямому IP → туннель (c_tun=$(ctun))" \
		|| bad "[membership] непрямой IP распределён неверно (c_tun=$(ctun))"
}

# Диспетчер ре-exec: каждый сценарий — в своём свежем netns.
if [ "${1:-}" = "__run" ]; then
	case "$2" in
		home)       scenario_home "$3" ;;
		travel)     scenario_travel "$3" ;;
		membership) scenario_membership ;;
		*) echo "unknown scenario: $2" >&2; exit 2 ;;
	esac
	[ "$fail" -eq 0 ] || exit 1
	exit 0
fi

# =====================================  ПАР­ЕНТ  ============================================
require_or_skip

printf '\033[1mnetns data-plane тест — поведение split-routing после установки\033[0m\n'

# Чистая проверка (без netns): data-plane awg и reality ИДЕНТИЧЕН — kill-switch/пометка не зависят
# от имени туннеля (ключуются по WAN-oifname и метке). Это доказывает «туннель взаимозаменяем».
hdr "Идентичность data-plane (awg0 vs singtun0)"
nft_awg=$(emit '{"what":"nft","domains":["x.example"],"routing_opts":{"ipv6":false,"wan_if":"wan0","mode":"home"},"fw_opts":{"tunnel_if":"awg0"}}')
nft_rea=$(emit '{"what":"nft","domains":["x.example"],"routing_opts":{"ipv6":false,"wan_if":"wan0","mode":"home"},"fw_opts":{"tunnel_if":"singtun0"}}')
if [ "$nft_awg" = "$nft_rea" ]; then
	ok "nft-правила (пометка + kill-switch) идентичны для обоих протоколов"
else
	bad "nft-правила разошлись между awg0 и singtun0 — data-plane НЕ взаимозаменяем"
fi

# Поведенческие сценарии — каждый в свежем rootless netns.
rc=0
for spec in "home awg0" "home singtun0" "travel awg0" "membership -"; do
	# shellcheck disable=SC2086
	set -- $spec
	unshare -rn sh "$SELF" __run "$1" "$2" || rc=1
done

hdr "ИТОГ"
if [ "$rc" -eq 0 ] && [ "$fail" -eq 0 ]; then
	printf '  \033[32mРазделение трафика и kill-switch подтверждены на реальном ядре\n'
	printf '  (форвард-путь, реальный вывод движка) — для AmneziaWG и VLESS+Reality.\033[0m\n'
	exit 0
fi
printf '  \033[31mЕсть провалы — смотри выше.\033[0m\n'
exit 1
