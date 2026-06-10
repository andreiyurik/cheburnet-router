// proc.uc — общие импурные процесс-хелперы (popen-обёртки) для router-side слоёв.
//
// Вынесено по правилу «3+ дублей блока 5+ строк»: sh/run_stdin/uci-batch-блок повторялись в
// каждом apply.uc и оркестраторе. Один источник = одна точка починки поведения popen.
// Импурно по определению — проверяется в QEMU, юнитов нет (логика вызывающих — под юнитами).

import { popen } from "fs";

// sh(cmd) → stdout строкой (пусто при сбое запуска). Команда идёт через /bin/sh -c.
export function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

// run_stdin(cmd, text) → код выхода команды; подаёт text на stdin. -1 — popen не запустился.
export function run_stdin(cmd, text) {
	let w = popen(cmd, "w");
	if (!w) return -1;
	w.write(text ?? "");
	return w.close();
}

// uci_batch(ops, commit_config?) → код выхода `uci batch` (0 = успех, -1 = не запустился).
// Пишет операции построчно, опционально добавляя `commit <config>`. ВЫЗЫВАЮЩИЙ ОБЯЗАН
// проверить код: молча проглоченный сбой batch = полуприменённый конфиг под видом успеха
// (урок code-review: упавший `commit firewall` оставлял nft-правила без NAT-зоны при exit 0).
export function uci_batch(ops, commit_config) {
	if (length(ops) == 0 && !commit_config) return 0;
	let w = popen("uci batch", "w");
	if (!w) return -1;
	for (let i = 0; i < length(ops); i++)
		w.write(ops[i] + "\n");
	if (commit_config)
		w.write("commit " + commit_config + "\n");
	return w.close();
}
