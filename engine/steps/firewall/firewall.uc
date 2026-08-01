// firewall.uc — data-plane шаг: пометка direct-трафика, policy routing и kill-switch.
//
// Это production-применение split-routing на роутере (форвард-трафик LAN-клиентов):
//   • наша prerouting-цепочка метит пакеты с daddr ∈ direct  → [[policy-routing]]
//   • ip rule/route разводят помеченное в WAN, остальное в туннель
//   • kill-switch роняет непрямой трафик, утекающий в WAN мимо туннеля → [[kill-switch]]
//
// НАШИ ЦЕПОЧКИ/СЕТЫ ЖИВУТ В /etc/nftables.d/10-cheburnet.nft — файле, который fw4 включает в
// table inet fw4 при КАЖДОМ reload. Это критично: ручная инъекция `nft add` теряла правила при
// ЛЮБОМ fw4 reload (hotplug awg0, установка пакета, правка LuCI, ребут) — kill-switch тихо
// умирал (поймано живым прогоном на роутере, QEMU это не показал). Через nftables.d fw4 сам
// восстанавливает наши правила при каждой пересборке — reload из врага становится союзником.
//
// ЧИСТОЕ ЯДРО: build_firewall_plan(routing_plan, opts) → { nft_file (содержимое), ip-команды,
// uci NAT }. Запись файла + reload + ip — в apply.uc (импурно, QEMU). ip rule/route fw4 reload
// не трогает; их сбрасывает лишь network restart (реже) — отдельная забота (hotplug), не здесь.

import { render_iprules } from "../../routing/routing.uc";

const NFT_PATH = "/etc/nftables.d/10-cheburnet.nft";
// hotplug-хук: восстанавливает ip-часть data-plane при подъёме WAN (загрузка роутера, реконнект).
// Почему hotplug, а не init-скрипт: он же покрывает смену шлюза у провайдера, а не только ребут.
const HOTPLUG_PATH = "/etc/hotplug.d/iface/99-cheburnet";

// Свои hooked-цепочки в inet fw4 (объявляются в nftables.d-файле). Сеты — тоже в файле: fw4
// пересоздаёт их пустыми при reload, dnsmasq пере-наполняет на резолве (адреса эфемерны).
const FW_DEFAULTS = {
	mark_chain: "cheburnet_mark", // type filter hook prerouting priority mangle
	ks_chain: "cheburnet_ks",     // type filter hook forward   priority filter
	killswitch: true,
	// NAT-зона туннеля (uci firewall): masq на awg0 + forwarding lan→vpn. Без неё LAN-трафик
	// уходит в туннель без SNAT/forwarding и не возвращается (роутер «зелёный, но не везёт»).
	nat: true,
	tunnel_if: "awg0", // интерфейс туннеля (совпадает с vpn-шагом)
	lan_zone: "lan",   // имя LAN-зоны fw4 (стандартное); forwarding по ИМЕНИ зоны, не по CIDR
	vpn_zone: "vpn",   // имя создаваемой зоны туннеля
};

function resolve_opts(opts) {
	let o = {};
	for (let k in FW_DEFAULTS) o[k] = FW_DEFAULTS[k];
	if (opts) for (let k in opts) if (exists(FW_DEFAULTS, k)) o[k] = opts[k];
	return o;
}

// build_nat_ops(opts) → { teardown, setup } — uci firewall: зона туннеля (masq + mtu_fix) и
// forwarding lan→vpn. Именованные секции (cheburnet_<zone>) → идемпотентность через delete-before-set
// (как peer-секция в vpn-шаге). Это ЧИСТЫЙ uci-конфиг: откатывается snapshot'ом (firewall ∈
// CLEAN_CONFIGS), в отличие от nft/ip ниже. Применять ДО nft-инъекции: fw4 reload пересобирает
// таблицу inet fw4 и стёр бы наши цепочки, если бы шёл после них (см. apply.uc).
//   masq=1   — SNAT трафика LAN-клиентов, ушедшего в awg0 (без него обратный путь не находится);
//   mtu_fix=1 — MSS-clamp под MTU туннеля; input REJECT — извне в роутер по туннелю не лезут.
function build_nat_ops(opts) {
	let o = opts ?? {};
	let tif  = o.tunnel_if ?? "awg0";
	let lan  = o.lan_zone ?? "lan";
	let zone = o.vpn_zone ?? "vpn";
	let zsect = "cheburnet_" + zone;            // именованная секция zone
	let fsect = "cheburnet_" + lan + "_" + zone; // именованная секция forwarding

	let teardown = [
		sprintf("delete firewall.%s", zsect),
		sprintf("delete firewall.%s", fsect),
	];
	let setup = [
		sprintf("set firewall.%s=zone", zsect),
		sprintf("set firewall.%s.name='%s'", zsect, zone),
		sprintf("add_list firewall.%s.network='%s'", zsect, tif),
		sprintf("set firewall.%s.masq='1'", zsect),
		sprintf("set firewall.%s.mtu_fix='1'", zsect),
		sprintf("set firewall.%s.input='REJECT'", zsect),
		sprintf("set firewall.%s.output='ACCEPT'", zsect),
		sprintf("set firewall.%s.forward='REJECT'", zsect),
		sprintf("set firewall.%s=forwarding", fsect),
		sprintf("set firewall.%s.src='%s'", fsect, lan),
		sprintf("set firewall.%s.dest='%s'", fsect, zone),
	];
	return { teardown: teardown, setup: setup };
}

