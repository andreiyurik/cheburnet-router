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

import { stdin, readfile, writefile, unlink } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { enabled_steps, snapshot_scope, dirty_steps, decide_outcome,
         tunnel_info, disabled_tunnels, default_protocol, handshake_state,
         protocol_ids } from "./install.uc";
import { parse_wan_route } from "../preflight/parse.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/
const ETC_CHEBURNET = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";

// set_step(name) — отметить текущий шаг для install_progress (веб-мастер показывает «Шаг: …»).
// Путь даёт ubus-слой через env STATE_FILE (см. rpcd-cheburnet spawn_bg). Нет env (CLI-запуск)
// → no-op: прогресс-индикация нужна только фоновой установке из мастера.
let STATE_FILE = getenv("STATE_FILE");
function set_step(name) {
	if (STATE_FILE) writefile(STATE_FILE, name + "\n");
}

// set_reason(code) — машинный код исхода (decide_outcome.code) для install_progress.reason:
// по нему веб-мастер различает «VPN-сервер не ответил» / «упал шаг X» / «preflight» и говорит
// с пользователем адресно. Путь даёт ubus-слой через env (см. spawn_bg); CLI-запуск — no-op.
let REASON_FILE = getenv("REASON_FILE");
function set_reason(code) {
	if (REASON_FILE) writefile(REASON_FILE, code + "\n");
}

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

// tunnel_ok(cfg, iface) — ОДНА проба готовности туннеля (без ожидания). reality (Full): туннель —
// userspace-сервис sing-box → «процесс жив» (глубокая проверка — QEMU/железо). awg (Light): по
// latest-handshakes — "up" (рукопожатие было) или "none" (vpn не настраивался) считаем готовым,
// "waiting" (peer есть, рукопожатия ещё нет) — нет.
function tunnel_ok(cfg, iface) {
	if ((cfg.protocol ?? default_protocol()) == "reality")
		return trim(sh("pgrep -x sing-box >/dev/null 2>&1; echo $?")) == "0";
	return handshake_state(sh(sprintf("awg show %s latest-handshakes 2>/dev/null", iface))) != "waiting";
}

// dns_ok() — ОДНА проба: резолвится ли имя через локальный dnsmasq (127.0.0.1).
function dns_ok() {
	return trim(sh("nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; echo $?")) == "0";
}

// Health-check: и DNS, и туннель должны подняться ДО commit. КЛЮЧЕВОЕ — поллим ОБА в одном окне
// (~30с): шаги dns/doh/vpn только что (пере)настроили dnsmasq, https-dns-proxy и awg0 — сервисам
// нужно несколько секунд на тёплый старт (AWG-handshake: initiation+ответ сервера ~5–15с; DoH:
// https-dns-proxy поднимается не мгновенно). Любая МГНОВЕННАЯ проверка ловила бы этот старт и
// откатывала рабочую установку (исходный баг). Успех — как только ОБА условия выполнены.
function healthcheck(cfg) {
	let iface = (cfg.routing_opts && cfg.routing_opts.tunnel_if) ? cfg.routing_opts.tunnel_if : "awg0";
	let dns = false, tun = false;
	for (let i = 0; i < 15; i++) {
		if (!dns) dns = dns_ok();
		if (!tun) tun = tunnel_ok(cfg, iface);
		if (dns && tun) return true;
		sh("sleep 2");
	}
	return dns && tun;
}

