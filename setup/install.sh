#!/bin/sh
# install.sh — единственный оркестратор установки. Всегда запускается НА РОУТЕРЕ.
#
# Точки входа:
#   • Веб-мастер: rpcd-cheburnet → setsid /opt/cheburnet/setup/install.sh (фоном).
#   • CLI с ноутбука: setup.sh scp'шит репо в /opt/cheburnet/ и делает
#     ssh root@router '/opt/cheburnet/setup/install.sh'.
#
# Пишет прогресс в /tmp/cheburnet/state, итоговый результат в /tmp/cheburnet/done.
# Логи уходят в stdout/stderr → перехватываются вызывающим кодом в
# /tmp/cheburnet/install.log (для веб-мастера) или печатаются в терминал (CLI).
set -e

INSTALL_DIR="/opt/cheburnet"
STATE_DIR="/tmp/cheburnet"
STATE="$STATE_DIR/state"
DONE="$STATE_DIR/done"

mkdir -p "$STATE_DIR"

# Сразу пишем стартовое состояние, чтобы пока скрипт делает подготовку
# (cp скриптов, чтение wifi-actual.txt и т.д.) поллер фронтенда уже видел
# осмысленный шаг и прогресс-бар стоял на 5% (а не показывал fallback 50%
# из-за отсутствующего ключа в STEP_PCT).
echo "[STEP] starting" > "$STATE"

# === Подключаем диагностические хелперы ===
# Источник: на роутере /opt/cheburnet/lib (туда копирует install.sh).
# shellcheck source=../lib/cheburnet-diag.sh disable=SC1090,SC1091
[ -f "$INSTALL_DIR/lib/cheburnet-diag.sh" ] && . "$INSTALL_DIR/lib/cheburnet-diag.sh"
# shellcheck source=../lib/cheburnet-utils.sh disable=SC1090,SC1091
[ -f "$INSTALL_DIR/lib/cheburnet-utils.sh" ] && . "$INSTALL_DIR/lib/cheburnet-utils.sh"
# shellcheck source=../lib/cheburnet-preflight.sh disable=SC1090,SC1091
[ -f "$INSTALL_DIR/lib/cheburnet-preflight.sh" ] && . "$INSTALL_DIR/lib/cheburnet-preflight.sh"

# === Системный паспорт — печатается один раз в самом начале ===
# Без него нельзя интерпретировать ни одну ошибку: «у юзера 64 МБ overlay —
# adblock не влезет», «arch=mipsel — awg-kmod собран только под 25.12.2», и т.п.
# Это тот самый блок, который мы хотим видеть В КАЖДОМ отчёте о падении.
if command -v cheburnet_diag_system >/dev/null 2>&1; then
    cheburnet_diag_system
fi

# === Preflight: жёсткие проверки совместимости железа и среды ===
# Бежим ДО манифеста и любых apk-команд: на провале ничего не изменено в системе,
# юзер видит большой баннер «РОУТЕР НЕ ПОДХОДИТ» и понимает причину сразу,
# а не на 30-й секунде после половины установки.
#
# Каждая проверка — отдельная функция в lib/cheburnet-preflight.sh, при сбое
# печатает баннер и возвращает 1. Мы записываем структурированную причину
# в $DONE (fail-preflight-flash / -ram / -internet / -arch), фронт показывает
# это в шапке ошибки, юзер пересылает скрин — нам сразу понятна категория.
# Жёсткий гард: если preflight-функций нет в окружении — значит lib не
# подсорсился (потерян/повреждён). Раньше эта ветка была if-проверкой и
# тихо пропускалась — а это ровно тот случай, когда preflight критичен:
# юзер на 16 МБ-роутере молча проходил мимо ловушки и упирался дальше в
# половину установки. Лучше упасть здесь с понятным сообщением.
if ! command -v cheburnet_preflight_flash >/dev/null 2>&1; then
    echo "✗ Preflight-библиотека не загружена ($INSTALL_DIR/lib/cheburnet-preflight.sh)." >&2
    echo "  Установка прервана — это означает повреждённый или неполный репо." >&2
    echo "  Перезалейте репо bootstrap'ом из README:" >&2
    echo "    wget -qO- https://raw.githubusercontent.com/yurik2718/cheburnet-router/master/install.sh | sh" >&2
    echo "fail-preflight-missing-lib" > "$DONE"
    exit 1
