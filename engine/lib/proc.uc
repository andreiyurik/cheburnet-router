// proc.uc — общие импурные процесс-хелперы (popen-обёртки) для router-side слоёв. Вынесено:
// sh/run_stdin/uci-batch-блок дублировались в каждом apply.uc и оркестраторе. Проверяется в
// QEMU, юнитов нет (логика вызывающих — под юнитами).

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
// Пишет операции построчно, опционально `commit <config>`. ВЫЗЫВАЮЩИЙ ОБЯЗАН проверить код —
// молча проглоченный сбой = полуприменённый конфиг под видом успеха.
//
// ПЛАТФОРМЕННЫЙ КВИРК: `uci batch` всегда выходит 0, даже на битом синтаксисе, несуществующем
// package или Unknown command (доказано на живом OpenWrt) — сигнал не код выхода, а ЛЮБОЙ вывод.
// «Entry not found» (rc=1) не логируем: для teardown/delete-before-set отсутствие записи — норма.
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
