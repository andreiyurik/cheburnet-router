// singbox.uc — Full-тир: разбор ссылок VLESS+Reality / Hysteria2 и генерация конфига sing-box.
//
// Пользователь приносит подключение от своего сервера — ссылкой `vless://…` (панели 3x-ui /
// Hiddify), ссылкой `hysteria2://…` (она же `hy2://…`) или сырым JSON-конфигом sing-box
// (advanced). Шаг разбирает вход, валидирует (граница доверия — вход пользователя) и генерирует
// /etc/sing-box/config.json + включает сервис. См. [[0004-multi-protocol-tiers]].
//
// ЧИСТОЕ ЯДРО: parse_vless_link / parse_hysteria2_link (ссылка → поля) +
// build_singbox_config / build_hysteria2_config (поля → конфиг-объект) + build_singbox_plan
// (вход → артефакты: config + uci-операции). Применение (запись файла, uci, рестарт) — в
// apply.uc (импурно, проверяется в QEMU).
//
// ДВА ПРОТОКОЛА — ОДИН ШАГ: специфичны ровно разбор ссылки и объект outbound. TUN-инбаунд,
// netifd-секции, half-routes, сервис и teardown — ОБЩИЕ (см. ADR 0004, «единый контракт
// транспорта»): туннель остаётся один (singtun0), значит firewall/policy-routing не знают, какой
// протокол активен, и health/проба у обоих одни.
//
// ИНВАРИАНТ (у AWG тот же смысл несёт route_allowed_ips='1'): auto_route=false — маршрутизацией
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

// Порт по умолчанию для hysteria2-ссылки: спецификация hy2-URI разрешает опустить порт и
// говорит, что тогда он равен 443 (в vless-ссылке порт обязателен — там мы его требуем).
const HY2_DEFAULT_PORT = "443";

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

// build_net_plan(opts) → { teardown, setup } — uci network: маршрут «весь трафик в туннель».
//
// ПОЧЕМУ netifd, а не sing-box: инвариант auto_route=false — маршрутизацией владеет ядро. У AWG
// это делает proto-handler (route_allowed_ips=1 ставит default dev awg0). У sing-box TUN такого
// нет, поэтому маршрут держим сами через netifd — он переустанавливает его при пересоздании
// устройства (рестарт sing-box), и откатывается обычным uci-snapshot'ом (симметрия с awg0).
//
// ПОЧЕМУ half-routes 0.0.0.0/1 + 128.0.0.0/1, а не один default: они СПЕЦИФИЧНЕЕ WAN-дефолта
// (0.0.0.0/0), поэтому побеждают его в main-таблице БЕЗ удаления WAN. WAN обязан остаться:
// (1) direct-трафик уходит через него по нашей policy-routing (mark→table→WAN); (2) сам sing-box
// коннектится к Reality-серверу через WAN (auto_detect_interface читает /0-дефолт = WAN — half-
// routes его не трогают, петли нет). Тот же приём, что `redirect-gateway def1` у OpenVPN.
// Наличие этого WAN-дефолта — предусловие шага, а не надежда: apply.uc проверяет его перед
// подъёмом сервиса (pick_wan_fallback из lib/route.uc), потому что AWG умеет его вытеснить.
//
// proto none: интерфейс лишь привязан к устройству singtun0 (адрес назначает сам sing-box,
// 172.19.0.1/30) — netifd не трогает L3, только держит маршруты и ждёт появления устройства.
// IPv4-only: TUN у нас v4 (tun_address). IPv6 в туннель не заводим — от утечки v6 защищает
// kill-switch firewall-шага (drop v6 в туннельном режиме), а не blackhole в v4-only TUN.
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
			// gvisor, а НЕ system — иначе TCP через туннель не работает на роутере с запущенным
			// firewall, то есть у всех (поймано qemu-live-install + диагностикой, 2026-07-31).
			//
			// Механика: со stack="system" sing-box обрабатывает TCP через ЛОКАЛЬНЫЙ сокет, поэтому
			// пакет из TUN обязан быть принят цепочкой input. У fw4 input имеет policy drop, а наш
			// TUN не входит ни в одну зону → SYN до слушателя не доходит. UDP при этом читается из
			// TUN напрямую и firewall его не касается — отсюда обманчивая картина «туннель живой»:
			// DNS и NTP ходят, а ни один сайт не открывается. Проба это честно ловила, но падала и
			// на исправном сервере, и установка Full-тира откатывалась.
			//
			// Почему gvisor, а не «разрешить input с туннеля» (второй проверенный вариант, тоже
			// работает): исключение в firewall открыло бы сервисы роутера со стороны VPN-сервера.
			// gvisor обрабатывает TCP в пользовательском пространстве, поэтому туннель вообще не
			// зависит от настроек firewall — включая чужие правила, которых мы не контролируем.
			// Цена: TCP считается в userspace. На канале до VPS разница неизмерима (узкое место —
			// сам канал); авторитетное сравнение — qemu-netem-v2 (см. ADR 0004).
			//
			// Сборка: gvisor есть и в sing-box-tiny (тег with_gvisor), и в полной — доступность
			// подтверждена в qemu-hysteria-v2.
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

