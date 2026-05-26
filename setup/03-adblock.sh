#!/bin/sh
# 03-adblock.sh — поставить adblock-lean с Hagezi Pro списком.
set -e

echo "== 03. adblock-lean =="

# ─── DNS-readiness: ждём пока полная цепочка dnsmasq→sing-box fakeip заработает ───
#
# После шага 02 sing-box жив и PodkopTable активна, но fakeip-кэш может быть
# ещё не прогрет: DNS-запросы возвращают fakeip-адреса, а sing-box при TCP-
# соединении не находит маппинг → ядро возвращает EPERM ("Operation not
# permitted"). Это гарантированно роняет uclient-fetch к api.github.com внутри
# abl-install.sh на медленных роутерах (Cudy WR3000, ~2-5с на прогрев), и
# воспроизводится в QEMU-тестах.
#
# Решение: блокирующий DNS-probe до 30с (по образцу hotplug/30-adblock).
# Проверяем nslookup через 127.0.0.1 (dnsmasq → sing-box DoH → через VPN) —
# если резолв прошёл, fakeip-маппинг создан и TCP через tproxy тоже пройдёт.
# example.com — IANA-reserved, всегда резолвится, не блокируется DPI.
# На практике probe проходит за 2-5с; 30с — запас для совсем медленного железа.
# Если не дождались — идём дальше: vendor-fallback + retry дадут шанс, а при
# полном фейле юзер получит внятную диагностику ниже.
echo "→ жду готовности DNS через sing-box..."
_dns_ready=0
_dns_try=0
while [ "$_dns_try" -lt 15 ]; do
    if nslookup example.com 127.0.0.1 >/dev/null 2>&1; then
        _dns_ready=1
        break
    fi
    _dns_try=$((_dns_try + 1))
    sleep 2
done
if [ "$_dns_ready" = "1" ]; then
    echo "  ✓ DNS готов (${_dns_try}×2с)"
else
    echo "  ⚠ DNS не ответил за 30с — продолжаю, но fetch с github.com может упасть"
fi

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
    # DNS-probe выше закрывает основной класс EPERM-сбоев (fakeip не прогрет),
    # но остаются транзиентные: GitHub rate-limit (60 req/час anonymous),
    # кратковременная недоступность CDN, uclient-fetch timeout на медленном
    # канале. Один повтор после apk update (который заодно прогревает TCP-стек
    # через tproxy) закрывает большинство таких случаев.
    # Критерий «успешно» — появился /etc/init.d/adblock-lean.
    sh /tmp/abl-install.sh -v release || true
    if [ ! -x /etc/init.d/adblock-lean ]; then
        echo "  установщик adblock-lean не оставил /etc/init.d/adblock-lean, повторяю..."
        apk update >/dev/null 2>&1 || true
        sh /tmp/abl-install.sh -v release || true
    fi
    if [ ! -x /etc/init.d/adblock-lean ]; then
        # Раньше тут звали cheburnet_apk_fail_advice — но эта функция диагностирует
        # downloads.openwrt.org, а adblock-lean качается с github.com (api за
        # тегом релиза + raw за скриптом). Категориальная ошибка: советчик
        # проверял не тот хост и выдавал нерелевантный вердикт «зеркало
        # недоступно». Теперь пишем напрямую две реальные причины фейла —
        # все встречающиеся падения тут укладываются в один из этих двух
        # сценариев, заводить отдельную diag-функцию ради одного callsite
        # не имеет смысла.
        echo "✗ Установщик adblock-lean отработал дважды, но /etc/init.d/adblock-lean не появился." >&2
        echo "" >&2
        echo "  AdBlock качается с github.com (НЕ с зеркала OpenWrt), и установщик" >&2
        echo "  ходит за тегом последнего релиза в api.github.com. Типичные причины:" >&2
        echo "" >&2
        echo "    1. Лимит anonymous-запросов GitHub (60 запросов в час с одного IP)." >&2
        echo "       Подожди 30-60 минут и запусти установку снова — лимит сбросится." >&2
        echo "" >&2
        echo "    2. github.com режется DPI у твоего провайдера." >&2
        echo "       Решение — установка через VPN-канал:" >&2
        echo "         /opt/cheburnet/scripts/install-via-tether.sh" >&2
        echo "       (подробности — docs/install-blocked.md)" >&2
        echo "" >&2
        echo "  Полный лог:  cat /tmp/cheburnet/install.log" >&2
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
