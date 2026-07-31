#!/usr/bin/env bash
# tests/vps/provision-lab.sh — поднять ОДНОРАЗОВЫЙ тестовый сервер Full-тира на чистом VPS.
#
# Запускается НА VPS (Debian/Ubuntu, root), не на роутере и не на хосте разработчика:
#
#     scp tests/vps/provision-lab.sh root@<vps>:/root/
#     ssh root@<vps> 'bash /root/provision-lab.sh'
#
# Печатает готовые ссылки `vless://…` и `hysteria2://…` — их вставляют в веб-мастер cheburnet.
#
# ЗАЧЕМ ЭТО ВООБЩЕ: ключи Reality и Hysteria2 НЕ выдаются провайдером, а генерируются самим
# sing-box (`generate reality-keypair`, `generate uuid`). То есть для проверки нашего кода никакие
# «ключи от сервера» просить не у кого — сервер поднимается за минуту, и он тоже sing-box.
#
# ЧТО ЭТОТ СЕРВЕР ДАЁТ, ЧЕГО НЕ ДАЁТ ГЕРМЕТИЧНЫЙ СТЕНД (make qemu-netem-v2):
#   • реальный интернет-путь: NAT провайдера, настоящий RTT, и главное — PMTU. У нас в TUN зашит
#     mtu 1500, а QUIC поверх PPPoE/оверхеда может фрагментироваться: стенд на veth этого не видит;
#   • Reality против НАСТОЯЩЕГО заимствованного SNI (в лабе рукопожатие-цель недостижима);
#   • долгий прогон: сутки, переживание reboot роутера, реконнект при смене IP;
#   • port hopping насквозь: сервер принимает весь диапазон, а не один порт.
#
# ЧТО ОН НЕ ПРОВЕРЯЕТ И НЕ МОЖЕТ: устойчивость к фильтрации. Ни один лабораторный сервер не
# скажет, пропустит ли конкретный провайдер конкретный протокол — это проверяется только из той
# сети, где у человека проблема.
#
# > [!warning] Это ОДНОРАЗОВЫЙ стенд, а не сервер для эксплуатации
# > Пароли и ключи генерируются случайными на каждый запуск и лежат в открытом виде в
# > /root/cheburnet-lab/. Пока сервис жив, VPS работает прокси для любого, у кого есть ссылка.
# > Закончили проверку — удалите VPS (или `bash provision-lab.sh --teardown`). В CI это не
# > встраивается намеренно: постоянный джоб на арендованном VPS — это секреты, деньги и внимание
# > каждый месяц, то есть прямо против «минимум поддержки одним человеком».

set -e -u -o pipefail

# Версию пиним под ту же ветку, что стоит на роутере из фида OpenWrt 25.12 (1.12.x) — так
# серверная и клиентская стороны говорят на одном языке, и расхождение поведения нельзя списать
# на разные мажорные версии.
SB_VERSION="${SB_VERSION:-1.12.17}"
LAB_DIR="${LAB_DIR:-/root/cheburnet-lab}"
REALITY_PORT="${REALITY_PORT:-443}"
HY2_PORT="${HY2_PORT:-8443}"
# Диапазон для port hopping: сервер слушает ОДИН порт, а весь диапазон заворачивается на него
# через nftables — именно так это и делают в реальности.
HY2_HOP_FROM="${HY2_HOP_FROM:-20000}"
HY2_HOP_TO="${HY2_HOP_TO:-20100}"
# Заимствованный SNI для Reality: любой крупный сайт с настоящим TLS. Сервер РЕАЛЬНО ходит на
# него во время рукопожатия (поле handshake в схеме — server only и обязательное), поэтому цель
# обязана быть достижима с VPS.
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
# AmneziaWG (Light-тир) на том же стенде. Объявляем ЗДЕСЬ, а не в своём блоке: AWG_NET нужен
# nft-таблице выше по файлу, и из локального блока он бы туда не дошёл (override молча терялся).
# Параметры обфускации обязаны СОВПАДАТЬ с клиентскими — это часть формата пакета, не тюнинг.
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
    ok "сервисы (sing-box + AWG), правила, sysctl и ключи удалены (бинари оставлены)"
    exit 0
fi

# ─── зависимости ──────────────────────────────────────────────────────────────
msg "Ставлю зависимости (curl, tar, openssl, nftables)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates tar openssl nftables >/dev/null
ok "готово"

# ─── бинарь sing-box ──────────────────────────────────────────────────────────
# Ставим релизный бинарь напрямую, а не из репозитория дистрибутива: нужна КОНКРЕТНАЯ версия,
# совпадающая с роутером, иначе разница в поведении необъяснима.
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64)  SB_ARCH=amd64 ;;
    aarch64) SB_ARCH=arm64 ;;
    *) die "неподдерживаемая arch VPS: $ARCH_RAW (нужен x86_64 или aarch64)" ;;
