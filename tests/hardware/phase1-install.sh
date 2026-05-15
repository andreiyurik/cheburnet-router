#!/bin/bash
# phase1-install.sh — bootstrap, happy-path install via RPC, full post-install
# verification, and the 5 priority regression checks.
#
# Requires fixtures/awg.conf (your real working AWG config; gitignored).
# Tunable via env:
#   HW_SSID          (default: cheburnet-hwtest)
#   HW_WIFI_KEY      (default: test-password-12345)
#   HW_COUNTRY       (default: RU)
#   HW_ROOT_PASS     (default: cheburnet-test)
#
# Usage (standalone):  ./phase1-install.sh root@192.168.1.1 [branch]
# Caller must have already run phase0 (or firstboot manually).

set -u
. "$(dirname "$0")/lib.sh"
hw_init "${1:-}" "${2:-}"

AWG_CONF="${HW_AWG_CONF:-$FIXTURES_DIR/awg.conf}"
SSID="${HW_SSID:-cheburnet-hwtest}"
WIFI_KEY="${HW_WIFI_KEY:-test-password-12345}"
COUNTRY="${HW_COUNTRY:-RU}"
ROOT_PASS="${HW_ROOT_PASS:-cheburnet-test}"

if [ ! -f "$AWG_CONF" ]; then
    echo "✗ fixtures/awg.conf missing — drop your working AmneziaWG config at" >&2
    echo "  $AWG_CONF (it's gitignored)." >&2
    exit 1
fi

report_init "Phase 1 — bootstrap + install + regressions"

# ── Bootstrap ────────────────────────────────────────────────────────────────
if ! run_bootstrap "$BRANCH"; then
    report_fail run_bootstrap "bootstrap exited non-zero — phase 1 aborted"
    report_summary
    exit 1
fi
check_bootstrap_succeeded

# ── Kick off the install via RPC, monitor to completion ──────────────────────
if ! trigger_install_via_rpc "$AWG_CONF" "$SSID" "$WIFI_KEY" "$COUNTRY" "$ROOT_PASS"; then
    report_summary
    exit 1
fi
wait_for_install_done 1200

# ── Done-state ───────────────────────────────────────────────────────────────
check_install_done_ok
check_state_file_format

# ── Core runtime checks ──────────────────────────────────────────────────────
check_awg_kmod_loaded
check_awg_interface_up
check_awg_handshake_fresh
check_awg_transfer_growing

check_podkop_running
check_sing_box_running
check_dnsmasq_running
check_firewall_running
check_firewall_zone_vpn
check_nft_podkop_table
check_doh_running
check_adblock_blocklist_loaded

# ── DNS routing (catches user-4 silent-broken bug) ───────────────────────────
check_dns_yandex_real_ip
check_dns_google_fakeip
check_dns_adblock

# ── Manifest / token / ACL ───────────────────────────────────────────────────
check_manifest_applied
check_install_token_removed
check_rpcd_acl_locked_down

# ── Wi-Fi / watchdog ─────────────────────────────────────────────────────────
check_wifi_radio_up
check_wifi_country_set
check_watchdog_in_cron
check_cron_running

# ── Priority regressions (must FAIL loudly if a refactor breaks them) ────────
report_info regressions "running priority regression suite"
check_sing_box_config_has_ru_exclusion          # user-4: silent-broken FakeIP for yandex.ru
check_sing_box_installed                        # user-1: apk add sing-box silently EPERM
check_wpad_installed                            # user-1: wpad-basic→mbedtls replacement
check_podkop_user_domain_list_type_dynamic     # AGENTS.md invariant: HOME-mode would silently no-op
check_podkop_fully_routed_ips_matches_lan      # AGENTS.md invariant: kill-switch leak on non-default LAN

# ── Other UCI invariants ─────────────────────────────────────────────────────
check_podkop_exclude_ru_community_lists
check_podkop_route_allowed_ips_zero

# Snapshot /tmp/cheburnet/install.log locally — phase 4 reuses install.log
# (via replace_awg_conf → 01-amneziawg) and phase 6 wipes it via reboot
# (it's on tmpfs). Saving here keeps phase-1's diagnostic for post-mortem.
LOCAL_LOG="/tmp/cheburnet-hwtest-phase1-install.log"
if ssh_router 'cat /tmp/cheburnet/install.log' >"$LOCAL_LOG" 2>/dev/null; then
    report_info phase1 "install.log saved to $LOCAL_LOG ($(wc -c <"$LOCAL_LOG") bytes)"
else
    report_warn phase1 "could not snapshot install.log"
fi

report_summary
exit $?
