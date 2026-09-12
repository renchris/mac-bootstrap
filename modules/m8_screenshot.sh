#!/bin/bash
# m8_screenshot — Cmd+Shift+4 -> bottom-right thumbnail -> clipboard -> paste into the agent.
#
# WHAT THIS INSTALLS, and why it is a Hammerspoon config rather than two `defaults write` lines:
#
#   macOS cannot do file AND clipboard AND thumbnail at once. `com.apple.screencapture target`
#   is SINGLE-VALUED, so `target=clipboard` writes no file and — measured with a positive
#   control on the process that draws it, `screencaptureui` — draws NO thumbnail at all. And the
#   native thumbnail is a PENDING-COMMIT UI: turning it on DEFERS the disk write by seconds
#   (measured A/B on one box in one minute: file at 0.41 s with show-thumbnail OFF, 6.11 s ON).
#   The shipped configuration — target=file, show-thumbnail=false, Hammerspoon polling the
#   directory — is the only one that yields all three, at ~0.42 s end to end.
#
#   THE Cmd+V -> Ctrl+V REWRITE IS REQUIRED IN EVERY DESIGN. It is not a flourish. Claude Code
#   binds `chat:imagePaste` to `ctrl+v` and never to `cmd+v` (present in 2.1.114, 2.1.183 and
#   2.1.260, each read with a positive and a negative control), and it reads the pasteboard OUT
#   OF BAND — `osascript -e 'the clipboard as «class PNGf»'` — so the terminal never carries the
#   image and only the 0x16 byte matters. Meanwhile an image-only clipboard has ZERO text
#   flavour (`pbpaste | wc -c` -> 0, against a 16-byte text control), and every stock terminal
#   consumes Cmd+V above the pty as its own Paste. So Cmd+V on a screenshot is a SILENT NO-OP in
#   kitty and iTerm2 alike: nothing happens and nothing says why. The eventtap in init.lua is
#   what makes the deliverable work; Accessibility is the permission it needs.
#
# WHAT THIS MODULE DELIBERATELY DOES NOT DO
#
#   * It does not install the community `copilot-cli-image-paste` monkey-patch. That is unread
#     remote code editing a vendored node_modules file inside ~/.copilot, it must be re-run after
#     every CLI update, its repo was last pushed 2026-05-04 with 0 stars and is tested only
#     against 1.0.37-1.0.40-2, and — decisively — it targets a condition the VENDOR says was
#     fixed: copilot-cli issue #3104 was closed `completed` citing release v1.0.30 (published
#     2026-04-16, eighteen days BEFORE the issue was opened), "Both Ctrl+V and Meta+V trigger
#     image paste on all platforms". Current is v1.0.83. One eventtap plausibly serves both
#     agents. The 30-second experiment is on the target Mac: record `copilot --version`, take a
#     Cmd+Shift+4, press Ctrl+V. Patch only if that fails, after reading patch.sh.
#   * It does not claim Screen Recording is unnecessary. The source research asserted Hammerspoon
#     was ABSENT from kTCCServiceScreenCapture; that was REFUTED — it is in the table, allowed,
#     sorted below a truncated listing. Nothing in this path calls a screen-capture API (macOS
#     captures; Hammerspoon reads a file and writes the pasteboard), so it is BELIEVED
#     unnecessary — and it has NEVER been tested without it, because the box it was measured on
#     holds the grant. A fresh Mac starts with no grant, so the target machine is the experiment.
#   * It does not assert the Cmd+V rewrite. No shell command can: it needs a real keypress in a
#     real TUI. install_ prints the one human observation instead of printing a green it did not
#     earn, and leaves it at $PB_STATE_DIR/m8-human-check.txt.
#
# HOUSE RULES THIS FILE OBEYS: bash 3.2 (no associative arrays, no ${x^^}, no mapfile) · set -u,
# never set -e · no absolute path containing a username, $HOME only · verify by INDEPENDENT
# read-back · human gates detected and RECORDED, never attempted · idempotent.
#
# TEST SEAMS (module-scoped; documented here because the environment contract in CONTRACT.md §5
# does not carry them). Both default to the real thing and neither is needed in production:
#   PB_M8_DOMAIN    the `defaults` domain to read and write. MEASURED, and the reason this seam
#                   exists: `defaults` IGNORES $HOME — a write under HOME=$(mktemp -d) landed in
#                   the REAL user's ~/Library/Preferences. A sandbox-HOME test without this seam
#                   would silently repoint the operator's live screenshot directory at a temp
#                   directory that is then deleted.
#   PB_M8_REPO_DIR  where the public config checkout lives. Default $HOME/Development/hammerspoon-config.
#   PB_M8_ACC_WAIT  seconds install_ waits for the Accessibility grant before handing back. 5.

