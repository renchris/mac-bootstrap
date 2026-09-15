#!/bin/bash
# screenshot — Cmd+Shift+4 -> bottom-right thumbnail -> clipboard -> paste into the agent.
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
#     earn, and leaves it at $BOOTSTRAP_STATE_DIR/screenshot-human-check.txt.
#
# HOUSE RULES THIS FILE OBEYS: bash 3.2 (no associative arrays, no ${x^^}, no mapfile) · set -u,
# never set -e · no absolute path containing a username, $HOME only · verify by INDEPENDENT
# read-back · human gates detected and RECORDED, never attempted · idempotent.
#
# TEST SEAMS (module-scoped; documented here because the environment contract in CONTRACT.md §5
# does not carry them). Both default to the real thing and neither is needed in production:
#   BOOTSTRAP_SCREENSHOT_DOMAIN    the `defaults` domain to read and write. MEASURED, and the reason this seam
#                   exists: `defaults` IGNORES $HOME — a write under HOME=$(mktemp -d) landed in
#                   the REAL user's ~/Library/Preferences. A sandbox-HOME test without this seam
#                   would silently repoint the operator's live screenshot directory at a temp
#                   directory that is then deleted.
#   BOOTSTRAP_SCREENSHOT_REPO_DIR  where the public config checkout lives. Default $HOME/Development/hammerspoon-config.
#   BOOTSTRAP_SCREENSHOT_ACCESSIBILITY_WAIT_S  seconds install_ waits for the Accessibility grant before handing back. 5.
#   BOOTSTRAP_SCREENSHOT_HAMMERSPOON_URL, BOOTSTRAP_SCREENSHOT_HAMMERSPOON_SHA256  replace the pinned
#                   Hammerspoon release, so a test drives the no-Homebrew install against a file:// fixture.
#
# A STANDARD USER GETS HAMMERSPOON TOO. /Applications is root:admin 775 and the Homebrew installer
# aborts without sudo, so the old route (brew, else "install Homebrew") was a gesture that person
# cannot perform. An administrator who already has Homebrew still gets the cask (analytics off);
# everyone else gets the pinned release, checked by sha256 before it is unpacked into
# $HOME/Applications. MEASURED 2026-09-15, macOS 15.7.9: the zip's sha256 equals the Homebrew
# cask's; after `ditto -x -k` no file in the bundle carries com.apple.quarantine (curl writes only
# com.apple.provenance), and `spctl -a -vv` answers "accepted, source=Notarized Developer ID,
# origin=Developer ID Application: Chris Jones (VQCYSNZB89)". No quarantine means no Gatekeeper
# dialog — which is exactly why a bundle `spctl` rejects is deleted rather than kept: a Mac whose
# IT allows only App Store apps would otherwise run it anyway, around the policy.

SCREENSHOT_HAMMERSPOON_URL='https://github.com/Hammerspoon/hammerspoon/releases/download/1.1.1/Hammerspoon-1.1.1.zip'
SCREENSHOT_HAMMERSPOON_SHA256='11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa'
SCREENSHOT_HAMMERSPOON_DOMAIN='org.hammerspoon.Hammerspoon'
# Hammerspoon phones home twice unless told not to, and both switches are its own (source read at
# the 1.1.1 tag):
#   HSUploadCrashData        crash reports to Sentry, default YES (variables.h:6, MJAppDelegate.m:329).
#                            Read ONCE, at launch, before Sentry starts (MJAppDelegate.m:249) — so a
#                            copy already running when it flips keeps uploading until it restarts.
#   SUEnableAutomaticChecks  Sparkle's key (Sparkle 2.6.4 SUConstants.m:50): what the documented
#                            hs.automaticallyCheckForUpdates() and the Preferences checkbox set
#                            (MJLua.m:491, MJPreferencesWindowController.m:114). The user default
#                            beats Info.plist's `SUEnableAutomaticChecks = 1` (SPUUpdaterSettings.m:36).
SCREENSHOT_HAMMERSPOON_PREFS='HSUploadCrashData SUEnableAutomaticChecks'
SCREENSHOT_SPCTL="/usr/sbin/spctl"
# The Hammerspoon config is VENDORED at assets/hammerspoon/init.lua. It used to be cloned from a
# personal GitHub repo, which made this module fail for anyone who is not its owner and put an
# account-shaped dependency in a bootstrap whose whole premise is an ANONYMOUS reader. The clone
# path survives only when the operator explicitly points at a checkout they want to track.
SCREENSHOT_REPO_URL="${BOOTSTRAP_SCREENSHOT_REPO_URL:-}"
SCREENSHOT_DEFAULTS="/usr/bin/defaults"
SCREENSHOT_SCREENCAPTURE="/usr/sbin/screencapture"

# ── paths, computed rather than stored, because no state survives between verbs ───────────────
screenshot_shot_dir() { printf '%s' "$HOME/Screenshots"; }
screenshot_hammerspoon_dir()   { printf '%s' "$HOME/.hammerspoon"; }
screenshot_repo_dir() { printf '%s' "${BOOTSTRAP_SCREENSHOT_REPO_DIR:-${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/hammerspoon}"; }
# ── screenshot_config_source — where init.lua comes from: the release tree the driver already verified
# against its sha256 manifest, and nowhere else. The raw-URL fetch this used to fall back to was
# unverified, and a curl'd driver now materializes that tree before any module runs.
screenshot_config_source() {
  local c="${BOOTSTRAP_ASSETS:-}/hammerspoon/init.lua"
  [ -n "${BOOTSTRAP_ASSETS:-}" ] && [ -f "$c" ] || return 1
  printf '%s' "$c"
}

# The app, wherever a person could have put it: /Applications, or $HOME/Applications, which is the
# only one of the two a standard user can write.
screenshot_app()             { bootstrap_find_app Hammerspoon.app; }
screenshot_app_home_target() { printf '%s' "$HOME/Applications/Hammerspoon.app"; }

