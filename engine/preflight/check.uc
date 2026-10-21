// check.uc — CLI-гейткипер: факты (JSON со stdin, см. gather.uc) → отчёт preflight (preflight.uc).
//   ucode -R gather.uc | ucode -R check.uc [--json] [--allow-soft]
// ИНВАРИАНТ: exit 0 = подходит, 1 = отказ — движок НЕ трогает систему при отказе.
// --allow-soft: провалы флеша/RAM не блокируют (осознанный выбор владельца, install.accept_risk).

import { stdin } from "fs";
import { evaluate, render_report } from "./preflight.uc";

// has_flag(name) — есть ли флаг среди аргументов (ARGV в ucode CLI доступен как глобал).
function has_flag(name) {
	for (let i = 0; i < length(ARGV); i++)
		if (ARGV[i] == name) return true;
	return false;
}

let raw = trim(stdin.read("all") ?? "");
if (length(raw) == 0 || substr(raw, 0, 1) != "{")
	die("preflight: ожидаю JSON с фактами о системе на stdin");

let facts = json(raw); // битый JSON → исключение: явный мусор на входе
let report = evaluate(facts, facts.requirements);

let allow_soft = has_flag("--allow-soft");

if (has_flag("--json")) {
	print(sprintf("%J\n", report));
} else {
	let lines = render_report(report, allow_soft);
	for (let i = 0; i < length(lines); i++)
		print(lines[i] + "\n");
}

// Гейт: обычно нужен ЧИСТЫЙ отчёт; с --allow-soft достаточно отсутствия hard-провалов.
exit((report.passed || (allow_soft && report.hard_failed == 0)) ? 0 : 1);
