# shellcheck shell=bash
# modules/reporting_off.sh — switch off the optional reporting that can carry detail off this Mac.
#
# A coding agent must send what it reads to its model provider; that is the one egress no module can
# remove, and --egress states it. What an agent and its tools send IN ADDITION is optional, and some
# of it carries far more than a usage count:
#
#   Claude Code   /feedback uploads the session transcript, code included, kept five years; a survey
#                 follow-up can upload it too; error reports carry stack traces. Each has its own
#                 switch, and all three go in the `env` block of $HOME/.claude/settings.json, which
#                 Claude Code applies to every session and every process it starts (documented).
#   Homebrew      every `brew install` reports the package to Homebrew's analytics host until
#                 `brew analytics off`, which it keeps in its own repository's git config.
#
# DELIBERATELY NOT SWITCHED: DISABLE_TELEMETRY, DO_NOT_TRACK and CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
# also stop Claude Code's feature-flag fetch, which silently removes Remote Control, auto mode by
# default, the advisor and more (documented) — a cost the person did not ask to pay. Its usage metrics
# carry "never your code, prompts, or file paths" (documented). Copilot CLI has no user-level switch
# at all (only COPILOT_OFFLINE with a local model), so there is nothing here to write for it; --egress
# says so rather than pretending.
#
# Source: .claude-plans research agent-egress-catalogue (A), each switch cited to code.claude.com/docs.

REPORTING_OFF_CLAUDE_ENV="DISABLE_ERROR_REPORTING DISABLE_FEEDBACK_COMMAND CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY"
REPORTING_OFF_MARKER_BREW="reporting_off.brew-analytics"   # we turned Homebrew's analytics off, so uninstall turns them back on

reporting_off_claude_settings() { printf '%s/.claude/settings.json' "$HOME"; }
reporting_off_state()           { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }

# The Homebrew this user can switch: one that exists and whose repository this user owns. A Homebrew
# an administrator installed for someone else is theirs to configure, not ours. Its switch lives in its
# own repository, OUTSIDE $HOME, so under a sandboxed HOME it is never touched (bootstrap_home_is_real).
reporting_off_brew() {
  local b repo
  bootstrap_home_is_real || return 1
  b="$(bootstrap_find_tool brew)" || return 1
  repo="$(HOMEBREW_NO_ANALYTICS=1 "$b" --repository 2>/dev/null)" || return 1
  [ -d "$repo/.git" ] && [ -w "$repo/.git/config" ] || return 1
  printf '%s' "$b"
}
# Read back through git, not through brew — a different reader from the `brew analytics off` that wrote it.
reporting_off_brew_off() {
  local b repo
  b="$(reporting_off_brew)" || return 1
  repo="$(HOMEBREW_NO_ANALYTICS=1 "$b" --repository 2>/dev/null)" || return 1
  [ "$(git -C "$repo" config --get homebrew.analyticsdisabled 2>/dev/null)" = true ]
}

# Each Claude Code switch treats ANY non-empty value as on (documented), so "set and non-empty" is the test.
reporting_off_claude_missing() {
  local k v f out=""
  f="$(reporting_off_claude_settings)"
  for k in $REPORTING_OFF_CLAUDE_ENV; do
    v="$(bootstrap_settings_get "$f" "env.$k" raw 2>/dev/null)" || v=""
    [ -n "$v" ] || out="$out $k"
  done
  printf '%s' "${out# }"
}

what_reporting_off()    { printf '%s' "switches off optional reporting that can carry your code or project off this Mac: Claude Code's /feedback transcript uploads, survey follow-ups and error reports, and Homebrew's install analytics"; }
cost_reporting_off()    { printf '%s' "three keys in Claude Code's settings and Homebrew's own switch. No installs, no permissions. Keeps feature flags, so nothing you use goes away. Copilot CLI has no such switch."; }
profile_reporting_off() { printf '%s' 'standard'; }
egress_reporting_off()  { :; }

verify_reporting_off() {
  [ -z "$(reporting_off_claude_missing)" ] || return 1
  # Homebrew counts only when this user can switch it; otherwise there is nothing of ours to verify.
  if reporting_off_brew >/dev/null 2>&1; then reporting_off_brew_off || return 1; fi
  return 0
}
gate_reporting_off()    { return 1; }
note_reporting_off()    { printf 'optional reporting is still on: %s' "$(reporting_off_claude_missing)"; }
gesture_reporting_off() { :; }

install_reporting_off() {
  local f k b rc=0
  f="$(reporting_off_claude_settings)"
  # Only a switch that is not already on is written: a value someone else set — any non-empty value
  # already switches it off — is theirs, and overwriting it would make uninstall_ remove it.
  for k in $(reporting_off_claude_missing); do
    bootstrap_settings_merge "$f" "env.$k" '"1"' || rc=1
  done
  if b="$(reporting_off_brew)" && ! reporting_off_brew_off; then
    if HOMEBREW_NO_ANALYTICS=1 "$b" analytics off >/dev/null 2>&1; then
      : > "$(reporting_off_state)/$REPORTING_OFF_MARKER_BREW"
    else
      bootstrap_warn "reporting_off: brew analytics off failed"; rc=1
    fi
  fi
  return "$rc"
}

# Removes exactly what install_ wrote: a key whose value is not our "1" was set by someone else.
uninstall_reporting_off() {
  local f k b rc=0
  f="$(reporting_off_claude_settings)"
  for k in $REPORTING_OFF_CLAUDE_ENV; do
    [ "$(bootstrap_settings_get "$f" "env.$k" raw 2>/dev/null)" = 1 ] || continue
    bootstrap_settings_remove "$f" "env.$k" || rc=1
  done
  if [ -e "$(reporting_off_state)/$REPORTING_OFF_MARKER_BREW" ]; then
    if b="$(reporting_off_brew)"; then HOMEBREW_NO_ANALYTICS=1 "$b" analytics on >/dev/null 2>&1 || rc=1; fi
    rm -f "$(reporting_off_state)/$REPORTING_OFF_MARKER_BREW"
  fi
  return "$rc"
}
