// test_install.uc — юнит-тесты политики оркестрации установки. Без роутера.
//   ucode -R engine/install/tests/test_install.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { all_steps, enabled_steps, snapshot_scope, dirty_steps,
         decide_outcome } from "../install.uc";

function names(steps) {
	let out = [];
	for (let i = 0; i < length(steps); i++) push(out, steps[i].name);
	return out;
}

test("порядок шагов: vpn → dns → doh → wifi → firewall (firewall последним)", () => {
	deep_eq(names(all_steps()), [ "vpn", "dns", "doh", "wifi", "firewall" ]);
});

test("enabled_steps: disable убирает шаг, порядок сохраняется", () => {
	let s = enabled_steps({ disable: [ "adblock", "doh" ] });
	deep_eq(names(s), [ "vpn", "dns", "wifi", "firewall" ]);
});

test("all_steps возвращает копию (мутация не ломает реестр)", () => {
	let a = all_steps();
	a[0].name = "HACKED";
	push(a[0].configs, "x");
	let b = all_steps();
	eq(b[0].name, "vpn");
	deep_eq(b[0].configs, [ "network" ]);
});

test("snapshot_scope: объединение чистых конфигов, дедуп; uci-часть dirty-шага входит", () => {
	let scope = snapshot_scope(all_steps());
	// dhcp встречается у dns/doh/adblock → один раз; wifi вносит wireless; firewall (dirty)
	// вносит uci 'firewall' (NAT-зона — чистый откат), его nft/ip-часть — teardown, не snapshot
	deep_eq(scope, [ "network", "dhcp", "https-dns-proxy", "wireless", "firewall" ]);
});

test("snapshot_scope: при отключённом vpn нет network", () => {
	let scope = snapshot_scope(enabled_steps({ disable: [ "vpn" ] }));
	deep_eq(scope, [ "dhcp", "https-dns-proxy", "wireless", "firewall" ]);
});

test("dirty_steps: только firewall (runtime nft/ip → safe-fail teardown)", () => {
	deep_eq(dirty_steps(all_steps()), [ "firewall" ]);
});

// --- decide_outcome ---
test("decide: нет/проваленный preflight → abort (ничего не трогали)", () => {
	eq(decide_outcome({ preflight: { ok: false } }).action, "abort");
	eq(decide_outcome({}).action, "abort");
	eq(decide_outcome(null).action, "abort");
});

test("decide: упавший шаг → rollback + список failed", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true }, { name: "dns", ok: false }, { name: "doh", ok: false } ],
	});
	eq(d.action, "rollback");
	deep_eq(d.failed, [ "dns", "doh" ]);
});

test("decide: все шаги ок, health провалился → rollback", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true } ],
		health: { ok: false },
	});
	eq(d.action, "rollback");
	ok(index(d.reason, "health") >= 0);
});

test("decide: всё ок → commit", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true }, { name: "firewall", ok: true } ],
		health: { ok: true },
	});
	eq(d.action, "commit");
	deep_eq(d.failed, []);
});

test("decide: шаги ок, health не дошёл (null) → commit", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true } ],
		health: null,
	});
	eq(d.action, "commit");
});

exit(summary());
