#!/usr/bin/env bash
# tests/install-singbox-test.sh — тесты install-singbox.sh (догрузка бинаря sing-box для Full-тира).
#
# Проверяем самое глючеопасное: ретраи apk, ПОРЯДОК ПРЕДПОЧТЕНИЯ пакетов (tiny → полный) и
# КОД ВЫХОДА по факту наличия бинаря (а не по коду apk). Изолируем через фейковые apk/sing-box на
# PATH — реальную сеть/пакеты не трогаем.
#
# Запуск: bash tests/install-singbox-test.sh  (или make test-shell). ~секунды.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/engine/install/install-singbox.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# make_env DIR FAIL_TIMES [GOOD_PKG] — фейковый PATH-каталог:
#   apk        — пишет каждый `add <pkg>` в .calls; для GOOD_PKG «падает» первые FAIL_TIMES раз,
#                затем «ставит» бинарь sing-box (создаёт фейк). Для ЛЮБОГО другого пакета —
#                отказ «нет такого пакета» (так ведёт себя фид, где сборки нет).
#   sing-box   — появляется только когда apk «поставил».
# GOOD_PKG по умолчанию sing-box-tiny — предпочтительная сборка Full-тира.
# Счётчики — в файлах, чтобы переживали вызовы.
make_env() {
    local dir="$1" fail_times="$2" good="${3:-sing-box-tiny}"
    mkdir -p "$dir"
    echo 0 > "$dir/.attempts"
    : > "$dir/.calls"
    echo "$fail_times" > "$dir/.fail_times"
    cat > "$dir/apk" <<EOF
#!/bin/sh
[ "\$1" = "update" ] && exit 0
if [ "\$1" = "add" ]; then
    echo "\$2" >> "$dir/.calls"
    if [ "\$2" != "$good" ]; then
        echo "ERROR: unable to select packages: \$2 (no such package)" >&2
        exit 1
    fi
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
    PATH="$dir:/usr/bin:/bin" SB_SLEEP=0 SB_OUT="$dir/apk.log" "$@" sh "$SCRIPT" >/dev/null 2>&1
}

