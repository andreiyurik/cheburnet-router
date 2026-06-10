// test_adblock.uc — юнит-тесты adblock-шага. Без роутера.
//   ucode -R engine/steps/adblock/tests/test_adblock.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_adblock_plan, parse_blocklists, addnmount_paths } from "../adblock.uc";
import { get_var } from "../../../lib/conf.uc";

function has(arr, s) {
	for (let i = 0; i < length(arr); i++) if (arr[i] == s) return true;
	return false;
}

// --- конфиг: ставит сбалансированный список ---
test("config: raw_block_lists = hagezi:pro по умолчанию", () => {
	let p = build_adblock_plan({ config: "", addnmount: [] }, null);
	ok(p.ok);
	ok(p.config_changed);
	eq(get_var(p.config, "raw_block_lists"), "hagezi:pro");
});

test("config: сохраняет чужие переменные и текущий тир (переустановка ≠ сброс выбора)", () => {
	let cur = "outbound_dns=\"127.0.0.1\"\nraw_block_lists=\"hagezi:light\"\n";
	let p = build_adblock_plan({ config: cur, addnmount: [] }, null);
	eq(get_var(p.config, "raw_block_lists"), "hagezi:light", "тир админа не сброшен на дефолт");
	eq(get_var(p.config, "outbound_dns"), "127.0.0.1", "чужая переменная на месте");
});

test("config: явный tier переопределяет текущий", () => {
	let cur = "raw_block_lists=\"hagezi:light\"\n";
	let p = build_adblock_plan({ config: cur, addnmount: [] }, { tier: "ultimate" });
	eq(get_var(p.config, "raw_block_lists"), "hagezi:ultimate");
});

test("config: идемпотентность — уже hagezi:pro → не изменён", () => {
	let cur = "raw_block_lists=\"hagezi:pro\"\n";
	let p = build_adblock_plan({ config: cur, addnmount: [
		"/bin/busybox", "/var/run/adblock-lean/abl-blocklist.gz",
	] }, null);
	ok(!p.config_changed, "конфиг без изменений");
	deep_eq(p.addnmount_ops, [], "addnmount тоже на месте → no-op");
});

// --- addnmount: dnsmasq право читать блок-лист ---
test("addnmount: чистая система → add_list busybox + gz-блоклист", () => {
	let p = build_adblock_plan({ config: "", addnmount: [] }, null);
	deep_eq(p.addnmount_ops, [
		"add_list dhcp.@dnsmasq[0].addnmount='/bin/busybox'",
		"add_list dhcp.@dnsmasq[0].addnmount='/var/run/adblock-lean/abl-blocklist.gz'",
	]);
});

test("addnmount: частично есть → добавляем только недостающее", () => {
	let p = build_adblock_plan({ config: "", addnmount: [ "/bin/busybox" ] }, null);
	deep_eq(p.addnmount_ops, [
		"add_list dhcp.@dnsmasq[0].addnmount='/var/run/adblock-lean/abl-blocklist.gz'",
	]);
});

test("addnmount: чужие записи не трогаем (не в remove)", () => {
	let p = build_adblock_plan({ config: "", addnmount: [
		"/usr/sbin/someother", "/bin/busybox", "/var/run/adblock-lean/abl-blocklist.gz",
	] }, null);
	deep_eq(p.addnmount_ops, [], "наши на месте, чужой /usr/sbin/someother не удаляем");
});

// --- кастомизация ---
test("кастомный tier прокидывается", () => {
	let p = build_adblock_plan({ config: "", addnmount: [] }, { tier: "light" });
	eq(get_var(p.config, "raw_block_lists"), "hagezi:light");
	eq(p.tier, "light");
});

test("доп. config_vars применяются поверх", () => {
	let p = build_adblock_plan({ config: "", addnmount: [] },
		{ config_vars: { max_blocklist_file_size_KB: "30000" } });
	eq(get_var(p.config, "raw_block_lists"), "hagezi:pro");
	eq(get_var(p.config, "max_blocklist_file_size_KB"), "30000");
});

// --- смена тира не выключает family-фильтр (фикс бага v1) ---
test("смена тира сохраняет чужие raw-URL токены (NSFW family-фильтра)", () => {
	let nsfw = "https://example.com/nsfw-onlydomains.txt";
	let cur = sprintf("raw_block_lists=\"hagezi:pro %s\"\n", nsfw);
	let p = build_adblock_plan({ config: cur, addnmount: [] }, { tier: "ultimate" });
	eq(get_var(p.config, "raw_block_lists"), "hagezi:ultimate " + nsfw,
		"тир сменился, NSFW-URL на месте");
});

// --- parse_blocklists: разбор для status ---
test("parse_blocklists: tier из hagezi-токена, raw-URL'ы в extras", () => {
	deep_eq(parse_blocklists("raw_block_lists=\"hagezi:pro\"\n"),
		{ tier: "pro", extras: [] });
	deep_eq(parse_blocklists("raw_block_lists=\"hagezi:pro.plus https://e/x.txt\"\n"),
		{ tier: "pro.plus", extras: [ "https://e/x.txt" ] });
	deep_eq(parse_blocklists(""), { tier: null, extras: [] }, "нет конфига → tier=null");
	deep_eq(parse_blocklists("other_var=\"1\"\n"), { tier: null, extras: [] }, "нет переменной");
});

test("addnmount_paths: пути шага (источник для reset), копия — мутация безвредна", () => {
	let a = addnmount_paths();
	deep_eq(a, [ "/bin/busybox", "/var/run/adblock-lean/abl-blocklist.gz" ]);
	push(a, "hacked");
	eq(length(addnmount_paths()), 2, "внутренний список не задет");
});

exit(summary());
