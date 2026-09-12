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
#   bash bootstrap.sh --only m1_statusline      re-drive ONE module (merges into the receipt)
#   bash bootstrap.sh --only m7_model --bench qwen3:8b     measure a candidate, write nothing
#   bash bootstrap.sh --only m7_model --model qwen3:8b     install with a parameter
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

MB_VERSION=1
MB_REPO="renchris/mac-bootstrap"
MB_PIN="${MB_PIN:-e3493657d2226e39c9307f5f0b4e311aefc21eeb}"          # replaced at release time. NEVER "main": a main-pinned
                                         # raw URL serves up to 5 minutes of stale Fastly bytes.
MB_RAW="https://raw.githubusercontent.com/$MB_REPO/$MB_PIN"

MB_STATE="$HOME/.mac-bootstrap"
MB_LOG="$MB_STATE/bootstrap.log"
MB_ROWS="$MB_STATE/rows"
MB_CACHE="$MB_STATE/modules"
MB_RECEIPT="$MB_STATE/receipt.json"
MB_VRECEIPT="$MB_STATE/receipt.verify.json"

MB_MODE=install
MB_ONLY=""
MB_EXCEPT=""
MB_SELECTED=""
MB_PROFILE=""            # empty => the default profile below
MB_PROFILE_DEFAULT=lite    # the safest useful set: config files only, no installs, no gestures
MB_BENCH=""
MB_MODEL=""
MB_RC=0

# The manifest of last resort: used only when there is no modules/ directory beside this script,
# i.e. when bootstrap.sh was curl'd on its own. A module that is not in the release at this pin
# is recorded SKIPPED, which is a precondition error (30) — never a silent absence.
MB_MANIFEST_DEFAULT="m1_statusline m2_instructions m3_hooks m4_handoff m5_panes m6_voiceink m7_model m8_screenshot"

mb_self_dir() {
  local s="${BASH_SOURCE[0]:-$0}" d
  d="$(cd "$(dirname "$s")" 2>/dev/null && pwd -P)" || d="."
  printf '%s' "$d"
}
MB_HERE="$(mb_self_dir)"

# ── output ───────────────────────────────────────────────────────────────────────────────────
mb_say()  { printf '%s\n' "$*"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&3 2>/dev/null; }
mb_fail() { printf '  x %s\n' "$*" >&2; printf '%s FAIL %s\n' "$(date -u +%FT%TZ)" "$*" >&3 2>/dev/null; }
mb_log()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&3 2>/dev/null; return 0; }

mb_help() {
  sed -n '2,32p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# ── flags ────────────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --verify)    MB_MODE=verify ;;
    --uninstall) MB_MODE=uninstall ;;
    --only)      [ $# -ge 2 ] || { printf 'bootstrap: --only needs a module name\n' >&2; exit 30; }
                 MB_ONLY="$MB_ONLY $(printf '%s' "$2" | tr ',' ' ')"; shift ;;
    --bench)     [ $# -ge 2 ] || { printf 'bootstrap: --bench needs a model name\n' >&2; exit 30; }
                 MB_MODE=bench; MB_BENCH="$2"; shift ;;
    --model)     [ $# -ge 2 ] || { printf 'bootstrap: --model needs a name\n' >&2; exit 30; }
                 MB_MODEL="$2"; shift ;;
    --list)      MB_MODE=list ;;
    --plan)      MB_MODE=plan ;;
    --manifest)  MB_MODE=manifest ;;
    --profile)   [ $# -ge 2 ] || { printf 'bootstrap: --profile needs a name (lite|standard|full|all)\n' >&2; exit 30; }
                 MB_PROFILE="$2"; shift ;;
    --except)    [ $# -ge 2 ] || { printf 'bootstrap: --except needs a module name\n' >&2; exit 30; }
                 MB_EXCEPT="$MB_EXCEPT $(printf '%s' "$2" | tr ',' ' ')"; shift ;;
    --help|-h)   mb_help; exit 0 ;;
    --dry-run)   printf 'bootstrap: --dry-run was REMOVED, not renamed.\n' >&2
                 printf '  It overwrote the receipt and exited 0 on a machine where nothing was\n' >&2
                 printf '  installed. Use:  bash %s --verify\n' "${0##*/}" >&2
                 exit 30 ;;
    *)           printf 'bootstrap: unknown argument: %s   (try --help)\n' "$1" >&2; exit 30 ;;
  esac
  shift
done

# ── state ────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$MB_STATE" "$MB_ROWS" "$MB_CACHE" "$MB_STATE/backups" 2>/dev/null || {
  printf 'bootstrap: cannot create %s\n' "$MB_STATE" >&2; exit 30; }
