// test_preflight.uc — юнит-тесты гейткипера. Без роутера, секунды.
//   ucode -R engine/preflight/tests/test_preflight.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { cmp_version, cidr_overlap, evaluate, render_report,
         suggest_lan, valid_lan_ip, evaluate_tiers, full_requirements } from "../preflight.uc";

// Хорошие факты — каждый тест портит одно поле, чтобы проверить ровно его проверку.
function good_facts() {
	return {
		arch: "aarch64",
		openwrt_version: "25.12.0",
		flash_free_mb: 100,
		ram_total_mb: 256,
		deps_installable: {
			"kmod-amneziawg": true, "https-dns-proxy": true,
			"dnsmasq": true,
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

// --- LAN-конфликт: подбор замены и валидация нового IP (граница apply_lan_ip) ---

test("suggest_lan: первый кандидат вне WAN-подсети, пересекающийся пропущен", () => {
	eq(suggest_lan("10.0.0.0/24"), "192.168.2.1", "WAN не из 192.168 → первый кандидат");
	eq(suggest_lan("192.168.2.0/24"), "192.168.3.1", "192.168.2 занят WAN'ом → следующий");
	// широкий WAN /16 накрывает ВСЕ кандидаты 192.168.X
	eq(suggest_lan("192.168.0.0/16"), null, "некуда — честный null");
	eq(suggest_lan("мусор"), "192.168.2.1", "непарсимый WAN → overlap=false → первый кандидат");
});

test("valid_lan_ip: только 192.168.X.Y, октеты в диапазоне, host 1..254", () => {
	ok(valid_lan_ip("192.168.2.1"), "кандидат проходит");
	ok(valid_lan_ip("192.168.255.254"), "граница диапазона");
	ok(!valid_lan_ip("192.168.2.0"), "host .0 — адрес сети");
	ok(!valid_lan_ip("192.168.2.255"), "host .255 — broadcast");
	ok(!valid_lan_ip("192.168.999.1"), "октет >255 (v1 такое пускал)");
	ok(!valid_lan_ip("10.0.0.1"), "не 192.168 — отказ");
	ok(!valid_lan_ip("0.0.0.0"), "нулевой адрес");
	ok(!valid_lan_ip(""), "пусто");
	ok(!valid_lan_ip(null), "null");
});

// --- evaluate_tiers: гейтинг Full-тира (VLESS+Reality) ---

// Мощное железо, потянет Full: AES-arch, RAM/флеш с запасом, sing-box ставится.
function full_facts() {
	let f = good_facts();
	f.flash_free_mb = 200;
	f.ram_total_mb = 512;
	f.deps_installable["sing-box"] = true;
	return f;
}

function full_check(rep, id) {
	for (let i = 0; i < length(rep.full_checks); i++)
		if (rep.full_checks[i].id == id) return rep.full_checks[i];
	return null;
}

test("evaluate_tiers: мощное железо → доступны и light, и full", () => {
	let rep = evaluate_tiers(full_facts(), null);
	ok(rep.light, "light доступен");
	ok(rep.full, "full доступен");
	eq(rep.full_failed, 0);
});

test("evaluate_tiers: слабый MIPS → light ок, full НЕ доступен (fail-safe на AWG)", () => {
	let f = full_facts();
	f.arch = "mipsel"; f.ram_total_mb = 128; f.flash_free_mb = 64;
	let rep = evaluate_tiers(f, null);
	ok(rep.light, "light всё ещё проходит на слабом железе");
	ok(!rep.full, "full отсечён");
	ok(!full_check(rep, "full_arch").ok, "arch без AES");
	ok(!full_check(rep, "full_ram").ok, "RAM мало для Full");
});

test("evaluate_tiers: RAM 128 при годной arch → full недоступен", () => {
	let f = full_facts(); f.ram_total_mb = 128;
	let rep = evaluate_tiers(f, null);
	ok(rep.light);
	ok(!rep.full);
	ok(!full_check(rep, "full_ram").ok);
});

test("evaluate_tiers: sing-box не ставится → full недоступен, перечислен", () => {
	let f = full_facts(); f.deps_installable["sing-box"] = false;
	let rep = evaluate_tiers(f, null);
	ok(!rep.full);
	let c = full_check(rep, "full_dep");
	ok(!c.ok);
	ok(index(c.detail, "sing-box") >= 0);
});

test("evaluate_tiers: провал базового light → full тоже false", () => {
	let f = full_facts(); f.openwrt_version = "24.10.0";  // light провалится по версии
	let rep = evaluate_tiers(f, null);
	ok(!rep.light);
	ok(!rep.full, "Full использует тот же базовый стек — без light невозможен");
});

test("evaluate_tiers: кастомные пороги Full через req.full", () => {
	let f = full_facts(); f.ram_total_mb = 200;  // ниже дефолтных 256
	ok(!evaluate_tiers(f, null).full, "при дефолте 256 — отказ Full");
	ok(evaluate_tiers(f, { full: { min_ram_mb: 128 } }).full, "при пороге 128 — Full проходит");
});

test("full_requirements: дефолты Full-тира", () => {
	let r = full_requirements();
	eq(r.min_ram_mb, 256);
	eq(r.min_flash_mb, 128);
	eq(r.dep, "sing-box");
	ok(index(r.arch, "aarch64") >= 0);
	ok(index(r.arch, "mipsel") < 0, "mips исключён из Full");
});

exit(summary());
