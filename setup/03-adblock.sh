#!/bin/sh
# 03-adblock.sh — поставить adblock-lean с Hagezi Pro списком.
set -e

# cheburnet-utils.sh — для cheburnet_apk_fail_advice (диагностика причины
# фейла, используется в failure-сообщении ниже).
LIB="${CHEBURNET_LIB:-/opt/cheburnet/lib/cheburnet-utils.sh}"
[ -f "$LIB" ] || LIB="$(dirname "$0")/../lib/cheburnet-utils.sh"
# shellcheck source=../lib/cheburnet-utils.sh disable=SC1090,SC1091
. "$LIB"

echo "== 03. adblock-lean =="

# === 1. Установка ===
if [ -x /etc/init.d/adblock-lean ]; then
    echo "→ adblock-lean уже установлен"
else
    echo "→ скачиваем и устанавливаем adblock-lean"
    UPSTREAM_URL="https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh"
    VENDOR_FILE="${CHEBURNET_VENDOR:-/opt/cheburnet/vendor}/abl-install.sh"

    # Upstream-first, vendor-fallback — см. 02-podkop.sh про DPI-блокировки.
    if uclient-fetch -q --timeout=20 "$UPSTREAM_URL" -O /tmp/abl-install.sh 2>/dev/null && \
       [ -s /tmp/abl-install.sh ]; then
        echo "  ✓ скачан свежий установщик с upstream"
    elif [ -f "$VENDOR_FILE" ]; then
        echo "  → беру установщик adblock-lean из репозитория"
        echo "    (свежий с github.com не качается — это норма в некоторых странах, не ошибка)"
        cp "$VENDOR_FILE" /tmp/abl-install.sh
    else
        echo "✗ Не удалось получить adblock-lean installer ни с upstream, ни локально." >&2
        echo "  Проверьте: uclient-fetch $UPSTREAM_URL" >&2
        exit 1
    fi

    # abl-install внутри ходит на api.github.com за тегом последнего релиза.
    # Этот fetch регулярно падает с "Operation not permitted" (netfilter EPERM
    # сразу после firewall reload в шагах 01/02) или транзиентным wget-сбоем —
    # установщик возвращает ненулевой код, наш set -e убивает шаг.
    # Один повтор после apk update закрывает класс таких сбоев. По образцу
    # 02-podkop.sh: критерий «успешно» — появился /etc/init.d/adblock-lean.
    sh /tmp/abl-install.sh -v release || true
    if [ ! -x /etc/init.d/adblock-lean ]; then
        echo "  установщик adblock-lean не оставил /etc/init.d/adblock-lean, повторяю..."
        apk update >/dev/null 2>&1 || true
        sh /tmp/abl-install.sh -v release || true
    fi
    if [ ! -x /etc/init.d/adblock-lean ]; then
        echo "✗ Установщик adblock-lean отработал дважды, но /etc/init.d/adblock-lean не появился." >&2
        # Диагностика — adblock-lean ходит на api.github.com за тегом релиза,
        # это редко блокируется, но проверить стоит.
        command -v cheburnet_apk_fail_advice >/dev/null 2>&1 \
            && cheburnet_apk_fail_advice adblock-lean
        exit 1
    fi
fi

# === 2. Конфиг ===
# /etc/adblock-lean/config раскладывается манифестом (setup/manifest.txt).
# Manifest sanity в setup/install.sh:93-115 валит установку до этого шага,
# если файл отсутствует — fallback на `adblock-lean gen_config` тут больше
# не нужен (он же исторически рожал неполный конфиг и был источником багов).
# Убедимся что блок-лист — Hagezi Pro (на случай если конфиг подменили вручную)
if ! grep -q 'raw_block_lists="hagezi:pro"' /etc/adblock-lean/config; then
    echo "→ ставим hagezi:pro"
    sed -i 's|^raw_block_lists=.*|raw_block_lists="hagezi:pro"|' /etc/adblock-lean/config
fi

# === 2.5. addnmount entries для dnsmasq ===
# Без этих записей dnsmasq не имеет права читать gz-блоклист и /bin/busybox,
# adblock-lean логирует "Missing addnmount entries" и итоговая компрессия
# блок-листа отключается (а в худшем случае dnsmasq вообще не подцепляет его).
# Обычно эту работу делает интерактивная команда `service adblock-lean setup`,
# но в нашем пайплайне (sh /tmp/abl-install.sh -v release без TTY) DO_DIALOGS=0
# и setup-функция установщиком не вызывается. Делаем сами через UCI —
# идемпотентно и без зависимости от интерактивных диалогов.
if ! uci -q get dhcp.@dnsmasq[0].addnmount 2>/dev/null | grep -q 'abl-blocklist.gz'; then
    echo "→ добавляю addnmount для adblock-lean в /etc/config/dhcp"
    uci -q del_list dhcp.@dnsmasq[0].addnmount='/bin/busybox' 2>/dev/null || true
    uci -q del_list dhcp.@dnsmasq[0].addnmount='/var/run/adblock-lean/abl-blocklist.gz' 2>/dev/null || true
    uci add_list dhcp.@dnsmasq[0].addnmount='/bin/busybox'
    uci add_list dhcp.@dnsmasq[0].addnmount='/var/run/adblock-lean/abl-blocklist.gz'
    uci commit dhcp
fi

# === 3. Disable boot-autostart, start один раз сейчас ===
# Boot-autostart отключаем сознательно: на холодном boot adblock-lean
# гонится с VPN handshake и падает с "Operation not permitted" (sing-box
# ещё не слушает, а podkop уже заворачивает output трафик в proxy-таблицу).
# Реальный триггер — /etc/hotplug.d/iface/30-adblock на ifup awg0 после
# успешного handshake. Здесь во время установки awg0 уже up (шаг 01),
# поэтому стартуем разово.
echo "→ disable boot-autostart (триггер — hotplug awg0 ifup)"
/etc/init.d/adblock-lean disable

echo "→ start adblock-lean (качает ~1.5 MB список)"
/etc/init.d/adblock-lean start
sleep 5

# Перезапуск dnsmasq, чтобы подхватил блок-лист
/etc/init.d/dnsmasq restart
sleep 3

# === 4. Проверка ===
echo "→ проверяем"
if [ -f /var/run/adblock-lean/abl-blocklist.gz ]; then
    entries=$(zcat /var/run/adblock-lean/abl-blocklist.gz 2>/dev/null | tr '/' '\n' | grep -c '\.')
    echo "✓ блок-лист загружен: ~$entries доменов"
else
    echo "⚠ блок-лист не создан"
fi

# Тест конкретного известно-блокируемого домена
BLOCKED=$(nslookup pagead2.googlesyndication.com 127.0.0.1 2>/dev/null | grep -c 'Address' || true)
if [ "$BLOCKED" -le 1 ]; then
    echo "✓ тестовый домен (pagead2.googlesyndication.com) блокирован"
else
    echo "⚠ тестовый домен резолвится (возможно, кэш — попробуйте killall -HUP dnsmasq)"
fi

echo "✓ adblock-lean OK"
