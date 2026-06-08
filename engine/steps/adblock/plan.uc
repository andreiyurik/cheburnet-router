// plan.uc — CLI чистого adblock-шага: current-снимок (stdin JSON) → конфиг + uci-операции.
//
//   echo '{"current":{"config":"raw_block_lists=\"old\"\n","addnmount":[]}}' | ucode -R plan.uc
//   echo '{}' | ucode -R plan.uc --json
//
// current подаём вручную (тест без роутера). opts — переопределение списка/addnmount.

import { stdin } from "fs";
import { build_adblock_plan } from "./adblock.uc";

let raw = trim(stdin.read("all") ?? "");
let req = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let plan = build_adblock_plan(req.current, req.opts);

if (length(ARGV) > 0 && ARGV[0] == "--json") {
	print(sprintf("%J\n", plan));
} else {
	print(sprintf("# /etc/adblock-lean/config (%s)\n",
		plan.config_changed ? "ИЗМЕНЁН" : "без изменений"));
	if (plan.config_changed)
		print(plan.config + "\n");
	print("# dnsmasq addnmount (uci batch)\n");
	for (let i = 0; i < length(plan.addnmount_ops); i++)
		print(plan.addnmount_ops[i] + "\n");
}

exit(plan.ok ? 0 : 1);
