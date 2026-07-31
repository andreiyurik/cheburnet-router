// install.uc — оркестрация установки: ЧИСТАЯ политика связывания кирпичей.
//
// Поток (см. reliability): preflight → snapshot UCI → шаги по порядку → health-check →
// commit / rollback. Здесь — чистая логика: реестр шагов и порядок, область snapshot (какие
// uci-конфиги защищаем) и решение commit/rollback/abort по результатам. Само выполнение
// (preflight, snapshot, apply шагов, health) — в run.uc (импурно, QEMU).
//
// Честность отката: ЧИСТЫЕ шаги (uci) откатываются snapshot'ом; ГРЯЗНЫЙ шаг (firewall —
// runtime nft/ip, не uci) при сбое чистится своим teardown (safe-fail), а не иллюзией uci-отката.

import { is_clean_config } from "../rollback/rollback.uc";

// Реестр шагов в порядке применения. configs — uci-конфиги, которые шаг меняет (для snapshot).
// rollback: clean = откатывается uci-snapshot'ом; dirty = состояние ядра, safe-fail через teardown.
// needs — что шагу подать на stdin (для run.uc): awg_conf | domains | none.
const STEPS = [
	// needs=tunnel_conf у ОБОИХ туннель-шагов: какой именно текст подать (AWG .conf / vless:// /
	// hysteria2://), решает conf_key активного протокола — см. PROTOCOLS и step_stdin в run.uc.
	// Так добавление протокола не требует новой ветки в раздаче stdin.
	{ name: "vpn",      configs: [ "network" ],                  rollback: "clean", needs: "tunnel_conf" },
	// singbox — альтернативный туннель (Full-тир: VLESS+Reality или Hysteria2). Взаимоисключающий
	// с vpn: активен ровно один (см. PROTOCOLS). Гибрид: uci sing-box + network-маршрут (чистый
	// откат snapshot'ом) + config.json/сервис (runtime → dirty teardown). network в configs →
	// интерфейс singtun откатывается uci-снимком (как NAT-зона у firewall). По умолчанию ОТКЛЮЧЁН.
	{ name: "singbox",  configs: [ "sing-box", "network" ],      rollback: "dirty", needs: "tunnel_conf" },
	{ name: "dns",      configs: [ "dhcp" ],                     rollback: "clean", needs: "domains" },
	{ name: "doh",      configs: [ "https-dns-proxy", "dhcp" ],  rollback: "clean", needs: "doh" },
	// wifi — перед firewall: настройка радио независима от split-routing. Нет радио/ключа → no-op.
	{ name: "wifi",     configs: [ "wireless" ],                 rollback: "clean", needs: "wifi" },
	// firewall — последним: пометка/ip rule/kill-switch поверх поднятого туннеля. Гибрид: NAT-зона —
	// uci firewall (чистый откат snapshot'ом), цепочки/ip rule — runtime → шаг dirty (teardown).
	{ name: "firewall", configs: [ "firewall" ],                 rollback: "dirty", needs: "domains" },
];

// Туннельные протоколы — ТРИ ОСИ ПОКРЫТИЯ (ADR 0004), каждая лечит свою поломку:
//   awg       — AmneziaWG в ядре: слабое железо (единственный, кто считается в ядре). Дефолт.
//   reality   — VLESS+Reality через sing-box: трафик НЕ ПРОХОДИТ (DPI, зондирование, блок UDP).
//   hysteria2 — Hysteria2 через тот же sing-box: трафик проходит, но ПЛОХО (потери, 4G, троттлинг).
// Взаимоисключающие: каждый ставит свой туннель-шаг и презентует свой интерфейс (цель
// policy-routing/NAT-зоны/health-check). Оба Full-протокола делят ОДИН шаг и ОДИН интерфейс →
// весь data-plane (firewall/routing/проба/health) переиспользуется без изменений, туннель
// взаимозаменяем, а третий протокол не приносит своей семантики здоровья (это инвариант ADR 0004).
// conf_key — под каким ключом лежит конфиг этого протокола в payload установки (run.uc/step_stdin).
const PROTOCOLS = {
	awg:       { step: "vpn",     tunnel_if: "awg0",     conf_key: "awg_conf" },
	reality:   { step: "singbox", tunnel_if: "singtun0", conf_key: "reality_conf" },
	hysteria2: { step: "singbox", tunnel_if: "singtun0", conf_key: "hysteria2_conf" },
};
const DEFAULT_PROTOCOL = "awg";
const TUNNEL_STEPS = [ "vpn", "singbox" ]; // взаимоисключающие шаги (ровно один активен)
const SINGBOX_STEP = "singbox";

