// test_run_paths.uc — host-тест оркестратора install/run.uc: ПУТИ РЕШЕНИЯ и их последствия.
//
// Чистая политика (decide_outcome/snapshot_scope/…) — под test_install.uc; здесь — ПРОВОДКА:
// что реально происходит с системой (sandbox) на каждом исходе. Реальный run.uc гоняется как
// subprocess с фейками команд (см. harness.uc) — так проверяем инварианты надёжности:
//   • abort (preflight / singbox-download) — система НЕ тронута, фантомного installed нет;
//   • commit — wan_if персистится, одноразовый токен снят, снимок выброшен;
//   • rollback — reason-код адресный, install.json-правда восстановлена, teardown вызван.
// Живой data-plane (netifd/fw4) — по-прежнему QEMU; здесь — логика переходов на реальном коде.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { writefile, readfile, access } from "fs";
import { mk_sandbox, run_uc, calls, cleanup } from "./harness.uc";

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
