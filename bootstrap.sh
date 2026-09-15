#!/bin/bash
# mac-bootstrap — the driver.
#
# Bootstraps a new Mac for an agent workflow that must work under BOTH Claude Code and GitHub
# Copilot CLI. It DRIVES every reversible step and RECORDS every step it must not take:
# a GUI permission, a Keychain dialog, sudo, an Apple ID, the App Store, money. It never
# attempts one of those and it never writes your agent's permissions, allowlists or credentials.
#
#   bash bootstrap.sh                  in a terminal: a menu to pick modules. Without one: the default profile
#   bash bootstrap.sh --pick           the menu, even when flags pre-select; --no-pick never shows it
#   bash bootstrap.sh --verify         re-read the machine cold; change nothing
#   bash bootstrap.sh --egress         every host each module can reach, and a check that no local
#                                      data can reach a cloud AI service; changes nothing
#   bash bootstrap.sh --only statusline      re-drive ONE module (merges into the receipt)
#   bash bootstrap.sh --only rewrite_model --bench qwen3:8b     measure a candidate, write nothing
#         --bench exits on the GATE's scale, not the install scale: 0 the model is fit ·
#         1 it was measured and REJECTED · 2 nothing was measured. It also prints one
#         BENCH_RESULT=... line for a caller that would rather parse than branch.
#   bash bootstrap.sh --only rewrite_model --model qwen3:8b     install with a parameter
#   bash bootstrap.sh --uninstall      reverse it
#
# EXIT CODES — one meaning each, on BOTH the install and the --verify path:
#     0   every module SATISFIED.
#    10   satisfied except for modules waiting on YOU (NEEDS_HUMAN). Read the receipt.
#    20   something FAILED. Read the log.
#    30   precondition/internal error: this run is not a verdict about the machine. A module the
#         run never evaluated — `--only` leaves the other seven unjudged — lands here, NOT in 0.
#   Under --uninstall the scale is: 0 everything removed · 20 an uninstall_ failed · 30 a row
#   nobody can read. Zero rows is uninstall's SUCCESS, and only uninstall's.
#   Precedence when several apply: 30 > 20 > 10 > 0. 30 wins because a run that could not
#   assemble itself has nothing to say about the machine, and 0 must never mean two things.
#
# THERE IS NO --dry-run, deliberately. The one that shipped in the design overwrote the receipt
# with six meaningless rows (destroying the only record of what needed the human), and it exited
# 0 on a machine where nothing was installed — three steps after the prompt taught the reader
# that 0 means done. `--verify` replaces it: it writes receipt.verify.json, never receipt.json.
#
# Nothing here is written inside the repo. Everything mutable lives under $HOME/.mac-bootstrap.

set -u
# NOT set -e: a module failure must never kill the run.
# NOT set -o pipefail either: $? after a pipe is the LAST stage's status, and the one measured
# instance of that in this design (`xcodebuild -version | head -1`) SIGPIPEd rc=141 in 1 of 80
# runs and misdiagnosed as an Xcode licence problem. This file captures, then reads the rc.

BOOTSTRAP_VERSION=1
BOOTSTRAP_REPO="renchris/mac-bootstrap"
BOOTSTRAP_PIN="${BOOTSTRAP_PIN:-e72735464824aad403f6e72d5ff2340413e74b12}"          # replaced at release time. NEVER "main": a main-pinned
                                         # raw URL serves up to 5 minutes of stale Fastly bytes.
# A company whose proxy blocks raw.githubusercontent.com points BOOTSTRAP_RAW at its own mirror of the
# same tree. That is safe to allow because nothing fetched is trusted by where it came from — see the
# manifest below.
BOOTSTRAP_RAW="${BOOTSTRAP_RAW:-https://raw.githubusercontent.com/$BOOTSTRAP_REPO/$BOOTSTRAP_PIN}"

# ── THE RELEASE MANIFEST ─────────────────────────────────────────────────────────────────────
# The sha256 of every module and asset at the pin, written by scripts/release.sh in the same commit
# as the pin — never by hand. A curl'd run checks every byte it fetches against this list BEFORE it
# sources or installs any of it, so where the bytes came from stops mattering: GitHub's raw host,
# its tarball host, or a company mirror. The one hash a person checks — bootstrap.sh's own, printed
# in the README — therefore covers the whole release. Its first line names the tree it describes; a
# BOOTSTRAP_PIN that names another tree is refused, because this list cannot vouch for that one.
driver_release_manifest() {
  cat <<'BOOTSTRAP_RELEASE_MANIFEST'
BOOTSTRAP_RELEASE_MANIFEST
}

BOOTSTRAP_STATE_DIR="$HOME/.mac-bootstrap"
BOOTSTRAP_LOG="$BOOTSTRAP_STATE_DIR/bootstrap.log"
BOOTSTRAP_ROWS="$BOOTSTRAP_STATE_DIR/rows"
BOOTSTRAP_RECEIPT="$BOOTSTRAP_STATE_DIR/receipt.json"
BOOTSTRAP_VERIFY_RECEIPT="$BOOTSTRAP_STATE_DIR/receipt.verify.json"

BOOTSTRAP_MODE=install
BOOTSTRAP_ONLY=""
BOOTSTRAP_EXCEPT=""
BOOTSTRAP_SELECTED=""
BOOTSTRAP_PROFILE=""            # empty => the default profile below
BOOTSTRAP_PROFILE_DEFAULT=lite    # the safest useful set: config files only, no installs, no gestures
BOOTSTRAP_BENCH=""
BOOTSTRAP_MODEL=""
BOOTSTRAP_PICK=auto              # auto: the menu when a person is at a terminal and no flag chose · yes · no
BOOTSTRAP_RC=0

# ── THE INSTALL ORDER, DECLARED. Cheapest and most reversible first; anything that needs a
# download, a permission or money last — so a run that stops early has done the safe things and
# none of the expensive ones. It is written down HERE because it has to be: the modules used to
# be named m1_ … m8_ and the order fell out of an alphabetical glob, which meant the sequence was
# a property of eight filenames and nothing stated it or could check it. Worse, the number read
# as a ranking it was not: m5_panes is in `lite` while m4_handoff is `standard`, so "4 before 5"
# implied a progression that does not exist. A module not named here still works — it is appended
# after these, in the glob's own order, and says so in --manifest.
#
# This list is ALSO the manifest of last resort, used when there is no modules/ directory beside
# this script — i.e. when bootstrap.sh was curl'd on its own. A module that is not in the release
# at this pin is recorded SKIPPED, a precondition error (30), never a silent absence.
BOOTSTRAP_MODULE_ORDER="statusline instructions hooks reporting_off handoff microsoft365 microsoft365_archive shared_folders pane_equalize voiceink rewrite_model screenshot"

driver_self_dir() {
  local s="${BASH_SOURCE[0]:-$0}" d
  d="$(cd "$(dirname "$s")" 2>/dev/null && pwd -P)" || d="."
  printf '%s' "$d"
}
BOOTSTRAP_HERE="$(driver_self_dir)"

# ── output ───────────────────────────────────────────────────────────────────────────────────
driver_say()  { printf '%s\n' "$*"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&3 2>/dev/null; }
driver_fail() { printf '  x %s\n' "$*" >&2; printf '%s FAIL %s\n' "$(date -u +%FT%TZ)" "$*" >&3 2>/dev/null; }
driver_log()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&3 2>/dev/null; return 0; }

driver_help() {
  sed -n '2,36p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# ── flags ────────────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --verify)    BOOTSTRAP_MODE=verify ;;
    --uninstall) BOOTSTRAP_MODE=uninstall ;;
    --only)      [ $# -ge 2 ] || { printf 'bootstrap: --only needs a module name\n' >&2; exit 30; }
                 BOOTSTRAP_ONLY="$BOOTSTRAP_ONLY $(printf '%s' "$2" | tr ',' ' ')"; shift ;;
    --bench)     [ $# -ge 2 ] || { printf 'bootstrap: --bench needs a model name\n' >&2; exit 30; }
                 BOOTSTRAP_MODE=bench; BOOTSTRAP_BENCH="$2"; shift ;;
    --model)     [ $# -ge 2 ] || { printf 'bootstrap: --model needs a name\n' >&2; exit 30; }
                 BOOTSTRAP_MODEL="$2"; shift ;;
    --list)      BOOTSTRAP_MODE=list ;;
    --plan)      BOOTSTRAP_MODE=plan ;;
    --manifest)  BOOTSTRAP_MODE=manifest ;;
    --egress)    BOOTSTRAP_MODE=egress ;;
    --profile)   [ $# -ge 2 ] || { printf 'bootstrap: --profile needs a name (lite|standard|full|all)\n' >&2; exit 30; }
                 BOOTSTRAP_PROFILE="$2"; shift ;;
    --except)    [ $# -ge 2 ] || { printf 'bootstrap: --except needs a module name\n' >&2; exit 30; }
                 BOOTSTRAP_EXCEPT="$BOOTSTRAP_EXCEPT $(printf '%s' "$2" | tr ',' ' ')"; shift ;;
    --pick)      BOOTSTRAP_PICK=yes ;;
    --no-pick)   BOOTSTRAP_PICK=no ;;
    --help|-h)   driver_help; exit 0 ;;
    --dry-run)   printf 'bootstrap: --dry-run was REMOVED, not renamed.\n' >&2
                 printf '  It overwrote the receipt and exited 0 on a machine where nothing was\n' >&2
                 printf '  installed. Use:  bash %s --verify\n' "${0##*/}" >&2
                 exit 30 ;;
    *)           printf 'bootstrap: unknown argument: %s   (try --help)\n' "$1" >&2; exit 30 ;;
  esac
  shift
