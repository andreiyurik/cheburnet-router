// test_run_paths.uc — host-тест оркестратора install/run.uc: ПУТИ РЕШЕНИЯ и их последствия.
//
// Чистая политика (decide_outcome/snapshot_scope/…) — под test_install.uc; здесь — ПРОВОДКА:
// что реально происходит с системой (sandbox) на каждом исходе. Реальный run.uc гоняется как
// subprocess с фейками команд (см. harness.uc) — так проверяем инварианты надёжности:
//   • abort (preflight / singbox-download) — система НЕ тронута, фантомного installed нет;
//   • commit — wan_if персистится, одноразовый токен снят, снимок выброшен;
//   • rollback — reason-код адресный, install.json-правда восстановлена, teardown вызван.
// Живой data-plane (netifd/fw4) — по-прежнему QEMU; здесь — логика переходов на реальном коде.

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { writefile, readfile, access, mkdir } from "fs";
import { mk_sandbox, with_singbox, run_uc, calls, cleanup, write_stub, shq } from "./harness.uc";

// seed_cfg(sb, extra) — install.json «до этой попытки» (то, что пишет m_install до исхода).
function seed_cfg(sb, name, obj) {
	writefile(sb.etc + "/" + name, sprintf("%J\n", obj));
}

const ALL_STEPS = ["vpn", "dns", "doh", "wifi", "firewall"];

test("preflight-провал: abort до снимка, reason=preflight, фантомный install.json удалён", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/apk.rc", "1"); // deps_installable=false → гейткипер отказывает
	seed_cfg(sb, "install.json", { routing_opts: {} }); // .prev нет — «чистая система»
	let r = run_uc(sb, "install/run.uc", null, '{"protocol":"awg","domains":[]}');
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "preflight", "машинный код для UI");
	ok(!access(sb.etc + "/install.json"), "правда installed восстановлена (файл удалён)");
	ok(!access(sb.snap), "снимок не создавался — система не тронута");
	cleanup(sb);
});

// --- «Поставить на свой страх и риск» (accept_risk): soft-провалы пропускаются, hard — нет ---
// df-стаб отдаёт «свободно 8 МБ» → soft-провал flash. RAM здесь не подделать (parse_meminfo
// читает /proc/meminfo напрямую), и не нужно: путь один и тот же для любого soft-провала.
const DF_SMALL = "Filesystem           1K-blocks      Used Available Use% Mounted on\n" +
	"/dev/root                20480     12288      8192  60% /overlay\n";

test("soft-провал без accept_risk: обычный abort (пропуск НЕ по умолчанию)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/df.out", DF_SMALL);
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, '{"protocol":"awg","domains":[]}');
	eq(r.rc, 1, "гейт закрыт: " + r.out);
	eq(trim(readfile(sb.reason) ?? ""), "preflight");
	ok(!access(sb.snap), "система не тронута");
	cleanup(sb);
});

test("soft-провал + accept_risk: установка идёт, пропуск в логе и в install.json", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/df.out", DF_SMALL);
	seed_cfg(sb, "install.json", { user_domains: [], domains: [], routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS, domains: [],
		routing_opts: {}, accept_risk: true });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "установка прошла: " + r.out);
	ok(index(r.out, "! flash") >= 0, "отчёт помечает пропуск, а не молчит");
	ok(index(r.out, "ВНИМАНИЕ") >= 0, "предупреждение осталось в install.log");
	let saved = json(readfile(sb.etc + "/install.json"));
	deep_eq(saved.forced, [ "flash" ], "след решения — панель покажет плашку");
	cleanup(sb);
});

test("hard-провал + accept_risk: всё равно abort (пакетов под платформу нет)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/apk.rc", "1"); // deps не ставятся — hard
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", domains: [], accept_risk: true });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "риск не пропускает hard-провал: " + r.out);
	eq(trim(readfile(sb.reason) ?? ""), "preflight");
	ok(!access(sb.snap), "система не тронута");
	cleanup(sb);
});

