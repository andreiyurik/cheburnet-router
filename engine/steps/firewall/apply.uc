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
import { build_plan } from "../../routing/routing.uc";
import { build_firewall_plan } from "./firewall.uc";

function run(cmd) { // запустить, вернуть код выхода
	let out = "";
	let p = popen(cmd + " >/dev/null 2>&1; echo $?", "r");
	if (p) { out = p.read("all") ?? ""; p.close(); }
	return int(trim(out));
}

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("firewall/apply: ожидаю JSON {domains, routing_opts{wan_if}} со stdin");
let req = json(raw);
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

let routing_plan = build_plan(req.domains ?? [], req.routing_opts);
let plan = build_firewall_plan(routing_plan, req.fw_opts);

if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("firewall: " + plan.errors[i] + "\n");
	exit(1); // отказ без изменений — лучше, чем дырявый/хардкод kill-switch
}

if (dry) {
	print("# nft teardown\n");  for (let i = 0; i < length(plan.nft_teardown); i++) print("  " + plan.nft_teardown[i] + "\n");
	print("# nft setup\n");     for (let i = 0; i < length(plan.nft_setup); i++)    print("  " + plan.nft_setup[i] + "\n");
	print("# ip teardown\n");   for (let i = 0; i < length(plan.ip_teardown); i++)  print("  " + plan.ip_teardown[i] + "\n");
	print("# ip setup\n");      for (let i = 0; i < length(plan.ip_setup); i++)     print("  " + plan.ip_setup[i] + "\n");
	exit(0);
}

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
