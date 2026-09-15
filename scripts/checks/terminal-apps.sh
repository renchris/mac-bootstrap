# shellcheck shell=bash
# scripts/checks/terminal-apps.sh — pane_equalize and screenshot on a fresh corporate Mac: a STANDARD
# user, no Homebrew, nothing in /Applications. Sourced by scripts/characterize.sh, which supplies the
# harness; never run on its own.
#
# No network: every download here is a file:// fixture of a tiny fake .app. A fake app is unsigned,
# so Gatekeeper rejects it, and that is used, not worked around — it is the check that a bundle
# Gatekeeper refuses is never left in ~/Applications. The positive arm (the real Hammerspoon 1.1.1
# zip, iTerm2 3.7.1 zip and kitty 0.48.2 dmg: sha256 equal to the Homebrew cask's, no quarantine
# flag after unpacking, `spctl` "accepted, Notarized Developer ID", both printed gestures landing
# the app when run in zsh and bash) was measured by hand on 2026-09-15; it needs the real bytes.
#
# The unit checks source the library and one module into a clean bash with a sandbox HOME, and
# replace bootstrap_find_app with one that sees only $HOME/Applications — this Mac's own
# /Applications holds iTerm2, kitty and Hammerspoon, and a fresh corporate Mac holds none of them.

TERM_H="$(fresh_home terminal-apps)"
TERM_FX="$CHECK_TMP/terminal-apps-fixtures"
mkdir -p "$TERM_FX" "$TERM_H/.mac-bootstrap"
TERM_PATH='/usr/bin:/bin:/usr/sbin:/sbin'                  # no Homebrew on PATH

# terminal_unit <module> <script> — run <script> after sourcing the library and <module>, as a
# standard user on a fresh Mac. Extra environment is passed by the caller as a prefix.
terminal_unit() {
  HOME="$TERM_H" BOOTSTRAP_STATE_DIR="$TERM_H/.mac-bootstrap" BOOTSTRAP_ASSUME_STANDARD_USER=1 \
  PATH="$TERM_PATH" TMPDIR="$CHECK_WORK" /bin/bash -c '
    . "$1/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1
    . "$1/modules/$2.sh" >/dev/null 2>&1
    bootstrap_find_app() { [ -d "$HOME/Applications/$1" ] || return 1; printf "%s" "$HOME/Applications/$1"; }
    eval "$3"' terminal_unit "$CHECK_ROOT" "$1" "$2"
}

# fake_app <dir> <Name.app> <executable> <bundle id> — an unsigned bundle, just enough to be one.
fake_app() {
  mkdir -p "$1/$2/Contents/MacOS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string></dict></plist>\n' "$4" "$3" > "$1/$2/Contents/Info.plist"
  printf '#!/bin/sh\nexit 0\n' > "$1/$2/Contents/MacOS/$3"; chmod +x "$1/$2/Contents/MacOS/$3"
}
fixture_zip() {                                          # fixture_zip <Name.app> <executable> <bundle id> → path
  local d="$TERM_FX/src-${1%.app}"
  rm -rf "$d"; mkdir -p "$d"; fake_app "$d" "$1" "$2" "$3"
  (cd "$d" && /usr/bin/ditto -c -k --keepParent "$1" "$TERM_FX/${1%.app}.zip") && printf '%s' "$TERM_FX/${1%.app}.zip"
}
home_apps() { ls -A "$TERM_H/Applications" 2>/dev/null | tr '\n' ' '; }
# A printed gesture starts with `mktemp -d`, which on macOS ignores TMPDIR (measured) and would put
# this suite's fixtures in the real per-user temp dir. A shim first on PATH keeps them in the sandbox
# without changing one byte of the command under test.
mkdir -p "$TERM_FX/bin"
printf '#!/bin/sh\nexec /usr/bin/mktemp -d "%s/gesture.XXXXXX"\n' "$CHECK_WORK" > "$TERM_FX/bin/mktemp"
chmod +x "$TERM_FX/bin/mktemp"
run_gesture() { HOME="$TERM_H" PATH="$TERM_FX/bin:$TERM_PATH" /bin/zsh -c "$1" 2>&1; }

