// replace_vpn.uc — замена AWG-конфига без переустановки (импурно, router-side).
//
//   printf '%s' "$awg_conf" | ucode -R replace_vpn.uc
//
// Защитный пояс (наследник v1 replace_awg_conf): snapshot UCI → применить vpn-шаг → ждать
// handshake → commit / restore. При сбое snapshot restore возвращает старый network-конфиг и
// reload'ит сеть — пользователь не остаётся без туннеля (авто-rollback). Синхронную валидацию
// .conf (до запуска этого скрипта) делает ubus-обработчик через vpn/plan.uc.
//
// Запускается обработчиком в фоне (setsid), код выхода → done-маркер (install_progress).

import { stdin } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { fresh_handshake } from "./install.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/

let conf = stdin.read("all") ?? "";

// --- 1. snapshot (старый network вернётся restore'ом при сбое) ---
sh(sprintf("ucode -R %s/rollback/snapshot.uc save", ENGINE));

// --- 2. применить vpn-шаг (uci + commit + network reload) ---
let rc = run_stdin(sprintf("ucode -R %s/steps/vpn/apply.uc", ENGINE), conf);
if (rc != 0) {
	warn("replace_vpn: vpn-шаг отказал — откат\n");
	sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
	exit(1);
}

// --- 3. health: ждать СВЕЖИЙ handshake (новее старта). До 30 с: peer-серверу нужно время. ---
// Разбор — чистая fresh_handshake (multi-peer-корректно, под юнит-тестами): единый regex по
// выводу awk ломался на 2+ peer'ах (многострочный hs) и ложно откатывал рабочий конфиг.
let started = time();
let ok = false;
for (let i = 0; i < 15; i++) {
	sh("sleep 2");
	if (fresh_handshake(sh("awg show awg0 latest-handshakes 2>/dev/null"), started)) { ok = true; break; }
}

// --- 4. commit / restore ---
if (ok) {
	sh(sprintf("ucode -R %s/rollback/snapshot.uc commit", ENGINE));
	print("replace_vpn: новый конфиг работает (handshake получен)\n");
	exit(0);
}
warn("replace_vpn: handshake не получен за 30 с — возвращаю прежний конфиг\n");
sh(sprintf("ucode -R %s/rollback/snapshot.uc restore", ENGINE));
exit(1);
