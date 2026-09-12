#!/bin/bash
# oracle.sh — the successor-engagement oracle, and the retire gate built on it.
#
#   oracle.sh probe  --cfg D --sid S [--cwd D] --marker M --nonce N [--ack F]   -> a TIER
#                    …and GOAL=none|live|done — absent / armed / already ruled by the evaluator
#   oracle.sh decide --cfg D --sid S ... --alive-cmd CMD [--budget 120] [--bar SPEAKING]
#   oracle.sh selftest                                                          -> the negative arms
#
# ═══ WHAT THIS ANSWERS, AND WHY THE OBVIOUS ANSWERS ARE WRONG ════════════════════════════════
# The question is NOT "is a process running". Measured on this design's own subject, every
# cheaper oracle is a demonstrated FALSE POSITIVE — it returns ENGAGED for a successor that has
# consumed nothing, which converts a recoverable stall into the one unrecoverable outcome
# (a retired predecessor over a dead successor):
#
#   "a non-shell process runs in the pane"      -> a pane parked on the first-run THEME PICKER
#                                                  reports pane_current_command=claude.exe
#   "a transcript file exists"                  -> an UNAUTHENTICATED run writes one
#   "the transcript contains the brief"         -> the harness writes the user record BEFORE the
#                                                  agent runs; it cannot tell "the agent read it"
#                                                  from "the CLI echoed it"
#   "the transcript has an assistant record"    -> the unauthenticated run writes one too:
#                                                  model "<synthetic>", isApiErrorMessage true,
#                                                  text "Not logged in · Please run /login"
#
# So this oracle requires a token that can only appear on the OUTPUT side by the model having
# READ the prompt:
#
#   <marker>  identifies the prompt on the INPUT side  (a user record)
#   <nonce>   the prompt instructs the agent to ECHO it (an assistant record, or an ack file)
#
# One token is not enough: a transcript quotes its own input in queue-operation and attachment
# rows, so a single token would make SPEAKING satisfiable by the harness's own bookkeeping.
#
# ═══ THE LADDER ══════════════════════════════════════════════════════════════════════════════
#   rc 0  ACTED       the agent ran a TOOL because of this prompt (the ack file holds the nonce)
#   rc 3  SPEAKING    logged in and answering THIS prompt (nonce in a non-error assistant record)
#   rc 4  ARRIVED     the prompt reached the model's input (marker in a user record)
#   rc 5  AUTHFAIL    the session cannot authenticate / the API refused — TERMINAL, waiting cannot help
#   rc 1  NO          every read SUCCEEDED and found nothing — the honest definite-so-far negative
#   rc 2  CANNOT-TELL a read itself FAILED — never treated as a negative
#
# `probe` states WHAT IS TRUE. `decide` states WHAT TO DO. Conflating those is how a detector
# that cannot say NO gets shipped.
#
# ═══ PRECONDITION — NOT an optimisation ══════════════════════════════════════════════════════
# The marker and the nonce MUST be unique per fire. A completed run's transcript stays on disk,
# so replaying a marker with nothing running at all returns SPEAKING. A predecessor that reuses
# a marker reads a PREVIOUS successor's transcript as proof that THIS one engaged, and retires
# over nothing. Derive them from a uuid or from epoch+pid. `decide` refuses a marker it can
# already prove stale (see --staleness-guard).
#
# ═══ NO python3, NO jq ═══════════════════════════════════════════════════════════════════════
# /usr/bin/python3 on a Mac without the Command Line Tools is the CLT stub multiplexer: running
# it opens an INSTALL DIALOG. This file is bash + find + awk only. One awk pass per file, never
# a pipeline: `var="$(a|b)"` sets PIPESTATUS to the ASSIGNMENT's status, and a dead first stage
# hands the second an empty input which answers an honest rc 1 — so a pipeline reports "no
# match" for a file that was never read. awk has one process and one exit status.
#
# set -u, and deliberately NOT set -e / NOT pipefail.
set -u

OR_VERSION=1

or_say() { printf '%s\n' "$*"; }
or_err() { printf '%s\n' "$*" >&2; }

