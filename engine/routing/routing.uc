// routing.uc — генератор конфигов split-routing (чистая логика, без роутера).
//
// Вход:  список доменов прямого доступа + опции (mark, table, имена сетов, WAN, режим).
// Выход: «план маршрутизации» + рендереры в три артефакта data-plane:
//   • dnsmasq nftset-строки  — DNS кладёт резолвнутый IP в nft-сет  ([[dnsmasq-nftset]])
//   • nft объявления+правила — сеты и пометка пакетов fwmark        ([[policy-routing]])
//   • ip rule / ip route     — policy routing разводит туннель/WAN  ([[policy-routing]])
//
// Чистые функции → юнит-тестируются без роутера (engine/routing/tests). Идемпотентность,
// применение и резолв WAN — НЕ здесь, это слой engine/steps. Здесь только генерация текста.
//
// Ключевой инсайт: доменно-зависим ТОЛЬКО dnsmasq-слой. nft-правила и ip rule — функция
// от опций, а не от списка: ядро работает с сетом по ссылке (@direct), наполняет dnsmasq.

// Значения по умолчанию. Переопределяются через opts в build_plan().
const DEFAULTS = {
	mark: "0x1",        // fwmark «этот пакет — прямой» (см. policy-routing)
	table: 100,         // таблица маршрутизации для прямого пути
	family: "inet",     // nft family таблицы fw4
	fw_table: "fw4",    // таблица фаервола OpenWrt
	set4: "direct",     // nft-сет для IPv4-адресов прямого доступа
	set6: "direct6",    // nft-сет для IPv6
	ipv6: true,         // генерировать ли IPv6-артефакты
	mode: "home",       // home = split; travel = всё в туннель (full tunnel)
	hook: "prerouting", // prerouting = форвард-трафик LAN-клиентов (роутер);
	                    // output = локально-сгенерированный трафик (нужно для netns-теста)
	wan_if: null,       // имя WAN-интерфейса для default-маршрута в table; без него строки нет
	wan_gw: null,       // шлюз WAN (если есть); не хардкодим — приходит из steps/preflight
};

// set_names() → имена наших nft-сетов [v4, v6]. Единственный источник для всех, кто матчит
// «наши» nftset-записи dnsmasq (#<set>): dns-шаг, status, reset — не дрейфует при переименовании.
export function set_names() {
	return [ DEFAULTS.set4, DEFAULTS.set6 ];
}

// resolve_opts(opts) — DEFAULTS, перекрытые переданными opts. Неизвестные ключи пропускаем.
function resolve_opts(opts) {
	let o = {};
	for (let k in DEFAULTS)
		o[k] = DEFAULTS[k];
	if (opts)
		for (let k in opts)
			if (exists(DEFAULTS, k))
				o[k] = opts[k];
	return o;
}

// normalize_domain(raw) — привести к каноничной форме для матчинга в dnsmasq:
// trim, lowercase, снять завершающую корневую точку. НЕ валидирует — это is_valid_domain.
export function normalize_domain(raw) {
	let s = lc(trim(raw));
	// FQDN с корневой точкой (example.com.) и example.com — для нас один домен.
	while (length(s) > 0 && substr(s, length(s) - 1) == ".")
		s = substr(s, 0, length(s) - 1);
	return s;
}

// is_valid_domain(d) — true, если d пригоден как direct-домен dnsmasq.
// Требуем ASCII LDH (letters/digits/hyphen + точки): не-ASCII (IDN) в DNS живёт как
// punycode (xn--...), поэтому юникод сюда не пускаем — он бы не сматчился (см. dnsmasq-nftset).
export function is_valid_domain(d) {
	if (length(d) < 1 || length(d) > 253)
		return false;
	if (!match(d, /^[a-z0-9.-]+$/))
		return false;
	let labels = split(d, ".");
	if (length(labels) < 1)
		return false;
	for (let i = 0; i < length(labels); i++) {
		let l = labels[i];
		if (length(l) < 1 || length(l) > 63)
			return false;
		// Дефис в начале/конце метки недопустим (но xn--... валиден: дефисы в середине).
		if (substr(l, 0, 1) == "-" || substr(l, length(l) - 1) == "-")
			return false;
	}
	return true;
}

// build_plan(domains, opts) — нормализовать/отвалидировать домены и собрать план.
// Возвращает: { opts, domains: [чистые уникальные], rejected: [{raw, reason}] }.
// Невалидные домены ОТБРАСЫВАЕМ, а не падаем: промах списка = трафик уйдёт в туннель
// (fail-safe), а не утечёт. rejected отдаём наверх для честного отчёта пользователю.
export function build_plan(domains, opts) {
	let o = resolve_opts(opts);
	let seen = {}, clean = [], rejected = [];
	for (let i = 0; i < length(domains); i++) {
		let raw = domains[i];
		let d = normalize_domain(raw);
		if (length(d) == 0)
			continue; // пустая строка / комментарий-остаток — молча пропускаем
		if (!is_valid_domain(d)) {
			push(rejected, { raw: raw, reason: "not an ASCII LDH/punycode domain" });
			continue;
		}
		if (seen[d])
			continue; // дубликат
		seen[d] = true;
		push(clean, d);
	}
	return { opts: o, domains: clean, rejected: rejected };
}

