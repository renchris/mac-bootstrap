#!/bin/bash
# driver-tmux.sh — the tmux succession driver, and the SUBSTRATE the other two sit on.
#
# THE SEAM (every driver implements exactly these, or declares it cannot):
#   capabilities                      key=value lines; the engine refuses a driver that lies
#   preflight                         rc 0 usable here · 2 not, with the reason on stdout
#   spawn <handle> <cwd> <title> ARGV…   launch ARGV as a real argv vector; no keystrokes
#   prove-alive <handle>              rc 0 alive · 1 definitely gone · 2 cannot tell
#   send-text <handle> <text>         rc 0 DELIVERY VERIFIED · 3 issued, unverifiable · 1 failed
#   capture <handle>                  print the successor's visible screen (rc 2 = unsupported)
#   attach <handle>                   open a viewport on the successor (substrate drivers)
#   close-self <statedir>             retire the CALLER's OWN pane; records its identity first
#   prove-pred-gone <statedir>        rc 0 gone · 1 still there · 2 cannot tell
#
# ═══ WHY TMUX IS THE SUBSTRATE AND NOT MERELY ONE OPTION ═════════════════════════════════════
# Measured, same harness, one variable — which thing dies:
#   tmux  : the server is ppid 1. `kill -TERM` the ENTIRE predecessor terminal and the successor
#           SURVIVES (pid unchanged, heartbeat still advancing), and re-attaches from any window.
#   kitty : the successor is a child of the kitty PROCESS. The window may close, but `kill -TERM`
#           on kitty takes the successor with it, heartbeat frozen.
#   iTerm2: same shape — the successor is a child of iTermServer.
# So the terminal is a VIEWPORT, never the substrate. A succession whose successor dies with the
# terminal app is automatic but not fault-tolerant, and fault tolerance is the whole requirement.
#
# tmux is also the only one of the three whose KEYSTROKE verb can say NO: `send-keys` to a
# missing pane is rc 1 with a message, where `kitty @ send-text` to a target that does not exist
# is rc 0 and a silent no-op.
#
# ═══ SAFETY: WE NEVER TOUCH A SERVER WE DO NOT OWN ═══════════════════════════════════════════
# Every session lives on a DEDICATED socket (`-L "$AH_TMUX_SOCKET"`, default "agenthandoff").
# The operator's default socket is never addressed, never listed, never signalled. `close-self`
# only ever names the caller's own $TMUX_PANE.
set -u

DT_SOCK="${AH_TMUX_SOCKET:-agenthandoff}"
DT_TMUX="${AH_TMUX_BIN:-}"
[ -n "$DT_TMUX" ] || DT_TMUX="$(command -v tmux 2>/dev/null)" || DT_TMUX=""

dt_say() { printf '%s\n' "$*"; }
dt_err() { printf '%s\n' "$*" >&2; }
dt()     { [ -n "$DT_TMUX" ] || return 127; "$DT_TMUX" -L "$DT_SOCK" "$@"; }

