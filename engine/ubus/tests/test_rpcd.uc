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
// opts.with_singbox — подсунуть стаб sing-box через PATH-префикс (гейты Full-тира);
// opts.engine — ENGINE_DIR с заглушками длинных операций (какой CLI фасад зовёт и с чем).
function rpc(method, args, opts) {
	opts = opts ?? {};
	let env = sprintf("STATE_DIR=%s ETC_CHEBURNET=%s", STATE, ETC);
	if (opts.with_singbox)
		env = sprintf("PATH=%s:$PATH %s", BIN, env);
	if (opts.engine)
		env = sprintf("ENGINE_DIR=%s %s", shq(opts.engine), env);
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

const AWG_OK = "[Interface]\nPrivateKey = k=\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = p=\nEndpoint = 192.0.2.1:51820\n";

// stub_run() → «движок», где install/run.uc ничего не делает (switch_to_awg не трогает систему), а
// валидатор AWG — настоящий (steps/vpn/plan.uc нужен валидации до фона).
function stub_run() {
	let dir = SB + "/engine-run";
	sh(sprintf("rm -rf %s; mkdir -p %s/install %s/steps; cp -r %s/../../steps/vpn %s/steps/; cp -r %s/../../lib %s/",
		shq(dir), shq(dir), shq(dir), shq(HERE), shq(dir), shq(HERE), shq(dir)));
	writefile(dir + "/install/run.uc", "exit(0);\n");
	sh(sprintf("cp -r %s/../../list %s/ 2>/dev/null", shq(HERE), shq(dir)));
	return dir;
}

// === точка входа rpcd: list / call ===

test("list: дескриптор методов — JSON со всеми методами реестра", () => {
	reset_sb();
	let out = sh(sprintf("ucode -R %s list", RPCD));
	let d = json(out);
	ok(type(d) == "object", "дескриптор — объект");
	for (m in ["preflight", "status", "install", "install_progress", "factory_reset", "switch_to_awg"])
		ok(exists(d, m), "метод в дескрипторе: " + m);
	for (m in [ "switch_to_hysteria2", "replace_hysteria2_conf", "switch_to_reality",
	            "replace_reality_conf", "install_full_tier" ])
		ok(!exists(d, m), "заморожённого метода нет (ADR 0009/0010): " + m);
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

// Full-тир заморожен (ADR 0009/0010): установить Reality/Hysteria2 через RPC нельзя — отбивает enum ДО I/O.
test("install: protocol=reality|hysteria2 → отказ на границе, фон не стартует", () => {
	for (let proto in [ "reality", "hysteria2" ]) {
		reset_sb();
		put_token("T");
		let r = rpc("install", { protocol: proto, root_password: "12345678", token: "T" });
		err_has(r, "protocol must be one of", proto + ": enum без legacy");
		ok(!access(STATE + "/pid"), proto + ": фон не стартовал");
	}
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

// === уход с legacy Full-тира (ADR 0010): единственный путь — switch_to_awg ===

test("switch_to_awg: без install.json → «сначала мастер»", () => {
	reset_sb();
	err_has(rpc("switch_to_awg", { awg_conf: "x" }), "ещё не настроена", "нет конфигурации");
});

test("switch_to_awg: уже awg → отсылка к замене конфига", () => {
	reset_sb();
	put_cfg({ protocol: "awg" });
	err_has(rpc("switch_to_awg", { awg_conf: "x" }), "уже используется AmneziaWG", "повторный свитч");
});

test("switch_to_awg с legacy reality/hysteria2: битый .conf → отказ, протокол не тронут", () => {
	for (let proto in [ "reality", "hysteria2" ]) {
		reset_sb();
		put_cfg({ protocol: proto });
		err_has(rpc("switch_to_awg", { awg_conf: "мусор" }), "AWG-конфиг не разобран", proto);
		eq(json(readfile(ETC + "/install.json")).protocol, proto, proto + ": битый вход протокол не меняет");
		ok(!access(ETC + "/install.json.prev"), proto + ": .prev не создан — до свитча не дошло");
	}
});

// Роутер, оставшийся на заморожённом Full-тире: сервер не меняется, путь один — уйти на AWG.
test("replace_awg_conf: активен legacy reality → «больше не поддерживается… переключитесь на AmneziaWG»", () => {
	reset_sb();
	put_cfg({ protocol: "reality" });
	let r = rpc("replace_awg_conf", { awg_conf: "x" });
	err_has(r, "VLESS+Reality больше не поддерживается", "назван активный туннель и его статус");
	err_has(r, "переключитесь на AmneziaWG", "и выход");
});

// ШРАМ (ревью): устаревший active с версии, где на Reality уходили из AWG-профиля, затёр бы чужой .conf.
test("switch_to_awg с legacy без профиля: устаревший активный профиль сброшен до запуска", () => {
	reset_sb();
	put_cfg({ protocol: "reality", routing_opts: {} });
	sh(sprintf("mkdir -p %s/profiles", shq(ETC)));
	writefile(ETC + "/profiles.json", sprintf("%J", { profiles: [ { id: "p1", name: "Германия" } ], active: "p1", next_id: 2 }));
	let r = rpc("switch_to_awg", { awg_conf: AWG_OK }, { engine: stub_run() });
	eq(r.status, "started", sprintf("%J", r));
	eq(json(readfile(ETC + "/profiles.json")).active, null, "вставленный .conf станет новым «Сервером N»");
});

// ШРАМ (ревью): Full-тир ставился при ≥44 МБ флеша; после sing-box свободно меньше soft-порога AWG, и
// preflight закрыл бы единственный выход. Решение о железе принято при установке — не спрашиваем снова.
test("switch_to_awg с legacy: payload несёт accept_risk — soft-гейт железа выход не закрывает", () => {
	reset_sb();
	put_cfg({ protocol: "reality", routing_opts: {} });
	let r = rpc("switch_to_awg", { awg_conf: AWG_OK }, { engine: stub_run() });
	eq(r.status, "started", sprintf("%J", r));
	let p = json(readfile(STATE + "/install-payload.json"));
	eq(p.accept_risk, true, "accept_risk в payload");
	eq(p.protocol, "awg", "протокол попытки");
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

// forced — отметка «поставлено с пропуском проверок железа» (её пишет run.uc на commit).
// Она обязана дожить до панели И пережить перезапись конфигурации: панель по ней показывает
// честную плашку, а мейнтейнер видит на скриншоте статуса, с какого железа пришла жалоба.
test("status: forced доезжает до панели; свежая система → пустой список", () => {
	reset_sb();
	eq(length(rpc("status", {}).forced), 0, "нечего пропускать — пустой массив, не null");
	put_cfg({ protocol: "awg", forced: [ "ram", "flash" ] });
	let r = rpc("status", {});
	eq(length(r.forced), 2, "оба пропуска видны");
	eq(r.forced[0], "ram");
});

test("set_mode: forced переживает перезапись install.json (save_cfg его не теряет)", () => {
	reset_sb();
	put_cfg({ protocol: "awg", routing_opts: { mode: "home" }, forced: [ "ram" ] });
	rpc("set_mode", { mode: "travel" }); // применение на хосте провалится — важен cfg
	let cfg = json(readfile(ETC + "/install.json"));
	eq(length(cfg.forced ?? []), 1, "отметка на месте после смены режима");
	eq(cfg.forced[0], "ram");
});

// === set_mode: единая реализация переприменения ===
// ШРАМ: у set_mode была своя копия «переприменить firewall» без tunnel_if — на Full-тире она
// пересобирала NAT-зону под awg0. Теперь firewall идёт ТОЛЬКО через install/reapply.uc.

// stub_engine(rc) → каталог-«движок»: reapply.uc фиксирует вызов и выходит с rc, dns-шаг пишет payload.
function stub_engine(rc) {
	let dir = SB + "/engine";
	sh(sprintf("rm -rf %s; mkdir -p %s/install %s/steps/dns", shq(dir), shq(dir), shq(dir)));
	writefile(dir + "/install/reapply.uc",
		sprintf("import { writefile, readfile } from \"fs\";\nwritefile(%s, readfile(%s) ?? \"\");\nexit(%d);\n",
			shq(SB + "/reapply-seen.json"), shq(ETC + "/install.json"), rc));
	writefile(dir + "/steps/dns/apply.uc",
		sprintf("import { stdin, writefile } from \"fs\";\nwritefile(%s, stdin.read(\"all\") ?? \"\");\n",
			shq(SB + "/dns-payload.json")));
	return dir;
}

test("set_mode на Full-тире: firewall — через install/reapply.uc, режим сохранён ДО него", () => {
	reset_sb();
	sh(sprintf("rm -f %s/reapply-seen.json %s/dns-payload.json", shq(SB), shq(SB)));
	put_cfg({ protocol: "reality", routing_opts: { mode: "home", wan_if: "eth0", tunnel_if: "singtun0" },
	          domains: [ "example.com" ] });
	let r = rpc("set_mode", { mode: "travel" }, { engine: stub_engine(0) });
	eq(r.status, "ok", sprintf("ответ: %J", r));
	let seen = json(readfile(SB + "/reapply-seen.json"));
	eq(seen.routing_opts.mode, "travel", "reapply.uc читает режим из install.json — он уже новый");
	eq(seen.routing_opts.tunnel_if, "singtun0", "tunnel_if Full-тира не потерян");
	let dns = json(readfile(SB + "/dns-payload.json"));
	eq(dns.routing_opts.mode, "travel", "DNS-шаг получил тот же режим");
	eq(json(readfile(ETC + "/install.json")).routing_opts.mode, "travel");
});

test("set_mode: WAN не найден (reapply.uc → 2) → честная ошибка, прежний режим возвращён", () => {
	reset_sb();
	put_cfg({ protocol: "awg", routing_opts: { mode: "home", wan_if: "eth0" } });
	let r = rpc("set_mode", { mode: "travel" }, { engine: stub_engine(2) });
	err_has(r, "WAN не найден", "set_mode");
	eq(json(readfile(ETC + "/install.json")).routing_opts.mode, "home",
		"install.json отражает ПРИМЕНЁННОЕ состояние, а не желаемое");
});

test("set_mode на ненастроенном роутере → ошибка, ничего не применяется", () => {
	reset_sb();
	sh(sprintf("rm -f %s/reapply-seen.json", shq(SB)));
	let r = rpc("set_mode", { mode: "travel" }, { engine: stub_engine(0) });
	err_has(r, "не настроен", "set_mode");
	ok(!access(SB + "/reapply-seen.json"), "reapply.uc не вызывался");
});

// === set_domains / get_domains: свой список из панели без переустановки ===
// Стаб-движок: настоящий list/assemble.uc (валидация — его работа), dns-шаг пишет payload и
// выходит с заданным кодом.
function stub_engine_domains(dns_rc) {
	let dir = SB + "/engine-d";
	// list/assemble.uc тянет ../routing/routing.uc — копируем оба модуля целиком.
	sh(sprintf("rm -rf %s; mkdir -p %s/steps/dns; cp -r %s/../../list %s/list; cp -r %s/../../routing %s/routing",
		shq(dir), shq(dir), shq(HERE), shq(dir), shq(HERE), shq(dir)));
	writefile(dir + "/steps/dns/apply.uc",
		sprintf("import { stdin, writefile } from \"fs\";\nwritefile(%s, stdin.read(\"all\") ?? \"\");\nexit(%d);\n",
			shq(SB + "/dns-payload.json"), dns_rc));
	return dir;
}

test("set_domains: DNS-шаг получает user + импорт, install.json обновлён, мусор назван", () => {
	reset_sb();
	sh(sprintf("rm -f %s/dns-payload.json", shq(SB)));
	put_cfg({ protocol: "awg", routing_opts: { mode: "home", wan_if: "eth0" },
	          user_domains: [ "ru" ], domains: [ "ru" ] });
	writefile(ETC + "/direct-list", "imported.example\n");
	let r = rpc("set_domains", { domains: [ "Example.COM ", "bad..name", "", "ru" ] }, { engine: stub_engine_domains(0) });
	eq(r.status, "ok", sprintf("ответ: %J", r));
	eq(r.user_domains, 3, "пустые строки отброшены до счёта");
	eq(r.direct_domains, 3, "example.com + ru + imported.example; bad..name — нет");
	eq(join(",", r.rejected), "bad..name", "панели названы ТОЛЬКО свои отброшенные записи");
	let dns = json(readfile(SB + "/dns-payload.json"));
	ok(index(dns.domains, "example.com") >= 0 && index(dns.domains, "imported.example") >= 0,
		"в шаг ушёл полный список: свои (нормализованные) + импорт");
	let cfg = json(readfile(ETC + "/install.json"));
	eq(join(",", cfg.user_domains), "Example.COM,bad..name,ru", "свой список хранится как ввёл человек (trim), валидация — при сборке");
	eq(length(cfg.domains), 3);
	eq(cfg.routing_opts.mode, "home", "остальная конфигурация не тронута");
});

test("set_domains: DNS-шаг упал → прежний список остался, ошибка честная", () => {
	reset_sb();
	put_cfg({ protocol: "awg", routing_opts: { mode: "home" }, user_domains: [ "ru" ], domains: [ "ru" ] });
	let r = rpc("set_domains", { domains: [ "example.com" ] }, { engine: stub_engine_domains(1) });
	err_has(r, "прежний оставлен", "set_domains");
	eq(join(",", json(readfile(ETC + "/install.json")).user_domains), "ru", "install.json отражает ПРИМЕНЁННОЕ");
});

test("set_domains: граница доверия — не строка / слишком длинно / нет конфигурации", () => {
	reset_sb();
	err_has(rpc("set_domains", { domains: [ "ru" ] }, { engine: stub_engine_domains(0) }), "не настроен", "без install.json");
	put_cfg({ protocol: "awg", routing_opts: {}, user_domains: [], domains: [] });
	err_has(rpc("set_domains", { domains: [ 5 ] }, { engine: stub_engine_domains(0) }), "строка", "число в списке");
	let many = [];
	for (let i = 0; i < 1001; i++) push(many, sprintf("d%d.example", i));
	err_has(rpc("set_domains", { domains: many }, { engine: stub_engine_domains(0) }), "слишком длинный", "лимит записей");
	ok(!access(SB + "/dns-payload.json") || length(readfile(SB + "/dns-payload.json")) == 0 ||
	   index(readfile(SB + "/dns-payload.json"), "d1000.example") < 0, "отказ ДО применения");
});

test("get_domains: отдаёт свой список; без конфигурации — ошибка", () => {
	reset_sb();
	err_has(rpc("get_domains", {}), "не настроен", "get_domains");
	put_cfg({ protocol: "awg", routing_opts: {}, user_domains: [ "ru", "example.com" ], domains: [] });
	let r = rpc("get_domains", {});
	eq(join(",", r.user_domains), "ru,example.com");
});

// === check_lan_conflict: на хосте фактов нет → честное «проверять нечего» ===

test("check_lan_conflict без фактов сети → conflict=false с причиной", () => {
	reset_sb();
	let r = rpc("check_lan_conflict", {});
	eq(r.conflict, false, "без lan/wan cidr конфликт не выдумывается");
	ok(type(r.reason) == "string", "причина объяснена");
});

// === профили AWG-серверов ===

test("профили: add/list/rename/order/set_failover — без секретов в ответе, .conf с правами 600", () => {
	reset_sb();
	put_cfg({ protocol: "awg", routing_opts: {} });
	let r = rpc("add_profile", { name: "Германия", awg_conf: AWG_OK });
	eq(r.profiles[0].name, "Германия", sprintf("%J", r));
	ok(index(sprintf("%J", r), "PrivateKey") < 0, "конфиг в ответ не уезжает");
	eq(trim(sh(sprintf("stat -c %%a %s/profiles/p1.conf", shq(ETC)))), "600", "приватный ключ — 600");
	rpc("add_profile", { name: "Нидерланды", awg_conf: AWG_OK });
	eq(rpc("rename_profile", { id: "p2", name: "Амстердам" }).profiles[1].name, "Амстердам");
	eq(rpc("order_profiles", { ids: [ "p2", "p1" ] }).profiles[0].id, "p2");
	eq(rpc("set_failover", { enabled: true }).auto, true);
	eq(rpc("list_profiles", {}).auto, true, "флаг пережил перечитывание");
});

test("профили: битый .conf и дубль имени отбиты синхронно; чужой id — отказ", () => {
	reset_sb();
	err_has(rpc("add_profile", { name: "X", awg_conf: "мусор" }), "AWG-конфиг не разобран", "битый conf");
	ok(!access(ETC + "/profiles.json"), "ничего не записано");
	rpc("add_profile", { name: "X", awg_conf: AWG_OK });
	err_has(rpc("add_profile", { name: "X", awg_conf: AWG_OK }), "уже есть", "дубль");
	err_has(rpc("activate_profile", { id: "../../etc/shadow" }), "нет такого", "чужой id");
	err_has(rpc("update_profile_conf", { id: "p9", awg_conf: AWG_OK }), "нет такого", "несуществующий id");
});

test("профили: активный удалить нельзя, неактивный — удаляется вместе с .conf", () => {
	reset_sb();
	rpc("add_profile", { name: "A", awg_conf: AWG_OK });
	rpc("add_profile", { name: "B", awg_conf: AWG_OK });
	let st = json(readfile(ETC + "/profiles.json")); st.active = "p1";
	writefile(ETC + "/profiles.json", sprintf("%J", st));
	err_has(rpc("delete_profile", { id: "p1" }), "подключён", "активный");
	eq(length(rpc("delete_profile", { id: "p2" }).profiles), 1);
	ok(!access(ETC + "/profiles/p2.conf"), "секрет удалённого профиля не остаётся на флеше");
});

// stub_replace() → «движок», где replace_vpn.uc лишь записывает, с чем его позвали.
function stub_replace() {
	let dir = SB + "/engine";
	sh(sprintf("rm -rf %s; mkdir -p %s/install", shq(dir), shq(dir)));
	writefile(dir + "/install/replace_vpn.uc",
		sprintf("import { stdin, writefile } from \"fs\";\nwritefile(%s, join(\" \", ARGV) + \"|\" + stdin.read(\"all\"));\n",
			shq(SB + "/replace-seen.txt")));
	return dir;
}

test("activate_profile на AWG: фоном replace_vpn.uc --profile <id> с .conf профиля", () => {
	reset_sb();
	put_cfg({ protocol: "awg", routing_opts: {} });
	rpc("add_profile", { name: "A", awg_conf: AWG_OK });
	unlink(SB + "/replace-seen.txt");
	let r = rpc("activate_profile", { id: "p1" }, { engine: stub_replace() });
	eq(r.status, "started", sprintf("%J", r));
	for (let i = 0; i < 50 && !access(SB + "/replace-seen.txt"); i++) sh("sleep 0.1");
	eq(readfile(SB + "/replace-seen.txt"), "--profile p1|" + AWG_OK);
});

let rc = summary();
sh(sprintf("rm -rf %s", SB));
exit(rc);