// protocol_ids() → список валидных протоколов (для enum в ubus-реестре — граница доверия).
function protocol_ids() {
	let out = [];
	for (let k in PROTOCOLS) push(out, k);
	return out;
}

function default_protocol() {
	return DEFAULT_PROTOCOL;
}

// tunnel_info(protocol) → { step, tunnel_if, conf_key } активного протокола
// (неизвестный → дефолт, fail-safe).
function tunnel_info(protocol) {
	return PROTOCOLS[protocol] ?? PROTOCOLS[DEFAULT_PROTOCOL];
}

// uses_singbox(protocol) — протокол едет на sing-box (Full-тир)? Спрашиваем про ШАГ, а не
// сверяем со списком имён: так каждое место, которое ветвится на «Full или ядро» (догрузка
// бинаря, проба вместо handshake, признак здоровья, гейт замены конфига), автоматически
// понимает новый протокол на sing-box — без правки в трёх файлах и без риска забыть один.
function uses_singbox(protocol) {
	return tunnel_info(protocol).step == SINGBOX_STEP;
}

// singbox_protocols() → протоколы Full-тира (для UI/гейтов: что предлагать на подходящем железе).
function singbox_protocols() {
	let out = [];
	for (let k in PROTOCOLS)
		if (PROTOCOLS[k].step == SINGBOX_STEP) push(out, k);
	return out;
}

// disabled_tunnels(protocol) → имена туннель-шагов, которые НЕ применяем (все, кроме активного).
// run.uc передаёт их в enabled_steps({disable}) → в установке остаётся ровно один туннель.
function disabled_tunnels(protocol) {
	let active = tunnel_info(protocol).step;
	let out = [];
	for (let i = 0; i < length(TUNNEL_STEPS); i++)
		if (TUNNEL_STEPS[i] != active) push(out, TUNNEL_STEPS[i]);
	return out;
}

function copy_step(s) {
	let c = [];
	for (let i = 0; i < length(s.configs); i++) push(c, s.configs[i]);
	return { name: s.name, configs: c, rollback: s.rollback, needs: s.needs };
}

// tunnel_conf(protocol, cfg) → текст конфига активного туннеля из payload (по conf_key).
// ЧИСТАЯ: run.uc раздаёт её результат туннель-шагу на stdin. Вынесено сюда, чтобы «какой ключ у
// какого протокола» жило ровно в PROTOCOLS, а не размазывалось по if'ам импурного слоя.
function tunnel_conf(protocol, cfg) {
	let key = tunnel_info(protocol).conf_key;
	let v = (cfg ?? {})[key];
	return (type(v) == "string") ? v : "";
}

// all_steps() → копия реестра (в порядке применения).
function all_steps() {
	let out = [];
	for (let i = 0; i < length(STEPS); i++) push(out, copy_step(STEPS[i]));
	return out;
}

// enabled_steps(opts) → шаги к применению. opts.disable — список имён, которые пропустить.
function enabled_steps(opts) {
	let disable = (opts && opts.disable) ? opts.disable : [];
	let out = [];
	for (let i = 0; i < length(STEPS); i++)
		if (index(disable, STEPS[i].name) < 0)
			push(out, copy_step(STEPS[i]));
	return out;
}

// snapshot_scope(steps) → uci-конфиги для snapshot: объединение configs всех шагов, только
// реально откатываемые (is_clean_config), без дублей, в порядке встречи. Классификация шага
// dirty НЕ исключает его uci-configs: у гибридного шага (firewall) uci-часть (NAT-зона)
// откатывается snapshot'ом, а runtime-часть (nft/ip) — его собственным teardown'ом.
function snapshot_scope(steps) {
	let seen = {}, out = [];
	for (let i = 0; i < length(steps); i++) {
		let s = steps[i];
		for (let j = 0; j < length(s.configs); j++) {
			let c = s.configs[j];
			if (is_clean_config(c) && !seen[c]) { seen[c] = true; push(out, c); }
		}
	}
	return out;
}

