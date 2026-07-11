// preflight.uc — гейткипер железа/версии/зависимостей (чистая логика, без роутера).
//
// Перед ЛЮБЫМИ изменениями движок проверяет, потянет ли железо стек, и честно отказывает
// с понятным сообщением (см. docs/v2/architecture/reliability.md, hardware-requirements.md).
//
// Разделение ради тестируемости:
//   • evaluate(facts, req) — ЧИСТАЯ оценка: на вход факты о системе → структурный отчёт.
//     Юнит-тестируется без роутера (engine/preflight/tests).
//   • сбор фактов (чтение /proc, ubus, uci, apk --simulate) — НЕ здесь: это router-side
//     companion (gather), он импурный и проверяется в QEMU. Граница честная, не пропуск.

// Требования по умолчанию. Пороги ориентировочные — уточняются по QEMU-замерам (Фаза 0).
const REQUIREMENTS = {
	arch: [ "arm", "aarch64", "mips", "mipsel", "x86_64" ],
	min_openwrt: "25.12",   // apk-based ветка OpenWrt
	min_flash_mb: 32,       // пакеты + конфиги влезут
	min_ram_mb: 128,        // dnsmasq + awg не упадут под нагрузкой
	deps: [ "kmod-amneziawg", "https-dns-proxy", "dnsmasq" ],
};

// resolve_req(req) — REQUIREMENTS, перекрытые переданными значениями (известные ключи).
function resolve_req(req) {
	let r = {};
	for (let k in REQUIREMENTS)
		r[k] = REQUIREMENTS[k];
	if (req)
		for (let k in req)
			if (exists(REQUIREMENTS, k))
				r[k] = req[k];
	return r;
}

// default_requirements() — копия дефолтных требований (для gather/UI; источник правды списка
// зависимостей и порогов — здесь, чтобы не разъезжалось между модулями).
function default_requirements() {
	return resolve_req(null);
}

// cmp_version(a, b) → -1|0|1. Точечные числовые версии; SNAPSHOT новее любого релиза.
function cmp_version(a, b) {
	if (a == b) return 0;
	if (a == "SNAPSHOT") return 1;
	if (b == "SNAPSHOT") return -1;
	let pa = split(a, "."), pb = split(b, ".");
	let n = (length(pa) > length(pb)) ? length(pa) : length(pb);
	for (let i = 0; i < n; i++) {
		let x = int(pa[i] ?? "0"); // отсутствующий сегмент → 0 (25.12 vs 25.12.0)
		let y = int(pb[i] ?? "0");
		if (x > y) return 1;
		if (x < y) return -1;
	}
	return 0;
}

// ip4_to_int(ip) → целое или null, если не валидный IPv4-литерал.
function ip4_to_int(ip) {
	let p = split(ip, ".");
	if (length(p) != 4) return null;
	let n = 0;
	for (let i = 0; i < 4; i++) {
		if (!match(p[i], /^[0-9]+$/)) return null;
		let o = int(p[i]);
		if (o < 0 || o > 255) return null;
		n = n * 256 + o; // без bitwise: 64-бит ucode-int держит 2^32 точно
	}
	return n;
}

function parse_cidr(c) {
	let parts = split(c, "/");
	if (length(parts) != 2) return null;
	let ip = ip4_to_int(parts[0]);
	if (ip == null || !match(parts[1], /^[0-9]+$/)) return null;
	let pfx = int(parts[1]);
	if (pfx < 0 || pfx > 32) return null;
	return { ip: ip, pfx: pfx };
}

// cidr_overlap(a, b) → true, если две IPv4-подсети пересекаются. Сравниваем сетевые части
// по меньшему префиксу: если совпали — одна вложена в другую (или равны) → пересечение.
// Непарсимый вход → false: не выдаём ложный «конфликт» из-за неизвестного формата.
function cidr_overlap(a, b) {
	let A = parse_cidr(a), B = parse_cidr(b);
	if (!A || !B) return false;
	let p = (A.pfx < B.pfx) ? A.pfx : B.pfx;
	let div = 1;
	for (let i = 0; i < 32 - p; i++) div = div * 2; // 2^(host-битов)
	return int(A.ip / div) == int(B.ip / div);       // int(x/div) = обнуление младших битов
}