screenshot_domain()   { printf '%s' "${BOOTSTRAP_SCREENSHOT_DOMAIN:-com.apple.screencapture}"; }
screenshot_state()    { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
screenshot_blocked_marker()     { printf '%s/screenshot-blocked' "$(screenshot_state)"; }
screenshot_defaults_snapshot()      { printf '%s/screenshot-defaults-before-install' "$(screenshot_state)"; }
screenshot_hammerspoon_snapshot()   { printf '%s/screenshot-hammerspoon-before-install' "$(screenshot_state)"; }
screenshot_human()    { printf '%s/screenshot-human-check.txt' "$(screenshot_state)"; }

# A marker for a gate install_ DISCOVERED THIS RUN: "<reason> <driver pid>". $$ is the driver's pid
# in every verb, because each verb runs in a subshell of it, so the gate fires for the rest of this
# run and not the next — a download that failed behind a proxy is retried on the next run instead
# of being reported forever by a marker nothing clears.
screenshot_mark_this_run() { printf '%s %s' "${1:-}" "$$" > "$(screenshot_blocked_marker)" 2>/dev/null; }
screenshot_marked_this_run() {                  # prints the reason, rc 1 unless marked by THIS run
  local m
  m="$(cat "$(screenshot_blocked_marker)" 2>/dev/null)" || return 1
  case "$m" in *" "*) : ;; *) return 1 ;; esac
  [ "${m#* }" = "$$" ] || return 1
  printf '%s' "${m%% *}"
}

