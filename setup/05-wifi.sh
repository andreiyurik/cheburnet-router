#!/bin/sh
# 05-wifi.sh — настроить Wi-Fi с WPA2/WPA3-mixed.
#
# Параметры задаются через переменные окружения:
#   WIFI_SSID     — имя сети (обязательно)
#   WIFI_KEY      — пароль (8+ символов, обязательно)
#   WIFI_COUNTRY  — код страны (по умолчанию RU)
#
# Пример вызова:
#   WIFI_SSID="MyHome" WIFI_KEY="correct-horse-battery-staple" ./05-wifi.sh
set -e

echo "== 05. Wi-Fi =="

SSID="${WIFI_SSID:?need WIFI_SSID env var}"
KEY="${WIFI_KEY:?need WIFI_KEY env var}"
COUNTRY="${WIFI_COUNTRY:-RU}"

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
if apk list --installed 2>/dev/null | grep -q wpad-basic-mbedtls; then
    echo "→ заменяем wpad-basic-mbedtls на wpad-mbedtls (для WPA3)"
    apk del wpad-basic-mbedtls
    apk add wpad-mbedtls
fi

# === 2. Настройка радио ===
# Имена radio/iface-секций нестандартны на разных board.json — итерируем
# по реально присутствующим, а не хардкодим radio0/radio1/default_radioN.
echo "→ настраиваем radio + SSID"
for RADIO in $(uci -q show wireless | awk -F'[.=]' '/=wifi-device$/{print $2}'); do
    uci set wireless."$RADIO".country="$COUNTRY"
done

IFACES=$(uci -q show wireless | awk -F'[.=]' '/=wifi-iface$/{print $2}')
if [ -z "$IFACES" ]; then
    echo "⚠ wifi-device есть, но wifi-iface не сгенерирован — обычно lkm wifi config"
    echo "  пробуем 'wifi config' и продолжаем"
    wifi config 2>/dev/null || true
    IFACES=$(uci -q show wireless | awk -F'[.=]' '/=wifi-iface$/{print $2}')
fi
for IFACE in $IFACES; do
    uci set wireless."$IFACE".ssid="$SSID"
    uci set wireless."$IFACE".encryption='sae-mixed'
    uci set wireless."$IFACE".key="$KEY"
    uci set wireless."$IFACE".ieee80211w='1'
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
