// test_rpcd.uc — интеграционный тест фасада rpcd-cheburnet В SANDBOX (host-only, без роутера).
//
// Юниты ubus.uc проверяют чистое ядро (валидация/ACL); здесь — то, что живёт ТОЛЬКО в фасаде
// и раньше проверялось лишь в QEMU: диспетчер, токен-гейт, confirm-word, взаимное исключение
// операций (PID-файл), state-машина install_progress и СИНХРОННАЯ валидация туннель-конфигов.
// Фасад запускается как subprocess (как его зовёт rpcd) с env-override STATE_DIR/ETC_CHEBURNET —
// ровно тот sandbox-механизм, ради которого override и заведён.
//
// ВАЖНО: тестируем только отказные и read-only ветки. Ни один случай не должен доходить до
// spawn_bg (фоновые run.uc/reset.uc) — конфиги в тестах намеренно битые, гейты — закрытые.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { sh } from "../../lib/proc.uc";
import { writefile, readfile, unlink, mkdir, access } from "fs";

const HERE = sourcepath(0, true);
const RPCD = HERE + "/../rpcd-cheburnet";

// Sandbox: свой STATE_DIR/ETC_CHEBURNET на весь прогон; между случаями чистим содержимое.
const SB    = trim(sh("mktemp -d"));
const STATE = SB + "/state";
const ETC   = SB + "/etc";
const BIN   = SB + "/bin"; // для стаба sing-box (PATH-префикс)

if (length(SB) == 0 || substr(SB, 0, 1) != "/")
	die("mktemp -d не дал sandbox-каталог");

// PID живого процесса на всё время прогона: $PPID дочернего sh — это сам ucode-тест.
const LIVE_PID = trim(sh("echo $PPID"));

function shq(s) {
	return "'" + replace(s ?? "", "'", "'\\''") + "'";
}

// rpc(method, args, opts) → распарсенный JSON-ответ фасада (null, если ответ не JSON).
// opts.with_singbox — подсунуть стаб sing-box через PATH-префикс (гейты Full-тира).
function rpc(method, args, opts) {
	opts = opts ?? {};
	let env = sprintf("STATE_DIR=%s ETC_CHEBURNET=%s", STATE, ETC);
	if (opts.with_singbox)
		env = sprintf("PATH=%s:$PATH %s", BIN, env);
	let cmd = sprintf("printf '%%s' %s | %s ucode -R %s call %s 2>/dev/null",
		shq(sprintf("%J", args ?? {})), env, RPCD, method);
	let out = sh(cmd);
	return (substr(trim(out), 0, 1) == "{") ? json(out) : null;
}

// reset_sb() — чистый sandbox перед случаем (идемпотентность фасада между случаями не тема
// этого теста; каждый случай собирает своё состояние с нуля).
function reset_sb() {
	sh(sprintf("rm -rf %s %s && mkdir -p %s %s", STATE, ETC, STATE, ETC));
}

// Частые кирпичи состояния.
function put_token(v)  { writefile(ETC + "/install-token", v + "\n"); }
function put_cfg(obj)  { writefile(ETC + "/install.json", sprintf("%J\n", obj)); }
function put_live_pid() { writefile(STATE + "/pid", LIVE_PID + "\n"); }

function err_has(resp, frag, msg) {
	ok(resp != null, (msg ?? "") + ": ответ — JSON");
	ok(type(resp.error) == "string" && index(resp.error, frag) >= 0,
		sprintf("%s: error содержит %J, got %J", msg ?? "err_has", frag, resp.error));
}

// Стаб sing-box: пустой исполняемый файл — command -v его находит, запускать его никто не должен.
mkdir(BIN, 0o755);
writefile(BIN + "/sing-box", "#!/bin/sh\nexit 0\n");
sh(sprintf("chmod +x %s/sing-box", BIN));

// === точка входа rpcd: list / call ===

