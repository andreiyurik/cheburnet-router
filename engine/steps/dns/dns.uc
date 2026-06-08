// dns.uc — идемпотентный DNS-шаг: синхронизирует nftset-список dnsmasq с планом маршрутизации.
//
// Это мост [[dns-and-routing|домен → IP → set]]: dnsmasq на резолве кладёт IP direct-доменов
// в nft-сет (см. dnsmasq-nftset). Шаг приводит секцию dnsmasq в желаемое состояние.
//
// ЧИСТОЕ ЯДРО: build_dns_plan(routing_plan, current, opts) → список uci-операций (минимальный
// diff). Чтение текущего uci и запуск `uci` — в apply.uc (импурно, router-side). Повторный
// запуск, когда всё уже как надо, даёт пустой план → no-op (кирпич идемпотентности).

import { render_dnsmasq } from "../../routing/routing.uc";
import { reconcile_list, ends_with } from "../../lib/uci.uc";

const DNS_DEFAULTS = {
	section: "@dnsmasq[0]", // секция dnsmasq в /etc/config/dhcp
	noresolv: true,         // не читать /etc/resolv.conf: upstream — только наш (DoH), без утечки
};

function resolve_opts(opts) {
	let o = {};
	for (let k in DNS_DEFAULTS) o[k] = DNS_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(DNS_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// owns_nftset(value, set4, set6) — наш ли это nftset-элемент. «Наши» — те, что целятся в наши
// сеты (#direct / #direct6). Чужие nftset-записи (другой софт/ручные) НЕ трогаем — поэтому
// reconcile считаем только по нашему подмножеству, а не по всему списку.
function owns_nftset(value, set4, set6) {
	return ends_with(value, "#" + set4) || ends_with(value, "#" + set6);
}

// build_dns_plan(routing_plan, current, opts) → { ops, add, remove, changed }.
//   routing_plan — результат routing.build_plan (даёт желаемые nftset-строки и имена сетов).
//   current      — снимок uci, читает apply: { nftset: [значения], options: {ключ:значение} }.
// ops — строки для `uci batch` (del_list/add_list/set). changed=false → шаг уже применён.
export function build_dns_plan(routing_plan, current, opts) {
	let o = resolve_opts(opts);
	let set4 = routing_plan.opts.set4, set6 = routing_plan.opts.set6;
	let sect = o.section;

	let desired = render_dnsmasq(routing_plan);

	// Текущие nftset, но только НАШИ — чужие сохраняем нетронутыми.
	let cur = (current && current.nftset) ? current.nftset : [];
	let cur_owned = [];
	for (let i = 0; i < length(cur); i++)
		if (owns_nftset(cur[i], set4, set6))
			push(cur_owned, cur[i]);

	let rec = reconcile_list(cur_owned, desired);

	let ops = [];
	for (let i = 0; i < length(rec.remove); i++)
		push(ops, sprintf("del_list dhcp.%s.nftset='%s'", sect, rec.remove[i]));
	for (let i = 0; i < length(rec.add); i++)
		push(ops, sprintf("add_list dhcp.%s.nftset='%s'", sect, rec.add[i]));

	// noresolv — идемпотентный set: трогаем, только если значение ещё не "1".
	let cur_opts = (current && current.options) ? current.options : {};
	if (o.noresolv && cur_opts.noresolv != "1")
		push(ops, sprintf("set dhcp.%s.noresolv='1'", sect));

	return { ops: ops, add: rec.add, remove: rec.remove, changed: length(ops) > 0 };
}
