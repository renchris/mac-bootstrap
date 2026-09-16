# shellcheck shell=bash
# scripts/checks/kitty-remote-control.sh — kitty.conf must enable remote control, because /handoff's
# kitty driver refuses without it. Sourced by scripts/characterize.sh, which supplies the harness;
# never run on its own.
#
# WHAT IS BEING PINNED. `assets/succession/driver-kitty.sh` (footgun F4) needs allow_remote_control
# AND a listen_on carrying a per-instance token: a LITERAL listen_on path is accepted by kitty's
# parser and then silently ignored — no socket, empty stderr — so "listen_on is set" is not the
# property that matters and asserting it would be a green over a dead socket. Every arm below reads
# the file back through KITTY'S OWN PARSER, never with a grep for the string the installer wrote.
#
# It needs a real kitty. Without one there is nothing to parse with and every arm records n/a: a
# check that quietly asserted nothing would be worse than one that says it did not run.

KRC_BIN=""
KRC_BIN="$(command -v kitty 2>/dev/null)" || KRC_BIN=""
if [ -z "$KRC_BIN" ]; then
  for KRC_APP in /Applications/kitty.app "$HOME/Applications/kitty.app"; do
    [ -x "$KRC_APP/Contents/MacOS/kitty" ] && { KRC_BIN="$KRC_APP/Contents/MacOS/kitty"; break; }
  done
fi

if [ -z "$KRC_BIN" ]; then
  pass "kitty-remote-control" "n/a: no kitty on this machine"
elif [ ! -r "$CHECK_ROOT/modules/pane_equalize.sh" ]; then
  pass "kitty-remote-control" "n/a: pane_equalize is not in this tree"