M8_APP="/Applications/Hammerspoon.app"
# The Hammerspoon config is VENDORED at assets/hammerspoon/init.lua. It used to be cloned from a
# personal GitHub repo, which made deliverable 5 fail for anyone who is not its owner and put an
# account-shaped dependency in a bootstrap whose whole premise is an ANONYMOUS reader. The clone
# path survives only when the operator explicitly points at a checkout they want to track.
M8_REPO_URL="${PB_M8_REPO_URL:-}"
M8_DEFAULTS="/usr/bin/defaults"
M8_SCREENCAPTURE="/usr/sbin/screencapture"

# ── paths, computed rather than stored, because no state survives between verbs ───────────────
m8_shot_dir() { printf '%s' "$HOME/Screenshots"; }
m8_hs_dir()   { printf '%s' "$HOME/.hammerspoon"; }
m8_repo_dir() { printf '%s' "${PB_M8_REPO_DIR:-${PB_STATE_DIR:-$HOME/.mac-bootstrap}/hammerspoon}"; }
# ── m8_cfg_source — where init.lua comes from. Local assets dir, then the cached copy, then the
# pinned raw URL. Identical in shape to m1_source, deliberately: one idiom for every asset.
m8_cfg_source() {
  local c t code
  for c in "${PB_ASSETS:-}/hammerspoon/init.lua" \
           "${PB_STATE_DIR:-$HOME/.mac-bootstrap}/assets/hammerspoon/init.lua"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  t="${PB_STATE_DIR:-$HOME/.mac-bootstrap}/assets/hammerspoon/init.lua"
  mkdir -p "$(dirname "$t")" 2>/dev/null || return 1
  [ -n "${PB_RAW:-}" ] || return 1
  code="$(curl -sS -L -o "$t.part" -w '%{http_code}' "${PB_RAW}/assets/hammerspoon/init.lua" 2>/dev/null)" || {
    rm -f "$t.part" 2>/dev/null; return 1; }
  [ "$code" = 200 ] || { rm -f "$t.part" 2>/dev/null; return 1; }
  mv -f "$t.part" "$t" 2>/dev/null || return 1
  printf '%s' "$t"
}

m8_domain()   { printf '%s' "${PB_M8_DOMAIN:-com.apple.screencapture}"; }
m8_state()    { printf '%s' "${PB_STATE_DIR:-$HOME/.mac-bootstrap}"; }
m8_mark()     { printf '%s/m8-blocked' "$(m8_state)"; }
m8_pre()      { printf '%s/m8-defaults-pre' "$(m8_state)"; }
m8_human()    { printf '%s/m8-human-check.txt' "$(m8_state)"; }

# ── m8_run_bounded <seconds> <cmd...> — a wall clock over one command. ────────────────────────
# There is no `timeout` on a stock Mac (coreutils is not on the default PATH), and a verifier
# that HANGS is worse than one that fails: it wedges the whole bootstrap with no output. The
# completion test is a SENTINEL FILE, not `kill -0`, because `kill -0` on an unreaped child
# answers "alive" for a zombie and the loop would never break. stdin is /dev/null throughout:
# `hs` PROMPTS for confirmation before launching Hammerspoon when it is not running, and a
# prompt reading a terminal is exactly how this hangs. rc 124 means the bound fired.
m8_run_bounded() {
  local secs="${1:-5}" out rcf pid i lim
  shift || return 70
  out="$(mktemp -t m8run 2>/dev/null)" || return 70
  rcf="$out.rc"
  ( "$@" >"$out" 2>/dev/null </dev/null; printf '%s' "$?" >"$rcf" ) &
  pid=$!
  lim=$((secs * 10)); i=0
  while [ "$i" -lt "$lim" ]; do
    [ -f "$rcf" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -f "$rcf" ]; then
    kill -TERM "$pid" 2>/dev/null
    sleep 0.2
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$out" "$rcf" 2>/dev/null
    return 124
  fi
  wait "$pid" 2>/dev/null
  cat "$out" 2>/dev/null
  i="$(cat "$rcf" 2>/dev/null)" || i=1
  rm -f "$out" "$rcf" 2>/dev/null
  case "${i:-1}" in ''|*[!0-9]*) i=1 ;; esac
  return "$i"
}

# ── tool resolution ──────────────────────────────────────────────────────────────────────────
m8_brew() {
  local c
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c="$(command -v brew 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

# MEASURED, and it is why this is not `command -v git`: /usr/bin/git, /usr/bin/python3,
# /usr/bin/clang and /usr/bin/swift are ONE INODE — the Command Line Tools shim, 78 hard links.
# RUNNING it on a Mac with no CLT raises the GUI "install command line developer tools" dialog,
# which is a human gesture this module must DETECT and never ATTEMPT. `xcode-select -p` answers
# the same question and raises nothing.
m8_git() {
  local g
  g="$(command -v git 2>/dev/null)" || g=""
  case "$g" in
    ''|/usr/bin/git) : ;;
    *) printf '%s' "$g"; return 0 ;;
  esac
  if [ -x /usr/bin/git ] && /usr/bin/xcode-select -p >/dev/null 2>&1; then
    printf '/usr/bin/git'; return 0
  fi
  return 1
}

