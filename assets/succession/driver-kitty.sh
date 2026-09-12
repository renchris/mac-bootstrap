#!/bin/bash
# driver-kitty.sh — kitty as a succession driver. Same seam as driver-tmux.sh.
#
# ═══ KITTY IS A VIEWPORT, NEVER THE SUBSTRATE ════════════════════════════════════════════════
# Measured, one variable — which thing dies:
#   close the LAUNCHING WINDOW  -> the successor SURVIVES (it is a child of the kitty PROCESS,
#                                  not of the requesting window's shell); heartbeat 2 -> 5.
#   kill -TERM the KITTY PROCESS -> the successor is GONE; heartbeat frozen at 5.
# So kitty protects against a window closing and not at all against the terminal app dying — a
# crash, an accidental ⌘Q, or the OS restarting it takes every successor with it. `AH_SUBSTRATE`
# therefore defaults to tmux whenever tmux exists; kitty then only draws the window.
#
# ═══ FOUR MEASURED FOOTGUNS, ALL DEFENDED HERE ═══════════════════════════════════════════════
# F1 `kitty @ send-text` is the ONE verb with NO negative arm: to `--match id:99999` it returns
#    rc 0 and silently does nothing, while ls / close-window / get-text / focus-window all return
#    rc 1 "No matching windows" on the same expression. So send-text's rc is never trusted here:
#    the target is pre-flighted with `@ ls --match <the same expression>`, and delivery is
#    confirmed by READ-BACK or reported as unverified (rc 3).
# F2 `kitty @ close-window` with NO --match and NO --self closes the CURRENTLY ACTIVE window,
#    rc 0, silently. On the operator's shared socket that is one typo from closing a live
#    session. Every call here passes --self or --match env:AHMARK=<our own id>.
# F3 `kitty @ launch --cwd=/nonexistent` returns rc 0 AND a window id, and the child silently
#    starts in the LAUNCHING kitty's cwd — a successor running in the wrong repo with no error.
#    The cwd is asserted before the call and the successor's real pwd is verified after it.
# F4 Remote control needs `allow_remote_control socket-only` AND a `listen_on` that contains a
#    per-instance token such as {kitty_pid}: a LITERAL path in kitty.conf is SILENTLY IGNORED —
#    no socket, EMPTY stderr — and `SIGUSR1` config reload does not create it either, only a
#    restart does. A socket path over the 104-byte sun_path limit makes kitty log "Invalid
#    listen_on…, ignoring" and START ANYWAY. preflight asserts the socket exists rather than
#    assuming the config is honoured.
set -u

DK_HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || DK_HERE=""
DK_KITTY="${AH_KITTY_BIN:-}"
[ -n "$DK_KITTY" ] || DK_KITTY="$(command -v kitty 2>/dev/null)" || DK_KITTY=""
DK_TMUXDRV="$DK_HERE/driver-tmux.sh"
DK_SUB="${AH_SUBSTRATE:-}"

dk_say() { printf '%s\n' "$*"; }
dk_err() { printf '%s\n' "$*" >&2; }
dk_h()   { [ -f "${1:-}" ] || return 1; LC_ALL=C awk -F= -v k="${2:-}" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$1"; }
dk_tmux() { [ -r "$DK_TMUXDRV" ] || return 127; /bin/bash "$DK_TMUXDRV" "$@"; }

# An agent's Bash tool has NO controlling terminal, so `kitty @` cannot fall back to /dev/tty
# ("Error: open /dev/tty: device not configured"). The socket is the only route.
dk_at() { [ -n "$DK_KITTY" ] || return 127
          if [ -n "${KITTY_LISTEN_ON:-}" ]; then "$DK_KITTY" @ --to "$KITTY_LISTEN_ON" "$@"
          else "$DK_KITTY" @ "$@"; fi; }

dk_mode() {
  case "$DK_SUB" in tmux|direct) printf '%s' "$DK_SUB"; return 0 ;; esac
  if [ -r "$DK_TMUXDRV" ] && command -v "${AH_TMUX_BIN:-tmux}" >/dev/null 2>&1; then
    printf 'tmux'; else printf 'direct'; fi
}