else

  # krc_read <conf> — "<allow_remote_control>|<listen_on>", straight out of kitty's config parser.
  # 🚨 NO `def` IN THE PYTHON: `kitty +runpy` exec's it inside a function body, so a helper defined
  #    here cannot see a module-level import and dies inside its own except arm. Keep it flat.
  krc_read() {
    KRC_CONF="$1" "$KRC_BIN" +runpy '
import os
from kitty.config import load_config
c = load_config(os.environ["KRC_CONF"])
print(str(getattr(c, "allow_remote_control", "")) + "|" + str(getattr(c, "listen_on", "")))
' 2>/dev/null | tail -1
  }

  krc_drive() {                                 # krc_drive <home> <args…>
    local h="$1"; shift
    # shellcheck disable=SC2034  # CHECK_OUT is the harness's "last driver output"; set so a later
    # check's diagnostic cannot quote a run that is not the most recent one.
    CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" /usr/bin/env -u CLAUDE_CONFIG_DIR \
      /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" 2>&1)"
    CHECK_RC=$?
    return 0
  }

  # ── 0. the instrument must be able to say NO before any yes it gives means anything ─────────
  mkdir -p "$CHECK_TMP/krc-empty"
  : > "$CHECK_TMP/krc-empty/kitty.conf"
  same "krc-reader-says-no-on-an-empty-config" "$(krc_read "$CHECK_TMP/krc-empty/kitty.conf")" "no|none"

  # ── 1. a clean install enables it ───────────────────────────────────────────────────────────
  KRC_HOME="$(fresh_home kitty-rc)"
  KRC_CONF_PATH="$KRC_HOME/.config/kitty/kitty.conf"
  krc_drive "$KRC_HOME" --only pane_equalize
  same "krc-install-rc" "$CHECK_RC" 0

  KRC_READ="$(krc_read "$KRC_CONF_PATH")"
  same "krc-allow-remote-control-is-socket-only" "${KRC_READ%%|*}" "socket-only"
  same "krc-listen-on-carries-the-pid-token" "${KRC_READ##*|}" "unix:/tmp/kitty-{kitty_pid}"

  # ── 2. NEGATIVE CONTROL: take listen_on away and a cold verify must say no ──────────────────
  # This is the arm that makes the one above mean something: without it, a verify_ that never
  # looked at listen_on at all would pass every check in this file.
  grep -v '^listen_on ' "$KRC_CONF_PATH" > "$CHECK_WORK/krc.conf" && cat "$CHECK_WORK/krc.conf" > "$KRC_CONF_PATH"
  krc_drive "$KRC_HOME" --verify --only pane_equalize
  same "krc-verify-says-no-without-listen-on" "$CHECK_RC" 20
  krc_drive "$KRC_HOME" --only pane_equalize
  KRC_READ="$(krc_read "$KRC_CONF_PATH")"
  same "krc-reinstall-puts-it-back" "${KRC_READ##*|}" "unix:/tmp/kitty-{kitty_pid}"

  # ── 3. idempotent: the second run changes not one byte ──────────────────────────────────────
  KRC_SUM="$(shasum -a 256 "$KRC_CONF_PATH" 2>/dev/null | cut -d' ' -f1)"
  krc_drive "$KRC_HOME" --only pane_equalize
  same "krc-second-run-changes-nothing" \
    "$(shasum -a 256 "$KRC_CONF_PATH" 2>/dev/null | cut -d' ' -f1)" "$KRC_SUM"

  # ── 4. a value the operator already chose is KEPT, never replaced with ours ─────────────────
  # `yes` is broader than socket-only and their own socket already carries the token, so there is
  # nothing to fix and nothing may be written.
  KRC_HOME2="$(fresh_home kitty-rc-own)"
  mkdir -p "$KRC_HOME2/.config/kitty"
  printf 'allow_remote_control yes\nlisten_on unix:/tmp/mine-{kitty_pid}\n' > "$KRC_HOME2/.config/kitty/kitty.conf"
  krc_drive "$KRC_HOME2" --only pane_equalize
  same "krc-own-choice-is-kept" "$(krc_read "$KRC_HOME2/.config/kitty/kitty.conf")" \
    "yes|unix:/tmp/mine-{kitty_pid}"

  # ── 5. `password` is the operator's deliberate, NARROWER choice and may not be weakened ─────
  # Writing the password would be writing a credential (house rule 6), so the module satisfies the
  # half it can — the socket — and leaves the value alone.
  KRC_HOME3="$(fresh_home kitty-rc-pw)"
  mkdir -p "$KRC_HOME3/.config/kitty"
  printf 'allow_remote_control password\nremote_control_password "fixture"\n' > "$KRC_HOME3/.config/kitty/kitty.conf"
  krc_drive "$KRC_HOME3" --only pane_equalize
  same "krc-password-is-not-weakened" \
    "$(krc_read "$KRC_HOME3/.config/kitty/kitty.conf")" "password|unix:/tmp/kitty-{kitty_pid}"

  # ── 6. a LITERAL listen_on is the silent-failure case, so it is overridden ──────────────────
  KRC_HOME4="$(fresh_home kitty-rc-literal)"
  mkdir -p "$KRC_HOME4/.config/kitty"
  printf 'allow_remote_control socket-only\nlisten_on unix:/tmp/a-fixed-path\n' > "$KRC_HOME4/.config/kitty/kitty.conf"
  krc_drive "$KRC_HOME4" --only pane_equalize
  same "krc-literal-listen-on-is-overridden" \
    "$(krc_read "$KRC_HOME4/.config/kitty/kitty.conf")" "socket-only|unix:/tmp/kitty-{kitty_pid}"

  # ── 7. uninstall takes ours out and leaves theirs ───────────────────────────────────────────
  krc_drive "$KRC_HOME4" --uninstall --only pane_equalize
  same "krc-uninstall-restores-their-own-lines" \
    "$(krc_read "$KRC_HOME4/.config/kitty/kitty.conf")" "socket-only|unix:/tmp/a-fixed-path"

  # ── 8. the disclosure: a listening socket is something IT governs, and it is declared ────────
  KRC_CLEAR="$(HOME="$KRC_HOME" /usr/bin/env -u CLAUDE_CONFIG_DIR /bin/bash "$CHECK_ROOT/bootstrap.sh" --list 2>&1)"
  case "$KRC_CLEAR" in
    *"unix socket"*) pass "krc-clearance-declares-the-socket" ;;
    *) fail "krc-clearance-declares-the-socket" "--list names no socket under pane_equalize" ;;
  esac

  unset -f krc_read krc_drive
fi
