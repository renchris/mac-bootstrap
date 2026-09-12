# shellcheck shell=bash
# m1_statusline — DELIVERABLE 1: context-% in the status line, on BOTH agents.
#
# Installs assets/agent-statusline.sh to $BOOTSTRAP_STATE_DIR/bin/ and registers it, by ABSOLUTE path,
# in $HOME/.claude/settings.json and $HOME/.copilot/settings.json — both through the ONE writer,
# bootstrap_settings_merge (C2). Nothing here calls plutil or jq to write a settings file.
#
# WHY THE ABSOLUTE PATH: Copilot documents that it expands `~` in statusLine.command; Claude
# Code's help only *recommends* a `~/…` path and its expansion was never measured. An absolute
# path costs nothing and removes the question.
#
# WHY verify_ EXECUTES THE SCRIPT. The status line provably never runs under `-p`, and Copilot
# renders it only in the interactive TUI — so an installed-but-crashing script is invisible to a
# registration check alone. Arm (a) parses the registration back out of each settings file with
# plutil (a different engine from the jq that usually wrote it); arm (b) RUNS the installed file
# against three fixtures, one of which is a negative control that must produce NO percentage.
#
# No permission, no credential, no allow-list keypath is written here or anywhere below.

M1_SL() { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/bin/agent-statusline.sh"; }
M1_CC() { printf '%s' "$HOME/.claude/settings.json"; }
M1_CP() { printf '%s' "$HOME/.copilot/settings.json"; }

# The three fixtures verify_ runs the INSTALLED script against. Their shapes are measured, not
# invented: the decoy is a real rate_limits block (a QUOTA number, never a context number), and
# the Copilot one is the authenticated 1.0.83 shape in which used_percentage is null and the
# live value sits at current_context_used_percentage.
M1_FIX_CC='{"session_id":"pb-m1-probe","cwd":"/tmp/pb-m1","model":{"display_name":"probe"},"context_window":{"used_percentage":42.7,"remaining_percentage":57.3},"rate_limits":{"five_hour":{"used_percentage":91}}}'
M1_FIX_CP='{"session_id":"pb-m1-probe2","cwd":"/tmp/pb-m1","model":{"id":null,"display_name":null},"context_window":{"used_percentage":null,"remaining_percentage":null,"current_context_used_percentage":7}}'
M1_FIX_NEG='{"session_id":"pb-m1-probe3","cwd":"/tmp/pb-m1","model":{"display_name":"probe"},"context_window":{"used_percentage":null,"remaining_percentage":null},"rate_limits":{"five_hour":{"used_percentage":91}}}'
# and the fixture that proves the alternation does not swallow a legitimate reading of ZERO:
# jq's `//` fires on null and false ONLY, so 0 must survive it and render as 0%.
M1_FIX_ZERO='{"session_id":"pb-m1-probe4","cwd":"/tmp/pb-m1","model":{"display_name":"probe"},"context_window":{"used_percentage":0,"remaining_percentage":100}}'

# m1_source — where the asset bytes come from: the clone, then the state-dir cache, then the
# pinned raw URL. NOT in pb-lib (the library deliberately does no network), so it lives here.
m1_source() {
  local c t
  for c in "${BOOTSTRAP_ASSETS:-}/agent-statusline.sh" \
           "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/assets/agent-statusline.sh"; do
    case "$c" in /agent-statusline.sh) continue ;; esac
    [ -r "$c" ] && { printf '%s' "$c"; return 0; }
  done
  case "${BOOTSTRAP_PIN:-}" in __PIN_SHA__|main|master|'') return 1 ;; esac
  command -v curl >/dev/null 2>&1 || return 1
  t="${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/assets/agent-statusline.sh"
  mkdir -p "$(dirname "$t")" 2>/dev/null || return 1
  local code
  code="$(curl -sS -L -o "$t.part" -w '%{http_code}' "${BOOTSTRAP_RAW:-}/assets/agent-statusline.sh" 2>/dev/null)" || {
    rm -f "$t.part" 2>/dev/null; return 1; }
  [ "$code" = "200" ] && [ -s "$t.part" ] || { rm -f "$t.part" 2>/dev/null; return 1; }
  mv -f "$t.part" "$t" 2>/dev/null || return 1
  printf '%s' "$t"
}