# fd 3 is the durable log; stdout stays human-readable and stderr stays STDERR.
# NOT `exec 3>>"$MB_LOG" 2>/dev/null`: that spelling is two redirections on one exec, and the
# second one silently sends THE WHOLE SCRIPT'S stderr to /dev/null for the rest of the run —
# measured here, it swallowed every mb_fail line while the log recorded them perfectly, so the
# terminal showed eight modules and not one word about why none of them ran.
if : >>"$MB_LOG" 2>/dev/null; then exec 3>>"$MB_LOG"; else exec 3>/dev/null; fi
export PB_LOG="$MB_LOG"
export PB_STATE_DIR="$MB_STATE"

# ── the shared library. One copy, sourced by the driver, the modules and the hooks. ──────────
MB_LIB=""
for c in "$MB_HERE/assets/hooks/pb-lib.sh" "$MB_STATE/assets/hooks/pb-lib.sh"; do
  [ -r "$c" ] && { MB_LIB="$c"; break; }
done
if [ -z "$MB_LIB" ]; then
  mkdir -p "$MB_STATE/assets/hooks" 2>/dev/null
  if mb_fetch_ok=$(curl -sS -L -o "$MB_STATE/assets/hooks/pb-lib.sh.part" -w '%{http_code}' \
        "$MB_RAW/assets/hooks/pb-lib.sh" 2>/dev/null) && [ "$mb_fetch_ok" = "200" ] \
        && [ -s "$MB_STATE/assets/hooks/pb-lib.sh.part" ]; then
    mv -f "$MB_STATE/assets/hooks/pb-lib.sh.part" "$MB_STATE/assets/hooks/pb-lib.sh"
    MB_LIB="$MB_STATE/assets/hooks/pb-lib.sh"
  else
    rm -f "$MB_STATE/assets/hooks/pb-lib.sh.part" 2>/dev/null
    printf 'bootstrap: cannot find or fetch assets/hooks/pb-lib.sh (pin=%s).\n' "$MB_PIN" >&2
    printf '  Run this from a clone of the repo, or cut a release and set MB_PIN.\n' >&2
    exit 30
  fi
fi
# shellcheck source=assets/hooks/pb-lib.sh
. "$MB_LIB" || { printf 'bootstrap: pb-lib.sh did not load\n' >&2; exit 30; }
export PB_LIB="$MB_LIB"

# ── THE ENVIRONMENT CONTRACT (C10). A sourced module cannot take flags, so parameters arrive
#    as exported variables. These names are the contract; CONTRACT.md is their documentation.
export PB_MODE="$MB_MODE"
export PB_MODEL="$MB_MODEL"
export PB_BENCH="$MB_BENCH"
export PB_PIN="$MB_PIN"
export PB_RAW="$MB_RAW"
export PB_ASSETS="$MB_HERE/assets"
# Compatibility aliases for the spelling the architecture document used for m7's parameters.
export PB_M7_MODEL="$MB_MODEL"
export PB_M7_BENCH="$MB_BENCH"

# ── fetch ────────────────────────────────────────────────────────────────────────────────────
mb_fetch() {                                    # mb_fetch <relpath> <dest>  → 0 on a real 200
  local rel="$1" dest="$2" code
  case "$MB_PIN" in
    __PIN_SHA__|main|master|"")
      mb_log "fetch refused for $rel: pin is '$MB_PIN' (unreleased, or a moving ref)"; return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || { mb_log "fetch: no curl"; return 1; }
  code="$(curl -sS -L -o "$dest.part" -w '%{http_code}' "$MB_RAW/$rel" 2>/dev/null)" || {
    rm -f "$dest.part" 2>/dev/null; mb_log "fetch: curl failed for $rel"; return 1; }
  [ "$code" = "200" ] || { rm -f "$dest.part" 2>/dev/null; mb_log "fetch: HTTP $code for $rel"; return 1; }
  [ -s "$dest.part" ] || { rm -f "$dest.part" 2>/dev/null; mb_log "fetch: empty body for $rel"; return 1; }
  mv -f "$dest.part" "$dest"
}

# ── the manifest ─────────────────────────────────────────────────────────────────────────────
# 1. PB_MODULES (explicit, used by the tests)  2. modules/ beside this script  3. the built-in
# list, fetched. Order matters: a clone must never silently run a stale fetched copy.
mb_manifest() {
  local f n out=""
  if [ -n "${PB_MODULES:-}" ]; then printf '%s' "$PB_MODULES"; return 0; fi
  if [ -d "$MB_HERE/modules" ]; then
    for f in "$MB_HERE/modules"/m*_*.sh; do
      [ -r "$f" ] || continue
      n="${f##*/}"; out="$out ${n%.sh}"
    done
  fi
  [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  printf '%s' "$MB_MANIFEST_DEFAULT"
}

mb_module_file() {                              # prints the readable path, or nothing
  local m="$1"
  [ -r "$MB_HERE/modules/$m.sh" ] && { printf '%s' "$MB_HERE/modules/$m.sh"; return 0; }
  [ -r "$MB_CACHE/$m.sh" ] && { printf '%s' "$MB_CACHE/$m.sh"; return 0; }
  mb_fetch "modules/$m.sh" "$MB_CACHE/$m.sh" >/dev/null 2>&1 && {
    printf '%s' "$MB_CACHE/$m.sh"; return 0; }
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
mb_meta() {                                     # mb_meta <module-file> <module> <field> <default>
  local out
  if mb_has_verb "$1" "$2" "$3"; then
    out="$(mb_call "$1" "$2" "$3" 2>/dev/null)" || out=""
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  fi
  printf '%s' "$4"
}

# Notes from inside a command substitution. stdout belongs to the caller's capture.
mb_note_out() { printf '%s\n' "$*" >&2; }

mb_profile_rank() {                             # lite=1 standard=2 full=3, anything else=2
  case "$1" in lite) printf 1 ;; standard) printf 2 ;; full) printf 3 ;; all) printf 9 ;; *) printf 2 ;; esac
}

