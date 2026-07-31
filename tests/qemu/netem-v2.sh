#!/bin/bash
# tests/qemu/netem-v2.sh — ЗАМЕР: держит ли Hysteria2 (QUIC) скорость на канале с потерями.
#
# Это тот замер, ради которого Hysteria2 и берут (ADR 0004, ось «трафик проходит, но плохо»).
# Утверждать «QUIC лучше на потерях» без цифр — значит обещать пользователю то, чего мы не мерили.
#
# СТЕНД (герметичный, целиком внутри одной VM — внешний сервер НЕ нужен):
#
#   root netns                          netem            netns lab-srv
#   ┌────────────────────────┐        ┌──────┐        ┌──────────────────────────┐
#   │ sing-box (наш конфиг)  │  lab0 ═╪ loss ╪═ lab1  │ sing-box inbound         │
#   │  hysteria2/vless out   │        └──────┘        │  hysteria2:8443          │
#   │  TUN singtun0          │                        │  vless:8444 (TCP-эталон) │
#   │ uclient-fetch ─────────┼───────── через TUN ───▶│ uhttpd @ 10.88.0.1:80    │
#   └────────────────────────┘                        └──────────────────────────┘
#
# Origin (10.88.0.1) виден ТОЛЬКО из netns сервера, поэтому «дошло» = дошло через туннель.
# Меряем goodput (КБ/с за окно фиксированной длительности) и CPU-время sing-box при loss 0/5/15 %.
#
# ЧТО ЭТОТ СТЕНД МОЖЕТ И ЧЕГО НЕ МОЖЕТ (честно):
#   • может: сравнить ТРАНСПОРТЫ в одинаковых условиях на x86_64 — QUIC (Hysteria2) против
#     TCP через тот же бинарь sing-box, плюс baseline без туннеля;
#   • НЕ может: предсказать потолок на целевом ARM (там узкое место — CPU, не канал);
#   • НЕ может: заменить живой сервер провайдера;
#   • НЕ включает AmneziaWG: для него нужен второй netns с kmod-amneziawg и awg-парой — это
#     отдельная работа, и её отсутствие названо здесь прямо, а не спрятано.
#   • TCP-эталон — РУКОПИСНЫЙ vless-конфиг без Reality: наш билдер Reality-конфигов требует
#     серверных ключей, а сравнить надо ТРАНСПОРТ (TCP против QUIC), не mimicry. Hysteria2-конфиг
#     при этом генерируется НАШИМ движком — то есть мерится именно то, что поедет пользователю.
#
# Тест НЕ гейтит релиз по цифрам (железо CI разное) — он их ПЕЧАТАЕТ и валится только на
# сломанном стенде (туннель не поднялся, файл не скачался). Цифры идут в ADR 0004 руками.
#
# Запуск: make qemu-netem-v2 (нужен интернет для apk). ~6-10 мин с KVM.

set -e -u -o pipefail

. "$(dirname "$0")/lib.sh"

# Стенду нужно больше RAM: два инстанса sing-box + uhttpd + netem-буферы. Переменную читает
# vm_start из lib.sh (`: "${VM_RAM_MB:=512}"`), поэтому задаём её ДО vm_lib_init.
# shellcheck disable=SC2034  # используется в lib.sh, не в этом файле
VM_RAM_MB=1024

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

echo "→ Проверяю интернет в VM"
vm_ssh "nslookup downloads.openwrt.org 2>&1 | grep -q 'Address.*\\.'" \
    || { echo "✗ DNS не работает в VM — apk update не пройдёт"; exit 1; }

apk_try() {
    local cmd="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if vm_ssh "$cmd" >/dev/null 2>&1; then return 0; fi
        sleep 10
    done
    return 1
}

echo "→ apk update"
apk_try "apk update" || { echo "✗ apk update упал"; exit 1; }

echo "→ Ставлю стенд: sing-box, netem, tc, openssl, uhttpd"
# kmod-veth в OpenWrt по умолчанию НЕ собран в образ — без него `ip link add ... type veth`
# отвечает «Unknown device type», и лаборатория не собирается.
for pkg in kmod-tun kmod-veth ip-full sing-box-tiny kmod-sched-core kmod-netem tc-full openssl-util uhttpd; do
    if apk_try "apk add $pkg"; then echo "  ✓ $pkg"; else echo "  ✗ $pkg не ставится из feed — стенд собрать нельзя"; exit 1; fi
