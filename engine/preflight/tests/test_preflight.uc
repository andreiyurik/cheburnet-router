// test_preflight.uc — юнит-тесты гейткипера. Без роутера, секунды.
//   ucode -R engine/preflight/tests/test_preflight.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { cmp_version, cidr_overlap, evaluate, render_report,
         suggest_lan, valid_lan_ip, default_requirements,
         soft_failed_ids } from "../preflight.uc";

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
	let f = good_facts(); f.flash_free_mb = 8; f.ram_total_mb = 64;
	let rep = evaluate(f, null);
	ok(!check_by(rep, "flash").ok);
	ok(!check_by(rep, "ram").ok);
	ok(!rep.passed, "гейт по умолчанию закрыт даже для soft-провалов");
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
	ok(!evaluate(f, null).passed, "при дефолтном пороге 112 — отказ");
	ok(evaluate(f, { min_ram_mb: 64 }).passed, "при пороге 64 — проходит");
});

// --- КАЛИБРОВКА порогов: защита от возврата к «паспортным» цифрам ---
// Пороги сравниваются с ФАКТАМИ роутера, а не с обещаниями коробки: MemTotal всегда меньше
// физической планки (kernel-reserve), свободный overlay на 32-МБ плате ≈ 21 МБ. Прежние
// 128/32 отказывали ровно тому железу, которое README называет поддерживаемым.
test("default_requirements: пороги калиброваны по фактам (RAM 112, флеш 16)", () => {
	let r = default_requirements();
	eq(r.min_ram_mb, 112, "128 отказывал ЛЮБОЙ 128-МБ плате: MemTotal там 118–124");
	eq(r.min_flash_mb, 16, "16 МБ — цифра docs/kb/reference/hardware-requirements.md для Light");
});

test("evaluate: реальный роутер со 128 МБ RAM и 32-МБ флешем проходит", () => {
	// Живой случай (mips, MemTotal 120 МБ, свободно 21 МБ) — на прежних порогах отказ.
	let f = good_facts();
	f.arch = "mips"; f.ram_total_mb = 120; f.flash_free_mb = 21;
	let rep = evaluate(f, null);
	ok(rep.passed, "поддерживаемое железо не должно отсекаться гейткипером");
});

// --- severity: что можно пропустить «на свой страх и риск», а что нельзя ---
test("evaluate: флеш/RAM — soft, остальные проверки — hard", () => {
	let rep = evaluate(good_facts(), null);
	eq(check_by(rep, "flash").severity, "soft");
	eq(check_by(rep, "ram").severity, "soft");
	eq(check_by(rep, "arch").severity, "hard");
	eq(check_by(rep, "openwrt").severity, "hard");
	eq(check_by(rep, "deps").severity, "hard");
	eq(check_by(rep, "lan_wan").severity, "hard", "LAN-конфликт чинится сменой подсети, не риском");
});

test("evaluate: только soft-провалы → overridable (владелец вправе решить)", () => {
	let f = good_facts(); f.ram_total_mb = 64; f.flash_free_mb = 8;
	let rep = evaluate(f, null);
	ok(!rep.passed, "гейт всё равно закрыт по умолчанию");
	eq(rep.hard_failed, 0);
	eq(rep.soft_failed, 2);
	ok(rep.overridable, "пропуск возможен");
	deep_eq(soft_failed_ids(rep), [ "flash", "ram" ]);
});

test("evaluate: hard-провал рядом с soft → overridable=false", () => {
	let f = good_facts(); f.arch = "ppc"; f.ram_total_mb = 64;
	let rep = evaluate(f, null);
	eq(rep.hard_failed, 1);
	eq(rep.soft_failed, 1);
	ok(!rep.overridable, "без нужной arch пакетов нет — «риск» обещал бы невозможное");
});

test("evaluate: всё пройдено → overridable=false (нечего пропускать)", () => {
	let rep = evaluate(good_facts(), null);
	ok(rep.passed);
	eq(rep.hard_failed, 0);
	eq(rep.soft_failed, 0);
	ok(!rep.overridable);
	deep_eq(soft_failed_ids(rep), []);
});

test("evaluate: только hard-провал → soft_failed=0, overridable=false", () => {
	let f = good_facts(); f.openwrt_version = "24.10.0";
	let rep = evaluate(f, null);
	eq(rep.soft_failed, 0);
	eq(rep.hard_failed, 1);
	ok(!rep.overridable);
});

// --- render_report ---
test("render_report: отказ помечает провал и итог", () => {
	let f = good_facts(); f.arch = "ppc";
	let lines = render_report(evaluate(f, null));
	let joined = join("\n", lines);
	ok(index(joined, "✗ arch") >= 0, "провал arch виден");
	ok(index(joined, "ОТКАЗ") >= 0, "итог — отказ");
});

test("render_report: soft-провал без allow_soft — обычный отказ", () => {
	let f = good_facts(); f.ram_total_mb = 64;
	let joined = join("\n", render_report(evaluate(f, null), false));
	ok(index(joined, "✗ ram") >= 0, "по умолчанию soft-провал — тот же ✗");
	ok(index(joined, "ОТКАЗ") >= 0);
});

// Лог установки — единственный след решения «поставить как есть»: он обязан честно сказать,
// ЧТО пропущено (иначе разбор жалобы начинается с гадания, на каком железе это стоит).
test("render_report: allow_soft помечает пропуск и меняет итог", () => {
	let f = good_facts(); f.ram_total_mb = 64;
	let joined = join("\n", render_report(evaluate(f, null), true));
	ok(index(joined, "! ram") >= 0, "soft-провал помечен «!», а не «✗»");
	ok(index(joined, "пропущено по решению владельца") >= 0, "видно, что это решение, а не норма");
	ok(index(joined, "ПРОПУЩЕН") >= 0, "итог отличим от OK и от ОТКАЗА");
	ok(index(joined, "стабильность не гарантируется") >= 0);
});

test("render_report: allow_soft НЕ смягчает hard-провал", () => {
	let f = good_facts(); f.arch = "ppc";
	let joined = join("\n", render_report(evaluate(f, null), true));
	ok(index(joined, "✗ arch") >= 0);
	ok(index(joined, "ОТКАЗ") >= 0, "hard-провал остаётся отказом даже в режиме риска");
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

exit(summary());
