#!/bin/bash
# stop.sh — Stop (Claude Code) · Stop→agentStop (Copilot CLI). ONE process, three arms:
#
#   A. THE LEDGER      dirty? committed? pushed? — from LIVE git reads, rendered as one line the
#                      operator reads and the model cannot fake.
#   B. THE CONTEXT     a recycle advisory when this session's context fill crosses a threshold.
#      ADVISORY        This is the self-management arm: the session is told to /handoff itself.
#   C. AUTO-CONTINUE   if files THIS SESSION wrote are still uncommitted, block the stop and feed
#                      the work back, so a turn does not end on a loose end. BOUNDED — see below.
#
# ONE PROCESS ON PURPOSE. Three Stop hooks would be three forks, three stdin reads and three
# `git status` calls per turn boundary, and only one of them can usefully block — so their order
# would be load-bearing and undocumented. Merged, the order is visible in this file.
#
# ═══ THE CONTEXT ADVISORY — THE DEFECT THIS FILE EXISTS TO NOT REPEAT ══════════════════════════════════════════
# The researcher's version rendered arm B INSIDE `if [ -n "$LEDGER" ]`, and LEDGER was set only
# inside `if [ -n "$ROOT" ]`. So the fill was computed and then SILENTLY DISCARDED whenever the
# cwd was not a git repo, or git was not on PATH. Both are the target machine's day-one state:
# /usr/bin/git is an inert xcrun shim until a human installs the Command Line Tools, and the one
# prompt says "in any directory". Measured at 82% fill: in a repo → fires; not a repo → SILENCE;
# git off PATH → SILENCE. The advisory is the one self-management arm the user asked for.
#   THE RULE NOW: arm B is computed by bootstrap_ctx_advisory, which reads NO git, NO repo root and NO
#   ledger, and it is rendered UNCONDITIONALLY. `bash stop.sh --selftest` asserts all four
#   cases — 12% and 82%, each in a git repo and in a bare $TMPDIR — plus a no-git-on-PATH arm.
#   12% must stay SILENT: an advisory that fires at every stop carries exactly as much
#   information as one that never fires.
#
# ═══ THE BOUND — a Stop hook that blocks is a loop; read this before changing anything ═══════
# {"decision":"block"} FORCES ANOTHER TURN. Unbounded, that is a runaway burning quota with
# nobody watching. THREE bounds, and the second is the operative one:
#   B1  stop_hook_active — the harness sets it true on the re-entrant Stop our own block caused.
#       Returning silently while it is true ⇒ AT MOST ONE block per organic stop, a termination
#       proof needing no state. First thing in the script. Present in Claude Code's Stop schema
#       on 2.1.114/220/260 and in Copilot's agentStop payload (measured, both).
#   B2  a per-session counter at $BOOTSTRAP_STATE_DIR/stop-count, ceiling BOOTSTRAP_STOP_MAX (default 3).
#       B1 is documented but its false→true flip was never traced, so a counter is the bound that
#       is measured by construction rather than trusted.
#   B3  the harness's own CLAUDE_CODE_STOP_HOOK_BLOCK_CAP. We do NOT rely on it: it is ABSENT
#       from the 2.1.114 binary (present in 220/260), so on a pinned older agent it is not a
#       bound at all. We are merely inside it where it exists.
#
# HOW THE COUNTER CLEARS ITSELF, and why not the obvious way: it is keyed on the session id, so a
# new session starts at 0 — that is the clearing. It is deliberately NOT reset by committing,
# because a budget the demanded action resets never binds (write → block → commit → write →
# block, forever). A file whose session id no longer matches is overwritten on sight, and files
# older than BOOTSTRAP_STOP_TTL_DAYS (default 7) are reaped, so the store cannot grow without bound.
#
# ATTRIBUTION IS THE WHOLE GAME FOR ARM C. Blocking on a dirty file someone else left in a shared
# checkout harasses a session for work that is not its own. The transcript records every
# Write/Edit/MultiEdit tool_use with the path it was given, so "mine" is decidable; with no jq or
# no transcript the answer is CANNOT-TELL and the arm ABSTAINS. It never blocks on ignorance.
#
# Arms A and B NEVER block. On Claude Code they ride `systemMessage`, which reaches the operator's
# pane without extending the turn. On Copilot CLI `systemMessage` is NOT a listed agentStop output
# field, so there they ride stderr instead — see hook_agent().
#
# Seams: BOOTSTRAP_STOP_HOOK=0 disables · BOOTSTRAP_STOP_MAX · BOOTSTRAP_CONTEXT_THRESHOLD_PCT · BOOTSTRAP_STATE_DIR · BOOTSTRAP_TELEMETRY_DIR.
# NO `set -e` and deliberately NO `pipefail` (CONTRACT.md §7.8). Every exit is an explicit 0.
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || HOOK_DIR="."
# ABSOLUTE, because the selftest re-executes this file from other directories: a relative $0
# stops resolving the moment anything cds, and `bash <missing file>` prints to stderr and yields
# an EMPTY stdout — which a fixture asserting silence reads as a PASS. (Measured here: advisory/4 and
# B1 both went green while the subject had not run at all.)
HOOK_SELF="$HOOK_DIR/$(basename "${BASH_SOURCE[0]:-$0}")"
# shellcheck source=bootstrap-lib.sh disable=SC1091
. "$HOOK_DIR/bootstrap-lib.sh" 2>/dev/null || exit 0