# ── the project slug — MEASURED, and the obvious guess is wrong ──────────────────────────────
# Claude Code replaces EVERY character outside [A-Za-z0-9] with '-', not just '/'. Evidence:
# 657 project directories on the source box, `grep -c '[^A-Za-z0-9-]'` -> 0; and a cwd
# .../wd/DEC-POS_1-178… lands as ...-wd-DEC-POS-1-178… — the UNDERSCORE became a dash.
# `sed 's#/#-#g'` cost a measured false negative on the first label that contained '_'.
# Worktree directory names routinely contain '_', '.' and spaces, so this is not exotic.
# Better still: pass --sid and find the transcript BY NAME, which needs no slug at all.
or_slug() { printf '%s' "${1:-}" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# ── or_files — the candidate transcripts, newline separated. rc 1 = enumeration FAILED. ──────
# Bounded to one project directory (or one file by name); never a walk of a 657-directory tree.
# 🚨 WHEN A SID IS GIVEN IT IS AUTHORITATIVE, AND THERE IS NO FALLBACK. This looked like a
# harmless belt-and-braces ("if the named file is not there yet, try the project directory") and
# it is a cross-session leak: every successor in one cwd shares one slug directory, so a sibling's
# OLD transcript answers for this one. Measured — a stub successor with no transcript at all
# returned `TIER=AUTHFAIL PROOF=assistant-api-error`, read out of a DIFFERENT session's file that
# happened to sit in the same cwd. AUTHFAIL is TERMINAL, so that verdict ends the proof window
# immediately: a healthy successor would be abandoned on a dead sibling's evidence. SPEAKING
# could not be forged that way (the nonce is unique per fire) — which is exactly why the leak was
# invisible until a tier that does NOT depend on the nonce was exercised.
or_files() {
  local cfg="${1:-}" sid="${2:-}" cwd="${3:-}" out="" d f
  [ -d "$cfg/projects" ] || return 1
  # 🚨 NO `find` HERE, AND THAT IS THE WHOLE POINT. BSD find does NOT descend a SYMLINKED START
  # DIRECTORY without -H, and it says so by printing nothing AT EXIT 0 — indistinguishable from
  # "there is no such transcript". MEASURED on the authoring box: an alternate config dir's projects/ was a symlink to
  # ~/.claude/projects, the transcript sat in it, `ls` showed it, and
  #   find "$cfg/projects" -maxdepth 2 -type f -name "$sid.jsonl"   ->  0 lines, rc 0
  #   find -H "$cfg/projects" …                                     ->  1 line
  # so the entire transcript arm of this oracle was blind on that config dir. Every succession
  # there could only ever be proven by the ACK FILE; with --no-ack, or an agent that answers
  # without running a tool, it would HOLD forever with PROOF=no-transcript and the operator would
  # be told the successor never engaged. A shell GLOB follows symlinks by construction and needs
  # no flag to be remembered, so the failure mode cannot come back in a different spelling.
  # The rc-1 channel ("enumeration FAILED", which the caller must read as CANNOT-TELL and never
  # as a negative) is preserved by TESTING the directory directly instead of inferring it from a
  # command exit status that was standing in for it.
  [ -r "$cfg/projects" ] && [ -x "$cfg/projects" ] || return 1
  if [ -n "$sid" ]; then
    for f in "$cfg"/projects/"$sid.jsonl" "$cfg"/projects/*/"$sid.jsonl"; do
      [ -f "$f" ] && out="$out$f
"
    done
    [ -n "$out" ] && printf '%s' "$out"
    return 0                      # named or nothing — never a sibling's file
  fi
  [ -n "$cwd" ] || return 0
  d="$cfg/projects/$(or_slug "$cwd")"
  [ -d "$d" ] || return 0
  [ -r "$d" ] && [ -x "$d" ] || return 1
  for f in "$d"/*.jsonl; do
    [ -f "$f" ] && out="$out$f
"
  done
  [ -n "$out" ] && printf '%s' "$out"
  return 0
}

or_mtime() { local m; m="$(stat -f %m "${1:-}" 2>/dev/null)" || m=0
             case "${m:-}" in ''|*[!0-9]*) m=0 ;; esac; printf '%s' "$m"; }

# ── or_scan_file — ONE awk pass. Exit contract: 100 + flags, so awk's own rc 2 (unopenable ────
# operand) cannot collide with a flag value and a read error is never read as a miss.
#   1 marker in a user record          2 nonce in a NON-ERROR assistant record
#   4 an api-error assistant record    8 a live goal_status (met:false) is the LAST goal record
or_scan_file() {
  local f="${1:-}" m="${2:-}" n="${3:-}"
  LC_ALL=C awk -v M="$m" -v N="$n" '
    /"type"[ ]*:[ ]*"user"/      { if (M != "" && index($0, M)) u = 1 }
    /"type"[ ]*:[ ]*"assistant"/ {
        # 🚨 TWO DIFFERENT ROLES, AND CONFLATING THEM COST THE WHOLE HAPPY PATH.
        # `model:"<synthetic>"` means "the HARNESS manufactured this record", not "this is an
        # error". It disqualifies a record from being PROOF — a manufactured record is not the
        # model speaking — and it says nothing about health. MEASURED on 2.1.269, a healthy,
        # authenticated, ENGAGED successor: line 7 of its own transcript is
        #   {"type":"assistant","message":{"model":"<synthetic>","content":[{"text":
        #    "No response requested."}]},"isApiErrorMessage":false}
        # written 1.2 s after launch, 2.7 s BEFORE the first real answer. Reading that as
        # an error returned TIER=AUTHFAIL, which `decide` treats as TERMINAL, so the proof window
        # closed 2.7 s before the proof arrived — and it closed that way on EVERY authenticated
        # run, because the 2 s spawn wait in the driver lands the first probe inside that window.
        # The structural error test is isApiErrorMessage, and it alone: on the real unauthenticated
        # transcript the "Not logged in · Please run /login" record carries it true.
        iserr  = ($0 ~ /"isApiErrorMessage"[ ]*:[ ]*true/)
        synth  = (index($0, "\"<synthetic>\"") > 0)
        if (iserr) e = 1
        if (N != "" && index($0, N) && !iserr && !synth) a = 1
    }
    /"type"[ ]*:[ ]*"goal_status"/ {
        gs = 1          # A GOAL RECORD EXISTS AT ALL. Without this bit, "never armed" and
                        # "armed, and the evaluator has already ruled" are the same answer, and
                        # the engine then tells the operator to re-arm by hand a goal that was
                        # armed with no keystrokes and then MET. Measured on a real run: the seed
                        # line at 23:18:57 met=false, the products own goal_status at 23:19:12
                        # met=true, screen reading "Goal achieved (13s / 1 turn)".
        if ($0 ~ /"met"[ ]*:[ ]*true/ || $0 ~ /"failed"[ ]*:[ ]*true/) g = 0; else g = 1
    }
    END { exit 100 + u + 2*a + 4*e + 8*g + 16*gs }
  ' "$f" </dev/null 2>/dev/null
}

# ── or_authcause — name the CAUSE of an error record. Version-fragile WORDING by construction, ─
# so it only ever refines a verdict the structural test (isApiErrorMessage) already reached.
or_authcause() {
  local f="${1:-}"
  LC_ALL=C awk '
    /"isApiErrorMessage"[ ]*:[ ]*true/ {
      if (index($0,"Not logged in") || index($0,"Please run /login") || index($0,"/login")) { print "not-logged-in"; exit }
      if (index($0,"Invalid API key") || index($0,"authentication_failed") || index($0,"OAuth")) { print "auth-failed"; exit }
      if (index($0,"usage limit") || index($0,"rate limit") || index($0,"Rate limit") || index($0,"quota")) { print "limit"; exit }
      print "api-error"; exit
    }
  ' "$f" </dev/null 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# probe — prints TIER=<t> PROOF=<what> [CAUSE=<c>] [GOAL=<live|clear|none>] and exits per ladder
# ═════════════════════════════════════════════════════════════════════════════════════════════
or_probe() {
  local cfg="" sid="" cwd="" marker="" nonce="" ack=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cfg)    cfg="${2:-}"; shift 2 ;;
      --sid)    sid="${2:-}"; shift 2 ;;
      --cwd)    cwd="${2:-}"; shift 2 ;;
      --marker) marker="${2:-}"; shift 2 ;;
      --nonce)  nonce="${2:-}"; shift 2 ;;
      --ack)    ack="${2:-}"; shift 2 ;;
      *) or_err "probe: unknown option $1"; return 2 ;;
    esac
  done
  [ -n "$cfg" ] && [ -n "$nonce" ] || { or_err "probe: need --cfg and --nonce"; return 2; }

  # ── tier 0, ACTED. Agent-agnostic: the ack file is written by the agent's OWN tool call, so
  #    it works for any agent whose transcript we cannot read (Copilot gates on login BEFORE
  #    submitting, so its store is empty pre-auth and the transcript route does not exist).
  if [ -n "$ack" ] && [ -f "$ack" ]; then
    if LC_ALL=C grep -qF -- "$nonce" "$ack" 2>/dev/null; then
      or_say "TIER=ACTED PROOF=ack-file FILE=$ack"; return 0
    fi
    # grep rc 2 is a READ ERROR, never a miss.
    LC_ALL=C grep -qF -- "$nonce" "$ack" >/dev/null 2>&1
    [ $? -ge 2 ] && { or_say "TIER=CANNOT-TELL PROOF=ack-unreadable:$ack"; return 2; }
  fi

  local files rc readerr=0 u=0 a=0 e=0 g=0 gs=0 f flags cause="" goal="none" seen=0 proof=""
  files="$(or_files "$cfg" "$sid" "$cwd")" || readerr=1
  if [ "$readerr" = 1 ]; then
    or_say "TIER=CANNOT-TELL PROOF=cannot-enumerate FILE=$cfg/projects"; return 2
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    seen=$((seen + 1))
    or_scan_file "$f" "$marker" "$nonce"; rc=$?
    if [ "$rc" -lt 100 ] || [ "$rc" -gt 131 ]; then readerr=1; continue; fi
    flags=$((rc - 100))
    [ $((flags % 2)) -eq 1 ] && u=1
    [ $(((flags / 2) % 2)) -eq 1 ] && a=1
    [ $(((flags / 4) % 2)) -eq 1 ] && e=1
    [ $(((flags / 8) % 2)) -eq 1 ] && g=1
    [ $(((flags / 16) % 2)) -eq 1 ] && gs=1
    [ "$e" = 1 ] && [ -z "$cause" ] && cause="$(or_authcause "$f")"
    [ -z "$proof" ] && proof="$f"
  done <<EOF
$files
EOF

  # THREE states, not two: absent / live / already-ruled. `done` means the goal WAS armed and
  # the Stop evaluator has met-or-cleared it — a success, not something to re-arm by hand.
  if   [ "$g"  = 1 ]; then goal="live"
  elif [ "$gs" = 1 ]; then goal="done"
  fi
  local tail=" GOAL=$goal"
  [ -n "$cause" ] && tail=" CAUSE=$cause$tail"
  [ -n "$proof" ] && tail="$tail FILE=$proof"

  if [ "$a" = 1 ]; then or_say "TIER=SPEAKING PROOF=assistant-nonce$tail"; return 3; fi
  if [ "$e" = 1 ]; then or_say "TIER=AUTHFAIL PROOF=assistant-api-error$tail"; return 5; fi
  if [ "$u" = 1 ]; then or_say "TIER=ARRIVED PROOF=user-marker$tail"; return 4; fi
  if [ "$readerr" = 1 ]; then or_say "TIER=CANNOT-TELL PROOF=file-unreadable"; return 2; fi
  if [ "$seen" = 0 ]; then or_say "TIER=NO PROOF=no-transcript$tail"; return 1; fi
  or_say "TIER=NO PROOF=transcript-without-marker$tail"; return 1
}

or_rank() {          # a total order over the ladder, so a bar can be compared numerically
  case "${1:-}" in
    ACTED) printf 4 ;; SPEAKING) printf 3 ;; ARRIVED) printf 2 ;;
    AUTHFAIL) printf 1 ;; *) printf 0 ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# decide — "may the predecessor die?"  exit 0 RETIRE · exit 1 HOLD.  There is no third outcome
# and no "assume it worked". Every failure path lands on HOLD, because the two errors are not
# the same size: retiring too early destroys a context that cannot be rebuilt, and retiring too
# late costs ONE IDLE PANE. An asymmetric loss function with an unbounded arm and a one-pane arm
# has exactly one defensible bias — and its corollary is the part people get wrong: UNKNOWN must
# resolve to the safe side, never to the cheap side.
# ═════════════════════════════════════════════════════════════════════════════════════════════
or_decide() {
  local cfg="" sid="" cwd="" marker="" nonce="" ack="" alive="" budget=120 bar="SPEAKING"
  local poll="${AH_POLL:-1}" stale=1 since=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="${2:-0}"; shift 2 ;;
      --cfg) cfg="${2:-}"; shift 2 ;;
      --sid) sid="${2:-}"; shift 2 ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      --marker) marker="${2:-}"; shift 2 ;;
      --nonce) nonce="${2:-}"; shift 2 ;;
      --ack) ack="${2:-}"; shift 2 ;;
      --alive-cmd) alive="${2:-}"; shift 2 ;;
      --budget) budget="${2:-}"; shift 2 ;;
      --bar) bar="${2:-}"; shift 2 ;;
      --poll) poll="${2:-}"; shift 2 ;;
      --no-staleness-guard) stale=0; shift ;;
      *) or_err "decide: unknown option $1"; return 2 ;;
    esac
  done
  case "${budget:-}" in ''|*[!0-9]*) budget=120 ;; esac
  case "${poll:-}" in ''|*[!0-9]*) poll=1 ;; esac
  local barn; barn="$(or_rank "$bar")"
  [ "$barn" -ge 2 ] || { or_err "decide: --bar must be ARRIVED, SPEAKING or ACTED"; return 2; }

  # THE STALENESS GUARD. Demonstrated hazard: replaying a completed run's marker with nothing
  # running returns SPEAKING, because the transcript is still on disk. If the bar is already met
  # BEFORE the successor can possibly have started, the tokens are not unique to this fire and
  # the whole proof is void. Refuse rather than retire on somebody else's evidence.
  if [ "$stale" = 1 ]; then
    local pre prerc pf pm
    pre="$(or_probe --cfg "$cfg" --sid "$sid" --cwd "$cwd" --marker "$marker" --nonce "$nonce" --ack "$ack")"
    prerc=$?
    if [ "$prerc" = 0 ] || [ "$prerc" = 3 ]; then
      # --since is the LAUNCH time, and it is what makes this guard usable on a RESUME. Without
      # it the rule is "the bar must not already be met when we start watching", which is right
      # on a first fire and WRONG the moment a killed driver re-enters: by then the successor has
      # legitimately engaged, and the guard would refuse to retire over its own success (measured
      # — a resumed driver reported stale-tokens over an ack its own successor had just written).
      # The honest discriminator is not "did we watch it happen" but "is the proof NEWER THAN THE
      # LAUNCH", which is true in both cases and false for a replayed marker.
      pf="$(printf '%s' "$pre" | LC_ALL=C sed -n 's/.*FILE=\(.*\)$/\1/p')"
      pm=0; [ -n "$pf" ] && pm="$(or_mtime "$pf")"
      case "${since:-0}" in ''|*[!0-9]*) since=0 ;; esac
      if [ "$since" -gt 0 ] && [ "$pm" -ge "$since" ]; then
        or_say "VERDICT=RETIRE TIER=$(printf '%s' "$pre" | LC_ALL=C sed -n 's/^TIER=\([A-Z-]*\).*/\1/p') ELAPSED=0s DETAIL=$pre"
        or_say "  (proof is newer than the launch, so it is this successor's)"
        return 0
      fi
      or_say "VERDICT=HOLD REASON=stale-tokens DETAIL=$pre"
      or_say "  the bar was already met before this successor could have produced it: the proof is"
      or_say "  older than the launch, so these tokens are NOT unique to this fire and nothing here"
      or_say "  proves the new successor engaged."
      return 1
    fi
  fi

  local t=0 best="NO" bestn=0 out rc dead=0
  while [ "$t" -le "$budget" ]; do
    out="$(or_probe --cfg "$cfg" --sid "$sid" --cwd "$cwd" --marker "$marker" --nonce "$nonce" --ack "$ack")"
    rc=$?
    case "$rc" in
      0) best="ACTED";    bestn=4 ;;
      3) best="SPEAKING"; bestn=3 ;;
      4) [ "$bestn" -lt 2 ] && { best="ARRIVED"; bestn=2; } ;;
      5) case "$out" in
           *CAUSE=not-logged-in*|*CAUSE=auth-failed*)
             or_say "VERDICT=HOLD REASON=authfail DETAIL=$out"
             or_say "  terminal: waiting cannot help. The predecessor stays up."
             return 1 ;;
           *)
             # A transient API error — an overload, a blip, a limit that may lift inside the
             # budget — is NOT a terminal state, and treating it as one ABANDONS a successor that
             # recovers. Keep watching: the verdict if nothing improves is still HOLD at timeout,
             # so this can only ever turn a premature abandonment into a proof, never a HOLD into
             # a retire. Only a CAUSE that no amount of waiting can change ends the window.
             [ "$bestn" -lt 1 ] && { best="AUTHFAIL"; bestn=1; } ;;
         esac ;;
      2) : ;;                       # CANNOT-TELL: a read that failed is not a negative
      *) : ;;
    esac
    if [ "$bestn" -ge "$barn" ]; then
      or_say "VERDICT=RETIRE TIER=$best ELAPSED=${t}s DETAIL=$out"
      return 0
    fi
    # LIVENESS. Two CONSECUTIVE dead observations, never one: the successor's process is
    # REPLACED during boot (shell -> node) and a single sample can land in the gap. A one-sample
    # death check is the mirror of a one-sample argv census.
    if [ -n "$alive" ]; then
      if eval "$alive" >/dev/null 2>&1; then dead=0; else dead=$((dead + 1)); fi
      if [ "$dead" -ge 2 ]; then
        or_say "VERDICT=HOLD REASON=successor-gone ELAPSED=${t}s DETAIL=$out"
        or_say "  the successor process is gone and the bar was never reached."
        return 1
      fi
    fi
    sleep "$poll"
    t=$((t + poll))
  done
  or_say "VERDICT=HOLD REASON=timeout-unproven ELAPSED=${t}s BEST=$best DETAIL=$out"
  or_say "  a slow first turn and a wedged one are identical here; the ambiguous case protects"
  or_say "  the thing that holds the context. The predecessor stays up."
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# selftest — every positive arm paired with the negative that gives it meaning. The fixtures are
# the REAL shapes, transcribed from measured transcripts, not shapes invented to pass.
# ═════════════════════════════════════════════════════════════════════════════════════════════
or__t=0; or__f=0
or_ok()  { or__t=$((or__t+1)); printf '  ok   %s\n' "$1"; }
or_bad() { or__t=$((or__t+1)); or__f=$((or__f+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
or_is()  { if [ "$2" = "$3" ]; then or_ok "$1"; else or_bad "$1" "want [$3] got [$2]"; fi; }

or_fixture() {        # or_fixture <dir> <slug-cwd> <sid> <kind>
  local root="$1" cwd="$2" sid="$3" kind="$4" d
  d="$root/projects/$(or_slug "$cwd")"
  mkdir -p "$d" || return 1
  : > "$d/$sid.jsonl"
  case "$kind" in
    empty) : ;;
    arrived)   # the marker echoed by the harness, in the rows a transcript ALWAYS writes
      printf '%s\n' '{"type":"queue-operation","op":"enqueue","content":"Task ORMARK. echo ORNONCE"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"parentUuid":null,"type":"user","message":{"role":"user","content":"Task ORMARK. reply with ORNONCE"},"promptSource":"typed"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"attachment","attachment":{"type":"note","text":"Task ORMARK reply with ORNONCE"}}' >> "$d/$sid.jsonl"
      ;;
    authfail)  # the UNAUTHENTICATED run: a real user record AND a content-bearing assistant turn
      printf '%s\n' '{"parentUuid":null,"type":"user","message":{"role":"user","content":"Task ORMARK. reply with ORNONCE"},"promptSource":"typed"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"isApiErrorMessage":true}' >> "$d/$sid.jsonl"
      ;;
    speaking)
      printf '%s\n' '{"parentUuid":null,"type":"user","message":{"role":"user","content":"Task ORMARK. reply with ORNONCE"},"promptSource":"typed"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"ORNONCE"}]}}' >> "$d/$sid.jsonl"
      ;;
    nonce-in-error)   # the adversarial arm: an ERROR record that happens to quote the nonce
      printf '%s\n' '{"parentUuid":null,"type":"user","message":{"role":"user","content":"Task ORMARK. reply with ORNONCE"},"promptSource":"typed"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"failed on: ORNONCE"}]},"isApiErrorMessage":true}' >> "$d/$sid.jsonl"
      ;;
    benign-synthetic)  # a HEALTHY authenticated session: the harness's own bookkeeping record
                       # lands BEFORE the model answers. Transcribed from a real 2.1.269 run.
      printf '%s\n' '{"parentUuid":null,"type":"user","message":{"role":"user","content":"Task ORMARK. reply with ORNONCE"},"promptSource":"typed"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"No response requested."}]},"isApiErrorMessage":false}' >> "$d/$sid.jsonl"
      ;;
    benign-synthetic-then-speaking)   # …and the same session 2.7 s later
      printf '%s\n' '{"parentUuid":null,"type":"user","message":{"role":"user","content":"Task ORMARK. reply with ORNONCE"},"promptSource":"typed"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"No response requested."}]},"isApiErrorMessage":false}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"ORNONCE"}]}}' >> "$d/$sid.jsonl"
      ;;
    synthetic-quotes-the-nonce)       # the NEGATIVE twin: a manufactured record is never proof
      printf '%s\n' '{"parentUuid":null,"type":"user","message":{"role":"user","content":"Task ORMARK. reply with ORNONCE"},"promptSource":"typed"}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"queued: ORNONCE"}]},"isApiErrorMessage":false}' >> "$d/$sid.jsonl"
      ;;
    goal-live)
      printf '%s\n' '{"type":"attachment","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"ORGOAL"}}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"ORNONCE"}]}}' >> "$d/$sid.jsonl"
      ;;
    goal-cleared)
      printf '%s\n' '{"type":"attachment","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"ORGOAL"}}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"attachment","attachment":{"type":"goal_status","met":true,"sentinel":true,"condition":"ORGOAL"}}' >> "$d/$sid.jsonl"
      printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"ORNONCE"}]}}' >> "$d/$sid.jsonl"
      ;;
  esac
  return 0
}

