// probe.uc — connectivity-probe туннеля reality (импурно, router-side).
//
// НАСТОЯЩАЯ проверка Full-тира: не «pgrep sing-box жив» (процесс жив ≠ туннель везёт), а бегут ли
// байты ЧЕРЕЗ туннель до известного эндпоинта. Используется install/run.uc (health-check) и
// install/replace_reality.uc (30с-гейт замены). Чистая часть (разбор `ip route get`) — в
// install.uc (route_uses_iface, под юнит-тестами); здесь — I/O (проверяется в QEMU).

import { sh } from "../lib/proc.uc";
import { route_uses_iface } from "./install.uc";

// probe-IP: anycast 1.1.1.1 (отвечает на TCP/443, нейтральный, всегда живой). host-route ставим
// только на время пробы. Совпадает с одним из DoH-провайдеров — не конфликт: маршрут снимаем сразу.
const PROBE_IP = "1.1.1.1";

// reality_connectivity(iface) → бежит ли трафик через туннель iface (singtun0).
//   1. Быстрый гейт: нет процесса sing-box → пробовать нечего.
//   2. Форсируем host-route probe-IP → iface (ip route replace: идемпотентно, без «File exists»).
//      Зачем форсировать, если half-routes и так шлют 1.1.1.1 в туннель: если дефолт-маршрут
//      туннеля НЕ встал, а WAN жив, обычный fetch ушёл бы на WAN и СОВРАЛ бы «работает». Пин
//      закрывает эту дыру — мёртвый туннель честно валит пробу (fail-safe).
//   3. Подтверждаем, что маршрут реально лёг на iface (route_uses_iface) — пин мог не примениться.
//   4. Тянем https через туннель (TCP поверх VLESS). --no-check-certificate: probe-IP не совпадает
//      с CN серта, но нам важна ДОСТИЖИМОСТЬ, не личность (ustream-ssl есть — зависимость DoH).
//   5. host-route снимаем ВСЕГДА (в т.ч. на провале) — не оставлять липкий маршрут.
function reality_connectivity(iface) {
	if (trim(sh("pgrep -x sing-box >/dev/null 2>&1; echo $?")) != "0")
		return false;

	sh(sprintf("ip route replace %s dev %s 2>/dev/null", PROBE_IP, iface));
	let pinned = route_uses_iface(sh(sprintf("ip route get %s 2>/dev/null", PROBE_IP)), iface);
	let ok = false;
	if (pinned)
		ok = trim(sh(sprintf(
			"uclient-fetch -q -T 5 --no-check-certificate -O /dev/null https://%s/ 2>/dev/null; echo $?",
			PROBE_IP))) == "0";
	sh(sprintf("ip route del %s dev %s 2>/dev/null", PROBE_IP, iface));
	return ok;
}

export { reality_connectivity, PROBE_IP };
