#!/bin/bash
# pane_equalize — Cmd+Shift+E evens out split panes, in kitty AND iTerm2.
#
# SOURCED, never executed. Six verbs, no top-level side effects (CONTRACT.md §1).
#
# WHAT THE END STATE IS, stated so verify_ can be read against it:
#   iTerm2 — ~/Library/Preferences/com.googlecode.iterm2.plist carries
#            NSUserKeyEquivalents:"Arrange Split Panes Evenly" = "@$e" (= Cmd+Shift+E), and
#            NSUserKeyEquivalents:"Show Timestamps" exists and does NOT hold "@$e", because
#            Show Timestamps is the stock occupant of that chord.
#   kitty  — the config kitty itself resolves has `splits` as its FIRST (default) layout and
#            binds cmd+shift+e to `layout_action equalize`.
# Zero permissions, zero GUI clicking, zero agent involvement. The iTerm2 half takes effect at
# the NEXT iTerm2 launch: a write made while iTerm2 is running survives its quit, but the
# running instance ignores it (measured 2026-09-11, iTerm2 3.6.11 / macOS 15.7.9).
#
# ── THE THREE CORRECTIONS THIS MODULE SHIPS. Do not "fix" any of them back. ──────────────────
#
# EMPTY-STRING-CLEARS  AN EMPTY STRING DOES CLEAR AN INCUMBENT BINDING. The original design displaced
#     `Show Timestamps` onto Ctrl+Cmd+E because it had measured `""` as inert. That measurement
#     does not reproduce: writing {Arrange Split Panes Evenly: "@$e", Show Timestamps: ""} in
#     one dict write and restarting yields the binding live, with Use Selection for Find (E/0),
#     Render Selection Natively (E/2) and Clear Find (E/3) all preserved — 2 of 2 reproductions
#     with a reversion control between them. So we write the simple form and consume no second
#     chord. verify_ accepts ANY value there except "@$e", so an operator who prefers to keep a
#     shortcut on Show Timestamps (say "@^e", separately proven to work) is not fought with.
#
# NO-STRINGS-BINARY  THE CAPABILITY PROBE MAY NOT USE `strings`. /usr/bin/strings shares an inode with
#     /usr/bin/nm and is the xcode-select SHIM: on a Mac with no Xcode and no Command Line
#     Tools — i.e. the target — it pops the "install the command line developer tools" GUI
#     dialog or fails, and a probe that then reports "this iTerm2 has no such menu item" is a
#     false diagnosis pointing at the wrong subsystem. `LC_ALL=C grep -qa` on the app binary is
#     base-system BSD grep: no developer tools, no dialog. Both arms are measured, and the
#     NEGATIVE arm is re-run inside verify_ on every call, so the instrument must prove it can
#     still say no before its yes is believed.
#
# EQUALIZE-ON-WINDOW-CLOSE  THE KITTY OPTION IS `equalize_on_window_close`, NOT `equalize_on_close`. kitty 0.48.2's
#     own shipped layouts.rst.txt names the wrong one, and kitty accepts the bad spelling with
#     NO config error while leaving the option off — a silent no-op.
#
# ── AND THE THIRD KEYMAP STORE, which is the one failure mode that produces a bound-looking,
#    dead key. iTerm2 records the SHIFTED character, so Cmd+Shift+E is `0x45-0x120000`, and a
#    PROFILE Keyboard Map entry (or a DynamicProfile, re-read at every launch) BEATS the menu
#    key equivalent — measured with a control: with the entry present the menu item reads
#    `enabled=true char=E mods=1` and the key does nothing; remove it and the same keystroke
#    equalizes. We DETECT and REPORT that; we never remove it. Which of the two meanings owns
#    Cmd+Shift+E is the operator's call, not a technical one.
#
# ── THE TWO HOLES this module is required to close ───────────────────────────────────────────
#   (a) NOTHING INSTALLS A TERMINAL. A genuinely fresh Mac has Terminal.app and nothing else,
#       so "configured nothing" must NOT exit 0. With neither kitty nor iTerm2 present, gate_
#       fires. Installing a whole terminal to satisfy a key binding is the person's call, not
#       this module's, so install_ never does it; the receipt carries ONE command instead. An
#       administrator who has Homebrew gets the cask. Anyone else — above all a standard user,
#       for whom `brew` and /Applications are both out of reach — gets a one-line fetch of
#       iTerm2's official release into $HOME/Applications that checks the sha256 pinned here and
#       Gatekeeper's verdict BEFORE anything lands (measured 2026-09-15: the 3.7.1 zip's sha256
#       equals the Homebrew cask's; unpacked it carries no quarantine flag and `spctl -a -vv`
#       says "accepted, source=Notarized Developer ID"; iTerm2's LetsMove counts ~/Applications
#       as installed, so it does not ask to move itself). A too-old kitty gets the same, from its
#       pinned dmg (0.48.2, same three measurements). Test seams, module-scoped:
#       BOOTSTRAP_PANE_EQUALIZE_ITERM_URL / _SHA256 replace the iTerm2 pin in the printed command.
#   (b) verify_ IS PLIST-ONLY (plus kitty's own config parser). The geometry read — `kitty @ ls`
#       columns, or AppleScript `columns of session` — needs Accessibility AND an Apple Events
#       automation consent that no gate here covers, so it is not in verify_ at any price. It is
#       a one-line human observation, logged by install_ and repeated at the end of this header:
#           open iTerm2, split the pane twice, drag a divider, press Cmd+Shift+E.
#
# ── A TRADE-OFF WORTH NAMING, because it is visible and deliberate ───────────────────────────
# The driver evaluates gate_ before install_, so ANY gate suppresses the whole install — a
# too-old iTerm2 blocks the kitty half too. One module holds one state, so the alternative is
# to configure what we can and say nothing about the rest, and a silent SATISFIED over a
# terminal we did not touch is the worst outcome available here. The recovery is one command
# and one re-run. On the target — a fresh Mac — the only reachable gate is hole (a).
#
# ── WRITERS ──────────────────────────────────────────────────────────────────────────────────
# `bootstrap_settings_merge` is the one writer for JSON settings files; neither file here is one
# (a binary plist and a kitty text config), and it refuses anything whose first byte is not `{`.
# The plist is written with PlistBuddy and read back with plutil through `bootstrap_settings_get` —
# two different engines by construction. kitty's config is written as text and read back by
# KITTY'S OWN PARSER, which is what makes the read-back independent rather than a grep for a
# phrase we just wrote.

