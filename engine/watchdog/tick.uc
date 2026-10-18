// tick.uc — ОДИН тик сторожа (импурно, router-side): собрать инварианты → решить → починить.
//   ucode -R tick.uc          # так его зовёт cron (раз в 5 минут, см. cron.uc)
// ЧТО должно быть истинно — engine/invariants; ЧЕМ чинить — те же шаги, что зовёт установка
// (watchdog.repair_cmd, под юнитами). Здесь только склейка и лог.

import { readfile, writefile, access, mkdir, unlink } from "fs";
import { sh, shellquote } from "../lib/proc.uc";
import { evaluate } from "../invariants/invariants.uc";
import { decide, repair_cmd, SETTLE_S } from "./watchdog.uc";
import { decide_failover, name_of, FAILOVER_AFTER } from "../profiles/profiles.uc";
import { load as profiles_load, conf_path } from "../profiles/store.uc";

const STATE_DIR = getenv("STATE_DIR")     ?? "/tmp/cheburnet";
const ETC       = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
const STATE_FILE = STATE_DIR + "/watchdog.json";
const FAILOVER_FILE = STATE_DIR + "/failover.json";
let ENGINE = getenv("ENGINE_DIR") ?? (sourcepath(0, true) + "/..");

// busy() — идёт длинная операция движка? Конвенция та же, что у ubus-слоя: pid-файл + done-маркер
// (переиспользованный pid — реальный случай, поэтому done-маркер гасит проверку).
function busy() {
	if (access(STATE_DIR + "/done")) return false;
	let pid = trim(readfile(STATE_DIR + "/pid") ?? "");
	if (length(pid) == 0) return false;
	return trim(sh(sprintf("kill -0 %s 2>/dev/null; echo $?", pid))) == "0";
}

function load_cfg() {
	let raw = readfile(ETC + "/install.json");
	return (raw && substr(trim(raw), 0, 1) == "{") ? json(raw) : {};
}

function log(line) {
	sh(sprintf("logger -t cheburnet-watchdog %s", shellquote(line)));
}

// Факты собираем тем же gather, что зовут диагностика и тесты. Не собрались (нет команд, битый
// вывод) — молча выходим: сторож не имеет права действовать по недостоверным фактам.
let facts_raw = trim(sh(sprintf("ucode -R %s/invariants/gather.uc 2>/dev/null", ENGINE)));
if (substr(facts_raw, 0, 1) != "{")
	exit(0);

let raw_state = readfile(STATE_FILE);
let state = (raw_state && substr(trim(raw_state), 0, 1) == "{") ? json(raw_state) : {};

// uptime — первое число /proc/uptime (секунды). Не прочиталось → null: гейт не выдумываем.
// UPTIME_S — override только для host-тестов (tests/test_tick.uc), как STATE_DIR/ENGINE_DIR.
let up_m = match(trim(getenv("UPTIME_S") ?? readfile("/proc/uptime") ?? ""), /^([0-9]+)/);
let uptime = up_m ? int(up_m[1]) : null;

let facts = json(facts_raw);
let is_busy = busy();
let d = decide(evaluate(facts), state, is_busy, uptime);

for (let i = 0; i < length(d.log); i++)
	log(d.log[i]);

if (d.action) {
	// Перечитываем install.json ПЕРЕД починкой: между сбором фактов и этим местом человек мог нажать
	// «Выключить защиту» (install/pause.uc) — вернуть ему маршрут в мёртвый туннель значило бы
	// отменить его решение и снова оставить дом без интернета.
	let cfg = load_cfg();
	let cmd = (cfg.paused === true) ? null : repair_cmd(d.action, cfg, ENGINE);
	if (cmd) {
		let rc = int(trim(sh(cmd + " >/dev/null 2>&1; echo $?")));
		// Успех не логируем: следующий тик либо промолчит (починилось), либо посчитает попытку.
		if (rc != 0)
			log(sprintf("починка (%s) вернула код %d", d.action, rc));
	}
}

if (!access(STATE_DIR))
	mkdir(STATE_DIR, 0o755);
writefile(STATE_FILE, sprintf("%J\n", d.state));

// --- автосмена сервера (engine/profiles) — только если инварианты сами ничего не чинили в этом тике ---

// wan_online(wan_if) — есть ли интернет МИМО туннеля: ping, привязанный к WAN-интерфейсу (half-routes
// на awg0 его не перехватывают). Два адреса — один бывает недоступен сам по себе.
function wan_online(wan_if) {
	if (!wan_if) return false;
	return trim(sh(sprintf("ping -c 1 -W 3 -I %s 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 -I %s 8.8.8.8 >/dev/null 2>&1; echo $?",
		shellquote(wan_if), shellquote(wan_if)))) == "0";
}

// switch_profile(id) → true | false | null — та же замена сервера, что из панели (snapshot → handshake →
// commit/restore), под тем же замком pid/done. null — замок занят: между началом тика и этим местом
// (пинги — до 6 с) панель могла запустить свою операцию. ШРАМ (ревью): две замены разом перетирают
// снимок друг друга, и откат возвращает непроверенный сервер. Перепроверка — вплотную к захвату.
function switch_profile(id) {
	if (busy()) return null;
	writefile(STATE_DIR + "/pid", trim(sh("echo $PPID")) + "\n");
	unlink(STATE_DIR + "/done");
	unlink(STATE_DIR + "/reason"); // причина прошлой операции не должна достаться этой
	writefile(STATE_DIR + "/state", "replacing-vpn\n");
	// >> — журнал прошлой операции человека (его провал) не затираем: он нужен для диагностики.
	let logf = STATE_DIR + "/install.log";
	sh(sprintf("echo '--- автосмена сервера ---' >> %s", logf));
	let rc = trim(sh(sprintf("ucode -R %s/install/replace_vpn.uc --profile %s --auto < %s >>%s 2>&1; echo $?",
		ENGINE, id, conf_path(id), logf)));
	writefile(STATE_DIR + "/done", rc + "\n");
	return rc == "0";
}

if (!d.action) {
	let cfg = load_cfg();
	let pst = profiles_load();
	let raw_fo = readfile(FAILOVER_FILE);
	let prev = (raw_fo && substr(trim(raw_fo), 0, 1) == "{") ? json(raw_fo) : {};
	let eligible = pst.auto && facts.protocol == "awg" && cfg.paused !== true && !is_busy
		&& (uptime == null || uptime >= SETTLE_S);
	let alive = (facts.tunnel_alive === true);
	// Пинг — только когда решение от него зависит (туннель мёртв достаточно долго), а не каждый тик.
	let wan = (eligible && !alive && length(pst.profiles) >= 2 && (prev.dead ?? 0) + 1 >= FAILOVER_AFTER)
		? wan_online(facts.wan_if) : null;
	let f = decide_failover({ st: pst, eligible: eligible, tunnel_alive: alive, wan_online: wan }, prev);
	for (let i = 0; i < length(f.log); i++)
		log(f.log[i]);
	if (f.action) {
		let from = name_of(pst, pst.active), to = name_of(pst, f.action.profile);
		let ok = switch_profile(f.action.profile);
		if (ok == null)
			f.state = prev; // занято панелью — попробуем на следующем тике, кандидата не «тратим»
		else if (ok) {
			log(sprintf("сервер «%s» недоступен — подключён «%s»", from ?? "прежний", to));
			f.state = {}; // работающий сервер найден — остаёмся на нём, счёт заново
		} else
			log(sprintf("«%s» тоже не ответил — прежний сервер возвращён", to));
	}
	writefile(FAILOVER_FILE, sprintf("%J\n", f.state));
}
exit(0);
