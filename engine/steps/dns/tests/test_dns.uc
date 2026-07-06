// test_dns.uc — юнит-тесты идемпотентного DNS-шага (модель `config ipset`). Без роутера.
//   ucode -R engine/steps/dns/tests/test_dns.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_plan } from "../../../routing/routing.uc";
import { owned_sections, build_dns_plan } from "../dns.uc";

// Удобный конструктор routing-плана (v4-only для краткости проверок).
function rplan(domains) {
	return build_plan(domains, { ipv6: false });
}

test("owned_sections: имена наших секций", () => {
	deep_eq(owned_sections(null), ["cheburnet_dns4", "cheburnet_dns6"]);
});

test("чистая система: создание v4-секции + noresolv (family явно)", () => {
	let plan = build_dns_plan(rplan(["example.com", "example.org"]),
		{ sections: {}, options: {} }, null);
	ok(plan.changed);
	deep_eq(plan.ops, [
		"set dhcp.cheburnet_dns4=ipset",
		"set dhcp.cheburnet_dns4.table='fw4'",
		"set dhcp.cheburnet_dns4.table_family='inet'",
		"set dhcp.cheburnet_dns4.family='4'",
		"add_list dhcp.cheburnet_dns4.name='direct'",
		"add_list dhcp.cheburnet_dns4.domain='example.com'",
		"add_list dhcp.cheburnet_dns4.domain='example.org'",
		"set dhcp.@dnsmasq[0].noresolv='1'",
	]);
});

test("ipv6=true → вторая секция с family='6' и сетом direct6", () => {
	let rp = build_plan(["example.com"], {});
	let plan = build_dns_plan(rp, { sections: {}, options: { noresolv: "1" } }, null);
	deep_eq(plan.ops, [
		"set dhcp.cheburnet_dns4=ipset",
		"set dhcp.cheburnet_dns4.table='fw4'",
		"set dhcp.cheburnet_dns4.table_family='inet'",
		"set dhcp.cheburnet_dns4.family='4'",
		"add_list dhcp.cheburnet_dns4.name='direct'",
		"add_list dhcp.cheburnet_dns4.domain='example.com'",
		"set dhcp.cheburnet_dns6=ipset",
		"set dhcp.cheburnet_dns6.table='fw4'",
		"set dhcp.cheburnet_dns6.table_family='inet'",
		"set dhcp.cheburnet_dns6.family='6'",
		"add_list dhcp.cheburnet_dns6.name='direct6'",
		"add_list dhcp.cheburnet_dns6.domain='example.com'",
	]);
});

test("зонная запись: однометочный домен (TLD) валиден и попадает в секцию", () => {
	let plan = build_dns_plan(rplan(["ru"]), { sections: {}, options: { noresolv: "1" } }, null);
	deep_eq(plan.ops, [
		"set dhcp.cheburnet_dns4=ipset",
		"set dhcp.cheburnet_dns4.table='fw4'",
		"set dhcp.cheburnet_dns4.table_family='inet'",
		"set dhcp.cheburnet_dns4.family='4'",
		"add_list dhcp.cheburnet_dns4.name='direct'",
		"add_list dhcp.cheburnet_dns4.domain='ru'",
	]);
});

test("идемпотентность: уже применённое состояние → пустой план (no-op)", () => {
	let current = {
		sections: {
			cheburnet_dns4: { name: ["direct"], domain: ["example.com"], family: "4" },
		},
		options: { noresolv: "1" },
	};
	let plan = build_dns_plan(rplan(["example.com"]), current, null);
	ok(!plan.changed, "повторный запуск ничего не меняет");
	deep_eq(plan.ops, []);
});

test("diff: смена списка доменов → секция пересоздаётся (delete-before-set)", () => {
	let current = {
		sections: {
			cheburnet_dns4: { name: ["direct"], domain: ["old.example"], family: "4" },
		},
		options: { noresolv: "1" },
	};
	let plan = build_dns_plan(rplan(["new.example"]), current, null);
	deep_eq(plan.ops, [
		"delete dhcp.cheburnet_dns4",
		"set dhcp.cheburnet_dns4=ipset",
		"set dhcp.cheburnet_dns4.table='fw4'",
		"set dhcp.cheburnet_dns4.table_family='inet'",
		"set dhcp.cheburnet_dns4.family='4'",
		"add_list dhcp.cheburnet_dns4.name='direct'",
		"add_list dhcp.cheburnet_dns4.domain='new.example'",
	]);
});

test("travel-режим: direct-доменов нет → наши секции сносятся", () => {
	let rp = build_plan(["example.com"], { ipv6: false, mode: "travel" });
	let current = {
		sections: {
			cheburnet_dns4: { name: ["direct"], domain: ["example.com"], family: "4" },
		},
		options: { noresolv: "1" },
	};
	let plan = build_dns_plan(rp, current, null);
	deep_eq(plan.ops, [ "delete dhcp.cheburnet_dns4" ]);
});

test("пустой список доменов: секций не создаём, delete не эмитим (её и нет)", () => {
	let plan = build_dns_plan(rplan([]), { sections: {}, options: { noresolv: "1" } }, null);
	ok(!plan.changed);
	deep_eq(plan.ops, []);
});

test("noresolv уже выставлен → трогаем только секции", () => {
	let plan = build_dns_plan(rplan(["example.com"]),
		{ sections: {}, options: { noresolv: "1" } }, null);
	eq(plan.ops[length(plan.ops) - 1],
		"add_list dhcp.cheburnet_dns4.domain='example.com'",
		"последняя операция — домен, noresolv не трогали");
});

exit(summary());
