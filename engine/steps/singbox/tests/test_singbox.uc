// test_singbox.uc — юнит-тесты sing-box шага: разбор vless://, генерация конфига, план. Без роутера.
//   ucode -R engine/steps/singbox/tests/test_singbox.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import {
	parse_vless_link, build_singbox_config, parse_input, build_singbox_plan,
	build_net_plan, network_sections, tun_interface, config_path, service_name
} from "../singbox.uc";

// Типовая Reality-ссылка (значения-заглушки). sni urlencoded (%2D = '-'), label с пробелом.
const LINK = "vless://11111111-2222-3333-4444-555555555555@vpn.example.com:443" +
	"?type=tcp&security=reality&pbk=PUBKEYbase64xxx&fp=chrome&sni=www%2Eexample%2Ecom" +
	"&sid=abcd1234&flow=xtls-rprx-vision&encryption=none#My%20Server";

// --- parse_vless_link ---
test("parse_vless_link: разбирает uuid/host/port и query, urldecode sni/label", () => {
	let r = parse_vless_link(LINK);
	ok(r.ok);
	eq(r.fields.uuid, "11111111-2222-3333-4444-555555555555");
	eq(r.fields.host, "vpn.example.com");
	eq(r.fields.port, "443");
	eq(r.fields.security, "reality");
	eq(r.fields.pbk, "PUBKEYbase64xxx");
	eq(r.fields.sni, "www.example.com", "urldecode %2E → .");
	eq(r.fields.sid, "abcd1234");
	eq(r.fields.flow, "xtls-rprx-vision");
	eq(r.fields.label, "My Server", "urldecode %20 → пробел");
});

test("parse_vless_link: [ipv6]:port", () => {
	let r = parse_vless_link("vless://uuid@[2001:db8::1]:8443?security=reality&pbk=k&sni=s");
	ok(r.ok);
	eq(r.fields.host, "2001:db8::1");
	eq(r.fields.port, "8443");
});

test("parse_vless_link: не-vless схема и отсутствие '@' → ok=false", () => {
	ok(!parse_vless_link("https://example.com").ok);
	ok(!parse_vless_link("vless://no-at-here?x=1").ok);
});

// --- build_singbox_config: валидация (граница доверия) ---
test("build_singbox_config: нет pbk/sni → ошибки, config=null", () => {
	let r = build_singbox_config({ uuid: "u", host: "h", port: "443" }, {});
	ok(!r.ok);
	eq(r.config, null);
	ok(index(join(" ", r.errors), "pbk") >= 0);
	ok(index(join(" ", r.errors), "sni") >= 0);
});

test("build_singbox_config: security != reality → ошибка (Full = только Reality)", () => {
	let f = { uuid: "u", host: "h", port: "443", pbk: "k", sni: "s", security: "tls" };
	let r = build_singbox_config(f, {});
	ok(!r.ok);
	ok(index(join(" ", r.errors), "reality") >= 0);
});

test("build_singbox_config: битый port → ошибка", () => {
	let f = { uuid: "u", host: "h", port: "noport", pbk: "k", sni: "s" };
	ok(!build_singbox_config(f, {}).ok);
});

// --- build_singbox_config: happy path ---
test("build_singbox_config: outbound vless+reality с правильными полями", () => {
	let c = build_singbox_config(parse_vless_link(LINK).fields, {}).config;
	let out = c.outbounds[0];
	eq(out.type, "vless");
	eq(out.server, "vpn.example.com");
	eq(out.server_port, 443, "port — число, не строка");
	eq(out.uuid, "11111111-2222-3333-4444-555555555555");
	eq(out.flow, "xtls-rprx-vision");
	eq(out.tls.server_name, "www.example.com");
	eq(out.tls.utls.fingerprint, "chrome");
	eq(out.tls.reality.enabled, true);
	eq(out.tls.reality.public_key, "PUBKEYbase64xxx");
	eq(out.tls.reality.short_id, "abcd1234");
});

test("build_singbox_config: КРИТИЧНЫЙ инвариант auto_route=false (routing — ядро)", () => {
	let c = build_singbox_config(parse_vless_link(LINK).fields, {}).config;
	eq(c.inbounds[0].type, "tun");
	eq(c.inbounds[0].interface_name, "singtun0");
	eq(c.inbounds[0].auto_route, false, "маршрутизацией управляет policy-routing, не sing-box");
	eq(c.route.auto_detect_interface, true, "серверное соединение уходит в WAN без петли");
	eq(c.route.final, "reality-out");
});

test("build_singbox_config: дефолты flow/fp при отсутствии в ссылке", () => {
	let f = { uuid: "u", host: "h", port: "443", pbk: "k", sni: "s", security: "reality" };
	let out = build_singbox_config(f, {}).config.outbounds[0];
	eq(out.flow, "xtls-rprx-vision");
	eq(out.tls.utls.fingerprint, "chrome");
});

