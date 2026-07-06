#!/bin/sh
# 00-prerequisites.sh — обновить пакетный индекс, установить базовые инструменты.
# Рассчитан на OpenWrt 25.12+ с apk.
set -e

echo "== 00. Prerequisites =="

# Преflight: apk = маркер OpenWrt 25.12+. На 24.x и старше пакетный
# менеджер opkg, наши скрипты везде пишут apk add/update — без него
# падение неизбежно, и без preflight'а оно случится в неочевидном
# месте с маловнятным сообщением. Лучше отказать сразу и громко.
if ! command -v apk >/dev/null 2>&1; then
    echo "✗ Команда apk не найдена — этот скрипт требует OpenWrt 25.12.0+." >&2
    echo "  Ваша прошивка использует устаревший opkg (OpenWrt 24.x или ниже)." >&2
    echo "  Перепрошейте роутер по docs/00-flash-openwrt.md и повторите запуск." >&2
    exit 1
fi

# Bootstrap (install.sh при web-пути) сам делает apk update до запуска
# setup/install.sh. Если он успел свежо — повторный вызов лишний и второй
# раз даёт DPI у провайдера шанс сломать установку на том же месте.
# Sentinel /tmp/cheburnet/apk-update-fresh выставляется bootstrap'ом; TTL
# 30 минут — это окно «юзер заполняет форму в браузере» с запасом.
# На CLI-пути bootstrap не запускается → файла нет → код идёт обычной веткой.
FRESH_SENTINEL=/tmp/cheburnet/apk-update-fresh
if [ -n "$(find "$FRESH_SENTINEL" -mmin -30 2>/dev/null)" ]; then
    echo "→ apk update: индексы свежие (bootstrap обновил <30 мин назад) — пропускаю"
    rm -f "$FRESH_SENTINEL"
    APK_UPDATE_SKIPPED=1
fi

