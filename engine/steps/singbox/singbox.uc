// singbox.uc — Full-тир: разбор VLESS+Reality и генерация конфига sing-box.
//
// Пользователь приносит подключение от своего Reality-сервера — обычно ссылкой `vless://…`
// (её отдают панели 3x-ui / Hiddify и т.п.) или сырым JSON-конфигом sing-box (advanced).
// Шаг разбирает вход, валидирует (граница доверия — вход пользователя) и генерирует
// /etc/sing-box/config.json + включает сервис. См. [[0004-multi-protocol-tiers]].
//
// ЧИСТОЕ ЯДРО: parse_vless_link (vless:// → поля) + build_singbox_config (поля → конфиг-объект)
// + build_singbox_plan (вход → артефакты: config + uci-операции). Применение (запись файла,
// uci, рестарт) — в apply.uc (импурно, проверяется в QEMU).
//
// ИНВАРИАНТ (тот же, что route_allowed_ips='0' у AWG): auto_route=false — маршрутизацией
// управляет ЯДРО (наш policy-routing / [[policy-routing]]), а НЕ sing-box. sing-box лишь
// презентует TUN-интерфейс (singtun0); тот же firewall/routing-слой направляет в него
// помеченный трафик — ровно как в awg0. Тунель становится взаимозаменяемым (Light↔Full).
// auto_detect_interface=true — серверное соединение sing-box уходит в WAN, не зацикливаясь.

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
export function tun_interface(opts) {
	return resolve_opts(opts).tun;
}

// config_path(opts) / service_name(opts) — артефакты, которыми владеет шаг (для reset/apply).
export function config_path(opts) {
	return resolve_opts(opts).config_path;
}
export function service_name(opts) {
	return resolve_opts(opts).service;
}

// hexnib(c) → значение hex-цифры 0..15 или -1. ucode без готового urldecode — пишем сами.
function hexnib(c) {
	let o = ord(c);
	if (o >= 48 && o <= 57)  return o - 48;  // 0-9
	if (o >= 97 && o <= 102) return o - 87;  // a-f
	if (o >= 65 && o <= 70)  return o - 55;  // A-F
	return -1;
}

// urldecode(s) → percent-декодирование (%XX) для query-параметров ссылки. '+' → пробел
// (form-encoding в query). Битый %XX оставляем как есть — не теряем символ.
function urldecode(s) {
	let out = "", i = 0, n = length(s ?? "");
	while (i < n) {
		let c = substr(s, i, 1);
		if (c == "%" && i + 2 < n) {
			let h = hexnib(substr(s, i + 1, 1)), l = hexnib(substr(s, i + 2, 1));
			if (h >= 0 && l >= 0) { out += chr(h * 16 + l); i += 3; continue; }
		}
		if (c == "+") { out += " "; i++; continue; }
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

// split_hostport(s) → { host, port } или null. host:port и [ipv6]:port (порт строкой).
function split_hostport(s) {
	let t = trim(s ?? "");
	if (length(t) == 0) return null;
	if (substr(t, 0, 1) == "[") {
		let m = match(t, /^\[([^\]]+)\]:([0-9]+)$/);
		return m ? { host: m[1], port: m[2] } : null;
	}
	let idx = -1;
	for (let i = 0; i < length(t); i++)
		if (substr(t, i, 1) == ":") idx = i;
	if (idx < 0) return null;
	let host = substr(t, 0, idx), port = substr(t, idx + 1);
	if (length(host) == 0 || !match(port, /^[0-9]+$/)) return null;
	return { host: host, port: port };
}

// parse_vless_link(s) → { ok, errors, fields }. Формат:
//   vless://<uuid>@<host>:<port>?security=reality&pbk=…&sni=…&sid=…&fp=…&flow=…&type=…#label
// fields: { uuid, host, port, security, pbk, sni, sid, fp, flow, type, label }.
// Парсинг отделён от валидации Reality (build_singbox_config) — здесь только разбор структуры.
export function parse_vless_link(s) {
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

// build_singbox_config(fields, opts) → { ok, errors, config }. fields — из parse_vless_link.
// Валидация (граница доверия): Reality требует uuid/host/port/pbk/sni; security, если задан,
// обязан быть "reality" (Full-тир = только Reality, см. ADR 0004). sid/fp/flow — с дефолтами.
export function build_singbox_config(fields, opts) {
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

	let config = {
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
			stack: "system",
		} ],
		outbounds: [ {
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
		}, {
			type: "direct",
			tag: "direct",
		} ],
		route: {
			// серверное соединение sing-box уходит в реальный WAN, не зацикливаясь в TUN
			auto_detect_interface: true,
			final: "reality-out",
		},
	};
	return { ok: true, errors: [], config: config };
}

// parse_input(text) → { ok, errors, config, source }. Диспетч входа:
//   • "vless://…"  → разобрать ссылку и сгенерировать конфиг (основной путь).
//   • "{…}"        → сырой JSON sing-box (advanced): должен содержать массив outbounds.
//                    Доверяем структуре пользователя, но проверяем минимум (граница доверия).
export function parse_input(text, opts) {
	let raw = trim(text ?? "");
	if (length(raw) == 0)
		return { ok: false, errors: [ "пустой вход" ], config: null, source: "empty" };

	if (substr(raw, 0, 8) == "vless://") {
		let link = parse_vless_link(raw);
		if (!link.ok) return { ok: false, errors: link.errors, config: null, source: "link" };
		let built = build_singbox_config(link.fields, opts);
		return { ok: built.ok, errors: built.errors, config: built.config, source: "link" };
	}

	if (substr(raw, 0, 1) == "{") {
		let obj = json(raw);   // битый JSON → ucode кинет исключение; ловит вызывающий/тест
		if (type(obj) != "object" || type(obj.outbounds) != "array" || length(obj.outbounds) == 0)
			return { ok: false, errors: [ "JSON без массива outbounds" ], config: null, source: "json" };
		return { ok: true, errors: [], config: obj, source: "json" };
	}

	return { ok: false, errors: [ "вход не vless:// и не JSON-объект" ], config: null, source: "?" };
}

// build_singbox_plan(text, opts) → { ok, errors, source, config, config_path, uci_setup,
//   uci_teardown, service }. Артефакты применения: config-объект (apply сериализует в файл),
//   uci-операции включения сервиса (delete-before-set → идемпотентно), имя сервиса для рестарта.
// Сервис OpenWrt sing-box: uci `sing-box.main` с enabled='1' и conffile=путь.
export function build_singbox_plan(text, opts) {
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

	return {
		ok: true, errors: [], source: parsed.source,
		config: parsed.config,
		config_path: o.config_path,
		uci_setup: uci_setup,
		uci_teardown: uci_teardown,
		service: o.service,
		tun: o.tun,
	};
}
