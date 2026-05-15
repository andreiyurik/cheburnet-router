#!/bin/bash
# phase2-webui.sh — exercises the RPC surface the web wizard talks to.
#
# Runs against an installed cheburnet (assumes phase 1 succeeded — no firstboot
# between them). Uses local ubus, so SSH+root access bypasses the HTTP auth
# layer; that's by design — we test the handler logic, not basic-auth.

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

report_init "Phase 2 — web RPC handlers"

check_rpc_get_status

# Mode switch: travel then back to home. Two switches catch the "stuck after
# first switch" class of bug.
check_rpc_mode_switch travel
check_rpc_mode_switch home

# Service restarts. We only check that the RPC was accepted; deep verification
# would require correlating PIDs through podkop's restart sequence, which is
# flaky enough on real hardware that it'd be noise.
check_rpc_service_restart vpn
check_rpc_service_restart dns
check_rpc_service_restart adblock

# Blocklist tier change. Default is 'pro'; switch to 'light' then back.
check_rpc_set_blocklist_tier light
check_rpc_set_blocklist_tier pro

# Family-filter toggle.
check_rpc_set_family_filter on
check_rpc_set_family_filter off

report_summary
exit $?