// suggest_lan(wan_cidr) → "192.168.X.1" — кандидат нового LAN-IP, чья /24 НЕ пересекается с
// WAN (проверка той же cidr_overlap — никаких префикс-сравнений «на глаз», урок v1). Набор
// кандидатов из v1 (частые домашние, но не дефолтные у провайдерских модемов). null —
// практически недостижимо (WAN-подсеть накрывает максимум один кандидат).
const LAN_CANDIDATES = [ 2, 3, 4, 8, 9, 10, 11 ];

function suggest_lan(wan_cidr) {
	for (let i = 0; i < length(LAN_CANDIDATES); i++) {
		let net = sprintf("192.168.%d.0/24", LAN_CANDIDATES[i]);
		if (!cidr_overlap(net, wan_cidr))
			return sprintf("192.168.%d.1", LAN_CANDIDATES[i]);
	}
	return null;
}

// valid_lan_ip(ip) → bool. Граница доверия apply_lan_ip: принимаем ТОЛЬКО 192.168.X.Y с
// валидными октетами и host-частью 1..254 — подделанный запрос не уронит роутер в
// 0.0.0.0/255.255.255.255 (safety guard из v1, ужесточённый: v1 пускал октеты до 999).
function valid_lan_ip(ip) {
	let m = match(ip ?? "", /^192\.168\.([0-9]{1,3})\.([0-9]{1,3})$/);
	if (!m) return false;
	let x = int(m[1]), y = int(m[2]);
	return x >= 0 && x <= 255 && y >= 1 && y <= 254;
}

// check(id, ok, detail, fix) — один результат проверки. fix показываем только при провале.
function check(id, ok, detail, fix) {
	return { id: id, ok: ok, detail: detail, fix: ok ? null : fix };
}

// evaluate(facts, req) — собрать отчёт preflight. passed=false, если хоть одна проверка
// (блокирующая) провалена. Это гейткипер: при passed=false движок НЕ трогает систему.
//
// facts: { arch, openwrt_version, flash_free_mb, ram_total_mb,
//          deps_installable: {pkg: bool}, lan_cidr, wan_cidr }
function evaluate(facts, req) {
	let r = resolve_req(req);
	let checks = [];

	// arch
	push(checks, check("arch", index(r.arch, facts.arch) >= 0,
		sprintf("arch = %s", facts.arch ?? "?"),
		sprintf("нужна одна из поддерживаемых: %s", join(", ", r.arch))));

	// версия OpenWrt
	let ver = facts.openwrt_version ?? "";
	push(checks, check("openwrt", ver != "" && cmp_version(ver, r.min_openwrt) >= 0,
		sprintf("OpenWrt %s", ver != "" ? ver : "?"),
		sprintf("нужна версия ≥ %s (apk-based)", r.min_openwrt)));

	// флеш
	let flash = facts.flash_free_mb ?? -1;
	push(checks, check("flash", flash >= r.min_flash_mb,
		sprintf("свободный флеш ≈ %d МБ", flash),
		sprintf("нужно ≥ %d МБ свободно", r.min_flash_mb)));

	// RAM
	let ram = facts.ram_total_mb ?? -1;
	push(checks, check("ram", ram >= r.min_ram_mb,
		sprintf("RAM ≈ %d МБ", ram),
		sprintf("нужно ≥ %d МБ", r.min_ram_mb)));

	// зависимости устанавливаются — ГЛАВНЫЙ чек: иначе install упрётся на середине
	let di = facts.deps_installable ?? {};
	let missing = [];
	for (let i = 0; i < length(r.deps); i++) {
		let d = r.deps[i];
		if (di[d] !== true)
			push(missing, d);
	}
	push(checks, check("deps", length(missing) == 0,
		length(missing) == 0 ? sprintf("все зависимости ставятся (%d)", length(r.deps))
		                      : sprintf("не ставятся: %s", join(", ", missing)),
		"проверьте feed/arch — нужные пакеты не доступны под эту платформу"));

	// конфликт LAN/WAN — только если обе подсети известны (иначе нечего сравнивать)
	if (facts.lan_cidr && facts.wan_cidr) {
		let clash = cidr_overlap(facts.lan_cidr, facts.wan_cidr);
		push(checks, check("lan_wan", !clash,
			sprintf("LAN %s / WAN %s", facts.lan_cidr, facts.wan_cidr),
			"LAN и WAN пересекаются — смените подсеть LAN, иначе потеряете доступ"));
	}

	let failed = 0;
	for (let i = 0; i < length(checks); i++)
		if (!checks[i].ok) failed++;

	return { passed: failed == 0, failed: failed, total: length(checks), checks: checks };
}

