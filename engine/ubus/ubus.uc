// ubus.uc — RPC-фасад движка: ЧИСТОЕ ядро валидации и роутинга входящих вызовов.
//
// Веб-мастер общается с движком через ubus RPC (см. web-wizard). Это ГРАНИЦА ДОВЕРИЯ: вход
// из RPC валидируем здесь (единственное место — как stdin пользователя), внутренним границам
// движка доверяем (см. CLAUDE.md: «валидируем только вход из ubus RPC и stdin»).
//
// Разделение ради тестируемости (паттерн движка):
//   • ЧИСТОЕ (здесь): реестр методов, разбор/проверка аргументов, вывод дескриптора `list`
//     и ACL — всё детерминировано, юнит-тестируется без шины (engine/ubus/tests).
//   • ИМПУРНОЕ (rpcd-cheburnet): регистрация на шине, запуск движковых CLI (preflight/run/
//     fetch/apply), фон+poll установки. Проверяется в QEMU.
//
// Источник правды — REGISTRY: из него выводятся и дескриптор `list`, и ACL. Так список методов
// и права не разъезжаются между кодом и rpcd-acl.json (тест сверяет файл с выводом отсюда).

// Реестр методов RPC. Один метод = одна запись (порядок стабилен → стабильны list/ACL).
//   args  — спецификации аргументов: { name, type, required?, enum?, minlen?, maxlen? }.
//           type ∈ string|array|object|bool. minlen/maxlen — границы длины строки (граница доверия:
//           короткий пароль/SSID режем синхронно ДО фоновой установки, как install_start в v1).
//   access— read | write (ubus-разделение прав в ACL).
//   auth  — anon  = доступен из LAN до установки (мутации гейтятся install-токеном на импурном слое);
//           admin = только авторизованной сессии (post-install управление).
//   token — мутации pre-install требуют install-токен (проверка значения — импурно, файл; здесь
//           лишь фиксируем, что поле обязательно и строкового типа).
const REGISTRY = [
	{ name: "preflight", access: "read",  auth: "anon",  token: false, args: [] },
	{ name: "status",    access: "read",  auth: "anon",  token: false, args: [] },
	// Пред-инсталл безопасность: детект пересечения LAN/WAN-подсетей (read) и смена LAN-IP.
	// apply_lan_ip — anon+токен (как install): до установки пароля root ещё нет, токен из
	// bootstrap — единственный идентификатор «это владелец, а не сосед по LAN». Деструктивно
	// (рвёт соединения LAN-клиентов) → строгая валидация значения ip на импурном слое.
	{ name: "check_lan_conflict", access: "read", auth: "anon", token: false, args: [] },
	{ name: "apply_lan_ip", access: "write", auth: "anon", token: true, args: [
		{ name: "ip",    type: "string", required: true },
		{ name: "token", type: "string", required: true },
	] },
	{ name: "install_progress", access: "read", auth: "anon", token: false, args: [] },
	{ name: "install",   access: "write", auth: "anon",  token: true, args: [
		{ name: "awg_conf",      type: "string", required: true },
		{ name: "root_password", type: "string", required: true, minlen: 8 }, // секрет → payload 600, не install.json
		// Wi-Fi необязателен: wired-only роутеры (x86/мини-ПК) ставятся без него. UI просит поля
		// только при наличии радио (status.wireless_present); шаг wifi делает no-op без них.
		{ name: "ssid",          type: "string", minlen: 1, maxlen: 32 },
		{ name: "wifi_key",      type: "string", minlen: 8, maxlen: 63 }, // секрет → payload 600
		{ name: "domains",       type: "array" },
		{ name: "routing_opts",  type: "object" },
		{ name: "token",         type: "string", required: true },
	] },
	// install_cancel — anon+токен (как install): отмену контролирует тот же человек, что запускал
	// установку (у него токен из bootstrap); admin-сессии при установке ещё нет.
	{ name: "install_cancel", access: "write", auth: "anon", token: true, args: [
		{ name: "token", type: "string", required: true },
	] },
	{ name: "set_mode",  access: "write", auth: "admin", token: false, args: [
		{ name: "mode", type: "string", required: true, enum: [ "home", "travel" ] },
	] },
	{ name: "update_list", access: "write", auth: "admin", token: false, args: [
		{ name: "url", type: "string" },
	] },
	{ name: "service_restart", access: "write", auth: "admin", token: false, args: [
		// v2-сервисы data-plane (без podkop/sing-box — вырезаны в v2)
		{ name: "service", type: "string", required: true, enum: [ "vpn", "dns", "doh", "adblock" ] },
	] },
	{ name: "set_blocklist_tier", access: "write", auth: "admin", token: false, args: [
		// hagezi-тиры adblock-lean (тот же набор, что в v1 valid_tier)
		{ name: "tier", type: "string", required: true, enum: [
			"light", "normal", "pro", "pro.plus", "ultimate",
			"tif", "tif.medium", "tif.mini", "multi.pro", "fake",
		] },
	] },
	{ name: "set_family_filter", access: "write", auth: "admin", token: false, args: [
		{ name: "enabled", type: "bool", required: true },
	] },
	{ name: "replace_awg_conf", access: "write", auth: "admin", token: false, args: [
		{ name: "awg_conf", type: "string", required: true },
	] },
	{ name: "factory_reset", access: "write", auth: "admin", token: false, args: [
		// защитное слово; значение ("RESET") сверяет импурный слой — здесь лишь обязательность
		{ name: "confirm", type: "string", required: true },
	] },
];