fi

echo "[STEP] preflight" > "$STATE"
echo "[preflight] проверяю железо и сеть"
_preflight_fail=""
cheburnet_preflight_flash    || _preflight_fail="flash"
[ -z "$_preflight_fail" ] && { cheburnet_preflight_ram      || _preflight_fail="ram"; }
[ -z "$_preflight_fail" ] && { cheburnet_preflight_internet || _preflight_fail="internet"; }
[ -z "$_preflight_fail" ] && { cheburnet_preflight_arch     || _preflight_fail="arch"; }
if [ -n "$_preflight_fail" ]; then
    echo "fail-preflight-${_preflight_fail}" > "$DONE"
    exit 1
fi
echo "  ✓ preflight OK"

# === Применяем манифест ===
# Раньше тут было два слоя копирования: сначала /opt/cheburnet/scripts/* →
# /tmp/scripts/, потом setup/0X-*.sh → /tmp/scripts/* в /usr/bin/. Это давало
# два места где можно «забыть скопировать файл» (см. историю с conntrack-monitor).
# Теперь один манифест → один проход install — финальные пути сразу.
# Setup-шаги после этого только настраивают сервисы и cron, не копируют файлы.
MANIFEST="$INSTALL_DIR/setup/manifest.txt"
if [ ! -f "$MANIFEST" ]; then
    echo "✗ $MANIFEST не найден — ставить нечего"
    echo "fail-no-manifest" > "$DONE"
    exit 1
fi

echo "[prepare] раскладываю файлы по манифесту"
missing=0
# shellcheck disable=SC2162  # POSIX read без -r — нам не нужно интерпретировать backslash в путях
while read src dst mode; do
    case "$src" in ''|\#*) continue;; esac
    full_src="$INSTALL_DIR/$src"
    if [ ! -f "$full_src" ]; then
        echo "  ✗ источник отсутствует: $src"
        missing=$((missing + 1))
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    # cp + chmod, не `install -m mode` — busybox-конфиг OpenWrt не включает
    # утилиту install в дефолтный набор. Поймали в QEMU smoke на свежем
    # snapshot: установка падала на первом файле манифеста.
    cp "$full_src" "$dst" && chmod "$mode" "$dst"
done < "$MANIFEST"

if [ "$missing" -gt 0 ]; then
    echo "✗ манифест ссылается на $missing отсутствующих файла(ов) — установка прервана"
    echo "fail-manifest-missing" > "$DONE"
    exit 1
fi
echo "  ✓ манифест применён"

# Wi-Fi параметры. Для веб-мастера — кладёт rpcd-cheburnet (RPC install_start
# принимает SSID/key/country и пишет файл). Для CLI — кладёт setup.sh
# (он же rsync'ит репо целиком). В обоих случаях файл должен быть в configs/.
if [ ! -f "$INSTALL_DIR/configs/wireless-actual.txt" ]; then
    echo "✗ configs/wireless-actual.txt не найден"
    echo "fail-no-wifi-config" > "$DONE"
    exit 1
fi
# shellcheck disable=SC1091
. "$INSTALL_DIR/configs/wireless-actual.txt"
export WIFI_SSID WIFI_KEY WIFI_COUNTRY

# === Список шагов ===
# AWG-конфиг должен быть в каноническом месте. Кладёт его либо rpcd-cheburnet
# (веб-мастер сохраняет тело .conf из RPC-вызова), либо setup.sh (CLI scp'шит).
if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then
    echo "✗ /etc/amnezia/amneziawg/awg0.conf не найден"
    echo "fail-no-awg-config" > "$DONE"
    exit 1
fi
STEPS="00-prerequisites.sh 01-amneziawg.sh 02-podkop.sh 03-adblock.sh \
       04-dns.sh 05-wifi.sh 06-vpn-mode.sh 07-killswitch.sh 08-watchdog.sh \
       09-ssh-hardening.sh 10-quality.sh"