PANE_EQUALIZE_MARK_BEGIN='# >>> mac-bootstrap pane_equalize >>>'
PANE_EQUALIZE_MARK_END='# <<< mac-bootstrap pane_equalize <<<'
PANE_EQUALIZE_KEY_EQUIVALENTS='@$e'                                    # single quotes: this is literal, not $e
PANE_EQUALIZE_ITERM_SELECTOR='arrangeSplitPanesEvenly:'
PANE_EQUALIZE_ITERM_BOGUS='definitelyNotASelector_zzz:'      # the negative arm of the capability probe
PANE_EQUALIZE_ITERM_ARRANGE='Arrange Split Panes Evenly'
PANE_EQUALIZE_ITERM_TIMESTAMPS='Show Timestamps'
PANE_EQUALIZE_ITERM_CHORD='0x45-0x120000'                    # Cmd+Shift+E as iTerm2 records it
PANE_EQUALIZE_KITTY_FLOOR='0.47.2'                           # first release with `layout_action equalize`
PANE_EQUALIZE_PLISTBUDDY='/usr/libexec/PlistBuddy'
PANE_EQUALIZE_ITERM_URL='https://iterm2.com/downloads/stable/iTerm2-3_7_1.zip'
PANE_EQUALIZE_ITERM_SHA256='ed5c0f623e584cddc123f87d8bda90cf4d1d18dbbae2b9b0e85939f989c640b0'
PANE_EQUALIZE_KITTY_URL='https://github.com/kovidgoyal/kitty/releases/download/v0.48.2/kitty-0.48.2.dmg'
PANE_EQUALIZE_KITTY_SHA256='f804f58ee4b69c76f84eb3281e140748269a63f3f4a816015a8dec2a06d2b195'

# ── small helpers ────────────────────────────────────────────────────────────────────────────

# pane_equalize_ver_ge <have> <want> — dotted numeric compare, three components, bash 3.2.
# 🚨 The padding is built into a VARIABLE first, and that is the whole bug this cost. Word
# splitting applies only to the EXPANDED part of a word, never to literal text beside it, so
# `H=(${1}.0.0)` with IFS='.' splits "0.47.1" into 0,47 and then glues the literal ".0.0" onto
# the last field: H=(0 47 1.0.0). The third field then fails the digit test, both sides default
# to 0, and EVERY comparison that turns on the patch component returns "new enough" — 0.47.1,
# 0.47.0 and 0.47.3 all read >= 0.47.2. Found by running the fixtures, not by reading the line.
pane_equalize_ver_ge() {
  local i=0 hv wv oldifs hs ws
  local -a H W
  hs="${1:-0}.0.0"; ws="${2:-0}.0.0"
  oldifs="$IFS"; IFS='.'
  # shellcheck disable=SC2206  # deliberate word split on '.', values are digits
  H=($hs)
  # shellcheck disable=SC2206
  W=($ws)
  IFS="$oldifs"
  while [ "$i" -lt 3 ]; do
    hv="${H[$i]}"; wv="${W[$i]}"
    case "$hv" in ''|*[!0-9]*) hv=0 ;; esac
    case "$wv" in ''|*[!0-9]*) wv=0 ;; esac
    [ "$hv" -gt "$wv" ] && return 0
    [ "$hv" -lt "$wv" ] && return 1
    i=$((i + 1))
  done
  return 0
}

# pane_equalize_probe_field <text> <key> — prints the value of a KEY=VALUE line, rc 1 if absent.
pane_equalize_probe_field() {
  local line k="${2:-}"
  while IFS= read -r line; do
    case "$line" in
      "$k="*) printf '%s' "${line#"$k"=}"; return 0 ;;
    esac
  done <<EOF
${1:-}
EOF
  return 1
}

# ── iTerm2 ───────────────────────────────────────────────────────────────────────────────────

pane_equalize_iterm_app() { bootstrap_find_app iTerm.app; }  # prints the app bundle, rc 1 if absent
pane_equalize_iterm_plist() { printf '%s' "$HOME/Library/Preferences/com.googlecode.iterm2.plist"; }
pane_equalize_iterm_dyndir() { printf '%s' "$HOME/Library/Application Support/iTerm2/DynamicProfiles"; }

# pane_equalize_iterm_capable <app> — does THIS build ship the menu item? NO-STRINGS-BINARY: base-system grep only.
# The bogus-selector arm runs every time: if a grep for a selector that cannot exist ever
# SUCCEEDS, the instrument is broken and its yes means nothing.
pane_equalize_iterm_capable() {
  local bin="${1:-}/Contents/MacOS/iTerm2"
  [ -f "$bin" ] || return 1
  LC_ALL=C grep -qa "$PANE_EQUALIZE_ITERM_BOGUS" "$bin" 2>/dev/null && {
    bootstrap_warn "pane_equalize: the iTerm2 selector probe matched a selector that cannot exist; not trusting it"
    return 1
  }
  LC_ALL=C grep -qa "$PANE_EQUALIZE_ITERM_SELECTOR" "$bin" 2>/dev/null
}

