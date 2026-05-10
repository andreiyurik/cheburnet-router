#!/usr/bin/env bats
# Контракт retry-обёрток в setup-шагах: одна автоматическая попытка при
# транзиентном сбое apk-зеркала или установщика. Закрывает класс ошибок
# "ADB integrity error", "wget: Operation not permitted", "unexpected end
# of file", "1 stale" — всё, что лечится повторным запросом к зеркалу.
#
# Тестируем 00-prerequisites.sh — это эталонный пример конструкции
# `if ! cmd; then cmd; fi`. Шаги 01-amneziawg и 02-podkop используют
# идентичный shell-паттерн (см. setup/01-amneziawg.sh:111-118 и
# setup/02-podkop.sh:36-50) — если он работает здесь, работает там же.
# Реальные шаги 01/02 целиком прогоняются через T3c (make qemu-install).
#
# Если этот тест начнёт падать, юзер увидит регрессию класса:
# • "kernel mismatch" / "uci: Entry not found" вместо понятного "повторите"
# • Скрипт фейлится при первом транзиентном чихе зеркала вместо ретрая

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

# ─── Хелпер: stateful apk-mock ───────────────────────────────────────────────
#
# Падает на первых N вызовах, дальше успех. Каждый вызов пишет argv
# в $CALLS_DIR/apk (одна строка на вызов) — для assert'ов на счётчик.
# Состояние счётчика — в $CALLS_DIR/apk_call_count.
make_stateful_apk() {
    local fail_first_n="$1"
    cat > "$MOCKDIR/apk" <<EOF
#!/bin/sh
state="\${CALLS_DIR}/apk_call_count"
n=\$(cat "\$state" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "\$state"
echo "\$@" >> "\$CALLS_DIR/apk"
if [ "\$n" -le "$fail_first_n" ]; then
    echo "ERROR: simulated transient mirror failure on call \$n" >&2
    exit 1
fi
echo "OK: simulated success on call \$n"
exit 0
EOF
    chmod +x "$MOCKDIR/apk"
}

# ─── apk update: счастливый путь ─────────────────────────────────────────────

@test "00-prereq: apk update прошёл с первой попытки → ретрая нет" {
    make_stateful_apk 0

    run "$REPO_ROOT/setup/00-prerequisites.sh"

    [ "$status" -eq 0 ]
    # apk вызвался ровно 2 раза: update + add. Без повтора.
    [ "$(wc -l < "$CALLS_DIR/apk")" -eq 2 ]
    # Сообщение про повтор НЕ должно появляться при успехе.
    [[ "$output" != *"повторяю"* ]]
}

# ─── apk update: транзиентный сбой → retry → успех ──────────────────────────

@test "00-prereq: apk update упал на первой попытке, ретрай прошёл" {
    make_stateful_apk 1

    run "$REPO_ROOT/setup/00-prerequisites.sh"

    [ "$status" -eq 0 ]
    # apk вызвался 3 раза: update (fail) + update (retry, ok) + add (ok).
    [ "$(wc -l < "$CALLS_DIR/apk")" -eq 3 ]
    # Юзер должен видеть что был повтор — это важно для понимания лога.
    [[ "$output" == *"повторяю"* ]]
}

# ─── apk update: оба раза фейл → честный exit 1 ─────────────────────────────

@test "00-prereq: apk update упал дважды → скрипт фейлит, не уходит в add" {
    make_stateful_apk 2

    run "$REPO_ROOT/setup/00-prerequisites.sh"

    [ "$status" -ne 0 ]
    # apk вызвался ровно 2 раза: update (fail) + update (retry, fail).
    # До apk add дойти не должно — set -e ловит второй провал.
    [ "$(wc -l < "$CALLS_DIR/apk")" -eq 2 ]
}
