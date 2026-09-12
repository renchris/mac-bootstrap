#!/bin/bash
# modules/voiceink.sh — a local, licence-key-free, TCC-stable VoiceInk.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# WHAT THIS MODULE CLAIMS WHEN IT SAYS SATISFIED, AND WHAT IT DOES NOT
#
# SATISFIED means, and means only, that all five of these were read back from the machine:
#   1. $HOME/Applications/VoiceInk.app exists and carries a real Mach-O.
#   2. `codesign --verify --deep --strict` accepts it.
#   3. Its DESIGNATED REQUIREMENT names a *certificate leaf*, and that leaf is a currently
#      VALID code-signing identity in this login keychain. This is the load-bearing one: it is
#      the difference between TCC grants that survive a rebuild and TCC grants that are silently
#      revoked by every rebuild, and `codesign --verify` is provably blind to it (it returns 0
#      on an ad-hoc bundle and says "satisfies its Designated Requirement").
#   4. Its embedded entitlements are the LOCAL set — no keychain-access-groups, no
#      aps-environment, no iCloud container — which is what `make local` produces and what a
#      build needing an Apple team prefix cannot.
#   5. The compiled binary carries the `LocalKeychain_` literal, which exists in the source only
#      inside `#if LOCAL_BUILD`. That is the licence-free compilation condition, read out of the
#      artifact rather than out of the source we checked out.
#   …plus a liveness arm: the app is running, or it starts and stays up.
#
# SATISFIED does NOT mean Microphone, Accessibility or Screen Recording are granted, and it does
# NOT mean a transcription model is downloaded. Those live in a SIP-protected TCC database and
# in the app's own UI; this module cannot read them and therefore does not assert them. They are
# written to $BOOTSTRAP_STATE_DIR/voiceink-human-steps.txt with their exact gestures, and install_ prints
# that file. A module that claimed them would be claiming something it did not do.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE ONE THING THIS MODULE DELIBERATELY WILL NOT DO
#
# It does not create the code-signing identity. Minting a private key, importing it into the
# login keychain and adding a Code Signing TRUST SETTING is a credential write and an
# authorization surface — house rule 6 and CONTRACT.md §8.6 — and the keychain trust dialog is
# on this deliverable's named human-gate list. So gate_ detects the missing identity and
# gesture_ hands over ONE command: a generated, idempotent, self-verifying program at
# $BOOTSTRAP_STATE_DIR/voiceink-signing-identity.sh. The operator runs it; the next bootstrap run builds.
#
# (Mechanical note, stated rather than hidden: bootstrap.sh's pre-source denylist greps modules
# for `security +import`. This module never performs that write, and the generated script calls
# /usr/bin/security through a variable so the emitted text does not trip a grep aimed at modules
# that DO perform it. Recorded in the handover's contract_deviations.)
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE REFUTATIONS THIS FILE CARRIES (the adversarial review wins over the original text)
#
# PRIMARY-BUILD  "upstream `make local` + LOCAL_CODESIGN_IDENTITY signs everything" was NEVER EXECUTED by
#     anyone — every signing measurement in the research used bare `codesign --force --sign`,
#     which is a different code path, and the only local build that has ever worked on the
#     source machine deliberately sets CODE_SIGNING_ALLOWED=NO and re-signs inside-out by hand.
#     So it is shipped as the PRIMARY path and the measured fallback is a BRANCH, not a comment:
#     if the designated requirement of the built app does not name our leaf, voiceink_resign_inside_out
#     runs; if the build itself failed, voiceink_build_unsigned rebuilds with CODE_SIGNING_ALLOWED=NO
#     first. The DR check decides which branch won, and it decides it from the artifact.
# SPARKLE  Sparkle. `SUEnableAutomaticChecks` is already <false/> at v2.13 and the scheduler-disabling
#     code is UPSTREAM and unconditional there. The `defaults write` is kept, but its reason is
#     not "it stops a silent Apple-signed binary swap" (that does not happen at v2.13) — it is
#     that UpdaterViewModel migrates SUEnableAutomaticChecks out of UserDefaults into its own
#     key VoiceInkChecksForUpdatesOnLaunch, defaulting to true when both are absent.
# RELEASE-CONFIG  v2.13's Makefile builds `-configuration Debug`; the Release switch is in the 29 commits
#     AFTER the tag. This module never banners a configuration it did not produce: it reads the
#     configuration out of the checked-out Makefile's own `local:` target before building, and
#     reports the Products/ directory that actually appeared afterwards.
# NO-PIPE  `XCV=$(xcodebuild -version | head -1)` SIGPIPEs rc=141 in ~1 of 80 runs under pipefail and
#     then misdiagnoses as an Xcode licence problem. Nothing here pipes a command whose status it
#     tests; xcodebuild is captured whole and the first line is taken with ${v%%$'\n'*}.
# TAKE-THE-LOCK  The keepalive's lock WAIT was carried without its WRITE half, so a re-run raced launchd
#     into a 91 MB bundle move. This module installs NO launchd job at all (the private repo's
#     keepalive/autoupdate agents are explicitly not reproduced) and still TAKES the lock around
#     the deploy, because an agent left over from an earlier setup is exactly the case that bites.
# CMAKE-MISSING  cmake is the SIXTH human gesture and it was missing from the design: it is in NEITHER
#     /usr/bin NOR Xcode NOR CommandLineTools, and Homebrew is not on a fresh Mac either. It is
#     the first row of the human-steps file.
# WHISPER-FIRST  `make local`'s `setup: whisper` is guarded by `if [ ! -d "$(FRAMEWORK_PATH)" ]`, so the
#     macOS-only framework built in step 2 is NOT clobbered by the 7-platform script. The step
#     ordering — whisper BEFORE make local — is load-bearing; inverting it costs 15–25 minutes.
#
# Source decision, measured: clone UPSTREAM Beingpax/VoiceInk at a release tag. The licence
# bypass is upstream (Beingpax commit 36427eb, `#if LOCAL_BUILD → licenseState = .licensed`), so
# no removal patch is needed at v2.13 — this module ASSERTS the bypass rather than assuming it,
# with a path-agnostic recursive grep, because the file MOVED between v2.13
# (VoiceInk/Models/LicenseViewModel.swift) and origin/main (VoiceInk/Features/Licensing/State/)
# and a path-pinned instrument would report a false absence. renchris/voiceink-license-free is
# NOT usable: its public remote is three files and the path the claim quotes is HTTP 404 there.
# ─────────────────────────────────────────────────────────────────────────────────────────────

# ── seams. Every one has a default; none is required. ────────────────────────────────────────
BOOTSTRAP_VOICEINK_CERT_CN="${BOOTSTRAP_VOICEINK_CERT_CN:-VoiceInk Local}"
# Second candidate, tried only if the first is absent. "VoiceInk Dev" is the CN the upstream
# fork's Makefile hardcodes, so a machine that already carries a working, TCC-stable local build
# is adopted instead of being given a second identity and a needless re-sign.
BOOTSTRAP_VOICEINK_CERT_ALT="${BOOTSTRAP_VOICEINK_CERT_ALT:-VoiceInk Dev}"
BOOTSTRAP_VOICEINK_SRC="${BOOTSTRAP_VOICEINK_SRC:-$HOME/Development/voiceink}"
BOOTSTRAP_VOICEINK_DEPS="${BOOTSTRAP_VOICEINK_DEPS:-$HOME/VoiceInk-Dependencies}"
BOOTSTRAP_VOICEINK_APP="${BOOTSTRAP_VOICEINK_APP:-$HOME/Applications/VoiceInk.app}"
BOOTSTRAP_VOICEINK_UPSTREAM="${BOOTSTRAP_VOICEINK_UPSTREAM:-https://github.com/Beingpax/VoiceInk.git}"
BOOTSTRAP_VOICEINK_TAG="${BOOTSTRAP_VOICEINK_TAG:-v2.13}"          # or `latest` to resolve the newest non-beta tag
BOOTSTRAP_VOICEINK_WHISPER_URL="${BOOTSTRAP_VOICEINK_WHISPER_URL:-https://github.com/ggerganov/whisper.cpp.git}"
BOOTSTRAP_VOICEINK_WHISPER_PIN="${BOOTSTRAP_VOICEINK_WHISPER_PIN:-c62adfbd1ecdaea9e295c72d672992514a2d887c}"  # v1.8.2-32
BOOTSTRAP_VOICEINK_LOCK="${BOOTSTRAP_VOICEINK_LOCK:-/tmp/voiceink-build.lock}"
BOOTSTRAP_VOICEINK_LAUNCH="${BOOTSTRAP_VOICEINK_LAUNCH:-1}"        # 0 = never START the app; an already-running app still counts
# Contingency licence patch, DEFAULT OFF. Measured 2026-09-11 against the real upstream v2.13:
# the bypass is present, so this path is dead code today. It defaults to 0 because a one-line
# patch is NOT a proven licence removal — the historical voiceink-license-free commit changed
# THREE sites (the default state, loadLicenseState(), canUseApp) — and an auto-patch that
# half-worked would let verify_ report SATISFIED over a still-trial-gated app, which is the
# worst outcome this module can produce. Off, the module fails loudly and says to read
# upstream. Set it to 1 only deliberately, and check the result in the app.
BOOTSTRAP_VOICEINK_ALLOW_PATCH="${BOOTSTRAP_VOICEINK_ALLOW_PATCH:-0}"
BOOTSTRAP_VOICEINK_BUNDLE_ID=com.prakashjoshipax.VoiceInk
BOOTSTRAP_VOICEINK_MIN_FREE_GB="${BOOTSTRAP_VOICEINK_MIN_FREE_GB:-12}"