# m1_shimpath <dir> — a PATH holding everything the status line needs EXCEPT jq.
# WHY IT EXISTS: the script has two arms and picks one with `command -v jq`, so a probe that
# just runs it only ever tests whichever arm THIS Mac selects — the axis under test held
# constant. Measured: reverting the rate_limits cut regresses the no-jq arm to a false red 91%
# while the jq arm stays correct, and a single-arm probe calls that mutant healthy.
# It returns non-zero rather than abstaining if jq is still reachable: an arm that cannot be
# made invalid is an instrument failure, and a silent skip is how coverage disappears.
m1_shimpath() {
  local d="${1:-}" b p
  [ -n "$d" ] || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  for b in cat date git mkdir mv rm; do
    p="$(command -v "$b" 2>/dev/null)" || p=""
    [ -n "$p" ] && ln -sf "$p" "$d/$b" 2>/dev/null
  done
  PATH="$d" command -v jq >/dev/null 2>&1 && return 1      # ARM VALIDITY, asserted not assumed
  return 0
}

# m1_probe <fixture-json> [nojq] — run the INSTALLED script, print its output, ANSI stripped.
# Its telemetry goes to a throwaway directory so a verification can never pollute the real one.
m1_probe() {
  local out td
  td="$(mktemp -d -t pbm1)" || return 1
  if [ "${2:-}" = nojq ]; then
    m1_shimpath "$td/bin" || { rm -rf "$td" 2>/dev/null; return 1; }
    out="$(printf '%s' "$1" | PATH="$td/bin" BOOTSTRAP_TELEMETRY_DIR="$td" "$(M1_SL)" 2>/dev/null)" ||
      { rm -rf "$td" 2>/dev/null; return 1; }
  else
    out="$(printf '%s' "$1" | BOOTSTRAP_TELEMETRY_DIR="$td" "$(M1_SL)" 2>/dev/null)" ||
      { rm -rf "$td" 2>/dev/null; return 1; }
  fi
  rm -rf "$td" 2>/dev/null
  printf '%s' "$out" | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9;]*m//g'
}

# ── the six verbs ────────────────────────────────────────────────────────────────────────────

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_m1_statusline()    { printf '%s' 'context-% in the agent status line, for Claude Code and Copilot CLI alike'; }
cost_m1_statusline()    { printf '%s' 'a ~4 KB script plus one key in each settings file. No installs, no permissions, no network.'; }
profile_m1_statusline() { printf '%s' 'lite'; }

verify_m1_statusline() {
  local sl f cur out
  sl="$(M1_SL)"
  [ -f "$sl" ] && [ -x "$sl" ] || return 1

  # (a) REGISTRATION, parsed back out of each file with plutil — never grepped.
  for f in "$(M1_CC)" "$(M1_CP)"; do
    cur="$(bootstrap_settings_get "$f" statusLine.command raw 2>/dev/null)" || return 1
    [ "$cur" = "$sl" ] || return 1
    cur="$(bootstrap_settings_get "$f" statusLine.type raw 2>/dev/null)" || return 1
    [ "$cur" = "command" ] || return 1
  done

  # (b) BEHAVIOUR: the installed file, EXECUTED — in BOTH its arms. A registration check alone
  #     cannot see a script that crashes, because the status line never runs under -p; and a
  #     single-arm probe cannot see a regression in the arm this Mac does not happen to take.
  local arm
  for arm in "" nojq; do
    out="$(m1_probe "$M1_FIX_CC" "$arm")" || return 1
    case "$out" in *42%*) : ;; *) return 1 ;; esac     # the float truncates: 42.7 -> 42
    case "$out" in *91*) return 1 ;; esac              # …and the rate_limits QUOTA decoy is not read
    out="$(m1_probe "$M1_FIX_CP" "$arm")" || return 1
    case "$out" in *7%*) : ;; *) return 1 ;; esac      # Copilot's live key, used_percentage null
    out="$(m1_probe "$M1_FIX_ZERO" "$arm")" || return 1
    case "$out" in *0%*) : ;; *) return 1 ;; esac      # a real 0 is a reading, not an absence
    # the crossed negative control: usage absent AND a 91% quota decoy ⇒ NO percentage at all
    out="$(m1_probe "$M1_FIX_NEG" "$arm")" || return 1
    case "$out" in *%*) return 1 ;; esac
  done

  # (c) the telemetry producer the Stop advisory depends on — read back through plutil.
  local td pct
  td="$(mktemp -d -t pbm1t)" || return 1
  printf '%s' "$M1_FIX_CC" | BOOTSTRAP_TELEMETRY_DIR="$td" "$sl" >/dev/null 2>&1
  pct="$(bootstrap_settings_get "$td/pb-m1-probe.json" used_pct raw 2>/dev/null)" || pct=""
  rm -rf "$td" 2>/dev/null
  [ "$pct" = "42" ] || return 1
  return 0
}

