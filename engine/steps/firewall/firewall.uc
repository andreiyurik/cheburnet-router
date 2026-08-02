// firewall.uc — data-plane шаг: пометка direct-трафика, policy routing и kill-switch.
// build_firewall_plan(routing_plan, opts) → чистый план (nft-файл, ip- и uci-команды);
// apply.uc применяет на роутере. Подробно: [[policy-routing]], [[kill-switch]]. Тесты: tests/.

import { render_iprules } from "../../routing/routing.uc";

const NFT_PATH = "/etc/nftables.d/10-cheburnet.nft";
// ИНВАРИАНТ: наши цепочки/сеты живут в /etc/nftables.d/, не инъекцией `nft add` — fw4 включает
// файл в table inet fw4 при каждом reload, поэтому reload их не стирает. Подробно: [[kill-switch]].
const HOTPLUG_PATH = "/etc/hotplug.d/iface/99-cheburnet";

const FW_DEFAULTS = {
	mark_chain: "cheburnet_mark",
	ks_chain: "cheburnet_ks",
	killswitch: true,
	nat: true, // зона masq на awg0 + forwarding lan→vpn, см. build_nat_ops
	tunnel_if: "awg0", // интерфейс туннеля (совпадает с vpn-шагом)
	lan_zone: "lan",   // имя LAN-зоны fw4; forwarding по ИМЕНИ зоны, не по CIDR
	vpn_zone: "vpn",
};

