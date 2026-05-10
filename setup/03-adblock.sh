#!/bin/sh
# 03-adblock.sh — поставить adblock-lean с Hagezi Pro списком.
set -e

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
        echo "  ⚠ upstream недоступен — использую vendored-копию ($VENDOR_FILE)"
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
        echo "  Скорее всего временный сбой api.github.com или сети — подождите 1-2 минуты" >&2
        echo "  и повторите setup.sh." >&2
        exit 1
    fi
fi

# === 2. Конфиг ===
# Раньше тут вызывался `adblock-lean gen_config`, но он на свежей установке
# регулярно рожал неполный конфиг (essential vars unset → adblock-lean
# падал в `get_def_preset` и сервис вставал в stopped). Готовый референс
# из repo раскладывается манифестом в /etc/adblock-lean/config — он
# содержит все нужные пресет-переменные (DNSMASQ_INDEXES, MAX_PARALLEL_JOBS,
# boot_start_delay_s и т.д.).
if [ ! -f /etc/adblock-lean/config ]; then
    echo "⚠ /etc/adblock-lean/config не найден (манифест?), fallback на gen_config"
    mkdir -p /etc/adblock-lean
    /etc/init.d/adblock-lean gen_config
fi

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
