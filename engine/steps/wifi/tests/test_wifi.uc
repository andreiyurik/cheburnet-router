// test_wifi.uc — юнит-тесты чистого ядра Wi-Fi-шага. Без роутера.
//   ucode -R engine/steps/wifi/tests/test_wifi.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { validate_wifi, build_wifi_plan } from "../wifi.uc";

// --- валидация (граница доверия) ---

test("validate_wifi: SSID 1..32 и ключ 8..63", () => {
	ok(validate_wifi("Home", "password123").ok, "норма");
	ok(!validate_wifi("", "password123").ok, "пустой SSID");
	ok(!validate_wifi("x", "short7!").ok, "ключ короче 8");
	ok(validate_wifi("x", "12345678").ok, "ключ ровно 8");
	let long_ssid = "X"; for (let i = 0; i < 5; i++) long_ssid += long_ssid; // 32 → потом >32
	eq(length(long_ssid), 32, "32 символа");
	ok(validate_wifi(long_ssid, "12345678").ok, "SSID ровно 32 ок");
	ok(!validate_wifi(long_ssid + "Y", "12345678").ok, "SSID 33 — нет");
	ok(!validate_wifi(7, "12345678").ok, "не строка SSID");
});

// --- план: no-op без радио ---

test("нет секций wifi-iface → no-op (applied=false, пустые ops)", () => {
	let p = build_wifi_plan([], { ssid: "Home", key: "password123" });
	ok(p.ok, "ok=true (не ошибка — просто нет радио)");
	eq(p.applied, false, "applied=false");
	deep_eq(p.setup, []);
	deep_eq(p.teardown, []);
});

test("невалидные креды → ok=false, ничего не применяем", () => {
	let p = build_wifi_plan([ "default_radio0" ], { ssid: "", key: "x" });
	eq(p.ok, false);
	eq(p.applied, false);
	ok(length(p.errors) >= 1);
});

// --- план: SAE по умолчанию (WPA2/WPA3-mixed) ---

test("по умолчанию sae-mixed + PMF; teardown пуст", () => {
	let p = build_wifi_plan([ "default_radio0" ], { ssid: "Home", key: "password123" });
	ok(p.applied);
	deep_eq(p.setup, [
		"set wireless.default_radio0.ssid='Home'",
		"set wireless.default_radio0.encryption='sae-mixed'",
		"set wireless.default_radio0.key='password123'",
		"set wireless.default_radio0.ieee80211w='1'",
		"set wireless.default_radio0.disabled='0'",
	]);
	deep_eq(p.teardown, [], "при SAE PMF ставим, не удаляем");
});

// --- план: WPA2 → PMF удаляется (урок T4 v1) ---

test("psk2+ccmp: ieee80211w УДАЛЯЕТСЯ (teardown), не ставится", () => {
	let p = build_wifi_plan([ "default_radio0" ], { ssid: "Home", key: "password123", encryption: "psk2+ccmp" });
	deep_eq(p.teardown, [ "delete wireless.default_radio0.ieee80211w" ]);
	deep_eq(p.setup, [
		"set wireless.default_radio0.ssid='Home'",
		"set wireless.default_radio0.encryption='psk2+ccmp'",
		"set wireless.default_radio0.key='password123'",
		"set wireless.default_radio0.disabled='0'",
	]);
});

// --- несколько радио ---

test("несколько секций → операции на каждую", () => {
	let p = build_wifi_plan([ "radio0", "radio1" ], { ssid: "Home", key: "password123" });
	// 5 set-операций на секцию
	eq(length(p.setup), 10);
	ok(index(p.setup[5], "radio1") >= 0, "вторая секция присутствует");
});

// --- экранирование кавычек (свободный ввод) ---

test("одинарная кавычка в SSID/ключе экранируется для uci batch", () => {
	let p = build_wifi_plan([ "r0" ], { ssid: "It's", key: "pa'ss1234" });
	eq(p.setup[0], "set wireless.r0.ssid='It'\\''s'", "SSID: ' → '\\''");
	eq(p.setup[2], "set wireless.r0.key='pa'\\''ss1234'", "ключ: ' → '\\''");
});

exit(summary());
