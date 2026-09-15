# shellcheck shell=bash
# scripts/checks/one-prompt.sh — the commands the README's one prompt tells an agent to run, run the way it
# runs them. Sourced by scripts/characterize.sh.
#
# Each check here is a defect a red team measured against the prompt: a plain --verify after an --only
# install judged the default profile and reported a successful install as FAILED (exit 20); a plain
# --uninstall would have left the installed module in place; the "look" commands wrote state while the
# prompt said they wrote nothing; and the model-advisor step named a path a curl'd run does not have.

OP_FIRST="$(printf '%s\n' "$MODULES" | head -1)"

# 1. --verify and --uninstall with nothing chosen act on what is installed here.
h="$(fresh_home one-prompt)"
drive_at "$h" --only "$OP_FIRST"
same "prompt-install-only-rc" "$CHECK_RC" 0
CHECK_OUT="$(HOME="$h" /bin/bash "$CHECK_ROOT/bootstrap.sh" --verify 2>&1)"; CHECK_RC=$?
same "plain-verify-judges-what-is-installed-rc" "$CHECK_RC" 0
case "$CHECK_OUT" in *"what is installed here -> 1 of"*) pass "plain-verify-says-what-it-judged" ;;
  *) fail "plain-verify-says-what-it-judged" "$(printf '%s\n' "$CHECK_OUT" | grep -m1 'selection:')" ;; esac
drive_at "$h" --uninstall
same "plain-uninstall-rc" "$CHECK_RC" 0
if ls "$h/.mac-bootstrap/rows"/*.state >/dev/null 2>&1; then fail "plain-uninstall-removes-what-is-installed" "$(ls "$h/.mac-bootstrap/rows")"
else pass "plain-uninstall-removes-what-is-installed"; fi
# NEGATIVE CONTROL: with nothing installed, a plain --verify still judges the default profile.
h="$(fresh_home one-prompt-empty)"
CHECK_OUT="$(HOME="$h" /bin/bash "$CHECK_ROOT/bootstrap.sh" --verify 2>&1)"; CHECK_RC=$?
case "$CHECK_OUT" in *"selection: lite ->"*) pass "empty-verify-falls-back-to-the-default" "rc $CHECK_RC" ;;
  *) fail "empty-verify-falls-back-to-the-default" "$(printf '%s\n' "$CHECK_OUT" | grep -m1 'selection:')" ;; esac

# 2. The looking commands change nothing — in a clone, not even a state directory appears.
h="$(fresh_home one-prompt-look)"
for OP_MODE in --list --plan "--plan --profile full" --manifest --egress --advise-model; do
  # shellcheck disable=SC2086  # the mode is deliberately word-split into flags
  HOME="$h" /bin/bash "$CHECK_ROOT/bootstrap.sh" $OP_MODE >/dev/null 2>&1
done
if [ -e "$h/.mac-bootstrap" ] || [ -e "$h/.claude" ] || [ -e "$h/.copilot" ]; then
  fail "looking-changes-nothing" "$(cd "$h" && find . -mindepth 1 -maxdepth 2 | head -5 | tr '\n' ' ')"
else pass "looking-changes-nothing" "list, plan, manifest, egress, advise-model"; fi

# 3. The model advisor is one command, from the verified tree, wherever the script was saved.
CHECK_OUT="$(cd "$CHECK_WORK" && HOME="$h" /bin/bash "$CHECK_ROOT/bootstrap.sh" --advise-model 2>&1)"; CHECK_RC=$?
case "$CHECK_RC:$CHECK_OUT" in 0:*agent-model-brief.md*) pass "advise-model-runs-from-anywhere" ;;
  *) fail "advise-model-runs-from-anywhere" "rc $CHECK_RC: $(printf '%s\n' "$CHECK_OUT" | tail -1)" ;; esac