test("commit на годном железе: forced пуст (прежняя отметка не залипает)", () => {
	let sb = mk_sandbox();
	seed_cfg(sb, "install.json", { user_domains: [], domains: [], routing_opts: {},
		forced: [ "ram" ] }); // как будто прошлая установка была с пропуском
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS, domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "установка прошла: " + r.out);
	deep_eq(json(readfile(sb.etc + "/install.json")).forced, [], "переустановка стирает отметку");
	cleanup(sb);
});

test("commit-путь: wan_if/wan_gw/tunnel_if персистятся, токен снят, снимок выброшен", () => {
	let sb = mk_sandbox();
	// Все шаги выключены → health = только DNS (nslookup-стаб по умолчанию отвечает).
	seed_cfg(sb, "install.json", { user_domains: [], domains: [], routing_opts: {} });
	writefile(sb.etc + "/install-token", "TOK-123\n");
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS,
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(r.out, "install: успешно") >= 0, "итог напечатан");
	let saved = json(readfile(sb.etc + "/install.json"));
	eq(saved.routing_opts.wan_if, "eth0", "wan_if найден через netifd и персистнут");
	eq(saved.routing_opts.wan_gw, "192.0.2.1", "wan_gw персистнут (ethernet-WAN)");
	eq(saved.routing_opts.tunnel_if, "awg0", "tunnel_if активного туннеля персистнут");
	ok(!access(sb.etc + "/install-token"), "одноразовый токен снят ТОЛЬКО на успехе");
	ok(!access(sb.snap), "снимок выброшен (commit)");
	eq(trim(readfile(sb.state) ?? ""), "health-check", "последний шаг прогресса");
	cleanup(sb);
});

test("шаг упал: rollback c reason=step:vpn, teardown грязных, install.json из .prev", () => {
	let sb = mk_sandbox();
	// Пере-установка ПОВЕРХ рабочей: .prev несёт прежнюю правду (с wan_if — для reapply).
	let prev = { user_domains: ["old.example"], domains: ["old.example"],
		routing_opts: { wan_if: "eth0", tunnel_if: "awg0" }, protocol: "awg" };
	seed_cfg(sb, "install.json", { routing_opts: {} }); // новая попытка уже записала своё
	seed_cfg(sb, "install.json.prev", prev);
	let payload = sprintf("%J", { protocol: "awg", disable: ["dns", "doh", "wifi"],
		awg_conf: "это не AWG-конфиг", domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "step:vpn", "адресный reason для UI");
	ok(index(r.out, "откат") >= 0, "об откате сказано явно");
	let restored = json(readfile(sb.etc + "/install.json"));
	eq(restored.user_domains[0], "old.example", "install.json восстановлен из .prev");
	ok(!access(sb.etc + "/install.json.prev"), ".prev поглощён восстановлением");
	// Firewall — грязный шаг: его teardown обязан быть вызван даже если сам шаг не успел
	// примениться (safe-fail), а reapply_data_plane обязан вернуть firewall прежней системы.
	ok(index(calls(sb), "nft") >= 0, "firewall teardown дошёл до nft");
	cleanup(sb);
});

test("health-провал (DNS): rollback с reason=health:dns (роутер настроен, DNS не поднялся)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/nslookup.rc", "1"); // DNS так и не поднялся за окно
	seed_cfg(sb, "install.json", { routing_opts: {} });
	// Все туннель/сетевые шаги выключены → tunnel_applied=false → tun_ok сразу true, падает
	// ровно DNS — адресный код должен указывать именно на него, не на «сервер молчит».
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS,
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "health:dns", "reason адресный — DNS, не общий «сервер молчит»");
	ok(!access(sb.etc + "/install.json"), "фантомный installed снят");
	cleanup(sb);
});

