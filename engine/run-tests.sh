#!/bin/sh
# engine/run-tests.sh — прогон всех юнит-тестов движка v2 (ucode), без роутера.
#
#   sh engine/run-tests.sh
#
# Находит engine/*/tests/test_*.uc и запускает каждый через ucode. Возвращает 1,
# если хоть один файл упал. ucode нет в окружении → честный skip с инструкцией
# (юнит-логика движка — чистая, но интерпретатор нужен; см. engine/routing/tests/README.md).

set -eu

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO"

if ! command -v ucode >/dev/null 2>&1; then
	echo "✗ ucode не найден в окружении."
	echo "  Юнит-тесты движка — чистая логика на ucode, но нужен интерпретатор."
	echo "  Установка локально и план CI: engine/routing/tests/README.md."
	exit 1
fi

fails=0
total=0
# find, а не glob: тест-файлы лежат на разной глубине (engine/<m>/tests, engine/steps/<c>/tests).
# Пути тестов без пробелов (наш репозиторий) → намеренное word-splitting результата find.
# shellcheck disable=SC2046
for t in $(find engine -type f -path '*/tests/test_*.uc' | sort); do
	[ -f "$t" ] || continue
	total=$((total + 1))
	printf '\n\033[1m▶ %s\033[0m\n' "$t"
	# ucode -R: весь файл — код (не шаблон). Тест сам печатает PASS/FAIL и exit'ит кодом.
	if ! ucode -R "$t"; then
		fails=$((fails + 1))
	fi
done

echo
if [ "$total" -eq 0 ]; then
	echo "⚠ тест-файлы engine/*/tests/test_*.uc не найдены"
	exit 1
fi
if [ "$fails" -eq 0 ]; then
	printf '\033[32m✓ все тест-файлы движка прошли (%d)\033[0m\n' "$total"
	exit 0
fi
printf '\033[31m✗ упало тест-файлов: %d из %d\033[0m\n' "$fails" "$total"
exit 1
