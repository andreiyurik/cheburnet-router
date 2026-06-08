// test_preflight.uc — юнит-тесты гейткипера. Без роутера, секунды.
//   ucode -R engine/preflight/tests/test_preflight.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { cmp_version, cidr_overlap, evaluate, render_report } from "../preflight.uc";

// Хорошие факты — каждый тест портит одно поле, чтобы проверить ровно его проверку.
function good_facts() {
	return {
		arch: "aarch64",
		openwrt_version: "25.12.0",
		flash_free_mb: 100,
		ram_total_mb: 256,
		deps_installable: {
			"kmod-amneziawg": true, "https-dns-proxy": true,
			"dnsmasq": true, "adblock-lean": true,
		},
		lan_cidr: "192.168.1.0/24",
		wan_cidr: "10.0.0.0/24",
	};
}

function check_by(report, id) {
	for (let i = 0; i < length(report.checks); i++)
		if (report.checks[i].id == id) return report.checks[i];
	return null;
}

// --- cmp_version ---
test("cmp_version: числовое сравнение и недостающие сегменты", () => {
	eq(cmp_version("25.12", "25.12.0"), 0);   // 25.12 == 25.12.0
	eq(cmp_version("25.12.1", "25.12.0"), 1);
	eq(cmp_version("24.10", "25.12"), -1);
	eq(cmp_version("26.1", "25.12"), 1);       // 26 > 25 численно (не лексикографически)
});
test("cmp_version: SNAPSHOT новее любого релиза", () => {
	eq(cmp_version("SNAPSHOT", "25.12"), 1);
	eq(cmp_version("25.12", "SNAPSHOT"), -1);
	eq(cmp_version("SNAPSHOT", "SNAPSHOT"), 0);
});

// --- cidr_overlap ---
test("cidr_overlap: пересечение и его отсутствие", () => {
	ok(!cidr_overlap("192.168.1.0/24", "10.0.0.0/24"), "разные сети не пересекаются");
	ok(cidr_overlap("192.168.1.0/24", "192.168.0.0/16"), "вложенная подсеть пересекается");
	ok(cidr_overlap("192.168.1.0/24", "192.168.1.0/24"), "равные сети пересекаются");
	ok(!cidr_overlap("192.168.1.0/24", "192.168.2.0/24"), "соседние /24 не пересекаются");
});
test("cidr_overlap: непарсимый вход → false (нет ложного конфликта)", () => {
	ok(!cidr_overlap("garbage", "10.0.0.0/24"));
	ok(!cidr_overlap("192.168.1.0/24", "999.0.0.0/8"));
});

// --- evaluate: happy path ---
test("evaluate: годное железо → passed, все проверки ok", () => {
	let rep = evaluate(good_facts(), null);
	ok(rep.passed, "должно пройти");
	eq(rep.failed, 0);
	eq(rep.total, 6); // arch, openwrt, flash, ram, deps, lan_wan
});

// --- evaluate: каждый провал по отдельности ---
test("evaluate: неподдерживаемая arch блокирует", () => {
	let f = good_facts(); f.arch = "ppc";
	let rep = evaluate(f, null);
	ok(!rep.passed);
	ok(!check_by(rep, "arch").ok);
	ok(check_by(rep, "ram").ok, "остальные проверки не задеты");
});
test("evaluate: старый OpenWrt блокирует", () => {
	let f = good_facts(); f.openwrt_version = "24.10.0";
	ok(!evaluate(f, null).passed);
});
test("evaluate: мало флеша/RAM блокирует", () => {
	let f = good_facts(); f.flash_free_mb = 16; f.ram_total_mb = 64;
	let rep = evaluate(f, null);
	ok(!check_by(rep, "flash").ok);
	ok(!check_by(rep, "ram").ok);
});
test("evaluate: неустанавливаемая зависимость блокирует + перечислена в fix", () => {
	let f = good_facts(); f.deps_installable["kmod-amneziawg"] = false;
	let rep = evaluate(f, null);
	let c = check_by(rep, "deps");
	ok(!c.ok);
	ok(index(c.detail, "kmod-amneziawg") >= 0, "недостающий пакет назван");
});
test("evaluate: пересечение LAN/WAN блокирует", () => {
	let f = good_facts(); f.wan_cidr = "192.168.1.0/24";
	ok(!evaluate(f, null).passed);
});
test("evaluate: WAN неизвестен → проверки lan_wan нет (нечего сравнивать)", () => {
	let f = good_facts(); f.wan_cidr = null;
	let rep = evaluate(f, null);
	eq(rep.total, 5, "проверка lan_wan не добавлена");
	ok(rep.passed);
});

// --- кастомные требования прокидываются ---
test("evaluate: кастомные пороги через req", () => {
	let f = good_facts(); f.ram_total_mb = 100;
	ok(!evaluate(f, null).passed, "при дефолтном пороге 128 — отказ");
	ok(evaluate(f, { min_ram_mb: 64 }).passed, "при пороге 64 — проходит");
});

// --- render_report ---
test("render_report: отказ помечает провал и итог", () => {
	let f = good_facts(); f.arch = "ppc";
	let lines = render_report(evaluate(f, null));
	let joined = join("\n", lines);
	ok(index(joined, "✗ arch") >= 0, "провал arch виден");
	ok(index(joined, "ОТКАЗ") >= 0, "итог — отказ");
});

exit(summary());
