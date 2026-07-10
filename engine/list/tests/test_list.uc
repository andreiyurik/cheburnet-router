// test_list.uc — юнит-тесты импорта/сборки списка доменов. Без роутера.
//   ucode -R engine/list/tests/test_list.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { parse_list, assemble, looks_like_list, DEFAULT_SOURCE } from "../list.uc";

// --- parse_list: форматы ---
test("parse_list: plain — по домену в строке, комментарии/пустые мимо", () => {
	let t = "# header\nexample.com\n\nexample.org   # inline\n; semicolon comment\n";
	deep_eq(parse_list(t), [ "example.com", "example.org" ]);
});
test("parse_list: hosts-формат — берём домен (2-й токен)", () => {
	let t = "0.0.0.0 ads.example.com\n127.0.0.1 track.example.net\n:: v6.example.org\n";
	deep_eq(parse_list(t), [ "ads.example.com", "track.example.net", "v6.example.org" ]);
});
test("parse_list: смешанный plain + hosts", () => {
	let t = "direct.example.com\n0.0.0.0 sink.example.net\n";
	deep_eq(parse_list(t), [ "direct.example.com", "sink.example.net" ]);
});

// --- assemble: слияние, дедуп, валидация ---
test("assemble: слияние user + imported, дедуп регистронезависимо", () => {
	let r = assemble([ "User.Example.com", "mine.example" ],
		"example.com\nUSER.example.COM\n", null);
	// User.Example.com и USER.example.COM → один; mine.example и example.com отдельные
	deep_eq(r.domains, [ "user.example.com", "mine.example", "example.com" ]);
	eq(r.stats.duplicates, 1);
});
test("assemble: мусор → rejected, не падаем (fail-safe)", () => {
	let r = assemble([ "good.example" ], "пример.рф\nunder_score.bad\nok.example\n", null);
	deep_eq(r.domains, [ "good.example", "ok.example" ]);
	eq(r.stats.rejected, 2);
	eq(length(r.rejected), 2);
});
test("assemble: пустые входы → пустой результат", () => {
	let r = assemble(null, null, null);
	deep_eq(r.domains, []);
	eq(r.stats.valid, 0);
});
test("assemble: stats считают user/imported/valid", () => {
	let r = assemble([ "a.example" ], "b.example\nc.example\n", null);
	eq(r.stats.user, 1);
	eq(r.stats.imported, 2);
	eq(r.stats.valid, 3);
});

// --- дефолтный источник: контракт ubus update_list «без url есть дефолт» ---
// Разъезд этого контракта уже ловили: обработчик обещал дефолт, а fetch.uc требовал URL —
// кнопка «Обновить список» в UI падала всегда. Существование и форма дефолта — под тестом.
test("DEFAULT_SOURCE: https-URL, семантика direct (outside, не inside)", () => {
	ok(substr(DEFAULT_SOURCE, 0, 8) == "https://", "только https");
	ok(index(DEFAULT_SOURCE, "outside") >= 0 && index(DEFAULT_SOURCE, "inside-") < 0,
		"outside = напрямую; inside — противоположная семантика (см. WHY в list.uc)");
});

// --- looks_like_list: защита от мусора при обновлении ---
test("looks_like_list: настоящий список проходит, мусор/404 — нет", () => {
	ok(looks_like_list("a.example\nb.example\nc.example\n", 2));
	ok(!looks_like_list("<html>404 Not Found</html>", 1));
	ok(!looks_like_list("", 1));
	ok(!looks_like_list("a.example\n", 2), "ниже порога — нет");
});

exit(summary());