# The in-BUNDLE hs binary first. It exists whenever the app does, on Intel and Apple Silicon
# alike — where `/opt/homebrew/bin/hs` is a hardcode that is simply wrong on an Intel Mac, and
# hs.ipc.cliInstall()'s own default target is /usr/local, which its documentation says may need
# sudo to pre-create.
m8_hs_bin() {
  local c
  for c in "$M8_APP/Contents/Frameworks/hs/hs" /opt/homebrew/bin/hs /usr/local/bin/hs; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c="$(command -v hs 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

# ── live reads into the RUNNING Hammerspoon ──────────────────────────────────────────────────
# 🚨 `hs -c` EXITS 0 FOR A BOGUS EXPRESSION (measured: `-c 'return "NO-SUCH-"..tostring(nosuchglobal)'`
# prints `NO-SUCH-nil` and exits 0). The rc is therefore never the verdict here — the STRING is.
m8_running() { pgrep -x Hammerspoon >/dev/null 2>&1; }

m8_hs_eval() {
  local hs out
  m8_running || return 1
  hs="$(m8_hs_bin)" || return 1
  out="$(m8_run_bounded 8 "$hs" -q -t 2 -c "${1:-}")" || return 1
  printf '%s' "$out"
  return 0
}

m8_accessibility() { [ "$(m8_hs_eval 'return tostring(hs.accessibilityState())')" = "true" ]; }

# The independent read-back that matters most: ask the LIVE app whether the screenshot poller is
# armed. It proves (a) Hammerspoon is up, (b) it loaded a config that contains the screenshot
# feature, (c) the timer is actually running — through IPC into the app, which is a different
# code path from the symlink this module wrote. Negative control, verified: a global the config
# does NOT define answers `nil` on the same instrument.
m8_config_live() { [ "$(m8_hs_eval 'return tostring(screenshotPollTimer and screenshotPollTimer:running())')" = "true" ]; }

# And ask the live app what IT sees at ~/.hammerspoon/init.lua — in ITS home, which is the home
# the GUI app actually runs under. A shell `readlink` answers about this process's $HOME, and
# those are not always the same directory.
m8_live_symlink_ok() {
  local want got
  want="$(m8_repo_dir)/init.lua"
  got="$(m8_hs_eval 'return tostring(hs.fs.symlinkAttributes(os.getenv("HOME").."/.hammerspoon/init.lua","target"))')" || return 1
  [ "$got" = "$want" ] && return 0
  pb_warn "m8: the running Hammerspoon reads [$got] as its init.lua; this run expects [$want]."
  return 1
}

# ── cheap structural reads ───────────────────────────────────────────────────────────────────
m8_app_ok()     { [ -d "$M8_APP" ] && [ -f "$M8_APP/Contents/Info.plist" ]; }
m8_repo_ok()    { [ -f "$(m8_repo_dir)/init.lua" ]; }
m8_shotdir_ok() { [ -d "$(m8_shot_dir)" ]; }
m8_quarantined(){ xattr -p com.apple.quarantine "$M8_APP" >/dev/null 2>&1; }

m8_symlink_ok() {
  local l t
  l="$(m8_hs_dir)/init.lua"
  [ -L "$l" ] || return 1
  t="$(readlink "$l" 2>/dev/null)" || return 1
  [ "$t" = "$(m8_repo_dir)/init.lua" ] && [ -f "$t" ]
}

m8_def_read() {
  local out
  out="$("$M8_DEFAULTS" read "$(m8_domain)" "${1:-}" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# Each key is read back INDIVIDUALLY, and each failure names the consequence rather than the key,
# because every one of these settings is load-bearing and silent when wrong.
m8_defaults_ok() {
  local want loc st tg
  want="$(m8_shot_dir)"
  loc="$(m8_def_read location)" || { pb_warn "m8: $(m8_domain) 'location' is unset — captures would go to the Desktop, which init.lua does not poll."; return 1; }
  # shellcheck disable=SC2088  # the literal tilde is DELIBERATE: macOS writes an UNEXPANDED
  # tilde into this domain itself (the live box holds `"location-last" = "~/Documents/"`), so a
  # user or an OS-written `~/Screenshots` must compare equal. We always WRITE the absolute form.
  case "$loc" in
    "$want"|"$want"/|'~/Screenshots'|'~/Screenshots/') : ;;
    *) pb_warn "m8: screencapture writes to [$loc] but init.lua polls [$want] — the pipeline would be dark."; return 1 ;;
  esac
  st="$(m8_def_read show-thumbnail)" || st=""
  [ "$st" = "0" ] || { pb_warn "m8: show-thumbnail is [$st], not 0. The native thumbnail is a pending-commit UI and DEFERS the disk write (measured 6.11 s ON vs 0.41 s OFF)."; return 1; }
  tg="$(m8_def_read target)" || tg=""
  [ "$tg" = "file" ] || { pb_warn "m8: target is [$tg], not file. target is single-valued: target=clipboard writes NO file and draws NO thumbnail."; return 1; }
  if m8_def_read name >/dev/null 2>&1; then
    pb_warn "m8: $(m8_domain) 'name' is set. init.lua anchors on ^Screenshot, so a renamed capture is never seen and the pipeline goes dark with no error."
    return 1
  fi
  return 0
}

