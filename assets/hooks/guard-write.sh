#!/bin/bash
# guard-write.sh — PreToolUse(Write|MultiEdit). The INTEGRATE-never-overwrite guard.
#
# PREVENTS: a full-file Write silently destroying sections of a file that accumulates state
# across sessions — a plan, a spec, AGENTS.md, a memory index. The loss is invisible: the write
# succeeds, the file is valid, and the decisions that were in it are simply gone.
# CAUSES: a timestamped backup on disk BEFORE the tool runs, and one line of context telling the
# model to integrate rather than replace, with the exact restore command.
#
# NEVER BLOCKS, on either agent. It is advisory plus a backup; the write always proceeds.
#
# 🚨 EVERY EXIT PATH IS AN EXPLICIT 0, and that is not style. Copilot CLI's preToolUse FAILS
# CLOSED: "exit 2, a crash, or any other non-zero exit denies the tool call, even if the hook's
# stdout JSON reports permissionDecision: allow". A crash here would block the agent's writes.
#
# ── TWO AGENTS, TWO COMPLETELY DIFFERENT WRITE SHAPES. MEASURED, and the second one is not what
#    the research predicted. ────────────────────────────────────────────────────────────────────
# CLAUDE CODE: tool_name "Write" / "MultiEdit", tool_input an OBJECT with file_path. "Edit" is
# deliberately NOT matched there: a Claude Code Edit is a targeted string replacement, it cannot
# silently drop sections, and matching it would add a fork per edit with no defect behind it.
#
# 🚨 COPILOT CLI 1.0.83, measured live on 2026-09-11 by registering this hook and running one real
# turn — NOT inferred from the docs, which say the payload is field-for-field Claude Code's:
#     {"hook_event_name":"PreToolUse","tool_name":"Edit",
#      "tool_input":"*** Begin Patch\n*** Delete File: /…/plan.md\n*** Add File: /…/plan.md\n+HELLO\n*** End Patch\n"}
# Three things are true at once there, and each one alone defeats a Claude-Code-shaped guard:
#   1. the tool is called "Edit" — the one name we are RIGHT to ignore on Claude Code;
#   2. `tool_input` is a STRING, not an object, so `tool_input.file_path` DOES NOT EXIST;
#   3. that "Edit" is a whole-file DELETE-then-ADD — precisely the destruction this hook exists
#      to make recoverable. The first run of this guard under a real Copilot turn backed up
#      NOTHING, and the file's two original lines would have been gone with no copy anywhere.
# So the match is: Claude Code's names as before, PLUS any payload whose tool_input is an
# apply-patch envelope, whatever the tool is called — the paths are read out of the patch's own
# `*** Update|Delete|Add File:` lines. An "Edit" carrying a patch is matched; an "Edit" carrying a
# file_path (Claude Code's shape) is still not.
# The remaining looseness — any unknown tool whose lowercased name contains write/edit AND whose
# input names an existing file — is ON PURPOSE and is safe BECAUSE this hook only ever copies a
# file and prints advice: a false positive costs one backup, a false negative costs the file.
#
# OUTPUT: Claude Code's PreToolUse additionalContext envelope. Copilot's preToolUse output fields
# are permissionDecision / permissionDecisionReason / modifiedArgs, with no advisory channel — so
# on Copilot the backup still happens and the advice is simply dropped. We do NOT emit an explicit
# permissionDecision:"allow" to smuggle the text through: that would auto-approve a tool call the
# user's own policy might have wanted to ask about. The backup is the load-bearing half anyway.
#
# Seams: BOOTSTRAP_WRITE_GUARD_HOOK=0 disables · BOOTSTRAP_STATE_DIR · BOOTSTRAP_GUARD_KEEP (default 10 backups per path)
#        BOOTSTRAP_GUARD_MAX_BYTES (default 20000000 — above it, advise without copying).
# NO `set -e`, no `pipefail` (CONTRACT.md §7.8). Self-test: bash guard-write.sh --selftest
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || HOOK_DIR="."
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

hook_wants() {                       # hook_wants <tool_name> → 0 if this tool can overwrite a file
  case "${1:-}" in
    Write|MultiEdit) return 0 ;;
    Edit|Read|Bash|Glob|Grep|WebFetch|WebSearch|Task|NotebookEdit) return 1 ;;
  esac
  # the unknown-tool arm: lowercase, and never ${x,,} — bash 3.2 does not have it.
  case "$(printf '%s' "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
    *write*|*edit*|*create_file*|*patch*) return 0 ;;
  esac
  return 1
}

