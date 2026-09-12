#!/bin/bash
# bootstrap-lib.sh — the ONLY shared code in mac-bootstrap.
#
# Sourced by BOTH the lifecycle hooks (session-start.sh, stop.sh, guard-*.sh) and the
# installer modules (modules/mN_*.sh) and the driver (bootstrap.sh). One copy, one set of rules.
#
# THE FIVE PROPERTIES, each of which cost a measured defect somewhere in this corpus:
#
#  1. bash 3.2 (macOS /bin/bash is 3.2.57). No associative arrays, no ${x^^}, no mapfile.
#  2. FAILS OPEN. No function here exits its caller, and nothing here sets -e. A hook that
#     wedges a session is worse than a hook that says nothing.
#  3. NEVER writes an authorization surface. bootstrap_settings_merge refuses a keypath or a file that
#     grants the agent permissions or carries credentials. This is a chokepoint guard against OUR
#     OWN mistakes, not a security boundary — see THE BOUND, below.
#  4. WRITES with jq when it is there, READS BACK with plutil always. Two different engines by
#     construction, so a verification can never be the writer agreeing with itself.
#  5. DEGRADES without jq. Every path here has a plutil arm. Nothing returns non-zero merely
#     because jq is absent — the stated risk is that a future macOS drops /usr/bin/jq, and a
#     bootstrap that hard-exits on that is a bootstrap that cannot bootstrap.
#
# THE BOUND, stated plainly because overclaiming it is the failure: modules are SOURCED, so
# arbitrary top-level code in a module runs before any function of ours is called. The guard in
# bootstrap_settings_merge stops a module that calls US; it cannot stop a module that calls plutil
# itself. The SHA pin on the fetched tree is the only real integrity control. This is
# defence-in-depth against our own mistakes and is documented as exactly that.
#
# Self-test:  bash bootstrap-lib.sh --selftest      (runs the shipped fixtures, including the empty-root-dict red arm)

# ── Seams. Every one has a default; none is required. ────────────────────────────────────────
BOOTSTRAP_STATE_DIR="${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"
BOOTSTRAP_TELEMETRY_DIR="${BOOTSTRAP_TELEMETRY_DIR:-/tmp/mac-bootstrap-telemetry}"
BOOTSTRAP_CONTEXT_THRESHOLD_PCT="${BOOTSTRAP_CONTEXT_THRESHOLD_PCT:-70}"                 # context-fill threshold, percent
BOOTSTRAP_CONTEXT_MAX_AGE_S="${BOOTSTRAP_CONTEXT_MAX_AGE_S:-600}"    # telemetry older than this says NOTHING
BOOTSTRAP_LIB_VERSION=1
BOOTSTRAP_BACKED_UP=""                            # files this process has already backed up

mkdir -p "$BOOTSTRAP_STATE_DIR" 2>/dev/null || true

BOOTSTRAP_PLUTIL=/usr/bin/plutil

# ── bootstrap_warn <text> — stderr + the log. NEVER stdout: a hook's stdout is parsed as JSON. ──────
bootstrap_warn() {
  printf 'mac-bootstrap: %s\n' "$*" >&2
  [ -n "${BOOTSTRAP_LOG:-}" ] && printf '%s bootstrap-lib.sh %s\n' "$(date -u +%FT%TZ)" "$*" >>"$BOOTSTRAP_LOG" 2>/dev/null
  return 0
}

# ── bootstrap_jq — prints an ABSOLUTE jq path, or returns 1. Absolute first (the one-writer rule): a PATH lookup in a
#    hook inherits whatever the agent's environment happens to be. BOOTSTRAP_NO_JQ=1 forces the plutil
#    arm, which is how the no-jq degrade is actually tested rather than asserted. ─────────────
bootstrap_jq() {
  [ -n "${BOOTSTRAP_NO_JQ:-}" ] && return 1
  local c
  for c in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c="$(command -v jq 2>/dev/null)" || c=""
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}
bootstrap_have_jq() { bootstrap_jq >/dev/null 2>&1; }

# ── bootstrap_json_escape <text> — make text safe inside a JSON string literal. ─────────────────────
# THE RECEIPT-ESCAPING DEFECT: the receipt was printf'd with no escaping, and one double quote in a gesture string made
# the file the agent is TOLD to parse unparseable. Backslash must be escaped before quote.
# Control characters are removed rather than \u-encoded: this text is prose for a human, and a
# lone control byte in it is never information.
bootstrap_json_escape() {
  printf '%s' "${1:-}" \
    | LC_ALL=C tr '\n\r\t' '   ' \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ── bootstrap_json_ok <file> — IS THIS VALID JSON? Two engines; both must agree. ────────────────────
# 🚨 MEASURED REFUTATION, 2026-09-11, macOS 15.7.9 (24G830). `plutil -lint` CANNOT validate JSON.
# It lints PROPERTY LIST syntax, and a JSON object with any key is not that:
#     $ printf '{"a":1}\n' > p.json && plutil -lint p.json
#     p.json: Unexpected character { at line 1        rc=1
#     $ plutil -lint "$HOME/.claude/settings.json"    # a real, valid, in-use settings file
#     …/.claude/settings.json: Unexpected character { at line 1        rc=1
# `{}` passes only because `{}` is also a valid EMPTY OPENSTEP dictionary — which is why a
# reader who tests -lint on `{}` concludes it works. The delivery spec's "plutil -lint the
# receipt as the last act of every run" would therefore have been a permanent false red on a
# perfectly good receipt, and that defect's own transcript shows that same error over a receipt whose
# only fault was an unescaped quote — so its CONCLUSION (escape it) is right and its
# INSTRUMENT was blind. `plutil -convert json -o /dev/null` is the arm that works, two-state:
#     good.json convert rc=0   ·   bad.json convert rc=1   (jq agrees: rc=0 / rc=5)
# It does not mutate the file (sha256 identical before and after, measured).
bootstrap_json_ok() {
  local f="${1:-}" jq
  [ -f "$f" ] || return 1
  "$BOOTSTRAP_PLUTIL" -convert json -o /dev/null "$f" >/dev/null 2>&1 || return 1
  jq="$(bootstrap_jq)" || return 0          # no jq ⇒ one engine is what we have; not a failure
  "$jq" -e . "$f" >/dev/null 2>&1 || return 1
  return 0
}

# ── bootstrap_is_json_text <file> — is this file JSON *TEXT*, as opposed to some other plist format? ─
# bootstrap_json_ok answers "can plutil parse this", and plutil parses XML and BINARY plists happily —
# measured, `plutil -convert json -o /dev/null` returns 0 for both. That matters here because
# `plutil -replace` PRESERVES the input format: handed an XML-plist settings.json it would write
# a perfectly valid XML plist back, and the agent, which reads that path as JSON, would then
# start with no settings at all. The first non-whitespace byte separates the three cases
# ('{' vs '<' vs 'b'), costs one read, and cannot be fooled by content.
bootstrap_is_json_text() {
  local f="${1:-}" c
  [ -f "$f" ] || return 1
  c="$(LC_ALL=C head -c 64 "$f" 2>/dev/null | LC_ALL=C tr -d '[:space:]' | LC_ALL=C head -c 1)"
  [ "$c" = "{" ]
}

# ── bootstrap_json_type <json-text> → plutil's type name, or nothing if the text is not valid JSON ──
# Measured: plutil renders a top-level SCALAR as neither valid plist nor valid JSON
#   $ printf '1' > n.json && plutil -convert json -o - n.json
#   n.json: invalid object in plist for destination format        rc=1
# so a scalar can be validated and compared only through `raw`, never through `json`. Wrapping
# the value in a one-key dictionary gives BOTH a validity verdict and a type name for free.
bootstrap_json_type() {
  local t out
  t="$(mktemp -t pbtype 2>/dev/null)" || return 1
  printf '{"_v":%s}' "${1:-}" > "$t" 2>/dev/null || { rm -f "$t"; return 1; }
  out="$("$BOOTSTRAP_PLUTIL" -type _v "$t" 2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "$out" ] || [ "$out" = "(any)" ]; then rm -f "$t"; return 1; fi
  rm -f "$t" 2>/dev/null
  printf '%s' "$out"
}

# ── bootstrap_json_fmt <json-text> → "json" for a container, "raw" for a scalar. ────────────────────
# This is the extract format that can actually render the value, and therefore the format both
# sides of every comparison must use.
bootstrap_json_fmt() {
  case "$(bootstrap_json_type "${1:-}")" in
    dictionary|array) printf 'json' ;;
    string|integer|float|bool) printf 'raw' ;;
    *) return 1 ;;
  esac
}