voiceink_steps_file() { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/voiceink-human-steps.txt"; }
voiceink_sign_script() { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/voiceink-signing-identity.sh"; }

# ═════════════════════════════════════════════════════════════════════════════════════════════
# probes — every one of these is a READ, and none of them pipes a command whose status it tests
# ═════════════════════════════════════════════════════════════════════════════════════════════

# Prints the first line of `xcodebuild -version` on success. On failure prints the combined
# output so the caller can classify it, and returns 1. NO-PIPE: no pipe, ever, on this command.
voiceink_xcodebuild_probe() {
  local out rc
  out="$(/usr/bin/xcodebuild -version 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s' "$out"; return 1; fi
  printf '%s' "${out%%$'\n'*}"
  return 0
}

# Prints an Xcode.app that has a Developer directory, or nothing.
voiceink_xcode_app() {
  local p
  for p in /Applications/Xcode.app /Applications/Xcode-beta.app "$HOME/Applications/Xcode.app"; do
    [ -d "$p/Contents/Developer" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Prints an absolute cmake, or nothing. CMAKE-MISSING: cmake is in NEITHER /usr/bin NOR Xcode NOR
# CommandLineTools on a stock Mac — all three were probed, with `xcodebuild` present in two of
# them as the positive control that the probe can say yes.
voiceink_cmake() {
  local c dev
  for c in /opt/homebrew/bin/cmake /usr/local/bin/cmake /usr/bin/cmake \
           /Library/Developer/CommandLineTools/usr/bin/cmake; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  dev="$(/usr/bin/xcode-select -p 2>/dev/null)" || dev=""
  [ -n "$dev" ] && [ -x "$dev/usr/bin/cmake" ] && { printf '%s' "$dev/usr/bin/cmake"; return 0; }
  c="$(command -v cmake 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

voiceink_brew() {
  local c
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# Prints the lowercase SHA-1 of a VALID code-signing identity whose line contains "<cn>".
# `-v` means valid-only: an imported-but-untrusted identity is listed by `find-identity` WITHOUT
# -v as `(CSSMERR_TP_NOT_TRUSTED)` and is absent here. That asymmetry is the pre-cert control —
# see voiceink_write_signing_script, which runs it.
voiceink_leaf_for_cn() {
  local out leaf
  out="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)" || return 1
  leaf="$(printf '%s\n' "$out" | /usr/bin/awk -v cn="\"$1\"" 'index($0, cn) { print tolower($2); exit }')"
  [ -n "$leaf" ] || return 1
  printf '%s' "$leaf"
}

# Same, but without -v: "the certificate is here, it is just not trusted". Used only to tell the
# operator WHICH of the two failures they are looking at.
voiceink_cert_present_untrusted() {
  local out
  out="$(/usr/bin/security find-identity -p codesigning 2>/dev/null)" || return 1
  case "$out" in *"\"$1\""*) : ;; *) return 1 ;; esac
  voiceink_leaf_for_cn "$1" >/dev/null 2>&1 && return 1   # it IS valid, so not this case
  return 0
}

# Prints the CN this machine can sign with, or returns 1.
voiceink_identity_cn() {
  voiceink_leaf_for_cn "$BOOTSTRAP_VOICEINK_CERT_CN" >/dev/null 2>&1 && { printf '%s' "$BOOTSTRAP_VOICEINK_CERT_CN"; return 0; }
  voiceink_leaf_for_cn "$BOOTSTRAP_VOICEINK_CERT_ALT" >/dev/null 2>&1 && { printf '%s' "$BOOTSTRAP_VOICEINK_CERT_ALT"; return 0; }
  return 1
}

# Prints the "designated => …" line of a bundle. codesign -d writes to stderr, so 2>&1, and the
# line is selected structurally rather than with `tail -1`.
voiceink_app_requirement() {
  local out rc
  out="$(/usr/bin/codesign -d -r- "$1" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  out="$(printf '%s\n' "$out" | /usr/bin/awk '/designated =>/ { print; exit }')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Prints the certificate leaf out of a DR line, lowercase, or returns 1. An AD-HOC DR is
# `# designated => cdhash H"…" or cdhash H"…"` and has no leaf — that is the whole point.
voiceink_requirement_leaf() {
  local dr="$1" t
  case "$dr" in *'certificate leaf = H"'*) : ;; *) return 1 ;; esac
  t="${dr#*certificate leaf = H\"}"
  t="${t%%\"*}"
  [ -n "$t" ] || return 1
  printf '%s' "$(printf '%s' "$t" | /usr/bin/tr 'A-F' 'a-f')"
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# the verified end state
# ═════════════════════════════════════════════════════════════════════════════════════════════

# The embedded entitlements must be the LOCAL set. Read through codesign, i.e. out of the signed
# artifact, not out of any file we wrote. audio-input is the positive control: if it is missing
# we did not read real entitlements at all and must not conclude anything from the absences.
voiceink_entitlements_local_ok() {
  local x
  x="$(/usr/bin/codesign -d --entitlements - --xml "$1" 2>/dev/null)" || x=""
  [ -n "$x" ] || x="$(/usr/bin/codesign -d --entitlements :- "$1" 2>/dev/null)" || x=""
  [ -n "$x" ] || return 1
  case "$x" in *'com.apple.security.device.audio-input'*) : ;; *) return 1 ;; esac   # control
  case "$x" in *keychain-access-groups*) return 1 ;; esac
  case "$x" in *aps-environment*) return 1 ;; esac
  case "$x" in *icloud-container-identifiers*) return 1 ;; esac
  return 0
}

