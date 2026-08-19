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

// tunnel_connectivity(iface) → { ok, reason }. Форсирует host-route PROBE_IP → iface (ip route
// replace, идемпотентно), подтверждает, что он лёг именно на iface (route_uses_iface), и тянет
// https через него. reason (только при !ok) — где именно отказ: "process" (sing-box не запущен),
// "route" (форсированный маршрут не лёг на iface), "fetch" (HTTPS через туннель не прошёл) — это
// три РАЗНЫЕ поломки (пакет не встал / роутер не смаршрутизировал / сервер не отвечает), и
// адресный текст в UI (web/src/lib/logic.js) зависит от того, какая именно. Каждый отказ — в
// syslog (logger -t cheburnet-probe): его уже забирает diagnostics.uc (grep по "cheburnet"),
// без изменений там.
// ИНВАРИАНТ: маршрут форсируется, а не просто проверяется — если дефолт туннеля не встал, а
// WAN жив, обычный fetch ушёл бы на WAN и соврал бы «работает» (fail-safe: мёртвый туннель
// должен честно валить пробу). --no-check-certificate: важна достижимость, не CN серта.
function tunnel_connectivity(iface) {
	// БЕЗ -x: busybox-pgrep матчит argv[0] КАК ЗАПУЩЕНО, а procd поднимает демон по абсолютному
	// пути — `pgrep -x sing-box` не находит его НИКОГДА, проба валила бы установку на живом
	// туннеле. -f тоже нельзя: подхватит собственную командную строку pgrep.
	if (trim(sh("pgrep sing-box >/dev/null 2>&1; echo $?")) != "0") {
		sh("logger -t cheburnet-probe 'sing-box process not running'");
		return { ok: false, reason: "process" };
	}

	sh(sprintf("ip route replace %s dev %s 2>/dev/null", PROBE_IP, iface));
	let pinned = route_uses_iface(sh(sprintf("ip route get %s 2>/dev/null", PROBE_IP)), iface);
	if (!pinned) {
		sh(sprintf("ip route del %s dev %s 2>/dev/null", PROBE_IP, iface)); // снимаем и на этом провале
		sh(sprintf("logger -t cheburnet-probe 'route to %s did not land on %s'", PROBE_IP, iface));
		return { ok: false, reason: "route" };
	}

	let fetched = trim(sh(sprintf(
		"uclient-fetch -q -T 5 --no-check-certificate -O /dev/null https://%s/ 2>/dev/null; echo $?",
		PROBE_IP))) == "0";
	sh(sprintf("ip route del %s dev %s 2>/dev/null", PROBE_IP, iface)); // снимаем всегда, и на провале
	if (!fetched) {
		sh(sprintf("logger -t cheburnet-probe 'https fetch via %s failed'", iface));
		return { ok: false, reason: "fetch" };
	}
	return { ok: true, reason: null };
}

export { tunnel_connectivity, PROBE_IP };