# ── screenshot_run_bounded <seconds> <cmd...> — a wall clock over one command. ────────────────────────
# There is no `timeout` on a stock Mac (coreutils is not on the default PATH), and a verifier
# that HANGS is worse than one that fails: it wedges the whole bootstrap with no output. The
# completion test is a SENTINEL FILE, not `kill -0`, because `kill -0` on an unreaped child
# answers "alive" for a zombie and the loop would never break. stdin is /dev/null throughout:
# `hs` PROMPTS for confirmation before launching Hammerspoon when it is not running, and a
# prompt reading a terminal is exactly how this hangs. rc 124 means the bound fired.
screenshot_run_bounded() {
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
screenshot_brew() { bootstrap_find_tool brew; }

# MEASURED, and it is why this is not `command -v git`: /usr/bin/git, /usr/bin/python3,
# /usr/bin/clang and /usr/bin/swift are ONE INODE — the Command Line Tools shim, 78 hard links.
# RUNNING it on a Mac with no CLT raises the GUI "install command line developer tools" dialog,
# which is a human gesture this module must DETECT and never ATTEMPT. `xcode-select -p` answers
# the same question and raises nothing.
screenshot_git() {
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
screenshot_hammerspoon_bin() {
  local c app
  app="$(screenshot_app)" || app=""
  for c in ${app:+"$app/Contents/Frameworks/hs/hs"} /opt/homebrew/bin/hs /usr/local/bin/hs; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c="$(command -v hs 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

# ── live reads into the RUNNING Hammerspoon ──────────────────────────────────────────────────
# 🚨 `hs -c` EXITS 0 FOR A BOGUS EXPRESSION (measured: `-c 'return "NO-SUCH-"..tostring(nosuchglobal)'`
# prints `NO-SUCH-nil` and exits 0). The rc is therefore never the verdict here — the STRING is.
screenshot_running() { pgrep -x Hammerspoon >/dev/null 2>&1; }

screenshot_hammerspoon_eval() {
  local hs out
  screenshot_running || return 1
  hs="$(screenshot_hammerspoon_bin)" || return 1
  out="$(screenshot_run_bounded 8 "$hs" -q -t 2 -c "${1:-}")" || return 1
  printf '%s' "$out"
  return 0
}

screenshot_accessibility() { [ "$(screenshot_hammerspoon_eval 'return tostring(hs.accessibilityState())')" = "true" ]; }

# The running app's own answer about both phone-home switches, through its documented getters — a
# different reader from the `defaults write` that set them. Each defaults to true, so "true" is an
# answer this instrument gives on a fresh install: it can say no.
screenshot_phone_home_off_live() {
  [ "$(screenshot_hammerspoon_eval 'return tostring(hs.uploadCrashData())..","..tostring(hs.automaticallyCheckForUpdates())')" = "false,false" ]
}

# The independent read-back that matters most: ask the LIVE app whether the screenshot poller is
# armed. It proves (a) Hammerspoon is up, (b) it loaded a config that contains the screenshot
# feature, (c) the timer is actually running — through IPC into the app, which is a different
# code path from the symlink this module wrote. Negative control, verified: a global the config
# does NOT define answers `nil` on the same instrument.
screenshot_config_live() { [ "$(screenshot_hammerspoon_eval 'return tostring(screenshotPollTimer and screenshotPollTimer:running())')" = "true" ]; }

# And ask the live app what IT sees at ~/.hammerspoon/init.lua — in ITS home, which is the home
# the GUI app actually runs under. A shell `readlink` answers about this process's $HOME, and
# those are not always the same directory.
screenshot_live_symlink_ok() {
  local want got
  want="$(screenshot_repo_dir)/init.lua"
  got="$(screenshot_hammerspoon_eval 'return tostring(hs.fs.symlinkAttributes(os.getenv("HOME").."/.hammerspoon/init.lua","target"))')" || return 1
  [ "$got" = "$want" ] && return 0
  bootstrap_warn "screenshot: the running Hammerspoon reads [$got] as its init.lua; this run expects [$want]."
  return 1
}

# ── cheap structural reads ───────────────────────────────────────────────────────────────────
screenshot_app_ok()     { local a; a="$(screenshot_app)" && [ -f "$a/Contents/Info.plist" ]; }
screenshot_repo_ok()    { [ -f "$(screenshot_repo_dir)/init.lua" ]; }
screenshot_shotdir_ok() { [ -d "$(screenshot_shot_dir)" ]; }
screenshot_quarantined(){ local a; a="$(screenshot_app)" && xattr -p com.apple.quarantine "$a" >/dev/null 2>&1; }

screenshot_symlink_ok() {
  local l t
  l="$(screenshot_hammerspoon_dir)/init.lua"
  [ -L "$l" ] || return 1
  t="$(readlink "$l" 2>/dev/null)" || return 1
  [ "$t" = "$(screenshot_repo_dir)/init.lua" ] && [ -f "$t" ]
}

screenshot_prefs_read() {                       # <domain> <key>
  local out
  out="$("$SCREENSHOT_DEFAULTS" read "${1:-}" "${2:-}" 2>/dev/null)" || return 1
  printf '%s' "$out"
}
screenshot_defaults_read() { screenshot_prefs_read "$(screenshot_domain)" "${1:-}"; }

# Both Hammerspoon switches read back as 0. `-bool false` is written and `0` is read: see
# screenshot_prefs_write for why those are two alphabets.
screenshot_hammerspoon_prefs_ok() {
  local k
  for k in $SCREENSHOT_HAMMERSPOON_PREFS; do
    [ "$(screenshot_prefs_read "$SCREENSHOT_HAMMERSPOON_DOMAIN" "$k")" = 0 ] || return 1
  done
  return 0
}

# Each key is read back INDIVIDUALLY, and each failure names the consequence rather than the key,
# because every one of these settings is load-bearing and silent when wrong.
screenshot_defaults_ok() {
  local want loc st tg
  want="$(screenshot_shot_dir)"
  loc="$(screenshot_defaults_read location)" || { bootstrap_warn "screenshot: $(screenshot_domain) 'location' is unset — captures would go to the Desktop, which init.lua does not poll."; return 1; }
  # shellcheck disable=SC2088  # the literal tilde is DELIBERATE: macOS writes an UNEXPANDED
  # tilde into this domain itself (the live box holds `"location-last" = "~/Documents/"`), so a
  # user or an OS-written `~/Screenshots` must compare equal. We always WRITE the absolute form.
  case "$loc" in
    "$want"|"$want"/|'~/Screenshots'|'~/Screenshots/') : ;;
    *) bootstrap_warn "screenshot: screencapture writes to [$loc] but init.lua polls [$want] — the pipeline would be dark."; return 1 ;;
  esac
  st="$(screenshot_defaults_read show-thumbnail)" || st=""
  [ "$st" = "0" ] || { bootstrap_warn "screenshot: show-thumbnail is [$st], not 0. The native thumbnail is a pending-commit UI and DEFERS the disk write (measured 6.11 s ON vs 0.41 s OFF)."; return 1; }
  tg="$(screenshot_defaults_read target)" || tg=""
  [ "$tg" = "file" ] || { bootstrap_warn "screenshot: target is [$tg], not file. target is single-valued: target=clipboard writes NO file and draws NO thumbnail."; return 1; }
  if screenshot_defaults_read name >/dev/null 2>&1; then
    bootstrap_warn "screenshot: $(screenshot_domain) 'name' is set. init.lua anchors on ^Screenshot, so a renamed capture is never seen and the pipeline goes dark with no error."
    return 1
  fi
  return 0
}

screenshot_struct_ok() { screenshot_app_ok && screenshot_repo_ok && screenshot_symlink_ok && screenshot_shotdir_ok && screenshot_defaults_ok; }

# ── the live end-to-end probe ────────────────────────────────────────────────────────────────
# rc 0 the clipboard received a PNG · 2 screencapture itself could not produce a capture
# (a different culprit, and a different gesture) · 1 everything else.
screenshot_clipboard_has_png() { osascript -e 'the clipboard as «class PNGf»' >/dev/null 2>&1; }

screenshot_live_probe() {
  local dir shot rc i
  dir="$(screenshot_shot_dir)"
  [ -d "$dir" ] || { bootstrap_warn "screenshot: $dir does not exist."; return 1; }

  # NEGATIVE CONTROL FIRST. Prime the clipboard with text and require the PNG read to FAIL. If a
  # PNG is already sitting there, the poll below would pass without Hammerspoon doing anything,
  # and a positive result would carry no information at all.
  printf '%s' 'mac-bootstrap screenshot sentinel — NOT an image' | pbcopy 2>/dev/null || {
    bootstrap_warn "screenshot: pbcopy failed; cannot establish the negative control."; return 1; }
  if screenshot_clipboard_has_png; then
    bootstrap_warn "screenshot: the clipboard still reads as a PNG immediately after text was copied — the instrument cannot say no, so nothing it says yes to would mean anything."
    return 1
  fi

  # A distinct, sweepable name that still matches init.lua's ^Screenshot anchor.
  shot="$dir/Screenshot $(date '+%Y-%m-%d at %H.%M.%S') mac-bootstrap-probe-$$.png"
  # screencapture's OWN rc, read directly. Never through a pipe: $? after a pipe is the LAST
  # stage's status, which is how a capture failure reads as success.
  "$SCREENSHOT_SCREENCAPTURE" -x -R 0,0,200,200 "$shot" >/dev/null 2>&1
  rc=$?
  if [ "$rc" != 0 ]; then
    bootstrap_warn "screenshot: screencapture exited $rc and wrote nothing. On macOS 15 the app that RUNS screencapture needs Screen Recording; grant it to your terminal, or run this from a terminal that has it."
    rm -f "$shot" 2>/dev/null
    return 2
  fi
  if [ ! -s "$shot" ]; then
    bootstrap_warn "screenshot: screencapture exited 0 but produced an empty file — treat this as a capture-side failure, not a pipeline failure."
    rm -f "$shot" 2>/dev/null
    return 2
  fi

  # Now the read-back, through a DIFFERENT API than the one that wrote: Hammerspoon writes the
  # pasteboard through NSPasteboard; this is the AppleScript coercion Claude Code itself runs.
  i=0
  while [ "$i" -lt 60 ]; do
    if screenshot_clipboard_has_png; then
      rm -f "$shot" 2>/dev/null           # our probe file, and only ours
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  bootstrap_warn "screenshot: 15 s after a capture landed in $dir the clipboard still holds no PNG — Hammerspoon's poll or its clipboard write is not running. Check: tail \$HOME/Library/Logs/Hammerspoon/screenshot.log"
  rm -f "$shot" 2>/dev/null
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# THE SIX VERBS
# ═════════════════════════════════════════════════════════════════════════════════════════════

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_screenshot()    { printf '%s' 'Cmd+Shift+4 to a bottom-right thumbnail to the clipboard to a paste into your agent'; }
cost_screenshot()    { printf '%s' 'Hammerspoon (a pinned download into ~/Applications, no admin needed), and one Accessibility toggle that no script can grant for you — on a standard account, an administrator has to approve it.'; }
profile_screenshot() { printf '%s' 'full'; }

# egress_ — the install route's hosts, and Hammerspoon's own. Crash reports to Sentry are not listed:
# install_ switches them off before the first launch and verify_ reads that back from the live app.
egress_screenshot() {
  local h
  printf '%s\n' 'github.com install Hammerspoon 1.1.1 zip, pinned by sha256, only when Hammerspoon is not installed'
  printf '%s\n' 'release-assets.githubusercontent.com install the Hammerspoon zip itself (github.com redirects there)'
  printf '%s\n' 'formulae.brew.sh install brew install --cask hammerspoon instead, only for an administrator who already has Homebrew (analytics off)'
  printf '%s\n' 'raw.githubusercontent.com run Hammerspoon update check (Sparkle appcast): switched OFF here; only Preferences or its Check for Updates menu item reaches it'
  if [ -n "$SCREENSHOT_REPO_URL" ]; then
    h="${SCREENSHOT_REPO_URL#*://}"; h="${h#*@}"; h="${h%%[/:]*}"
    printf '%s install git clone of BOOTSTRAP_SCREENSHOT_REPO_URL, which you set\n' "$h"
  fi
}

verify_screenshot() {
  # The defaults domain is resolved from the password database, not from $HOME, so a sandboxed
  # HOME would silently rewrite the REAL machine. Refuse instead. (bootstrap-lib.sh: bootstrap_defaults_home_ok)
  bootstrap_defaults_home_ok || return 1
  screenshot_app_ok         || { bootstrap_warn "screenshot: Hammerspoon.app is in neither /Applications nor $HOME/Applications."; return 1; }
  screenshot_hammerspoon_prefs_ok || { bootstrap_warn "screenshot: $SCREENSHOT_HAMMERSPOON_DOMAIN does not read back HSUploadCrashData=0 and SUEnableAutomaticChecks=0 — Hammerspoon would upload crash reports or check for updates."; return 1; }
  screenshot_repo_ok        || { bootstrap_warn "screenshot: no config checkout at $(screenshot_repo_dir)."; return 1; }
  screenshot_symlink_ok     || { bootstrap_warn "screenshot: $(screenshot_hammerspoon_dir)/init.lua is not a symlink to $(screenshot_repo_dir)/init.lua."; return 1; }
  screenshot_shotdir_ok     || { bootstrap_warn "screenshot: $(screenshot_shot_dir) does not exist."; return 1; }
  screenshot_defaults_ok    || return 1
  screenshot_running        || { bootstrap_warn "screenshot: Hammerspoon is not running."; return 1; }
  screenshot_config_live    || { bootstrap_warn "screenshot: the running Hammerspoon has no armed screenshotPollTimer — the loaded config does not carry the screenshot feature, or it errored while loading."; return 1; }
  screenshot_live_symlink_ok || return 1
  screenshot_phone_home_off_live || { bootstrap_warn "screenshot: the running Hammerspoon reports crash upload or automatic update checks ON."; return 1; }
  screenshot_accessibility  || { bootstrap_warn "screenshot: Hammerspoon does not hold Accessibility; the Cmd+V -> Ctrl+V rewrite cannot run."; return 1; }
  screenshot_live_probe     || return 1
  return 0
}

# The Homebrew installer is a gesture only for an ADMINISTRATOR on Apple Silicon: install.sh aborts
# without sudo, and on any Intel Mac ("only supported on Apple Silicon processors").
screenshot_homebrew_installable() {
  bootstrap_is_admin && ! screenshot_brew >/dev/null 2>&1 && [ "$(/usr/bin/uname -m 2>/dev/null)" = arm64 ]
}

# gate_ answers ONE question: is a human gesture the next thing needed? It must NOT answer yes
# while drivable work remains, because the driver reports NEEDS_HUMAN *instead of* installing.
# A missing Hammerspoon is drivable for everyone now, so it gates only when THIS run's install
# could not get it: the download failed, its sha256 was wrong, or Gatekeeper refuses it.
screenshot_gate_reason() {
  local mark
  if ! screenshot_app_ok; then
    mark="$(screenshot_marked_this_run)" && { printf '%s' "$mark"; return 0; }
  fi
  # git is needed only for a checkout the operator explicitly asked for; the vendored config needs none.
  if [ -n "$SCREENSHOT_REPO_URL" ] && ! screenshot_repo_ok && ! screenshot_git >/dev/null 2>&1; then printf 'clt'; return 0; fi
  mark="$(cat "$(screenshot_blocked_marker)" 2>/dev/null)" || mark=""
  case "$mark" in
    gatekeeper)      if screenshot_app_ok && ! screenshot_running; then printf 'gatekeeper'; return 0; fi ;;
    screenrecording) if screenshot_running; then printf 'screenrecording'; return 0; fi ;;
  esac
  if screenshot_struct_ok && screenshot_running && ! screenshot_accessibility; then printf 'accessibility'; return 0; fi
  return 0
}

