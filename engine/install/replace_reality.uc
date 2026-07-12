// replace_reality.uc — замена VLESS+Reality-конфига без переустановки (импурно, router-side).
//
//   printf '%s' "$reality_conf" | ucode -R replace_reality.uc     # vless://… или JSON sing-box
//
// Защитный пояс (аналог replace_vpn.uc для AWG): back up config.json → snapshot UCI → применить
// singbox-шаг → connectivity-probe ЧЕРЕЗ туннель → commit / restore. При сбое возвращаем и uci
// (snapshot), и внешний config.json (snapshot его НЕ покрывает — это файл, не uci), и
// перезапускаем sing-box со СТАРЫМ конфигом: пользователь не остаётся с полу-битым туннелем.
//
// ПОЧЕМУ config.json отдельно: у AWG весь конфиг в uci (network.awg0) → snapshot восстанавливает
// всё. У reality в uci только указатель (sing-box.main.conffile), а сам конфиг — /etc/sing-box/
// config.json. apply.uc его уже перезаписал новым → snapshot-restore uci вернул бы указатель на
// НОВЫЙ (битый) файл. Поэтому бэкапим и возвращаем config.json руками.
//
// Синхронную валидацию входа (до этого скрипта) делает ubus-обработчик через singbox/plan.uc.
// Запускается обработчиком в фоне (setsid), код выхода → done-маркер (install_progress).

import { stdin, readfile, writefile, unlink } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { reality_connectivity } from "./probe.uc";
import { config_path, tun_interface } from "../steps/singbox/singbox.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/

let conf = stdin.read("all") ?? "";
let cfgfile = config_path({});
let bak = cfgfile + ".bak";
let iface = tun_interface({});

// --- 0. бэкап старого config.json (для отката; отсутствие — норма, была чистая система) ---
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
	warn("replace_reality: singbox-шаг отказал — откат\n");
	sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
	restore_config();
	exit(1);
}

// --- 3. health: connectivity-probe через туннель. До 30 с: sing-box + Reality-рукопожатие warm-up. ---
let ok = false;
for (let i = 0; i < 15; i++) {
	sh("sleep 2");
	if (reality_connectivity(iface)) { ok = true; break; }
}

// --- 4. commit / restore ---
if (ok) {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc commit", ENGINE));
	unlink(bak); // новый конфиг работает — бэкап больше не нужен
	print("replace_reality: новый конфиг работает (трафик идёт через туннель)\n");
	exit(0);
}
warn("replace_reality: туннель не отозвался за 30 с — возвращаю прежний конфиг\n");
sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
restore_config();
exit(1);
