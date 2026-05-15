#!/bin/bash
# phase0-cleanstate.sh — verify the router is a clean OpenWrt installation.
#
# Assumes the caller did `firstboot -y && reboot` (or run-all.sh did it) and
# we now talk to a freshly-booted system with no cheburnet artefacts.
#
# Usage (standalone):  ./phase0-cleanstate.sh root@192.168.1.1
# Usage (orchestrated): called by run-all.sh after firstboot_reset.

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

report_init "Phase 0 — clean OpenWrt state"

check_clean_state
check_openwrt_version
check_wan_up
check_overlay_size
check_ram_total
check_internet_https

report_summary
exit $?