# ── bootstrap_json_norm <json-text> — plutil's canonical rendering of a JSON value. ─────────────────
# The ONLY sound way to compare "what I want to write" with "what is already there": plutil
# escapes '/' as '\/' on output, so a byte-compare against hand-written text always differs.
# Normalising both sides through the same engine makes idempotence exact rather than hopeful.
# Containers come back as JSON; scalars come back in `raw` form, which is what bootstrap_settings_get
# will hand back for them too.
bootstrap_json_norm() {
  local t fmt out rc
  fmt="$(bootstrap_json_fmt "${1:-}")" || return 1
  t="$(mktemp -t pbnorm 2>/dev/null)" || return 1
  printf '{"_v":%s}' "${1:-}" > "$t" 2>/dev/null || { rm -f "$t"; return 1; }
  out="$("$BOOTSTRAP_PLUTIL" -extract _v "$fmt" -o - "$t" 2>/dev/null)"
  rc=$?
  rm -f "$t" 2>/dev/null
  [ $rc -eq 0 ] || return $rc
  printf '%s' "$out"
}

# ── bootstrap_settings_get <file> <keypath> [json|raw] — THE READ-BACK. plutil only, never jq. ──────
# rc 1 and empty output when the keypath is absent — plutil names the error, so the instrument
# can say no, which is what makes a rc 0 mean something.
# 🚨 MEASURED: `plutil -extract` writes its FAILURE MESSAGE TO STDOUT, not to stderr —
#     $ out="$(plutil -extract nope raw -o - f.json 2>/dev/null)"
#     rc=1  stdout=[f.json: Could not extract value, error: No value at that key path …]
# so a reader that forwards stdout without checking rc hands its caller an ERROR SENTENCE where
# it expects a value. Every comparison downstream then silently compares against that sentence.
# Output is therefore emitted ONLY on rc 0, and an absent keypath is an EMPTY string plus rc 1.
bootstrap_settings_get() {
  local f="${1:-}" k="${2:-}" fmt="${3:-json}" out rc
  [ -f "$f" ] || return 1
  out="$("$BOOTSTRAP_PLUTIL" -extract "$k" "$fmt" -o - "$f" 2>/dev/null)"
  rc=$?
  [ $rc -eq 0 ] || return $rc
  printf '%s' "$out"
}

bootstrap_settings_type() {    # prints plutil's type name for a keypath, or nothing (rc 1)
  local f="${1:-}" k="${2:-}" out rc
  [ -f "$f" ] || return 1
  out="$("$BOOTSTRAP_PLUTIL" -type "$k" "$f" 2>/dev/null)"
  rc=$?
  [ $rc -eq 0 ] || return $rc
  printf '%s' "$out"
}

# bootstrap_array_len <file> <keypath> → how many elements the array at keypath has (0 if absent).
bootstrap_array_len() {
  local f="${1:-}" k="${2:-}" i=0
  [ -f "$f" ] || { printf '0'; return 0; }
  while [ "$i" -lt 256 ] && "$BOOTSTRAP_PLUTIL" -extract "$k.$i" json -o - "$f" >/dev/null 2>&1; do
    i=$((i + 1))
  done
  printf '%s' "$i"
}

# ── bootstrap_backup <file> — once per file per process, never overwritten. ─────────────────────────
bootstrap_backup() {
  local f="${1:-}"
  case "$BOOTSTRAP_BACKED_UP" in *"|$f|"*) return 0 ;; esac
  BOOTSTRAP_BACKED_UP="$BOOTSTRAP_BACKED_UP|$f|"
  [ -f "$f" ] || return 0
  cp -p "$f" "$f.mac-bootstrap-backup.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
  return 0
}

# ── bootstrap_keypath_json <dotted> — ["hooks","Stop",0]; numeric segments stay NUMBERS. ────────────
# jq's setpath treats a string segment as an object key, so "0" would create {"0":…} where an
# array index was meant. Segments may not themselves contain a dot (documented in CONTRACT.md).
bootstrap_keypath_json() {
  local out="[" first=1 seg oldifs hadf
  case "$-" in *f*) hadf=1 ;; *) hadf=0 ;; esac
  oldifs="$IFS"; IFS='.'; set -f
  # shellcheck disable=SC2086
  set -- ${1:-}
  IFS="$oldifs"; [ "$hadf" = 1 ] || set +f
  for seg in "$@"; do
    [ "$first" = 1 ] || out="$out,"
    first=0
    case "$seg" in
      ''|*[!0-9]*) out="$out\"$(bootstrap_json_escape "$seg")\"" ;;
      *)           out="$out$seg" ;;
    esac
  done
  printf '%s]' "$out"
}