test("list: дескриптор методов — JSON со всеми методами реестра", () => {
	reset_sb();
	let out = sh(sprintf("ucode -R %s list", RPCD));
	let d = json(out);
	ok(type(d) == "object", "дескриптор — объект");
	for (m in ["preflight", "status", "install", "install_progress", "factory_reset",
	           "switch_to_reality", "switch_to_awg"])
		ok(exists(d, m), "метод в дескрипторе: " + m);
});

test("call без метода в реестре → error (граница валидации подключена)", () => {
	reset_sb();
	let r = rpc("no_such_method", {});
	ok(r != null && type(r.error) == "string", "неизвестный метод отбит ошибкой");
});

test("call set_mode с невалидным enum → error ДО любого применения", () => {
	reset_sb();
	let r = rpc("set_mode", { mode: "banana" });
	ok(r != null && type(r.error) == "string", "кривой mode отбит");
	ok(!access(ETC + "/install.json"), "конфигурация не создана при отбитом входе");
});

// === токен-гейт (центральный, по requires_token из реестра) ===

test("install без файла токена → понятная ошибка про bootstrap", () => {
	reset_sb();
	let r = rpc("install", { awg_conf: "x", root_password: "12345678", token: "whatever" });
	err_has(r, "install-токен не найден", "нет файла токена");
});

test("install с неверным токеном → отбит до обработчика", () => {
	reset_sb();
	put_token("SECRET-123");
	let r = rpc("install", { awg_conf: "x", root_password: "12345678", token: "WRONG" });
	err_has(r, "неверный install-токен", "чужой токен");
	ok(!access(ETC + "/install.json"), "конфигурация не тронута");
});

test("apply_lan_ip: верный токен пропускает к границе ip (гейт и валидация в связке)", () => {
	reset_sb();
	put_token("SECRET-123");
	let r = rpc("apply_lan_ip", { ip: "10.0.0.1", token: "SECRET-123" });
	err_has(r, "192.168", "не-LAN ip отбит после токен-гейта");
});

// === синхронная валидация туннель-конфигов (validate_tunnel_conf через реальные plan.uc) ===

test("install: битый AWG-конфиг отбивается синхронно, установка не стартует", () => {
	reset_sb();
	put_token("T");
	let r = rpc("install", { awg_conf: "не конфиг вовсе", root_password: "12345678", token: "T" });
	err_has(r, "AWG-конфиг не разобран", "битый awg");
	ok(!access(ETC + "/install.json"), "install.json не создан — фон не стартовал");
	ok(!access(STATE + "/pid"), "PID-файл не создан — фон не стартовал");
});

test("install: битая Reality-ссылка → адресная причина из singbox/plan.uc", () => {
	reset_sb();
	put_token("T");
	let r = rpc("install", { protocol: "reality", reality_conf: "мусор",
		root_password: "12345678", token: "T" });
	err_has(r, "ссылка Reality не разобрана", "битый reality");
	ok(!access(STATE + "/reality-validate.txt"), "временный файл с секретом удалён");
});

test("install: пустой reality_conf → подсказка про vless://", () => {
	reset_sb();
	put_token("T");
	let r = rpc("install", { protocol: "reality", reality_conf: "   ",
		root_password: "12345678", token: "T" });
	err_has(r, "vless://", "пустой reality-конфиг");
});

// === взаимное исключение длинных операций (PID-файл) ===

test("живой PID без done-маркера блокирует мутации («операция уже выполняется»)", () => {
	reset_sb();
	put_live_pid();
	for (m in [["set_mode", { mode: "home" }],
	           ["service_restart", { service: "dns" }],
	           ["set_dns_provider", { provider: "quad9" }],
	           ["update_list", {}]]) {
		let r = rpc(m[0], m[1]);
		err_has(r, "операция уже выполняется", m[0]);
	}
});

test("done-маркер гасит живой PID (переиспользованный pid не блокирует навсегда)", () => {
	reset_sb();
	put_live_pid();
	writefile(STATE + "/done", "0\n");
	// set_mode пройдёт гейт и упадёт дальше на применении шага (на хосте нет uci) —
	// важно, что это НЕ «операция уже выполняется».
	let r = rpc("set_mode", { mode: "home" });
	ok(r != null && type(r.error) == "string" &&
		index(r.error, "операция уже выполняется") < 0,
		"после done PID-гейт открыт");
});

