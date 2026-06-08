// test_adblock.uc — юнит-тесты adblock-шага. Без роутера.
//   ucode -R engine/steps/adblock/tests/test_adblock.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { build_adblock_plan } from "../adblock.uc";
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

test("config: сохраняет чужие переменные, меняет только нашу", () => {
	let cur = "outbound_dns=\"127.0.0.1\"\nraw_block_lists=\"hagezi:light\"\n";
	let p = build_adblock_plan({ config: cur, addnmount: [] }, null);
	eq(get_var(p.config, "raw_block_lists"), "hagezi:pro");
	eq(get_var(p.config, "outbound_dns"), "127.0.0.1", "чужая переменная на месте");
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
test("кастомный blocklists прокидывается", () => {
	let p = build_adblock_plan({ config: "", addnmount: [] }, { blocklists: "hagezi:light" });
	eq(get_var(p.config, "raw_block_lists"), "hagezi:light");
});

test("доп. config_vars применяются поверх", () => {
	let p = build_adblock_plan({ config: "", addnmount: [] },
		{ config_vars: { max_blocklist_file_size_KB: "30000" } });
	eq(get_var(p.config, "raw_block_lists"), "hagezi:pro");
	eq(get_var(p.config, "max_blocklist_file_size_KB"), "30000");
});

exit(summary());