gate_screenshot() {
  # A sandboxed HOME is a DECISION, not a bug: `defaults` would escape it and hit the real
  # domain, so bootstrap_defaults_home_ok refuses. Reported through gate_ so it reads NEEDS_HUMAN
  # rather than FAILED — FAILED sends the reader to the log for a defect that is not there.
  bootstrap_defaults_home_ok >/dev/null 2>&1 || return 0
  local r
  r="$(screenshot_gate_reason)"
  [ -n "$r" ]
}

note_screenshot() {
  if ! bootstrap_defaults_home_ok >/dev/null 2>&1; then
    printf 'this run has a sandboxed HOME ($HOME is not your real home), and `defaults` ignores $HOME — writing would hit your REAL preferences. Nothing was written.'
    return 0
  fi
  case "$(screenshot_gate_reason)" in
    fetch)
      if screenshot_homebrew_installable; then
        printf 'Hammerspoon could not be downloaded from github.com, so nothing was installed. Homebrew would install it instead (the command below needs your password), or run the bootstrap again once github.com is reachable.'
      else
        printf 'Hammerspoon could not be downloaded from github.com, so nothing was installed. Run the bootstrap again once github.com is reachable; if a company proxy blocks it, ask IT for Hammerspoon (https://www.hammerspoon.org).'
      fi ;;
    refused)         printf 'the Hammerspoon download did not have the sha256 this release pins, so it was deleted and nothing was installed. Do not install it by hand from the same source; report it to the maintainers of this bootstrap.' ;;
    gatekeeper-policy) printf 'this Mac'"'"'s Gatekeeper policy rejects Hammerspoon (a notarized Developer ID app, team VQCYSNZB89), so it was deleted rather than run around the policy. Ask IT to allow Hammerspoon.' ;;
    clt)
      if bootstrap_is_admin; then printf 'The Xcode Command Line Tools are absent, so git cannot clone BOOTSTRAP_SCREENSHOT_REPO_URL; the installer is a GUI dialog you must approve.'
      else printf 'The Xcode Command Line Tools are absent, so git cannot clone BOOTSTRAP_SCREENSHOT_REPO_URL, and installing them needs an administrator — ask IT, or unset BOOTSTRAP_SCREENSHOT_REPO_URL to use the config this release ships.'; fi ;;
    gatekeeper)      printf 'Hammerspoon is installed but will not launch — macOS quarantines a first-run downloaded app until you approve it once.' ;;
    screenrecording)
      if bootstrap_is_admin; then printf 'screencapture could not produce a capture from this terminal; on macOS 15 the app that runs it needs Screen Recording.'
      else printf 'screencapture could not produce a capture from this terminal; on macOS 15 the app that runs it needs Screen Recording, and on a standard account an administrator must approve it — unless IT'"'"'s Privacy Preferences profile lets standard users allow it.'; fi ;;
    accessibility)
      if bootstrap_is_admin; then printf 'Hammerspoon needs Accessibility, and on an unmanaged Mac that toggle cannot be set by any script: tccutil only resets, TCC writes are SIP-protected, and a PPPC profile needs an MDM-enrolled and supervised device.'
      else printf 'Hammerspoon needs Accessibility, and on a standard account only an administrator can turn it on: they type their name and password in the pane below, or IT pushes a Privacy Preferences (PPPC) profile allowing org.hammerspoon.Hammerspoon. Apple lets IT hand Screen Recording to standard users, but never Accessibility.'; fi ;;
    *)               printf 'Hammerspoon, the config checkout, the symlink, the screenshot directory and the screencapture defaults are not all in place yet.' ;;
  esac
}

