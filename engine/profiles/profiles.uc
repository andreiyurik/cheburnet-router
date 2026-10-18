// profiles.uc — профили AWG-серверов («страны»): список, приоритет, активный, решение автосмены (чисто).
// Хранилище — store.uc (/etc/cheburnet/profiles.json + profiles/<id>.conf, 600). Тесты: tests/.
// ИНВАРИАНТ: интерфейс один (awg0) — профиль это лишь СОХРАНЁННЫЙ .conf; применяет его тот же
// replace_vpn.uc с автооткатом, что и ручную замену сервера. Подробно: [[0008-awg-profiles]].

const MAX_PROFILES = 16;
// Квирк ucode: length() считает БАЙТЫ — 64 байта = 32 кириллических символа.
const MAX_NAME = 64;

// Подряд «мёртвых» тиков сторожа (по 5 мин), после которых пробуем другой сервер: один-два — это
// переходные состояния (rekey, перезапуск WAN), а не мёртвый сервер.
const FAILOVER_AFTER = 3;
// Перебрали всех и никто не ответил — повторяем круг не раньше, чем через столько мёртвых тиков (~1 ч).
const FAILOVER_RETRY = 12;

// normalize(raw) → { profiles:[{id,name}], active, auto, next_id, last_switch }. Мусор — пустой дефолт.
// ИНВАРИАНТ: порядок profiles = приоритет автосмены.
function normalize(raw) {
	let r = (type(raw) == "object") ? raw : {};
	let out = [];
	for (let p in (type(r.profiles) == "array" ? r.profiles : []))
		if (type(p) == "object" && type(p.id) == "string" && match(p.id, /^p[0-9]+$/) && type(p.name) == "string")
			push(out, { id: p.id, name: p.name });
	let active = null;
	for (let p in out) if (p.id == r.active) active = p.id;
	return {
		profiles: out,
		active: active,
		auto: (r.auto === true),
		next_id: (type(r.next_id) == "int" && r.next_id > 0) ? r.next_id : length(out) + 1,
		last_switch: (type(r.last_switch) == "object") ? r.last_switch : null,
	};
}

function find(st, id) {
	for (let p in st.profiles) if (p.id == id) return p;
	return null;
}

function name_of(st, id) {
	let p = find(st, id);
	return p ? p.name : null;
}

// clean_name(raw) → { ok, name, error }. Имя — вход пользователя (ubus): без управляющих символов,
// до MAX_NAME байт, уникально (иначе «Германия не отвечает — пробую Германия» в журнале).
// Квирк ucode: lc() понижает только ASCII — кириллица сравнивается с учётом регистра.
function clean_name(st, raw, except_id) {
	let n = trim(replace(raw ?? "", /[[:cntrl:]]/g, " "));
	if (length(n) == 0) return { ok: false, error: "введите название сервера" };
	if (length(n) > MAX_NAME) return { ok: false, error: "название слишком длинное (до 32 букв)" };
	for (let p in st.profiles)
		if (p.id != except_id && lc(p.name) == lc(n))
			return { ok: false, error: sprintf("сервер «%s» уже есть", n) };
	return { ok: true, name: n };
}

// add(st, name) → { ok, state, id, error }. id выдаётся из счётчика (имя файла — не из ввода).
function add(st, name) {
	if (length(st.profiles) >= MAX_PROFILES)
		return { ok: false, error: sprintf("не больше %d серверов — удалите лишний", MAX_PROFILES) };
	let c = clean_name(st, name, null);
	if (!c.ok) return c;
	let id = sprintf("p%d", st.next_id);
	let next = normalize(st);
	push(next.profiles, { id: id, name: c.name });
	next.next_id = st.next_id + 1;
	return { ok: true, state: next, id: id };
}

function rename(st, id, name) {
	if (!find(st, id)) return { ok: false, error: "нет такого сервера" };
	let c = clean_name(st, name, id);
	if (!c.ok) return c;
	let next = normalize(st);
	for (let p in next.profiles) if (p.id == id) p.name = c.name;
	return { ok: true, state: next };
}

// remove(st, id) — активный удалить нельзя: на нём сейчас держится весь дом.
function remove(st, id) {
	if (!find(st, id)) return { ok: false, error: "нет такого сервера" };
	if (st.active == id) return { ok: false, error: "этот сервер сейчас подключён — сначала переключитесь на другой" };
	let next = normalize(st);
	next.profiles = filter(next.profiles, (p) => p.id != id);
	return { ok: true, state: next };
}

