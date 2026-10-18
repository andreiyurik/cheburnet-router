// test_vpn.uc — юнит-тесты VPN-шага: парсер .conf + UCI-план. Без роутера.
//   ucode -R engine/steps/vpn/tests/test_vpn.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { parse_awg_conf, split_endpoint, build_vpn_plan, build_arm_ops, owned_sections,
         route_sections, unsupported_awg_opts } from "../vpn.uc";

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

// --- маршрут туннеля: half-routes, а не один default (см. ИНВАРИАНТ у HALF_ROUTES в vpn.uc) ---
// Это регресс-тест инцидента: proto-handler ставил ОДИН `default dev awg0`, замещавший WAN-дефолт,
// и первый же подъём WAN возвращал свой default обратно — туннель жив, панель зелёная, а весь
// не-direct трафик LAN резал kill-switch. Лечилось только перезагрузкой.
test("build_vpn_plan: маршрут держат half-routes 0.0.0.0/1 + 128.0.0.0/1 (WAN-дефолт не трогаем)", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), {});
	ok(has(plan.setup, "set network.awg0_route4lo=route"));
	ok(has(plan.setup, "set network.awg0_route4lo.target='0.0.0.0/1'"));
	ok(has(plan.setup, "set network.awg0_route4hi.target='128.0.0.0/1'"));
	ok(has(plan.setup, "set network.awg0_route4lo.interface='awg0'"), "маршрут привязан к интерфейсу туннеля");
	ok(index(join("\n", plan.setup), "target='0.0.0.0/0'") < 0,
		"ни одного полного default: он ЗАМЕСТИЛ бы WAN-дефолт, и подъём WAN отобрал бы маршрут обратно");
});

test("build_vpn_plan: v6 наравне с v4 — ::/1 + 8000::/1 (поведение allowed_ips '::/0' сохранено)", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), {});
	ok(has(plan.setup, "set network.awg0_route6lo=route6"));
	ok(has(plan.setup, "set network.awg0_route6lo.target='::/1'"));
	ok(has(plan.setup, "set network.awg0_route6hi.target='8000::/1'"));
});

test("build_vpn_plan: route_allowed_ips ВСЕГДА '0' — маршрут держим мы, не proto-handler", () => {
	ok(has(build_vpn_plan(parse_awg_conf(CONF), {}).setup,
		"set network.awg0_peer.route_allowed_ips='0'"), "вооружённый план");
	ok(has(build_vpn_plan(parse_awg_conf(CONF), { arm: false }).setup,
		"set network.awg0_peer.route_allowed_ips='0'"), "невооружённый план");
	ok(index(join("\n", build_vpn_plan(parse_awg_conf(CONF), {}).setup),
		"route_allowed_ips='1'") < 0, "старое значение не просочилось ни при каких opts");
});

// --- arm:false (первая установка, до health-check — см. [[reliability]]) ---
test("build_vpn_plan: arm=false → half-routes НЕ создаются, остальной план не меняется", () => {
	let plan = build_vpn_plan(parse_awg_conf(CONF), { arm: false });
	ok(index(join("\n", plan.setup), "_route4lo=route") < 0,
		"дом не переключается на непроверенный туннель раньше health-check");
	ok(index(join("\n", plan.setup), "_route6lo=route6") < 0, "и v6 тоже");
	ok(has(plan.setup, "set network.awg0_peer.public_key='cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMDA='"),
		"остальной план (ключи/endpoint) от arm не зависит");
});

test("build_vpn_plan: arm не задан → вооружено (обратная совместимость replace_vpn/reapply)", () => {
	ok(has(build_vpn_plan(parse_awg_conf(CONF), {}).setup, "set network.awg0_route4lo=route"));
});

// Пере-применение с --no-arm обязано СНЯТЬ прежние half-routes — иначе «не вооружён» остался бы
// вооружённым, и дом переключился бы на непроверенный туннель молча.
test("build_vpn_plan: teardown сносит route-секции при ЛЮБОМ arm", () => {
	for (let opts in [ {}, { arm: false } ])
		ok(has(build_vpn_plan(parse_awg_conf(CONF), opts).teardown, "delete network.awg0_route4lo"));
});

// --- build_arm_ops: путь apply.uc --arm (довооружение и миграция со старой схемы) ---
test("build_arm_ops: идемпотентен (delete-before-set) и запрещает proto-handler'у свой маршрут", () => {
	let arm = build_arm_ops(null);
	deep_eq(arm.teardown, [ "delete network.awg0_route4lo", "delete network.awg0_route4hi",
		"delete network.awg0_route6lo", "delete network.awg0_route6hi" ]);
	eq(arm.setup[0], "set network.awg0_peer.route_allowed_ips='0'",
		"миграция со старой схемы: '1' обязан быть перебит ДО reload");
	ok(has(arm.setup, "set network.awg0_route4hi.target='128.0.0.0/1'"));
});