# ── hook_field <payload> <keypath> — READ A FIELD OUT OF THE HOOK PAYLOAD, WITH OR WITHOUT jq. ──
# bootstrap_json is the library's reader and is deliberately conservative without jq: it handles only
# FLAT keys whose values are QUOTED STRINGS, because sed-extracting a quote-laden shell command
# out of JSON mis-parses silently and a wrong answer is worse than none. Two consequences bit
# here, both MEASURED under BOOTSTRAP_NO_JQ=1:
#   · `stop_hook_active` is a flat key with a BOOLEAN value, so it read EMPTY — and bound B1, the
#     one that makes a blocking Stop hook provably terminate, silently disarmed.
#   · every nested read (`tool_input.file_path`, `tool_input.command`) read EMPTY, so both guards
#     were inert rather than merely weaker.
# The repair is not a better regex: it is to use the OTHER engine the library already trusts.
# plutil parses the payload properly — booleans, numbers, nesting, embedded quotes — so we write
# the payload to a temp file ONCE and extract through bootstrap_settings_get, which emits only on rc 0
# (plutil writes its failure message to STDOUT, so a reader that forwards stdout blindly hands
# its caller an error sentence where a value belongs). With jq present this path never runs.
HOOK_PAYLOAD=""
hook_field() {
  local v
  v="$(bootstrap_json "${1:-}" "${2:-}")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  if [ -z "$HOOK_PAYLOAD" ]; then
    HOOK_PAYLOAD="$(mktemp -t hook-payload 2>/dev/null)" || { HOOK_PAYLOAD=""; return 0; }
    printf '%s' "${1:-}" > "$HOOK_PAYLOAD" 2>/dev/null || { rm -f "$HOOK_PAYLOAD"; HOOK_PAYLOAD=""; return 0; }
  fi
  bootstrap_settings_get "$HOOK_PAYLOAD" "${2:-}" raw 2>/dev/null
  return 0
}
hook_field_cleanup() { [ -n "$HOOK_PAYLOAD" ] && rm -f "$HOOK_PAYLOAD" 2>/dev/null; HOOK_PAYLOAD=""; return 0; }
trap hook_field_cleanup EXIT

