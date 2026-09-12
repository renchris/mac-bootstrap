#!/bin/bash
# verify-instructions-live.sh — does the agent ACTUALLY read this repo's instructions file?
#
#   bash verify-instructions-live.sh [<repo-dir>] [--yes] [--marker "<line>"]
#
# This is NOT part of `bootstrap.sh --verify`, deliberately: it starts a real agent turn, so it
# costs tokens on the Claude Code arm and AI credits on the Copilot arm, and it needs an agent
# that is already logged in. `verify_instructions` proves the FILES are right; this proves the
# AGENT SEES THEM, which is a different claim and the only one that matters in the end.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# 🚨 WHY THIS IS NOT THE ONE-LINER THE RESEARCH ORIGINALLY SHIPPED.
#
# That command was:
#   claude -p 'Do not use any tools. Name one rule from this project'"'"'s instructions.
#            If none are in your context, answer exactly UNKNOWN.'
#
# It CANNOT FAIL. Measured in `g_clean`, a git repo containing nothing but a README:
#   2.1.114 → "Landing goes through /ship; a bare git push is never the move."
#   2.1.183 → "One rule from this project's instructions: Git commit messages must start
#              lowercase…"
# Both confident, both `num_turns=1`, neither from any project file — because the phrase "this
# project's instructions" is satisfied by the GLOBAL `~/.claude/CLAUDE.md` that step 1 of this
# same bootstrap installs. A check that passes identically whether or not the wiring worked is a
# check that certifies success unconditionally.
#
# THE SOUND ORACLE IS A RETRIEVAL ORACLE KEYED ON CONTENT ONLY THE PROJECT FILE CAN SUPPLY, WITH
# AN EMPTY CONTROL DIRECTORY THAT MUST ANSWER `UNKNOWN`. The per-repo template mandates a `Test`
# command line, and no global file can know a per-project test command. That is the key used
# below, and the empty-control arm is what makes a PASS mean anything: this script reports a
# PASS only when the wired repo answers AND the empty control does not.
#
# Two further constraints, both measured:
#  · A *reporting* oracle ("tell me what is in your context") is unreliable in BOTH directions —
#    it returned a false `UNKNOWN` for a fixture that a retrieval probe proved loaded on the same
#    binary minutes earlier. Never ask the model to describe its context; ask it for a fact.
#  · A sentinel must NEVER be an HTML comment. Block-level HTML comments are stripped before the
#    content is injected into the model's context, so a `<!-- SENTINEL -->` marker is invisible
#    and would read as "not loaded" forever.
#
# The Copilot arm cannot use a retrieval oracle at all: asked to enumerate its instructions it
# answers "I can't provide or enumerate confidential system or custom-instruction content." It
# gets a MECHANICAL oracle instead — Copilot writes its whole system prompt verbatim into
# `~/.copilot/session-state/<uuid>/events.jsonl`, so the marker line is COUNTED there rather than
# asked for. Same empty-control arm.
# ─────────────────────────────────────────────────────────────────────────────────────────────
#
# Exit codes:  0 every arm that ran PASSED (and at least one ran) · 1 an arm FAILED
#              2 nothing could run (no agent installed, or the marker could not be derived)
#              3 bad usage
#
# A skipped arm is reported as SKIPPED with its reason and never as a pass.

set -u

VIL_DIR="."
VIL_YES=0
VIL_MARKER=""
VIL_TMP=""

# The agent binaries. Seams, because `claude` is not always a binary: on a machine that wraps it
# in a shell function (a version pinner, a launcher) a non-interactive `claude -p` dies rc 127
# with `command not found: _claude_pinned`, and an arm that reads a non-zero rc as "not logged
# in" would report SKIP forever without ever naming the real cause. Point these at the real
# executable to run the arm anyway:  CLAUDE_BIN=~/.claude-versions/X/node_modules/.bin/claude
VIL_CLAUDE="${CLAUDE_BIN:-claude}"
VIL_COPILOT="${COPILOT_BIN:-copilot}"