# ── bootstrap_settings_refuse <file> <keypath> — rule 3, at the chokepoint. ─────────────────────────
# "Enforcement must live at the chokepoint": this is the one function that writes, so this is
# where the refusal belongs — not in a grep over module TEXT, which is a denylist of spellings
# and was defeated in three lines of string-splitting by the delivery reviewer.
bootstrap_settings_refuse() {
  local f="${1:-}" k="${2:-}"
  case "$f" in
    *settings.local.json|*.credentials.json|*/.credentials*|*/keychain*)
      bootstrap_warn "REFUSED: $f is an authorization/credential surface; ask the operator in chat."; return 0 ;;
  esac
  case "$k" in
    permissions|permissions.*|allowedTools|allowedTools.*|apiKeyHelper|apiKeyHelper.*\
    |awsAuthRefresh*|awsCredentialExport*|forceLoginMethod*|enableAllProjectMcpServers*\
    |enabledMcpjsonServers*|trust*|autoApprove*)
      bootstrap_warn "REFUSED: '$k' authorizes the agent; ask the operator in chat."; return 0 ;;
  esac
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# bootstrap_settings_merge — THE ONE SETTINGS WRITER (the one-writer rule). Nothing else in this repo writes a JSON
# settings file. statusline (statusLine) and hooks (hooks) both come through here, and so does every
# Copilot file: ~/.copilot/settings.json and ~/.copilot/hooks/00-lifecycle.json.
#
#   bootstrap_settings_merge <file> <keypath> <json-value> [set|append]
#
#   ADDITIVE    every other key in the file survives; we set exactly one keypath.
#   IDEMPOTENT  if the keypath already holds this value (compared through plutil's own
#               normalisation, not by string equality), the file is not touched at all.
#   ATOMIC      all work happens on <file>.mac-bootstrap-tmp.$$ and is read back THERE; a failed write
#               never lands, and a half-written settings.json — which makes the agent start
#               with NO hooks, silently — is impossible.
#   BACKED UP   <file>.mac-bootstrap-backup.<utc> once per process.
#   DEGRADING   jq when present, plutil when not. NEVER returns non-zero merely for no jq.
#
# 🚨 THE EMPTY-ROOT-DICT DEFECT, and it is the whole reason this function exists. plutil -replace AND -insert BOTH exit 1
#    against an EMPTY ROOT DICT — the fresh-Mac case, and it RECURS whenever uninstall_ removes
#    the last key (CONTRACT.md §7 item 2). Measured, macOS 15.7.9:
#        $ printf '{}\n' > a.json
#        $ plutil -replace statusLine -json '{…}' a.json   →  a.json: <unknown error>   rc=1
#        $ plutil -insert  statusLine -json '{…}' a.json   →  a.json: <unknown error>   rc=1
#        $ plutil -convert json a.json ; plutil -replace … →  rc=1   (-convert is not the fix)
#    The fix is to seed a throwaway key, write, then remove the seed — measured rc=0 both calls.
#    `bash bootstrap-lib.sh --selftest` runs the PRE-FIX arm and asserts it RED, so the repair here is
#    attributable rather than merely asserted.
#
# rc: 0 written-or-already-correct · 2 refused/failed · 3 keypath shape not supported
# ═════════════════════════════════════════════════════════════════════════════════════════════
bootstrap_settings_merge() {
  local f="${1:-}" k="${2:-}" v="${3:-}" mode="${4:-set}"
  local norm fmt cur tmp jq path seeded=0 rc idx

  [ -n "$f" ] && [ -n "$k" ] && [ -n "$v" ] || { bootstrap_warn "bootstrap_settings_merge: need <file> <keypath> <json>"; return 2; }
  bootstrap_settings_refuse "$f" "$k" && return 2

  # VALIDATE FIRST. fmt is the only extract format that can render this value, and therefore the
  # format BOTH sides of every comparison below must use — a scalar cannot be rendered as json.
  fmt="$(bootstrap_json_fmt "$v")"  || { bootstrap_warn "bootstrap_settings_merge: value is not valid JSON: $v"; return 2; }
  norm="$(bootstrap_json_norm "$v")" || { bootstrap_warn "bootstrap_settings_merge: cannot normalise: $v"; return 2; }

  mkdir -p "$(dirname "$f")" 2>/dev/null || true

  if [ "$mode" = "set" ]; then
    cur="$(bootstrap_settings_get "$f" "$k" "$fmt" 2>/dev/null)" || cur=""
    [ -n "$cur" ] && [ "$cur" = "$norm" ] && return 0        # already exactly this — no write
  fi
  idx="$(bootstrap_array_len "$f" "$k")"                            # where an append will land

  bootstrap_backup "$f"
  tmp="$f.mac-bootstrap-tmp.$$"
  if [ -s "$f" ]; then
    cp -p "$f" "$tmp" 2>/dev/null || { bootstrap_warn "cannot copy $f"; return 2; }
    bootstrap_json_ok "$tmp" || { rm -f "$tmp"; bootstrap_warn "$f is not valid JSON — refusing to touch it."; return 2; }
    bootstrap_is_json_text "$tmp" || { rm -f "$tmp"; bootstrap_warn "$f parses, but it is an XML or binary plist, not JSON text — refusing to touch it."; return 2; }
  else
    printf '%s\n' '{"_pbseed":1}' > "$tmp" 2>/dev/null || { bootstrap_warn "cannot write $tmp"; return 2; }
    seeded=1
  fi

  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then
    path="$(bootstrap_keypath_json "$k")"
    if [ "$mode" = "append" ]; then
      "$jq" --argjson v "$v" --argjson p "$path" \
            'setpath($p; ((if (getpath($p)|type)=="array" then getpath($p) else [] end) + [$v]))' \
            "$tmp" > "$tmp.2" 2>/dev/null
    else
      "$jq" --argjson v "$v" --argjson p "$path" 'setpath($p; $v)' "$tmp" > "$tmp.2" 2>/dev/null
    fi
    rc=$?
    if [ "$rc" = 0 ] && [ -s "$tmp.2" ]; then mv -f "$tmp.2" "$tmp"; else rm -f "$tmp.2"; jq=""; fi
  fi

  if [ -z "$jq" ]; then                                        # ── the plutil arm ──
    # the seed dance: an empty root dict is the one shape plutil refuses to modify.
    if [ "$(bootstrap_json_norm "$(cat "$tmp" 2>/dev/null)" 2>/dev/null)" = "{}" ]; then
      printf '%s\n' '{"_pbseed":1}' > "$tmp"; seeded=1
    fi
    bootstrap_settings_ensure_parents "$tmp" "$k" || { rc=$?; rm -f "$tmp"; return "$rc"; }
    if [ "$mode" = "append" ]; then
      # -append is ONLY safe on a keypath that is ALREADY an array. Measured trap: on a MISSING
      # key it exits 0 and writes the VALUE ITSELF — hooks.SessionStart becomes {"a":1} instead
      # of [{"a":1}], a silent shape corruption the agent then cannot read.
      if [ "$(bootstrap_settings_type "$tmp" "$k" 2>/dev/null)" = "array" ]; then
        "$BOOTSTRAP_PLUTIL" -insert "$k" -json "$v" -append "$tmp" >/dev/null 2>&1 || {
          rm -f "$tmp"; bootstrap_warn "plutil -append failed at $k"; return 2; }
      else
        "$BOOTSTRAP_PLUTIL" -replace "$k" -json "[$v]" "$tmp" >/dev/null 2>&1 || {
          rm -f "$tmp"; bootstrap_warn "plutil -replace failed at $k"; return 2; }
        idx=0
      fi
    else
      "$BOOTSTRAP_PLUTIL" -replace "$k" -json "$v" "$tmp" >/dev/null 2>&1 || {
        rm -f "$tmp"; bootstrap_warn "plutil -replace failed at $k"; return 2; }
    fi
  fi
  [ "$seeded" = 1 ] && "$BOOTSTRAP_PLUTIL" -remove _pbseed "$tmp" >/dev/null 2>&1

  # READ BACK ON THE TEMP FILE, BEFORE IT LANDS. plutil parses it; we compare to the normalised
  # target. A write that did not take can therefore never become the real file.
  bootstrap_json_ok "$tmp" || { rm -f "$tmp"; bootstrap_warn "write produced invalid JSON — $f untouched."; return 2; }
  if [ "$mode" = "append" ]; then
    cur="$(bootstrap_settings_get "$tmp" "$k.$idx" "$fmt" 2>/dev/null)" || cur=""
  else
    cur="$(bootstrap_settings_get "$tmp" "$k" "$fmt" 2>/dev/null)" || cur=""
  fi
  [ "$cur" = "$norm" ] || { rm -f "$tmp"; bootstrap_warn "read-back mismatch at $k (want [$norm] got [$cur])"; return 2; }

  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; bootstrap_warn "could not replace $f"; return 2; }
  return 0
}

