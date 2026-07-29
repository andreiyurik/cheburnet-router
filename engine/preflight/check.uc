// check.uc — CLI-гейткипер: читает факты о системе (JSON со stdin) → отчёт preflight.
//
//   echo '{"arch":"aarch64","openwrt_version":"25.12.0","flash_free_mb":100,
//          "ram_total_mb":256,"deps_installable":{"kmod-amneziawg":true,...}}' \
//     | ucode -R check.uc
//
// Факты собирает router-side companion (чтение /proc, ubus, uci, apk --simulate) — см.
// engine/preflight/README.md. Здесь — только оценка. exit 0 = подходит, 1 = отказ
// (гейткипер: при отказе движок НЕ должен трогать систему).
//
// Флаги (в любом порядке):
//   --json        отчёт машинно (для ubus/UI), вместо человекочитаемых строк
//   --allow-soft  «на свой страх и риск»: soft-провалы (флеш/RAM) НЕ блокируют — exit 0, пока
//                 нет hard-провалов. Ставится только по осознанному выбору владельца
//                 (install accept_risk); отчёт при этом честно печатает, что пропущено.

import { stdin } from "fs";
import { evaluate, render_report, evaluate_tiers } from "./preflight.uc";

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
	// tiers — какие туннель-тиры потянет это железо (Light всегда, Full гейтится). Информационно
	// для UI (показывать ли выбор VLESS+Reality); НЕ влияет на exit-код (блокирует только Light).
	report.tiers = evaluate_tiers(facts, facts.requirements);
	print(sprintf("%J\n", report));
} else {
	let lines = render_report(report, allow_soft);
	for (let i = 0; i < length(lines); i++)
		print(lines[i] + "\n");
}

// Гейт: обычно нужен ЧИСТЫЙ отчёт; с --allow-soft достаточно отсутствия hard-провалов.
exit((report.passed || (allow_soft && report.hard_failed == 0)) ? 0 : 1);