test("build_singbox_config: без sid → short_id не пишем", () => {
	let f = { uuid: "u", host: "h", port: "443", pbk: "k", sni: "s" };
	let reality = build_singbox_config(f, {}).config.outbounds[0].tls.reality;
	ok(!exists(reality, "short_id"), "пустой sid → ключа нет");
});

test("build_singbox_config: opts.tun прокидывается в interface_name", () => {
	let f = { uuid: "u", host: "h", port: "443", pbk: "k", sni: "s" };
	let c = build_singbox_config(f, { tun: "singtun1" }).config;
	eq(c.inbounds[0].interface_name, "singtun1");
});

// --- parse_input: диспетч ссылка / JSON / мусор ---
test("parse_input: vless:// → source=link, config сгенерирован", () => {
	let r = parse_input(LINK, {});
	ok(r.ok);
	eq(r.source, "link");
	eq(r.config.outbounds[0].type, "vless");
});

test("parse_input: JSON-конфиг с outbounds → source=json, passthrough", () => {
	let raw = '{"outbounds":[{"type":"vless","tag":"x"}]}';
	let r = parse_input(raw, {});
	ok(r.ok);
	eq(r.source, "json");
	eq(r.config.outbounds[0].tag, "x");
});

test("parse_input: JSON без outbounds → ok=false", () => {
	ok(!parse_input('{"log":{}}', {}).ok);
});

test("parse_input: пустой и мусорный вход → ok=false", () => {
	ok(!parse_input("", {}).ok);
	ok(!parse_input("just text", {}).ok);
});

// --- build_singbox_plan: артефакты ---
test("build_singbox_plan: uci включает сервис + conffile, teardown delete-before-set", () => {
	let plan = build_singbox_plan(LINK, {});
	ok(plan.ok);
	eq(plan.config_path, "/etc/sing-box/config.json");
	eq(plan.service, "sing-box");
	deep_eq(plan.uci_teardown, [ "delete sing-box.main" ]);
	ok(index(join("\n", plan.uci_setup), "set sing-box.main.enabled='1'") >= 0);
	ok(index(join("\n", plan.uci_setup), "conffile='/etc/sing-box/config.json'") >= 0);
});

test("build_singbox_plan: битый JSON → ok=false, не кидает наружу", () => {
	let plan = build_singbox_plan("{not valid json", {});
	ok(!plan.ok);
	ok(index(join(" ", plan.errors), "JSON") >= 0);
});

test("build_singbox_plan: невалидная ссылка → ok=false с ошибками", () => {
	let plan = build_singbox_plan("vless://u@h:443?security=reality", {});
	ok(!plan.ok, "нет pbk/sni");
});

// --- маршрут в туннель через netifd (build_net_plan) ---
test("build_net_plan: интерфейс proto none на TUN + half-routes 0/1 и 128/1", () => {
	let n = build_net_plan({});
	let s = join("\n", n.setup);
	// интерфейс поверх устройства, БЕЗ адреса (его назначает сам sing-box)
	ok(index(s, "set network.singtun=interface") >= 0);
	ok(index(s, "set network.singtun.proto='none'") >= 0);
	ok(index(s, "set network.singtun.device='singtun0'") >= 0);
	// две half-route СПЕЦИФИЧНЕЕ WAN-дефолта (0/0) → выигрывают без удаления WAN
	ok(index(s, "target='0.0.0.0/1'") >= 0);
	ok(index(s, "target='128.0.0.0/1'") >= 0);
	// обе привязаны к интерфейсу singtun (netifd переустановит при пересоздании устройства)
	ok(index(s, "set network.cheburnet_str0.interface='singtun'") >= 0);
	ok(index(s, "set network.cheburnet_str1.interface='singtun'") >= 0);
});

test("build_net_plan: teardown удаляет ровно наши секции (идемпотентность)", () => {
	let n = build_net_plan({});
	deep_eq(n.teardown, [
		"delete network.singtun",
		"delete network.cheburnet_str0",
		"delete network.cheburnet_str1",
	]);
});

test("build_net_plan: device берётся из opts.tun (единый источник имени TUN)", () => {
	let s = join("\n", build_net_plan({ tun: "singtun7" }).setup);
	ok(index(s, "set network.singtun.device='singtun7'") >= 0);
});

test("network_sections: интерфейс + обе route-секции (источник для reset)", () => {
	deep_eq(network_sections(null), [ "singtun", "cheburnet_str0", "cheburnet_str1" ]);
});

test("build_singbox_plan: несёт net_setup/net_teardown (network-часть гибридного шага)", () => {
	let plan = build_singbox_plan(LINK, {});
	ok(plan.ok);
	ok(index(join("\n", plan.net_setup), "network.singtun.proto='none'") >= 0);
	ok(index(join("\n", plan.net_teardown), "delete network.singtun") >= 0);
	eq(plan.net_iface, "singtun");
});

