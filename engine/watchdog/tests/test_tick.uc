// test_tick.uc — host-тест тика сторожа: автосмена AWG-сервера (engine/profiles) в sandbox.
//   ucode -R engine/watchdog/tests/test_tick.uc
// Факты и replace_vpn.uc — заглушки (ENGINE_DIR), ping/logger — стабы в PATH; решение — настоящее.

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { sh } from "../../lib/proc.uc";
import { writefile, readfile, mkdir, access, unlink } from "fs";

const TICK = sourcepath(0, true) + "/../tick.uc";
const SB = trim(sh("mktemp -d"));
if (substr(SB, 0, 1) != "/") die("mktemp -d не дал sandbox");
const STATE = SB + "/state", ETC = SB + "/etc", BIN = SB + "/bin", ENG = SB + "/engine";

// PID живого процесса (сам тест): $PPID дочернего sh — это ucode.
const LIVE_PID = trim(sh("echo $PPID"));

function shq(s) { return "'" + replace(s ?? "", "'", "'\\''") + "'"; }

// setup(o) — sandbox: o.alive (туннель), o.wan (ping), o.replace_rc, o.auto, o.paused.
function setup(o) {
	sh(sprintf("rm -rf %s/*.log %s/syslog", SB, SB));
	sh(sprintf("rm -rf %s %s %s %s; mkdir -p %s %s %s %s/invariants %s/install %s/profiles",
		STATE, ETC, BIN, ENG, STATE, ETC, BIN, ENG, ENG, ETC));
	writefile(ENG + "/invariants/gather.uc", sprintf("print(%s);\n", shq(sprintf("%J",
		{ installed: false, protocol: o.protocol ?? "awg", tunnel_alive: o.alive === true, wan_if: "eth0" }))));
	writefile(ENG + "/install/replace_vpn.uc", sprintf(
		"import { writefile, readfile } from \"fs\";\n" +
		"writefile(%s, (readfile(%s) ?? \"\") + join(\" \", ARGV) + \"\\n\");\nexit(%d);\n",
		shq(SB + "/replace.log"), shq(SB + "/replace.log"), o.replace_rc ?? 0));
	// o.grab — пока сторож пингует, панель запускает свою операцию (берёт замок pid без done).
	writefile(BIN + "/ping", sprintf("#!/bin/sh\necho ping >> %s\n%sexit %d\n", shq(SB + "/ping.log"),
		o.grab ? sprintf("echo %s > %s/pid; rm -f %s/done\n", LIVE_PID, STATE, STATE) : "", o.wan === false ? 1 : 0));
	writefile(BIN + "/logger", sprintf("#!/bin/sh\nshift 2\necho \"$*\" >> %s\n", shq(SB + "/syslog")));
	sh(sprintf("chmod +x %s/ping %s/logger", BIN, BIN));
	writefile(ETC + "/install.json", sprintf("%J", { protocol: o.protocol ?? "awg", paused: o.paused === true }));
	writefile(ETC + "/profiles.json", sprintf("%J", { profiles: [ { id: "p1", name: "Германия" },
		{ id: "p2", name: "Нидерланды" } ], active: "p1", auto: o.auto ?? true, next_id: 3 }));
	writefile(ETC + "/profiles/p2.conf", "[Interface]\n");
}

function tick() {
	sh(sprintf("PATH=%s:$PATH STATE_DIR=%s ETC_CHEBURNET=%s ENGINE_DIR=%s UPTIME_S=9999 ucode -R %s",
		BIN, STATE, ETC, ENG, TICK));
}
function ticks(n) { for (let i = 0; i < n; i++) tick(); }
function syslog() { return readfile(SB + "/syslog") ?? ""; }

test("туннель мёртв 3 тика, WAN жив → replace_vpn.uc --profile p2 --auto; итог в журнале", () => {
	setup({});
	ticks(2);
	ok(!access(SB + "/replace.log"), "две неудачи — ещё не повод");
	ok(!access(SB + "/ping.log"), "пока решение не зависит от WAN, его не пингуем");
	tick();
	eq(trim(readfile(SB + "/replace.log") ?? ""), "--profile p2 --auto");
	ok(index(syslog(), "сервер «Германия» недоступен — подключён «Нидерланды»") >= 0, syslog());
	eq(trim(readfile(STATE + "/done") ?? ""), "0", "под замком pid/done — панель видит операцию");
	deep_eq(json(readfile(STATE + "/failover.json")), {}, "нашёлся рабочий — счёт заново");
});

test("нет домашнего интернета → серверы не перебираются", () => {
	setup({ wan: false });
	ticks(4);
	ok(!access(SB + "/replace.log"), "дело не в сервере");
	ok(index(syslog(), "нет домашнего интернета") >= 0);
});

test("новый сервер не ответил → журнал говорит, что прежний возвращён", () => {
	setup({ replace_rc: 1 });
	ticks(3);
	ok(index(syslog(), "«Нидерланды» тоже не ответил") >= 0, syslog());
});

test("панель взяла замок, пока сторож пинговал → сторож не запускает вторую замену поверх", () => {
	setup({ grab: true });
	ticks(3);
	ok(!access(SB + "/replace.log"), "две замены разом перетёрли бы снимок друг друга");
	eq(json(readfile(STATE + "/failover.json")).dead, 2, "кандидат не потрачен — следующий тик попробует снова");
});

test("автосмена выключена / не AWG / аварийный режим / туннель жив → ничего", () => {
	for (let o in [ { auto: false }, { protocol: "reality" }, { paused: true }, { alive: true } ]) {
		setup(o);
		ticks(4);
		ok(!access(SB + "/replace.log"), sprintf("%J", o));
	}
});

let rc = summary();
sh(sprintf("rm -rf %s", SB));
exit(rc);