# ── bootstrap_settings_ensure_parents <file> <keypath> ──────────────────────────────────────────────
# plutil cannot create an intermediate key: `-replace hooks.Stop` on a file with no `hooks`
# exits 1 with "Value … not valid for key path hooks.Stop" (measured). Walk the ancestors and
# create each missing one as an empty DICT — which plutil accepts as a VALUE; only an empty
# ROOT is refused. A missing ancestor whose next segment is numeric would have to be an ARRAY:
# refuse rather than guess, because guessing wrong writes a dict where the agent reads a list.
bootstrap_settings_ensure_parents() {
  local f="${1:-}" k="${2:-}" prefix="" i=0 n seg next oldifs hadf
  case "$k" in *.*) : ;; *) return 0 ;; esac
  case "$-" in *f*) hadf=1 ;; *) hadf=0 ;; esac
  oldifs="$IFS"; IFS='.'; set -f
  # shellcheck disable=SC2086
  set -- $k
  IFS="$oldifs"; [ "$hadf" = 1 ] || set +f
  n=$#
  while [ "$i" -lt $((n - 1)) ]; do
    i=$((i + 1))
    eval "seg=\${$i}"
    eval "next=\${$((i + 1))}"
    if [ -z "$prefix" ]; then prefix="$seg"; else prefix="$prefix.$seg"; fi
    "$BOOTSTRAP_PLUTIL" -extract "$prefix" json -o - "$f" >/dev/null 2>&1 && continue
    case "$next" in
      ''|*[!0-9]*) : ;;
      *) bootstrap_warn "keypath '$k': missing ancestor '$prefix' would have to be an array — create it first."; return 3 ;;
    esac
    "$BOOTSTRAP_PLUTIL" -replace "$prefix" -json '{}' "$f" >/dev/null 2>&1 || {
      bootstrap_warn "could not create ancestor '$prefix'"; return 2; }
  done
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# HOOK WIRING — computed here, WRITTEN by bootstrap_settings_merge. Two envelopes, one entry point each.
# ═════════════════════════════════════════════════════════════════════════════════════════════

# bootstrap_hook_present <file> <event> <command> — parse-based membership. Never a grep of the file.
bootstrap_hook_present() {
  local f="${1:-}" ev="${2:-}" cmd="${3:-}" i=0 j c
  [ -f "$f" ] || return 1
  while [ "$i" -lt 64 ] && "$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i" json -o - "$f" >/dev/null 2>&1; do
    j=0
    while [ "$j" -lt 64 ]; do
      c="$("$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i.hooks.$j.command" raw -o - "$f" 2>/dev/null)" || break
      [ "$c" = "$cmd" ] && return 0
      j=$((j + 1))
    done
    i=$((i + 1))
  done
  return 1
}

# bootstrap_hook_wire <settings.json> <Event> <matcher> <command> [timeout]
# Claude Code envelope: .hooks.<Event>[] = {matcher, hooks:[{type,command,timeout}]}
# ADDITIVE and ORDER-PRESERVING: an event the user already has keeps its entries, in order, and
# ours is appended LAST. Order inside a Stop chain is load-bearing (only one hook can usefully
# block), so we never reorder and never replace a group.
bootstrap_hook_wire() {
  local f="${1:-}" ev="${2:-}" mt="${3:-}" cmd="${4:-}" to="${5:-10}"
  local entry group i=0 found=-1 m
  [ -n "$f" ] && [ -n "$ev" ] && [ -n "$cmd" ] || { bootstrap_warn "bootstrap_hook_wire: need <file> <event> <matcher> <command>"; return 2; }
  bootstrap_hook_present "$f" "$ev" "$cmd" && return 0
  entry="{\"type\":\"command\",\"command\":\"$(bootstrap_json_escape "$cmd")\",\"timeout\":$to}"

  if [ "$(bootstrap_settings_type "$f" "hooks.$ev")" != "array" ]; then
    bootstrap_settings_merge "$f" "hooks.$ev" "[{\"matcher\":\"$(bootstrap_json_escape "$mt")\",\"hooks\":[$entry]}]"
    return $?
  fi
  while [ "$i" -lt 64 ] && "$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i" json -o - "$f" >/dev/null 2>&1; do
    m="$("$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i.matcher" raw -o - "$f" 2>/dev/null)" || m=""
    if [ "$m" = "$mt" ] && [ "$found" -lt 0 ]; then found=$i; fi
    i=$((i + 1))
  done
  if [ "$found" -ge 0 ]; then
    bootstrap_settings_merge "$f" "hooks.$ev.$found.hooks" "$entry" append
    return $?
  fi
  group="{\"matcher\":\"$(bootstrap_json_escape "$mt")\",\"hooks\":[$entry]}"
  bootstrap_settings_merge "$f" "hooks.$ev" "$group" append
}

# bootstrap_hook_unwire <settings.json> <command-prefix> — remove every hook whose command starts with
# <command-prefix>, then drop groups and events that this emptied. Indices are walked BACKWARDS
# so a removal never invalidates an index we have not visited yet.
bootstrap_hook_unwire() {
  local f="${1:-}" pre="${2:-}" ev i j c n changed=0
  [ -f "$f" ] && [ -n "$pre" ] || return 0
  bootstrap_backup "$f"
  for ev in $(bootstrap_hook_events "$f"); do
    i=63
    while [ "$i" -ge 0 ]; do
      if "$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i" json -o - "$f" >/dev/null 2>&1; then
        j=63
        while [ "$j" -ge 0 ]; do
          c="$("$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i.hooks.$j.command" raw -o - "$f" 2>/dev/null)" || c=""
          case "$c" in
            "$pre"*) [ -n "$c" ] && { "$BOOTSTRAP_PLUTIL" -remove "hooks.$ev.$i.hooks.$j" "$f" >/dev/null 2>&1 && changed=1; } ;;
          esac
          j=$((j - 1))
        done
        n="$("$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i.hooks" json -o - "$f" 2>/dev/null)" || n=""
        [ "$n" = "[]" ] && "$BOOTSTRAP_PLUTIL" -remove "hooks.$ev.$i" "$f" >/dev/null 2>&1
      fi
      i=$((i - 1))
    done
    n="$("$BOOTSTRAP_PLUTIL" -extract "hooks.$ev" json -o - "$f" 2>/dev/null)" || n=""
    [ "$n" = "[]" ] && "$BOOTSTRAP_PLUTIL" -remove "hooks.$ev" "$f" >/dev/null 2>&1
  done
  [ "$changed" = 1 ] && bootstrap_json_ok "$f"
  return 0
}

