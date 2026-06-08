// apply.uc — применение VPN-шага на роутере (импурно, router-side).
//
//   cat awg0.conf | ucode -R apply.uc              # применить
//   cat awg0.conf | ucode -R apply.uc --dry-run    # только показать план
//
// teardown (delete-before-add, || true) → setup (uci batch) → commit → перезапуск сети, чтобы
// netifd поднял awg0. Проверяется в QEMU; логика плана — под юнит-тестами (vpn/tests).
// Битый/неполный .conf → plan.ok=false → отказ без изменений (граница доверия — вход юзера).

import { stdin, popen } from "fs";
import { parse_awg_conf, build_vpn_plan } from "./vpn.uc";

let conf = stdin.read("all") ?? "";
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let plan = build_vpn_plan(parse_awg_conf(conf), {});
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("vpn: " + plan.errors[i] + "\n");
	exit(1);
}

if (dry) {
	for (let i = 0; i < length(plan.teardown); i++) print("  " + plan.teardown[i] + "\n");
	for (let i = 0; i < length(plan.setup); i++) print("  " + plan.setup[i] + "\n");
	exit(0);
}

// teardown по одному с глушением: удаляем старые секции, отсутствие — норма.
for (let i = 0; i < length(plan.teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.teardown[i]), "r");
	if (p) p.close();
}

// setup атомарно через `uci batch`, затем commit network.
let w = popen("uci batch", "w");
if (!w) die("vpn/apply: не смог запустить uci batch");
for (let i = 0; i < length(plan.setup); i++)
	w.write(plan.setup[i] + "\n");
w.write("commit network\n");
w.close();

// Поднять awg0. reload_config мягче restart; netifd сам поднимет новый интерфейс.
let r = popen("/etc/init.d/network reload >/dev/null 2>&1", "r");
if (r) r.close();

printf("vpn: применено — интерфейс %s, peer %s\n", plan.interface, plan.peer_section);