function resolve_opts(opts) {
	let o = {};
	for (let k in FW_DEFAULTS) o[k] = FW_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(FW_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// build_nat_ops(opts) → { teardown, setup }: uci-зона туннеля (masq+mtu_fix) + forwarding lan→vpn.
// Именованные секции, идемпотентно (delete-before-set). Чистый uci-конфиг (∈ CLEAN_CONFIGS,
// откатывается snapshot'ом), в отличие от nft/ip ниже — применять ДО nft-инъекции (apply.uc).
//   masq=1 — SNAT LAN→awg0 (без него обратный путь не находится); mtu_fix=1 — MSS-clamp под MTU
//   туннеля; input REJECT — снаружи по туннелю в роутер не лезут.
function build_nat_ops(opts) {
	let o = opts ?? {};
	let tif  = o.tunnel_if ?? "awg0";
	let lan  = o.lan_zone ?? "lan";
	let zone = o.vpn_zone ?? "vpn";
	let zsect = "cheburnet_" + zone;
	let fsect = "cheburnet_" + lan + "_" + zone;

	let teardown = [
		sprintf("delete firewall.%s", zsect),
		sprintf("delete firewall.%s", fsect),
	];
	let setup = [
		sprintf("set firewall.%s=zone", zsect),
		sprintf("set firewall.%s.name='%s'", zsect, zone),
		sprintf("add_list firewall.%s.network='%s'", zsect, tif),
		sprintf("set firewall.%s.masq='1'", zsect),
		sprintf("set firewall.%s.mtu_fix='1'", zsect),
		sprintf("set firewall.%s.input='REJECT'", zsect),
		sprintf("set firewall.%s.output='ACCEPT'", zsect),
		sprintf("set firewall.%s.forward='REJECT'", zsect),
		sprintf("set firewall.%s=forwarding", fsect),
		sprintf("set firewall.%s.src='%s'", fsect, lan),
		sprintf("set firewall.%s.dest='%s'", fsect, zone),
	];
	return { teardown: teardown, setup: setup };
}

// render_nft_file(routing_plan, o) → содержимое /etc/nftables.d/10-cheburnet.nft.
// Формат — тело, которое fw4 включает ВНУТРЬ table inet fw4 (без обёртки table и без `add`):
// декларативные `set …` и `chain …` с правилами. Возвращает { content, killswitch }.
// killswitch отдаём отдельно (список ks-правил) — для юнит-проверки security-семантики.
function render_nft_file(routing_plan, o) {
	let ro = routing_plan.opts;
	let wan = ro.wan_if, mark = ro.mark;
	let L = [
		"# cheburnet: пометка direct-трафика + kill-switch (см. firewall.uc).",
		"# fw4 включает этот файл в table inet fw4 при каждом reload — правила переживают reload.",
		sprintf("set %s { type ipv4_addr; flags interval; }", ro.set4),
	];
	if (ro.ipv6)
		push(L, sprintf("set %s { type ipv6_addr; flags interval; }", ro.set6));

	// Цепочка пометки (prerouting/mangle): daddr ∈ direct → mark. В travel правил нет.
	push(L, sprintf("chain %s {", o.mark_chain));
	push(L, "\ttype filter hook prerouting priority mangle; policy accept;");
	if (ro.mode != "travel") {
		push(L, sprintf("\tip daddr @%s meta mark set %s", ro.set4, mark));
		if (ro.ipv6)
			push(L, sprintf("\tip6 daddr @%s meta mark set %s", ro.set6, mark));
	}
	push(L, "}");

	// kill-switch (forward/filter): ct state new рубит только новые соединения мимо туннеля,
	// established проходит. AWG-handshake — output роутера, не forward, поэтому не задет.
	let ks = [];
	if (o.killswitch && wan) {
		if (ro.mode == "travel")
			push(ks, sprintf("oifname \"%s\" ct state new drop", wan));
		else
			push(ks, sprintf("oifname \"%s\" meta mark != %s ct state new drop", wan, mark));
		push(L, sprintf("chain %s {", o.ks_chain));
		push(L, "\ttype filter hook forward priority filter; policy accept;");
		for (let i = 0; i < length(ks); i++)
			push(L, "\t" + ks[i]);
		push(L, "}");
	}

	return { content: join("\n", L) + "\n", killswitch: ks };
}

// render_hotplug() → текст hotplug-хука (POSIX sh, busybox-ash).
// ШРАМ: ip-часть data-plane (policy routing) живёт только в ядре и не переживает ребут — split
// молча уходит в туннель, панель остаётся зелёной. Хук зовёт reapply.uc на ifup ЛЮБОГО
// интерфейса (имя WAN-логики в netifd не гарантировано) и ждёт ОБА артефакта (правило И маршрут
// в таблице direct) — иначе гейт «есть правило» закрывает починку навсегда после половинчатого
// первого ifup. Подробно: [[0004-multi-protocol-tiers]] (п.2). Номер таблицы — из плана, не зашит.
function render_hotplug(table) {
	return join("\n", [
		"#!/bin/sh",
		"# cheburnet: вернуть ip-часть data-plane (policy-routing) — она живёт только в ядре.",
		"# Файл создаёт шаг firewall; правки перезапишутся при следующем применении.",
		'[ "$ACTION" = "ifup" ] || exit 0',
		"# Оба артефакта на месте — выходим сразу (дешёвый путь на каждый ifup).",
		sprintf("if ip rule show 2>/dev/null | grep -q fwmark && \\"),
		sprintf("   ip route show table %d 2>/dev/null | grep -q default; then", table),
		"\texit 0",
		"fi",
		"ucode -R /usr/share/cheburnet/engine/install/reapply.uc >/dev/null 2>&1",
		"exit 0",
	]) + "\n";
}

// build_firewall_plan(routing_plan, opts) → структурный план (nft/ip/uci).
// ИНВАРИАНТ: kill-switch ключуется по oifname WAN, не по LAN-CIDR (хардкод CIDR — тихо-дырявый
// kill-switch на нестандартной подсети, урок v1). wan_if — из routing_plan.opts, не хардкод.
function build_firewall_plan(routing_plan, opts) {
	let o = resolve_opts(opts);
	let ro = routing_plan.opts;
	let wan = ro.wan_if;
	let errors = [];

	if (o.killswitch && !wan)
		push(errors, "нет wan_if: kill-switch не построить без WAN-интерфейса (не хардкодим)");

	let nft = render_nft_file(routing_plan, o);

	// policy routing: правило fwmark + default в table через WAN (из routing). Teardown —
	// снять правило и очистить таблицу (ip rule add не идемпотентен → del перед add).
	let ip_setup = render_iprules(routing_plan);
	let ip_teardown = [];
	if (ro.mode != "travel") {
		push(ip_teardown, sprintf("ip rule del fwmark %s lookup %d", ro.mark, ro.table));
		if (ro.ipv6)
			push(ip_teardown, sprintf("ip -6 rule del fwmark %s lookup %d", ro.mark, ro.table));
		push(ip_teardown, sprintf("ip route flush table %d", ro.table));
		if (ro.ipv6)
			push(ip_teardown, sprintf("ip -6 route flush table %d", ro.table));
	}

	// NAT-зона туннеля (uci firewall, чистый откат). Выключаемо через fw_opts.nat=false.
	let nat = o.nat ? build_nat_ops(o) : { teardown: [], setup: [] };

	// ШРАМ (smoke): fw4 reload не удаляет чужие цепочки/сеты из inet fw4 — после unlink файла
	// остаются пустые hooked-цепочки. Снимаем явно, все 4 имени (могла создать прошлая установка).
	let nft_teardown = [
		sprintf("delete chain inet fw4 %s", o.mark_chain),
		sprintf("delete chain inet fw4 %s", o.ks_chain),
		sprintf("delete set inet fw4 %s", ro.set4),
		sprintf("delete set inet fw4 %s", ro.set6),
	];

	return {
		ok: length(errors) == 0,
		errors: errors,
		uci_teardown: nat.teardown,
		uci_setup: nat.setup,
		nft_path: NFT_PATH,
		nft_file: nft.content,
		hotplug_path: HOTPLUG_PATH,
		hotplug_file: render_hotplug(ro.table),
		nft_teardown: nft_teardown,
		ip_teardown: ip_teardown,
		ip_setup: ip_setup,
		killswitch: nft.killswitch,
	};
}

export { NFT_PATH, HOTPLUG_PATH, build_nat_ops, render_nft_file, render_hotplug, build_firewall_plan };
