// gather.uc — сбор фактов о системе для preflight (РОУТЕРНАЯ, импурная часть).
//
//   ucode -R gather.uc | ucode -R check.uc        # факты → вердикт гейткипера
//
// Импурно: читает /proc, зовёт ubus/uname/df/apk. РАЗБОР вывода — в parse.uc (чисто, под
// юнит-тестами); здесь только запуск команд и сборка facts-JSON. Проверяется в QEMU, не
// юнитами — осознанная граница (см. README). Команды недоступны/упали → поле null/false:
// это безопасное направление гейткипера — «не смог подтвердить» = блокировать, не пропускать.

import { popen, readfile } from "fs";
import { default_requirements, full_requirements } from "./preflight.uc";
import { parse_meminfo, parse_df, parse_arch, parse_board,
         parse_iface_cidr } from "./parse.uc";

// sh(cmd) → stdout строкой (пусто при сбое). Команда идёт через /bin/sh -c (popen).
function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

// cmd_rc(cmd) → true, если команда завершилась кодом 0. Вывод глушим, читаем только $?.
function cmd_rc(cmd) {
	let out = sh(cmd + " >/dev/null 2>&1; echo $?");
	return int(trim(out)) == 0;
}

let req = default_requirements();

// Зависимости: `apk add --simulate <pkg>` — dry-run, ничего не ставит, лишь проверяет
// доступность пакета под текущую arch/feed. Так узнаём deps_installable ДО реальной установки.
let deps_installable = {};
for (let i = 0; i < length(req.deps); i++) {
	let pkg = req.deps[i];
	deps_installable[pkg] = cmd_rc(sprintf("apk add --simulate %s", pkg));
}
// Full-тир (VLESS+Reality): установимость sing-box — тем же apk --simulate (для evaluate_tiers).
// Нет под arch/feed → Full недоступен (Light не задет: слабое железо остаётся на AmneziaWG).
let fr = full_requirements();
deps_installable[fr.dep] = cmd_rc(sprintf("apk add --simulate %s", fr.dep));

// Full-тир — opt-in: sing-box ставится ОТДЕЛЬНО (кнопка в панели → apk add sing-box), не при
// bootstrap. Поэтому «установлен ли» (бинарь есть) ≠ «устанавливаем ли» (--simulate выше).
// evaluate_tiers по этому факту различает: показать кнопку «включить» vs предложить Reality.
let sing_box_installed = cmd_rc(sprintf("command -v %s", fr.dep));

let facts = {
	arch: parse_arch(sh("uname -m")),
	openwrt_version: parse_board(sh("ubus call system board 2>/dev/null")),
	flash_free_mb: parse_df(sh("df -k /overlay 2>/dev/null || df -k /")),
	ram_total_mb: parse_meminfo(readfile("/proc/meminfo") ?? ""),
	deps_installable: deps_installable,
	sing_box_installed: sing_box_installed,
	lan_cidr: parse_iface_cidr(sh("ubus call network.interface.lan status 2>/dev/null")),
	wan_cidr: parse_iface_cidr(sh("ubus call network.interface.wan status 2>/dev/null")),
};

print(sprintf("%J\n", facts));
