#!/bin/sh
# install-via-tether.sh — установка cheburnet через USB-tethering с телефона.
#
# Зачем: если провайдер блокирует загрузку конкретных .apk-пакетов
# (sing-box и т.п. — частая практика DPI у российских и некоторых других
# провайдеров), штатный setup.sh падает с «wget Failed to send request:
# Operation not permitted». Cheburnet сам ничего обойти не может, пока
# не установлен — это chicken-and-egg.
#
# Решение: на время установки взять интернет с телефона, на котором
# работает AmneziaVPN. Подключаем телефон USB-кабелем, роутер автоматически
# создаёт интерфейс usb0 — переключаем WAN на него, ставимся, возвращаем.
#
# Что делает скрипт:
#   1. Ищет usb0 (создаётся ядром при USB-tethering телефона).
#   2. Бекапит текущие network.wan.{device,proto} в /tmp/cheburnet/.
#   3. Переключает WAN на usb0 (DHCP), ждёт интернет.
#   4. Запускает /opt/cheburnet/setup/install.sh.
#   5. По завершении (успех ИЛИ ошибка ИЛИ Ctrl-C) — восстанавливает
#      исходные network.wan.{device,proto} через trap.
#
# Полная инструкция со скриншотами и troubleshooting — docs/install-blocked.md
set -e

STATE_DIR="/tmp/cheburnet"
mkdir -p "$STATE_DIR"
WAN_DEVICE_BAK="$STATE_DIR/wan-device.bak"
WAN_PROTO_BAK="$STATE_DIR/wan-proto.bak"

echo "────────────────────────────────────────────────────────────"
echo "  install-via-tether  —  установка через мобильный (AmneziaVPN)"
echo "────────────────────────────────────────────────────────────"
echo

# ── Шаг 1: Проверка предусловий ──
if [ ! -x /opt/cheburnet/setup/install.sh ]; then
    echo "✗ /opt/cheburnet/setup/install.sh не найден." >&2
    echo "  Сначала разверните репо cheburnet (./install.sh или setup.sh с ноутбука)." >&2
    exit 1
fi

# ── Шаг 2: Ищем USB-tethered интерфейс ──
echo "→ Ищу USB-tethered интерфейс (usb0)..."
_max_wait=30
_waited=0
_advice_printed=0
while [ "$_waited" -lt "$_max_wait" ]; do
    if ip link show usb0 >/dev/null 2>&1; then
        echo "  ✓ usb0 найден"
        break
    fi
    if [ "$_advice_printed" = "0" ]; then
        echo "  ⏳ usb0 ещё не появился. Проверьте:"
        echo "     • Телефон подключён к USB-порту роутера (не зарядки!)"
        echo "     • На телефоне включён USB-tethering"
        echo "         (Android: Настройки → Точка доступа → USB-модем)"
        echo "         (iOS: Личная точка доступа, потом подключите USB)"
        echo "     • Кабель USB поддерживает данные (не только зарядка)"
        echo "     • На телефоне опционально активен AmneziaVPN"
        echo "  Жду до ${_max_wait} сек..."
        _advice_printed=1
    fi
    sleep 2
    _waited=$((_waited + 2))
done
if ! ip link show usb0 >/dev/null 2>&1; then
    echo
    echo "✗ usb0 так и не появился за ${_max_wait} сек." >&2
    echo "  Возможные причины:" >&2
    echo "  • В OpenWrt не загружен USB-сетевой драйвер. Проверьте:" >&2
    echo "      lsmod | grep -E 'rndis_host|cdc_ether|cdc_ncm'" >&2
    echo "    Что обычно есть в стоковых образах OpenWrt 25.12+:" >&2
    echo "      cdc_ether/cdc_ncm  — часто есть (драйвер для iPhone tether)" >&2
    echo "      rndis_host         — обычно НЕТ (драйвер для Android tether)" >&2
    echo "    Если нужного драйвера нет — у вас chicken-and-egg: apk add" >&2
    echo "    тоже заблокирован провайдером. Варианты:" >&2
    echo "    1. Попробовать iPhone вместо Android (cdc_ether обычно встроен)." >&2
    echo "    2. Сделать sysupgrade-образ с kmod-usb-net-rndis заранее," >&2
    echo "       прошить, и повторить этот скрипт. См. firmware-selector.openwrt.org" >&2
    echo "       и docs/install-blocked.md." >&2
    echo "  • Телефон в неподходящем USB-режиме — отключите USB-tethering," >&2
    echo "    подождите 5 сек, включите снова." >&2
    echo "  • Кабель USB только для зарядки — попробуйте другой кабель." >&2
    exit 1