vil_usage() { sed -n '2,12p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)  VIL_YES=1 ;;
    --marker)  [ $# -ge 2 ] || { printf 'need a string after --marker\n' >&2; exit 3; }
               VIL_MARKER="$2"; shift ;;
    --claude)  [ $# -ge 2 ] || { printf 'need a path after --claude\n' >&2; exit 3; }
               VIL_CLAUDE="$2"; shift ;;
    --copilot) [ $# -ge 2 ] || { printf 'need a path after --copilot\n' >&2; exit 3; }
               VIL_COPILOT="$2"; shift ;;
    --help|-h) vil_usage; exit 0 ;;
    -*)        printf 'unknown argument: %s\n' "$1" >&2; exit 3 ;;
    *)         VIL_DIR="$1" ;;
  esac
  shift
done

[ -d "$VIL_DIR" ] || { printf 'not a directory: %s\n' "$VIL_DIR" >&2; exit 3; }
VIL_DIR="$(cd "$VIL_DIR" 2>/dev/null && pwd -P)" || { printf 'cannot enter %s\n' "$VIL_DIR" >&2; exit 3; }

# Keep the scratch dir when something went wrong: its .err files are the ONLY evidence for a
# SKIP, and deleting them leaves a message that names a path which no longer exists.
vil_cleanup() {
  [ -n "$VIL_TMP" ] || return 0
  if [ "${VIL_FAIL:-0}" != 0 ] || [ "${VIL_SKIP:-0}" != 0 ]; then
    printf 'kept for inspection: %s\n' "$VIL_TMP"
    return 0
  fi
  rm -rf "$VIL_TMP" 2>/dev/null
  return 0
}
trap vil_cleanup EXIT
VIL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vil.XXXXXX")" || { printf 'cannot make a temp dir\n' >&2; exit 2; }

VIL_CTRL="$VIL_TMP/control"          # THE NEGATIVE CONTROL: a directory with no instructions file
mkdir -p "$VIL_CTRL" 2>/dev/null
printf 'placeholder\n' > "$VIL_CTRL/README.md" 2>/dev/null
command -v git >/dev/null 2>&1 && ( cd "$VIL_CTRL" && git init -q . >/dev/null 2>&1 )

# ── the marker: a line only THIS repo's instructions file can supply ─────────────────────────
# Derived from the template's mandated `- Test <cmd>` line. Refuses an unfilled template, because
# `<cmd>` is not content — a probe keyed on a placeholder would be answered by any repo at all.
vil_src=""
for c in "$VIL_DIR/AGENTS.md" "$VIL_DIR/CLAUDE.md"; do
  [ -r "$c" ] && { vil_src="$c"; break; }
done

if [ -z "$VIL_MARKER" ]; then
  if [ -z "$vil_src" ]; then
    printf 'no AGENTS.md or CLAUDE.md in %s — there is nothing to verify.\n' "$VIL_DIR" >&2
    exit 2
  fi
  VIL_MARKER="$(sed -n 's/^[-*] *Test  *//p' "$vil_src" 2>/dev/null | sed -n '1p')"
  [ -n "$VIL_MARKER" ] || VIL_MARKER="$(sed -n 's/^[-*] *Test:  *//p' "$vil_src" 2>/dev/null | sed -n '1p')"
fi

case "$VIL_MARKER" in
  ''|*'<cmd>'*|*'<'*'>'*)
    printf 'could not derive a usable marker from %s\n' "${vil_src:-<none>}" >&2
    printf '  Expected a filled-in line like:   - Test `pnpm vitest run`\n' >&2
    printf '  An unfilled <cmd> placeholder cannot discriminate — fill the template, or pass --marker.\n' >&2
    exit 2 ;;
esac

# The command inside the first backticks — what the model is expected to answer with.
VIL_CMD="$(printf '%s' "$VIL_MARKER" | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p')"
[ -n "$VIL_CMD" ] || VIL_CMD="$VIL_MARKER"

VIL_PROMPT='Do not use any tools. What is the test command for this project? Answer in one line. If it is not already stated in your context, answer exactly UNKNOWN.'