# ── hook_agent <transcript_path> <stop_reason> → claude | copilot ─────────────────────────────
# Which agent is calling? Measured: Copilot's transcript path is $HOME/.copilot/session-state/…,
# Claude Code's is $HOME/.claude/projects/…; Copilot's agentStop payload additionally carries
# stop_reason. Defaulting to claude is the safe direction — an unknown key is ignored, whereas a
# missing systemMessage silently drops the ledger.
hook_agent() {
  case "${1:-}" in */.copilot/*) printf 'copilot'; return 0 ;; esac
  case "${1:-}" in */.claude/*)  printf 'claude';  return 0 ;; esac
  [ -n "${2:-}" ] && { printf 'copilot'; return 0; }
  printf 'claude'
}

# ── hook_say <agent> <line> — arm A/B output. Never extends the turn. ─────────────────────────
hook_say() {
  local jq
  if [ "${1:-claude}" = copilot ]; then printf '%s\n' "${2:-}" >&2; return 0; fi
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then "$jq" -nc --arg s "${2:-}" '{systemMessage:$s}'; return 0; fi
  printf '{"systemMessage":"%s"}\n' "$(printf '%s' "${2:-}" | LC_ALL=C tr -d '"\\' | LC_ALL=C tr '\n\r\t' '   ')"
  return 0
}

# ── hook_block <agent> <reason> <banner> — the ONE blocking output. ───────────────────────────
hook_block() {
  local jq
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then
    if [ "${1:-claude}" = copilot ]; then
      "$jq" -nc --arg r "${2:-}" '{decision:"block",reason:$r}'
    else
      "$jq" -nc --arg r "${2:-}" --arg s "${3:-}" '{decision:"block",reason:$r,systemMessage:$s}'
    fi
    return 0
  fi
  # no jq ⇒ arm C is already inert (attribution needs the transcript parser), so this is
  # unreachable in practice; it is here so the shape is never hand-built somewhere else.
  printf '{"decision":"block","reason":"%s"}\n' \
    "$(printf '%s' "${2:-}" | LC_ALL=C tr -d '"\\' | LC_ALL=C tr '\n\r\t' '   ')"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# SHIPPED FIXTURES —  bash stop.sh --selftest
# The four-case advisory matrix is the point: a fix with no negative control is a claim. Case 2 and 4
# (12% SILENT) are what make cases 1, 3 and 5 mean something.
# ═════════════════════════════════════════════════════════════════════════════════════════════
hook_selftest() {
  local T t f i n=0 bad=0 out sid repo
  T="$(mktemp -d -t pbstop)" || return 30
  mkdir -p "$T/tel" "$T/state" "$T/bare"
  sid="STOPTEST-SID"
  printf 'stop selftest · bash %s\n' "${BASH_VERSION:-?}"

  _tel() {   # _tel <pct>  — fresh telemetry at that fill
    printf '{"ts":%s,"session_id":"%s","window":1000000,"used_pct":%s}\n' \
      "$(date +%s)" "$sid" "$1" > "$T/tel/$sid.json"
  }
  _run() {   # _run <cwd> <payload-extra> → the hook's stdout, with a private state dir
    ( cd "$1" 2>/dev/null || exit 0
      BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" \
      /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"$sid","cwd":"$1","transcript_path":"","stop_hook_active":false$2}
XIN
    )
  }
  _is() {    # _is <label> <haystack> <needle|EMPTY>
    n=$((n+1))
    if [ "$3" = EMPTY ]; then
      if [ -z "$2" ]; then printf '  ok   %s\n' "$1"; else bad=$((bad+1)); printf '  FAIL %s\n       got [%s]\n' "$1" "$2"; fi
      return 0
    fi
    case "$2" in *"$3"*) printf '  ok   %s\n' "$1" ;;
      *) bad=$((bad+1)); printf '  FAIL %s\n       want [%s] in [%s]\n' "$1" "$3" "$2" ;;
    esac
  }
  _isnt() {  # _isnt <label> <haystack> <needle>  — the negative control half
    n=$((n+1))
    case "$2" in *"$3"*) bad=$((bad+1)); printf '  FAIL %s\n       [%s] must NOT appear, got [%s]\n' "$1" "$3" "$2" ;;
      *) printf '  ok   %s\n' "$1" ;;
    esac
  }

  # ── advisory/0 — THE PRE-FIX (RED) ARM, so the repair stays attributable to a measured defect. ────
  # This is the researcher's render gate, verbatim in shape: `if [ -n "$LEDGER" ]`, where LEDGER
  # is set only inside `if [ -n "$ROOT" ]`. Fed the SAME fresh 82% telemetry in a directory that
  # is not a repo, it must print NOTHING. If this ever speaks, the gate was never the defect and
  # this file's advisory section is no longer evidence of anything.
  _tel 82
  out="$( cd "$T/bare" && BOOTSTRAP_TELEMETRY_DIR="$T/tel" /bin/bash -c '
      . "$1/bootstrap-lib.sh" || exit 0
      ROOT="$(bootstrap_git "$PWD" rev-parse --show-toplevel)"
      LEDGER=""; [ -n "$ROOT" ] && LEDGER="clean"
      CTX="$(bootstrap_ctx_advisory "$2")"
      if [ -n "$LEDGER" ]; then printf "%s%s\n" "$LEDGER" "$CTX"; fi
    ' _ "$HOOK_DIR" "$sid" 2>/dev/null )"
  _is "advisory/0 PRE-FIX arm is RED: the nested gate swallows an 82% advisory outside a repo" "$out" EMPTY

  # ── THE ADVISORY, four cases: {12%, 82%} × {git repo, bare dir} ───────────────────────────────────────
  repo=""
  if command -v git >/dev/null 2>&1 && git init -q "$T/repo" >/dev/null 2>&1; then
    repo="$T/repo"
    ( cd "$repo" && git config user.email fixture@example.invalid && git config user.name fixture \
      && : > keep.txt && git add keep.txt && git commit -qm init ) >/dev/null 2>&1
  fi
  if [ -n "$repo" ]; then
    _tel 82; out="$(_run "$repo" "")"; _is "advisory/1 git repo    @82% SPEAKS"  "$out" "CONTEXT 82%"
    _tel 12; out="$(_run "$repo" "")"; _isnt "advisory/2 git repo    @12% says NOTHING about context" "$out" "CONTEXT"
  else
    printf '  --   [advisory/1,2 skipped: no usable git — which is itself the fresh-Mac state]\n'
  fi
  _tel 82; out="$(_run "$T/bare" "")"; _is "advisory/3 bare tmpdir @82% SPEAKS"  "$out" "CONTEXT 82%"
  _tel 12; out="$(_run "$T/bare" "")"; _is "advisory/4 bare tmpdir @12% SILENT"  "$out" EMPTY
  # ── advisory/5-6: THE FRESH-MAC DAY-ONE STATE, reproduced rather than described. /usr/bin/git is an
  #    inert xcrun shim until a human installs the Command Line Tools: it exists, it is on PATH,
  #    and every invocation fails. So arm A is dead and arm B must still speak.
  mkdir -p "$T/shim"
  printf '#!/bin/sh\necho "xcrun: error: invalid active developer path" >&2\nexit 1\n' > "$T/shim/git"
  chmod +x "$T/shim/git"
  _shimrun() {
    ( cd "${1:-$T/bare}" 2>/dev/null || exit 0
      PATH="$T/shim:$PATH" BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" \
      /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"$sid","cwd":"${1:-$T/bare}","stop_hook_active":false}
XIN
    )
  }
  _tel 82; out="$(_shimrun "${repo:-$T/bare}")"
  _is "advisory/5 git present but INERT (xcrun shim) @82% SPEAKS" "$out" "CONTEXT 82%"
  _tel 12; out="$(_shimrun "${repo:-$T/bare}")"
  _isnt "advisory/6 git present but INERT (xcrun shim) @12% says NOTHING about context" "$out" "CONTEXT"

  # ── B1: the harness's re-entrancy flag ⇒ total silence, whatever else is true ───────────────
  _tel 82
  out="$( cd "$T/bare" && BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" \
          /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"$sid","cwd":"$T/bare","stop_hook_active":true}
XIN
       )"
  _is "B1  stop_hook_active:true ⇒ SILENCE" "$out" EMPTY
  # …AND ON THE PLUTIL ARM. stop_hook_active is a flat key with a BOOLEAN value, which the
  # library's no-jq reader (quoted strings only) returned EMPTY for — so B1, the bound that makes
  # a blocking Stop hook provably terminate, silently disarmed on a machine without jq. Measured,
  # fixed by hook_field, and pinned here: without this case the whole suite is green on the arm
  # that matters least.
  out="$( cd "$T/bare" && BOOTSTRAP_NO_JQ=1 BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" \
          /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"$sid","cwd":"$T/bare","stop_hook_active":true}
XIN
       )"
  _is "B1  stop_hook_active:true ⇒ SILENCE with NO jq (plutil arm)" "$out" EMPTY
  _tel 82
  out="$( cd "$T/bare" && BOOTSTRAP_NO_JQ=1 BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" \
          /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"$sid","cwd":"$T/bare","stop_hook_active":false}
XIN
       )"
  _is "advisory: still SPEAKS with no jq (plutil arm)" "$out" "CONTEXT 82%"

  # ── B2: arm C blocks at most BOOTSTRAP_STOP_MAX times, and abstains on someone else's file ────────
  if [ -n "$repo" ] && bootstrap_have_jq; then
    ( cd "$repo" && : > mine.txt && : > theirs.txt ) 2>/dev/null
    t="$T/transcript.jsonl"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/mine.txt"}}]}}\n' "$repo" > "$t"
    f=0; i=1
    while [ "$i" -le 4 ]; do
      out="$( cd "$repo" && BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" BOOTSTRAP_STOP_MAX=3 \
              /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"B2-SID","cwd":"$repo","transcript_path":"$t","stop_hook_active":false}
XIN
           )"
      case "$out" in *'"block"'*) f=$((f+1)) ;; esac
      i=$((i+1))
    done
    n=$((n+1))
    if [ "$f" = 3 ]; then printf '  ok   B2  blocks exactly 3 of 4 stops (ceiling binds)\n'
    else bad=$((bad+1)); printf '  FAIL B2  blocked %s of 4, want 3\n' "$f"; fi
    # attribution negative control: the transcript names a file this session did NOT write
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/nothere.txt"}}]}}\n' "$repo" > "$t"
    out="$( cd "$repo" && BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" \
            /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"B2-NEG","cwd":"$repo","transcript_path":"$t","stop_hook_active":false}
XIN
         )"
    n=$((n+1))
    case "$out" in *'"block"'*) bad=$((bad+1)); printf '  FAIL B2neg blocked on a file this session never wrote\n' ;;
      *) printf '  ok   B2neg a dirty file this session did NOT write ⇒ NO block\n' ;;
    esac
    # missing transcript ⇒ CANNOT-TELL ⇒ abstain
    out="$( cd "$repo" && BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_TELEMETRY_DIR="$T/tel" \
            /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"session_id":"B2-ABS","cwd":"$repo","transcript_path":"$T/does-not-exist","stop_hook_active":false}
XIN
         )"
    n=$((n+1))
    case "$out" in *'"block"'*) bad=$((bad+1)); printf '  FAIL B2abs blocked with no transcript to attribute from\n' ;;
      *) printf '  ok   B2abs no transcript ⇒ abstains, never blocks on ignorance\n' ;;
    esac
  else
    printf '  --   [B2 skipped: needs git and jq]\n'
  fi

  printf '\n%s/%s cases passed.\n' "$((n - bad))" "$n"
  rm -rf "$T" 2>/dev/null
  [ "$bad" = 0 ] && return 0
  return 1
}

case "${1:-}" in
  --selftest) hook_selftest; exit $? ;;
esac

[ "${BOOTSTRAP_STOP_HOOK:-1}" = 1 ] || exit 0
IN="$(cat 2>/dev/null || true)"

# ── B1 ────────────────────────────────────────────────────────────────────────────────────────
[ "$(hook_field "$IN" stop_hook_active)" = "true" ] && exit 0

SID="$(hook_field "$IN" session_id)"
TP="$(hook_field "$IN" transcript_path)"
SR="$(hook_field "$IN" stop_reason)"
CWD="$(hook_field "$IN" cwd)"; [ -n "$CWD" ] || CWD="$PWD"
AGENT="$(hook_agent "$TP" "$SR")"
ROOT="$(bootstrap_git "$CWD" rev-parse --show-toplevel)"

# ── ARM A: the ledger ─────────────────────────────────────────────────────────────────────────
# `git status --porcelain` is the right read. Do NOT "optimise" it to `git diff --quiet`: diff
# compares the worktree to the INDEX and is blind to staged-but-uncommitted and to untracked
# files, which is most of what a loose end actually looks like.
RUNG="OK"; LEDGER=""; DIRTY_N=0; AHEAD=0; BRANCH=""; PORC=""; TRUNK=""
if [ -n "$ROOT" ]; then
  BRANCH="$(bootstrap_git "$ROOT" rev-parse --abbrev-ref HEAD)"
  PORC="$(bootstrap_git "$ROOT" status --porcelain)"
  DIRTY_N="$(printf '%s' "$PORC" | bootstrap_count)"
  TRUNK="$(bootstrap_trunk "$ROOT")"
  if [ -n "$TRUNK" ]; then AHEAD="$(bootstrap_git "$ROOT" rev-list --count "$TRUNK..HEAD")"; fi
  case "$DIRTY_N" in ''|*[!0-9]*) DIRTY_N=0 ;; esac
  case "$AHEAD"   in ''|*[!0-9]*) AHEAD=0 ;; esac
  # THREE RUNGS AND A FOURTH THAT SAYS "I CANNOT TELL". With no remote, bootstrap_trunk returns empty and
  # AHEAD stays 0 — which would render as "clean, nothing unpushed", a claim with no evidence
  # behind it. A fail-safe default that mimics the healthy state is unfalsifiable, and the
  # operator reads it as a verdict.
  if   [ "$DIRTY_N" -gt 0 ]; then RUNG="DIRTY";   LEDGER="$DIRTY_N uncommitted file(s) on $BRANCH"
  elif [ -z "$TRUNK" ];      then RUNG="UNKNOWN"; LEDGER="tree clean on $BRANCH, but there is no remote trunk ref — whether this work is pushed anywhere is UNVERIFIED"
  elif [ "$AHEAD" -gt 0 ];   then RUNG="PARKED";  LEDGER="$AHEAD commit(s) on $BRANCH not on $TRUNK — push them or they live only on this disk"
  else                            RUNG="CLEAN";   LEDGER="clean, nothing unpushed on $BRANCH"
  fi
fi

# ── ARM B: THE CONTEXT ADVISORY. UNCONDITIONAL, AND IT READS NO GIT. ────────────────────
CTX="$(bootstrap_ctx_advisory "$SID")"

# ── ARM C: bounded auto-continue on THIS SESSION's own uncommitted work ───────────────────────
# rc 0 + a file list = mine and dirty · rc 1 = nothing of mine · rc 2 = cannot tell (abstain).
hook_mine_dirty() {
  local jq wrote hits="" rel w pre
  [ -n "$ROOT" ] || return 2
  [ "$DIRTY_N" -gt 0 ] || return 1
  jq="$(bootstrap_jq)" || return 2
  [ -n "$TP" ] && [ -f "$TP" ] || return 2
  wrote="$("$jq" -rn 'reduce inputs as $r ([];
      if $r.type=="assistant"
      then . + [ $r.message.content[]?
                 | select(.type=="tool_use")
                 | select(.name|test("^(Write|Edit|MultiEdit|NotebookEdit)$"))
                 | (.input.file_path // .input.notebook_path // empty)
                 | select(. != "") ]
      else . end) | .[]' "$TP" 2>/dev/null | sort -u)" || return 2
  [ -n "$wrote" ] || return 1
  # PHYSICAL vs LOGICAL. `rev-parse --show-toplevel` answers with the PHYSICAL path while the
  # transcript records the path as the tool was GIVEN it — logically. On macOS /tmp is a symlink
  # to /private/tmp and /Users can appear under /System/Volumes/Data, so a literal string compare
  # matches NOTHING and the arm reports "no writes of mine" over a tree full of them. (Measured:
  # ROOT=/private/tmp/fixture-repo vs transcript /tmp/fixture-repo/mine.txt — zero hits.) Fix: match the
  # repo-relative SUFFIX, then PROVE the prefix is this repo by resolving it with `cd -P`. The
  # suffix alone would false-match another checkout's identically-named file.
  # RESIDUAL, stated rather than papered over: a RENAME renders as `R  old -> new`; we take the
  # destination, and a rename whose destination we never wrote is simply never attributed. That
  # is a MISS, not a false block — it fails in the safe direction.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in *' -> '*) rel="${rel##* -> }" ;; esac
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      case "$w" in
        */"$rel")
          pre="${w%/$rel}"
          [ "$(cd "$pre" 2>/dev/null && pwd -P)" = "$ROOT" ] && { hits="$hits $rel"; break; } ;;
      esac
    done <<EOW
