#!/bin/sh
# 02-podkop.sh — установить podkop + sing-box и настроить UCI для режима
# «всё через VPN кроме RU-сервисов» (HOME по умолчанию).
set -e

# cheburnet-utils.sh — для cheburnet_apk_fail_advice (диагностика причины
# фейла apk-загрузки: DPI на имя пакета / общая проблема зеркала / временный
# сбой), используется в failure-сообщениях ниже.
LIB_DIR="${CHEBURNET_LIB_DIR:-/opt/cheburnet/lib}"
[ -f "$LIB_DIR/cheburnet-utils.sh" ] || LIB_DIR="$(dirname "$0")/../lib"
# shellcheck source=../lib/cheburnet-utils.sh disable=SC1090,SC1091
. "$LIB_DIR/cheburnet-utils.sh"

echo "== 02. Podkop + sing-box =="

# === 1. Установка через официальный скрипт ===
# Cascading fallback (vendor → upstream → retry с apk update → diag) вынесен
# в lib/install-podkop.sh, чтобы update_podkop RPC переиспользовал ту же
# логику. Здесь — ensure-режим: skip если уже стоит.
# shellcheck source=../lib/install-podkop.sh disable=SC1090,SC1091
. "$LIB_DIR/install-podkop.sh"
cheburnet_install_podkop ensure || exit 1

# === 2. UCI-конфигурация ===
echo "→ настраиваем podkop UCI"

# Подключаем оставшиеся хелперы. cheburnet-utils.sh уже подключён в шапке.
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

# === 2a. Bootstrap-кеш sing-box rule_sets из vendor ===
# Зачем. При DPI на github.com подkop не сможет скачать russia_outside.srs
# при первом старте sing-box → HOME-режим тихо ляжет (см. rulesets_health
# баннер в web-панели mgmt). Подкладываем pre-downloaded copy по тому пути
# и имени, что подkop генерирует в sing-box-конфиге:
# `<section>-<tag>-community-ruleset.srs`. См.
# itdoginfo/podkop:podkop/files/usr/bin/podkop::configure_community_list_handler
# и ::get_ruleset_tag в lib/rulesets.sh.
#
# Кеш в /tmp/ (RAM) — на reboot стирается, но после первой установки у
# юзера уже работает AmneziaWG, и sing-box обновит файл сам через свой
# update_interval (по умолчанию 1d).
VENDOR_RULESETS="${CHEBURNET_VENDOR:-/opt/cheburnet/vendor}/sing-box-rulesets"
RULESETS_DIR=/tmp/sing-box/rulesets
if [ -s "$VENDOR_RULESETS/russia_outside.srs" ]; then
    mkdir -p "$RULESETS_DIR"
    cp "$VENDOR_RULESETS/russia_outside.srs" \
       "$RULESETS_DIR/exclude_ru-russia_outside-community-ruleset.srs"
    echo "  ✓ bootstrap-кеш russia_outside.srs ($(wc -c < "$VENDOR_RULESETS/russia_outside.srs") B)"
fi

# === 3. Enable + start + ожидание готовности ===
# Раньше тут было `restart &` + `sleep 10`: на медленной железке sing-box не
# успевал стартовать, проверки ниже печатали ⚠ — а 07-killswitch потом
# активировал KillSwitch поверх неработающего sing-box. Юзер получал
# «нет интернета» при `done=ok` в логе. Теперь — синхронный restart и
# блокирующий poll до двух условий: процесс sing-box жив И nft-таблица
# PodkopTable создана. Без обоих идти в KillSwitch нельзя.
echo "→ enable + start podkop, жду готовности sing-box и PodkopTable..."
/etc/init.d/podkop enable
/etc/init.d/podkop restart >/dev/null 2>&1
_r=0
while [ "$_r" -lt 30 ]; do
    if pidof sing-box >/dev/null 2>&1 \
       && nft list table inet PodkopTable >/dev/null 2>&1; then
        break
    fi
    _r=$((_r + 1))
    sleep 1
done

if ! pidof sing-box >/dev/null 2>&1; then
    echo "✗ sing-box не запустился за 30 секунд." >&2
    echo "  Диагностика (последние 20 строк logread):" >&2
    logread -e sing-box 2>/dev/null | tail -20 >&2 || true
    echo "  Полный лог:  logread -e sing-box | tail -100" >&2
    exit 1
fi
if ! nft list table inet PodkopTable >/dev/null 2>&1; then
    echo "✗ Подkop не создал nft-таблицу PodkopTable за 30 секунд." >&2
    echo "  Без неё split-routing не работает — kill-switch заблокирует весь LAN." >&2
    echo "  Диагностика:  podkop check_nft_rules ; logread -e podkop | tail -40" >&2
    exit 1
fi
echo "✓ sing-box запущен, PodkopTable активна"

echo "✓ podkop OK"