or_tier()   { printf '%s' "${1#TIER=}" | awk '{print $1}'; }

cmd_selftest() {
  local tmp arm out rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/or-selftest.XXXXXX")" || { or_err "cannot mktemp"; return 1; }
  printf 'oracle.sh selftest (v%s)\n' "$OR_VERSION"

  # ── the SLUG rule. The refuted form is run as the negative arm, so the fix is attributable.
  #    The fixture path is deliberately NOT /Users/<name>/… : this repo is public and its
  #    publish gate fails any file carrying an absolute home path. The rule under test is
  #    path-agnostic, so the shape is preserved and only the prefix changes. Do not
  #    "restore realism" here — it re-trips the gate and blocks the release.
  or_is "slug: every non-alnum becomes a dash" \
        "$(or_slug '/w/x/.worktrees/a_b c')" "-w-x--worktrees-a-b-c"
  or_is "slug: the REFUTED s#/#-#g form differs (this is why it cost a false negative)" \
        "$(printf '%s' '/w/x/.worktrees/a_b c' | sed 's#/#-#g')" "-w-x-.worktrees-a_b c"

  # ── POSITIVE ARM
  or_fixture "$tmp/c1" /w/p sid1 speaking
  out="$(or_probe --cfg "$tmp/c1" --sid sid1 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "POS  speaking transcript -> SPEAKING"  "$(or_tier "$out")" "SPEAKING"
  or_is "POS  speaking transcript -> rc 3"      "$rc" "3"

  # ── NEGATIVE ARM (a): nothing on disk at all — the immediate-death / silent-no-op shape
  mkdir -p "$tmp/c2/projects"
  out="$(or_probe --cfg "$tmp/c2" --sid sidX --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  no transcript -> NO"              "$(or_tier "$out")" "NO"
  or_is "NEG  no transcript -> rc 1"            "$rc" "1"

  # ── NEGATIVE ARM (b/c): started, received nothing / parked on a modal. A modal-parked agent
  #    writes ZERO transcripts, which is the same on-disk shape as (a) — and is exactly the case
  #    the refuted process-level detector called ENGAGED.
  or_fixture "$tmp/c3" /w/p sid3 empty
  out="$(or_probe --cfg "$tmp/c3" --sid sid3 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  empty transcript (modal) -> NO"   "$(or_tier "$out")" "NO"

  # ── NEGATIVE ARM: the prompt ARRIVED but nothing answered it. This is the arm that proves the
  #    oracle is not merely "a transcript exists" or "the transcript contains the brief".
  or_fixture "$tmp/c4" /w/p sid4 arrived
  out="$(or_probe --cfg "$tmp/c4" --sid sid4 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  marker in user/queue/attachment only -> ARRIVED, not SPEAKING" "$(or_tier "$out")" "ARRIVED"
  or_is "NEG  ... -> rc 4"                     "$rc" "4"

  # ── NEGATIVE ARM: a content-bearing assistant turn that is a LOGIN ERROR. Every "an assistant
  #    record exists" oracle returns ENGAGED here.
  or_fixture "$tmp/c5" /w/p sid5 authfail
  out="$(or_probe --cfg "$tmp/c5" --sid sid5 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  unauthenticated assistant turn -> AUTHFAIL" "$(or_tier "$out")" "AUTHFAIL"
  or_is "NEG  ... -> rc 5"                     "$rc" "5"
  case "$out" in *CAUSE=not-logged-in*) or_ok "NEG  ... names the cause" ;;
                 *) or_bad "NEG  ... names the cause" "got [$out]" ;; esac

  # ── ADVERSARIAL: an error record that QUOTES the nonce must not reach SPEAKING.
  or_fixture "$tmp/c6" /w/p sid6 nonce-in-error
  out="$(or_probe --cfg "$tmp/c6" --sid sid6 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  nonce inside an API-ERROR record -> AUTHFAIL, not SPEAKING" "$(or_tier "$out")" "AUTHFAIL"

  # ── THE HARNESS'S OWN BOOKKEEPING RECORD IS NOT AN ERROR, AND IS NOT PROOF EITHER.
  # Transcribed from a real 2.1.269 authenticated run whose oracle abandoned it: a benign
  # model:"<synthetic>" record, isApiErrorMessage:false, landing 2.7 s before the real answer.
  or_fixture "$tmp/c6b" /w/p sid6b benign-synthetic
  out="$(or_probe --cfg "$tmp/c6b" --sid sid6b --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  a BENIGN <synthetic> record is NOT an AUTHFAIL" "$(or_tier "$out")" "ARRIVED"
  or_is "...  and it does not end the proof window (rc 4, not 5)" "$rc" "4"
  or_fixture "$tmp/c6c" /w/p sid6c benign-synthetic-then-speaking
  out="$(or_probe --cfg "$tmp/c6c" --sid sid6c --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "POS  ...and the answer that follows it still reads SPEAKING" "$(or_tier "$out")" "SPEAKING"
  or_fixture "$tmp/c6d" /w/p sid6d synthetic-quotes-the-nonce
  out="$(or_probe --cfg "$tmp/c6d" --sid sid6d --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  a <synthetic> record QUOTING the nonce is never proof" "$(or_tier "$out")" "ARRIVED"

  # ── A SYMLINKED STORE IS STILL A STORE. BSD find does not descend a symlinked start dir
  # without -H and reports that as "nothing found" at rc 0; a real config dir on the source box
  # (an alternate config dir's projects/ -> the primary one's) was invisible to the whole transcript arm.
  or_fixture "$tmp/c10real" /w/p sid10 speaking
  mkdir -p "$tmp/c10link"
  ln -s "$tmp/c10real/projects" "$tmp/c10link/projects" 2>/dev/null
  out="$(or_probe --cfg "$tmp/c10link" --sid sid10 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "POS  a SYMLINKED projects/ is still read (find -maxdepth is not)" "$(or_tier "$out")" "SPEAKING"
  or_is "...  and it is the same verdict as the real dir" "$rc" "3"
  # the negative twin: a symlink to a directory that holds nothing must still be able to say NO
  mkdir -p "$tmp/c10empty/projects"; mkdir -p "$tmp/c10linkempty"
  ln -s "$tmp/c10empty/projects" "$tmp/c10linkempty/projects" 2>/dev/null
  out="$(or_probe --cfg "$tmp/c10linkempty" --sid sid10 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  …and an EMPTY symlinked store still answers NO" "$(or_tier "$out")" "NO"

  # ── READ ERROR is never a miss.
  or_fixture "$tmp/c7" /w/p sid7 speaking
  chmod 000 "$tmp/c7/projects/$(or_slug /w/p)/sid7.jsonl" 2>/dev/null
  if [ -r "$tmp/c7/projects/$(or_slug /w/p)/sid7.jsonl" ]; then
    or_ok "SKIP read-error arm (running as a user chmod cannot stop)"
  else
    out="$(or_probe --cfg "$tmp/c7" --sid sid7 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
    or_is "NEG  unreadable transcript -> CANNOT-TELL, not NO" "$(or_tier "$out")" "CANNOT-TELL"
    or_is "NEG  ... -> rc 2"                    "$rc" "2"
  fi
  chmod 644 "$tmp/c7/projects/$(or_slug /w/p)/sid7.jsonl" 2>/dev/null
  out="$(or_probe --cfg "$tmp/c7/nope" --sid sid7 --cwd /w/p --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  missing projects dir -> CANNOT-TELL" "$(or_tier "$out")" "CANNOT-TELL"

  # ── ACK tier: agent-agnostic, and the arm Copilot needs because its store is unreadable.
  printf 'ORNONCE\n' > "$tmp/ack.txt"
  out="$(or_probe --cfg "$tmp/c2" --sid sidX --cwd /w/p --marker ORMARK --nonce ORNONCE --ack "$tmp/ack.txt")"; rc=$?
  or_is "POS  ack file holding the nonce -> ACTED" "$(or_tier "$out")" "ACTED"
  or_is "POS  ... -> rc 0"                      "$rc" "0"
  printf 'something else\n' > "$tmp/ack2.txt"
  out="$(or_probe --cfg "$tmp/c2" --sid sidX --cwd /w/p --marker ORMARK --nonce ORNONCE --ack "$tmp/ack2.txt")"; rc=$?
  or_is "NEG  ack file WITHOUT the nonce -> NO"  "$(or_tier "$out")" "NO"

  # ── GOAL read-back, both arms. met:true is NOT "achieved" — a launch-time error writes a
  #    second goal_status with met:true, so an armed goal can be disarmed moments later.
  or_fixture "$tmp/c8" /w/p sid8 goal-live
  out="$(or_probe --cfg "$tmp/c8" --sid sid8 --cwd /w/p --marker ORMARK --nonce ORNONCE)"
  case "$out" in *GOAL=live*) or_ok "POS  live goal_status -> GOAL=live" ;;
                 *) or_bad "POS  live goal_status -> GOAL=live" "got [$out]" ;; esac
  or_fixture "$tmp/c9" /w/p sid9 goal-cleared
  out="$(or_probe --cfg "$tmp/c9" --sid sid9 --cwd /w/p --marker ORMARK --nonce ORNONCE)"
  case "$out" in *GOAL=done*) or_ok "NEG  cleared goal (met:true LAST) -> GOAL=done, never live" ;;
                 *) or_bad "NEG  cleared goal -> GOAL=done" "got [$out]" ;; esac
  # …and the third state is genuinely distinct: a transcript with NO goal record at all.
  or_fixture "$tmp/c9b" /w/p sid9b speaking
  out="$(or_probe --cfg "$tmp/c9b" --sid sid9b --cwd /w/p --marker ORMARK --nonce ORNONCE)"
  case "$out" in *GOAL=none*) or_ok "NEG  no goal record at all -> GOAL=none (not done)" ;;
                 *) or_bad "NEG  no goal record -> GOAL=none" "got [$out]" ;; esac

  # ── the SID path must not fall back to a WRONG-cwd directory: fail closed.
  out="$(or_probe --cfg "$tmp/c1" --sid nosuchsid --cwd /nowhere --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG  sid nothing holds + wrong cwd -> NO (fails closed)" "$(or_tier "$out")" "NO"
  # ...but a RIGHT sid with a deliberately WRONG cwd still resolves, because find is by NAME.
  out="$(or_probe --cfg "$tmp/c1" --sid sid1 --cwd /deliberately/wrong --marker ORMARK --nonce ORNONCE)"
  or_is "POS  right sid + wrong cwd -> SPEAKING (no slug in the trust path)" "$(or_tier "$out")" "SPEAKING"

  # ── the RETIRE GATE. Every failure path must land on HOLD.
  out="$(or_decide --cfg "$tmp/c5" --sid sid5 --cwd /w/p --marker ORMARK --nonce ORNONCE --budget 2 --poll 1)"; rc=$?
  or_is "GATE authfail -> HOLD"                 "$rc" "1"
  case "$out" in *REASON=authfail*) or_ok "GATE authfail names its reason" ;;
                 *) or_bad "GATE authfail names its reason" "got [$out]" ;; esac
  out="$(or_decide --cfg "$tmp/c4" --sid sid4 --cwd /w/p --marker ORMARK --nonce ORNONCE --budget 2 --poll 1)"; rc=$?
  or_is "GATE budget expires at ARRIVED -> HOLD" "$rc" "1"
  case "$out" in *REASON=timeout-unproven*) or_ok "GATE timeout names its reason" ;;
                 *) or_bad "GATE timeout names its reason" "got [$out]" ;; esac
  out="$(or_decide --cfg "$tmp/c3" --sid sid3 --cwd /w/p --marker ORMARK --nonce ORNONCE --budget 2 --poll 1 \
                   --alive-cmd 'false')"; rc=$?
  or_is "GATE successor gone -> HOLD"           "$rc" "1"
  case "$out" in *REASON=successor-gone*) or_ok "GATE dead successor names its reason" ;;
                 *) or_bad "GATE dead successor names its reason" "got [$out]" ;; esac
  # ONE dead sample must NOT convict: the process is replaced during boot (shell -> node).
  arm="$tmp/flap"; printf '0' > "$arm"
  out="$(or_decide --cfg "$tmp/c1" --sid sid1 --cwd /w/p --marker ORMARK --nonce ORNONCE --budget 4 --poll 1 \
                   --no-staleness-guard --alive-cmd "true")"; rc=$?
  or_is "GATE bar met -> RETIRE"                "$rc" "0"

  # ── THE STALENESS GUARD: the bar met BEFORE the successor could start is NOT proof.
  out="$(or_decide --cfg "$tmp/c1" --sid sid1 --cwd /w/p --marker ORMARK --nonce ORNONCE --budget 2 --poll 1)"; rc=$?
  or_is "GATE pre-met tokens -> HOLD (stale)"   "$rc" "1"
  case "$out" in *REASON=stale-tokens*) or_ok "GATE stale tokens named" ;;
                 *) or_bad "GATE stale tokens named" "got [$out]" ;; esac
  # …and the SAME evidence is legitimate on a RESUME, where the successor engaged before the new
  # driver started watching. The discriminator is the launch time, not who was watching.
  out="$(or_decide --cfg "$tmp/c1" --sid sid1 --cwd /w/p --marker ORMARK --nonce ORNONCE --budget 2 --poll 1 \
                   --since 1)"; rc=$?
  or_is "GATE the same evidence with --since BEFORE it -> RETIRE (a resume is not a replay)" "$rc" "0"
  out="$(or_decide --cfg "$tmp/c1" --sid sid1 --cwd /w/p --marker ORMARK --nonce ORNONCE --budget 2 --poll 1 \
                   --since "$(( $(date +%s) + 600 ))")"; rc=$?
  or_is "GATE the same evidence with --since AFTER it -> HOLD (a replayed marker)" "$rc" "1"

  # ── THE CROSS-SESSION LEAK: a sid that does not exist must NOT be answered by a SIBLING's
  #    transcript sitting in the same cwd slug directory. AUTHFAIL is terminal, so a leaked one
  #    abandons a healthy successor on a dead sibling's evidence.
  or_fixture "$tmp/c10" /w/q sidA authfail
  out="$(or_probe --cfg "$tmp/c10" --sid sidNOTHERE --cwd /w/q --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "NEG a named sid that is absent is NOT answered by a sibling in the same cwd" \
        "$(or_tier "$out")" "NO"
  out="$(or_probe --cfg "$tmp/c10" --cwd /w/q --marker ORMARK --nonce ORNONCE)"; rc=$?
  or_is "POS ...but with NO sid, the cwd scan is still the intended fallback" \
        "$(or_tier "$out")" "AUTHFAIL"

  rm -rf "$tmp" 2>/dev/null
  printf '\n%s tests, %s failed\n' "$or__t" "$or__f"
  [ "$or__f" = 0 ]
}

case "${1:-}" in
  probe)    shift; or_probe "$@" ;;
  decide)   shift; or_decide "$@" ;;
  slug)     shift; or_slug "${1:-}"; printf '\n' ;;
  selftest) cmd_selftest ;;
  --version) or_say "oracle.sh $OR_VERSION" ;;
  *) or_err "usage: oracle.sh probe|decide|slug|selftest"; exit 2 ;;
esac
