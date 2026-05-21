#!/usr/bin/env bats
# Контракт vendor/sing-box-rulesets/ bootstrap-cache (Problem 2 follow-up):
# обеспечить что HOME-режим работает с первой минуты установки, даже если у
# юзера DPI на github.com и подkop не сможет скачать russia_outside.srs сам.
#
# Эти тесты — регресс-защита для:
#   1. vendor/sing-box-rulesets/russia_outside.srs — файл существует, не пустой,
#      имеет правдоподобный размер (>100 B — не плейсхолдер, <100 KB — не битый).
#   2. update.sh — синтаксически валидный, упоминает правильный URL upstream'а
#      (github.com/itdoginfo/allow-domains/releases) и tag (russia_outside).
#   3. Copy-блок из setup/02-podkop.sh — копирует с ПРАВИЛЬНЫМ именем по
#      ПРАВИЛЬНОМУ пути. Имя `exclude_ru-russia_outside-community-ruleset.srs`
#      завязано на подkop'овский format generator (см. itdoginfo/podkop:
#      podkop/files/usr/lib/rulesets.sh::get_ruleset_tag) — если эта формула
#      сломается, наш кеш будет лежать в /tmp, а sing-box будет искать его
#      под другим именем и тихо скачивать с github (и падать при DPI).
#
# Зачем bats, а не manual smoke: copy-логика тривиальна (3 строки), но имя
# файла критично и его легко сломать при рефакторинге («сделаю-ка я переменную
# поудобнее»). Этот тест поймёт, что переменная стала переименовываться.

load 'helpers/sandbox'

setup() {
    sandbox_init
}

teardown() {
    sandbox_cleanup
}

# ─── vendor/sing-box-rulesets/ файл-инвентаризация ───────────────────────────

@test "vendor: russia_outside.srs существует и непустой" {
    [ -s "$REPO_ROOT/vendor/sing-box-rulesets/russia_outside.srs" ]
}

@test "vendor: russia_outside.srs размер правдоподобный (>100 B, <100 KB)" {
    # 100 B — нижняя граница (меньше = плейсхолдер или битый файл).
    # 100 KB — верхняя (формат binary .srs для ~37 доменов это ~500 B;
    # если файл внезапно стал >100 KB — либо мы скачали неправильный файл,
    # либо upstream-формат сменился и нам нужна re-vendoring проверка).
    _size=$(wc -c < "$REPO_ROOT/vendor/sing-box-rulesets/russia_outside.srs")
    [ "$_size" -gt 100 ] && [ "$_size" -lt 102400 ]
}

@test "vendor: update.sh синтаксически валиден" {
    sh -n "$REPO_ROOT/vendor/sing-box-rulesets/update.sh"
}

@test "vendor: update.sh упоминает правильный upstream URL" {
    # Контракт с подkop'ом: $SRS_MAIN_URL/$tag.srs из его constants.sh.
    # Если они сменят hosting (например, на свой CDN) — наш кеш будет
    # тянуться с устаревшего источника. Поймать grep'ом.
    grep -q "github.com/itdoginfo/allow-domains/releases" \
        "$REPO_ROOT/vendor/sing-box-rulesets/update.sh"
}

@test "vendor: update.sh обновляет именно russia_outside (наш только default-tag)" {
    grep -q "russia_outside" "$REPO_ROOT/vendor/sing-box-rulesets/update.sh"
}

# ─── Copy-блок из setup/02-podkop.sh ─────────────────────────────────────────
#
# Изолируем copy-логику в sh-функцию (буквально те же 6 строк, что в
# setup/02-podkop.sh между маркерами `=== 2a. Bootstrap-кеш`). Если эти
# строки в setup-скрипте поменяются, ОБЯЗАТЕЛЬНО синхронизировать.
# Иначе тест проверяет «как должно быть», а скрипт делает что-то иное.

_run_bootstrap_cache_block() {
    # Те же переменные, что в setup/02-podkop.sh
    VENDOR_RULESETS="${CHEBURNET_VENDOR:-/opt/cheburnet/vendor}/sing-box-rulesets"
    if [ -s "$VENDOR_RULESETS/russia_outside.srs" ]; then
        mkdir -p "$RULESETS_DIR"
        cp "$VENDOR_RULESETS/russia_outside.srs" \
           "$RULESETS_DIR/exclude_ru-russia_outside-community-ruleset.srs"
    fi
}

