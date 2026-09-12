#!/bin/bash
# session-start.sh — SessionStart (Claude Code) · SessionStart→sessionStart (Copilot CLI).
#
# THE WHERE-WE-WERE BRIEF, injected as additionalContext before the model's first turn.
#
# PREVENTS: a successor re-deriving state the disk already holds and — the expensive one —
# re-judging SCOPE from scratch. A session that cannot see the frozen scope grows it silently;
# close-time completeness is meant to be a diff against a contract, not a fresh opinion.
#
# CAUSES: four facts in context before turn 1 —
#   1. the frozen scope, if one was written (.agent/scope.md at cwd or repo root, else state dir)
#   2. the ledger the previous Stop left behind (dirty / parked / unknown / clean)
#   3. live git state for this checkout, read NOW, not remembered
#   4. a PRECONDITION warning when jq is absent — because pb-guard-bash and pb-stop's arm C are
#      INERT without it. A guard believed present but inert is worse than one known absent.
#
# NEVER BLOCKS. SessionStart has no blocking contract anywhere; this is context injection, exit 0.
#
# ── TWO AGENTS, ONE FILE, TWO OUTPUT ENVELOPES ───────────────────────────────────────────────
# Claude Code reads  {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":…}}
# Copilot CLI reads  {"additionalContext":…}                      (its sessionStart output field)
# We emit BOTH KEYS IN ONE OBJECT. Each agent ignores the other's, so one file serves both with
# no shim. (bootstrap_emit_ctx in the library emits the Claude Code envelope only — hence hook_emit_ctx
# below, which is this file's own helper and is noted as such.)
#
# 🚨 HONEST BOUND on the Copilot arm: copilot-surface.md §3.7 measured the sentinel appearing in
# the `hook.end` record and NOT in `system.message`/`user.message` under `copilot -p`. So the
# injection is PARSED there; whether it reaches the model in non-interactive mode is UNVERIFIED.
# It is free to emit and costs nothing if ignored.
#
# Seams: BOOTSTRAP_STATE_DIR (default $HOME/.mac-bootstrap) · BOOTSTRAP_SESSION_START_HOOK=0 disables.
# NO `set -e`, and deliberately NO `pipefail`: under pipefail a SIGPIPEd stage makes `$?` the
# wrong answer (CONTRACT.md §7.8, measured 1-in-80). `set -u` only.
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || HOOK_DIR="."
# shellcheck source=bootstrap-lib.sh disable=SC1091
. "$HOOK_DIR/bootstrap-lib.sh" 2>/dev/null || exit 0      # no library ⇒ say nothing, never wedge
[ "${BOOTSTRAP_SESSION_START_HOOK:-1}" = 1 ] || exit 0

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

# ── hook_emit_ctx <event> <text> — BOTH envelopes in one object. ──────────────────────────────
# The no-jq arm STRIPS the characters it cannot escape rather than trying to quote them: the one
# message that MUST survive a missing jq is the warning that jq is missing, and a hand-built JSON
# string from arbitrary text is how a hook emits malformed output and gets its chain ignored.
hook_emit_ctx() {
  local jq c
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then
    "$jq" -nc --arg e "${1:-}" --arg c "${2:-}" \
      '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c},additionalContext:$c}' && return 0
  fi
  c="$(printf '%s' "${2:-}" | LC_ALL=C tr -d '"\\' | LC_ALL=C tr '\n\r\t' '   ')"
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"},"additionalContext":"%s"}\n' \
    "${1:-}" "$c" "$c"
  return 0
}

IN="$(cat 2>/dev/null || true)"
CWD="$(hook_field "$IN" cwd)"; [ -n "$CWD" ] || CWD="$PWD"
ROOT="$(bootstrap_git "$CWD" rev-parse --show-toplevel)"

MSG=""
if ! bootstrap_have_jq; then
  MSG="PRECONDITION: jq is NOT on PATH. Everything in this hook set still works through plutil EXCEPT pb-stop's auto-continue arm, which has to read the JSONL transcript to tell files YOU edited from files someone else left dirty — it abstains rather than guess, so a loose end will not be fed back to you at the turn boundary. macOS 15 ships /usr/bin/jq on the sealed system volume; if it is missing here, something removed it. "
fi

# Frozen scope. ROOT is empty outside a repo, so it is tested rather than pasted into a path —
# "$ROOT/.agent/scope.md" with an empty ROOT reads /.agent/scope.md, a file nobody owns.
SCOPE=""
for f in "$CWD/.agent/scope.md" "${ROOT:-$CWD}/.agent/scope.md" "$BOOTSTRAP_STATE_DIR/scope.md"; do
  [ -f "$f" ] || continue
  SCOPE="$(head -c 600 "$f" 2>/dev/null)"
  [ -n "$SCOPE" ] && break
done
[ -n "$SCOPE" ] && MSG="${MSG}FROZEN SCOPE (the contract this session's close is a diff against — do not grow it silently; if you add to it, append a 'Scope (grown): +<item>' line to that file so the growth is auditable): ${SCOPE} "

[ -f "$BOOTSTRAP_STATE_DIR/last-ledger" ] && \
  MSG="${MSG}LAST SESSION ENDED: $(head -c 200 "$BOOTSTRAP_STATE_DIR/last-ledger" 2>/dev/null) "

if [ -n "$ROOT" ]; then
  BR="$(bootstrap_git "$ROOT" rev-parse --abbrev-ref HEAD)"
  DN="$(bootstrap_git "$ROOT" status --porcelain | bootstrap_count)"
  TR="$(bootstrap_trunk "$ROOT")"
  AH=0
  if [ -n "$TR" ]; then
    AH="$(bootstrap_git "$ROOT" rev-list --count "$TR..HEAD")"
    case "${AH:-}" in ''|*[!0-9]*) AH=0 ;; esac
  fi
  LOG="$(bootstrap_git "$ROOT" log -3 --format='%h %s' | tr '\n' ';')"
  MSG="${MSG}GIT NOW (live read, not memory): branch ${BR:-?} · ${DN:-0} uncommitted · ${AH} commit(s) ahead of ${TR:-<no remote trunk ref — unpushed-ness is UNVERIFIED>} · recent: ${LOG:-none}"
fi

[ -n "$MSG" ] && hook_emit_ctx SessionStart "$MSG"
exit 0