printf 'repo    : %s\n' "$VIL_DIR"
printf 'source  : %s\n' "${vil_src:-<--marker>}"
printf 'marker  : %s\n' "$VIL_MARKER"
printf 'expect  : the agent answers with %s here, and UNKNOWN in an empty control directory\n\n' "$VIL_CMD"

# ── the money gate ───────────────────────────────────────────────────────────────────────────
# This is the one irreversible thing here: it spends the operator's tokens and AI credits. It is
# printed resolved, and it waits for a typed yes. Reversible work above ran silently.
if [ "$VIL_YES" != 1 ]; then
  printf 'This starts up to FOUR real agent turns and SPENDS TOKENS / AI CREDITS:\n'
  printf '  claude  -p "…" in the repo, and again in an empty control directory\n'
  printf '  copilot -p "…" in the repo, and again in an empty control directory\n'
  printf 'Nothing is written to the repo, and no file is changed. Type yes to continue: '
  read -r vil_ans
  [ "$vil_ans" = "yes" ] || { printf 'stopped — nothing was spent.\n'; exit 0; }
  printf '\n'
fi

VIL_PASS=0; VIL_FAIL=0; VIL_SKIP=0
vil_pass() { VIL_PASS=$((VIL_PASS+1)); printf '  PASS %s\n' "$1"; }
vil_fail() { VIL_FAIL=$((VIL_FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
vil_skip() { VIL_SKIP=$((VIL_SKIP+1)); printf '  SKIP %s — %s\n' "$1" "$2"; }

# ── ARM A — Claude Code, retrieval oracle ────────────────────────────────────────────────────
# num_turns is asserted to be 1: without it a run that used tools could simply READ AGENTS.md off
# the disk and answer correctly for a repo whose wiring never loaded anything — a false PASS.
# Parsed with plutil, which is on every Mac; note that `plutil -extract` writes its FAILURE
# MESSAGE TO STDOUT, so every read below is gated on its own rc.
vil_claude() {                                   # vil_claude <cwd> <outvar-file>
  local cwd="$1" out="$2" rc
  ( cd "$cwd" 2>/dev/null && "$VIL_CLAUDE" -p "$VIL_PROMPT" --output-format json ) >"$out" 2>"$out.err"
  rc=$?
  printf '%s' "$rc"
}
vil_json() {                                     # vil_json <file> <key> → value, rc 1 if absent
  local v rc
  v="$(/usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$v"
}

printf 'arm A — Claude Code (retrieval oracle)\n'
if ! command -v "$VIL_CLAUDE" >/dev/null 2>&1; then
  vil_skip "claude" "$VIL_CLAUDE is not on PATH — install it and log in, then re-run"
else
  vil_rc="$(vil_claude "$VIL_DIR" "$VIL_TMP/cc.json")"
  if [ "$vil_rc" != 0 ]; then
    if [ "$vil_rc" = 127 ]; then
      vil_skip "claude wired-repo arm" "$VIL_CLAUDE is not executable here (a shell-function wrapper? pass --claude <real binary>)"
    else
      vil_skip "claude wired-repo arm" "$VIL_CLAUDE exited $vil_rc — not logged in? see $VIL_TMP/cc.json.err"
    fi
  else
    vil_turns="$(vil_json "$VIL_TMP/cc.json" num_turns)" || vil_turns=""
    vil_ans="$(vil_json "$VIL_TMP/cc.json" result)"      || vil_ans=""
    if [ -z "$vil_ans" ]; then
      vil_skip "claude wired-repo arm" "no .result in the JSON reply"
    elif [ -n "$vil_turns" ] && [ "$vil_turns" != 1 ]; then
      vil_skip "claude wired-repo arm" "num_turns=$vil_turns — it used tools, so this answer is not evidence about context"
    else
      case "$vil_ans" in
        *"$VIL_CMD"*) vil_pass "claude reads this repo's instructions   [$vil_ans]" ;;
        *)            vil_fail "claude did NOT answer with the project's test command" "got: $vil_ans" ;;
      esac
    fi

    # the control arm — this is the half the refuted one-liner did not have
    vil_rc="$(vil_claude "$VIL_CTRL" "$VIL_TMP/ccctl.json")"
    if [ "$vil_rc" != 0 ]; then
      vil_skip "claude empty-control arm" "claude exited $vil_rc"
    else
      vil_ans="$(vil_json "$VIL_TMP/ccctl.json" result)" || vil_ans=""
      case "$vil_ans" in
        *"$VIL_CMD"*) vil_fail "the EMPTY CONTROL answered with this repo's test command" \
                                "the probe cannot discriminate — do not trust the arm above. got: $vil_ans" ;;
        *UNKNOWN*)    vil_pass "empty control answers UNKNOWN (the probe can say no)" ;;
        '')           vil_skip "claude empty-control arm" "no .result in the JSON reply" ;;
        *)            vil_pass "empty control does not produce this repo's command  [$vil_ans]" ;;
      esac
    fi
  fi