# pane_equalize_conflict — prints "dyn <path>" or "plist", rc 0 when something else already owns the
# chord. Structural, not textual: exact plutil keypaths for the profile and global key maps.
# A DynamicProfile is JSON text and is matched on the quoted key, which is the only shape the
# chord takes in one. DynamicProfiles are checked FIRST: they are re-read at every launch, so
# clearing the prefs plist alone would not stick.
pane_equalize_conflict() {
  local p d j i=0
  d="$(pane_equalize_iterm_dyndir)"
  if [ -d "$d" ]; then
    for j in "$d"/*; do
      [ -f "$j" ] || continue
      LC_ALL=C grep -qa "\"$PANE_EQUALIZE_ITERM_CHORD\"" "$j" 2>/dev/null && { printf 'dyn %s' "$j"; return 0; }
    done
  fi
  p="$(pane_equalize_iterm_plist)"
  [ -f "$p" ] || return 1
  bootstrap_settings_type "$p" "GlobalKeyMap.$PANE_EQUALIZE_ITERM_CHORD" >/dev/null 2>&1 && { printf 'plist'; return 0; }
  while [ "$i" -lt 64 ]; do
    bootstrap_settings_type "$p" "New Bookmarks.$i" >/dev/null 2>&1 || break
    bootstrap_settings_type "$p" "New Bookmarks.$i.Keyboard Map.$PANE_EQUALIZE_ITERM_CHORD" >/dev/null 2>&1 \
      && { printf 'plist'; return 0; }
    i=$((i + 1))
  done
  return 1
}

# pane_equalize_iterm_verify — the read-back. plutil via bootstrap_settings_get; PlistBuddy wrote it.
# 🚨 MEASURED, and the reason every plist read here passes `raw` rather than taking
# bootstrap_settings_get's DEFAULT of `json`: plutil serialises the WHOLE FILE to the destination
# format before it extracts, so one value anywhere in the plist that JSON cannot represent
# fails the extraction of an unrelated, purely-string key:
#     $ plutil -extract NSUserKeyEquivalents json -o - ~/Library/Preferences/com.googlecode.iterm2.plist
#     …: invalid object in plist for destination format          rc=1
#     $ plutil -extract NSUserKeyEquivalents raw  -o - …          rc=0  (and xml1 too)
# A real iTerm2 plist carries a <date> (line 4877 of 4909 on the source machine) and the
# minimal reproduction is a <data> blob: add one to a two-key fixture and the same json
# extract flips from `{"Select Next Tab":"@]"}` rc 0 to that sentence, rc 1. So `json` here
# would be a permanent, file-wide false negative that names the key it was not about — and for
# the same reason bootstrap_json_ok, which runs `plutil -convert json`, must never be pointed at this
# file. `raw` is right for these values anyway: they are scalars, and plutil cannot render a
# top-level scalar as JSON at all (bootstrap-lib.sh's own trap 5).
pane_equalize_iterm_verify() {
  local p v rc
  p="$(pane_equalize_iterm_plist)"
  [ -f "$p" ] || return 1
  v="$(bootstrap_settings_get "$p" "NSUserKeyEquivalents.$PANE_EQUALIZE_ITERM_ARRANGE" raw)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ "$v" = "$PANE_EQUALIZE_KEY_EQUIVALENTS" ] || return 1
  # The stock occupant must have been vacated. Absent means it still holds Cmd+Shift+E.
  v="$(bootstrap_settings_get "$p" "NSUserKeyEquivalents.$PANE_EQUALIZE_ITERM_TIMESTAMPS" raw)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ "$v" = "$PANE_EQUALIZE_KEY_EQUIVALENTS" ] && return 1
  return 0
}

# pane_equalize_plist_set <plist> <menu item title> <key equivalent>
pane_equalize_plist_set() {
  local p="${1:-}" k="${2:-}" v="${3:-}"
  "$PANE_EQUALIZE_PLISTBUDDY" -c "Add :NSUserKeyEquivalents:'$k' string '$v'" "$p" >/dev/null 2>&1 && return 0
  "$PANE_EQUALIZE_PLISTBUDDY" -c "Set :NSUserKeyEquivalents:'$k' '$v'" "$p" >/dev/null 2>&1
}

pane_equalize_is_bplist() {
  local h
  h="$(LC_ALL=C head -c 8 "${1:-}" 2>/dev/null)" || return 1
  [ "$h" = "bplist00" ]
}

# pane_equalize_iterm_install — PlistBuddy writes; the format is restored afterwards. PlistBuddy rewrites
# a BINARY plist as XML (measured), and while both are valid plists that cfprefsd and iTerm2
# read either way, silently changing the format of a file the operator owns is not ours to do.
# File mode is preserved by PlistBuddy (measured: 600 in, 600 out).
pane_equalize_iterm_install() {
  local p was_bin=0
  p="$(pane_equalize_iterm_plist)"
  pane_equalize_iterm_verify && return 0                    # already correct: do not open it for writing
  mkdir -p "$(dirname "$p")" 2>/dev/null
  bootstrap_backup "$p"
  [ -f "$p" ] && pane_equalize_is_bplist "$p" && was_bin=1
  "$PANE_EQUALIZE_PLISTBUDDY" -c "Add :NSUserKeyEquivalents dict" "$p" >/dev/null 2>&1   # rc 1 if it exists
  pane_equalize_plist_set "$p" "$PANE_EQUALIZE_ITERM_ARRANGE" "$PANE_EQUALIZE_KEY_EQUIVALENTS" || {
    bootstrap_warn "pane_equalize: could not write NSUserKeyEquivalents:$PANE_EQUALIZE_ITERM_ARRANGE"; return 1; }
  # EMPTY-STRING-CLEARS: "" vacates the chord. Only write it if the incumbent still holds Cmd+Shift+E — an
  # operator who moved it somewhere else is left alone.
  local cur rc
  cur="$(bootstrap_settings_get "$p" "NSUserKeyEquivalents.$PANE_EQUALIZE_ITERM_TIMESTAMPS" raw)"; rc=$?
  if [ "$rc" -ne 0 ] || [ "$cur" = "$PANE_EQUALIZE_KEY_EQUIVALENTS" ]; then
    pane_equalize_plist_set "$p" "$PANE_EQUALIZE_ITERM_TIMESTAMPS" '' || {
      bootstrap_warn "pane_equalize: could not vacate Cmd+Shift+E from $PANE_EQUALIZE_ITERM_TIMESTAMPS"; return 1; }
  fi
  [ "$was_bin" = 1 ] && "$BOOTSTRAP_PLUTIL" -convert binary1 "$p" >/dev/null 2>&1
  return 0
}

pane_equalize_iterm_uninstall() {
  local p v rc was_bin=0
  p="$(pane_equalize_iterm_plist)"
  [ -f "$p" ] || return 0
  pane_equalize_is_bplist "$p" && was_bin=1
  v="$(bootstrap_settings_get "$p" "NSUserKeyEquivalents.$PANE_EQUALIZE_ITERM_ARRANGE" raw)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$v" = "$PANE_EQUALIZE_KEY_EQUIVALENTS" ]; then
    bootstrap_backup "$p"
    "$PANE_EQUALIZE_PLISTBUDDY" -c "Delete :NSUserKeyEquivalents:'$PANE_EQUALIZE_ITERM_ARRANGE'" "$p" >/dev/null 2>&1
  fi
  # Only our own value comes out. If they put a real shortcut there, it is theirs now.
  v="$(bootstrap_settings_get "$p" "NSUserKeyEquivalents.$PANE_EQUALIZE_ITERM_TIMESTAMPS" raw)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$v" ]; then
    bootstrap_backup "$p"
    "$PANE_EQUALIZE_PLISTBUDDY" -c "Delete :NSUserKeyEquivalents:'$PANE_EQUALIZE_ITERM_TIMESTAMPS'" "$p" >/dev/null 2>&1
  fi
  [ "$was_bin" = 1 ] && "$BOOTSTRAP_PLUTIL" -convert binary1 "$p" >/dev/null 2>&1
  return 0
}

# ── kitty ────────────────────────────────────────────────────────────────────────────────────

pane_equalize_kitty_bin() {
  local c
  c="$(command -v kitty 2>/dev/null)" || c=""
  [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  c="$(bootstrap_find_app kitty.app)" || return 1
  [ -x "$c/Contents/MacOS/kitty" ] || return 1
  printf '%s' "$c/Contents/MacOS/kitty"
}

pane_equalize_kitty_ver() {                                 # prints "0.48.2", rc 1 if unreadable
  local out v
  out="$("${1:-kitty}" --version 2>/dev/null)" || return 1
  # "kitty 0.48.2 created by Kovid Goyal" — taken with parameter expansion rather than
  # `set -- $out`, which would word-split (and glob-expand) whatever the binary chose to print.
  v="${out#* }"; v="${v%% *}"
  case "$v" in ''|*[!0-9.]*) return 1 ;; esac
  printf '%s' "$v"
}

# pane_equalize_kitty_refused <kitty> — rc 0 when this Mac REFUSES TO EXECUTE kitty, as opposed to a kitty
# that ran and printed no version: 126 is execve refused (Santa and other binary-authorization tools
# answer EPERM), 137 is SIGKILL at exec, how the kernel's code-signing enforcement answers (measured:
# a malformed Mach-O comes back 137 with no output). Asked only after the version read failed.
pane_equalize_kitty_refused() {
  local rc
  "${1:-kitty}" --version >/dev/null 2>&1; rc=$?
  [ "$rc" = 126 ] || [ "$rc" = 137 ]
}

# pane_equalize_signer <path> — who signed it, in the terms an allowlist rule is written in (Santa's
# rules are TEAMID, SIGNINGID, CERTIFICATE, BINARY and CDHASH). codesign reads, never executes, so a
# refused binary still answers; CDHash is printed only at -dvvv.
pane_equalize_signer() {
  local out v
  out="$(/usr/bin/codesign -dvvv "${1:-}" 2>&1)" || out=""
  v="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -1)"
  case "$v" in ''|'not set') : ;; *) printf 'Developer ID team %s' "$v"; return 0 ;; esac
  v="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^CDHash=//p' | /usr/bin/head -1)"
  [ -n "$v" ] && { printf 'the code with cdhash %s (it has no Team ID)' "$v"; return 0; }
  printf 'nothing by signer: %s is not signed' "${1:-}"
}

pane_equalize_kitty_ver_ok() {
  local v
  v="$(pane_equalize_kitty_ver "${1:-}")" || return 1
  pane_equalize_ver_ge "$v" "$PANE_EQUALIZE_KITTY_FLOOR"
}

# The probe. kitty's OWN parser answers three arms in one process:
#   CTL  a config we wrote here that certainly carries the binding  → must say yes
#   NEG  an empty config                                            → must say no
#   USR  the config kitty actually resolves for this HOME           → the answer
# Without CTL and NEG a "no" from USR could be an instrument that cannot say yes and a "yes"
# an instrument that cannot say no; kitty's internals are not a stable API and this is what
# keeps a rename from silently becoming a verdict about the machine.
# `layout_action equalize` is a SPLITS-LAYOUT action — measured, it is a silent rc-0 no-op in
# tall, grid and stack — so the test is that splits is the FIRST (default) layout, not merely
# that it is enabled: a kitty with NO config at all enables all seven layouts, which would make
# "splits is enabled" a green on a machine where the key does nothing.
pane_equalize_kitty_py() {
  # 🚨 MEASURED, and the reason this probe has no `def` in it: `kitty +runpy` exec's the code
  # inside a FUNCTION body, not at module scope — `globals() is locals()` is False — so a
  # function defined here cannot see a module-level import and dies with
  # `NameError: name 'load_config' is not defined` INSIDE the except arm, which then reports
  # itself as "this config has no such binding". A false negative wearing a real answer's
  # clothes. Minimal repro: kitty +runpy 'X=1
  # def f(): return X
  # f()' → NameError. Keep everything at one level; do not refactor the arms into a function.
  cat <<'PY'
import os
try:
    from kitty.constants import config_dir
    from kitty.config import load_config
except Exception:
    print('PROBE=no')
    raise SystemExit(0)
print('PROBE=yes')
print('CONFDIR=' + config_dir)
for path, tag in (
    (os.environ['KITTY_PROBE_CONTROL_CONF'], 'CTL'),
    (os.environ['KITTY_PROBE_NEGATIVE_CONF'], 'NEG'),
    (os.path.join(config_dir, 'kitty.conf'), 'USR'),
):
    lay = []
    eq = 'no'
    try:
        c = load_config(path)
        lay = [str(x) for x in c.enabled_layouts]
        try:
            km = c.keyboard_modes[''].keymap
        except Exception:
            km = getattr(c, 'keymap', {})
        for k, v in km.items():
            if getattr(k, 'key', None) == 101 and getattr(k, 'mods', None) == 9:
                try:
                    ds = list(v)
                except Exception:
                    ds = [v]
                for d in ds:
                    if str(getattr(d, 'definition', d)).strip() == 'layout_action equalize':
                        eq = 'yes'
    except Exception:
        print(tag + '_ERR=1')
    print(tag + '_LAYOUT0=' + (lay[0].split(':')[0] if lay else ''))
    print(tag + '_LAYOUTS=' + ','.join(lay))
    print(tag + '_EQ=' + eq)
PY
}

pane_equalize_kitty_probe() {                               # prints the KEY=VALUE block, rc 1 if it could not run
  local kb td out rc
  kb="$(pane_equalize_kitty_bin)" || return 1
  td="$(mktemp -d -t pbm5 2>/dev/null)" || return 1
  mkdir -p "$td/ctl" "$td/neg" 2>/dev/null
  printf '%s\n%s\n' "$(pane_equalize_kitty_layout_line 'stack')" 'map cmd+shift+e layout_action equalize' \
    > "$td/ctl/kitty.conf" 2>/dev/null
  : > "$td/neg/kitty.conf" 2>/dev/null
  out="$(KITTY_PROBE_CONTROL_CONF="$td/ctl/kitty.conf" KITTY_PROBE_NEGATIVE_CONF="$td/neg/kitty.conf" \
         "$kb" +runpy "$(pane_equalize_kitty_py)" 2>/dev/null)"
  rc=$?
  rm -rf "$td" 2>/dev/null
  [ "$rc" -eq 0 ] || return 1
  case "$out" in *PROBE=yes*) : ;; *) return 1 ;; esac
  # The instrument must be able to say both words before we read its answer.
  [ "$(pane_equalize_probe_field "$out" CTL_EQ)" = yes ] || return 1
  [ "$(pane_equalize_probe_field "$out" CTL_LAYOUT0)" = splits ] || return 1
  [ "$(pane_equalize_probe_field "$out" NEG_EQ)" = no ] || return 1
  printf '%s' "$out"
}

# EQUALIZE-ON-WINDOW-CLOSE: `equalize_on_window_close`, which is what kitty implements. `equalize_on_close` — the
# spelling in kitty's own shipped docs — parses with no error and leaves the option OFF.
pane_equalize_kitty_layout_line() {
  printf 'enabled_layouts splits:equalize_on_window_close=true%s' \
    "${1:+,$1}"
}

# pane_equalize_kitty_confpath — kitty's own answer when the probe runs; its documented lookup when not.
pane_equalize_kitty_confpath() {
  local out d
  out="${1:-}"
  d="$(pane_equalize_probe_field "$out" CONFDIR)" || d=""
  if [ -z "$d" ]; then
    if [ -n "${KITTY_CONFIG_DIRECTORY:-}" ]; then d="$KITTY_CONFIG_DIRECTORY"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then d="$XDG_CONFIG_HOME/kitty"
    else d="$HOME/.config/kitty"; fi
  fi
  printf '%s/kitty.conf' "$d"
}

pane_equalize_kitty_verify() {
  local out
  pane_equalize_kitty_ver_ok "$(pane_equalize_kitty_bin)" || return 1
  out="$(pane_equalize_kitty_probe)" || {
    bootstrap_warn "pane_equalize: kitty's config probe could not run or failed its own control arms"
    return 1
  }
  [ "$(pane_equalize_probe_field "$out" USR_LAYOUT0)" = splits ] || return 1
  [ "$(pane_equalize_probe_field "$out" USR_EQ)" = yes ] || return 1
  return 0
}

# pane_equalize_kitty_strip <conf> — remove our block, refusing on any shape but exactly one begin and
# one end. A `sed '/a/,/b/d'` with a missing endpoint deletes to EOF; counting first is what
# makes the absence of an endpoint a refusal instead of a silent truncation.
pane_equalize_kitty_strip() {
  local conf="${1:-}" nb ne tmp
  [ -f "$conf" ] || return 0
  nb="$(LC_ALL=C grep -c "^$PANE_EQUALIZE_MARK_BEGIN\$" "$conf" 2>/dev/null)"
  ne="$(LC_ALL=C grep -c "^$PANE_EQUALIZE_MARK_END\$" "$conf" 2>/dev/null)"
  case "${nb:-0}" in ''|*[!0-9]*) nb=0 ;; esac
  case "${ne:-0}" in ''|*[!0-9]*) ne=0 ;; esac
  [ "$nb" = 0 ] && [ "$ne" = 0 ] && return 0
  if [ "$nb" != 1 ] || [ "$ne" != 1 ]; then
    bootstrap_warn "pane_equalize: $conf has $nb begin and $ne end markers; leaving it alone"
    return 1
  fi
  tmp="$(mktemp -t pbm5conf 2>/dev/null)" || return 1
  awk -v b="$PANE_EQUALIZE_MARK_BEGIN" -v e="$PANE_EQUALIZE_MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$conf" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$conf" 2>/dev/null || { rm -f "$tmp"; return 1; }   # keeps inode and mode
  rm -f "$tmp" 2>/dev/null
  return 0
}

pane_equalize_kitty_install() {
  local conf out l0 eq layouts rest need_layout=0 need_map=0
  pane_equalize_kitty_ver_ok "$(pane_equalize_kitty_bin)" || return 1
  out="$(pane_equalize_kitty_probe)" || {
    bootstrap_warn "pane_equalize: kitty's own config parser did not answer, so this install cannot be verified"
    return 1
  }
  conf="$(pane_equalize_kitty_confpath "$out")"
  mkdir -p "$(dirname "$conf")" 2>/dev/null
  [ -f "$conf" ] || : > "$conf" 2>/dev/null
  bootstrap_backup "$conf"
  pane_equalize_kitty_strip "$conf" || return 1             # then re-read: the answer changes without it
  out="$(pane_equalize_kitty_probe)" || return 1
  l0="$(pane_equalize_probe_field "$out" USR_LAYOUT0)"
  eq="$(pane_equalize_probe_field "$out" USR_EQ)"
  layouts="$(pane_equalize_probe_field "$out" USR_LAYOUTS)"
  [ "$l0" = splits ] || need_layout=1
  [ "$eq" = yes ] || need_map=1
  [ "$need_layout" = 0 ] && [ "$need_map" = 0 ] && return 0
  {
    printf '%s\n' "$PANE_EQUALIZE_MARK_BEGIN"
    printf '%s\n' "# Cmd+Shift+E gives every split an equal share again after manual resizing."
    if [ "$need_layout" = 1 ]; then
      # Keep every layout the config already enabled; splits goes FIRST because
      # `layout_action equalize` is a splits-only action and is a silent no-op anywhere else.
      rest="$(pane_equalize_kitty_rest_layouts "$layouts")"
      printf '%s\n' "# splits must be the DEFAULT layout: equalize is a splits-only action and"
      printf '%s\n' "# does nothing at all (silently, rc 0) in tall, fat, grid, stack, horizontal"
      printf '%s\n' "# or vertical. equalize_on_window_close is the implemented spelling; the"
      printf '%s\n' "# equalize_on_close in kitty's own docs parses fine and does nothing."
      printf '%s\n' "$(pane_equalize_kitty_layout_line "$rest")"
    fi
    [ "$need_map" = 1 ] && printf '%s\n' 'map cmd+shift+e layout_action equalize'
    printf '%s\n' "$PANE_EQUALIZE_MARK_END"
  } >> "$conf" 2>/dev/null || return 1
  return 0
}

# pane_equalize_kitty_rest_layouts <comma list> — everything except splits, order kept, opts kept.
pane_equalize_kitty_rest_layouts() {
  local item out="" oldifs
  oldifs="$IFS"; IFS=','
  # shellcheck disable=SC2086
  set -f; set -- ${1:-}; set +f
  IFS="$oldifs"
  for item in "$@"; do
    [ -n "$item" ] || continue
    case "${item%%:*}" in splits) continue ;; esac
    if [ -z "$out" ]; then out="$item"; else out="$out,$item"; fi
  done
  # A config with no enabled_layouts line reports all seven; carrying them all forward would be
  # noise, so the default we write beside splits is stack, which is what the source machine uses.
  case "$out" in
    'fat,grid,horizontal,stack,tall,vertical') out='stack' ;;
    '') out='stack' ;;
  esac
  printf '%s' "$out"
}

pane_equalize_kitty_uninstall() {
  local conf out
  out="$(pane_equalize_kitty_probe)" || out=""
  conf="$(pane_equalize_kitty_confpath "$out")"
  [ -f "$conf" ] || return 0
  bootstrap_backup "$conf"
  pane_equalize_kitty_strip "$conf"
}

# ── getting (or upgrading) a terminal, as ONE command a person can paste ─────────────────────
# Homebrew is offered only to an administrator: its installer aborts without sudo, and a cask lands
# in /Applications, which is root:admin 775. `upgrade` also needs the cask to be brew's own — on an
# app brew did not install, `brew upgrade --cask` fails with "not installed".
pane_equalize_admin_brew() { bootstrap_is_admin && bootstrap_find_tool brew; }
pane_equalize_brew_owns() {                                 # <cask>
  local b
  b="$(pane_equalize_admin_brew)" && [ -d "${b%/bin/brew}/Caskroom/${1:-}" ]
}

pane_equalize_kitty_app() {                                 # the kitty.app bundle, rc 1 if kitty is not one
  local b
  b="$(pane_equalize_kitty_bin)" || return 1
  case "$b" in
    */kitty.app/Contents/MacOS/kitty) printf '%s' "${b%/Contents/MacOS/kitty}" ;;
    *) bootstrap_find_app kitty.app ;;
  esac
}

