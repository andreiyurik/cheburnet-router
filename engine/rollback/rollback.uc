// rollback.uc — точечный откат: ЧИСТОЕ ядро политики «что откатывается транзакцией».
//
// Кирпич 3 надёжности ([[reliability]]): snapshot UCI → применить шаг → health-check →
// ok=commit / fail=restore. Но честно: транзакцию строим ТОЛЬКО для uci-конфигов (откат
// чистый). Грязный откат (загруженный kmod, изменённое состояние сети/линка, запущенный
// сервис) НЕ маскируем под транзакцию — для него safe-fail + понятная ошибка. Притворяться,
// что откатили то, что не откатывается, хуже, чем честно сказать.
//
// Здесь — чистая логика (классификация, реестр, решение commit/rollback). Реальные snapshot/
// restore (чтение/запись /etc/config) — в snapshot.uc (импурно, QEMU).

// UCI-конфиги, которые трогают наши шаги и которые откатываются ЧИСТО.
const CLEAN_CONFIGS = [ "network", "dhcp", "firewall", "https-dns-proxy", "wireless", "sing-box" ];

// protected_configs() → копия списка защищаемых конфигов (копия, чтобы не мутировали внутренний).
export function protected_configs() {
	let out = [];
	for (let i = 0; i < length(CLEAN_CONFIGS); i++) push(out, CLEAN_CONFIGS[i]);
	return out;
}

// is_clean_config(name) → true, если это наш uci-конфиг с чистым откатом.
export function is_clean_config(name) {
	return index(CLEAN_CONFIGS, name) >= 0;
}

// classify(target) → { class, reason }. clean = uci-конфиг (транзакция); всё прочее = dirty
// (неизвестное считаем грязным — безопаснее): kmod, линк, рантайм-сервис не откатываются чисто.
export function classify(target) {
	if (is_clean_config(target))
		return { class: "clean", reason: "uci-конфиг — откат через snapshot/restore чистый" };
	return {
		class: "dirty",
		reason: "не uci-конфиг (kmod/линк/сервис/состояние ядра) — safe-fail, не транзакция",
	};
}

// plan_snapshot(configs) → { ok, errors, configs }. configs пуст/нет → берём protected_configs().
// Отказывает, если среди целей есть грязная: транзакцию строим только для чистых конфигов.
export function plan_snapshot(configs) {
	let list = (configs && length(configs) > 0) ? configs : protected_configs();
	let errors = [], clean = [];
	for (let i = 0; i < length(list); i++) {
		let c = list[i];
		if (is_clean_config(c))
			push(clean, c);
		else
			push(errors, sprintf("%s: %s", c, classify(c).reason));
	}
	return { ok: length(errors) == 0, errors: errors, configs: clean };
}

// decide(health) → "commit" | "rollback". Чистое решение по результату health-check.
// Любой не-ok (или отсутствие результата) → rollback: fail-safe в сторону отката.
export function decide(health) {
	return (health && health.ok === true) ? "commit" : "rollback";
}