done

# ── state ────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$BOOTSTRAP_STATE_DIR" "$BOOTSTRAP_ROWS" "$BOOTSTRAP_STATE_DIR/backups" 2>/dev/null || {
  printf 'bootstrap: cannot create %s\n' "$BOOTSTRAP_STATE_DIR" >&2; exit 30; }
# fd 3 is the durable log; stdout stays human-readable and stderr stays STDERR.
# NOT `exec 3>>"$BOOTSTRAP_LOG" 2>/dev/null`: that spelling is two redirections on one exec, and the
# second one silently sends THE WHOLE SCRIPT'S stderr to /dev/null for the rest of the run —
# measured here, it swallowed every driver_fail line while the log recorded them perfectly, so the
# terminal showed eight modules and not one word about why none of them ran.
if : >>"$BOOTSTRAP_LOG" 2>/dev/null; then exec 3>>"$BOOTSTRAP_LOG"; else exec 3>/dev/null; fi
export BOOTSTRAP_LOG="$BOOTSTRAP_LOG"
export BOOTSTRAP_STATE_DIR="$BOOTSTRAP_STATE_DIR"

# ── THE TREE — the modules/ and assets/ this run uses ────────────────────────────────────────
# A clone has them beside this script. A curl'd bootstrap.sh has nothing beside it, so it fetches the
# release ONCE into $BOOTSTRAP_STATE_DIR/release/<pin>/, checks every file against the manifest, and
# only then uses it — the library included, which is why this runs before anything is sourced. After
# this, no module fetches our own code over the network: every one of them reads $BOOTSTRAP_ASSETS.
#
# Two routes, in order: GitHub's tarball of the pinned commit (one request), then each file from
# BOOTSTRAP_RAW. A corporate proxy commonly blocks one host and not the other; a mirror named in
# BOOTSTRAP_RAW is used on its own. A route that fails, or serves one wrong byte, is simply not used.
driver_sha_list() { driver_release_manifest | grep -v '^pin ' | grep .; }
driver_manifest_pin() { driver_release_manifest | sed -n 's/^pin \([0-9a-f]*\)$/\1/p' | head -1; }

# driver_tree_ok <dir> — 0 iff every file the manifest names is there with its sha256. One shasum
# process for the whole tree, not one per file.
driver_tree_ok() {
  [ -d "$1" ] || return 1
  ( cd "$1" 2>/dev/null && driver_sha_list | shasum -a 256 -c --status - 2>/dev/null )
}

driver_tree_from_tarball() {                        # driver_tree_from_tarball <dir> → rc 0 when it extracted
  local d="$1" url="${BOOTSTRAP_TARBALL:-https://codeload.github.com/$BOOTSTRAP_REPO/tar.gz/$BOOTSTRAP_PIN}" rel want
  [ -n "${BOOTSTRAP_RAW_MIRROR:-}" ] && [ -z "${BOOTSTRAP_TARBALL:-}" ] && return 1
  curl -fsSL --retry 2 -o "$d.tgz" "$url" 2>/dev/null || { rm -f "$d.tgz"; driver_log "tree: tarball route unavailable ($url)"; return 1; }
  mkdir -p "$d.x" && tar -xzf "$d.tgz" -C "$d.x" --strip-components 1 2>/dev/null || {
    rm -rf "$d.tgz" "$d.x"; driver_log "tree: the tarball from $url did not extract"; return 1; }
  # Only the files the manifest names are kept: the rest of the repo (README, scripts, this driver at
  # another pin) is not vouched for, so it never lands in a tree a module reads from.
  while read -r want rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$d/$(dirname "$rel")" && cp -f "$d.x/$rel" "$d/$rel" 2>/dev/null
  done <<EOF
$(driver_sha_list)
EOF
  rm -rf "$d.tgz" "$d.x"
  return 0
}

driver_tree_from_files() {                          # driver_tree_from_files <dir> → rc 0 when every file arrived
  local d="$1" rel want code
  while read -r want rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$d/$(dirname "$rel")" || return 1
    code="$(curl -sS -L --retry 2 -o "$d/$rel" -w '%{http_code}' "$BOOTSTRAP_RAW/$rel" 2>/dev/null)" || code="failed"
    case "$code" in
      200) : ;;
      000) case "$BOOTSTRAP_RAW" in file://*) : ;; *) driver_log "tree: $rel — no answer from $BOOTSTRAP_RAW"; return 1 ;; esac ;;
      *)   driver_log "tree: $rel — HTTP $code from $BOOTSTRAP_RAW"; return 1 ;;
    esac
  done <<EOF
$(driver_sha_list)
EOF
}

driver_materialize() {                              # sets BOOTSTRAP_TREE → rc 0, or says why not → rc 1
  local dir part bad
  case "$BOOTSTRAP_PIN" in
    __PIN_SHA__|main|master|"")
      printf 'bootstrap: no modules/ beside this script, and pin "%s" is not a release — nothing can be fetched.\n' "$BOOTSTRAP_PIN" >&2
      printf '  Run it from a clone of the repo, or use the released bootstrap.sh the README links.\n' >&2
      return 1 ;;
  esac
  if [ -z "$(driver_sha_list)" ]; then
    printf 'bootstrap: this bootstrap.sh carries no release manifest, so it cannot verify anything it would fetch.\n' >&2
    printf '  Use the released bootstrap.sh the README links, or run it from a clone.\n' >&2
    return 1
  fi
  if [ "$(driver_manifest_pin)" != "$BOOTSTRAP_PIN" ]; then
    printf 'bootstrap: BOOTSTRAP_PIN=%s names a tree this script'\''s manifest (%s) cannot vouch for.\n' "$BOOTSTRAP_PIN" "$(driver_manifest_pin)" >&2
    printf '  Fetch the bootstrap.sh released with that tree instead, and run it without BOOTSTRAP_PIN.\n' >&2
    return 1
  fi
  dir="$BOOTSTRAP_STATE_DIR/release/$BOOTSTRAP_PIN"
  if driver_tree_ok "$dir"; then BOOTSTRAP_TREE="$dir"; return 0; fi
  part="$dir.part.$$"
  rm -rf "$part" "$part.tgz" "$part.x"; mkdir -p "$part" || return 1
  driver_say "fetching the release tree at $BOOTSTRAP_PIN — every file is checked against this script's manifest"
  if { driver_tree_from_tarball "$part" && driver_tree_ok "$part"; } \
     || { rm -rf "$part" && mkdir -p "$part" && driver_tree_from_files "$part" && driver_tree_ok "$part"; }; then
    rm -rf "$dir"; mv -f "$part" "$dir" && { BOOTSTRAP_TREE="$dir"; return 0; }
  fi
  bad="$( (cd "$part" 2>/dev/null && driver_sha_list | shasum -a 256 -c - 2>/dev/null) | grep -v ': OK$' | head -3 | tr '\n' ' ')"
  rm -rf "$part" "$part.tgz" "$part.x"
  printf 'bootstrap: could not assemble a verified copy of the release at %s.\n' "$BOOTSTRAP_PIN" >&2
  [ -n "$bad" ] && printf '  first mismatches: %s\n' "$bad" >&2
  printf '  Tried the tarball (codeload.github.com) and each file from %s.\n' "$BOOTSTRAP_RAW" >&2
  printf '  Behind a proxy that blocks both, point BOOTSTRAP_RAW at a mirror of this repo at that commit.\n' >&2
  return 1
}

BOOTSTRAP_TREE=""
[ "${BOOTSTRAP_RAW:-}" != "https://raw.githubusercontent.com/$BOOTSTRAP_REPO/$BOOTSTRAP_PIN" ] && BOOTSTRAP_RAW_MIRROR=1
if [ -d "$BOOTSTRAP_HERE/modules" ] && [ -r "$BOOTSTRAP_HERE/assets/hooks/bootstrap-lib.sh" ]; then
  BOOTSTRAP_TREE="$BOOTSTRAP_HERE"
else
  driver_materialize || exit 30
fi
BOOTSTRAP_LIB="$BOOTSTRAP_TREE/assets/hooks/bootstrap-lib.sh"
# shellcheck source=assets/hooks/bootstrap-lib.sh
. "$BOOTSTRAP_LIB" || { printf 'bootstrap: bootstrap-lib.sh did not load\n' >&2; exit 30; }
export BOOTSTRAP_LIB="$BOOTSTRAP_LIB"