# pane_equalize_shell_dir <dir> — the dir as the person's shell should read it: "$HOME/…" under the
# home directory (a receipt never carries a user name), the absolute path otherwise.
pane_equalize_shell_dir() {
  case "${1:-}" in
    "$HOME")   printf '%s' "\$HOME" ;;
    "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;;
    *)         printf '%s' "${1:-}" ;;
  esac
}

# pane_equalize_fetch_cmd <zip|dmg> <url> <sha256> <App.app> <target dir, as the shell spells it> <replace 0|1>
# One line, `&&` throughout: the sha256 is checked before anything is unpacked, and Gatekeeper's
# verdict is read on the unpacked bundle in a temp dir before it moves — so a wrong download, or a
# Mac whose IT refuses the app, stops the line with nothing landed. replace=1 (an upgrade) removes
# the old bundle only after both checks have passed.
pane_equalize_fetch_cmd() {
  local kind="${1:-}" url="${2:-}" sha="${3:-}" app="${4:-}" dir="${5:-}" replace="${6:-0}" f open
  # shellcheck disable=SC2016  # every $d and $(…) here is for the PERSON's shell, not this one
  f='$d/download.'"$kind"
  case "$kind" in
    zip) open="ditto -x -k \"$f\" \"\$d\"" ;;
    dmg) open="hdiutil attach -nobrowse -readonly -mountpoint \"\$d/mnt\" \"$f\" >/dev/null && { ditto \"\$d/mnt/$app\" \"\$d/$app\"; hdiutil detach \"\$d/mnt\" >/dev/null; }" ;;
    *)   return 1 ;;
  esac
  # shellcheck disable=SC2016
  printf 'd="$(mktemp -d)" && curl -fsSL -o "%s" '"'"'%s'"'"' && echo "%s  %s" | shasum -a 256 -c - && %s && spctl -a -vv "$d/%s" && mkdir -p "%s" && ' \
    "$f" "$url" "$sha" "$f" "$open" "$app" "$dir"
  [ "$replace" = 1 ] && printf 'rm -rf "%s/%s" && ' "$dir" "$app"
  printf 'mv "$d/%s" "%s/"' "$app" "$dir"
}

