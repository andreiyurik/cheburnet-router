#!/usr/bin/env bash
# tests/bootstrap-test.sh — стаб-тесты bootstrap.sh (тонкий установщик; см. install-singbox-test.sh
# — тот же приём: фейковые apk/uci/uclient-fetch на PATH, реальную сеть/систему не трогаем).
#
# Проверяем самое глючеопасное для shell-слоя: fail-closed (ничего не ставим, пока не скачано
# ВСЁ), ретраи fetch, гейт AmneziaWG по ФАКТУ пакетов (а не коду upstream-скрипта),
# переиспользование токена и нормализацию LAN_IP (список/CIDR).
#
# Запуск: bash tests/bootstrap-test.sh  (или make test-shell). ~секунды.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/bootstrap/bootstrap.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# make_env DIR — фейковый PATH-каталог со стабами. Поведение крутится файлами-ручками:
#   .fetch_fails   — сколько первых вызовов uclient-fetch «падают» (сетевой флап)
#   .installed     — вывод `apk list --installed` (какие пакеты «стоят»)
#   .awg_rc        — код выхода фейкового awg-инсталлятора (который «скачивается»)
#   .lan_ip        — что вернёт `uci get network.lan.ipaddr` (пусто = uci падает)
#   .apk_calls     — журнал вызовов apk (add/update) для ассертов
make_env() {
    local dir="$1"
    mkdir -p "$dir"
    echo 0 > "$dir/.fetch_fails"; echo 0 > "$dir/.fetch_n"
    : > "$dir/.installed"; : > "$dir/.apk_calls"
    echo 0 > "$dir/.awg_rc"; echo "192.168.1.1" > "$dir/.lan_ip"

    # uclient-fetch -T 15 -qO DEST URL: отдаёт awg-инсталлятор или «пакет», уважая .fetch_fails.
    cat > "$dir/uclient-fetch" <<EOF
#!/bin/sh
dest=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in -T) shift ;; -qO) dest="\$2"; shift ;; *) url="\$1" ;; esac
    shift
done
n=\$(cat "$dir/.fetch_n"); n=\$((n + 1)); echo "\$n" > "$dir/.fetch_n"
[ "\$n" -le "\$(cat "$dir/.fetch_fails")" ] && exit 1
case "\$url" in
  *amneziawg-install*) printf '#!/bin/sh\nexit %s\n' "\$(cat "$dir/.awg_rc")" > "\$dest" ;;
  *cheburnet.apk*)     echo "fake-apk-payload" > "\$dest" ;;
  *)                   exit 1 ;;
esac
exit 0
EOF

    # apk: list --installed из ручки, update/add — журналируем и выходим 0.
    cat > "$dir/apk" <<EOF
#!/bin/sh
if [ "\$1" = "list" ]; then cat "$dir/.installed"; exit 0; fi
echo "\$*" >> "$dir/.apk_calls"
exit 0
EOF

    # uci -q get network.lan.ipaddr — из ручки; пустая ручка = «ключа нет» (rc 1).
    cat > "$dir/uci" <<EOF
#!/bin/sh
v=\$(cat "$dir/.lan_ip")
[ -n "\$v" ] || exit 1
echo "\$v"
EOF

    # wget — всегда провал: fetch() предпочитает uclient-fetch, а фолбэк на РЕАЛЬНЫЙ wget хоста
    # утащил бы настоящие файлы из сети и сломал герметичность (поймано первым же прогоном).
    printf '#!/bin/sh\nexit 1\n' > "$dir/wget"
    printf '#!/bin/sh\nexit 0\n' > "$dir/sleep" # ретраи без реальных пауз
    chmod +x "$dir"/uclient-fetch "$dir"/apk "$dir"/uci "$dir"/sleep "$dir"/wget
}

# run_bootstrap DIR → код выхода; stdout+stderr в $DIR/out.log; ETC изолирован в $DIR/etc.
run_bootstrap() {
    local dir="$1"
    PATH="$dir:/usr/bin:/bin" CHEBURNET_ETC="$dir/etc" \
        sh "$SCRIPT" > "$dir/out.log" 2>&1
}

