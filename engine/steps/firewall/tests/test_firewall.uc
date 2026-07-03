// test_firewall.uc — юнит-тесты data-plane шага. Фокус — содержимое kill-switch (security).
//   ucode -R engine/steps/firewall/tests/test_firewall.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_plan } from "../../../routing/routing.uc";
import { build_firewall_plan, build_nat_ops } from "../firewall.uc";

// routing-план с заданным WAN (v4-only для краткости, если не сказано иначе).
function rp(extra) {
	let o = { ipv6: false, wan_if: "eth0" };
	if (extra) for (let k in extra) o[k] = extra[k];
	return build_plan([ "example.com" ], o);
}

function has(arr, s) {
	for (let i = 0; i < length(arr); i++) if (arr[i] == s) return true;
	return false;
}

// --- kill-switch: HOME ---
test("HOME kill-switch: непомеченное в WAN → drop, по oifname (не по LAN-CIDR)", () => {
	let p = build_firewall_plan(rp(null), null);
	ok(p.ok);
	deep_eq(p.killswitch, [
		"oifname \"eth0\" meta mark != 0x1 ct state new drop",
	]);
	// LAN-подсеть нигде не упоминается — kill-switch от неё не зависит
	ok(index(p.nft_file, "192.168") < 0, "нет хардкода LAN-подсети");
});

// --- kill-switch: TRAVEL строже (нет direct-исключений) ---
test("TRAVEL kill-switch: всё в WAN → drop, без mark-исключения", () => {
	let p = build_firewall_plan(rp({ mode: "travel" }), null);
	deep_eq(p.killswitch, [
		"oifname \"eth0\" ct state new drop",
	]);
});

// --- wan_if обязателен, не хардкодим ---
test("без wan_if: план.ok=false, kill-switch не строится", () => {
	let plan = build_plan([ "example.com" ], { ipv6: false }); // wan_if не задан
	let p = build_firewall_plan(plan, null);
	ok(!p.ok, "должен отказать");
	eq(length(p.killswitch), 0);
	ok(length(p.errors) >= 1);
});

// --- динамический WAN прокидывается в правило ---
test("kill-switch использует переданный wan_if (динамический)", () => {
	let p = build_firewall_plan(rp({ wan_if: "wwan0" }), null);
	ok(has(p.killswitch, "oifname \"wwan0\" meta mark != 0x1 ct state new drop"));
});

// --- nftables.d-файл: путь + сеты + цепочки + правила (декларативно, для fw4-include) ---
test("nft_file: путь /etc/nftables.d, сеты, цепочка пометки, правило, ks-цепочка", () => {
	let p = build_firewall_plan(rp(null), null);
	eq(p.nft_path, "/etc/nftables.d/10-cheburnet.nft");
	ok(index(p.nft_file, "set direct { type ipv4_addr; flags interval; }") >= 0);
	ok(index(p.nft_file, "chain cheburnet_mark {") >= 0);
	ok(index(p.nft_file, "type filter hook prerouting priority mangle;") >= 0);
	ok(index(p.nft_file, "ip daddr @direct meta mark set 0x1") >= 0);
	ok(index(p.nft_file, "chain cheburnet_ks {") >= 0);
	ok(index(p.nft_file, "type filter hook forward priority filter;") >= 0);
	// декларативный формат fw4-include: без императивных `add` и без обёртки `table` (её ставит fw4)
	ok(index(p.nft_file, "add rule") < 0 && index(p.nft_file, "add chain") < 0, "нет императивных add-команд");
	ok(index(p.nft_file, "table inet fw4 {") < 0, "нет обёртки table (её ставит fw4)");
});

// --- ip rule/route teardown+setup ---
test("ip setup из routing + teardown снимает правило и чистит таблицу", () => {
	let p = build_firewall_plan(rp(null), null);
	ok(has(p.ip_setup, "ip rule add fwmark 0x1 lookup 100"));
	ok(has(p.ip_setup, "ip route add default dev eth0 table 100"));
	ok(has(p.ip_teardown, "ip rule del fwmark 0x1 lookup 100"));
	ok(has(p.ip_teardown, "ip route flush table 100"));
});

