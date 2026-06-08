// list.uc — импорт community-списка доменов ПРЯМОГО доступа (direct). Чистое ядро.
//
// Принцип «не владеть данными»: список доменов импортируем из maintained-community, а не ведём
// руками (см. architecture-v2). Движок периодически тянет его и регенерит конфиг dnsmasq/nftset.
//
// СЕМАНТИКА (якорь v1, важно): импортируемый список = домены, которые идут НАПРЯМУЮ (в обход
// туннеля), как и пользовательский direct-список. Перепутать «direct» и «через туннель» —
// источник багов. Fail-safe страхует: промах → трафик уйдёт в туннель (безопасно), не утечёт.
//
// Здесь — сборка чистого списка доменов из сырого текста (+ пользовательский список). Валидацию
// переиспользуем из routing. Загрузка по сети — fetch.uc (импурно, QEMU). Результат → build_plan.

import { normalize_domain, is_valid_domain } from "../routing/routing.uc";

// Адреса-«заглушки» в hosts-формате блок-/направляющих списков: 0.0.0.0 domain / 127.0.0.1 domain.
const HOST_SINKS = [ "0.0.0.0", "127.0.0.1", "::", "::1" ];

// parse_list(text) → массив доменов-кандидатов (сырых строк). Понимает два формата строки:
//   • plain:  «example.com»  (по одному домену в строке)
//   • hosts:  «0.0.0.0 example.com»  → берём домен (2-й токен)
// Inline-комментарии (# или ;) и пустые строки отбрасываются. Формат определяется по строке.
export function parse_list(text) {
	let out = [];
	let lines = split(text ?? "", "\n");
	for (let i = 0; i < length(lines); i++) {
		let l = trim(replace(lines[i], /[#;].*$/, ""));
		if (length(l) == 0)
			continue;
		let toks = split(l, /[ \t]+/);
		let dom = toks[0];
		// hosts-формат: первый токен — адрес-заглушка, домен идёт вторым.
		if (index(HOST_SINKS, toks[0]) >= 0 && length(toks) >= 2)
			dom = toks[1];
		push(out, dom);
	}
	return out;
}

// assemble(user_domains, imported_text, opts) → { domains, rejected, stats }.
// Сливает пользовательский direct-список и импортированный community-список, нормализует и
// валидирует (переиспользуя routing), дедуплицирует (регистронезависимо). Мусор → rejected
// (fail-safe: не падаем). domains готов для routing.build_plan.
export function assemble(user_domains, imported_text, opts) {
	let user = user_domains ?? [];
	let imported = parse_list(imported_text);

	let candidates = [];
	for (let i = 0; i < length(user); i++) push(candidates, user[i]);
	for (let i = 0; i < length(imported); i++) push(candidates, imported[i]);

	let seen = {}, domains = [], rejected = [], dups = 0;
	for (let i = 0; i < length(candidates); i++) {
		let d = normalize_domain(candidates[i]);
		if (length(d) == 0)
			continue;
		if (!is_valid_domain(d)) {
			push(rejected, { raw: candidates[i], reason: "not an ASCII LDH/punycode domain" });
			continue;
		}
		if (seen[d]) { dups++; continue; }
		seen[d] = true;
		push(domains, d);
	}

	return {
		domains: domains,
		rejected: rejected,
		stats: {
			user: length(user),
			imported: length(imported),
			valid: length(domains),
			rejected: length(rejected),
			duplicates: dups,
		},
	};
}

// looks_like_list(text, min_valid) → true, если в тексте есть хотя бы min_valid валидных доменов.
// Защита от замены хорошего списка мусором (404/captive-portal): fetch проверяет это ДО замены кэша.
export function looks_like_list(text, min_valid) {
	let need = (min_valid != null) ? min_valid : 1;
	let cands = parse_list(text);
	let n = 0;
	for (let i = 0; i < length(cands); i++) {
		let d = normalize_domain(cands[i]);
		if (length(d) > 0 && is_valid_domain(d)) {
			n++;
			if (n >= need) return true;
		}
	}
	return false;
}