// render_nft_file(routing_plan, o) → содержимое /etc/nftables.d/10-cheburnet.nft.
// Формат — тело, которое fw4 включает ВНУТРЬ table inet fw4 (без обёртки table и без `add`):
// декларативные `set …` и `chain …` с правилами. Возвращает { content, killswitch }.
// killswitch отдаём отдельно (список ks-правил) — для юнит-проверки security-семантики.
function render_nft_file(routing_plan, o) {
	let ro = routing_plan.opts;
	let wan = ro.wan_if, mark = ro.mark;
	let L = [
		"# cheburnet: пометка direct-трафика + kill-switch (см. firewall.uc).",
		"# fw4 включает этот файл в table inet fw4 при каждом reload — правила переживают reload.",
		sprintf("set %s { type ipv4_addr; flags interval; }", ro.set4),
	];
	if (ro.ipv6)
		push(L, sprintf("set %s { type ipv6_addr; flags interval; }", ro.set6));

	// Цепочка пометки (prerouting/mangle): daddr ∈ direct → mark. В travel правил нет.
	push(L, sprintf("chain %s {", o.mark_chain));
	push(L, "\ttype filter hook prerouting priority mangle; policy accept;");
	if (ro.mode != "travel") {
		push(L, sprintf("\tip daddr @%s meta mark set %s", ro.set4, mark));
		if (ro.ipv6)
			push(L, sprintf("\tip6 daddr @%s meta mark set %s", ro.set6, mark));
	}
	push(L, "}");

	// kill-switch (forward/filter). ct state new: рубим только новые соединения наружу мимо
	// туннеля; established (обратный трафик) проходит. AWG-handshake — output роутера, не
	// forward, поэтому kill-switch его не задевает. drop в base-chain финализирует пакет,
	// так что порядок относительно fw4-forward неважен.
	let ks = [];
	if (o.killswitch && wan) {
		if (ro.mode == "travel")
			push(ks, sprintf("oifname \"%s\" ct state new drop", wan)); // всё в WAN → drop
		else
			push(ks, sprintf("oifname \"%s\" meta mark != %s ct state new drop", wan, mark));
		push(L, sprintf("chain %s {", o.ks_chain));
		push(L, "\ttype filter hook forward priority filter; policy accept;");
		for (let i = 0; i < length(ks); i++)
			push(L, "\t" + ks[i]);
		push(L, "}");
	}

	return { content: join("\n", L) + "\n", killswitch: ks };
}