# gate_ — exit 0 ONLY when a human gesture is genuinely required. Two such states, and neither
# can occur on the fresh Mac this bootstrap targets:
#   1. a settings file exists but is not JSON text, or is unparseable, or is not writable —
#      bootstrap_settings_merge refuses it by design and only a person can decide what to do;
#   2. a settings file already carries SOMEBODY ELSE'S status line. Replacing it is a decision,
#      not an installation. (Once ours is registered this is quiet, so it stays idempotent.)
gate_m1_statusline() { m1_gated_file >/dev/null 2>&1; }

# m1_gated_file — prints "<file>|<why>" for the FIRST file that needs the human, rc 1 if none.
# gate_ is this function, so the gate and the note it prints can never disagree about which
# state fired — two copies of one predicate is how a "needs you" line ends up naming the wrong
# file. The classification is three-way, because "plutil can parse it" is NOT "it is JSON":
# plutil parses XML and binary plists happily, and -replace PRESERVES the input format, so an
# XML-plist settings.json would be rewritten as valid XML and the agent, which reads that path
# as JSON, would start with no settings at all.
m1_gated_file() {
  local f cur sl
  sl="$(M1_SL)"
  for f in "$(M1_CC)" "$(M1_CP)"; do
    if [ -f "$f" ]; then
      if ! bootstrap_is_json_text "$f" >/dev/null 2>&1; then
        if "$BOOTSTRAP_PLUTIL" -convert json -o /dev/null "$f" >/dev/null 2>&1
          then printf '%s|plist' "$f"
          else printf '%s|unparseable' "$f"
        fi
        return 0
      fi
      bootstrap_json_ok "$f" >/dev/null 2>&1 || { printf '%s|unparseable' "$f"; return 0; }
      [ -w "$f" ] || { printf '%s|readonly' "$f"; return 0; }
      cur="$(bootstrap_settings_get "$f" statusLine.command raw 2>/dev/null)" || cur=""
      [ -n "$cur" ] && [ "$cur" != "$sl" ] && { printf '%s|taken' "$f"; return 0; }
    else
      [ -d "$(dirname "$f")" ] && [ ! -w "$(dirname "$f")" ] && { printf '%s|dir' "$f"; return 0; }
    fi
  done
  return 1
}