// find_spec(method) → запись реестра или null.
function find_spec(method) {
	for (let i = 0; i < length(REGISTRY); i++)
		if (REGISTRY[i].name == method)
			return REGISTRY[i];
	return null;
}

// method_specs() — копия реестра (для UI/отладки; источник правды — здесь).
export function method_specs() {
	return json(sprintf("%J", REGISTRY)); // глубокая копия через JSON-раунд-трип
}

// Плейсхолдер-значение для типа в дескрипторе `list` (rpcd берёт ТИП образца, не значение).
function type_placeholder(t) {
	if (t == "array")  return [];
	if (t == "object") return {};
	if (t == "bool")   return false;
	return ""; // string
}

// list_descriptor() → объект протокола rpcd `list`: { method: { arg: <образец-типа> } }.
// Скрипт-обработчик печатает его на действие `list`, чтобы rpcd знал сигнатуры методов.
export function list_descriptor() {
	let out = {};
	for (let i = 0; i < length(REGISTRY); i++) {
		let m = REGISTRY[i], sig = {};
		for (let j = 0; j < length(m.args); j++)
			sig[m.args[j].name] = type_placeholder(m.args[j].type);
		out[m.name] = sig;
	}
	return out;
}

// type_ok(val, t) — соответствует ли значение объявленному типу аргумента.
function type_ok(val, t) {
	let vt = type(val);
	if (t == "string") return vt == "string";
	if (t == "array")  return vt == "array";
	if (t == "object") return vt == "object";
	if (t == "bool")   return vt == "bool";
	return false;
}

// validate_request(method, args) → { ok, error?, value? }.
// Граница доверия: метод существует? обязательные поля на месте? типы? enum? Лишние ключи
// отбрасываем (берём только объявленные). Не падаем на мусоре — возвращаем структурную ошибку
// (её импурный слой отдаёт клиенту как {"error":...}). Значение ТОКЕНА здесь не проверяем —
// это сравнение с файлом (импурно); здесь лишь требуем, что поле присутствует и строковое.
export function validate_request(method, args) {
	let spec = find_spec(method);
	if (!spec)
		return { ok: false, error: "unknown method" };

	let a = (type(args) == "object") ? args : {};
	let value = {};
	for (let i = 0; i < length(spec.args); i++) {
		let p = spec.args[i];
		let v = a[p.name];

		// required: отсутствует (null) или пустая строка для строкового поля.
		let missing = (v == null) || (p.type == "string" && type(v) == "string" && length(v) == 0);
		if (p.required && missing)
			return { ok: false, error: sprintf("%s required", p.name) };

		if (v == null)
			continue; // необязательное и не передано — пропускаем

		if (!type_ok(v, p.type))
			return { ok: false, error: sprintf("%s must be %s", p.name, p.type) };

		if (p.enum && index(p.enum, v) < 0)
			return { ok: false, error: sprintf("%s must be one of: %s", p.name, join(", ", p.enum)) };

		// Границы длины строки (только для строк): синхронная отбраковка слишком коротких/длинных
		// значений (пароль, SSID) — пользователь получает ответ сразу, а не на середине установки.
		if (p.type == "string") {
			if (p.minlen != null && length(v) < p.minlen)
				return { ok: false, error: sprintf("%s must be at least %d chars", p.name, p.minlen) };
			if (p.maxlen != null && length(v) > p.maxlen)
				return { ok: false, error: sprintf("%s must be at most %d chars", p.name, p.maxlen) };
		}

		value[p.name] = v;
	}
	return { ok: true, value: value };
}

// requires_token(method) → нужен ли install-токен (импурный слой сверяет значение с файлом).
export function requires_token(method) {
	let s = find_spec(method);
	return s ? (s.token === true) : false;
}

// acl_split() → { unauth:{read,write}, admin:{read,write} } — имена методов по тирам, выведенные
// из реестра. unauth = anon-методы (мутации всё равно гейтятся токеном); admin видит ВСЕ методы
// (анонимные + admin-only). Из этого собирается rpcd-acl.json (build_acl).
export function acl_split() {
	let ur = [], uw = [], ar = [], aw = [];
	for (let i = 0; i < length(REGISTRY); i++) {
		let m = REGISTRY[i];
		if (m.access == "read")  push(ar, m.name); else push(aw, m.name);
		if (m.auth == "anon") {
			if (m.access == "read") push(ur, m.name); else push(uw, m.name);
		}
	}
	return {
		unauth: { read: ur, write: uw },
		admin:  { read: ar, write: aw },
	};
}

// build_acl() → полный объект rpcd-acl.json (готов к печати). Два тира:
//   unauthenticated — первичная установка из LAN (мутации защищены install-токеном);
//   cheburnet-admin — пост-установочное управление (выдаётся авторизованной сессии).
// Источник правды прав — REGISTRY (acl_split); описания статичны.
export function build_acl() {
	let s = acl_split();
	return {
		unauthenticated: {
			description: "cheburnet web wizard — первичная установка (LAN-only). Мутации защищены install-токеном.",
			read:  { ubus: { cheburnet: s.unauth.read } },
			write: { ubus: { cheburnet: s.unauth.write } },
		},
		"cheburnet-admin": {
			description: "cheburnet — пост-установочное управление (выдаётся авторизованной сессии).",
			read:  { ubus: { cheburnet: s.admin.read } },
			write: { ubus: { cheburnet: s.admin.write } },
		},
	};
}

// make_error(msg, extra?) → { error: msg, ...extra }. Единообразный ответ-ошибка для RPC.
export function make_error(msg, extra) {
	let o = { error: msg };
	if (extra) for (let k in extra) o[k] = extra[k];
	return o;
}
