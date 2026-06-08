// adblock.uc — adblock-шаг: настроить adblock-lean и дать dnsmasq читать блок-лист.
//
// adblock-lean скармливает dnsmasq списки рекламных/трекерных доменов → dnsmasq отвечает
// NXDOMAIN на них для всей сети ([[adblock]]). Берём сбалансированный список (реклама+трекеры),
// не «аггро», чтобы не ломать легитимные сайты (цель — «у бабушки ничего не отвалилось»).
//
// ЧИСТОЕ ЯДРО: build_adblock_plan(current, opts) → новый текст /etc/adblock-lean/config (shell-
// стиль) + uci-операции addnmount для dnsmasq. Применение — apply.uc (импурно, QEMU).
//
// addnmount: без этих записей dnsmasq не имеет прав читать gz-блок-лист и /bin/busybox —
// adblock-lean логирует "Missing addnmount entries" и сжатый список не подхватывается (урок v1).

import { reconcile_list } from "../../lib/uci.uc";
import { set_var } from "../../lib/conf.uc";

const ABL_DEFAULTS = {
	blocklists: "hagezi:pro",        // реклама+трекеры, сбалансированно
	dnsmasq_section: "@dnsmasq[0]",
	addnmount: [ "/bin/busybox", "/var/run/adblock-lean/abl-blocklist.gz" ],
	config_vars: {},                 // доп. key=value поверх raw_block_lists
};

function resolve_opts(opts) {
	let o = {};
	for (let k in ABL_DEFAULTS) o[k] = ABL_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(ABL_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// build_adblock_plan(current, opts) → { ok, config, config_changed, addnmount_ops, blocklists }.
//   current — снимок из apply: { config: "<текст /etc/adblock-lean/config>", addnmount: [список] }.
// config — целиком новый текст файла (apply пишет его, если config_changed). addnmount — минимальный
// diff по dnsmasq-списку: добавляем недостающие наши пути, чужие addnmount не трогаем.
export function build_adblock_plan(current, opts) {
	let o = resolve_opts(opts);

	// shell-конфиг adblock-lean: задаём raw_block_lists + любые доп. переменные.
	let cfg = (current && current.config) ? current.config : "";
	let newcfg = set_var(cfg, "raw_block_lists", o.blocklists);
	for (let k in o.config_vars)
		newcfg = set_var(newcfg, k, o.config_vars[k]);

	// dnsmasq addnmount: только ДОБАВЛЯЕМ недостающие наши пути (owned = current ∩ desired) —
	// чужие addnmount-записи не удаляем. Идемпотентно: всё на месте → пустой diff.
	let desired = o.addnmount;
	let dset = {};
	for (let i = 0; i < length(desired); i++) dset[desired[i]] = true;
	let cur = (current && current.addnmount) ? current.addnmount : [];
	let owned = [];
	for (let i = 0; i < length(cur); i++)
		if (dset[cur[i]]) push(owned, cur[i]);
	let rec = reconcile_list(owned, desired);

	let ops = [], sect = o.dnsmasq_section;
	for (let i = 0; i < length(rec.remove); i++)
		push(ops, sprintf("del_list dhcp.%s.addnmount='%s'", sect, rec.remove[i]));
	for (let i = 0; i < length(rec.add); i++)
		push(ops, sprintf("add_list dhcp.%s.addnmount='%s'", sect, rec.add[i]));

	return {
		ok: true,
		config: newcfg,
		config_changed: newcfg != cfg,
		addnmount_ops: ops,
		blocklists: o.blocklists,
	};
}