m8_struct_ok() { m8_app_ok && m8_repo_ok && m8_symlink_ok && m8_shotdir_ok && m8_defaults_ok; }

# ── the live end-to-end probe ────────────────────────────────────────────────────────────────
# rc 0 the clipboard received a PNG · 2 screencapture itself could not produce a capture
# (a different culprit, and a different gesture) · 1 everything else.
m8_clipboard_has_png() { osascript -e 'the clipboard as «class PNGf»' >/dev/null 2>&1; }

m8_live_probe() {
  local dir shot rc i
  dir="$(m8_shot_dir)"
  [ -d "$dir" ] || { pb_warn "m8: $dir does not exist."; return 1; }

  # NEGATIVE CONTROL FIRST. Prime the clipboard with text and require the PNG read to FAIL. If a
  # PNG is already sitting there, the poll below would pass without Hammerspoon doing anything,
  # and a positive result would carry no information at all.
  printf '%s' 'mac-bootstrap m8 sentinel — NOT an image' | pbcopy 2>/dev/null || {
    pb_warn "m8: pbcopy failed; cannot establish the negative control."; return 1; }
  if m8_clipboard_has_png; then
    pb_warn "m8: the clipboard still reads as a PNG immediately after text was copied — the instrument cannot say no, so nothing it says yes to would mean anything."
    return 1
  fi

  # A distinct, sweepable name that still matches init.lua's ^Screenshot anchor.
  shot="$dir/Screenshot $(date '+%Y-%m-%d at %H.%M.%S') mac-bootstrap-probe-$$.png"
  # screencapture's OWN rc, read directly. Never through a pipe: $? after a pipe is the LAST
  # stage's status, which is how a capture failure reads as success.
  "$M8_SCREENCAPTURE" -x -R 0,0,200,200 "$shot" >/dev/null 2>&1
  rc=$?
  if [ "$rc" != 0 ]; then
    pb_warn "m8: screencapture exited $rc and wrote nothing. On macOS 15 the app that RUNS screencapture needs Screen Recording; grant it to your terminal, or run this from a terminal that has it."
    rm -f "$shot" 2>/dev/null
    return 2
  fi
  if [ ! -s "$shot" ]; then
    pb_warn "m8: screencapture exited 0 but produced an empty file — treat this as a capture-side failure, not a pipeline failure."
    rm -f "$shot" 2>/dev/null
    return 2
  fi

  # Now the read-back, through a DIFFERENT API than the one that wrote: Hammerspoon writes the
  # pasteboard through NSPasteboard; this is the AppleScript coercion Claude Code itself runs.
  i=0
  while [ "$i" -lt 60 ]; do
    if m8_clipboard_has_png; then
      rm -f "$shot" 2>/dev/null           # our probe file, and only ours
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  pb_warn "m8: 15 s after a capture landed in $dir the clipboard still holds no PNG — Hammerspoon's poll or its clipboard write is not running. Check: tail \$HOME/Library/Logs/Hammerspoon/screenshot.log"
  rm -f "$shot" 2>/dev/null
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# THE SIX VERBS
# ═════════════════════════════════════════════════════════════════════════════════════════════

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_m8_screenshot()    { printf '%s' 'Cmd+Shift+4 to a bottom-right thumbnail to the clipboard to a paste into your agent'; }
cost_m8_screenshot()    { printf '%s' 'Homebrew + Hammerspoon, and one Accessibility toggle that no script can grant for you.'; }
profile_m8_screenshot() { printf '%s' 'full'; }

verify_m8_screenshot() {
  # The defaults domain is resolved from the password database, not from $HOME, so a sandboxed
  # HOME would silently rewrite the REAL machine. Refuse instead. (pb-lib: pb_defaults_home_ok)
  pb_defaults_home_ok || return 1
  m8_app_ok         || { pb_warn "m8: $M8_APP is not installed."; return 1; }
  m8_repo_ok        || { pb_warn "m8: no config checkout at $(m8_repo_dir)."; return 1; }
  m8_symlink_ok     || { pb_warn "m8: $(m8_hs_dir)/init.lua is not a symlink to $(m8_repo_dir)/init.lua."; return 1; }
  m8_shotdir_ok     || { pb_warn "m8: $(m8_shot_dir) does not exist."; return 1; }
  m8_defaults_ok    || return 1
  m8_running        || { pb_warn "m8: Hammerspoon is not running."; return 1; }
  m8_config_live    || { pb_warn "m8: the running Hammerspoon has no armed screenshotPollTimer — the loaded config does not carry the screenshot feature, or it errored while loading."; return 1; }
  m8_live_symlink_ok || return 1
  m8_accessibility  || { pb_warn "m8: Hammerspoon does not hold Accessibility; the Cmd+V -> Ctrl+V rewrite cannot run."; return 1; }
  m8_live_probe     || return 1
  return 0
}

# gate_ answers ONE question: is a human gesture the next thing needed? It must NOT answer yes
# while drivable work remains, because the driver reports NEEDS_HUMAN *instead of* installing.
m8_gate_reason() {
  local mark
  if ! m8_app_ok && ! m8_brew >/dev/null 2>&1; then printf 'homebrew'; return 0; fi
  if ! m8_repo_ok && ! m8_git >/dev/null 2>&1; then printf 'clt'; return 0; fi
  mark="$(cat "$(m8_mark)" 2>/dev/null)" || mark=""
  case "$mark" in
    gatekeeper)      if m8_app_ok && ! m8_running; then printf 'gatekeeper'; return 0; fi ;;
    screenrecording) if m8_running; then printf 'screenrecording'; return 0; fi ;;
  esac
  if m8_struct_ok && m8_running && ! m8_accessibility; then printf 'accessibility'; return 0; fi
  return 0
}