# ── THE ENVIRONMENT CONTRACT (CONTRACT.md §5). A sourced module cannot take flags, so parameters arrive
#    as exported variables. These names are the contract; CONTRACT.md is their documentation.
export BOOTSTRAP_MODE="$BOOTSTRAP_MODE"
export BOOTSTRAP_MODEL="$BOOTSTRAP_MODEL"
export BOOTSTRAP_BENCH="$BOOTSTRAP_BENCH"
export BOOTSTRAP_PIN="$BOOTSTRAP_PIN"
export BOOTSTRAP_RAW="$BOOTSTRAP_RAW"
export BOOTSTRAP_ASSETS="$BOOTSTRAP_TREE/assets"
# The entry script a module's hint can tell the person to re-run. A clone's own path; a file run from
# elsewhere (the README's /tmp/mac-bootstrap.sh) is copied beside the verified tree, since /tmp is
# wiped and the person already checked that file's hash; under `curl | bash` there is no file to name.
BOOTSTRAP_ENTRY=""
if [ "$BOOTSTRAP_TREE" = "$BOOTSTRAP_HERE" ]; then
  [ -r "$BOOTSTRAP_HERE/bootstrap.sh" ] && BOOTSTRAP_ENTRY="$BOOTSTRAP_HERE/bootstrap.sh"
elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
  cp -f "${BASH_SOURCE[0]}" "$BOOTSTRAP_STATE_DIR/bootstrap.sh" 2>/dev/null && BOOTSTRAP_ENTRY="$BOOTSTRAP_STATE_DIR/bootstrap.sh"
fi
export BOOTSTRAP_ENTRY="$BOOTSTRAP_ENTRY"

# ── the manifest ─────────────────────────────────────────────────────────────────────────────
# 1. BOOTSTRAP_MODULES (explicit, used by the tests)  2. modules/ in the tree  3. the declared order.
driver_manifest() {
  local f n out=""
  if [ -n "${BOOTSTRAP_MODULES:-}" ]; then printf '%s' "$BOOTSTRAP_MODULES"; return 0; fi
  if [ -d "$BOOTSTRAP_TREE/modules" ]; then
    for f in "$BOOTSTRAP_TREE/modules"/*.sh; do
      [ -r "$f" ] || continue
      n="${f##*/}"; out="$out ${n%.sh}"
    done
  fi
  if [ -n "$out" ]; then
    # Emit in the DECLARED order, then anything on disk the declaration does not name. The glob
    # is alphabetical, which is not the order these have to run in and never was.
    for n in $BOOTSTRAP_MODULE_ORDER; do
      case " $out " in *" $n "*) printf '%s ' "$n" ;; esac
    done
    for n in $out; do
      case " $BOOTSTRAP_MODULE_ORDER " in *" $n "*) : ;; *) printf '%s ' "$n" ;; esac
    done
    return 0
  fi
  printf '%s' "$BOOTSTRAP_MODULE_ORDER"
}

# The tree is complete or the run never got this far, so a module not in it is not in this release.
driver_module_file() {                              # prints the readable path, or nothing
  [ -r "$BOOTSTRAP_TREE/modules/$1.sh" ] || return 1
  printf '%s' "$BOOTSTRAP_TREE/modules/$1.sh"
}

# ── the CATALOG ───────────────────────────────────────────────────────────────────────────────
# A module may declare itself with four OPTIONAL verbs. They are optional on purpose: the six
# required verbs are the contract, and a module that declares none of these still works — it just
# lands in the `standard` profile with no printed cost. Defaults are chosen so that silence is
# never dangerous: an undeclared module is NOT in `lite`, so a module nobody has priced can never
# arrive by default on a stranger's machine.
#
#   what_<m>      one line: what you get
#   cost_<m>      one line: disk, minutes, and the human gestures it will ask for
#   profile_<m>   lite | standard | full   (the smallest profile that includes it)
#   needs_<m>     space-separated module names this one requires to be meaningful
driver_meta() {                                     # driver_meta <module-file> <module> <field> <default>
  local out
  if driver_has_verb "$1" "$2" "$3"; then
    out="$(driver_call "$1" "$2" "$3" 2>/dev/null)" || out=""
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  fi
  printf '%s' "$4"
}

# Notes from inside a command substitution. stdout belongs to the caller's capture.
driver_note_out() { printf '%s\n' "$*" >&2; }

# driver_renamed_to <name> — the one release in which every module was renamed, answered for a
# reader who pasted a command from an older README. It REFUSES rather than aliasing: running a
# different module than the one you named is worse than a clear error, and a permanent alias is
# the dead name surviving forever. This table is deliberately finite and dated — DELETE IT in the
# release after the next one, by which point an older command is old enough to be re-read.
driver_renamed_to() {
  case "$1" in
    m1_statusline)   printf 'statusline' ;;
    m2_instructions) printf 'instructions' ;;
    m3_hooks)        printf 'hooks' ;;
    m4_handoff)      printf 'handoff' ;;
    m5_panes)        printf 'pane_equalize' ;;
    m6_voiceink)     printf 'voiceink' ;;
    m7_model)        printf 'rewrite_model' ;;
    m8_screenshot)   printf 'screenshot' ;;
    *) return 1 ;;
  esac
}

driver_profile_rank() {                             # lite=1 standard=2 full=3, anything else=2
  case "$1" in lite) printf 1 ;; standard) printf 2 ;; full) printf 3 ;; all) printf 9 ;; *) printf 2 ;; esac
}

# The selected set, in manifest order. Precedence, and it is deliberate:
#   --only wins outright (an explicit list is an explicit list)
#   otherwise: the profile, then --except subtracts, then needs_ adds back OUT LOUD.
# A dependency is never added silently and never turns into a failure: the one thing worse than
# installing something the user did not ask for is refusing to explain why it is needed.
driver_select() {
  local m f p want rank sel="" add chg guard bad=""
  rank="$(driver_profile_rank "${BOOTSTRAP_PROFILE:-$BOOTSTRAP_PROFILE_DEFAULT}")"

  # A name that is in no manifest is a typo. Selecting nothing and exiting 0 would report a clean
  # run over an empty set — the false-green shape this driver already had to have removed twice.
  for m in $BOOTSTRAP_ONLY $BOOTSTRAP_EXCEPT; do
    case " $BOOTSTRAP_MANIFEST " in *" $m "*) : ;; *) bad="$bad $m" ;; esac
  done
  if [ -n "$bad" ]; then
    driver_note_out "bootstrap: no such module:$bad"
    driver_note_out "           known modules: $BOOTSTRAP_MANIFEST"
    for m in $bad; do
      chg="$(driver_renamed_to "$m")" || continue
      driver_note_out "           \"$m\" was renamed to \"$chg\" in the 2026-09-12 release."
    done
    return 1
  fi

  if [ -n "$BOOTSTRAP_ONLY" ]; then
    for m in $BOOTSTRAP_MANIFEST; do
      case " $BOOTSTRAP_ONLY " in *" $m "*) sel="$sel $m" ;; esac
    done
  else
    for m in $BOOTSTRAP_MANIFEST; do
      # An UNRESOLVABLE module is INCLUDED, never skipped. Dropping it here would delete it from
      # the selection the verdict is scored over, and the run would report success having silently
      # lost a module it was asked for — measured: BOOTSTRAP_MODULES with a ghost name exited 0. Included,
      # it reaches driver_run_module, records SKIPPED, and SKIPPED maps to 30.
      if ! f="$(driver_module_file "$m")"; then sel="$sel $m"; continue; fi
      p="$(driver_meta "$f" "$m" profile standard)"
      [ "$(driver_profile_rank "$p")" -le "$rank" ] && sel="$sel $m"
    done
  fi

  for m in $BOOTSTRAP_EXCEPT; do
    sel=" $(printf '%s' "$sel" | tr ' ' '\n' | grep -v "^${m}\$" | tr '\n' ' ') "
  done

  # Close over needs_, bounded by the manifest size so a cycle cannot spin.
  guard=0
  while [ "$guard" -lt 16 ]; do
    guard=$((guard + 1)); chg=0
    for m in $sel; do
      f="$(driver_module_file "$m")" || continue
      for want in $(driver_meta "$f" "$m" needs ""); do
        case " $sel " in
          *" $want "*) : ;;
          *) case " $BOOTSTRAP_EXCEPT " in
               *" $want "*) [ "$guard" = 1 ] && driver_note_out "   note: $m wants $want, but you excluded it — $m will install in a reduced form" ;;
               *) case " $BOOTSTRAP_MANIFEST " in
                    *" $want "*) sel="$sel $want"; chg=1
                                 # STDERR, not stdout: this function runs inside $( ), so a note
                                 # printed to stdout is captured as if it were a module name and
                                 # then dropped by the rebuild below — invisible, and the reason
                                 # "adding it out loud" silently became "adding it".
                                 driver_note_out "   note: $m needs $want — adding it" ;;
                  esac ;;
             esac ;;
        esac
      done
    done
    [ "$chg" = 0 ] && break
  done

  # Emit in manifest order, deduplicated.
  add=""
  for m in $BOOTSTRAP_MANIFEST; do
    case " $sel " in *" $m "*) case " $add " in *" $m "*) : ;; *) add="$add $m" ;; esac ;; esac
  done
  printf '%s' "${add# }"
}

