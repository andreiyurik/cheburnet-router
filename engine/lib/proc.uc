// proc.uc — общие импурные процесс-хелперы (popen-обёртки) для router-side слоёв.
//
// Вынесено по правилу «3+ дублей блока 5+ строк»: sh/run_stdin/uci-batch-блок повторялись в
// каждом apply.uc и оркестраторе. Один источник = одна точка починки поведения popen.
// Импурно по определению — проверяется в QEMU, юнитов нет (логика вызывающих — под юнитами).

import { popen } from "fs";

// sh(cmd) → stdout строкой (пусто при сбое запуска). Команда идёт через /bin/sh -c.
function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

// run_stdin(cmd, text) → код выхода команды; подаёт text на stdin. -1 — popen не запустился.
function run_stdin(cmd, text) {
	let w = popen(cmd, "w");
	if (!w) return -1;
	w.write(text ?? "");
	return w.close();
}

// uci_batch(ops, commit_config?) → 0 = успех, 1 = uci сообщил об ошибках, -1 = не запустился.
// Пишет операции построчно, опционально добавляя `commit <config>`. ВЫЗЫВАЮЩИЙ ОБЯЗАН
// проверить код: молча проглоченный сбой batch = полуприменённый конфиг под видом успеха
// (урок code-review: упавший `commit firewall` оставлял nft-правила без NAT-зоны при exit 0).
//
// ВАЖНО: сам `uci batch` выходит 0 ВСЕГДА (проверено на живом OpenWrt: set в несуществующий
// package, битый синтаксис, Unknown command — всё rc=0; upstream cli.c печатает ошибку и
// продолжает). Поэтому код выхода процесса — не сигнал; сигнал — ЛЮБОЙ вывод (наши батчи —
// только set/delete/add_list/del_list/commit, при успехе они молчат, эталон проверен там же).
// «Entry not found» возвращает rc=1, но НЕ логируется: для teardown/delete-before-set
// отсутствие записи — норма (эти вызывающие rc игнорируют), а setup-путь и так умрёт с
// именем шага. Остальные ошибки — в warn (попадают в install.log).
function uci_batch(ops, commit_config) {
	if (length(ops) == 0 && !commit_config) return 0;
	let all = [];
	for (let i = 0; i < length(ops); i++) push(all, ops[i]);
	if (commit_config)
		push(all, "commit " + commit_config);
	let q = [];
	for (let i = 0; i < length(all); i++)
		push(q, "'" + replace(all[i], "'", "'\\''") + "'"); // replace со строкой — глобален (ucode)
	let out = trim(sh("printf '%s\\n' " + join(" ", q) + " | uci batch 2>&1"));
	if (length(out) == 0) return 0;
	let noise = [], lines = split(out, "\n");
	for (let i = 0; i < length(lines); i++)
		if (length(trim(lines[i])) > 0 && index(lines[i], "Entry not found") < 0)
			push(noise, trim(lines[i]));
	if (length(noise) > 0)
		warn("uci batch: " + join("; ", noise) + "\n");
	return 1;
}

export { sh, run_stdin, uci_batch };