# handle files are flat key=value; nothing here parses JSON.
dt_h()   { [ -f "${1:-}" ] || return 1; LC_ALL=C awk -F= -v k="${2:-}" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$1"; }

cmd_capabilities() {
  dt_say "driver=tmux"
  dt_say "spawn=yes"
  dt_say "send-text=yes"          # and it is the only one of the three with a real NEGATIVE arm
  dt_say "prove-alive=yes"
  dt_say "capture=yes"
  dt_say "close-self=$([ -n "${TMUX_PANE:-}" ] && printf yes || printf no)"
  dt_say "survives-app-death=yes"
  dt_say "argv=exact"
}

cmd_preflight() {
  [ -n "$DT_TMUX" ] || { dt_say "tmux is not installed (install it, or set AH_DRIVER=iterm2 with AH_SUBSTRATE=direct)"; return 2; }
  [ -x "$DT_TMUX" ] || { dt_say "$DT_TMUX is not executable"; return 2; }
  # PROBE THE MECHANISM, do not merely test for the binary. A server that cannot start (a stale
  # socket owned by another uid, a full /tmp) fails here rather than half-way through a launch.
  local probe; probe="ahpf-$$-$(date +%s 2>/dev/null)"
  dt new-session -d -s "$probe" -x 80 -y 24 /bin/sh -c 'sleep 5' >/dev/null 2>&1 || {
    dt_say "tmux cannot start a session on socket '$DT_SOCK'"; return 2; }
  if ! dt has-session -t "$probe" >/dev/null 2>&1; then
    dt kill-session -t "$probe" >/dev/null 2>&1
    dt_say "tmux started a session that immediately vanished on socket '$DT_SOCK'"; return 2
  fi
  # the NEGATIVE arm of the liveness oracle, proven at preflight rather than assumed
  if dt has-session -t "ahpf-no-such-$$" >/dev/null 2>&1; then
    dt kill-session -t "$probe" >/dev/null 2>&1
    dt_say "tmux has-session answered YES for a session nothing holds — the liveness oracle cannot say NO"
    return 2
  fi
  dt kill-session -t "$probe" >/dev/null 2>&1
  return 0
}

# ── spawn — the brief travels as ARGV, never as keystrokes. ──────────────────────────────────
# MEASURED, 3,086-byte hostile payload (quotes, backticks, $VARS, 68 newlines, ZWJ emoji):
#   argv vector through tmux -> 3086/3086 byte-identical, and byte-identical again inside Claude
#   Code's own transcript. The same payload typed as one line into a COOKED tty arrives as
#   0 BYTES with the sender reporting rc 0 — the line discipline's MAX_CANON is 1024 and it does
#   not truncate, it DELETES. That is why nothing here types a payload.
# -c is MANDATORY: without it tmux inherits the CALLER's cwd, which silently breaks a trust seed
# keyed on the absolute cwd. -x/-y are mandatory too: a detached pane is 80x24 until somebody
# attaches, and a TUI successor renders at that size.
cmd_spawn() {
  local handle="${1:-}" cwd="${2:-}" title="${3:-}"
  shift 3 2>/dev/null || { dt_err "spawn: need <handle> <cwd> <title> ARGV..."; return 2; }
  [ $# -gt 0 ] || { dt_err "spawn: no argv"; return 2; }
  [ -d "$cwd" ] || { dt_err "spawn: cwd does not exist: $cwd"; return 2; }
  local name="ah-$title"
  dt new-session -d -s "$name" -c "$cwd" \
     -x "${AH_COLS:-200}" -y "${AH_ROWS:-50}" "$@" >/dev/null 2>&1 || {
       dt_err "spawn: tmux new-session failed"; return 1; }
  { printf 'driver=tmux\n'; printf 'socket=%s\n' "$DT_SOCK"; printf 'session=%s\n' "$name"
    printf 'cwd=%s\n' "$cwd"; } > "$handle" || return 1
  # THE LAUNCHER'S rc IS NOT LIVENESS. `tmux new-session -d` returns 0 for a child that has
  # ALREADY DIED — measured with a nonexistent binary, and again with an argv vector mangled by
  # the driver's own serialisation. has-session a moment later is the real signal.
  sleep 2
  dt has-session -t "$name" >/dev/null 2>&1 || {
    dt_err "spawn: tmux returned 0 but session '$name' is already gone — the command did not start"
    return 1; }
  return 0
}

cmd_prove_alive() {
  local h="${1:-}" s
  s="$(dt_h "$h" session)" || return 2
  [ -n "$s" ] || return 2
  dt has-session -t "$s" >/dev/null 2>&1 && return 0
  # distinguish "no such session" from "no server / cannot ask"
  dt list-sessions >/dev/null 2>&1 && return 1
  return 2
}

# ── send-text — the only keystroke verb in this repo with a demonstrated negative arm. ────────
# Used ONLY for a short control line (arming a goal as message 2). NEVER for a payload.
cmd_send_text() {
  local h="${1:-}" text="${2:-}" s
  s="$(dt_h "$h" session)" || return 1
  [ -n "$s" ] || return 1
  dt has-session -t "$s" >/dev/null 2>&1 || { dt_err "send-text: no such session: $s"; return 1; }
  case "${#text}" in *) [ "${#text}" -lt 1000 ] || { dt_err "send-text: refusing ${#text} bytes — a cooked tty DELETES a line at 1024 and reports success"; return 1; } ;; esac
  dt send-keys -t "$s" -l -- "$text" >/dev/null 2>&1 || return 1
  dt send-keys -t "$s" Enter >/dev/null 2>&1 || return 1
  return 0
}

cmd_capture() {
  local h="${1:-}" s
  s="$(dt_h "$h" session)" || return 2
  [ -n "$s" ] || return 2
  dt capture-pane -p -t "$s" 2>/dev/null || return 2
}

cmd_attach() {
  local h="${1:-}" s
  s="$(dt_h "$h" session)" || return 2
  [ -n "$s" ] || return 2
  dt_say "$DT_TMUX -L $DT_SOCK attach -t $s"
}

# ── close-self — the CALLER's own pane, addressed by $TMUX_PANE and nothing else. ─────────────
# We record the identity BEFORE issuing the kill, because the kill destroys this process: a
# driver that writes its terminal record afterwards leaves the state machine stranded (measured:
# the phase stopped at ENGAGED and RETIRED/DONE never landed). `resume` heals that, and
# prove-pred-gone is how it checks.
cmd_close_self() {
  local sd="${1:-}"
  [ -n "${TMUX_PANE:-}" ] || { dt_err "close-self: not inside a tmux pane (\$TMUX_PANE unset)"; return 1; }
  [ -n "$sd" ] && { printf 'driver=tmux\npane=%s\ntmux=%s\n' "$TMUX_PANE" "${TMUX:-}" > "$sd/pred-pane" 2>/dev/null; }
  # Address the caller's OWN pane. Never a session name, never a pattern, never an id we were
  # handed by someone else. The socket here is the caller's own ($TMUX), not our dedicated one.
  local sock="${TMUX%%,*}"
  [ -n "$sock" ] || return 1
  "$DT_TMUX" -S "$sock" kill-pane -t "$TMUX_PANE" >/dev/null 2>&1
  # If we are still here, the kill did not take. Returning 3 = issued, unverifiable from inside.
  sleep 1
  return 3
}

cmd_prove_pred_gone() {
  local sd="${1:-}" pane sock
  [ -f "$sd/pred-pane" ] || return 2
  pane="$(dt_h "$sd/pred-pane" pane)"; sock="$(dt_h "$sd/pred-pane" tmux)"; sock="${sock%%,*}"
  [ -n "$pane" ] && [ -n "$sock" ] || return 2
  "$DT_TMUX" -S "$sock" list-panes -a -F '#{pane_id}' 2>/dev/null | LC_ALL=C grep -qx -- "$pane" && return 1
  "$DT_TMUX" -S "$sock" list-panes -a -F '#{pane_id}' >/dev/null 2>&1 || return 2
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
                   # the shell string the oracle's --alive-cmd wants, resolved for this handle
                   s="$(dt_h "${1:-}" session)"; [ -n "$s" ] || exit 2
                   printf '%s -L %s has-session -t %s\n' "$DT_TMUX" "$DT_SOCK" "$s" ;;
  *) dt_err "usage: driver-tmux.sh capabilities|preflight|spawn|prove-alive|send-text|capture|attach|close-self|prove-pred-gone|alive-cmd"; exit 2 ;;
esac
