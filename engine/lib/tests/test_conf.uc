// test_conf.uc — юнит-тесты редактора shell-конфигов.
//   ucode -R engine/lib/tests/test_conf.uc

import { test, eq, ok, summary } from "../assert.uc";
import { set_var, get_var } from "../conf.uc";

test("set_var: заменяет существующее присваивание, сохраняя остальное", () => {
	let txt = "# header\nfoo=1\nraw_block_lists=\"old\"\nbar=2\n";
	let out = set_var(txt, "raw_block_lists", "hagezi:pro");
	ok(index(out, "raw_block_lists=\"hagezi:pro\"") >= 0);
	ok(index(out, "old") < 0, "старое значение ушло");
	ok(index(out, "foo=1") >= 0 && index(out, "bar=2") >= 0, "соседние строки на месте");
});

test("set_var: добавляет в конец, если ключа не было", () => {
	let out = set_var("a=1\n", "b", "x");
	ok(index(out, "b=\"x\"") >= 0);
	ok(index(out, "a=1") >= 0);
});

test("set_var: идемпотентность — повтор не меняет текст", () => {
	let once = set_var("x=1\n", "raw_block_lists", "hagezi:pro");
	let twice = set_var(once, "raw_block_lists", "hagezi:pro");
	eq(once, twice);
});

test("set_var: дубликаты ключа схлопываются в один", () => {
	let txt = "k=\"a\"\nk=\"b\"\nother=1\n";
	let out = set_var(txt, "k", "c");
	// ровно одно присваивание k
	let n = 0, lines = split(out, "\n");
	for (let i = 0; i < length(lines); i++)
		if (substr(lines[i], 0, 2) == "k=") n++;
	eq(n, 1);
	ok(index(out, "k=\"c\"") >= 0);
});

test("set_var: закомментированный #key= не трогаем (добавляем свою строку)", () => {
	let out = set_var("#raw_block_lists=\"default\"\n", "raw_block_lists", "hagezi:pro");
	ok(index(out, "#raw_block_lists=\"default\"") >= 0, "комментарий сохранён");
	ok(index(out, "raw_block_lists=\"hagezi:pro\"") >= 0, "наша строка добавлена");
});

test("get_var: достаёт значение в кавычках и без", () => {
	eq(get_var("raw_block_lists=\"hagezi:pro\"\n", "raw_block_lists"), "hagezi:pro");
	eq(get_var("port=5353\n", "port"), "5353");
	eq(get_var("a=1\n", "missing"), null);
});

exit(summary());
