// plan.uc — CLI чистого DoH-шага: current-снимок (stdin JSON) → uci-операции.
//
//   echo '{"current":{"hdp_sections":["cfg01"],"servers":[]}}' | ucode -R plan.uc
//   echo '{}' | ucode -R plan.uc --json
//
// current подаём вручную (так шаг тестируется без роутора). opts — переопределение резолверов.

import { stdin } from "fs";
import { build_doh_plan } from "./doh.uc";

let raw = trim(stdin.read("all") ?? "");
let req = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let plan = build_doh_plan(req.current, req.opts);

if (length(ARGV) > 0 && ARGV[0] == "--json") {
	print(sprintf("%J\n", plan));
} else if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++) print("ERROR: " + plan.errors[i] + "\n");
} else {
	function section(title, arr) {
		print("# " + title + "\n");
		for (let i = 0; i < length(arr); i++) print(arr[i] + "\n");
	}
	section("https-dns-proxy teardown (|| true)", plan.hdp_teardown);
	section("https-dns-proxy setup (uci batch)", plan.hdp_setup);
	section("dnsmasq upstream (uci batch)", plan.dnsmasq_ops);
}

exit(plan.ok ? 0 : 1);
