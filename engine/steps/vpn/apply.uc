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
	printf("vpn: teardown выполнен (интерфейс %s снят из network)\n", sects[0]);
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