gesture_screenshot() {
  if ! bootstrap_defaults_home_ok >/dev/null 2>&1; then
    printf 'run it from your own account (no HOME override), or set BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 if you truly mean to write the real domain'
    return 0
  fi
  case "$(screenshot_gate_reason)" in
    fetch)           screenshot_homebrew_installable && printf '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' ;;
    clt)             bootstrap_is_admin && printf 'xcode-select --install' ;;
    gatekeeper)      printf 'open "x-apple.systempreferences:com.apple.preference.security?Security"' ;;
    screenrecording) printf 'open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"' ;;
    accessibility)   printf 'open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"' ;;
    *)               : ;;
  esac
  return 0
}

# ── install ──────────────────────────────────────────────────────────────────────────────────
screenshot_defaults_pre_record() {                      # once per machine, before the first write
  local p k v
  p="$(screenshot_defaults_snapshot)"
  [ -f "$p" ] && return 0
  : > "$p" 2>/dev/null || return 0
  for k in location show-thumbnail target name; do
    if v="$(screenshot_defaults_read "$k")"; then
      printf '%s\t%s\n' "$k" "$v" >> "$p" 2>/dev/null
    else
      printf '%s\tABSENT\n' "$k" >> "$p" 2>/dev/null
    fi
  done
  return 0
}

# screenshot_defaults_write <key> <type-flag> <write-value> [expected-read-value]
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
screenshot_prefs_write() {                      # <domain> <key> <type-flag> <write-value> [expected-read-value]
  local d="${1:-}" k="${2:-}" tf="${3:-}" v="${4:-}" want="${5:-}" cur
  [ -n "$want" ] || want="$v"
  cur="$(screenshot_prefs_read "$d" "$k")" || cur=""
  [ "$cur" = "$want" ] && return 0               # already exactly this — do not open the file
  "$SCREENSHOT_DEFAULTS" write "$d" "$k" "$tf" "$v" >/dev/null 2>&1 || return 1
  # read back through the same reader the verifier uses, in the READ alphabet
  cur="$(screenshot_prefs_read "$d" "$k")" || cur=""
  [ "$cur" = "$want" ]
}
screenshot_defaults_write() { screenshot_prefs_write "$(screenshot_domain)" "$@"; }

# screenshot_hammerspoon_prefs_off — both switches to false, BEFORE Hammerspoon's first launch, so that
# launch never starts Sentry. Guarded on its own, not only by install_: `defaults` ignores $HOME, so
# a sandboxed caller would otherwise switch off the REAL user's Hammerspoon. Sets
# SCREENSHOT_PREFS_CHANGED=1 when it changed anything (a running copy must then restart).
SCREENSHOT_PREFS_CHANGED=0
screenshot_hammerspoon_prefs_off() {
  bootstrap_defaults_home_ok || return 1
  local p k v
  p="$(screenshot_hammerspoon_snapshot)"
  if [ ! -f "$p" ] && : > "$p" 2>/dev/null; then      # once per machine: what uninstall_ restores
    for k in $SCREENSHOT_HAMMERSPOON_PREFS; do
      v="$(screenshot_prefs_read "$SCREENSHOT_HAMMERSPOON_DOMAIN" "$k")" || v=ABSENT
      printf '%s\t%s\n' "$k" "$v" >> "$p" 2>/dev/null
    done
  fi
  for k in $SCREENSHOT_HAMMERSPOON_PREFS; do
    [ "$(screenshot_prefs_read "$SCREENSHOT_HAMMERSPOON_DOMAIN" "$k")" = 0 ] && continue
    screenshot_prefs_write "$SCREENSHOT_HAMMERSPOON_DOMAIN" "$k" -bool false 0 || {
      bootstrap_warn "screenshot: could not set $SCREENSHOT_HAMMERSPOON_DOMAIN $k to false"; return 1; }
    SCREENSHOT_PREFS_CHANGED=1
  done
  return 0
}