$wrote
EOW
  done <<EOF
$(printf '%s' "$PORC" | sed 's/^...//')
EOF
  [ -n "$hits" ] || return 1
  printf '%s' "${hits# }"
  return 0
}

CNT_F="$BOOTSTRAP_STATE_DIR/stop-count"; MAX="${BOOTSTRAP_STOP_MAX:-3}"; CNT=0
case "$MAX" in ''|*[!0-9]*) MAX=3 ;; esac
if [ -f "$CNT_F" ]; then
  CLINE="$(cat "$CNT_F" 2>/dev/null)"
  [ "${CLINE%% *}" = "$SID" ] && CNT="${CLINE##* }"
  case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac
fi
# reap a counter left by a session that ended days ago — the store cannot grow without bound
find "$BOOTSTRAP_STATE_DIR" -maxdepth 1 -name 'stop-count' -mtime "+${BOOTSTRAP_STOP_TTL_DAYS:-7}" -delete 2>/dev/null

MINE=""
if MINE="$(hook_mine_dirty)"; then :; else MINE=""; fi

# What the NEXT session's SessionStart brief will read back. With no repo there is no ledger to
# write, and "OK" on its own tells a successor nothing — say which state it actually was.
printf '%s %s\n' "$RUNG" "${LEDGER:-no git repo at that cwd — nothing to report}" \
  > "$BOOTSTRAP_STATE_DIR/last-ledger" 2>/dev/null || true