# ── --list ────────────────────────────────────────────────────────────────────────────────────
driver_cmd_list() {
  local m f what cost prof needs selected
  selected=" $(driver_select) " || return 30
  printf '\n  MODULES — a * marks what THIS invocation would act on (profile: %s)\n\n' "${BOOTSTRAP_PROFILE:-$BOOTSTRAP_PROFILE_DEFAULT}"
  for m in $BOOTSTRAP_MANIFEST; do
    f="$(driver_module_file "$m")" || { printf '  ?  %-16s (module file unavailable)\n' "$m"; continue; }
    what="$(driver_meta "$f" "$m" what "$m")"
    cost="$(driver_meta "$f" "$m" cost "unpriced")"
    prof="$(driver_meta "$f" "$m" profile standard)"
    needs="$(driver_meta "$f" "$m" needs "")"
    case "$selected" in *" $m "*) printf '  * ' ;; *) printf '    ' ;; esac
    printf '%-16s [%s]\n' "$m" "$prof"
    printf '       what : %s\n' "$what"
    printf '       cost : %s\n' "$cost"
    [ -n "$needs" ] && printf '       needs: %s\n' "$needs"
    printf '\n'
  done
  printf '  PROFILES\n'
  printf '    lite      config files only. No Homebrew, no permissions, no Apple ID. THE DEFAULT.\n'
  printf '    standard  lite + the succession engine, a local rewrite model and Outlook.\n'
  printf '    full      standard + the app build, the screenshot pipeline, the Microsoft 365 markdown archive and shared-folder links. Apple ID, ~9 GB.\n\n'
  printf '  SELECT      --pick (a menu)   --profile <name>   --only a,b,c   --except x\n'
  printf '  INSPECT     --list   --plan   --manifest   --egress   --verify\n\n'
}

# ── --egress — where your data can go. Writes nothing. ───────────────────────────────────────
# Two halves, and the second is the one that counts. The first prints what each module DECLARES
# through the optional `egress_<m>` verb: one line per host, `<host> <install|run> <purpose>`,
# where a declared-but-empty list means "no network at all". A module that declares nothing is
# printed as UNDECLARED and fails the report, because silence must never read as "local".
# The second half does not trust any declaration: assets/local-only-check.sh reads the machine —
# the configuration of every app and agent a module sets up — and fails when anything there can
# send local data to a cloud AI service. Exit 0 clean · 20 a cloud path is live or a module is
# undeclared · 30 the check could not run.
driver_cmd_egress() {
  local m f out rc=0 undeclared="" host when purpose first
  printf '\n  EGRESS — every host a module can reach. "install" = only while it installs; "run" = afterwards.\n\n'
  for m in $BOOTSTRAP_MANIFEST; do
    f="$(driver_module_file "$m")" || { printf '    %-21s (module file unavailable)\n' "$m"; rc=30; continue; }
    if ! driver_has_verb "$f" "$m" egress; then
      printf '    %-21s UNDECLARED — this module does not say where it connects\n' "$m"
      undeclared="$undeclared $m"; continue
    fi
    out="$(driver_call "$f" "$m" egress 2>/dev/null)" || out=""
    if [ -z "$out" ]; then printf '    %-21s none — no network at all\n' "$m"; continue; fi
    first=1
    while read -r host when purpose; do
      [ -n "$host" ] || continue
      if [ "$first" = 1 ]; then printf '    %-21s ' "$m"; first=0; else printf '    %-21s ' ''; fi
      printf '%-34s %-8s %s\n' "$host" "$when" "$purpose"
    done <<EOF
$out
EOF
  done
  printf '\n  Every coding agent sends what it reads to its own model provider — Claude Code to Anthropic (or\n'
  printf '  the Bedrock or Vertex account your company routes it to), Copilot CLI to GitHub (or the provider\n'
  printf '  COPILOT_PROVIDER_BASE_URL names). That is how an agent works; no module can change it, and none adds to it.\n'
  printf '\n  LOCAL-ONLY CHECK — read from this machine, not from the declarations above\n\n'
  # Executed, never sourced: it is a second, independent reader of what the modules configured.
  f="$BOOTSTRAP_ASSETS/local-only-check.sh"
  if [ -r "$f" ]; then
    /bin/bash "$f"
    case $? in
      0) : ;;
      1) [ "$rc" = 30 ] || rc=20 ;;
      *) rc=30 ;;
    esac
  else
    printf '    could not run: this release has no assets/local-only-check.sh\n'; rc=30
  fi
  if [ -n "$undeclared" ]; then
    printf '\n  UNDECLARED:%s — a module that does not declare its hosts is never assumed to be local.\n' "$undeclared"
    [ "$rc" = 30 ] || rc=20
  fi
  printf '\n'
  return "$rc"
}

# ── --pick — the menu ─────────────────────────────────────────────────────────────────────────
# One command has to serve a person who wants to choose, and three places that command runs:
# `curl … | bash` (stdin IS the script, so the answer cannot come from stdin), `bash file` in a
# terminal, and an agent's tool shell or CI, where there is no person to answer at all. So the menu
# reads from /dev/tty, never stdin, and is shown only when a person is visibly there. It is never
# waited on forever: an unanswered menu installs NOTHING, because an unattended run must never do
# something nobody chose.
#
# BOOTSTRAP_PICK_INPUT (a test seam) names a file of answers; the menu then goes to stderr.

# driver_pick_open — fd 4 carries the answers and fd 5 the menu. rc 1: nobody can answer.
# The open is tried in a SUBSHELL first: a failed `exec` redirection is not something to find out
# in the shell that is running the install.
driver_pick_open() {
  if [ -n "${BOOTSTRAP_PICK_INPUT:-}" ]; then
    [ -r "$BOOTSTRAP_PICK_INPUT" ] || return 1
    exec 4<"$BOOTSTRAP_PICK_INPUT" 5>&2
    return 0
  fi
  ( exec 4</dev/tty ) 2>/dev/null || return 1
  exec 4</dev/tty 5>/dev/tty
}
driver_pick_close() { exec 4<&- 5>&-; }

# driver_invocation — how to run THIS script again, for a hint the person can paste. Under
# `curl … | bash` there is no file and $0 is just "bash", which printed `bash bash --only …`.
driver_invocation() {
  local s="${BASH_SOURCE[0]:-}"
  if [ -n "$s" ] && [ -r "$s" ]; then printf 'bash %s' "$s"; else printf 'curl -fsSL <the same URL> | bash -s --'; fi
}

# driver_pick_auto — 0 iff the menu is the right default for THIS invocation: a plain install with
# nothing chosen by flag, and a person at a terminal. An agent's shell, CI, or output piped into a
# file all say "nobody is watching", and there the default profile runs as it always has.
driver_pick_auto() {
  [ "$BOOTSTRAP_MODE" = install ] || return 1
  [ "$BOOTSTRAP_PICK" = auto ] || return 1
  [ -z "$BOOTSTRAP_ONLY$BOOTSTRAP_EXCEPT$BOOTSTRAP_PROFILE" ] || return 1
  [ -z "${CI:-}${CLAUDECODE:-}${BOOTSTRAP_NONINTERACTIVE:-}" ] || return 1
  [ -t 1 ] || return 1
  ( exec 4</dev/tty ) 2>/dev/null
}

# driver_pick_read — one line from the person into PICK_LINE. rc 1 on end-of-input or a timeout.
PICK_LINE=""
driver_pick_read() {
  PICK_LINE=""
  IFS= read -r -t "${BOOTSTRAP_PICK_TIMEOUT:-1800}" PICK_LINE <&4 && return 0
  [ -n "$PICK_LINE" ]                         # a last line with no newline still counts
}