# The selected set, in manifest order. Precedence, and it is deliberate:
#   --only wins outright (an explicit list is an explicit list)
#   otherwise: the profile, then --except subtracts, then needs_ adds back OUT LOUD.
# A dependency is never added silently and never turns into a failure: the one thing worse than
# installing something the user did not ask for is refusing to explain why it is needed.
mb_select() {
  local m f p want rank sel="" add chg guard bad=""
  rank="$(mb_profile_rank "${MB_PROFILE:-$MB_PROFILE_DEFAULT}")"

  # A name that is in no manifest is a typo. Selecting nothing and exiting 0 would report a clean
  # run over an empty set — the false-green shape this driver already had to have removed twice.
  for m in $MB_ONLY $MB_EXCEPT; do
    case " $MB_MANIFEST " in *" $m "*) : ;; *) bad="$bad $m" ;; esac
  done
  if [ -n "$bad" ]; then
    mb_note_out "bootstrap: no such module:$bad"
    mb_note_out "           known modules: $MB_MANIFEST"
    return 1
  fi

  if [ -n "$MB_ONLY" ]; then
    for m in $MB_MANIFEST; do
      case " $MB_ONLY " in *" $m "*) sel="$sel $m" ;; esac
    done
  else
    for m in $MB_MANIFEST; do
      # An UNRESOLVABLE module is INCLUDED, never skipped. Dropping it here would delete it from
      # the selection the verdict is scored over, and the run would report success having silently
      # lost a module it was asked for — measured: PB_MODULES with a ghost name exited 0. Included,
      # it reaches mb_run_module, records SKIPPED, and SKIPPED maps to 30.
      if ! f="$(mb_module_file "$m")"; then sel="$sel $m"; continue; fi
      p="$(mb_meta "$f" "$m" profile standard)"
      [ "$(mb_profile_rank "$p")" -le "$rank" ] && sel="$sel $m"
    done
  fi

  for m in $MB_EXCEPT; do
    sel=" $(printf '%s' "$sel" | tr ' ' '\n' | grep -v "^${m}\$" | tr '\n' ' ') "
  done

  # Close over needs_, bounded by the manifest size so a cycle cannot spin.
  guard=0
  while [ "$guard" -lt 16 ]; do
    guard=$((guard + 1)); chg=0
    for m in $sel; do
      f="$(mb_module_file "$m")" || continue
      for want in $(mb_meta "$f" "$m" needs ""); do
        case " $sel " in
          *" $want "*) : ;;
          *) case " $MB_EXCEPT " in
               *" $want "*) [ "$guard" = 1 ] && mb_note_out "   note: $m wants $want, but you excluded it — $m will install in a reduced form" ;;
               *) case " $MB_MANIFEST " in
                    *" $want "*) sel="$sel $want"; chg=1
                                 # STDERR, not stdout: this function runs inside $( ), so a note
                                 # printed to stdout is captured as if it were a module name and
                                 # then dropped by the rebuild below — invisible, and the reason
                                 # "adding it out loud" silently became "adding it".
                                 mb_note_out "   note: $m needs $want — adding it" ;;
                  esac ;;
             esac ;;
        esac
      done
    done
    [ "$chg" = 0 ] && break
  done

  # Emit in manifest order, deduplicated.
  add=""
  for m in $MB_MANIFEST; do
    case " $sel " in *" $m "*) case " $add " in *" $m "*) : ;; *) add="$add $m" ;; esac ;; esac
  done
  printf '%s' "${add# }"
}