pane_equalize_iterm_fetch_cmd() {                           # <target dir, shell-spelled> <replace 0|1>
  pane_equalize_fetch_cmd zip "${BOOTSTRAP_PANE_EQUALIZE_ITERM_URL:-$PANE_EQUALIZE_ITERM_URL}" \
    "${BOOTSTRAP_PANE_EQUALIZE_ITERM_SHA256:-$PANE_EQUALIZE_ITERM_SHA256}" iTerm.app "${1:-}" "${2:-0}"
}

# pane_equalize_upgrade_route <iterm2|kitty> — brew · fetch · none: which upgrade THIS person can run.
pane_equalize_upgrade_route() {
  local app
  case "${1:-}" in
    iterm2) app="$(pane_equalize_iterm_app)" || app="" ;;
    kitty)  app="$(pane_equalize_kitty_app)" || app="" ;;
  esac
  if pane_equalize_brew_owns "${1:-}"; then printf 'brew'
  elif [ -n "$app" ] && [ -w "$(dirname "$app")" ]; then printf 'fetch'
  else printf 'none'; fi
}

# ── the gate, and the one place its reason is decided ────────────────────────────────────────
# Verbs run in separate subshells with nothing shared, so note_ and gesture_ re-derive this.
pane_equalize_gate_reason() {
  local app="" kb="" c
  if app="$(pane_equalize_iterm_app)"; then
    pane_equalize_iterm_capable "$app" || { printf 'ITERM_OLD'; return 0; }
  fi
  if kb="$(pane_equalize_kitty_bin)"; then
    if ! pane_equalize_kitty_ver_ok "$kb"; then
      if pane_equalize_kitty_refused "$kb"; then printf 'KITTY_REFUSED'; else printf 'KITTY_OLD'; fi
      return 0
    fi
  fi
  [ -n "$app" ] || [ -n "$kb" ] || { printf 'NOTERM'; return 0; }
  if [ -n "$app" ]; then
    c="$(pane_equalize_conflict)" && {
      case "$c" in
        dyn\ *) printf 'CONFLICT_DYN' ;;
        *)      printf 'CONFLICT_PLIST' ;;
      esac
      return 0
    }
  fi
  return 1
}

