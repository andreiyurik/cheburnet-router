// vpn.uc — VPN-шаг: разбор AmneziaWG .conf → идемпотентный uci-план интерфейса awg0.
// Пользователь приносит .conf от провайдера ([[amneziawg]]); .conf — вход пользователя, поэтому
// валидируем (граница доверия) и не трогаем сеть при ok=false. Чистое ядро — apply.uc применяет.

const VPN_DEFAULTS = {
	interface: "awg0",
	mtu: "1420",
	keepalive: "25",
	// arm:false — только для первой установки (run.uc, apply.uc --no-arm): интерфейс поднимается
	// и хендшейк возможен (WireGuard не смотрит на routing table), но half-routes не создаются —
	// дом не переключается на туннель, пока health-check его не подтвердит. Довооружает
	// apply.uc --arm. См. [[reliability]].
	arm: true,
};

// AWG-параметры: ключ .conf → uci-опция proto-handler'а amneziawg (awg-openwrt). Имена явные, не lc():
// у AWG 3.x в uci подчёркивания (HeaderProtectionKey → awg_header_protection_key). Все опциональны —
// пишем только присутствующие, иначе proto-handler получит пустую строку и netifd не поднимет интерфейс (v1).
// ШРАМ (Cudy TR3000, 2026-10): AWG 3.x-поля не доезжали до uci → сервер с HeaderProtectionKey не
// отвечал на handshake → health-check → откат установки. Значения (в т.ч. диапазоны) — как есть.
const AWG_PARAMS = [
	[ "Jc", "awg_jc" ], [ "Jmin", "awg_jmin" ], [ "Jmax", "awg_jmax" ],
	[ "S1", "awg_s1" ], [ "S2", "awg_s2" ], [ "S3", "awg_s3" ], [ "S4", "awg_s4" ],
	[ "H1", "awg_h1" ], [ "H2", "awg_h2" ], [ "H3", "awg_h3" ], [ "H4", "awg_h4" ],
	[ "I1", "awg_i1" ], [ "I2", "awg_i2" ], [ "I3", "awg_i3" ], [ "I4", "awg_i4" ], [ "I5", "awg_i5" ],
	[ "HeaderProtectionKey",    "awg_header_protection_key" ],
	[ "ContentPaddingAddition", "awg_content_padding_addition" ],
	[ "RekeyAfterTime",         "awg_rekey_after_time" ],
	[ "RekeyTimeout",           "awg_rekey_timeout" ],
	[ "RejectAfterTime",        "awg_reject_after_time" ],
	[ "KeepaliveTimeout",       "awg_keepalive_timeout" ],
	[ "MaxHandshakeAttempts",   "awg_max_handshake_attempts" ],
];

// Размер nonce защиты заголовков в модуле AWG 3.1 (header_protection.h): нижняя граница S1..S4.
const HP_NONCE = 12;

// Флаги AWG 3.1: в .conf `on`, в uci — boolean (proto-handler сам пишет обратно `=on`).
const AWG_FLAGS = [
	[ "RandomTrailers", "awg_random_trailers" ],
	[ "DisableCookies", "awg_disable_cookies" ],
];

function flag_on(v) {
	return index([ "on", "true", "yes", "1" ], lc(trim(v ?? ""))) >= 0;
}

// ИНВАРИАНТ: маршрут «всё в туннель» держат HALF-ROUTES (0.0.0.0/1 + 128.0.0.0/1, v6 ::/1 + 8000::/1),
// а НЕ один default: они специфичнее WAN-дефолта и побеждают его, НЕ УДАЛЯЯ — WAN остаётся путём
// для direct-трафика, endpoint'а туннеля и самого роутера. Тот же механизм у Full-тира (singbox.uc).
// ШРАМ: route_allowed_ips='1' замещал WAN-дефолт → исчез awg0 → роутер без пути наружу до ребута
// (QEMU, 2026-08-22). Подробно: [[reliability]].
const HALF_ROUTES = [
	{ suffix: "_route4lo", type: "route",  target: "0.0.0.0/1" },
	{ suffix: "_route4hi", type: "route",  target: "128.0.0.0/1" },
	// v6 наравне с v4: allowed_ips '::/0' и раньше давал ::/0 dev awg0 — поведение туннеля для
	// IPv6 не меняем, меняем только способ держать маршрут.
	{ suffix: "_route6lo", type: "route6", target: "::/1" },
	{ suffix: "_route6hi", type: "route6", target: "8000::/1" },
];

