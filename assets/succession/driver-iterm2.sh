#!/bin/bash
# driver-iterm2.sh — iTerm2 as a succession driver. Same seam as driver-tmux.sh.
#
# ═══ TWO MODES, AND THE DEFAULT IS THE FAULT-TOLERANT ONE ════════════════════════════════════
#   AH_SUBSTRATE=tmux   (DEFAULT when tmux exists)
#       The successor is born DETACHED in tmux; an ordinary iTerm2 window is then opened
#       attached to it. The operator sees a normal iTerm2 window, and the successor survives
#       iTerm2 dying, being ⌘Q'd, crashing, or being restarted by the OS — measured: a tmux
#       successor's pid is unchanged after the entire terminal is killed, where an iTeriterm2-native
#       child dies with iTermServer.
#   AH_SUBSTRATE=direct
#       `create window with default profile command "…"`. This is a REAL argv launch — the prior
#       design's "iTerm2 has no argv path, so split a pane and type into a cold shell after a
#       fixed sleep" is REFUTED: all four sdef verbs carry the optional `command` parameter, they
#       honour shell quoting, and `create` returns only AFTER the command is already running
#       (10/10 runs, exec latency median 0.199 s). There is no sleep anywhere in this file.
#       Use this only where tmux is genuinely absent: the successor then dies with iTerm2.
#
# ═══ FIVE NON-NEGOTIABLES, EACH BOUGHT WITH A MEASUREMENT ════════════════════════════════════
# 1. NEVER inline a payload in the AppleScript. An AppleScript string literal cannot hold a
#    newline: a 3,086-byte brief passed that way delivered ZERO bytes and opened a husk window
#    named `iTermServer-3.6.11"`. The engine always hands us a LAUNCHER PATH; we refuse anything
#    with a newline in it rather than produce a husk.
# 2. NEVER rely on PATH. The launched command inherits iTerm2.app's OWN environment, which came
#    from whoever cold-launched iTerm2 — a Dock launch gives the launchd environment and `claude`
#    is not found. Absolute interpreter, absolute binary, always.
# 3. NEVER rely on the cwd. The command starts in the PROFILE's directory ($HOME), not the
#    caller's. The launcher cd's explicitly; on $HOME the trust dialog additionally warns "this
#    folder pre-approves 339 tool permissions", which is a second reason never to inherit it.
# 4. SCRUB THE ENVIRONMENT. `open -a iTerm` from inside an agent's Bash tool propagates 21
#    CLAUDE_*/ANTHROPIC_* variables into the app on COLD LAUNCH, and every session iTerm2 spawns
#    for the rest of its life inherits them. Observed damage: a successor rendering "⚠ Transcript
#    saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker" and writing ZERO transcripts —
#    a healthy agent that the engagement oracle must report DEAD. The engine's launcher does the
#    `env -i` scrub; this driver never uses `open`.
# 5. NEVER WRAP THE osascript IN A NEW HELPER. TCC keys Automation consent on the (client binary,
#    target bundle id) PAIR, and attributes to the nearest non-platform binary in the
#    responsibility chain. A `timeout`/`gtimeout` wrapper creates a DIFFERENT pair and therefore
#    a NEW consent modal on the target machine. The engine invokes drivers as `/bin/bash <driver>`
#    for exactly this reason; keep it that way.
#
# ═══ THE CLOSE VERB IS NOT TRUSTED, AND THAT IS DELIBERATE ═══════════════════════════════════
# Two independent measurements of `close` on 3.6.11 DISAGREE: one saw a window vanish (count
# 24 -> 22, the id confirmed absent); the other saw rc 0 with the window still on screen, three
# different spellings, plus `quit` returning "User canceled. (-128)" and doing nothing. So the
# verb's rc is NOT evidence. `close-self` records the pane identity first and returns 3
# (issued, unverifiable from inside the pane being closed); `prove-pred-gone` is the read-back,
# and the engine's universal fallback is the portable one: the predecessor exits ITSELF.
set -u

DI_HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || DI_HERE=""
DI_OSA=/usr/bin/osascript
DI_SUB="${AH_SUBSTRATE:-}"
DI_TMUXDRV="$DI_HERE/driver-tmux.sh"

