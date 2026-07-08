// test_parse.uc — юнит-тесты парсеров системного вывода. На захваченных сэмплах, без роутера.
//   ucode -R engine/preflight/tests/test_parse.uc

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { parse_meminfo, parse_df, parse_arch, parse_board,
         parse_iface_cidr, parse_wan_route } from "../parse.uc";

// --- /proc/meminfo ---
test("parse_meminfo: MemTotal kB → МБ (вниз)", () => {
	let mi = "MemTotal:       246789 kB\nMemFree:        100000 kB\n";
	eq(parse_meminfo(mi), 241); // 246789/1024 = 241.0…
});
test("parse_meminfo: мусор → null", () => {
	eq(parse_meminfo("nothing useful"), null);
	eq(parse_meminfo(""), null);
});

// --- df ---
test("parse_df: обычная строка (имя ФС в строке) → Available", () => {
	let d = "Filesystem      1K-blocks    Used Available Use% Mounted on\n" +
	        "/dev/sdd        1055760   58800   996721   1% /\n";
	eq(parse_df(d), int(996721 / 1024));
});
test("parse_df: busybox-перенос длинного имени ФС на отдельную строку", () => {
	// Когда имя ФС длинное, busybox df переносит цифры на следующую строку — в строке данных
	// нет поля Filesystem, поля сдвинуты. Парсер по 3-му целому всё равно берёт Available.
	let d = "Filesystem           1K-blocks      Used Available Use% Mounted on\n" +
	        "/dev/mtdblock6\n" +
	        "                         20480     10240     10240  50% /overlay\n";
	eq(parse_df(d), 10); // 10240 kB → 10 МБ
});
test("parse_df: мало полей → null", () => {
	eq(parse_df("Filesystem 1K-blocks\n/dev/x 100\n"), null);
});

// --- uname ---
test("parse_arch: trim", () => {
	eq(parse_arch(" aarch64 \n"), "aarch64");
	eq(parse_arch("  "), null);
});

// --- ubus system board ---
test("parse_board: release.version", () => {
	let j = '{"kernel":"6.6","release":{"distribution":"OpenWrt","version":"25.12.0"}}';
	eq(parse_board(j), "25.12.0");
	let s = '{"release":{"version":"SNAPSHOT"}}';
	eq(parse_board(s), "SNAPSHOT");
});
test("parse_board: нет release/битый JSON → null", () => {
	eq(parse_board('{"kernel":"6.6"}'), null);
	eq(parse_board("not json"), null);
});

// --- ubus network.interface status ---
test("parse_iface_cidr: address + mask → addr/mask", () => {
	let j = '{"up":true,"ipv4-address":[{"address":"192.168.1.1","mask":24}]}';
	eq(parse_iface_cidr(j), "192.168.1.1/24");
});
test("parse_iface_cidr: нет адресов / битый → null", () => {
	eq(parse_iface_cidr('{"up":false,"ipv4-address":[]}'), null);
	eq(parse_iface_cidr('{"up":true}'), null);
	eq(parse_iface_cidr("nope"), null);
});

// --- ubus network.interface.wan status → WAN для routing/firewall ---
test("parse_wan_route: ethernet-WAN — l3_device + nexthop (живой сэмпл GL-MT3000)", () => {
	let j = '{"up":true,"l3_device":"eth0","device":"eth0",' +
		'"route":[{"target":"0.0.0.0","mask":0,"nexthop":"192.168.31.1","source":"192.168.31.111/32"}]}';
	let r = parse_wan_route(j);
	eq(r.wan_if, "eth0");
	eq(r.wan_gw, "192.168.31.1");
});
test("parse_wan_route: p2p без nexthop → wan_gw null (dev-only маршрут корректен)", () => {
	let j = '{"up":true,"l3_device":"pppoe-wan","route":[{"target":"0.0.0.0","mask":0}]}';
	let r = parse_wan_route(j);
	eq(r.wan_if, "pppoe-wan");
	eq(r.wan_gw, null);
});
test("parse_wan_route: не-default маршруты игнорируются, нет устройства/битый → null", () => {
	let j = '{"up":true,"l3_device":"eth0","route":[{"target":"10.0.0.0","mask":8,"nexthop":"192.168.31.1"}]}';
	eq(parse_wan_route(j).wan_gw, null);
	eq(parse_wan_route('{"up":false}'), null);
	eq(parse_wan_route("nope"), null);
});

exit(summary());
