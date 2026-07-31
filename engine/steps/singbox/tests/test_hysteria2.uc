// test_hysteria2.uc — юниты Hysteria2-ветки sing-box шага: разбор hysteria2://, генерация
// outbound, port hopping, границы поддержки. Без роутера.
//   ucode -R engine/steps/singbox/tests/test_hysteria2.uc
//
// Почему это отдельный файл от test_singbox.uc: там Reality-ветка, здесь Hysteria2 — их ломают
// разные правки, и при провале сразу видно, какая ось поехала.

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import {
	parse_hysteria2_link, build_hysteria2_config, parse_port_ranges,
	parse_input, build_singbox_plan
} from "../singbox.uc";

// Типовая hy2-ссылка (значения-заглушки): пароль, порт, obfs salamander, sni, insecure.
const LINK = "hysteria2://p%40ssw0rd@vpn.example.com:8443" +
	"?sni=www.example.com&insecure=1&obfs=salamander&obfs-password=obfskey#My%20HY2";

// hy2_out(link) → туннельный outbound из ссылки (или die с причиной — тест должен называть
// ПОЧЕМУ упало, а не «false != true»).
function hy2_out(link, opts) {
	let p = parse_hysteria2_link(link);
	if (!p.ok) die("ссылка не разобрана: " + join("; ", p.errors));
	let b = build_hysteria2_config(p.fields, opts ?? {});
	if (!b.ok) die("конфиг не собран: " + join("; ", b.errors));
	return b.config.outbounds[0];
}

// --- parse_hysteria2_link: структура ---
test("parse_hysteria2_link: пароль/host/port/query, urldecode пароля и label", () => {
	let r = parse_hysteria2_link(LINK);
	ok(r.ok, "ссылка разобрана");
	eq(r.fields.auth, "p@ssw0rd", "urldecode %40 → @ (иначе пароль тихо не тот)");
	eq(r.fields.host, "vpn.example.com");
	eq(r.fields.port, "8443");
	deep_eq(r.fields.ports, [], "одиночный порт — не port hopping");
	eq(r.fields.sni, "www.example.com");
	eq(r.fields.insecure, "1");
	eq(r.fields.obfs, "salamander");
	eq(r.fields.obfs_password, "obfskey");
	eq(r.fields.label, "My HY2");
});

test("parse_hysteria2_link: схема-алиас hy2:// принимается", () => {
	let r = parse_hysteria2_link("hy2://pw@h.example.com:443");
	ok(r.ok);
	eq(r.fields.host, "h.example.com");
});

test("parse_hysteria2_link: порт опущен → 443 (так говорит спецификация hy2-URI)", () => {
	let r = parse_hysteria2_link("hysteria2://pw@h.example.com");
	ok(r.ok);
	eq(r.fields.port, "443");
});

test("parse_hysteria2_link: путь '/' перед query отрезается (не уезжает в host)", () => {
	let r = parse_hysteria2_link("hysteria2://pw@h.example.com:443/?sni=s");
	ok(r.ok);
	eq(r.fields.host, "h.example.com", "слеш не прилип к имени хоста");
	eq(r.fields.sni, "s");
});

test("parse_hysteria2_link: [ipv6]:port и [ipv6] без порта", () => {
	let r = parse_hysteria2_link("hysteria2://pw@[2001:db8::1]:8443");
	ok(r.ok);
	eq(r.fields.host, "2001:db8::1");
	eq(r.fields.port, "8443");
	let d = parse_hysteria2_link("hysteria2://pw@[2001:db8::1]");
	ok(d.ok);
	eq(d.fields.port, "443", "без порта — дефолт");
});

test("parse_hysteria2_link: голый IPv6 без скобок → ok=false (не мусорные host/port)", () => {
	// Тот же класс бага, что чинили в vless-парсере: разбор «прошёл бы», а туннель умер бы
	// только после установки — на 30-секундной пробе, без внятной причины.
	ok(!parse_hysteria2_link("hysteria2://pw@2001:db8::1").ok);
	ok(!parse_hysteria2_link("hysteria2://pw@fe80::1:8443").ok);
});