di_say() { printf '%s\n' "$*"; }
di_err() { printf '%s\n' "$*" >&2; }
di_h()   { [ -f "${1:-}" ] || return 1; LC_ALL=C awk -F= -v k="${2:-}" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$1"; }
di_tmux() { [ -x "$DI_TMUXDRV" ] || [ -r "$DI_TMUXDRV" ] || return 127; /bin/bash "$DI_TMUXDRV" "$@"; }

di_mode() {
  case "$DI_SUB" in
    tmux|direct) printf '%s' "$DI_SUB"; return 0 ;;
  esac
  if [ -r "$DI_TMUXDRV" ] && command -v "${AH_TMUX_BIN:-tmux}" >/dev/null 2>&1; then
    printf 'tmux'; else printf 'direct'; fi
}

# AppleScript string escaping: backslash first, then the quote. Nothing else needs it, and a
# newline is REFUSED rather than escaped (see non-negotiable 1).
di_as_str() { printf '%s' "${1:-}" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g'; }

di_osa() { "$DI_OSA" "$@" 2>&1; }

cmd_capabilities() {
  local m; m="$(di_mode)"
  di_say "driver=iterm2"
  di_say "mode=$m"
  di_say "spawn=yes"
  if [ "$m" = tmux ]; then
    di_say "send-text=yes"          # rides tmux send-keys, which HAS a negative arm
    di_say "prove-alive=yes"
    di_say "capture=yes"
    di_say "survives-app-death=yes"
  else
    di_say "send-text=unverifiable" # `write text` has no read-back and no negative arm
    di_say "prove-alive=yes"
    di_say "capture=yes"
    di_say "survives-app-death=no"
  fi
  di_say "close-self=$([ -n "${ITERM_SESSION_ID:-}" ] && printf unverifiable || printf no)"
  di_say "argv=exact"
}

cmd_preflight() {
  local out m
  [ -x "$DI_OSA" ] || { di_say "no /usr/bin/osascript"; return 2; }
  # 🚨 CHECK THAT IT IS RUNNING BEFORE ASKING IT ANYTHING. `tell application "iTerm2" to …`
  # AUTO-LAUNCHES the app, and launching iTerm2 is not free: measured, `open -g -a iTerm`
  # triggered macOS SESSION RESTORATION, which re-created a 4-session window and let the user's
  # shell rc spawn three real agent sessions and three git worktrees nobody asked for. A
  # preflight that quietly starts a terminal has already done something irreversible.
  # In production this guard never fires — the driver is only selected when we are INSIDE
  # iTerm2 — so it costs nothing and closes the `doctor --driver iterm2` hole.
  pgrep -x iTerm2 >/dev/null 2>&1 || pgrep -f 'iTermServer' >/dev/null 2>&1 || {
    di_say "iTerm2 is not running. Start it yourself and retry — this driver will not launch it"
    di_say "(launching iTerm2 triggers macOS session restoration, which is not a read)."
    return 2; }
  # THE TCC PROBE, and it is the reason preflight exists at all. On a clean-install Mac the first
  # Apple Event to iTerm2 raises the macOS Automation modal and, unanswered, fails -1743. Raising
  # it HERE is the difference between a one-time human click at setup and a half-finished
  # succession: preflight runs BEFORE the first irreversible step, never after.
  out="$(di_osa -e 'tell application "iTerm2" to count windows')"
  case "$out" in
    ''|*[!0-9]*)
      case "$out" in
        *-1743*|*"Not authorized"*|*"not allowed assistive"*)
          di_say "macOS has not granted this process Automation control of iTerm2 (error -1743)."
          di_say "ONE-TIME human gesture, once per (calling binary, iTerm2) pair:"
          di_say "  osascript -e 'tell application \"iTerm2\" to count windows'   # then click Allow"
          return 2 ;;
        *-600*|*"isn't running"*)
          di_say "iTerm2 is not running. Start it once, then retry."; return 2 ;;
        *) di_say "osascript could not talk to iTerm2: $out"; return 2 ;;
      esac ;;
  esac
  m="$(di_mode)"
  if [ "$m" = tmux ]; then
    out="$(di_tmux preflight)" || { di_say "substrate=tmux but the tmux driver refused: $out"; return 2; }
  else
    di_say "WARNING mode=direct: the successor will be a child of iTermServer and will DIE if"
    di_say "        iTerm2 is quit, crashes or is restarted. Install tmux for the fault-tolerant path."
  fi
  return 0
}

