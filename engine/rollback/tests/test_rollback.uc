// test_rollback.uc — юнит-тесты политики отката. Без роутера.
//   ucode -R engine/rollback/tests/test_rollback.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { protected_configs, is_clean_config, classify,
         plan_snapshot, decide } from "../rollback.uc";

test("is_clean_config: наши uci-конфиги чистые, прочее — нет", () => {
	ok(is_clean_config("network"));
	ok(is_clean_config("dhcp"));
	ok(is_clean_config("firewall"));
	ok(is_clean_config("https-dns-proxy"));
	ok(!is_clean_config("kmod-amneziawg"));
	ok(!is_clean_config("awg0-link"));
});

test("classify: clean для uci-конфига, dirty для всего прочего (честность)", () => {
	eq(classify("network").class, "clean");
	eq(classify("kmod-amneziawg").class, "dirty");
	eq(classify("runtime-service").class, "dirty");
	ok(length(classify("kmod-amneziawg").reason) > 0, "у dirty есть причина");
});

test("protected_configs: возвращает копию (мутация не ломает внутренний список)", () => {
	let a = protected_configs();
	push(a, "hacked");
	let b = protected_configs();
	ok(index(b, "hacked") < 0, "внутренний список не затронут");
});

test("plan_snapshot: по умолчанию — все защищаемые, ok", () => {
	let p = plan_snapshot(null);
	ok(p.ok);
	deep_eq(p.configs, [ "network", "dhcp", "firewall", "https-dns-proxy" ]);
});

test("plan_snapshot: грязная цель → ok=false с причиной, в configs не попадает", () => {
	let p = plan_snapshot([ "network", "kmod-amneziawg" ]);
	ok(!p.ok, "транзакцию для грязного не строим");
	ok(length(p.errors) >= 1);
	deep_eq(p.configs, [ "network" ], "только чистые");
});

test("plan_snapshot: подмножество чистых конфигов", () => {
	let p = plan_snapshot([ "dhcp", "firewall" ]);
	ok(p.ok);
	deep_eq(p.configs, [ "dhcp", "firewall" ]);
});

test("decide: ok → commit, иначе → rollback (fail-safe)", () => {
	eq(decide({ ok: true }), "commit");
	eq(decide({ ok: false }), "rollback");
	eq(decide(null), "rollback", "нет результата → откат");
	eq(decide({}), "rollback", "ok отсутствует → откат");
});

exit(summary());
