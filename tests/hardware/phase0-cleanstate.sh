#!/bin/bash
# phase0-cleanstate.sh — precondition gate.
#
# Verifies the router is in a fresh-OpenWrt + SSH-access state. The user
# must have done factoryreset + LuCI password + SSH-key setup manually
# (see README.md → Precondition). If any check here fails, run-all.sh
# aborts the run — cascading 30+ false fails from a broken precondition
# would obscure the real issue.
#
# Usage (standalone):  ./phase0-cleanstate.sh root@192.168.1.1
# Usage (orchestrated): called by run-all.sh as the gate.

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

report_init "Phase 0 — precondition: fresh OpenWrt + SSH access"

check_clean_state
check_openwrt_version
check_wan_up
check_overlay_size
check_ram_total
check_internet_https

report_summary
exit $?
