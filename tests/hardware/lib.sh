#!/bin/bash
# tests/hardware/lib.sh — T4 hardware test library
#
# Source it from a phase script:
#
#     . "$(dirname "$0")/lib.sh"
#     hw_init "$@"
#     report_init "phase 1"
#     check_xxx
#     check_yyy
#     report_summary
#
# Each check_* function is self-reporting (calls report_pass / report_fail /
# report_warn) and returns 0/1. Phase scripts don't have to inspect return
# codes; they invoke checks linearly.
#
# Output: [PASS] / [FAIL] / [WARN] / [INFO]. Greppable. Colorised only on TTY.

set -u

# ─── Colours (TTY-only) ──────────────────────────────────────────────────────
if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; N=''
fi

# ─── Globals ─────────────────────────────────────────────────────────────────
ROUTER="${ROUTER:-root@192.168.1.1}"
BRANCH="${BRANCH:-master}"
HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${FIXTURES_DIR:-$HW_DIR/fixtures}"

# Per-phase counters
PHASE_NAME=""
PHASE_PASS=0
PHASE_FAIL=0
PHASE_WARN=0
PHASE_FAILED=""

# Cross-phase accumulators (read by run-all.sh)
RUN_TOTAL_PASS=0
RUN_TOTAL_FAIL=0
RUN_TOTAL_WARN=0

# ─── SSH wrappers ────────────────────────────────────────────────────────────
# A throwaway known_hosts file: every firstboot rotates the dropbear host key,
# so persistent known_hosts only gets in the way.
HW_KNOWN_HOSTS="${HW_KNOWN_HOSTS:-/tmp/cheburnet-hw-known_hosts}"
SSH_OPTS=(-o ConnectTimeout=10
          -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$HW_KNOWN_HOSTS"
          -o LogLevel=ERROR
          -o BatchMode=yes)
# If you keep a dedicated key for the router (e.g. ~/.ssh/beryl) — point at it
# via HW_SSH_KEY. Without this, ssh defaults to id_rsa/id_ed25519 and silently
# falls back to password auth (which BatchMode=yes refuses → "Permission
# denied (publickey)").
if [ -n "${HW_SSH_KEY:-}" ]; then
    SSH_OPTS+=(-i "$HW_SSH_KEY" -o IdentitiesOnly=yes)
fi

ssh_router()       { ssh "${SSH_OPTS[@]}" "$ROUTER" "$@"; }
ssh_router_quiet() { ssh "${SSH_OPTS[@]}" "$ROUTER" "$@" 2>/dev/null; }

# Push a local file to the router via ssh+cat — NOT scp.
#
# Why not scp: dropbear on OpenWrt doesn't ship `sftp-server`, and modern
# scp speaks sftp by default. The transfer fails with "sftp-server: not
# found / Connection closed". The ssh+cat redirect is binary-safe and
# proto-independent. Same trick tests/qemu/lib.sh::vm_scp uses.
scp_to_router() {
    local local_path=$1 remote_path=$2
    ssh "${SSH_OPTS[@]}" "$ROUTER" "cat > '$remote_path'" < "$local_path"
}

# ─── Reporting ───────────────────────────────────────────────────────────────
_report() {
    local kind=$1 name=$2 msg=$3
    case "$kind" in
        pass)
            printf '%s[PASS]%s %s: %s\n' "$G" "$N" "$name" "$msg"
            PHASE_PASS=$((PHASE_PASS + 1))
            ;;
        fail)
            printf '%s[FAIL]%s %s: %s\n' "$R" "$N" "$name" "$msg"
            PHASE_FAIL=$((PHASE_FAIL + 1))
            PHASE_FAILED="${PHASE_FAILED}${name}|${msg}
"
            ;;
        warn)
            printf '%s[WARN]%s %s: %s\n' "$Y" "$N" "$name" "$msg"
            PHASE_WARN=$((PHASE_WARN + 1))
            ;;
        info)
            printf '[INFO] %s: %s\n' "$name" "$msg"
            ;;
    esac
}

report_pass() { _report pass "$1" "$2"; return 0; }
report_fail() { _report fail "$1" "$2"; return 1; }
report_warn() { _report warn "$1" "$2"; return 0; }
report_info() { _report info "$1" "$2"; return 0; }

report_init() {
    PHASE_NAME="$1"
    PHASE_PASS=0
    PHASE_FAIL=0
    PHASE_WARN=0
    PHASE_FAILED=""
    printf '\n%s\n' "════════════════════════════════════════════════════════════"
    printf ' %s\n' "$PHASE_NAME"
    printf '%s\n\n' "════════════════════════════════════════════════════════════"
}

report_summary() {
    local total=$((PHASE_PASS + PHASE_FAIL))
    printf '\n'
    if [ "$PHASE_FAIL" -eq 0 ]; then
        printf '%s✓%s %s: PASS (%d/%d)' "$G" "$N" "$PHASE_NAME" "$PHASE_PASS" "$total"
    else
        printf '%s✗%s %s: FAIL (%d/%d)' "$R" "$N" "$PHASE_NAME" "$PHASE_PASS" "$total"
    fi
    [ "$PHASE_WARN" -gt 0 ] && printf ' (%d warnings)' "$PHASE_WARN"
    printf '\n'
    if [ -n "$PHASE_FAILED" ]; then
        printf '  Failures:\n'
        printf '%s' "$PHASE_FAILED" | while IFS='|' read -r fname fmsg; do
            [ -z "$fname" ] && continue
            printf '    - %s: %s\n' "$fname" "$fmsg"
        done
    fi
    RUN_TOTAL_PASS=$((RUN_TOTAL_PASS + PHASE_PASS))
    RUN_TOTAL_FAIL=$((RUN_TOTAL_FAIL + PHASE_FAIL))
    RUN_TOTAL_WARN=$((RUN_TOTAL_WARN + PHASE_WARN))
    return "$PHASE_FAIL"
}

