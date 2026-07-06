// test_providers.uc — юнит-тесты каталога DNS-провайдеров. Без роутера.
//   ucode -R engine/steps/doh/tests/test_providers.uc

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { default_provider, provider_ids, resolvers_for, describe, catalog_for_ui } from "../providers.uc";

test("default_provider — валидный id из каталога", () => {
	let ids = provider_ids();
	ok(index(ids, default_provider()) >= 0, "дефолт есть в каталоге");
	eq(default_provider(), "adguard", "дефолт = AdGuard (реклама)");
});

test("provider_ids — ожидаемый набор", () => {
	deep_eq(provider_ids(),
		[ "adguard", "adguard-family", "cleanbrowsing-family", "quad9", "cloudflare" ]);
});

test("resolvers_for — одна секция cheburnet_doh:5053 с url+bootstrap провайдера", () => {
	let r = resolvers_for("adguard-family");
	eq(length(r), 1, "один резолвер на провайдера");
	eq(r[0].name, "cheburnet_doh", "фиксированное имя секции → чистая замена");
	eq(r[0].port, 5053);
	eq(r[0].url, "https://family.adguard-dns.com/dns-query");
	ok(index(r[0].bootstrap, ",") >= 0, "два anycast-эндпоинта (redundancy в классе)");
});

test("resolvers_for — неизвестный id → дефолт (fail-safe, рабочий DNS)", () => {
	let r = resolvers_for("nonsense");
	eq(r[0].url, resolvers_for("adguard")[0].url, "откат на дефолт");
	let rnull = resolvers_for(null);
	eq(rnull[0].url, resolvers_for("adguard")[0].url, "null → дефолт");
});

test("describe — дружелюбное описание; категории заданы", () => {
	let d = describe("cloudflare");
	eq(d.category, "plain");
	ok(length(d.description) > 0, "есть описание для UI");
	eq(describe("nope"), null, "неизвестный → null");
});

test("catalog_for_ui — все провайдеры с id/name/description/category", () => {
	let cat = catalog_for_ui();
	eq(length(cat), length(provider_ids()));
	for (let i = 0; i < length(cat); i++) {
		ok(length(cat[i].id) > 0 && length(cat[i].name) > 0, "id+name");
		ok(length(cat[i].description) > 0, "описание");
		ok(index([ "plain", "ads", "family" ], cat[i].category) >= 0, "валидная категория");
	}
});

exit(summary());
