#!/usr/bin/env bash
# tests/lint.sh — статические проверки cheburnet-router.
#
# Один и тот же скрипт вызывается из CI (.github/workflows/lint.yml) и локально
# через `make lint`. Никакой логики не должно быть в Makefile/CI помимо вызова
# этого файла — DRY.
#
# Что проверяется:
#   1. shellcheck --shell=sh   на POSIX-скриптах (роутер = busybox-ash)
#   2. shellcheck --shell=bash на хост-тулинге (QEMU-тесты, сам lint.sh)
#   3. sh -n / bash -n         синтаксис (safety net поверх shellcheck)
#   4. JSON-валидность         engine/ubus/rpcd-acl.json
#
# Логику движка (ucode) shellcheck не проверяет — см. `make test-engine`.
#
# Любой провал → exit 1.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

# === Списки файлов ===
# POSIX sh — всё что идёт на роутер (busybox-ash) или тонкий host-glue без bash-фич.
POSIX_FILES=(
    bootstrap/bootstrap.sh
    engine/run-tests.sh
    package/cheburnet/files/rpcd-cheburnet.sh
    tests/poc/split-routing-netns.sh
)

# BASH_FILES и BATS_FILES — собираются автоматически через find, чтобы новые
# скрипты не требовали ручной правки lint.sh (single source of truth = ФС).
# Для надёжной работы в read-only checkout'е: find отбирает по содержимому
# файла (shebang), не по имени.

BASH_FILES=( tests/lint.sh )
while IFS= read -r f; do
    case "$(head -1 "$f" 2>/dev/null)" in
        '#!/usr/bin/env bash'|'#!/bin/bash'|'#!/usr/bin/bash')
            BASH_FILES+=("$f") ;;
    esac
done < <(find tests/qemu -type f,l -not -path 'tests/qemu/.work/*' 2>/dev/null | sort -u)

# === Цветовой helper ===
if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; N=""
fi

FAILS=0
section() { printf '\n%s━━━ %s ━━━%s\n' "$Y" "$1" "$N"; }
ok()      { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
fail()    { printf '  %s✗%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS + 1)); }

# === 1. shellcheck (POSIX) ===
section "shellcheck --shell=sh (severity=warning)"
if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck не установлен (apt-get install shellcheck / dnf install ShellCheck)"
else
    if shellcheck --shell=sh --severity=warning --external-sources "${POSIX_FILES[@]}"; then
        ok "${#POSIX_FILES[@]} POSIX-файлов чисты"
    else
        fail "shellcheck warnings в POSIX-файлах"
    fi
fi

# === 2. shellcheck (bash) ===
section "shellcheck --shell=bash (severity=warning)"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck --shell=bash --severity=warning --external-sources "${BASH_FILES[@]}"; then
        ok "${#BASH_FILES[@]} bash-файлов чисты"
    else
        fail "shellcheck warnings в bash-файлах"
    fi
fi

# === 3. Синтаксис (sh -n / bash -n) ===
section "syntax check (sh -n / bash -n)"
syntax_fail=0
for f in "${POSIX_FILES[@]}"; do
    if ! sh -n "$f" 2>/tmp/lint-syntax.err; then
        printf '  %s✗%s %s\n' "$R" "$N" "$f"
        cat /tmp/lint-syntax.err
        syntax_fail=1
    fi
done
for f in "${BASH_FILES[@]}"; do
    if ! bash -n "$f" 2>/tmp/lint-syntax.err; then
        printf '  %s✗%s %s\n' "$R" "$N" "$f"
        cat /tmp/lint-syntax.err
        syntax_fail=1
    fi
done
rm -f /tmp/lint-syntax.err
if [ "$syntax_fail" -eq 0 ]; then
    ok "$(( ${#POSIX_FILES[@]} + ${#BASH_FILES[@]} )) файлов парсятся без синтаксических ошибок"
else
    fail "найдены синтаксические ошибки (см. выше)"
fi

# === 4. JSON-валидность ===
# engine/ubus/rpcd-acl.json — генерируется acl.uc из реестра ubus-методов и
# коммитится в репо (пакет ставит его как есть). Кривой JSON ломает rpcd —
# веб-мастер мёртв. Соответствие файла реестру проверяет engine/ubus/tests
# (make test-engine); здесь — только быстрая проверка валидности синтаксиса.
section "JSON validity"
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 не найден — пропустить JSON-проверки нельзя"
else
    if python3 -m json.tool engine/ubus/rpcd-acl.json >/dev/null; then
        ok "engine/ubus/rpcd-acl.json"
    else
        fail "engine/ubus/rpcd-acl.json — невалидный JSON"
    fi
fi

# === Итог ===
echo
if [ "$FAILS" -eq 0 ]; then
    printf '%s✓ lint OK%s\n' "$G" "$N"
    exit 0
else
    printf '%s✗ lint FAILED — %d проверок упало%s\n' "$R" "$FAILS" "$N"
    exit 1
fi
