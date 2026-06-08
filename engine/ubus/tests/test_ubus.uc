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
	deep_eq(d.install, { awg_conf: "", domains: [], routing_opts: {}, token: "" }, "сигнатура install");
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
	let r = validate_request("install", { awg_conf: "x", domains: "notarray", token: "t" });
	eq(r.ok, false, "ok=false");
	eq(r.error, "domains must be array", "тип domains");
	let r2 = validate_request("install", { awg_conf: "x", routing_opts: [1], token: "t" });
	eq(r2.error, "routing_opts must be object", "тип routing_opts");
});

test("validate: install со всеми полями → ok, value содержит только объявленные", () => {
	let r = validate_request("install", {
		awg_conf: "[Interface]\n", domains: [ "example.com" ],
		routing_opts: { mode: "home" }, token: "abc", junk: "drop-me",
	});
	eq(r.ok, true, "ok=true");
	deep_eq(r.value, {
		awg_conf: "[Interface]\n", domains: [ "example.com" ],
		routing_opts: { mode: "home" }, token: "abc",
	}, "value без junk");
});

test("validate: необязательные поля можно опускать", () => {
	let r = validate_request("install", { awg_conf: "c", token: "t" });
	eq(r.ok, true, "ok без domains/routing_opts");
	deep_eq(r.value, { awg_conf: "c", token: "t" }, "только переданное");
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

// --- токен ---

test("requires_token: только pre-install мутация install", () => {
	eq(requires_token("install"), true, "install требует токен");
	eq(requires_token("set_mode"), false, "set_mode — admin, без токена");
	eq(requires_token("status"), false, "status — read, без токена");
	eq(requires_token("nope"), false, "неизвестный — false");
});

// --- ACL выводится из реестра ---

test("acl_split: тиры выведены из реестра", () => {
	let s = acl_split();
	deep_eq(s.unauth.read, [ "preflight", "status", "install_progress" ], "anon read");
	deep_eq(s.unauth.write, [ "install" ], "anon write (токен-гейт)");
	// admin видит все методы
	ok(index(s.admin.write, "set_mode") >= 0, "set_mode в admin write");
	ok(index(s.admin.write, "update_list") >= 0, "update_list в admin write");
	ok(index(s.admin.write, "install") >= 0, "install тоже доступен admin");
	deep_eq(s.admin.read, [ "preflight", "status", "install_progress" ], "admin read = все read");
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