done
vm_ssh "command -v sing-box >/dev/null" || { echo "✗ бинарь sing-box не появился"; exit 1; }

# ip и tc разрешаем ЯВНО и один раз. Почему: busybox тоже несёт `ip`, и он НЕ умеет `netns`
# (печатает usage и выходит 1). Какой из них найдётся первым в PATH — зависит от способа запуска
# команды, поэтому «иногда работает» здесь хуже, чем «всегда одно и то же»: полные версии живут
# в /usr/libexec (пакеты ip-full / tc-full), к ним и обращаемся.
IPB="$(vm_ssh '[ -x /usr/libexec/ip-full ] && echo /usr/libexec/ip-full || command -v ip')"
TCB="$(vm_ssh '[ -x /usr/libexec/tc-full ] && echo /usr/libexec/tc-full || command -v tc')"
vm_ssh "$IPB netns list >/dev/null 2>&1" \
    || { echo "✗ $IPB не умеет netns — лабораторию не собрать"; exit 1; }
echo "  ✓ полные утилиты: ip=$IPB, tc=$TCB"
# Штатный сервис не нужен: инстансы стенда запускаем руками с явными конфигами.
vm_ssh "/etc/init.d/sing-box stop >/dev/null 2>&1; /etc/init.d/sing-box disable >/dev/null 2>&1; /etc/init.d/uhttpd stop >/dev/null 2>&1 || true"

# ─── стенд: netns + veth + origin + сертификат ────────────────────────────────
echo "→ Собираю лабораторию (netns lab-srv, veth, origin-файл, self-signed сертификат)"
FILE_MB=32
vm_ssh "cat > /root/lab-setup.sh" <<LABSETUP
#!/bin/sh
# Лаборатория для замера транспорта. Идемпотентно: повторный запуск пересобирает с нуля.
set -e
${IPB} netns del lab-srv 2>/dev/null || true
${IPB} link del lab0 2>/dev/null || true

${IPB} netns add lab-srv
${IPB} link add lab0 type veth peer name lab1
${IPB} link set lab1 netns lab-srv
${IPB} addr add 10.77.0.1/24 dev lab0
${IPB} link set lab0 up
${IPB} netns exec lab-srv ${IPB} addr add 10.77.0.2/24 dev lab1
${IPB} netns exec lab-srv ${IPB} link set lab1 up
${IPB} netns exec lab-srv ${IPB} link set lo up
# Origin-адрес: виден только внутри netns сервера → «дошло» значит «дошло через туннель».
${IPB} netns exec lab-srv ${IPB} addr add 10.88.0.1/32 dev lo

# Файл для скачивания: /dev/urandom, чтобы ничего не сжималось по пути.
mkdir -p /root/lab-www
dd if=/dev/urandom of=/root/lab-www/blob.bin bs=1M count=${FILE_MB} 2>/dev/null

# Self-signed сертификат для TLS hysteria2-инбаунда (клиент идёт с insecure=1).
openssl req -x509 -newkey rsa:2048 -keyout /root/lab-key.pem -out /root/lab-cert.pem \
    -days 1 -nodes -subj "/CN=lab.invalid" >/dev/null 2>&1

echo LAB_READY
LABSETUP
# Вывод сохраняем и печатаем при провале: «не удалось собрать лабораторию» без причины —
# это полчаса гадания, а `sh -x` сразу показывает, какая команда отвалилась.
LAB_OUT="$(vm_ssh "sh -x /root/lab-setup.sh 2>&1" || true)"
case "$LAB_OUT" in
    *LAB_READY*) ;;
    *) echo "✗ не удалось собрать лабораторию:"; printf '%s\n' "$LAB_OUT" | tail -20 | sed 's/^/    /'; exit 1 ;;
esac

# uhttpd в netns сервера: отдаёт blob.bin на 10.88.0.1:80.
# setsid ОБЯЗАТЕЛЕН: без него процесс — член process-group ssh-сессии и получает SIGHUP, как
# только ssh закрывается (тот же приём, что spawn_bg в движке). Иначе стенд «поднимался» и молча
# умирал между вызовами, а тест валился на скачивании с невнятной причиной.
vm_ssh "setsid $IPB netns exec lab-srv uhttpd -f -h /root/lab-www -p 10.88.0.1:80 </dev/null >/tmp/lab-uhttpd.log 2>&1 &
        sleep 2; pgrep uhttpd >/dev/null" \
    || { echo "✗ uhttpd в netns сервера не поднялся:"; vm_ssh 'cat /tmp/lab-uhttpd.log 2>&1' | sed 's/^/    /'; exit 1; }