// --- owned-экспорты (источник для routing/firewall/reset) ---
test("owned: tun_interface / config_path / service_name уважают opts", () => {
	eq(tun_interface(null), "singtun0");
	eq(tun_interface({ tun: "t9" }), "t9");
	eq(config_path(null), "/etc/sing-box/config.json");
	eq(service_name(null), "sing-box");
});

// --- краевые случаи пользовательского входа (граница доверия) ---
test("urldecode: '+' в query — литерал, не пробел (standard-base64 pbk не бьётся)", () => {
	let r = parse_vless_link("vless://u@h:443?security=reality&pbk=AB+CD/EF=&sni=s");
	ok(r.ok);
	eq(r.fields.pbk, "AB+CD/EF=", "'+' обязан пережить разбор: пробел = битый ключ, провал только на probe");
});

test("urldecode: битый/обрезанный %XX не теряет символы", () => {
	let r = parse_vless_link("vless://u@h:443?security=reality&pbk=k&sni=s#My%2GServer%4");
	ok(r.ok);
	eq(r.fields.label, "My%2GServer%4", "невалидный percent-код остаётся как есть");
});

test("parse_vless_link: CRLF-хвост (вставка из Windows) не портит поля", () => {
	let r = parse_vless_link("vless://u@h:443?security=reality&pbk=k&sni=s\r\n");
	ok(r.ok);
	eq(r.fields.port, "443");
	eq(r.fields.sni, "s", "внешний \\r\\n снят trim'ом, поля чисты");
});

test("parse_vless_link: голый IPv6 без скобок → ok=false (не мусорные host:port)", () => {
	// Резать "2001:db8::1" по последнему ':' давало host="2001:db8:", port="1" — план проходил,
	// а туннель умирал только после установки. Требуем [скобки] — честный отказ на границе.
	ok(!parse_vless_link("vless://u@2001:db8::1?security=reality&pbk=k&sni=s").ok);
	ok(!parse_vless_link("vless://u@2001:db8::1:8443?security=reality&pbk=k&sni=s").ok);
});

test("parse_vless_link: порт вне 1..65535 → ok=false", () => {
	ok(!parse_vless_link("vless://u@h:99999?security=reality&pbk=k&sni=s").ok);
	ok(!parse_vless_link("vless://u@h:0?security=reality&pbk=k&sni=s").ok);
	ok(!parse_vless_link("vless://u@[2001:db8::1]:99999?security=reality&pbk=k&sni=s").ok);
	ok(parse_vless_link("vless://u@h:65535?security=reality&pbk=k&sni=s").ok, "граница включительно");
});

test("parse_vless_link: host без порта и мусорный порт → ok=false", () => {
	ok(!parse_vless_link("vless://u@hostonly?security=reality&pbk=k&sni=s").ok);
	ok(!parse_vless_link("vless://u@[2001:db8::1]?security=reality&pbk=k&sni=s").ok);
	ok(!parse_vless_link("vless://u@h:443a?security=reality&pbk=k&sni=s").ok);
});

test("parse_vless_link: без query/label разбирается; конфиг без pbk/sni не строится", () => {
	let r = parse_vless_link("vless://u@h:443");
	ok(r.ok);
	eq(r.fields.security, "");
	ok(!build_singbox_config(r.fields, null).ok);
});

test("parse_query: пара без '=', пустой ключ, '=' внутри значения", () => {
	let r = parse_vless_link("vless://u@h:443?flag&=x&sid=v=w&security=reality&pbk=k&sni=s");
	ok(r.ok);
	eq(r.fields.sid, "v=w", "режем по ПЕРВОМУ '='");
});

test("build_singbox_config: типы значений (address массив, mtu/port числа)", () => {
	let r = build_singbox_config(parse_vless_link(LINK).fields, null);
	ok(r.ok);
	deep_eq(r.config.inbounds[0].address, [ "172.19.0.1/30" ]);
	ok(r.config.inbounds[0].mtu === 1500, "mtu обязан быть числом — строку sing-box отвергнет");
	ok(r.config.outbounds[0].server_port === 443, "server_port обязан быть числом");
});

test("parse_input: JSON-массив и JSON без outbounds → ok=false", () => {
	ok(!parse_input("[1,2]", null).ok);
	ok(!parse_input('{"outbounds":[]}', null).ok, "пустой массив outbounds — не конфиг");
});

test("resolve_opts: неизвестный ключ opts не протекает в план", () => {
	let plan = build_singbox_plan(LINK, { bogus_key: "x" });
	ok(plan.ok);
	ok(index(sprintf("%J", plan), "bogus_key") < 0);
});

exit(summary());
