#!/usr/bin/env bash
# tests/lint.sh — статические проверки cheburnet-router.
#
# Один и тот же скрипт вызывается из CI (.github/workflows/lint.yml) и локально
# через `make lint`. Никакой логики не должно быть в Makefile/CI помимо вызова
# этого файла — DRY.
#
# Что проверяется:
#   1. shellcheck --shell=sh   на всех POSIX-скриптах (роутер = busybox-ash)
#   2. shellcheck --shell=bash на хост-тулинге (setup.sh)
#   3. sh -n / bash -n         синтаксис (safety net поверх shellcheck)
#   4. JSON-валидность         web/rpcd-acl.json + embedded ACL-heredoc'и
#
# Любой провал → exit 1.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

# === Списки файлов ===
# POSIX sh — всё что идёт на роутер (busybox-ash) или на хост, но без bash-фич.
POSIX_FILES=(
    install.sh
    lib/cheburnet-utils.sh
    lib/net-detect.sh
    lib/podkop-config.sh
    web/rpcd-cheburnet
    setup/install.sh
    setup/00-prerequisites.sh
    setup/01-amneziawg.sh
    setup/02-podkop.sh
    setup/03-adblock.sh
    setup/04-dns.sh
    setup/05-wifi.sh
    setup/06-vpn-mode.sh
    setup/07-killswitch.sh
    setup/08-watchdog.sh
    setup/09-ssh-hardening.sh
    setup/10-quality.sh
    setup/post-upgrade.sh
    scripts/awg-watchdog
    scripts/conntrack-monitor
    scripts/conntrack-tune
    scripts/dns-healthcheck
    scripts/dns-provider
    scripts/log-snapshot
    scripts/net-benchmark
    scripts/sqm-tune
    scripts/vpn-mode
    scripts/hotplug/button/10-vpn-mode
    scripts/init.d/vpn-mode
    backup/backup.sh
    backup/restore.sh
)

# BASH_FILES и BATS_FILES — собираются автоматически через find, чтобы новые
# моки/тесты не требовали ручной правки lint.sh (single source of truth = ФС).
# jsonfilter и nslookup — bash-script с #!/usr/bin/env python3 / bash; первый
# исключаем, второй включаем по shebang'у.
#
# Для надёжной работы в read-only checkout'е: find отбирает по содержимому
# файла (shebang), не по имени.

