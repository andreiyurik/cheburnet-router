# lib/install-awg.sh — установка пакетов AmneziaWG (kmod + tools + luci-proto).
#
# Source-only: ничего не выполняет, только определяет install_awg_packages.
#
# В отличие от lib/cheburnet-utils.sh, эта функция имеет ЯВНЫЕ side-effects:
# скачивает .apk-файлы, делает `apk add`, грузит kernel-модуль. Поэтому она
# живёт отдельно от pure-функций — контракт cheburnet-utils.sh «без
# side-effects» (см. его шапку) ради этой одной функции ломать нельзя.
#
# Подключение (вызывающий должен предварительно загрузить cheburnet-utils.sh
# ради awg_pick_version и cheburnet_apk_fail_advice):
#   . /opt/cheburnet/lib/cheburnet-utils.sh
#   . /opt/cheburnet/lib/install-awg.sh
#   install_awg_packages
#
# Используется в setup/01-amneziawg.sh (первичная установка) и
# setup/post-upgrade.sh (восстановление после sysupgrade). Раньше эти два
# места содержали почти идентичные блоки скачивания/установки, но без общего
# retry/wait-for-network — post-upgrade падал на flaky-сети там, где
# 01-amneziawg.sh переживал транзиентные сбои.

# install_awg_packages
# Идемпотентно ставит AmneziaWG. Возвращает:
#   0 — kmod загружен (либо был загружен с прошлого запуска).
#   1 — фейл (диагностика — на stderr, человекочитаемая).
# Сам читает /etc/openwrt_release и зовёт awg_pick_version из cheburnet-utils.sh.
# Caller с set -e получит немедленный выход при return 1 — это и нужно.
install_awg_packages() {
    # 1. Идемпотентность — kmod уже загружен, второй раз не ставим.
    if lsmod | grep -q '^amneziawg '; then
        echo "→ amneziawg уже установлен, пропускаю установку"
        return 0
    fi

    echo "→ скачиваем и ставим kmod-amneziawg + tools"

    # 2. Автодетект архитектуры пакетов awg-openwrt:
    # Формат тэга = ${DISTRIB_ARCH}_${DISTRIB_TARGET с / → _}
    # Пример: aarch64_cortex-a53 + mediatek/filogic → aarch64_cortex-a53_mediatek_filogic
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    if [ -z "${DISTRIB_ARCH:-}" ] || [ -z "${DISTRIB_TARGET:-}" ] || [ -z "${DISTRIB_RELEASE:-}" ]; then
        echo "✗ Не удалось определить архитектуру/версию роутера." >&2
        echo "  Проверьте: cat /etc/openwrt_release" >&2
        return 1
    fi
    _arch="${DISTRIB_ARCH}_$(echo "$DISTRIB_TARGET" | tr '/' '_')"
    _release="$DISTRIB_RELEASE"

    # 3. Ждём готовности сети — awg_pick_version ниже идёт на github
    # (HEAD-запрос на .apk + GitHub API за latest-тегом). Если WAN ещё не
    # приехал (после reboot DHCP занимает 15-30 сек), wget не разрезолвит
    # хост, функция вернёт пусто, и юзер увидит ложное «нет совместимого
    # релиза» вместо честного «сеть не готова». Эта же проверка нужна и в
    # post-upgrade.sh — после sysupgrade сеть тоже поднимается не сразу.
    # Ждём до 60 сек: nameserver в resolv.conf + ping до 8.8.8.8.
    echo "→ ожидаем готовности сети перед скачиванием..."
    _net_ready=0
    for _w in 1 2 3 4 5 6 7 8 9 10 11 12; do
        # ping ИЛИ wget-spider: ICMP режется в части сетей (корпоративные wifi,
        # некоторые мобильные APN, qemu user-mode netdev), но HTTP к OpenWrt-
        # зеркалам в них всё равно работает — это ровно тот канал, по которому
        # пойдёт apk add ниже. Та же логика — в lib/cheburnet-preflight.sh.
        if grep -q '^nameserver' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null \
           && { ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 \
                || wget -q --spider --timeout=5 http://downloads.openwrt.org/ 2>/dev/null; }; then
            _net_ready=1
            break
        fi
        echo "  ожидание сети... (${_w}/12, по 5 сек)"
        sleep 5
    done
    if [ "$_net_ready" = "0" ]; then
        echo "✗ Нет доступа к интернету через 60 сек." >&2
        echo "  Возможные причины:" >&2
        echo "  • WAN-кабель не подключён или провайдер не даёт DHCP" >&2
        echo "  • IPv6-only WAN без IPv4 (проверьте настройки провайдера)" >&2
        echo "  Диагностика:" >&2
        ip route 2>&1 >&2 || true
        cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null >&2 || echo "  (resolv.conf пустой)" >&2
        return 1
    fi
    echo "  ✓ сеть готова"

    # 4. Выбор версии awg-openwrt. См. cheburnet-utils.sh:awg_pick_version
    # — preferred (DISTRIB_RELEASE) → latest по GitHub API → fail.
    _awg_ver="$(awg_pick_version "$_release" "$_arch")" || _awg_ver=""
    if [ -z "$_awg_ver" ]; then
        echo "✗ Нет совместимого релиза awg-openwrt для OpenWrt ${_release} / ${_arch}." >&2
        echo "  Доступные релизы: https://github.com/Slava-Shchipunov/awg-openwrt/releases" >&2
        echo "  Если вашей архитектуры нет — соберите пакет вручную по инструкции из репозитория." >&2
        return 1
    fi
    echo "  arch=${_arch}, awg-openwrt=v${_awg_ver}"

    _base="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${_awg_ver}"

    mkdir -p /etc/amnezia/amneziawg
    cd /tmp || { echo "✗ cd /tmp failed" >&2; return 1; }
    for _pkg in "kmod-amneziawg_v${_awg_ver}" "amneziawg-tools_v${_awg_ver}" "luci-proto-amneziawg_v${_awg_ver}"; do
        _file="${_pkg}_${_arch}.apk"
        # Один промах wget на GitHub releases CDN (release-assets.github*.com)
        # = установка целиком падает у юзера. 3 попытки с backoff закрывают
        # 99% транзиентных сбоев: DPI throttle, временный timeout, TCP RST
        # после редиректа на blob.core.windows.net. Поймано T4 на alt-сети:
        # один прогон файл не качался, второй прогон через минуту — OK.
        _attempt=0
        while [ "$_attempt" -lt 3 ]; do
            if wget -q -T 30 -O "$_file" "$_base/$_file"; then break; fi
            _attempt=$((_attempt + 1))
            if [ "$_attempt" -ge 3 ]; then
                echo "✗ download failed after 3 attempts: $_file" >&2
                echo "  URL: $_base/$_file" >&2
                echo "  Проверьте: wget $_base/$_file с роутера руками; если падает —" >&2
                echo "  возможно блокировка release-assets.githubusercontent.com у провайдера." >&2
                return 1
            fi
            echo "  ⚠ download flake (попытка $_attempt/3), повтор через $((_attempt * 5))s..."
            sleep $((_attempt * 5))
        done
    done

    # apk изредка падает с "ADB integrity error" / "download failed"
    # из-за рассинхрона индекса или оборванной закачки с зеркала. Один
    # повтор после apk update закрывает такие транзиентные сбои без
    # ручного вмешательства. Реальный kernel-mismatch ловится ниже через
    # modprobe — гадать о причине по тексту apk не нужно.
    _awg_apk_add() {
        apk add --allow-untrusted \
            "./kmod-amneziawg_v${_awg_ver}_${_arch}.apk" \
            "./amneziawg-tools_v${_awg_ver}_${_arch}.apk" \
            "./luci-proto-amneziawg_v${_awg_ver}_${_arch}.apk" 2>&1
    }
    if ! _apk_err=$(_awg_apk_add); then
        echo "  apk add упал, обновляю индексы и повторяю..."
        apk update >/dev/null 2>&1 || true
        if ! _apk_err=$(_awg_apk_add); then
            echo "✗ apk add не удался после повтора. Вывод apk:" >&2
            printf '%s\n' "$_apk_err" | grep -v '^$' >&2
            # Диагностика причины — DPI на «amneziawg» сейчас редко (это не
            # известный VPN-инструмент в DPI-сигнатурах), но всё же стоит
            # проверить и направить юзера в правильное место.
            command -v cheburnet_apk_fail_advice >/dev/null 2>&1 \
                && cheburnet_apk_fail_advice amneziawg
            return 1
        fi
    fi

    if ! modprobe amneziawg; then
        echo "✗ modprobe amneziawg завершился с ошибкой." >&2
        echo "  kmod-amneziawg v${_awg_ver} установлен, но не совместим с текущим ядром ($(uname -r))." >&2
        echo "  Диагностика: dmesg | tail -20" >&2
        return 1
    fi

    unset _arch _release _awg_ver _base _net_ready _w _pkg _file _attempt _apk_err
    return 0
}
