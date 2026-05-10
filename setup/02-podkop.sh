#!/bin/sh
# 02-podkop.sh — установить podkop + sing-box и настроить UCI для режима
# «всё через VPN кроме RU-сервисов» (HOME по умолчанию).
set -e

echo "== 02. Podkop + sing-box =="

# === 1. Установка через официальный скрипт ===
if [ -x /etc/init.d/podkop ]; then
    echo "→ podkop уже установлен"
else
    echo "→ скачиваем и ставим podkop"
    UPSTREAM_URL="https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"
    VENDOR_FILE="${CHEBURNET_VENDOR:-/opt/cheburnet/vendor}/podkop-install.sh"

    # Сначала пробуем upstream (свежая версия), потом fallback на vendored-копию.
    # raw.githubusercontent.com периодически блокируют провайдеры по DPI —
    # без vendor-копии пользователь без VPN никогда сюда не доберётся.
    if wget -qO /tmp/podkop-install.sh --timeout=20 "$UPSTREAM_URL" 2>/dev/null && \
       [ -s /tmp/podkop-install.sh ]; then
        echo "  ✓ скачан свежий установщик с upstream"
    elif [ -f "$VENDOR_FILE" ]; then
        echo "  ⚠ upstream недоступен — использую vendored-копию ($VENDOR_FILE)"
        cp "$VENDOR_FILE" /tmp/podkop-install.sh
    else
        echo "✗ Не удалось получить podkop installer ни с upstream, ни локально." >&2
        echo "  Проверьте: wget $UPSTREAM_URL" >&2
        exit 1
    fi

    # `yes n` шлёт бесконечный поток "n" — устойчиво к любому числу y/n-вопросов
    # подкоповского установщика (раньше было `printf 'n\nn\nn\n'` — хрупко,
    # ломалось бы если itdoginfo добавил четвёртый вопрос).
    yes n | sh /tmp/podkop-install.sh 2>&1 | tail -20

    # Установщик подкопа сам внутри делает apk update + apk add. Изредка
    # падает на транзиентных проблемах с зеркалами OpenWrt
    # (wget "Operation not permitted", "unexpected end of file", битый
    # индекс). Один повтор после apk update закрывает 90% таких случаев
    # без вмешательства пользователя. Дальше идти бессмысленно — UCI-конфиг
    # подкопа применять некуда.
    if [ ! -x /etc/init.d/podkop ]; then
        echo "  установщик подкопа не оставил /etc/init.d/podkop, обновляю индексы и повторяю..."
        apk update >/dev/null 2>&1 || true
        yes n | sh /tmp/podkop-install.sh 2>&1 | tail -20
    fi
    if [ ! -x /etc/init.d/podkop ]; then
        echo "✗ Установщик podkop отработал дважды, но /etc/init.d/podkop не появился." >&2
        echo "  Скорее всего временный сбой зеркал OpenWrt/wget — подождите 1-2 минуты" >&2
        echo "  и повторите setup.sh." >&2
        exit 1
    fi
fi

# === 2. UCI-конфигурация ===
echo "→ настраиваем podkop UCI"

# Подключаем общие хелперы. На роутере lib живёт в /opt/cheburnet/lib/
# (туда копирует install.sh / setup.sh). Fallback на относительный путь
# нужен для запуска шага напрямую из репо-чекаута без install.sh.
LIB_DIR="${CHEBURNET_LIB_DIR:-/opt/cheburnet/lib}"
[ -f "$LIB_DIR/net-detect.sh" ] || LIB_DIR="$(dirname "$0")/../lib"
# shellcheck source=../lib/net-detect.sh disable=SC1090,SC1091
. "$LIB_DIR/net-detect.sh"
# shellcheck source=../lib/podkop-config.sh disable=SC1090,SC1091
. "$LIB_DIR/podkop-config.sh"

LAN_CIDR=$(net_lan_cidr) || {
    echo "✗ Не удалось определить LAN-подсеть из uci." >&2
    echo "  Проверьте: uci show network.lan" >&2
    exit 1
}
echo "  LAN-подсеть: $LAN_CIDR"

# main: всё через AWG. exclude_ru: исключения для RU-сервисов (HOME-режим
# применяется по умолчанию — запускаем установку как "обычно дома").
# Логика обеих секций живёт в lib/podkop-config.sh, чтобы scripts/vpn-mode
# при переключении HOME/TRAVEL не дублировал ту же UCI-простыню.
podkop_apply_main_section "$LAN_CIDR"
podkop_apply_home

# Лог-уровень — warn (чтобы не забивать logd дебагом)
uci set podkop.settings.log_level='warn'
uci commit podkop

# === 3. Enable + start ===
echo "→ enable + start podkop"
/etc/init.d/podkop enable
/etc/init.d/podkop restart >/dev/null 2>&1 &
sleep 10

# === 4. Проверка ===
echo "→ проверяем"
if /etc/init.d/sing-box status | grep -q running 2>/dev/null; then
    echo "✓ sing-box running"
else
    echo "⚠ sing-box не работает — см. logread | grep sing-box"
fi

# Проверка nft правил
if nft list table inet PodkopTable >/dev/null 2>&1; then
    echo "✓ nft PodkopTable установлен"
else
    echo "⚠ nft-правила подkop'а отсутствуют"
fi

echo "✓ podkop OK"
