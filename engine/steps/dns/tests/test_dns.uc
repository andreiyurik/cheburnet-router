// test_dns.uc — юнит-тесты идемпотентного DNS-шага. Без роутера.
//   ucode -R engine/steps/dns/tests/test_dns.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_plan } from "../../../routing/routing.uc";
import { build_dns_plan } from "../dns.uc";

// Удобный конструктор routing-плана (v4-only для краткости проверок).
function rplan(domains) {
	return build_plan(domains, { ipv6: false });
}

test("чистая система: add_list всех желаемых + noresolv", () => {
	let plan = build_dns_plan(rplan(["example.com", "example.org"]),
		{ nftset: [], options: {} }, null);
	ok(plan.changed);
	deep_eq(plan.add, [
		"/example.com/4#inet#fw4#direct",
		"/example.org/4#inet#fw4#direct",
	]);
	deep_eq(plan.remove, []);
	deep_eq(plan.ops, [
		"add_list dhcp.@dnsmasq[0].nftset='/example.com/4#inet#fw4#direct'",
		"add_list dhcp.@dnsmasq[0].nftset='/example.org/4#inet#fw4#direct'",
		"set dhcp.@dnsmasq[0].noresolv='1'",
	]);
});

test("идемпотентность: уже применённое состояние → пустой план (no-op)", () => {
	let current = {
		nftset: [ "/example.com/4#inet#fw4#direct" ],
		options: { noresolv: "1" },
	};
	let plan = build_dns_plan(rplan(["example.com"]), current, null);
	ok(!plan.changed, "повторный запуск ничего не меняет");
	deep_eq(plan.ops, []);
});

test("diff: добавить новый домен, убрать ушедший", () => {
	let current = {
		nftset: [ "/old.example/4#inet#fw4#direct" ],
		options: { noresolv: "1" },
	};
	let plan = build_dns_plan(rplan(["new.example"]), current, null);
	deep_eq(plan.add, [ "/new.example/4#inet#fw4#direct" ]);
	deep_eq(plan.remove, [ "/old.example/4#inet#fw4#direct" ]);
});

test("чужие nftset-записи не трогаем", () => {
	// запись в другой set (не наш direct/direct6) должна остаться нетронутой
	let current = {
		nftset: [
			"/example.com/4#inet#fw4#direct",       // наша, желаемая → остаётся
			"/foo.bar/4#inet#fw4#someoneelse",        // чужой set → НЕ в remove
		],
		options: { noresolv: "1" },
	};
	let plan = build_dns_plan(rplan(["example.com"]), current, null);
	deep_eq(plan.add, []);
	deep_eq(plan.remove, [], "чужую запись не удаляем");
	ok(!plan.changed);
});

test("noresolv уже выставлен, меняются только nftset", () => {
	let current = { nftset: [], options: { noresolv: "1" } };
	let plan = build_dns_plan(rplan(["example.com"]), current, null);
	deep_eq(plan.ops, [
		"add_list dhcp.@dnsmasq[0].nftset='/example.com/4#inet#fw4#direct'",
	]);
});

test("кастомная секция dnsmasq прокидывается", () => {
	let plan = build_dns_plan(rplan(["example.com"]),
		{ nftset: [], options: { noresolv: "1" } }, { section: "cfg01" });
	deep_eq(plan.ops, [
		"add_list dhcp.cfg01.nftset='/example.com/4#inet#fw4#direct'",
	]);
});

test("travel-режим: желаемых nftset нет → наши удаляются", () => {
	let rp = build_plan(["example.com"], { ipv6: false, mode: "travel" });
	let current = {
		nftset: [ "/example.com/4#inet#fw4#direct" ],
		options: { noresolv: "1" },
	};
	let plan = build_dns_plan(rp, current, null);
	deep_eq(plan.remove, [ "/example.com/4#inet#fw4#direct" ]);
	deep_eq(plan.add, []);
});

exit(summary());