# ── --list ────────────────────────────────────────────────────────────────────────────────────
mb_cmd_list() {
  local m f what cost prof needs selected
  selected=" $(mb_select) " || return 30
  printf '\n  MODULES — a * marks what THIS invocation would act on (profile: %s)\n\n' "${MB_PROFILE:-$MB_PROFILE_DEFAULT}"
  for m in $MB_MANIFEST; do
    f="$(mb_module_file "$m")" || { printf '  ?  %-16s (module file unavailable)\n' "$m"; continue; }
    what="$(mb_meta "$f" "$m" what "$m")"
    cost="$(mb_meta "$f" "$m" cost "unpriced")"
    prof="$(mb_meta "$f" "$m" profile standard)"
    needs="$(mb_meta "$f" "$m" needs "")"
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
mb_cmd_manifest() {
  local m f
  printf '\n  MANIFEST — mac-bootstrap %s, pin %s\n\n' "$MB_VERSION" "$MB_PIN"
  printf '  Runtime state (never inside the repo):\n'
  printf '    %s/{receipt.json,receipt.verify.json,bootstrap.log,rows/,backups/,bin/}\n\n' "${PB_STATE_DIR:-$HOME/.mac-bootstrap}"
  printf '  Module sources and their hashes:\n'
  for m in $MB_MANIFEST; do
    f="$(mb_module_file "$m")" || { printf '    %-16s UNAVAILABLE\n' "$m"; continue; }
    printf '    %-16s %s  %s\n' "$m" "$(shasum -a 256 "$f" 2>/dev/null | cut -c1-16)" "$f"
  done
  printf '\n  Assets:\n'
  for f in "$MB_HERE"/assets/*.sh "$MB_HERE"/assets/*.md "$MB_HERE"/assets/hammerspoon/init.lua; do
    [ -r "$f" ] || continue
    printf '    %s  %s\n' "$(shasum -a 256 "$f" 2>/dev/null | cut -c1-16)" "${f#"$MB_HERE"/}"
  done
  printf '\n  Nothing above has been written. Run --plan to see what would change.\n\n'
}

# ── --plan — writes NOTHING. Distinct from the removed --dry-run, which wrote the receipt. ─────
mb_cmd_plan() {
  local m f sel st
  sel="$(mb_select)" || return 30
  if [ -z "$sel" ]; then
    mb_note_out "bootstrap: this selection contains no modules — nothing to plan. Try --list."
    return 30
  fi
  printf '\n  PLAN — profile %s. This run writes NOTHING.\n\n' "${MB_PROFILE:-$MB_PROFILE_DEFAULT}"
  for m in $MB_MANIFEST; do
    case " $sel " in *" $m "*) : ;; *) printf '    skip  %-16s (not in this selection)\n' "$m"; continue ;; esac
    f="$(mb_module_file "$m")" || { printf '    ??    %-16s module unavailable\n' "$m"; continue; }
    if mb_call "$f" "$m" verify >/dev/null 2>&1; then st="already satisfied — would do nothing"
    elif mb_call "$f" "$m" gate >/dev/null 2>&1; then st="NEEDS YOU: $(mb_note "$f" "$m")"
    else st="would install: $(mb_meta "$f" "$m" what "$m")"; fi
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
# is real lives in pb_settings_merge, which refuses an authorization keypath at the one place
# that writes — the chokepoint, not the text.
mb_audit() {
  local f="$1" hit
  hit="$(grep -n -E 'permissions?\.allow|settings\.local\.json|allowedTools|--dangerously|add-generic-password|security +import' "$f" 2>/dev/null)" || hit=""
  [ -z "$hit" ] && return 0
  mb_fail "module $f looks like it writes an authorization surface; refusing to source it"
  printf '%s\n' "$hit" >&2
  return 1
}

# ── rows: the receipt's backing store, one small file per field per module. ──────────────────
# --only MERGES because of this: a module that was not selected keeps the row it already had.
# The design's own driver REPLACED the receipt with a one-module receipt, so the agent's input
# destroyed itself the first time it followed the instruction to re-drive one module.
mb_row_set() {                                  # mb_row_set <module> <state> <note> <gesture>
  printf '%s' "$2" > "$MB_ROWS/$1.state" 2>/dev/null
  printf '%s' "${3:-}" > "$MB_ROWS/$1.note" 2>/dev/null
  printf '%s' "${4:-}" > "$MB_ROWS/$1.gesture" 2>/dev/null
}
mb_row_clear() { rm -f "$MB_ROWS/$1.state" "$MB_ROWS/$1.note" "$MB_ROWS/$1.gesture" 2>/dev/null; }
mb_row_get()   { cat "$MB_ROWS/$1.$2" 2>/dev/null; }

# Recovery: if the rows store was wiped but a receipt survives, rebuild the rows from it through
# plutil rather than losing the human gestures it is the only record of.
mb_rows_recover() {
  local i=0 m s n g
  [ -f "$MB_RECEIPT" ] || return 0
  ls "$MB_ROWS"/*.state >/dev/null 2>&1 && return 0
  while [ "$i" -lt 64 ]; do
    m="$(pb_settings_get "$MB_RECEIPT" "modules.$i.module" raw 2>/dev/null)" || break
    [ -n "$m" ] || break
    s="$(pb_settings_get "$MB_RECEIPT" "modules.$i.state" raw 2>/dev/null)" || s=""
    n="$(pb_settings_get "$MB_RECEIPT" "modules.$i.note" raw 2>/dev/null)" || n=""
    g="$(pb_settings_get "$MB_RECEIPT" "modules.$i.human_command" raw 2>/dev/null)" || g=""
    [ -n "$s" ] && mb_row_set "$m" "$s" "$n" "$g"
    i=$((i + 1))
  done
  [ "$i" -gt 0 ] && mb_log "recovered $i receipt row(s) into $MB_ROWS"
  return 0
}

# ── the receipt ──────────────────────────────────────────────────────────────────────────────
# printf + explicit escaping. One double quote in a note or a gesture string made the file the
# agent is TOLD to parse unparseable, and every value below goes through pb_json_escape.
mb_emit_receipt() {                             # mb_emit_receipt <path> <exit_code> [error]
  local out="$1" code="$2" err="${3:-}" f m first=1 tmp="$1.tmp.$$"
  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "generated_utc": "%s",\n' "$(date -u +%FT%TZ)"
    printf '  "mode": "%s",\n' "$(pb_json_escape "$MB_MODE")"
    printf '  "pin": "%s",\n' "$(pb_json_escape "$MB_PIN")"
    printf '  "host": "%s",\n' "$(pb_json_escape "$(sw_vers -productVersion 2>/dev/null) $(uname -m 2>/dev/null)")"
    printf '  "driver_version": %s,\n' "$MB_VERSION"
    printf '  "exit_code": %s,\n' "$code"
    [ -n "$err" ] && printf '  "error": "%s",\n' "$(pb_json_escape "$err")"
    printf '  "modules": [\n'
    for f in "$MB_ROWS"/*.state; do
      [ -r "$f" ] || continue
      m="${f##*/}"; m="${m%.state}"
      mb_in_manifest "$m" || continue
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '    {"module": "%s", "state": "%s", "note": "%s", "human_command": "%s"}' \
        "$(pb_json_escape "$m")" \
        "$(pb_json_escape "$(mb_row_get "$m" state)")" \
        "$(pb_json_escape "$(mb_row_get "$m" note)")" \
        "$(pb_json_escape "$(mb_row_get "$m" gesture)")"
    done
    [ "$first" = 1 ] || printf '\n'
    printf '  ]\n}\n'
  } > "$tmp" 2>/dev/null || { mb_fail "could not write $tmp"; return 1; }
  mv -f "$tmp" "$out" 2>/dev/null || { mb_fail "could not place $out"; return 1; }

  # THE LAST ACT OF EVERY RUN: parse the receipt back. NOTE, and do not "fix" this back:
  # `plutil -lint` — which the design named for this job — CANNOT validate JSON on macOS 15.
  # It lints property-list syntax, and reports `Unexpected character { at line 1` on a perfectly
  # valid receipt, and on the operator's own real ~/.claude/settings.json (both measured). The
  # arm that works is `plutil -convert json -o /dev/null`, plus jq as a second engine when it is
  # present. pb_json_ok is that pair.
  if pb_json_ok "$out"; then return 0; fi
  mb_fail "the receipt at $out did not parse back — this is a bug in the driver, not in your Mac."
  return 1
}

