// conf.uc — чистое идемпотентное редактирование shell-стиль конфигов (key="value").
//
// Нужно для файлов вроде /etc/adblock-lean/config (не UCI, а shell-переменные). Узкая
// операция, понятная целиком: задать одно присваивание, сохранив остальной файл. НЕ парсер
// shell и не generic-движок.

// set_var(text, key, value) → новый текст: строка key="value" заменяет ПЕРВОЕ присваивание
// key (дубликаты того же ключа убираем) или добавляется в конец, если ключа не было.
// Закомментированные строки (#key=) не трогаем — при sourcing'е победит наша строка.
// Идемпотентно: если присваивание уже точно такое — текст не меняется.
function set_var(text, key, value) {
	let lines = split(text ?? "", "\n");
	let want = sprintf("%s=\"%s\"", key, value);
	let pfx = key + "=";
	let out = [], replaced = false;
	for (let i = 0; i < length(lines); i++) {
		if (substr(lines[i], 0, length(pfx)) == pfx) {
			if (!replaced) { push(out, want); replaced = true; }
			// последующие присваивания того же ключа отбрасываем (last-wins → один канонический)
		} else {
			push(out, lines[i]);
		}
	}
	if (!replaced)
		push(out, want);
	return join("\n", out);
}

// get_var(text, key) → значение (без кавычек) первого присваивания key, или null.
function get_var(text, key) {
	let lines = split(text ?? "", "\n");
	let pfx = key + "=";
	for (let i = 0; i < length(lines); i++) {
		if (substr(lines[i], 0, length(pfx)) == pfx) {
			let v = substr(lines[i], length(pfx));
			// снять окружающие одинарные/двойные кавычки, если есть
			let m = match(v, /^"(.*)"$/) || match(v, /^'(.*)'$/);
			return m ? m[1] : v;
		}
	}
	return null;
}

export { set_var, get_var };