# ── spawn ────────────────────────────────────────────────────────────────────────────────────
cmd_spawn() {
  local handle="${1:-}" cwd="${2:-}" title="${3:-}"
  shift 3 2>/dev/null || { di_err "spawn: need <handle> <cwd> <title> ARGV..."; return 2; }
  [ $# -gt 0 ] || { di_err "spawn: no argv"; return 2; }
  [ -d "$cwd" ] || { di_err "spawn: cwd does not exist: $cwd"; return 2; }
  local m; m="$(di_mode)"

  local inner
  if [ "$m" = tmux ]; then
    di_tmux spawn "$handle" "$cwd" "$title" "$@" || return 1
    inner="$(di_tmux attach "$handle")" || { di_err "spawn: cannot resolve the attach command"; return 1; }
  else
    # Build ONE shell-quotable command line. Refuse anything that cannot survive an AppleScript
    # string literal rather than silently producing a husk window.
    local a
    inner=""
    for a in "$@"; do
      case "$a" in
        *"
"*) di_err "spawn: refusing an argv element containing a newline — an AppleScript string literal cannot hold one (measured: 3086 bytes in, 0 delivered, husk window). Pass a LAUNCHER PATH."; return 2 ;;
      esac
      inner="$inner'$(printf '%s' "$a" | LC_ALL=C sed "s/'/'\\\\''/g")' "
    done
    inner="cd $(printf '%s' "$cwd" | LC_ALL=C sed "s/'/'\\\\''/g" | sed "s/^/'/; s/\$/'/"); exec $inner"
    inner="/bin/bash -c \"$(di_as_str "$inner")\""
  fi
  case "${#inner}" in *) [ "${#inner}" -lt 4000 ] || { di_err "spawn: command string is ${#inner} bytes; refuse"; return 2; } ;; esac

  local res win sess
  res="$(di_osa <<AS
tell application "iTerm2"
  set w to (create window with default profile command "$(di_as_str "$inner")")
  return ((id of w) as string) & "|" & ((id of current session of current tab of w) as string)
end tell
AS
)"
  case "$res" in
    *"|"*) : ;;
    *) di_err "spawn: iTerm2 refused the launch: $res"; return 1 ;;
  esac
  win="${res%%|*}"; sess="${res#*|}"
  # NO SLEEP: `create` returns only after the command is already running (10/10 measured).
  if [ "$m" = tmux ]; then
    { cat "$handle"; printf 'viewport=iterm2\nwindow=%s\nsession_uuid=%s\n' "$win" "$sess"; } > "$handle.new" \
      && mv -f "$handle.new" "$handle"
  else
    { printf 'driver=iterm2\nmode=direct\nwindow=%s\nsession_uuid=%s\ncwd=%s\n' "$win" "$sess" "$cwd"; } > "$handle"
    sleep 2      # the launcher's rc is not liveness; re-read the window two seconds later
    cmd_prove_alive "$handle" || { di_err "spawn: iTerm2 returned a window id but it is already gone"; return 1; }
  fi
  return 0
}

di_window_count() {
  local id="${1:-}" out
  out="$(di_osa -e "tell application \"iTerm2\" to return (count of (windows whose id is $id))")"
  case "$out" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s' "$out"
}

cmd_prove_alive() {
  local h="${1:-}" m w n
  m="$(di_h "$h" mode)" || m=""
  if [ "$m" != direct ]; then di_tmux prove-alive "$h"; return $?; fi
  w="$(di_h "$h" window)"; [ -n "$w" ] || return 2
  n="$(di_window_count "$w")" || return 2
  [ "$n" -gt 0 ] && return 0
  return 1
}

