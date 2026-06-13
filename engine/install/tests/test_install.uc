// test_install.uc — юнит-тесты политики оркестрации установки. Без роутера.
//   ucode -R engine/install/tests/test_install.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { all_steps, enabled_steps, snapshot_scope, dirty_steps,
         decide_outcome, protocol_ids, default_protocol, tunnel_info,
         disabled_tunnels } from "../install.uc";

function names(steps) {
	let out = [];
	for (let i = 0; i < length(steps); i++) push(out, steps[i].name);
	return out;
}

test("порядок шагов: vpn → singbox → dns → doh → wifi → firewall (firewall последним)", () => {
	deep_eq(names(all_steps()), [ "vpn", "singbox", "dns", "doh", "wifi", "firewall" ]);
});

test("enabled_steps: disable убирает шаг, порядок сохраняется", () => {
	let s = enabled_steps({ disable: [ "singbox", "doh" ] });
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
	// dhcp у dns/doh → один раз; singbox вносит sing-box (uci-часть — чистый откат); wifi —
	// wireless; firewall (dirty) — uci 'firewall' (NAT-зона), его nft/ip-часть — teardown, не snapshot
	deep_eq(scope, [ "network", "sing-box", "dhcp", "https-dns-proxy", "wireless", "firewall" ]);
});

test("snapshot_scope: reality-протокол (vpn off, singbox on) → sing-box вместо network", () => {
	// reality: disable vpn (через disabled_tunnels), остаётся singbox
	let scope = snapshot_scope(enabled_steps({ disable: [ "vpn" ] }));
	deep_eq(scope, [ "sing-box", "dhcp", "https-dns-proxy", "wireless", "firewall" ]);
});

test("dirty_steps: singbox + firewall (runtime config.json/nft/ip → safe-fail teardown)", () => {
	deep_eq(dirty_steps(all_steps()), [ "singbox", "firewall" ]);
});

// --- модель протокола (две оси покрытия, ADR 0004) ---
test("protocol_ids / default_protocol: awg (дефолт) и reality", () => {
	deep_eq(protocol_ids(), [ "awg", "reality" ]);
	eq(default_protocol(), "awg");
});

test("tunnel_info: awg→vpn/awg0, reality→singbox/singtun0, неизвестный→дефолт", () => {
	deep_eq(tunnel_info("awg"), { step: "vpn", tunnel_if: "awg0" });
	deep_eq(tunnel_info("reality"), { step: "singbox", tunnel_if: "singtun0" });
	deep_eq(tunnel_info("bogus"), { step: "vpn", tunnel_if: "awg0" }, "fail-safe на дефолт");
});

test("disabled_tunnels: отключает неактивный туннель-шаг (взаимоисключение)", () => {
	deep_eq(disabled_tunnels("awg"), [ "singbox" ], "awg → singbox off");
	deep_eq(disabled_tunnels("reality"), [ "vpn" ], "reality → vpn off");
});

test("enabled_steps: awg-протокол (disable singbox) → туннель = vpn", () => {
	let s = enabled_steps({ disable: disabled_tunnels("awg") });
	deep_eq(names(s), [ "vpn", "dns", "doh", "wifi", "firewall" ]);
});

test("enabled_steps: reality-протокол (disable vpn) → туннель = singbox", () => {
	let s = enabled_steps({ disable: disabled_tunnels("reality") });
	deep_eq(names(s), [ "singbox", "dns", "doh", "wifi", "firewall" ]);
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
