// doh.uc — DoH-шаг: настроить https-dns-proxy и завернуть upstream dnsmasq в него.
//
// Шифрует upstream-резолв (DNS over HTTPS) лёгким https-dns-proxy перед dnsmasq — замена DoH,
// который в v1 нёс sing-box ([[encrypted-dns]]). Централизованный DNS на роутере, чтобы
// сохранить [[dnsmasq-nftset|пометку адресов]] и [[adblock]] — клиентский DoH их ломает.
//
// ЧИСТОЕ ЯДРО: build_doh_plan(current, opts) → uci-операции для https-dns-proxy + dnsmasq.
// Применение — apply.uc (импурно, QEMU). dnsmasq-привязку держим САМИ (не магия пакета):
// видно каждый шаг (учебная цель), один владелец конфига dnsmasq.

import { reconcile_list, starts_with } from "../../lib/uci.uc";

const DOH_DEFAULTS = {
	listen_addr: "127.0.0.1",
	dnsmasq_section: "@dnsmasq[0]",
	manage_dnsmasq: true, // отключаем авто-правку dnsmasq пакетом — рулим upstream сами
	// По умолчанию Quad9 (no-log, блокирует malware) + Cloudflare как fallback.
	resolvers: [
		{ name: "quad9", url: "https://dns.quad9.net/dns-query",
		  port: 5053, bootstrap: "9.9.9.9,149.112.112.112" },
		{ name: "cloudflare", url: "https://cloudflare-dns.com/dns-query",
		  port: 5054, bootstrap: "1.1.1.1,1.0.0.1" },
	],
};

function resolve_opts(opts) {
	let o = {};
	for (let k in DOH_DEFAULTS) o[k] = DOH_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(DOH_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// build_doh_plan(current, opts) → { ok, errors, hdp_teardown, hdp_setup, dnsmasq_ops, servers }.
//   current — снимок из apply: { hdp_sections: [имена секций], servers: [server-записи dnsmasq] }.
// Идемпотентность: https-dns-proxy секции пересоздаём (delete-before-set, плюс сносим ВСЕ
// существующие — иначе дефолтная секция пакета на :5053 конфликтует с нашей); dnsmasq server —
// минимальный diff по НАШИМ записям (127.0.0.1#port), чужие upstream не трогаем.
export function build_doh_plan(current, opts) {
	let o = resolve_opts(opts);
	let R = o.resolvers;

	// Валидация конфигурации резолверов.
	let errors = [], names = {}, ports = {};
	if (!R || length(R) == 0)
		push(errors, "пустой список резолверов");
	for (let i = 0; i < length(R); i++) {
		let r = R[i];
		if (!r.name || !r.url || !r.port) { push(errors, "резолвер без name/url/port"); continue; }
		if (names[r.name]) push(errors, sprintf("дубль имени резолвера: %s", r.name));
		if (ports[r.port]) push(errors, sprintf("дубль порта: %d", r.port));
		names[r.name] = true; ports[r.port] = true;
	}
	if (length(errors) > 0)
		return { ok: false, errors: errors, hdp_teardown: [], hdp_setup: [], dnsmasq_ops: [] };

	// teardown: снести все существующие https-dns-proxy секции + наши имена (dedup) — чистая замена.
	let td = [], seen = {};
	let existing = (current && current.hdp_sections) ? current.hdp_sections : [];
	for (let i = 0; i < length(existing); i++) {
		let s = existing[i];
		if (!seen[s]) { push(td, sprintf("delete https-dns-proxy.%s", s)); seen[s] = true; }
	}
	for (let i = 0; i < length(R); i++) {
		let n = R[i].name;
		if (!seen[n]) { push(td, sprintf("delete https-dns-proxy.%s", n)); seen[n] = true; }
	}

	// setup: отключить авто-привязку dnsmasq пакетом (рулим сами) + секции резолверов.
	let su = [];
	if (o.manage_dnsmasq)
		// секция 'config' типа main ставится пакетом при установке; правим её опцию.
		push(su, "set https-dns-proxy.config.update_dnsmasq_config='-'");
	for (let i = 0; i < length(R); i++) {
		let r = R[i];
		push(su, sprintf("set https-dns-proxy.%s=https-dns-proxy", r.name));
		push(su, sprintf("set https-dns-proxy.%s.listen_addr='%s'", r.name, o.listen_addr));
		push(su, sprintf("set https-dns-proxy.%s.listen_port='%d'", r.name, r.port));
		push(su, sprintf("set https-dns-proxy.%s.resolver_url='%s'", r.name, r.url));
		if (r.bootstrap)
			push(su, sprintf("set https-dns-proxy.%s.bootstrap_dns='%s'", r.name, r.bootstrap));
		push(su, sprintf("set https-dns-proxy.%s.user='nobody'", r.name));
		push(su, sprintf("set https-dns-proxy.%s.group='nogroup'", r.name));
	}

	// dnsmasq upstream: server = listen_addr#port каждого резолвера. Минимальный diff по НАШИМ
	// записям (начинаются с listen_addr#) — чужие upstream-серверы пользователя сохраняем.
	let desired = [];
	for (let i = 0; i < length(R); i++)
		push(desired, sprintf("%s#%d", o.listen_addr, R[i].port));
	let cur_servers = (current && current.servers) ? current.servers : [];
	let owned = [];
	for (let i = 0; i < length(cur_servers); i++)
		if (starts_with(cur_servers[i], o.listen_addr + "#"))
			push(owned, cur_servers[i]);
	let rec = reconcile_list(owned, desired);
	let dops = [], sect = o.dnsmasq_section;
	for (let i = 0; i < length(rec.remove); i++)
		push(dops, sprintf("del_list dhcp.%s.server='%s'", sect, rec.remove[i]));
	for (let i = 0; i < length(rec.add); i++)
		push(dops, sprintf("add_list dhcp.%s.server='%s'", sect, rec.add[i]));

	return {
		ok: true, errors: [],
		hdp_teardown: td, hdp_setup: su, dnsmasq_ops: dops,
		servers: desired,
	};
}