# bootstrap_hook_events <file> — the event names present under .hooks, one per line.
bootstrap_hook_events() {
  local f="${1:-}" jq
  [ -f "$f" ] || return 0
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then "$jq" -r '(.hooks // {}) | keys[]?' "$f" 2>/dev/null; return 0; fi
  # jq-free: probe the documented event set rather than enumerate keys, which plutil cannot do.
  local e
  for e in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse Stop SubagentStop \
           Notification PreCompact sessionStart sessionEnd userPromptSubmitted preToolUse \
           postToolUse agentStop; do
    "$BOOTSTRAP_PLUTIL" -extract "hooks.$e" json -o - "$f" >/dev/null 2>&1 && printf '%s\n' "$e"
  done
  return 0
}

# bootstrap_copilot_hook_wire <hooks.json> <Event> <matcher> <command> [timeoutSec]
# Copilot CLI 1.0.83 envelope: {"version":1,"hooks":{<Event>:[{type,bash,timeoutSec,matcher}]}}
# Registered under Claude Code's PascalCase names, which GitHub's own reference calls the
# "VS Code compatible format" and which were measured firing with silent near-miss controls.
# `matcher` is omitted when empty — it is a regex there, and an empty one is not a wildcard.
# preToolUse FAILS CLOSED on any non-zero exit, so every hook script must exit 0 explicitly.
bootstrap_copilot_hook_wire() {
  local f="${1:-}" ev="${2:-}" mt="${3:-}" cmd="${4:-}" to="${5:-10}"
  local entry i=0 b
  [ -n "$f" ] && [ -n "$ev" ] && [ -n "$cmd" ] || { bootstrap_warn "bootstrap_copilot_hook_wire: need <file> <event> <matcher> <command>"; return 2; }
  bootstrap_settings_merge "$f" "version" "1" || return 2
  while [ "$i" -lt 64 ]; do
    b="$("$BOOTSTRAP_PLUTIL" -extract "hooks.$ev.$i.bash" raw -o - "$f" 2>/dev/null)" || break
    [ "$b" = "$cmd" ] && return 0
    i=$((i + 1))
  done
  if [ -n "$mt" ]; then
    entry="{\"type\":\"command\",\"bash\":\"$(bootstrap_json_escape "$cmd")\",\"timeoutSec\":$to,\"matcher\":\"$(bootstrap_json_escape "$mt")\"}"
  else
    entry="{\"type\":\"command\",\"bash\":\"$(bootstrap_json_escape "$cmd")\",\"timeoutSec\":$to}"
  fi
  if [ "$(bootstrap_settings_type "$f" "hooks.$ev")" = "array" ]; then
    bootstrap_settings_merge "$f" "hooks.$ev" "$entry" append
  else
    bootstrap_settings_merge "$f" "hooks.$ev" "[$entry]"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# CONTEXT FILL. The advisory that makes self-recycle automatic.
#
# 🚨 These two functions read NO git, NO repo root and NO ledger, and that is the entire point.
# The shipped Stop hook computed the fill and then rendered it INSIDE `if [ -n "$LEDGER" ]`,
# where LEDGER is set only inside `if [ -n "$ROOT" ]`. Executed at 82% fill: inside a git repo
# the advisory fires; cwd not a git repo → SILENCE; git absent from PATH → SILENCE. Both dead
# states are the target machine's day-one state (/usr/bin/git is an inert xcrun shim until a
# human installs the Command Line Tools, and the prompt says "in any directory"). A caller must
# render bootstrap_ctx_advisory UNCONDITIONALLY; it is silent when it has nothing to say, which is the
# only correct silence. `bash bootstrap-lib.sh --selftest` runs the no-git arm.
# ═════════════════════════════════════════════════════════════════════════════════════════════

# bootstrap_ctx_pct <session_id> → an integer 0-100, or nothing.
# Says NOTHING when the telemetry file is absent, stale or carries a null. An imputed window
# would be a WRONG number rather than a missing one — the same model id runs at 200k and at 1M.
bootstrap_ctx_pct() {
  local sid="${1:-}" tf pct ts now age jq pair
  [ -n "$sid" ] || return 0
  tf="$BOOTSTRAP_TELEMETRY_DIR/$sid.json"
  [ -f "$tf" ] || return 0
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then
    pair="$("$jq" -r '"\(.used_pct // "") \(.ts // 0)"' "$tf" 2>/dev/null)" || pair=""
    pct="${pair%% *}"; ts="${pair##* }"
  else
    pct="$("$BOOTSTRAP_PLUTIL" -extract used_pct raw -o - "$tf" 2>/dev/null)" || pct=""
    ts="$("$BOOTSTRAP_PLUTIL" -extract ts raw -o - "$tf" 2>/dev/null)" || ts=""
  fi
  pct="${pct%%.*}"                       # Claude Code's used_percentage is a FLOAT: 45.7 → 45
  case "${pct:-}" in ''|*[!0-9]*) return 0 ;; esac
  case "${ts:-}" in ''|*[!0-9]*) ts=0 ;; esac
  now="$(date +%s 2>/dev/null)" || return 0
  age=$((now - ts))
  [ "$age" -lt "$BOOTSTRAP_CONTEXT_MAX_AGE_S" ] || return 0
  [ "$pct" -ge 0 ] && [ "$pct" -le 100 ] || return 0
  printf '%s' "$pct"
}

# bootstrap_ctx_advisory <session_id> → one line of advice, or nothing. NO git anywhere in this path.
bootstrap_ctx_advisory() {
  local pct t low
  pct="$(bootstrap_ctx_pct "${1:-}")" || pct=""
  [ -n "$pct" ] || return 0
  t="$BOOTSTRAP_CONTEXT_THRESHOLD_PCT"
  low=$((t - 20)); [ "$low" -lt 0 ] && low=0
  if [ "$pct" -ge "$t" ]; then
    printf 'CONTEXT %s%% — past the %s%% line. Persist what this context holds that the disk does not (a rejected approach and why, a measurement that contradicts the obvious reading), commit it, then run /handoff. Do not ride to the ceiling: it is a hard refusal, not an auto-compaction, and nothing rescues you at it.' "$pct" "$t"
  elif [ "$pct" -ge "$low" ]; then
    printf 'context %s%%' "$pct"
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# SMALL SHARED HELPERS — carried verbatim from the measured research, with their reasons.
# ═════════════════════════════════════════════════════════════════════════════════════════════

# bootstrap_json <payload> <dotted.path> → scalar or empty.
# With jq: exact. Without jq: FLAT top-level STRING keys only — a nested path returns EMPTY
# rather than a guess, because sed-ing a shell command full of quotes out of JSON mis-parses
# silently, and a wrong answer here is worse than no answer.
bootstrap_json() {
  local jq
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then
    printf '%s' "${1:-}" | "$jq" -r "(.${2:-} // empty) | tostring" 2>/dev/null
    return 0
  fi
  case "${2:-}" in *.*) return 0 ;; esac
  printf '%s' "${1:-}" | sed -n "s/.*\"${2:-}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  return 0
}