// render_dnsmasq(plan) — значения для dnsmasq nftset (без обёртки UCI/conf).
// Формат: /<домен>/<family>#<nft-family>#<fw-table>#<set>  (см. dnsmasq-nftset).
// В режиме travel direct-доменов нет → пустой список (весь трафик в туннель).
export function render_dnsmasq(plan) {
	let o = plan.opts, out = [];
	if (o.mode == "travel")
		return out;
	for (let i = 0; i < length(plan.domains); i++) {
		let d = plan.domains[i];
		push(out, sprintf("/%s/4#%s#%s#%s", d, o.family, o.fw_table, o.set4));
		if (o.ipv6)
			push(out, sprintf("/%s/6#%s#%s#%s", d, o.family, o.fw_table, o.set6));
	}
	return out;
}

// render_dnsmasq_uci(plan) — те же значения, обёрнутые в строки UCI (/etc/config/dhcp).
export function render_dnsmasq_uci(plan) {
	let out = [];
	let vals = render_dnsmasq(plan);
	for (let i = 0; i < length(vals); i++)
		push(out, sprintf("list nftset '%s'", vals[i]));
	return out;
}

// render_sets(plan) — объявления nft-сетов (IPv4 + опц. IPv6). От доменов не зависят: ядро
// работает с сетом по ссылке (@direct), наполняет dnsmasq. Идемпотентны (add set — no-op,
// если есть). Таблица inet fw4 предполагается существующей (её держит firewall4).
export function render_sets(plan) {
	let o = plan.opts, out = [];
	push(out, sprintf("add set %s %s %s { type ipv4_addr; flags interval; }",
		o.family, o.fw_table, o.set4));
	if (o.ipv6)
		push(out, sprintf("add set %s %s %s { type ipv6_addr; flags interval; }",
			o.family, o.fw_table, o.set6));
	return out;
}

// render_mark_rules(plan, chain) — правила пометки «daddr ∈ direct → mark» в указанной цепочке.
// В travel-режиме пусто (нечего метить → всё в туннель). Цепочку выбирает вызывающий: для
// production это наша prerouting-цепочка (engine/steps/firewall), для netns-теста — mangle_output.
export function render_mark_rules(plan, chain) {
	let o = plan.opts, out = [];
	if (o.mode == "travel")
		return out;
	push(out, sprintf("add rule %s %s %s ip daddr @%s meta mark set %s",
		o.family, o.fw_table, chain, o.set4, o.mark));
	if (o.ipv6)
		push(out, sprintf("add rule %s %s %s ip6 daddr @%s meta mark set %s",
			o.family, o.fw_table, chain, o.set6, o.mark));
	return out;
}

// render_nft(plan) — сеты + правила пометки в цепочке, выбранной по hook: prerouting (форвард-
// трафик на роутере) или output (локальный трафик — путь netns-теста). Композиция из кирпичей
// выше, чтобы engine/steps/firewall переиспользовал их в своей (owned) цепочке без дублей.
export function render_nft(plan) {
	let chain = (plan.opts.hook == "output") ? "mangle_output" : "mangle_prerouting";
	let out = render_sets(plan);
	let marks = render_mark_rules(plan, chain);
	for (let i = 0; i < length(marks); i++)
		push(out, marks[i]);
	return out;
}

// render_iprules(plan) — команды policy routing: правило fwmark→table + default в table через WAN.
// В travel-режиме пусто: без правила направления весь трафик идёт main-таблицей (туннель).
// default-маршрут таблицы требует WAN-интерфейс (не хардкодим — приходит из steps/preflight);
// без wan_if строку маршрута не генерируем (правило fwmark всё равно полезно).
export function render_iprules(plan) {
	let o = plan.opts, out = [];
	if (o.mode == "travel")
		return out;
	push(out, sprintf("ip rule add fwmark %s lookup %d", o.mark, o.table));
	if (o.ipv6)
		push(out, sprintf("ip -6 rule add fwmark %s lookup %d", o.mark, o.table));
	if (o.wan_if) {
		if (o.wan_gw)
			push(out, sprintf("ip route add default via %s dev %s table %d",
				o.wan_gw, o.wan_if, o.table));
		else
			push(out, sprintf("ip route add default dev %s table %d",
				o.wan_if, o.table));
	}
	return out;
}

// render_all(plan) — все артефакты одним объектом (удобно для CLI/ubus/отладки).
export function render_all(plan) {
	return {
		dnsmasq: render_dnsmasq(plan),
		dnsmasq_uci: render_dnsmasq_uci(plan),
		nft: render_nft(plan),
		iprules: render_iprules(plan),
		rejected: plan.rejected,
	};
}
