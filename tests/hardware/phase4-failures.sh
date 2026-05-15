#!/bin/bash
# phase4-failures.sh — auto-injectable failure scenarios.
#
# Two scenarios:
#   (a) install-via-tether without a USB phone — must exit non-zero AND
#       leave network.wan.device untouched (the trap-on-EXIT in
#       scripts/install-via-tether.sh must restore WAN). Runs against the
#       installed system, no firstboot needed.
#   (b) Bad AWG endpoint (TEST-NET-1 192.0.2.1:51820) — must fail on
#       01-amneziawg after exhausting fallbacks, with done = fail-01-amneziawg.
#       Requires a clean system, so we firstboot+bootstrap inside this phase.
#
# This phase is destructive: the bad-AWG scenario leaves the router in a
# half-installed state. run-all.sh schedules it last for this reason.
#
# The bad-AWG scenario takes ~8–10 minutes (apk install + 3 fallbacks ×
# ~60 s each + final diagnostics). Skip with HW_SKIP_BAD_AWG=1 if you only
# want the tether-trap check.

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

BAD_AWG="$FIXTURES_DIR/bad-awg.conf"
SSID="${HW_SSID:-cheburnet-hwtest}"
WIFI_KEY="${HW_WIFI_KEY:-test-password-12345}"
COUNTRY="${HW_COUNTRY:-RU}"

report_init "Phase 4 — fault injection"

# ── (a) install-via-tether trap-on-no-USB ────────────────────────────────────
if ssh_router '[ -x /opt/cheburnet/scripts/install-via-tether.sh ]'; then
    check_install_via_tether_rejects_without_usb
else
    report_warn check_install_via_tether_rejects_without_usb \
        "install-via-tether.sh not present — skipping (run after phase 1?)"
fi

# ── (b) Bad-AWG endpoint → fail-01-amneziawg ─────────────────────────────────
if [ "${HW_SKIP_BAD_AWG:-0}" = "1" ]; then
    report_info phase4 "HW_SKIP_BAD_AWG=1 set, skipping bad-AWG scenario"
    report_summary
    exit $?
fi

if [ ! -f "$BAD_AWG" ]; then
    report_warn bad_awg_setup "$BAD_AWG missing — skipping bad-AWG scenario"
    report_summary
    exit $?
fi

report_info phase4 "firstboot + bootstrap + direct install with bad AWG endpoint"
firstboot_reset || { report_summary; exit 1; }
check_clean_state

if ! run_bootstrap "$BRANCH"; then
    report_fail run_bootstrap "bootstrap failed; bad-AWG scenario aborted"
    report_summary
    exit 1
fi

if ! prepare_direct_install "$BAD_AWG" "$SSID" "$WIFI_KEY" "$COUNTRY"; then
    report_summary
    exit 1
fi

trigger_install_direct
wait_for_install_done 900   # fallbacks add up to ~5 min; budget for slow apk

# The install MUST fail on 01-amneziawg (TEST-NET-1 endpoint never answers).
check_install_done_matches "fail-01-amneziawg"

# Belt-and-braces: log should record the three fallback attempts.
if ssh_router 'grep -q "Fallback" /tmp/cheburnet/install.log 2>/dev/null'; then
    report_pass bad_awg_fallback_attempted "install.log mentions Fallback"
else
    report_warn bad_awg_fallback_attempted "no Fallback mention — fallbacks may not have run"
fi

report_summary
exit $?
