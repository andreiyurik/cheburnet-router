#!/bin/sh
# 05-wifi.sh — настроить Wi-Fi с WPA2/WPA3-mixed.
#
# Параметры задаются через переменные окружения:
#   WIFI_SSID  — имя сети (обязательно)
#   WIFI_KEY   — пароль (8+ символов, обязательно)
#
# Пример вызова:
#   WIFI_SSID="MyHome" WIFI_KEY="correct-horse-battery-staple" ./05-wifi.sh
set -e

echo "== 05. Wi-Fi =="

SSID="${WIFI_SSID:?need WIFI_SSID env var}"
KEY="${WIFI_KEY:?need WIFI_KEY env var}"

# Пароль должен быть >= 8 символов
[ ${#KEY} -ge 8 ] || { echo "ERROR: WIFI_KEY must be >= 8 chars"; exit 1; }

# === 0. Есть ли вообще беспроводное железо? ===
# x86, mini-PC и часть SBC-роутеров идут без Wi-Fi-чипа; на чипах без
# поддерживаемого драйвера /etc/config/wireless либо отсутствует, либо
# не содержит wifi-device-секций. Это валидный кейс — устанавливаем
# роутер как проводной и идём дальше, не валим установку.
if [ ! -f /etc/config/wireless ] || ! uci -q show wireless 2>/dev/null | grep -q '=wifi-device'; then
    echo "→ /etc/config/wireless без wifi-device — у этого роутера нет Wi-Fi"
    echo "  пропускаю настройку Wi-Fi (роутер будет работать как проводной)"
    echo "✓ Wi-Fi step skipped (no wireless hardware)"
    exit 0
fi

# === 1. Заменить wpad-basic-mbedtls на wpad-mbedtls (для SAE) ===
# OpenWrt 25.12 поставляет wpad-basic-mbedtls по умолчанию (WPA2 only).
# WPA3 SAE требует полный wpad-mbedtls. На 25.12+ apk видит их как
# взаимоисключающие — `apk add wpad-mbedtls` при установленном basic
# падает с conflict-сообщением, ничего не удаляет, basic остаётся жив.
#
# Идём по убыванию предпочтительности; первый успех — берём:
#   1) mbedtls уже стоит
#   2) можем поставить mbedtls (на свежем без wpad-basic)
#   3) basic уже стоит (apk отказал mbedtls из-за conflict — fine, WPA2 OK)
#   4) можем поставить basic (на каком-то экзотичном железе совсем без wpad)
#   5) ничего не получилось — Wi-Fi не работает, hard-fail
WPAD_FLAVOR=""
INSTALLED=$(apk list --installed 2>/dev/null)
if printf '%s' "$INSTALLED" | grep -q '^wpad-mbedtls-'; then
    WPAD_FLAVOR=mbedtls
elif apk add wpad-mbedtls 2>&1; then
    WPAD_FLAVOR=mbedtls
elif printf '%s' "$INSTALLED" | grep -q '^wpad-basic-mbedtls-'; then
    echo "  ⚠ wpad-mbedtls install отказан (обычно conflict с basic) — остаюсь на wpad-basic-mbedtls (WPA2)"
    WPAD_FLAVOR=basic
elif apk add wpad-basic-mbedtls 2>&1; then
    WPAD_FLAVOR=basic
else
    echo "✗ wpad не удалось установить — Wi-Fi работать не сможет." >&2
    exit 1
fi

# Выбор шифрования: sae-mixed требует полный wpad-mbedtls.
# На basic-mbedtls hostapd с sae-mixed просто не запустится — откатываемся на WPA2.
case "$WPAD_FLAVOR" in
    mbedtls) ENCRYPTION="sae-mixed"; PMF="1" ;;
    basic)   ENCRYPTION="psk2+ccmp"; PMF="" ;;
    *)       ENCRYPTION="psk2+ccmp"; PMF="" ;;
esac
echo "→ wpad=${WPAD_FLAVOR}, encryption=${ENCRYPTION}"

# === 2. Настройка радио ===
# Имена radio/iface-секций нестандартны на разных board.json — итерируем
# по реально присутствующим, а не хардкодим radio0/radio1/default_radioN.
echo "→ настраиваем radio + SSID"
IFACES=$(uci -q show wireless | awk -F'[.=]' '/=wifi-iface$/{print $2}')
if [ -z "$IFACES" ]; then
    echo "⚠ wifi-device есть, но wifi-iface не сгенерирован — обычно lkm wifi config"
    echo "  пробуем 'wifi config' и продолжаем"
    wifi config 2>/dev/null || true
    IFACES=$(uci -q show wireless | awk -F'[.=]' '/=wifi-iface$/{print $2}')
fi
for IFACE in $IFACES; do
    uci set wireless."$IFACE".ssid="$SSID"
    uci set wireless."$IFACE".encryption="$ENCRYPTION"
    uci set wireless."$IFACE".key="$KEY"
    if [ -n "$PMF" ]; then
        uci set wireless."$IFACE".ieee80211w="$PMF"
    else
        # PMF имеет смысл только при SAE; на чистом WPA2 он скорее ломает
        # совместимость со старыми клиентами (телефонами/IoT), чем помогает.
        # `-q` подавляет вывод, НО на отсутствующем ключе uci всё равно
        # exit 1 → `set -e` убивает шаг 05 до wifi reload, и пользователь
        # остаётся с дефолтным `ssid='OpenWrt' disabled='1'`. Поймано T4
        # на vanilla 25.12.2: default_radio0/1 не имеют ieee80211w.
        uci -q delete wireless."$IFACE".ieee80211w 2>/dev/null || true
    fi
    uci set wireless."$IFACE".disabled='0'
done

uci commit wireless

# === 3. Применить ===
wifi reload
sleep 5

# === 4. Проверка ===
if iw dev 2>/dev/null | grep -q "ssid $SSID"; then
    echo "✓ Wi-Fi поднят, SSID='$SSID'"
    iw dev 2>/dev/null | grep -E "Interface|ssid|channel" | head -8
else
    echo "⚠ Wi-Fi не видится — logread | grep hostapd"
fi

echo "✓ Wi-Fi OK"
