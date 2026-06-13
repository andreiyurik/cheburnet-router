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

import { stdin } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { enabled_steps, snapshot_scope, dirty_steps, decide_outcome,
         tunnel_info, disabled_tunnels, default_protocol } from "./install.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/

function step_cmd(name, extra) {
	return sprintf("ucode -R %s/steps/%s/apply.uc%s", ENGINE, name, extra ?? "");
}
// stdin для шага по его потребности (install.uc.needs).
function step_stdin(s, cfg) {
	if (s.needs == "awg_conf") return cfg.awg_conf ?? "";
	if (s.needs == "reality")  return cfg.reality_conf ?? ""; // vless://… или JSON sing-box (сырой текст)
	if (s.needs == "domains")
		// fw_opts.tunnel_if — интерфейс активного туннеля для NAT-зоны (firewall apply берёт его
		// из fw_opts; routing его игнорирует). dns-шаг лишний ключ игнорирует — payload общий.
		return sprintf("%J", { domains: cfg.domains ?? [], routing_opts: cfg.routing_opts,
			fw_opts: { tunnel_if: cfg.routing_opts.tunnel_if } });
	if (s.needs == "wifi")
		return sprintf("%J", { ssid: cfg.ssid, key: cfg.wifi_key }); // нет полей → шаг сделает no-op
	if (s.needs == "doh")
		return sprintf("%J", { provider: cfg.dns_provider }); // нет id → doh берёт дефолт каталога
	return "{}";
}

// Минимальный health-check: свежий awg-handshake (если есть интерфейс) + DNS резолвится локально.
// Расширяемо; цель — поймать «туннель/DNS не поднялись» до commit.
function healthcheck(cfg) {
	let dns_ok = (trim(sh("nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; echo $?")) == "0");
	// reality (Full): туннель — userspace-сервис sing-box, не awg-интерфейс. Минимальная проверка
	// «процесс жив»; глубокая (handshake к Reality-серверу) — QEMU/железо.
	if ((cfg.protocol ?? default_protocol()) == "reality") {
		let up = (trim(sh("pgrep -x sing-box >/dev/null 2>&1; echo $?")) == "0");
		return dns_ok && up;
	}
	let iface = (cfg.routing_opts && cfg.routing_opts.tunnel_if) ? cfg.routing_opts.tunnel_if : "awg0";
	let hs = sh(sprintf("awg show %s latest-handshakes 2>/dev/null", iface));
	// handshake != 0 (когда-либо был) ИЛИ vpn не настраивался — не валим установку из-за этого жёстко.
	let awg_ok = (length(trim(hs)) == 0) || !match(hs, /\t0$/);
	return dns_ok && awg_ok;
}

// rollback_all(steps, cfg) — ЕДИНСТВЕННАЯ реализация отката: вернуть чистые конфиги из снимка
// + снять правила грязных шагов (safe-fail). Зовётся отсюда (упавшая установка) и ubus-слоем
// через `run.uc --rollback` (отмена установки) — знание «как откатывать» не дрейфует по слоям.
function rollback_all(steps, cfg) {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
	let dirty = dirty_steps(steps);
	for (let i = 0; i < length(dirty); i++)
		run_stdin(step_cmd(dirty[i], " --teardown"), step_stdin({ name: dirty[i], needs: "domains" }, cfg));
}

// --- вход ---
let raw = trim(stdin.read("all") ?? "");
let cfg = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

// Протокол туннеля: awg (Light, дефолт) | reality (Full). Определяет активный туннель-шаг и
// интерфейс, который туннель презентует (NAT-зона firewall + health-check). tunnel_if кладём в
// routing_opts: routing его игнорирует, а health-check и (через fw_opts) firewall — используют.
let protocol = cfg.protocol ?? default_protocol();
let tinfo = tunnel_info(protocol);
if (type(cfg.routing_opts) != "object") cfg.routing_opts = {};
cfg.routing_opts.tunnel_if = tinfo.tunnel_if;

// Отключаем неактивные туннель-шаги (vpn/singbox взаимоисключающие) + пользовательский disable.
let disable = disabled_tunnels(protocol);
if (type(cfg.disable) == "array")
	for (let i = 0; i < length(cfg.disable); i++) push(disable, cfg.disable[i]);

let steps = enabled_steps({ disable: disable });
let scope = snapshot_scope(steps);

// --rollback: только откат, без установки. stdin — {domains?, routing_opts?} для teardown'ов.
if (length(ARGV) > 0 && ARGV[0] == "--rollback") {
	rollback_all(steps, cfg);
	warn("install: откат выполнен (--rollback)\n");
	exit(0);
}

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
	// Пароль root — не транзакция (см. steps/rootpass): применяем на успешном пути, отдельно от
	// uci-снимка. Сбой passwd не валит установку — честный warning, пароль вторичен к data-plane.
	if (cfg.root_password) {
		let rc = run_stdin(sprintf("ucode -R %s/steps/rootpass/apply.uc", ENGINE),
			sprintf("%J", { root_password: cfg.root_password }));
		if (rc != 0)
			warn("install: пароль root не применился — установите вручную по SSH\n");
	}
	printf("install: успешно — %s\n", outcome.reason);
	exit(0);
}

// rollback: единая реализация (см. rollback_all выше).
warn(sprintf("install: откат — %s\n", outcome.reason));
rollback_all(steps, cfg);
warn("install: откат выполнен — система возвращена к состоянию до установки\n");
exit(1);
