// singbox.uc — legacy-шаг Full-тира: имена артефактов, которыми владеет sing-box на УЖЕ установленном роутере.
// Full-тир заморожен (тег reality-final): новый конфиг не собирается — подробно: [[0010-freeze-full-tier]].
// Зовут apply.uc (--arm/--disarm/--teardown), reset.uc, watchdog, run.uc (бэкап config.json). Тесты — tests/.

const SINGBOX_DEFAULTS = {
	tun:         "singtun0",          // имя TUN-интерфейса (цель policy-routing, как awg0)
	config_path: "/etc/sing-box/config.json",
	service:     "sing-box",          // имя init.d/uci-сервиса пакета OpenWrt
};

function resolve_opts(opts) {
	let o = {};
	for (let k in SINGBOX_DEFAULTS) o[k] = SINGBOX_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(SINGBOX_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// tun_interface(opts) → имя TUN-интерфейса. Единственный источник для routing/firewall и reset
// (как owned_sections у vpn) — не дрейфует при переименовании.
function tun_interface(opts) {
	return resolve_opts(opts).tun;
}

// config_path(opts) / service_name(opts) — артефакты, которыми владеет шаг (для reset/apply).
function config_path(opts) {
	return resolve_opts(opts).config_path;
}
function service_name(opts) {
	return resolve_opts(opts).service;
}

// network_sections(opts?) → секции network, которыми владеет шаг: proto-none интерфейс singtun поверх
// TUN и две route-секции half-routes. ИНВАРИАНТ: [0] — интерфейс (по нему ifup/ifdown).
const NET_IFACE = "singtun";
const NET_ROUTE_SECTIONS = [ "cheburnet_str0", "cheburnet_str1" ];
function network_sections(opts) {
	return [ NET_IFACE, ...NET_ROUTE_SECTIONS ];
}

export { tun_interface, config_path, service_name, network_sections };