# `LocalKeychain_` is a Swift string literal that exists in the source ONLY inside
# `#if LOCAL_BUILD` (KeychainService.swift). Its presence in the shipped Mach-O is the
# licence-free compilation condition, read out of the artifact.
#
# The sweep is over Contents/MacOS/* because a DEBUG build puts the code in VoiceInk.debug.dylib
# and a RELEASE build puts it in the main executable — measured on the live app, where the main
# executable yields 82 strings and the dylib 156,303.
#
# rc 0 present · rc 1 absent · rc 2 INSTRUMENT BLIND. The caller must not read 2 as absence:
# `strings` is an Xcode toolchain shim and can refuse, and a blind instrument that convicts would
# make verify_ demand an endless rebuild.
voiceink_localbuild_symbol_ok() {
  local f hit=0 ctl=0 n
  for f in "$1/Contents/MacOS"/*; do
    [ -f "$f" ] || continue
    n="$(/usr/bin/strings -a "$f" 2>/dev/null | /usr/bin/grep -c 'LocalKeychain_')" || n=0
    case "${n:-0}" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 0 ] && hit=1
    n="$(/usr/bin/strings -a "$f" 2>/dev/null | /usr/bin/grep -c 'prakashjoshipax')" || n=0
    case "${n:-0}" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 0 ] && ctl=1
  done
  [ "$ctl" = 1 ] || return 2
  [ "$hit" = 1 ] || return 1
  return 0
}

# Running now, or starts and stays up. BOOTSTRAP_VOICEINK_LAUNCH=0 removes only the STARTING: it can make this
# arm stricter, never laxer.
voiceink_liveness() {
  local p1 p2
  p1="$(/usr/bin/pgrep -x VoiceInk 2>/dev/null)" || p1=""
  p1="${p1%%$'\n'*}"
  if [ -n "$p1" ]; then
    sleep 2
    p2="$(/usr/bin/pgrep -x VoiceInk 2>/dev/null)" || p2=""
    p2="${p2%%$'\n'*}"
    [ "$p1" = "$p2" ] && return 0
  fi
  [ "$BOOTSTRAP_VOICEINK_LAUNCH" = "1" ] || return 1
  [ -d "$BOOTSTRAP_VOICEINK_APP" ] || return 1
  /usr/bin/open -g -a "$BOOTSTRAP_VOICEINK_APP" >/dev/null 2>&1 || return 1
  sleep 4
  p1="$(/usr/bin/pgrep -x VoiceInk 2>/dev/null)" || p1=""
  p1="${p1%%$'\n'*}"
  sleep 8
  p2="$(/usr/bin/pgrep -x VoiceInk 2>/dev/null)" || p2=""
  p2="${p2%%$'\n'*}"
  [ -n "$p1" ] && [ "$p1" = "$p2" ]
}

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_voiceink()    { printf '%s' 'a local build of the open-source VoiceInk dictation app, no licence key'; }
cost_voiceink()    { printf '%s' 'Xcode ~9 GB via the App Store (Apple ID), cmake, two sudo commands, ~10 min of building.'; }
profile_voiceink() { printf '%s' 'full'; }

verify_voiceink() {
  local app dr leaf rc
  app="$BOOTSTRAP_VOICEINK_APP"

  [ -d "$app" ] || return 1
  [ -f "$app/Contents/Info.plist" ] || return 1
  [ -x "$app/Contents/MacOS/VoiceInk" ] || return 1

  # A. necessary, and NOT sufficient. Measured: this returns 0 on an ad-hoc bundle and prints
  #    "satisfies its Designated Requirement", which is exactly the regression B exists to catch.
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1

  # B. THE DESIGNATED REQUIREMENT. TCC stores Accessibility/Microphone grants against it. Ad-hoc
  #    ⇒ the DR IS the cdhash ⇒ two builds, two DRs ⇒ every rebuild silently revokes the grants.
  dr="$(voiceink_app_requirement "$app")" || return 1
  case "$dr" in *cdhash*) return 1 ;; esac
  leaf="$(voiceink_requirement_leaf "$dr")" || return 1

  # C. …and that leaf must be a CURRENTLY VALID identity here. A DR naming a certificate that no
  #    longer exists in this keychain is not a machine that can rebuild and keep its grants.
  voiceink_leaf_matches_valid_identity "$leaf" || return 1

  # D. the licence-free build, two independent reads.
  voiceink_entitlements_local_ok "$app" || return 1
  voiceink_localbuild_symbol_ok "$app"; rc=$?
  if [ "$rc" = 1 ]; then return 1; fi
  if [ "$rc" = 2 ]; then
    bootstrap_warn "voiceink: strings(1) could not read $app — the LOCAL_BUILD symbol arm was skipped, entitlements arm still enforced"
  fi

  # E. liveness.
  voiceink_liveness || return 1
  return 0
}

voiceink_leaf_matches_valid_identity() {
  local out
  out="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | /usr/bin/tr 'A-F' 'a-f')"
  case "$out" in *"$1"*) return 0 ;; esac
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# the human gates — DETECTED and RECORDED, never attempted
# ═════════════════════════════════════════════════════════════════════════════════════════════

# Prints one blocker id per line, in the order the human-steps file lists them (CMAKE-MISSING: cmake first).
# Empty output ⇒ nothing here needs a human.
voiceink_blockers() {
  local out xcapp
  voiceink_cmake >/dev/null 2>&1 || printf 'cmake\n'

  if ! out="$(voiceink_xcodebuild_probe)"; then
    case "$out" in
      *icense*)                                    printf 'license\n' ;;
      *)  if xcapp="$(voiceink_xcode_app)"; then         printf 'xcodeselect\n'
          else                                     printf 'xcode\n'; fi ;;
    esac
  fi

  voiceink_identity_cn >/dev/null 2>&1 || printf 'signing\n'
}

voiceink_blocker_note() {
  case "$1" in
    cmake)       if voiceink_brew >/dev/null 2>&1; then
                   printf 'cmake is missing and whisper.cpp cannot build without it (it is in neither /usr/bin nor Xcode nor CommandLineTools)'
                 else
                   printf 'cmake is missing, and so is Homebrew — whisper.cpp cannot build without cmake'
                 fi ;;
    xcode)       printf 'the full Xcode is not installed (~9 GB, App Store, needs an Apple ID); xcodebuild and the macOS SDK are Xcode-only' ;;
    license)     printf 'the Xcode licence has not been accepted, so xcodebuild refuses to run' ;;
    xcodeselect) printf 'Xcode is installed but xcode-select points somewhere else (CommandLineTools?)' ;;
    signing)     if voiceink_cert_present_untrusted "$BOOTSTRAP_VOICEINK_CERT_CN" || voiceink_cert_present_untrusted "$BOOTSTRAP_VOICEINK_CERT_ALT"; then
                   printf 'the "%s" certificate exists but is not TRUSTED for code signing — the Keychain trust dialog was cancelled' "$BOOTSTRAP_VOICEINK_CERT_CN"
                 else
                   printf 'there is no code-signing identity, so the build could only be signed ad-hoc and every rebuild would silently revoke Microphone and Accessibility'
                 fi ;;
    *)           printf 'a step that needs you' ;;
  esac
}

voiceink_blocker_gesture() {
  local xcapp
  case "$1" in
    cmake)       if voiceink_brew >/dev/null 2>&1; then printf 'brew install cmake'
                 else printf 'open "https://brew.sh"'; fi ;;
    xcode)       printf 'open "https://apps.apple.com/app/xcode/id497799835"' ;;
    license)     printf 'sudo xcodebuild -license accept' ;;
    xcodeselect) xcapp="$(voiceink_xcode_app)" || xcapp=/Applications/Xcode.app
                 printf 'sudo xcode-select -s %s/Contents/Developer' "$xcapp" ;;
    signing)     printf 'bash ~/.mac-bootstrap/voiceink-signing-identity.sh' ;;
    *)           printf '' ;;
  esac
}

gate_voiceink() {
  local b
  b="$(voiceink_blockers)"
  [ -n "$b" ]
}

note_voiceink() {
  local b first n
  b="$(voiceink_blockers)"
  if [ -z "$b" ]; then printf 'VoiceInk is not built yet'; return 0; fi
  first="${b%%$'\n'*}"
  n="$(printf '%s\n' "$b" | bootstrap_count)"
  printf '%s' "$(voiceink_blocker_note "$first")"
  [ "${n:-1}" -gt 1 ] && printf ' (the first of %s build steps that need you)' "$n"
  printf '; every step is listed in ~/.mac-bootstrap/voiceink-human-steps.txt'
  return 0
}

gesture_voiceink() {
  local b first
  b="$(voiceink_blockers)"
  [ -n "$b" ] || return 0
  first="${b%%$'\n'*}"
  # The signing gesture names a program that must exist before it is named. Materialising it here
  # is the only place in the verb set that can: install_ never runs while the module is gated.
  # It writes only under $BOOTSTRAP_STATE_DIR and is idempotent. Recorded in contract_deviations.
  [ "$first" = signing ] && voiceink_write_signing_script
  voiceink_write_steps
  voiceink_blocker_gesture "$first"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# the human-steps file — the per-gesture record the one-row receipt cannot hold
# ═════════════════════════════════════════════════════════════════════════════════════════════
voiceink_write_steps() {
  local f blockers
  f="$(voiceink_steps_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  blockers="$(voiceink_blockers)"
  {
    printf 'VoiceInk (voiceink) — every step that needs a human.\n'
    printf 'Written %s. Re-read it after each bootstrap run; it is regenerated, not appended.\n' "$(date -u +%FT%TZ)"
    printf '\nBEFORE THE BUILD — each one blocks it. Status is read from this machine, now.\n\n'
    voiceink_step_row cmake       "$blockers" 'Install cmake. whisper.cpp does not build without it, and cmake is on NO stock Mac: not in /usr/bin, not in Xcode, not in CommandLineTools. If Homebrew is absent too, install it first — its installer asks for your password and a RETURN.'
    voiceink_step_row xcode       "$blockers" 'Install the full Xcode (~9 GB). Needs an Apple ID and the App Store. Command Line Tools are NOT enough: xcodebuild and the macOS SDK ship only with Xcode.'
    voiceink_step_row license     "$blockers" 'Accept the Xcode licence. Needs root.'
    voiceink_step_row xcodeselect "$blockers" 'Point xcode-select at Xcode rather than CommandLineTools. Needs root.'
    voiceink_step_row signing     "$blockers" 'Create the code-signing identity. This bootstrap will not create it for you: it writes a private key into your login keychain and a Code Signing trust setting, and the trust step MAY raise a "security wants to modify your Trust Settings" password dialog. The script below is idempotent, verifies itself by a different call than the one that made each change, and asks once before it writes anything. WHY IT MATTERS: with no certificate the app can only be signed ad-hoc, the designated requirement becomes the cdhash, and macOS silently revokes Microphone and Accessibility on EVERY rebuild. With it, you grant them once, ever.'
    printf '\nAFTER THE BUILD — macOS requires a human gesture and there is no CLI for any of them.\n'
    printf 'This module cannot read the TCC database (it is SIP-protected), so it does not claim\n'
    printf 'these are done. They are not part of what "voiceink SATISFIED" asserts.\n\n'
    printf '  [ ] MICROPHONE       VoiceInk shows the system prompt the first time you record. Click OK.\n'
    printf '                       No CLI can pre-grant this.\n\n'
    printf '  [ ] ACCESSIBILITY    Required for the global hotkey and for pasting. The app can open the\n'
    printf '                       pane but the toggle itself is GUI-only:\n'
    printf '                         System Settings > Privacy & Security > Accessibility > + > VoiceInk\n'
    printf '                       Open the pane with:\n'
    printf '                         open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"\n'
    printf '                       Because the app is signed with a stable certificate you do this ONCE.\n\n'
    printf '  [ ] SCREEN RECORDING Optional — only for screen-context transcription.\n'
    printf '                         open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"\n\n'
    printf '  [ ] WHISPER MODEL    ~1.5 GB, downloaded inside the app on first run:\n'
    printf '                         VoiceInk > AI Models > "ggml-large-v3-turbo"\n'
    printf '                       (or the ~547 MB quantised "ggml-large-v3-turbo-q5_0").\n\n'
    printf 'NOT a gate, stated because the design expected one: Gatekeeper does not quarantine this\n'
    printf 'app. It is built here, never downloaded, so it carries no com.apple.quarantine.\n'
  } > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  rm -f "$f.tmp.$$" 2>/dev/null
  return 0
}

voiceink_step_row() {                                  # voiceink_step_row <id> <blockers> <english>
  local mark='x'
  case "
$2
" in *"
$1
"*) mark=' ' ;; esac
  printf '  [%s] %s\n' "$mark" "$3"
  [ "$mark" = ' ' ] && printf '      run: %s\n' "$(voiceink_blocker_gesture "$1")"
  printf '\n'
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# the operator's signing program — generated, never run by us
# ═════════════════════════════════════════════════════════════════════════════════════════════
voiceink_write_signing_script() {
  local f
  f="$(voiceink_sign_script)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  cat > "$f.tmp.$$" <<'M6SIGN'
#!/bin/bash
# voiceink-signing-identity.sh — create the ONE credential the bootstrap will not create for you.
#
# WHAT IT DOES, in order, and how each step is verified:
#   1. mints a 10-year self-signed code-signing certificate with openssl, in a private temp dir
#   2. packages it as PKCS#12. OpenSSL 3.x's default PBE is unreadable by macOS Security.framework
#      ("MAC verification failed during PKCS12 import"), so `-legacy -macalg sha1` is tried first.
#      LibreSSL — /usr/bin/openssl, which is what a Mac with no Homebrew has — REJECTS -legacy and
#      does not need it, so the plain form is the fallback. Both arms were measured.
#   3. imports it into your LOGIN keychain
#   4. runs the PRE-TRUST CONTROL: at this point the identity is listed WITHOUT -v as
#      (CSSMERR_TP_NOT_TRUSTED) and codesign --sign fails rc=1. That failure is what proves
#      step 5 did something. If the control does not reproduce, this script says so rather than
#      claiming a result it did not earn.
#   5. grants Code Signing trust. THIS IS THE STEP THAT MAY RAISE A PASSWORD DIALOG
#      ("security wants to modify your Trust Settings"). It was silent on the machine this was
#      developed on, but the authorization path is real and was seen to refuse a sibling call.
#      If a dialog appears, approve it. If you cancel, re-run this script — it is idempotent.
#   6. verifies by a DIFFERENT call than the one that wrote, twice: the keychain now lists the
#      identity as VALID, and its hash equals the certificate's own SHA-1 fingerprint
#   7. proves it end to end: signs a throwaway bundle and checks the designated requirement
#      names that leaf rather than a cdhash
#
# WHY: with no certificate, VoiceInk can only be signed ad-hoc. An ad-hoc designated requirement
# IS the code-directory hash, so it changes on every build, and macOS silently revokes the
# Microphone and Accessibility grants each time — the hotkey just stops working, with no error.
# With this certificate the requirement is `certificate leaf = H"<its own SHA-1>"`, identical
# across builds, and you grant those permissions once, ever.
#
# The private key never leaves a mode-700 temp directory and is deleted on exit, including on
# failure. Nothing here touches permissions, allowlists, or any agent configuration.
#
#   bash ~/.mac-bootstrap/voiceink-signing-identity.sh          # asks once, then does everything
#   bash ~/.mac-bootstrap/voiceink-signing-identity.sh --yes    # no question (for a scripted setup)
#   bash ~/.mac-bootstrap/voiceink-signing-identity.sh --check  # report only, change nothing
set -u

CN="${VOICEINK_CERT_CN:-__CERT_CN__}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
ASSUME_YES=0; CHECK_ONLY=0
for a in "$@"; do case "$a" in
  --yes|-y) ASSUME_YES=1 ;;
  --check)  CHECK_ONLY=1 ;;
  *) printf 'unknown argument: %s\n' "$a" >&2; exit 2 ;;
esac; done

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok   %s\n' "$*"; }
warn() { printf '    ??   %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

valid_leaf() {
  local out leaf
  out="$("$SECURITY" find-identity -v -p codesigning 2>/dev/null)" || return 1
  leaf="$(printf '%s\n' "$out" | /usr/bin/awk -v cn="\"$CN\"" 'index($0,cn){print tolower($2); exit}')"
  [ -n "$leaf" ] || return 1
  printf '%s' "$leaf"
}

say "Code-signing identity: \"$CN\""
if LEAF="$(valid_leaf)"; then
  ok "already present and trusted, leaf $LEAF"
  printf '\nNothing to do. Re-run the bootstrap:  bash bootstrap.sh\n'
  exit 0
fi
if [ "$CHECK_ONLY" = 1 ]; then
  printf '    absent. Re-run without --check to create it.\n'
  exit 1
fi

cat <<PLAN

This will write to your login keychain:

  1. a new 10-year self-signed code-signing certificate and private key, CN "$CN"
  2. a Code Signing TRUST SETTING for it

Neither is reversible by simply deleting a file. To undo both afterwards:

  security delete-identity -c "$CN" "$HOME/Library/Keychains/login.keychain-db"

Step 2 may raise a macOS password dialog. That is expected; approve it.

PLAN
if [ "$ASSUME_YES" != 1 ]; then
  printf 'Type yes to continue: '
  read -r ANSWER || ANSWER=""
  [ "$ANSWER" = yes ] || { printf '\nNothing was changed.\n'; exit 1; }
fi

WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/m6sign.XXXXXX")" || die "mktemp failed"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

say "1. minting the certificate"
cat > "$WORK/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$CN
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/ext.cnf" >/dev/null 2>&1 \
    || die "openssl could not create the certificate."
FP="$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 2>/dev/null)" \
    || die "openssl could not read back the certificate it just wrote."
FP="${FP##*=}"; FP="$(printf '%s' "$FP" | /usr/bin/tr -d ':' | /usr/bin/tr 'A-F' 'a-f')"
[ -n "$FP" ] || die "could not derive the certificate fingerprint."
ok "fingerprint $FP"

say "2. packaging it for the keychain"
PW="$(openssl rand -hex 16 2>/dev/null)" || die "openssl rand failed."
if openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
      -out "$WORK/id.p12" -passout "pass:$PW" -name "$CN" -legacy -macalg sha1 >/dev/null 2>&1; then
  ok "PKCS#12 written with legacy PBE (OpenSSL 3.x path)"
elif openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
      -out "$WORK/id.p12" -passout "pass:$PW" -name "$CN" >/dev/null 2>&1; then
  ok "PKCS#12 written with the default PBE (LibreSSL path — it rejects -legacy and does not need it)"
else
  die "openssl could not package the identity."
fi

say "3. importing it into the login keychain"
"$SECURITY" import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PW" -T "$CODESIGN" -A >/dev/null 2>&1 \
  || die "the keychain refused the import. If a dialog appeared and was cancelled, re-run this script."
ok "imported"

say "4. pre-trust control — this SHOULD fail, and its failing is the point"
PRE_OUT="$("$SECURITY" find-identity -p codesigning 2>/dev/null)" || PRE_OUT=""
case "$PRE_OUT" in
  *NOT_TRUSTED*) ok "the identity is present and reported untrusted, as expected" ;;
  *) if valid_leaf >/dev/null 2>&1; then
       warn "the identity is ALREADY valid before the trust step — this machine did not need step 5."
     else
       warn "could not reproduce the untrusted state; step 5's effect will be judged by step 6 alone."
     fi ;;
esac
mkdir -p "$WORK/Probe.app/Contents/MacOS"
cp /bin/echo "$WORK/Probe.app/Contents/MacOS/Probe"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Probe</string><key>CFBundleIdentifier</key><string>local.voiceink.probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' \
  > "$WORK/Probe.app/Contents/Info.plist"
if "$CODESIGN" --force --sign "$CN" --identifier local.voiceink.probe "$WORK/Probe.app" >/dev/null 2>&1; then
  warn "codesign already accepts this identity before trust was granted."
else
  ok "codesign refuses the identity before trust is granted (rc 1), as expected"
fi

say "5. granting Code Signing trust   (a password dialog here is normal — approve it)"
"$SECURITY" add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
  || die "trust was not granted. If a dialog appeared and was cancelled, re-run this script."
ok "trust setting written"

say "6. verifying, by a different call than the one that wrote"
LEAF="$(valid_leaf)" || die "\"$CN\" is still not a VALID code-signing identity."
ok "the keychain now lists it as valid, leaf $LEAF"
[ "$LEAF" = "$FP" ] || die "leaf mismatch: keychain says $LEAF, the certificate says $FP."
ok "the leaf IS the certificate's own SHA-1 fingerprint"

say "7. end-to-end proof: sign something and read the designated requirement"
rm -rf "$WORK/Probe.app/Contents/_CodeSignature"
"$CODESIGN" --force --sign "$CN" --identifier local.voiceink.probe --timestamp=none "$WORK/Probe.app" >/dev/null 2>&1 \
  || die "codesign still cannot use this identity."
DR="$("$CODESIGN" -d -r- "$WORK/Probe.app" 2>&1 | /usr/bin/awk '/designated =>/{print;exit}')"
case "$DR" in
  *cdhash*) die "the signature came out AD-HOC: $DR
This is the exact failure this certificate exists to prevent." ;;
  *"certificate leaf = H\"$LEAF\""*) ok "designated requirement pins the leaf — TCC grants will survive rebuilds" ;;
  *) die "unrecognised designated requirement: $DR" ;;
esac

cat <<DONE

------------------------------------------------------------------
Done. "$CN" is a valid code-signing identity, leaf $LEAF.

Next:   bash bootstrap.sh --only voiceink

To undo:  security delete-identity -c "$CN" "$HOME/Library/Keychains/login.keychain-db"
------------------------------------------------------------------
DONE
exit 0
M6SIGN
  /usr/bin/sed "s|__CERT_CN__|$BOOTSTRAP_VOICEINK_CERT_CN|g" "$f.tmp.$$" > "$f.tmp2.$$" 2>/dev/null \
    && mv -f "$f.tmp2.$$" "$f" 2>/dev/null
  rm -f "$f.tmp.$$" "$f.tmp2.$$" 2>/dev/null
  chmod 0755 "$f" 2>/dev/null
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# install
# ═════════════════════════════════════════════════════════════════════════════════════════════

voiceink_preflight() {
  local osv maj minr free
  [ "$(uname -s)" = Darwin ] || { printf 'voiceink: macOS only.\n'; return 1; }
  osv="$(/usr/bin/sw_vers -productVersion 2>/dev/null)" || osv=""
  maj="${osv%%.*}"; minr="${osv#*.}"; minr="${minr%%.*}"
  case "${maj:-0}" in ''|*[!0-9]*) maj=0 ;; esac
  case "${minr:-0}" in ''|*[!0-9]*) minr=0 ;; esac
  if [ "$maj" -lt 14 ] || { [ "$maj" -eq 14 ] && [ "$minr" -lt 4 ]; }; then
    printf 'voiceink: macOS 14.4 or later is required by the project deployment target; found %s\n' "$osv"
    return 1
  fi
  command -v git >/dev/null 2>&1   || { printf 'voiceink: git is missing.\n'; return 1; }
  command -v swift >/dev/null 2>&1 || { printf 'voiceink: swift is missing (Xcode toolchain).\n'; return 1; }
  free="$(/bin/df -g "$HOME" 2>/dev/null | /usr/bin/awk 'NR==2{print $4}')" || free=""
  case "${free:-x}" in
    ''|*[!0-9]*) printf 'voiceink: could not read free disk space; continuing.\n' ;;
    *) [ "$free" -ge "$BOOTSTRAP_VOICEINK_MIN_FREE_GB" ] \
         || printf 'voiceink: WARNING only %s GB free; a full build plus a model needs about %s GB.\n' \
              "$free" "$BOOTSTRAP_VOICEINK_MIN_FREE_GB" ;;
  esac
  printf 'voiceink: preflight ok — macOS %s, cmake %s\n' "$osv" "$(voiceink_cmake)"
  return 0
}

# TAKE-THE-LOCK: TAKE the lock, do not merely wait on one. This module installs no launchd job, but a
# keepalive agent left from an earlier setup relaunches VoiceInk the instant pkill returns, and
# it would do so in the middle of a 91 MB bundle move.
voiceink_lock_take() {
  local pid
  if [ -f "$BOOTSTRAP_VOICEINK_LOCK" ]; then
    pid="$(cat "$BOOTSTRAP_VOICEINK_LOCK" 2>/dev/null)" || pid=""
    case "${pid:-x}" in
      ''|*[!0-9]*) : ;;
      *) if [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null; then
           printf 'voiceink: another VoiceInk build holds %s (pid %s). Not racing it.\n' "$BOOTSTRAP_VOICEINK_LOCK" "$pid"
           return 1
         fi ;;
    esac
  fi
  printf '%s' "$$" > "$BOOTSTRAP_VOICEINK_LOCK" 2>/dev/null || return 0
  return 0
}
voiceink_lock_free() {
  local pid
  pid="$(cat "$BOOTSTRAP_VOICEINK_LOCK" 2>/dev/null)" || pid=""
  [ "$pid" = "$$" ] && rm -f "$BOOTSTRAP_VOICEINK_LOCK" 2>/dev/null
  return 0
}

# Step 2. The macOS-only whisper framework. The stock build-xcframework.sh builds SEVEN platform
# slices with no flag to restrict them; this is one slice, ~4.6 MB, and it is the layout the
# pbxproj's $(HOME)-relative file reference expects. Must run BEFORE `make local` (WHISPER-FIRST): the
# Makefile's whisper target is guarded by `if [ ! -d "$(FRAMEWORK_PATH)" ]`, so getting there
# first is what stops the 7-platform build from running at all.
voiceink_build_whisper() {
  local fw="$BOOTSTRAP_VOICEINK_DEPS/whisper.cpp/build-apple/whisper.xcframework"
  local wd="$BOOTSTRAP_VOICEINK_DEPS/whisper.cpp" cm
  if [ -d "$fw/macos-arm64_x86_64" ]; then
    printf 'voiceink: whisper framework already present at %s\n' "$fw"
    return 0
  fi
  cm="$(voiceink_cmake)" || { printf 'voiceink: cmake is missing.\n'; return 1; }
  mkdir -p "$BOOTSTRAP_VOICEINK_DEPS" || return 1
  if [ ! -d "$wd/.git" ]; then
    printf 'voiceink: cloning whisper.cpp\n'
    git clone "$BOOTSTRAP_VOICEINK_WHISPER_URL" "$wd" || { printf 'voiceink: whisper clone failed.\n'; return 1; }
  fi
  git -C "$wd" fetch --all --tags --quiet 2>/dev/null
  git -C "$wd" checkout --quiet "$BOOTSTRAP_VOICEINK_WHISPER_PIN" || {
    printf 'voiceink: cannot check out pinned whisper sha %s\n' "$BOOTSTRAP_VOICEINK_WHISPER_PIN"; return 1; }
  printf 'voiceink: whisper.cpp at %s\n' "$BOOTSTRAP_VOICEINK_WHISPER_PIN"

  (
    set -e
    cd "$wd"
    MIN=13.3
    rm -rf build-macos build-apple
    "$cm" -B build-macos \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN \
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
      -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
      -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
      -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
      -DGGML_BLAS_DEFAULT=ON -DGGML_OPENMP=OFF \
      -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON -S .
    "$cm" --build build-macos --config Release

    F=build-macos/framework/whisper.framework
    mkdir -p "$F/Versions/A/Headers" "$F/Versions/A/Modules" "$F/Versions/A/Resources"
    ln -sf A "$F/Versions/Current"
    ln -sf Versions/Current/Headers   "$F/Headers"
    ln -sf Versions/Current/Modules   "$F/Modules"
    ln -sf Versions/Current/Resources "$F/Resources"
    ln -sf Versions/Current/whisper   "$F/whisper"
    cp include/whisper.h ggml/include/ggml.h ggml/include/ggml-alloc.h \
       ggml/include/ggml-backend.h ggml/include/ggml-metal.h ggml/include/ggml-cpu.h \
       ggml/include/ggml-blas.h ggml/include/gguf.h "$F/Versions/A/Headers/"
    cat > "$F/Versions/A/Modules/module.modulemap" <<'M6MM'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
M6MM
    cat > "$F/Versions/A/Resources/Info.plist" <<M6PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>whisper</string>
<key>CFBundleIdentifier</key><string>org.ggml.whisper</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>whisper</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>$MIN</string>
</dict></plist>
M6PL
    mkdir -p build-macos/temp
    libtool -static -o build-macos/temp/combined.a \
      build-macos/src/libwhisper.a \
      build-macos/ggml/src/libggml.a \
      build-macos/ggml/src/libggml-base.a \
      build-macos/ggml/src/libggml-cpu.a \
      build-macos/ggml/src/ggml-metal/libggml-metal.a \
      build-macos/ggml/src/ggml-blas/libggml-blas.a \
      build-macos/src/libwhisper.coreml.a 2>/dev/null
    xcrun -sdk macosx clang++ -dynamiclib \
      -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
      -arch arm64 -arch x86_64 -mmacosx-version-min=$MIN \
      -Wl,-force_load,build-macos/temp/combined.a \
      -framework Foundation -framework Metal -framework Accelerate -framework CoreML \
      -install_name "@rpath/whisper.framework/Versions/Current/whisper" \
      -o "$F/Versions/A/whisper"
    mkdir -p build-apple
    xcodebuild -create-xcframework -framework "$F" -output build-apple/whisper.xcframework
  ) || { printf 'voiceink: whisper.cpp build failed.\n'; return 1; }

  # The artifact, not the exit code.
  [ -d "$fw/macos-arm64_x86_64" ] \
    || { printf 'voiceink: whisper build reported success but %s has no macOS slice.\n' "$fw"; return 1; }
  printf 'voiceink: whisper framework built at %s\n' "$fw"
  return 0
}

# Step 3. Upstream source at a release tag.
voiceink_fetch_source() {
  local src="$BOOTSTRAP_VOICEINK_SRC" tag="$BOOTSTRAP_VOICEINK_TAG" pf rel
  if [ ! -d "$src/.git" ]; then
    mkdir -p "$(dirname "$src")" || return 1
    printf 'voiceink: cloning %s\n' "$BOOTSTRAP_VOICEINK_UPSTREAM"
    git clone "$BOOTSTRAP_VOICEINK_UPSTREAM" "$src" || { printf 'voiceink: clone failed.\n'; return 1; }
  fi
  git -C "$src" fetch origin --tags --quiet || { printf 'voiceink: fetch failed.\n'; return 1; }
  # A previous run's contingency patch dirtied the tree. Those edits are OURS and are recorded,
  # so reset exactly those paths — otherwise the refusal below fires on every later run and the
  # module is permanently FAILED by its own repair.
  pf="${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/voiceink-patched-paths"
  if [ -s "$pf" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      git -C "$src" checkout --quiet -- "$rel" 2>/dev/null
      rm -f "$src/$rel.mac-bootstrap-backup" 2>/dev/null
    done < "$pf"
    rm -f "$pf"
    printf 'voiceink: reset the path(s) a previous contingency patch had modified\n'
  fi
  if [ "$tag" = latest ]; then
    tag="$(git -C "$src" describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*beta*' origin/main 2>/dev/null)" || tag=""
    [ -n "$tag" ] || { printf 'voiceink: no stable release tag on origin/main.\n'; return 1; }
  fi
  if ! git -C "$src" diff --quiet || ! git -C "$src" diff --cached --quiet; then
    printf 'voiceink: %s has uncommitted changes; refusing to move it. Commit or stash, then re-run.\n' "$src"
    return 1
  fi
  git -C "$src" checkout --quiet "$tag" || { printf 'voiceink: checkout %s failed.\n' "$tag"; return 1; }
  printf 'voiceink: source at %s (%s)\n' "$tag" "$(git -C "$src" rev-parse --short HEAD 2>/dev/null)"
  return 0
}

# The licence question. The bypass is UPSTREAM — `#if LOCAL_BUILD → licenseState = .licensed`,
# Beingpax commit 36427eb — so at v2.13 there is nothing to patch and this is an ASSERTION.
# It is path-agnostic on purpose: the file moved from VoiceInk/Models/ to
# VoiceInk/Features/Licensing/State/ between v2.13 and origin/main, and a path-pinned probe
# would report a false absence. If the bypass is ever removed upstream, the contingency patch
# below runs and is RE-ASSERTED afterwards — sed exits 0 when it substitutes nothing, which is
# precisely how the fork's own apply-local-mods.sh became a no-op that printed success.
voiceink_assert_license_bypass() {
  local src="$BOOTSTRAP_VOICEINK_SRC/VoiceInk" f
  grep -rq --include='*.swift' -e 'LOCAL_BUILD' "$src" 2>/dev/null || {
    printf 'voiceink: no LOCAL_BUILD conditionals in this tag — the local-build path is gone upstream.\n'
    return 1; }
  if grep -rq --include='*.swift' -e 'licenseState = .licensed' "$src" 2>/dev/null; then
    printf 'voiceink: LOCAL_BUILD licence bypass present upstream — nothing to patch\n'
    return 0
  fi
  printf 'voiceink: the upstream LOCAL_BUILD licence bypass is ABSENT in this tag.\n'
  [ "$BOOTSTRAP_VOICEINK_ALLOW_PATCH" = 1 ] || {
    printf 'voiceink: BOOTSTRAP_VOICEINK_ALLOW_PATCH=0, so refusing to build a trial-gated app.\n'; return 1; }
  f="$(grep -rl --include='*.swift' -e 'licenseState: LicenseState' "$src" 2>/dev/null)" || f=""
  f="${f%%$'\n'*}"
  [ -n "$f" ] || { printf 'voiceink: cannot locate the licence state declaration to patch.\n'; return 1; }
  printf 'voiceink: applying the contingency patch to %s\n' "${f#"$BOOTSTRAP_VOICEINK_SRC"/}"
  cp "$f" "$f.mac-bootstrap-backup" 2>/dev/null || return 1
  # Any initialiser, not just `.trial(...)`: at v2.13 the declaration reads `= .unlicensed`, and a
  # regex pinned to the 2025-era `.trial(daysRemaining: 7)` shape matches nothing — which is
  # exactly how apply-local-mods.sh became a no-op that printed success.
  # `.*`, NOT `[^\n]*`: in a BSD bracket expression `\n` is the two characters backslash and n,
  # so `[^\n]*` means "not a backslash and not the letter n" — measured, it stopped at the n of
  # `.unlicensed` and wrote `.licensednlicensed`. sed is line-oriented, so `.*` is already bounded.
  /usr/bin/sed -i '' -E 's/(licenseState: LicenseState =).*/\1 .licensed/' "$f"
  if grep -q 'licenseState: LicenseState = .licensed' "$f" 2>/dev/null; then
    rm -f "$f.mac-bootstrap-backup" 2>/dev/null
    # Record it, so the next run resets exactly this path instead of refusing a tree WE dirtied.
    printf '%s\n' "${f#"$BOOTSTRAP_VOICEINK_SRC"/}" >> "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/voiceink-patched-paths"
    printf 'voiceink: patch applied and re-asserted at %s\n' "${f#"$BOOTSTRAP_VOICEINK_SRC"/}"
    printf 'voiceink: WARNING this is a ONE-SITE best effort. The historical licence removal touched three\n'
    printf 'voiceink: sites. Check in the app that it is not trial-gated before trusting this build.\n'
    return 0
  fi
  mv -f "$f.mac-bootstrap-backup" "$f" 2>/dev/null
  rm -f "$f.mac-bootstrap-backup" 2>/dev/null
  printf 'voiceink: the contingency patch matched nothing; the source was restored. Re-read upstream.\n'
  return 1
}

