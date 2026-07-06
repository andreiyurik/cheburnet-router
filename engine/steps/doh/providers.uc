// providers.uc — каталог DNS-провайдеров (DoH): ВЫБОР ФИЛЬТРАЦИИ = ВЫБОР РЕЗОЛВЕРА.
//
// Блокировку рекламы и взрослого контента в v2 делает не локальный список, а выбранный
// фильтрующий DoH-резолвер (легче для слабого железа, ноль обслуживания). Каждый провайдер —
// дружелюбное описание (для веб-мастера) + DoH-URL с bootstrap-IP'ами.
//
// category — «класс фильтрации» (plain / ads / family). Важно для надёжности: fallback держим
// В ПРЕДЕЛАХ КЛАССА — семейный фильтр не должен молча расфильтроваться, если откатиться на
// не-фильтрующий резолвер. Поэтому у каждого провайдера два anycast-эндпоинта (bootstrap),
// redundancy внутри провайдера, а не кросс-классовый fallback.
//
// Один резолвер на провайдера, ФИКСИРОВАННОЕ имя секции (SECTION) → смена провайдера = чистая
// идемпотентная замена (delete-before-set по тому же имени в doh.uc).

const SECTION = "cheburnet_doh"; // имя https-dns-proxy секции (одно на любой провайдер)
const PORT = 5053;               // локальный порт listener'а (один upstream для dnsmasq)
const DEFAULT_ID = "adguard";    // дефолт: реклама+трекеры, полезно и ничего не ломает

// Каталог. Порядок стабилен (UI рисует в нём же). Эндпоинты — публичные, бесплатные, без аккаунта.
const PROVIDERS = [
	{ id: "adguard",              name: "AdGuard",               category: "ads",
	  description: "Блокирует рекламу и трекеры",
	  url: "https://dns.adguard-dns.com/dns-query",     bootstrap: "94.140.14.14,94.140.15.15" },
	{ id: "adguard-family",       name: "AdGuard Семейный",      category: "family",
	  description: "Реклама, трекеры, сайты 18+ и безопасный поиск",
	  url: "https://family.adguard-dns.com/dns-query",  bootstrap: "94.140.14.15,94.140.15.16" },
	{ id: "cleanbrowsing-family", name: "CleanBrowsing Семейный", category: "family",
	  description: "Сайты 18+ и безопасный поиск",
	  url: "https://doh.cleanbrowsing.org/doh/family-filter/", bootstrap: "185.228.168.168,185.228.169.168" },
	{ id: "quad9",                name: "Quad9",                 category: "plain",
	  description: "Без логов, блокирует вредоносные сайты",
	  url: "https://dns.quad9.net/dns-query",           bootstrap: "9.9.9.9,149.112.112.112" },
	{ id: "cloudflare",           name: "Cloudflare",            category: "plain",
	  description: "Быстрый, без фильтрации",
	  url: "https://cloudflare-dns.com/dns-query",      bootstrap: "1.1.1.1,1.0.0.1" },
];

function find(id) {
	for (let i = 0; i < length(PROVIDERS); i++)
		if (PROVIDERS[i].id == id) return PROVIDERS[i];
	return null;
}

// default_provider() → id провайдера по умолчанию.
function default_provider() {
	return DEFAULT_ID;
}

// provider_ids() → список валидных id (для enum в ubus-реестре — граница доверия).
function provider_ids() {
	let out = [];
	for (let i = 0; i < length(PROVIDERS); i++) push(out, PROVIDERS[i].id);
	return out;
}

// resolvers_for(id) → список резолверов для doh.build_doh_plan (opts.resolvers).
// Неизвестный/пустой id → дефолт (fail-safe: лучше рабочий DNS, чем пустой). Имя секции
// фиксировано → смена провайдера переписывает ту же секцию.
function resolvers_for(id) {
	let p = find(id) ?? find(DEFAULT_ID);
	return [ { name: SECTION, url: p.url, port: PORT, bootstrap: p.bootstrap } ];
}

// describe(id) → запись каталога { id, name, description, category } или null. Для status.
function describe(id) {
	let p = find(id);
	return p ? { id: p.id, name: p.name, description: p.description, category: p.category } : null;
}

// catalog_for_ui() → [{ id, name, description, category }] для дропдауна веб-мастера (status отдаёт).
function catalog_for_ui() {
	let out = [];
	for (let i = 0; i < length(PROVIDERS); i++)
		push(out, describe(PROVIDERS[i].id));
	return out;
}

export { default_provider, provider_ids, resolvers_for, describe, catalog_for_ui };
