// test_redact.uc — юнит-тесты чистки секретов в диагностике.
//   ucode -R engine/lib/tests/test_redact.uc
//
// Направление проверок: КАЖДЫЙ секрет, который реально бывает в наших логах, обязан исчезнуть, а
// то, без чего диагноз невозможен (адрес сервера, порт, сообщения об ошибках), — остаться.
// Пропущенный секрет здесь = ключи пользователя, отправленные в чужой мессенджер.

import { test, ok, deep_eq, summary } from "../assert.uc";
import { redact, MASK } from "../redact.uc";

// has(text, needle) — читаемее, чем index(...) >= 0, в утверждениях ниже.
function has(t, needle) { return index(t, needle) >= 0; }

test("AmneziaWG .conf: приватный и пресхаред-ключ вырезаны, публичный и адрес остались", () => {
	let conf = "[Interface]\nPrivateKey = QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo=\n" +
		"Address = 10.0.0.2/32\nJc = 4\n[Peer]\n" +
		"PublicKey = Bp7uKqLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuV=\n" +
		"PresharedKey = ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHhGgFfE=\n" +
		"Endpoint = 203.0.113.10:51820\n";
	let r = redact(conf);
	ok(!has(r.text, "QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo"), "приватный ключ вырезан");
	ok(!has(r.text, "ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHhGgFfE"), "пресхаред-ключ вырезан");
	ok(has(r.text, "203.0.113.10:51820"), "адрес сервера остался — без него диагноза нет");
	ok(has(r.text, "Jc = 4"), "параметры обфускации остались (не секрет)");
	ok(index(r.removed, "ключи туннеля") >= 0, "removed называет ключи туннеля");
});

test("голый ключ WireGuard в логе (без имени поля) тоже вырезается", () => {
	let line = "awg0: peer QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo= handshake failed";
	let r = redact(line);
	ok(!has(r.text, "QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo"), "ключ вырезан");
	ok(has(r.text, "handshake failed"), "сообщение об ошибке осталось");
});

test("ссылка Hysteria2: пароль и пароль обфускации вырезаны, хост и порт остались", () => {
	let link = "hysteria2://SuperSecretPass123@203.0.113.10:8443?sni=example.com&insecure=1" +
		"&obfs=salamander&obfs-password=ObfsSecret456#lab";
	let r = redact(link);
	ok(!has(r.text, "SuperSecretPass123"), "пароль вырезан");
	ok(!has(r.text, "ObfsSecret456"), "пароль обфускации вырезан");
	ok(has(r.text, "203.0.113.10:8443"), "адрес и порт остались");
	ok(has(r.text, "obfs=salamander"), "тип обфускации остался — он нужен для диагноза");
});

// Регресс на подвох ucode: \s внутри [...] исключал букву «s», и пароли с ней не находились.
test("пароль с буквой s вырезается (регресс на \\s внутри класса)", () => {
	let r = redact("hysteria2://passsss@h:8443?password=sss");
	ok(!has(r.text, "passsss"), "пароль с s вырезан");
	ok(!has(r.text, "=sss"), "параметр password с s вырезан");
});

test("ссылка VLESS+Reality: UUID, pbk и sid вырезаны, sni и fp остались", () => {
	let link = "vless://b82175ba-6b0f-4c2e-9a11-7d3e5f8c1a22@203.0.113.10:443?security=reality" +
		"&pbk=HzZi7tVy4hRAqLmNoPqRsTuVwXyZaBcDeFgHiJkLmNo&sid=eaab3dad&sni=www.example.com&fp=chrome";
	let r = redact(link);
	ok(!has(r.text, "b82175ba-6b0f-4c2e-9a11-7d3e5f8c1a22"), "UUID вырезан");
	ok(!has(r.text, "HzZi7tVy4hRAqLmNoPqRsTuVwXyZaBcDeFgHiJkLmNo"), "pbk вырезан");
	ok(!has(r.text, "eaab3dad"), "sid вырезан");
	ok(has(r.text, "sni=www.example.com"), "заимствованный SNI остался — по нему и разбирают Reality");
});

test("JSON-конфиг sing-box из вывода check: пароли вырезаны, структура читаема", () => {
	let cfg = '{"type":"hysteria2","server":"203.0.113.10","server_port":8443,' +
		'"password":"SecretPw","obfs":{"type":"salamander","password":"ObfsPw"}}';
	let r = redact(cfg);
	ok(!has(r.text, "SecretPw"), "пароль вырезан");
	ok(!has(r.text, "ObfsPw"), "пароль обфускации вырезан");
	ok(has(r.text, '"server":"203.0.113.10"'), "адрес сервера остался");
	ok(has(r.text, '"type":"hysteria2"'), "тип протокола остался");
});

test("UCI: пароль Wi-Fi вырезан, SSID остался", () => {
	let uci = "wireless.default_radio0.ssid='MyHome'\nwireless.default_radio0.key='wifi-secret-1'\n";
	let r = redact(uci);
	ok(!has(r.text, "wifi-secret-1"), "пароль Wi-Fi вырезан");
	ok(has(r.text, "'MyHome'"), "SSID остался — он не секрет и нужен для диагноза");
	ok(index(r.removed, "пароль Wi-Fi") >= 0, "removed называет пароль Wi-Fi");
});

test("чистый текст не меняется и removed пуст", () => {
	let t = "install: шаг dns применён\nawg0: handshake 12 seconds ago\n";
	let r = redact(t);
	ok(r.text == t, "текст без секретов не тронут");
	deep_eq(r.removed, []);
});

test("removed без повторов: два правила с одной меткой дают одну запись", () => {
	let r = redact("PrivateKey = QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo=\n" +
		"peer ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJjIiHhGgFfE= down");
	let n = 0;
	for (let i = 0; i < length(r.removed); i++) if (r.removed[i] == "ключи туннеля") n++;
	ok(n == 1, "метка «ключи туннеля» встречается один раз");
});

test("не строка на входе → пустой результат, без исключения", () => {
	let r = redact(null);
	ok(r.text == "", "text пустой");
	deep_eq(r.removed, []);
});

test("маска действительно подставляется (UI обещает её человеку)", () => {
	let r = redact("PrivateKey = QFxsc0Gk3nJ2VZUwvVYqNlH9y7bTf1cKmXpRsAeDgHo=");
	ok(has(r.text, MASK), "в тексте видна метка удаления");
});

summary();