test("build_arm_ops: уважает кастомный interface (имена не хардкод)", () => {
	let arm = build_arm_ops({ interface: "awg1" });
	ok(has(arm.setup, "set network.awg1_route4lo.interface='awg1'"));
	ok(has(arm.teardown, "delete network.awg1_route4lo"));
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
	deep_eq(plan.teardown, [ "delete network.awg0", "delete network.awg0_peer",
		"delete network.awg0_route4lo", "delete network.awg0_route4hi",
		"delete network.awg0_route6lo", "delete network.awg0_route6hi" ]);
});

// --- dual-stack Address ---
test("build_vpn_plan: dual-stack Address → два add_list", () => {
	let conf = "[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32, fd00::2/128\n" +
		"[Peer]\nPublicKey = p=\nEndpoint = 1.2.3.4:51820\n";
	let plan = build_vpn_plan(parse_awg_conf(conf), {});
	ok(has(plan.setup, "add_list network.awg0.addresses='10.0.0.2/32'"));
	ok(has(plan.setup, "add_list network.awg0.addresses='fd00::2/128'"));
});

// ШРАМ (GL-MT3000, 2026-08-27): Amnezia-клиент 2.0 пишет диапазон, awg-tools отвергает весь конфиг.
test("build_vpn_plan: keepalive-диапазон 25-35 → нижняя граница; мусор → дефолт", () => {
	let rng = replace(CONF, "PersistentKeepalive = 25", "PersistentKeepalive = 25-35");
	ok(has(build_vpn_plan(parse_awg_conf(rng), {}).setup, "set network.awg0_peer.persistent_keepalive='25'"),
		"нижняя граница: чаще keepalive — безопасно, реже — NAT-запись протухнет");
	let junk = replace(CONF, "PersistentKeepalive = 25", "PersistentKeepalive = often");
	ok(has(build_vpn_plan(parse_awg_conf(junk), {}).setup, "set network.awg0_peer.persistent_keepalive='25'"),
		"нечисло → дефолт, а не отказ netifd после установки");
});

// ШРАМ (Cudy TR3000, 2026-10): AWG 3.x-поля не доезжали до uci — сервер с защитой заголовков молчал.
const HPK = "2GuHslRmlqkLNgYPKK4Nqt2z8uMwPKfzzy9xbnGkiFw=";
const AWG31 = replace(CONF, "Jc = 4\n", "Jc = 4\nS2 = 40\nS3 = 20\nS4 = 16\n" +
	"HeaderProtectionKey = " + HPK + "\n" +
	"ContentPaddingAddition = 0-16\n" +
	"RekeyAfterTime = 120\n" +
	"RekeyTimeout = 5\n" +
	"RejectAfterTime = 180\n" +
	"KeepaliveTimeout = 10\n" +
	"MaxHandshakeAttempts = 18\n" +
	"RandomTrailers = on\n" +
	"DisableCookies = off\n");

test("build_vpn_plan: AWG 3.1 — явные uci-имена с подчёркиваниями, значения как есть", () => {
	let plan = build_vpn_plan(parse_awg_conf(AWG31), {});
	ok(plan.ok);
	ok(has(plan.setup, "set network.awg0.awg_header_protection_key='" + HPK + "'"));
	ok(has(plan.setup, "set network.awg0.awg_content_padding_addition='0-16'"), "диапазон не режем");
	ok(has(plan.setup, "set network.awg0.awg_rekey_after_time='120'"));
	ok(has(plan.setup, "set network.awg0.awg_rekey_timeout='5'"));
	ok(has(plan.setup, "set network.awg0.awg_reject_after_time='180'"));
	ok(has(plan.setup, "set network.awg0.awg_keepalive_timeout='10'"));
	ok(has(plan.setup, "set network.awg0.awg_max_handshake_attempts='18'"));
	ok(has(plan.setup, "set network.awg0.awg_random_trailers='1'"), "флаг on → uci boolean");
	ok(!has(plan.setup, "set network.awg0.awg_disable_cookies='1'"), "флаг off — не пишем");
	ok(!has(plan.setup, "set network.awg0.awg_headerprotectionkey='" + HPK + "'"), "lc()-имя proto-handler не знает");
});

test("build_vpn_plan: HeaderProtectionKey при S1..S4 < 12 → отказ с причиной (ядро отвергло бы весь конфиг)", () => {
	let no_s3 = replace(AWG31, "S3 = 20\n", "");
	let r = build_vpn_plan(parse_awg_conf(no_s3), {});
	ok(!r.ok);
	ok(index(join(" ", r.errors), "S3 не меньше 12") >= 0, join(" ", r.errors));
	ok(!build_vpn_plan(parse_awg_conf(replace(AWG31, "S4 = 16", "S4 = 8")), {}).ok, "8 < 12");
	ok(build_vpn_plan(parse_awg_conf(replace(AWG31, "S4 = 16", "S4 = 12")), {}).ok, "12 — граница допустима");
	ok(build_vpn_plan(parse_awg_conf(CONF), {}).ok, "без защиты заголовков S3/S4 не нужны");
});