// reorder(st, ids) — новый приоритет; ids обязан быть перестановкой текущих id (вход ubus).
function reorder(st, ids) {
	if (type(ids) != "array" || length(ids) != length(st.profiles))
		return { ok: false, error: "порядок должен перечислять все серверы" };
	let next = normalize(st), out = [];
	for (let id in ids) {
		let p = find(st, id);
		if (!p || index(map(out, (q) => q.id), id) >= 0)
			return { ok: false, error: "порядок должен перечислять все серверы ровно по разу" };
		push(out, { id: p.id, name: p.name });
	}
	next.profiles = out;
	return { ok: true, state: next };
}

// mark_active(st, id, now, auto_switch) → state: id стал активным (после подтверждённого handshake).
// Смену запоминаем для панели («переключился сам: Германия → Нидерланды»).
function mark_active(st, id, now, auto_switch) {
	let next = normalize(st);
	if (next.active != id)
		next.last_switch = { from: name_of(st, st.active), to: name_of(st, id), at: now, auto: auto_switch === true };
	next.active = id;
	return next;
}

// failover_order(st) → id кандидатов по приоритету: сначала те, что ниже активного, затем сначала
// списка (круг), активный не включаем. Нет активного — весь список.
function failover_order(st) {
	let ids = map(st.profiles, (p) => p.id);
	let at = index(ids, st.active);
	if (at < 0) return ids;
	return [ ...slice(ids, at + 1), ...slice(ids, 0, at) ];
}

// decide_failover(ctx, prev) → { action:{profile}|null, log:[], state }.
//   ctx: { st (normalize), eligible, tunnel_alive, wan_online (null = не проверяли) };
//   prev: { dead, tried:[], wan_down, exhausted } с прошлого тика.
// eligible=false — автосмена выключена, не AWG, аварийный режим, идёт операция, ребут: молча сброс.
// ИНВАРИАНТ: при недоступном домашнем интернете серверы НЕ перебираем — дело не в них.
function decide_failover(ctx, prev) {
	let p = prev ?? {};
	if (!ctx.eligible || length(ctx.st.profiles) < 2)
		return { action: null, log: [], state: {} };
	if (ctx.tunnel_alive)
		return { action: null, log: (p.dead ?? 0) >= FAILOVER_AFTER ? [ "VPN снова работает" ] : [], state: {} };

	let dead = (p.dead ?? 0) + 1;
	let tried = (type(p.tried) == "array") ? p.tried : [];
	if (dead < FAILOVER_AFTER)
		return { action: null, log: [], state: { dead: dead, tried: tried } };

	if (ctx.wan_online === false)
		return { action: null,
		         log: p.wan_down ? [] : [ "нет домашнего интернета — серверы не перебираю, дело не в них" ],
		         state: { dead: dead, tried: tried, wan_down: true, exhausted: p.exhausted } };

	if (p.exhausted && dead - p.exhausted < FAILOVER_RETRY)
		return { action: null, log: [], state: { dead: dead, tried: tried, exhausted: p.exhausted } };
	if (p.exhausted) tried = [];

	let cands = filter(failover_order(ctx.st), (id) => index(tried, id) < 0);
	if (length(cands) == 0)
		return { action: null,
		         log: [ "ни один сохранённый сервер не ответил — остаюсь на прежнем, повторю через час" ],
		         state: { dead: dead, tried: tried, exhausted: dead } };

	let who = name_of(ctx.st, ctx.st.active);
	return { action: { profile: cands[0] },
	         log: [ sprintf("%s не отвечает — пробую %s", who ? "«" + who + "»" : "VPN", "«" + name_of(ctx.st, cands[0]) + "»") ],
	         state: { dead: dead, tried: [ ...tried, cands[0] ] } };
}

// public_view(st, protocol) → то, что видит панель: без секретов; active — только при AWG.
function public_view(st, protocol) {
	let awg = (protocol == "awg");
	return {
		profiles: map(st.profiles, (p) => ({ id: p.id, name: p.name, active: awg && p.id == st.active })),
		active: awg ? st.active : null,
		auto: st.auto,
		max: MAX_PROFILES,
		last_switch: st.last_switch,
	};
}

export { normalize, find, name_of, add, rename, remove, reorder, mark_active, failover_order,
         decide_failover, public_view, MAX_PROFILES, FAILOVER_AFTER, FAILOVER_RETRY };