# driver_cmd_pick — sets BOOTSTRAP_ONLY to what the person chose, dependencies included.
# rc 0 chosen and confirmed · 30 they quit, or never answered (nothing was installed).
driver_cmd_pick() {
  local i n m f sel tok line resolved chosen k want
  local -a pm pp pw pc pon
  sel=" $(driver_select 2>/dev/null) " || return 30

  n=0
  for m in $BOOTSTRAP_MANIFEST; do
    f="$(driver_module_file "$m")" || continue
    pm[n]="$m"
    pp[n]="$(driver_meta "$f" "$m" profile standard)"
    pw[n]="$(driver_meta "$f" "$m" what "$m")"
    pc[n]="$(driver_meta "$f" "$m" cost unpriced)"
    case "$sel" in *" $m "*) pon[n]=1 ;; *) pon[n]=0 ;; esac
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { driver_note_out "bootstrap: no module could be read — nothing to choose from."; return 30; }

  while :; do
    printf '\n  Pick what to install. [x] is selected now.\n\n' >&5
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${pon[i]}" = 1 ]; then k='x'; else k=' '; fi
      line="${pw[i]}"
      [ "${#line}" -gt 62 ] && line="${line:0:59}..."
      printf '   [%s] %2d  %-21s %-8s %s\n' "$k" "$((i + 1))" "${pm[i]}" "${pp[i]}" "$line" >&5
      i=$((i + 1))
    done
    printf '\n  Type numbers to switch modules on or off (e.g. 5 7), or a profile: lite, standard, full, none.\n' >&5
    printf '  ?5 shows what module 5 costs. Press Enter when the list is right; q quits and installs nothing.\n  > ' >&5
    driver_pick_read || { printf '\n' >&5; driver_note_out "bootstrap: no answer — nothing was installed."; return 30; }

    if [ -z "$(printf '%s' "$PICK_LINE" | tr -d ' ')" ]; then
      chosen=""
      i=0; while [ "$i" -lt "$n" ]; do [ "${pon[i]}" = 1 ] && chosen="$chosen ${pm[i]}"; i=$((i + 1)); done
      if [ -z "$chosen" ]; then printf '\n  Nothing is selected. Pick at least one, or q to quit.\n' >&5; continue; fi
      BOOTSTRAP_ONLY="$chosen"; BOOTSTRAP_PROFILE=""; BOOTSTRAP_EXCEPT=""
      resolved="$(driver_select 2>&5)" || return 30
      printf '\n  This installs %s module(s):\n\n' "$(printf '%s' "$resolved" | wc -w | tr -d ' ')" >&5
      for m in $resolved; do
        i=0; while [ "$i" -lt "$n" ] && [ "${pm[i]}" != "$m" ]; do i=$((i + 1)); done
        printf '   %-21s %s\n' "$m" "${pc[i]:-unpriced}" >&5
      done
      printf '\n  Install these now? [Y/n] ' >&5
      driver_pick_read || { printf '\n' >&5; driver_note_out "bootstrap: no answer — nothing was installed."; return 30; }
      case "$(printf '%s' "$PICK_LINE" | tr -d ' ' | tr 'YN' 'yn')" in
        ''|y|yes) BOOTSTRAP_ONLY="$resolved"; return 0 ;;
        *)        continue ;;
      esac
    fi

    # The answer is word-split on purpose and must NOT be globbed: `?5` is a filename pattern, and in
    # a directory holding a two-character file ending in 5 it would arrive here as that file's name.
    set -f
    for tok in $PICK_LINE; do
      case "$tok" in
        q|Q|quit|exit) set +f; driver_note_out "bootstrap: you quit the menu — nothing was installed."; return 30 ;;
        lite|standard|full|all|none)
          want="$(driver_profile_rank "$tok")"; [ "$tok" = none ] && want=0
          i=0
          while [ "$i" -lt "$n" ]; do
            if [ "$(driver_profile_rank "${pp[i]}")" -le "$want" ]; then pon[i]=1; else pon[i]=0; fi
            i=$((i + 1))
          done ;;
        \?*)
          k="${tok#\?}"
          case "$k" in ''|*[!0-9]*) printf '  ?%s — which number?\n' "$k" >&5; continue ;; esac
          if [ "$k" -ge 1 ] && [ "$k" -le "$n" ]; then
            printf '\n  %s — %s\n  cost: %s\n' "${pm[k-1]}" "${pw[k-1]}" "${pc[k-1]}" >&5
          else printf '  there is no module %s\n' "$k" >&5; fi ;;
        *[!0-9]*) printf '  "%s" is not a number or a profile name\n' "$tok" >&5 ;;
        *)
          if [ "$tok" -ge 1 ] && [ "$tok" -le "$n" ]; then
            if [ "${pon[tok-1]}" = 1 ]; then pon[tok-1]=0; else pon[tok-1]=1; fi
          else printf '  there is no module %s\n' "$tok" >&5; fi ;;
      esac
    done
    set +f
  done
}

# ── --manifest — every file this release would write, and the sha256 of what it writes from. ──
# The point is diffability: a reader can take this list before and after and see exactly what
# changed on their machine, without trusting a word we say about it.
driver_cmd_manifest() {
  local m f
  printf '\n  MANIFEST — mac-bootstrap %s, pin %s\n\n' "$BOOTSTRAP_VERSION" "$BOOTSTRAP_PIN"
  printf '  Runtime state (never inside the repo):\n'
  printf '    %s/{receipt.json,receipt.verify.json,bootstrap.log,rows/,backups/,bin/}\n\n' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"
  printf '  Module sources and their hashes:\n'
  for m in $BOOTSTRAP_MANIFEST; do
    f="$(driver_module_file "$m")" || { printf '    %-16s UNAVAILABLE\n' "$m"; continue; }
    printf '    %-16s %s  %s\n' "$m" "$(shasum -a 256 "$f" 2>/dev/null | cut -c1-16)" "$f"
  done
  printf '\n  Assets:\n'
  # Every regular file under assets/, at any depth, in byte order — a fixed list of globs missed every
  # subfolder a module installs from (hooks/, succession/, microsoft365-archive/ and its fixtures,
  # shared-folders/). assets/diagrams/ is the README's pictures and is never installed; hidden files
  # (a Finder .DS_Store) are never in a release.
  while IFS= read -r f; do
    [ -r "$f" ] || continue
    printf '    %s  %s\n' "$(shasum -a 256 "$f" 2>/dev/null | cut -c1-16)" "${f#"$BOOTSTRAP_TREE"/}"
  done <<EOF
$([ -d "$BOOTSTRAP_TREE/assets" ] && find "$BOOTSTRAP_TREE/assets" -type f ! -path "$BOOTSTRAP_TREE/assets/diagrams/*" ! -name '.*' 2>/dev/null | LC_ALL=C sort)
EOF
  printf '\n  Nothing above has been written. Run --plan to see what would change.\n\n'
}

# ── --plan — writes NOTHING. Distinct from the removed --dry-run, which wrote the receipt. ─────
driver_cmd_plan() {
  local m f sel st
  sel="$(driver_select)" || return 30
  if [ -z "$sel" ]; then
    driver_note_out "bootstrap: this selection contains no modules — nothing to plan. Try --list."
    return 30
  fi
  printf '\n  PLAN — profile %s. This run writes NOTHING.\n\n' "${BOOTSTRAP_PROFILE:-$BOOTSTRAP_PROFILE_DEFAULT}"
  for m in $BOOTSTRAP_MANIFEST; do
    case " $sel " in *" $m "*) : ;; *) printf '    skip  %-16s (not in this selection)\n' "$m"; continue ;; esac
    f="$(driver_module_file "$m")" || { printf '    ??    %-16s module unavailable\n' "$m"; continue; }
    if driver_call "$f" "$m" verify >/dev/null 2>&1; then st="already satisfied — would do nothing"
    elif driver_call "$f" "$m" gate >/dev/null 2>&1; then st="NEEDS YOU: $(driver_note "$f" "$m")"
    else st="would install: $(driver_meta "$f" "$m" what "$m")"; fi
    printf '    %-16s %s\n' "$m" "$st"
  done
  printf '\n  Nothing above has happened. Run without --plan to act.\n\n'
}

# ── the self-authorization audit ─────────────────────────────────────────────────────────────
# HONEST FRAMING, because the alternative was measured and defeated: this is a DENYLIST OF
# SPELLINGS inside the fetched artifact, it was broken in three lines of string-splitting by the
# design's own reviewer, and modules are SOURCED so top-level code runs before any check of
# ours. The SHA pin on the fetched tree is the only real integrity control. This grep is
# defence-in-depth against OUR OWN mistakes and is not claimed to be more. The enforcement that
# is real lives in bootstrap_settings_merge, which refuses an authorization keypath at the one place
# that writes — the chokepoint, not the text.
driver_audit() {
  local f="$1" hit
  hit="$(grep -n -E 'permissions?\.allow|settings\.local\.json|allowedTools|--dangerously|add-generic-password|security +import' "$f" 2>/dev/null)" || hit=""
  [ -z "$hit" ] && return 0
  driver_fail "module $f looks like it writes an authorization surface; refusing to source it"
  printf '%s\n' "$hit" >&2
  return 1
}

# ── rows: the receipt's backing store, one small file per field per module. ──────────────────
# --only MERGES because of this: a module that was not selected keeps the row it already had.
# The design's own driver REPLACED the receipt with a one-module receipt, so the agent's input
# destroyed itself the first time it followed the instruction to re-drive one module.
driver_row_set() {                                  # driver_row_set <module> <state> <note> <gesture>
  printf '%s' "$2" > "$BOOTSTRAP_ROWS/$1.state" 2>/dev/null
  printf '%s' "${3:-}" > "$BOOTSTRAP_ROWS/$1.note" 2>/dev/null
  printf '%s' "${4:-}" > "$BOOTSTRAP_ROWS/$1.gesture" 2>/dev/null
}
driver_row_clear() { rm -f "$BOOTSTRAP_ROWS/$1.state" "$BOOTSTRAP_ROWS/$1.note" "$BOOTSTRAP_ROWS/$1.gesture" 2>/dev/null; }
driver_row_get()   { cat "$BOOTSTRAP_ROWS/$1.$2" 2>/dev/null; }