gate_m8_screenshot() {
  # A sandboxed HOME is a DECISION, not a bug: `defaults` would escape it and hit the real
  # domain, so pb_defaults_home_ok refuses. Reported through gate_ so it reads NEEDS_HUMAN
  # rather than FAILED — FAILED sends the reader to the log for a defect that is not there.
  pb_defaults_home_ok >/dev/null 2>&1 || return 0
  local r
  r="$(m8_gate_reason)"
  [ -n "$r" ]
}

note_m8_screenshot() {
  if ! pb_defaults_home_ok >/dev/null 2>&1; then
    printf 'this run has a sandboxed HOME ($HOME is not your real home), and `defaults` ignores $HOME — writing would hit your REAL preferences. Nothing was written.'
    return 0
  fi
  case "$(m8_gate_reason)" in
    homebrew)        printf 'Homebrew is not installed, so Hammerspoon cannot be installed; the Homebrew installer needs your password (sudo).' ;;
    clt)             printf 'The Xcode Command Line Tools are absent, so git cannot clone the config; the installer is a GUI dialog you must approve.' ;;
    gatekeeper)      printf 'Hammerspoon is installed but will not launch — macOS quarantines a first-run downloaded app until you approve it once.' ;;
    screenrecording) printf 'screencapture could not produce a capture from this terminal; on macOS 15 the app that runs it needs Screen Recording.' ;;
    accessibility)   printf 'Hammerspoon needs Accessibility, and on an unmanaged Mac that toggle cannot be set by any script: tccutil only resets, TCC writes are SIP-protected, and a PPPC profile needs an MDM-enrolled and supervised device.' ;;
    *)               printf 'Hammerspoon, the config checkout, the symlink, the screenshot directory and the screencapture defaults are not all in place yet.' ;;
  esac
}

gesture_m8_screenshot() {
  if ! pb_defaults_home_ok >/dev/null 2>&1; then
    printf 'run it from your own account (no HOME override), or set PB_ALLOW_FOREIGN_DEFAULTS=1 if you truly mean to write the real domain'
    return 0
  fi
  case "$(m8_gate_reason)" in
    homebrew)        printf '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' ;;
    clt)             printf 'xcode-select --install' ;;
    gatekeeper)      printf 'open "x-apple.systempreferences:com.apple.preference.security?Security"' ;;
    screenrecording) printf 'open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"' ;;
    accessibility)   printf 'open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"' ;;
    *)               : ;;
  esac
}

# ── install ──────────────────────────────────────────────────────────────────────────────────
m8_defaults_pre_record() {                      # once per machine, before the first write
  local p k v
  p="$(m8_pre)"
  [ -f "$p" ] && return 0
  : > "$p" 2>/dev/null || return 0
  for k in location show-thumbnail target name; do
    if v="$(m8_def_read "$k")"; then
      printf '%s\t%s\n' "$k" "$v" >> "$p" 2>/dev/null
    else
      printf '%s\tABSENT\n' "$k" >> "$p" 2>/dev/null
    fi
  done
  return 0
}