@test "copy: vendor-файл копируется с подkop'овским именем по правильному пути" {
    # Pre-condition: подкладываем vendor в sandbox
    mkdir -p "$SANDBOX/vendor/sing-box-rulesets"
    cp "$REPO_ROOT/vendor/sing-box-rulesets/russia_outside.srs" \
       "$SANDBOX/vendor/sing-box-rulesets/"

    CHEBURNET_VENDOR="$SANDBOX/vendor"
    _run_bootstrap_cache_block

    # КРИТИЧНО: имя файла на destination'е должно быть строго
    # `exclude_ru-russia_outside-community-ruleset.srs` — sing-box ищет
    # его именно под этим именем, генерируемым подkop'ом по формуле
    # <section>-<tag>-community-ruleset.srs. Любое отклонение → cache
    # игнорируется, sing-box качает с github (и падает при DPI).
    [ -f "$RULESETS_DIR/exclude_ru-russia_outside-community-ruleset.srs" ]
}

@test "copy: содержимое скопировалось byte-perfect (md5)" {
    mkdir -p "$SANDBOX/vendor/sing-box-rulesets"
    cp "$REPO_ROOT/vendor/sing-box-rulesets/russia_outside.srs" \
       "$SANDBOX/vendor/sing-box-rulesets/"

    CHEBURNET_VENDOR="$SANDBOX/vendor"
    _run_bootstrap_cache_block

    src_md5=$(md5sum "$REPO_ROOT/vendor/sing-box-rulesets/russia_outside.srs" | awk '{print $1}')
    dst_md5=$(md5sum "$RULESETS_DIR/exclude_ru-russia_outside-community-ruleset.srs" | awk '{print $1}')
    [ "$src_md5" = "$dst_md5" ]
}

@test "copy: vendor-файла нет — no-op, не падает" {
    # Vendor-каталог пустой → блок не должен пытаться копировать. Не должно
    # быть exit 1 или stderr-шума. Защита от сценария «юзер собрал кастомный
    # билд без vendor-копий».
    mkdir -p "$SANDBOX/vendor/sing-box-rulesets"
    # russia_outside.srs НЕ кладём

    CHEBURNET_VENDOR="$SANDBOX/vendor"
    _run_bootstrap_cache_block  # должно вернуть 0

    [ ! -d "$RULESETS_DIR" ] || [ -z "$(ls -A "$RULESETS_DIR" 2>/dev/null)" ]
}

@test "copy: vendor-файл пустой (0 байт) — no-op (защита от битого скачивания)" {
    # Edge: update.sh упал на середине, оставив 0-байтный файл. Не должны
    # копировать в /tmp/ битый файл — sing-box получит пустой rule_set и
    # его правила вообще не применятся. -s test уже это предотвращает.
    mkdir -p "$SANDBOX/vendor/sing-box-rulesets"
    : > "$SANDBOX/vendor/sing-box-rulesets/russia_outside.srs"

    CHEBURNET_VENDOR="$SANDBOX/vendor"
    _run_bootstrap_cache_block

    [ ! -f "$RULESETS_DIR/exclude_ru-russia_outside-community-ruleset.srs" ]
}

# ─── Контракт между bootstrap-cache и healthcheck ────────────────────────────

@test "интеграция: после copy — get_status.rulesets_health.russia_outside_loaded=true" {
    # Этот тест проверяет что наш copy-блок и наш healthcheck (Problem 2)
    # используют одну и ту же конвенцию именования. Если copy-блок начнёт
    # класть файл под другим именем — healthcheck-баннер будет показываться
    # ВСЕГДА, потому что glob `*russia_outside*.srs` не сматчит.
    sandbox_set_token >/dev/null
    # Симулируем HOME-режим
    uci set podkop.exclude_ru.connection_type=exclusion
    uci set podkop.exclude_ru.community_lists=russia_outside

    # Подкладываем vendor + выполняем copy-блок
    mkdir -p "$SANDBOX/vendor/sing-box-rulesets"
    cp "$REPO_ROOT/vendor/sing-box-rulesets/russia_outside.srs" \
       "$SANDBOX/vendor/sing-box-rulesets/"
    CHEBURNET_VENDOR="$SANDBOX/vendor"
    _run_bootstrap_cache_block

    # get_status должен видеть файл и сказать loaded=true
    run run_rpcd get_status
    assert_success
    assert_json_field "$output" .rulesets_health.russia_outside_loaded "true"
}