# ── the six verbs ────────────────────────────────────────────────────────────────────────────

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_pane_equalize()    { printf '%s' 'Cmd+Shift+E evens out split panes, in kitty and iTerm2 alike'; }
cost_pane_equalize()    { printf '%s' 'two config lines and one plist key. No installs, no permissions. Needs one terminal relaunch.'; }
profile_pane_equalize() { printf '%s' 'lite'; }
# No network at all: it writes two config files. The one command it may hand a person downloads a
# terminal, and that is the person's command, run by them, named in the receipt.
egress_pane_equalize()  { :; }
# What a company's IT or security team governs here. The module itself installs nothing; the one
# command it hands a person with no usable terminal (or a too-old one) downloads a vendor app.
clearance_pane_equalize() {
  printf '%s\n' 'software only if you run the command it offers when neither kitty nor iTerm2 is usable: the official iTerm2 3.7.1 or kitty 0.48.2 release, a vendor download not distributed by IT'
}

verify_pane_equalize() {
  local configured=0
  [ -n "$(pane_equalize_gate_reason)" ] && return 1
  if pane_equalize_iterm_app >/dev/null 2>&1; then
    pane_equalize_iterm_verify || return 1
    configured=1
  fi
  if pane_equalize_kitty_bin >/dev/null 2>&1; then
    pane_equalize_kitty_verify || return 1
    configured=1
  fi
  [ "$configured" = 1 ] || return 1               # hole (a): configuring nothing is not success
  return 0
}

