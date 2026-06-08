// plan.uc — CLI чистого firewall-шага: facts → nft/ip команды (НЕ применяет).
//
//   echo '{"domains":["example.com"],"routing_opts":{"ipv6":false,"wan_if":"eth0"}}' \
//     | ucode -R plan.uc
//
// Печатает teardown/setup секции по порядку применения. wan_if обязателен в routing_opts —
// без него kill-switch не строится (см. firewall.uc). --json → весь план машинно.

import { stdin } from "fs";
import { build_plan } from "../../routing/routing.uc";
import { build_firewall_plan } from "./firewall.uc";

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("firewall/plan: ожидаю JSON со stdin");

let req = json(raw);
let routing_plan = build_plan(req.domains ?? [], req.routing_opts);
let plan = build_firewall_plan(routing_plan, req.fw_opts);

if (length(ARGV) > 0 && ARGV[0] == "--json") {
	print(sprintf("%J\n", plan));
} else {
	if (!plan.ok)
		for (let i = 0; i < length(plan.errors); i++)
			print("ERROR: " + plan.errors[i] + "\n");
	function section(title, arr) {
		print("# " + title + "\n");
		for (let i = 0; i < length(arr); i++)
			print(arr[i] + "\n");
	}
	section("nft teardown (|| true)", plan.nft_teardown);
	section("nft setup (nft -f -)", plan.nft_setup);
	section("ip teardown (|| true)", plan.ip_teardown);
	section("ip setup", plan.ip_setup);
}

exit(plan.ok ? 0 : 1);
