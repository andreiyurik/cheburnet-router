// probe.uc — connectivity-probe туннеля Full-тира (импурно, router-side).
//
// Одна проба на все sing-box-протоколы (общий TUN, общая семантика здоровья — ADR 0004),
// а не «pgrep жив» (процесс жив ≠ туннель везёт трафик).
// Используется install/run.uc (health-check) и install/replace_singbox.uc (30с-гейт замены).
// Чистая часть (route_uses_iface) — в install.uc, под юнит-тестами; здесь — I/O, под QEMU.

import { sh } from "../lib/proc.uc";
import { route_uses_iface } from "./install.uc";

// probe-IP: anycast 1.1.1.1 (TCP/443, нейтральный, всегда живой). host-route ставим только на
// время пробы; совпадение с DoH-провайдером не конфликтует — маршрут снимаем сразу.
const PROBE_IP = "1.1.1.1";

// tunnel_connectivity(iface) → бежит ли трафик через туннель iface. Форсирует host-route
// PROBE_IP → iface (ip route replace, идемпотентно), подтверждает, что он лёг именно на iface
// (route_uses_iface), и тянет https через него.
// ИНВАРИАНТ: маршрут форсируется, а не просто проверяется — если дефолт туннеля не встал, а
// WAN жив, обычный fetch ушёл бы на WAN и соврал бы «работает» (fail-safe: мёртвый туннель
// должен честно валить пробу). --no-check-certificate: важна достижимость, не CN серта.
function tunnel_connectivity(iface) {
	// БЕЗ -x: busybox-pgrep матчит argv[0] КАК ЗАПУЩЕНО, а procd поднимает демон по абсолютному
	// пути — `pgrep -x sing-box` не находит его НИКОГДА, проба валила бы установку на живом
	// туннеле. -f тоже нельзя: подхватит собственную командную строку pgrep.
	if (trim(sh("pgrep sing-box >/dev/null 2>&1; echo $?")) != "0")
		return false;

	sh(sprintf("ip route replace %s dev %s 2>/dev/null", PROBE_IP, iface));
	let pinned = route_uses_iface(sh(sprintf("ip route get %s 2>/dev/null", PROBE_IP)), iface);
	let ok = false;
	if (pinned)
		ok = trim(sh(sprintf(
			"uclient-fetch -q -T 5 --no-check-certificate -O /dev/null https://%s/ 2>/dev/null; echo $?",
			PROBE_IP))) == "0";
	sh(sprintf("ip route del %s dev %s 2>/dev/null", PROBE_IP, iface)); // снимаем всегда, и на провале
	return ok;
}

export { tunnel_connectivity, PROBE_IP };
