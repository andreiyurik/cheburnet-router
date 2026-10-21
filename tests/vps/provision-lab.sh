#!/usr/bin/env bash
# tests/vps/provision-lab.sh — поднять ОДНОРАЗОВЫЙ тестовый сервер AmneziaWG на чистом VPS.
#
# Запускается НА VPS (Debian/Ubuntu, root), не на роутере и не на хосте разработчика:
#
#     scp tests/vps/provision-lab.sh root@<vps>:/root/
#     ssh root@<vps> 'bash /root/provision-lab.sh'
#
# Кладёт клиентский конфиг AmneziaWG (его вставляют в веб-мастер cheburnet). Ключи генерирует сам
# awg — «ключей от сервера» просить не у кого. Full-тир (sing-box) заморожен — ADR 0010.
#
# ЧТО ЭТОТ СЕРВЕР ДАЁТ, ЧЕГО НЕ ДАЁТ ГЕРМЕТИЧНЫЙ СТЕНД (QEMU):
#   • реальный интернет-путь: NAT провайдера, настоящий RTT, и главное — PMTU. У нас в TUN зашит
#     mtu 1500, а туннель поверх PPPoE/оверхеда может фрагментироваться: стенд на veth этого не видит;
#   • долгий прогон: сутки, переживание reboot роутера, реконнект при смене IP.
#
# ЧТО ОН НЕ ПРОВЕРЯЕТ И НЕ МОЖЕТ: устойчивость к фильтрации. Ни один лабораторный сервер не
# скажет, пропустит ли конкретный провайдер конкретный протокол — это проверяется только из той
# сети, где у человека проблема.
#
# > [!warning] Это ОДНОРАЗОВЫЙ стенд, а не сервер для эксплуатации
# > Пароли и ключи генерируются случайными на каждый запуск и лежат в открытом виде в
# > /root/cheburnet-lab/. Пока сервис жив, VPS работает VPN-сервером для любого, у кого есть конфиг.
# > Закончили проверку — удалите VPS (или `bash provision-lab.sh --teardown`). В CI это не
# > встраивается намеренно: постоянный джоб на арендованном VPS — это секреты, деньги и внимание
# > каждый месяц, то есть прямо против «минимум поддержки одним человеком».

set -e -u -o pipefail

LAB_DIR="${LAB_DIR:-/root/cheburnet-lab}"
AWG_PORT="${AWG_PORT:-51820}"
AWG_NET="${AWG_NET:-10.13.13}"
AWG_JC="${AWG_JC:-4}";     AWG_JMIN="${AWG_JMIN:-40}"; AWG_JMAX="${AWG_JMAX:-70}"
AWG_S1="${AWG_S1:-78}";    AWG_S2="${AWG_S2:-22}"
AWG_H1="${AWG_H1:-1234567}"; AWG_H2="${AWG_H2:-2345678}"
AWG_H3="${AWG_H3:-3456789}"; AWG_H4="${AWG_H4:-4567890}"

msg()  { printf '\n\033[1m→ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "нужен root"

# ─── teardown ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--teardown" ]; then
    msg "Снимаю тестовый стенд"
    systemctl disable --now cheburnet-lab.service 2>/dev/null || true
    systemctl disable --now cheburnet-lab-awg.service 2>/dev/null || true
    rm -f /etc/systemd/system/cheburnet-lab.service /etc/systemd/system/cheburnet-lab-awg.service
    ip link del awg0 2>/dev/null || true
    rm -f /etc/sysctl.d/99-cheburnet-lab.conf
    systemctl daemon-reload 2>/dev/null || true
    nft delete table inet cheburnet_lab 2>/dev/null || true
    rm -rf "$LAB_DIR"
    ok "сервисы, правила, sysctl и ключи удалены (бинари оставлены)"
    exit 0
fi

# ─── зависимости ──────────────────────────────────────────────────────────────
msg "Ставлю зависимости (curl, tar, openssl, nftables)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates tar openssl nftables >/dev/null
ok "готово"

# ─── каталог стенда ───────────────────────────────────────────────────────────
mkdir -p "$LAB_DIR"
chmod 700 "$LAB_DIR"

# ─── публичный адрес ──────────────────────────────────────────────────────────
# Определяем сами: в ссылку должен попасть адрес, по которому VPS реально виден снаружи, а не
# внутренний адрес за NAT провайдера (у части хостеров это разные вещи).
msg "Определяю публичный адрес VPS"
PUBIP="${PUBIP:-$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)}"
if [ -z "$PUBIP" ]; then
    PUBIP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    printf '  \033[33m⚠\033[0m внешний сервис не ответил — беру адрес интерфейса: %s\n' "$PUBIP"
fi
[ -n "$PUBIP" ] || die "не удалось определить адрес VPS (задайте PUBIP=…)"
ok "$PUBIP"

# ─── NAT и MSS для подсети AWG ────────────────────────────────────────────────
msg "Включаю NAT для подсети AWG"
nft delete table inet cheburnet_lab 2>/dev/null || true
nft -f - <<EOF
table inet cheburnet_lab {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $AWG_NET.0/24 masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        # MSS clamping для TCP внутри AWG: без него крупные страницы «висят» на путях с меньшим
        # MTU — классический симптом, который легко списать на протокол.
        tcp flags syn tcp option maxseg size set rt mtu
    }
}
EOF
ok "NAT для подсети AWG включён"