// render_hotplug() → текст hotplug-хука (POSIX sh, busybox-ash).
//
// ЗАЧЕМ (оплачено живым прогоном 2026-08-01): nft-часть переживает перезагрузку файлом в
// /etc/nftables.d/, а ip-часть (`ip rule fwmark → table`, default этой таблицы через WAN) живёт
// ТОЛЬКО в ядре и после ребута исчезает. Симптом самый неприятный из возможных: панель зелёная,
// туннель поднят, наборы direct наполняются — а direct-домены идут в туннель, потому что
// направлять их стало нечем. Тихо отключается главная функция продукта.
//
// Хук намеренно тонкий: вся логика (какой WAN, какие домены, какой туннель) — в reapply.uc, чтобы
// после ребута применялось РОВНО то же, что после откатa.
//
// Реагируем на ifup ЛЮБОГО интерфейса, а не только «wan»: имя WAN-логики в netifd бывает другим
// (wwan, wan_4, нестандартные сборки), и фильтр по имени тихо не срабатывал бы именно там, где
// помочь и надо. Порядок подъёма интерфейсов при загрузке тоже не гарантирован.
//
// ГЕЙТ ПРОВЕРЯЕТ ОБА АРТЕФАКТА — правило И маршрут в таблице direct (замер на живом роутере,
// 2026-08-01): при первом ifup (lan, ~20-я секунда после загрузки) WAN ещё не готов, маршрут
// добавиться не может, и остаётся ПОЛОВИНА — правило есть, таблица пуста. Гейт «есть правило» тогда
// закрывал путь к починке навсегда: следующий ifup (уже с готовым WAN) выходил сразу. Пока
// направлять некуда, split не работает, поэтому ждём именно оба артефакта.
//
// Номер таблицы подставляется из плана, а не зашит: его знает движок, а хук — генерируемый файл.
function render_hotplug(table) {
	return join("\n", [
		"#!/bin/sh",
		"# cheburnet: вернуть ip-часть data-plane (policy-routing) — она живёт только в ядре.",
		"# Файл создаёт шаг firewall; правки перезапишутся при следующем применении.",
		'[ "$ACTION" = "ifup" ] || exit 0',
		"# Оба артефакта на месте — выходим сразу (дешёвый путь на каждый ifup).",
		sprintf("if ip rule show 2>/dev/null | grep -q fwmark && \\"),
		sprintf("   ip route show table %d 2>/dev/null | grep -q default; then", table),
		"\texit 0",
		"fi",
		"ucode -R /usr/share/cheburnet/engine/install/reapply.uc >/dev/null 2>&1",
		"exit 0",
	]) + "\n";
}

// build_firewall_plan(routing_plan, opts) → структурный план.
// wan_if берётся из routing_plan.opts (его кладёт gather/preflight) и НЕ хардкодится — это
// прямой урок v1: хардкод LAN/WAN = тихо-дырявый kill-switch на нестандартной подсети.
// kill-switch ключуется по oifname WAN, а не по LAN-CIDR → вообще не зависит от подсети.
function build_firewall_plan(routing_plan, opts) {
	let o = resolve_opts(opts);
	let ro = routing_plan.opts;
	let wan = ro.wan_if;
	let errors = [];

	if (o.killswitch && !wan)
		push(errors, "нет wan_if: kill-switch не построить без WAN-интерфейса (не хардкодим)");

	let nft = render_nft_file(routing_plan, o);

	// policy routing: правило fwmark + default в table через WAN (из routing). Teardown —
	// снять правило и очистить таблицу (ip rule add не идемпотентен → del перед add).
	let ip_setup = render_iprules(routing_plan);
	let ip_teardown = [];
	if (ro.mode != "travel") {
		push(ip_teardown, sprintf("ip rule del fwmark %s lookup %d", ro.mark, ro.table));
		if (ro.ipv6)
			push(ip_teardown, sprintf("ip -6 rule del fwmark %s lookup %d", ro.mark, ro.table));
		push(ip_teardown, sprintf("ip route flush table %d", ro.table));
		if (ro.ipv6)
			push(ip_teardown, sprintf("ip -6 route flush table %d", ro.table));
	}

	// NAT-зона туннеля (uci firewall, чистый откат). Выключаемо через fw_opts.nat=false.
	let nat = o.nat ? build_nat_ops(o) : { teardown: [], setup: [] };

	// fw4 reload вычищает ПРАВИЛА, но чужие цепочки/сеты в inet fw4 не удаляет (поймано
	// smoke): после unlink nftables.d-файла остаются пустые hooked-цепочки. Снимаем явно.
	// Всегда все четыре имени, независимо от текущих opts: прошлая установка могла их создать.
	let nft_teardown = [
		sprintf("delete chain inet fw4 %s", o.mark_chain),
		sprintf("delete chain inet fw4 %s", o.ks_chain),
		sprintf("delete set inet fw4 %s", ro.set4),
		sprintf("delete set inet fw4 %s", ro.set6),
	];

	return {
		ok: length(errors) == 0,
		errors: errors,
		uci_teardown: nat.teardown,
		uci_setup: nat.setup,
		nft_path: NFT_PATH,
		nft_file: nft.content,
		hotplug_path: HOTPLUG_PATH,
		hotplug_file: render_hotplug(ro.table),
		nft_teardown: nft_teardown,
		ip_teardown: ip_teardown,
		ip_setup: ip_setup,
		killswitch: nft.killswitch,
	};
}

export { NFT_PATH, HOTPLUG_PATH, build_nat_ops, render_nft_file, render_hotplug, build_firewall_plan };
