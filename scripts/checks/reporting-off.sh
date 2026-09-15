# shellcheck shell=bash
# scripts/checks/reporting-off.sh — the optional-reporting switches. Sourced by scripts/characterize.sh.
#
# It writes three keys into Claude Code's settings and, on the real machine only, flips Homebrew's own
# switch. So besides the install/verify/uninstall arms, one check proves a sandboxed run never reaches
# the real Homebrew repository — the switch lives outside $HOME, where a sandbox cannot contain it.

if [ -r "$CHECK_ROOT/modules/reporting_off.sh" ]; then
  h="$(fresh_home reporting)"
  RB_BREW="$(command -v brew 2>/dev/null)"; RB_BEFORE=""
  [ -n "$RB_BREW" ] && RB_BEFORE="$(git -C "$(HOMEBREW_NO_ANALYTICS=1 "$RB_BREW" --repository)" config --get homebrew.analyticsdisabled 2>/dev/null || printf unset)"

  # Someone else's value for one switch must be kept, and still counts: any non-empty value is on.
  mkdir -p "$h/.claude" && printf '{"env": {"DISABLE_ERROR_REPORTING": "yes"}, "keep": 1}\n' > "$h/.claude/settings.json"
  drive_at "$h" --only reporting_off
  same "reporting-off-install-rc" "$CHECK_RC" 0
  same "reporting-off-keys-read-back" \
    "$(json_at "$h/.claude/settings.json" env.DISABLE_FEEDBACK_COMMAND)/$(json_at "$h/.claude/settings.json" env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY)/$(json_at "$h/.claude/settings.json" env.DISABLE_ERROR_REPORTING)" "1/1/yes"
  RB_SUM="$(shasum -a 256 "$h/.claude/settings.json" | cut -d' ' -f1)"
  drive_at "$h" --only reporting_off
  same "reporting-off-second-run-changes-nothing" "$(shasum -a 256 "$h/.claude/settings.json" | cut -d' ' -f1)" "$RB_SUM"

  # NEGATIVE CONTROL: take one switch away and verify must say no.
  plutil -remove env.DISABLE_FEEDBACK_COMMAND "$h/.claude/settings.json" >/dev/null 2>&1
  HOME="$h" /bin/bash "$CHECK_ROOT/bootstrap.sh" --verify --only reporting_off >/dev/null 2>&1; CHECK_RC=$?
  same "reporting-off-verify-sees-a-missing-switch" "$CHECK_RC" 20

  drive_at "$h" --uninstall --only reporting_off
  same "reporting-off-uninstall-keeps-what-is-not-ours" \
    "$(json_at "$h/.claude/settings.json" env.DISABLE_ERROR_REPORTING)/$(json_at "$h/.claude/settings.json" keep)/$(json_at "$h/.claude/settings.json" env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY || printf gone)" "yes/1/gone"

  if [ -n "$RB_BREW" ]; then
    same "reporting-off-sandbox-never-touches-homebrew" \
      "$(git -C "$(HOMEBREW_NO_ANALYTICS=1 "$RB_BREW" --repository)" config --get homebrew.analyticsdisabled 2>/dev/null || printf unset)" "$RB_BEFORE"
  else
    pass "reporting-off-sandbox-never-touches-homebrew" "n/a: no Homebrew here"
  fi
fi
