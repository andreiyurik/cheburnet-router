// replace_singbox.uc — замена конфига Full-тира без переустановки (импурно, router-side).
//   printf '%s' "$conf" | ucode -R replace_singbox.uc   # vless://… | hysteria2://… | JSON sing-box
//
// Один скрипт на все протоколы Full-тира: общий шаг, config.json и проба (ADR 0004). Защитный
// пояс (аналог replace_vpn.uc): бэкап config.json → snapshot UCI → singbox-шаг → connectivity-
// probe через туннель → commit / restore. Запускается в фоне (setsid), код выхода → done-маркер.

import { stdin, readfile, writefile, unlink } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { tunnel_connectivity } from "./probe.uc";
import { config_path, tun_interface } from "../steps/singbox/singbox.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/

let conf = stdin.read("all") ?? "";
// config.json: env-override для host-тестов в sandbox (тот же приём, что ETC_CHEBURNET в run.uc);
// тот же env читает singbox/apply.uc — оба слоя пишут/бэкапят ОДИН файл и в тесте, и в бою.
let cfgfile = getenv("SB_CONFIG") ?? config_path({});
let bak = cfgfile + ".bak";
let iface = tun_interface({});

// --- 0. бэкап старого config.json (отсутствие — норма, была чистая система) ---
// ИНВАРИАНТ: бэкап отдельно от uci-snapshot — в uci только указатель (sing-box.main.conffile),
// сам конфиг внешним файлом; apply.uc его уже перезапишет новым, snapshot-restore uci тогда
// вернул бы указатель на НОВЫЙ (битый) файл.
let old_config = readfile(cfgfile);
if (old_config != null)
	writefile(bak, old_config);

// restore_config() — вернуть прежний config.json (или убрать, если его не было) + рестарт sing-box.
function restore_config() {
	let saved = readfile(bak);
	if (saved != null) {
		writefile(cfgfile, saved);
		unlink(bak);
	} else {
		unlink(cfgfile); // чистая система была без конфига — не оставляем новый
	}
	sh("/etc/init.d/sing-box restart >/dev/null 2>&1");
}

// --- 1. snapshot uci (network + sing-box вернутся restore'ом при сбое) ---
sh(sprintf("ucode -R %s/rollback/snapshot.uc save", ENGINE));

// --- 2. применить singbox-шаг (config.json + uci sing-box/network + рестарт + ifup singtun) ---
let rc = run_stdin(sprintf("ucode -R %s/steps/singbox/apply.uc", ENGINE), conf);
if (rc != 0) {
	warn("replace_singbox: singbox-шаг отказал — откат\n");
	sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
	restore_config();
	exit(1);
}

// --- 3. health: connectivity-probe через туннель. До 30 с: старт sing-box + рукопожатие warm-up. ---
let ok = false;
for (let i = 0; i < 15; i++) {
	sh("sleep 2");
	if (tunnel_connectivity(iface).ok) { ok = true; break; }
}

// --- 4. commit / restore ---
if (ok) {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc commit", ENGINE));
	unlink(bak); // новый конфиг работает — бэкап больше не нужен
	print("replace_singbox: новый конфиг работает (трафик идёт через туннель)\n");
	exit(0);
}
warn("replace_singbox: туннель не отозвался за 30 с — возвращаю прежний конфиг\n");
sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
restore_config();
exit(1);
