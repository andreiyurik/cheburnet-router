#!/bin/sh
# vendor/sing-box-rulesets/update.sh — обновить bootstrap-кеш sing-box rule_sets.
#
# Когда запускать: при каждом release cheburnet (или раз в 6 месяцев). Файлы
# здесь — «затравка» для первого старта sing-box. Подkop из коробки тянет их
# с github при первом запуске; если у юзера DPI на github, HOME-режим тихо
# ляжет (видно в web-панели как красный баннер «список russia_outside не
# загружен»). Vendor-копия страхует именно этот первый boot.
#
# После первой установки sing-box обновляет файлы через update_interval сам.
set -e
cd "$(dirname "$0")"

# URL должен матчить $SRS_MAIN_URL/$tag.srs из подkop'а
# (itdoginfo/podkop:podkop/files/usr/lib/constants.sh::SRS_MAIN_URL).
BASE="https://github.com/itdoginfo/allow-domains/releases/latest/download"

# Только те tag'и, что используются в нашем default-конфиге (HOME-режим
# = exclude_ru.community_lists='russia_outside'). Другие community_lists
# в наш default не входят — кому надо, грузит сам через VPN.
for tag in russia_outside; do
    echo "→ $tag.srs"
    # .new + rename: при сетевом обрыве не оставляем половинку файла.
    if ! wget -qO "$tag.srs.new" --timeout=20 "$BASE/$tag.srs"; then
        echo "  ✗ wget failed — старый файл оставлен на месте" >&2
        rm -f "$tag.srs.new"
        exit 1
    fi
    if [ ! -s "$tag.srs.new" ]; then
        echo "  ✗ скачался пустой файл — старый оставлен" >&2
        rm -f "$tag.srs.new"
        exit 1
    fi
    mv "$tag.srs.new" "$tag.srs"
    echo "  ✓ $(wc -c < "$tag.srs") байт"
done

echo
echo "✓ vendor/sing-box-rulesets/ обновлён."
echo "  Закоммить: git add vendor/sing-box-rulesets/ && git commit"
