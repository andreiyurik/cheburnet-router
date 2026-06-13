// apply.uc — применение sing-box шага на роутере (импурно, router-side).
//
//   cat vless.txt | ucode -R apply.uc              # применить
//   cat vless.txt | ucode -R apply.uc --dry-run    # только показать артефакты
//   ucode -R apply.uc --teardown                   # снять (выключить сервис, убрать конфиг)
//
// Запись config.json → uci-включение сервиса → рестарт sing-box. TUN-интерфейс поднимет сам
// sing-box; маршрутизацию в него навешивает firewall-шаг (как для awg0). Логика плана — под
// юнит-тестами (singbox/tests); живой стек (реальный sing-box + Reality-сервер) — QEMU/железо.
// Битый/неполный вход → plan.ok=false → отказ без изменений (граница доверия — вход юзера).

import { stdin, popen } from "fs";
import { build_singbox_plan, config_path, service_name } from "./singbox.uc";
import { uci_batch } from "../../lib/proc.uc";

let teardown = (length(ARGV) > 0 && ARGV[0] == "--teardown");
let dry      = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

// writefile(path, text) — атомарная запись через tmp+rename (config.json не должен читаться
// полу-записанным). Каталог /etc/sing-box создаёт пакет; на всякий случай mkdir -p.
function writefile(path, text) {
	let dir = replace(path, /\/[^\/]+$/, "");
	let m = popen(sprintf("mkdir -p '%s'", dir), "r"); if (m) m.close();
	let w = popen(sprintf("cat > '%s.tmp'", path), "w");
	if (!w) die("singbox/apply: не смог записать " + path);
	w.write(text);
	w.close();
	let r = popen(sprintf("mv '%s.tmp' '%s'", path, path), "r"); if (r) r.close();
}

function svc(action, name) {
	let p = popen(sprintf("/etc/init.d/%s %s >/dev/null 2>&1", name, action), "r");
	if (p) p.close();
}

if (teardown) {
	let name = service_name({});
	svc("stop", name);
	svc("disable", name);
	// uci-выключение + удаление нашего конфиг-файла (отсутствие — норма).
	uci_batch([ "set sing-box.main.enabled='0'" ], "sing-box");
	let r = popen(sprintf("rm -f '%s'", config_path({})), "r"); if (r) r.close();
	printf("singbox: teardown выполнен (сервис выключен, конфиг убран)\n");
	exit(0);
}

let input = stdin.read("all") ?? "";
let plan = build_singbox_plan(input, {});
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("singbox: " + plan.errors[i] + "\n");
	exit(1);
}

let config_text = sprintf("%J\n", plan.config);

if (dry) {
	printf("  config → %s (source: %s)\n", plan.config_path, plan.source);
	print(config_text);
	for (let i = 0; i < length(plan.uci_teardown); i++) print("  " + plan.uci_teardown[i] + "\n");
	for (let i = 0; i < length(plan.uci_setup); i++) print("  " + plan.uci_setup[i] + "\n");
	exit(0);
}

writefile(plan.config_path, config_text);

// teardown по одному с глушением (отсутствие секции — норма), затем setup атомарно.
for (let i = 0; i < length(plan.uci_teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.uci_teardown[i]), "r");
	if (p) p.close();
}
let rc = uci_batch(plan.uci_setup, "sing-box");
if (rc != 0)
	die(sprintf("singbox/apply: uci batch вернул %d", rc));

svc("enable", plan.service);
svc("restart", plan.service);

printf("singbox: применено — конфиг %s, сервис %s, TUN %s\n",
	plan.config_path, plan.service, plan.tun);