// Full-тир заморожен (ADR 0010): у legacy-протоколов нет conf_key, а singbox-шаг новый конфиг не
// применяет. ubus такой install и не пропустит (enum) — это второй рубеж.
test("reality/hysteria2 (legacy): поставить заново нельзя — шаг sing-box отказывает, откат", () => {
	for (let proto in [ "reality", "hysteria2" ]) {
		let sb = mk_sandbox();
		with_singbox(sb);
		seed_cfg(sb, "install.json", { routing_opts: {} });
		let payload = { protocol: proto, domains: [], routing_opts: {},
			disable: [ "dns", "doh", "wifi", "firewall" ] };
		payload[proto + "_conf"] = "SECRET-LINK";
		let r = run_uc(sb, "install/run.uc", null, sprintf("%J", payload));
		eq(r.rc, 1, proto + ": exit 1: " + r.out);
		eq(trim(readfile(sb.reason) ?? ""), "step:singbox", proto + ": адресный reason");
		ok(index(r.out, "больше не поддерживается") >= 0, proto + ": причина названа");
		ok(index(calls(sb), "ifup singtun") < 0, proto + ": дом на туннель не переключался");
		cleanup(sb);
	}
});

// Отмена ухода с legacy Reality на AWG: install.json уже несёт protocol попытки (awg), .prev — reality.
// ШРАМ (ревью): откат сносил ОБА туннеля после restore — восстановленный sing-box выключался, и
// legacy-роутер оставался без туннеля и без способа вернуть его (Reality больше не ставится).
test("--rollback (отмена ухода на AWG): legacy sing-box НЕ снимается, install.json и config.json возвращены", () => {
	let sb = mk_sandbox();
	seed_cfg(sb, "install.json", { routing_opts: {}, protocol: "awg" });
	seed_cfg(sb, "install.json.prev", { routing_opts: { wan_if: "eth0" }, protocol: "reality" });
	writefile(sb.sbconf + ".prev", "ПРЕЖНИЙ РАБОЧИЙ\n"); // teardown шага при уходе удалил живой config.json
	let r = run_uc(sb, "install/run.uc", "--rollback", '{"protocol":"awg","routing_opts":{}}');
	eq(r.rc, 0, "exit 0: " + r.out);
	let log = calls(sb);
	ok(index(log, "ifdown singtun") < 0, "восстановленный sing-box не снесён teardown'ом: " + log);
	ok(index(log, "nft") >= 0, "firewall (грязный шаг) снят; vpn вернул snapshot restore");
	eq(readfile(sb.sbconf), "ПРЕЖНИЙ РАБОЧИЙ\n", "config.json возвращён из .prev");
	ok(!access(sb.sbconf + ".prev"), "бэкап config.json поглощён");
	eq(json(readfile(sb.etc + "/install.json")).protocol, "reality", "install.json восстановлен из .prev");
	cleanup(sb);
});

const AWG_CONF =
	"[Interface]\nPrivateKey = cHJpdmF0ZXByaXZhdGVwcml2YXRlcHJpdmF0ZXByaXZhdGUwMA==\n" +
	"Address = 10.0.0.2/32\n\n[Peer]\nPublicKey = cHVibGljcHVibGljcHVibGljcHVibGljcHVibGljMDA=\n" +
	"Endpoint = vpn.example.com:51820\n";
const REALITY_CONF = "vless://uuid-x@203.0.113.9:443?security=reality&pbk=YQ&sni=example.com";

// ШРАМ (ревью): ветка enable+restart после возврата config.json держалась без теста — регресс не поймали бы.
test("--rollback: вернули config.json и sing-box был включён → init.d enable + restart", () => {
	let sb = mk_sandbox();
	seed_cfg(sb, "install.json", { routing_opts: {}, protocol: "awg" });
	seed_cfg(sb, "install.json.prev", { routing_opts: { wan_if: "eth0" }, protocol: "reality" });
	writefile(sb.sbconf + ".prev", "ПРЕЖНИЙ РАБОЧИЙ\n");
	writefile(sb.fake + "/sb_enabled", "1\n"); // snapshot restore вернул enabled=1
	with_singbox(sb); // тот же стаб играет init.d/sing-box
	let r = run_uc(sb, "install/run.uc", "--rollback", '{"protocol":"awg","routing_opts":{}}');
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "sing-box enable") >= 0, "автозапуск включён обратно: " + calls(sb));
	ok(index(calls(sb), "sing-box restart") >= 0, "сервис поднят");
	cleanup(sb);
});

