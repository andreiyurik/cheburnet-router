// test_firewall.uc — юнит-тесты data-plane шага. Фокус — содержимое kill-switch (security).
//   ucode -R engine/steps/firewall/tests/test_firewall.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_plan } from "../../../routing/routing.uc";
import { build_firewall_plan } from "../firewall.uc";

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
		"add rule inet fw4 cheburnet_ks oifname \"eth0\" meta mark != 0x1 ct state new drop",
	]);
	// LAN-подсеть нигде не упоминается — kill-switch от неё не зависит
	let joined = join("\n", p.nft_setup);
	ok(index(joined, "192.168") < 0, "нет хардкода LAN-подсети");
});

// --- kill-switch: TRAVEL строже (нет direct-исключений) ---
test("TRAVEL kill-switch: всё в WAN → drop, без mark-исключения", () => {
	let p = build_firewall_plan(rp({ mode: "travel" }), null);
	deep_eq(p.killswitch, [
		"add rule inet fw4 cheburnet_ks oifname \"eth0\" ct state new drop",
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
	ok(has(p.killswitch, "add rule inet fw4 cheburnet_ks oifname \"wwan0\" meta mark != 0x1 ct state new drop"));
});

// --- setup: сеты + наша prerouting-цепочка + правило пометки + ks-цепочка ---
test("nft_setup: сеты, цепочка пометки (prerouting), правило, ks-цепочка", () => {
	let p = build_firewall_plan(rp(null), null);
	ok(has(p.nft_setup, "add set inet fw4 direct { type ipv4_addr; flags interval; }"));
	ok(has(p.nft_setup, "add chain inet fw4 cheburnet_mark { type filter hook prerouting priority mangle; }"));
	ok(has(p.nft_setup, "add rule inet fw4 cheburnet_mark ip daddr @direct meta mark set 0x1"));
	ok(has(p.nft_setup, "add chain inet fw4 cheburnet_ks { type filter hook forward priority filter; }"));
});

// --- teardown: удаляем НАШИ цепочки, сеты не трогаем ---
test("teardown удаляет наши цепочки, но НЕ сеты (в них живут адреса dnsmasq)", () => {
	let p = build_firewall_plan(rp(null), null);
	ok(has(p.nft_teardown, "delete chain inet fw4 cheburnet_mark"));
	ok(has(p.nft_teardown, "delete chain inet fw4 cheburnet_ks"));
	let joined = join("\n", p.nft_teardown);
	ok(index(joined, "delete set") < 0, "сеты не удаляем");
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
	ok(index(join("\n", p.nft_setup), "meta mark set") < 0, "правил пометки нет");
});

// --- IPv6: v6 сет/правило пометки появляются, ks остаётся одним inet-правилом ---
test("ipv6: добавляются v6 сет и правило пометки; ks по-прежнему одно", () => {
	let p = build_firewall_plan(build_plan([ "example.com" ], { ipv6: true, wan_if: "eth0" }), null);
	ok(has(p.nft_setup, "add set inet fw4 direct6 { type ipv6_addr; flags interval; }"));
	ok(has(p.nft_setup, "add rule inet fw4 cheburnet_mark ip6 daddr @direct6 meta mark set 0x1"));
	eq(length(p.killswitch), 1, "kill-switch — одно inet-правило на оба семейства");
	ok(has(p.ip_setup, "ip -6 rule add fwmark 0x1 lookup 100"));
});

// --- killswitch=false отключает ks (но пометка/маршрутизация остаются) ---
test("killswitch=false: ks-цепочки/правил нет, mark и ip остаются", () => {
	let p = build_firewall_plan(rp(null), { killswitch: false });
	eq(length(p.killswitch), 0);
	ok(index(join("\n", p.nft_setup), "cheburnet_ks") < 0);
	ok(has(p.nft_setup, "add rule inet fw4 cheburnet_mark ip daddr @direct meta mark set 0x1"));
});

exit(summary());