# m8_def_write <key> <type-flag> <write-value> [expected-read-value]
#
# 🚨 MEASURED, and found by RUNNING this module rather than by reading it: `defaults` WRITES and
# READS a boolean in two different alphabets.
#     $ defaults write <dom> show-thumbnail -bool 0     ->  prints the whole usage block, rc=255
#     $ defaults write <dom> show-thumbnail -bool false ->  rc=0
#     $ defaults read  <dom> show-thumbnail             ->  0          (read-type: boolean)
# `-bool` accepts ONLY true|false|yes|no, and the value it hands back is 0|1. So a writer that
# compares "what I am about to write" with "what is there" in ONE spelling is wrong in one of
# two ways: it passes an unacceptable argument, or it never sees its own write as idempotent and
# rewrites the file forever. The two spellings are therefore separate parameters.
m8_def_write() {
  local k="${1:-}" tf="${2:-}" v="${3:-}" want="${4:-}" cur
  [ -n "$want" ] || want="$v"
  cur="$(m8_def_read "$k")" || cur=""
  [ "$cur" = "$want" ] && return 0               # already exactly this — do not open the file
  "$M8_DEFAULTS" write "$(m8_domain)" "$k" "$tf" "$v" >/dev/null 2>&1 || return 1
  # read back through the same reader the verifier uses, in the READ alphabet
  cur="$(m8_def_read "$k")" || cur=""
  [ "$cur" = "$want" ]
}