installed_ok() { printf 'kmod-amneziawg-1.0\namneziawg-tools-1.0\n' > "$1/.installed"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "── bootstrap.sh: стаб-тесты ──"

# 1. Happy path: всё скачивается, пакеты «встают» → ссылка с токеном, токен сохранён.
d="$T/happy"; make_env "$d"; installed_ok "$d"
if run_bootstrap "$d" && grep -q 'http://192.168.1.1/cheburnet/?token=' "$d/out.log" \
   && [ -s "$d/etc/install-token" ]; then
    ok "happy path: ссылка мастера напечатана, токен сохранён"
else bad "happy path (см. $d/out.log)"; fi

# 2. Fail-closed: пакет не скачивается совсем → ничего не установлено (apk add не вызывался).
d="$T/failclosed"; make_env "$d"; installed_ok "$d"; echo 99 > "$d/.fetch_fails"
if ! run_bootstrap "$d" && ! grep -q 'add' "$d/.apk_calls"; then
    ok "fail-closed: провал скачивания до единого apk add"
else bad "fail-closed: что-то ставилось при недоступной сети"; fi

# 3. Ретраи fetch: два флапа, третий успех → установка доходит до конца.
d="$T/retry"; make_env "$d"; installed_ok "$d"; echo 2 > "$d/.fetch_fails"
if run_bootstrap "$d"; then
    ok "ретраи fetch: два флапа сети пережиты"
else bad "ретраи fetch (см. $d/out.log)"; fi

# 4. Гейт AmneziaWG по факту: upstream-скрипт выходит с 1, но пакеты стоят → не умираем.
#    (живой шрам GL-MT3000: awg-openwrt делает exit 1 из-за luci-proto, поставив нужное.)
d="$T/awgfact"; make_env "$d"; installed_ok "$d"; echo 1 > "$d/.awg_rc"
if run_bootstrap "$d"; then
    ok "AmneziaWG: exit 1 upstream-скрипта не валит установку, если пакеты встали"
else bad "AmneziaWG: гейтим по коду выхода вместо факта пакетов"; fi

# 5. И наоборот: скрипт «успешен», но пакетов НЕТ → честный провал с понятным сообщением.
d="$T/awgmiss"; make_env "$d"
if ! run_bootstrap "$d" && grep -q 'не установились' "$d/out.log"; then
    ok "AmneziaWG: нет пакетов по факту → честный провал"
else bad "AmneziaWG: отсутствие пакетов прошло незамеченным"; fi

# 6. Токен переиспользуется: засеянный токен не перезаписывается, ссылка содержит его же.
d="$T/token"; make_env "$d"; installed_ok "$d"
mkdir -p "$d/etc"; echo "SEEDED-TOKEN" > "$d/etc/install-token"
if run_bootstrap "$d" && grep -q 'token=SEEDED-TOKEN' "$d/out.log" \
   && [ "$(cat "$d/etc/install-token")" = "SEEDED-TOKEN" ]; then
    ok "токен: существующий переиспользован (повторный запуск даёт ту же ссылку)"
else bad "токен: засеянный токен потерян или ссылка с другим"; fi

# 7. LAN_IP: список в CIDR-форме → в ссылке первый адрес без маски.
d="$T/lanip"; make_env "$d"; installed_ok "$d"
echo "192.168.8.1/24 fd00::1/64" > "$d/.lan_ip"
if run_bootstrap "$d" && grep -q 'http://192.168.8.1/cheburnet/' "$d/out.log"; then
    ok "LAN_IP: '192.168.8.1/24 …' нормализован в 192.168.8.1"
else bad "LAN_IP: CIDR/список сломал ссылку (см. $d/out.log)"; fi

# 8. uci без ключа → фолбэк 192.168.1.1 (а не пустой хост в ссылке).
d="$T/lanmiss"; make_env "$d"; installed_ok "$d"; : > "$d/.lan_ip"
if run_bootstrap "$d" && grep -q 'http://192.168.1.1/cheburnet/' "$d/out.log"; then
    ok "LAN_IP: нет ключа в uci → фолбэк 192.168.1.1"
else bad "LAN_IP: фолбэк не сработал"; fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