// rollback_all(steps, cfg) — ЕДИНСТВЕННАЯ реализация отката: вернуть чистые конфиги из снимка
// + снять правила грязных шагов (safe-fail). Зовётся отсюда (упавшая установка) и ubus-слоем
// через `run.uc --rollback` (отмена установки) — знание «как откатывать» не дрейфует по слоям.
function rollback_all(steps, cfg) {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
	let dirty = dirty_steps(steps);
	for (let i = 0; i < length(dirty); i++)
		run_stdin(step_cmd(dirty[i], " --teardown"), step_stdin({ name: dirty[i], needs: "domains" }, cfg));

	// Snapshot вернул uci-КОНФИГИ, но РАНТАЙМ ещё несёт изменения установки, и сам по себе он не
	// сойдётся с конфигом: netifd держит default через awg0 (route_allowed_ips=1, см. vpn-шаг) и НЕ
	// вернёт WAN-дефолт, пока его не передёрнуть; dnsmasq резолвит через (возможно мёртвый) DoH.
	// Без переприменения сервисов провал установки оставит LAN-клиентов БЕЗ интернета (kill-switch
	// в туннель, которого нет; DNS через https-dns-proxy, который не встал). network restart —
	// детерминированно (reload недостаточно для снятия awg0+возврата дефолта), на пути отката
	// (уже не happy-path) краткий разрыв LAN приемлем ради гарантированного восстановления.
	sh("/etc/init.d/network restart >/dev/null 2>&1");
	sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
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

// WAN (интерфейс + шлюз) для kill-switch и default-маршрута direct-таблицы. Веб-мастер их НЕ
// передаёт (пользователь не вводит имена интерфейсов) — определяем САМИ, динамически, не
// хардкодим (урок v1). Первичный источник — netifd: он знает WAN, даже когда kernel-default
// уже у туннеля (пере-установка поверх рабочей; детект по `ip route` там находил awg0/ничего).
// Шлюз обязателен для ethernet-WAN: без via ядро ARP-ит публичные IP прямо в линк, апстрим
// proxy-ARP не делает → direct-путь молча мёртв (доказано живым прогоном 2026-07-08).
// PPPoE/p2p отдаёт маршрут без nexthop — там dev-only корректен.
if (type(cfg.routing_opts.wan_if) != "string" || length(cfg.routing_opts.wan_if) == 0) {
	let wr = parse_wan_route(sh("ubus call network.interface.wan status 2>/dev/null"));
	if (!wr) {
		// Фолбэк (нестандартное имя WAN-логики в netifd): дефолт-маршрут, минуя туннели.
		let tunnels = {};
		for (let p in protocol_ids())
			tunnels[tunnel_info(p).tunnel_if] = true;
		let defs = split(trim(sh("ip route show default 2>/dev/null")), "\n");
		for (let i = 0; i < length(defs); i++) {
			let dev = match(defs[i], /dev ([^ ]+)/);
			if (!dev || tunnels[dev[1]])
				continue;
			let gw = match(defs[i], /via ([0-9.]+)/);
			wr = { wan_if: dev[1], wan_gw: gw ? gw[1] : null };
			break;
		}
	}
	if (wr) {
		cfg.routing_opts.wan_if = wr.wan_if;
		if (wr.wan_gw)
			cfg.routing_opts.wan_gw = wr.wan_gw;
	}
}

// Отключаем неактивные туннель-шаги (vpn/singbox взаимоисключающие) + пользовательский disable.
let disable = disabled_tunnels(protocol);
if (type(cfg.disable) == "array")
	for (let i = 0; i < length(cfg.disable); i++) push(disable, cfg.disable[i]);

let steps = enabled_steps({ disable: disable });
let scope = snapshot_scope(steps);

// restore_cfg_truth() — вернуть install.json к состоянию ДО этой попытки установки.
// Файл — признак «установлено» для m_status, а m_install пишет его до исхода: был прежний
// (пере-установка поверх рабочей) — восстановить из .prev, не было — удалить. Иначе провал/
// отмена оставляли фантомное installed=true, и мастер после отката открывал «панель» пустой
// системы (поймано живым провал-прогоном 2026-07-09).
function restore_cfg_truth() {
	let f = ETC_CHEBURNET + "/install.json";
	let out = sh(sprintf("[ -f %s.prev ] && mv %s.prev %s && echo restored", f, f, f));
	if (index(out, "restored") < 0)
		unlink(f);
}

// --rollback: только откат, без установки. stdin — {domains?, routing_opts?} для teardown'ов.
// Зовёт install_cancel — отменённая установка тоже не должна оставлять фантомный install.json.
if (length(ARGV) > 0 && ARGV[0] == "--rollback") {
	rollback_all(steps, cfg);
	restore_cfg_truth();
	warn("install: откат выполнен (--rollback)\n");
	exit(0);
}

// --- 1. preflight (гейткипер) ---
set_step("preflight");
let facts = sh(sprintf("ucode -R %s/preflight/gather.uc", ENGINE));
let pf_rc = run_stdin(sprintf("ucode -R %s/preflight/check.uc", ENGINE), facts);
let preflight = { ok: (pf_rc == 0) };

if (!preflight.ok) {
	// Отчёт preflight уже напечатан check.uc выше (его stdout унаследован). Прерываемся, но
	// правду install.json возвращаем и здесь: abort гейткипера — такой же не-успех, как rollback
	// (иначе фантомное installed=true — тот же баг, что чинили на ветках отката 2026-07-09).
	restore_cfg_truth();
	let d = decide_outcome({ preflight: preflight });
	set_reason(d.code);
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
set_step("snapshot");
sh(sprintf("ucode -R %s/rollback/snapshot.uc save", ENGINE));

// --- 3. шаги по порядку (fail-fast) ---
let results = [];
for (let i = 0; i < length(steps); i++) {
	let s = steps[i];
	set_step(s.name); // веб-мастер покажет «Шаг: vpn/dns/doh/wifi/firewall»
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
if (all_ok) set_step("health-check"); // поднятие туннеля+DNS — самый долгий этап (до ~30с)
let health = all_ok ? { ok: healthcheck(cfg) } : null;

// --- 5. решение: commit / rollback ---
let outcome = decide_outcome({ preflight: preflight, steps: results, health: health });
if (outcome.action == "commit") {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc commit", ENGINE));
	// WAN нашли МЫ (детект выше), мастер его не знает → персистим в install.json: set_mode
	// переприменяет firewall через rpcd БЕЗ run.uc, а без wan_if kill-switch не строится
	// (firewall-план честно откажет). tunnel_if — туда же (NAT-зона при переприменении).
	let cfg_file = ETC_CHEBURNET + "/install.json";
	let saved_raw = readfile(cfg_file);
	let saved = (saved_raw && substr(trim(saved_raw), 0, 1) == "{") ? json(saved_raw) : null;
	if (saved && cfg.routing_opts.wan_if) {
		if (type(saved.routing_opts) != "object") saved.routing_opts = {};
		saved.routing_opts.wan_if = cfg.routing_opts.wan_if;
		if (cfg.routing_opts.wan_gw)
			saved.routing_opts.wan_gw = cfg.routing_opts.wan_gw;
		saved.routing_opts.tunnel_if = cfg.routing_opts.tunnel_if;
		writefile(cfg_file, sprintf("%J\n", saved));
	}
	// Пароль root — не транзакция (см. steps/rootpass): применяем на успешном пути, отдельно от
	// uci-снимка. Сбой passwd не валит установку — честный warning, пароль вторичен к data-plane.
	if (cfg.root_password) {
		let rc = run_stdin(sprintf("ucode -R %s/steps/rootpass/apply.uc", ENGINE),
			sprintf("%J", { root_password: cfg.root_password }));
		if (rc != 0)
			warn("install: пароль root не применился — установите вручную по SSH\n");
	}
	// Install-токен одноразовый: установка удалась → пропуск использован, снимаем его (иначе он
	// продолжал бы пускать install/apply_lan_ip любого в LAN). Только на commit-пути: при откате
	// токен ОСТАЁТСЯ, чтобы пользователь исправил данные и повторил тем же токеном без bootstrap.
	unlink(ETC_CHEBURNET + "/install-token");
	unlink(ETC_CHEBURNET + "/install.json.prev"); // бэкап прежнего cfg больше не нужен
	printf("install: успешно — %s\n", outcome.reason);
	exit(0);
}

// rollback: единая реализация (см. rollback_all выше).
set_reason(outcome.code);
warn(sprintf("install: откат — %s\n", outcome.reason));
rollback_all(steps, cfg);
restore_cfg_truth();
warn("install: откат выполнен — система возвращена к состоянию до установки\n");
exit(1);
