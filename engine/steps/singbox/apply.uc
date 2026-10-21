// apply.uc — legacy sing-box шаг (импурно) для роутеров, оставшихся на Full-тире: --arm | --disarm | --teardown.
// Новый конфиг не применяется: Full-тир заморожен ([[0010-freeze-full-tier]]). Тесты — install/tests (QEMU — нет).

import { popen } from "fs";
import { config_path, service_name, network_sections } from "./singbox.uc";
import { sh, uci_batch } from "../../lib/proc.uc";

let teardown = (length(ARGV) > 0 && ARGV[0] == "--teardown");
let arm_only = (length(ARGV) > 0 && ARGV[0] == "--arm");

// SB_CONFIG: env-override пути config.json — тот же файл бэкапит run.uc при уходе на AWG.
const SB_OPTS = getenv("SB_CONFIG") ? { config_path: getenv("SB_CONFIG") } : {};

// INITD_DIR — env-override ТОЛЬКО для host-тестов (как SB_CONFIG): init-скрипты в sandbox — стабы.
const INITD = getenv("INITD_DIR") ?? "/etc/init.d";
function svc(action, name) {
	let p = popen(sprintf("%s/%s %s >/dev/null 2>&1", INITD, name, action), "r");
	if (p) p.close();
}

// --arm: поднять netifd-интерфейс поверх УЖЕ применённого шага; stdin и config.json не трогает.
// Half-routes живут на TUN, а TUN — на живом sing-box: мёртвый процесс (OOM, исчерпанный respawn)
// `ifup` не оживит — сначала сервис. Так «arm» сторожа чинит и упавший sing-box, а не только маршрут.
if (arm_only) {
	if (trim(sh("pgrep sing-box >/dev/null 2>&1; echo $?")) != "0")
		svc("restart", service_name({}));
	sh(sprintf("ifup %s >/dev/null 2>&1", network_sections({})[0]));
	printf("singbox: маршрут вооружён (%s)\n", network_sections({})[0]);
	exit(0);
}

// --disarm: снять half-routes, не трогая конфиг и сервис (аварийный режим, install/pause.uc).
// Зеркало --arm: там ifup, здесь ifdown — секции network остаются, вернуть можно одним --arm.
if (length(ARGV) > 0 && ARGV[0] == "--disarm") {
	sh(sprintf("ifdown %s >/dev/null 2>&1", network_sections({})[0]));
	printf("singbox: маршрут снят (%s опущен, конфиг на месте)\n", network_sections({})[0]);
	exit(0);
}

if (teardown) {
	let name = service_name({});
	svc("stop", name);
	svc("disable", name);
	// ИНВАРИАНТ: ifdown ДО удаления секций network — иначе netifd оставляет half-route
	// в мёртвый TUN, и LAN лишается интернета.
	sh(sprintf("ifdown %s >/dev/null 2>&1", network_sections({})[0]));
	let nsects = network_sections({});
	let nops = [];
	for (let i = 0; i < length(nsects); i++)
		push(nops, "delete network." + nsects[i]);
	uci_batch(nops, "network");
	// uci-выключение + удаление нашего конфиг-файла (отсутствие — норма).
	uci_batch([ "set sing-box.main.enabled='0'" ], "sing-box");
	let r = popen(sprintf("rm -f '%s'", config_path(SB_OPTS)), "r"); if (r) r.close();
	printf("singbox: teardown выполнен (сервис выключен, маршрут и конфиг убраны)\n");
	exit(0);
}

// Любой другой вызов — попытка применить НОВЫЙ конфиг sing-box: честный отказ, туннель не тронут.
warn("singbox: Full-тир (VLESS+Reality, Hysteria2) больше не поддерживается — используйте AmneziaWG\n");
exit(1);