# Проверяем не «процесс жив», а «origin реально отвечает» — иначе стенд мог бы молча мерить
# скачивание с мёртвого сервера (тот же принцип, что у нашей connectivity-пробы).
vm_ssh "$IPB netns exec lab-srv uclient-fetch -q -T 5 -O /dev/null http://10.88.0.1/blob.bin" \
    || { echo "✗ origin не отдаёт файл внутри netns — мерить нечего"; vm_ssh 'cat /tmp/lab-uhttpd.log 2>&1' | sed 's/^/    /'; exit 1; }
echo "  ✓ лаборатория готова: origin 10.88.0.1, файл ${FILE_MB} МБ"

# ─── конфиги сервера (hysteria2 + vless-TCP) и клиентов ───────────────────────
# Серверная сторона — рукописная (это лаборатория, не наш продукт). Клиентский hysteria2-конфиг
# ГЕНЕРИРУЕТ НАШ ДВИЖОК из ссылки — мерим то, что реально поедет пользователю.
echo "→ Раскладываю движок v2 и конфиги стенда"
vm_ssh "mkdir -p /usr/share/cheburnet /etc/cheburnet /tmp/cheburnet"
tar -C "$REPO_ROOT" --exclude='engine/*/tests' --exclude='engine/*/*/tests' \
    --exclude='*README.md' -cf - engine \
    | vm_ssh "tar -C /usr/share/cheburnet -xf -"