# ── 1. The driver's plan, as a standard user with no brew on PATH ─────────────────────────────
h="$(fresh_home terminal-plan)"
PATH="$TERM_PATH" BOOTSTRAP_ASSUME_STANDARD_USER=1 drive_at "$h" --plan --only pane_equalize,screenshot
case "$CHECK_OUT" in *"NEEDS YOU:"*) same "terminal-plan-rc" "$CHECK_RC" 10 ;; *) same "terminal-plan-rc" "$CHECK_RC" 0 ;; esac   # --plan foresees on the install scale
case "$CHECK_OUT" in
  *[Bb]rew*) fail "terminal-plan-offers-no-homebrew" "$(printf '%s\n' "$CHECK_OUT" | grep -i brew | head -2)" ;;
  *)         pass "terminal-plan-offers-no-homebrew" ;;
esac

# ── 2. pane_equalize: no terminal at all ──────────────────────────────────────────────────────
rm -rf "$TERM_H/Applications"
out="$(terminal_unit pane_equalize 'gate_pane_equalize && echo GATE; echo "G=$(gesture_pane_equalize)"; echo "N=$(note_pane_equalize)"')"
TERM_G="$(printf '%s\n' "$out" | sed -n 's/^G=//p')"
case "$out" in *GATE*) pass "noterm-gates" ;; *) fail "noterm-gates" "$out" ;; esac
case "$TERM_G" in
  *brew*) fail "noterm-standard-gesture-has-no-brew" "$TERM_G" ;;
  *'$HOME/Applications'*ed5c0f623e584cddc123f87d8bda90cf4d1d18dbbae2b9b0e85939f989c640b0*|*ed5c0f623e584cddc123f87d8bda90cf4d1d18dbbae2b9b0e85939f989c640b0*'$HOME/Applications'*)
          pass "noterm-standard-gesture-has-no-brew" "pinned fetch into \$HOME/Applications" ;;
  *)      fail "noterm-standard-gesture-has-no-brew" "$TERM_G" ;;
esac
case "$out" in *"needs no administrator"*) pass "noterm-standard-note-says-no-admin" ;; *) fail "noterm-standard-note-says-no-admin" "$out" ;; esac
# the other side of the same switch: an administrator with Homebrew is offered the cask, analytics off
out="$(terminal_unit pane_equalize 'bootstrap_is_admin() { return 0; }
  bootstrap_find_tool() { [ "$1" = brew ] && { printf /fake/bin/brew; return 0; }; return 1; }
  gesture_pane_equalize')"
same "noterm-admin-brew-gesture" "$out" 'HOMEBREW_NO_ANALYTICS=1 brew install --cask iterm2'

# ── 3. …and that gesture is executable as typed, and lands nothing it has not verified ─────────
TERM_IZIP="$(fixture_zip iTerm.app iTerm2 com.googlecode.iterm2)"
TERM_ISHA="$(/usr/bin/shasum -a 256 "$TERM_IZIP" | cut -d' ' -f1)"
TERM_G="$(BOOTSTRAP_PANE_EQUALIZE_ITERM_URL="file://$TERM_IZIP" BOOTSTRAP_PANE_EQUALIZE_ITERM_SHA256="$TERM_ISHA" \
  terminal_unit pane_equalize 'gesture_pane_equalize')"
if /bin/zsh -n -c "$TERM_G" 2>/dev/null && /bin/bash -n -c "$TERM_G" 2>/dev/null; then pass "noterm-gesture-parses-in-zsh-and-bash"
else fail "noterm-gesture-parses-in-zsh-and-bash" "$TERM_G"; fi
out="$(run_gesture "$TERM_G")"; rc=$?
case "$out" in *"$CHECK_WORK/gesture."*": OK"*) pass "noterm-gesture-checks-sha-first" ;; *) fail "noterm-gesture-checks-sha-first" "$out" ;; esac
if [ "$rc" != 0 ] && [ -z "$(home_apps)" ]; then pass "noterm-gesture-lands-nothing-gatekeeper-refuses" "rc $rc"
else fail "noterm-gesture-lands-nothing-gatekeeper-refuses" "rc $rc, ~/Applications: $(home_apps)"; fi
TERM_G="$(BOOTSTRAP_PANE_EQUALIZE_ITERM_URL="file://$TERM_IZIP" BOOTSTRAP_PANE_EQUALIZE_ITERM_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
  terminal_unit pane_equalize 'gesture_pane_equalize')"
out="$(run_gesture "$TERM_G")"; rc=$?
if [ "$rc" != 0 ] && [ -z "$(home_apps)" ]; then pass "noterm-gesture-wrong-sha-lands-nothing" "rc $rc"
else fail "noterm-gesture-wrong-sha-lands-nothing" "rc $rc, ~/Applications: $(home_apps)"; fi