// === state-машина install_progress ===

test("install_progress: done=0 → result=ok", () => {
	reset_sb();
	writefile(STATE + "/done", "0\n");
	writefile(STATE + "/state", "health-check\n");
	let r = rpc("install_progress", {});
	eq(r.done, true, "done");
	eq(r.result, "ok", "result");
	eq(r.running, false, "running");
	eq(r.step, "health-check", "step из STATE_FILE");
});

test("install_progress: done=cancelled → result=cancelled", () => {
	reset_sb();
	writefile(STATE + "/done", "cancelled\n");
	let r = rpc("install_progress", {});
	eq(r.done, true, "done");
	eq(r.result, "cancelled", "result");
});

test("install_progress: ненулевой код + reason → result=fail с машинной причиной", () => {
	reset_sb();
	writefile(STATE + "/done", "7\n");
	writefile(STATE + "/reason", "health\n");
	writefile(STATE + "/install.log", "шаг health-check упал\n");
	let r = rpc("install_progress", {});
	eq(r.result, "fail", "result");
	eq(r.reason, "health", "reason прокинут для адресной диагностики UI");
	ok(index(r.log, "health-check") >= 0, "хвост лога отдан");
});

test("install_progress: процесс мёртв без done-маркера, лог есть → crashed", () => {
	reset_sb();
	writefile(STATE + "/install.log", "оборвалось\n");
	// PID-файла нет вовсе → pid_alive()=false; done нет → упавшая операция.
	let r = rpc("install_progress", {});
	eq(r.done, true, "done");
	eq(r.result, "crashed", "result");
});

test("install_progress: свежая система (ничего нет) → idle, не done", () => {
	reset_sb();
	let r = rpc("install_progress", {});
	eq(r.step, "idle", "step по умолчанию");
	eq(r.done, false, "нет ни done, ни лога → операция не шла");
});

// === factory_reset: confirm-word ===

test("factory_reset: confirm≠RESET отбит ДО всего остального", () => {
	reset_sb();
	put_live_pid(); // даже при «занято» первым должен сработать confirm-гейт
	let r = rpc("factory_reset", { confirm: "reset" });
	err_has(r, 'ровно "RESET"', "регистр важен");
});

test("factory_reset: верный confirm при занятой операции → блок по PID (фон не стартует)", () => {
	reset_sb();
	put_live_pid();
	let r = rpc("factory_reset", { confirm: "RESET" });
	err_has(r, "операция уже выполняется", "PID-гейт после confirm");
});

// === гейты переключения туннеля (switch_to_reality / switch_to_awg) ===

test("switch_to_reality: без install.json → «сначала мастер»", () => {
	reset_sb();
	let r = rpc("switch_to_reality", { reality_conf: "x" });
	err_has(r, "ещё не настроена", "нет конфигурации");
});

test("switch_to_reality: без sing-box → подсказка включить Full-тир", () => {
	// На хосте с установленным sing-box ветка недостижима — честный скип, не ложный провал.
	if (length(trim(sh("command -v sing-box"))) > 0) return;
	reset_sb();
	put_cfg({ protocol: "awg" });
	let r = rpc("switch_to_reality", { reality_conf: "x" });
	err_has(r, "sing-box не установлен", "нет бинаря");
});

test("switch_to_reality: уже reality → отправляет в «Замену Reality-сервера»", () => {
	reset_sb();
	put_cfg({ protocol: "reality" });
	let r = rpc("switch_to_reality", { reality_conf: "x" }, { with_singbox: true });
	err_has(r, "уже используется VLESS+Reality", "повторный свитч");
});

test("switch_to_reality: битая ссылка → синхронный отказ, protocol в cfg не тронут", () => {
	reset_sb();
	put_cfg({ protocol: "awg" });
	let r = rpc("switch_to_reality", { reality_conf: "мусор" }, { with_singbox: true });
	err_has(r, "ссылка Reality не разобрана", "битая ссылка");
	let cfg = json(readfile(ETC + "/install.json"));
	eq(cfg.protocol, "awg", "protocol не переключён при отказе");
	ok(!access(ETC + "/install.json.prev"), ".prev не создан — до свитча не дошло");
});

