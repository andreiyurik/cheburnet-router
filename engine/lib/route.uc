// route.uc — ЧИСТЫЙ разбор вывода `ip route`. Нужен и оркестратору (определить WAN), и шагам
// (проверить выход в интернет мимо туннеля) — шаг не должен зависеть от оркестратора.

// pick_wan_fallback(route_text, tunnel_ifs) → { wan_if, wan_gw|null } или null. Разбор
// `ip route show default`, когда netifd не знает WAN — первый default-маршрут МИМО туннельных
// интерфейсов. ИНВАРИАНТ: выбор туннеля как «WAN» превратил бы kill-switch в правило, ключёванное
// на сам туннель — тихо мёртвый data-plane (шрам: «wan_if не вычислялся»).
function pick_wan_fallback(route_text, tunnel_ifs) {
	let skip = {};
	for (let i = 0; i < length(tunnel_ifs ?? []); i++) skip[tunnel_ifs[i]] = true;
	let defs = split(trim(route_text ?? ""), "\n");
	for (let i = 0; i < length(defs); i++) {
		let dev = match(defs[i], /dev ([^ ]+)/);
		if (!dev || skip[dev[1]])
			continue;
		let gw = match(defs[i], /via ([0-9.]+)/);
		return { wan_if: dev[1], wan_gw: gw ? gw[1] : null };
	}
	return null;
}

export { pick_wan_fallback };