# screenshot_install_pinned — the pinned release into $HOME/Applications, for anyone without an
# administrator's Homebrew. rc 0 installed · 1 not downloaded · 2 refused: the sha256 was wrong ·
# 3 refused: Gatekeeper rejects this app on this Mac · 4 could not unpack or land it. On every
# non-zero rc nothing is left in $HOME/Applications: the bundle is unpacked into a staging dir
# beside its target (one filesystem, so the final mv is a rename) and assessed THERE.
screenshot_install_pinned() {
  local url sha zip dest stage app q
  url="${BOOTSTRAP_SCREENSHOT_HAMMERSPOON_URL:-$SCREENSHOT_HAMMERSPOON_URL}"
  sha="${BOOTSTRAP_SCREENSHOT_HAMMERSPOON_SHA256:-$SCREENSHOT_HAMMERSPOON_SHA256}"
  dest="$(dirname "$(screenshot_app_home_target)")"
  zip="$(bootstrap_tools_dir)/downloads/Hammerspoon.zip"
  if [ -e "$(screenshot_app_home_target)" ]; then
    bootstrap_warn "screenshot: $(screenshot_app_home_target) exists but is not a complete app; move it aside and run again"
    return 4
  fi
  bootstrap_fetch_pinned "$url" "$sha" "$zip" || return $?
  mkdir -p "$dest" 2>/dev/null && stage="$(mktemp -d "$dest/.mac-bootstrap-hammerspoon.XXXXXX" 2>/dev/null)" \
    || { rm -f "$zip"; return 4; }
  /usr/bin/ditto -x -k "$zip" "$stage" 2>/dev/null; rm -f "$zip"
  app="$stage/Hammerspoon.app"
  [ -f "$app/Contents/Info.plist" ] || { rm -rf "$stage"; bootstrap_warn "screenshot: the download held no Hammerspoon.app"; return 4; }
  q="$(/usr/bin/xattr -r "$app" 2>/dev/null | /usr/bin/grep -c 'com.apple.quarantine')"
  printf '   ok   unpacked; %s file(s) carry a quarantine flag\n' "${q:-0}"
  if ! "$SCREENSHOT_SPCTL" -a -vv "$app" >/dev/null 2>&1; then
    bootstrap_warn "screenshot: Gatekeeper on this Mac rejects the Hammerspoon download ($("$SCREENSHOT_SPCTL" -a -vv "$app" 2>&1 | tr '\n' ' '))"
    rm -rf "$stage"
    return 3
  fi
  mv "$app" "$(screenshot_app_home_target)" 2>/dev/null || { rm -rf "$stage"; return 4; }
  rm -rf "$stage"
  screenshot_app_ok || return 4
}