# bootstrap_emit_ctx <event> <text> — additionalContext. Advisory; never blocks.
# The no-jq arm STRIPS rather than quotes: hand-building JSON from arbitrary text is how a hook
# emits malformed output and gets its whole chain ignored. The message degrades; it never
# becomes invalid JSON. This exists because the one message that MUST survive a missing jq is
# the warning that jq is missing.
bootstrap_emit_ctx() {
  local jq c
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then
    "$jq" -nc --arg e "${1:-}" --arg c "${2:-}" \
      '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
    return 0
  fi
  c="$(printf '%s' "${2:-}" | LC_ALL=C tr -d '"\\' | LC_ALL=C tr '\n\r\t' '   ')"
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "${1:-}" "$c"
  return 0
}

# bootstrap_git <dir> <args…> — git confined to <dir>, silent, never fails the caller.
# Its rc IS git's rc: bootstrap_trunk's second arm is `rev-parse --verify`, and a wrapper that always
# returns 0 turns that verification into a rubber stamp. (Measured: `rev-parse --abbrev-ref
# origin/HEAD` in a remote-less repo PRINTS "origin/HEAD" on stdout and exits 128, so the verify
# arm is the only thing standing between us and a fabricated trunk.)
bootstrap_git() { local d="${1:-.}"; [ $# -gt 0 ] && shift; git -C "$d" "$@" 2>/dev/null; }

# bootstrap_count — count lines on stdin, always printing exactly ONE integer.
# NOT `grep -c . || echo 0`: grep -c PRINTS a valid 0 AND EXITS 1 on no match, so the fallback
# puts a SECOND producer on the same stream and the caller reads "0\n0", which then fails every
# -gt test with "integer expected". (Measured: a brief rendered "· 0\n0 uncommitted".)
bootstrap_count() { local n; n="$(grep -c . 2>/dev/null)" || true; case "${n:-0}" in ''|*[!0-9]*) n=0 ;; esac; printf '%s' "$n"; }

# bootstrap_trunk <dir> → a REMOTE trunk ref, or empty.
# REMOTE-ONLY, deliberately. Falling back to a local main/master resolves, on a repo with no
# remote, to the branch you are standing on: rev-list master..HEAD = 0, and the ledger renders
# "nothing unpushed" over work that has never left the disk. No remote ⇒ empty ⇒ say UNKNOWN.
bootstrap_trunk() {
  local r v
  for r in origin/HEAD origin/main origin/master; do
    v="$(bootstrap_git "${1:-.}" rev-parse --abbrev-ref "$r")"
    [ -n "$v" ] && bootstrap_git "${1:-.}" rev-parse --verify -q "$v" >/dev/null && { printf '%s' "$v"; return 0; }
  done
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# SHIPPED FIXTURES —  bash bootstrap-lib.sh --selftest
#
# Not decoration. The empty-root-dict correction says: "Add the {} case as a shipped fixture … with the
# pre-fix arm asserted red — otherwise the repair is unattributed." Case 1 IS that pre-fix arm:
# it runs the UNREPAIRED command and REQUIRES it to fail. If macOS ever fixes plutil, case 1
# goes red and tells you the repair is no longer attributable — which is information, not a bug.
# Every jq-dependent case is run TWICE: once as the machine is, once under BOOTSTRAP_NO_JQ=1.
# ═════════════════════════════════════════════════════════════════════════════════════════════
bootstrap__t=0; bootstrap__f=0
bootstrap_ok()   { bootstrap__t=$((bootstrap__t+1)); printf '  ok   %s\n' "$1"; }
bootstrap_bad()  { bootstrap__t=$((bootstrap__t+1)); bootstrap__f=$((bootstrap__f+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
bootstrap_is()   { if [ "$2" = "$3" ]; then bootstrap_ok "$1"; else bootstrap_bad "$1" "want [$3] got [$2]"; fi; }

bootstrap_selftest() {
  local T A B rc out sid arm
  T="$(mktemp -d -t pbself)" || return 30
  printf 'bootstrap-lib.sh selftest · bash %s · %s %s\n' "${BASH_VERSION:-?}" "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)"

  # ── 1. EMPTY-ROOT-DICT PRE-FIX (RED) ARM. The unrepaired command against a literal {}. ──────────────────
  printf '{}\n' > "$T/c1.json"
  "$BOOTSTRAP_PLUTIL" -replace statusLine -json '{"type":"command","command":"/x.sh"}' "$T/c1.json" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then
    bootstrap_bad "empty-root-dict pre-fix arm is RED (plutil -replace refuses an empty root dict)" \
           "plutil now ACCEPTS it — the seed dance is no longer attributable to a measured defect."
  else
    bootstrap_ok "empty-root-dict pre-fix arm is RED (plutil -replace on {} exits $rc — the defect the seed dance repairs)"
  fi
  "$BOOTSTRAP_PLUTIL" -insert statusLine -json '{"a":1}' "$T/c1.json" >/dev/null 2>&1
  [ $? -ne 0 ] && bootstrap_ok "empty-root-dict pre-fix arm: -insert is NOT the fix either" || bootstrap_bad "empty-root-dict: -insert unexpectedly worked"

  # ── 2-6. run the whole settings block on BOTH engines ─────────────────────────────────────
  for arm in jq nojq; do
    if [ "$arm" = nojq ]; then export BOOTSTRAP_NO_JQ=1; else unset BOOTSTRAP_NO_JQ; fi
    if [ "$arm" = jq ] && ! bootstrap_have_jq; then printf '  --   [jq arm skipped: no jq on this box]\n'; continue; fi
    BOOTSTRAP_BACKED_UP=""

    # 2. empty-root-dict POST-FIX: the same empty root dict, through the one writer.
    printf '{}\n' > "$T/s.json"
    bootstrap_settings_merge "$T/s.json" statusLine '{"type":"command","command":"/tmp/sl.sh"}'
    bootstrap_is "[$arm] empty-root-dict green: merge into a literal {} succeeds" "$?" "0"
    bootstrap_is "[$arm] empty-root-dict green: read-back through plutil" "$(bootstrap_settings_get "$T/s.json" statusLine.command raw)" "/tmp/sl.sh"
    bootstrap_is "[$arm] seed key removed" "$(bootstrap_settings_get "$T/s.json" _pbseed raw 2>/dev/null)" ""

    # 3. IDEMPOTENT: the second identical call must not touch the file at all.
    A="$(shasum -a 256 "$T/s.json" | cut -d' ' -f1)"
    bootstrap_settings_merge "$T/s.json" statusLine '{"type":"command","command":"/tmp/sl.sh"}' >/dev/null 2>&1
    B="$(shasum -a 256 "$T/s.json" | cut -d' ' -f1)"
    bootstrap_is "[$arm] idempotent: second merge is a no-op" "$A" "$B"

    # 4. ADDITIVE: an unrelated key the user owns survives, and so does its value.
    printf '%s\n' '{"model":"claude-opus-5","env":{"FOO":"bar"}}' > "$T/a.json"
    bootstrap_settings_merge "$T/a.json" statusLine '{"type":"command","command":"/tmp/sl.sh"}' >/dev/null 2>&1
    bootstrap_is "[$arm] additive: unrelated scalar survives" "$(bootstrap_settings_get "$T/a.json" model raw)" "claude-opus-5"
    bootstrap_is "[$arm] additive: unrelated nested value survives" "$(bootstrap_settings_get "$T/a.json" env.FOO raw)" "bar"

    # 5. HOOKS: user's existing hook stays FIRST, ours is appended, and re-wiring is a no-op.
    printf '%s\n' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/mine/existing.sh"}]}]}}' > "$T/h.json"
    bootstrap_hook_wire "$T/h.json" Stop "" "/fixture/stop.sh" >/dev/null 2>&1
    bootstrap_is "[$arm] hook: user's hook still first" "$(bootstrap_settings_get "$T/h.json" hooks.Stop.0.hooks.0.command raw)" "/mine/existing.sh"
    bootstrap_is "[$arm] hook: ours appended into the same matcher group" "$(bootstrap_settings_get "$T/h.json" hooks.Stop.0.hooks.1.command raw)" "/fixture/stop.sh"
    A="$(shasum -a 256 "$T/h.json" | cut -d' ' -f1)"
    bootstrap_hook_wire "$T/h.json" Stop "" "/fixture/stop.sh" >/dev/null 2>&1
    B="$(shasum -a 256 "$T/h.json" | cut -d' ' -f1)"
    bootstrap_is "[$arm] hook: re-wiring is a no-op" "$A" "$B"
    bootstrap_hook_wire "$T/h.json" PreToolUse "Write|MultiEdit" "/fixture/guard-write.sh" >/dev/null 2>&1
    bootstrap_is "[$arm] hook: a new event is created as an ARRAY, not a dict" "$(bootstrap_settings_type "$T/h.json" hooks.PreToolUse)" "array"
    bootstrap_is "[$arm] hook: new matcher group carries the matcher" "$(bootstrap_settings_get "$T/h.json" hooks.PreToolUse.0.matcher raw)" "Write|MultiEdit"
    bootstrap_hook_wire "$T/h.json" Stop "OTHER" "/fixture/other.sh" >/dev/null 2>&1
    bootstrap_is "[$arm] hook: a different matcher makes a NEW group" "$(bootstrap_settings_get "$T/h.json" hooks.Stop.1.hooks.0.command raw)" "/fixture/other.sh"
    bootstrap_hook_unwire "$T/h.json" "/fixture/" >/dev/null 2>&1
    bootstrap_is "[$arm] unwire: ours gone" "$(bootstrap_settings_get "$T/h.json" hooks.Stop.0.hooks.1.command raw 2>/dev/null)" ""
    bootstrap_is "[$arm] unwire: the user's survives" "$(bootstrap_settings_get "$T/h.json" hooks.Stop.0.hooks.0.command raw)" "/mine/existing.sh"

    # 6. COPILOT: a fresh envelope on a machine with no ~/.copilot at all.
    rm -rf "$T/copilot"
    bootstrap_copilot_hook_wire "$T/copilot/hooks/00-lifecycle.json" Stop "" "/fixture/stop.sh" >/dev/null 2>&1
    bootstrap_is "[$arm] copilot: version pinned" "$(bootstrap_settings_get "$T/copilot/hooks/00-lifecycle.json" version raw)" "1"
    bootstrap_is "[$arm] copilot: bash key, not command" "$(bootstrap_settings_get "$T/copilot/hooks/00-lifecycle.json" hooks.Stop.0.bash raw)" "/fixture/stop.sh"
    bootstrap_is "[$arm] copilot: event is an ARRAY" "$(bootstrap_settings_type "$T/copilot/hooks/00-lifecycle.json" hooks.Stop)" "array"
    A="$(shasum -a 256 "$T/copilot/hooks/00-lifecycle.json" | cut -d' ' -f1)"
    bootstrap_copilot_hook_wire "$T/copilot/hooks/00-lifecycle.json" Stop "" "/fixture/stop.sh" >/dev/null 2>&1
    B="$(shasum -a 256 "$T/copilot/hooks/00-lifecycle.json" | cut -d' ' -f1)"
    bootstrap_is "[$arm] copilot: re-wiring is a no-op" "$A" "$B"

    # 7. REFUSAL at the chokepoint — and the file must be untouched.
    printf '%s\n' '{"model":"x"}' > "$T/r.json"
    A="$(shasum -a 256 "$T/r.json" | cut -d' ' -f1)"
    bootstrap_settings_merge "$T/r.json" permissions.allow '["Bash(*)"]' >/dev/null 2>&1
    bootstrap_is "[$arm] refuses to write permissions" "$?" "2"
    B="$(shasum -a 256 "$T/r.json" | cut -d' ' -f1)"
    bootstrap_is "[$arm] refused write left the file untouched" "$A" "$B"
    bootstrap_settings_merge "$T/settings.local.json" model '"x"' >/dev/null 2>&1
    bootstrap_is "[$arm] refuses settings.local.json entirely" "$?" "2"

    # 8b. A file that PARSES but is not JSON text (an XML plist) is never touched either.
    printf '%s\n' '{"model":"x"}' > "$T/xml.json"; "$BOOTSTRAP_PLUTIL" -convert xml1 "$T/xml.json" >/dev/null 2>&1
    A="$(shasum -a 256 "$T/xml.json" | cut -d' ' -f1)"
    bootstrap_settings_merge "$T/xml.json" statusLine '{"a":1}' >/dev/null 2>&1
    bootstrap_is "[$arm] refuses an XML plist wearing a .json name" "$?" "2"
    bootstrap_is "[$arm] XML plist untouched" "$A" "$(shasum -a 256 "$T/xml.json" | cut -d' ' -f1)"

    # 8. A file that is NOT valid JSON is never touched.
    printf '%s\n' 'not json at all {' > "$T/bad.json"
    A="$(shasum -a 256 "$T/bad.json" | cut -d' ' -f1)"
    bootstrap_settings_merge "$T/bad.json" statusLine '{"a":1}' >/dev/null 2>&1
    bootstrap_is "[$arm] refuses a non-JSON settings file" "$?" "2"
    bootstrap_is "[$arm] non-JSON file untouched" "$A" "$(shasum -a 256 "$T/bad.json" | cut -d' ' -f1)"
  done
  unset BOOTSTRAP_NO_JQ

  # ── 9. THE CONTEXT ADVISORY, with NO git anywhere on PATH and cwd not a repo. ──────────
  mkdir -p "$T/nogit/bin" "$T/notarepo"
  # a PATH holding ONLY what the advisory legitimately needs — and pointedly no git.
  [ -x /bin/date ] && ln -sf /bin/date "$T/nogit/bin/date"
  [ -x /usr/bin/date ] && ln -sf /usr/bin/date "$T/nogit/bin/date"
  BOOTSTRAP_TELEMETRY_DIR="$T/tel"; mkdir -p "$BOOTSTRAP_TELEMETRY_DIR"
  sid="SELFTEST-SID"
  printf '{"ts":%s,"session_id":"%s","window":1000000,"used_pct":82,"input_tokens":820000}\n' "$(date +%s)" "$sid" > "$BOOTSTRAP_TELEMETRY_DIR/$sid.json"
  out="$( cd "$T/notarepo" && PATH="$T/nogit/bin" bootstrap_ctx_advisory "$sid" )"
  case "$out" in
    CONTEXT\ 82%*) bootstrap_ok "advisory: 82% advisory FIRES with no git on PATH and cwd not a repo" ;;
    *)             bootstrap_bad "advisory: 82% advisory lost outside a git repo" "got [$out]" ;;
  esac
  printf '{"ts":%s,"used_pct":12}\n' "$(date +%s)" > "$BOOTSTRAP_TELEMETRY_DIR/$sid.json"
  out="$( cd "$T/notarepo" && PATH="$T/nogit/bin" bootstrap_ctx_advisory "$sid" )"
  bootstrap_is "advisory polarity: 12% stays SILENT" "$out" ""
  printf '{"ts":1,"used_pct":82}\n' > "$BOOTSTRAP_TELEMETRY_DIR/$sid.json"
  bootstrap_is "advisory: stale telemetry stays SILENT" "$(bootstrap_ctx_advisory "$sid")" ""
  printf '{"ts":%s,"used_pct":null}\n' "$(date +%s)" > "$BOOTSTRAP_TELEMETRY_DIR/$sid.json"
  bootstrap_is "advisory: a null used_pct is NOT read as 0%" "$(bootstrap_ctx_advisory "$sid")" ""
  printf '{"ts":%s,"used_pct":45.7}\n' "$(date +%s)" > "$BOOTSTRAP_TELEMETRY_DIR/$sid.json"
  bootstrap_is "advisory: a FLOAT fill truncates rather than being discarded" "$(bootstrap_ctx_pct "$sid")" "45"
  rm -f "$BOOTSTRAP_TELEMETRY_DIR/$sid.json"
  bootstrap_is "advisory: absent telemetry stays SILENT" "$(bootstrap_ctx_advisory "$sid")" ""
  bootstrap_is "advisory: no session id stays SILENT" "$(bootstrap_ctx_advisory "")" ""

  # ── 10. RECEIPT ESCAPING. The exact shape that made the receipt unparseable. ──────────────────
  out="$(bootstrap_json_escape 'kitty says "unknown action" and exits 0 \ ok')"
  printf '{"note":"%s"}\n' "$out" > "$T/d4.json"
  if bootstrap_json_ok "$T/d4.json"; then bootstrap_ok "receipt-escaping: a quoted+backslashed note still yields valid JSON"
  else bootstrap_bad "receipt-escaping: escaping failed" "$(cat "$T/d4.json")"; fi
  bootstrap_is "receipt-escaping: the note round-trips through plutil unchanged" \
        "$(bootstrap_settings_get "$T/d4.json" note raw)" 'kitty says "unknown action" and exits 0 \ ok'
  printf '{"note":"he said "hi""}\n' > "$T/d4bad.json"
  if bootstrap_json_ok "$T/d4bad.json"; then bootstrap_bad "receipt-escaping control: the validator passed MALFORMED json"; else bootstrap_ok "receipt-escaping control: the validator rejects an unescaped quote"; fi

  # ── 11. bootstrap_count: exactly one integer, even on empty input. ───────────────────────────────
  bootstrap_is "bootstrap_count on empty stdin prints exactly one 0" "$(printf '' | bootstrap_count)" "0"
  bootstrap_is "bootstrap_count on 3 lines" "$(printf 'a\nb\nc\n' | bootstrap_count)" "3"

  # ── 12. bootstrap_trunk: a repo with no remote must answer nothing, not 'master'. ────────────────
  if command -v git >/dev/null 2>&1 && git -C "$T" init -q "$T/norepo" >/dev/null 2>&1; then
    bootstrap_is "bootstrap_trunk: no remote ⇒ empty (never a local branch)" "$(bootstrap_trunk "$T/norepo")" ""
  else
    printf '  --   [bootstrap_trunk case skipped: git unavailable — which is itself the fresh-Mac state]\n'
  fi

  printf '\n%s/%s cases passed.\n' "$((bootstrap__t - bootstrap__f))" "$bootstrap__t"
  rm -rf "$T" 2>/dev/null
  [ "$bootstrap__f" = 0 ] && return 0
  return 1
}

# Executed, not sourced? ${BASH_SOURCE[0]} equals $0 only when this file IS the program.
# A hook that sources us must never see its own positional parameters interpreted here.
if [ "${BASH_SOURCE[0]:-x}" = "${0:-y}" ]; then
  case "${1:-}" in
    --selftest) bootstrap_selftest; exit $? ;;
    --version)  printf 'bootstrap-lib.sh %s\n' "$BOOTSTRAP_LIB_VERSION"; exit 0 ;;
    *)          printf 'bootstrap-lib.sh is a library. Source it, or run: bash bootstrap-lib.sh --selftest\n' >&2; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------------------------