# ─── AmneziaWG ────────────────────────────────────────────────────────────────
# Реализация — amneziawg-go (userspace), а НЕ модуль ядра: сборка модуля требует заголовков
# ядра провайдера и ломается на любом их обновлении. Для стенда важна совместимость протокола,
# а не скорость: клиент на роутере всё равно работает в ядре.
#
# КРИТИЧНО: параметры обфускации (Jc/Jmin/Jmax/S1/S2/H1..H4) обязаны СОВПАДАТЬ на клиенте и
# сервере — это не «настройки производительности», а часть формата пакета. Расхождение = туннель
# не поднимается без внятной ошибки, и это самая частая причина «AWG не работает».

msg "Ставлю AmneziaWG (userspace amneziawg-go + awg-tools)"
apt-get install -y -qq git golang-go make >/dev/null 2>&1 || die "не удалось поставить go/make"

if [ ! -x /usr/local/bin/amneziawg-go ]; then
    rm -rf /tmp/awg-src && mkdir -p /tmp/awg-src
    git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-go /tmp/awg-src/go \
        || die "не склонировался amneziawg-go"
    ( cd /tmp/awg-src/go && make >/dev/null 2>&1 && install -m 755 amneziawg-go /usr/local/bin/ ) \
        || die "amneziawg-go не собрался"
fi
if [ ! -x /usr/local/bin/awg ]; then
    rm -rf /tmp/awg-tools && mkdir -p /tmp/awg-tools
    git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-tools /tmp/awg-tools/t \
        || die "не склонировался amneziawg-tools"
    ( cd /tmp/awg-tools/t/src && make >/dev/null 2>&1 && install -m 755 wg /usr/local/bin/awg ) \
        || die "amneziawg-tools не собрались"
fi
ok "amneziawg-go и awg на месте"

msg "Генерирую ключи AmneziaWG (сервер + клиент)"
AWG_SRV_PRIV="$(/usr/local/bin/awg genkey)"
AWG_SRV_PUB="$(printf '%s' "$AWG_SRV_PRIV" | /usr/local/bin/awg pubkey)"
AWG_CLI_PRIV="$(/usr/local/bin/awg genkey)"
AWG_CLI_PUB="$(printf '%s' "$AWG_CLI_PRIV" | /usr/local/bin/awg pubkey)"
ok "пары ключей сгенерированы (приватные не печатаем)"

mkdir -p "$LAB_DIR/awg"
# ВАЖНО: здесь конфиг для `awg setconf`, а НЕ для `awg-quick`. setconf понимает только ключи
# самого протокола (PrivateKey/ListenPort/Jc…/Peer) и падает с «Line unrecognized» на любом
# ключе уровня awg-quick — Address, MTU, DNS, Table. Адрес интерфейса назначается отдельно, в
# up.sh через `ip address add`. В КЛИЕНТСКОМ конфиге ниже Address, наоборот, обязателен: он в
# формате awg-quick, именно такой файл человек и вставляет в мастер.
cat > "$LAB_DIR/awg/awg0.conf" <<EOF
[Interface]
PrivateKey = $AWG_SRV_PRIV
ListenPort = $AWG_PORT
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $AWG_CLI_PUB
AllowedIPs = $AWG_NET.2/32
EOF
chmod 600 "$LAB_DIR/awg/awg0.conf"

# Клиентский .conf — в том виде, в каком его принимает наш веб-мастер (шаг vpn).
cat > "$LAB_DIR/awg/client.conf" <<EOF
[Interface]
PrivateKey = $AWG_CLI_PRIV
Address = $AWG_NET.2/32
DNS = 1.1.1.1
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $AWG_SRV_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $PUBIP:$AWG_PORT
PersistentKeepalive = 25
EOF
chmod 600 "$LAB_DIR/awg/client.conf"
ok "конфиги сервера и клиента записаны"

# Форвардинг и NAT для подсети AWG: без них туннель поднимется, а интернета в нём не будет —
# ровно тот случай, когда «handshake есть, а сайты не открываются».
msg "Включаю форвардинг и NAT для $AWG_NET.0/24"
sysctl -qw net.ipv4.ip_forward=1
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-cheburnet-lab.conf
WAN_IF="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
[ -n "$WAN_IF" ] || die "не определился внешний интерфейс для NAT"
ok "внешний интерфейс: $WAN_IF"

