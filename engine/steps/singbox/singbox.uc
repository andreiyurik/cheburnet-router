// singbox.uc — Full-тир: разбор ссылки VLESS+Reality и генерация конфига sing-box.
// Чистое ядро: parse_vless_link (ссылка→поля), build_singbox_config (поля→конфиг), build_singbox_plan
// (вход→артефакты). Применение (файл, uci, рестарт) — apply.uc. Тесты — tests/.
// Hysteria2 заморожена (тег hysteria2-final): подробно: [[0009-freeze-hysteria2]], [[0004-multi-protocol-tiers]]

const SINGBOX_DEFAULTS = {
	tun:         "singtun0",          // имя TUN-интерфейса (цель policy-routing, как awg0)
	tun_address: "172.19.0.1/30",     // p2p-адрес TUN (служебный, не пересекается с LAN-кандидатами)
	mtu:         "1500",              // безопасный дефолт; throughput-тюнинг — позже по замерам
	config_path: "/etc/sing-box/config.json",
	service:     "sing-box",          // имя init.d/uci-сервиса пакета OpenWrt
	flow:        "xtls-rprx-vision",  // штатный flow Reality (XTLS Vision)
	fingerprint: "chrome",            // uTLS-отпечаток ClientHello по умолчанию
	log_level:   "warn",
};

