// rootpass.uc — шаг «пароль root»: ЧИСТОЕ ядро валидации.
//
// Пользователь задаёт пароль администратора роутера в веб-мастере. Установка пароля — это
// I/O (busybox passwd, см. apply.uc); здесь — лишь проверка значения. Пароль приходит со
// stdin apply.uc, поэтому ВАЛИДИРУЕМ (граница доверия): слишком короткий → ok=false, пароль
// не меняем. Дубль той же проверки стоит на ubus-границе (minlen 8) ради синхронного ответа.
//
// Откат не нужен: смена пароля root — всегда безопасное улучшение, не транзакция (run.uc
// применяет шаг на commit-пути, отдельно от uci-снимка).

const MIN_PASSWORD_LEN = 8; // тот же минимум, что в ubus-реестре (install.root_password.minlen)

// validate_password(pw) → { ok, errors }. Правило одно: непустая строка не короче минимума.
function validate_password(pw) {
	let errors = [];
	if (type(pw) != "string" || length(pw) == 0)
		push(errors, "пароль не задан");
	else if (length(pw) < MIN_PASSWORD_LEN)
		push(errors, sprintf("пароль короче %d символов", MIN_PASSWORD_LEN));
	return { ok: length(errors) == 0, errors: errors };
}

export { validate_password };