test("unsupported_awg_opts: сверка с proto-handler'ом — старый пакет называет недостающее", () => {
	let plan = build_vpn_plan(parse_awg_conf(AWG31), {});
	// Опции proto-handler'а до AWG 3.1 (awg-openwrt v25.12.5 до пересборки 2026-09-22).
	let old = "";
	for (let k in [ "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5" ])
		old += sprintf('proto_config_add_string "awg_%s"\n', k);
	let missing = unsupported_awg_opts(plan, old);
	ok(index(missing, "awg_header_protection_key") >= 0);
	ok(index(missing, "awg_jc") < 0, "известная опция не в списке");
	let neu = old;
	for (let i = 0; i < length(plan.awg_options); i++) neu += sprintf('proto_config_add_string "%s"\n', plan.awg_options[i]);
	eq(length(unsupported_awg_opts(plan, neu)), 0, "AWG 3.1-пакет — без предупреждения");
	eq(length(unsupported_awg_opts(build_vpn_plan(parse_awg_conf(CONF), {}), old)), 0,
		"обычный конфиг на старом пакете — без предупреждения");
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
	ok(has(plan.setup, "set network.awg1_route4lo.interface='awg1'"));
});

test("owned_sections: имена секций шага (источник для reset), уважает opts", () => {
	deep_eq(owned_sections(null), [ "awg0", "awg0_peer",
		"awg0_route4lo", "awg0_route4hi", "awg0_route6lo", "awg0_route6hi" ]);
	deep_eq(owned_sections({ interface: "awg1" }), [ "awg1", "awg1_peer",
		"awg1_route4lo", "awg1_route4hi", "awg1_route6lo", "awg1_route6hi" ]);
});

// route-секции ОБЯЗАНЫ быть внутри owned_sections: reset.uc сносит ровно её список, и забытая
// половина оставила бы в uci маршрут в несуществующий туннель.
test("owned_sections включает все route_sections (reset не оставит осиротевший маршрут)", () => {
	let owned = owned_sections(null), routes = route_sections(null);
	eq(length(routes), 4);
	for (let i = 0; i < length(routes); i++)
		ok(index(owned, routes[i]) >= 0, routes[i] + " — в списке владения");
});

// КОНТРАКТ для vpn/apply --teardown (смена протокола awg→reality): элемент [0] — это ИНТЕРФЕЙС,
// его teardown делает `ifdown`. Если порядок перевернуть, ifdown дёрнет peer-секцию (не устройство)
// и awg0 останется поднятым → конфликт маршрутов с singtun0. Фиксируем порядок явно.
test("owned_sections[0] — интерфейс (vpn --teardown его ifdown'ит), [1] — peer", () => {
	eq(owned_sections(null)[0], "awg0", "первый — интерфейс (цель ifdown)");
	eq(owned_sections(null)[1], "awg0_peer", "второй — peer");
});

// --- краевые случаи пользовательского входа (граница доверия) ---
test("parse_awg_conf: CRLF (конфиг из Windows-блокнота) — значения без \\r", () => {
	let conf = "[Interface]\r\nPrivateKey = k=\r\nAddress = 10.0.0.2/32\r\n" +
		"[Peer]\r\nPublicKey = p=\r\nEndpoint = 1.2.3.4:51820\r\n";
	let plan = build_vpn_plan(parse_awg_conf(conf), {});
	ok(plan.ok, "CRLF-конфиг обязан разбираться");
	// \r в private_key молча уехал бы в uci и netifd не поднял бы awg0 — только после установки.
	ok(has(plan.setup, "set network.awg0.private_key='k='"), "значение чисто, без \\r");
	ok(has(plan.setup, "set network.awg0_peer.endpoint_port='51820'"));
});

test("split_endpoint: голый IPv6 без скобок → null (не мусорные host:port)", () => {
	// Резка по последнему ':' давала host="2001:db8:", port="1" — план проходил, туннель
	// умирал после установки. IPv6 обязан быть в [скобках] — честный отказ с понятной ошибкой.
	eq(split_endpoint("2001:db8::1"), null);
	eq(split_endpoint("2001:db8::1:51820"), null);
	deep_eq(split_endpoint("[2001:db8::1]:51820"), { host: "2001:db8::1", port: "51820" });
});

test("split_endpoint: порт вне 1..65535 → null", () => {
	eq(split_endpoint("h:99999"), null);
	eq(split_endpoint("h:0"), null);
	eq(split_endpoint("[2001:db8::1]:99999"), null);
	deep_eq(split_endpoint("h:65535"), { host: "h", port: "65535" });
});

test("build_vpn_plan: два [Peer] → берётся первый (типовой случай — один сервер)", () => {
	let conf = "[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32\n" +
		"[Peer]\nPublicKey = first=\nEndpoint = 1.1.1.1:1111\n" +
		"[Peer]\nPublicKey = second=\nEndpoint = 2.2.2.2:2222\n";
	let plan = build_vpn_plan(parse_awg_conf(conf), {});
	ok(plan.ok);
	ok(has(plan.setup, "set network.awg0_peer.public_key='first='"));
	ok(!has(plan.setup, "set network.awg0_peer.public_key='second='"));
});

exit(summary());