// FULL-тир (VLESS+Reality через sing-box) — отдельные, более жёсткие требования.
// Пороги по ADR 0004 — ОРИЕНТИРОВОЧНЫЕ, подтвердить замером throughput/RAM на реальном
// слабом и сильном роутере (это план, не факт). arch здесь — proxy для AES-ускорения
// (sing-box+Reality криптотяжелы); точная проверка флагов cpuinfo — gather (router-side).
const FULL_REQUIREMENTS = {
	arch: [ "aarch64", "x86_64" ],  // ARMv8/x86 с AES; mips/armv7 исключены
	min_flash_mb: 128,              // sing-box-бинарь крупнее kmod-amneziawg
	min_ram_mb: 256,                // userspace-туннель + crypto не упадёт под нагрузкой
	dep: "sing-box",                // должен ставиться из feed под эту arch
};

function resolve_full_req(req) {
	let r = {};
	for (let k in FULL_REQUIREMENTS)
		r[k] = FULL_REQUIREMENTS[k];
	if (req)
		for (let k in req)
			if (exists(FULL_REQUIREMENTS, k))
				r[k] = req[k];
	return r;
}

// full_requirements() — копия дефолтных требований Full-тира (для gather/UI; источник правды здесь).
function full_requirements() {
	return resolve_full_req(null);
}

// evaluate_tiers(facts, req) → { light, full, full_installed, full_checks, full_failed }.
//   light         — проходит ли базовый гейткипер (тот же evaluate; Full на том же базовом стеке).
//   full          — «железо ПОТЯНЕТ Full» (capable): light И пороги (AES-arch, RAM/флеш, sing-box
//                   УСТАНОВИМ через apk --simulate). Это сигнал «показать кнопку включения».
//   full_installed — sing-box РЕАЛЬНО стоит (opt-in: ставится кнопкой отдельно, не при bootstrap).
//                   Это сигнал «можно предлагать Reality» (мастер/панель). capable ≠ installed.
// ИНФОРМАЦИОННО: Light это НЕ блокирует (fail-safe — слабый роутер остаётся на AmneziaWG).
// req.full — вложенные кастомные пороги Full (тесты); req (верхний) идёт в Light-evaluate.
function evaluate_tiers(facts, req) {
	let light = evaluate(facts, req);
	let fr = resolve_full_req(req ? req.full : null);

	let checks = [];
	push(checks, check("full_arch", index(fr.arch, facts.arch) >= 0,
		sprintf("arch = %s", facts.arch ?? "?"),
		sprintf("Full-тир нужен AES-arch: %s", join(", ", fr.arch))));

	let ram = facts.ram_total_mb ?? -1;
	push(checks, check("full_ram", ram >= fr.min_ram_mb,
		sprintf("RAM ≈ %d МБ", ram),
		sprintf("Full-тиру нужно ≥ %d МБ", fr.min_ram_mb)));

	let flash = facts.flash_free_mb ?? -1;
	push(checks, check("full_flash", flash >= fr.min_flash_mb,
		sprintf("свободный флеш ≈ %d МБ", flash),
		sprintf("Full-тиру нужно ≥ %d МБ", fr.min_flash_mb)));

	let di = facts.deps_installable ?? {};
	push(checks, check("full_dep", di[fr.dep] === true,
		di[fr.dep] === true ? sprintf("%s ставится", fr.dep) : sprintf("%s не ставится", fr.dep),
		sprintf("пакет %s недоступен под эту платформу/feed", fr.dep)));

	let failed = 0;
	for (let i = 0; i < length(checks); i++)
		if (!checks[i].ok) failed++;

	return {
		light: light.passed,
		full: light.passed && failed == 0,
		full_installed: facts.sing_box_installed === true,
		full_checks: checks,
		full_failed: failed,
	};
}

// render_report(report) — человекочитаемые строки для CLI/лога.
function render_report(report) {
	let out = [];
	for (let i = 0; i < length(report.checks); i++) {
		let c = report.checks[i];
		let mark = c.ok ? "✓" : "✗";
		let line = sprintf("%s %-8s %s", mark, c.id, c.detail);
		if (!c.ok && c.fix)
			line += sprintf("  → %s", c.fix);
		push(out, line);
	}
	push(out, report.passed
		? sprintf("preflight OK — железо подходит (%d проверок)", report.total)
		: sprintf("preflight ОТКАЗ — провалено %d из %d", report.failed, report.total));
	return out;
}

export { default_requirements, cmp_version, cidr_overlap, suggest_lan, valid_lan_ip, evaluate, full_requirements, evaluate_tiers, render_report };