# ── module verbs ─────────────────────────────────────────────────────────────────────────────
# EVERY verb runs in its own SUBSHELL with the library and the module freshly sourced. Measured:
# a syntax error in a sourced file leaves the shell alive, but a bare `exit` in one KILLS IT —
# so a single stray `exit` in one module would end the whole run and every later module would
# silently never run. A subshell contains both. The cost is the contract in CONTRACT.md: no
# state survives between verbs; persist to disk if you need it.
mb_call() {                                     # mb_call <module-file> <module> <verb> [redirect-to-log]
  local mf="$1" m="$2" verb="$3" tolog="${4:-}"
  if [ "$tolog" = "log" ]; then
    # shellcheck disable=SC1090  # both paths are resolved at runtime by design
    ( . "$PB_LIB" >/dev/null 2>&1; . "$mf" >/dev/null 2>&1 || exit 90
      command -v "${verb}_${m}" >/dev/null 2>&1 || exit 91
      "${verb}_${m}" ) >>"$MB_LOG" 2>&1
  else
    # shellcheck disable=SC1090
    ( . "$PB_LIB" >/dev/null 2>&1; . "$mf" >/dev/null 2>&1 || exit 90
      command -v "${verb}_${m}" >/dev/null 2>&1 || exit 91
      "${verb}_${m}" ) 2>>"$MB_LOG"
  fi
}
mb_has_verb() {
  # shellcheck disable=SC1090
  ( . "$PB_LIB" >/dev/null 2>&1; . "$1" >/dev/null 2>&1 || exit 1
    command -v "${3}_${2}" >/dev/null 2>&1 ) >/dev/null 2>&1
}

# A row whose module is NOT in this release's manifest is not evidence about this release —
# it is a ghost from an older one. It is excluded from both the receipt and the verdict, and in
# install/uninstall mode the file is removed. Without this, dropping a module from a release
# leaves a FAILED row that nothing can ever clear and every later run inherits it.
mb_in_manifest() {
  case " $MB_MANIFEST " in *" $1 "*) return 0 ;; esac
  return 1
}
mb_prune_rows() {
  local f m
  for f in "$MB_ROWS"/*.state; do
    [ -r "$f" ] || continue
    m="${f##*/}"; m="${m%.state}"
    mb_in_manifest "$m" && continue
    mb_log "pruning stale row for '$m' — not in this release's manifest"
    mb_row_clear "$m"
  done
}