# Recovery: if the rows store was wiped but a receipt survives, rebuild the rows from it through
# plutil rather than losing the human gestures it is the only record of.
driver_rows_recover() {
  local i=0 m s n g
  [ -f "$BOOTSTRAP_RECEIPT" ] || return 0
  ls "$BOOTSTRAP_ROWS"/*.state >/dev/null 2>&1 && return 0
  while [ "$i" -lt 64 ]; do
    m="$(bootstrap_settings_get "$BOOTSTRAP_RECEIPT" "modules.$i.module" raw 2>/dev/null)" || break
    [ -n "$m" ] || break
    s="$(bootstrap_settings_get "$BOOTSTRAP_RECEIPT" "modules.$i.state" raw 2>/dev/null)" || s=""
    n="$(bootstrap_settings_get "$BOOTSTRAP_RECEIPT" "modules.$i.note" raw 2>/dev/null)" || n=""
    g="$(bootstrap_settings_get "$BOOTSTRAP_RECEIPT" "modules.$i.human_command" raw 2>/dev/null)" || g=""
    [ -n "$s" ] && driver_row_set "$m" "$s" "$n" "$g"
    i=$((i + 1))
  done
  [ "$i" -gt 0 ] && driver_log "recovered $i receipt row(s) into $BOOTSTRAP_ROWS"
  return 0
}

# ── the receipt ──────────────────────────────────────────────────────────────────────────────
# printf + explicit escaping. One double quote in a note or a gesture string made the file the
# agent is TOLD to parse unparseable, and every value below goes through bootstrap_json_escape.
driver_emit_receipt() {                             # driver_emit_receipt <path> <exit_code> [error]
  local out="$1" code="$2" err="${3:-}" f m first=1 tmp="$1.tmp.$$"
  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "generated_utc": "%s",\n' "$(date -u +%FT%TZ)"
    printf '  "mode": "%s",\n' "$(bootstrap_json_escape "$BOOTSTRAP_MODE")"
    printf '  "pin": "%s",\n' "$(bootstrap_json_escape "$BOOTSTRAP_PIN")"
    printf '  "host": "%s",\n' "$(bootstrap_json_escape "$(sw_vers -productVersion 2>/dev/null) $(uname -m 2>/dev/null)")"
    printf '  "driver_version": %s,\n' "$BOOTSTRAP_VERSION"
    printf '  "exit_code": %s,\n' "$code"
    [ -n "$err" ] && printf '  "error": "%s",\n' "$(bootstrap_json_escape "$err")"
    printf '  "modules": [\n'
    for f in "$BOOTSTRAP_ROWS"/*.state; do
      [ -r "$f" ] || continue
      m="${f##*/}"; m="${m%.state}"
      driver_in_manifest "$m" || continue
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '    {"module": "%s", "state": "%s", "note": "%s", "human_command": "%s"}' \
        "$(bootstrap_json_escape "$m")" \
        "$(bootstrap_json_escape "$(driver_row_get "$m" state)")" \
        "$(bootstrap_json_escape "$(driver_row_get "$m" note)")" \
        "$(bootstrap_json_escape "$(driver_row_get "$m" gesture)")"
    done
    [ "$first" = 1 ] || printf '\n'
    printf '  ]\n}\n'
  } > "$tmp" 2>/dev/null || { driver_fail "could not write $tmp"; return 1; }
  mv -f "$tmp" "$out" 2>/dev/null || { driver_fail "could not place $out"; return 1; }

  # THE LAST ACT OF EVERY RUN: parse the receipt back. NOTE, and do not "fix" this back:
  # `plutil -lint` — which the design named for this job — CANNOT validate JSON on macOS 15.
  # It lints property-list syntax, and reports `Unexpected character { at line 1` on a perfectly
  # valid receipt, and on the operator's own real ~/.claude/settings.json (both measured). The
  # arm that works is `plutil -convert json -o /dev/null`, plus jq as a second engine when it is
  # present. bootstrap_json_ok is that pair.
  if bootstrap_json_ok "$out"; then return 0; fi
  driver_fail "the receipt at $out did not parse back — this is a bug in the driver, not in your Mac."
  return 1
}

# ── module verbs ─────────────────────────────────────────────────────────────────────────────
# EVERY verb runs in its own SUBSHELL with the library and the module freshly sourced. Measured:
# a syntax error in a sourced file leaves the shell alive, but a bare `exit` in one KILLS IT —
# so a single stray `exit` in one module would end the whole run and every later module would
# silently never run. A subshell contains both. The cost is the contract in CONTRACT.md: no
# state survives between verbs; persist to disk if you need it.
driver_call() {                                     # driver_call <module-file> <module> <verb> [redirect-to-log]
  local mf="$1" m="$2" verb="$3" tolog="${4:-}"
  if [ "$tolog" = "log" ]; then
    # shellcheck disable=SC1090  # both paths are resolved at runtime by design
    ( . "$BOOTSTRAP_LIB" >/dev/null 2>&1; . "$mf" >/dev/null 2>&1 || exit 90
      command -v "${verb}_${m}" >/dev/null 2>&1 || exit 91
      "${verb}_${m}" ) >>"$BOOTSTRAP_LOG" 2>&1
  else
    # shellcheck disable=SC1090
    ( . "$BOOTSTRAP_LIB" >/dev/null 2>&1; . "$mf" >/dev/null 2>&1 || exit 90
      command -v "${verb}_${m}" >/dev/null 2>&1 || exit 91
      "${verb}_${m}" ) 2>>"$BOOTSTRAP_LOG"
  fi
}
driver_has_verb() {
  # shellcheck disable=SC1090
  ( . "$BOOTSTRAP_LIB" >/dev/null 2>&1; . "$1" >/dev/null 2>&1 || exit 1
    command -v "${3}_${2}" >/dev/null 2>&1 ) >/dev/null 2>&1
}

# A row whose module is NOT in this release's manifest is not evidence about this release —
# it is a ghost from an older one. It is excluded from both the receipt and the verdict, and in
# install/uninstall mode the file is removed. Without this, dropping a module from a release
# leaves a FAILED row that nothing can ever clear and every later run inherits it.
driver_in_manifest() {
  case " $BOOTSTRAP_MANIFEST " in *" $1 "*) return 0 ;; esac
  return 1
}
driver_prune_rows() {
  local f m
  for f in "$BOOTSTRAP_ROWS"/*.state; do
    [ -r "$f" ] || continue
    m="${f##*/}"; m="${m%.state}"
    driver_in_manifest "$m" && continue
    driver_log "pruning stale row for '$m' — not in this release's manifest"
    driver_row_clear "$m"
  done
}

# The CLOSED selection decides, never the raw --only list: driver_select adds each needs_ out loud,
# and a module it added must then run. Measured before this: `--only handoff` announced "handoff
# needs statusline — adding it", skipped statusline here, and exited 30 on its own "never
# evaluated" check — so no module with a dependency could be installed on its own.
driver_selected() {
  if [ -n "$BOOTSTRAP_SELECTED" ]; then
    case " $BOOTSTRAP_SELECTED " in *" $1 "*) return 0 ;; esac
    return 1
  fi
  [ -z "$BOOTSTRAP_ONLY" ] && return 0
  case " $BOOTSTRAP_ONLY " in *" $1 "*) return 0 ;; esac
  return 1
}

driver_note()    { local t; t="$(driver_call "$1" "$2" note)"    || t=""; [ -n "$t" ] || t="not installed"; printf '%s' "$t"; }
driver_gesture() { local t; t="$(driver_call "$1" "$2" gesture)" || t=""; printf '%s' "$t"; }