# hook_patch_paths <tool_input-as-text> — the files an apply-patch envelope touches, one per line.
# Copilot's edit tool hands the whole patch through as a STRING; its header lines are the only
# place a path appears. `Add File:` is included because an add over an existing path is an
# overwrite — and when the path does not exist the caller simply finds nothing to back up.
hook_patch_paths() {
  # The awk pass turns a LITERAL backslash-n back into a real newline before the header lines are
  # matched. That is not cosmetic: with jq the string arrives decoded, but on the plutil/no-jq arm
  # the whole patch can arrive as ONE line with `\n` still escaped, and every `^\*\*\*` anchor then
  # matches nothing — the guard would go quietly inert on exactly the machine the degrade exists
  # for. Harmless when the text is already decoded, because there is no literal `\n` left to find.
  printf '%s' "${1:-}" \
    | LC_ALL=C awk '{ gsub(/\\n/, "\n"); print }' \
    | LC_ALL=C sed -E -n 's/^\*\*\* (Update|Delete|Add) File: //p'
}
hook_is_patch() {                    # is this tool_input an apply-patch envelope rather than a dict?
  case "${1:-}" in *'*** '*'File:'*) return 0 ;; esac
  return 1
}

hook_guard_write_main() {
  local IN TOOL F TI SEEN MSG FRAG
  [ "${BOOTSTRAP_WRITE_GUARD_HOOK:-1}" = 1 ] || return 0
  IN="$(cat 2>/dev/null || true)"
  TOOL="$(hook_field "$IN" tool_name)"
  F="$(hook_field "$IN" tool_input.file_path)"
  if [ -n "$F" ]; then
    hook_wants "$TOOL" || return 0                 # the Claude Code shape: one path in the payload
    MSG="$(hook_backup_one "$F")"
    [ -n "$MSG" ] && bootstrap_emit_ctx PreToolUse "$MSG"
    return 0
  fi
  # No file_path. Either this tool touches no file at all, or it is an apply-patch envelope —
  # which is how Copilot CLI's edit tool arrives, and which can delete and recreate a whole file.
  TI="$(bootstrap_json "$IN" tool_input)"
  hook_is_patch "$TI" || return 0
  # ONE OBJECT ON STDOUT, ALWAYS. A patch that deletes and re-adds the same path names it TWICE
  # (measured — that is exactly the shape Copilot sent), and an earlier draft emitted one JSON
  # object per line: two objects on a hook's stdout is not "two messages", it is malformed output,
  # and a parser that reads the first and chokes on the second drops the whole chain. So: dedupe
  # the paths, back each up once, and emit a single advisory naming all of them.
  SEEN="|"; MSG=""
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    case "$SEEN" in *"|$F|"*) continue ;; esac
    SEEN="$SEEN$F|"
    FRAG="$(hook_backup_one "$F")"
    [ -n "$FRAG" ] && MSG="$MSG$FRAG "
  done <<EOP
$(hook_patch_paths "$TI")
EOP
  [ -n "$MSG" ] && bootstrap_emit_ctx PreToolUse "$MSG"
  return 0
}

