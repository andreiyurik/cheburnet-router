// test_uci.uc — юнит-тесты чистых UCI-хелперов.
//   ucode -R engine/lib/tests/test_uci.uc

import { test, eq, ok, deep_eq, summary } from "../assert.uc";
import { reconcile_list, ends_with, starts_with } from "../uci.uc";

test("reconcile_list: пустой текущий → всё в add", () => {
	let r = reconcile_list([], ["a", "b"]);
	deep_eq(r.add, ["a", "b"]);
	deep_eq(r.remove, []);
});
test("reconcile_list: равные наборы → no-op (идемпотентность)", () => {
	let r = reconcile_list(["a", "b"], ["a", "b"]);
	deep_eq(r.add, []);
	deep_eq(r.remove, []);
});
test("reconcile_list: минимальный diff — общие не трогаем", () => {
	let r = reconcile_list(["a", "b", "c"], ["b", "c", "d"]);
	deep_eq(r.add, ["d"]);
	deep_eq(r.remove, ["a"]);
});
test("reconcile_list: дубликаты во входе схлопываются", () => {
	let r = reconcile_list(["a", "a"], ["b", "b"]);
	deep_eq(r.add, ["b"]);
	deep_eq(r.remove, ["a"]);
});

test("ends_with", () => {
	ok(ends_with("/x/4#inet#fw4#direct", "#direct"));
	ok(!ends_with("/x/6#inet#fw4#direct6", "#direct")); // не путаем direct и direct6
	ok(ends_with("/x/6#inet#fw4#direct6", "#direct6"));
	ok(!ends_with("ab", "abc"));
});

test("starts_with", () => {
	ok(starts_with("127.0.0.1#5053", "127.0.0.1#"));
	ok(!starts_with("8.8.8.8", "127.0.0.1#"));
	ok(!starts_with("ab", "abc"));
});

exit(summary());