BASH_FILES=( setup.sh tests/lint.sh )
while IFS= read -r f; do
    # Пропускаем shellcheck-вендоров, симлинки разрешаем
    case "$f" in
        */vendor/*) continue ;;
    esac
    case "$(head -1 "$f" 2>/dev/null)" in
        '#!/usr/bin/env bash'|'#!/bin/bash'|'#!/usr/bin/bash')
            BASH_FILES+=("$f") ;;
    esac
done < <(find tests/helpers tests/integration -type f,l \
            \( -name '*.bash' -o -name '*' \) 2>/dev/null \
            | sort -u)

# .bats — надмножество bash; shellcheck на них работает с --shell=bash.
mapfile -t BATS_FILES < <(find tests -type f -name '*.bats' \
    -not -path 'tests/vendor/*' | sort)

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

    # .bats — надмножество bash (макрос @test переписывается в функции при
    # выполнении). Shellcheck парсит их как bash и ловит опечатки/quoting.
    # SC2317 (unused command) глушим: bats-функции не вызываются напрямую,
    # их исполняет сам bats-runner.
    if shellcheck --shell=bash --severity=warning --external-sources \
            --exclude=SC2317 "${BATS_FILES[@]}"; then
        ok "${#BATS_FILES[@]} .bats-файлов чисты"
    else
        fail "shellcheck warnings в .bats-файлах"
    fi
fi

# === 3. Синтаксис (sh -n / bash -n) ===
section "syntax check (sh -n / bash -n)"
syntax_fail=0
for f in "${POSIX_FILES[@]}"; do
    # init.d/vpn-mode имеет шебанг "#!/bin/sh /etc/rc.common" — sh -n парсит сам файл,
    # вторая часть шебанга для парсера неважна.
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
section "JSON validity"
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 не найден — пропустить JSON-проверки нельзя"
else
    # 4a. Standalone JSON
    if python3 -m json.tool web/rpcd-acl.json >/dev/null; then
        ok "web/rpcd-acl.json"
    else
        fail "web/rpcd-acl.json — невалидный JSON"
    fi

    # 4b. Embedded heredoc <<'ACL' ... ACL в setup/install.sh.
    # Извлекаем содержимое между маркерами и валидируем.
    extract_acl() {
        # $1 — путь к скрипту. Печатает содержимое первого ACL-heredoc'а.
        sed -n "/<<'ACL'/,/^ACL$/p" "$1" | sed "/<<'ACL'/d;/^ACL$/d"
    }

    src=setup/install.sh
    body="$(extract_acl "$src")"
    if [ -z "$body" ]; then
        fail "$src — heredoc <<'ACL' не найден (формат поменялся?)"
    elif printf '%s\n' "$body" | python3 -m json.tool >/dev/null 2>/tmp/lint-json.err; then
        ok "$src (embedded ACL heredoc)"
    else
        fail "$src — невалидный embedded JSON"
        cat /tmp/lint-json.err
    fi
    rm -f /tmp/lint-json.err
fi

# === 5. Smoke-test манифеста ===
# setup/manifest.txt — единственный источник правды о том, какие файлы едут
# на роутер. Если в манифесте есть ссылка на отсутствующий в репо файл,
# установка упадёт на этапе [prepare] с "источник отсутствует". Ловим в CI.
section "manifest sanity"
MANIFEST="setup/manifest.txt"
if [ ! -f "$MANIFEST" ]; then
    fail "$MANIFEST не найден"
else
    manifest_fail=0
    # POSIX read; backslash-escapes в путях нам не нужны — пути обычные.
    while read -r src dst mode; do
        case "$src" in ''|\#*) continue;; esac
        if [ ! -f "$src" ]; then
            fail "manifest: источник отсутствует: $src"
            manifest_fail=$((manifest_fail + 1))
        fi
        case "$dst" in
            /*) ;;
            *)  fail "manifest: dst должен быть абсолютным путём: $dst"
                manifest_fail=$((manifest_fail + 1));;
        esac
        case "$mode" in
            [0-7][0-7][0-7]) ;;
            *) fail "manifest: mode должен быть 3-значным octal: $mode (для $src)"
               manifest_fail=$((manifest_fail + 1));;
        esac
    done < "$MANIFEST"
    [ "$manifest_fail" -eq 0 ] && ok "$MANIFEST — все источники на месте, dst абсолютные, modes валидны"
fi

# === 6. Manifest coverage ===
# setup/0X-*.sh после рефакторинга ничего не копируют сами, а полагаются
# на манифест: `[ -x /usr/bin/X ]`-проверки и cron-задачи `/usr/bin/Y`
# верят, что файл уже на месте. Если кто-то удалит строку из манифеста
# или переименует destination — установка либо упадёт на конкретном шаге,
# либо тихо пропустит компонент. Ловим оба класса: каждое упоминание
# /usr/bin/ в setup-шагах должно иметь соответствующий dst в манифесте.
section "manifest coverage"
if [ ! -f "$MANIFEST" ]; then
    fail "$MANIFEST не найден — пропускаем coverage"
else
    # Список dst'ов из манифеста — для быстрого `grep -F`-сравнения.
    manifest_dsts="$(awk '$1 !~ /^#/ && NF==3 {print $2}' "$MANIFEST")"

    # Все упоминания /usr/bin/X в setup-шагах. Сначала вырезаем строки-
    # комментарии (там бывают glob-паттерны вида `/usr/bin/vpn-*`,
    # которые дают false-positive); затем извлекаем уникальные пути.
    # Echo-строки cron-задач включаем намеренно: они тоже зависят
    # от наличия бинаря (cron не упадёт, но команда будет no-op).
    setup_refs="$(grep -hv '^[[:space:]]*#' setup/*.sh 2>/dev/null \
                  | grep -oE '/usr/bin/[a-zA-Z][a-zA-Z0-9._-]*[a-zA-Z0-9]' \
                  | sort -u)"

    coverage_fail=0
    for ref in $setup_refs; do
        if ! printf '%s\n' "$manifest_dsts" | grep -qxF "$ref"; then
            fail "$ref упоминается в setup/ но НЕ устанавливается манифестом"
            coverage_fail=$((coverage_fail + 1))
        fi
    done

    if [ "$coverage_fail" -eq 0 ]; then
        n=$(printf '%s\n' "$setup_refs" | grep -c '^/usr/bin/' || true)
        ok "$n путей /usr/bin/* из setup/ покрыты манифестом"
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