function resolve_opts(opts) {
	let o = {};
	for (let k in VPN_DEFAULTS) o[k] = VPN_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(VPN_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// owned_sections(opts?) → имена uci-секций network, которыми владеет шаг: интерфейс, peer и
// route-секции half-routes. ИНВАРИАНТ: [0] — интерфейс (по нему ifdown). Единственный источник
// для тех, кто их сносит (install/reset.uc) — не дрейфует при переименовании.
function owned_sections(opts) {
	let o = resolve_opts(opts);
	let out = [ o.interface, o.interface + "_peer" ];
	for (let i = 0; i < length(HALF_ROUTES); i++)
		push(out, o.interface + HALF_ROUTES[i].suffix);
	return out;
}

// route_sections(opts?) → только имена route-секций half-routes (для тестов и диагностики).
function route_sections(opts) {
	let ifname = resolve_opts(opts).interface, out = [];
	for (let i = 0; i < length(HALF_ROUTES); i++)
		push(out, ifname + HALF_ROUTES[i].suffix);
	return out;
}

// no_proto_route_op(ifname) → uci-операция «proto-handler свой маршрут НЕ ставит» (см. HALF_ROUTES).
function no_proto_route_op(ifname) {
	return sprintf("set network.%s_peer.route_allowed_ips='0'", ifname);
}

// build_disarm_ops(opts) → { teardown, setup } — «снять маршрут туннеля, КОНФИГ НЕ ТРОГАЯ».
// Интерфейс остаётся настроенным (ключи, endpoint, обфускация) — вернуть вооружение можно одним
// движением. Нужен аварийному режиму (install/pause.uc): туннель мёртв, а дом должен выйти в
// сеть напрямую. teardown применяют по одной через `uci -q` (delete отсутствующей секции — норма,
// а uci_batch считает сбоем любой вывод).
function build_disarm_ops(opts) {
	let ifname = resolve_opts(opts).interface;
	let teardown = [], rs = route_sections(opts);
	for (let i = 0; i < length(rs); i++)
		push(teardown, "delete network." + rs[i]);
	return { teardown: teardown, setup: [ no_proto_route_op(ifname) ] };
}

// build_arm_ops(opts) → { teardown, setup } — «вооружить маршрут туннеля»: half-routes плюс
// запрет proto-handler'у ставить свой default. Идемпотентно (delete-before-set, список удаления
// общий с build_disarm_ops — не разъедется). Зовут два пути: build_vpn_plan (arm=true) и
// apply.uc --arm — довооружение после health-check и миграция установок со старой схемой.
function build_arm_ops(opts) {
	let ifname = resolve_opts(opts).interface;
	let d = build_disarm_ops(opts);
	let setup = [ d.setup[0] ];
	for (let i = 0; i < length(HALF_ROUTES); i++) {
		let r = HALF_ROUTES[i], sect = ifname + r.suffix;
		push(setup, sprintf("set network.%s=%s", sect, r.type));
		push(setup, sprintf("set network.%s.interface='%s'", sect, ifname));
		push(setup, sprintf("set network.%s.target='%s'", sect, r.target));
	}
	return { teardown: d.teardown, setup: setup };
}

// keepalive_seconds(raw, fallback) → секунды строкой. ШРАМ (GL-MT3000, 2026-08-27): клиент Amnezia 2.0
// пишет `PersistentKeepalive = 25-35` (диапазон), awg-tools его отвергает целиком («neither 0/off nor
// 1-65535») — интерфейс не конфигурируется, handshake невозможен. Берём нижнюю границу: чаще — безопасно.
function keepalive_seconds(raw, fallback) {
	let m = match(trim(raw ?? ""), /^([0-9]+)(-[0-9]+)?$/);
	return (m && int(m[1]) >= 0 && int(m[1]) <= 65535) ? m[1] : fallback;
}

// valid_port(host, port) → {host, port} или null: порт 1..65535 (вход пользователя; "99999"
// проходил бы regex и валил netifd только при поднятии интерфейса).
function valid_port(host, port) {
	let p = int(port);
	return (p >= 1 && p <= 65535) ? { host: host, port: port } : null;
}

// split_endpoint(ep) → { host, port } или null. Поддерживает host:port и [ipv6]:port.
function split_endpoint(ep) {
	let s = trim(ep ?? "");
	if (length(s) == 0) return null;
	if (substr(s, 0, 1) == "[") {
		let m = match(s, /^\[([^\]]+)\]:([0-9]+)$/);
		return m ? valid_port(m[1], m[2]) : null;
	}
	// host:port — режем по последнему ':' (у IPv4/DNS-хоста двоеточий нет)
	let idx = -1;
	for (let i = 0; i < length(s); i++)
		if (substr(s, i, 1) == ":") idx = i;
	if (idx < 0) return null;
	let host = substr(s, 0, idx), port = substr(s, idx + 1);
	if (length(host) == 0 || !match(port, /^[0-9]+$/)) return null;
	// Голый IPv6 без скобок резался бы по последнему ':' в мусорные host/port и молча ехал в uci
	// (туннель мёртв после установки). IPv6-endpoint обязан быть в скобках — честный отказ.
	if (index(host, ":") >= 0) return null;
	return valid_port(host, port);
}

// parse_awg_conf(text) → { interface: {ключ:значение}, peers: [{...}] }. INI-формат WireGuard:
// секции [Interface]/[Peer], строки key = value. Inline-комментарии (# или ;) отсекаются.
function parse_awg_conf(text) {
	let iface = {}, peers = [], section = "", curpeer = null;
	let lines = split(text ?? "", "\n");
	for (let i = 0; i < length(lines); i++) {
		let line = trim(replace(lines[i], /[#;].*$/, ""));
		if (length(line) == 0) continue;
		let sec = match(line, /^\[(.+)\]$/);
		if (sec) {
			section = lc(trim(sec[1]));
			if (section == "peer") { curpeer = {}; push(peers, curpeer); }
			continue;
		}
		let eq = index(line, "=");
		if (eq < 0) continue;
		let key = trim(substr(line, 0, eq));
		let val = trim(substr(line, eq + 1));
		if (length(key) == 0) continue;
		if (section == "interface") iface[key] = val;
		else if (section == "peer" && curpeer) curpeer[key] = val;
	}
	return { interface: iface, peers: peers };
}

// unsupported_awg_opts(plan, handler_text) → uci-опции плана, которых proto-handler не знает.
// netifd молча игнорирует незнакомую опцию, а без неё сервер AWG 3.x не ответит на handshake
// (GL-MT3000, 2026-08-27: пакеты до AWG 3.1 и HeaderProtectionKey — 105 пакетов ушло, 0 вернулось).
function unsupported_awg_opts(plan, handler_text) {
	let out = [];
	for (let i = 0; i < length(plan.awg_options ?? []); i++)
		if (index(handler_text ?? "", '"' + plan.awg_options[i] + '"') < 0)
			push(out, plan.awg_options[i]);
	return out;
}

// build_vpn_plan(parsed, opts) → { ok, errors, teardown, setup, interface, peer_section,
// awg_options } (awg_options — записанные awg_*-опции, для сверки с proto-handler'ом в apply.uc).
// teardown — delete-before-add (идемпотентность; на apply с || true). setup — uci set/add_list.
// Берём первый [Peer] (типовой случай: один сервер). Маршрутизацию навязываем ядру (см. инвариант).
function build_vpn_plan(parsed, opts) {
	let o = resolve_opts(opts);
	let iface = (parsed && parsed.interface) ? parsed.interface : {};
	let peer = (parsed && parsed.peers && length(parsed.peers) > 0) ? parsed.peers[0] : {};
	let ifname = o.interface;
	let peersect = ifname + "_peer";        // network.awg0_peer (именованная секция — batch-friendly)
	let peertype = "amneziawg_" + ifname;   // тип секции кодирует привязку к интерфейсу

	let errors = [];
	if (!iface.PrivateKey) push(errors, "нет PrivateKey в [Interface]");
	if (!iface.Address)    push(errors, "нет Address в [Interface]");
	if (!peer.PublicKey)   push(errors, "нет PublicKey в [Peer]");
	let ep = peer.Endpoint ? split_endpoint(peer.Endpoint) : null;
	if (!peer.Endpoint)    push(errors, "нет Endpoint в [Peer]");
	else if (!ep)          push(errors, sprintf("не разобран Endpoint: %s", peer.Endpoint));

	// ШРАМ (qemu-profiles, 2026-10-18): модуль AWG 3.1 с HeaderProtectionKey требует S1..S4 ≥ 12 (nonce)
	// и иначе отвергает ВЕСЬ конфиг (EINVAL) — интерфейс пуст, установка падает невнятным «нет рукопожатия».
	if (length(iface.HeaderProtectionKey ?? "") > 0)
		for (let k in [ "S1", "S2", "S3", "S4" ])
			if (!match(iface[k] ?? "", /^[0-9]+$/) || int(iface[k]) < HP_NONCE)
				push(errors, sprintf("HeaderProtectionKey требует %s не меньше %d (в конфиге: %s) — "
					+ "конфиг неполный, возьмите его у сервера заново", k, HP_NONCE, iface[k] ?? "нет"));

	if (length(errors) > 0)
		return { ok: false, errors: errors, teardown: [], setup: [] };

	let arm = build_arm_ops(o);
	let teardown = [
		sprintf("delete network.%s", ifname),
		sprintf("delete network.%s", peersect),
	];
	// route-секции сносим всегда: пере-применение с --no-arm обязано СНЯТЬ прежние half-routes,
	// иначе «не вооружён» остался бы вооружённым.
	for (let i = 0; i < length(arm.teardown); i++)
		push(teardown, arm.teardown[i]);

	let setup = [];
	push(setup, sprintf("set network.%s=interface", ifname));
	push(setup, sprintf("set network.%s.proto='amneziawg'", ifname));
	push(setup, sprintf("set network.%s.private_key='%s'", ifname, iface.PrivateKey));
	// Address может быть dual-stack ("10.0.0.2/32, fd00::2/128") → каждый в add_list.
	let addrs = split(iface.Address, ",");
	for (let i = 0; i < length(addrs); i++) {
		let a = trim(addrs[i]);
		if (length(a) > 0)
			push(setup, sprintf("add_list network.%s.addresses='%s'", ifname, a));
	}
	push(setup, sprintf("set network.%s.mtu='%s'", ifname, iface.MTU ?? o.mtu));
	let awg_options = [];
	for (let i = 0; i < length(AWG_PARAMS); i++) {
		let k = AWG_PARAMS[i][0], opt = AWG_PARAMS[i][1];
		if (exists(iface, k) && length(iface[k]) > 0) {
			push(setup, sprintf("set network.%s.%s='%s'", ifname, opt, iface[k]));
			push(awg_options, opt);
		}
	}
	for (let i = 0; i < length(AWG_FLAGS); i++) {
		let k = AWG_FLAGS[i][0], opt = AWG_FLAGS[i][1];
		if (flag_on(iface[k])) {
			push(setup, sprintf("set network.%s.%s='1'", ifname, opt));
			push(awg_options, opt);
		}
	}

	// Peer.
	push(setup, sprintf("set network.%s=%s", peersect, peertype));
	push(setup, sprintf("set network.%s.public_key='%s'", peersect, peer.PublicKey));
	if (peer.PresharedKey)
		push(setup, sprintf("set network.%s.preshared_key='%s'", peersect, peer.PresharedKey));
	// allowed_ips навязываем full (туннель принимает всё); направление решает ядро.
	push(setup, sprintf("add_list network.%s.allowed_ips='0.0.0.0/0'", peersect));
	push(setup, sprintf("add_list network.%s.allowed_ips='::/0'", peersect));
	push(setup, sprintf("set network.%s.endpoint_host='%s'", peersect, ep.host));
	push(setup, sprintf("set network.%s.endpoint_port='%s'", peersect, ep.port));
	push(setup, sprintf("set network.%s.persistent_keepalive='%s'",
		peersect, keepalive_seconds(peer.PersistentKeepalive, o.keepalive)));
	// Вооружение = наличие half-routes (см. HALF_ROUTES): туннель — дефолт для всего, что не
	// помечено direct, а direct уходит мимо через mark→table-100 (routing/firewall) — разные
	// таблицы, конфликта нет. fail-safe: промах direct-списка = трафик в туннель, а не мимо
	// kill-switch'а. o.arm=false (первая установка, до health-check) — интерфейс поднимается,
	// хендшейк идёт, но дом на непроверенный туннель не переключается (довооружает apply.uc --arm).
	if (o.arm)
		for (let i = 0; i < length(arm.setup); i++)
			push(setup, arm.setup[i]);
	else
		push(setup, no_proto_route_op(ifname));

	return {
		ok: true, errors: [],
		teardown: teardown, setup: setup,
		interface: ifname, peer_section: peersect,
		awg_options: awg_options,
	};
}

export { owned_sections, route_sections, build_arm_ops, build_disarm_ops, split_endpoint, parse_awg_conf,
         build_vpn_plan, unsupported_awg_opts };