test("--rollback: sing-box был выключен (enabled≠1) → enable не зовём", () => {
	let sb = mk_sandbox();
	seed_cfg(sb, "install.json", { routing_opts: {}, protocol: "awg" });
	seed_cfg(sb, "install.json.prev", { routing_opts: {}, protocol: "reality" });
	writefile(sb.sbconf + ".prev", "X\n");
	with_singbox(sb);
	let r = run_uc(sb, "install/run.uc", "--rollback", '{"protocol":"awg","routing_opts":{}}');
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "sing-box enable") < 0, "не включаем то, что было выключено");
	cleanup(sb);
});

// --- Уход с legacy Reality на AWG сквозь run.uc (switch_to_awg) ---
function legacy_switch(sb) {
	seed_cfg(sb, "install.json", { routing_opts: {}, protocol: "awg" });
	seed_cfg(sb, "install.json.prev", { routing_opts: { wan_if: "eth0", tunnel_if: "singtun0" }, protocol: "reality" });
	writefile(sb.sbconf, "РАБОЧИЙ SING-BOX\n");
	with_singbox(sb);
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	return run_uc(sb, "install/run.uc", null, payload);
}

test("уход с legacy на AWG, успех: sing-box снят, бэкап config.json убран, tunnel_if=awg0", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/awg.out", "pubkeyXXX\t5\n");
	let r = legacy_switch(sb);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "ifdown singtun") >= 0, "teardown sing-box вызван");
	ok(!access(sb.sbconf), "config.json удалён teardown'ом");
	ok(!access(sb.sbconf + ".prev"), "на commit бэкап зачищен");
	eq(json(readfile(sb.etc + "/install.json")).routing_opts.tunnel_if, "awg0", "tunnel_if сменился");
	cleanup(sb);
});

test("уход с legacy на AWG, health провален: config.json вернулся, sing-box включён обратно", () => {
	let sb = mk_sandbox(); // awg.out пуст → handshake не придёт
	writefile(sb.fake + "/sb_enabled", "1\n");
	let r = legacy_switch(sb);
	eq(r.rc, 1, "exit 1: " + r.out);
	eq(readfile(sb.sbconf), "РАБОЧИЙ SING-BOX\n", "прежний config.json на месте");
	ok(index(calls(sb), "sing-box enable") >= 0, "автозапуск включён обратно");
	eq(json(readfile(sb.etc + "/install.json")).protocol, "reality", "install.json — прежняя правда");
	cleanup(sb);
});

test("чистая установка AWG: sing-box teardown не вызывается (config.json нет)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/awg.out", "pubkeyXXX\t5\n");
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	eq(run_uc(sb, "install/run.uc", null, payload).rc, 0);
	ok(index(calls(sb), "singtun") < 0 && index(calls(sb), "sing-box") < 0, "sing-box не трогали");
	cleanup(sb);
});

test("--dry-run: план напечатан, система не тронута", () => {
	let sb = mk_sandbox();
	let r = run_uc(sb, "install/run.uc", "--dry-run",
		'{"protocol":"awg","awg_conf":"мусор","domains":[],"routing_opts":{}}');
	eq(r.rc, 0, "exit 0");
	ok(index(r.out, "# snapshot scope:") >= 0, "область снимка показана");
	ok(index(r.out, "# шаги:") >= 0, "список шагов показан");
	ok(!access(sb.snap), "снимок не создан");
	cleanup(sb);
});

// --- --no-arm/--arm: половина дома не переключается на непроверенный туннель (см. план в
// docs/kb/architecture/reliability.md, инцидент 2026-08-19 — kill-switch срабатывал раньше
// health-check и ронял интернет всему дому при провале). Сначала точечно на уровне apply.uc,
// потом сквозь run.uc — что реально произойдёт при провале/успехе первой установки.


