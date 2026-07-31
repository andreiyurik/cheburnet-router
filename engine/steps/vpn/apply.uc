// apply.uc — применение VPN-шага на роутере (импурно, router-side).
//
//   cat awg0.conf | ucode -R apply.uc              # применить
//   cat awg0.conf | ucode -R apply.uc --dry-run    # только показать план
//   ucode -R apply.uc --teardown                   # снять awg0 (при смене протокола на reality)
//
// teardown (delete-before-add, || true) → setup (uci batch) → commit → перезапуск сети, чтобы
// netifd поднял awg0. Проверяется в QEMU; логика плана — под юнит-тестами (vpn/tests).
// Битый/неполный .conf → plan.ok=false → отказ без изменений (граница доверия — вход юзера).

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

// --teardown — снять awg0 (смена протокола awg→reality): ifdown + удалить наши секции network
// (иначе awg0 держит свой default-маршрут и конфликтует с singtun0). Отсутствие секций — норма.
if (teardown) {
	let sects = owned_sections({});
	sh(sprintf("ifdown %s >/dev/null 2>&1", sects[0])); // sects[0] = интерфейс awg0
	let ops = [];
	for (let i = 0; i < length(sects); i++)
		push(ops, "delete network." + sects[i]);
	uci_batch(ops, "network");
	// Вернуть WAN его маршрут по умолчанию и ДОЖДАТЬСЯ его. НЕ «на всякий случай»: netifd ставит
	// default через WAN, а поднявшийся awg0 с route_allowed_ips='1' ЗАМЕЩАЕТ его в main (тот же
	// prefix и метрика), продолжая считать свой установленным. Поэтому после снятия awg0 в main не
	// остаётся ни одного дефолта, и следующий шаг — sing-box — не может соединиться с сервером
	// («no route to internet», поймано на живом роутере при переключении AWG → Full-тир).
	//
	// Ждём, потому что ifdown/ifup у netifd асинхронные: без ожидания следующий шаг видит либо ещё
	// не убранный дефолт через awg0, либо уже пустую таблицу — оба состояния обманчивы. ifup
	// идемпотентен, а невозврат маршрута здесь НЕ фатален: teardown обязан довести уборку до конца,
	// а на отсутствие выхода пожалуется следующий шаг (у него это предусловие).
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
let plan = build_vpn_plan(parse_awg_conf(conf), {});
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

// Поднять awg0. reload — быстрый путь (мягче restart, не дёргает остальные интерфейсы). НО на
// свежей установке proto-handler amneziawg только что доставлен пакетом, и netifd о нём ещё не
// знает: reload НЕ создаёт интерфейс (proto:none / NO_DEVICE на OpenWrt 25.12.4). Поэтому после
// reload проверяем, появилось ли устройство, и при отсутствии эскалируем в restart (он перечитывает
// /lib/netifd/proto/*). На повторных запусках (proto уже загружен) хватает reload — restart не нужен.
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

printf("vpn: применено — интерфейс %s, peer %s\n", plan.interface, plan.peer_section);
