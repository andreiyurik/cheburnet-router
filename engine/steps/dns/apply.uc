// apply.uc — применение DNS-шага на роутере (импурно, router-side).
//
//   echo '{"domains":["example.com"]}' | ucode -R apply.uc            # применить
//   echo '{"domains":["example.com"]}' | ucode -R apply.uc --dry-run  # только показать план
//
// Читает ТЕКУЩЕЕ состояние dnsmasq из uci, строит план (чистое ядро dns.uc) и применяет его
// через `uci batch` + commit, затем перезагружает dnsmasq. Импурную часть (uci/init.d)
// проверяем в QEMU, не юнитами — логика плана уже под юнит-тестами (dns/tests). Идемпотентно:
// пустой план → ничего не делаем и не дёргаем dnsmasq зря.

import { stdin, popen } from "fs";
import { build_plan } from "../../routing/routing.uc";
import { build_dns_plan } from "./dns.uc";

function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("dns/apply: ожидаю JSON {domains, routing_opts?, dns_opts?} со stdin");
let req = json(raw);
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let section = (req.dns_opts && req.dns_opts.section) ? req.dns_opts.section : "@dnsmasq[0]";

// Текущий снимок uci. Значения nftset/опций без пробелов → split по whitespace безопасен.
// `uci -q get` списка отдаёт элементы через пробел; пусто/нет ключа → выходит 1 (глушим).
let cur_nftset_raw = trim(sh(sprintf("uci -q get dhcp.%s.nftset 2>/dev/null", section)));
let cur_nftset = length(cur_nftset_raw) > 0 ? split(cur_nftset_raw, /[ \t]+/) : [];
let cur_noresolv = trim(sh(sprintf("uci -q get dhcp.%s.noresolv 2>/dev/null", section)));

let current = { nftset: cur_nftset, options: { noresolv: cur_noresolv } };
let routing_plan = build_plan(req.domains ?? [], req.routing_opts);
let plan = build_dns_plan(routing_plan, current, req.dns_opts);

if (!plan.changed) {
	print("dns: уже применено — изменений нет\n");
	exit(0);
}

for (let i = 0; i < length(plan.ops); i++)
	print("  " + plan.ops[i] + "\n");

if (dry) {
	print("dns: --dry-run, не применяю\n");
	exit(0);
}

// Применяем атомарно через `uci batch` + commit, затем перезагружаем dnsmasq.
let w = popen("uci batch", "w");
if (!w) die("dns/apply: не смог запустить uci batch");
for (let i = 0; i < length(plan.ops); i++)
	w.write(plan.ops[i] + "\n");
w.write("commit dhcp\n");
w.close();

sh("/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1");
printf("dns: применено (+%d / -%d nftset)\n", length(plan.add), length(plan.remove));
