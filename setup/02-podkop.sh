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
    # Вывод сохраняем — нужен для детекции «Insufficient space in flash»
    # и других permanent-ошибок, по которым повторять бессмысленно.
    INSTALLER_LOG=/tmp/podkop-installer.log
    yes n | sh /tmp/podkop-install.sh >"$INSTALLER_LOG" 2>&1
    tail -20 "$INSTALLER_LOG"

    # Permanent-фейл: апстрим-установщик сам проверяет flash и пишет
    # «Insufficient space in flash, Required: 15MB, Available: 5MB».
    # Повтор не поможет — это аппаратное ограничение. Раньше скрипт
    # пытался дважды и финальное сообщение врало юзеру про «временный
    # сбой зеркал». Жёсткий preflight в setup/install.sh обычно ловит
    # это раньше, но оставляем defense-in-depth (юзер мог запустить
    # 02-podkop.sh напрямую, или порог preflight'а отличается).
    if grep -q 'Insufficient space in flash' "$INSTALLER_LOG"; then
        echo "" >&2
        echo "✗ Подкоп не помещается в flash-память роутера." >&2
        echo "  Это аппаратное ограничение — программно не обойти." >&2
        echo "  Нужен роутер с ≥64 МБ flash (см. README, проверенные модели)." >&2
        exit 1
    fi

    # Установщик подкопа сам внутри делает apk update + apk add. Изредка
    # падает на транзиентных проблемах с зеркалами OpenWrt
    # (wget "Operation not permitted", "unexpected end of file", битый
    # индекс). Один повтор после apk update закрывает 90% таких случаев
    # без вмешательства пользователя. Дальше идти бессмысленно — UCI-конфиг
    # подкопа применять некуда.
    if [ ! -x /etc/init.d/podkop ]; then
        echo "  установщик подкопа не оставил /etc/init.d/podkop, обновляю индексы и повторяю..."
        apk update >/dev/null 2>&1 || true
        yes n | sh /tmp/podkop-install.sh >"$INSTALLER_LOG" 2>&1
        tail -20 "$INSTALLER_LOG"
        if grep -q 'Insufficient space in flash' "$INSTALLER_LOG"; then
            echo "" >&2
            echo "✗ Подкоп не помещается в flash-память роутера." >&2
            echo "  Нужен роутер с ≥64 МБ flash (см. README)." >&2
            exit 1
        fi
    fi
    if [ ! -x /etc/init.d/podkop ]; then
        echo "✗ Установщик podkop отработал дважды, но /etc/init.d/podkop не появился." >&2
        # Диагностика — выяснит, что блокируется: зеркало, IPv6 или имя пакета.
        command -v cheburnet_apk_fail_advice >/dev/null 2>&1 \
            && cheburnet_apk_fail_advice podkop
        exit 1
    fi

    # КРИТИЧНО: sing-box — обязательная зависимость подкопа. Если её
    # установка свалилась на сети («wget: Operation not permitted»,
    # «unexpected end of file»), /etc/init.d/podkop появляется, а
    # /etc/init.d/sing-box — нет. Без sing-box подкоп не маршрутизирует
    # ничего, и установка должна остановиться, а не идти дальше с тихим ⚠.
    # Раньше эта проверка была warning'ом на шаге 4 и шаг печатал «✓ podkop OK»,
    # хотя по факту юзер получал нерабочий VPN.
    if [ ! -x /etc/init.d/sing-box ]; then
        echo "" >&2
        echo "✗ sing-box не установлен после установщика подкопа." >&2
        echo "  Это критично — без sing-box подкоп не маршрутизирует ничего." >&2
        # Диагностика — sing-box известный таргет DPI у части провайдеров.
        # Лог юзера 1 показал ровно это: sing-box падает, остальные пакеты
        # из той же транзакции — нет. Диагностика подтвердит/опровергнет.
        command -v cheburnet_apk_fail_advice >/dev/null 2>&1 \
            && cheburnet_apk_fail_advice sing-box
        exit 1
    fi
fi

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
