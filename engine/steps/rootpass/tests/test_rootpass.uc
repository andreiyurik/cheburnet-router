// test_rootpass.uc — юнит-тесты чистого ядра шага «пароль root». Без роутера.
//   ucode -R engine/steps/rootpass/tests/test_rootpass.uc

import { test, eq, ok, summary } from "../../../lib/assert.uc";
import { validate_password } from "../rootpass.uc";

test("пустой/не строка → невалиден", () => {
	eq(validate_password("").ok, false, "пустая строка");
	eq(validate_password(null).ok, false, "null");
	eq(validate_password(12345678).ok, false, "число — не пароль");
});

test("короче 8 → невалиден, ошибка упоминает минимум", () => {
	let r = validate_password("short7!"); // 7 символов
	eq(r.ok, false, "7 символов не проходят");
	ok(index(r.errors[0], "8") >= 0, "ошибка называет минимум");
});

test("8+ символов → валиден", () => {
	eq(validate_password("12345678").ok, true, "ровно 8");
	eq(validate_password("correct horse battery").ok, true, "длинная фраза с пробелами");
});

exit(summary());