test("parse_hysteria2_link: не-hy2 схема → ok=false с причиной", () => {
	let r = parse_hysteria2_link("vless://u@h:443");
	ok(!r.ok);
	ok(index(join(" ", r.errors), "hysteria2://") >= 0, "причина названа");
});

test("parse_hysteria2_link: CRLF-хвост (вставка из Windows) не портит поля", () => {
	let r = parse_hysteria2_link("hysteria2://pw@h.example.com:8443?sni=s\r\n");
	ok(r.ok);
	eq(r.fields.port, "8443");
	eq(r.fields.sni, "s");
});

// --- port hopping ---
test("parse_port_ranges: одиночный порт, диапазон, список; нормализация в синтаксис sing-box", () => {
	deep_eq(parse_port_ranges("443"), [ "443:443" ]);
	deep_eq(parse_port_ranges("5000-6000"), [ "5000:6000" ], "дефис ссылки → двоеточие sing-box");
	deep_eq(parse_port_ranges("5000:6000"), [ "5000:6000" ], "двоеточная форма тоже принимается");
	deep_eq(parse_port_ranges("443,5000-6000,7000"), [ "443:443", "5000:6000", "7000:7000" ]);
});

test("parse_port_ranges: битая спека → null (порт-хоппинг не должен молча не работать)", () => {
	eq(parse_port_ranges(""), null);
	eq(parse_port_ranges(null), null);
	eq(parse_port_ranges("0-100"), null, "порт 0 невалиден");
	eq(parse_port_ranges("100-99999"), null, "выше 65535");
	eq(parse_port_ranges("6000-5000"), null, "перевёрнутый диапазон");
	eq(parse_port_ranges("443,"), null, "пустой токен");
	eq(parse_port_ranges("443,abc"), null);
});

test("parse_hysteria2_link: диапазоны в порт-компоненте (стандартный port hopping)", () => {
	let r = parse_hysteria2_link("hysteria2://pw@h.example.com:443,5000-6000");
	ok(r.ok);
	eq(r.fields.port, "", "при хоппинге одиночного порта нет");
	deep_eq(r.fields.ports, [ "443:443", "5000:6000" ]);
});

test("parse_hysteria2_link: mport= как альтернативная форма (её отдают некоторые панели)", () => {
	let r = parse_hysteria2_link("hysteria2://pw@h.example.com?mport=5000-6000");
	ok(r.ok);
	deep_eq(r.fields.ports, [ "5000:6000" ]);
	// Порт-компонент приоритетнее mport: он часть самого адреса.
	let both = parse_hysteria2_link("hysteria2://pw@h.example.com:7000-7100?mport=5000-6000");
	ok(both.ok);
	deep_eq(both.fields.ports, [ "7000:7100" ], "порт-компонент побеждает");
});

test("parse_hysteria2_link: битый диапазон → ok=false с названной спекой", () => {
	let r = parse_hysteria2_link("hysteria2://pw@h.example.com:6000-5000");
	ok(!r.ok);
	ok(index(join(" ", r.errors), "6000-5000") >= 0, "в ошибке видно, что именно не разобрано");
});

test("build_hysteria2_config: хоппинг → server_ports, БЕЗ server_port (по схеме они конфликтуют)", () => {
	let out = hy2_out("hysteria2://pw@h.example.com:443,5000-6000");
	deep_eq(out.server_ports, [ "443:443", "5000:6000" ]);
	ok(!exists(out, "server_port"), "server_port не пишем — схема объявляет конфликт");
});

test("build_hysteria2_config: одиночный порт → server_port числом, без server_ports", () => {
	let out = hy2_out(LINK);
	ok(out.server_port === 8443, "server_port обязан быть числом — строку sing-box отвергнет");
	ok(!exists(out, "server_ports"));
});

