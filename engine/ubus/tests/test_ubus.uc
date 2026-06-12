// test_ubus.uc — юнит-тесты чистого ядра RPC-фасада (валидация/роутинг/ACL), без шины.
//
//   ucode -R engine/ubus/tests/test_ubus.uc   (или make test-engine)

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { readfile } from "fs";
import {
	list_descriptor, validate_request, requires_token,
	acl_split, build_acl, make_error, method_specs
} from "../ubus.uc";

// --- список методов / дескриптор ---

test("list_descriptor: все методы реестра присутствуют с сигнатурами", () => {
	let d = list_descriptor();
	ok(exists(d, "preflight"), "preflight в дескрипторе");
	ok(exists(d, "install"), "install в дескрипторе");
	ok(exists(d, "set_mode"), "set_mode в дескрипторе");
	// install объявляет свои аргументы; типы — образцы (string→"", array→[], object→{})
	deep_eq(d.install, { awg_conf: "", root_password: "", ssid: "", wifi_key: "", dns_provider: "", domains: [], routing_opts: {}, token: "" }, "сигнатура install");
	deep_eq(d.set_mode, { mode: "" }, "сигнатура set_mode");
	deep_eq(d.preflight, {}, "preflight без аргументов");
});

// --- валидация: граница доверия ---

test("validate: неизвестный метод → ошибка", () => {
	let r = validate_request("nope", {});
	eq(r.ok, false, "ok=false");
	eq(r.error, "unknown method", "текст ошибки");
});

test("validate: метод без аргументов проходит при любом мусоре в args", () => {
	eq(validate_request("status", null).ok, true, "null args ок");
	eq(validate_request("status", { junk: 1 }).ok, true, "лишний ключ игнор");
	deep_eq(validate_request("status", { junk: 1 }).value, {}, "value пустой — лишнее отброшено");
});

test("validate: отсутствует обязательное поле → ошибка с именем", () => {
	let r = validate_request("install", { token: "t" }); // нет awg_conf
	eq(r.ok, false, "ok=false");
	eq(r.error, "awg_conf required", "сообщение");
});

test("validate: пустая строка в обязательном строковом поле = отсутствует", () => {
	let r = validate_request("install", { awg_conf: "", token: "t" });
	eq(r.ok, false, "пустой awg_conf не проходит");
	eq(r.error, "awg_conf required", "сообщение");
});

test("validate: неверный тип → ошибка must be <type>", () => {
	let r = validate_request("install", { awg_conf: "x", root_password: "longenough", domains: "notarray", token: "t" });
	eq(r.ok, false, "ok=false");
	eq(r.error, "domains must be array", "тип domains");
	let r2 = validate_request("install", { awg_conf: "x", root_password: "longenough", routing_opts: [1], token: "t" });
	eq(r2.error, "routing_opts must be object", "тип routing_opts");
});

test("validate: root_password — обязателен и не короче 8 символов", () => {
	let miss = validate_request("install", { awg_conf: "c", token: "t" });
	eq(miss.error, "root_password required", "без пароля → required");
	let short = validate_request("install", { awg_conf: "c", root_password: "short7!", token: "t" });
	eq(short.ok, false, "7 символов не проходят");
	eq(short.error, "root_password must be at least 8 chars", "сообщение minlen");
	eq(validate_request("install", { awg_conf: "c", root_password: "12345678", token: "t" }).ok, true, "ровно 8 — ок");
});

test("validate: Wi-Fi необязателен, но при наличии — в границах длины", () => {
	eq(validate_request("install", { awg_conf: "c", root_password: "s3cretpass", token: "t" }).ok,
		true, "без ssid/wifi_key — ок (wired-only)");
	let short_key = validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", ssid: "Home", wifi_key: "short7!" });
	eq(short_key.error, "wifi_key must be at least 8 chars", "короткий ключ Wi-Fi");
	let long_ssid = "X"; for (let i = 0; i < 6; i++) long_ssid += long_ssid; // 2^6 = 64 символа
	let big = validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", ssid: long_ssid });
	eq(big.error, "ssid must be at most 32 chars", "слишком длинный SSID");
	eq(validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", ssid: "Home", wifi_key: "password123" }).ok,
		true, "валидный Wi-Fi");
});

test("validate: install со всеми полями → ok, value содержит только объявленные", () => {
	let r = validate_request("install", {
		awg_conf: "[Interface]\n", root_password: "s3cretpass", domains: [ "example.com" ],
		routing_opts: { mode: "home" }, token: "abc", junk: "drop-me",
	});
	eq(r.ok, true, "ok=true");
	deep_eq(r.value, {
		awg_conf: "[Interface]\n", root_password: "s3cretpass", domains: [ "example.com" ],
		routing_opts: { mode: "home" }, token: "abc",
	}, "value без junk");
});

test("validate: необязательные поля можно опускать", () => {
	let r = validate_request("install", { awg_conf: "c", root_password: "s3cretpass", token: "t" });
	eq(r.ok, true, "ok без domains/routing_opts");
	deep_eq(r.value, { awg_conf: "c", root_password: "s3cretpass", token: "t" }, "только переданное");
});

test("validate: enum mode — только home|travel", () => {
	eq(validate_request("set_mode", { mode: "home" }).ok, true, "home ок");
	eq(validate_request("set_mode", { mode: "travel" }).ok, true, "travel ок");
	let r = validate_request("set_mode", { mode: "vpn" });
	eq(r.ok, false, "чужое значение отвергнуто");
	eq(r.error, "mode must be one of: home, travel", "сообщение enum");
});

