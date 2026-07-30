#!/bin/sh
# install-singbox.sh — догрузка sing-box для Full-тира (opt-in). Зовётся ubus-методом
# install_full_tier через spawn_bg (фон). Раньше это была рукописная shell-строка внутри
# ucode-обработчика (вложенные кавычки + ретраи в одну строку) — вынесено в отдельный
# файл РАДИ ТЕСТИРУЕМОСТИ: логика ретраев/кода выхода теперь под tests/install-singbox-test.sh.
#
# Ретраи: downloads.openwrt.org из фильтрующих сетей рвётся посреди передачи (README про иронию
# знает). КОД ВЫХОДА = наличие бинаря (`command -v sing-box`), а НЕ код apk: единый честный
# критерий «получилось» — sing-box реально появился. Не трогает работающий AWG: ставит лишь пакет.
#
# Переопределяемые для теста (по умолчанию — боевые значения):
#   SB_RETRIES — сколько раз пытаться apk add (по умолчанию 4)
#   SB_SLEEP   — пауза между попытками, сек (по умолчанию 3; тест ставит 0)

set -u

RETRIES="${SB_RETRIES:-4}"
SLEEP="${SB_SLEEP:-3}"

echo "Ставлю sing-box (apk add)…"
# Индекс пакетов: обновление желательно, но не критично — apk add подтянет сам, если индекс свеж.
apk update 2>&1

# Вывод apk сохраняем: по нему различаем ПРИЧИНУ отказа. Совет «проверьте интернет» на
# самом деле про сеть, а на забитом флеше он отправляет человека чинить не то — а нехватка
# места здесь реальный кейс (sing-box ~15 МБ на роутер с 32-МБ флешем).
OUT="${SB_OUT:-/tmp/cheburnet-singbox-apk.log}"
: > "$OUT"

# ВАЖНО: НЕ `apk … | tee` — код выхода пайпа принадлежит tee (всегда 0), и ретраи бы не сработали
# (pipefail в busybox-ash не гарантирован). Пишем попытку в файл, печатаем её и копим в общий лог.
i=1
while [ "$i" -le "$RETRIES" ]; do
    if apk add sing-box > "$OUT.try" 2>&1; then
        cat "$OUT.try"; cat "$OUT.try" >> "$OUT"; rm -f "$OUT.try"
        break
    fi
    cat "$OUT.try"; cat "$OUT.try" >> "$OUT"; rm -f "$OUT.try"
    echo "попытка $i из $RETRIES не удалась, повтор…"
    i=$((i + 1))
    [ "$i" -le "$RETRIES" ] && sleep "$SLEEP"
done

# Итог строго по факту наличия бинаря (а не по коду apk, который мог «успешно» ничего не сделать).
if command -v sing-box >/dev/null 2>&1; then
    echo "sing-box установлен."
    rm -f "$OUT"
    exit 0
fi

# Причина отказа → REASON_FILE (его даёт ubus-слой через env, как длинным операциям): панель
# скажет адресно, а не «проверьте интернет» при забитом флеше. Нет env — просто печатаем.
# grep -i по типовым формулировкам apk/busybox о нехватке места; -q + || true (set -e не ловит
# пайп, но код grep тут именно ветвление, а не ошибка).
if grep -qiE "no space left|not enough space|out of space|ENOSPC" "$OUT" 2>/dev/null; then
    echo "sing-box установить не удалось: на роутере не хватило места (нужно ~15 МБ свободно)."
    [ -n "${REASON_FILE:-}" ] && echo "no-space" > "$REASON_FILE"
    rm -f "$OUT"
    exit 1
fi
echo "sing-box установить не удалось — проверьте подключение роутера к интернету."
[ -n "${REASON_FILE:-}" ] && echo "download" > "$REASON_FILE"
rm -f "$OUT"
exit 1
