// test_recover.uc — host-тест отката прерванной установки (install/recover.uc) на заглушке run.uc.
// Решение «откатывать или не мешать» и однократность; сам откат проверен test_install/qemu-interrupt.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { writefile, mkdir, access, readfile } from "fs";
import { mk_sandbox, run_uc, cleanup, shq } from "./harness.uc";
import { sh } from "../../lib/proc.uc";

// stub_engine(sb) — install/run.uc лишь записывает аргументы и stdin, с которыми его позвали.
function stub_engine(sb) {
	let dir = sb.root + "/engine";
	mkdir(dir, 0o755); mkdir(dir + "/install", 0o755);
	writefile(dir + "/install/run.uc", sprintf(
		"import { stdin, writefile } from \"fs\";\n" +
		"writefile(%s, join(\" \", ARGV) + \"\\n\" + (stdin.read(\"all\") ?? \"\"));\n",
		shq(sb.root + "/run-call.txt")));
	return dir;
}

function recover(sb) {
	let state = sb.root + "/tmpstate";
	mkdir(state, 0o755);
	return run_uc(sb, "install/recover.uc", null, null,
		sprintf("ENGINE_DIR=%s STATE_DIR=%s", shq(stub_engine(sb)), shq(state)));
}

const PENDING = '{"protocol":"awg","domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}';

test("recover: метки нет — ничего не трогает", () => {
	let sb = mk_sandbox();
	let r = recover(sb);
	eq(r.rc, 0, r.out);
	ok(!access(sb.root + "/run-call.txt"), "run.uc не вызывался");
	cleanup(sb);
});

test("recover: метка есть, установщика нет (перезагрузка) — откат с данными из метки", () => {
	let sb = mk_sandbox();
	writefile(sb.etc + "/install.pending", PENDING);
	let r = recover(sb);
	eq(r.rc, 0, r.out);
	let call = readfile(sb.root + "/run-call.txt") ?? "";
	ok(index(call, "--rollback") == 0, "run.uc позван с --rollback");
	ok(index(call, '"example.com"') >= 0, "stdin — сохранённые домены и маршрутизация");
	ok(!access(sb.etc + "/install.pending"), "метка снята: повторная загрузка не откатывает дважды");
	ok(!access(sb.root + "/tmpstate/recover.lock"), "замок освобождён");
	cleanup(sb);
});

test("recover: установщик жив — не мешает и метку не трогает", () => {
	let sb = mk_sandbox();
	writefile(sb.etc + "/install.pending", PENDING);
	mkdir(sb.root + "/tmpstate", 0o755);
	writefile(sb.root + "/tmpstate/pid", trim(sh("echo $PPID")) + "\n");
	let r = recover(sb);
	eq(r.rc, 0, r.out);
	ok(!access(sb.root + "/run-call.txt"), "отката нет");
	ok(access(sb.etc + "/install.pending"), "метка на месте");
	cleanup(sb);
});

test("recover: процесс жив, но установка уже завершилась (done) — значит, упала: откат", () => {
	let sb = mk_sandbox();
	writefile(sb.etc + "/install.pending", PENDING);
	mkdir(sb.root + "/tmpstate", 0o755);
	writefile(sb.root + "/tmpstate/pid", trim(sh("echo $PPID")) + "\n");
	writefile(sb.root + "/tmpstate/done", "1\n");
	recover(sb);
	ok(access(sb.root + "/run-call.txt"), "откат запущен");
	cleanup(sb);
});

test("recover: замок занят параллельным вызовом — второй откат не запускается", () => {
	let sb = mk_sandbox();
	writefile(sb.etc + "/install.pending", PENDING);
	mkdir(sb.root + "/tmpstate", 0o755);
	mkdir(sb.root + "/tmpstate/recover.lock", 0o755);
	recover(sb);
	ok(!access(sb.root + "/run-call.txt"), "отката нет — его уже выполняет другой вызов");
	cleanup(sb);
});

summary();