# Настройка интерфейса ПОСЛЕ старта демона: adres/маршрут ставим вручную, без awg-quick (он тянет
# bash+resolvconf, а нам нужен предсказуемый минимум).
#
# ПОЧЕМУ ждём сокет, а не зовём setconf сразу (поймано живьём, стоило часа): amneziawg-go общается
# с awg через UAPI-сокет /var/run/amneziawg/awg0.sock, и создаёт его ПОЗЖЕ, чем сам TUN-интерфейс.
# `awg setconf`, запущенный в этот зазор, не падает, а ВИСНЕТ бесконечно — вместе с юнитом и всем
# скриптом. Поэтому: сначала дождаться сокета, потом настраивать.
cat > "$LAB_DIR/awg/configure.sh" <<EOF
#!/bin/sh
set -e
i=0
while [ ! -S /var/run/amneziawg/awg0.sock ]; do
    i=\$((i + 1)); [ "\$i" -gt 100 ] && { echo "UAPI-сокет awg0 так и не появился" >&2; exit 1; }
    sleep 0.1
done
/usr/local/bin/awg setconf awg0 $LAB_DIR/awg/awg0.conf
ip address add $AWG_NET.1/24 dev awg0 2>/dev/null || true
ip link set awg0 up
EOF
chmod 755 "$LAB_DIR/awg/configure.sh"

# Демон держим в FOREGROUND под systemd (Type=simple), а не даём ему демонизироваться: тогда
# интерфейс живёт ровно пока жив юнит, падение перезапускается, а лог идёт в journal.
# ExecStartPre снимает возможный осиротевший awg0 и stale-сокет: amneziawg-go не стартует, если
# интерфейс уже есть, и это читалось бы как «сервер не поднялся».
# Баннер «этому ядру amneziawg-go не нужен, есть модуль» в логе — унаследованное от wireguard-go
# предупреждение о наличии WireGuard в ЯДРЕ (нам он и не нужен), а не отказ.
cat > /etc/systemd/system/cheburnet-lab-awg.service <<EOF
[Unit]
Description=cheburnet test lab (AmneziaWG, userspace)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=WG_PROCESS_FOREGROUND=1
ExecStartPre=/bin/sh -c 'ip link del awg0 2>/dev/null; rm -f /var/run/amneziawg/awg0.sock; true'
ExecStart=/usr/local/bin/amneziawg-go awg0
ExecStartPost=$LAB_DIR/awg/configure.sh
ExecStopPost=/bin/sh -c 'ip link del awg0 2>/dev/null; true'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
# enable + restart, а НЕ `enable --now`: --now не трогает уже РАБОТАЮЩИЙ сервис, поэтому повторный
# запуск стенда генерировал новые ключи, а демон продолжал работать со старыми — стенд отдавал
# ссылки, которые сам же не принимал (потеряно на этом больше часа живого прогона).
systemctl enable cheburnet-lab-awg.service >/dev/null 2>&1 || true
systemctl restart cheburnet-lab-awg.service >/dev/null 2>&1 || true
sleep 2
# Проверяем НЕ факт «интерфейс есть»: amneziawg-go создаёт TUN до применения конфига, поэтому при
# провале setconf остаётся пустой awg0 — стенд выглядел бы поднятым, а клиент не подключился бы
# никогда. Гейтим на том, что реально нужно клиенту: слушающий порт и заданный peer.
if /usr/local/bin/awg show awg0 2>/dev/null | grep -q "listening port: $AWG_PORT" \
   && /usr/local/bin/awg show awg0 2>/dev/null | grep -q '^peer:'; then
    ok "awg0 поднят на сервере (порт $AWG_PORT, peer задан)"
else
    /usr/local/bin/awg show awg0 2>&1 | head -10 || true
    journalctl -u cheburnet-lab-awg.service -n 15 --no-pager || true
    die "awg0 не настроен (интерфейс без порта/peer — смотрите ошибку setconf выше)"
fi

# ─── итог ─────────────────────────────────────────────────────────────────────
# links.txt: путь к клиентскому конфигу на стенде (сам конфиг забирает fetch-links.sh отдельным файлом).
{
    echo "# Тестовый стенд, $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "AWG_CONF_REMOTE='$LAB_DIR/awg/client.conf'"
} > "$LAB_DIR/links.txt"
chmod 600 "$LAB_DIR/links.txt"

cat <<EOF

════════════════════════════════════════════════════════════════════════════
Стенд поднят. Клиентский конфиг AmneziaWG: $LAB_DIR/awg/client.conf
(fetch-links.sh заберёт его сам в tests/vps/awg-client.conf).

Логи: journalctl -u cheburnet-lab-awg -f        Снять стенд: bash $0 --teardown
════════════════════════════════════════════════════════════════════════════

Что проверять на роутере (порядок — от самого важного):
  1. MTU/PMTU: крупные страницы и скачивание файла; симптом проблемы — «мелкие сайты
     открываются, крупные висят». Это главный риск, которого герметичный стенд не видит.
  2. Установка насквозь: make qemu-live-install (commit, трафик через сервер, ребут).
  3. Сутки без вмешательства + reboot роутера: туннель встаёт сам.

НАПОМИНАНИЕ: пока сервис жив, VPS работает VPN-сервером для любого, у кого есть конфиг.
Закончили — снимите стенд и удалите VPS.
EOF
