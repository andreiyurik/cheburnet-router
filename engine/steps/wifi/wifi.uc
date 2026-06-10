// wifi.uc — Wi-Fi-шаг: разбор желаемого состояния радио и идемпотентный UCI-план.
//
// Пользователь задаёт имя сети (SSID) и пароль в веб-мастере. Шаг приводит секции wifi-iface
// к желаемому состоянию (ssid/шифрование/ключ) и поднимает их (disabled='0'). Имена секций НЕ
// хардкодим (radio0/default_radioN различаются по board.json) — apply.uc перечисляет реально
// присутствующие и передаёт сюда. Нет радио / нет ключа → пустой план (no-op): fail-safe для
// wired-only роутеров (x86/мини-ПК) и для случая «поле не заполнено».
//
// ЧИСТОЕ ЯДРО: validate_wifi (граница доверия — вход пользователя) + build_wifi_plan (→ uci ops).
// Выбор шифрования (sae-mixed vs psk2+ccmp) зависит от УСТАНОВЛЕННОГО wpad → решается в apply.uc
// (импурно) и приходит сюда опцией. Применение uci — apply.uc, проверяется в QEMU.

const SSID_MIN = 1, SSID_MAX = 32;  // IEEE 802.11 SSID: 1..32 байта
const KEY_MIN = 8,  KEY_MAX = 63;   // WPA-PSK passphrase: 8..63 символа

// q(s) — значение в одинарных кавычках для `uci batch`: ' → '\'' (как в shell). SSID и пароль —
// свободный ввод пользователя; без экранирования кавычка внутри значения разорвала бы строку batch.
function q(s) {
	return "'" + replace(s ?? "", "'", "'\\''") + "'";
}

// validate_wifi(ssid, key) → { ok, errors }. Граница доверия: длины в пределах стандарта.
export function validate_wifi(ssid, key) {
	let errors = [];
	if (type(ssid) != "string" || length(ssid) < SSID_MIN || length(ssid) > SSID_MAX)
		push(errors, sprintf("SSID: %d..%d символов", SSID_MIN, SSID_MAX));
	if (type(key) != "string" || length(key) < KEY_MIN || length(key) > KEY_MAX)
		push(errors, sprintf("пароль Wi-Fi: %d..%d символов", KEY_MIN, KEY_MAX));
	return { ok: length(errors) == 0, errors: errors };
}

// build_wifi_plan(ifaces, opts) → { ok, errors, teardown, setup, applied }.
//   ifaces — имена секций wifi-iface (их перечисляет apply.uc); пусто → no-op (нет радио).
//   opts   — { ssid, key, encryption?, pmf? }. encryption по умолчанию sae-mixed (WPA2/WPA3-mixed).
// teardown — tolerant-удаления (apply гонит с -q): снимаем ieee80211w, когда PMF не нужен.
// setup    — idempotent set'ы через uci batch. Разделение как в vpn-шаге (delete-before-set).
//
// PMF (ieee80211w) осмыслен только при SAE; на чистом WPA2 он рвёт совместимость со старыми
// клиентами (телефоны/IoT) — поэтому в не-SAE режиме мы его УДАЛЯЕМ, а не оставляем (урок v1 T4:
// vanilla-секции default_radioN могут нести ieee80211w из коробки).
export function build_wifi_plan(ifaces, opts) {
	let o = opts ?? {};
	let enc = o.encryption ?? "sae-mixed";
	let sae = (substr(enc, 0, 3) == "sae");
	let pmf = sae ? (o.pmf ?? "1") : null;

	let v = validate_wifi(o.ssid, o.key);
	if (!v.ok)
		return { ok: false, errors: v.errors, teardown: [], setup: [], applied: false };

	if (!ifaces || length(ifaces) == 0)
		return { ok: true, errors: [], teardown: [], setup: [], applied: false }; // нет радио → no-op

	let teardown = [], setup = [];
	for (let i = 0; i < length(ifaces); i++) {
		let s = ifaces[i];
		push(setup, sprintf("set wireless.%s.ssid=%s", s, q(o.ssid)));
		push(setup, sprintf("set wireless.%s.encryption='%s'", s, enc));
		push(setup, sprintf("set wireless.%s.key=%s", s, q(o.key)));
		if (pmf)
			push(setup, sprintf("set wireless.%s.ieee80211w='%s'", s, pmf));
		else
			push(teardown, sprintf("delete wireless.%s.ieee80211w", s));
		push(setup, sprintf("set wireless.%s.disabled='0'", s));
	}
	return { ok: true, errors: [], teardown: teardown, setup: setup, applied: true };
}