# bootstrap_defaults_home_ok — refuse a `defaults` write when $HOME is not this user's REAL home.
#
# MEASURED HAZARD, and it bit the authoring session. /usr/bin/defaults resolves the preferences
# directory from the PASSWORD DATABASE, not from $HOME, so every `defaults read/write` ESCAPES a
# sandboxed HOME and acts on the real user's domain. The documented way to test this bootstrap —
# `HOME=$(mktemp -d) bash bootstrap.sh` — therefore silently rewrites the live machine for exactly
# the two modules that use defaults (rewrite_model VoiceInk, screenshot screencapture). Observed: a sandboxed run set
# the real com.apple.screencapture `location` to a path inside a temp dir, and when that temp dir
# was removed the user's screenshots had nowhere to go. Nothing in the run reported a thing,
# because from defaults' point of view every call succeeded.
#
# So: compare $HOME against the password database and REFUSE on a mismatch. A refusal is a correct
# NEEDS_HUMAN-shaped outcome; corrupting the live domain is not. Kill switch for a deliberate
# cross-home install: BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1.
bootstrap_defaults_home_ok() {
  [ "${BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS:-0}" = 1 ] && return 0
  local real
  real="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')"
  [ -n "$real" ] || return 0          # cannot tell => do not block a real install
  [ "$real" = "${HOME%/}" ] && return 0
  bootstrap_warn "defaults writes would escape this sandboxed HOME and hit the REAL domain ($real). Refusing. Set BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 only if that is genuinely what you want."
  return 1
}