# ── the per-module state machine ─────────────────────────────────────────────────────────────
driver_run_module() {
  local m="$1" mf gated=0 note gesture rc

  driver_selected "$m" || return 0

  if ! mf="$(driver_module_file "$m")" || [ -z "$mf" ]; then
    driver_say "-- $m"
    driver_fail "not present at pin $BOOTSTRAP_PIN (no local modules/$m.sh, and nothing fetchable)"
    driver_row_set "$m" SKIPPED "module not shipped at pin $BOOTSTRAP_PIN" ""
    return 0
  fi
  driver_say "-- $m"
  driver_audit "$mf" || { driver_row_set "$m" FAILED "refused: looks like it writes an authorization surface" ""; return 0; }

  local v
  for v in verify gate note gesture install uninstall; do
    driver_has_verb "$mf" "$m" "$v" && continue
    driver_fail "$m does not implement ${v}_$m — see CONTRACT.md"
    driver_row_set "$m" FAILED "module does not implement ${v}_$m (see CONTRACT.md)" ""
    return 0
  done

  # gate-before-verify: gate_ is evaluated BEFORE any early return, so a gated module is always reported —
  # whatever mode we are in and whatever verify_ says next.
  driver_call "$mf" "$m" gate >/dev/null 2>&1 && gated=1

  case "$BOOTSTRAP_MODE" in
    uninstall)
      if driver_call "$mf" "$m" uninstall log; then driver_say "   removed"; driver_row_clear "$m"
      else driver_fail "uninstall_$m failed (see $BOOTSTRAP_LOG)"; driver_row_set "$m" FAILED "uninstall failed; see the log" ""; fi
      return 0 ;;
    bench)
      if driver_has_verb "$mf" "$m" bench; then
        driver_say "   bench: $BOOTSTRAP_BENCH"
        # A bench VERDICT is not a driver failure. `--bench` asks "is this model fit?", and
        # REJECTED is a successful measurement with a negative answer — mapping it onto exit 20
        # ("something FAILED, read the log") both mis-describes it and, before this, was not
        # propagated at all. 90/91 are driver_call's own sentinels and ARE real failures.
        driver_call "$mf" "$m" bench
        BOOTSTRAP_BENCH_RC=$?
        case "$BOOTSTRAP_BENCH_RC" in
          90|91) driver_fail "bench_$m could not be sourced, or the module does not define it"
                 BOOTSTRAP_BENCH_RC=2; BOOTSTRAP_RC=30 ;;
          *)     BOOTSTRAP_BENCHED=1 ;;
        esac
      fi
      return 0 ;;
  esac

  if driver_call "$mf" "$m" verify >/dev/null 2>&1; then
    driver_say "   satisfied (verified by read-back)"
    driver_row_set "$m" SATISFIED "verified by read-back" ""
    return 0
  fi

  if [ "$gated" = 1 ]; then
    note="$(driver_note "$mf" "$m")"; gesture="$(driver_gesture "$mf" "$m")"
    driver_say "   needs you: $note"
    [ -n "$gesture" ] && driver_say "      $gesture"
    driver_row_set "$m" NEEDS_HUMAN "$note" "$gesture"
    return 0
  fi

  if [ "$BOOTSTRAP_MODE" = verify ]; then
    driver_fail "not installed"
    driver_row_set "$m" FAILED "not installed — run without --verify to install it" ""
    return 0
  fi

  driver_call "$mf" "$m" install log
  rc=$?
  if [ "$rc" = 0 ]; then
    if driver_call "$mf" "$m" verify >/dev/null 2>&1; then
      driver_say "   installed and verified"
      driver_row_set "$m" SATISFIED "verified by read-back" ""
    else
      # Rule 2: the installer's own exit code is never the verdict.
      driver_fail "install_$m exited 0 but verify_$m disagreed"
      driver_row_set "$m" FAILED "installer exited 0 but the read-back disagreed; see the log" ""
    fi
    return 0
  fi

  # An installer may DISCOVER a gate it could not see beforehand. Ask the module again before
  # calling this a failure — a human gesture reported as FAILED sends the reader to the log for
  # a bug that is not there.
  if driver_call "$mf" "$m" gate >/dev/null 2>&1; then
    note="$(driver_note "$mf" "$m")"; gesture="$(driver_gesture "$mf" "$m")"
    driver_say "   needs you: $note"
    [ -n "$gesture" ] && driver_say "      $gesture"
    driver_row_set "$m" NEEDS_HUMAN "$note" "$gesture"
    return 0
  fi
  case "$rc" in
    90) driver_fail "$m could not be sourced (syntax error?) — see $BOOTSTRAP_LOG"
        driver_row_set "$m" FAILED "module could not be sourced" "" ;;
    91) driver_fail "install_$m vanished between the contract check and the call"
        driver_row_set "$m" FAILED "install_$m not defined" "" ;;
    *)  driver_fail "install_$m exited $rc (see $BOOTSTRAP_LOG)"
        driver_row_set "$m" FAILED "installer exited $rc; see ~/.mac-bootstrap/bootstrap.log" "" ;;
  esac
  return 0
}

# ── the aggregate verdict ────────────────────────────────────────────────────────────────────
# THE FOUR MEASURED FALSE SIGNALS THIS FUNCTION EXISTS TO KILL. Each was reproduced on this
# machine against the version that shipped before it, and each one now has a fixture below.
#
#   1. `--only handoff` on a FRESH Mac exited 0 and printed "every module satisfied", with
#      seven of the eight deliverables never evaluated and no statusline installed at all. An
#      unselected module writes no row, the verdict only ever looked at rows that EXIST, and the
#      one prompt the agent follows teaches 0 = done two steps earlier. A manifest module with no
#      row was never judged, and a run that never judged it is not a verdict about the machine.
#   2. An UNRECOGNISED row state ("BANANA") exited 0: the case had no default, so anything that is
#      not one of the four literals fell through to the all-satisfied return.
#   3. An EMPTY row state — what a truncated or failed driver_row_set write leaves behind — exited 0
#      for the same reason.
#   4. A COMPLETELY SUCCESSFUL `--uninstall` exited 30, i.e. "this run is NOT a verdict about your
#      Mac", because uninstall CLEARS every row and zero rows hit the "nothing assembled" arm.
#      Zero rows is uninstall's correct terminal state, and only uninstall's.

# driver_missing_rows — the manifest modules that have NO row, i.e. were never evaluated here.
# It PRINTS, because driver_verdict is called in a command substitution and a variable assigned in
# one never escapes it.
driver_missing_rows() {
  local m out="" scope
  # Scored over the SELECTION, never the manifest. The false green was "--only left 7 of 8
  # unevaluated and exit 0 said every module satisfied"; the cure must not become "a deliberate
  # --profile lite can never exit 0", which would make the whole selection feature unreachable.
  # A module the user did not select is not an unevaluated module, it is a declined one — and the
  # verdict line names the selection, so 0 cannot be read as a claim about the other four.
  scope="${BOOTSTRAP_SELECTED:-$BOOTSTRAP_MANIFEST}"
  for m in $scope; do
    [ -r "$BOOTSTRAP_ROWS/$m.state" ] || out="$out $m"
  done
  printf '%s' "${out# }"
}

driver_verdict() {
  local f s m any=0 failed=0 human=0 skipped=0 unknown=0
  for f in "$BOOTSTRAP_ROWS"/*.state; do
    [ -r "$f" ] || continue
    m="${f##*/}"; m="${m%.state}"
    driver_in_manifest "$m" || continue
    any=1; s="$(cat "$f" 2>/dev/null)"
    case "$s" in
      SATISFIED)   : ;;
      FAILED)      failed=1 ;;
      NEEDS_HUMAN) human=1 ;;
      SKIPPED)     skipped=1 ;;
      *)           unknown=1 ;;    # empty, truncated, or not one of the four. FAIL CLOSED.
    esac
  done

  # An uninstall REMOVES rows, so missing rows are its success and zero rows is its terminal
  # state. A row it could not clear is still a failure, and a state nobody can read is still 30.
  if [ "$BOOTSTRAP_MODE" = uninstall ]; then
    # SKIPPED here means the module file could not be resolved, so its uninstall_ was never even
    # attempted — a precondition error, not a removal. It must not read as "everything removed".
    [ "$unknown" = 1 ] && { printf '30'; return 0; }
    [ "$skipped" = 1 ] && { printf '30'; return 0; }
    [ "$failed" = 1 ]  && { printf '20'; return 0; }
    printf '0'; return 0
  fi

  [ "$any" = 0 ] && { printf '30'; return 0; }
  [ -n "$(driver_missing_rows)" ] && { printf '30'; return 0; }
  [ "$unknown" = 1 ] && { printf '30'; return 0; }
  [ "$skipped" = 1 ] && { printf '30'; return 0; }
  [ "$failed" = 1 ] && { printf '20'; return 0; }
  [ "$human" = 1 ] && { printf '10'; return 0; }
  printf '0'
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
driver_say "mac-bootstrap $BOOTSTRAP_VERSION · mode=$BOOTSTRAP_MODE · pin=$BOOTSTRAP_PIN · $(sw_vers -productVersion 2>/dev/null) $(uname -m 2>/dev/null)"
bootstrap_have_jq || driver_say "note: jq is not on this machine — every step below uses the plutil path instead."

driver_rows_recover

BOOTSTRAP_MANIFEST="$(driver_manifest)"
BOOTSTRAP_BENCHED=0
BOOTSTRAP_BENCH_RC=2          # 0 PASS · 1 REJECTED · 2 nothing was measured. 2 until a bench says otherwise.
BOOTSTRAP_ERR=""

if [ -z "$BOOTSTRAP_MANIFEST" ]; then
  BOOTSTRAP_ERR="no modules: none beside this script, and pin '$BOOTSTRAP_PIN' is not fetchable"
  driver_fail "$BOOTSTRAP_ERR"
