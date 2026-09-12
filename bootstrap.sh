#!/bin/bash
# mac-bootstrap — the driver.
#
# Bootstraps a new Mac for an agent workflow that must work under BOTH Claude Code and GitHub
# Copilot CLI. It DRIVES every reversible step and RECORDS every step it must not take:
# a GUI permission, a Keychain dialog, sudo, an Apple ID, the App Store, money. It never
# attempts one of those and it never writes your agent's permissions, allowlists or credentials.
#
#   bash bootstrap.sh                  install everything that is installable, then verify it
#   bash bootstrap.sh --verify         re-read the machine cold; change nothing
#   bash bootstrap.sh --only statusline      re-drive ONE module (merges into the receipt)
#   bash bootstrap.sh --only rewrite_model --bench qwen3:8b     measure a candidate, write nothing
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
BOOTSTRAP_PIN="${BOOTSTRAP_PIN:-c6c81f08315d3c47eb3f6553db1f24f6f3965cf6}"          # replaced at release time. NEVER "main": a main-pinned
                                         # raw URL serves up to 5 minutes of stale Fastly bytes.
BOOTSTRAP_RAW="https://raw.githubusercontent.com/$BOOTSTRAP_REPO/$BOOTSTRAP_PIN"

BOOTSTRAP_STATE_DIR="$HOME/.mac-bootstrap"
BOOTSTRAP_LOG="$BOOTSTRAP_STATE_DIR/bootstrap.log"
BOOTSTRAP_ROWS="$BOOTSTRAP_STATE_DIR/rows"
BOOTSTRAP_CACHE="$BOOTSTRAP_STATE_DIR/modules"
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
BOOTSTRAP_MODULE_ORDER="statusline instructions hooks handoff pane_equalize voiceink rewrite_model screenshot"

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
  sed -n '2,32p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
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
    --profile)   [ $# -ge 2 ] || { printf 'bootstrap: --profile needs a name (lite|standard|full|all)\n' >&2; exit 30; }
                 BOOTSTRAP_PROFILE="$2"; shift ;;
    --except)    [ $# -ge 2 ] || { printf 'bootstrap: --except needs a module name\n' >&2; exit 30; }
                 BOOTSTRAP_EXCEPT="$BOOTSTRAP_EXCEPT $(printf '%s' "$2" | tr ',' ' ')"; shift ;;
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
mkdir -p "$BOOTSTRAP_STATE_DIR" "$BOOTSTRAP_ROWS" "$BOOTSTRAP_CACHE" "$BOOTSTRAP_STATE_DIR/backups" 2>/dev/null || {
  printf 'bootstrap: cannot create %s\n' "$BOOTSTRAP_STATE_DIR" >&2; exit 30; }
# fd 3 is the durable log; stdout stays human-readable and stderr stays STDERR.
# NOT `exec 3>>"$BOOTSTRAP_LOG" 2>/dev/null`: that spelling is two redirections on one exec, and the
# second one silently sends THE WHOLE SCRIPT'S stderr to /dev/null for the rest of the run —
# measured here, it swallowed every driver_fail line while the log recorded them perfectly, so the
# terminal showed eight modules and not one word about why none of them ran.
if : >>"$BOOTSTRAP_LOG" 2>/dev/null; then exec 3>>"$BOOTSTRAP_LOG"; else exec 3>/dev/null; fi
export BOOTSTRAP_LOG="$BOOTSTRAP_LOG"
export BOOTSTRAP_STATE_DIR="$BOOTSTRAP_STATE_DIR"

# ── the shared library. One copy, sourced by the driver, the modules and the hooks. ──────────
BOOTSTRAP_LIB=""
for c in "$BOOTSTRAP_HERE/assets/hooks/bootstrap-lib.sh" "$BOOTSTRAP_STATE_DIR/assets/hooks/bootstrap-lib.sh"; do
  [ -r "$c" ] && { BOOTSTRAP_LIB="$c"; break; }
done
if [ -z "$BOOTSTRAP_LIB" ]; then
  mkdir -p "$BOOTSTRAP_STATE_DIR/assets/hooks" 2>/dev/null
  if driver_fetch_ok=$(curl -sS -L -o "$BOOTSTRAP_STATE_DIR/assets/hooks/bootstrap-lib.sh.part" -w '%{http_code}' \
        "$BOOTSTRAP_RAW/assets/hooks/bootstrap-lib.sh" 2>/dev/null) && [ "$driver_fetch_ok" = "200" ] \
        && [ -s "$BOOTSTRAP_STATE_DIR/assets/hooks/bootstrap-lib.sh.part" ]; then
    mv -f "$BOOTSTRAP_STATE_DIR/assets/hooks/bootstrap-lib.sh.part" "$BOOTSTRAP_STATE_DIR/assets/hooks/bootstrap-lib.sh"
    BOOTSTRAP_LIB="$BOOTSTRAP_STATE_DIR/assets/hooks/bootstrap-lib.sh"
  else
    rm -f "$BOOTSTRAP_STATE_DIR/assets/hooks/bootstrap-lib.sh.part" 2>/dev/null
    printf 'bootstrap: cannot find or fetch assets/hooks/bootstrap-lib.sh (pin=%s).\n' "$BOOTSTRAP_PIN" >&2
    printf '  Run this from a clone of the repo, or cut a release and set BOOTSTRAP_PIN.\n' >&2
    exit 30
  fi
fi
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
export BOOTSTRAP_ASSETS="$BOOTSTRAP_HERE/assets"

# ── fetch ────────────────────────────────────────────────────────────────────────────────────
driver_fetch() {                                    # driver_fetch <relpath> <dest>  → 0 on a real 200
  local rel="$1" dest="$2" code
  case "$BOOTSTRAP_PIN" in
    __PIN_SHA__|main|master|"")
      driver_log "fetch refused for $rel: pin is '$BOOTSTRAP_PIN' (unreleased, or a moving ref)"; return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || { driver_log "fetch: no curl"; return 1; }
  code="$(curl -sS -L -o "$dest.part" -w '%{http_code}' "$BOOTSTRAP_RAW/$rel" 2>/dev/null)" || {
    rm -f "$dest.part" 2>/dev/null; driver_log "fetch: curl failed for $rel"; return 1; }
  [ "$code" = "200" ] || { rm -f "$dest.part" 2>/dev/null; driver_log "fetch: HTTP $code for $rel"; return 1; }
  [ -s "$dest.part" ] || { rm -f "$dest.part" 2>/dev/null; driver_log "fetch: empty body for $rel"; return 1; }
  mv -f "$dest.part" "$dest"
}