gate_pane_equalize() {
  [ -n "$(pane_equalize_gate_reason)" ]
}

# pane_equalize_upgrade_note <what is wrong> <iterm2|kitty> <App name>
pane_equalize_upgrade_note() {
  case "$(pane_equalize_upgrade_route "${2:-}")" in
    brew)  printf '%s; the command below upgrades it with Homebrew, then run the bootstrap again' "${1:-}" ;;
    fetch) printf '%s; the command below replaces it with the pinned official release, checked by sha256 and by Gatekeeper before the old copy is removed — then run the bootstrap again' "${1:-}" ;;
    *)     if [ "${2:-}" = kitty ] && ! pane_equalize_kitty_app >/dev/null 2>&1; then
             printf '%s; this kitty is not an app bundle, so update it the way you installed it (https://sw.kovidgoyal.net/kitty/binary/)' "${1:-}"
           else
             printf '%s; it sits where only an administrator can replace it, so ask IT to update %s' "${1:-}" "${3:-}"
           fi ;;
  esac
}

note_pane_equalize() {
  case "$(pane_equalize_gate_reason)" in
    NOTERM)
      if pane_equalize_admin_brew >/dev/null 2>&1; then
        printf '%s' "no terminal to bind Cmd+Shift+E in: this Mac has neither kitty nor iTerm2, only Terminal.app, which has no equalize action. Installing one is your call; the command below installs iTerm2 with Homebrew, then run the bootstrap again"
      else
        printf '%s' "no terminal to bind Cmd+Shift+E in: this Mac has neither kitty nor iTerm2, only Terminal.app, which has no equalize action. Installing one is your call and needs no administrator: the command below downloads iTerm2's official release from iterm2.com into ~/Applications, checking the sha256 this release pins and Gatekeeper's verdict before anything lands. Then run the bootstrap again"
      fi ;;
    ITERM_OLD)
      pane_equalize_upgrade_note "this iTerm2 build has no 'Arrange Split Panes Evenly' menu item, so Cmd+Shift+E would have nothing to invoke" iterm2 iTerm2 ;;
    KITTY_OLD)
      pane_equalize_upgrade_note "kitty is older than $PANE_EQUALIZE_KITTY_FLOOR, the first release with the 'equalize' layout action" kitty kitty ;;
    KITTY_REFUSED)
      printf 'this Mac refuses to execute kitty (%s) — binary authorization such as Santa blocks software IT has not allowed. Ask IT to allow %s, then run this again' \
        "$(pane_equalize_kitty_bin)" "$(pane_equalize_signer "$(pane_equalize_kitty_bin)")" ;;
    CONFLICT_DYN)
      printf '%s' "an iTerm2 DynamicProfile already binds Cmd+Shift+E and is re-read at every launch; a profile binding beats the menu shortcut, so the key would look bound and do nothing — decide which meaning keeps it" ;;
    CONFLICT_PLIST)
      printf '%s' "an iTerm2 profile keyboard map already binds Cmd+Shift+E; a profile binding beats the menu shortcut, so the key would look bound and do nothing — quit iTerm2, then free the chord" ;;
    *)
      printf '%s' "Cmd+Shift+E is not bound to equalize yet" ;;
  esac
}