esac

if ! command -v sing-box >/dev/null 2>&1 || ! sing-box version 2>/dev/null | grep -q "$SB_VERSION"; then
    msg "Качаю sing-box $SB_VERSION ($SB_ARCH)"
    TARBALL="sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${TARBALL}"
    tmp="$(mktemp -d)"
    curl -fsSL "$URL" -o "$tmp/$TARBALL" || die "не удалось скачать $URL"
    tar -C "$tmp" -xzf "$tmp/$TARBALL"
    install -m 0755 "$tmp/sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box" /usr/local/bin/sing-box
    rm -rf "$tmp"
fi
ok "$(sing-box version | head -1)"

# ─── ключи и пароли ───────────────────────────────────────────────────────────
# ВСЁ генерируется здесь и сейчас, случайным на каждый запуск. Это и есть ответ на вопрос
# «где взять ключи для Reality/Hysteria2»: их негде взять, их создают.
msg "Генерирую ключи и пароли (случайные на каждый запуск)"
mkdir -p "$LAB_DIR"
chmod 700 "$LAB_DIR"

KEYPAIR="$(sing-box generate reality-keypair)"
REALITY_PRIV="$(printf '%s\n' "$KEYPAIR" | awk '/PrivateKey/{print $2}')"
REALITY_PUB="$(printf '%s\n' "$KEYPAIR" | awk '/PublicKey/{print $2}')"
[ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ] || die "sing-box не отдал пару ключей Reality"

UUID="$(sing-box generate uuid)"
SHORT_ID="$(openssl rand -hex 4)"
HY2_PASS="$(openssl rand -base64 18 | tr -d '/+=')"
OBFS_PASS="$(openssl rand -base64 18 | tr -d '/+=')"

# Сертификат для Hysteria2. Self-signed — сознательно: клиент идёт с insecure=1, и это ровно тот
# путь, который наш парсер обязан поддерживать. Reality сертификата не требует В ПРИНЦИПЕ — он
# занимает рукопожатие чужого сайта, в этом его смысл.
openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes \
    -keyout "$LAB_DIR/hy2-key.pem" -out "$LAB_DIR/hy2-cert.pem" \
    -subj "/CN=$REALITY_SNI" >/dev/null 2>&1
chmod 600 "$LAB_DIR"/hy2-*.pem
ok "ключи в $LAB_DIR (режим 700)"

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