# ── the manifest ─────────────────────────────────────────────────────────────────────────────
# 1. BOOTSTRAP_MODULES (explicit, used by the tests)  2. modules/ beside this script  3. the built-in
# list, fetched. Order matters: a clone must never silently run a stale fetched copy.
driver_manifest() {
  local f n out=""
  if [ -n "${BOOTSTRAP_MODULES:-}" ]; then printf '%s' "$BOOTSTRAP_MODULES"; return 0; fi
  if [ -d "$BOOTSTRAP_HERE/modules" ]; then
    for f in "$BOOTSTRAP_HERE/modules"/*.sh; do
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

driver_module_file() {                              # prints the readable path, or nothing
  local m="$1"
  [ -r "$BOOTSTRAP_HERE/modules/$m.sh" ] && { printf '%s' "$BOOTSTRAP_HERE/modules/$m.sh"; return 0; }
  [ -r "$BOOTSTRAP_CACHE/$m.sh" ] && { printf '%s' "$BOOTSTRAP_CACHE/$m.sh"; return 0; }
  driver_fetch "modules/$m.sh" "$BOOTSTRAP_CACHE/$m.sh" >/dev/null 2>&1 && {
    printf '%s' "$BOOTSTRAP_CACHE/$m.sh"; return 0; }
  return 1
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
  printf '    standard  lite + the succession engine and a local rewrite model.\n'
  printf '    full      standard + the app build and the screenshot pipeline. Apple ID, ~9 GB.\n\n'
  printf '  SELECT      --profile <name>   --only a,b,c   --except x\n'
  printf '  INSPECT     --list   --plan   --manifest   --verify\n\n'
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
  for f in "$BOOTSTRAP_HERE"/assets/*.sh "$BOOTSTRAP_HERE"/assets/*.md "$BOOTSTRAP_HERE"/assets/hammerspoon/init.lua; do
    [ -r "$f" ] || continue
    printf '    %s  %s\n' "$(shasum -a 256 "$f" 2>/dev/null | cut -c1-16)" "${f#"$BOOTSTRAP_HERE"/}"
  done
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

driver_selected() {
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
        if driver_call "$mf" "$m" bench; then BOOTSTRAP_BENCHED=1; else driver_fail "bench_$m exited non-zero"; BOOTSTRAP_RC=20; fi
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
  esac

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
    exit "$BOOTSTRAP_RC" ;;
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