test("vpn/apply.uc --no-arm: half-routes НЕ создаются, интерфейс всё равно поднимается", () => {
	let sb = mk_sandbox();
	let r = run_uc(sb, "steps/vpn/apply.uc", "--no-arm", AWG_CONF);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "awg0_route4lo=route") < 0, "маршрут НЕ вооружён");
	ok(index(calls(sb), "route_allowed_ips='0'") >= 0, "но proto-handler свой default тоже не ставит");
	ok(index(calls(sb), "route_allowed_ips='1'") < 0, "старая схема не просочилась");
	cleanup(sb);
});

test("vpn/apply.uc --arm: half-routes + reload, конфиг туннеля не трогает", () => {
	let sb = mk_sandbox();
	let r = run_uc(sb, "steps/vpn/apply.uc", "--arm");
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "awg0_route4lo.target='0.0.0.0/1'") >= 0, "маршрут довооружён");
	// netifd применяет route-секции по reload — перезапускать туннель сразу после health-check
	// не за что (обе ветки прогнаны в qemu-route-fallback).
	ok(index(calls(sb), "ifup awg0") < 0, "туннель не дёргаем: reload ставит маршруты сам");
	ok(index(calls(sb), "private_key") < 0, "конфиг туннеля не переписывается");
	cleanup(sb);
});

// --arm — он же путь миграции со старой схемы: route_allowed_ips='1' обязан быть перебит, иначе
// netifd оставит свой ЗАМЕЩАЮЩИЙ default и подъём WAN снова отберёт маршрут у туннеля.
test("vpn/apply.uc --arm: перебивает route_allowed_ips на '0' (миграция старой установки)", () => {
	let sb = mk_sandbox();
	run_uc(sb, "steps/vpn/apply.uc", "--arm");
	ok(index(calls(sb), "route_allowed_ips='0'") >= 0, "старая схема снята");
	// WAN-дефолт в песочнице есть (route_default.out) → гасить и поднимать wan не за чем.
	ok(index(calls(sb), "ifup wan") < 0, "живой WAN не дёргаем на ровном месте");
	cleanup(sb);
});

test("singbox/apply.uc без режима (новый конфиг): отказ, сервис и сеть не тронуты", () => {
	let sb = mk_sandbox();
	with_singbox(sb);
	let r = run_uc(sb, "steps/singbox/apply.uc", null, REALITY_CONF);
	eq(r.rc, 1, "exit 1: " + r.out);
	ok(index(r.out, "больше не поддерживается") >= 0, "причина названа: " + r.out);
	eq(calls(sb), "", "ни uci, ни ifup, ни рестарта сервиса");
	cleanup(sb);
});

test("singbox/apply.uc --arm при живом sing-box: ifup singtun, сервис не трогаем", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/pgrep.rc", "0\n"); // sing-box жив
	mkdir(sb.root + "/initd", 0o755); write_stub(sb.root + "/initd", "sing-box", "exit 0");
	let r = run_uc(sb, "steps/singbox/apply.uc", "--arm", null, sprintf("INITD_DIR=%s", shq(sb.root + "/initd")));
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "ifup singtun") >= 0, "маршрут довооружён");
	ok(index(calls(sb), "sing-box restart") < 0, "живой туннель не мигаем ровно тогда, когда health его подтвердил");
	cleanup(sb);
});

// Half-routes живут на TUN, а TUN — на живом sing-box: после OOM/исчерпанного respawn «arm» сторожа
// делал `ifup` в пустоту три раза и замолкал — дом без интернета до SSH.
test("singbox/apply.uc --arm при МЁРТВОМ sing-box: сначала рестарт сервиса, потом ifup", () => {
	let sb = mk_sandbox();
	// pgrep.rc по умолчанию 1 → процесса нет
	mkdir(sb.root + "/initd", 0o755); write_stub(sb.root + "/initd", "sing-box", "exit 0");
	let r = run_uc(sb, "steps/singbox/apply.uc", "--arm", null, sprintf("INITD_DIR=%s", shq(sb.root + "/initd")));
	eq(r.rc, 0, "exit 0: " + r.out);
	let c = calls(sb);
	ok(index(c, "sing-box restart") >= 0, "сервис поднят");
	ok(index(c, "sing-box restart") < index(c, "ifup singtun"), "рестарт ДО ifup: netifd ставит маршрут на живой TUN");
	cleanup(sb);
});

