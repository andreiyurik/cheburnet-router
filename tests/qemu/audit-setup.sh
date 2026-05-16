#!/bin/bash
# tests/qemu/audit-setup.sh — разовый audit всех setup-шагов 00→10 на VM.
#
# Отличие от install.sh: НЕ exit-on-first-fail. Гоняем КАЖДЫЙ шаг отдельно,
# собираем по каждому: rc, stdout/stderr, видимые маркеры ошибок. Цель — за
# один прогон вытащить максимум багов, а не остановиться на первом x86-fail.
#
# Логи: tests/qemu/.work/audit-logs/NN-*.log + сводная таблица в конце.

set -u

. "$(dirname "$0")/lib.sh"

vm_lib_init
vm_prepare_image
vm_start
vm_boot_and_setup

LOGDIR="$WORK/audit-logs"
rm -rf "$LOGDIR" && mkdir -p "$LOGDIR"

# === Заливаем репо в /opt/cheburnet (имитация install.sh) ===
echo "→ Заливаю репо в /opt/cheburnet"
vm_ssh "mkdir -p /opt/cheburnet /tmp/cheburnet /etc/cheburnet /etc/amnezia/amneziawg /usr/libexec/rpcd /usr/share/rpcd/acl.d"

tar -C "$REPO_ROOT" -czf - \
    --exclude='.git' --exclude='tests' --exclude='docs' \
    --exclude='backup' --exclude='assets' --exclude='*.md' \
    setup scripts configs lib web vendor 2>/dev/null \
    | vm_ssh "tar -C /opt/cheburnet -xzf -"

# === Manifest application (как делает install.sh) ===
echo "→ Применяю manifest"
vm_ssh '
INSTALL_DIR=/opt/cheburnet
MANIFEST=$INSTALL_DIR/setup/manifest.txt
missing=0
while read src dst mode; do
    case "$src" in ""|\#*) continue;; esac
    full_src="$INSTALL_DIR/$src"
    if [ ! -f "$full_src" ]; then
        echo "  MANIFEST-MISSING: $src"
        missing=$((missing + 1))
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$full_src" "$dst" && chmod "$mode" "$dst"
done < "$MANIFEST"
echo "  manifest: missing=$missing"
' 2>&1 | tee "$LOGDIR/00-manifest.log"

# === awg0.conf (валидный синтаксис, нерабочий endpoint) ===
vm_ssh "cat > /etc/amnezia/amneziawg/awg0.conf" <<'EOF'
[Interface]
Address = 10.7.0.2/32
DNS = 1.1.1.1
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
ListenPort = 51820
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 50
S2 = 100
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:51820
PersistentKeepalive = 25
EOF
vm_ssh "chmod 600 /etc/amnezia/amneziawg/awg0.conf"

# === wireless-actual.txt ===
vm_ssh "cat > /opt/cheburnet/configs/wireless-actual.txt" <<'EOF'
WIFI_SSID="cheburnet-test"
WIFI_KEY="testpassword123"
WIFI_COUNTRY="RU"
EOF

# === Preflight (как install.sh — отдельный шаг) ===
echo
echo "═══ preflight ═══"
vm_ssh '
. /opt/cheburnet/lib/cheburnet-preflight.sh 2>&1
echo "--- flash ---"
cheburnet_preflight_flash; echo "RC=$?"
echo "--- ram ---"
cheburnet_preflight_ram; echo "RC=$?"
echo "--- internet ---"
cheburnet_preflight_internet; echo "RC=$?"
echo "--- arch ---"
cheburnet_preflight_arch; echo "RC=$?"
' 2>&1 | tee "$LOGDIR/00-preflight.log"

# === Гоняем каждый шаг отдельно. continue-on-fail ===
STEPS="00-prerequisites 01-amneziawg 02-podkop 03-adblock 04-dns 05-wifi 06-vpn-mode 07-killswitch 08-watchdog 09-ssh-hardening 10-quality"

# Резюме копится здесь для финального вывода.
declare -A STEP_RC
declare -A STEP_ERR
declare -A STEP_WARN

for STEP in $STEPS; do
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo "  STEP: $STEP"
    echo "═══════════════════════════════════════════════════════════"

    LOG="$LOGDIR/$STEP.log"

    # Каждый шаг — отдельный sh invocation, с тем же env, что install.sh передаёт.
    # Маркер __RC=N в конце — единственный надёжный способ вытащить exit-code
    # из vm_ssh stream'а (vm_ssh сам возвращает 0 если последняя команда не
    # упала, а наша последняя — echo маркера).
    vm_ssh "
        export CHEBURNET_KEY_REQUIRED=0
        . /opt/cheburnet/configs/wireless-actual.txt
        export WIFI_SSID WIFI_KEY
        sh /opt/cheburnet/setup/$STEP.sh
        echo \"__RC=\$?\"
    " > "$LOG" 2>&1

    rc=$(grep '^__RC=' "$LOG" | tail -1 | sed 's/__RC=//')
    [ -z "$rc" ] && rc="?"
    # Маркеры: ✗, ERROR, FAIL — реальная ошибка; ⚠ — предупреждение
    err=$(grep -cE '(^|[[:space:]])✗|ERROR|^FAIL' "$LOG" 2>/dev/null || echo 0)
    warn=$(grep -cE '(^|[[:space:]])⚠' "$LOG" 2>/dev/null || echo 0)

    STEP_RC[$STEP]=$rc
    STEP_ERR[$STEP]=$err
    STEP_WARN[$STEP]=$warn

    echo "  → RC=$rc  ERR=$err  WARN=$warn  (лог: $LOG)"

    # Покажем первые ошибки сразу — чтобы видно было живой progress.
    if [ "$err" != "0" ]; then
        echo "  ─── первые маркеры ✗/ERROR/FAIL ───"
        grep -nE '(^|[[:space:]])✗|ERROR|^FAIL' "$LOG" | head -5 | sed 's/^/    /'
    fi
done

# === Сводный отчёт ===
echo
echo "════════════════════════════════════════════════════════════════"
echo "                       СВОДНЫЙ ОТЧЁТ"
echo "════════════════════════════════════════════════════════════════"
printf "  %-22s %-5s %-5s %s\n" "STEP" "RC" "ERR" "WARN"
echo  "  ────────────────────── ───── ───── ────"
for STEP in $STEPS; do
    printf "  %-22s %-5s %-5s %s\n" \
        "$STEP" \
        "${STEP_RC[$STEP]}" \
        "${STEP_ERR[$STEP]}" \
        "${STEP_WARN[$STEP]}"
done

echo
echo "Логи: $LOGDIR/"
echo "Готово."