# 09-ssh-hardening в режиме инсталляции не должен валиться при пустом
# authorized_keys — мы хотим хотя бы Block-SSH-from-WAN всегда поставить.
# Сам скрипт уважает CHEBURNET_KEY_REQUIRED и при KEY_REQUIRED=0 включает
# password-auth disable только если ключ есть (recovery остаётся).
export CHEBURNET_KEY_REQUIRED=0

# === Выполнение ===
for STEP in $STEPS; do
    SHORT=$(echo "$STEP" | sed 's/\.sh$//')
    echo "[STEP] $SHORT" > "$STATE"
    echo
    echo "════════════════════════════════════════════"
    echo " ШАГ: $STEP"
    echo "════════════════════════════════════════════"

    if [ ! -f "$INSTALL_DIR/setup/$STEP" ]; then
        echo "⚠ $STEP не найден, пропускаю"
        continue
    fi

    # 05-wifi.sh ожидает env-переменные, остальные — нет
    if ! sh "$INSTALL_DIR/setup/$STEP"; then
        echo
        echo "✗ ШАГ $STEP завершился с ошибкой."
        # Универсальный снимок состояния системы — печатается на ветке фейла
        # ЛЮБОГО шага. Покрывает причины, не привязанные к конкретному скрипту:
        # OOM-killer, нехватка disk-space, kernel-warnings. Если у шага есть
        # своя domain-диагностика (07-killswitch, 01-amneziawg) — она уже
        # отработала выше; этот снимок её дополняет, а не дублирует.
        if command -v cheburnet_diag_runtime >/dev/null 2>&1; then
            cheburnet_diag_runtime
        fi
        echo "fail-$SHORT" > "$DONE"
        exit 1
    fi
done

# === Применяем root-пароль (положен в $STATE_DIR/root_pass либо rpcd-handler'ом, либо setup.sh) ===
if [ -s "$STATE_DIR/root_pass" ]; then
    echo "[STEP] root-password" > "$STATE"
    echo
    echo "════════════════════════════════════════════"
    echo " ШАГ: установка пароля root"
    echo "════════════════════════════════════════════"
    pass=$(cat "$STATE_DIR/root_pass")
    if printf '%s\n%s\n' "$pass" "$pass" | passwd root >/dev/null 2>&1; then
        echo "✓ пароль root установлен"
    else
        echo "⚠ passwd root не сработал — установите пароль вручную через SSH"
    fi
    unset pass
    # root_pass лежит в /tmp (tmpfs/RAM) — dd-перезапись бессмысленна
    # (tmpfs не имеет дисковых блоков, по unlink RAM освобождается).
    rm -f "$STATE_DIR/root_pass"
fi

# === Удаляем install-токен (одноразовый, больше не нужен) ===
if [ -f /etc/cheburnet/install-token ]; then
    # На UBI/JFFS2 с wear-leveling dd пишет в НОВЫЕ блоки, не затирая старые
    # — «безопасная» перезапись была cargo cult. rm-а достаточно.
    rm -f /etc/cheburnet/install-token
    echo "→ install-токен удалён"
fi

# === Запираем ACL: после установки unauth остаётся только read-only ===
echo "[STEP] lock-acl" > "$STATE"
echo
echo "════════════════════════════════════════════"
echo " ШАГ: запираем веб-ACL (read-only без логина)"
echo "════════════════════════════════════════════"
cat > /usr/share/rpcd/acl.d/cheburnet.json <<'ACL'
{
    "unauthenticated": {
        "description": "cheburnet read-only status (post-install LAN-локально)",
        "read": { "ubus": { "cheburnet": ["get_status", "install_progress"] } }
    },
    "cheburnet-admin": {
        "description": "cheburnet admin (login as root required)",
        "read":  { "ubus": { "cheburnet": ["get_status", "install_progress"] } },
        "write": { "ubus": { "cheburnet": ["install_start", "install_cancel", "mode_switch", "service_restart", "set_blocklist_tier", "set_family_filter", "factory_reset", "replace_awg_conf"] } }
    }
}
ACL
# ВАЖНО: именно restart, а не reload. На ряде OpenWrt-сборок rpcd HUP
# (то, что делает reload) НЕ перечитывает JSON-файлы из /usr/share/rpcd/acl.d/
# — они грузятся только при start. Без restart рестрикция unauth и роль
# cheburnet-admin не подхватываются: get_status работает (он был и в старом
# ACL), но mode_switch / service_restart / factory_reset возвращают
# `ubus code 6` даже после login, потому что роль cheburnet-admin для
# rpcd «не существует». Один прецедент с этим багом уже был в продакшне.
# Restart роняет rpcd на 1-2 сек — фронт переживёт через свой retry-loop.
/etc/init.d/rpcd restart >/dev/null 2>&1
echo "✓ ACL заблокирован: чтение без логина, мутации требуют пароль root"