// dirty_steps(steps) → имена грязных шагов (их откат при сбое — teardown, не uci-restore).
function dirty_steps(steps) {
	let out = [];
	for (let i = 0; i < length(steps); i++)
		if (steps[i].rollback == "dirty") push(out, steps[i].name);
	return out;
}

// decide_outcome(results) → { action, code, reason, failed }. action ∈ abort | rollback | commit.
//   results = { preflight:{ok}, steps:[{name,ok}...], health:{ok}|null }
// Порядок проверок = fail-safe: нет preflight → abort (ничего не трогали); упал шаг или
// health → rollback; всё ок → commit.
// code — машинный код исхода для UI ("preflight" | "step:<имя>" | "health" | "ok"): по нему
// веб-мастер показывает адресную диагностику («VPN-сервер не ответил» ≠ «упал шаг»), а не
// одинаковое «установка не удалась» на всё.
function decide_outcome(results) {
	if (!results || !results.preflight || results.preflight.ok !== true)
		return { action: "abort", code: "preflight", reason: "preflight не пройден — изменений нет", failed: [] };

	let failed = [];
	let steps = results.steps ?? [];
	for (let i = 0; i < length(steps); i++)
		if (steps[i].ok !== true) push(failed, steps[i].name);
	if (length(failed) > 0)
		return { action: "rollback", code: "step:" + failed[0],
			reason: sprintf("шаги упали: %s", join(", ", failed)), failed: failed };

	if (results.health && results.health.ok !== true)
		return { action: "rollback", code: "health", reason: "health-check не пройден", failed: [] };

	return { action: "commit", code: "ok", reason: "все фазы успешны", failed: [] };
}

// handshake_state(hs) — состояние AWG-рукопожатия по выводу `awg show <if> latest-handshakes`
// (строки "<pubkey>\t<секунд_с_последнего_рукопожатия>"). ЧИСТАЯ (вход — строка вывода awg):
// health-check (run.uc, импурный поллинг) принимает решение тестируемой логикой. Это суть fix #2 —
// раньше health читал handshake ОДИН раз сразу после firewall-шага и почти всегда видел "waiting"
// → откатывал рабочую установку.
//   "none"    — пустой вывод: awg-интерфейса нет / vpn не настраивался → health НЕ валим;
//   "up"      — хотя бы у одного peer ненулевой timestamp (рукопожатие было);
//   "waiting" — peer(ы) есть, но рукопожатий ещё нет → поллить дальше.
// Разбор по строкам (а не regex "\t0$"): корректно для нескольких peer и без зависимости от
// multiline-семантики `$`.
function handshake_state(hs) {
	let s = trim(hs ?? "");
	if (length(s) == 0) return "none";
	let lines = split(s, "\n");
	for (let i = 0; i < length(lines); i++) {
		let f = split(trim(lines[i]), "\t");      // [pubkey, секунд]; pubkey — base64, без табов
		if (length(f) >= 2 && int(f[length(f) - 1]) > 0)
			return "up";
	}
	return "waiting";
}

// Свежесть AWG-рукопожатия для панели: сервер отвечал не позже этого окна (сек). Живой AWG
// пингует peer'а раз в ~2 мин; 300 с даёт запас на один пропуск, не объявляя туннель мёртвым.
const HANDSHAKE_FRESH_S = 300;

