// test_vpn.uc — юнит-тесты VPN-шага: парсер .conf + UCI-план. Без роутера.
//   ucode -R engine/steps/vpn/tests/test_vpn.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { parse_awg_conf, split_endpoint, build_vpn_plan, owned_sections } from "../vpn.uc";

// Типовой .conf с обфускацией и PSK (значения-заглушки, не настоящие ключи).
const CONF = "[Interface]\n" +
	"PrivateKey = aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvMDA=\n" +
	"Address = 10.9.0.2/32\n" +
	"Jc = 4\n" +
	"Jmin = 40\n" +
	"Jmax = 70\n" +
	"S1 = 100   # inline comment\n" +
	"H1 = 1234567890\n" +
	"MTU = 1380\n" +
	"\n" +
	"[Peer]\n" +
	"PublicKey = cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMDA=\n" +
	"PresharedKey = cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrMDA=\n" +
	"Endpoint = vpn.example.com:51820\n" +
	"AllowedIPs = 0.0.0.0/0, ::/0\n" +
	"PersistentKeepalive = 25\n";

function has(arr, s) {
	for (let i = 0; i < length(arr); i++) if (arr[i] == s) return true;
	return false;
}

// --- split_endpoint ---
test("split_endpoint: host:port, [ipv6]:port, мусор", () => {
	deep_eq(split_endpoint("1.2.3.4:51820"), { host: "1.2.3.4", port: "51820" });
	deep_eq(split_endpoint("vpn.example.com:443"), { host: "vpn.example.com", port: "443" });
	deep_eq(split_endpoint("[2001:db8::1]:51820"), { host: "2001:db8::1", port: "51820" });
	eq(split_endpoint("no-port"), null);
	eq(split_endpoint("host:notaport"), null);
});

// --- parser ---
test("parse_awg_conf: секции, обфускация, inline-комментарий, peer", () => {
	let p = parse_awg_conf(CONF);
	eq(p.interface.Address, "10.9.0.2/32");
	eq(p.interface.Jc, "4");
	eq(p.interface.S1, "100", "inline-комментарий отрезан");
	eq(length(p.peers), 1);
	eq(p.peers[0].Endpoint, "vpn.example.com:51820");
	eq(p.peers[0].PresharedKey, "cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrMDA=");
});
test("parse_awg_conf: PrivateKey с '=' в base64 не теряется", () => {
	let p = parse_awg_conf(CONF);
	eq(substr(p.interface.PrivateKey, length(p.interface.PrivateKey) - 1), "=");
});

// --- план: happy path ---
test("build_vpn_plan: интерфейс awg0, обфускация только присутствующая", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), {});
	ok(plan.ok);
	ok(has(plan.setup, "set network.awg0.proto='amneziawg'"));
	ok(has(plan.setup, "add_list network.awg0.addresses='10.9.0.2/32'"));
	ok(has(plan.setup, "set network.awg0.awg_jc='4'"));
	ok(has(plan.setup, "set network.awg0.awg_s1='100'"));
	ok(has(plan.setup, "set network.awg0.awg_h1='1234567890'"));
	ok(has(plan.setup, "set network.awg0.mtu='1380'"), "MTU из conf, не дефолт");
	// отсутствующих параметров (например S2/H2) в плане быть не должно
	ok(index(join("\n", plan.setup), "awg_s2") < 0, "S2 отсутствует → не пишем");
});

test("build_vpn_plan: route_allowed_ips='1' — туннель=дефолт (v2, netifd держит маршрут)", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), {});
	ok(has(plan.setup, "set network.awg0_peer.route_allowed_ips='1'"),
		"netifd ставит default через awg0 + пинит endpoint; direct вытягивает policy-routing (fail-safe в туннель)");
});

test("build_vpn_plan: peer — endpoint split, PSK, forced allowed_ips, keepalive", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), {});
	ok(has(plan.setup, "set network.awg0_peer.public_key='cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMDA='"));
	ok(has(plan.setup, "set network.awg0_peer.preshared_key='cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrMDA='"));
	ok(has(plan.setup, "set network.awg0_peer.endpoint_host='vpn.example.com'"));
	ok(has(plan.setup, "set network.awg0_peer.endpoint_port='51820'"));
	ok(has(plan.setup, "add_list network.awg0_peer.allowed_ips='0.0.0.0/0'"));
	ok(has(plan.setup, "add_list network.awg0_peer.allowed_ips='::/0'"));
	ok(has(plan.setup, "set network.awg0_peer.persistent_keepalive='25'"));
});

test("build_vpn_plan: teardown удаляет интерфейс и peer (delete-before-add)", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), {});
	deep_eq(plan.teardown, [ "delete network.awg0", "delete network.awg0_peer" ]);
});

// --- dual-stack Address ---
test("build_vpn_plan: dual-stack Address → два add_list", () => {
	let conf = "[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32, fd00::2/128\n" +
		"[Peer]\nPublicKey = p=\nEndpoint = 1.2.3.4:51820\n";
	let plan = build_vpn_plan(parse_awg_conf(conf), {});
	ok(has(plan.setup, "add_list network.awg0.addresses='10.0.0.2/32'"));
	ok(has(plan.setup, "add_list network.awg0.addresses='fd00::2/128'"));
});

// --- keepalive по умолчанию, если в conf нет ---
test("build_vpn_plan: keepalive дефолт 25, если в conf отсутствует", () => {
	let conf = "[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32\n" +
		"[Peer]\nPublicKey = p=\nEndpoint = 1.2.3.4:51820\n";
	let plan = build_vpn_plan(parse_awg_conf(conf), {});
	ok(has(plan.setup, "set network.awg0_peer.persistent_keepalive='25'"));
});

// --- валидация: граница доверия ---
test("build_vpn_plan: нет PrivateKey/Address/PublicKey/Endpoint → ok=false с ошибками", () => {
	let plan = build_vpn_plan(parse_awg_conf("[Interface]\n[Peer]\n"), {});
	ok(!plan.ok);
	eq(length(plan.errors), 4, "четыре отсутствующих обязательных поля");
	deep_eq(plan.setup, []);
});
test("build_vpn_plan: битый Endpoint → ошибка", () => {
	let conf = "[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32\n" +
		"[Peer]\nPublicKey = p=\nEndpoint = broken-no-port\n";
	let plan = build_vpn_plan(parse_awg_conf(conf), {});
	ok(!plan.ok);
});

// --- кастомное имя интерфейса прокидывается ---
test("build_vpn_plan: кастомный interface → секции и тип peer соответствуют", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), { interface: "awg1" });
	ok(has(plan.setup, "set network.awg1=interface"));
	ok(has(plan.setup, "set network.awg1_peer=amneziawg_awg1"));
	ok(has(plan.setup, "set network.awg1_peer.route_allowed_ips='1'"));
});

test("owned_sections: имена секций шага (источник для reset), уважает opts", () => {
	deep_eq(owned_sections(null), [ "awg0", "awg0_peer" ]);
	deep_eq(owned_sections({ interface: "awg1" }), [ "awg1", "awg1_peer" ]);
});

exit(summary());