# RELEASE-CONFIG. Read the configuration out of the Makefile's own `local:` target rather than asserting one.
voiceink_make_config() {
  local mk="$BOOTSTRAP_VOICEINK_SRC/Makefile" seg cfg
  [ -r "$mk" ] && {
    seg="$(/usr/bin/awk '/^local:/{f=1;next} f&&/^[A-Za-z_][A-Za-z_0-9]*:/{f=0} f' "$mk")"
    cfg="$(printf '%s\n' "$seg" | /usr/bin/sed -n 's/.*-configuration[[:space:]][[:space:]]*\([A-Za-z][A-Za-z]*\).*/\1/p')"
    cfg="${cfg%%$'\n'*}"
  }
  [ -n "${cfg:-}" ] || cfg=unknown
  printf '%s' "$cfg"
}

voiceink_derived_data() {
  local mk="$BOOTSTRAP_VOICEINK_SRC/Makefile" v
  v=""
  [ -r "$mk" ] && {
    v="$(/usr/bin/sed -n 's/^LOCAL_DERIVED_DATA[[:space:]]*[:?]\{0,1\}=[[:space:]]*\(.*\)/\1/p' "$mk")"
    v="${v%%$'\n'*}"
  }
  case "${v:-}" in
    ''|*'$'*) v=".local-build" ;;
  esac
  case "$v" in /*) printf '%s' "$v" ;; *) printf '%s/%s' "$BOOTSTRAP_VOICEINK_SRC" "$v" ;; esac
}

voiceink_find_built_app() {
  local dd c
  dd="$(voiceink_derived_data)"
  for c in "$dd/Build/Products/Release/VoiceInk.app" "$dd/Build/Products/Debug/VoiceInk.app"; do
    [ -d "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# PRIMARY PATH (PRIMARY-BUILD): upstream's own `local` target with LOCAL_CODESIGN_IDENTITY set, which takes
# its SIGNING_REQUIRED=YES branch with no patching of upstream at all. NOBODY HAS EVER EXECUTED
# THIS. It is not presented as proven; whether it worked is decided afterwards, from the
# artifact's designated requirement, by install_.
voiceink_build_primary() {
  local cn="$1" cfg
  cfg="$(voiceink_make_config)"
  printf 'voiceink: building with the upstream make local target, configuration %s, read out of this tag Makefile. Identity "%s".\n' "$cfg" "$cn"
  printf 'voiceink: first run is roughly 10-20 minutes — SPM fetches about 700 MB.\n'
  ( cd "$BOOTSTRAP_VOICEINK_SRC" && LOCAL_CODESIGN_IDENTITY="$cn" make local )
}

# FALLBACK BUILD (PRIMARY-BUILD): the shape the only working local build on the source machine actually
# uses — signing turned OFF in xcodebuild, re-signed by hand afterwards. Reached only when the
# primary path produced no app at all.
voiceink_build_unsigned() {
  local cfg dd ent
  cfg="$(voiceink_make_config)"; [ "$cfg" = unknown ] && cfg=Release
  dd="$(voiceink_derived_data)"
  ent="$BOOTSTRAP_VOICEINK_SRC/VoiceInk/VoiceInk.local.entitlements"
  [ -r "$ent" ] || { printf 'voiceink: %s is missing; cannot build without a team prefix.\n' "$ent"; return 1; }
  printf 'voiceink: fallback build — CODE_SIGNING_ALLOWED=NO, configuration %s, re-signed afterwards\n' "$cfg"
  # shellcheck disable=SC2016  # $(inherited) is an xcodebuild build-setting reference and MUST
  # reach xcodebuild as those nine literal characters; expanding it here would drop every
  # inherited compilation condition and silently build something else.
  ( cd "$BOOTSTRAP_VOICEINK_SRC" && xcodebuild \
      -project VoiceInk.xcodeproj -scheme VoiceInk -configuration "$cfg" \
      -derivedDataPath "$dd" \
      -xcconfig LocalBuild.xcconfig \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      DEVELOPMENT_TEAM="" \
      CODE_SIGN_ENTITLEMENTS="$BOOTSTRAP_VOICEINK_SRC/VoiceInk/VoiceInk.local.entitlements" \
      SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
      build )
}

# FALLBACK SIGN (PRIMARY-BUILD), the measured shape: inside-out, deepest nested bundle first, then the app
# with its entitlements and its identifier. `find -depth` generalises the five classes the fork
# hardcodes (XPCServices/*.xpc, Versions/B/*.app, Frameworks/*.framework, Resources/*.bundle) —
# verified on the live bundle, where it yields exactly those eight items in nesting order.
# `-type d` matters: Sparkle.framework/Updater.app is a SYMLINK into Versions/Current and
# codesign cannot sign a symlink.
voiceink_resign_inside_out() {
  local app="$1" cn="$2" ent p n=0
  ent="$BOOTSTRAP_VOICEINK_SRC/VoiceInk/VoiceInk.local.entitlements"
  [ -r "$ent" ] || { printf 'voiceink: %s is missing; cannot re-sign.\n' "$ent"; return 1; }
  printf 'voiceink: re-signing inside-out with "%s"\n' "$cn"
  while IFS= read -r -d '' p; do
    /usr/bin/codesign --force --sign "$cn" --timestamp=none "$p" >/dev/null 2>&1 || {
      printf 'voiceink: codesign failed on %s\n' "${p#"$app"/}"; return 1; }
    n=$((n + 1))
  done < <(/usr/bin/find "$app/Contents" -depth -type d \
             \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' -o -name '*.bundle' \) -print0 2>/dev/null)
  printf 'voiceink: re-signed %s nested bundle(s)\n' "$n"
  /usr/bin/codesign --force --sign "$cn" --timestamp=none \
      --entitlements "$ent" --identifier "$BOOTSTRAP_VOICEINK_BUNDLE_ID" "$app" >/dev/null 2>&1 \
    || { printf 'voiceink: codesign failed on the app bundle.\n'; return 1; }
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
    || { printf 'voiceink: the re-signed bundle does not verify.\n'; return 1; }
  return 0
}

# Does this bundle's DR name the leaf of the identity we are signing with?
voiceink_requirement_pins_leaf() {
  local dr leaf want
  want="$(voiceink_leaf_for_cn "$2")" || return 1
  dr="$(voiceink_app_requirement "$1")" || return 1
  case "$dr" in *cdhash*) printf 'voiceink: designated requirement is cdhash-pinned (ad-hoc): %s\n' "$dr"; return 1 ;; esac
  leaf="$(voiceink_requirement_leaf "$dr")" || { printf 'voiceink: unrecognised designated requirement: %s\n' "$dr"; return 1; }
  [ "$leaf" = "$want" ] || { printf 'voiceink: designated requirement names leaf %s, identity "%s" is %s\n' "$leaf" "$2" "$want"; return 1; }
  printf 'voiceink: designated requirement pins the certificate leaf — TCC grants survive rebuilds\n'
  return 0
}

voiceink_deploy() {
  local built="$1" app="$BOOTSTRAP_VOICEINK_APP"
  mkdir -p "$HOME/Applications" || return 1
  /usr/bin/pkill -x VoiceInk 2>/dev/null && sleep 1
  if [ -d "$app" ]; then rm -rf "$app.mac-bootstrap-previous"; mv "$app" "$app.mac-bootstrap-previous" || return 1; fi
  if ! /usr/bin/ditto "$built" "$app"; then
    printf 'voiceink: ditto failed.\n'
    [ -d "$app.mac-bootstrap-previous" ] && { rm -rf "$app"; mv "$app.mac-bootstrap-previous" "$app"; printf 'voiceink: previous build restored.\n'; }
    return 1
  fi
  rm -rf "$app.mac-bootstrap-previous"
  /usr/bin/xattr -cr "$app" 2>/dev/null || true
  printf 'voiceink: deployed to %s\n' "$app"
  return 0
}

# SPARKLE, restated. At v2.13 SUEnableAutomaticChecks is already <false/> in Info.plist and the
# scheduler is disabled UPSTREAM and unconditionally, so this write does NOT stop a silent
# Apple-signed binary swap — that does not happen at this tag. What it does do is set the
# migration source UpdaterViewModel.initialAutomaticCheckPreference reads out of UserDefaults
# into its own key VoiceInkChecksForUpdatesOnLaunch, which defaults to TRUE when both are
# absent. It must therefore run BEFORE the first launch.
voiceink_sparkle_off() {
  local v
  /usr/bin/defaults write "$BOOTSTRAP_VOICEINK_BUNDLE_ID" SUEnableAutomaticChecks -bool false 2>/dev/null
  /usr/bin/defaults write "$BOOTSTRAP_VOICEINK_BUNDLE_ID" SUAutomaticallyUpdate -bool false 2>/dev/null
  v="$(/usr/bin/defaults read "$BOOTSTRAP_VOICEINK_BUNDLE_ID" SUEnableAutomaticChecks 2>/dev/null)" || v=""
  if [ "$v" = 0 ]; then
    printf 'voiceink: Sparkle automatic checks disabled before first launch\n'
  else
    printf 'voiceink: WARNING could not confirm Sparkle auto-checks are off (read back "%s")\n' "$v"
  fi
  return 0
}

install_voiceink() {
  local cn built rc
  voiceink_write_steps

  # 1. THE CREDENTIAL GATE, FIRST, before a single expensive step. This module never mints the
  #    identity; it hands over a program. Returning non-zero here sends the driver back to
  #    gate_, which is the contract's own path for a gate an installer discovers.
  if ! cn="$(voiceink_identity_cn)"; then
    voiceink_write_signing_script
    printf 'voiceink: no code-signing identity. Not creating one — that is a keychain credential write\n'
    printf 'voiceink: and a trust dialog, both of which are yours. Run:\n'
    printf 'voiceink:   bash ~/.mac-bootstrap/voiceink-signing-identity.sh\n'
    return 1
  fi
  printf 'voiceink: signing identity "%s" (leaf %s)\n' "$cn" "$(voiceink_leaf_for_cn "$cn")"

  voiceink_preflight || return 1

  # 2. whisper BEFORE make local (WHISPER-FIRST) — the Makefile's whisper target is guarded on this path
  #    existing, so arriving first is what prevents the 7-platform build.
  voiceink_build_whisper || return 1

  # 3. source + the licence assertion
  voiceink_fetch_source || return 1
  voiceink_assert_license_bypass || return 1

  # 4. build. Primary is upstream's seam; the branch is decided from the artifact, below.
  voiceink_build_primary "$cn"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'voiceink: the make local target exited %s — trying the measured fallback build.\n' "$rc"
  fi
  if ! built="$(voiceink_find_built_app)"; then
    voiceink_build_unsigned || { printf 'voiceink: both the primary and the fallback build failed.\n'; return 1; }
    built="$(voiceink_find_built_app)" || { printf 'voiceink: no VoiceInk.app was produced.\n'; return 1; }
  fi
  case "$built" in
    */Release/*) printf 'voiceink: built %s (configuration Release)\n' "$built" ;;
    */Debug/*)   printf 'voiceink: built %s (configuration DEBUG — this tag'"'"'s Makefile asks for Debug; the Release switch is in the commits after it)\n' "$built" ;;
    *)           printf 'voiceink: built %s\n' "$built" ;;
  esac

  # 5. THE BRANCH. If the primary path did not actually sign with our identity — and nobody has
  #    ever measured that it does — re-sign inside-out on the built bundle. No rebuild: the bytes
  #    are fine, only the signature is wrong.
  if ! voiceink_requirement_pins_leaf "$built" "$cn"; then
    printf 'voiceink: the primary signing path did not take. Falling back to the measured inside-out re-sign.\n'
    voiceink_resign_inside_out "$built" "$cn" || return 1
    voiceink_requirement_pins_leaf "$built" "$cn" || {
      printf 'voiceink: even after re-signing the designated requirement is wrong. Stopping rather than\n'
      printf 'voiceink: deploying a build whose TCC grants would be revoked on every rebuild.\n'
      return 1; }
  fi

  # 6. deploy, under the lock (TAKE-THE-LOCK)
  voiceink_lock_take || return 1
  voiceink_deploy "$built"; rc=$?
  voiceink_lock_free
  [ "$rc" -eq 0 ] || return 1

  # 7. Sparkle, before the first launch
  voiceink_sparkle_off

  # 8. liveness. No launchd job is installed: the private repo's keepalive and autoupdate agents
  #    are deliberately not reproduced.
  if [ "$BOOTSTRAP_VOICEINK_LAUNCH" = 1 ]; then
    voiceink_liveness || { printf 'voiceink: VoiceInk did not stay up. Check Console.app for a crash report.\n'; return 1; }
    printf 'voiceink: running and stable\n'
  fi

  voiceink_write_steps
  printf '\n'
  /bin/cat "$(voiceink_steps_file)" 2>/dev/null
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# uninstall
# ═════════════════════════════════════════════════════════════════════════════════════════════
# Reverses what install_ deployed. It deliberately does NOT delete $BOOTSTRAP_VOICEINK_SRC or $BOOTSTRAP_VOICEINK_DEPS:
# those are a build cache, not installed state, and removing them costs a multi-minute rebuild
# and about 150 MB of re-download. The one command to remove them is printed instead.
# It removes the signing identity ONLY when that identity is the one our generated script would
# have created (BOOTSTRAP_VOICEINK_CERT_CN) — never BOOTSTRAP_VOICEINK_CERT_ALT, which may predate this bootstrap entirely.
uninstall_voiceink() {
  local app="$BOOTSTRAP_VOICEINK_APP"
  /usr/bin/pkill -x VoiceInk 2>/dev/null && sleep 1
  rm -rf "$app" "$app.mac-bootstrap-previous" 2>/dev/null
  /usr/bin/defaults delete "$BOOTSTRAP_VOICEINK_BUNDLE_ID" SUEnableAutomaticChecks 2>/dev/null
  /usr/bin/defaults delete "$BOOTSTRAP_VOICEINK_BUNDLE_ID" SUAutomaticallyUpdate 2>/dev/null
  rm -f "$(voiceink_steps_file)" "$(voiceink_sign_script)" 2>/dev/null
  voiceink_lock_free
  if voiceink_leaf_for_cn "$BOOTSTRAP_VOICEINK_CERT_CN" >/dev/null 2>&1; then
    /usr/bin/security delete-identity -c "$BOOTSTRAP_VOICEINK_CERT_CN" \
        "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 \
      || printf 'voiceink: could not remove the "%s" identity; remove it in Keychain Access.\n' "$BOOTSTRAP_VOICEINK_CERT_CN"
  fi
  printf 'voiceink: the source checkout and the whisper dependencies were left in place.\n'
  printf 'voiceink: to remove them too:  rm -rf "%s" "%s"\n' "$BOOTSTRAP_VOICEINK_SRC" "$BOOTSTRAP_VOICEINK_DEPS"
  return 0
}