install_screenshot() {
  # The defaults domain is resolved from the password database, not from $HOME, so a sandboxed
  # HOME would silently rewrite the REAL machine. Refuse instead. (bootstrap-lib.sh: bootstrap_defaults_home_ok)
  bootstrap_defaults_home_ok || return 1
  local brew git dir hs out i rc want src app unfinished=0

  rm -f "$(screenshot_blocked_marker)" 2>/dev/null

  # 1. Hammerspoon. Homebrew only for an administrator who already has it — a cask lands in
  #    /Applications, which a standard user cannot write. Everyone else, and an administrator whose
  #    cask install did not produce the app, gets the pinned release in $HOME/Applications.
  if screenshot_app_ok; then
    printf '   ok   Hammerspoon already at %s\n' "$(screenshot_app)"
  else
    if bootstrap_is_admin && brew="$(screenshot_brew)"; then
      printf '   ..   brew install --cask hammerspoon (analytics off)\n'
      # </dev/null so a cask that asks for a password FAILS rather than hanging the bootstrap.
      NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 bootstrap_brew "$brew" install --cask hammerspoon </dev/null 2>&1
      screenshot_app_ok || printf '   --   brew finished but Hammerspoon.app is not there; trying the pinned release\n'
    fi
    if ! screenshot_app_ok; then
      printf '   ..   Hammerspoon 1.1.1 from github.com, pinned by sha256, into %s\n' "$(dirname "$(screenshot_app_home_target)")"
      screenshot_install_pinned
      rc=$?
      case "$rc" in
        0) printf '   ok   installed at %s; Gatekeeper accepted it before it was moved into place\n' "$(screenshot_app)" ;;
        1) screenshot_mark_this_run fetch;             printf '   x    could not download Hammerspoon\n'; return 1 ;;
        2) screenshot_mark_this_run refused;           printf '   x    the download did not match the pinned sha256; deleted\n'; return 1 ;;
        3) screenshot_mark_this_run gatekeeper-policy; printf '   x    Gatekeeper on this Mac rejects Hammerspoon; deleted, not installed around it\n'; return 1 ;;
        *) printf '   x    could not unpack Hammerspoon into %s\n' "$(dirname "$(screenshot_app_home_target)")"; return 1 ;;
      esac
    fi
  fi

  # 1b. Hammerspoon's two phone-home switches, BEFORE it first launches (see the header).
  if screenshot_hammerspoon_prefs_off && screenshot_hammerspoon_prefs_ok; then
    printf '   ok   Hammerspoon: crash-report upload off, automatic update checks off (read back)\n'
  else
    printf '   x    could not switch off Hammerspoon crash reports and update checks\n'
    return 1
  fi

  # 2. the config itself — VENDORED, not cloned. A git checkout is used only when the operator
  #    explicitly named one (BOOTSTRAP_SCREENSHOT_REPO_DIR at a .git, or BOOTSTRAP_SCREENSHOT_REPO_URL); otherwise the file
  #    comes from the release tree the driver verified, and needs no git, no GitHub account and no
  #    network of its own.
  dir="$(screenshot_repo_dir)"
  if [ -n "$SCREENSHOT_REPO_URL" ] && ! screenshot_repo_ok; then
    if git="$(screenshot_git)"; then
      mkdir -p "$(dirname "$dir")" 2>/dev/null
      printf '   ..   git clone %s (explicitly requested)\n' "$SCREENSHOT_REPO_URL"
      GIT_TERMINAL_PROMPT=0 "$git" clone --depth 1 "$SCREENSHOT_REPO_URL" "$dir" </dev/null 2>&1
    else
      printf '   x    BOOTSTRAP_SCREENSHOT_REPO_URL is set but there is no usable git — that step is yours.\n'
      return 1
    fi
  fi
  if [ -d "$dir/.git" ] && git="$(screenshot_git)"; then
    printf '   ok   tracking the checkout at %s\n' "$dir"
    if [ -z "$("$git" -C "$dir" status --porcelain 2>/dev/null)" ]; then
      GIT_TERMINAL_PROMPT=0 "$git" -C "$dir" pull --ff-only </dev/null >/dev/null 2>&1 \
        && printf '   ok   fast-forwarded\n' || printf '   --   no fast-forward available; leaving it as it is\n'
    else
      printf '   --   checkout has local changes; not pulling\n'
    fi
  elif ! src="$(screenshot_config_source)"; then
    if screenshot_repo_ok; then printf '   ok   config already installed at %s (this run has no release tree to refresh it from)\n' "$dir"
    else printf '   x    this run has no release tree holding assets/hammerspoon/init.lua\n'; return 1; fi
  else
    mkdir -p "$dir" 2>/dev/null
    if [ -f "$dir/init.lua" ] && cmp -s "$src" "$dir/init.lua"; then
      printf '   ok   config already current at %s\n' "$dir"
    else
      cp "$src" "$dir/init.lua.part" 2>/dev/null && mv -f "$dir/init.lua.part" "$dir/init.lua" 2>/dev/null \
        || { printf '   x    could not write %s/init.lua\n' "$dir"; return 1; }
      printf '   ok   config installed to %s (vendored, no GitHub account needed)\n' "$dir"
    fi
  fi
  screenshot_repo_ok || { printf '   x    no init.lua at %s\n' "$dir"; return 1; }

  # 3. the symlink — guarded, idempotent, non-destructive. Anything already there that is not
  #    ours is MOVED ASIDE, never overwritten: `ln -sfn` would silently discard it.
  mkdir -p "$(screenshot_hammerspoon_dir)" 2>/dev/null
  want="$dir/init.lua"
  if screenshot_symlink_ok; then
    printf '   ok   %s/init.lua -> %s\n' "$(screenshot_hammerspoon_dir)" "$want"
  else
    if [ -e "$(screenshot_hammerspoon_dir)/init.lua" ] || [ -L "$(screenshot_hammerspoon_dir)/init.lua" ]; then
      out="$(screenshot_hammerspoon_dir)/init.lua.mac-bootstrap-backup.$(date -u +%Y%m%dT%H%M%SZ)"
      mv "$(screenshot_hammerspoon_dir)/init.lua" "$out" 2>/dev/null \
        && printf '   ok   your existing init.lua was MOVED to %s — nothing was overwritten\n' "$out"
    fi
    ln -s "$want" "$(screenshot_hammerspoon_dir)/init.lua" 2>/dev/null
    if screenshot_symlink_ok; then printf '   ok   symlinked %s/init.lua -> %s\n' "$(screenshot_hammerspoon_dir)" "$want"
    else printf '   x    could not symlink %s/init.lua\n' "$(screenshot_hammerspoon_dir)"; return 1; fi
  fi

  # 4. the screenshot directory init.lua polls
  mkdir -p "$(screenshot_shot_dir)" 2>/dev/null
  # NOT `A && printf ok || { ...; return 1; }` — printf is a command that can fail (EPIPE), and
  # that shape then runs the failure branch over a TRUE condition. if/else says what it means.
  if screenshot_shotdir_ok; then
    printf '   ok   %s\n' "$(screenshot_shot_dir)"
  else
    printf '   x    could not create %s\n' "$(screenshot_shot_dir)"
    return 1
  fi

  # 5. the screencapture defaults, each written only if it differs and each READ BACK ALONE
  screenshot_defaults_pre_record
  screenshot_defaults_write location -string "$(screenshot_shot_dir)" || printf '   x    could not write location\n'
  screenshot_defaults_write show-thumbnail -bool false 0      || printf '   x    could not write show-thumbnail\n'
  screenshot_defaults_write target -string file               || printf '   x    could not write target\n'
  if screenshot_defaults_read name >/dev/null 2>&1; then
    # Recorded above, restored by uninstall_. It has to go: init.lua anchors on ^Screenshot and
    # a renamed capture is simply never seen — the whole pipeline goes dark with no error.
    "$SCREENSHOT_DEFAULTS" delete "$(screenshot_domain)" name >/dev/null 2>&1 \
      && printf '   ok   removed the screencapture "name" prefix (it breaks the ^Screenshot anchor); uninstall restores it\n'
  fi
  if screenshot_defaults_ok; then
    printf '   ok   defaults read back: location=%s show-thumbnail=0 target=file name unset\n' "$(screenshot_shot_dir)"
  else
    printf '   x    the screencapture defaults did not read back as written\n'
    return 1
  fi

  # 6. launch, or reload a Hammerspoon that is already up — otherwise a running instance keeps
  #    whatever config it started with and every check below fails for a reason nothing names.
  #    If 1b just switched crash upload off under a RUNNING copy, a reload is not enough: the switch
  #    is read once at launch, so that copy keeps uploading. It is asked to quit (hs._exit is
  #    [NSApp terminate:], MJLua.m:785) and started again below.
  app="$(screenshot_app)"
  if screenshot_running && [ "$SCREENSHOT_PREFS_CHANGED" = 1 ]; then
    hs="$(screenshot_hammerspoon_bin)" && screenshot_run_bounded 8 "$hs" -q -t 2 -c 'hs._exit()' >/dev/null 2>&1
    i=0; while [ "$i" -lt 10 ] && screenshot_running; do sleep 1; i=$((i + 1)); done
    if screenshot_running; then printf '   --   Hammerspoon did not quit; crash upload stays on in it until it next starts\n'
    else printf '   ok   quit the running Hammerspoon, so the crash-report switch takes effect\n'; fi
  fi
  if screenshot_running; then
    hs="$(screenshot_hammerspoon_bin)" && screenshot_run_bounded 8 "$hs" -q -t 2 -c 'hs.reload()' >/dev/null 2>&1
    printf '   ok   Hammerspoon was running; asked it to reload\n'
  else
    open "$app" 2>/dev/null
    i=0; while [ "$i" -lt 20 ]; do screenshot_running && break; sleep 1; i=$((i + 1)); done
    if screenshot_running; then printf '   ok   Hammerspoon launched\n'
    else
      if screenshot_quarantined; then
        printf 'gatekeeper' > "$(screenshot_blocked_marker)" 2>/dev/null
        printf '   x    Hammerspoon did not start and still carries the quarantine attribute — macOS wants you to approve its first launch\n'
      else
        printf '   x    Hammerspoon did not start\n'
      fi
      return 1
    fi
  fi

  # 7. the config is loaded AND armed — asked of the running app, not of the file we wrote
  i=0; while [ "$i" -lt 20 ]; do screenshot_config_live && break; sleep 1; i=$((i + 1)); done
  if screenshot_config_live; then
    printf '   ok   screenshotPollTimer is armed inside the running Hammerspoon\n'
  else
    printf '   x    the running Hammerspoon has no armed screenshotPollTimer. If your checkout predates the screenshot feature: git -C %s pull --ff-only\n' "$dir"
    return 1
  fi
  screenshot_live_symlink_ok || { printf '   x    the running Hammerspoon is reading a different init.lua than this run installed\n'; return 1; }

  # 8. Accessibility — polled briefly in case it is already granted, then HANDED BACK. It is not
  #    ours to take, and a bootstrap that blocks for six minutes on one toggle is worse than one
  #    that tells you the command and lets you re-run: re-running IS the recovery procedure.
  i=0
  while [ "$i" -lt "${BOOTSTRAP_SCREENSHOT_ACCESSIBILITY_WAIT_S:-5}" ]; do screenshot_accessibility && break; sleep 1; i=$((i + 1)); done
  if screenshot_accessibility; then
    printf '   ok   Hammerspoon holds Accessibility\n'
  else
    printf '   --   Hammerspoon does NOT hold Accessibility. That toggle is yours; nothing can set it for you.\n'
    unfinished=1
  fi

  # 9. the live end-to-end — and the one place a capture-side failure is discoverable, which is
  #    why install_ runs it rather than leaving it to verify_: a gate the installer discovers at
  #    run time is reported NEEDS_HUMAN, and only install_ can discover this one.
  if [ "$unfinished" = 0 ]; then
    screenshot_live_probe
    rc=$?
    case "$rc" in
      0) printf '   ok   capture -> clipboard proven live (osascript read the PNG back)\n' ;;
      2) printf 'screenrecording' > "$(screenshot_blocked_marker)" 2>/dev/null
         printf '   x    screencapture could not produce a capture from this process\n'
         unfinished=1 ;;
      *) printf '   x    a capture landed but the clipboard never received it\n'
         unfinished=1 ;;
    esac
  fi

  # 10. the one thing no shell can assert, stated plainly rather than greened.
  {
    printf 'mac-bootstrap screenshot — the ONE check a shell cannot make\n\n'
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
  } > "$(screenshot_human)" 2>/dev/null
  printf '   ..   NOT ASSERTED, and no shell command can assert it: the Cmd+V -> Ctrl+V rewrite.\n'
  printf '        Take a Cmd+Shift+4 and press Ctrl+V in your agent; an image must attach.\n'
  printf '   ..   Screen Recording is BELIEVED unnecessary for Hammerspoon and was NEVER tested\n'
  printf '        without it. This Mac is that experiment. Nothing asserts it either way here.\n'
  printf '        Both notes are also at %s\n' "$(screenshot_human)"

  [ "$unfinished" = 0 ] || return 1
  return 0
}