cmd_capabilities() {
  local m; m="$(dk_mode)"
  dk_say "driver=kitty"
  dk_say "mode=$m"
  dk_say "spawn=yes"
  if [ "$m" = tmux ]; then
    dk_say "send-text=yes"; dk_say "survives-app-death=yes"
  else
    dk_say "send-text=unverifiable"   # F1: rc 0 for a target that does not exist
    dk_say "survives-app-death=no"
  fi
  dk_say "prove-alive=yes"
  dk_say "capture=yes"
  dk_say "close-self=$([ -n "${KITTY_WINDOW_ID:-}${KITTY_LISTEN_ON:-}" ] && printf yes || printf no)"
  dk_say "argv=exact"
}

cmd_preflight() {
  local m out
  [ -n "$DK_KITTY" ] || { dk_say "kitty is not installed"; return 2; }
  [ -n "${KITTY_LISTEN_ON:-}" ] || {
    dk_say "KITTY_LISTEN_ON is unset — kitty remote control is not reachable from an agent."
    dk_say "ONE-TIME, and it needs a kitty RESTART (SIGUSR1 config reload does NOT create the socket):"
    dk_say "  put these two lines in ~/.config/kitty/kitty.conf, then restart kitty:"
    dk_say "    allow_remote_control socket-only"
    dk_say "    listen_on unix:/tmp/kitty-{kitty_pid}      # a LITERAL path is silently ignored"
    return 2; }
  case "${KITTY_LISTEN_ON#unix:}" in
    /*) [ -S "${KITTY_LISTEN_ON#unix:}" ] || { dk_say "KITTY_LISTEN_ON names ${KITTY_LISTEN_ON#unix:} but no socket is there (a >104-byte path makes kitty log 'Invalid listen_on' and start anyway)"; return 2; } ;;
  esac
  dk_at ls >/dev/null 2>&1 || { dk_say "kitty @ ls failed — remote control is not enabled on this instance"; return 2; }
  # the NEGATIVE arm of the liveness oracle, proven rather than assumed
  if dk_at ls --match id:99999999 >/dev/null 2>&1; then
    dk_say "kitty @ ls answered YES for a window nothing holds — the liveness oracle cannot say NO"; return 2; fi
  m="$(dk_mode)"
  if [ "$m" = tmux ]; then
    out="$(dk_tmux preflight)" || { dk_say "substrate=tmux but the tmux driver refused: $out"; return 2; }
  else
    dk_say "WARNING mode=direct: the successor is a child of the kitty PROCESS and DIES with it"
    dk_say "        (measured). Install tmux for the fault-tolerant path."
  fi
  return 0
}

cmd_spawn() {
  local handle="${1:-}" cwd="${2:-}" title="${3:-}"
  shift 3 2>/dev/null || { dk_err "spawn: need <handle> <cwd> <title> ARGV..."; return 2; }
  [ $# -gt 0 ] || { dk_err "spawn: no argv"; return 2; }
  [ -d "$cwd" ] || { dk_err "spawn: cwd does not exist: $cwd (F3: kitty would return 0 and start in ITS cwd)"; return 2; }
  local m wid mark; m="$(dk_mode)"; mark="ah-$title"

  if [ "$m" = tmux ]; then
    dk_tmux spawn "$handle" "$cwd" "$title" "$@" || return 1
    local att; att="$(dk_tmux attach "$handle")" || { dk_err "spawn: cannot resolve the attach command"; return 1; }
    # shellcheck disable=SC2086
    wid="$(dk_at launch --type=os-window --cwd="$cwd" --title "$mark" --env "AHMARK=$mark" -- $att 2>/dev/null)" || wid=""
    { cat "$handle"; printf 'viewport=kitty\nkitty_window=%s\nkitty_mark=%s\n' "${wid:-}" "$mark"; } > "$handle.new" \
      && mv -f "$handle.new" "$handle"
    return 0
  fi

  wid="$(dk_at launch --type=os-window --cwd="$cwd" --title "$mark" --env "AHMARK=$mark" -- "$@" 2>/dev/null)" || wid=""
  case "${wid:-}" in ''|*[!0-9]*) dk_err "spawn: kitty @ launch did not return a window id"; return 1 ;; esac
  printf 'driver=kitty\nmode=direct\nkitty_window=%s\nkitty_mark=%s\ncwd=%s\n' "$wid" "$mark" "$cwd" > "$handle"
  sleep 2   # the launcher's rc is not liveness
  cmd_prove_alive "$handle" || { dk_err "spawn: kitty returned a window id but it is already gone"; return 1; }
  # F3 read-back: the child's REAL cwd, not the one we asked for.
  local real
  real="$(dk_at ls --match "env:AHMARK=$mark" 2>/dev/null | LC_ALL=C sed -n 's/.*"cwd": *"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$real" ] && [ "$real" != "$cwd" ]; then
    dk_err "spawn: kitty started the successor in $real, not $cwd"; return 1
  fi
  return 0
}

cmd_prove_alive() {
  local h="${1:-}" m mark
  m="$(dk_h "$h" mode)" || m=""
  if [ "$m" != direct ]; then dk_tmux prove-alive "$h"; return $?; fi
  mark="$(dk_h "$h" kitty_mark)"; [ -n "$mark" ] || return 2
  dk_at ls >/dev/null 2>&1 || return 2            # cannot ask is not a negative
  dk_at ls --match "env:AHMARK=$mark" >/dev/null 2>&1 && return 0
  return 1
}

cmd_send_text() {
  local h="${1:-}" text="${2:-}" m mark before after
  m="$(dk_h "$h" mode)" || m=""
  if [ "$m" != direct ]; then dk_tmux send-text "$h" "$text"; return $?; fi
  mark="$(dk_h "$h" kitty_mark)"; [ -n "$mark" ] || return 1
  case "${#text}" in *) [ "${#text}" -lt 1000 ] || { dk_err "send-text: refusing ${#text} bytes"; return 1; } ;; esac
  # F1: pre-flight with a verb that CAN say no, because send-text cannot.
  dk_at ls --match "env:AHMARK=$mark" >/dev/null 2>&1 || { dk_err "send-text: no window matching env:AHMARK=$mark"; return 1; }
  before="$(dk_at get-text --match "env:AHMARK=$mark" 2>/dev/null)" || before=""
  dk_at send-text --match "env:AHMARK=$mark" -- "$text
" >/dev/null 2>&1
  sleep 1
  after="$(dk_at get-text --match "env:AHMARK=$mark" 2>/dev/null)" || after=""
  if [ -n "$after" ] && [ "$after" != "$before" ]; then return 0; fi
  return 3      # issued; the screen did not visibly change, so delivery is NOT proven
}

cmd_capture() {
  local h="${1:-}" m mark
  m="$(dk_h "$h" mode)" || m=""
  if [ "$m" != direct ]; then dk_tmux capture "$h"; return $?; fi
  mark="$(dk_h "$h" kitty_mark)"; [ -n "$mark" ] || return 2
  dk_at get-text --match "env:AHMARK=$mark" 2>/dev/null || return 2
}

cmd_attach() {
  local h="${1:-}" m
  m="$(dk_h "$h" mode)" || m=""
  [ "$m" = direct ] && { dk_say "(direct mode: the window IS the successor)"; return 0; }
  dk_tmux attach "$h"
}

cmd_close_self() {
  local sd="${1:-}"
  [ -n "$DK_KITTY" ] || return 1
  [ -n "${KITTY_WINDOW_ID:-}${KITTY_LISTEN_ON:-}" ] || { dk_err "close-self: not inside kitty"; return 1; }
  [ -n "$sd" ] && printf 'driver=kitty\nkitty_window=%s\n' "${KITTY_WINDOW_ID:-}" > "$sd/pred-pane" 2>/dev/null
  # F2: --self, ALWAYS. A bare close-window closes the ACTIVE window, rc 0, silently.
  dk_at close-window --self >/dev/null 2>&1
  sleep 1
  return 3
}

cmd_prove_pred_gone() {
  local sd="${1:-}" w
  [ -f "$sd/pred-pane" ] || return 2
  w="$(dk_h "$sd/pred-pane" kitty_window)"; [ -n "$w" ] || return 2
  dk_at ls >/dev/null 2>&1 || return 2
  dk_at ls --match "id:$w" >/dev/null 2>&1 && return 1
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
                   if [ "$(dk_h "${1:-}" mode)" = direct ]; then
                     printf '%s @ --to %s ls --match env:AHMARK=%s\n' "$DK_KITTY" "${KITTY_LISTEN_ON:-}" "$(dk_h "${1:-}" kitty_mark)"
                   else dk_tmux alive-cmd "${1:-}"; fi ;;
  *) dk_err "usage: driver-kitty.sh capabilities|preflight|spawn|prove-alive|send-text|capture|attach|close-self|prove-pred-gone|alive-cmd"; exit 2 ;;
esac
