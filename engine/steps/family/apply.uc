// apply.uc — применение семейного режима на роутере (импурно, router-side).
//
//   echo '{"enabled":true}'  | ucode -R apply.uc            # включить
//   echo '{"enabled":false}' | ucode -R apply.uc            # выключить
//   ... | ucode -R apply.uc --dry-run                       # только показать план
//
// Читает raw_block_lists из /etc/adblock-lean/config и наши cname-секции из uci, строит план
// (чистое ядро family.uc), пишет конфиг (set_var), применяет uci batch + commit dhcp, затем
// перезапускает adblock-lean (скачать/убрать NSFW-лист) и dnsmasq. Проверяется в QEMU.

import { stdin, readfile, writefile } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { build_family_plan } from "./family.uc";
import { set_var, get_var } from "../../lib/conf.uc";

const ABL_CONFIG = "/etc/adblock-lean/config";

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("family/apply: ожидаю JSON {enabled} со stdin");
let req = json(raw);
if (type(req.enabled) != "bool")
	die("family/apply: enabled должен быть bool");
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let cfg = readfile(ABL_CONFIG) ?? "";

// Наши секции — одним вызовом (не 10 форков на слабом железе): перечисляем cname-секции
// с нашим префиксом; чужие имена сюда не попадают, а план и так удаляет только своё.
let out = trim(sh("uci -q show dhcp 2>/dev/null | awk -F'[.=]' '/^dhcp\\.cheburnet_ss_[a-z0-9_]+=cname$/{print $2}'"));
let sections = length(out) > 0 ? split(out, /\n+/) : [];

let current = { raw_block_lists: get_var(cfg, "raw_block_lists") ?? "", sections: sections };
let plan = build_family_plan(current, req.enabled);

if (dry) {
	printf("# raw_block_lists %s%s\n", plan.conf_changed ? "→ " : "без изменений",
		plan.conf_changed ? plan.conf_value : "");
	for (let i = 0; i < length(plan.uci_ops); i++) print("  " + plan.uci_ops[i] + "\n");
	exit(0);
}

if (!plan.changed) {
	printf("family: уже %s — изменений нет\n", req.enabled ? "включён" : "выключен");
	exit(0);
}

if (plan.conf_changed)
	writefile(ABL_CONFIG, set_var(cfg, "raw_block_lists", plan.conf_value));

if (length(plan.uci_ops) > 0) {
	let rc = uci_batch(plan.uci_ops, "dhcp");
	if (rc != 0)
		die(sprintf("family/apply: uci batch завершился кодом %d", rc));
}

// adblock-lean перечитает блок-листы (скачает/уберёт NSFW), dnsmasq подхватит cname+лист.
sh("/etc/init.d/adblock-lean start >/dev/null 2>&1 || /etc/init.d/adblock-lean restart >/dev/null 2>&1");
sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
printf("family: %s\n", req.enabled ? "включён (NSFW-блок + SafeSearch)" : "выключен");
