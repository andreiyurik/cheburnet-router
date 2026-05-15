#!/bin/bash
# phase6-reboot.sh — cold reboot + steady-state verification.
#
# Runs against an installed cheburnet. Issues `reboot`, waits for SSH, then
# re-verifies every runtime service. Catches autostart regressions: a podkop
# that runs after install but doesn't survive reboot is a silent killer.

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

report_init "Phase 6 — reboot + steady state"

reboot_only

# Wait for podkop's nft table — that's the only reliable "podkop is fully
# loaded" signal. On aarch64 Beryl AX with master-cheburnet, podkop's `start`
# takes 3-5 minutes after a reboot: it downloads RU/community lists, builds
# the sing-box config, applies nft routing. During that window the init.d
# script is still running so check_podkop_running misleadingly passes; the
# nft table doesn't exist until the very end.
report_info phase6 "waiting for podkop nft readiness (up to 360s)"
start_ts=$(date +%s)
ready=0
while [ "$(($(date +%s) - start_ts))" -lt 360 ]; do
    if ssh_router_quiet 'nft list table inet PodkopTable >/dev/null 2>&1'; then
        ready=1
        report_info phase6 "podkop ready after ~$(($(date +%s) - start_ts))s"
        break
    fi
    sleep 10
done
if [ "$ready" -eq 0 ]; then
    report_fail phase6_bootstrap "podkop nft table never appeared within 360s — aborting downstream checks"
    report_summary
    exit 1
fi
sleep 10  # additional grace for DNS/handshake handoff after table is up

# All the services should self-start from init.d.
check_awg_kmod_loaded
check_awg_interface_up
check_awg_handshake_fresh
check_podkop_running
check_sing_box_running
check_dnsmasq_running
check_firewall_running
check_nft_podkop_table
check_doh_running
check_dns_resolves

# Force HOME — Phase 2/3 могли оставить нас в TRAVEL, а в TRAVEL exclude_ru
# (по дизайну) пустой → exclude_ru rule_set не генерится. Контракт ниже
# проверяет HOME-mode инвариант, поэтому форсим HOME явно.
ssh_router 'vpn-mode home' >/dev/null 2>&1 || true
sleep 5
check_podkop_ruleset_contains_ru

# Cron must have come back up — watchdog only fires through it.
check_cron_running
check_watchdog_in_cron

report_summary
exit $?