# Обновляем списки пакетов (если не пропустили выше).
# apk update изредка падает с "Operation not permitted" / "unexpected end
# of file" из-за временной недоступности одного из зеркал OpenWrt — даже
# когда стейл всего один индекс из 8, apk возвращает ошибку. Один повтор
# закрывает большинство таких транзиентных сбоев без вмешательства
# пользователя.
#
# Если оба прогона не прошли — это устойчивый DPI-блок downloads.openwrt.org
# у RU-провайдера. Без `apk add` дальше ставить нечего → exit с подробной
# инструкцией. На этой точке /opt/cheburnet уже развёрнут, поэтому можем
# ссылаться на локальный скрипт-помощник install-via-tether.sh.
if [ -z "${APK_UPDATE_SKIPPED:-}" ]; then
    # Стейл-sentinel убираем, если он есть, но просрочен — не хотим, чтобы
    # следующий запуск (например, retry установки через час) ложно срабатывал.
    rm -f "$FRESH_SENTINEL"
    echo "→ apk update"
    if ! apk update; then
        echo "  apk update упал на одном из зеркал, повторяю..."
        if ! apk update; then
            # Перед вердиктом «провайдер режет» проверяем что именно отвалилось.
            # Логика та же что в install.sh:194+ (bootstrap step [2/8]) — дублируем
            # потому что install.sh может вообще не запускаться (CLI-путь), и
            # хочется честный диагноз на обоих путях. lib/ нельзя — мы хотим
            # одинаковое поведение даже когда репо повреждён или lib отсутствует.
            echo
            echo "  ── Диагностика (~20с) ───────────────────────────────────"

            PING_OK=0; DNS_OK=0; GH_OK=0; OPENWRT_OK=0

            if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
                echo "  ✓ ping 8.8.8.8 — общий интернет работает"
                PING_OK=1
            else
                echo "  ✗ ping 8.8.8.8 — НЕ проходит (WAN отвалился?)"
            fi

            if nslookup downloads.openwrt.org >/dev/null 2>&1; then
                echo "  ✓ DNS резолвит downloads.openwrt.org"
                DNS_OK=1
            else
                echo "  ✗ DNS не резолвит downloads.openwrt.org"
            fi

            if wget -qO /dev/null --timeout=8 \
                https://raw.githubusercontent.com/andreiyurik/cheburnet-router/master/install.sh \
                2>/dev/null; then
                echo "  ✓ raw.githubusercontent.com доступен"
                GH_OK=1
            else
                echo "  ✗ raw.githubusercontent.com тоже недоступен"
            fi

            # Версию OpenWrt берём из /etc/openwrt_release. Файл точно есть —
            # apk-preflight выше уже валится если это не OpenWrt 25.12+.
            DISTRIB_RELEASE=""
            . /etc/openwrt_release 2>/dev/null || true
            OPENWRT_PROBE_URL="https://downloads.openwrt.org/releases/${DISTRIB_RELEASE:-25.12.2}/SHA256SUMS"
            # КРИТИЧНО: `var=$(cmd)` под `set -e` в busybox ash убивает скрипт,
            # если cmd возвращает non-zero. А wget тут как раз и должен упасть —
            # это нормальная ветка (DPI). Оборачиваем в `|| OPENWRT_RC=$?`:
            # это conditional-context, set -e не применяется, rc корректно ловится.
            # Без этого скрипт молча умирал прямо на тесте 4 и вердикт не печатался.
            OPENWRT_ERR=""
            OPENWRT_RC=0
            OPENWRT_ERR=$(wget -qO /dev/null --timeout=8 "$OPENWRT_PROBE_URL" 2>&1) \
                || OPENWRT_RC=$?
            if [ "$OPENWRT_RC" = "0" ]; then
                echo "  ? wget downloads.openwrt.org прошёл СЕЙЧАС (apk упал — транзиент?)"
                OPENWRT_OK=1
            else
                # Любая ненулевая RC (DPI-сигнатуры или другие сетевые ошибки) → не OK.
                # Вердикт ниже не различает их: else-ветка покрывает оба случая
                # рекомендацией VPN-обхода, разделение тут лишний шум.
                echo "  ✗ wget downloads.openwrt.org: $OPENWRT_ERR"
            fi

            echo
            echo "  ── Вердикт ──────────────────────────────────────────────"
            echo

            # Порядок классификации: WAN → DNS → транзиент → DPI. Самые
            # «земные» причины исключаем первыми, рекомендация VPN-обхода —
            # только когда он действительно показан.
            if [ "$PING_OK" = "0" ]; then
                echo "  ✗ Интернет на роутере отвалился"
                echo
                echo "  ping 8.8.8.8 не проходит — это не DPI, а отсутствие интернета."
                echo "  Проверь:"
                echo "    • WAN-кабель воткнут в роутер и в провайдера/домашний роутер"
                echo "    • Другие устройства в этой сети работают?"
                echo "    • Перезагрузи роутер: reboot"
                echo
                echo "  После починки перезапусти установку:"
                echo "    /opt/cheburnet/setup/install.sh"
                echo
            elif [ "$DNS_OK" = "0" ]; then
                echo "  ✗ Сломался DNS"
                echo
                echo "  Интернет есть (ping проходит), но имена не резолвятся."
                echo "  Попробуй:"
                echo "    /etc/init.d/dnsmasq restart"
                echo "  Если не помогло — указать публичный DNS вручную:"
                echo "    uci add_list network.wan.dns='8.8.8.8'"
                echo "    uci commit network && /etc/init.d/network restart"
                echo
            elif [ "$OPENWRT_OK" = "1" ]; then
                echo "  ⚠ Транзиентный сбой — попробуй ещё раз"
                echo
                echo "  apk update упал дважды, но сейчас прямой wget на"
                echo "  downloads.openwrt.org прошёл. Скорее всего зеркало"
                echo "  отдавало байты слишком медленно — apk выпал по таймауту,"
                echo "  но содержимое доступно."
                echo
                echo "  Перезапусти установку:"
                echo "    /opt/cheburnet/setup/install.sh"
                echo
            else
                # PING ok, DNS ok, downloads.openwrt.org режется — DPI подтверждён.
                echo "════════════════════════════════════════════════════════════"
                echo "  Загрузка пакетов заблокирована провайдером (подтверждено)"
                echo "════════════════════════════════════════════════════════════"
                echo
                if [ "$GH_OK" = "1" ]; then
                    echo "  Диагностика показывает: общий интернет работает, DNS отвечает,"
                    echo "  GitHub открывается, но конкретно downloads.openwrt.org режется."
                    echo "  Это SNI-DPI у твоего провайдера, не баг cheburnet'а."
                else
                    echo "  Диагностика показывает: общий интернет работает, DNS отвечает,"
                    echo "  но и downloads.openwrt.org, и GitHub режутся. Очень агрессивный"
                    echo "  DPI или ты в публичной сети с captive portal."
                fi
                echo
                echo "  После установки cheburnet сам уйдёт под VPN — проблема исчезнет."
                echo
                echo "  Два варианта — выбери по своему роутеру:"
                echo
                echo "  ─── Вариант A: на роутере ЕСТЬ USB-порт → через смартфон ───"
                echo
                echo "    1. На телефоне: AmneziaVPN включён, USB-tethering включён."
                echo "    2. Воткни USB-кабель в роутер, подожди 15-30 секунд."
                echo "    3. Запусти автоматический скрипт на роутере:"
                echo "         /opt/cheburnet/scripts/install-via-tether.sh"
                echo "       Он сам переключит WAN, поставит cheburnet, и вернёт WAN."
                echo
                echo "  ─── Вариант B: USB на роутере НЕТ → через ноутбук ──────────"
                echo
                echo "    Может потребоваться переходник USB-Ethernet на ноут (~\$8),"
                echo "    если на ноуте нет встроенного Ethernet."
                echo
                echo "    1. На ноутбуке: AmneziaVPN включён."
                echo "    2. На ноутбуке Internet Sharing на Ethernet-порт"
                echo "       (macOS: Settings → Sharing → Internet Sharing;"
                echo "        Windows: AmneziaVPN-адаптер → Properties → Sharing;"
                echo "        Linux: Network → Ethernet → IPv4: Shared)."
                echo "    3. Переткни WAN-кабель cheburnet'а в ноут. Подожди 15 сек."
                echo "    4. Перезапусти установку: /opt/cheburnet/setup/install.sh"
                echo "    5. После установки — кабель обратно в домашний роутер."
                echo
                echo "  Подробная инструкция (шаги, troubleshooting):"
                echo "    cat /opt/cheburnet/docs/install-blocked.md"
                echo
                echo "  Помощь: @industrialprofi в Telegram."
                echo
            fi
            exit 1
        fi
    fi
fi

# Базовые инструменты, нужные дальше
# - jq для разбора JSON (sing-box config, clash-api)
# - curl для тестов и скачиваний
# - coreutils-sort для adblock-lean (ускоряет обработку списков)
# - ca-bundle для TLS
echo "→ install base tools"
apk add --no-interactive jq ca-bundle coreutils-sort 2>&1 | tail -3 || true

# Disable unused services (уменьшаем attack surface)
if [ -f /etc/init.d/radius ]; then
    /etc/init.d/radius disable 2>/dev/null || true
    echo "→ disabled unused service: radius"
fi

echo "✓ prerequisites OK"
