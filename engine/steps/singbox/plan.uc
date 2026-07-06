// plan.uc — CLI чистого sing-box шага: вход (stdin) → артефакты (НЕ применяет).
//
//   cat vless.txt | ucode -R plan.uc            # показать план (конфиг + uci)
//   cat vless.txt | ucode -R plan.uc --json     # план машинно
//
// Вход — сырой текст: ссылка vless://… или JSON-конфиг sing-box (так удобнее пользователю/тестам).

import { stdin } from "fs";
import { build_singbox_plan } from "./singbox.uc";

let input = stdin.read("all") ?? "";
let plan = build_singbox_plan(input, {});

if (length(ARGV) > 0 && ARGV[0] == "--json") {
	print(sprintf("%J\n", plan));
} else if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		print("ERROR: " + plan.errors[i] + "\n");
} else {
	print(sprintf("# config → %s (source: %s)\n", plan.config_path, plan.source));
	print(sprintf("%J\n", plan.config));
	print("# uci teardown (|| true)\n");
	for (let i = 0; i < length(plan.uci_teardown); i++) print(plan.uci_teardown[i] + "\n");
	print("# uci setup (uci batch) + commit sing-box\n");
	for (let i = 0; i < length(plan.uci_setup); i++) print(plan.uci_setup[i] + "\n");
	print(sprintf("# restart: /etc/init.d/%s restart\n", plan.service));
}

exit(plan.ok ? 0 : 1);
