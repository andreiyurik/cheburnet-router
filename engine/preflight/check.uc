// check.uc — CLI-гейткипер: читает факты о системе (JSON со stdin) → отчёт preflight.
//
//   echo '{"arch":"aarch64","openwrt_version":"25.12.0","flash_free_mb":100,
//          "ram_total_mb":256,"deps_installable":{"kmod-amneziawg":true,...}}' \
//     | ucode -R check.uc
//
// Факты собирает router-side companion (чтение /proc, ubus, uci, apk --simulate) — см.
// engine/preflight/README.md. Здесь — только оценка. exit 0 = подходит, 1 = отказ
// (гейткипер: при отказе движок НЕ должен трогать систему). --json → отчёт машинно.

import { stdin } from "fs";
import { evaluate, render_report } from "./preflight.uc";

let raw = trim(stdin.read("all") ?? "");
if (length(raw) == 0 || substr(raw, 0, 1) != "{")
	die("preflight: ожидаю JSON с фактами о системе на stdin");

let facts = json(raw); // битый JSON → исключение: явный мусор на входе
let report = evaluate(facts, facts.requirements);

// Машинный режим: первый аргумент == "--json". (ARGV в ucode CLI доступен как глобал.)
let want_json = (length(ARGV) > 0 && ARGV[0] == "--json");
if (want_json) {
	print(sprintf("%J\n", report));
} else {
	let lines = render_report(report);
	for (let i = 0; i < length(lines); i++)
		print(lines[i] + "\n");
}

exit(report.passed ? 0 : 1);