# ── uninstall ────────────────────────────────────────────────────────────────────────────────
# Reverses what install_ changed and NOTHING ELSE. Three things are deliberately left alone and
# each is named: the Hammerspoon app (it holds TCC grants that do not come back, and you may now
# use it for other things), the config checkout (a git repo, which may hold your own commits),
# and ~/Screenshots (your captures — on the source machine that directory holds 3,381 files).
uninstall_screenshot() {
  local l t b k v p dom
  dom="$(screenshot_domain)"

  l="$(screenshot_hammerspoon_dir)/init.lua"
  if [ -L "$l" ]; then
    t="$(readlink "$l" 2>/dev/null)" || t=""
    if [ "$t" = "$(screenshot_repo_dir)/init.lua" ]; then
      rm -f "$l" 2>/dev/null
      b="$(ls -1 "$(screenshot_hammerspoon_dir)"/init.lua.mac-bootstrap-backup.* 2>/dev/null | tail -1)" || b=""
      [ -n "$b" ] && mv "$b" "$l" 2>/dev/null && printf '   ok   restored %s from %s\n' "$l" "$b"
    fi
  fi

  p="$(screenshot_defaults_snapshot)"
  if [ -f "$p" ]; then
    while IFS="$(printf '\t')" read -r k v; do
      [ -n "${k:-}" ] || continue
      if [ "${v:-}" = "ABSENT" ]; then
        "$SCREENSHOT_DEFAULTS" delete "$dom" "$k" >/dev/null 2>&1
      else
        case "$k" in
          show-thumbnail)
            # `defaults read` gave us 0|1; `-bool` accepts only true|false|yes|no (measured:
            # `-bool 0` exits 255 with the usage block). Restoring needs the translation back.
            case "$v" in
              0|false|no|NO) v=false ;;
              *)             v=true ;;
            esac
            "$SCREENSHOT_DEFAULTS" write "$dom" "$k" -bool "$v" >/dev/null 2>&1 ;;
          *)  "$SCREENSHOT_DEFAULTS" write "$dom" "$k" -string "$v" >/dev/null 2>&1 ;;
        esac
      fi
    done < "$p"
    rm -f "$p" 2>/dev/null
    printf '   ok   screencapture defaults restored to what they were before this ran\n'
  fi

  # Hammerspoon's two switches, back to what they were — both are -bool, and ABSENT means the
  # app's own default (on) comes back.
  p="$(screenshot_hammerspoon_snapshot)"
  if [ -f "$p" ] && bootstrap_defaults_home_ok >/dev/null 2>&1; then
    while IFS="$(printf '\t')" read -r k v; do
      [ -n "${k:-}" ] || continue
      case "${v:-}" in
        ABSENT)         "$SCREENSHOT_DEFAULTS" delete "$SCREENSHOT_HAMMERSPOON_DOMAIN" "$k" >/dev/null 2>&1 ;;
        0|false|no|NO)  "$SCREENSHOT_DEFAULTS" write "$SCREENSHOT_HAMMERSPOON_DOMAIN" "$k" -bool false >/dev/null 2>&1 ;;
        *)              "$SCREENSHOT_DEFAULTS" write "$SCREENSHOT_HAMMERSPOON_DOMAIN" "$k" -bool true >/dev/null 2>&1 ;;
      esac
    done < "$p"
    rm -f "$p" 2>/dev/null
    printf '   ok   Hammerspoon crash-report and update-check settings restored to what they were before this ran\n'
  fi

  rm -f "$(screenshot_blocked_marker)" "$(screenshot_human)" 2>/dev/null
  printf '   --   left alone on purpose: %s, the checkout at %s, and %s\n' "$(screenshot_app 2>/dev/null || printf 'Hammerspoon.app')" "$(screenshot_repo_dir)" "$(screenshot_shot_dir)"
  return 0
}