install_m8_screenshot() {
  # The defaults domain is resolved from the password database, not from $HOME, so a sandboxed
  # HOME would silently rewrite the REAL machine. Refuse instead. (pb-lib: pb_defaults_home_ok)
  pb_defaults_home_ok || return 1
  local brew git dir hs out i rc want src unfinished=0

  rm -f "$(m8_mark)" 2>/dev/null

  # 1. Hammerspoon
  if m8_app_ok; then
    printf '   ok   Hammerspoon already at %s\n' "$M8_APP"
  else
    if brew="$(m8_brew)"; then
      printf '   ..   brew install --cask hammerspoon\n'
      # </dev/null so a cask that asks for a password FAILS rather than hanging the bootstrap.
      NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install --cask hammerspoon </dev/null 2>&1
      if m8_app_ok; then printf '   ok   installed\n'
      else printf '   x    brew finished but %s is not there\n' "$M8_APP"; return 1; fi
    else
      printf '   x    Homebrew is not installed — that step is yours.\n'
      return 1
    fi
  fi

  # 2. the config itself — VENDORED, not cloned. A git checkout is used only when the operator
  #    explicitly named one (PB_M8_REPO_DIR at a .git, or PB_M8_REPO_URL); otherwise the file
  #    comes from this repo's own assets and needs no git, no GitHub account and no network
  #    beyond the pinned raw URL the driver already used.
  dir="$(m8_repo_dir)"
  if [ -n "$M8_REPO_URL" ] && ! m8_repo_ok; then
    if git="$(m8_git)"; then
      mkdir -p "$(dirname "$dir")" 2>/dev/null
      printf '   ..   git clone %s (explicitly requested)\n' "$M8_REPO_URL"
      GIT_TERMINAL_PROMPT=0 "$git" clone --depth 1 "$M8_REPO_URL" "$dir" </dev/null 2>&1
    else
      printf '   x    PB_M8_REPO_URL is set but there is no usable git — that step is yours.\n'
      return 1
    fi
  fi
  if [ -d "$dir/.git" ] && git="$(m8_git)"; then
    printf '   ok   tracking the checkout at %s\n' "$dir"
    if [ -z "$("$git" -C "$dir" status --porcelain 2>/dev/null)" ]; then
      GIT_TERMINAL_PROMPT=0 "$git" -C "$dir" pull --ff-only </dev/null >/dev/null 2>&1 \
        && printf '   ok   fast-forwarded\n' || printf '   --   no fast-forward available; leaving it as it is\n'
    else
      printf '   --   checkout has local changes; not pulling\n'
    fi
  else
    src="$(m8_cfg_source)" || { printf '   x    cannot find or fetch assets/hammerspoon/init.lua\n'; return 1; }
    mkdir -p "$dir" 2>/dev/null
    if [ -f "$dir/init.lua" ] && cmp -s "$src" "$dir/init.lua"; then
      printf '   ok   config already current at %s\n' "$dir"
    else
      cp "$src" "$dir/init.lua.part" 2>/dev/null && mv -f "$dir/init.lua.part" "$dir/init.lua" 2>/dev/null \
        || { printf '   x    could not write %s/init.lua\n' "$dir"; return 1; }
      printf '   ok   config installed to %s (vendored, no GitHub account needed)\n' "$dir"
    fi
  fi
  m8_repo_ok || { printf '   x    no init.lua at %s\n' "$dir"; return 1; }

  # 3. the symlink — guarded, idempotent, non-destructive. Anything already there that is not
  #    ours is MOVED ASIDE, never overwritten: `ln -sfn` would silently discard it.
  mkdir -p "$(m8_hs_dir)" 2>/dev/null
  want="$dir/init.lua"
  if m8_symlink_ok; then
    printf '   ok   %s/init.lua -> %s\n' "$(m8_hs_dir)" "$want"
  else
    if [ -e "$(m8_hs_dir)/init.lua" ] || [ -L "$(m8_hs_dir)/init.lua" ]; then
      out="$(m8_hs_dir)/init.lua.pb-bak.$(date -u +%Y%m%dT%H%M%SZ)"
      mv "$(m8_hs_dir)/init.lua" "$out" 2>/dev/null \
        && printf '   ok   your existing init.lua was MOVED to %s — nothing was overwritten\n' "$out"
    fi
    ln -s "$want" "$(m8_hs_dir)/init.lua" 2>/dev/null
    if m8_symlink_ok; then printf '   ok   symlinked %s/init.lua -> %s\n' "$(m8_hs_dir)" "$want"
    else printf '   x    could not symlink %s/init.lua\n' "$(m8_hs_dir)"; return 1; fi
  fi

  # 4. the screenshot directory init.lua polls
  mkdir -p "$(m8_shot_dir)" 2>/dev/null
  # NOT `A && printf ok || { ...; return 1; }` — printf is a command that can fail (EPIPE), and
  # that shape then runs the failure branch over a TRUE condition. if/else says what it means.
  if m8_shotdir_ok; then
    printf '   ok   %s\n' "$(m8_shot_dir)"
  else
    printf '   x    could not create %s\n' "$(m8_shot_dir)"
    return 1
  fi

  # 5. the screencapture defaults, each written only if it differs and each READ BACK ALONE
  m8_defaults_pre_record
  m8_def_write location -string "$(m8_shot_dir)" || printf '   x    could not write location\n'
  m8_def_write show-thumbnail -bool false 0      || printf '   x    could not write show-thumbnail\n'
  m8_def_write target -string file               || printf '   x    could not write target\n'
  if m8_def_read name >/dev/null 2>&1; then
    # Recorded above, restored by uninstall_. It has to go: init.lua anchors on ^Screenshot and
    # a renamed capture is simply never seen — the whole pipeline goes dark with no error.
    "$M8_DEFAULTS" delete "$(m8_domain)" name >/dev/null 2>&1 \
      && printf '   ok   removed the screencapture "name" prefix (it breaks the ^Screenshot anchor); uninstall restores it\n'
  fi
  if m8_defaults_ok; then
    printf '   ok   defaults read back: location=%s show-thumbnail=0 target=file name unset\n' "$(m8_shot_dir)"
  else
    printf '   x    the screencapture defaults did not read back as written\n'
    return 1
  fi

  # 6. launch, or reload a Hammerspoon that is already up — otherwise a running instance keeps
  #    whatever config it started with and every check below fails for a reason nothing names.
  if m8_running; then
    hs="$(m8_hs_bin)" && m8_run_bounded 8 "$hs" -q -t 2 -c 'hs.reload()' >/dev/null 2>&1
    printf '   ok   Hammerspoon was running; asked it to reload\n'
  else
    open -a Hammerspoon 2>/dev/null
    i=0; while [ "$i" -lt 20 ]; do m8_running && break; sleep 1; i=$((i + 1)); done
    if m8_running; then printf '   ok   Hammerspoon launched\n'
    else
      if m8_quarantined; then
        printf 'gatekeeper' > "$(m8_mark)" 2>/dev/null
        printf '   x    Hammerspoon did not start and still carries the quarantine attribute — macOS wants you to approve its first launch\n'
      else
        printf '   x    Hammerspoon did not start\n'
      fi
      return 1
    fi
  fi

  # 7. the config is loaded AND armed — asked of the running app, not of the file we wrote
  i=0; while [ "$i" -lt 20 ]; do m8_config_live && break; sleep 1; i=$((i + 1)); done
  if m8_config_live; then
    printf '   ok   screenshotPollTimer is armed inside the running Hammerspoon\n'
  else
    printf '   x    the running Hammerspoon has no armed screenshotPollTimer. If your checkout predates the screenshot feature: git -C %s pull --ff-only\n' "$dir"
    return 1
  fi
  m8_live_symlink_ok || { printf '   x    the running Hammerspoon is reading a different init.lua than this run installed\n'; return 1; }

  # 8. Accessibility — polled briefly in case it is already granted, then HANDED BACK. It is not
  #    ours to take, and a bootstrap that blocks for six minutes on one toggle is worse than one
  #    that tells you the command and lets you re-run: re-running IS the recovery procedure.
  i=0
  while [ "$i" -lt "${PB_M8_ACC_WAIT:-5}" ]; do m8_accessibility && break; sleep 1; i=$((i + 1)); done
  if m8_accessibility; then
    printf '   ok   Hammerspoon holds Accessibility\n'
  else
    printf '   --   Hammerspoon does NOT hold Accessibility. That toggle is yours; nothing can set it for you.\n'
    unfinished=1
  fi

  # 9. the live end-to-end — and the one place a capture-side failure is discoverable, which is
  #    why install_ runs it rather than leaving it to verify_: a gate the installer discovers at
  #    run time is reported NEEDS_HUMAN, and only install_ can discover this one.
  if [ "$unfinished" = 0 ]; then
    m8_live_probe
    rc=$?
    case "$rc" in
      0) printf '   ok   capture -> clipboard proven live (osascript read the PNG back)\n' ;;
      2) printf 'screenrecording' > "$(m8_mark)" 2>/dev/null
         printf '   x    screencapture could not produce a capture from this process\n'
         unfinished=1 ;;
      *) printf '   x    a capture landed but the clipboard never received it\n'
         unfinished=1 ;;
    esac
  fi

  # 10. the one thing no shell can assert, stated plainly rather than greened.
  {
    printf 'mac-bootstrap m8 — the ONE check a shell cannot make\n\n'
    printf 'Take a screenshot with Cmd+Shift+4, then press Ctrl+V in your agent.\n'
    printf 'An image must attach. (Cmd+V works too, and ONLY because Hammerspoon rewrites it:\n'
    printf 'every terminal eats Cmd+V above the pty, and an image-only clipboard has no text to\n'
    printf 'paste, so without that rewrite Cmd+V is a silent no-op.)\n\n'
    printf 'If it does not attach, the log is: tail $HOME/Library/Logs/Hammerspoon/screenshot.log\n\n'
    printf 'SCREEN RECORDING: Hammerspoon is BELIEVED not to need it and that has NEVER been\n'
    printf 'tested without it — the box this was measured on already held the grant, and the\n'
    printf 'claim that Hammerspoon was absent from the Screen Recording table was refuted (it\n'
    printf 'is in it, allowed). Nothing in this path calls a screen-capture API: macOS captures,\n'
    printf 'Hammerspoon reads the file and writes the pasteboard. This Mac is the experiment. If\n'
    printf 'the pipeline works here with no Screen Recording grant, the question is settled.\n\n'
    printf 'GitHub Copilot CLI: no patch is installed and none should be. Its vendor closed the\n'
    printf 'image-paste issue citing release v1.0.30 -- "Both Ctrl+V and Meta+V trigger image\n'
    printf 'paste on all platforms". Test it: record `copilot --version`, take a screenshot,\n'
    printf 'press Ctrl+V. Only if that fails is the third-party patch worth reading.\n'
  } > "$(m8_human)" 2>/dev/null
  printf '   ..   NOT ASSERTED, and no shell command can assert it: the Cmd+V -> Ctrl+V rewrite.\n'
  printf '        Take a Cmd+Shift+4 and press Ctrl+V in your agent; an image must attach.\n'
  printf '   ..   Screen Recording is BELIEVED unnecessary for Hammerspoon and was NEVER tested\n'
  printf '        without it. This Mac is that experiment. Nothing asserts it either way here.\n'
  printf '        Both notes are also at %s\n' "$(m8_human)"

  [ "$unfinished" = 0 ] || return 1
  return 0
}

