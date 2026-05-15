#!/bin/bash
# phase3-cli.sh — CLI tooling on the router (vpn-mode, dns-provider, watchdog).
#
# Runs against an installed cheburnet (no firstboot between phase 2 and 3).

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

report_init "Phase 3 — CLI tools"

check_cli_vpn_mode_switch travel
check_cli_vpn_mode_switch home

check_cli_dns_provider
check_cli_awg_watchdog
check_cli_log_snapshot

report_summary
exit $?
