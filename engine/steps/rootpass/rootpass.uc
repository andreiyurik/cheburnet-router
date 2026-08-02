// rootpass.uc — шаг «пароль root»: ЧИСТОЕ ядро валидации (граница доверия — вход со stdin
// apply.uc). Установка — I/O через busybox passwd, см. apply.uc. Тот же minlen продублирован
// на ubus-границе ради синхронного ответа. Откат не нужен: смена пароля — безопасна всегда.

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
