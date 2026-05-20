# lib/install-awg.sh — установка пакетов AmneziaWG (kmod + tools + luci-proto).
#
# Side-effects (apk add, modprobe) — поэтому отдельно от pure-функций
# cheburnet-utils.sh. Вызывать после подключения cheburnet-utils.sh —
# нужны awg_pick_version и cheburnet_apk_fail_advice.

# install_awg_packages — 0 если kmod загружен, 1 на фейле (диагностика в stderr).
install_awg_packages() {
    if lsmod | grep -q '^amneziawg '; then
        echo "→ amneziawg уже установлен, пропускаю установку"
        return 0
    fi

    echo "→ скачиваем и ставим kmod-amneziawg + tools"

    # shellcheck disable=SC1091
    . /etc/openwrt_release
    if [ -z "${DISTRIB_ARCH:-}" ] || [ -z "${DISTRIB_TARGET:-}" ] || [ -z "${DISTRIB_RELEASE:-}" ]; then
        echo "✗ Не удалось определить архитектуру/версию роутера." >&2
        echo "  Проверьте: cat /etc/openwrt_release" >&2
        return 1
    fi
    _arch="${DISTRIB_ARCH}_$(echo "$DISTRIB_TARGET" | tr '/' '_')"
    _release="$DISTRIB_RELEASE"

    # После reboot/sysupgrade DHCP подъезжает 15-30 сек. Без этой проверки
    # awg_pick_version вернёт пусто и юзер увидит «нет совместимого релиза»
    # вместо «сеть не готова». ICMP || HTTP — ping режется на части сетей.
    echo "→ ожидаем готовности сети перед скачиванием..."
    _net_ready=0
    for _w in 1 2 3 4 5 6 7 8 9 10 11 12; do
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
        # GitHub CDN изредка флэйкает (DPI throttle / TCP RST / redirect timeout).
        # 3 попытки с backoff закрывают это без вмешательства юзера.
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

    # apk изредка падает с "ADB integrity error" из-за рассинхрона индекса.
    # Повтор после apk update — закрывает. Реальный kernel-mismatch ловится modprobe ниже.
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
            # Передаём $_apk_err во 2-й аргумент — advice сначала проверит,
            # не kernel-mismatch ли это (типовая причина для kmod-пакетов
            # с rolling-ядром). Если да — даст честный вердикт «несовместимое
            # ядро» вместо ложного «mirror lag, подожди минуту».
            command -v cheburnet_apk_fail_advice >/dev/null 2>&1 \
                && cheburnet_apk_fail_advice amneziawg "$_apk_err"
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