if [ -n "$MINE" ] && [ "$CNT" -lt "$MAX" ]; then
  printf '%s %s' "$SID" "$((CNT + 1))" > "$CNT_F" 2>/dev/null || true
  hook_block "$AGENT" \
    "Files you edited this turn are still uncommitted:$MINE. Run the project's gate, commit with explicit paths, then push. If this is deliberately parked, or is not your work, say so in your closing message and stop — this nudge fires at most $MAX times per session." \
    "mac-bootstrap [$((CNT + 1))/$MAX]: $RUNG — $LEDGER${CTX:+ · $CTX}"
  exit 0
fi

# ── no block: render whatever there is to say, and NEVER extend the turn ─────────────────────
# The render condition is `LEDGER or CTX`, never `LEDGER` alone — that gate is the advisory's, and it is the
# whole reason the advisory reaches a session standing in a directory that is not a repo.
LINE=""
[ -n "$LEDGER" ] && LINE="$RUNG — $LEDGER"
if [ -n "$CTX" ]; then
  if [ -n "$LINE" ]; then LINE="$LINE · $CTX"; else LINE="$CTX"; fi
fi
# alarm polarity: a clean tree with nothing to advise is not news.
[ "$RUNG" = CLEAN ] && [ -z "$CTX" ] && exit 0
[ -n "$LINE" ] && hook_say "$AGENT" "$LINE"
exit 0