# === Финальное сообщение для пользователя ===
# Последний экран в логе перед автопереходом на success-screen. Цель:
# человек не теряется «а что дальше?», получает конкретные значения
# (SSID, URL) и план действий. Печатаем в stdout → попадает в
# /tmp/cheburnet/install.log → виден в веб-консоли.
# ВАЖНО: не печатаем секреты (Wi-Fi password, root password) — лог
# доступен через install_progress RPC без авторизации.
FINAL_SSID="${WIFI_SSID:-<ваш SSID>}"
# shellcheck source=../lib/net-detect.sh disable=SC1090,SC1091
. "$INSTALL_DIR/lib/net-detect.sh"
FINAL_LAN_IP=$(net_lan_ip 192.168.1.1)

cat <<EOF

════════════════════════════════════════════════════════════
                    ✓ Установка завершена!
════════════════════════════════════════════════════════════

Поздравляем! Cheburnet-router настроен и готов к работе.

ЗАПОМНИТЕ:
  • Wi-Fi SSID:    $FINAL_SSID
  • Наша панель:   http://$FINAL_LAN_IP/cheburnet/
                   (повседневное управление: режимы, перезапуск, статус)
  • LuCI:          http://$FINAL_LAN_IP/
                   Графическая админ-панель самого OpenWrt — для
                   опытных пользователей: тонкая настройка сети,
                   firewall, пакеты, диагностика, расширенные опции.
                   Для повседневного использования она НЕ нужна —
                   наша панель проще и закрывает все обычные задачи.
  • Логин:         root
  • Пароль:        тот, что вы задали на шаге «Пароль администратора».
                   Работает и в нашей панели, и в LuCI, и в SSH из LAN.
                   Записан только у вас — храните в надёжном месте.
                   Если потеряете — придётся делать factory reset
                   через кнопку на роутере.

ЧТО ДЕЛАТЬ ДАЛЬШЕ:
  1. Подключите телефон/ноутбук к новому Wi-Fi (SSID выше).
  2. Откройте https://yandex.com/internet — должен идти напрямую с полной
     скоростью (трафик к .ru-зоне идёт без VPN-туннеля).
  3. Откройте speedtest.net — должен идти через VPN-туннель
     (скорость может быть ниже, IP сервера — другой).
  4. Если оба работают — всё в порядке, можно пользоваться.
  5. Закладку на http://$FINAL_LAN_IP/cheburnet/ сохраните в браузере —
     это ваша панель управления роутером.

ЕСЛИ ВСЁ ПОЛУЧИЛОСЬ И ПРОЕКТ ВАМ ОТКЛИКНУЛСЯ:
  ⭐ Поставьте звезду:
     https://github.com/yurik2718/cheburnet-router

  Это занимает 2 секунды и ничего не стоит, но каждая звезда
  поднимает проект в поиске GitHub — больше людей, кому нужен
  такой роутер, его находят. Для open-source это самая ценная
  и при этом бесплатная поддержка.

  💰 Нужен VPN-сервер? Amnezia Premium со скидкой 15% (промокод CHEBURNET15):
     https://storage.googleapis.com/amnezia/amnezia.org?m-path=premium&arf=EB5KDKXCJYQYP4MG&coupon=CHEBURNET15
     Поддерживает развитие проекта.

ЕСЛИ НУЖНА ПОМОЩЬ ИЛИ ЧТО-ТО НЕ РАБОТАЕТ:
  Напишите в Telegram: @industrialprofi
  Лучше всего — приложите скриншот этого окна целиком (в нём виден
  весь лог установки, по нему можно понять, где сбой).

════════════════════════════════════════════════════════════
EOF

echo "ok" > "$DONE"
echo "[done]" > "$STATE"
