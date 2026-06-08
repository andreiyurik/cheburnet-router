// run.uc — установочный оркестратор (импурно, router-side). Связывает кирпичи в поток:
//   preflight → snapshot UCI → шаги по порядку → health-check → commit / rollback.
//
//   echo '{"awg_conf":"...","domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}' \
//     | ucode -R run.uc
//   ... | ucode -R run.uc --dry-run     # показать, что будет сделано
//
// Политика (порядок, область snapshot, решение) — чистое ядро install.uc (под тестами). Здесь —
// выполнение: запуск preflight/snapshot/шагов/health через существующие CLI. Проверяется в QEMU.
//
// Откат честный: чистые шаги возвращает snapshot restore; грязный (firewall) — его --teardown.

import { popen, stdin } from "fs";
import { enabled_steps, snapshot_scope, dirty_steps, decide_outcome } from "./install.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/

function sh(cmd) {                       // запустить, вернуть stdout
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}
function run_stdin(cmd, text) {           // запустить, подать text на stdin, вернуть код выхода
	let w = popen(cmd, "w");
	if (!w) return -1;
	w.write(text ?? "");
	return w.close();
}
function step_cmd(name, extra) {
	return sprintf("ucode -R %s/steps/%s/apply.uc%s", ENGINE, name, extra ?? "");
}
// stdin для шага по его потребности (install.uc.needs).
function step_stdin(s, cfg) {
	if (s.needs == "awg_conf") return cfg.awg_conf ?? "";
	if (s.needs == "domains")
		return sprintf("%J", { domains: cfg.domains ?? [], routing_opts: cfg.routing_opts });
	return "{}";
}

// Минимальный health-check: свежий awg-handshake (если есть интерфейс) + DNS резолвится локально.
// Расширяемо; цель — поймать «туннель/DNS не поднялись» до commit.
function healthcheck(cfg) {
	let dns_ok = (trim(sh("nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; echo $?")) == "0");
	let iface = (cfg.routing_opts && cfg.routing_opts.tunnel_if) ? cfg.routing_opts.tunnel_if : "awg0";
	let hs = sh(sprintf("awg show %s latest-handshakes 2>/dev/null", iface));
	// handshake != 0 (когда-либо был) ИЛИ vpn не настраивался — не валим установку из-за этого жёстко.
	let awg_ok = (length(trim(hs)) == 0) || !match(hs, /\t0$/);
	return dns_ok && awg_ok;
}

// --- вход ---
let raw = trim(stdin.read("all") ?? "");
let cfg = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let steps = enabled_steps({ disable: cfg.disable });
let scope = snapshot_scope(steps);

// --- 1. preflight (гейткипер) ---
let facts = sh(sprintf("ucode -R %s/preflight/gather.uc", ENGINE));
let pf_rc = run_stdin(sprintf("ucode -R %s/preflight/check.uc", ENGINE), facts);
let preflight = { ok: (pf_rc == 0) };

if (!preflight.ok) {
	// Отчёт preflight уже напечатан check.uc выше (его stdout унаследован). Просто прерываемся.
	let d = decide_outcome({ preflight: preflight });
	warn(sprintf("install: %s\n", d.reason));
	exit(1);
}

if (dry) {
	printf("# preflight: ok\n# snapshot scope: %s\n# шаги: ", join(", ", scope));
	for (let i = 0; i < length(steps); i++) printf("%s ", steps[i].name);
	printf("\n# dirty (teardown при rollback): %s\n", join(", ", dirty_steps(steps)));
	for (let i = 0; i < length(steps); i++)
		run_stdin(step_cmd(steps[i].name, " --dry-run"), step_stdin(steps[i], cfg));
	exit(0);
}

// --- 2. snapshot UCI (для чистого отката) ---
sh(sprintf("ucode -R %s/rollback/snapshot.uc save", ENGINE));

// --- 3. шаги по порядку (fail-fast) ---
let results = [];
for (let i = 0; i < length(steps); i++) {
	let s = steps[i];
	let code = run_stdin(step_cmd(s.name, null), step_stdin(s, cfg));
	push(results, { name: s.name, ok: (code == 0) });
	if (code != 0) {
		warn(sprintf("install: шаг %s упал (код %d)\n", s.name, code));
		break;
	}
}

// --- 4. health-check (только если все шаги прошли) ---
let all_ok = true;
for (let i = 0; i < length(results); i++) if (!results[i].ok) all_ok = false;
let health = all_ok ? { ok: healthcheck(cfg) } : null;

// --- 5. решение: commit / rollback ---
let outcome = decide_outcome({ preflight: preflight, steps: results, health: health });
if (outcome.action == "commit") {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc commit", ENGINE));
	printf("install: успешно — %s\n", outcome.reason);
	exit(0);
}

// rollback: вернуть чистые конфиги из снимка + снять правила грязных шагов (safe-fail).
warn(sprintf("install: откат — %s\n", outcome.reason));
sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
let dirty = dirty_steps(steps);
for (let i = 0; i < length(dirty); i++)
	run_stdin(step_cmd(dirty[i], " --teardown"), step_stdin({ name: dirty[i], needs: "domains" }, cfg));
warn("install: откат выполнен — система возвращена к состоянию до установки\n");
exit(1);
