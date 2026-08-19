// apply.uc — применение VPN-шага на роутере (импурно): teardown → uci batch → перезапуск сети,
// чтобы netifd поднял awg0. Логика плана — в vpn.uc (тесты: vpn/tests); битый .conf → plan.ok=false.
//   cat awg0.conf | ucode -R apply.uc [--dry-run]
//   cat awg0.conf | ucode -R apply.uc --no-arm     # применить, БЕЗ route_allowed_ips=1
//   ucode -R apply.uc --arm             # довооружить (route_allowed_ips=1 + reload)
//   ucode -R apply.uc --teardown        # снять awg0 (смена протокола на reality)
//
// --no-arm/--arm — та же логика, что у steps/singbox/apply.uc: только для первой установки
// (run.uc), см. комментарий там и [[reliability]].

import { stdin, popen } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { pick_wan_fallback } from "../../lib/route.uc";
import { parse_awg_conf, build_vpn_plan, owned_sections } from "./vpn.uc";

// dev_present(iface) — создал ли netifd kernel-устройство интерфейса (ip link).
function dev_present(iface) {
	return trim(sh(sprintf("ip link show %s >/dev/null 2>&1; echo $?", iface))) == "0";
}

let teardown = (length(ARGV) > 0 && ARGV[0] == "--teardown");
let dry      = (length(ARGV) > 0 && ARGV[0] == "--dry-run");
let no_arm   = (length(ARGV) > 0 && ARGV[0] == "--no-arm");
let arm_only = (length(ARGV) > 0 && ARGV[0] == "--arm");

// --arm: довооружить уже применённый (--no-arm) интерфейс — только route_allowed_ips=1 + reload,
// без пересборки плана из stdin (его и не подать: соединение уже поднято под предыдущим конфигом).
if (arm_only) {
	let peersect = owned_sections({})[1];
	let rc = uci_batch([ sprintf("set network.%s.route_allowed_ips='1'", peersect) ], "network");
	if (rc != 0)
		die(sprintf("vpn/apply: uci batch (arm) вернул %d", rc));
	let p = popen("/etc/init.d/network reload >/dev/null 2>&1", "r");
	if (p) p.close();
	printf("vpn: маршрут вооружён (route_allowed_ips=1 на %s)\n", peersect);
	exit(0);
}

// --teardown — снять awg0 (смена протокола awg→reality): ifdown + удалить наши секции network
// (иначе awg0 держит свой default-маршрут и конфликтует с singtun0). Отсутствие секций — норма.
if (teardown) {
	let sects = owned_sections({});
	sh(sprintf("ifdown %s >/dev/null 2>&1", sects[0]));
	let ops = [];
	for (let i = 0; i < length(sects); i++)
		push(ops, "delete network." + sects[i]);
	uci_batch(ops, "network");
	// ШРАМ: awg0 с route_allowed_ips='1' замещает WAN-дефолт в main; после снятия awg0 в main не
	// остаётся ни одного дефолта, и следующий шаг (sing-box) не может соединиться с сервером
	// («no route to internet» при переключении AWG → Full-тир). Поэтому явно возвращаем и ЖДЁМ
	// WAN-маршрут (ifdown/ifup у netifd асинхронные) — невозврат здесь не фатален, это подхватит
	// предусловие следующего шага. Подробно: [[0004-multi-protocol-tiers]] (п.1).
	sh("ifup wan >/dev/null 2>&1");
	let wan_back = false;
	for (let i = 0; i < 10; i++) {
		if (pick_wan_fallback(sh("ip -4 route show default 2>/dev/null"), [ sects[0], "singtun0" ]) != null) {
			wan_back = true;
			break;
		}
		sh("sleep 1");
	}
	printf("vpn: teardown выполнен (интерфейс %s снят из network, WAN-маршрут %s)\n",
		sects[0], wan_back ? "вернулся" : "НЕ вернулся — смотрите wan в netifd");
	exit(0);
}

let conf = stdin.read("all") ?? "";
let plan = build_vpn_plan(parse_awg_conf(conf), no_arm ? { arm: false } : {});
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++)
		warn("vpn: " + plan.errors[i] + "\n");
	exit(1);
}

if (dry) {
	for (let i = 0; i < length(plan.teardown); i++) print("  " + plan.teardown[i] + "\n");
	for (let i = 0; i < length(plan.setup); i++) print("  " + plan.setup[i] + "\n");
	exit(0);
}

// teardown по одному с глушением: удаляем старые секции, отсутствие — норма.
for (let i = 0; i < length(plan.teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.teardown[i]), "r");
	if (p) p.close();
}

// setup атомарно через `uci batch` + commit. rc проверяем: молча упавший batch =
// полуприменённый network-конфиг под видом успеха (контракт lib/proc.uc, урок dns/doh).
let rc = uci_batch(plan.setup, "network");
if (rc != 0)
	die(sprintf("vpn/apply: uci batch упал (код %d)", rc));

// Платформенный квирк (OpenWrt 25.12.4): на свежей установке proto-handler amneziawg только что
// доставлен пакетом, и reload его не подхватывает (proto:none/NO_DEVICE) — нужен restart, который
// перечитывает /lib/netifd/proto/*. На повторных запусках хватает более лёгкого reload.
let p = popen("/etc/init.d/network reload >/dev/null 2>&1", "r");
if (p) p.close();
// Ждём появления kernel-устройства (до 5с). Нет → reload не подхватил свежий proto-handler.
let up = false;
for (let i = 0; i < 5 && !up; i++) { sh("sleep 1"); up = dev_present(plan.interface); }
if (!up) {
	let r = popen("/etc/init.d/network restart >/dev/null 2>&1", "r");
	if (r) r.close();
	// restart перечитывает proto-handlers и поднимает интерфейсы НЕ мгновенно — блокируемся до
	// появления интерфейса (до 15с), чтобы следующие шаги и health-check видели готовое устройство.
	for (let i = 0; i < 15 && !up; i++) { sh("sleep 1"); up = dev_present(plan.interface); }
}
if (!up)
	warn(sprintf("vpn: интерфейс %s не появился после reload+restart — health-check это поймает (см. logread)\n",
		plan.interface));

printf("vpn: применено — интерфейс %s, peer %s%s\n", plan.interface, plan.peer_section,
	no_arm ? " (маршрут ЕЩЁ НЕ вооружён, --no-arm)" : "");