# The note and the gesture name the file as $HOME/… literally: that string is executable as
# typed in any shell AND carries no username, which is the rule this public repo runs under.
m1_short() { case "$1" in *.claude/*) printf '$HOME/.claude/settings.json' ;; *) printf '$HOME/.copilot/settings.json' ;; esac; }

note_m1_statusline() {
  local g f why
  if g="$(m1_gated_file)"; then
    f="${g%%|*}"; why="${g##*|}"
    case "$why" in
      taken) printf 'a status line of your own is already registered in %s, and replacing it is your call, not mine.' "$(m1_short "$f")" ;;
      unparseable) printf '%s is not valid JSON, so nothing here will touch it.' "$(m1_short "$f")" ;;
      plist) printf '%s is an XML or binary property list wearing a .json name — the agent reads that path as JSON, so it has to be fixed by hand.' "$(m1_short "$f")" ;;
      readonly) printf '%s is not writable by you.' "$(m1_short "$f")" ;;
      *) printf 'the folder holding %s is not writable by you.' "$(m1_short "$f")" ;;
    esac
    return 0
  fi
  printf 'the context-%% status line is not registered with either agent yet.'
}

gesture_m1_statusline() {
  local g f
  g="$(m1_gated_file)" || return 0
  f="${g%%|*}"
  printf 'open -e "%s"' "$(m1_short "$f")"
}

install_m1_statusline() {
  local src sl bin tmp v
  src="$(m1_source)" || { bootstrap_warn "m1: cannot find or fetch assets/agent-statusline.sh"; return 1; }
  sl="$(M1_SL)"; bin="$(dirname "$sl")"
  mkdir -p "$bin" 2>/dev/null || { bootstrap_warn "m1: cannot create $bin"; return 1; }

  if ! cmp -s "$src" "$sl" 2>/dev/null; then           # idempotent: identical bytes ⇒ no write
    tmp="$sl.pb-tmp.$$"
    cp -f "$src" "$tmp" 2>/dev/null || { bootstrap_warn "m1: cannot stage the script"; return 1; }
    chmod 755 "$tmp" 2>/dev/null
    mv -f "$tmp" "$sl" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; bootstrap_warn "m1: cannot place $sl"; return 1; }
  fi
  chmod 755 "$sl" 2>/dev/null

  # Rule 4, before we register anything: a script that cannot produce a percentage must never be
  # written into a settings file, because the agent will then run a broken command every redraw.
  v="$(m1_probe "$M1_FIX_CC")" || { bootstrap_warn "m1: the installed script did not run"; return 1; }
  case "$v" in *42%*) : ;; *) bootstrap_warn "m1: the installed script printed no percentage — not registering it"; return 1 ;; esac

  local ent rc
  ent="{\"type\":\"command\",\"command\":\"$(bootstrap_json_escape "$sl")\"}"
  bootstrap_settings_merge "$(M1_CC)" statusLine "$ent"; rc=$?
  [ "$rc" = 0 ] || { bootstrap_warn "m1: could not register in the Claude Code settings file (rc $rc)"; return 1; }
  bootstrap_settings_merge "$(M1_CP)" statusLine "$ent"; rc=$?
  [ "$rc" = 0 ] || { bootstrap_warn "m1: could not register in the Copilot settings file (rc $rc)"; return 1; }
  return 0
}

# m1_settings_remove <file> <keypath> — the un-write. pb-lib has ONE writer and no remover, so
# this lives here, with the same discipline: back up, work on a temp copy, read the removal back
# THERE, and only then let it land. It refuses exactly what the writer refuses.
m1_settings_remove() {
  local f="${1:-}" k="${2:-}" tmp
  [ -f "$f" ] || return 0
  bootstrap_settings_type "$f" "$k" >/dev/null 2>&1 || return 0        # already absent
  bootstrap_json_ok "$f" >/dev/null 2>&1 || return 2
  bootstrap_is_json_text "$f" >/dev/null 2>&1 || return 2
  bootstrap_backup "$f"
  tmp="$f.m1-tmp.$$"
  cp -p "$f" "$tmp" 2>/dev/null || return 2
  "$BOOTSTRAP_PLUTIL" -remove "$k" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 2; }
  bootstrap_json_ok "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 2; }
  bootstrap_settings_type "$tmp" "$k" >/dev/null 2>&1 && { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 2; }
  return 0
}

uninstall_m1_statusline() {
  local sl f cur rc=0
  sl="$(M1_SL)"
  for f in "$(M1_CC)" "$(M1_CP)"; do
    [ -f "$f" ] || continue
    cur="$(bootstrap_settings_get "$f" statusLine.command raw 2>/dev/null)" || cur=""
    [ "$cur" = "$sl" ] || continue                     # someone else's status line is not ours to remove
    m1_settings_remove "$f" statusLine || rc=1
  done
  rm -f "$sl" 2>/dev/null
  rmdir "$(dirname "$sl")" 2>/dev/null || true         # only if we left it empty
  return "$rc"
}