# ── 4. pane_equalize: an iTerm2 too old for the menu item, in ~/Applications and out of reach ──
rm -rf "$TERM_H/Applications"; mkdir -p "$TERM_H/Applications"
fake_app "$TERM_H/Applications" iTerm.app iTerm2 com.googlecode.iterm2   # its binary lacks the selector
out="$(terminal_unit pane_equalize 'echo "R=$(pane_equalize_gate_reason)"; gesture_pane_equalize')"
case "$out" in
  R=ITERM_OLD*'rm -rf "$HOME/Applications/iTerm.app"'*) pass "iterm-old-in-home-gets-verified-replace" ;;
  *) fail "iterm-old-in-home-gets-verified-replace" "$out" ;;
esac
TERM_RO="$TERM_FX/readonly-apps"; rm -rf "$TERM_RO"; mkdir -p "$TERM_RO"
fake_app "$TERM_RO" iTerm.app iTerm2 com.googlecode.iterm2; chmod 555 "$TERM_RO"
out="$(TERM_RO="$TERM_RO" terminal_unit pane_equalize 'bootstrap_find_app() { [ "$1" = iTerm.app ] && printf "%s" "$TERM_RO/iTerm.app"; }
  echo "G=[$(gesture_pane_equalize)]"; note_pane_equalize')"
chmod 755 "$TERM_RO"
case "$out" in
  "G=[]"*"ask IT to update iTerm2"*) pass "iterm-old-out-of-reach-says-ask-it" "empty gesture" ;;
  *) fail "iterm-old-out-of-reach-says-ask-it" "$out" ;;
esac
rm -rf "$TERM_H/Applications"

# ── 5. screenshot: a missing Hammerspoon is the installer's job now, not a Homebrew gesture ────
# BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS lets gate_ reason past the sandbox refusal; gate_, note_ and
# gesture_ only read, and BOOTSTRAP_SCREENSHOT_DOMAIN points even those reads at a domain nobody has.
shot_unit() { BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 BOOTSTRAP_SCREENSHOT_DOMAIN=com.mac-bootstrap.characterize.absent terminal_unit screenshot "$1"; }
out="$(shot_unit 'gate_screenshot && echo GATE; echo "G=[$(gesture_screenshot)]"')"
same "screenshot-fresh-mac-does-not-gate" "$out" "G=[]"
out="$(shot_unit 'screenshot_mark_this_run fetch; gate_screenshot && echo GATE; echo "G=[$(gesture_screenshot)]"; note_screenshot')"
case "$out" in
  GATE*"G=[]"*"ask IT for Hammerspoon"*) pass "screenshot-fetch-failed-standard-asks-it" ;;
  *) fail "screenshot-fetch-failed-standard-asks-it" "$out" ;;
esac
out="$(shot_unit 'printf "fetch 1" > "$(screenshot_blocked_marker)"; gate_screenshot && echo GATE; echo done')"
same "screenshot-fetch-failed-last-run-retries" "$out" "done"
if [ "$(uname -m)" = arm64 ]; then TERM_WANT='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; else TERM_WANT=''; fi
# bootstrap_find_tool looks in /opt/homebrew/bin by absolute path, so PATH alone cannot hide a brew
out="$(shot_unit 'bootstrap_is_admin() { return 0; }; bootstrap_find_tool() { return 1; }; screenshot_mark_this_run fetch; gesture_screenshot')"
same "screenshot-fetch-failed-admin-gets-homebrew" "$out" "$TERM_WANT"
out="$(shot_unit 'screenshot_struct_ok() { return 0; }; screenshot_running() { return 0; }; screenshot_accessibility() { return 1; }
  echo "G=$(gesture_screenshot)"; note_screenshot')"
case "$out" in
  *Privacy_Accessibility*"only an administrator can turn it on"*) pass "screenshot-accessibility-standard-names-admin" ;;
  *) fail "screenshot-accessibility-standard-names-admin" "$out" ;;
esac

