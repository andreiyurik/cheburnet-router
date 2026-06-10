// apply.uc — применение firewall-шага на роутере (импурно, router-side).
//
//   echo '{"domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}' | ucode -R apply.uc
//   ... | ucode -R apply.uc --dry-run
//
// Сходимость ПЕРЕ-применением: teardown (удалить наши цепочки/правила, || true) → setup
// (nft -f -, ip add). Состояние ядра не откатывается чисто как UCI — поэтому safe-fail, а не
// транзакция. Проверяется в QEMU; логика плана — под юнит-тестами (firewall/tests).
//
// wan_if обязателен в routing_opts (его даёт gather). Нет → план.ok=false → отказ без изменений.

import { stdin, popen } from "fs";
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

// teardown-only: убрать наши nft-цепочки, ip-правила и NAT-зону, ничего не ставя (safe-fail при
// rollback; на rollback uci firewall и так вернёт snapshot — здесь для standalone-teardown).
// Код uci_batch здесь НЕ проверяем намеренно: teardown толерантен (отсутствие секций — норма).
if (teardown_only) {
	for (let i = 0; i < length(plan.nft_teardown); i++)
		run("nft " + plan.nft_teardown[i]);
	for (let i = 0; i < length(plan.ip_teardown); i++)
		run(plan.ip_teardown[i]);
	for (let i = 0; i < length(plan.uci_teardown); i++)
		run("uci -q " + plan.uci_teardown[i]);
	run("uci commit firewall");
	run("/etc/init.d/firewall reload"); // пересобрать fw4 без нашей зоны
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
	print("# nft teardown\n");  for (let i = 0; i < length(plan.nft_teardown); i++) print("  " + plan.nft_teardown[i] + "\n");
	print("# nft setup\n");     for (let i = 0; i < length(plan.nft_setup); i++)    print("  " + plan.nft_setup[i] + "\n");
	print("# ip teardown\n");   for (let i = 0; i < length(plan.ip_teardown); i++)  print("  " + plan.ip_teardown[i] + "\n");
	print("# ip setup\n");      for (let i = 0; i < length(plan.ip_setup); i++)     print("  " + plan.ip_setup[i] + "\n");
	exit(0);
}

// NAT-зона (uci firewall) ПЕРЕД nft: fw4 reload пересобирает таблицу inet fw4 и стёр бы наши
// цепочки, если бы шёл ПОСЛЕ nft-инъекции. teardown (-q, отсутствие — норма) → batch setup →
// commit → reload. Это чистый uci-конфиг (откат через snapshot), в отличие от nft/ip ниже.
for (let i = 0; i < length(plan.uci_teardown); i++)
	run("uci -q " + plan.uci_teardown[i]);
// Код batch ОБЯЗАТЕЛЬНО проверяем: без NAT-зоны kill-switch + default через awg0 = «зелёная»
// установка без интернета у LAN-клиентов (health-check локален и этого не видит).
let uci_rc = uci_batch(plan.uci_setup, "firewall");
if (uci_rc != 0)
	die(sprintf("firewall/apply: uci batch (NAT-зона) завершился кодом %d", uci_rc));
run("/etc/init.d/firewall reload");

// nft teardown: удаление наших цепочек; отсутствие — норма (|| true внутри run, код игнорим).
for (let i = 0; i < length(plan.nft_teardown); i++)
	run("nft " + plan.nft_teardown[i]);

// nft setup: одним батчем через `nft -f -` (атомарно). Падение здесь — реальная ошибка.
let w = popen("nft -f -", "w");
if (!w) die("firewall/apply: не смог запустить nft -f -");
for (let i = 0; i < length(plan.nft_setup); i++)
	w.write(plan.nft_setup[i] + "\n");
let nft_rc = w.close();
if (nft_rc != 0)
	die(sprintf("firewall/apply: nft -f завершился кодом %d", nft_rc));

// ip teardown затем setup (ip rule add не идемпотентен → del перед add; отсутствие — норма).
// Строки уже полные команды ('ip rule ...' / 'ip route ...') — запускаем как есть.
for (let i = 0; i < length(plan.ip_teardown); i++)
	run(plan.ip_teardown[i]);
for (let i = 0; i < length(plan.ip_setup); i++)
	run(plan.ip_setup[i]);

printf("firewall: применено (kill-switch %s, mode %s)\n",
	length(plan.killswitch) > 0 ? "вкл" : "выкл", routing_plan.opts.mode);
