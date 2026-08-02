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
import { writefile, readfile, access } from "fs";
import { mk_sandbox, with_singbox, run_uc, calls, cleanup } from "./harness.uc";

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

test("health-провал: rollback с reason=health (роутер настроен, сервер молчит)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/nslookup.rc", "1"); // DNS так и не поднялся за окно
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "awg", disable: ALL_STEPS,
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "health", "reason=health — не «упал шаг»");
	ok(!access(sb.etc + "/install.json"), "фантомный installed снят");
	cleanup(sb);
});

test("reality без sing-box: провал догрузки = чистый abort ДО снимка, reason=singbox-download", () => {
	let sb = mk_sandbox();
	// apk «успешен», но бинарь sing-box так и не появился в PATH — критерий install-singbox.sh
	// (наличие бинаря, не код apk) обязан сработать и здесь.
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "reality", reality_conf: "vless://x",
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "singbox-download", "адресный reason");
	ok(!access(sb.snap), "снимка нет — роутер не тронут (откатывать нечего)");
	ok(!access(sb.etc + "/install.json"), "фантомный installed снят");
	eq(trim(readfile(sb.state) ?? ""), "singbox-download", "прогресс показывал догрузку");
	cleanup(sb);
});

// Гейт догрузки ветвится по uses_singbox, а не по имени «reality» — иначе выбор Hysteria2 на
// системе без бинаря дошёл бы до шагов и упал бы уже ПОСЛЕ снимка, с невнятной причиной.
test("hysteria2 без sing-box: тот же чистый abort ДО снимка (гейт по шагу, не по имени)", () => {
	let sb = mk_sandbox();
	seed_cfg(sb, "install.json", { routing_opts: {} });
	let payload = sprintf("%J", { protocol: "hysteria2", hysteria2_conf: "hysteria2://pw@h:443",
		domains: [], routing_opts: {} });
	let r = run_uc(sb, "install/run.uc", null, payload);
	eq(r.rc, 1, "exit 1");
	eq(trim(readfile(sb.reason) ?? ""), "singbox-download", "адресный reason");
	ok(!access(sb.snap), "снимка нет — роутер не тронут");
	ok(!access(sb.etc + "/install.json"), "фантомный installed снят");
	cleanup(sb);
});

// Ключ конфига выбирается по протоколу (conf_key): если бы run.uc продолжал читать reality_conf,
// hysteria2-установка ушла бы в singbox-шаг с ПУСТЫМ stdin и упала бы «непонятно почему».
test("hysteria2: конфиг доезжает до singbox-шага по conf_key (dry-run печатает hysteria2-outbound)", () => {
	let sb = mk_sandbox();
	with_singbox(sb); // бинарь «есть» → догрузка пропускается
	let r = run_uc(sb, "install/run.uc", "--dry-run", sprintf("%J", {
		protocol: "hysteria2",
		hysteria2_conf: "hysteria2://HY2PASS@203.0.113.5:8443?sni=example.com",
		domains: [], routing_opts: {},
	}));
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(r.out, "\"type\": \"hysteria2\"") >= 0, "singbox-шаг получил hy2-ссылку: " + r.out);
	ok(index(r.out, "HY2PASS") >= 0, "пароль из ссылки доехал в конфиг");
	ok(index(r.out, "singtun") >= 0, "маршрут в общий TUN-интерфейс");
	cleanup(sb);
});

test("--rollback (отмена): teardown ОБОИХ туннелей + возврат install.json и config.json", () => {
	let sb = mk_sandbox();
	let prev = { routing_opts: { wan_if: "eth0" }, protocol: "reality" };
	seed_cfg(sb, "install.json", { routing_opts: {} });
	seed_cfg(sb, "install.json.prev", prev);
	// Рабочий Full-тир: config.json уже подменён установкой, .prev ждёт возврата.
	writefile(sb.sbconf, "НОВЫЙ (от прерванной установки)\n");
	writefile(sb.sbconf + ".prev", "ПРЕЖНИЙ РАБОЧИЙ\n");
	let r = run_uc(sb, "install/run.uc", "--rollback",
		'{"protocol":"reality","routing_opts":{}}');
	eq(r.rc, 0, "exit 0: " + r.out);
	let log = calls(sb);
	// vpn — clean-шаг: его возвращает snapshot restore; teardown'ятся только dirty
	// (singbox + firewall) — отменённая reality-установка не оставляет живой sing-box.
	ok(index(log, "ifdown singtun") >= 0, "singbox teardown вызван — sing-box не остаётся жить");
	ok(index(log, "nft") >= 0, "firewall teardown вызван (safe-fail)");
	eq(readfile(sb.sbconf), "ПРЕЖНИЙ РАБОЧИЙ\n", "config.json возвращён из .prev");
	ok(!access(sb.sbconf + ".prev"), "бэкап config.json поглощён");
	eq(json(readfile(sb.etc + "/install.json")).protocol, "reality",
		"install.json восстановлен из .prev");
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

exit(summary());
