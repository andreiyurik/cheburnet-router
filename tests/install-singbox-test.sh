#!/usr/bin/env bash
# tests/install-singbox-test.sh — тесты install-singbox.sh (догрузка sing-box по кнопке).
#
# Проверяем самое глючеопасное: ретраи apk и КОД ВЫХОДА по факту наличия бинаря (а не по коду
# apk). Изолируем через фейковые apk/sing-box на PATH — реальную сеть/пакеты не трогаем.
#
# Запуск: bash tests/install-singbox-test.sh  (или make test-shell). ~секунды.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/engine/install/install-singbox.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# make_env DIR FAIL_TIMES — готовит фейковый PATH-каталог:
#   apk        — «падает» первые FAIL_TIMES вызовов add, затем «ставит» sing-box (создаёт фейк).
#   sing-box   — появляется только когда apk «поставил» (флаг-файл installed).
# Счётчик попыток — в файле, чтобы переживал вызовы.
make_env() {
    local dir="$1" fail_times="$2"
    mkdir -p "$dir"
    echo 0 > "$dir/.attempts"
    echo "$fail_times" > "$dir/.fail_times"
    # фейковый apk: update → ok; add sing-box → падает N раз, потом создаёт бинарь sing-box.
    cat > "$dir/apk" <<EOF
#!/bin/sh
[ "\$1" = "update" ] && exit 0
if [ "\$1" = "add" ] && [ "\$2" = "sing-box" ]; then
    n=\$(cat "$dir/.attempts"); n=\$((n + 1)); echo "\$n" > "$dir/.attempts"
    ft=\$(cat "$dir/.fail_times")
    if [ "\$n" -le "\$ft" ]; then echo "apk: сеть недоступна" >&2; exit 1; fi
    # успех: кладём рабочий фейк sing-box рядом (появится в command -v)
    printf '#!/bin/sh\nexit 0\n' > "$dir/sing-box"; chmod +x "$dir/sing-box"
    exit 0
fi
exit 0
EOF
    chmod +x "$dir/apk"
}

run_script() { # PATH=fakedir SB_SLEEP=0 SB_RETRIES=? → запустить скрипт, вернуть код
    local dir="$1"; shift
    PATH="$dir:/usr/bin:/bin" SB_SLEEP=0 "$@" sh "$SCRIPT" >/dev/null 2>&1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. apk ставит с первой попытки → exit 0, ровно 1 попытка ---
D="$TMP/first"; make_env "$D" 0
if run_script "$D"; then ok "успех с первой попытки → exit 0"; else bad "должен был выйти 0"; fi
[ "$(cat "$D/.attempts")" = "1" ] && ok "ровно 1 попытка apk add" || bad "ожидалась 1 попытка, было $(cat "$D/.attempts")"

# --- 2. apk падает 2 раза, потом успех → exit 0 после ретраев (3 попытки) ---
D="$TMP/retry"; make_env "$D" 2
if run_script "$D"; then ok "успех после 2 провалов → exit 0 (ретраи работают)"; else bad "ретраи должны были добить до успеха"; fi
[ "$(cat "$D/.attempts")" = "3" ] && ok "ровно 3 попытки (2 провала + успех)" || bad "ожидалось 3 попытки, было $(cat "$D/.attempts")"

# --- 3. apk всегда падает, бинаря нет → exit 1, попыток = SB_RETRIES (не бесконечно) ---
D="$TMP/fail"; make_env "$D" 99
if run_script "$D" env SB_RETRIES=4; then bad "должен был выйти НЕ 0 (бинаря нет)"; else ok "все попытки провалились → exit 1 (честный отказ)"; fi
[ "$(cat "$D/.attempts")" = "4" ] && ok "ровно SB_RETRIES=4 попытки, не залипло в цикле" || bad "ожидалось 4 попытки, было $(cat "$D/.attempts")"

# --- 4. КРИТИЧНО: apk «успешен» (exit 0), но бинарь не появился → exit 1 (код по факту, не по apk) ---
D="$TMP/liar"; mkdir -p "$D"
cat > "$D/apk" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$D/apk"
if run_script "$D"; then bad "apk соврал успех, но sing-box нет — должен быть exit 1"; else ok "apk exit 0 без бинаря → всё равно exit 1 (критерий = наличие бинаря)"; fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ install-singbox: PASS=%d FAIL=0\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m✗ install-singbox: PASS=%d FAIL=%d\033[0m\n' "$PASS" "$FAIL"
exit 1
