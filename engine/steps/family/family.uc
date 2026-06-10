// family.uc — «семейный режим»: ЧИСТОЕ ядро. Один тумблер, две подсистемы (порт v1
// lib/family-filter.sh — проверенный дизайн):
//
//   1. NSFW DNS-блок — Hagezi NSFW-лист добавляется raw-URL-токеном к raw_block_lists в
//      конфиге adblock-lean. В hagezi-тиры NSFW не входит → отдельный URL, не шорткат.
//      Смену тира токен переживает: adblock-шаг сохраняет не-hagezi токены ([[adblock]]).
//   2. Force SafeSearch — именованные uci-секции cname в dhcp (cheburnet_ss_*): поисковики
//      и YouTube переадресуются на их же SafeSearch-endpoint'ы. Именно named-секции —
//      `list cname` в @dnsmasq[0] init-скрипт dnsmasq игнорирует (урок v1).
//
// build_family_plan(current, enabled) → diff (conf_value + uci-операции). Идемпотентно:
// повторное включение/выключение → пустой план. Чужие cname-секции не трогаем (удаляем только
// своё подмножество cheburnet_ss_*). Применение — apply.uc (импурно, QEMU).

export const FAMILY_FILTER_URL =
	"https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt";

// Force SafeSearch — стандартный набор (Pi-hole/AGH). YouTube — strict-режим
// (restrict.youtube.com); нужен moderate — заменить на restrictmoderate.youtube.com.
const SAFESEARCH = [
	{ src: "www.google.com",          dst: "forcesafesearch.google.com" },
	{ src: "google.com",              dst: "forcesafesearch.google.com" },
	{ src: "www.youtube.com",         dst: "restrict.youtube.com" },
	{ src: "m.youtube.com",           dst: "restrict.youtube.com" },
	{ src: "youtubei.googleapis.com", dst: "restrict.youtube.com" },
	{ src: "youtube.googleapis.com",  dst: "restrict.youtube.com" },
	{ src: "www.bing.com",            dst: "strict.bing.com" },
	{ src: "bing.com",                dst: "strict.bing.com" },
	{ src: "duckduckgo.com",          dst: "safe.duckduckgo.com" },
	{ src: "www.duckduckgo.com",      dst: "safe.duckduckgo.com" },
];

// Sentinel — по нему судим статус SafeSearch: набор ставится/снимается атомарно, одной
// проверки достаточно.
const SS_SENTINEL = "www.google.com";

// ss_sect(src) → имя uci-секции: только [a-z0-9_], префикс cheburnet_ss_ исключает коллизии.
export function ss_sect(src) {
	return "cheburnet_ss_" + replace(src, /[.-]/g, "_");
}

// sentinel_section() → имя sentinel-секции (для точечной проверки статуса извне, напр. status).
export function sentinel_section() {
	return ss_sect(SS_SENTINEL);
}

// expected_sections() → имена всех наших cname-секций (для перечисления/фильтрации в apply).
export function expected_sections() {
	let out = [];
	for (let i = 0; i < length(SAFESEARCH); i++)
		push(out, ss_sect(SAFESEARCH[i].src));
	return out;
}

function tokens(raw) {
	let s = trim(raw ?? "");
	return length(s) > 0 ? split(s, /[ \t]+/) : [];
}

function has(arr, v) {
	return index(arr, v) >= 0;
}

// family_status(current) → bool. current = { raw_block_lists, sections }. true ⟺ обе
// подсистемы включены; рассинхрон трактуем как «выключено» — включение идемпотентно дотянет.
export function family_status(current) {
	let c = current ?? {};
	let nsfw = has(tokens(c.raw_block_lists), FAMILY_FILTER_URL);
	let ss = has(c.sections ?? [], ss_sect(SS_SENTINEL));
	return nsfw && ss;
}

// build_family_plan(current, enabled) → { conf_value, conf_changed, uci_ops, changed }.
//   current = { raw_block_lists: "<значение>", sections: [имеющиеся cheburnet_ss_* секции] }.
// conf_value — новое значение raw_block_lists (apply пишет через set_var, если conf_changed).
// uci_ops — set/delete по dhcp (apply гонит через uci batch + commit).
export function build_family_plan(current, enabled) {
	let c = current ?? {};
	let toks = tokens(c.raw_block_lists);
	let sects = c.sections ?? [];
	let ours = expected_sections();

	let newtoks = [], uci_ops = [];
	if (enabled) {
		newtoks = toks;
		if (!has(toks, FAMILY_FILTER_URL)) {
			newtoks = [];
			for (let i = 0; i < length(toks); i++) push(newtoks, toks[i]);
			push(newtoks, FAMILY_FILTER_URL);
		}
		for (let i = 0; i < length(SAFESEARCH); i++) {
			let e = SAFESEARCH[i], s = ss_sect(e.src);
			if (has(sects, s)) continue; // уже есть → no-op
			push(uci_ops, sprintf("set dhcp.%s=cname", s));
			push(uci_ops, sprintf("set dhcp.%s.cname='%s'", s, e.src));
			push(uci_ops, sprintf("set dhcp.%s.target='%s'", s, e.dst));
		}
	} else {
		for (let i = 0; i < length(toks); i++)
			if (toks[i] != FAMILY_FILTER_URL) push(newtoks, toks[i]);
		// Удаляем только СВОЁ подмножество: чужие секции (в т.ч. ручные cname) не трогаем.
		for (let i = 0; i < length(sects); i++)
			if (has(ours, sects[i]))
				push(uci_ops, sprintf("delete dhcp.%s", sects[i]));
	}

	let conf_value = join(" ", newtoks);
	let conf_changed = conf_value != join(" ", toks);
	return {
		conf_value: conf_value,
		conf_changed: conf_changed,
		uci_ops: uci_ops,
		changed: conf_changed || length(uci_ops) > 0,
	};
}