# hook_backup_one <path> — copy it aside and PRINT one plain-text fragment. Silent when there is
# nothing to destroy. It does not emit JSON: main owns the envelope, so stdout can never hold two.
hook_backup_one() {
  local F="${1:-}" B BK KEEP p o n sz keepn
  [ -n "$F" ] && [ -f "$F" ] || return 0          # a NEW file has nothing to destroy

  B="$BOOTSTRAP_STATE_DIR/backups"; mkdir -p "$B" 2>/dev/null || true
  BK="$B/$(basename "$F")__$(date +%Y%m%d-%H%M%S)-$$-${RANDOM:-0}.bak"
  sz="$(stat -f %z "$F" 2>/dev/null)"; case "${sz:-}" in ''|*[!0-9]*) sz=0 ;; esac
  if [ "$sz" -gt "${BOOTSTRAP_GUARD_MAX_BYTES:-20000000}" ]; then
    printf "OVERWRITE GUARD: '%s' is %s bytes — too large to back up inside a hook, so this write is UNBACKED. INTEGRATE new content; do not replace the file." "$(basename "$F")" "$sz"
    return 0
  fi

  if cp -L "$F" "$BK" 2>/dev/null; then
    # The identity of a backup is the SOURCE PATH, not the basename: two repos' AGENTS.md must
    # not evict each other. The sidecar carries it, so rotation keys on the sidecar's CONTENT.
    printf '%s\n' "$F" > "${BK%.bak}.path" 2>/dev/null || true
    keepn="${BOOTSTRAP_GUARD_KEEP:-10}"; case "$keepn" in ''|*[!0-9]*) keepn=10 ;; esac
    KEEP=""
    for p in "$B/$(basename "$F")__"*.path; do
      [ -f "$p" ] || continue
      [ "$(cat "$p" 2>/dev/null)" = "$F" ] && KEEP="$KEEP$p