// --- Hysteria2 (Full-тир, ось «плохой канал»): ссылка → поля → outbound ---
//
// Формат (официальная спецификация hy2-URI):
//   hysteria2://[auth@]host[:портовая-часть][/]?[params]#label      (схема-алиас: hy2://)
// params: sni, insecure, obfs, obfs-password, pinSHA256, ech (+ наши локальные up/down, ниже).
// Порт можно опустить (→ 443), а в портовой части разрешён «multi-port» для port hopping.

// parse_port_ranges(spec) → массив диапазонов в СИНТАКСИСЕ SING-BOX ("5000:6000") или null,
// если спека битая. Вход — портовая часть ссылки или значение mport: "443", "443,5000-6000",
// уже-двоеточный "5000:6000". Одиночный порт нормализуем в "N:N" — sing-box принимает range-форму,
// и так вызывающему не нужно различать формы при сборке server_ports.
// null (а не «пропустить мусор») осознанно: битый диапазон = порт-хоппинг молча не работает,
// а узнать об этом человек смог бы только по мёртвому туннелю.
function parse_port_ranges(spec) {
	let s = trim(spec ?? "");
	if (length(s) == 0) return null;
	let out = [], toks = split(s, ",");
	for (let i = 0; i < length(toks); i++) {
		let t = trim(toks[i]);
		if (length(t) == 0) return null;
		let m = match(t, /^([0-9]+)[-:]([0-9]+)$/);
		let lo = m ? int(m[1]) : (match(t, /^[0-9]+$/) ? int(t) : -1);
		let hi = m ? int(m[2]) : lo;
		if (lo < 1 || lo > 65535 || hi < 1 || hi > 65535 || hi < lo) return null;
		push(out, sprintf("%d:%d", lo, hi));
	}
	return out;
}

// split_hy2_hostport(s) → { host, port_spec } или null. Два отличия от split_hostport (vless):
// порт НЕОБЯЗАТЕЛЕН (спецификация: нет порта = 443) и может быть «multi-port» (запятые/дефисы),
// поэтому валидирует портовую часть parse_port_ranges, а не valid_port.
//
// Режем по ПЕРВОМУ ':' (у vless — по последнему): в портовой части могут быть свои двоеточия
// (диапазон "5000:6000"), и резать по последнему значило бы разорвать сам диапазон.
// Голый IPv6 без скобок при этом отваливается сам: "fe80::1" даёт port_spec ":1", а он не
// проходит проверку ниже. Требование скобок — то же, что у vless-парсера, и честный отказ
// лучше мусорных host/port, которые убили бы туннель уже после установки.
function split_hy2_hostport(s) {
	let t = trim(s ?? "");
	if (length(t) == 0) return null;
	if (substr(t, 0, 1) == "[") {
		let close = index(t, "]");
		if (close < 2) return null;
		let host = substr(t, 1, close - 1), tail = substr(t, close + 1);
		if (length(tail) == 0) return { host: host, port_spec: "" };
		if (substr(tail, 0, 1) != ":") return null;
		tail = substr(tail, 1);
		return match(tail, /^[0-9][0-9,:-]*$/) ? { host: host, port_spec: tail } : null;
	}
	let idx = index(t, ":");
	if (idx < 0)
		return { host: t, port_spec: "" };
	let host = substr(t, 0, idx), spec = substr(t, idx + 1);
	if (length(host) == 0 || !match(spec, /^[0-9][0-9,:-]*$/))
		return null;
	return { host: host, port_spec: spec };
}