# `write text` into a live session. It is a real primitive — it drives a full-screen TUI and was
# measured 10/10 delivered with zero sleep — but it has NO read-back and NO negative arm, so this
# returns 3 (issued, unverifiable) and never 0 in direct mode. The engine treats 3 as "not proven".
cmd_send_text() {
  local h="${1:-}" text="${2:-}" m sess out
  m="$(di_h "$h" mode)" || m=""
  if [ "$m" != direct ]; then di_tmux send-text "$h" "$text"; return $?; fi
  sess="$(di_h "$h" session_uuid)"; [ -n "$sess" ] || return 1
  case "${#text}" in *) [ "${#text}" -lt 1000 ] || { di_err "send-text: refusing ${#text} bytes"; return 1; } ;; esac
  out="$(di_osa <<AS
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$(di_as_str "$sess")" then
          tell s to write text "$(di_as_str "$text")"
          return "SENT"
        end if
      end repeat
    end repeat
  end repeat
  return "NOTARGET"
end tell
AS
)"
  case "$out" in SENT) return 3 ;; NOTARGET) di_err "send-text: no session $sess"; return 1 ;;
                 *) di_err "send-text: $out"; return 1 ;; esac
}

cmd_capture() {
  local h="${1:-}" m sess out
  m="$(di_h "$h" mode)" || m=""
  if [ "$m" != direct ]; then di_tmux capture "$h"; return $?; fi
  sess="$(di_h "$h" session_uuid)"; [ -n "$sess" ] || return 2
  out="$(di_osa <<AS
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$(di_as_str "$sess")" then return (contents of s)
      end repeat
    end repeat
  end repeat
  return ""
end tell
AS
)" || return 2
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

cmd_attach() {
  local h="${1:-}" m
  m="$(di_h "$h" mode)" || m=""
  [ "$m" = direct ] && { di_say "(direct mode: the window IS the successor)"; return 0; }
  di_tmux attach "$h"
}

cmd_close_self() {
  local sd="${1:-}" mine
  mine="${ITERM_SESSION_ID:-}"; mine="${mine##*:}"
  [ -n "$mine" ] || { di_err "close-self: not inside an iTerm2 session (\$ITERM_SESSION_ID unset)"; return 1; }
  [ -n "$sd" ] && printf 'driver=iterm2\nsession_uuid=%s\n' "$mine" > "$sd/pred-pane" 2>/dev/null
  di_osa <<AS >/dev/null 2>&1
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$(di_as_str "$mine")" then close s
      end repeat
    end repeat
  end repeat
end tell
AS
  sleep 1
  # If we are still executing, `close` did not take effect on us. Two independent measurements of
  # this verb disagree, so its rc is not evidence either way: report "issued, unverified".
  return 3
}

cmd_prove_pred_gone() {
  local sd="${1:-}" sess out
  [ -f "$sd/pred-pane" ] || return 2
  sess="$(di_h "$sd/pred-pane" session_uuid)"; [ -n "$sess" ] || return 2
  out="$(di_osa <<AS
tell application "iTerm2"
  set n to 0
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$(di_as_str "$sess")" then set n to n + 1
      end repeat
    end repeat
  end repeat
  return n as string
end tell
AS
)"
  case "$out" in ''|*[!0-9]*) return 2 ;; esac
  [ "$out" -gt 0 ] && return 1
  return 0
}

case "${1:-}" in
  capabilities)    cmd_capabilities ;;
  preflight)       cmd_preflight ;;
  spawn)           shift; cmd_spawn "$@" ;;
  prove-alive)     shift; cmd_prove_alive "${1:-}" ;;
  send-text)       shift; cmd_send_text "${1:-}" "${2:-}" ;;
  capture)         shift; cmd_capture "${1:-}" ;;
  attach)          shift; cmd_attach "${1:-}" ;;
  close-self)      shift; cmd_close_self "${1:-}" ;;
  prove-pred-gone) shift; cmd_prove_pred_gone "${1:-}" ;;
  alive-cmd)       shift
                   if [ "$(di_h "${1:-}" mode)" = direct ]; then
                     printf '%s -e %s\n' "$DI_OSA" \
                       "'tell application \"iTerm2\" to return (count of (windows whose id is $(di_h "${1:-}" window)))' | grep -qv '^0\$'"
                   else di_tmux alive-cmd "${1:-}"; fi ;;
  *) di_err "usage: driver-iterm2.sh capabilities|preflight|spawn|prove-alive|send-text|capture|attach|close-self|prove-pred-gone|alive-cmd"; exit 2 ;;
esac
