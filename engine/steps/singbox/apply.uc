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
import { build_singbox_plan, build_net_plan, config_path, service_name, network_sections } from "./singbox.uc";
import { pick_wan_fallback } from "../../lib/route.uc";
import { sh, uci_batch } from "../../lib/proc.uc";

let teardown = (length(ARGV) > 0 && ARGV[0] == "--teardown");
let dry      = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

// config.json: env-override пути для host-тестов в sandbox — тот же env читают run.uc и
// replace_singbox.uc (все слои пишут/бэкапят ОДИН файл и в тесте, и в бою). Без env — дефолт плана.
const SB_OPTS = getenv("SB_CONFIG") ? { config_path: getenv("SB_CONFIG") } : {};

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
	// Снять netifd-маршрут: ifdown интерфейса + удалить наши секции network (иначе остаётся
	// half-route в мёртвый TUN → LAN без интернета). Отсутствие секций — норма (уже снято).
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

let input = stdin.read("all") ?? "";
let plan = build_singbox_plan(input, SB_OPTS);
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("singbox: " + plan.errors[i] + "\n");
	exit(1);
}

// ПРЕДУСЛОВИЕ ШАГА, проверяем ДО любых изменений: в main-таблице обязан быть маршрут по умолчанию
// МИМО туннелей. sing-box с auto_detect_interface выбирает по нему интерфейс для соединения С
// СЕРВЕРОМ; без него он не набирает вообще — «dial tcp <сервер>: no route to internet», что читается
// как «сервер мёртв» при исправном сервере (поймано на живом роутере, 2026-08-01).
//
// Туннели ИСКЛЮЧАЕМ оба: и свой TUN (петля), и awg0. Дефолт через awg0 в этот момент — это остаток
// снятого Light-тира: `ifdown` у netifd асинхронный, поэтому маршрут ещё виден секунду-две, а затем
// исчезает — принять его за выход в интернет значит поднять sing-box в среду без выхода.
// Ждём (netifd тоже асинхронный), а не проверяем однократно.
const TUNNEL_IFS = [ "awg0" ];   // + свой TUN добавляем ниже: он известен из плана
function wan_ready(tun) {
	let skip = [ tun ];
	for (let i = 0; i < length(TUNNEL_IFS); i++) push(skip, TUNNEL_IFS[i]);
	return pick_wan_fallback(sh("ip -4 route show default 2>/dev/null"), skip) != null;
}
if (!dry) {
	let ok_wan = false;
	for (let i = 0; i < 10; i++) {
		if (wan_ready(plan.tun)) { ok_wan = true; break; }
		// Владелец WAN-маршрута — netifd; просим его переустановить, а не правим таблицу сами.
		if (i == 0)
			sh("ifup wan >/dev/null 2>&1");
		sh("sleep 1");
	}
	if (!ok_wan) {
		warn("singbox: в main-таблице нет маршрута по умолчанию мимо туннелей — sing-box не сможет дозвониться до сервера\n");
		warn("singbox: проверьте WAN (uci show network.wan; ip route show default) — шаг не применён, туннель не тронут\n");
		exit(1);
	}
}

let config_text = sprintf("%J\n", plan.config);

if (dry) {
	printf("  config → %s (source: %s)\n", plan.config_path, plan.source);
	print(config_text);
	for (let i = 0; i < length(plan.uci_teardown); i++) print("  " + plan.uci_teardown[i] + "\n");
	for (let i = 0; i < length(plan.uci_setup); i++) print("  " + plan.uci_setup[i] + "\n");
	for (let i = 0; i < length(plan.net_teardown); i++) print("  " + plan.net_teardown[i] + "\n");
	for (let i = 0; i < length(plan.net_setup); i++) print("  " + plan.net_setup[i] + "\n");
	exit(0);
}

// Конфиг проверяем САМИМ sing-box ДО того, как он станет живым. Зачем: структурно наш план
// корректен (юниты это держат), но семантику знает только бинарь — неподдерживаемое поле или
// конфликт опций (например server_port вместе с server_ports у hysteria2) раньше молча поднимали
// МЁРТВЫЙ демон, и человек узнавал об этом из 30-секундной пробы и отката «туннель не поднялся»
// без причины. Теперь шаг падает сразу, а объяснение от sing-box уезжает в install-лог.
//
// Порядок «во временный файл → check → на место» существен: битый конфиг НЕ становится живым
// даже на миг. Гейт по наличию бинаря: в dry-run/host-тестах sing-box может отсутствовать — тогда
// проверять нечем, и это не повод валить шаг (сервис ниже всё равно не поднимется, и это поймает
// health-check).
let staged = plan.config_path + ".check";
writefile(staged, config_text);
if (trim(sh("command -v sing-box 2>/dev/null")) != "") {
	let chk = sh(sprintf("sing-box check -c '%s' 2>&1; echo __rc=$?", staged));
	let m = match(chk, /__rc=([0-9]+)/);
	if (!m || m[1] != "0") {
		sh(sprintf("rm -f '%s'", staged));
		warn("singbox: sing-box отверг сгенерированный конфиг — шаг не применён, туннель не тронут\n");
		warn(trim(replace(chk, /__rc=[0-9]+\s*$/, "")) + "\n");
		exit(1);
	}
}
sh(sprintf("mv '%s' '%s'", staged, plan.config_path));

// teardown по одному с глушением (отсутствие секции — норма), затем setup атомарно.
for (let i = 0; i < length(plan.uci_teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.uci_teardown[i]), "r");
	if (p) p.close();
}
let rc = uci_batch(plan.uci_setup, "sing-box");
if (rc != 0)
	die(sprintf("singbox/apply: uci batch (sing-box) вернул %d", rc));

// netifd-маршрут в туннель (отдельный конфиг network). teardown с глушением, setup — с проверкой rc:
// молча упавший batch = нет маршрута в туннель под видом успеха (тот же урок, что dns/doh/vpn).
for (let i = 0; i < length(plan.net_teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.net_teardown[i]), "r");
	if (p) p.close();
}
let nrc = uci_batch(plan.net_setup, "network");
if (nrc != 0)
	die(sprintf("singbox/apply: uci batch (network) вернул %d", nrc));

svc("enable", plan.service);
svc("restart", plan.service);

// Поднять netifd-интерфейс поверх TUN: netifd поставит half-routes, как только sing-box создаст
// устройство (и переустановит при пересоздании — рестарт sing-box). ifup идемпотентен.
sh(sprintf("ifup %s >/dev/null 2>&1", plan.net_iface ?? "singtun"));

printf("singbox: применено — конфиг %s, сервис %s, TUN %s, маршрут через netifd (%s)\n",
	plan.config_path, plan.service, plan.tun, network_sections({})[0]);