"
    done
    printf '%s' "$KEEP" | sort -r | tail -n "+$((keepn + 1))" | while IFS= read -r o; do
      [ -n "$o" ] && rm -f "${o%.path}.bak" "$o" 2>/dev/null
    done
    n="$(wc -l < "$F" 2>/dev/null | tr -d ' ')"; case "${n:-}" in ''|*[!0-9]*) n="?" ;; esac
    printf "OVERWRITE GUARD: '%s' already exists (%s lines). Backup: %s. INTEGRATE new content — do not delete or restructure existing sections; prefer a targeted edit over a whole-file write. Restore with: cp '%s' '%s'" "$(basename "$F")" "$n" "$BK" "$BK" "$F"
  else
    printf "WARNING: the backup of '%s' FAILED (disk or permissions). This write will proceed UNBACKED. Make a targeted edit instead of replacing the file." "$(basename "$F")"
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# SHIPPED FIXTURES — bash guard-write.sh --selftest
# The negative controls are the point: a guard that fires on everything proves nothing about the
# one case it exists for, and "the hook fired" is unfalsifiable without a tool name that must NOT
# fire and an event name that does not exist.
# ═════════════════════════════════════════════════════════════════════════════════════════════
hook_selftest() {
  local T n=0 bad=0 out before after i
  T="$(mktemp -d -t pbgw)" || return 30
  mkdir -p "$T/state"
  printf 'line1\nline2\n' > "$T/plan.md"
  printf 'pb-guard-write selftest · bash %s\n' "${BASH_VERSION:-?}"
  _ok()  { n=$((n+1)); printf '  ok   %s\n' "$1"; }
  _bad() { n=$((n+1)); bad=$((bad+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
  _fire() {   # _fire <tool_name> <file> → stdout of the hook
    BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$HOOK_SELF" <<XIN 2>/dev/null
{"hook_event_name":"PreToolUse","session_id":"GW","cwd":"$T","tool_name":"$1","tool_input":{"file_path":"$2"}}
XIN
  }
  _count() { ls "$T/state/backups/"*.bak 2>/dev/null | bootstrap_count; }

  before="$(_count)"
  out="$(_fire Write "$T/plan.md")"
  after="$(_count)"
  [ "$after" -gt "$before" ] && _ok "Write on an existing file WRITES A BACKUP ($before → $after)" \
                             || _bad "Write did not produce a backup" "count stayed $after"
  case "$out" in *'OVERWRITE GUARD'*) _ok "…and emits the advisory" ;; *) _bad "no advisory emitted" "[$out]" ;; esac
  case "$out" in *'"PreToolUse"'*) _ok "…in the PreToolUse envelope" ;; *) _bad "wrong envelope" "[$out]" ;; esac
  if [ -n "$out" ]; then
    printf '%s' "$out" > "$T/out.json"
    if bootstrap_json_ok "$T/out.json"; then _ok "…and that output is valid JSON (parsed, not grepped)"
    else _bad "hook stdout is not valid JSON" "[$out]"; fi
  fi

  # NEGATIVE CONTROL 1 — a tool that cannot overwrite a file must write NOTHING.
  before="$(_count)"; out="$(_fire NotAToolXYZ "$T/plan.md")"; after="$(_count)"
  if [ "$after" = "$before" ] && [ -z "$out" ]; then _ok "NEGATIVE: an unknown non-write tool writes nothing and says nothing"
  else _bad "NEGATIVE: unknown tool produced output or a backup" "out=[$out] $before→$after"; fi

  # NEGATIVE CONTROL 2 — Edit is deliberately not matched.
  before="$(_count)"; out="$(_fire Edit "$T/plan.md")"; after="$(_count)"
  if [ "$after" = "$before" ] && [ -z "$out" ]; then _ok "NEGATIVE: Edit is not matched (targeted by construction)"
  else _bad "NEGATIVE: Edit fired the guard" "out=[$out]"; fi

  # NEGATIVE CONTROL 3 — a file that does not exist yet has nothing to destroy.
  before="$(_count)"; out="$(_fire Write "$T/brand-new.md")"; after="$(_count)"
  if [ "$after" = "$before" ] && [ -z "$out" ]; then _ok "NEGATIVE: a new file produces no backup"
  else _bad "NEGATIVE: new file produced a backup" "out=[$out]"; fi

  # The Copilot arm: an unverified write-ish tool name still gets a backup.
  before="$(_count)"; out="$(_fire str_replace_editor "$T/plan.md")"; after="$(_count)"
  [ "$after" -gt "$before" ] && _ok "Copilot arm: an unknown *edit* tool still backs the file up" \
                             || _bad "Copilot arm did not fire" "$before→$after"

  # ROTATION — newest BOOTSTRAP_GUARD_KEEP per SOURCE PATH, and a same-basename file elsewhere survives.
  mkdir -p "$T/other"; printf 'x\n' > "$T/other/plan.md"
  BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_GUARD_KEEP=3 /bin/bash "$HOOK_SELF" >/dev/null 2>&1 <<XIN
{"tool_name":"Write","tool_input":{"file_path":"$T/other/plan.md"}}
XIN
  i=0
  while [ "$i" -lt 6 ]; do
    BOOTSTRAP_STATE_DIR="$T/state" BOOTSTRAP_GUARD_KEEP=3 /bin/bash "$HOOK_SELF" >/dev/null 2>&1 <<XIN
{"tool_name":"Write","tool_input":{"file_path":"$T/plan.md"}}
XIN
    i=$((i + 1))
  done
  n=$((n+1))
  after="$(grep -l "^$T/plan.md$" "$T/state/backups/"*.path 2>/dev/null | bootstrap_count)"
  if [ "$after" -le 3 ]; then printf '  ok   rotation keeps at most BOOTSTRAP_GUARD_KEEP per source path (%s)\n' "$after"
  else bad=$((bad+1)); printf '  FAIL rotation kept %s, want <= 3\n' "$after"; fi
  n=$((n+1))
  after="$(grep -l "^$T/other/plan.md$" "$T/state/backups/"*.path 2>/dev/null | bootstrap_count)"
  if [ "$after" -ge 1 ]; then printf '  ok   a same-basename file in another directory is NOT evicted\n'
  else bad=$((bad+1)); printf '  FAIL the other directory backup was evicted\n'; fi

  # ── COPILOT CLI's REAL WRITE SHAPE, captured verbatim from a live turn on 1.0.83. ──────────
  # tool_name "Edit", tool_input a STRING holding an apply-patch that DELETES and re-ADDS the
  # file. Registered with no matcher (its write-tool name could not be predicted), this is what
  # arrived, and the first version of this guard backed up nothing at all.
  printf 'copilot one\ncopilot two\n' > "$T/cop.md"
  before="$(_count)"
  out="$(BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$HOOK_SELF" 2>/dev/null <<XIN
{"hook_event_name":"PreToolUse","session_id":"E2E","tool_name":"Edit","tool_input":"*** Begin Patch\\n*** Delete File: $T/cop.md\\n*** Add File: $T/cop.md\\n+HELLO\\n*** End Patch\\n"}
XIN
)"
  after="$(_count)"
  n=$((n+1))
  if [ "$after" -gt "$before" ]; then printf '  ok   COPILOT apply-patch Edit (tool_input is a STRING) still gets a backup\n'
  else bad=$((bad+1)); printf '  FAIL COPILOT apply-patch Edit wrote NO backup — the file would be unrecoverable\n'; fi
  # …and the same patch names that path TWICE (Delete then Add). Stdout must still be ONE object.
  printf '%s' "$out" > "$T/cop.json"
  n=$((n+1))
  if bootstrap_json_ok "$T/cop.json"; then printf '  ok   …and a path named twice in one patch still yields exactly ONE JSON object\n'
  else bad=$((bad+1)); printf '  FAIL two JSON objects on stdout — malformed hook output: [%s]\n' "$out"; fi
  n=$((n+1))
  if [ "$(printf '%s' "$out" | grep -c 'hookEventName')" = 1 ]; then printf '  ok   …exactly one envelope, counted\n'
  else bad=$((bad+1)); printf '  FAIL more than one envelope on stdout\n'; fi

  # …and the Claude Code Edit must STILL not fire: same tool name, different shape, no patch.
  before="$(_count)"
  out="$(_fire Edit "$T/plan.md")"
  after="$(_count)"
  n=$((n+1))
  if [ "$after" = "$before" ] && [ -z "$out" ]; then printf '  ok   NEGATIVE: a Claude Code Edit (file_path, no patch) is still not matched\n'
  else bad=$((bad+1)); printf '  FAIL NEGATIVE: the Claude Code Edit fired the guard\n'; fi

  # …and a patch that only ADDS a file that does not exist has nothing to destroy.
  before="$(_count)"
  BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$HOOK_SELF" >/dev/null 2>&1 <<'XIN'
{"tool_name":"Edit","tool_input":"*** Begin Patch\n*** Add File: /nonexistent/pb/nope.md\n+hi\n*** End Patch\n"}
XIN
  after="$(_count)"
  n=$((n+1))
  if [ "$after" = "$before" ]; then printf '  ok   NEGATIVE: a patch adding a file that does not exist backs nothing up\n'
  else bad=$((bad+1)); printf '  FAIL NEGATIVE: backed up a file that does not exist\n'; fi

  # …and the patch arm must survive the PLUTIL ARM too: without jq the patch can arrive as one
  # line with its newlines still escaped, and every header anchor then matches nothing.
  printf 'nojq one\nnojq two\n' > "$T/cop2.md"
  before="$(_count)"
  BOOTSTRAP_NO_JQ=1 BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$HOOK_SELF" >/dev/null 2>&1 <<XIN
{"tool_name":"Edit","tool_input":"*** Begin Patch\\n*** Delete File: $T/cop2.md\\n*** Add File: $T/cop2.md\\n+HELLO\\n*** End Patch\\n"}
XIN
  after="$(_count)"
  n=$((n+1))
  if [ "$after" -gt "$before" ]; then printf '  ok   NO-JQ arm: the apply-patch envelope still resolves its paths\n'
  else bad=$((bad+1)); printf '  FAIL NO-JQ arm: the patch guard is inert without jq\n'; fi

  # NO-JQ ARM. tool_input.file_path is a NESTED read, which the library's no-jq reader refuses;
  # before hook_field this hook was inert without jq and this case is what says so out loud.
  before="$(_count)"
  BOOTSTRAP_NO_JQ=1 BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$HOOK_SELF" >/dev/null 2>&1 <<XIN
{"tool_name":"Write","tool_input":{"file_path":"$T/plan.md"}}
XIN
  after="$(_count)"
  n=$((n+1))
  if [ "$after" -gt "$before" ]; then printf '  ok   NO-JQ arm: the nested file_path still resolves and the backup is written\n'
  else bad=$((bad+1)); printf '  FAIL NO-JQ arm: no backup — the guard is inert without jq\n'; fi

  # Never blocks, whatever happens: rc 0 even on unreadable stdin.
  n=$((n+1))
  BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$HOOK_SELF" < /dev/null >/dev/null 2>&1
  if [ $? -eq 0 ]; then printf '  ok   empty stdin still exits 0 (Copilot preToolUse fails CLOSED)\n'
  else bad=$((bad+1)); printf '  FAIL empty stdin exited non-zero — that DENIES the tool call on Copilot\n'; fi

  printf '\n%s/%s cases passed.\n' "$((n - bad))" "$n"
  rm -rf "$T" 2>/dev/null
  [ "$bad" = 0 ] && return 0
  return 1
}

case "${1:-}" in
  --selftest) hook_selftest; exit $? ;;
esac
hook_guard_write_main
exit 0