fi

# ── ARM B — Copilot CLI, mechanical oracle over its own event log ────────────────────────────
# Copilot refuses to enumerate its instructions, so the marker is counted in the session's
# events.jsonl, where the system prompt is written verbatim. The session directory is identified
# by mtime AFTER a marker file, never by "the newest one" alone.
printf '\narm B — GitHub Copilot CLI (mechanical oracle over events.jsonl)\n'
VIL_CPSTATE="${COPILOT_HOME:-$HOME/.copilot}/session-state"
if ! command -v "$VIL_COPILOT" >/dev/null 2>&1; then
  vil_skip "copilot" "$VIL_COPILOT is not on PATH — install it and authenticate, then re-run"
elif [ ! -d "$VIL_CPSTATE" ]; then
  vil_skip "copilot" "no session-state directory yet — run copilot once interactively first"
else
  vil_copilot() {                                # vil_copilot <cwd> → prints the marker count
    local cwd="$1" stamp="$VIL_TMP/stamp.$$" f n newest=""
    : > "$stamp"
    ( cd "$cwd" 2>/dev/null && copilot -p 'Reply with the single word ok.' --no-color ) \
      >"$VIL_TMP/cp.out" 2>&1
    for f in "$VIL_CPSTATE"/*/events.jsonl; do
      [ -r "$f" ] || continue
      [ "$f" -nt "$stamp" ] || continue
      newest="$f"
    done
    rm -f "$stamp" 2>/dev/null
    [ -n "$newest" ] || { printf 'NOSESSION'; return 0; }
    n="$(/usr/bin/grep -c -F -- "$VIL_MARKER" "$newest" 2>/dev/null)" || n=0
    case "${n:-0}" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
  }
  vil_n="$(vil_copilot "$VIL_DIR")"
  if [ "$vil_n" = NOSESSION ]; then
    vil_skip "copilot wired-repo arm" "no new events.jsonl appeared (see $VIL_TMP/cp.out)"
  elif [ "$vil_n" -gt 0 ]; then
    vil_pass "copilot loaded this repo's instructions (marker x$vil_n in its own event log)"
  else
    vil_fail "copilot's system prompt does not contain this repo's marker" "see $VIL_TMP/cp.out"
  fi

  vil_n="$(vil_copilot "$VIL_CTRL")"
  if [ "$vil_n" = NOSESSION ]; then
    vil_skip "copilot empty-control arm" "no new events.jsonl appeared"
  elif [ "$vil_n" -gt 0 ]; then
    vil_fail "the EMPTY CONTROL's system prompt contains this repo's marker" \
             "the probe cannot discriminate — do not trust the arm above"
  else
    vil_pass "empty control does not carry the marker (the probe can say no)"
  fi
fi

printf '\n%s passed · %s failed · %s skipped\n' "$VIL_PASS" "$VIL_FAIL" "$VIL_SKIP"
if [ "$VIL_FAIL" -gt 0 ]; then
  printf 'VERDICT: FAILED — the agent is not reading what this repo tells it.\n'
  exit 1
fi
if [ "$VIL_PASS" -eq 0 ]; then
  printf 'VERDICT: NOTHING RAN. This is not a verdict about the machine.\n'
  exit 2
fi
printf 'VERDICT: PASS on every arm that could run.\n'
exit 0
