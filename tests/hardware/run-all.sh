#!/bin/bash
# run-all.sh — orchestrate every hardware-test phase and emit a markdown
# report. Designed to be the single command a maintainer runs before a release.
#
# Usage:
#   ./run-all.sh root@192.168.1.1 [branch]
#   HW_SKIP_PHASES=phase4 ./run-all.sh ...     # comma-list of phases to skip
#   HW_SSH_KEY=~/.ssh/beryl ./run-all.sh ...   # SSH key path (defaults
#                                              # match ssh's id_* search)
#
# PRECONDITION: the router is in a fresh-OpenWrt + SSH-access state. Factory
# reset and SSH setup (root password + authorized_keys) are manual steps —
# automating factoryreset would wipe authorized_keys and lock the framework
# out. See README.md → Precondition.
#
# Phase order is phase0 → 1 → 2 → 3 → 6 → 4. Phase 0 is the precondition gate
# (aborts the run on fail). Phase 4 (fault injection) runs last but is
# non-destructive — it exercises the replace_awg_conf rollback path on the
# install from phase 1, no firstboot needed.
#
# Outputs:
#   • Live log to stdout (tee'd from each phase)
#   • Markdown summary to stdout at the end + saved at /tmp/cheburnet-hwtest-*.md
#   • Full log saved at /tmp/cheburnet-hwtest-*.log

set -u

# ─── arg parsing ─────────────────────────────────────────────────────────────
# Precondition: the router is already in a "fresh OpenWrt + SSH access" state.
# Factory reset + LuCI password + authorized_keys setup is the user's job —
# automated factoryreset would wipe authorized_keys and lock the framework
# out, defeating the test. Phase 0 enforces the precondition and aborts the
# run if not met. See README.md → Precondition section.
ARGS=()
for a in "$@"; do
    case "$a" in
        --help|-h)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

ROUTER="${1:-root@192.168.1.1}"
BRANCH="${2:-master}"
HW_DIR="$(cd "$(dirname "$0")" && pwd)"
SKIP_PHASES="${HW_SKIP_PHASES:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/tmp/cheburnet-hwtest-${STAMP}.log"
MD_FILE="/tmp/cheburnet-hwtest-${STAMP}.md"

. "$HW_DIR/lib.sh"
hw_init "$ROUTER" "$BRANCH"

# ─── per-phase aggregation ───────────────────────────────────────────────────
PHASE_NAMES=()
PHASE_LABELS=()
declare -A PASS_OF FAIL_OF TOTAL_OF WARN_OF FAILS_OF

phase_skipped() {
    case ",${SKIP_PHASES}," in *",$1,"*) return 0 ;; esac
    return 1
}

run_phase() {
    local pid=$1 label=$2 script=$3
    PHASE_NAMES+=("$pid")
    PHASE_LABELS+=("$label")
    if phase_skipped "$pid"; then
        PASS_OF[$pid]=0; FAIL_OF[$pid]=0; TOTAL_OF[$pid]=0; WARN_OF[$pid]=0
        FAILS_OF[$pid]="(skipped)"
        printf '\n[INFO] %s: skipped via HW_SKIP_PHASES\n' "$pid" | tee -a "$LOG_FILE"
        return 0
    fi

    local phase_log
    phase_log=$(mktemp)
    # Run phase as subprocess so an `exit 1` doesn't kill us. Tee output to
    # both the run-wide log and a per-phase temp file we parse below.
    bash "$HW_DIR/$script" "$ROUTER" "$BRANCH" 2>&1 | tee "$phase_log" | tee -a "$LOG_FILE"

    # Parse summary line: "✓ Phase N — label: PASS (M/N)" or "✗ ... FAIL (M/N)".
    # The lib.sh emits ANSI codes only on TTY; tee disables TTY so we get plain.
    local summary counts pass total fail warn fails
    summary=$(grep -E '(✓|✗) .+ (PASS|FAIL) \([0-9]+/[0-9]+\)' "$phase_log" | tail -1)
    counts=$(echo "$summary" | grep -oE '\([0-9]+/[0-9]+\)' | tr -d '()' )
    if [ -n "$counts" ]; then
        pass="${counts%/*}"
        total="${counts#*/}"
        fail=$((total - pass))
    else
        pass=0; total=0; fail=1
    fi
    warn=$(echo "$summary" | grep -oE '\([0-9]+ warnings?\)' | grep -oE '[0-9]+' || echo 0)
    fails=$(awk '/^  Failures:/{flag=1; next} flag && /^    - /{print substr($0,7); next} flag && !/^    /{flag=0}' "$phase_log")
    PASS_OF[$pid]=$pass
    FAIL_OF[$pid]=$fail
    TOTAL_OF[$pid]=$total
    WARN_OF[$pid]=${warn:-0}
    FAILS_OF[$pid]="$fails"
    rm -f "$phase_log"
}