mb_selected() {
  [ -z "$MB_ONLY" ] && return 0
  case " $MB_ONLY " in *" $1 "*) return 0 ;; esac
  return 1
}

mb_note()    { local t; t="$(mb_call "$1" "$2" note)"    || t=""; [ -n "$t" ] || t="not installed"; printf '%s' "$t"; }
mb_gesture() { local t; t="$(mb_call "$1" "$2" gesture)" || t=""; printf '%s' "$t"; }

# ── the per-module state machine ─────────────────────────────────────────────────────────────
mb_run_module() {
  local m="$1" mf gated=0 note gesture rc

  mb_selected "$m" || return 0

  if ! mf="$(mb_module_file "$m")" || [ -z "$mf" ]; then
    mb_say "-- $m"
    mb_fail "not present at pin $MB_PIN (no local modules/$m.sh, and nothing fetchable)"
    mb_row_set "$m" SKIPPED "module not shipped at pin $MB_PIN" ""
    return 0
  fi
  mb_say "-- $m"
  mb_audit "$mf" || { mb_row_set "$m" FAILED "refused: looks like it writes an authorization surface" ""; return 0; }

  local v
  for v in verify gate note gesture install uninstall; do
    mb_has_verb "$mf" "$m" "$v" && continue
    mb_fail "$m does not implement ${v}_$m — see CONTRACT.md"
    mb_row_set "$m" FAILED "module does not implement ${v}_$m (see CONTRACT.md)" ""
    return 0
  done

  # D3: gate_ is evaluated BEFORE any early return, so a gated module is always reported —
  # whatever mode we are in and whatever verify_ says next.
  mb_call "$mf" "$m" gate >/dev/null 2>&1 && gated=1

  case "$MB_MODE" in
    uninstall)
      if mb_call "$mf" "$m" uninstall log; then mb_say "   removed"; mb_row_clear "$m"
      else mb_fail "uninstall_$m failed (see $MB_LOG)"; mb_row_set "$m" FAILED "uninstall failed; see the log" ""; fi
      return 0 ;;
    bench)
      if mb_has_verb "$mf" "$m" bench; then
        mb_say "   bench: $MB_BENCH"
        if mb_call "$mf" "$m" bench; then MB_BENCHED=1; else mb_fail "bench_$m exited non-zero"; MB_RC=20; fi
      fi
      return 0 ;;
  esac

  if mb_call "$mf" "$m" verify >/dev/null 2>&1; then
    mb_say "   satisfied (verified by read-back)"
    mb_row_set "$m" SATISFIED "verified by read-back" ""
    return 0
  fi

  if [ "$gated" = 1 ]; then
    note="$(mb_note "$mf" "$m")"; gesture="$(mb_gesture "$mf" "$m")"
    mb_say "   needs you: $note"
    [ -n "$gesture" ] && mb_say "      $gesture"
    mb_row_set "$m" NEEDS_HUMAN "$note" "$gesture"
    return 0
  fi

  if [ "$MB_MODE" = verify ]; then
    mb_fail "not installed"
    mb_row_set "$m" FAILED "not installed — run without --verify to install it" ""
    return 0
  fi

  mb_call "$mf" "$m" install log
  rc=$?
  if [ "$rc" = 0 ]; then
    if mb_call "$mf" "$m" verify >/dev/null 2>&1; then
      mb_say "   installed and verified"
      mb_row_set "$m" SATISFIED "verified by read-back" ""
    else
      # Rule 2: the installer's own exit code is never the verdict.
      mb_fail "install_$m exited 0 but verify_$m disagreed"
      mb_row_set "$m" FAILED "installer exited 0 but the read-back disagreed; see the log" ""
    fi
    return 0
  fi

  # An installer may DISCOVER a gate it could not see beforehand. Ask the module again before
  # calling this a failure — a human gesture reported as FAILED sends the reader to the log for
  # a bug that is not there.
  if mb_call "$mf" "$m" gate >/dev/null 2>&1; then
    note="$(mb_note "$mf" "$m")"; gesture="$(mb_gesture "$mf" "$m")"
    mb_say "   needs you: $note"
    [ -n "$gesture" ] && mb_say "      $gesture"
    mb_row_set "$m" NEEDS_HUMAN "$note" "$gesture"
    return 0
  fi
  case "$rc" in
    90) mb_fail "$m could not be sourced (syntax error?) — see $MB_LOG"
        mb_row_set "$m" FAILED "module could not be sourced" "" ;;
    91) mb_fail "install_$m vanished between the contract check and the call"
        mb_row_set "$m" FAILED "install_$m not defined" "" ;;
    *)  mb_fail "install_$m exited $rc (see $MB_LOG)"
        mb_row_set "$m" FAILED "installer exited $rc; see ~/.mac-bootstrap/bootstrap.log" "" ;;
  esac
  return 0
}