# ─── Init ────────────────────────────────────────────────────────────────────
hw_init() {
    [ "${1:-}" ] && ROUTER="$1"
    [ "${2:-}" ] && BRANCH="$2"
    : >"$HW_KNOWN_HOSTS"
    command -v ssh     >/dev/null 2>&1 || { echo "✗ ssh not in PATH"     >&2; exit 1; }
    command -v scp     >/dev/null 2>&1 || { echo "✗ scp not in PATH"     >&2; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "✗ python3 not in PATH" >&2; exit 1; }
    # BRANCH and ROUTER end up interpolated into ssh "..." command strings.
    # Constrain to safe alphabets to make any future shell-injection mistake
    # easier to spot in code review.
    case "$BRANCH" in
        *[!a-zA-Z0-9._/-]*) echo "✗ BRANCH has unsafe chars: '$BRANCH'" >&2; exit 1 ;;
    esac
    case "$ROUTER" in
        *[!a-zA-Z0-9._@-]*) echo "✗ ROUTER has unsafe chars: '$ROUTER'" >&2; exit 1 ;;
    esac
}

# ─── Reboot ──────────────────────────────────────────────────────────────────
#
# Note: there is no automated firstboot_reset in this framework. factoryreset
# wipes /root/.ssh/authorized_keys along with /overlay/upper, leaving the
# router unreachable from any test driver. Mirroring the real-user workflow,
# we treat fresh-OpenWrt-with-SSH-access as a manual *precondition* (LuCI
# setup or USB-tether bootstrap, exactly what a new user does) and assert it
# in phase 0. T4 then takes over from "SSH-accessible fresh OpenWrt", which
# is precisely where a real user starts their cheburnet journey.
#
# reboot_only is still here — a plain reboot does NOT wipe SSH, so phase 6's
# cold-boot recovery check is safe to automate.

reboot_only() {
    report_info reboot_only "issuing reboot on $ROUTER"
    ssh_router 'reboot' >/dev/null 2>&1 || :
    sleep 30
    wait_router_ssh 240
}

wait_router_ssh() {
    local timeout=${1:-300}
    local start
    start=$(date +%s)
    local elapsed=0
    report_info wait_router_ssh "polling SSH up to ${timeout}s"
    while [ "$elapsed" -lt "$timeout" ]; do
        if ssh_router_quiet 'echo ready' >/dev/null 2>&1; then
            report_info wait_router_ssh "ready after ${elapsed}s"
            sleep 3
            return 0
        fi
        sleep 5
        elapsed=$(($(date +%s) - start))
    done
    report_fail wait_router_ssh "no SSH after ${timeout}s"
    return 1
}

wait_for_install_done() {
    local timeout=${1:-1200}
    local start elapsed=0 last_state=""
    start=$(date +%s)
    report_info wait_for_install_done "polling /tmp/cheburnet/done (max ${timeout}s)"
    while [ "$elapsed" -lt "$timeout" ]; do
        if ssh_router_quiet '[ -f /tmp/cheburnet/done ]'; then
            local code
            code=$(ssh_router 'cat /tmp/cheburnet/done')
            report_info wait_for_install_done "done=${code} (after ${elapsed}s)"
            return 0
        fi
        local state
        state=$(ssh_router_quiet 'cat /tmp/cheburnet/state 2>/dev/null' || echo '?')
        if [ -n "$state" ] && [ "$state" != "$last_state" ]; then
            report_info wait_for_install_done "$state (${elapsed}s)"
            last_state="$state"
        fi
        sleep 10
        elapsed=$(($(date +%s) - start))
    done
    report_fail wait_for_install_done "timeout ${timeout}s, last state='$last_state'"
    return 1
}