// parse_hysteria2_link(s) → { ok, errors, fields }.
// fields: { auth, host, port, ports[], sni, insecure, obfs, obfs_password, pin, ech, up, down, label }.
//   port  — одиночный порт строкой (обычный случай, идёт в server_port);
//   ports — диапазоны для port hopping в sing-box-синтаксисе (идут в server_ports).
// Заполнен ровно один из двух: схема sing-box объявляет server_port и server_ports конфликтующими.
function parse_hysteria2_link(s) {
	let raw = trim(s ?? "");
	let rest = null;
	if (substr(raw, 0, 12) == "hysteria2://") rest = substr(raw, 12);
	else if (substr(raw, 0, 6) == "hy2://") rest = substr(raw, 6);
	if (rest == null)
		return { ok: false, errors: [ "ссылка не начинается с hysteria2:// или hy2://" ], fields: {} };

	// fragment (#label) → query (?…) — как в vless-парсере, порядок важен: '?' может быть в label.
	let label = "";
	let hash = index(rest, "#");
	if (hash >= 0) { label = urldecode(substr(rest, hash + 1)); rest = substr(rest, 0, hash); }

	let query = "";
	let qm = index(rest, "?");
	if (qm >= 0) { query = substr(rest, qm + 1); rest = substr(rest, 0, qm); }

	// Путь в hy2-ссылке пустой ("/" перед '?') — отрезаем, иначе он уехал бы в host.
	rest = replace(rest, /\/+$/, "");

	// userinfo@host: auth percent-энкодится (спецификация), поэтому '@' в нём быть не может —
	// но режем по ПОСЛЕДНЕМУ '@' на случай ссылки от панели, которая энкодинг забыла.
	let auth = "", at = -1;
	for (let i = 0; i < length(rest); i++)
		if (substr(rest, i, 1) == "@") at = i;
	if (at >= 0) { auth = urldecode(substr(rest, 0, at)); rest = substr(rest, at + 1); }

	let hp = split_hy2_hostport(rest);
	if (!hp)
		return { ok: false, errors: [ "не разобран host[:порт] (IPv6 — только в квадратных скобках)" ], fields: {} };

	let p = parse_query(query);

	// Порт-хоппинг: стандарт кладёт диапазоны в порт-компонент (host:443,5000-6000), но часть
	// панелей отдаёт их параметром mport — принимаем оба. Порт-компонент приоритетнее: он ближе
	// к серверу правды (сам адрес), mport — расширение.
	let port = "", ports = [];
	let spec = hp.port_spec;
	if (length(spec) == 0)
		spec = trim(p.mport ?? "");
	if (length(spec) == 0) {
		port = HY2_DEFAULT_PORT;
	} else {
		let ranges = parse_port_ranges(spec);
		if (!ranges)
			return { ok: false, errors: [ sprintf("не разобран диапазон портов '%s' (ожидается 443 или 5000-6000,7000)", spec) ], fields: {} };
		// Одиночный порт — обычный server_port, без машинерии port hopping.
		if (match(spec, /^[0-9]+$/))
			port = "" + int(spec);
		else
			ports = ranges;
	}

	return {
		ok: true, errors: [],
		fields: {
			auth: auth, host: hp.host, port: port, ports: ports,
			sni: p.sni ?? "", insecure: p.insecure ?? "",
			obfs: p.obfs ?? "", obfs_password: p["obfs-password"] ?? "",
			pin: p.pinSHA256 ?? "", ech: p.ech ?? "",
			// up/down — НАШИ локальные параметры, не часть стандарта: спецификация hy2-URI прямо
			// требует не класть полосу в ссылку (она индивидуальна и «не для слепого применения»).
			// Их добавляет наш UI по решению владельца — см. ADR 0004, раздел про Brutal.
			up: p.up ?? "", down: p.down ?? "",
			label: label,
		},
	};
}

// truthy_flag(v) — значение булева параметра ссылки. Спецификация задаёт "1"/"0"; "true"
// принимаем как распространённое отклонение панелей.
function truthy_flag(v) {
	let t = lc(trim(v ?? ""));
	return t == "1" || t == "true";
}

// mbps(v) → целое Мбит/с или null. Терпим хвост вида "50 mbps" (панели пишут по-разному),
// но НЕ выдумываем значение: не разобрали — значит его нет, и Brutal не включится (BBR).
function mbps(v) {
	let m = match(trim(v ?? ""), /^([0-9]+)/);
	if (!m) return null;
	let n = int(m[1]);
	return (n > 0 && n <= 100000) ? n : null;
}

