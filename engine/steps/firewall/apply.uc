// apply.uc — применение firewall-шага на роутере (импурно, router-side).
//
//   echo '{"domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}' | ucode -R apply.uc
//   ... | ucode -R apply.uc --dry-run
//   ... | ucode -R apply.uc --teardown
//
// Наши цепочки/сеты/правила пишутся в /etc/nftables.d/10-cheburnet.nft — fw4 включает файл в
// table inet fw4 при каждом reload, поэтому правила ПЕРЕЖИВАЮТ любой reload (урок живого
// прогона: ручная `nft add`-инъекция терялась при hotplug/reload → kill-switch тихо умирал).
// NAT-зона — uci firewall (чистый откат через snapshot). ip rule/route — iproute2.
//
// wan_if обязателен в routing_opts (его даёт gather). Нет → план.ok=false → отказ без изменений.

import { stdin, writefile, unlink } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { build_plan } from "../../routing/routing.uc";
import { build_firewall_plan } from "./firewall.uc";

function run(cmd) { // запустить, вернуть код выхода
	return int(trim(sh(cmd + " >/dev/null 2>&1; echo $?")));
}

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("firewall/apply: ожидаю JSON {domains, routing_opts{wan_if}} со stdin");
let req = json(raw);
let arg = (length(ARGV) > 0) ? ARGV[0] : "";
let dry = (arg == "--dry-run");
let teardown_only = (arg == "--teardown"); // снять наши правила (откат грязного шага оркестратором)

let routing_plan = build_plan(req.domains ?? [], req.routing_opts);
let plan = build_firewall_plan(routing_plan, req.fw_opts);

// teardown-only: убрать nftables.d-файл (+reload вычистит цепочки), ip-правила и NAT-зону,
// ничего не ставя. Код uci_batch НЕ проверяем: teardown толерантен (отсутствие секций — норма).
if (teardown_only) {
	unlink(plan.nft_path); // отсутствие файла — норма (unlink вернёт false, игнорим)
	for (let i = 0; i < length(plan.ip_teardown); i++)
		run(plan.ip_teardown[i]);
	for (let i = 0; i < length(plan.uci_teardown); i++)
		run("uci -q " + plan.uci_teardown[i]);
	run("uci commit firewall");
	run("/etc/init.d/firewall reload"); // пересобрать fw4 без нашего файла и зоны
	// reload не удаляет чужие цепочки/сеты (остаются пустыми) — добиваем явно, отсутствие — норма.
	for (let i = 0; i < length(plan.nft_teardown); i++)
		run("nft " + plan.nft_teardown[i]);
	print("firewall: teardown выполнен (правила и NAT-зона сняты)\n");
	exit(0);
}

if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("firewall: " + plan.errors[i] + "\n");
	exit(1); // отказ без изменений — лучше, чем дырявый/хардкод kill-switch
}

if (dry) {
	print("# uci teardown (NAT, || true)\n"); for (let i = 0; i < length(plan.uci_teardown); i++) print("  " + plan.uci_teardown[i] + "\n");
	print("# uci setup (uci batch) + commit firewall + fw4 reload\n"); for (let i = 0; i < length(plan.uci_setup); i++) print("  " + plan.uci_setup[i] + "\n");
	printf("# nftables.d-файл: %s\n", plan.nft_path);
	print(plan.nft_file);
	print("# ip teardown\n");   for (let i = 0; i < length(plan.ip_teardown); i++)  print("  " + plan.ip_teardown[i] + "\n");
	print("# ip setup\n");      for (let i = 0; i < length(plan.ip_setup); i++)     print("  " + plan.ip_setup[i] + "\n");
	exit(0);
}

// 1) nftables.d-файл (наши цепочки/сеты/правила). Пишем ДО uci-reload, чтобы тот же reload
// сразу включил их в fw4 — не остаётся окна без kill-switch.
if (!writefile(plan.nft_path, plan.nft_file))
	die(sprintf("firewall/apply: не смог записать %s", plan.nft_path));

// 2) NAT-зона (uci firewall) + commit + reload. Reload пересобирает fw4 И подхватывает наш
// файл из nftables.d — одним действием и зона, и наши цепочки. Код batch ОБЯЗАТЕЛЬНО проверяем:
// без NAT-зоны kill-switch + default через awg0 = «зелёная» установка без интернета у LAN.
for (let i = 0; i < length(plan.uci_teardown); i++)
	run("uci -q " + plan.uci_teardown[i]);
let uci_rc = uci_batch(plan.uci_setup, "firewall");
if (uci_rc != 0)
	die(sprintf("firewall/apply: uci batch (NAT-зона) завершился кодом %d", uci_rc));
let fw_rc = run("/etc/init.d/firewall reload");
if (fw_rc != 0)
	die(sprintf("firewall/apply: fw4 reload завершился кодом %d (файл nftables.d невалиден?)", fw_rc));

// 3) ip teardown затем setup (ip rule add не идемпотентен → del перед add; отсутствие — норма).
// Строки уже полные команды ('ip rule ...' / 'ip route ...') — запускаем как есть.
for (let i = 0; i < length(plan.ip_teardown); i++)
	run(plan.ip_teardown[i]);
for (let i = 0; i < length(plan.ip_setup); i++)
	run(plan.ip_setup[i]);

printf("firewall: применено (kill-switch %s, mode %s)\n",
	length(plan.killswitch) > 0 ? "вкл" : "выкл", routing_plan.opts.mode);