test("switch_to_awg: без install.json → «сначала мастер»", () => {
	reset_sb();
	let r = rpc("switch_to_awg", { awg_conf: "x" });
	err_has(r, "ещё не настроена", "нет конфигурации");
});

test("switch_to_awg: уже awg → отправляет в «Замену VPN-конфига»", () => {
	reset_sb();
	put_cfg({ protocol: "awg" });
	let r = rpc("switch_to_awg", { awg_conf: "x" });
	err_has(r, "уже используется AmneziaWG", "повторный свитч");
});

test("switch_to_awg: битый .conf → синхронный отказ, protocol не тронут", () => {
	reset_sb();
	put_cfg({ protocol: "reality" });
	let r = rpc("switch_to_awg", { awg_conf: "не ini" });
	err_has(r, "AWG-конфиг не разобран", "битый conf");
	let cfg = json(readfile(ETC + "/install.json"));
	eq(cfg.protocol, "reality", "protocol не переключён при отказе");
});

// === гейты замены конфига активного туннеля ===

test("replace_awg_conf: активен reality → отсылка к правильной кнопке", () => {
	reset_sb();
	put_cfg({ protocol: "reality" });
	let r = rpc("replace_awg_conf", { awg_conf: "x" });
	err_has(r, "VLESS+Reality", "не тот активный туннель");
});

test("replace_reality_conf: активен awg → отказ (защита живого awg0 от half-routes)", () => {
	reset_sb();
	put_cfg({ protocol: "awg" });
	let r = rpc("replace_reality_conf", { reality_conf: "x" });
	err_has(r, "AmneziaWG", "не тот активный туннель");
});

// === install_full_tier ===

test("install_full_tier: sing-box уже стоит → отказ без запуска установщика", () => {
	reset_sb();
	let r = rpc("install_full_tier", {}, { with_singbox: true });
	err_has(r, "уже установлен", "повторная догрузка");
	ok(!access(STATE + "/pid"), "фон не стартовал");
});

// === status: дефолты воспроизводимой конфигурации (load_cfg) ===

test("status: свежая система → installed=false, дефолтный protocol/mode", () => {
	reset_sb();
	let r = rpc("status", {});
	eq(r.installed, false, "нет install.json");
	eq(r.installing, false, "фон не идёт");
	eq(r.protocol, "awg", "дефолтный туннель — Light");
	eq(r.mode, "home", "дефолтный режим");
	eq(r.direct_domains, 0, "домены не настроены");
	eq(r.direct_list_loaded, false, "community-кэша нет");
});

test("status: частичный install.json → недостающие поля добиты дефолтами", () => {
	reset_sb();
	put_cfg({ protocol: "reality" }); // без routing_opts/domains/dns_provider
	writefile(ETC + "/direct-list", "example.com\n# комментарий\nexample.org\n");
	let r = rpc("status", {});
	eq(r.installed, true, "install.json есть");
	eq(r.protocol, "reality", "protocol из конфигурации");
	eq(r.mode, "home", "mode добит дефолтом");
	ok(type(r.dns_provider) == "string" && length(r.dns_provider) > 0, "dns_provider добит дефолтом");
	eq(r.imported_domains, 2, "комментарии в кэше не считаются");
	eq(r.direct_list_loaded, true, "кэш распознан");
});

// === check_lan_conflict: на хосте фактов нет → честное «проверять нечего» ===

test("check_lan_conflict без фактов сети → conflict=false с причиной", () => {
	reset_sb();
	let r = rpc("check_lan_conflict", {});
	eq(r.conflict, false, "без lan/wan cidr конфликт не выдумывается");
	ok(type(r.reason) == "string", "причина объяснена");
});

let rc = summary();
sh(sprintf("rm -rf %s", SB));
exit(rc);
