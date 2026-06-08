// apply.uc — применение DoH-шага на роутере (импурно, router-side).
//
//   ucode -R apply.uc               # прочитать текущее состояние из uci и применить
//   ucode -R apply.uc --dry-run     # только показать план
//
// Читает текущие https-dns-proxy секции и dnsmasq server из uci, строит план (чистое ядро
// doh.uc), применяет: delete секций (|| true) → uci batch (резолверы + dnsmasq server) →
// commit → перезапуск https-dns-proxy + reload dnsmasq. Проверяется в QEMU.
//
// Зависит от dnsmasq noresolv='1' (его ставит DNS-шаг): без него dnsmasq утечёт в ISP-resolv.conf.

import { popen } from "fs";
import { build_doh_plan } from "./doh.uc";

function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

// Текущие секции https-dns-proxy: строки вида `https-dns-proxy.<name>=https-dns-proxy`.
let hdp_sections = [];
let show = sh("uci -q show https-dns-proxy 2>/dev/null");
let lines = split(show, "\n");
for (let i = 0; i < length(lines); i++) {
	let m = match(lines[i], /^https-dns-proxy\.([^.=]+)=https-dns-proxy$/);
	if (m) push(hdp_sections, m[1]);
}

// Текущие dnsmasq server (без пробелов в записях → split по whitespace).
let srv_raw = trim(sh("uci -q get dhcp.@dnsmasq[0].server 2>/dev/null"));
let servers = length(srv_raw) > 0 ? split(srv_raw, /[ \t]+/) : [];

let plan = build_doh_plan({ hdp_sections: hdp_sections, servers: servers }, {});
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++) warn("doh: " + plan.errors[i] + "\n");
	exit(1);
}

if (dry) {
	for (let i = 0; i < length(plan.hdp_teardown); i++) print("  " + plan.hdp_teardown[i] + "\n");
	for (let i = 0; i < length(plan.hdp_setup); i++)    print("  " + plan.hdp_setup[i] + "\n");
	for (let i = 0; i < length(plan.dnsmasq_ops); i++)  print("  " + plan.dnsmasq_ops[i] + "\n");
	exit(0);
}

for (let i = 0; i < length(plan.hdp_teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.hdp_teardown[i]), "r");
	if (p) p.close();
}

let w = popen("uci batch", "w");
if (!w) die("doh/apply: не смог запустить uci batch");
for (let i = 0; i < length(plan.hdp_setup); i++) w.write(plan.hdp_setup[i] + "\n");
for (let i = 0; i < length(plan.dnsmasq_ops); i++) w.write(plan.dnsmasq_ops[i] + "\n");
w.write("commit https-dns-proxy\n");
w.write("commit dhcp\n");
w.close();

sh("/etc/init.d/https-dns-proxy restart >/dev/null 2>&1");
sh("/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1");
printf("doh: применено — резолверов %d, upstream dnsmasq → %s\n",
	length(plan.servers), join(", ", plan.servers));