// tunnel_health(protocol, facts) → "up" | "down" — ОДИН признак здоровья туннеля для панели,
// одинаково отвечающий для любого протокола. ЧИСТАЯ (вход — уже собранные факты).
//
// ЗАЧЕМ: панель раньше судила о туннеле ТОЛЬКО по AWG-рукопожатию, а у sing-box-протоколов
// интерфейса awg0 нет — значит на РАБОТАЮЩЕМ Reality она показывала «VPN не работает» и вела
// заменять AWG-конфиг (тупик: движок такую замену при активном reality отвергает). Признак обязан
// зависеть от протокола, а не от одного awg.
//
// Ветвимся по ШАГУ (uses_singbox), а не по имени протокола: Hysteria2 приехал на тот же sing-box
// и тот же singtun0 — и получил правильную семантику здоровья без правки этой функции. Разная
// семантика здоровья по протоколам — доказанный источник багов (ADR 0004).
//
// facts: { hs_age (сек с последнего рукопожатия | null), sb_running (bool), tun_up (bool) }
//   ядро (awg)  — сервер ОТВЕЧАЛ недавно (рукопожатие в окне): сильный признак, «трафик идёт».
//   sing-box    — туннель ПОДНЯТ (процесс sing-box жив И TUN-устройство up). Слабее: это не
//                 доказательство, что сервер отвечает (сессий наружу тут не видно). Поэтому панель
//                 для них и формулирует слабее — «туннель поднят», без «всё работает». Живая
//                 проверка достижимости — connectivity-probe (probe.uc), она дорогая (пин
//                 host-route + fetch) и потому идёт при установке/замене, а не на каждый поллинг.
function tunnel_health(protocol, facts) {
	let f = facts ?? {};
	if (uses_singbox(protocol ?? default_protocol()))
		return (f.sb_running === true && f.tun_up === true) ? "up" : "down";
	let age = f.hs_age;
	return (type(age) == "int" && age >= 0 && age < HANDSHAKE_FRESH_S) ? "up" : "down";
}

// fresh_handshake(hs, started) — есть ли у КАКОГО-ЛИБО peer'а рукопожатие не старше started
// (unix-время). ЧИСТАЯ: replace_vpn (импурный 30с-гейт замены конфига) решает commit/restore
// этой логикой. Разбор построчно, как handshake_state: multi-peer конфиг давал многострочный
// вывод awk, единый regex на нём всегда фейлил — и РАБОЧИЙ новый конфиг ложно откатывался.
function fresh_handshake(hs, started) {
	let s = trim(hs ?? "");
	if (length(s) == 0) return false;
	let lines = split(s, "\n");
	for (let i = 0; i < length(lines); i++) {
		// последний токен строки = секунды; принимаем и сырой вывод awg ("pubkey\tсекунд"),
		// и урезанный (одни числа) — вызывающему не нужно готовить формат
		let f = split(trim(lines[i]), /[ \t]+/);
		let ts = f[length(f) - 1];
		if (match(ts, /^[0-9]+$/) && int(ts) >= started)
			return true;
	}
	return false;
}

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

// route_uses_iface(route_out, iface) — идёт ли маршрут через iface по выводу `ip route get <ip>`.
// ЧИСТАЯ (вход — строка вывода ip): connectivity-probe reality (run.uc/replace_reality, импурно)
// форсирует host-route на probe-IP через туннель и этой функцией подтверждает, что маршрут реально
// лёг на singtun0, а не утёк на WAN — иначе рабочий-с-виду fetch мог бы пройти мимо туннеля.
// Формат первой строки: "<ip> dev <iface> src <...>" (или "... via <gw> dev <iface> ...").
// Берём токен строго ПОСЛЕ "dev" — не подстрокой (dev singtun0 ≠ dev singtun00).
function route_uses_iface(route_out, iface) {
	let s = trim(route_out ?? "");
	if (length(s) == 0 || length(iface ?? "") == 0) return false;
	let first = split(s, "\n")[0];
	let toks = split(trim(first), /[ \t]+/);
	for (let i = 0; i + 1 < length(toks); i++)
		if (toks[i] == "dev" && toks[i + 1] == iface)
			return true;
	return false;
}

export { protocol_ids, default_protocol, tunnel_info, uses_singbox, singbox_protocols, tunnel_conf,
         disabled_tunnels, all_steps, enabled_steps, snapshot_scope, dirty_steps, decide_outcome,
         handshake_state, fresh_handshake, tunnel_health, HANDSHAKE_FRESH_S,
         pick_wan_fallback, route_uses_iface };