# ── the aggregate verdict ────────────────────────────────────────────────────────────────────
# C8 — THE FOUR MEASURED FALSE SIGNALS THIS FUNCTION EXISTS TO KILL. Each was reproduced on this
# machine against the version that shipped before it, and each one now has a fixture below.
#
#   1. `--only m4_handoff` on a FRESH Mac exited 0 and printed "every module satisfied", with
#      seven of the eight deliverables never evaluated and no statusline installed at all. An
#      unselected module writes no row, the verdict only ever looked at rows that EXIST, and the
#      one prompt the agent follows teaches 0 = done two steps earlier. A manifest module with no
#      row was never judged, and a run that never judged it is not a verdict about the machine.
#   2. An UNRECOGNISED row state ("BANANA") exited 0: the case had no default, so anything that is
#      not one of the four literals fell through to the all-satisfied return.
#   3. An EMPTY row state — what a truncated or failed mb_row_set write leaves behind — exited 0
#      for the same reason.
#   4. A COMPLETELY SUCCESSFUL `--uninstall` exited 30, i.e. "this run is NOT a verdict about your
#      Mac", because uninstall CLEARS every row and zero rows hit the "nothing assembled" arm.
#      Zero rows is uninstall's correct terminal state, and only uninstall's.

# mb_missing_rows — the manifest modules that have NO row, i.e. were never evaluated here.
# It PRINTS, because mb_verdict is called in a command substitution and a variable assigned in
# one never escapes it.
mb_missing_rows() {
  local m out="" scope
  # Scored over the SELECTION, never the manifest. C8's false green was "--only left 7 of 8
  # unevaluated and exit 0 said every module satisfied"; the cure must not become "a deliberate
  # --profile lite can never exit 0", which would make the whole selection feature unreachable.
  # A module the user did not select is not an unevaluated module, it is a declined one — and the
  # verdict line names the selection, so 0 cannot be read as a claim about the other four.
  scope="${MB_SELECTED:-$MB_MANIFEST}"
  for m in $scope; do
    [ -r "$MB_ROWS/$m.state" ] || out="$out $m"
  done
  printf '%s' "${out# }"
}

mb_verdict() {
  local f s m any=0 failed=0 human=0 skipped=0 unknown=0
  for f in "$MB_ROWS"/*.state; do
    [ -r "$f" ] || continue
    m="${f##*/}"; m="${m%.state}"
    mb_in_manifest "$m" || continue
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
  if [ "$MB_MODE" = uninstall ]; then
    # SKIPPED here means the module file could not be resolved, so its uninstall_ was never even
    # attempted — a precondition error, not a removal. It must not read as "everything removed".
    [ "$unknown" = 1 ] && { printf '30'; return 0; }
    [ "$skipped" = 1 ] && { printf '30'; return 0; }
    [ "$failed" = 1 ]  && { printf '20'; return 0; }
    printf '0'; return 0
  fi

  [ "$any" = 0 ] && { printf '30'; return 0; }
  [ -n "$(mb_missing_rows)" ] && { printf '30'; return 0; }
  [ "$unknown" = 1 ] && { printf '30'; return 0; }
  [ "$skipped" = 1 ] && { printf '30'; return 0; }
  [ "$failed" = 1 ] && { printf '20'; return 0; }
  [ "$human" = 1 ] && { printf '10'; return 0; }
  printf '0'
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
mb_say "mac-bootstrap $MB_VERSION · mode=$MB_MODE · pin=$MB_PIN · $(sw_vers -productVersion 2>/dev/null) $(uname -m 2>/dev/null)"
pb_have_jq || mb_say "note: jq is not on this machine — every step below uses the plutil path instead."

mb_rows_recover

MB_MANIFEST="$(mb_manifest)"
MB_BENCHED=0
MB_ERR=""

if [ -z "$MB_MANIFEST" ]; then
  MB_ERR="no modules: none beside this script, and pin '$MB_PIN' is not fetchable"
  mb_fail "$MB_ERR"
else
  # READ-ONLY MODES FIRST. Each writes nothing at all — no receipt, no rows, no backups — so a
  # stranger can see exactly what this thing would do before letting it do anything. That is the
  # whole reason they exist, and it is why they exit here rather than falling through.
  case "$MB_MODE" in
    list)     mb_cmd_list;     exit $? ;;
    plan)     mb_cmd_plan;     exit $? ;;
    manifest) mb_cmd_manifest; exit $? ;;
  esac

  MB_SELECTED="$(mb_select)"
  if [ -z "$MB_SELECTED" ]; then
    MB_ERR="the selection is empty: profile '${MB_PROFILE:-$MB_PROFILE_DEFAULT}'${MB_ONLY:+, --only$MB_ONLY}${MB_EXCEPT:+, --except$MB_EXCEPT} leaves no module to act on. Try --list."
    mb_fail "$MB_ERR"
  else
    [ -z "$MB_ONLY" ] && mb_say "selection: ${MB_PROFILE:-$MB_PROFILE_DEFAULT} -> $(printf '%s' "$MB_SELECTED" | wc -w | tr -d ' ') of $(printf '%s' "$MB_MANIFEST" | wc -w | tr -d ' ') modules  (--list to see the rest)"
    # shellcheck disable=SC2086  # the selection is a deliberately word-split list
    for mb_m in $MB_SELECTED; do mb_run_module "$mb_m"; done
  fi
