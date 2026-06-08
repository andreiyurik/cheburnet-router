// plan.uc — CLI чистого VPN-шага: .conf (stdin) → uci-операции (НЕ применяет).
//
//   cat awg0.conf | ucode -R plan.uc            # показать план
//   cat awg0.conf | ucode -R plan.uc --json     # план машинно
//
// Вход — сырой текст AmneziaWG .conf (не JSON): так удобнее пользователю и тестам.

import { stdin } from "fs";
import { parse_awg_conf, build_vpn_plan } from "./vpn.uc";

let conf = stdin.read("all") ?? "";
let parsed = parse_awg_conf(conf);
let plan = build_vpn_plan(parsed, {});

if (length(ARGV) > 0 && ARGV[0] == "--json") {
	print(sprintf("%J\n", plan));
} else if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		print("ERROR: " + plan.errors[i] + "\n");
} else {
	print("# uci teardown (|| true)\n");
	for (let i = 0; i < length(plan.teardown); i++) print(plan.teardown[i] + "\n");
	print("# uci setup (uci batch) + commit network\n");
	for (let i = 0; i < length(plan.setup); i++) print(plan.setup[i] + "\n");
}

exit(plan.ok ? 0 : 1);
