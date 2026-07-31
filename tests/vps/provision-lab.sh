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

msg()  { printf '\n\033[1m→ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "нужен root"

# ─── teardown ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--teardown" ]; then
    msg "Снимаю тестовый стенд"
    systemctl disable --now cheburnet-lab.service 2>/dev/null || true
    rm -f /etc/systemd/system/cheburnet-lab.service
    systemctl daemon-reload 2>/dev/null || true
    nft delete table inet cheburnet_lab 2>/dev/null || true
    rm -rf "$LAB_DIR"
    ok "сервис, правила и ключи удалены (сам бинарь sing-box оставлен)"
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
}
EOF
ok "диапазон заворачивается"

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

{
    echo "# Ссылки тестового стенда, $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "VLESS_REALITY=$VLESS_LINK"
    echo "HYSTERIA2=$HY2_LINK"
    echo "HYSTERIA2_PORT_HOPPING=$HY2_HOP_LINK"
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