function resolve_opts(opts) {
	let o = {};
	for (let k in SINGBOX_DEFAULTS) o[k] = SINGBOX_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(SINGBOX_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// tun_interface(opts) → имя TUN-интерфейса. Единственный источник для routing/firewall и reset
// (как owned_sections у vpn) — не дрейфует при переименовании.
function tun_interface(opts) {
	return resolve_opts(opts).tun;
}

// config_path(opts) / service_name(opts) — артефакты, которыми владеет шаг (для reset/apply).
function config_path(opts) {
	return resolve_opts(opts).config_path;
}
function service_name(opts) {
	return resolve_opts(opts).service;
}

// Имя netifd-интерфейса и route-секций, которыми владеет шаг (для build_net_plan/reset).
// singtun — тонкий proto-none интерфейс поверх TUN-устройства, чтобы netifd держал маршрут;
// две route-секции — half-routes (см. build_net_plan). Единый источник имён — нет дрейфа.
const NET_IFACE = "singtun";
const NET_ROUTE_SECTIONS = [ "cheburnet_str0", "cheburnet_str1" ];

// network_sections(opts?) → секции network, которыми владеет шаг (интерфейс + route-секции).
// Для reset.uc: снести ровно наше, имена не хардкодить на той стороне (как vpn.owned_sections).
function network_sections(opts) {
	let out = [ NET_IFACE ];
	for (let i = 0; i < length(NET_ROUTE_SECTIONS); i++)
		push(out, NET_ROUTE_SECTIONS[i]);
	return out;
}

// build_net_plan(opts) → { teardown, setup } — маршрут «весь трафик в туннель» держит netifd,
// не sing-box (auto_route=false). Тот же механизм и у AWG — см. steps/vpn/vpn.uc HALF_ROUTES.
// ИНВАРИАНТ: half-routes 0.0.0.0/1 + 128.0.0.0/1, не один default — специфичнее WAN-дефолта,
// значит побеждают его без удаления WAN. WAN обязан остаться (direct уходит через него, и сам
// sing-box коннектится к серверу через него же) — apply.uc проверяет это ПЕРЕД стартом сервиса.
// IPv6 в TUN не заводим — от утечки защищает kill-switch firewall-шага. подробно: [[0004-multi-protocol-tiers]]
function build_net_plan(opts) {
	let o = resolve_opts(opts);
	let teardown = [];
	for (let i = 0; i < length(network_sections(opts)); i++)
		push(teardown, "delete network." + network_sections(opts)[i]);

	let setup = [
		sprintf("set network.%s=interface", NET_IFACE),
		sprintf("set network.%s.proto='none'", NET_IFACE),
		sprintf("set network.%s.device='%s'", NET_IFACE, o.tun),
		// half-route 0.0.0.0/1
		sprintf("set network.%s=route", NET_ROUTE_SECTIONS[0]),
		sprintf("set network.%s.interface='%s'", NET_ROUTE_SECTIONS[0], NET_IFACE),
		sprintf("set network.%s.target='0.0.0.0/1'", NET_ROUTE_SECTIONS[0]),
		// half-route 128.0.0.0/1
		sprintf("set network.%s=route", NET_ROUTE_SECTIONS[1]),
		sprintf("set network.%s.interface='%s'", NET_ROUTE_SECTIONS[1], NET_IFACE),
		sprintf("set network.%s.target='128.0.0.0/1'", NET_ROUTE_SECTIONS[1]),
	];
	return { teardown: teardown, setup: setup, iface: NET_IFACE };
}

// hexnib(c) → значение hex-цифры 0..15 или -1. ucode без готового urldecode — пишем сами.
function hexnib(c) {
	let o = ord(c);
	if (o >= 48 && o <= 57)  return o - 48;  // 0-9
	if (o >= 97 && o <= 102) return o - 87;  // a-f
	if (o >= 65 && o <= 70)  return o - 55;  // A-F
	return -1;
}

// urldecode(s) → percent-декодирование (%XX) для query-параметров ссылки. '+' НЕ трогаем:
// vless-ссылка — RFC 3986 URI, а не form-encoding; '+' в значении (например, standard-base64
// pbk от нестандартной панели) — литерал, и превращение его в пробел тихо било бы ключ
// (провал всплывал бы только на 30с-probe после установки). Битый %XX оставляем как есть.
function urldecode(s) {
	let out = "", i = 0, n = length(s ?? "");
	while (i < n) {
		let c = substr(s, i, 1);
		if (c == "%" && i + 2 < n) {
			let h = hexnib(substr(s, i + 1, 1)), l = hexnib(substr(s, i + 2, 1));
			if (h >= 0 && l >= 0) { out += chr(h * 16 + l); i += 3; continue; }
		}
		out += c; i++;
	}
	return out;
}

// parse_query(q) → объект { k: v } из "k1=v1&k2=v2" с urldecode значений.
function parse_query(q) {
	let out = {};
	if (length(q ?? "") == 0) return out;
	let pairs = split(q, "&");
	for (let i = 0; i < length(pairs); i++) {
		let kv = pairs[i];
		let eq = index(kv, "=");
		if (eq < 0) continue;
		let k = substr(kv, 0, eq), v = substr(kv, eq + 1);
		if (length(k) > 0) out[k] = urldecode(v);
	}
	return out;
}

// valid_port(host, port) → {host, port} или null: порт в диапазоне 1..65535 (вход пользователя;
// "99999" проходил бы regex и бил sing-box/netifd только на старте сервиса).
function valid_port(host, port) {
	let p = int(port);
	return (p >= 1 && p <= 65535) ? { host: host, port: port } : null;
}

// split_hostport(s) → { host, port } или null. host:port и [ipv6]:port (порт строкой).
function split_hostport(s) {
	let t = trim(s ?? "");
	if (length(t) == 0) return null;
	if (substr(t, 0, 1) == "[") {
		let m = match(t, /^\[([^\]]+)\]:([0-9]+)$/);
		return m ? valid_port(m[1], m[2]) : null;
	}
	let idx = -1;
	for (let i = 0; i < length(t); i++)
		if (substr(t, i, 1) == ":") idx = i;
	if (idx < 0) return null;
	let host = substr(t, 0, idx), port = substr(t, idx + 1);
	if (length(host) == 0 || !match(port, /^[0-9]+$/)) return null;
	// Голый IPv6 без скобок ("2001:db8::1") резался бы по последнему ':' в мусорные host/port
	// («host» с двоеточиями, «port» из хвоста адреса) и падал только на probe после установки.
	// IPv6 обязан быть в скобках (URL-синтаксис) — честный отказ с понятной ошибкой парсера.
	if (index(host, ":") >= 0) return null;
	return valid_port(host, port);
}

// parse_vless_link(s) → { ok, errors, fields }. Формат:
//   vless://<uuid>@<host>:<port>?security=reality&pbk=…&sni=…&sid=…&fp=…&flow=…&type=…#label
// fields: { uuid, host, port, security, pbk, sni, sid, fp, flow, type, label }.
// Парсинг отделён от валидации Reality (build_singbox_config) — здесь только разбор структуры.
function parse_vless_link(s) {
	let raw = trim(s ?? "");
	if (substr(raw, 0, 8) != "vless://")
		return { ok: false, errors: [ "ссылка не начинается с vless://" ], fields: {} };
	let rest = substr(raw, 8);

	// fragment (#label) — отрезаем первым, label декодируем.
	let label = "";
	let hash = index(rest, "#");
	if (hash >= 0) { label = urldecode(substr(rest, hash + 1)); rest = substr(rest, 0, hash); }

	// query (?…) — отделяем.
	let query = "";
	let qm = index(rest, "?");
	if (qm >= 0) { query = substr(rest, qm + 1); rest = substr(rest, 0, qm); }

	// userinfo@hostport — uuid не содержит '@', режем по первому.
	let at = index(rest, "@");
	if (at < 0)
		return { ok: false, errors: [ "нет '@' — не разобрать uuid@host" ], fields: {} };
	let uuid = trim(substr(rest, 0, at));
	let hp = split_hostport(substr(rest, at + 1));
	if (!hp)
		return { ok: false, errors: [ "не разобран host:port после '@'" ], fields: {} };

	let p = parse_query(query);
	return {
		ok: true, errors: [],
		fields: {
			uuid: uuid, host: hp.host, port: hp.port,
			security: p.security ?? "", pbk: p.pbk ?? "", sni: p.sni ?? "",
			sid: p.sid ?? "", fp: p.fp ?? "", flow: p.flow ?? "",
			type: p.type ?? "", label: label,
		},
	};
}

// wrap_outbound(o, outbound) → полный конфиг sing-box вокруг ГОТОВОГО туннельного outbound.
// ОБЩАЯ часть обоих Full-протоколов: TUN-инбаунд + direct + route. Протокол-специфичен только
// сам outbound — поэтому новый протокол не может случайно потерять инвариант auto_route=false
// или уехать на другой TUN (см. ADR 0004, «единый контракт транспорта»).
function wrap_outbound(o, outbound) {
	return {
		log: { level: o.log_level, timestamp: true },
		inbounds: [ {
			type: "tun",
			tag: "tun-in",
			interface_name: o.tun,
			address: [ o.tun_address ],
			mtu: int(o.mtu),
			// ИНВАРИАНТ: маршрутизацией управляет ядро (наш policy-routing), не sing-box.
			auto_route: false,
			strict_route: false,
			// ИНВАРИАНТ: stack="gvisor", не "system" — при auto_route=false пакет из TUN должен
			// пройти input, а у fw4 там policy drop и TUN вне зон: TCP молча не идёт (UDP идёт →
			// картина обманчива). подробно: [[0004-multi-protocol-tiers]]
			stack: "gvisor",
		} ],
		outbounds: [ outbound, {
			type: "direct",
			tag: "direct",
		} ],
		route: {
			// серверное соединение sing-box уходит в реальный WAN, не зацикливаясь в TUN
			auto_detect_interface: true,
			final: outbound.tag,
		},
	};
}

// build_singbox_config(fields, opts) → { ok, errors, config }. fields — из parse_vless_link.
// Валидация (граница доверия): Reality требует uuid/host/port/pbk/sni; security, если задан,
// обязан быть "reality" (у VLESS без Reality ценности нет, см. ADR 0004). sid/fp/flow — с дефолтами.
function build_singbox_config(fields, opts) {
	let o = resolve_opts(opts);
	let f = fields ?? {};

	let errors = [];
	if (length(f.uuid ?? "") == 0) push(errors, "нет uuid");
	if (length(f.host ?? "") == 0) push(errors, "нет host");
	if (!match(f.port ?? "", /^[0-9]+$/)) push(errors, "нет/битый port");
	if (length(f.pbk ?? "") == 0) push(errors, "нет pbk (Reality public key)");
	if (length(f.sni ?? "") == 0) push(errors, "нет sni (server name)");
	if (length(f.security ?? "") > 0 && f.security != "reality")
		push(errors, sprintf("security=%s — поддерживается только reality", f.security));
	if (length(errors) > 0)
		return { ok: false, errors: errors, config: null };

	let fp   = (length(f.fp ?? "") > 0) ? f.fp : o.fingerprint;
	let flow = (length(f.flow ?? "") > 0) ? f.flow : o.flow;

	// reality.short_id опционален у Reality (сервер может работать без sid) — пишем только если есть.
	let reality = { enabled: true, public_key: f.pbk };
	if (length(f.sid ?? "") > 0) reality.short_id = f.sid;

	return { ok: true, errors: [], config: wrap_outbound(o, {
		type: "vless",
		tag: "reality-out",
		server: f.host,
		server_port: int(f.port),
		uuid: f.uuid,
		flow: flow,
		tls: {
			enabled: true,
			server_name: f.sni,
			utls: { enabled: true, fingerprint: fp },
			reality: reality,
		},
	}) };
}

// parse_input(text) → { ok, errors, config, source }: "vless://" → Reality, "{…}" → сырой JSON sing-box
// (нужен массив outbounds — минимум границы доверия). source ("link" | "json") — для UI/логов.
function parse_input(text, opts) {
	let raw = trim(text ?? "");
	if (length(raw) == 0)
		return { ok: false, errors: [ "пустой вход" ], config: null, source: "empty" };

	if (substr(raw, 0, 8) == "vless://") {
		let link = parse_vless_link(raw);
		if (!link.ok) return { ok: false, errors: link.errors, config: null, source: "link" };
		let built = build_singbox_config(link.fields, opts);
		return { ok: built.ok, errors: built.errors, config: built.config, source: "link" };
	}

	if (substr(raw, 0, 12) == "hysteria2://" || substr(raw, 0, 6) == "hy2://") {
		// Заморожена (ADR 0009): честный отказ с выходом, а не «непонятный вход».
		return { ok: false, config: null, source: "hy2",
			errors: [ "Hysteria2 больше не поддерживается — используйте VLESS+Reality или AmneziaWG" ] };
	}

	if (substr(raw, 0, 1) == "{") {
		let obj = json(raw);   // битый JSON → ucode кинет исключение; ловит вызывающий/тест
		if (type(obj) != "object" || type(obj.outbounds) != "array" || length(obj.outbounds) == 0)
			return { ok: false, errors: [ "JSON без массива outbounds" ], config: null, source: "json" };
		return { ok: true, errors: [], config: obj, source: "json" };
	}

	return { ok: false, errors: [ "вход не vless:// и не JSON-объект" ],
		config: null, source: "?" };
}

// build_singbox_plan(text, opts) → { ok, errors, source, config, config_path, uci_setup,
//   uci_teardown, service }. Артефакты применения: config-объект (apply сериализует в файл),
//   uci-операции включения сервиса (delete-before-set → идемпотентно), имя сервиса для рестарта.
// Сервис OpenWrt sing-box: uci `sing-box.main` с enabled='1' и conffile=путь.
function build_singbox_plan(text, opts) {
	let o = resolve_opts(opts);
	let parsed;
	try {
		parsed = parse_input(text, opts);
	} catch (e) {
		return { ok: false, errors: [ "битый JSON: " + (e.message ?? e) ], source: "json" };
	}
	if (!parsed.ok)
		return { ok: false, errors: parsed.errors, source: parsed.source };

	// Именованная секция main → чистая идемпотентная замена (как cheburnet_doh у DoH).
	let uci_teardown = [ "delete sing-box.main" ];
	let uci_setup = [
		"set sing-box.main=sing-box",
		"set sing-box.main.enabled='1'",
		sprintf("set sing-box.main.conffile='%s'", o.config_path),
	];

	// Маршрут «весь трафик в туннель» через netifd (см. build_net_plan) — отдельный uci-конфиг
	// (network), поэтому отдаём его собственными списками: apply применяет обоими батчами.
	let net = build_net_plan(opts);

	return {
		ok: true, errors: [], source: parsed.source,
		config: parsed.config,
		config_path: o.config_path,
		uci_setup: uci_setup,
		uci_teardown: uci_teardown,
		net_setup: net.setup,
		net_teardown: net.teardown,
		net_iface: net.iface,
		service: o.service,
		tun: o.tun,
	};
}

export { tun_interface, config_path, service_name, network_sections, build_net_plan,
         parse_vless_link, build_singbox_config, parse_input, build_singbox_plan };