// --- build_hysteria2_config: happy path ---
test("build_hysteria2_config: outbound hysteria2 с паролем, obfs и tls", () => {
	let out = hy2_out(LINK);
	eq(out.type, "hysteria2");
	eq(out.tag, "hysteria2-out");
	eq(out.server, "vpn.example.com");
	eq(out.password, "p@ssw0rd");
	deep_eq(out.obfs, { type: "salamander", password: "obfskey" });
	eq(out.tls.enabled, true, "tls обязателен по схеме hysteria2-outbound");
	eq(out.tls.server_name, "www.example.com");
	eq(out.tls.insecure, true);
});

test("build_hysteria2_config: инвариант auto_route=false и общий TUN singtun0", () => {
	// Тот же инвариант, что у Reality: маршрутизацией владеет ядро. Проверяем именно здесь —
	// новый протокол не должен уметь его потерять.
	let p = parse_hysteria2_link(LINK);
	let c = build_hysteria2_config(p.fields, {}).config;
	eq(c.inbounds[0].type, "tun");
	eq(c.inbounds[0].interface_name, "singtun0", "туннель общий с Reality → data-plane не меняется");
	eq(c.inbounds[0].auto_route, false, "маршрутизацией управляет policy-routing, не sing-box");
	eq(c.route.auto_detect_interface, true, "серверное соединение уходит в WAN без петли");
	eq(c.route.final, "hysteria2-out");
});

test("build_hysteria2_config: без sni имя хоста идёт в server_name, IP — нет", () => {
	eq(hy2_out("hysteria2://pw@h.example.com:443").tls.server_name, "h.example.com");
	let ip = hy2_out("hysteria2://pw@203.0.113.5:443");
	ok(!exists(ip.tls, "server_name"), "SNI с IP-адресом часть серверов отвергает — не подставляем");
});

test("build_hysteria2_config: без obfs ключа obfs нет (не пишем пустую обфускацию)", () => {
	let out = hy2_out("hysteria2://pw@h.example.com:443");
	ok(!exists(out, "obfs"));
	ok(!exists(out.tls, "insecure"), "insecure не задан → проверку сертификата не снимаем");
});

// --- Brutal: полоса не имеет дефолта ---
test("build_hysteria2_config: без up/down полосу НЕ пишем (это включает BBR, не Brutal)", () => {
	let out = hy2_out(LINK);
	ok(!exists(out, "up_mbps"), "выдуманная скорость включила бы Brutal и могла сделать хуже");
	ok(!exists(out, "down_mbps"));
});

test("build_hysteria2_config: up+down из ссылки → up_mbps/down_mbps числами (opt-in Brutal)", () => {
	let out = hy2_out("hysteria2://pw@h.example.com:443?up=20&down=80");
	ok(out.up_mbps === 20);
	ok(out.down_mbps === 80);
});

test("build_hysteria2_config: только одна половина полосы → отказ с причиной", () => {
	let p = parse_hysteria2_link("hysteria2://pw@h.example.com:443?down=80");
	let b = build_hysteria2_config(p.fields, {});
	ok(!b.ok);
	ok(index(join(" ", b.errors), "парой") >= 0, "объясняем, что нужны оба значения");
});

test("build_hysteria2_config: мусорная/нулевая полоса игнорируется как отсутствующая", () => {
	let out = hy2_out("hysteria2://pw@h.example.com:443?up=0&down=0");
	ok(!exists(out, "up_mbps"), "0 Мбит/с — не скорость; молча в Brutal не уходим");
	let unit = hy2_out("hysteria2://pw@h.example.com:443?up=20%20mbps&down=80%20mbps");
	ok(unit.up_mbps === 20, "хвост с единицами терпим (панели пишут по-разному)");
});

// --- границы поддержки (граница доверия: отказ с названной причиной) ---
test("build_hysteria2_config: obfs=gecko → отказ (sing-box умеет только salamander)", () => {
	let p = parse_hysteria2_link("hysteria2://pw@h.example.com:443?obfs=gecko&obfs-password=x");
	let b = build_hysteria2_config(p.fields, {});
	ok(!b.ok);
	ok(index(join(" ", b.errors), "salamander") >= 0);
});

test("build_hysteria2_config: obfs без пароля → отказ (сервер такой трафик не примет)", () => {
	let p = parse_hysteria2_link("hysteria2://pw@h.example.com:443?obfs=salamander");
	ok(!build_hysteria2_config(p.fields, {}).ok);
});