# ─── Bootstrap / install drivers ─────────────────────────────────────────────
# Deploys the LOCAL working tree to the router and stands up the web master —
# exactly the side effect install.sh produces, minus the GitHub download.
#
# Rationale: T4 should validate the code in front of us, not whatever happens
# to be on origin. Going through wget|sh adds a network dependency, requires
# the dev branch to be pushed, and obscures which version is under test.
# Mirrors the tar|ssh pattern in setup.sh:316-326 (rsync excluded — dropbear
# ships rsync inconsistently across vendors; tar|ssh works everywhere).
run_bootstrap() {
    local branch=${1:-$BRANCH}
    local repo_root="${HW_DIR%/tests/hardware}"
    report_info run_bootstrap "deploy local working tree → $ROUTER (branch ref: $branch)"

    # 1. Stage directories on the router.
    ssh_router 'set -e
        mkdir -p /opt/cheburnet /etc/cheburnet /tmp/cheburnet \
                 /www/cheburnet /usr/libexec/rpcd /usr/share/rpcd/acl.d
        rm -rf /opt/cheburnet/* 2>/dev/null || true' || return 1

    # 2. Stream the repo via tar over ssh. Exclude same paths as setup.sh plus
    # dev-side dotdirs that have no business on the router. Note: `.*` as a
    # tar exclude matches `.` (the archive root) and silently drops the entire
    # tree — keep the list explicit.
    if ! tar -C "$repo_root" -czf - \
            --exclude='.git' --exclude='.github' --exclude='.idea' \
            --exclude='.claude' --exclude='.gitignore' --exclude='.gitmodules' \
            --exclude='tests' --exclude='docs' \
            --exclude='backup' --exclude='assets' --exclude='*.md' \
            . | ssh "${SSH_OPTS[@]}" "$ROUTER" 'tar -C /opt/cheburnet -xzf -'; then
        return 1
    fi

    # 3. Reproduce install.sh's web-master setup (sections 4–9).
    ssh_router 'set -e
        apk update >/dev/null 2>&1
        apk add --no-interactive uhttpd-mod-ubus rpcd jsonfilter >/dev/null 2>&1 || true
        cp /opt/cheburnet/web/rpcd-cheburnet /usr/libexec/rpcd/cheburnet
        chmod +x /usr/libexec/rpcd/cheburnet
        cp /opt/cheburnet/web/rpcd-acl.json  /usr/share/rpcd/acl.d/cheburnet.json
        cp /opt/cheburnet/web/index.html     /www/cheburnet/index.html
        chmod +x /opt/cheburnet/setup/*.sh /opt/cheburnet/scripts/* 2>/dev/null || true
        if ! uci -q get uhttpd.main.ubus_prefix >/dev/null; then
            uci set uhttpd.main.ubus_prefix=/ubus
            uci commit uhttpd
        fi
        head -c 16 /dev/urandom | hexdump -e "16/1 \"%02x\"" > /etc/cheburnet/install-token
        chmod 600 /etc/cheburnet/install-token
        /etc/init.d/rpcd enable    >/dev/null 2>&1
        /etc/init.d/rpcd restart   >/dev/null 2>&1
        /etc/init.d/uhttpd enable  >/dev/null 2>&1
        /etc/init.d/uhttpd restart >/dev/null 2>&1
    ' || return 1

    sleep 3
    return 0
}

# Kick off the full install via the install_start RPC — exactly what the
# web wizard does. Returns 0 on accepted call, 1 otherwise; the install runs
# in the background and is monitored via wait_for_install_done.
trigger_install_via_rpc() {
    local awg_conf=$1 ssid=$2 wifi_key=$3 country=$4 root_pass=$5
    if [ ! -f "$awg_conf" ]; then
        report_fail trigger_install_via_rpc "awg.conf not found at $awg_conf"
        return 1
    fi
    local token
    token=$(ssh_router 'cat /etc/cheburnet/install-token 2>/dev/null') || true
    if [ -z "$token" ]; then
        report_fail trigger_install_via_rpc "no install-token on router — bootstrap didn't run?"
        return 1
    fi
    local payload
    payload=$(mktemp)
    AWG_PATH="$awg_conf" SSID="$ssid" WIFI_KEY="$wifi_key" \
    COUNTRY="$country" ROOT_PASS="$root_pass" TOKEN="$token" \
    python3 - >"$payload" <<'PY'
import json, os
with open(os.environ['AWG_PATH']) as f:
    awg = f.read()
print(json.dumps({
    'ssid':      os.environ['SSID'],
    'wifi_key':  os.environ['WIFI_KEY'],
    'country':   os.environ['COUNTRY'],
    'awg_conf':  awg,
    'root_pass': os.environ['ROOT_PASS'],
    'token':     os.environ['TOKEN'],
}))
PY
    scp_to_router "$payload" /tmp/cheburnet-install.json >/dev/null
    rm -f "$payload"
    if ssh_router 'ubus -t 30 call cheburnet install_start "$(cat /tmp/cheburnet-install.json)"' >/dev/null 2>&1; then
        ssh_router 'rm -f /tmp/cheburnet-install.json' 2>/dev/null || true
        report_pass trigger_install_via_rpc "install_start accepted"
        return 0
    fi
    ssh_router 'rm -f /tmp/cheburnet-install.json' 2>/dev/null || true
    report_fail trigger_install_via_rpc "ubus install_start rejected"
    return 1
}

# Direct install (bypasses RPC and the install-token). Used by phase 4
# fault-injection where we want to control awg.conf precisely without going
# through the web wizard.
prepare_direct_install() {
    local awg_conf=$1 ssid=$2 wifi_key=$3 country=$4
    if [ ! -f "$awg_conf" ]; then
        report_fail prepare_direct_install "awg.conf not found at $awg_conf"
        return 1
    fi
    # We embed these in a single-quoted heredoc on the remote side. A literal
    # single quote in any of them would close the quoting prematurely. The
    # values are test fixtures we control; reject early instead of producing
    # cryptic remote errors.
    for v in "$ssid" "$wifi_key" "$country"; do
        case "$v" in
            *"'"*) report_fail prepare_direct_install "value contains single quote, refusing: $v"; return 1 ;;
        esac
    done
    ssh_router 'mkdir -p /etc/amnezia/amneziawg'
    scp_to_router "$awg_conf" /etc/amnezia/amneziawg/awg0.conf >/dev/null
    ssh_router "mkdir -p /opt/cheburnet/configs && cat >/opt/cheburnet/configs/wireless-actual.txt <<EOF
WIFI_SSID='$ssid'
WIFI_KEY='$wifi_key'
WIFI_COUNTRY='$country'
EOF"
    return 0
}

trigger_install_direct() {
    report_info trigger_install_direct "spawning /opt/cheburnet/setup/install.sh in background"
    ssh_router 'mkdir -p /tmp/cheburnet; setsid sh /opt/cheburnet/setup/install.sh \
        >/tmp/cheburnet/install.log 2>&1 </dev/null &' || true
}

# ─── STATE / clean-system checks ─────────────────────────────────────────────
check_clean_state() {
    local found=""
    for p in /opt/cheburnet /etc/amnezia /etc/init.d/podkop /etc/init.d/sing-box \
             /etc/init.d/adblock-lean /usr/bin/vpn-mode; do
        if ssh_router_quiet "[ -e $p ]"; then
            found="$found $p"
        fi
    done
    if [ -z "$found" ]; then
        report_pass check_clean_state "no cheburnet artifacts"
    else
        report_fail check_clean_state "stale paths:$found"
    fi
}

check_wan_up() {
    local dev ip
    dev=$(ssh_router 'uci -q get network.wan.device') || true
    if [ -z "$dev" ]; then
        report_fail check_wan_up "network.wan.device not set"
        return 1
    fi
    ip=$(ssh_router "ip -4 addr show '$dev' 2>/dev/null | awk '/inet /{print \$2; exit}'") || true
    if [ -z "$ip" ]; then
        report_fail check_wan_up "no IPv4 on $dev"
        return 1
    fi
    report_pass check_wan_up "$dev → $ip"
}

check_overlay_size() {
    local kb mb
    kb=$(ssh_router "df /overlay 2>/dev/null | awk 'NR==2{print \$4}'") || true
    if [ -z "$kb" ]; then
        report_fail check_overlay_size "df /overlay failed"
        return 1
    fi
    mb=$((kb / 1024))
    if [ "$mb" -lt 100 ]; then
        report_fail check_overlay_size "${mb}MB free (< 100MB)"
        return 1
    fi
    report_pass check_overlay_size "${mb}MB free on /overlay"
}

check_ram_total() {
    local kb mb
    kb=$(ssh_router "awk '/MemTotal/{print \$2}' /proc/meminfo") || true
    if [ -z "$kb" ]; then
        report_fail check_ram_total "couldn't read /proc/meminfo"
        return 1
    fi
    mb=$((kb / 1024))
    if [ "$mb" -lt 200 ]; then
        report_fail check_ram_total "${mb}MB RAM (< 200MB)"
        return 1
    fi
    report_pass check_ram_total "${mb}MB RAM total"
}

check_internet_https() {
    # 3 attempts with backoff. Found necessary on flaky uplinks (alt-networks,
    # mobile-tethered WAN) where a single TLS handshake can stall but the
    # next succeeds within seconds. One transient failure here would hard-
    # abort the entire run.
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        if ssh_router 'wget -qO /dev/null --timeout=15 \
            https://raw.githubusercontent.com/yurik2718/cheburnet-router/master/install.sh' >/dev/null 2>&1; then
            if [ "$attempt" -eq 0 ]; then
                report_pass check_internet_https "https raw.github reachable"
            else
                report_pass check_internet_https "https raw.github reachable (after $((attempt + 1)) attempts)"
            fi
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -lt 3 ] && sleep $((attempt * 5))
    done
    report_fail check_internet_https "wget https failed after 3 attempts (network unstable?)"
}

check_openwrt_version() {
    local ver
    ver=$(ssh_router "awk -F'=' '/DISTRIB_RELEASE/{gsub(/[\"\\047]/,\"\",\$2); print \$2}' /etc/openwrt_release") || true
    if [ -z "$ver" ]; then
        report_fail check_openwrt_version "couldn't read /etc/openwrt_release"
        return 1
    fi
    case "$ver" in
        25.*|26.*|SNAPSHOT) report_pass check_openwrt_version "$ver" ;;
        *)                  report_warn check_openwrt_version "$ver — recommended ≥25.12" ;;
    esac
}

# ─── Install / done-state checks ─────────────────────────────────────────────
check_bootstrap_succeeded() {
    if ssh_router '[ -x /opt/cheburnet/setup/install.sh ] && [ -f /etc/cheburnet/install-token ]'; then
        report_pass check_bootstrap_succeeded "/opt/cheburnet + install-token present"
    else
        report_fail check_bootstrap_succeeded "bootstrap artefacts missing"
    fi
}

check_install_done_ok() { check_install_done_matches ok; }

check_install_done_matches() {
    local expected=${1:-ok} actual
    actual=$(ssh_router 'cat /tmp/cheburnet/done 2>/dev/null') || true
    if [ "$actual" = "$expected" ]; then
        report_pass check_install_done_matches "done=$actual"
    else
        report_fail check_install_done_matches "expected '$expected', got '$actual'"
    fi
}

check_state_file_format() {
    local state
    state=$(ssh_router 'cat /tmp/cheburnet/state 2>/dev/null') || true
    case "$state" in
        '[done]'|'[fail-'*|'[STEP] '*) report_pass check_state_file_format "state=$state" ;;
        *)                              report_fail check_state_file_format "unexpected state='$state'" ;;
    esac
}

# ─── AmneziaWG ───────────────────────────────────────────────────────────────
check_awg_interface_up() {
    if ssh_router 'ip addr show awg0 2>/dev/null | grep -q "inet "'; then
        local addr
        addr=$(ssh_router "ip addr show awg0 | awk '/inet /{print \$2; exit}'") || true
        report_pass check_awg_interface_up "awg0 has $addr"
    else
        report_fail check_awg_interface_up "awg0 has no IPv4 address"
    fi
}

check_awg_handshake_fresh() {
    local ts now ago
    ts=$(ssh_router "awg show awg0 latest-handshakes 2>/dev/null | awk '{print \$2; exit}'") || true
    if [ -z "$ts" ] || [ "$ts" = "0" ]; then
        report_fail check_awg_handshake_fresh "no handshake yet (peer unreachable?)"
        return 1
    fi
    now=$(ssh_router 'date +%s')
    ago=$((now - ts))
    if [ "$ago" -gt 180 ]; then
        report_fail check_awg_handshake_fresh "stale: ${ago}s ago"
        return 1
    fi
    report_pass check_awg_handshake_fresh "${ago}s ago"
}

check_awg_transfer_growing() {
    local rx1 rx2 delta
    rx1=$(ssh_router "awg show awg0 transfer 2>/dev/null | awk '{print \$2; exit}'") || true
    sleep 5
    rx2=$(ssh_router "awg show awg0 transfer 2>/dev/null | awk '{print \$2; exit}'") || true
    if [ -z "$rx1" ] || [ -z "$rx2" ]; then
        report_warn check_awg_transfer_growing "no transfer data"
        return 0
    fi
    delta=$((rx2 - rx1))
    if [ "$delta" -gt 0 ]; then
        report_pass check_awg_transfer_growing "RX +${delta} bytes in 5s"
    else
        report_warn check_awg_transfer_growing "no traffic in 5s — may be idle"
    fi
}

check_awg_kmod_loaded() {
    if ssh_router 'lsmod 2>/dev/null | grep -q amneziawg'; then
        report_pass check_awg_kmod_loaded "amneziawg kmod loaded"
    else
        report_fail check_awg_kmod_loaded "amneziawg kmod NOT loaded"
    fi
}

# ─── Services ────────────────────────────────────────────────────────────────
_service_running() {
    local svc=$1
    ssh_router "/etc/init.d/$svc status 2>/dev/null | grep -qiE 'running|started|active'" && return 0
    ssh_router "pgrep -f '/$svc' >/dev/null 2>&1" && return 0
    return 1
}

check_podkop_running() {
    if _service_running podkop; then
        report_pass check_podkop_running "podkop running"
    else
        report_fail check_podkop_running "podkop not running"
    fi
}

check_sing_box_running() {
    if _service_running sing-box; then
        report_pass check_sing_box_running "sing-box running"
    else
        report_fail check_sing_box_running "sing-box not running"
    fi
}

check_sing_box_installed() {
    if ssh_router '[ -x /etc/init.d/sing-box ]'; then
        report_pass check_sing_box_installed "/etc/init.d/sing-box exists"
    else
        report_fail check_sing_box_installed \
            "/etc/init.d/sing-box MISSING — user-1 regression (apk add sing-box silently failed)"
    fi
}

check_dnsmasq_running() {
    if ssh_router 'pgrep dnsmasq >/dev/null 2>&1'; then
        report_pass check_dnsmasq_running "dnsmasq alive"
    else
        report_fail check_dnsmasq_running "dnsmasq not running"
    fi
}

check_firewall_running() {
    if _service_running firewall; then
        report_pass check_firewall_running "firewall running"
    else
        report_fail check_firewall_running "firewall not running"
    fi
}

check_firewall_zone_vpn() {
    if ssh_router "uci show firewall 2>/dev/null | grep -qE \"zone.*name='?vpn'?\""; then
        report_pass check_firewall_zone_vpn "firewall zone 'vpn' present"
    else
        report_fail check_firewall_zone_vpn "no firewall zone 'vpn'"
    fi
}

check_nft_podkop_table() {
    if ssh_router 'nft list table inet PodkopTable >/dev/null 2>&1'; then
        report_pass check_nft_podkop_table "nft table inet PodkopTable present"
    else
        report_fail check_nft_podkop_table "nft table inet PodkopTable missing"
    fi
}

check_doh_running() {
    # Two valid DoH stacks across cheburnet history:
    #   • https-dns-proxy as a standalone daemon (older / newer setups)
    #   • sing-box doing DNS forwarding on 127.0.0.42 (master uses this —
    #     dnsmasq forwards to sing-box, sing-box talks DoH upstream)
    # Either signals "DoH is up". Hard-fail only if neither shows up.
    if ssh_router 'pgrep https-dns-proxy >/dev/null 2>&1'; then
        report_pass check_doh_running "https-dns-proxy alive"
        return 0
    fi
    if ssh_router "uci -q get dhcp.@dnsmasq[0].server" | grep -q '127.0.0.42'; then
        if ssh_router 'pgrep sing-box >/dev/null 2>&1'; then
            report_pass check_doh_running "sing-box providing DoH on 127.0.0.42"
            return 0
        fi
    fi
    report_fail check_doh_running "no DoH backend running (neither https-dns-proxy nor sing-box-on-42)"
}

# ─── DNS routing (critical for user-4 regression) ────────────────────────────
_resolve_first_ip() {
    # Echo the first IPv4 from the answer section of busybox nslookup output.
    # Output format on OpenWrt 25.12:
    #   Server:    127.0.0.1
    #   Address 1: 127.0.0.1 localhost
    #   <blank>
    #   Name:      <domain>
    #   Address 1: <ip>  <hostname>
    #   Address 2: <ip>  <hostname>
    # The blank line splits server-section from answer-section; we read after it.
    ssh_router "nslookup $1 127.0.0.1 2>/dev/null" | awk '
        BEGIN { in_body = 0 }
        /^$/ { in_body = 1; next }
        in_body && /^Address/ {
            for (i = NF; i >= 1; i--) {
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
            }
        }
    '
}

check_dns_resolves() {
    # Sanity that dnsmasq+DoH chain answers at all. Returned IP can be FakeIP
    # (198.18.0.0/15 — podkop tagging .ru/global via sing-box for routing)
    # OR a real IP (DoH-direct for domains not in any rule_set yet) — both fine.
    # The real check for routing correctness lives in check_podkop_ruleset_*.
    local ip
    ip=$(_resolve_first_ip google.com) || true
    if [ -z "$ip" ]; then
        report_fail check_dns_resolves "google.com did not resolve"
        return 1
    fi
    report_pass check_dns_resolves "google.com → $ip"
}

check_dns_adblock() {
    local ip
    ip=$(_resolve_first_ip pagead2.googlesyndication.com) || true
    case "$ip" in
        '')          report_pass check_dns_adblock "NXDOMAIN/blocked (adblock active)" ;;
        0.0.0.0|::)  report_pass check_dns_adblock "sinkholed → $ip" ;;
        *)           report_fail check_dns_adblock "ad domain resolved to $ip (adblock inactive?)" ;;
    esac
}

check_podkop_ruleset_contains_ru() {
    # Podkop 0.7.17+ writes domain rules into external sing-box rule_set files
    # under /tmp/sing-box/rulesets/, not inline domain_suffix in config.json
    # (which only holds reject/route metadata + rule_set references). The
    # exact regression user-4 ran into: rule_set file missing or empty →
    # yandex.ru lands in the VPN-bound bucket → routed via non-RU exit IP.
    local rs=/tmp/sing-box/rulesets/exclude_ru-user-domains-ruleset.json
    if ! ssh_router_quiet "[ -s $rs ]"; then
        report_fail check_podkop_ruleset_contains_ru \
            "$rs missing/empty — podkop list_update never ran (user-4!)"
        return 1
    fi
    if ssh_router "grep -q '\"\\.ru\"' $rs"; then
        report_pass check_podkop_ruleset_contains_ru "$rs has .ru"
    else
        report_fail check_podkop_ruleset_contains_ru \
            "$rs exists but .ru not in it (user-4 regression!)"
    fi
}

# ─── Manifest / token / ACL ──────────────────────────────────────────────────
check_manifest_applied() {
    local sample missing=0 checked=0
    sample=$(ssh_router "grep -vE '^[[:space:]]*(#|\$)' /opt/cheburnet/setup/manifest.txt 2>/dev/null | head -10") || true
    if [ -z "$sample" ]; then
        report_fail check_manifest_applied "manifest empty or absent"
        return 1
    fi
    while IFS=' ' read -r _src dst _mode; do
        [ -z "$dst" ] && continue
        checked=$((checked + 1))
        ssh_router_quiet "[ -e '$dst' ]" || missing=$((missing + 1))
    done <<EOF
$sample
EOF
    if [ "$missing" -eq 0 ]; then
        report_pass check_manifest_applied "$checked sampled manifest entries present"
    else
        report_fail check_manifest_applied "$missing of $checked sampled entries missing"
    fi
}

check_install_token_removed() {
    if ssh_router_quiet '[ -e /etc/cheburnet/install-token ]'; then
        report_fail check_install_token_removed "/etc/cheburnet/install-token still exists"
    else
        report_pass check_install_token_removed "install-token cleared"
    fi
}

check_rpcd_acl_locked_down() {
    # Post-install ACL: unauthenticated must have NO write-block. Earlier
    # versions of this check used a 20-line awk window after the literal
    # string "unauthenticated"; on the real post-install JSON that window
    # spilled into the cheburnet-admin section (which legitimately holds
    # "write": ...), producing a false negative. Use jsonfilter for a
    # structural check — that's what the project already standardised on.
    local has_unauth has_unauth_write
    has_unauth=$(ssh_router "jsonfilter -i /usr/share/rpcd/acl.d/cheburnet.json -e '@.unauthenticated' 2>/dev/null") || true
    if [ -z "$has_unauth" ]; then
        report_fail check_rpcd_acl_locked_down "ACL file has no 'unauthenticated' block"
        return 1
    fi
    has_unauth_write=$(ssh_router "jsonfilter -i /usr/share/rpcd/acl.d/cheburnet.json -e '@.unauthenticated.write' 2>/dev/null") || true
    if [ -z "$has_unauth_write" ]; then
        report_pass check_rpcd_acl_locked_down "unauth.write absent — admin operations gated"
    else
        report_fail check_rpcd_acl_locked_down "unauth.write still present"
    fi
}

# ─── UCI invariants (AGENTS.md) ──────────────────────────────────────────────
check_podkop_user_domain_list_type_dynamic() {
    local v
    v=$(ssh_router 'uci -q get podkop.main.user_domain_list_type') || true
    if [ "$v" = "dynamic" ]; then
        report_pass check_podkop_user_domain_list_type_dynamic "= dynamic"
    else
        report_fail check_podkop_user_domain_list_type_dynamic \
            "expected 'dynamic', got '$v' — HOME-mode will silently no-op (AGENTS.md invariant)"
    fi
}

check_podkop_fully_routed_ips_matches_lan() {
    local fri lan_cidr
    fri=$(ssh_router 'uci -q get podkop.main.fully_routed_ips') || true
    lan_cidr=$(ssh_router '. /opt/cheburnet/lib/net-detect.sh 2>/dev/null && net_lan_cidr 192.168.1.0/24') || true
    if [ -z "$fri" ]; then
        report_fail check_podkop_fully_routed_ips_matches_lan "unset"
        return 1
    fi
    if [ "$fri" = "$lan_cidr" ]; then
        report_pass check_podkop_fully_routed_ips_matches_lan "$fri matches LAN CIDR"
    else
        report_fail check_podkop_fully_routed_ips_matches_lan \
            "podkop=$fri but LAN=$lan_cidr — likely hardcoded (kill-switch will leak)"
    fi
}

check_podkop_exclude_ru_community_lists() {
    local v
    v=$(ssh_router 'uci -q get podkop.exclude_ru.community_lists') || true
    if [ "$v" = "russia_outside" ]; then
        report_pass check_podkop_exclude_ru_community_lists "= russia_outside"
    else
        report_fail check_podkop_exclude_ru_community_lists \
            "expected 'russia_outside', got '$v' — .ru sites would route via VPN"
    fi
}

check_podkop_route_allowed_ips_zero() {
    local v
    v=$(ssh_router 'uci -q get podkop.main.route_allowed_ips') || true
    case "$v" in
        0|'') report_pass check_podkop_route_allowed_ips_zero "route_allowed_ips=${v:-(default 0)}" ;;
        *)    report_fail check_podkop_route_allowed_ips_zero "expected 0, got '$v'" ;;
    esac
}

# ─── Wpad (user-1 regression) ────────────────────────────────────────────────
check_wpad_installed() {
    local pkgs
    pkgs=$(ssh_router "apk list -I 2>/dev/null | awk '/^wpad-(mbedtls|openssl|basic)/{print \$1}' | tr '\n' ' '") || true
    if [ -n "$pkgs" ]; then
        report_pass check_wpad_installed "installed: $pkgs"
    else
        report_fail check_wpad_installed "no wpad-* package — Wi-Fi WPA broken (user-1)"
    fi
}

# ─── Wi-Fi ───────────────────────────────────────────────────────────────────
check_wifi_radio_up() {
    local count
    count=$(ssh_router "iw dev 2>/dev/null | grep -c 'Interface phy'") || true
    case "${count:-0}" in
        0)    report_fail check_wifi_radio_up "no Wi-Fi interfaces" ;;
        1)    report_warn check_wifi_radio_up "only 1 radio (expected 2 on Beryl AX)" ;;
        *)    report_pass check_wifi_radio_up "$count radios up" ;;
    esac
}

check_wifi_country_set() {
    local cc
    cc=$(ssh_router 'uci -q get wireless.radio0.country') || true
    if [ -n "$cc" ]; then
        report_pass check_wifi_country_set "country=$cc"
    else
        report_fail check_wifi_country_set "wireless.radio0.country not set"
    fi
}

# ─── Watchdog / cron ─────────────────────────────────────────────────────────
check_watchdog_in_cron() {
    if ssh_router 'crontab -l 2>/dev/null | grep -q awg-watchdog'; then
        report_pass check_watchdog_in_cron "awg-watchdog scheduled"
    else
        report_fail check_watchdog_in_cron "awg-watchdog NOT in crontab"
    fi
}

check_cron_running() {
    if ssh_router 'pgrep crond >/dev/null 2>&1'; then
        report_pass check_cron_running "crond alive"
    else
        report_fail check_cron_running "crond not running"
    fi
}

# ─── Web RPC (phase 2) ───────────────────────────────────────────────────────
check_rpc_get_status() {
    local mode
    mode=$(ssh_router "ubus call cheburnet get_status 2>/dev/null | jsonfilter -e '@.mode' 2>/dev/null") || true
    if [ -n "$mode" ]; then
        report_pass check_rpc_get_status "mode=$mode"
    else
        report_fail check_rpc_get_status "ubus call returned no .mode field"
    fi
}

check_rpc_mode_switch() {
    local target=$1
    if ! ssh_router "ubus call cheburnet mode_switch '{\"mode\":\"$target\"}'" >/dev/null 2>&1; then
        report_fail check_rpc_mode_switch "ubus mode_switch '$target' rejected"
        return 1
    fi
    sleep 3
    local actual
    actual=$(ssh_router 'vpn-mode status 2>/dev/null | head -1') || true
    if echo "$actual" | grep -qi "$target"; then
        report_pass check_rpc_mode_switch "switched to $target"
    else
        report_fail check_rpc_mode_switch "ubus accepted '$target' but status='$actual'"
    fi
}

check_rpc_service_restart() {
    local svc=$1
    if ssh_router "ubus call cheburnet service_restart '{\"service\":\"$svc\"}'" >/dev/null 2>&1; then
        sleep 2
        report_pass check_rpc_service_restart "$svc restart accepted"
    else
        report_fail check_rpc_service_restart "$svc restart rejected"
    fi
}

check_rpc_set_blocklist_tier() {
    local tier=$1
    if ssh_router "ubus call cheburnet set_blocklist_tier '{\"tier\":\"$tier\"}'" >/dev/null 2>&1; then
        report_pass check_rpc_set_blocklist_tier "tier=$tier accepted"
    else
        report_fail check_rpc_set_blocklist_tier "tier=$tier rejected"
    fi
}

check_rpc_set_family_filter() {
    local state=$1 enabled rc out
    if [ "$state" = "on" ]; then enabled=true; else enabled=false; fi
    # Distinguish via exit code, not stdout content. Successful ubus call
    # to set_family_filter returns 0 and emits the JSON response on stdout
    # (e.g. {"status": "family_filter set", "enabled": true}). Missing
    # method comes out on stderr with exit code 4 ("Method not found").
    out=$(ssh_router "ubus call cheburnet set_family_filter '{\"enabled\":$enabled}'" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        report_pass check_rpc_set_family_filter "$state — handler accepted"
    elif echo "$out" | grep -q 'Method not found'; then
        report_warn check_rpc_set_family_filter "method absent in installed rpcd (older cheburnet?)"
    else
        report_fail check_rpc_set_family_filter "rc=$rc — ${out%%$'\n'*}"
    fi
}

# ─── CLI tools (phase 3) ─────────────────────────────────────────────────────
check_cli_vpn_mode_switch() {
    local target=$1
    if ssh_router "vpn-mode $target" >/dev/null 2>&1; then
        sleep 2
        if ssh_router "vpn-mode status 2>/dev/null" | grep -qi "$target"; then
            report_pass check_cli_vpn_mode_switch "vpn-mode $target → status reports $target"
        else
            report_fail check_cli_vpn_mode_switch "vpn-mode $target ran but status mismatch"
        fi
    else
        report_fail check_cli_vpn_mode_switch "vpn-mode $target exited non-zero"
    fi
}

check_cli_dns_provider() {
    local out first
    out=$(ssh_router 'dns-provider 2>&1') || true
    first=$(printf '%s' "$out" | head -1)
    if [ -n "$first" ]; then
        report_pass check_cli_dns_provider "$first"
    else
        report_fail check_cli_dns_provider "dns-provider produced no output"
    fi
}

check_cli_awg_watchdog() {
    if ssh_router 'awg-watchdog' >/dev/null 2>&1; then
        report_pass check_cli_awg_watchdog "exit 0"
    else
        report_fail check_cli_awg_watchdog "exit non-zero (handshake stale?)"
    fi
}

check_cli_log_snapshot() {
    local before after
    before=$(ssh_router 'ls /root/logs/ 2>/dev/null | wc -l') || true
    if ssh_router 'log-snapshot >/dev/null 2>&1'; then
        after=$(ssh_router 'ls /root/logs/ 2>/dev/null | wc -l') || true
        if [ "${after:-0}" -gt "${before:-0}" ]; then
            report_pass check_cli_log_snapshot "snapshot created"
        else
            report_warn check_cli_log_snapshot "ran but no new file in /root/logs"
        fi
    else
        report_fail check_cli_log_snapshot "log-snapshot exit non-zero"
    fi
}

# ─── Phase 4: fault-injection helpers ────────────────────────────────────────
check_install_via_tether_rejects_without_usb() {
    local wan_before wan_after rc=0
    wan_before=$(ssh_router 'uci -q get network.wan.device') || true
    ssh_router 'timeout 60 /opt/cheburnet/scripts/install-via-tether.sh </dev/null \
                >/tmp/cheburnet-tether-test.log 2>&1' || rc=$?
    wan_after=$(ssh_router 'uci -q get network.wan.device') || true
    if [ "$rc" -eq 0 ]; then
        report_fail check_install_via_tether_rejects_without_usb \
            "exit 0 — should fail without USB tether"
        return 1
    fi
    if [ "$wan_before" != "$wan_after" ]; then
        report_fail check_install_via_tether_rejects_without_usb \
            "WAN changed $wan_before → $wan_after — trap failure!"
        return 1
    fi
    report_pass check_install_via_tether_rejects_without_usb \
        "exit $rc, WAN unchanged ($wan_after)"
}

# ─── split-routing (phase5) ───────────────────────────────────────────────────
#
# Эти три функции проверяют что HOME-режим реально работает на железе:
#   1. routing-separation: outgoing IP через WAN ≠ через awg0 (два туннеля живы)
#   2. dns-split: .ru-домены резолвятся в FakeIP (sing-box подменил), западные — в real IP
#   3. lan-traffic-split: с хоста-разработчика как LAN-клиента, 5+5 сайтов
#      открываются, outgoing IP при заходе на западное = VPN-IP роутера
#
# Толерантны к internet-flakiness: пороги «≥4/5», коды 4xx считаются OK
# (соединение прошло, сервер ответил), 5xx тоже считаются «соединение есть»;
# критично — только timeout (000) и DNS-fail.
#
# Test 3 требует чтобы хост был подключён в LAN cheburnet'а (default gw =
# IP роутера). Если нет — тест пропускается с warn, остальные проходят.

check_routing_separation() {
    local wan vpn
    wan=$(ssh_router 'curl -s --max-time 10 https://ifconfig.io' 2>/dev/null)
    vpn=$(ssh_router 'curl -s --max-time 10 --interface awg0 https://ifconfig.io' 2>/dev/null)
    if [ -z "$wan" ] || [ -z "$vpn" ]; then
        report_fail check_routing_separation \
            "один из IP пустой: WAN='$wan' VPN='$vpn' (один из выходов не работает)"
        return 1
    fi
    if [ "$wan" = "$vpn" ]; then
        report_fail check_routing_separation \
            "WAN == VPN == $wan — split routing не работает, оба выхода идут одним путём"
        return 1
    fi
    report_pass check_routing_separation "WAN=$wan ≠ VPN=$vpn"
}

check_dns_split() {
    # .ru-домены должны попадать в exclude_ru rule_set → DNS возвращает FakeIP.
    # Западные — обычный real IP. Берём по 4 домена в каждой группе —
    # достаточно чтобы поймать поломку, но не слишком много чтобы блокировать
    # тест на медленных DNS.
    local ru_domains="gosuslugi.ru yandex.ru sberbank.ru vk.com"
    local west_domains="google.com github.com youtube.com wikipedia.org"
    local router_lan="${ROUTER#*@}"
    local d ip failures=0 details=""

    for d in $ru_domains; do
        ip=$(ssh_router "nslookup '$d' '$router_lan' 2>/dev/null \
            | awk '/^Address: [0-9]/{print \$2; exit}'" 2>/dev/null)
        case "$ip" in
            198.18.*) ;;
            *) failures=$((failures + 1)); details="$details [.ru/$d=$ip]" ;;
        esac
    done
    for d in $west_domains; do
        ip=$(ssh_router "nslookup '$d' '$router_lan' 2>/dev/null \
            | awk '/^Address: [0-9]/{print \$2; exit}'" 2>/dev/null)
        case "$ip" in
            198.18.*) failures=$((failures + 1)); details="$details [west/$d=$ip(FakeIP)]" ;;
            "")       failures=$((failures + 1)); details="$details [west/$d=NXDOMAIN]" ;;
            *) ;;
        esac
    done

    if [ "$failures" -gt 0 ]; then
        report_fail check_dns_split "$failures доменов с неправильным DNS:$details"
        return 1
    fi
    report_pass check_dns_split "4 .ru → FakeIP (198.18.*), 4 западных → real IP"
}

check_lan_traffic_split() {
    # Эта проверка использует HOST (где run-all.sh запущен) как LAN-клиента.
    # Это типичный setup hw-теста: ноут разработчика подключён ethernet'ом
    # в LAN-порт роутера. Если хост в LAN — default gw совпадает с роутером.
    local router_ip="${ROUTER#*@}"
    local host_gw
    host_gw=$(ip route 2>/dev/null | awk '/^default /{print $3; exit}')
    if [ "$host_gw" != "$router_ip" ]; then
        report_warn check_lan_traffic_split \
            "host default-gw='$host_gw' ≠ router='$router_ip' — host не подключён в LAN cheburnet'а, тест пропущен"
        return 0
    fi

    # 5+5 сайтов. Любой 2xx/3xx/4xx считаем «соединение прошло» — мы тестируем
    # routing, не HTTP-status сайта. 5xx — тоже OK (сервер ответил). Только
    # 000 (timeout) = реальный сбой соединения.
    local west_sites="google.com github.com youtube.com wikipedia.org cloudflare.com"
    local ru_sites="gosuslugi.ru yandex.ru sberbank.ru vk.com lenta.ru"
    local d code west_ok=0 ru_ok=0 failed=""

    for d in $west_sites; do
        code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "https://$d" 2>/dev/null)
        case "$code" in
            [2345][0-9][0-9]) west_ok=$((west_ok + 1)) ;;
            *) failed="$failed [west/$d=$code]" ;;
        esac
    done
    for d in $ru_sites; do
        code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "https://$d" 2>/dev/null)
        case "$code" in
            [2345][0-9][0-9]) ru_ok=$((ru_ok + 1)) ;;
            *) failed="$failed [ru/$d=$code]" ;;
        esac
    done

    # Outgoing IP с хоста (LAN-клиент) при заходе на западный сайт должен
    # отличаться от WAN-IP роутера — это значит трафик ушёл через VPN,
    # а не direct через провайдера. Сравнивать ровно с awg0-bind IP роутера
    # нельзя: CDN-VPN'ы (Amnezia, Cloudflare) используют разные egress-сервера
    # для разных запросов — host_out и router-awg0-out часто разные IP, но
    # оба не равны WAN-IP. Контракт: «LAN-трафик НЕ идёт через WAN-провайдера».
    local host_out wan_ip
    host_out=$(curl -s --max-time 10 https://ifconfig.io 2>/dev/null)
    wan_ip=$(ssh_router 'curl -s --max-time 10 https://ifconfig.io' 2>/dev/null)

    local errors=""
    [ "$west_ok" -lt 4 ] && errors="$errors west_ok=$west_ok/5(min 4)"
    [ "$ru_ok"   -lt 4 ] && errors="$errors ru_ok=$ru_ok/5(min 4)"
    if [ -z "$host_out" ]; then
        errors="$errors host_out=пусто(ifconfig.io недоступен)"
    elif [ -n "$wan_ip" ] && [ "$host_out" = "$wan_ip" ]; then
        # Худший сценарий: LAN-трафик идёт через WAN — split routing СЛОМАН
        # или AmneziaWG не поднят. Юзер из РФ виден миру как из РФ.
        errors="$errors host_out=$host_out=WAN_IP(VPN не работает!)"
    fi

    if [ -n "$errors" ]; then
        report_fail check_lan_traffic_split "$errors$failed"
        return 1
    fi
    report_pass check_lan_traffic_split \
        "$west_ok/5 западных OK, $ru_ok/5 .ru OK, host_out=$host_out ≠ WAN=$wan_ip (VPN активен)"
}