gesture_pane_equalize() {
  local c j tail app
  case "$(pane_equalize_gate_reason)" in
    NOTERM)
      if pane_equalize_admin_brew >/dev/null 2>&1; then printf '%s' 'HOMEBREW_NO_ANALYTICS=1 brew install --cask iterm2'
      else pane_equalize_iterm_fetch_cmd "\$HOME/Applications" 0; fi ;;
    ITERM_OLD)
      case "$(pane_equalize_upgrade_route iterm2)" in
        brew)  printf '%s' 'HOMEBREW_NO_ANALYTICS=1 brew upgrade --cask iterm2' ;;
        fetch) app="$(pane_equalize_iterm_app)" && pane_equalize_iterm_fetch_cmd "$(pane_equalize_shell_dir "$(dirname "$app")")" 1 ;;
      esac ;;
    KITTY_OLD)
      case "$(pane_equalize_upgrade_route kitty)" in
        brew)  printf '%s' 'HOMEBREW_NO_ANALYTICS=1 brew upgrade --cask kitty' ;;
        fetch) app="$(pane_equalize_kitty_app)" && pane_equalize_fetch_cmd dmg "$PANE_EQUALIZE_KITTY_URL" "$PANE_EQUALIZE_KITTY_SHA256" \
                 kitty.app "$(pane_equalize_shell_dir "$(dirname "$app")")" 1 ;;
      esac ;;
    CONFLICT_DYN)
      c="$(pane_equalize_conflict)" || return 0
      j="${c#dyn }"
      tail="${j#"$HOME"/}"
      # An editor, never a bare path: a path pasted into a shell is executed, not opened.
      printf 'open -e "$HOME/%s"' "$tail" ;;
    CONFLICT_PLIST)
      # One line, and it refuses rather than losing the edit: iTerm2 rewrites its profiles from
      # memory when it quits, so a delete made while it is running comes straight back.
      printf '%s' 'pgrep -x iTerm2 >/dev/null && echo "Quit iTerm2 first, then run this again." || { for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do /usr/libexec/PlistBuddy -c "Delete '"'"'New Bookmarks'"'"':$i:'"'"'Keyboard Map'"'"':'"'"'0x45-0x120000'"'"'" "$HOME/Library/Preferences/com.googlecode.iterm2.plist" >/dev/null 2>&1; done; echo "Cmd+Shift+E is free now — re-run the bootstrap."; }' ;;
    *) : ;;
  esac
  return 0
}

install_pane_equalize() {
  local did=0 rc=0
  if pane_equalize_iterm_app >/dev/null 2>&1; then
    if pane_equalize_iterm_install; then
      did=1
      printf '%s\n' "pane_equalize: iTerm2 — Cmd+Shift+E bound to Arrange Split Panes Evenly."
      printf '%s\n' "pane_equalize: it takes effect at the NEXT iTerm2 launch; the running instance ignores it."
    else
      rc=1
    fi
  fi
  if pane_equalize_kitty_bin >/dev/null 2>&1; then
    if pane_equalize_kitty_install; then
      did=1
      printf '%s\n' "pane_equalize: kitty — cmd+shift+e mapped to layout_action equalize, splits made the default layout."
      printf '%s\n' "pane_equalize: a running kitty picks it up on restart, or with: kitty @ --to \"\$KITTY_LISTEN_ON\" load-config"
    else
      rc=1
    fi
  fi
  # The one thing no verifier here may assert, because the geometry read needs Accessibility
  # and an Apple Events consent that no gate covers — so it is stated for a human instead:
  printf '%s\n' "pane_equalize: CHECK IT BY HAND — open the terminal, split the pane twice, drag a divider, press Cmd+Shift+E."
  [ "$did" = 1 ] || return 1
  return "$rc"
}

uninstall_pane_equalize() {
  pane_equalize_iterm_app >/dev/null 2>&1 && pane_equalize_iterm_uninstall
  pane_equalize_kitty_bin >/dev/null 2>&1 && pane_equalize_kitty_uninstall
  return 0
}
