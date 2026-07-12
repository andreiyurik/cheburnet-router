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
	{ name: "vpn",      configs: [ "network" ],                  rollback: "clean", needs: "awg_conf" },
	// singbox — альтернативный туннель (Full-тир, VLESS+Reality). Взаимоисключающий с vpn:
	// активен ровно один (см. PROTOCOLS). Гибрид: uci sing-box + network-маршрут (чистый откат
	// snapshot'ом) + config.json/сервис (runtime → dirty teardown). network в configs → интерфейс
	// singtun откатывается uci-снимком (как NAT-зона у firewall). По умолчанию ОТКЛЮЧЁН (awg).
	{ name: "singbox",  configs: [ "sing-box", "network" ],      rollback: "dirty", needs: "reality" },
	{ name: "dns",      configs: [ "dhcp" ],                     rollback: "clean", needs: "domains" },
	{ name: "doh",      configs: [ "https-dns-proxy", "dhcp" ],  rollback: "clean", needs: "doh" },
	// wifi — перед firewall: настройка радио независима от split-routing. Нет радио/ключа → no-op.
	{ name: "wifi",     configs: [ "wireless" ],                 rollback: "clean", needs: "wifi" },
	// firewall — последним: пометка/ip rule/kill-switch поверх поднятого туннеля. Гибрид: NAT-зона —
	// uci firewall (чистый откат snapshot'ом), цепочки/ip rule — runtime → шаг dirty (teardown).
	{ name: "firewall", configs: [ "firewall" ],                 rollback: "dirty", needs: "domains" },
];

// Туннельные протоколы (две оси покрытия, ADR 0004): awg = AmneziaWG в ядре (Light, дефолт);
// reality = VLESS+Reality через sing-box (Full, для устойчивости к DPI на мощном железе).
// Взаимоисключающие: каждый ставит свой туннель-шаг и презентует свой интерфейс (цель
// policy-routing/NAT-зоны/health-check). Один интерфейс → весь data-plane (firewall/routing)
// переиспользуется без изменений — туннель взаимозаменяем.
const PROTOCOLS = {
	awg:     { step: "vpn",     tunnel_if: "awg0" },
	reality: { step: "singbox", tunnel_if: "singtun0" },
};
const DEFAULT_PROTOCOL = "awg";
const TUNNEL_STEPS = [ "vpn", "singbox" ]; // взаимоисключающие шаги (ровно один активен)

// protocol_ids() → список валидных протоколов (для enum в ubus-реестре — граница доверия).
function protocol_ids() {
	let out = [];
	for (let k in PROTOCOLS) push(out, k);
	return out;
}

function default_protocol() {
	return DEFAULT_PROTOCOL;
}

// tunnel_info(protocol) → { step, tunnel_if } активного протокола (неизвестный → дефолт, fail-safe).
function tunnel_info(protocol) {
	return PROTOCOLS[protocol] ?? PROTOCOLS[DEFAULT_PROTOCOL];
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

export { protocol_ids, default_protocol, tunnel_info, disabled_tunnels, all_steps, enabled_steps, snapshot_scope, dirty_steps, decide_outcome, handshake_state, fresh_handshake, pick_wan_fallback, route_uses_iface };
