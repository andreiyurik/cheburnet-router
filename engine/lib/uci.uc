// uci.uc — маленькие чистые хелперы для идемпотентной работы с UCI-списками.
//
// НЕ generic desired-state движок (его сознательно не строим — см. reliability.md). Здесь
// только узкая, понятная целиком операция: посчитать минимальный diff между текущим и желаемым
// набором значений списка. На ней стоит «кирпич идемпотентности»: повторный запуск шага,
// когда всё уже как надо, даёт пустой diff → no-op (а не дубликаты).

// reconcile_list(current, desired) → { add, remove }: что добавить и что убрать, чтобы current
// стал равен desired. Минимальный diff (общие элементы не трогаем) → идемпотентность.
// Порядок сохраняем; дубликаты во входе схлопываются (членство по множеству).
export function reconcile_list(current, desired) {
	let cset = {}, dset = {};
	for (let i = 0; i < length(current); i++) cset[current[i]] = true;
	for (let i = 0; i < length(desired); i++) dset[desired[i]] = true;

	let add = [], remove = [], seen = {};
	for (let i = 0; i < length(desired); i++) {
		let v = desired[i];
		if (!cset[v] && !seen[v]) { push(add, v); seen[v] = true; }
	}
	seen = {};
	for (let i = 0; i < length(current); i++) {
		let v = current[i];
		if (!dset[v] && !seen[v]) { push(remove, v); seen[v] = true; }
	}
	return { add: add, remove: remove };
}

// ends_with(s, suffix) — true, если строка s оканчивается на suffix.
export function ends_with(s, suffix) {
	let n = length(s), m = length(suffix);
	return n >= m && substr(s, n - m) == suffix;
}

// starts_with(s, prefix) — true, если строка s начинается с prefix.
export function starts_with(s, prefix) {
	return length(s) >= length(prefix) && substr(s, 0, length(prefix)) == prefix;
}
