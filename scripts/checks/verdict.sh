# shellcheck shell=bash
# scripts/checks/verdict.sh — the exit code is a verdict over the SELECTION, never over every row on
# disk. Sourced by scripts/characterize.sh.
#
# Measured before the fix: one FAILED row left by an earlier run for a module this run did not select
# made every later run exit 20 — `--only statusline` included — and nothing the person could re-run
# would clear it. The receipt still keeps that row (--only merges), marked "this_run": false.

h="$(fresh_home verdict)"
drive_at "$h" --only statusline
same "verdict-baseline-only-statusline-rc" "$CHECK_RC" 0

# An old FAILED row for a module outside the selection: history, not a verdict.
printf 'FAILED' > "$h/.mac-bootstrap/rows/instructions.state"
printf 'not installed' > "$h/.mac-bootstrap/rows/instructions.note"
drive_at "$h" --only statusline
same "verdict-ignores-a-row-outside-the-selection" "$CHECK_RC" 0
same "verdict-receipt-keeps-the-old-row-as-history" \
  "$(receipt_states "$h/.mac-bootstrap/receipt.json" | grep '^instructions ')" "instructions FAILED"
VD_I=0; VD_THIS=""
while [ "$VD_I" -lt 64 ]; do
  VD_M="$(json_at "$h/.mac-bootstrap/receipt.json" "modules.$VD_I.module")" || break
  VD_THIS="$VD_THIS $VD_M=$(json_at "$h/.mac-bootstrap/receipt.json" "modules.$VD_I.this_run")"
  VD_I=$((VD_I + 1))
done
case "$VD_THIS" in
  *" instructions=false"*" statusline=true"*|*" statusline=true"*" instructions=false"*)
    pass "verdict-receipt-marks-this-run" "$VD_THIS" ;;
  *) fail "verdict-receipt-marks-this-run" "$VD_THIS" ;;
esac

# Negative control: the same FAILED row, now INSIDE the selection, must still fail the run.
drive_at "$h" --only statusline,instructions --verify
case "$CHECK_RC" in
  0) fail "control-verdict-still-fails-a-selected-row" "rc 0 over a selection holding a module that is not installed" ;;
  *) pass "control-verdict-still-fails-a-selected-row" "rc $CHECK_RC" ;;
esac
