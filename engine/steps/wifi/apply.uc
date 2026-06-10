// apply.uc — применение Wi-Fi-шага на роутере (импурно, router-side).
//
//   echo '{"ssid":"Home","key":"password123"}' | ucode -R apply.uc            # применить
//   echo '{"ssid":"Home","key":"password123"}' | ucode -R apply.uc --dry-run  # только план
//
// Поток: нет SSID/ключа → no-op; нет wifi-device → no-op (wired-only роутер); перечислить секции
// wifi-iface (имена нестандартны → не хардкодим); выбрать шифрование по установленному wpad;
// построить план чистым ядром (wifi.uc); teardown (-q, tolerant) → setup (uci batch) → commit →
// `wifi reload`. Логика плана под юнит-тестами (wifi/tests); импурную часть проверяем в QEMU.

import { stdin, popen } from "fs";
import { sh, uci_batch } from "../../lib/proc.uc";
import { build_wifi_plan } from "./wifi.uc";

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("wifi/apply: ожидаю JSON {ssid, key} со stdin");
let req = json(raw);
let ssid = req.ssid, key = req.key;
let dry = (length(ARGV) > 0 && ARGV[0] == "--dry-run");

// Поле не заполнено (или wired-only роутер): не настраиваем Wi-Fi, но и не валим установку.
if (type(ssid) != "string" || length(ssid) == 0 || type(key) != "string" || length(key) == 0) {
	print("wifi: SSID/ключ не заданы — пропускаю шаг\n");
	exit(0);
}

// Нет радио → no-op. У роутера без wifi-device настраивать нечего (fail-safe, не ошибка).
let radios = trim(sh("uci -q show wireless 2>/dev/null | grep -c '=wifi-device'"));
if (!match(radios, /^[0-9]+$/) || int(radios) == 0) {
	print("wifi: нет wifi-device — у роутера нет радио, пропускаю\n");
	exit(0);
}

// Перечислить секции wifi-iface. busybox awk: тип-строка `wireless.<sect>=wifi-iface`.
function list_ifaces() {
	let out = trim(sh("uci -q show wireless | awk -F'[.=]' '/=wifi-iface$/{print $2}'"));
	return length(out) > 0 ? split(out, /\n+/) : [];
}
let ifaces = list_ifaces();
// Радио есть, но iface не сгенерирован (редкий lkm-случай) — попробовать и перечислить снова (как v1).
if (length(ifaces) == 0) {
	sh("wifi config >/dev/null 2>&1");
	ifaces = list_ifaces();
}

// Выбор шифрования по УСТАНОВЛЕННОМУ wpad: полный wpad-mbedtls → WPA2/WPA3-mixed (SAE) + PMF;
// иначе WPA2 (psk2+ccmp). Пакеты НЕ ставим — это забота preflight/зависимостей; промах = безопасный
// откат на WPA2 (fail-safe), а не отказ Wi-Fi. WPA3 требует `+wpad-mbedtls` в DEPENDS пакета.
let full = trim(sh("apk list --installed 2>/dev/null | grep -c '^wpad-mbedtls-'"));
let enc = (match(full, /^[0-9]+$/) && int(full) > 0) ? "sae-mixed" : "psk2+ccmp";

let plan = build_wifi_plan(ifaces, { ssid: ssid, key: key, encryption: enc });
if (!plan.ok) {
	for (let i = 0; i < length(plan.errors); i++) warn("wifi: " + plan.errors[i] + "\n");
	exit(1);
}
if (!plan.applied) {
	print("wifi: нет секций wifi-iface — нечего настраивать\n");
	exit(0);
}

if (dry) {
	for (let i = 0; i < length(plan.teardown); i++) print("  " + plan.teardown[i] + "\n");
	for (let i = 0; i < length(plan.setup); i++) print("  " + plan.setup[i] + "\n");
	printf("wifi: --dry-run (шифрование %s), не применяю\n", enc);
	exit(0);
}

// teardown по одному с глушением: снять ieee80211w, отсутствие — норма.
for (let i = 0; i < length(plan.teardown); i++) {
	let p = popen(sprintf("uci -q %s", plan.teardown[i]), "r");
	if (p) p.close();
}

// setup атомарно через `uci batch` + commit wireless; сбой batch = шаг упал (не маскируем).
let rc = uci_batch(plan.setup, "wireless");
if (rc != 0)
	die(sprintf("wifi/apply: uci batch завершился кодом %d", rc));

// Применить: wifi reload перечитывает wireless и поднимает интерфейсы.
let r = popen("wifi reload >/dev/null 2>&1", "r");
if (r) r.close();

printf("wifi: применено — SSID настроен на %d секциях (шифрование %s)\n", length(ifaces), enc);