# ── uninstall ────────────────────────────────────────────────────────────────────────────────
# Reverses what install_ changed and NOTHING ELSE. Three things are deliberately left alone and
# each is named: the Hammerspoon app (it holds TCC grants that do not come back, and you may now
# use it for other things), the config checkout (a git repo, which may hold your own commits),
# and ~/Screenshots (your captures — on the source machine that directory holds 3,381 files).
uninstall_m8_screenshot() {
  local l t b k v p dom
  dom="$(m8_domain)"

  l="$(m8_hs_dir)/init.lua"
  if [ -L "$l" ]; then
    t="$(readlink "$l" 2>/dev/null)" || t=""
    if [ "$t" = "$(m8_repo_dir)/init.lua" ]; then
      rm -f "$l" 2>/dev/null
      b="$(ls -1 "$(m8_hs_dir)"/init.lua.pb-bak.* 2>/dev/null | tail -1)" || b=""
      [ -n "$b" ] && mv "$b" "$l" 2>/dev/null && printf '   ok   restored %s from %s\n' "$l" "$b"
    fi
  fi

  p="$(m8_pre)"
  if [ -f "$p" ]; then
    while IFS="$(printf '\t')" read -r k v; do
      [ -n "${k:-}" ] || continue
      if [ "${v:-}" = "ABSENT" ]; then
        "$M8_DEFAULTS" delete "$dom" "$k" >/dev/null 2>&1
      else
        case "$k" in
          show-thumbnail)
            # `defaults read` gave us 0|1; `-bool` accepts only true|false|yes|no (measured:
            # `-bool 0` exits 255 with the usage block). Restoring needs the translation back.
            case "$v" in
              0|false|no|NO) v=false ;;
              *)             v=true ;;
            esac
            "$M8_DEFAULTS" write "$dom" "$k" -bool "$v" >/dev/null 2>&1 ;;
          *)  "$M8_DEFAULTS" write "$dom" "$k" -string "$v" >/dev/null 2>&1 ;;
        esac
      fi
    done < "$p"
    rm -f "$p" 2>/dev/null
    printf '   ok   screencapture defaults restored to what they were before this ran\n'
  fi

  rm -f "$(m8_mark)" "$(m8_human)" 2>/dev/null
  printf '   --   left alone on purpose: %s, the checkout at %s, and %s\n' "$M8_APP" "$(m8_repo_dir)" "$(m8_shot_dir)"
  return 0
}
