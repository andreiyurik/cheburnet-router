// assert.uc — крошечный тест-раннер для юнит-тестов движка на ucode.
//
// Без зависимостей и без роутера. Тест-файл импортирует { test, eq, deep_eq, summary },
// регистрирует случаи через test(name, fn) и в конце вызывает exit(summary()).
// summary() печатает итог и возвращает код выхода (0 = всё PASS) для CI.

let _pass = 0, _fail = 0, _fails = [];

// eq(a, b) — строгое равенство скаляров; кидает при несовпадении (ловит test()).
export function eq(got, want, msg) {
	if (got !== want)
		die(sprintf("%s: got %J, want %J", msg ?? "eq", got, want));
}

// deep_eq(a, b) — рекурсивное сравнение массивов/объектов/скаляров через JSON-канонизацию.
// Достаточно для наших планов/артефактов (порядок ключей в ucode-объектах стабилен).
export function deep_eq(got, want, msg) {
	let g = sprintf("%J", got), w = sprintf("%J", want);
	if (g !== w)
		die(sprintf("%s:\n  got : %s\n  want: %s", msg ?? "deep_eq", g, w));
}

// ok(cond) — истинность условия.
export function ok(cond, msg) {
	if (!cond)
		die(sprintf("%s: expected truthy", msg ?? "ok"));
}

// test(name, fn) — выполнить случай; исключение из fn = провал (а не падение раннера).
export function test(name, fn) {
	try {
		fn();
		_pass++;
		printf("  \033[32m✓\033[0m %s\n", name);
	} catch (e) {
		_fail++;
		push(_fails, name);
		printf("  \033[31m✗\033[0m %s\n     %s\n", name, e.message ?? e);
	}
}

// summary() — печать итога; возвращает код выхода (0 = успех).
export function summary() {
	printf("\n  PASS=%d  FAIL=%d\n", _pass, _fail);
	if (_fail > 0) {
		printf("  \033[31mпровалы: %s\033[0m\n", join(", ", _fails));
		return 1;
	}
	printf("  \033[32mвсе тесты прошли\033[0m\n");
	return 0;
}
