// plan.uc — CLI чистого Wi-Fi-шага: {ssid,key,ifaces?,encryption?,pmf?} (stdin JSON) → uci ops.
//
//   echo '{"ssid":"Home","key":"password123","ifaces":["default_radio0"]}' | ucode -R plan.uc
//   ... | ucode -R plan.uc --json      # план машинно
//
// Имена секций (ifaces) на роутере перечисляет apply.uc; здесь их подаём явно (тесты/локально).

import { stdin } from "fs";
import { build_wifi_plan } from "./wifi.uc";

let raw = trim(stdin.read("all") ?? "");
let req = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let ifaces = (type(req.ifaces) == "array") ? req.ifaces : [];
let plan = build_wifi_plan(ifaces, { ssid: req.ssid, key: req.key, encryption: req.encryption, pmf: req.pmf });

if (length(ARGV) > 0 && ARGV[0] == "--json") {
	print(sprintf("%J\n", plan));
} else if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++) print("ERROR: " + plan.errors[i] + "\n");
} else if (!plan.applied) {
	print("# no-op (нет радио / пустой список секций)\n");
} else {
	print("# uci teardown (|| true)\n");
	for (let i = 0; i < length(plan.teardown); i++) print(plan.teardown[i] + "\n");
	print("# uci setup (uci batch) + commit wireless\n");
	for (let i = 0; i < length(plan.setup); i++) print(plan.setup[i] + "\n");
}

exit(plan.ok ? 0 : 1);