fi

case "$MB_MODE" in install|uninstall) mb_prune_rows ;; esac

# If NOTHING could be resolved, say so once, at the top of the receipt, in a sentence. Eight
# identical SKIPPED rows state a fact and explain nothing.
mb_all_skipped() {
  local f n=0 k=0
  for f in "$MB_ROWS"/*.state; do
    [ -r "$f" ] || continue
    n=$((n + 1)); [ "$(cat "$f" 2>/dev/null)" = "SKIPPED" ] && k=$((k + 1))
  done
  [ "$n" -gt 0 ] && [ "$n" = "$k" ]
}
if [ -z "$MB_ERR" ] && mb_all_skipped; then
  case "$MB_PIN" in
    __PIN_SHA__|main|master|"")
      MB_ERR="no module ran: there is no modules/ directory beside bootstrap.sh, and MB_PIN is '$MB_PIN' — not a release sha, so nothing can be fetched. Run this from a clone of the repo, or set MB_PIN to a release commit." ;;
    *)
      MB_ERR="no module ran: none of them could be fetched from $MB_RAW — check the pin and your network." ;;
  esac
  mb_fail "$MB_ERR"
fi

if [ -n "$MB_ONLY" ]; then
  for mb_m in $MB_ONLY; do
    case " $MB_MANIFEST " in
      *" $mb_m "*) : ;;
      *) mb_fail "--only $mb_m: no such module in this release"; MB_ERR="--only named a module that does not exist: $mb_m"; MB_RC=30 ;;
    esac
  done
fi

# C8 — NAME THE MODULES THIS RUN NEVER JUDGED, so the 30 mb_verdict returns for them carries its
# reason. Measured before this existed: `--only m4_handoff` on a fresh Mac printed "exit 0 — every
# module satisfied" with seven deliverables never evaluated and no statusline on disk at all.
# bench is excluded because it exits below without ever consulting the verdict.
if [ "$MB_MODE" != uninstall ] && [ "$MB_MODE" != bench ] && [ -z "$MB_ERR" ]; then
  MB_UNEVAL="$(mb_missing_rows)"
  if [ -n "$MB_UNEVAL" ]; then
    MB_UNEVAL_N=0
    for mb_m in $MB_UNEVAL; do MB_UNEVAL_N=$((MB_UNEVAL_N + 1)); done
    MB_ERR="$MB_UNEVAL_N module(s) you selected were never evaluated ($MB_UNEVAL) — so this run is not a verdict about them. That is a defect, not a narrowing: report it."
    mb_fail "$MB_ERR"
  fi
fi

case "$MB_MODE" in
  bench)
    # A bench MEASURES; it changes nothing and it must not touch the receipt the agent reads.
    if [ "$MB_BENCHED" = 0 ] && [ "$MB_RC" = 0 ]; then
      mb_fail "no module in scope implements bench_ — nothing was measured"
      MB_RC=30
    fi
    mb_say ""
    mb_say "bench only: no state changed, and $MB_RECEIPT was not touched."
    exit "$MB_RC" ;;
  uninstall)
    MB_OUT="$MB_RECEIPT" ;;
  verify)
    MB_OUT="$MB_VRECEIPT" ;;
  *)
    MB_OUT="$MB_RECEIPT" ;;
esac

MB_CODE="$(mb_verdict)"
[ "$MB_RC" = 30 ] && MB_CODE=30
[ -n "$MB_ERR" ] && MB_CODE=30
mb_emit_receipt "$MB_OUT" "$MB_CODE" "$MB_ERR" || MB_CODE=30

mb_say ""
mb_say "receipt: $MB_OUT"
mb_say "log:     $MB_LOG"
case "$MB_CODE" in
  0)  if [ "$MB_MODE" = uninstall ]; then mb_say "exit 0  — every module removed."
      else mb_say "exit 0  — every module in this selection is satisfied ($(printf '%s' "${MB_SELECTED:-$MB_MANIFEST}" | wc -w | tr -d ' ') of $(printf '%s' "$MB_MANIFEST" | wc -w | tr -d ' ') available). Run --list to see what you did not select."; fi ;;
  10) mb_say "exit 10 — satisfied except for the step(s) marked NEEDS_HUMAN in the receipt." ;;
  20) mb_say "exit 20 — something FAILED. Read the log, fix the cause, then re-run --only <module>." ;;
  30) mb_say "exit 30 — precondition error: this run is NOT a verdict about your Mac." ;;
esac
exit "$MB_CODE"
