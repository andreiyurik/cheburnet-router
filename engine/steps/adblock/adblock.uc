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
import { set_var, get_var } from "../../lib/conf.uc";

const ABL_DEFAULTS = {
	tier: "pro",                     // hagezi-тир: реклама+трекеры, сбалансированно
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

// addnmount_paths() → addnmount-записи dnsmasq, которыми владеет шаг (для снятия в reset.uc —
// единственный источник, не дрейфует при смене путей).
export function addnmount_paths() {
	let out = [];
	for (let i = 0; i < length(ABL_DEFAULTS.addnmount); i++)
		push(out, ABL_DEFAULTS.addnmount[i]);
	return out;
}

// parse_blocklists(config_text) → { tier, extras }. Разбор raw_block_lists: первый токен вида
// hagezi:<tier> даёт текущий тир; остальные токены (raw-URL'ы — напр. NSFW-лист family-фильтра)
// идут в extras. Нет переменной/hagezi-токена → tier=null. Используется status и build-планом.
export function parse_blocklists(config_text) {
	let raw = get_var(config_text, "raw_block_lists") ?? "";
	let toks = length(trim(raw)) > 0 ? split(trim(raw), /[ \t]+/) : [];
	let tier = null, extras = [];
	for (let i = 0; i < length(toks); i++) {
		let m = match(toks[i], /^hagezi:(.+)$/);
		if (m && tier == null) tier = m[1];
		else if (!m) push(extras, toks[i]);
	}
	return { tier: tier, extras: extras };
}

// build_adblock_plan(current, opts) → { ok, config, config_changed, addnmount_ops, blocklists }.
//   current — снимок из apply: { config: "<текст /etc/adblock-lean/config>", addnmount: [список] }.
// config — целиком новый текст файла (apply пишет его, если config_changed). addnmount — минимальный
// diff по dnsmasq-списку: добавляем недостающие наши пути, чужие addnmount не трогаем.
//
// Смена тира СОХРАНЯЕТ чужие raw-URL-токены в raw_block_lists (NSFW-лист family-фильтра):
// тир владеет только hagezi-шорткатом. Это фикс бага v1, где sed по всей строке тихо
// выключал NSFW-блок при смене тира.
export function build_adblock_plan(current, opts) {
	let o = resolve_opts(opts);

	// shell-конфиг adblock-lean: задаём raw_block_lists + любые доп. переменные.
	let cfg = (current && current.config) ? current.config : "";
	let parsed = parse_blocklists(cfg);
	// Тир: явный (set_blocklist_tier) → берём; иначе сохраняем текущий из конфига (переустановка
	// не сбрасывает выбор админа); дефолт — только на чистой системе.
	let tier = (opts && opts.tier) ? o.tier : (parsed.tier ?? o.tier);
	let value = "hagezi:" + tier;
	for (let i = 0; i < length(parsed.extras); i++)
		value += " " + parsed.extras[i];
	let newcfg = set_var(cfg, "raw_block_lists", value);
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
		blocklists: value,
		tier: tier,
	};
}
