// test_install.uc — юнит-тесты политики оркестрации установки. Без роутера.
//   ucode -R engine/install/tests/test_install.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { route_uses_iface,
         all_steps, enabled_steps, snapshot_scope, dirty_steps,
         decide_outcome, protocol_ids, default_protocol, tunnel_info,
         disabled_tunnels, handshake_state } from "../install.uc";

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

test("snapshot_scope: reality-протокол (vpn off, singbox on) → sing-box + network (маршрут в туннель)", () => {
	// reality: disable vpn (через disabled_tunnels), остаётся singbox. Его configs — sing-box И
	// network (netifd-маршрут в singtun): обе uci-части откатываются snapshot'ом (гибридный шаг).
	let scope = snapshot_scope(enabled_steps({ disable: [ "vpn" ] }));
	deep_eq(scope, [ "sing-box", "network", "dhcp", "https-dns-proxy", "wireless", "firewall" ]);
});

test("dirty_steps: singbox + firewall (runtime config.json/nft/ip → safe-fail teardown)", () => {
	deep_eq(dirty_steps(all_steps()), [ "singbox", "firewall" ]);
});

// КРИТИЧНО для чистой смены протокола: перед шагами run.uc делает teardown НЕактивного туннеля
// (awg0 при reality и наоборот) — он мутирует network. Значит network ОБЯЗАН быть в snapshot-
// scope при ЛЮБОМ активном протоколе, иначе откат не вернёт снятый туннель. Проверяем оба.
test("snapshot_scope: network защищён при обоих протоколах (иначе смена протокола не откатна)", () => {
	let awg = snapshot_scope(enabled_steps({ disable: disabled_tunnels("awg") }));
	ok(index(awg, "network") >= 0, "awg: network в снимке (vpn.configs)");
	let reality = snapshot_scope(enabled_steps({ disable: disabled_tunnels("reality") }));
	ok(index(reality, "network") >= 0, "reality: network в снимке (singbox.configs)");
});

// Teardown неактивного туннеля адресуется по имени ШАГА (vpn/singbox) — у обоих есть --teardown.
// Если сюда попадёт не-туннельный шаг, run.uc дёрнул бы у него несуществующий режим.
test("disabled_tunnels возвращает только туннель-шаги (у них есть --teardown)", () => {
	let protos = [ "awg", "reality" ];
	for (let i = 0; i < length(protos); i++) {
		let dt = disabled_tunnels(protos[i]);
		for (let j = 0; j < length(dt); j++)
			ok(index([ "vpn", "singbox" ], dt[j]) >= 0,
				sprintf("%s: '%s' — туннель-шаг", protos[i], dt[j]));
	}
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
	eq(decide_outcome({ preflight: { ok: false } }).code, "preflight");
	eq(decide_outcome({}).action, "abort");
	eq(decide_outcome(null).action, "abort");
});

test("decide: упавший шаг → rollback + список failed + code первого упавшего", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true }, { name: "dns", ok: false }, { name: "doh", ok: false } ],
	});
	eq(d.action, "rollback");
	deep_eq(d.failed, [ "dns", "doh" ]);
	eq(d.code, "step:dns"); // адресная диагностика UI — по ПЕРВОМУ упавшему (fail-fast)
});

test("decide: все шаги ок, health провалился → rollback", () => {
	let d = decide_outcome({
		preflight: { ok: true },
		steps: [ { name: "vpn", ok: true } ],
		health: { ok: false },
	});
	eq(d.action, "rollback");
	eq(d.code, "health"); // UI по этому коду говорит «VPN-сервер не ответил», не «упал шаг»
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

// --- handshake_state (fix #2: health-check поллит рукопожатие, а не валит мгновенно) ---
test("handshake_state: пустой вывод → none (vpn не настраивался — health не валим)", () => {
	eq(handshake_state(""), "none");
	eq(handshake_state("  \n "), "none");
	eq(handshake_state(null), "none");
});

test("handshake_state: peer есть, рукопожатия ещё нет ('\\t0') → waiting (поллить дальше)", () => {
	// именно этот кейс ловил баг: мгновенная проверка видела waiting и откатывала установку
	eq(handshake_state("dCtNRb28Iu+YT2OWBnfFQTXJ79C4NhWeQTU5+hV3zG8=\t0"), "waiting");
});

test("handshake_state: peer с ненулевым timestamp → up", () => {
	eq(handshake_state("dCtNRb28Iu+YT2OWBnfFQTXJ79C4NhWeQTU5+hV3zG8=\t1782814714"), "up");
	// timestamp, оканчивающийся на 0 (не '\t0'), — рукопожатие было, не ложный waiting
	eq(handshake_state("AAA=\t1782814710"), "up");
});

test("handshake_state: несколько peer — любой с ненулевым timestamp → up", () => {
	eq(handshake_state("AAA=\t0\nBBB=\t0"), "waiting", "ни один peer не сделал рукопожатие");
	eq(handshake_state("AAA=\t1782814700\nBBB=\t0"), "up", "первый peer с рукопожатием");
	eq(handshake_state("AAA=\t0\nBBB=\t1782814700"), "up", "второй peer с рукопожатием");
});

// --- route_uses_iface (чистая часть connectivity-probe reality) ---
test("route_uses_iface: маршрут через туннель → true (dev-токен, не подстрока)", () => {
	ok(route_uses_iface("1.1.1.1 dev singtun0 src 172.19.0.1 uid 0 \n    cache", "singtun0"));
	ok(route_uses_iface("1.1.1.1 via 10.0.0.1 dev singtun0 src 172.19.0.1", "singtun0"));
});

test("route_uses_iface: маршрут утёк на WAN → false (мёртвый туннель не выдаём за рабочий)", () => {
	ok(!route_uses_iface("1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.2", "singtun0"));
});

test("route_uses_iface: точное совпадение имени (dev singtun00 ≠ singtun0)", () => {
	ok(!route_uses_iface("1.1.1.1 dev singtun00 src x", "singtun0"));
});

test("route_uses_iface: пустой вход / пустой iface → false (fail-safe)", () => {
	ok(!route_uses_iface("", "singtun0"));
	ok(!route_uses_iface(null, "singtun0"));
	ok(!route_uses_iface("1.1.1.1 dev singtun0", ""));
});

exit(summary());
