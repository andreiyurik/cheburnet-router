// firewall.uc — data-plane шаг: пометка direct-трафика, policy routing и kill-switch.
//
// Это production-применение split-routing на роутере (форвард-трафик LAN-клиентов):
//   • наша prerouting-цепочка метит пакеты с daddr ∈ direct  → [[policy-routing]]
//   • ip rule/route разводят помеченное в WAN, остальное в туннель
//   • kill-switch роняет непрямой трафик, утекающий в WAN мимо туннеля → [[kill-switch]]
//
// ЧИСТОЕ ЯДРО: build_firewall_plan(routing_plan, opts) → списки nft/ip команд (setup+teardown).
// Применение (nft -f, ip) — в apply.uc (импурно, QEMU). Сходимость здесь — ПЕРЕ-применением
// (teardown+setup), не минимальным diff: состояние ядра (nft/ip) не откатывается чисто, как
// UCI, — честный safe-fail вместо иллюзии транзакции (см. reliability.md).

import { render_sets, render_mark_rules, render_iprules } from "../../routing/routing.uc";

// Свои hooked-цепочки в inet fw4: их можно целиком удалить (clean teardown), не задев правил
// fw4. Сеты НЕ в этом списке — их не удаляем (в них живут адреса от dnsmasq).
const FW_DEFAULTS = {
	mark_chain: "cheburnet_mark", // type filter hook prerouting priority mangle
	ks_chain: "cheburnet_ks",     // type filter hook forward   priority filter
	killswitch: true,
	// NAT-зона туннеля (uci firewall): masq на awg0 + forwarding lan→vpn. Без неё LAN-трафик
	// уходит в туннель без SNAT/forwarding и не возвращается (роутер «зелёный, но не везёт»).
	nat: true,
	tunnel_if: "awg0", // интерфейс туннеля (совпадает с vpn-шагом)
	lan_zone: "lan",   // имя LAN-зоны fw4 (стандартное); forwarding по ИМЕНИ зоны, не по CIDR
	vpn_zone: "vpn",   // имя создаваемой зоны туннеля
};

function resolve_opts(opts) {
	let o = {};
	for (let k in FW_DEFAULTS) o[k] = FW_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(FW_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// build_nat_ops(opts) → { teardown, setup } — uci firewall: зона туннеля (masq + mtu_fix) и
// forwarding lan→vpn. Именованные секции (cheburnet_<zone>) → идемпотентность через delete-before-set
// (как peer-секция в vpn-шаге). Это ЧИСТЫЙ uci-конфиг: откатывается snapshot'ом (firewall ∈
// CLEAN_CONFIGS), в отличие от nft/ip ниже. Применять ДО nft-инъекции: fw4 reload пересобирает
// таблицу inet fw4 и стёр бы наши цепочки, если бы шёл после них (см. apply.uc).
//   masq=1   — SNAT трафика LAN-клиентов, ушедшего в awg0 (без него обратный путь не находится);
//   mtu_fix=1 — MSS-clamp под MTU туннеля; input REJECT — извне в роутер по туннелю не лезут.
function build_nat_ops(opts) {
	let o = opts ?? {};
	let tif  = o.tunnel_if ?? "awg0";
	let lan  = o.lan_zone ?? "lan";
	let zone = o.vpn_zone ?? "vpn";
	let zsect = "cheburnet_" + zone;            // именованная секция zone
	let fsect = "cheburnet_" + lan + "_" + zone; // именованная секция forwarding

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

// build_firewall_plan(routing_plan, opts) → структурный план.
// wan_if берётся из routing_plan.opts (его кладёт gather/preflight) и НЕ хардкодится — это
// прямой урок v1: хардкод LAN/WAN = тихо-дырявый kill-switch на нестандартной подсети.
// kill-switch ключуется по oifname WAN, а не по LAN-CIDR → вообще не зависит от подсети.
function build_firewall_plan(routing_plan, opts) {
	let o = resolve_opts(opts);
	let ro = routing_plan.opts;
	let fam = ro.family, tbl = ro.fw_table, wan = ro.wan_if;
	let errors = [];

	if (o.killswitch && !wan)
		push(errors, "нет wan_if: kill-switch не построить без WAN-интерфейса (не хардкодим)");

	// teardown: удалить наши цепочки (сбрасывает их правила). Сеты не трогаем.
	let nft_teardown = [ sprintf("delete chain %s %s %s", fam, tbl, o.mark_chain) ];
	if (o.killswitch)
		push(nft_teardown, sprintf("delete chain %s %s %s", fam, tbl, o.ks_chain));

	// setup: сеты (идемпотентно) + prerouting-цепочка пометки + правила пометки.
	let nft_setup = render_sets(routing_plan);
	push(nft_setup, sprintf("add chain %s %s %s { type filter hook prerouting priority mangle; }",
		fam, tbl, o.mark_chain));
	let marks = render_mark_rules(routing_plan, o.mark_chain);
	for (let i = 0; i < length(marks); i++)
		push(nft_setup, marks[i]);

	// kill-switch в forward-цепочке. ct state new: рубим только новые соединения наружу мимо
	// туннеля; established (обратный трафик уже разрешённого) проходит. AWG-handshake — это
	// output роутера, не forward, поэтому kill-switch его не задевает.
	let ks = [];
	if (o.killswitch && wan) {
		push(nft_setup, sprintf("add chain %s %s %s { type filter hook forward priority filter; }",
			fam, tbl, o.ks_chain));
		if (ro.mode == "travel")
			// нет direct-исключений: всё в WAN — drop (через awg0 разрешено неявно: oifname != wan)
			push(ks, sprintf("add rule %s %s %s oifname \"%s\" ct state new drop",
				fam, tbl, o.ks_chain, wan));
		else
			// непомеченное (не direct), уходящее в WAN, — drop; direct (mark) и туннель проходят
			push(ks, sprintf("add rule %s %s %s oifname \"%s\" meta mark != %s ct state new drop",
				fam, tbl, o.ks_chain, wan, ro.mark));
		for (let i = 0; i < length(ks); i++)
			push(nft_setup, ks[i]);
	}

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

	return {
		ok: length(errors) == 0,
		errors: errors,
		uci_teardown: nat.teardown,
		uci_setup: nat.setup,
		nft_teardown: nft_teardown,
		nft_setup: nft_setup,
		ip_teardown: ip_teardown,
		ip_setup: ip_setup,
		killswitch: ks,
	};
}

export { build_nat_ops, build_firewall_plan };