else
  # READ-ONLY MODES FIRST. Each writes nothing at all — no receipt, no rows, no backups — so a
  # stranger can see exactly what this thing would do before letting it do anything. That is the
  # whole reason they exist, and it is why they exit here rather than falling through.
  case "$BOOTSTRAP_MODE" in
    list)     driver_cmd_list;     exit $? ;;
    plan)     driver_cmd_plan;     exit $? ;;
    manifest) driver_cmd_manifest; exit $? ;;
    egress)   driver_cmd_egress;   exit $? ;;
  esac

  # THE MENU, before anything is judged or written. It is closed again before any module runs, so
  # no module can ever read the person's terminal.
  if [ "$BOOTSTRAP_PICK" = yes ] && [ "$BOOTSTRAP_MODE" != install ]; then
    driver_fail "--pick chooses what to INSTALL; it does not combine with --$BOOTSTRAP_MODE"
    exit 30
  fi
  if [ "$BOOTSTRAP_PICK" = yes ] || driver_pick_auto; then
    if ! driver_pick_open; then
      driver_fail "--pick needs a person at a terminal, and this shell has none (an agent or CI?)."
      driver_fail "   Name the modules instead:  $(driver_invocation) --only <a,b,c>    (--list shows them)"
      exit 30
    fi
    driver_cmd_pick; driver_pick_rc=$?
    driver_pick_close
    [ "$driver_pick_rc" = 0 ] || exit "$driver_pick_rc"
    driver_say ""
    driver_say "chosen: $BOOTSTRAP_ONLY"
    driver_say "   the same run without the menu:  $(driver_invocation) --only $(printf '%s' "$BOOTSTRAP_ONLY" | tr ' ' ',')"
  elif [ "$BOOTSTRAP_MODE" = install ] && [ "$BOOTSTRAP_PICK" = auto ] \
       && [ -z "$BOOTSTRAP_ONLY$BOOTSTRAP_EXCEPT$BOOTSTRAP_PROFILE" ]; then
    driver_say "no terminal to ask you on, so this installs the default profile ($BOOTSTRAP_PROFILE_DEFAULT). To choose: run it in a terminal, or pass --only / --profile."
  fi

  BOOTSTRAP_SELECTED="$(driver_select)"
  if [ -z "$BOOTSTRAP_SELECTED" ]; then
    BOOTSTRAP_ERR="the selection is empty: profile '${BOOTSTRAP_PROFILE:-$BOOTSTRAP_PROFILE_DEFAULT}'${BOOTSTRAP_ONLY:+, --only$BOOTSTRAP_ONLY}${BOOTSTRAP_EXCEPT:+, --except$BOOTSTRAP_EXCEPT} leaves no module to act on. Try --list."
    driver_fail "$BOOTSTRAP_ERR"
  else
    [ -z "$BOOTSTRAP_ONLY" ] && driver_say "selection: ${BOOTSTRAP_PROFILE:-$BOOTSTRAP_PROFILE_DEFAULT} -> $(printf '%s' "$BOOTSTRAP_SELECTED" | wc -w | tr -d ' ') of $(printf '%s' "$BOOTSTRAP_MANIFEST" | wc -w | tr -d ' ') modules  (--list to see the rest)"
    # shellcheck disable=SC2086  # the selection is a deliberately word-split list
    for driver_m in $BOOTSTRAP_SELECTED; do driver_run_module "$driver_m"; done
  fi
fi

case "$BOOTSTRAP_MODE" in install|uninstall) driver_prune_rows ;; esac

# If NOTHING could be resolved, say so once, at the top of the receipt, in a sentence. Eight
# identical SKIPPED rows state a fact and explain nothing.
driver_all_skipped() {
  local f n=0 k=0
  for f in "$BOOTSTRAP_ROWS"/*.state; do
    [ -r "$f" ] || continue
    n=$((n + 1)); [ "$(cat "$f" 2>/dev/null)" = "SKIPPED" ] && k=$((k + 1))
  done
  [ "$n" -gt 0 ] && [ "$n" = "$k" ]
}
if [ -z "$BOOTSTRAP_ERR" ] && driver_all_skipped; then
  case "$BOOTSTRAP_PIN" in
    __PIN_SHA__|main|master|"")
      BOOTSTRAP_ERR="no module ran: there is no modules/ directory beside bootstrap.sh, and BOOTSTRAP_PIN is '$BOOTSTRAP_PIN' — not a release sha, so nothing can be fetched. Run this from a clone of the repo, or set BOOTSTRAP_PIN to a release commit." ;;
    *)
      BOOTSTRAP_ERR="no module ran: none of them could be fetched from $BOOTSTRAP_RAW — check the pin and your network." ;;
  esac
  driver_fail "$BOOTSTRAP_ERR"
fi

if [ -n "$BOOTSTRAP_ONLY" ]; then
  for driver_m in $BOOTSTRAP_ONLY; do
    case " $BOOTSTRAP_MANIFEST " in
      *" $driver_m "*) : ;;
      *) driver_fail "--only $driver_m: no such module in this release"; BOOTSTRAP_ERR="--only named a module that does not exist: $driver_m"; BOOTSTRAP_RC=30 ;;
    esac
  done
fi

# NAME THE MODULES THIS RUN NEVER JUDGED, so the 30 driver_verdict returns for them carries its
# reason. Measured before this existed: `--only handoff` on a fresh Mac printed "exit 0 — every
# module satisfied" with seven deliverables never evaluated and no statusline on disk at all.
# bench is excluded because it exits below without ever consulting the verdict.
if [ "$BOOTSTRAP_MODE" != uninstall ] && [ "$BOOTSTRAP_MODE" != bench ] && [ -z "$BOOTSTRAP_ERR" ]; then
  BOOTSTRAP_UNEVALUATED="$(driver_missing_rows)"
  if [ -n "$BOOTSTRAP_UNEVALUATED" ]; then
    BOOTSTRAP_UNEVALUATED_N=0
    for driver_m in $BOOTSTRAP_UNEVALUATED; do BOOTSTRAP_UNEVALUATED_N=$((BOOTSTRAP_UNEVALUATED_N + 1)); done
    BOOTSTRAP_ERR="$BOOTSTRAP_UNEVALUATED_N module(s) you selected were never evaluated ($BOOTSTRAP_UNEVALUATED) — so this run is not a verdict about them. That is a defect, not a narrowing: report it."
    driver_fail "$BOOTSTRAP_ERR"
  fi
fi

case "$BOOTSTRAP_MODE" in
  bench)
    # A bench MEASURES; it changes nothing and it must not touch the receipt the agent reads.
    if [ "$BOOTSTRAP_BENCHED" = 0 ] && [ "$BOOTSTRAP_RC" = 0 ]; then
      driver_fail "no module in scope implements bench_ — nothing was measured"
      BOOTSTRAP_RC=30
    fi
    driver_say ""
    driver_say "bench only: no state changed, and $BOOTSTRAP_RECEIPT was not touched."
    # --bench carries the GATE's verdict, not the 0/10/20/30 install scale: a rejected candidate
    # says nothing about the machine, which is what that scale describes.
    [ "$BOOTSTRAP_RC" = 30 ] && exit 30
    exit "$BOOTSTRAP_BENCH_RC" ;;
  uninstall)
    BOOTSTRAP_RECEIPT_PATH="$BOOTSTRAP_RECEIPT" ;;
  verify)
    BOOTSTRAP_RECEIPT_PATH="$BOOTSTRAP_VERIFY_RECEIPT" ;;
  *)
    BOOTSTRAP_RECEIPT_PATH="$BOOTSTRAP_RECEIPT" ;;
esac

BOOTSTRAP_EXIT_CODE="$(driver_verdict)"
[ "$BOOTSTRAP_RC" = 30 ] && BOOTSTRAP_EXIT_CODE=30
[ -n "$BOOTSTRAP_ERR" ] && BOOTSTRAP_EXIT_CODE=30
driver_emit_receipt "$BOOTSTRAP_RECEIPT_PATH" "$BOOTSTRAP_EXIT_CODE" "$BOOTSTRAP_ERR" || BOOTSTRAP_EXIT_CODE=30

driver_say ""
driver_say "receipt: $BOOTSTRAP_RECEIPT_PATH"
driver_say "log:     $BOOTSTRAP_LOG"
case "$BOOTSTRAP_EXIT_CODE" in
  0)  if [ "$BOOTSTRAP_MODE" = uninstall ]; then driver_say "exit 0  — every module removed."
      else driver_say "exit 0  — every module in this selection is satisfied ($(printf '%s' "${BOOTSTRAP_SELECTED:-$BOOTSTRAP_MANIFEST}" | wc -w | tr -d ' ') of $(printf '%s' "$BOOTSTRAP_MANIFEST" | wc -w | tr -d ' ') available). Run --list to see what you did not select."; fi ;;
  10) driver_say "exit 10 — satisfied except for the step(s) marked NEEDS_HUMAN in the receipt." ;;
  20) driver_say "exit 20 — something FAILED. Read the log, fix the cause, then re-run --only <module>." ;;
  30) driver_say "exit 30 — precondition error: this run is NOT a verdict about your Mac." ;;
esac
exit "$BOOTSTRAP_EXIT_CODE"