// looks_like_ip(h) — литеральный адрес (IPv4 или IPv6), а не имя. Нужно для server_name: SNI с
// IP-адресом часть серверов отвергает, поэтому при отсутствии sni подставляем host ТОЛЬКО если
// это имя.
function looks_like_ip(h) {
	return match(h ?? "", /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null || index(h ?? "", ":") >= 0;
}

// build_hysteria2_config(fields, opts) → { ok, errors, config }. fields — из parse_hysteria2_link.
//
// ГРАНИЦА ДОВЕРИЯ. Часть параметров hy2-URI sing-box не умеет, и молчаливое игнорирование здесь
// было бы худшим из вариантов: человек узнал бы о проблеме из 30-секундной пробы и отката без
// причины. Поэтому отвергаем с НАЗВАННОЙ причиной (см. ADR 0004, «границы поддержки hy2-URI»):
//   • pinSHA256 без insecure=1 — пиннинг сертификата sing-box для hysteria2 не поддерживает,
//     а подставить insecure самим значило бы тихо снять проверку сертификата;
//   • ech — в сборке sing-box-tiny ECH нет;
//   • obfs=gecko — Hysteria умеет, sing-box только salamander.
//
// Полоса (up_mbps/down_mbps) НЕ имеет дефолта осознанно: пустые значения = BBR (документировано в
// схеме outbound hysteria2), а выдуманная цифра включила бы Brutal, который берёт объявленную
// скорость силой — завышение раздувает очередь и делает хуже БЕЗ ошибок в логах.
function build_hysteria2_config(fields, opts) {
	let o = resolve_opts(opts);
	let f = fields ?? {};

	let errors = [];
	if (length(f.host ?? "") == 0) push(errors, "нет host");
	if (length(f.auth ?? "") == 0)
		push(errors, "нет пароля (часть ссылки до '@')");
	let has_port  = match(f.port ?? "", /^[0-9]+$/) != null;
	let has_ports = type(f.ports) == "array" && length(f.ports) > 0;
	if (!has_port && !has_ports) push(errors, "нет/битый порт");

	if (length(f.obfs ?? "") > 0) {
		if (lc(f.obfs) != "salamander")
			push(errors, sprintf("obfs=%s — sing-box поддерживает только salamander", f.obfs));
		else if (length(f.obfs_password ?? "") == 0)
			push(errors, "obfs=salamander без obfs-password — сервер такой трафик не примет");
	}
	let insecure = truthy_flag(f.insecure);
	if (length(f.pin ?? "") > 0 && !insecure)
		push(errors, "параметр pinSHA256 не поддерживается — попросите ссылку с обычным TLS-сертификатом (или с insecure=1)");
	if (length(f.ech ?? "") > 0)
		push(errors, "параметр ech не поддерживается этой сборкой sing-box");

	let up = mbps(f.up), down = mbps(f.down);
	if ((up == null) != (down == null))
		push(errors, "скорость канала указывается парой: и приём, и отдача (иначе congestion control непредсказуем)");

	if (length(errors) > 0)
		return { ok: false, errors: errors, config: null };

	let out = {
		type: "hysteria2",
		tag: "hysteria2-out",
		server: f.host,
		password: f.auth,
	};
	// server_port и server_ports конфликтуют по схеме → пишем ровно одно.
	if (has_ports) out.server_ports = f.ports;
	else out.server_port = int(f.port);
	if (up != null) { out.up_mbps = up; out.down_mbps = down; }
	if (length(f.obfs ?? "") > 0)
		out.obfs = { type: "salamander", password: f.obfs_password };

	// tls обязателен по схеме hysteria2-outbound. server_name: sni из ссылки, иначе имя хоста
	// (но не IP-литерал — такой SNI часть серверов отвергает).
	let tls = { enabled: true };
	let sni = (length(f.sni ?? "") > 0) ? f.sni : (looks_like_ip(f.host) ? "" : f.host);
	if (length(sni) > 0) tls.server_name = sni;
	if (insecure) tls.insecure = true;
	out.tls = tls;

	return { ok: true, errors: [], config: wrap_outbound(o, out) };
}

// parse_input(text) → { ok, errors, config, source }. Диспетч входа:
//   • "vless://…"                 → Reality: разобрать ссылку и сгенерировать конфиг.
//   • "hysteria2://…" / "hy2://…" → Hysteria2: то же самое своей парой функций.
//   • "{…}"                       → сырой JSON sing-box (advanced): должен содержать массив
//                                   outbounds. Доверяем структуре пользователя, но проверяем
//                                   минимум (граница доверия).
// source различает ветки для UI/логов: "link" (vless), "hy2", "json".
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
		let link = parse_hysteria2_link(raw);
		if (!link.ok) return { ok: false, errors: link.errors, config: null, source: "hy2" };
		let built = build_hysteria2_config(link.fields, opts);
		return { ok: built.ok, errors: built.errors, config: built.config, source: "hy2" };
	}

	if (substr(raw, 0, 1) == "{") {
		let obj = json(raw);   // битый JSON → ucode кинет исключение; ловит вызывающий/тест
		if (type(obj) != "object" || type(obj.outbounds) != "array" || length(obj.outbounds) == 0)
			return { ok: false, errors: [ "JSON без массива outbounds" ], config: null, source: "json" };
		return { ok: true, errors: [], config: obj, source: "json" };
	}

	return { ok: false, errors: [ "вход не vless://, не hysteria2:// и не JSON-объект" ],
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
         parse_vless_link, build_singbox_config,
         parse_hysteria2_link, build_hysteria2_config, parse_port_ranges,
         parse_input, build_singbox_plan };
