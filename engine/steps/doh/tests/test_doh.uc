// test_doh.uc — юнит-тесты DoH-шага. Без роутера.
//   ucode -R engine/steps/doh/tests/test_doh.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_doh_plan, listen_prefix } from "../doh.uc";

function has(arr, s) {
	for (let i = 0; i < length(arr); i++) if (arr[i] == s) return true;
	return false;
}

// --- дефолтные резолверы: Quad9 + Cloudflare ---
test("дефолт: секции quad9/cloudflare с портами 5053/5054", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	ok(p.ok);
	ok(has(p.hdp_setup, "set https-dns-proxy.quad9=https-dns-proxy"));
	ok(has(p.hdp_setup, "set https-dns-proxy.quad9.listen_port='5053'"));
	ok(has(p.hdp_setup, "set https-dns-proxy.quad9.resolver_url='https://dns.quad9.net/dns-query'"));
	ok(has(p.hdp_setup, "set https-dns-proxy.cloudflare.listen_port='5054'"));
	ok(has(p.hdp_setup, "set https-dns-proxy.quad9.bootstrap_dns='9.9.9.9,149.112.112.112'"));
});

test("сами рулим dnsmasq: update_dnsmasq_config='-'", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	ok(has(p.hdp_setup, "set https-dns-proxy.config.update_dnsmasq_config='-'"));
});

// --- dnsmasq upstream: свежая система → add обоих ---
test("dnsmasq upstream: чистая система → add_list обоих локальных портов", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, null);
	deep_eq(p.dnsmasq_ops, [
		"add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'",
		"add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'",
	]);
});

// --- идемпотентность upstream: уже настроено → no-op ---
test("dnsmasq upstream: уже настроено → пустой diff", () => {
	let p = build_doh_plan({
		hdp_sections: [ "quad9", "cloudflare" ],
		servers: [ "127.0.0.1#5053", "127.0.0.1#5054" ],
	}, null);
	deep_eq(p.dnsmasq_ops, []);
});

// --- чужой upstream пользователя не трогаем ---
test("чужой upstream-сервер (не 127.0.0.1#) сохраняется", () => {
	let p = build_doh_plan({
		hdp_sections: [],
		servers: [ "8.8.8.8", "127.0.0.1#5053", "127.0.0.1#5054" ],
	}, null);
	deep_eq(p.dnsmasq_ops, [], "наши уже на месте, чужой 8.8.8.8 не в remove");
});

// --- замена дефолтной секции пакета (конфликт по порту) ---
test("teardown сносит существующие секции пакета + наши имена (чистая замена)", () => {
	let p = build_doh_plan({ hdp_sections: [ "cfg01" ], servers: [] }, null);
	ok(has(p.hdp_teardown, "delete https-dns-proxy.cfg01"), "дефолтная секция пакета снесена");
	ok(has(p.hdp_teardown, "delete https-dns-proxy.quad9"));
	ok(has(p.hdp_teardown, "delete https-dns-proxy.cloudflare"));
});

// --- кастомные резолверы заменяют дефолт ---
test("кастомный резолвер заменяет дефолт", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, {
		resolvers: [ { name: "mullvad", url: "https://dns.mullvad.net/dns-query", port: 5053 } ],
	});
	ok(has(p.hdp_setup, "set https-dns-proxy.mullvad.resolver_url='https://dns.mullvad.net/dns-query'"));
	ok(!has(p.hdp_setup, "set https-dns-proxy.quad9=https-dns-proxy"), "quad9 не появляется");
	deep_eq(p.dnsmasq_ops, [ "add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'" ]);
});

test("резолвер без bootstrap → строки bootstrap_dns нет", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, {
		resolvers: [ { name: "r1", url: "https://r1/dns-query", port: 5053 } ],
	});
	ok(index(join("\n", p.hdp_setup), "bootstrap_dns") < 0);
});

// --- manage_dnsmasq=false ---
test("manage_dnsmasq=false: строки update_dnsmasq_config нет", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, { manage_dnsmasq: false });
	ok(index(join("\n", p.hdp_setup), "update_dnsmasq_config") < 0);
});

// --- валидация ---
test("валидация: пустой список резолверов → ok=false", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, { resolvers: [] });
	ok(!p.ok);
});
test("валидация: дубль порта → ok=false", () => {
	let p = build_doh_plan({ hdp_sections: [], servers: [] }, {
		resolvers: [
			{ name: "a", url: "https://a/dns-query", port: 5053 },
			{ name: "b", url: "https://b/dns-query", port: 5053 },
		],
	});
	ok(!p.ok);
});

test("listen_prefix: префикс наших dnsmasq-upstream (источник для reset)", () => {
	eq(listen_prefix(), "127.0.0.1#");
});

exit(summary());
