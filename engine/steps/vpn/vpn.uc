// vpn.uc — VPN-шаг: разбор AmneziaWG .conf и идемпотентный UCI-план интерфейса awg0.
//
// Пользователь приносит .conf от провайдера. Шаг парсит его и приводит network.<iface> +
// peer-секцию к желаемому состоянию ([[amneziawg]]). awg0 — дефолт для всего, что не direct.
//
// ЧИСТОЕ ЯДРО: parse_awg_conf (INI → объект) + split_endpoint + build_vpn_plan (→ uci-операции).
// .conf — вход пользователя, поэтому ВАЛИДИРУЕМ (граница доверия): нет обязательных полей →
// errors, ok=false, шаг не трогает сеть. Применение uci — в apply.uc (импурно, QEMU).
//
// МАРШРУТИЗАЦИЯ (v2): route_allowed_ips='1' — netifd ставит default через awg0 (туннель — дефолт
// для всего, что не direct) и host-route на endpoint через WAN (без зацикливания). Direct-исключения
// вытягивает наша policy-routing (mark→table-100→WAN, см. [[policy-routing]]) — конфликта нет, разные
// таблицы. В v1 дефолт ставил podkop, поэтому стояло '0'; podkop убран — дефолт теперь на netifd.

const VPN_DEFAULTS = {
	interface: "awg0",
	mtu: "1420",
	keepalive: "25",
};

// AWG-параметры обфускации: ключ .conf → uci-опция awg_<lc>. Все опциональны — пишем только
// присутствующие, иначе proto-handler получит пустую строку и netifd не поднимет интерфейс (v1).
const OBFUSCATION = [
	"Jc", "Jmin", "Jmax",
	"S1", "S2", "S3", "S4",
	"H1", "H2", "H3", "H4",
	"I1", "I2", "I3", "I4", "I5",
];

function resolve_opts(opts) {
	let o = {};
	for (let k in VPN_DEFAULTS) o[k] = VPN_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(VPN_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// owned_sections(opts?) → имена uci-секций network, которыми владеет шаг (интерфейс + peer).
// Единственный источник для тех, кто их сносит (install/reset.uc) — не дрейфует при переименовании.
function owned_sections(opts) {
	let o = resolve_opts(opts);
	return [ o.interface, o.interface + "_peer" ];
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

// build_vpn_plan(parsed, opts) → { ok, errors, teardown, setup, interface, peer_section }.
// teardown — delete-before-add (идемпотентность; на apply с || true). setup — uci set/add_list.
// Берём первый [Peer] (типовой случай: один сервер). Маршрутизацию навязываем ядру (см. инвариант).
function build_vpn_plan(parsed, opts) {
	let o = resolve_opts(opts);
	let iface = (parsed && parsed.interface) ? parsed.interface : {};
	let peer = (parsed && parsed.peers && length(parsed.peers) > 0) ? parsed.peers[0] : {};
	let ifname = o.interface;
	let peersect = ifname + "_peer";        // network.awg0_peer (именованная секция — batch-friendly)
	let peertype = "amneziawg_" + ifname;   // тип секции кодирует привязку к интерфейсу

	// Валидация входа пользователя.
	let errors = [];
	if (!iface.PrivateKey) push(errors, "нет PrivateKey в [Interface]");
	if (!iface.Address)    push(errors, "нет Address в [Interface]");
	if (!peer.PublicKey)   push(errors, "нет PublicKey в [Peer]");
	let ep = peer.Endpoint ? split_endpoint(peer.Endpoint) : null;
	if (!peer.Endpoint)    push(errors, "нет Endpoint в [Peer]");
	else if (!ep)          push(errors, sprintf("не разобран Endpoint: %s", peer.Endpoint));

	if (length(errors) > 0)
		return { ok: false, errors: errors, teardown: [], setup: [] };

	let teardown = [
		sprintf("delete network.%s", ifname),
		sprintf("delete network.%s", peersect),
	];

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
	// Обфускация — только присутствующие поля.
	for (let i = 0; i < length(OBFUSCATION); i++) {
		let k = OBFUSCATION[i];
		if (exists(iface, k) && length(iface[k]) > 0)
			push(setup, sprintf("set network.%s.awg_%s='%s'", ifname, lc(k), iface[k]));
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
		peersect, peer.PersistentKeepalive ?? o.keepalive));
	// route_allowed_ips='1' — netifd ставит default dev awg0 (туннель = дефолт) + host-route на
	// endpoint через WAN. Direct идёт мимо туннеля через mark→table-100 (routing/firewall). fail-safe:
	// промах direct-списка = трафик уходит в туннель, а не дропается kill-switch'ем. v1 ставил '0'
	// (маршрутом владел podkop); в v2 podkop нет — дефолт держит netifd.
	push(setup, sprintf("set network.%s.route_allowed_ips='1'", peersect));

	return {
		ok: true, errors: [],
		teardown: teardown, setup: setup,
		interface: ifname, peer_section: peersect,
	};
}

export { owned_sections, split_endpoint, parse_awg_conf, build_vpn_plan };
