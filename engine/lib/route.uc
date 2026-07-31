// route.uc — ЧИСТЫЙ разбор вывода `ip route`. Без побочных эффектов: строка на входе, факт на
// выходе. Здесь, а не в install.uc, потому что это нужно и оркестратору (определить WAN), и шагам
// (проверить, есть ли вообще выход в интернет мимо туннеля) — а шаг не должен зависеть от
// оркестратора.

// pick_wan_fallback(route_text, tunnel_ifs) → { wan_if, wan_gw|null } или null. ЧИСТАЯ: разбор
// `ip route show default`, когда netifd не знает WAN (нестандартное имя логики) — первый
// default-маршрут МИМО туннельных интерфейсов. Выбор туннеля как «WAN» здесь = kill-switch,
// ключёванный на сам туннель (тихо мёртвый data-plane) — потомок инцидента «wan_if не вычислялся».
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
