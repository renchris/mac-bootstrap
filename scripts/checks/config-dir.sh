# shellcheck shell=bash
# scripts/checks/config-dir.sh — CLAUDE_CONFIG_DIR is where Claude Code's config actually lives, so it
# is where a module must write and where verify_ must read. Sourced by scripts/characterize.sh, which
# supplies the harness; never run on its own.
#
# THE DEFECT THIS PINS. Every module hardcoded $HOME/.claude, so on a Mac that sets CLAUDE_CONFIG_DIR —
# a supported Claude Code variable — the install wrote files the agent never opens and verify_ then
# read those same files back and reported SATISFIED over them. Agreeing with yourself about the wrong
# file is the one failure a read-back verifier is supposed to be immune to, so the arm that matters
# here is not "the files landed" but "$HOME/.claude STAYED EMPTY and a verify pointed there says NO".
#
# characterize.sh unsets CLAUDE_CONFIG_DIR for the whole suite (line 58) so a developer's real account
# can never answer for a sandbox. This file therefore sets it per invocation and never exports it: a
# leak would reach every check sourced after this one, and c sorts early.

if [ -r "$CHECK_ROOT/modules/statusline.sh" ]; then

  # cfgdir_drive <home> <config-dir> <args…> — the driver, sandboxed, with the variable set. Empty
  # <config-dir> means "set nothing", which is the control the default path is measured against.
  cfgdir_drive() {
    local h="$1" c="$2"; shift 2
    if [ -n "$c" ]; then
      CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" CLAUDE_CONFIG_DIR="$c" \
        /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" 2>&1)"
    else
      CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" \
        /usr/bin/env -u CLAUDE_CONFIG_DIR /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" 2>&1)"
    fi
    CHECK_RC=$?
    return 0
  }

  CFGDIR_MODS="statusline,instructions,hooks"
  CFGDIR_HOME="$(fresh_home configdir)"
  CFGDIR_ELSEWHERE="$CHECK_TMP/configdir-elsewhere"

  # ── 1. the variable is honoured: the files land THERE ──────────────────────────────────────
  cfgdir_drive "$CFGDIR_HOME" "$CFGDIR_ELSEWHERE" --only "$CFGDIR_MODS"
  same "cfgdir-install-rc" "$CHECK_RC" 0

  # statusline: read back with plutil, a different engine from the jq that usually wrote it
  same "cfgdir-statusline-registered-there" \
    "$(json_at "$CFGDIR_ELSEWHERE/settings.json" statusLine.command || printf MISSING)" \
    "$CFGDIR_HOME/.mac-bootstrap/bin/agent-statusline.sh"

  # instructions: the shipped file, byte for byte, at the config root
  if cmp -s "$CHECK_ROOT/assets/global-CLAUDE.md" "$CFGDIR_ELSEWHERE/CLAUDE.md"; then
    pass "cfgdir-instructions-placed-there"
  else
    fail "cfgdir-instructions-placed-there" "$CFGDIR_ELSEWHERE/CLAUDE.md is absent or differs"
  fi

  # hooks: at least one lifecycle hook registered in the settings file at the config root
  CFGDIR_HOOKS=0
  json_at "$CFGDIR_ELSEWHERE/settings.json" hooks.SessionStart.0.hooks.0.command >/dev/null 2>&1 && CFGDIR_HOOKS=1
  true_ "cfgdir-hooks-wired-there" "$CFGDIR_HOOKS"

  # ── 2. THE ARM THAT MATTERS: the hardcoded path was not written at all ─────────────────────
  # Before the fix this directory held every file above and the run still exited 0.
  if [ -e "$CFGDIR_HOME/.claude" ]; then
    fail "cfgdir-home-dot-claude-untouched" "$(ls -A "$CFGDIR_HOME/.claude" 2>/dev/null | tr '\n' ' ')"
  else
    pass "cfgdir-home-dot-claude-untouched" "not created"
  fi

  # ── 3. a cold, separate process agrees — and DISAGREES when pointed at the empty default ───
  cfgdir_drive "$CFGDIR_HOME" "$CFGDIR_ELSEWHERE" --verify --only "$CFGDIR_MODS"
  same "cfgdir-verify-agrees-with-the-variable-set" "$CHECK_RC" 0
  # NEGATIVE CONTROL. $HOME/.claude is empty, so a verifier reading there must say no. A verifier
  # that still said 0 would be the original defect wearing a green tick.
  cfgdir_drive "$CFGDIR_HOME" "" --verify --only "$CFGDIR_MODS"
  same "cfgdir-verify-says-no-when-pointed-at-the-default" "$CHECK_RC" 20

  # ── 4. idempotent: the second run changes nothing ──────────────────────────────────────────
  CFGDIR_SUM="$(shasum -a 256 "$CFGDIR_ELSEWHERE/settings.json" 2>/dev/null | cut -d' ' -f1)"
  cfgdir_drive "$CFGDIR_HOME" "$CFGDIR_ELSEWHERE" --only "$CFGDIR_MODS"
  same "cfgdir-second-run-changes-nothing" \
    "$(shasum -a 256 "$CFGDIR_ELSEWHERE/settings.json" 2>/dev/null | cut -d' ' -f1)" "$CFGDIR_SUM"

  # ── 5. a config root that does not exist yet is the operator's intent, so it is created ────
  CFGDIR_HOME2="$(fresh_home configdir-new)"
  cfgdir_drive "$CFGDIR_HOME2" "$CHECK_TMP/configdir-new/deep/root" --only instructions
  same "cfgdir-missing-root-is-created" "$CHECK_RC" 0
  if cmp -s "$CHECK_ROOT/assets/global-CLAUDE.md" "$CHECK_TMP/configdir-new/deep/root/CLAUDE.md"; then
    pass "cfgdir-missing-root-holds-the-file"
  else
    fail "cfgdir-missing-root-holds-the-file" "nothing landed under a config root that had to be made"
  fi

  # ── 6. a RELATIVE root resolves against the cwd, the way the agent's own would ──────────────
  # Run from inside the sandbox HOME so nothing lands in the repo (house rule 10).
  CFGDIR_HOME3="$(fresh_home configdir-rel)"
  # shellcheck disable=SC2034  # CHECK_OUT is the harness's "last driver output"; set so a later
  # check's diagnostic cannot quote a run that is not the most recent one.
  CHECK_OUT="$( cd "$CFGDIR_HOME3" && HOME="$CFGDIR_HOME3" TMPDIR="$CHECK_WORK" CLAUDE_CONFIG_DIR="relative-root" \
    /bin/bash "$CHECK_ROOT/bootstrap.sh" --only instructions 2>&1 )"
  CHECK_RC=$?
  same "cfgdir-relative-root-rc" "$CHECK_RC" 0
  if cmp -s "$CHECK_ROOT/assets/global-CLAUDE.md" "$CFGDIR_HOME3/relative-root/CLAUDE.md"; then
    pass "cfgdir-relative-root-is-honoured"
  else
    fail "cfgdir-relative-root-is-honoured" "$CFGDIR_HOME3/relative-root/CLAUDE.md is absent or differs"
  fi

  # ── 7. a TRAILING SLASH is the same root, not a second one ─────────────────────────────────
  cfgdir_drive "$CFGDIR_HOME" "$CFGDIR_ELSEWHERE/" --verify --only "$CFGDIR_MODS"
  same "cfgdir-trailing-slash-is-the-same-root" "$CHECK_RC" 0

  # ── 8. REGRESSION GUARD: with the variable unset, nothing moved ────────────────────────────
  CFGDIR_HOME4="$(fresh_home configdir-default)"
  cfgdir_drive "$CFGDIR_HOME4" "" --only "$CFGDIR_MODS"
  same "cfgdir-default-still-installs" "$CHECK_RC" 0
  same "cfgdir-default-is-still-home-dot-claude" \
    "$(json_at "$CFGDIR_HOME4/.claude/settings.json" statusLine.command || printf MISSING)" \
    "$CFGDIR_HOME4/.mac-bootstrap/bin/agent-statusline.sh"

  unset -f cfgdir_drive
fi
