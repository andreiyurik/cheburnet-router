#!/bin/bash
# phase4-failures.sh — fault injection scenarios. Non-destructive.
#
# Two real-user failure modes:
#
#   (a) install-via-tether without a USB phone — the script must exit
#       non-zero AND leave network.wan.device untouched (trap-on-EXIT in
#       scripts/install-via-tether.sh restores WAN). Tests the trap path.
#
#   (b) replace_awg_conf rollback with a bad config — the new conf parses
#       fine but 01-amneziawg's handshake never establishes (TEST-NET-1
#       endpoint). The RPC must roll back to the previous (working) conf
#       and emit done='fail-rolled-back'. End state: awg0.conf is the
#       original, handshake comes back. This mirrors what really happens
#       when a user's VPN provider rotates keys and they paste a stale
#       conf — the system must NOT brick.
#
# Both run against the live install from phase 1; no firstboot, no
# additional manual setup needed. Phase 4 ends with the system fully
# operational (rollback returns AWG to the working config).

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

BAD_AWG="$FIXTURES_DIR/bad-awg.conf"

report_init "Phase 4 — fault injection (non-destructive)"

# ── (a) install-via-tether trap-on-no-USB ────────────────────────────────────
if ssh_router '[ -x /opt/cheburnet/scripts/install-via-tether.sh ]'; then
    check_install_via_tether_rejects_without_usb
else
    report_warn install_via_tether "/opt/cheburnet/scripts/install-via-tether.sh missing (phase 1 didn't install?)"
fi

# ── (b) replace_awg_conf with bad-AWG → expect rollback ──────────────────────
if [ ! -f "$BAD_AWG" ]; then
    report_warn replace_awg_setup "$BAD_AWG missing — skipping rollback scenario"
    report_summary
    exit $?
fi

# Snapshot the working awg0.conf so we can verify byte-for-byte rollback.
orig_hash=$(ssh_router 'sha256sum /etc/amnezia/amneziawg/awg0.conf 2>/dev/null | awk "{print \$1}"') || true
if [ -z "$orig_hash" ]; then
    report_fail replace_awg_setup "no /etc/amnezia/amneziawg/awg0.conf on router — phase 1 didn't install"
    report_summary
    exit $?
fi
report_info replace_awg_setup "original awg.conf sha256: ${orig_hash:0:16}…"

# Build the RPC payload via python3 (proper JSON escaping for awg.conf body).
payload=$(mktemp)
AWG_PATH="$BAD_AWG" python3 - >"$payload" <<'PY'
import json, os
with open(os.environ['AWG_PATH']) as f:
    print(json.dumps({'awg_conf': f.read()}))
PY
scp_to_router "$payload" /tmp/cheburnet-replace.json >/dev/null
rm -f "$payload"

# Clear the done marker; replace_awg_conf writes a fresh one.
ssh_router 'rm -f /tmp/cheburnet/done' >/dev/null 2>&1 || true

# Trigger replace_awg_conf. Returns when the operation has been spawned;
# the actual handshake-test runs in the background, we poll done below.
if ! ssh_router 'ubus -t 30 call cheburnet replace_awg_conf "$(cat /tmp/cheburnet-replace.json)"' >/dev/null 2>&1; then
    report_fail replace_awg_trigger "ubus replace_awg_conf rejected the payload (handler missing or arg validation failed)"
    ssh_router 'rm -f /tmp/cheburnet-replace.json' 2>/dev/null || true
    report_summary
    exit $?
fi
ssh_router 'rm -f /tmp/cheburnet-replace.json' 2>/dev/null || true

# The replace flow runs 01-amneziawg internally with the new conf; we wait
# for it to fail and roll back. Budget: 01-amneziawg handshake-wait is 60s
# + 3 × 30s for fallbacks + rollback restore = ~3min worst case.
wait_for_install_done 300

# Expect done = fail-rolled-back. Anything else means the rollback path
# is broken — a real user would be left with a bricked tunnel.
expected=fail-rolled-back
actual=$(ssh_router 'cat /tmp/cheburnet/done 2>/dev/null') || true
if [ "$actual" = "$expected" ]; then
    report_pass check_replace_rolled_back "done=$expected"
else
    report_fail check_replace_rolled_back "expected '$expected', got '$actual'"
fi

# Verify the awg0.conf on the router is byte-identical to what we snapshotted
# before the bad replace. If hash differs, the rollback partially applied
# the bad conf → silent corruption.
new_hash=$(ssh_router 'sha256sum /etc/amnezia/amneziawg/awg0.conf 2>/dev/null | awk "{print \$1}"') || true
if [ "$new_hash" = "$orig_hash" ]; then
    report_pass check_awg_conf_restored "awg0.conf identical to pre-replace snapshot"
else
    report_fail check_awg_conf_restored "awg0.conf hash changed: ${orig_hash:0:16}… → ${new_hash:0:16}…"
fi

# Give the restored conf time to bring the tunnel back. After rollback,
# 01-amneziawg.sh re-runs with the original conf; handshake establishment
# can take 5–60s depending on path latency. Poll instead of guessing.
report_info phase4 "polling for AWG handshake recovery (up to 90s)"
start_ts=$(date +%s)
recovered=0
while [ "$(($(date +%s) - start_ts))" -lt 90 ]; do
    ts=$(ssh_router "awg show awg0 latest-handshakes 2>/dev/null | awk '{print \$2; exit}'") || true
    if [ -n "$ts" ] && [ "$ts" != "0" ]; then
        now=$(ssh_router 'date +%s')
        ago=$((now - ts))
        if [ "$ago" -lt 90 ]; then
            recovered=1
            report_info phase4 "handshake recovered after $(($(date +%s) - start_ts))s post-rollback"
            break
        fi
    fi
    sleep 5
done
if [ "$recovered" -eq 1 ]; then
    check_awg_handshake_fresh
else
    report_fail check_awg_handshake_fresh "no fresh handshake within 90s of rollback (VPN bricked?)"
fi

report_summary
exit $?