fi

# ── Шаг 3: Бэкап текущих настроек WAN ──
# Бекапим только две option'ы (device + proto), которые будем менять.
# Остальные (username/password для PPPoE и т.п.) — не трогаем, они остаются
# в /etc/config/network нетронутыми, при восстановлении proto они снова
# начнут учитываться.
WAN_DEVICE_ORIG=$(uci -q get network.wan.device 2>/dev/null || echo "")
WAN_PROTO_ORIG=$(uci -q get network.wan.proto 2>/dev/null || echo "")
printf '%s' "$WAN_DEVICE_ORIG" > "$WAN_DEVICE_BAK"
printf '%s' "$WAN_PROTO_ORIG"  > "$WAN_PROTO_BAK"
echo "→ Сохранил исходные WAN-настройки:"
echo "    device='$WAN_DEVICE_ORIG'  proto='$WAN_PROTO_ORIG'"

# ── Шаг 4: Trap-восстановление на ЛЮБОЙ выход ──
# Сделано до изменений UCI: если что-то пойдёт не так на следующих шагах,
# trap всё равно отработает и вернёт сеть в исходное состояние.
restore_wan() {
    _rc=$?
    echo
    echo "→ Восстанавливаю исходный WAN-конфиг..."
    if [ -f "$WAN_DEVICE_BAK" ]; then
        _d=$(cat "$WAN_DEVICE_BAK")
        if [ -n "$_d" ]; then
            uci set network.wan.device="$_d"
        else
            uci -q delete network.wan.device || true
        fi
    fi
    if [ -f "$WAN_PROTO_BAK" ]; then
        _p=$(cat "$WAN_PROTO_BAK")
        if [ -n "$_p" ]; then
            uci set network.wan.proto="$_p"
        else
            uci -q delete network.wan.proto || true
        fi
    fi
    uci commit network 2>/dev/null || true
    /etc/init.d/network reload >/dev/null 2>&1 || true
    rm -f "$WAN_DEVICE_BAK" "$WAN_PROTO_BAK"
    echo "  ✓ Исходный WAN восстановлен (device='${_d:-<unset>}', proto='${_p:-<unset>}')"
    return "$_rc"
}
trap restore_wan EXIT INT TERM

# ── Шаг 5: Переключение WAN на usb0 ──
echo "→ Переключаю WAN на usb0 (DHCP)"
uci set network.wan.device='usb0'
uci set network.wan.proto='dhcp'
uci commit network
/etc/init.d/network restart >/dev/null 2>&1 || true

# ── Шаг 6: Ждём интернет через usb0 ──
echo "→ Жду интернет через usb0 (до 30 сек)..."
_net_ok=0
for _try in 1 2 3 4 5 6; do
    sleep 5
    if wget -q --spider --timeout=5 http://downloads.openwrt.org/ 2>/dev/null; then
        _net_ok=1
        echo "  ✓ Интернет работает через телефон"
        break
    fi
    echo "  ожидание... (${_try}/6)"
done
if [ "$_net_ok" = "0" ]; then
    echo
    echo "✗ Не могу достучаться до downloads.openwrt.org через usb0." >&2
    echo "  Проверьте на телефоне:" >&2
    echo "  • Мобильный интернет включён и работает" >&2
    echo "  • USB-tethering активен (иконка в системной строке)" >&2
    echo "  • AmneziaVPN, если включён, реально подключён" >&2
    echo "  Trap восстановит исходный WAN — выходим." >&2
    exit 1
fi

# ── Шаг 7: Запускаем install.sh ──
echo
echo "────────────────────────────────────────────────────────────"
echo "  Запускаю /opt/cheburnet/setup/install.sh через мобильный"
echo "────────────────────────────────────────────────────────────"
echo
# Временно снимаем set -e, чтобы наш trap отработал на любом коде выхода.
set +e
/opt/cheburnet/setup/install.sh
_install_rc=$?
set -e

echo
echo "────────────────────────────────────────────────────────────"
if [ "$_install_rc" -eq 0 ]; then
    echo "  ✓ Установка завершилась успешно"
else
    echo "  ⚠ Установка завершилась с кодом $_install_rc"
    echo "  (см. /tmp/cheburnet/install.log для деталей)"
fi
echo "  WAN сейчас будет восстановлен на исходные настройки."
echo "────────────────────────────────────────────────────────────"

# trap restore_wan отработает на этом exit.
exit "$_install_rc"