# ─── header ──────────────────────────────────────────────────────────────────
START=$(date +%s)
{
    echo "═══════════════════════════════════════════════════════════════"
    echo " Cheburnet hardware tests — $ROUTER (branch=$BRANCH)"
    echo " Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo " Log:    $LOG_FILE"
    echo " Report: $MD_FILE"
    echo "═══════════════════════════════════════════════════════════════"
} | tee "$LOG_FILE"

# ─── ordered phase execution ─────────────────────────────────────────────────
# phase 0 is the precondition gate — if it fails, the user hasn't done the
# manual factoryreset+SSH setup, so everything else is meaningless. Abort
# fast with a helpful message rather than cascading 30+ false fails.
run_phase phase0 "clean state" phase0-cleanstate.sh
if [ "${FAIL_OF[phase0]:-0}" -gt 0 ]; then
    {
        echo
        echo "✗ Phase 0 failed — precondition not met. Run aborted."
        echo
        echo "T4 expects a fresh-OpenWrt + SSH-access state. Steps to fix:"
        echo "  1. Factory-reset the router (LuCI: System → Backup/Flash → Reset"
        echo "     OR GL.iNet web UI: Settings → Factory Reset, OR press the"
        echo "     reset button per the hardware manual)."
        echo "  2. Connect to http://192.168.1.1/ in a browser."
        echo "  3. Set a root password when prompted."
        echo "  4. System → Administration → SSH-Keys → paste \$HW_SSH_KEY.pub."
        echo "  5. Verify: ssh -i \$HW_SSH_KEY root@192.168.1.1 'echo up'."
        echo "  6. Re-run this script."
        echo
        echo "See tests/hardware/README.md → Precondition for the full checklist."
    } | tee -a "$LOG_FILE"
    exit 1
fi
run_phase phase1 "happy install"         phase1-install.sh
run_phase phase2 "web UI via RPC"        phase2-webui.sh
run_phase phase3 "CLI tools"             phase3-cli.sh
run_phase phase6 "reboot + steady state" phase6-reboot.sh
run_phase phase4 "failure injection"     phase4-failures.sh

# ─── markdown report ─────────────────────────────────────────────────────────
END=$(date +%s)
DURATION=$((END - START))
HOURS=$((DURATION / 3600))
MIN=$(((DURATION % 3600) / 60))
SEC=$((DURATION % 60))
if [ "$HOURS" -gt 0 ]; then DUR_STR="${HOURS}h ${MIN}m"
elif [ "$MIN" -gt 0 ]; then DUR_STR="${MIN}m ${SEC}s"
else DUR_STR="${SEC}s"; fi

OW_VER=$(ssh_router "awk -F'=' '/DISTRIB_RELEASE/{gsub(/[\"\\047]/,\"\",\$2); print \$2}' /etc/openwrt_release 2>/dev/null" || echo "?")
HW_NAME=$(ssh_router "cat /tmp/sysinfo/model 2>/dev/null" || echo "?")

OVERALL_FAIL=0
for p in "${PHASE_NAMES[@]}"; do
    OVERALL_FAIL=$((OVERALL_FAIL + ${FAIL_OF[$p]:-0}))
done

{
    echo
    echo '```'
    echo "=== Cheburnet automated hardware test ==="
    echo "Branch:   $BRANCH"
    echo "Router:   $HW_NAME, OpenWrt $OW_VER"
    echo "Date:     $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "Duration: $DUR_STR"
    echo
    for i in "${!PHASE_NAMES[@]}"; do
        pid="${PHASE_NAMES[$i]}"
        label="${PHASE_LABELS[$i]}"
        pass="${PASS_OF[$pid]:-0}"
        total="${TOTAL_OF[$pid]:-0}"
        fail="${FAIL_OF[$pid]:-0}"
        if [ "$total" -eq 0 ] && [ "${FAILS_OF[$pid]:-}" = "(skipped)" ]; then
            printf "Phase %-2s (%-22s): ⏭  skipped\n" "${pid#phase}" "$label"
        else
            warn="${WARN_OF[$pid]:-0}"; wtag=""
            [ "$warn" -gt 0 ] && wtag=" — $warn warning(s)"
            if [ "$fail" -eq 0 ]; then
                printf "Phase %-2s (%-22s): ✅ PASS (%d/%d)%s\n" "${pid#phase}" "$label" "$pass" "$total" "$wtag"
            else
                printf "Phase %-2s (%-22s): ❌ FAIL (%d/%d)%s\n" "${pid#phase}" "$label" "$pass" "$total" "$wtag"
                printf '%s\n' "${FAILS_OF[$pid]}" | while IFS= read -r line; do
                    [ -n "$line" ] && printf "   - %s\n" "$line"
                done
            fi
        fi
    done
    echo
    if [ "$OVERALL_FAIL" -eq 0 ]; then
        echo "OVERALL: ✅ PASS"
    else
        echo "OVERALL: ❌ FAIL ($OVERALL_FAIL failed checks across phases)"
    fi
    echo '```'
} | tee "$MD_FILE" | tee -a "$LOG_FILE"

echo
echo "Full log:    $LOG_FILE"
echo "Markdown:    $MD_FILE"

[ "$OVERALL_FAIL" -eq 0 ]