test("build_hysteria2_config: pinSHA256 без insecure → отказ, с insecure=1 → принимаем", () => {
	// Пиннинг sing-box для hysteria2 не поддерживает. Подставить insecure самим = тихо снять
	// проверку сертификата; промолчать = мёртвый туннель без объяснения. Отказываем с причиной.
	let strict = parse_hysteria2_link("hysteria2://pw@h.example.com:443?pinSHA256=deadbeef");
	let b = build_hysteria2_config(strict.fields, {});
	ok(!b.ok);
	ok(index(join(" ", b.errors), "pinSHA256") >= 0);
	// insecure=1 → пиннинг всё равно ничего не проверяет, ссылка рабочая.
	let lax = parse_hysteria2_link("hysteria2://pw@h.example.com:443?pinSHA256=deadbeef&insecure=1");
	ok(build_hysteria2_config(lax.fields, {}).ok);
});

test("build_hysteria2_config: ech → отказ (в tiny-сборке sing-box ECH нет)", () => {
	let p = parse_hysteria2_link("hysteria2://pw@h.example.com:443?ech=AEj%2BDQBE");
	let b = build_hysteria2_config(p.fields, {});
	ok(!b.ok);
	ok(index(join(" ", b.errors), "ech") >= 0);
});

test("build_hysteria2_config: нет пароля / нет host → отказ с перечислением полей", () => {
	let noauth = parse_hysteria2_link("hysteria2://h.example.com:443");
	// Без '@' вся строка — host, пароля нет: сервер hysteria2 без аутентификации не бывает.
	let b = build_hysteria2_config(noauth.fields, {});
	ok(!b.ok);
	ok(index(join(" ", b.errors), "парол") >= 0);
	ok(!build_hysteria2_config({ auth: "pw" }, {}).ok, "нет host");
});

// --- диспетч входа и план ---
test("parse_input: hysteria2:// и hy2:// → source=hy2, конфиг сгенерирован", () => {
	let r = parse_input(LINK, {});
	ok(r.ok);
	eq(r.source, "hy2");
	eq(r.config.outbounds[0].type, "hysteria2");
	eq(parse_input("hy2://pw@h.example.com:443", {}).source, "hy2");
});

test("parse_input: мусор — причина упоминает оба протокола (человек должен понять, что вставить)", () => {
	let r = parse_input("просто текст", {});
	ok(!r.ok);
	ok(index(join(" ", r.errors), "hysteria2") >= 0);
	ok(index(join(" ", r.errors), "vless") >= 0);
});

test("build_singbox_plan: hy2-ссылка даёт те же артефакты, что reality (шаг общий)", () => {
	let plan = build_singbox_plan(LINK, {});
	ok(plan.ok, "план собран: " + join("; ", plan.errors ?? []));
	eq(plan.source, "hy2");
	eq(plan.config_path, "/etc/sing-box/config.json");
	eq(plan.service, "sing-box");
	eq(plan.tun, "singtun0");
	deep_eq(plan.uci_teardown, [ "delete sing-box.main" ]);
	// netifd-маршрут — тот же, что у Reality: half-routes на общий singtun.
	ok(index(join("\n", plan.net_setup), "network.singtun.device='singtun0'") >= 0);
	ok(index(join("\n", plan.net_setup), "target='0.0.0.0/1'") >= 0);
});

test("build_singbox_plan: битая hy2-ссылка → ok=false, артефактов нет", () => {
	let plan = build_singbox_plan("hysteria2://pw@h.example.com:0", {});
	ok(!plan.ok, "порт 0 не должен доехать до конфига");
	eq(plan.source, "hy2", "источник ошибки назван — UI покажет адресно");
});

test("build_hysteria2_config: opts.tun прокидывается (единый источник имени TUN)", () => {
	let p = parse_hysteria2_link(LINK);
	let c = build_hysteria2_config(p.fields, { tun: "singtun9" }).config;
	eq(c.inbounds[0].interface_name, "singtun9");
});

exit(summary());
