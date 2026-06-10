// test_family.uc — юнит-тесты чистого ядра семейного режима. Без роутера.
//   ucode -R engine/steps/family/tests/test_family.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_family_plan, family_status, ss_sect, expected_sections,
         FAMILY_FILTER_URL } from "../family.uc";

const SENT = "cheburnet_ss_www_google_com";

test("ss_sect: точки и дефисы → подчёркивания, префикс cheburnet_ss_", () => {
	eq(ss_sect("www.google.com"), SENT);
	eq(ss_sect("a-b.c"), "cheburnet_ss_a_b_c");
});

test("включение с чистой системы: URL добавлен, все cname-секции создаются", () => {
	let p = build_family_plan({ raw_block_lists: "hagezi:pro", sections: [] }, true);
	ok(p.changed);
	eq(p.conf_value, "hagezi:pro " + FAMILY_FILTER_URL, "NSFW-URL дописан к тиру");
	// 10 пар × 3 операции
	eq(length(p.uci_ops), 30);
	ok(index(p.uci_ops, "set dhcp." + SENT + "=cname") >= 0);
	ok(index(p.uci_ops, "set dhcp." + SENT + ".target='forcesafesearch.google.com'") >= 0);
});

test("включение идемпотентно: всё уже на месте → пустой план", () => {
	let p = build_family_plan({
		raw_block_lists: "hagezi:pro " + FAMILY_FILTER_URL,
		sections: expected_sections(),
	}, true);
	ok(!p.changed, "повтор включения — no-op");
	deep_eq(p.uci_ops, []);
});

test("включение дотягивает рассинхрон (URL есть, секций нет)", () => {
	let p = build_family_plan({
		raw_block_lists: "hagezi:pro " + FAMILY_FILTER_URL,
		sections: [],
	}, true);
	ok(p.changed);
	ok(!p.conf_changed, "конфиг не трогаем");
	eq(length(p.uci_ops), 30, "секции досоздаются");
});

test("выключение: URL убран (тир остался), секции удаляются", () => {
	let p = build_family_plan({
		raw_block_lists: "hagezi:pro " + FAMILY_FILTER_URL,
		sections: expected_sections(),
	}, false);
	eq(p.conf_value, "hagezi:pro", "тир не задет");
	eq(length(p.uci_ops), length(expected_sections()), "delete на каждую нашу секцию");
	ok(index(p.uci_ops, "delete dhcp." + SENT) >= 0);
});

test("выключение идемпотентно + чужие секции не трогаем", () => {
	let p = build_family_plan({
		raw_block_lists: "hagezi:pro",
		sections: [ "manual_cname_entry" ], // чужая (не cheburnet_ss_*)
	}, false);
	ok(!p.changed, "выключать нечего");
	deep_eq(p.uci_ops, [], "чужая секция не удалена");
});

test("family_status: true только когда обе подсистемы включены", () => {
	let all = expected_sections();
	ok(family_status({ raw_block_lists: "x " + FAMILY_FILTER_URL, sections: all }), "обе → true");
	ok(!family_status({ raw_block_lists: "x", sections: all }), "нет URL → false");
	ok(!family_status({ raw_block_lists: FAMILY_FILTER_URL, sections: [] }), "нет секций → false");
	ok(!family_status({}), "пустой current → false");
});

exit(summary());
