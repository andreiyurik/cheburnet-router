#!/usr/bin/env bats
# Тесты awg_pick_version: выбор подходящего релиза awg-openwrt-пакета.
#
# Контракт после рефакторинга «без хардкода» (вариант c):
#   1. Пробуем v$preferred ($DISTRIB_RELEASE).
#   2. Если нет — спрашиваем GitHub API за latest-релизом awg-openwrt
#      и проверяем, есть ли у него .apk под нужную arch.
#   3. Иначе — return 1, ничего не печатаем (вызывающий покажет ошибку).
#
# Зашитой константы «25.12.2» больше нет — она быстро устаревала и на
# свежем ядре всё равно не работала (kernel mismatch ловил modprobe).

load '../helpers/setup'

# ─── Мок-инфраструктура ─────────────────────────────────────────────────────
#
# wget-shim различает два режима по URL:
#   • .../releases/latest (api.github.com) → отдаёт synthetic JSON с
#     "tag_name":"v$LATEST_TAG", если LATEST_TAG_FILE непустой; иначе fail.
#   • .../releases/download/.../*.apk → exit 0 если URL в available_urls.

setup() {
    MOCK_DIR="$(mktemp -d)"
    export MOCK_DIR
    AVAILABLE_URLS="$MOCK_DIR/available_urls"
    LATEST_TAG_FILE="$MOCK_DIR/latest_tag"
    export AVAILABLE_URLS LATEST_TAG_FILE
    : > "$AVAILABLE_URLS"
    : > "$LATEST_TAG_FILE"

    cat > "$MOCK_DIR/wget" <<'SHIM'
#!/usr/bin/env bash
url="${!#}"  # last positional arg = URL
case "$url" in
    *api.github.com*releases/latest*)
        if [ -s "$LATEST_TAG_FILE" ]; then
            printf '{"tag_name":"v%s","name":"latest"}\n' "$(cat "$LATEST_TAG_FILE")"
            exit 0
        fi
        exit 1
        ;;
esac
while IFS= read -r allowed; do
    [ "$url" = "$allowed" ] && exit 0
done < "$AVAILABLE_URLS"
exit 1
SHIM
    chmod +x "$MOCK_DIR/wget"
    PATH="$MOCK_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$MOCK_DIR"
}

# Хелперы.
allow_url() { echo "$1" >> "$AVAILABLE_URLS"; }
set_latest_tag() { echo "$1" > "$LATEST_TAG_FILE"; }

url_for() {
    # url_for VERSION ARCH
    printf 'https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v%s/kmod-amneziawg_v%s_%s.apk\n' \
        "$1" "$1" "$2"
}

# ─── Тесты ──────────────────────────────────────────────────────────────────

@test "awg_pick_version: preferred доступен → возвращает preferred (без обращения к API)" {
    allow_url "$(url_for 25.12.3 aarch64_cortex-a53_mediatek_filogic)"
    # Намеренно НЕ выставляем latest — preferred должен сработать с первой попытки.
    run awg_pick_version "25.12.3" "aarch64_cortex-a53_mediatek_filogic"
    assert_success
    assert_output "25.12.3"
}

@test "awg_pick_version: preferred недоступен → берёт latest из GitHub API" {
    # У апстрима ещё нет билда под 25.12.5, но latest = 25.12.4 и под нашу arch есть.
    allow_url "$(url_for 25.12.4 aarch64_cortex-a53_mediatek_filogic)"
    set_latest_tag "25.12.4"
    run awg_pick_version "25.12.5" "aarch64_cortex-a53_mediatek_filogic"
    assert_success
    assert_output "25.12.4"
}

@test "awg_pick_version: latest = preferred — не дублирует HEAD-запрос" {
    # preferred = latest = 25.12.3. Первый wget --spider успешен → возвращаем сразу.
    # API вообще не должен опрашиваться (это и важно — лишних сетевых вызовов нет).
    allow_url "$(url_for 25.12.3 x86_64)"
    # latest НЕ выставляем намеренно: если бы код сходил в API, мы бы это заметили
    # — функция бы вернула пустую строку через step 2.
    run awg_pick_version "25.12.3" "x86_64"
    assert_success
    assert_output "25.12.3"
}

@test "awg_pick_version: API даёт latest, но под arch'у нет билда → fail" {
    # latest = 25.12.4, но в available_urls .apk под нужную arch отсутствует.
    set_latest_tag "25.12.4"
    # available_urls пустой — никакая arch не считается доступной.
    run awg_pick_version "25.12.5" "exotic_arch"
    assert_failure
    assert_output ""
}

@test "awg_pick_version: preferred недоступен и API недоступен → fail" {
    # Ни preferred-arch'и в available_urls, ни latest-тега — оба пути закрыты.
    run awg_pick_version "26.01.0" "x86_64"
    assert_failure
    assert_output ""
}

@test "awg_pick_version: пустой preferred → сразу идёт за latest из API" {
    allow_url "$(url_for 25.12.3 x86_64)"
    set_latest_tag "25.12.3"
    run awg_pick_version "" "x86_64"
    assert_success
    assert_output "25.12.3"
}

@test "awg_pick_version: пустой preferred + API недоступен → fail" {
    run awg_pick_version "" "x86_64"
    assert_failure
    assert_output ""
}

@test "awg_pick_version: разные архитектуры различимы (mediatek vs x86)" {
    allow_url "$(url_for 25.12.3 x86_64)"
    set_latest_tag "25.12.3"
    # Для mediatek-arch нет билда → fail (через preferred недоступен → latest без arch).
    run awg_pick_version "25.12.3" "aarch64_cortex-a53_mediatek_filogic"
    assert_failure

    run awg_pick_version "25.12.3" "x86_64"
    assert_success
    assert_output "25.12.3"
}
