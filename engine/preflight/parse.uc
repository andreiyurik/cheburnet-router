// parse.uc — чистые парсеры системного вывода для preflight gather.
//
// Зачем отдельно: чтение железа (gather.uc) импурно и тестируется в QEMU, а РАЗБОР его
// вывода — чистые функции, юнит-тестируемые на захваченных сэмплах без роутера. Так
// импурная граница максимально тонка, а вся хрупкая логика парсинга — под тестами.
// Каждый парсер при непонятном входе возвращает null/«?» — gather решает, что с этим делать.

// kb_to_mb(kb) → целые МБ (округление вниз). Для порогов «не меньше» вниз — безопасно.
function kb_to_mb(kb) {
	return int(kb / 1024);
}

// parse_meminfo(text) → ram_total_mb или null. Источник: /proc/meminfo, строка "MemTotal: N kB".
function parse_meminfo(text) {
	let lines = split(text ?? "", "\n");
	for (let i = 0; i < length(lines); i++) {
		let m = match(lines[i], /^MemTotal:[ \t]+([0-9]+)[ \t]+kB/);
		if (m)
			return kb_to_mb(int(m[1]));
	}
	return null;
}

// parse_df(text) → free_mb или null. Источник: `df -k <path>` (одна ФС).
// Колонки строки данных: 1K-blocks, Used, Available, Use%, Mounted. Available — 3-е ЦЕЛОЕ
// поле. Собираем целые токены по порядку: это устойчиво и к busybox-переносу длинного имени
// ФС на отдельную строку (тогда в строке данных просто нет поля Filesystem). Use% ("1%") и
// путь монтирования — не чистые целые, в счёт не идут.
function parse_df(text) {
	let lines = split(text ?? "", "\n");
	let started = false, ints = [];
	for (let i = 0; i < length(lines); i++) {
		if (!started) {
			if (substr(trim(lines[i]), 0, 10) == "Filesystem")
				started = true;
			continue;
		}
		let toks = split(trim(lines[i]), /[ \t]+/);
		for (let j = 0; j < length(toks); j++)
			if (match(toks[j], /^[0-9]+$/))
				push(ints, int(toks[j]));
	}
	return length(ints) >= 3 ? kb_to_mb(ints[2]) : null; // 3-е целое = Available
}

// parse_arch(text) → arch (trim) или null. Источник: `uname -m`.
function parse_arch(text) {
	let a = trim(text ?? "");
	return length(a) > 0 ? a : null;
}

// parse_board(json_text) → openwrt_version или null. Источник: `ubus call system board`,
// поле release.version (например "25.12.0" или "SNAPSHOT").
function parse_board(json_text) {
	let o;
	try { o = json(json_text); } catch (e) { return null; }
	if (type(o) != "object" || type(o.release) != "object")
		return null;
	let v = o.release.version;
	return (type(v) == "string" && length(v) > 0) ? v : null;
}

// parse_iface_cidr(json_text) → "addr/mask" или null. Источник: `ubus call network.interface.<X> status`,
// первый ipv4-address {address, mask}. Хост-биты в адресе не мешают: cidr_overlap маскирует сам.
function parse_iface_cidr(json_text) {
	let o;
	try { o = json(json_text); } catch (e) { return null; }
	if (type(o) != "object")
		return null;
	let addrs = o["ipv4-address"];
	if (type(addrs) != "array" || length(addrs) < 1)
		return null;
	let a = addrs[0];
	if (type(a) != "object" || type(a.address) != "string")
		return null;
	let mask = a.mask;
	if (type(mask) != "int" || mask < 0 || mask > 32)
		return null;
	return sprintf("%s/%d", a.address, mask);
}

// parse_wan_route(json_text) → {wan_if, wan_gw|null} или null. Источник: тот же
// `ubus call network.interface.wan status`. netifd знает WAN, даже когда kernel-default уже
// у туннеля (пере-установка) — поэтому это ПЕРВИЧНЫЙ источник wan_if/wan_gw для routing/firewall,
// а разбор `ip route` — только фолбэк. wan_gw null — норма для p2p-линков (PPPoE): там
// default-маршрут без via корректен; для ethernet-WAN nexthop обязателен (без via ядро ARP-ит
// публичные IP в линк, апстрим не отвечает — direct-путь мёртв; доказано живьём 2026-07-08).
function parse_wan_route(json_text) {
	let o;
	try { o = json(json_text); } catch (e) { return null; }
	if (type(o) != "object")
		return null;
	let dev = o.l3_device ?? o.device;
	if (type(dev) != "string" || length(dev) == 0)
		return null;
	let gw = null;
	if (type(o.route) == "array")
		for (let i = 0; i < length(o.route); i++) {
			let r = o.route[i];
			if (type(r) == "object" && r.target == "0.0.0.0" && r.mask == 0 &&
			    type(r.nexthop) == "string" && r.nexthop != "0.0.0.0") {
				gw = r.nexthop;
				break;
			}
		}
	return { wan_if: dev, wan_gw: gw };
}

export { parse_meminfo, parse_df, parse_arch, parse_board, parse_iface_cidr, parse_wan_route };