// --- TRAVEL: нет ip-правил направления (всё в туннель main-таблицей) ---
test("TRAVEL: ip_setup и mark-правила пусты", () => {
	let p = build_firewall_plan(rp({ mode: "travel" }), null);
	deep_eq(p.ip_setup, []);
	ok(index(p.nft_file, "meta mark set") < 0, "правил пометки нет");
});

// --- IPv6: v6 сет/правило пометки появляются, ks остаётся одним inet-правилом ---
test("ipv6: добавляются v6 сет и правило пометки; ks по-прежнему одно", () => {
	let p = build_firewall_plan(build_plan([ "example.com" ], { ipv6: true, wan_if: "eth0" }), null);
	ok(index(p.nft_file, "set direct6 { type ipv6_addr; flags interval; }") >= 0);
	ok(index(p.nft_file, "ip6 daddr @direct6 meta mark set 0x1") >= 0);
	eq(length(p.killswitch), 1, "kill-switch — одно inet-правило на оба семейства");
	ok(has(p.ip_setup, "ip -6 rule add fwmark 0x1 lookup 100"));
});

// --- killswitch=false отключает ks (но пометка/маршрутизация остаются) ---
test("killswitch=false: ks-цепочки/правил нет, mark и ip остаются", () => {
	let p = build_firewall_plan(rp(null), { killswitch: false });
	eq(length(p.killswitch), 0);
	ok(index(p.nft_file, "cheburnet_ks") < 0);
	ok(index(p.nft_file, "ip daddr @direct meta mark set 0x1") >= 0);
});

// --- NAT-зона awg0: masq + forwarding lan→vpn (uci firewall, чистый откат) ---
test("build_nat_ops: именованные секции, masq, mtu_fix, forwarding lan→vpn", () => {
	let n = build_nat_ops({});
	// delete-before-set по именованным секциям → идемпотентность
	deep_eq(n.teardown, [ "delete firewall.cheburnet_vpn", "delete firewall.cheburnet_lan_vpn" ]);
	ok(has(n.setup, "set firewall.cheburnet_vpn=zone"));
	ok(has(n.setup, "set firewall.cheburnet_vpn.name='vpn'"));
	ok(has(n.setup, "add_list firewall.cheburnet_vpn.network='awg0'"));
	ok(has(n.setup, "set firewall.cheburnet_vpn.masq='1'"), "SNAT туннеля");
	ok(has(n.setup, "set firewall.cheburnet_vpn.mtu_fix='1'"), "MSS-clamp");
	ok(has(n.setup, "set firewall.cheburnet_lan_vpn=forwarding"));
	ok(has(n.setup, "set firewall.cheburnet_lan_vpn.src='lan'"));
	ok(has(n.setup, "set firewall.cheburnet_lan_vpn.dest='vpn'"));
});

test("build_nat_ops: имена интерфейса/зон переопределяемы (не хардкод)", () => {
	let n = build_nat_ops({ tunnel_if: "wg0", lan_zone: "guest", vpn_zone: "tun" });
	ok(has(n.setup, "add_list firewall.cheburnet_tun.network='wg0'"));
	ok(has(n.setup, "set firewall.cheburnet_guest_tun.src='guest'"));
	ok(has(n.setup, "set firewall.cheburnet_guest_tun.dest='tun'"));
});

test("build_firewall_plan: NAT включён по умолчанию, выключаем fw_opts.nat=false", () => {
	let on = build_firewall_plan(rp(null), null);
	ok(has(on.uci_setup, "set firewall.cheburnet_vpn.masq='1'"), "NAT в плане по умолчанию");
	deep_eq(on.uci_teardown, [ "delete firewall.cheburnet_vpn", "delete firewall.cheburnet_lan_vpn" ]);
	let off = build_firewall_plan(rp(null), { nat: false });
	deep_eq(off.uci_setup, [], "nat=false → нет uci-операций");
	deep_eq(off.uci_teardown, []);
});

exit(summary());
