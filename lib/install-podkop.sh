# lib/install-podkop.sh — установка/переустановка podkop в одном месте.
#
# Source-only: ничего не выполняет, только определяет cheburnet_install_podkop.
# Без shebang. POSIX sh + busybox-ash.
#
# Подключение:
#   . /opt/cheburnet/lib/install-podkop.sh    # на роутере
#   . lib/install-podkop.sh                    # из репо-чекаута
#
# Зачем выделили в lib. Двое зовут одну и ту же установочную процедуру:
#   1) setup/02-podkop.sh — первая установка во flow setup/install.sh.
#   2) web/rpcd-cheburnet::update_podkop — RPC для апгрейда устаревших
#      инсталляций. Старые установки имели подkop с битым upstream URL
#      (raw.githubusercontent.com → 404), HOME-режим тихо умирал. Юзер
#      из web-панели кликает «Обновить podkop» → этот RPC переустанавливает
#      подkop, сохраняя текущий HOME/TRAVEL.
#
# Раньше cascading fallback (vendor → upstream → retry → diag) жил только в
# 02-podkop.sh. Дублировать его в update_podkop = двойная поддержка, и через
# год гарантированный рассинхрон (был такой прецедент с UCI-логикой подkop'а
# до выделения lib/podkop-config.sh). Поэтому extract.

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_install_podkop
# ─────────────────────────────────────────────────────────────────────────────
#
# Идемпотентная установка подkop (skip если уже установлен), либо принудительная
# переустановка через apk del.
#
# Аргумент: $1 — режим
#   "ensure"      (default) — если /etc/init.d/podkop уже есть, skip установки.
#                  Используется в setup/02-podkop.sh: первая установка или
#                  повторный запуск install.sh после ручной правки.
#   "force"                  — apk del podkop sing-box, затем поставить заново.
#                  Используется в update_podkop RPC для апгрейда устаревших
#                  инсталляций (старый URL .srs-ов был raw.githubusercontent.com,
#                  сейчас upstream сменил на releases/latest/download).
#
# Зависимости (должны быть в окружении):
#   - cheburnet_apk_fail_advice из lib/cheburnet-utils.sh — диагностика
#     causal-чейна (DPI на имя пакета vs. сбой зеркала).
#   - $CHEBURNET_VENDOR (опционально) — путь до vendored snapshot'ов
#     (по умолчанию /opt/cheburnet/vendor).
#
# Print: прогресс в stdout (так же как 02-podkop.sh), error в stderr.
# Return: 0 — успех (есть /etc/init.d/podkop И /etc/init.d/sing-box),
#         1 — фатально (flash, DPI на оба источника, sing-box не приехал).
cheburnet_install_podkop() {
    _mode="${1:-ensure}"

    case "$_mode" in
        ensure)
            if [ -x /etc/init.d/podkop ]; then
                echo "→ podkop уже установлен"
                unset _mode
                return 0
            fi
            ;;
        force)
            # Останавливаем сервис до apk del, иначе апдейтер пакетов может
            # упереться в «file busy» при перезаписи бинарей sing-box.
            if [ -x /etc/init.d/podkop ]; then
                echo "→ останавливаю podkop перед переустановкой"
                /etc/init.d/podkop stop >/dev/null 2>&1 || true
            fi
            echo "→ apk del podkop sing-box (force-reinstall)"
            # Сначала apk (OpenWrt 25.12+), потом opkg fallback (если кто-то
            # ставил наш стенд поверх старой 24.10-сборки и подkop приехал
            # opkg-пакетом). 2>/dev/null — apk шумит про conf-файлы; нам важен
            # exit-код, а не вывод.
            apk del podkop sing-box >/dev/null 2>&1 \
                || opkg remove podkop sing-box >/dev/null 2>&1 \
                || true
            ;;
        *)
            echo "✗ cheburnet_install_podkop: неизвестный режим '$_mode' (ensure|force)" >&2
            unset _mode
            return 1
            ;;
    esac

    UPSTREAM_URL="https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"
    VENDOR_FILE="${CHEBURNET_VENDOR:-/opt/cheburnet/vendor}/podkop-install.sh"

    # Сначала пробуем upstream (свежая версия), потом fallback на vendored-копию.
    # raw.githubusercontent.com периодически блокируют провайдеры по DPI —
    # без vendor-копии пользователь без VPN никогда сюда не доберётся.
    echo "→ скачиваю установщик podkop"
    if wget -qO /tmp/podkop-install.sh --timeout=20 "$UPSTREAM_URL" 2>/dev/null && \
       [ -s /tmp/podkop-install.sh ]; then
        echo "  ✓ скачан свежий установщик с upstream"
    elif [ -f "$VENDOR_FILE" ]; then
        # ⚠ → →: для RU-юзера это основной путь (raw.githubusercontent.com
        # массово закрыт DPI у провайдеров по SNI). Текст «недоступен» юзер
        # читал как поломку — поэтому переформулировка с «это норма».
        echo "  → беру установщик podkop из репозитория"
        echo "    (свежий с github.com не качается — это норма в некоторых странах, не ошибка)"
        cp "$VENDOR_FILE" /tmp/podkop-install.sh
    else
        echo "✗ Не удалось получить podkop installer ни с upstream, ни локально." >&2
        echo "  Проверьте: wget $UPSTREAM_URL" >&2
        unset _mode
        return 1
    fi

    # `yes n` шлёт бесконечный поток "n" — устойчиво к любому числу y/n-вопросов
    # подкоповского установщика (раньше было `printf 'n\nn\nn\n'` — хрупко,
    # ломалось бы если itdoginfo добавил четвёртый вопрос).
    # Вывод сохраняем — нужен для детекции «Insufficient space in flash»
    # и других permanent-ошибок, по которым повторять бессмысленно.
    INSTALLER_LOG=/tmp/podkop-installer.log
    # Установщик пишет в файл (нужен для grep по Insufficient space ниже),
    # за ~30-90с apk update + download юзер ничего не видит. В Web-UI это
    # читается как «зависло» — поэтому head-up строка о том, что идёт работа.
    echo "  → ставлю пакеты (sing-box + kmod-tproxy + podkop, ~30-90с)..."
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
        unset _mode
        return 1
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
            unset _mode
            return 1
        fi
    fi
    if [ ! -x /etc/init.d/podkop ]; then
        echo "✗ Установщик podkop отработал дважды, но /etc/init.d/podkop не появился." >&2
        # Диагностика — выяснит, что блокируется: зеркало, IPv6 или имя пакета.
        command -v cheburnet_apk_fail_advice >/dev/null 2>&1 \
            && cheburnet_apk_fail_advice podkop
        unset _mode
        return 1
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
        unset _mode
        return 1
    fi

    unset _mode
    return 0
}