# ─── конфиг ───────────────────────────────────────────────────────────────────
# Два инбаунда в одном процессе: клиент проверяет оба протокола против одного сервера, и разница
# в результатах — это разница протоколов, а не двух разных серверов.
msg "Пишу конфиг сервера"
cat > "$LAB_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PRIV",
          "short_id": [ "$SHORT_ID" ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PASS" } ],
      "obfs": { "type": "salamander", "password": "$OBFS_PASS" },
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "certificate_path": "$LAB_DIR/hy2-cert.pem",
        "key_path": "$LAB_DIR/hy2-key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
chmod 600 "$LAB_DIR/config.json"

sing-box check -c "$LAB_DIR/config.json" || die "sing-box отверг серверный конфиг (см. вывод выше)"
ok "конфиг валиден"

# ─── port hopping на стороне сервера ──────────────────────────────────────────
# Клиент с диапазоном портов стучится в случайный порт из него; сервер слушает один. Разворот
# диапазона делаем nftables-DNAT — это стандартный способ, и без него клиентский server_ports
# проверить насквозь нельзя.
msg "Заворачиваю диапазон $HY2_HOP_FROM-$HY2_HOP_TO на порт $HY2_PORT (port hopping)"
nft delete table inet cheburnet_lab 2>/dev/null || true
nft -f - <<EOF
table inet cheburnet_lab {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport $HY2_HOP_FROM-$HY2_HOP_TO redirect to :$HY2_PORT
    }
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
ok "диапазон заворачивается, NAT для подсети AWG включён"

# ─── AmneziaWG (Light-тир) на том же VPS ──────────────────────────────────────
# ЗАЧЕМ здесь, а не отдельным сервером: три протокола с ОДНОГО стенда сравнимы между собой —
# разница в результатах будет разницей ПРОТОКОЛОВ, а не двух машин. Порты не конфликтуют
# (AWG UDP/51820, Reality TCP/443, Hysteria2 UDP/8443 + диапазон).
#
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
cat > "$LAB_DIR/awg/awg0.conf" <<EOF
[Interface]
PrivateKey = $AWG_SRV_PRIV
ListenPort = $AWG_PORT
Address = $AWG_NET.1/24
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

# Скрипт подъёма: amneziawg-go создаёт TUN, awg setconf применяет конфиг, адрес и маршрут — вручную
# (awg-quick тянет за собой bash+resolvconf, а нам нужен предсказуемый минимум).
cat > "$LAB_DIR/awg/up.sh" <<EOF
#!/bin/sh
set -e
/usr/local/bin/amneziawg-go awg0
/usr/local/bin/awg setconf awg0 $LAB_DIR/awg/awg0.conf
ip address add $AWG_NET.1/24 dev awg0 2>/dev/null || true
ip link set awg0 up
EOF
chmod 755 "$LAB_DIR/awg/up.sh"

cat > /etc/systemd/system/cheburnet-lab-awg.service <<EOF
[Unit]
Description=cheburnet test lab (AmneziaWG, userspace)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_PROCESS_FOREGROUND=0
ExecStart=$LAB_DIR/awg/up.sh
ExecStop=/usr/bin/env ip link del awg0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cheburnet-lab-awg.service >/dev/null 2>&1 || true
sleep 2
if ip link show awg0 >/dev/null 2>&1; then
    ok "awg0 поднят на сервере (порт $AWG_PORT)"
else
    journalctl -u cheburnet-lab-awg.service -n 15 --no-pager || true
    die "интерфейс awg0 не поднялся"
fi

# ─── сервис ───────────────────────────────────────────────────────────────────
msg "Ставлю systemd-сервис"
cat > /etc/systemd/system/cheburnet-lab.service <<EOF
[Unit]
Description=cheburnet test lab (sing-box: VLESS+Reality + Hysteria2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $LAB_DIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cheburnet-lab.service >/dev/null 2>&1
sleep 2
systemctl is-active --quiet cheburnet-lab.service \
    || { journalctl -u cheburnet-lab.service -n 20 --no-pager; die "сервис не поднялся"; }
ok "cheburnet-lab.service запущен"

# ─── ссылки для мастера ───────────────────────────────────────────────────────
VLESS_LINK="vless://${UUID}@${PUBIP}:${REALITY_PORT}?security=reality&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}#cheburnet-lab"
HY2_LINK="hysteria2://${HY2_PASS}@${PUBIP}:${HY2_PORT}?sni=${REALITY_SNI}&insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}#cheburnet-lab"
HY2_HOP_LINK="hysteria2://${HY2_PASS}@${PUBIP}:${HY2_PORT},${HY2_HOP_FROM}-${HY2_HOP_TO}?sni=${REALITY_SNI}&insecure=1&obfs=salamander&obfs-password=${OBFS_PASS}#cheburnet-lab-hop"

# Значения в ОДИНАРНЫХ кавычках: файл предназначен для `. links.env` на стороне разработчика, а в
# ссылках есть '&' и '#' — без кавычек shell разваливает их на фоновые команды и комментарии.
{
    echo "# Ссылки тестового стенда, $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "VLESS_REALITY='$VLESS_LINK'"
    echo "HYSTERIA2='$HY2_LINK'"
    echo "HYSTERIA2_PORT_HOPPING='$HY2_HOP_LINK'"
    # AmneziaWG передаётся не ссылкой, а .conf-файлом (так его и принимает мастер), поэтому в
    # links.env кладём ПУТЬ, а сам конфиг забирает fetch-links.sh отдельным файлом.
    echo "AWG_CONF_REMOTE='$LAB_DIR/awg/client.conf'"
} > "$LAB_DIR/links.txt"
chmod 600 "$LAB_DIR/links.txt"

cat <<EOF

════════════════════════════════════════════════════════════════════════════
Стенд поднят. Вставляйте ссылки в веб-мастер cheburnet (или в панель).

1) VLESS + Reality — ось «трафик вообще не проходит»:

$VLESS_LINK

2) Hysteria2 — ось «трафик проходит, но теряет пакеты»:

$HY2_LINK

3) Hysteria2 с port hopping — проверка server_ports насквозь:

$HY2_HOP_LINK

Копия: $LAB_DIR/links.txt        Логи: journalctl -u cheburnet-lab -f
Снять стенд: bash $0 --teardown
════════════════════════════════════════════════════════════════════════════

Что проверять на роутере (порядок — от самого важного):
  1. MTU/PMTU. Наш TUN зашит на mtu 1500. Прогоните крупные страницы и скачивание файла;
     симптом проблемы — «мелкие сайты открываются, крупные висят». Это главный риск,
     которого герметичный стенд не видит.
  2. Оба протокола end-to-end: трафик реально идёт, connectivity-probe подтверждает.
  3. Переключение туда-обратно из панели (switch_to_*) с автооткатом.
  4. Port hopping: ссылка (3) обязана работать так же, как (2).
  5. Сутки без вмешательства + reboot роутера: туннель встаёт сам.

НАПОМИНАНИЕ: пока сервис жив, VPS работает прокси для любого, у кого есть ссылка.
Закончили — снимите стенд и удалите VPS.
EOF