# ── 6. screenshot: the pinned Hammerspoon install, against fixtures ───────────────────────────
TERM_HZIP="$(fixture_zip Hammerspoon.app Hammerspoon org.hammerspoon.Hammerspoon)"
TERM_HSHA="$(/usr/bin/shasum -a 256 "$TERM_HZIP" | cut -d' ' -f1)"
pin_unit() { BOOTSTRAP_SCREENSHOT_HAMMERSPOON_URL="$1" BOOTSTRAP_SCREENSHOT_HAMMERSPOON_SHA256="$2" \
  terminal_unit screenshot 'screenshot_install_pinned >/dev/null 2>&1; echo "rc=$?"'; }
leftovers() { printf '%s' "$(home_apps)$(ls -A "$TERM_H/.mac-bootstrap/tools/downloads" 2>/dev/null | tr '\n' ' ')"; }
out="$(pin_unit "file://$TERM_HZIP" 0000000000000000000000000000000000000000000000000000000000000000)"
if [ "$out" = "rc=2" ] && [ -z "$(leftovers)" ]; then pass "hammerspoon-wrong-sha-refused-leaves-nothing"
else fail "hammerspoon-wrong-sha-refused-leaves-nothing" "$out, left: $(leftovers)"; fi
out="$(pin_unit "file://$TERM_HZIP" "$TERM_HSHA")"            # rc 3, not 2: the sha matched, the bundle was unpacked and assessed
if [ "$out" = "rc=3" ] && [ -z "$(leftovers)" ]; then pass "hammerspoon-gatekeeper-refused-leaves-nothing"
else fail "hammerspoon-gatekeeper-refused-leaves-nothing" "$out, left: $(leftovers)"; fi
out="$(pin_unit "file://$TERM_FX/no-such.zip" "$TERM_HSHA")"
same "hammerspoon-unreachable-is-not-fetched" "$out" "rc=1"

# ── 7. the crash-report switch refuses a sandboxed HOME, and says so ──────────────────────────
TERM_REAL0="$(/usr/bin/defaults read org.hammerspoon.Hammerspoon HSUploadCrashData 2>/dev/null || echo ABSENT)"
out="$(terminal_unit screenshot 'screenshot_hammerspoon_prefs_off; echo "rc=$? changed=$SCREENSHOT_PREFS_CHANGED"' 2>&1)"
case "$out" in
  *Refusing*"rc=1 changed=0"*) pass "hammerspoon-crash-key-refused-in-sandbox" ;;
  *) fail "hammerspoon-crash-key-refused-in-sandbox" "$out" ;;
esac
same "hammerspoon-real-crash-key-untouched" "$(/usr/bin/defaults read org.hammerspoon.Hammerspoon HSUploadCrashData 2>/dev/null || echo ABSENT)" "$TERM_REAL0"
if [ -e "$TERM_H/.mac-bootstrap/screenshot-hammerspoon-before-install" ]; then fail "hammerspoon-refusal-records-nothing"
else pass "hammerspoon-refusal-records-nothing"; fi

# ── 8. egress verbs: well-formed, and what they must and must not say ─────────────────────────
terminal_egress_ok() {                                    # every line: <host> <install|run> <purpose>
  printf '%s\n' "$1" | awk 'NF { if (NF < 3 || ($2 != "install" && $2 != "run")) bad = 1 } END { exit bad }'
}
out="$(terminal_unit pane_equalize 'egress_pane_equalize; echo "rc=$?"')"
same "egress-pane-equalize-is-no-network" "$out" "rc=0"
out="$(terminal_unit screenshot 'egress_screenshot')"
if terminal_egress_ok "$out" && [ -n "$out" ]; then pass "egress-screenshot-well-formed" "$(printf '%s\n' "$out" | grep -c .) host(s)"
else fail "egress-screenshot-well-formed" "$out"; fi
case "$out" in *sentry*) fail "egress-screenshot-no-crash-upload" "$out" ;; *) pass "egress-screenshot-no-crash-upload" ;; esac
case "$out" in *"raw.githubusercontent.com install"*) fail "egress-screenshot-no-raw-fetch" "$out" ;; *) pass "egress-screenshot-no-raw-fetch" ;; esac
case "$out" in *"raw.githubusercontent.com run Hammerspoon update check"*) pass "egress-screenshot-states-update-check" ;; *) fail "egress-screenshot-states-update-check" "$out" ;; esac
out="$(BOOTSTRAP_SCREENSHOT_REPO_URL=https://git.example.com/me/hs.git terminal_unit screenshot 'egress_screenshot')"
case "$out" in *"git.example.com install"*) pass "egress-screenshot-names-your-repo-host" ;; *) fail "egress-screenshot-names-your-repo-host" "$out" ;; esac