// --- Сквозь run.uc: главный регресс-тест инцидента ---
test("первая установка (AWG), health провалился → half-routes НИ РАЗУ не вооружались", () => {
	let sb = mk_sandbox();
	// awg.out по умолчанию пуст (нет рукопожатия) → health-check не пройдёт.
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1: " + r.out);
	eq(trim(readfile(sb.reason) ?? ""), "health:tunnel:fetch");
	ok(index(calls(sb), "awg0_route4lo=route") < 0,
		"дом НЕ переключался на непроверенный туннель — раньше здесь была утечка/потеря интернета");
	ok(!access(sb.etc + "/profiles.json"), "откатившийся сервер профилем не запоминается");
	ok(index(calls(sb), "amneziawg_awg0") >= 0, "но интерфейс поднимался (--no-arm) — health-check мог его проверить");
	cleanup(sb);
});

// Сторож — единственное, что смотрит за роутером ПОСЛЕ установки. Не поставился на успешном
// пути — обещание «работает годами» опирается только на удачу.
test("успешная установка ставит сторожа в cron; провал — не ставит", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/awg.out", "pubkeyXXX\t5\n"); // свежее рукопожатие → health ok
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	eq(run_uc(sb, "install/run.uc", null, payload).rc, 0);
	ok(index(readfile(sb.crontab) ?? "", "watchdog/tick.uc") >= 0, "cron-запись на месте");
	cleanup(sb);

	let sb2 = mk_sandbox(); // awg.out пуст → health не пройдёт → откат
	seed_cfg(sb2, "install.json", { routing_opts: {} });
	eq(run_uc(sb2, "install/run.uc", null, payload).rc, 1);
	ok(index(readfile(sb2.crontab) ?? "", "watchdog/tick.uc") < 0,
		"на откате сторожить нечего — запись не ставим");
	cleanup(sb2);
});

test("первая установка (AWG), health прошёл → half-routes вооружены (arm вызван)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/awg.out", "pubkeyXXX\t5\n"); // свежее рукопожатие → up
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(calls(sb), "awg0_route4lo=route") >= 0, "туннель подтверждён — теперь вооружён");
	eq(json(readfile(sb.etc + "/profiles.json")).active, "p1", "подтверждённый сервер стал профилем");
	eq(readfile(sb.etc + "/profiles/p1.conf"), AWG_CONF);
	cleanup(sb);
});

test("возврат на AWG вставленным конфигом без активного → новый «Сервер N», чужой профиль не тронут", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/awg.out", "pubkeyXXX\t5\n");
	seed_cfg(sb, "install.json", { routing_opts: {} });
	mkdir(sb.etc + "/profiles", 0o700);
	writefile(sb.etc + "/profiles/p1.conf", "СТАРЫЙ");
	writefile(sb.etc + "/profiles.json", sprintf("%J", { profiles: [ { id: "p1", name: "Германия" } ], active: null, next_id: 2 }));
	let payload = sprintf("%J", { protocol: "awg", awg_conf: AWG_CONF,
		disable: [ "dns", "doh", "wifi", "firewall" ], domains: [], routing_opts: {} });
	eq(run_uc(sb, "install/run.uc", null, payload).rc, 0);
	let st = json(readfile(sb.etc + "/profiles.json"));
	eq(st.active, "p2");
	eq(readfile(sb.etc + "/profiles/p1.conf"), "СТАРЫЙ", "конфиг «Германии» не перезаписан");
	cleanup(sb);
});

exit(summary());