vm_ssh "cat > /root/lab-server.json" <<'SRVCFG'
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "10.77.0.2",
      "listen_port": 8443,
      "users": [ { "password": "labpassword" } ],
      "tls": {
        "enabled": true,
        "server_name": "lab.invalid",
        "certificate_path": "/root/lab-cert.pem",
        "key_path": "/root/lab-key.pem"
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "10.77.0.2",
      "listen_port": 8444,
      "users": [ { "uuid": "11111111-2222-3333-4444-555555555555" } ]
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
SRVCFG

# Клиент TCP-эталона: тот же бинарь, тот же TUN-приём, отличается ТОЛЬКО транспорт.
vm_ssh "cat > /root/lab-client-tcp.json" <<'TCPCFG'
{
  "log": { "level": "error" },
  "inbounds": [ {
    "type": "tun", "tag": "tun-in", "interface_name": "labtun0",
    "address": [ "172.20.0.1/30" ], "mtu": 1500,
    "auto_route": false, "strict_route": false, "stack": "system"
  } ],
  "outbounds": [
    { "type": "vless", "tag": "tcp-out", "server": "10.77.0.2", "server_port": 8444,
      "uuid": "11111111-2222-3333-4444-555555555555" },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "auto_detect_interface": true, "final": "tcp-out" }
}
TCPCFG

# Клиент Hysteria2 — НАШ генератор (та же функция, что в установке). Конфиг достаём маленьким
# эмиттером на ucode, а не sed'ом по JSON: разбирать вложенный JSON регуляркой — способ получить
# «почему-то пустой файл» вместо внятной ошибки.
vm_ssh "cat > /root/emit-config.uc" <<'EMIT'
import { stdin } from "fs";
import { build_singbox_plan } from "/usr/share/cheburnet/engine/steps/singbox/singbox.uc";
let p = build_singbox_plan(stdin.read("all") ?? "", {});
if (!p.ok) { warn("emit: " + join("; ", p.errors ?? []) + "\n"); exit(1); }
print(sprintf("%J\n", p.config));
EMIT
HY2_LINK="hysteria2://labpassword@10.77.0.2:8443?sni=lab.invalid&insecure=1#lab"
vm_ssh "printf '%s' '$HY2_LINK' | ucode -R /root/emit-config.uc > /root/lab-client-hy2.json" \
    || { echo "✗ движок не сгенерировал клиентский hysteria2-конфиг"; exit 1; }
vm_ssh "sing-box check -c /root/lab-client-hy2.json" \
    || { echo "✗ наш сгенерированный hysteria2-конфиг не проходит check"; vm_ssh 'cat /root/lab-client-hy2.json'; exit 1; }
# Наш конфиг презентует TUN singtun0 — тот же, что в бою.
vm_ssh "sing-box check -c /root/lab-client-tcp.json" \
    || { echo "✗ конфиг TCP-эталона невалиден"; vm_ssh 'cat /root/lab-client-tcp.json'; exit 1; }
echo "  ✓ конфиги стенда валидны (клиентский hysteria2 — из нашего движка)"

echo "→ Поднимаю сервер стенда (hysteria2 + vless в netns lab-srv)"
vm_ssh "setsid $IPB netns exec lab-srv sing-box run -c /root/lab-server.json </dev/null >/tmp/lab-server.log 2>&1 &
        sleep 3; pgrep -f 'sing-box run -c /root/lab-server.json' >/dev/null" \
    || { echo "✗ сервер стенда не поднялся"; vm_ssh 'cat /tmp/lab-server.log'; exit 1; }

# ─── измерительные помощники ──────────────────────────────────────────────────
# netem на ОБА конца veth: потери симметричны, как в реальном плохом канале.
set_loss() {
    local pct="$1"
    if [ "$pct" = "0" ]; then
        vm_ssh "$TCB qdisc del dev lab0 root 2>/dev/null; $IPB netns exec lab-srv $TCB qdisc del dev lab1 root 2>/dev/null; true"
    else
        vm_ssh "$TCB qdisc replace dev lab0 root netem loss ${pct}% && \
                $IPB netns exec lab-srv $TCB qdisc replace dev lab1 root netem loss ${pct}%"
    fi
}

# cpu_ticks PID — utime+stime процесса (поля 14,15 /proc/PID/stat) для оценки цены транспорта.
cpu_ticks() { vm_ssh "awk '{print \$14 + \$15}' /proc/$1/stat 2>/dev/null || echo 0"; }

# Время берём из /proc/uptime в СОТЫХ СЕКУНДЫ. Почему не `date +%s%N`: busybox не умеет %N, и
# первая версия стенда из-за этого показывала «16777216 КБ/с за 1 мс» — сломанный измеритель,
# который выглядит как успех. /proc/uptime всегда несёт два знака после точки → разрешение 10 мс.
#
# ЗАМЕР — ОКНОМ ФИКСИРОВАННОЙ ДЛИТЕЛЬНОСТИ, а не «скачать файл целиком». Две причины:
#   1) `uclient-fetch -T N` — таймаут на ОДНО чтение, а не на всю передачу: при 15 % потерь
#      передача еле ползёт, но каждое чтение успевает, и замер висит бесконечно (поймано прогоном);
#   2) на большой потере «не докачалось» — плохой ответ. Скачали 3 МБ за окно — это и есть
#      goodput, и его можно сравнивать между транспортами. FAIL остаётся только для «не пришло
#      вообще ничего», то есть для реально мёртвого туннеля.
#
# Окно держим САМИ (фон + kill по счётчику), а не утилитой `timeout`: busybox в релизном образе её
# не несёт, и опора на неё превращала ВСЕ точки замера в FAIL — прогон выглядел как «стенд сломан»
# вместо «нет одной утилиты».
WINDOW_S=20

# fetch_kbs IFACE — качать origin через TUN не дольше окна; вернуть «КБ/с сотые-секунды байты»
# или FAIL, если не пришло ни байта.
# Пин host-route на TUN — тот же приём, что в нашей пробе: гарантия, что байты пошли в туннель,
# а не мимо (иначе замер мерил бы не то, что мы думаем).
fetch_kbs() {
    local iface="$1"
    vm_ssh "$IPB route replace 10.88.0.1 dev $iface 2>/dev/null
        rm -f /tmp/lab-dl /tmp/lab-fetch.err
        $IPB route get 10.88.0.1 2>/dev/null | grep -q \" dev $iface\" || {
            $IPB route del 10.88.0.1 dev $iface 2>/dev/null; echo NOROUTE; exit 0; }
        s=\$(awk '{printf \"%d\", \$1 * 100}' /proc/uptime)
        uclient-fetch -q -O /tmp/lab-dl http://10.88.0.1/blob.bin 2>/tmp/lab-fetch.err &
        fp=\$!
        i=0
        while [ \"\$i\" -lt $WINDOW_S ] && kill -0 \$fp 2>/dev/null; do sleep 1; i=\$(( i + 1 )); done
        kill \$fp 2>/dev/null
        wait \$fp 2>/dev/null
        e=\$(awk '{printf \"%d\", \$1 * 100}' /proc/uptime)
        $IPB route del 10.88.0.1 dev $iface 2>/dev/null
        sz=\$(wc -c < /tmp/lab-dl 2>/dev/null || echo 0)
        [ \"\$sz\" -gt 0 ] || { echo FAIL; exit 0; }
        cs=\$(( e - s ))
        [ \"\$cs\" -lt 1 ] && cs=1
        echo \"\$(( sz * 100 / 1024 / cs )) \$cs \$sz\"" 2>/dev/null
}

# baseline_kbs — то же скачивание БЕЗ туннеля (маршрут прямо через veth): верхняя граница стенда.
baseline_kbs() {
    vm_ssh "$IPB route replace 10.88.0.1 via 10.77.0.2 dev lab0 2>/dev/null
        rm -f /tmp/lab-dl /tmp/lab-fetch.err
        s=\$(awk '{printf \"%d\", \$1 * 100}' /proc/uptime)
        uclient-fetch -q -O /tmp/lab-dl http://10.88.0.1/blob.bin 2>/tmp/lab-fetch.err &
        fp=\$!
        i=0
        while [ \"\$i\" -lt $WINDOW_S ] && kill -0 \$fp 2>/dev/null; do sleep 1; i=\$(( i + 1 )); done
        kill \$fp 2>/dev/null
        wait \$fp 2>/dev/null
        e=\$(awk '{printf \"%d\", \$1 * 100}' /proc/uptime)
        $IPB route del 10.88.0.1 2>/dev/null
        sz=\$(wc -c < /tmp/lab-dl 2>/dev/null || echo 0)
        [ \"\$sz\" -gt 0 ] || { echo FAIL; exit 0; }
        cs=\$(( e - s ))
        [ \"\$cs\" -lt 1 ] && cs=1
        echo \"\$(( sz * 100 / 1024 / cs )) \$cs \$sz\"" 2>/dev/null
}

# start_client CFG IFACE — поднять клиентский sing-box и дождаться появления TUN. Возвращает PID.
#
# PID берём из pid-файла, который дочерний shell пишет ПЕРЕД `exec`: после exec это pid самого
# sing-box. `pgrep -f 'sing-box run -c …'` здесь НЕЛЬЗЯ — он совпадает сам с собой (его командная
# строка содержит образец), и мы получали pid уже мёртвого pgrep → CPU-колонка всегда 0. Ровно та
# же грабля, из-за которой в probe.uc запрещён -f.
start_client() {
    local cfg="$1" iface="$2"
    vm_ssh "rm -f /tmp/lab-client.pid
        setsid sh -c 'echo \$\$ > /tmp/lab-client.pid; exec sing-box run -c $cfg' \
            </dev/null >/tmp/lab-client.log 2>&1 &
        for i in \$(seq 1 20); do $IPB link show $iface >/dev/null 2>&1 && break; sleep 1; done
        $IPB link set $iface up 2>/dev/null || true
        $IPB link show $iface >/dev/null 2>&1 && cat /tmp/lab-client.pid 2>/dev/null" 2>/dev/null
}
stop_client() { vm_ssh "kill $1 2>/dev/null; sleep 1; true"; }

LOSSES="0 5 15"
RESULT_FILE="$WORK/netem-results.txt"
: > "$RESULT_FILE"

# ─── baseline без туннеля ─────────────────────────────────────────────────────
echo ""
echo "→ Baseline БЕЗ туннеля (верхняя граница стенда)"
for loss in $LOSSES; do
    set_loss "$loss"
    r="$(baseline_kbs)"
    case "$r" in
        FAIL) echo "  loss ${loss}%: FAIL (не пришло ни байта)"; echo "baseline $loss FAIL 0" >> "$RESULT_FILE" ;;
        *) set -- $r; echo "  loss ${loss}%: $1 КБ/с (${2} сотых сек, $(( $3 / 1048576 )) МБ)"; echo "baseline $loss $1 0" >> "$RESULT_FILE" ;;
    esac
done
set_loss 0

# ─── измерение по транспортам ─────────────────────────────────────────────────
measure_transport() { # NAME CFG IFACE
    local name="$1" cfg="$2" iface="$3"
    echo ""
    echo "→ $name"
    local pid
    pid="$(start_client "$cfg" "$iface")"
    if [ -z "$pid" ]; then
        echo "  ✗ клиент не поднялся ($name) — стенд сломан"
        vm_ssh 'tail -20 /tmp/lab-client.log' || true
        return 1
    fi
    for loss in $LOSSES; do
        set_loss "$loss"
        local t0 t1 r
        t0="$(cpu_ticks "$pid")"
        r="$(fetch_kbs "$iface")"
        t1="$(cpu_ticks "$pid")"
        local cpu=$(( t1 - t0 ))
        case "$r" in
            NOROUTE)
                # Маршрут не лёг на TUN → мы бы измерили ПРЯМОЙ путь и записали его как туннель.
                # Тот же принцип, что в нашей connectivity-пробе: сначала докажи, что путь тот.
                echo "  ✗ loss ${loss}%: пин маршрута на $iface не применился — замер был бы не про туннель"
                echo "$name $loss FAIL $cpu" >> "$RESULT_FILE" ;;
            FAIL)
                echo "  loss ${loss}%: FAIL (не пришло ни байта), CPU ${cpu} тиков"
                echo "$name $loss FAIL $cpu" >> "$RESULT_FILE" ;;
            *)
                set -- $r
                echo "  loss ${loss}%: $1 КБ/с (${2} сотых сек, $(( $3 / 1048576 )) МБ), CPU ${cpu} тиков"
                echo "$name $loss $1 $cpu" >> "$RESULT_FILE" ;;
        esac
    done
    set_loss 0
    stop_client "$pid"
}

measure_transport "hysteria2-QUIC" /root/lab-client-hy2.json singtun0 || exit 1
measure_transport "vless-TCP" /root/lab-client-tcp.json labtun0 || exit 1

# ─── здравость стенда: без потерь оба транспорта ОБЯЗАНЫ довезти файл ─────────
echo ""
echo "→ Проверка здравости стенда (при loss 0% файл обязан доехать через оба туннеля)"
bad=0
for name in hysteria2-QUIC vless-TCP; do
    v="$(awk -v n="$name" '$1==n && $2==0 { print $3 }' "$RESULT_FILE")"
    if [ "$v" = "FAIL" ] || [ -z "$v" ]; then
        echo "  ✗ через $name не прошло ни байта даже без потерь — стенд сломан"
        echo "    stderr последнего скачивания:"; vm_ssh 'cat /tmp/lab-fetch.err 2>/dev/null | tail -5' | sed 's/^/      /'
        bad=1
    else
        echo "  ✓ $name: $v КБ/с при 0% потерь"
    fi
done
[ "$bad" -eq 0 ] || { vm_ssh 'tail -20 /tmp/lab-server.log' || true; exit 1; }

# ─── сводка: во сколько раз просела скорость ──────────────────────────────────
echo ""
echo "════ СВОДКА ЗАМЕРА (x86_64 в QEMU; на ARM цифры будут ниже — там узкое место CPU) ════"
printf '%-16s %8s %12s %10s %10s\n' "транспорт" "loss" "goodput" "CPU" "от 0%"
awk '
    { key = $1 SUBSEP $2; val[key] = $3; cpu[key] = $4; if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 } }
    END {
        split("0 5 15", losses, " ")
        for (i = 1; i <= n; i++) {
            name = order[i]
            base = val[name SUBSEP 0]
            for (j = 1; j <= 3; j++) {
                l = losses[j]
                v = val[name SUBSEP l]
                if (v == "" ) continue
                if (v == "FAIL") { rel = "—" }
                else if (base != "FAIL" && base + 0 > 0) { rel = sprintf("%d%%", (v * 100) / base) }
                else { rel = "—" }
                printf "%-16s %7s%% %9s КБ/с %7s тк %10s\n", name, l, v, cpu[name SUBSEP l], rel
            }
        }
    }
' "$RESULT_FILE"

echo ""
echo "Как читать: колонка «от 0%» — какая доля скорости осталась при потерях. Если QUIC держится"
echo "заметно лучше TCP на 5–15 % — это и есть польза Hysteria2 на плохом канале. Если нет —"
echo "результат ЧЕСТНО заносится в ADR 0004 как есть, а не прячется."
echo ""
echo "НЕ входит в замер: AmneziaWG (нужен второй netns с kmod-amneziawg и awg-парой — не"
echo "автоматизировано) и потолок на целевом ARM (нужно железо)."
echo ""
echo "✓ T3f-v2 NETEM-СТЕНД ОТРАБОТАЛ: цифры выше — материал для ADR 0004, раздел «Замеры»."
