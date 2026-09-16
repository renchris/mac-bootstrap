# shellcheck shell=bash
# statusline — context-% in the status line, on BOTH agents.
#
# Installs assets/agent-statusline.sh to $BOOTSTRAP_STATE_DIR/bin/ and registers it, by ABSOLUTE path,
# in $HOME/.claude/settings.json and $HOME/.copilot/settings.json — both through the ONE writer,
# bootstrap_settings_merge (the one-writer rule). Nothing here calls plutil or jq to write a settings file.
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

statusline_script() { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/bin/agent-statusline.sh"; }
# ── Claude Code's config root: CLAUDE_CONFIG_DIR when the operator sets it, $HOME/.claude when
# not — the expression the library's bootstrap_managed_sources already reads IT's policy through.
# Every verb runs in its own subshell with ONE module sourced, so this cannot live in one place.
# Hardcoding $HOME/.claude registered the status line in a file the agent never opens.
statusline_config_dir() {
  local d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  case "$d" in */) [ "$d" = / ] || d="${d%/}" ;; esac
  # A relative value is made absolute here: this path is stored and linked from elsewhere, and
  # only an absolute one still names the same file from another directory.
  case "$d" in /*) : ;; *) d="$(pwd -P)/$d" ;; esac
  printf '%s' "$d"
}
statusline_claude_settings() { printf '%s/settings.json' "$(statusline_config_dir)"; }
statusline_copilot_settings() { printf '%s' "$HOME/.copilot/settings.json"; }

# The three fixtures verify_ runs the INSTALLED script against. Their shapes are measured, not
# invented: the decoy is a real rate_limits block (a QUOTA number, never a context number), and
# the Copilot one is the authenticated 1.0.83 shape in which used_percentage is null and the
# live value sits at current_context_used_percentage.
STATUSLINE_FIXTURE_CLAUDE='{"session_id":"statusline-probe","cwd":"/tmp/statusline-fixture","model":{"display_name":"probe"},"context_window":{"used_percentage":42.7,"remaining_percentage":57.3},"rate_limits":{"five_hour":{"used_percentage":91}}}'
STATUSLINE_FIXTURE_COPILOT='{"session_id":"statusline-probe2","cwd":"/tmp/statusline-fixture","model":{"id":null,"display_name":null},"context_window":{"used_percentage":null,"remaining_percentage":null,"current_context_used_percentage":7}}'
STATUSLINE_FIXTURE_NEGATIVE='{"session_id":"statusline-probe3","cwd":"/tmp/statusline-fixture","model":{"display_name":"probe"},"context_window":{"used_percentage":null,"remaining_percentage":null},"rate_limits":{"five_hour":{"used_percentage":91}}}'
# and the fixture that proves the alternation does not swallow a legitimate reading of ZERO:
# jq's `//` fires on null and false ONLY, so 0 must survive it and render as 0%.
STATUSLINE_FIXTURE_ZERO='{"session_id":"statusline-probe4","cwd":"/tmp/statusline-fixture","model":{"display_name":"probe"},"context_window":{"used_percentage":0,"remaining_percentage":100}}'

# statusline_source — where the asset bytes come from: the release tree the driver verified
# ($BOOTSTRAP_ASSETS), else the copy already installed. This module used to fetch the file itself from
# the raw URL; the driver now fetches and hash-checks the whole release once, so a second, unverified
# fetch here could only ever run bytes nobody checked.
statusline_source() {
  local c
  for c in "${BOOTSTRAP_ASSETS:-}/agent-statusline.sh" "$(statusline_script)"; do
    case "$c" in /agent-statusline.sh) continue ;; esac
    [ -r "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ── company policy: the status line is installed but the agent will not run it ───────────────
# The read-back below proves OUR files are right; it cannot see a setting that outranks them. Claude
# Code runs a status line only where hooks may run: allowManagedHooksOnly or disableAllHooks in a
# managed source narrows it to IT's own, and a statusLine IT sets outranks ours by precedence. The
# user's OWN disableAllHooks in $HOME/.claude/settings.json does the same with no IT involved.
# Copilot CLI: no managed gate on its statusLine has been found (1.0.83) — nothing is claimed either way.
# A policyHelper means the policy is computed by a program at startup and cannot be read here.
#
# statusline_policy — one line per cause, "<it|user>|<sentence>"; rc 1 when nothing stands in the way.
statusline_policy() {
  local a name k found=1 what='the context-% status line never shows'
  for a in claude copilot; do
    case "$a" in claude) name='Claude Code' ;; *) name='Copilot CLI' ;; esac
    if bootstrap_policy "$a" policyHelper raw >/dev/null 2>&1; then
      printf 'it|%s: your company computes its policy with a helper program (policyHelper) that cannot be read from here, so whether the status line shows is unknown; ask IT\n' "$name"
      found=0
    fi
  done
  for k in allowManagedHooksOnly disableAllHooks; do
    [ "$(bootstrap_policy claude "$k" raw 2>/dev/null)" = true ] || continue
    printf "it|Claude Code: your company's policy %s means %s; ask IT\n" "$k" "$what"
    return 0
  done
  if bootstrap_policy claude statusLine raw >/dev/null 2>&1; then
    printf "it|Claude Code: your company's policy sets its own statusLine, which outranks this one, so %s; ask IT\n" "$what"
    return 0
  fi
  if [ "$(bootstrap_settings_get "$(statusline_claude_settings)" disableAllHooks raw 2>/dev/null)" = true ]; then
    printf 'user-claude|Claude Code: disableAllHooks is true in your own %s, so %s; removing it is your call\n' "$(statusline_short_path "$(statusline_claude_settings)")" "$what"
    return 0
  fi
  return "$found"
}

# statusline_policy_note / _gesture — the causes as ONE line, and the one command that SHOWS the
# user's own setting (never one that edits it). IT's policy has no command: the gesture is empty.
statusline_policy_note() { statusline_policy | awk '{ sub(/^[^|]*\|/, ""); printf "%s%s", (NR > 1 ? ". " : ""), $0 }'; }
statusline_policy_gesture() {
  local p
  p="$(statusline_policy)" || return 0
  printf '%s\n' "$p" | /usr/bin/grep -q '^it|' && return 0
  printf '%s\n' "$p" | /usr/bin/grep -q '^user-claude|' \
    && printf 'grep -n disableAllHooks "%s"' "$(statusline_short_path "$(statusline_claude_settings)")"
  return 0
}

# statusline_shim_path <dir> — a PATH holding everything the status line needs EXCEPT jq.
# WHY IT EXISTS: the script has two arms and picks one with `command -v jq`, so a probe that
# just runs it only ever tests whichever arm THIS Mac selects — the axis under test held
# constant. Measured: reverting the rate_limits cut regresses the no-jq arm to a false red 91%
# while the jq arm stays correct, and a single-arm probe calls that mutant healthy.
# It returns non-zero rather than abstaining if jq is still reachable: an arm that cannot be
# made invalid is an instrument failure, and a silent skip is how coverage disappears.
statusline_shim_path() {
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

# statusline_probe <fixture-json> [nojq] — run the INSTALLED script, print its output, ANSI stripped.
# Its telemetry goes to a throwaway directory so a verification can never pollute the real one.
statusline_probe() {
  local out td
  td="$(mktemp -d -t pbm1)" || return 1
  if [ "${2:-}" = nojq ]; then
    statusline_shim_path "$td/bin" || { rm -rf "$td" 2>/dev/null; return 1; }
    out="$(printf '%s' "$1" | PATH="$td/bin" BOOTSTRAP_TELEMETRY_DIR="$td" "$(statusline_script)" 2>/dev/null)" ||
      { rm -rf "$td" 2>/dev/null; return 1; }
  else
    out="$(printf '%s' "$1" | BOOTSTRAP_TELEMETRY_DIR="$td" "$(statusline_script)" 2>/dev/null)" ||
      { rm -rf "$td" 2>/dev/null; return 1; }
  fi
  rm -rf "$td" 2>/dev/null
  printf '%s' "$out" | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9;]*m//g'
}

# ── the six verbs ────────────────────────────────────────────────────────────────────────────

# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_statusline()    { printf '%s' 'context-% in the agent status line, for Claude Code and Copilot CLI alike'; }
cost_statusline()    { printf '%s' 'a ~4 KB script plus one key in each settings file. No installs, no permissions, no network.'; }
profile_statusline() { printf '%s' 'lite'; }
# No network of its own: the script reads the JSON the agent pipes to it and the local git branch.
egress_statusline()  { :; }
# The one thing IT governs here: a command the agent runs by itself, on every redraw, with no prompt.
clearance_statusline() {
  printf '%s\n' "agent a status-line command (agent-statusline.sh) that Claude Code and Copilot CLI run on their own at every screen redraw, registered in both agents' settings"
}

verify_statusline() {
  local sl f cur out
  # Our files can all be right while the agent ignores them: a policy that outranks them is not SATISFIED.
  statusline_policy >/dev/null 2>&1 && return 1
  sl="$(statusline_script)"
  [ -f "$sl" ] && [ -x "$sl" ] || return 1

  # (a) REGISTRATION, parsed back out of each file with plutil — never grepped.
  for f in "$(statusline_claude_settings)" "$(statusline_copilot_settings)"; do
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
    out="$(statusline_probe "$STATUSLINE_FIXTURE_CLAUDE" "$arm")" || return 1
    case "$out" in *42%*) : ;; *) return 1 ;; esac     # the float truncates: 42.7 -> 42
    case "$out" in *91*) return 1 ;; esac              # …and the rate_limits QUOTA decoy is not read
    out="$(statusline_probe "$STATUSLINE_FIXTURE_COPILOT" "$arm")" || return 1
    case "$out" in *7%*) : ;; *) return 1 ;; esac      # Copilot's live key, used_percentage null
    out="$(statusline_probe "$STATUSLINE_FIXTURE_ZERO" "$arm")" || return 1
    case "$out" in *0%*) : ;; *) return 1 ;; esac      # a real 0 is a reading, not an absence
    # the crossed negative control: usage absent AND a 91% quota decoy ⇒ NO percentage at all
    out="$(statusline_probe "$STATUSLINE_FIXTURE_NEGATIVE" "$arm")" || return 1
    case "$out" in *%*) return 1 ;; esac
  done

  # (c) the telemetry producer the Stop advisory depends on — read back through plutil.
  local td pct
  td="$(mktemp -d -t pbm1t)" || return 1
  printf '%s' "$STATUSLINE_FIXTURE_CLAUDE" | BOOTSTRAP_TELEMETRY_DIR="$td" "$sl" >/dev/null 2>&1
  pct="$(bootstrap_settings_get "$td/statusline-probe.json" used_pct raw 2>/dev/null)" || pct=""
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
# …and a third that CAN occur on the corporate Mac this bootstrap targets: a policy (statusline_policy).
gate_statusline() { statusline_policy >/dev/null 2>&1 && return 0; statusline_gated_file >/dev/null 2>&1; }

# statusline_gated_file — prints "<file>|<why>" for the FIRST file that needs the human, rc 1 if none.
# gate_ is this function, so the gate and the note it prints can never disagree about which
# state fired — two copies of one predicate is how a "needs you" line ends up naming the wrong
# file. The classification is three-way, because "plutil can parse it" is NOT "it is JSON":
# plutil parses XML and binary plists happily, and -replace PRESERVES the input format, so an
# XML-plist settings.json would be rewritten as valid XML and the agent, which reads that path
# as JSON, would start with no settings at all.
statusline_gated_file() {
  local f cur sl
  sl="$(statusline_script)"
  for f in "$(statusline_claude_settings)" "$(statusline_copilot_settings)"; do
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

# The note and the gesture name the file as $HOME/… where it lives there: that string is executable
# as typed in any shell AND carries no username, which is the rule this public repo runs under. A
# CLAUDE_CONFIG_DIR outside $HOME is printed whole — it is the operator's own path, not one of ours.
statusline_short_path() {
  case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

note_statusline() {
  local g f why
  if statusline_policy >/dev/null 2>&1; then statusline_policy_note; return 0; fi
  if g="$(statusline_gated_file)"; then
    f="${g%%|*}"; why="${g##*|}"
    case "$why" in
      taken) printf 'a status line of your own is already registered in %s, and replacing it is your call, not mine.' "$(statusline_short_path "$f")" ;;
      unparseable) printf '%s is not valid JSON, so nothing here will touch it.' "$(statusline_short_path "$f")" ;;
      plist) printf '%s is an XML or binary property list wearing a .json name — the agent reads that path as JSON, so it has to be fixed by hand.' "$(statusline_short_path "$f")" ;;
      readonly) printf '%s is not writable by you.' "$(statusline_short_path "$f")" ;;
      *) printf 'the folder holding %s is not writable by you.' "$(statusline_short_path "$f")" ;;
    esac
    return 0
  fi
  printf 'the context-%% status line is not registered with either agent yet.'
}

gesture_statusline() {
  local g f
  if statusline_policy >/dev/null 2>&1; then statusline_policy_gesture; return 0; fi
  g="$(statusline_gated_file)" || return 0
  f="${g%%|*}"
  printf 'open -e "%s"' "$(statusline_short_path "$f")"
}

install_statusline() {
  local src sl bin tmp v
  src="$(statusline_source)" || { bootstrap_warn "statusline: cannot find or fetch assets/agent-statusline.sh"; return 1; }
  sl="$(statusline_script)"; bin="$(dirname "$sl")"
  mkdir -p "$bin" 2>/dev/null || { bootstrap_warn "statusline: cannot create $bin"; return 1; }

  if ! cmp -s "$src" "$sl" 2>/dev/null; then           # idempotent: identical bytes ⇒ no write
    tmp="$sl.mac-bootstrap-tmp.$$"
    cp -f "$src" "$tmp" 2>/dev/null || { bootstrap_warn "statusline: cannot stage the script"; return 1; }
    chmod 755 "$tmp" 2>/dev/null
    mv -f "$tmp" "$sl" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; bootstrap_warn "statusline: cannot place $sl"; return 1; }
  fi
  chmod 755 "$sl" 2>/dev/null

  # Rule 4, before we register anything: a script that cannot produce a percentage must never be
  # written into a settings file, because the agent will then run a broken command every redraw.
  v="$(statusline_probe "$STATUSLINE_FIXTURE_CLAUDE")" || { bootstrap_warn "statusline: the installed script did not run"; return 1; }
  case "$v" in *42%*) : ;; *) bootstrap_warn "statusline: the installed script printed no percentage — not registering it"; return 1 ;; esac

  local ent rc
  ent="{\"type\":\"command\",\"command\":\"$(bootstrap_json_escape "$sl")\"}"
  bootstrap_settings_merge "$(statusline_claude_settings)" statusLine "$ent"; rc=$?
  [ "$rc" = 0 ] || { bootstrap_warn "statusline: could not register in the Claude Code settings file (rc $rc)"; return 1; }
  bootstrap_settings_merge "$(statusline_copilot_settings)" statusLine "$ent"; rc=$?
  [ "$rc" = 0 ] || { bootstrap_warn "statusline: could not register in the Copilot settings file (rc $rc)"; return 1; }
  return 0
}

# statusline_settings_remove <file> <keypath> — the un-write. bootstrap-lib.sh has ONE writer and no remover, so
# this lives here, with the same discipline: back up, work on a temp copy, read the removal back
# THERE, and only then let it land. It refuses exactly what the writer refuses.
statusline_settings_remove() {
  local f="${1:-}" k="${2:-}" tmp
  [ -f "$f" ] || return 0
  bootstrap_settings_type "$f" "$k" >/dev/null 2>&1 || return 0        # already absent
  bootstrap_json_ok "$f" >/dev/null 2>&1 || return 2
  bootstrap_is_json_text "$f" >/dev/null 2>&1 || return 2
  bootstrap_backup "$f"
  tmp="$f.statusline-tmp.$$"
  cp -p "$f" "$tmp" 2>/dev/null || return 2
  "$BOOTSTRAP_PLUTIL" -remove "$k" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 2; }
  bootstrap_json_ok "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 2; }
  bootstrap_settings_type "$tmp" "$k" >/dev/null 2>&1 && { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 2; }
  return 0
}

uninstall_statusline() {
  local sl f cur rc=0
  sl="$(statusline_script)"
  for f in "$(statusline_claude_settings)" "$(statusline_copilot_settings)"; do
    [ -f "$f" ] || continue
    cur="$(bootstrap_settings_get "$f" statusLine.command raw 2>/dev/null)" || cur=""
    [ "$cur" = "$sl" ] || continue                     # someone else's status line is not ours to remove
    statusline_settings_remove "$f" statusLine || rc=1
  done
  rm -f "$sl" 2>/dev/null
  rmdir "$(dirname "$sl")" 2>/dev/null || true         # only if we left it empty
  return "$rc"
}
