// apply.uc — применение adblock-шага на роутере (импурно, router-side).
//
//   ucode -R apply.uc               # прочитать состояние, записать конфиг, применить addnmount
//   ucode -R apply.uc --dry-run     # только показать план
//
// Читает /etc/adblock-lean/config и dnsmasq addnmount из uci, строит план (чистое ядро),
// пишет конфиг (если изменился), применяет addnmount (uci batch + commit), затем запускает
// adblock-lean и перезапускает dnsmasq, чтобы подхватить блок-лист. Проверяется в QEMU.

import { popen, readfile, writefile } from "fs";
import { build_adblock_plan } from "./adblock.uc";

const ABL_CONFIG = "/etc/adblock-lean/config";

function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let cfg = readfile(ABL_CONFIG) ?? "";
let am_raw = trim(sh("uci -q get dhcp.@dnsmasq[0].addnmount 2>/dev/null"));
let addnmount = length(am_raw) > 0 ? split(am_raw, /[ \t]+/) : [];

let plan = build_adblock_plan({ config: cfg, addnmount: addnmount }, {});

if (dry) {
	printf("# config %s\n", plan.config_changed ? "изменится" : "без изменений");
	for (let i = 0; i < length(plan.addnmount_ops); i++) print("  " + plan.addnmount_ops[i] + "\n");
	exit(0);
}

if (plan.config_changed)
	writefile(ABL_CONFIG, plan.config);

if (length(plan.addnmount_ops) > 0) {
	let w = popen("uci batch", "w");
	if (!w) die("adblock/apply: не смог запустить uci batch");
	for (let i = 0; i < length(plan.addnmount_ops); i++)
		w.write(plan.addnmount_ops[i] + "\n");
	w.write("commit dhcp\n");
	w.close();
}

// Запустить adblock-lean (скачает/обновит список) и перезапустить dnsmasq, чтобы подхватил.
sh("/etc/init.d/adblock-lean start >/dev/null 2>&1 || /etc/init.d/adblock-lean restart >/dev/null 2>&1");
sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
printf("adblock: применено — список %s%s\n", plan.blocklists,
	plan.config_changed ? " (конфиг обновлён)" : "");