calls() { tr '\n' ' ' < "$1/.calls"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. предпочтительная сборка ставится с первой попытки → exit 0, полную не трогаем ---
# Порядок важен: tiny легче (11.5 МБ против 16.0) и покрывает оба Full-протокола (with_quic +
# with_utls). Если бы скрипт начинал с полной сборки, экономия флеша не работала бы вообще.
D="$TMP/first"; make_env "$D" 0
if run_script "$D"; then ok "успех с первой попытки → exit 0"; else bad "должен был выйти 0"; fi
[ "$(cat "$D/.attempts")" = "1" ] && ok "ровно 1 попытка apk add" || bad "ожидалась 1 попытка, было $(cat "$D/.attempts")"
[ "$(calls "$D")" = "sing-box-tiny " ] \
    && ok "первым пробуется sing-box-tiny, полная сборка не качается" \
    || bad "ожидался только sing-box-tiny, вызовы: [$(calls "$D")]"

# --- 2. apk падает 2 раза, потом успех → exit 0 после ретраев (3 попытки) ---
D="$TMP/retry"; make_env "$D" 2
if run_script "$D"; then ok "успех после 2 провалов → exit 0 (ретраи работают)"; else bad "ретраи должны были добить до успеха"; fi
[ "$(cat "$D/.attempts")" = "3" ] && ok "ровно 3 попытки (2 провала + успех)" || bad "ожидалось 3 попытки, было $(cat "$D/.attempts")"

# --- 3. tiny НЕ собран под платформу → фолбэк на полную сборку (Full-железу не отказываем) ---
D="$TMP/fallback"; make_env "$D" 0 "sing-box"
if run_script "$D" env SB_RETRIES=2; then ok "нет tiny → полная сборка ставится, exit 0"; else bad "фолбэк на полный sing-box не сработал"; fi
[ "$(calls "$D")" = "sing-box-tiny sing-box-tiny sing-box " ] \
    && ok "tiny исчерпал ретраи, затем взят полный sing-box (порядок предпочтения соблюдён)" \
    || bad "неожиданная последовательность пакетов: [$(calls "$D")]"

# --- 4. ни один пакет не доступен → exit 1, попыток конечное число (не залипаем) ---
D="$TMP/fail"; make_env "$D" 99 "нет-такого-пакета"
if run_script "$D" env SB_RETRIES=3; then bad "должен был выйти НЕ 0 (бинаря нет)"; else ok "оба пакета недоступны → exit 1 (честный отказ)"; fi
[ "$(calls "$D")" = "sing-box-tiny sing-box-tiny sing-box-tiny sing-box sing-box sing-box " ] \
    && ok "по SB_RETRIES=3 попытки на каждый пакет, не залипло в цикле" \
    || bad "неожиданная последовательность: [$(calls "$D")]"

# --- 5. КРИТИЧНО: apk «успешен» (exit 0), но бинарь не появился → exit 1 (код по факту, не по apk) ---
D="$TMP/liar"; mkdir -p "$D"
cat > "$D/apk" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$D/apk"
if run_script "$D"; then bad "apk соврал успех, но sing-box нет — должен быть exit 1"; else ok "apk exit 0 без бинаря → всё равно exit 1 (критерий = наличие бинаря)"; fi

# --- 6. ПРИЧИНА отказа: нет места ≠ нет интернета (панель советует разное) ---
# Совет «проверьте интернет» на забитом флеше отправляет человека чинить не то, а бинарь
# (~11 МБ скачивания) на 32-МБ роутере реально может не влезть.
D="$TMP/nospace"; mkdir -p "$D"
cat > "$D/apk" <<'EOF'
#!/bin/sh
[ "$1" = "update" ] && exit 0
echo "ERROR: $2: No space left on device" >&2
exit 1
EOF
chmod +x "$D/apk"
PATH="$D:/usr/bin:/bin" SB_SLEEP=0 SB_RETRIES=2 SB_OUT="$D/apk.log" REASON_FILE="$D/reason" \
    sh "$SCRIPT" > "$D/out.txt" 2>&1 && bad "должен быть exit 1" || ok "нет места → exit 1"
[ "$(cat "$D/reason" 2>/dev/null)" = "no-space" ] \
    && ok "reason=no-space (панель скажет про место, а не про интернет)" \
    || bad "ожидался reason=no-space, получено '$(cat "$D/reason" 2>/dev/null)'"
grep -q "не хватило места" "$D/out.txt" && ok "в логе адресное сообщение про место" \
    || bad "сообщение про нехватку места не напечатано"

# --- 7. Сетевой отказ → reason=download (прежний совет про интернет уместен) ---
D="$TMP/nonet"; make_env "$D" 99
PATH="$D:/usr/bin:/bin" SB_SLEEP=0 SB_RETRIES=2 SB_OUT="$D/apk.log" REASON_FILE="$D/reason" \
    sh "$SCRIPT" >/dev/null 2>&1 && bad "должен быть exit 1" || ok "сеть недоступна → exit 1"
[ "$(cat "$D/reason" 2>/dev/null)" = "download" ] \
    && ok "reason=download (причина отличима от нехватки места)" \
    || bad "ожидался reason=download, получено '$(cat "$D/reason" 2>/dev/null)'"
[ "$(cat "$D/.attempts")" = "2" ] && ok "ретраи не сломались (код apk, а не tee): 2 попытки на tiny" \
    || bad "ожидалось 2 попытки, было $(cat "$D/.attempts")"

# --- 8. Бинарь УЖЕ стоит (переустановка/switch поверх Full) → apk вообще не зовём ---
# Иначе `apk add sing-box-tiny` поверх установленного полного sing-box упёрся бы в объявленный
# CONFLICTS и засорил лог пугающей ошибкой на ровном месте.
D="$TMP/present"; make_env "$D" 0
printf '#!/bin/sh\nexit 0\n' > "$D/sing-box"; chmod +x "$D/sing-box"
if run_script "$D"; then ok "бинарь уже есть → exit 0"; else bad "должен был выйти 0"; fi
[ -z "$(calls "$D")" ] && ok "apk add не вызывался (конфликт сборок не провоцируем)" \
    || bad "лишние вызовы apk: [$(calls "$D")]"

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✓ install-singbox: PASS=%d FAIL=0\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m✗ install-singbox: PASS=%d FAIL=%d\033[0m\n' "$PASS" "$FAIL"
exit 1
