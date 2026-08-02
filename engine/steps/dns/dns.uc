// dns.uc — идемпотентный DNS-шаг: секции `config ipset` в /etc/config/dhcp + noresolv.
// Мост [[dns-and-routing|домен → IP → set]] — механика nftset: [[dnsmasq-nftset]].
//
// ЧИСТОЕ ЯДРО: build_dns_plan(routing_plan, current, opts) → список uci-операций.
// Идемпотентность: желаемая секция совпала с текущей → не трогаем; всё совпало → no-op.

const DNS_DEFAULTS = {
	sect4: "cheburnet_dns4", // именованная ipset-секция для v4-сета
	sect6: "cheburnet_dns6", // — для v6-сета
	section: "@dnsmasq[0]",  // секция dnsmasq (для noresolv)
	noresolv: true,          // не читать /etc/resolv.conf: upstream — только наш (DoH), без утечки
};

function resolve_opts(opts) {
	let o = {};
	for (let k in DNS_DEFAULTS) o[k] = DNS_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(DNS_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// owned_sections(opts?) → имена наших ipset-секций. Единственный источник для всех, кто их
// читает/сносит (apply, reset, status) — не дрейфует при переименовании.
function owned_sections(opts) {
	let o = resolve_opts(opts);
	return [ o.sect4, o.sect6 ];
}

// same_section(cur, want) → bool. name/domain сравниваются как строки — порядок значим,
// но оба источника детерминированы.
function same_section(cur, want) {
	if (!cur || !want)
		return !cur && !want;
	return join("\n", cur.name ?? []) == join("\n", want.name) &&
	       join("\n", cur.domain ?? []) == join("\n", want.domain) &&
	       (cur.family ?? "") == want.family;
}

// section_ops(sect, want, ro, exists) — uci-операции приведения секции к want.
// Пересоздание целиком (delete-before-set): состояние секции маленькое, а diff по спискам
// не окупает сложность. delete эмитим только если секция реально есть (uci batch падает
// на delete несуществующего).
function section_ops(sect, want, ro, exists) {
	let ops = [];
	if (exists)
		push(ops, sprintf("delete dhcp.%s", sect));
	if (!want)
		return ops;
	push(ops, sprintf("set dhcp.%s=ipset", sect));
	push(ops, sprintf("set dhcp.%s.table='%s'", sect, ro.fw_table));
	push(ops, sprintf("set dhcp.%s.table_family='%s'", sect, ro.family));
	// Платформенный квирк: family задаём явно — иначе init выводит его через `nft list set`,
	// а на свежей установке сета ещё нет (firewall-шаг идёт после dns). Подробно: [[dnsmasq-nftset]].
	push(ops, sprintf("set dhcp.%s.family='%s'", sect, want.family));
	for (let i = 0; i < length(want.name); i++)
		push(ops, sprintf("add_list dhcp.%s.name='%s'", sect, want.name[i]));
	for (let i = 0; i < length(want.domain); i++)
		push(ops, sprintf("add_list dhcp.%s.domain='%s'", sect, want.domain[i]));
	return ops;
}

// build_dns_plan(routing_plan, current, opts) → { ops, domains, changed }.
//   routing_plan — результат routing.build_plan (даёт домены, имена сетов, режим).
//   current      — снимок uci, читает apply: { sections: {имя: {name,domain,family}},
//                  options: {noresolv} }. Отсутствующая секция — просто нет ключа.
// В travel-режиме direct-доменов нет → обе секции сносятся (весь трафик в туннель).
function build_dns_plan(routing_plan, current, opts) {
	let o = resolve_opts(opts);
	let ro = routing_plan.opts;
	let domains = (ro.mode == "travel") ? [] : routing_plan.domains;
	let cur_sections = (current && current.sections) ? current.sections : {};

	let want4 = length(domains) > 0 ? { name: [ro.set4], domain: domains, family: "4" } : null;
	let want6 = (ro.ipv6 && length(domains) > 0)
		? { name: [ro.set6], domain: domains, family: "6" } : null;

	let ops = [];
	let pairs = [ [o.sect4, want4], [o.sect6, want6] ];
	for (let i = 0; i < length(pairs); i++) {
		let sect = pairs[i][0], want = pairs[i][1];
		let cur = cur_sections[sect] ?? null;
		if (!same_section(cur, want)) {
			let sops = section_ops(sect, want, ro, cur != null);
			for (let j = 0; j < length(sops); j++)
				push(ops, sops[j]);
		}
	}

	// noresolv — идемпотентный set: трогаем, только если значение ещё не "1".
	let cur_opts = (current && current.options) ? current.options : {};
	if (o.noresolv && cur_opts.noresolv != "1")
		push(ops, sprintf("set dhcp.%s.noresolv='1'", o.section));

	return { ops: ops, domains: domains, changed: length(ops) > 0 };
}

export { owned_sections, build_dns_plan };