test("validate: update_list — url необязателен", () => {
	eq(validate_request("update_list", {}).ok, true, "без url ок (дефолтный источник)");
	eq(validate_request("update_list", { url: "https://e/x" }).ok, true, "с url ок");
	eq(validate_request("update_list", { url: 5 }).ok, false, "url не строка → ошибка");
});

// --- валидация: admin-методы Фазы B ---

test("validate: service_restart — только v2-сервисы (без podkop/adblock)", () => {
	eq(validate_request("service_restart", { service: "vpn" }).ok, true, "vpn ок");
	eq(validate_request("service_restart", { service: "doh" }).ok, true, "doh ок");
	eq(validate_request("service_restart", { service: "podkop" }).ok, false, "podkop вырезан в v2");
	eq(validate_request("service_restart", { service: "adblock" }).ok, false, "adblock убран (фильтрация через DNS)");
	eq(validate_request("service_restart", {}).ok, false, "service обязателен");
});

test("validate: set_dns_provider — enum из каталога; dns_provider в install опционален", () => {
	eq(validate_request("set_dns_provider", { provider: "adguard" }).ok, true, "каталожный id ок");
	eq(validate_request("set_dns_provider", { provider: "adguard-family" }).ok, true, "семейный ок");
	eq(validate_request("set_dns_provider", { provider: "nonsense" }).ok, false, "чужой id отвергнут");
	eq(validate_request("set_dns_provider", {}).ok, false, "provider обязателен");
	// в install dns_provider опционален (дефолт подставит handler), но при наличии — из enum
	eq(validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", dns_provider: "quad9" }).ok,
		true, "валидный провайдер в install");
	eq(validate_request("install",
		{ awg_conf: "c", root_password: "s3cretpass", token: "t", dns_provider: "bad" }).ok,
		false, "невалидный провайдер в install");
});

test("validate: replace_awg_conf и factory_reset — обязательные строки", () => {
	eq(validate_request("replace_awg_conf", { awg_conf: "[Interface]\n" }).ok, true);
	eq(validate_request("replace_awg_conf", {}).ok, false, "awg_conf обязателен");
	eq(validate_request("factory_reset", { confirm: "RESET" }).ok, true);
	eq(validate_request("factory_reset", {}).ok, false, "confirm обязателен");
});

// --- токен ---

test("requires_token: pre-install мутации install, install_cancel, apply_lan_ip", () => {
	eq(requires_token("install"), true, "install требует токен");
	eq(requires_token("install_cancel"), true, "отмена — тем же токеном");
	eq(requires_token("apply_lan_ip"), true, "смена LAN-IP — деструктив, токен");
	eq(requires_token("set_mode"), false, "set_mode — admin, без токена");
	eq(requires_token("status"), false, "status — read, без токена");
	eq(requires_token("nope"), false, "неизвестный — false");
});

test("validate: apply_lan_ip — ip и token обязательны", () => {
	eq(validate_request("apply_lan_ip", { ip: "192.168.2.1", token: "t" }).ok, true);
	eq(validate_request("apply_lan_ip", { token: "t" }).error, "ip required", "без ip");
	eq(validate_request("check_lan_conflict", {}).ok, true, "детект — без аргументов");
});

// --- ACL выводится из реестра ---

test("acl_split: тиры выведены из реестра", () => {
	let s = acl_split();
	deep_eq(s.unauth.read, [ "preflight", "status", "check_lan_conflict", "install_progress" ], "anon read");
	deep_eq(s.unauth.write, [ "apply_lan_ip", "install", "install_cancel" ], "anon write (токен-гейт)");
	// admin видит все методы
	ok(index(s.admin.write, "set_mode") >= 0, "set_mode в admin write");
	ok(index(s.admin.write, "update_list") >= 0, "update_list в admin write");
	ok(index(s.admin.write, "install") >= 0, "install тоже доступен admin");
	ok(index(s.admin.write, "service_restart") >= 0, "service_restart в admin write");
	ok(index(s.admin.write, "factory_reset") >= 0, "factory_reset в admin write");
	deep_eq(s.admin.read, [ "preflight", "status", "check_lan_conflict", "install_progress" ], "admin read = все read");
});

test("rpcd-acl.json синхронен с реестром (build_acl)", () => {
	// Коммитнутый файл должен совпадать с генерацией из реестра — иначе права разъехались.
	// Меняешь REGISTRY → перегенери: ucode -R engine/ubus/acl.uc > engine/ubus/rpcd-acl.json
	let path = sourcepath(0, true) + "/../rpcd-acl.json";
	let raw = readfile(path);
	ok(raw != null, "rpcd-acl.json читается");
	deep_eq(json(raw), build_acl(), "файл == build_acl()");
});

// --- ответы ---

test("make_error: базовая и с extra", () => {
	deep_eq(make_error("oops"), { error: "oops" }, "только error");
	deep_eq(make_error("busy", { pid: 7 }), { error: "busy", pid: 7 }, "error + extra");
});

test("method_specs: глубокая копия (мутация не трогает реестр)", () => {
	let a = method_specs();
	a[0].name = "MUT";
	eq(method_specs()[0].name, "preflight", "реестр не изменился");
});

exit(summary());
