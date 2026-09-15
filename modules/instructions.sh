#!/bin/bash
# instructions — the minimal, repo-agnostic instructions file, honoured by
# BOTH Claude Code and GitHub Copilot CLI.
#
# It installs four things and nothing else:
#
#   $HOME/.claude/CLAUDE.md                     the 72-line / 6,142-byte global file, verbatim
#   $HOME/.copilot/copilot-instructions.md      a SYMLINK to it — the global tier's only bridge
#   $BOOTSTRAP_STATE_DIR/templates/repo-CLAUDE.md      the 19-line / 518-byte per-repo template
#   $BOOTSTRAP_STATE_DIR/bin/agent-repo-init           the guarded per-repo wiring, as a program
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE LAYOUT IS MEASURED, NOT CHOSEN. Do not "simplify" it back; each leg cost a probe with both
# a positive and a negative control, on Claude Code 2.1.114 and 2.1.183 and Copilot CLI 1.0.83:
#
#  · Claude Code does NOT load a bare AGENTS.md. (Positive control: the same fixture renamed to
#    CLAUDE.md answered. Negative control: a NOTES.md decoy answered UNKNOWN.)
#  · A project CLAUDE.md that is a SYMLINK to AGENTS.md IS loaded by Claude Code, and git
#    records it as a symlink (mode 120000). Copilot reads AGENTS.md, CLAUDE.md, symlinks and
#    @imports — all four shapes — and de-duplicates the identical bytes (measured on its own
#    context counter: 16.2k for one file, 16.2k for the symlinked pair, 17.6k for two different
#    files of the same size).
#  · THE GLOBAL TIER IS TWO DIFFERENT PATHS AND NO CONTENT TRICK UNIFIES THEM. Claude Code reads
#    $HOME/.claude/CLAUDE.md; Copilot reads $HOME/.copilot/copilot-instructions.md.
#    $HOME/.copilot/CLAUDE.md and $HOME/.copilot/AGENTS.md both score ZERO. So: one real file at
#    the Claude path, and a symlink at the Copilot path — measured working 2 of 2 at the default
#    ~/.copilot location, with the symlink then removed and the probe re-run to UNKNOWN 1 of 1.
#
#  The direction matters and is deliberate: the real file sits on the Claude side because
#  "$HOME/.claude/CLAUDE.md as an ordinary file" is the plain documented default and the ONE leg
#  that could not be probed on the research box (auth is bound to the config directory). The
#  symlink sits on the Copilot side, where it WAS measured. Zero untested mechanism carries load.
#
# NOTHING HERE IS OVERWRITTEN. If the machine already has a global instructions file that is not
# ours — a Migration-Assistant Mac carries the old one across — this module installs nothing,
# reports NEEDS_HUMAN, and hands over the diff. Silently replacing an instructions file is the
# exact failure the file it installs tells the agent never to commit.
# ─────────────────────────────────────────────────────────────────────────────────────────────

# ── where things go ──────────────────────────────────────────────────────────────────────────
instructions_state()   { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
instructions_global()  { printf '%s' "$HOME/.claude/CLAUDE.md"; }
instructions_copilot_bridge() { printf '%s' "${COPILOT_HOME:-$HOME/.copilot}/copilot-instructions.md"; }
instructions_template()     { printf '%s/templates/repo-CLAUDE.md' "$(instructions_state)"; }
instructions_repo_init()    { printf '%s/bin/agent-repo-init' "$(instructions_state)"; }

# ── instructions_asset <name> — a readable path to assets/<name> in the release tree the driver verified ──
# Only $BOOTSTRAP_ASSETS. This used to fall back to a state-dir cache and then fetch the file itself
# from the raw URL; the driver now fetches and hash-checks the whole release once, so that fetch could
# only ever supply bytes nobody checked. There is no "installed copy" to fall back to either: the
# installed file is the thing verify_ compares against the shipped one, and it cannot vouch for itself.
instructions_asset() {
  local n="${1:-}"
  [ -n "$n" ] || return 1
  if [ -n "${BOOTSTRAP_ASSETS:-}" ] && [ -r "$BOOTSTRAP_ASSETS/$n" ]; then printf '%s' "$BOOTSTRAP_ASSETS/$n"; return 0; fi
  return 1
}

# $HOME/x rather than an expanded home directory — rule 9, applied to what we PRINT as well as what we ship.
instructions_homeify() {
  local p="${1:-}"
  case "$p" in
    "$HOME"/*) printf '$HOME/%s' "${p#"$HOME"/}" ;;
    *)         printf '%s' "$p" ;;
  esac
}

# ── instructions_absolute <path> — absolute, symlink-resolved. The final component need not exist. ─────────
# /usr/bin/realpath is not on every macOS, and a plain `readlink` comparison is wrong under a
# temp HOME: mktemp -d hands back /var/folders/… which is itself a symlink to /private/var/…,
# so the stored link text and the resolved target differ while naming the same file. Both sides
# of every comparison below go through this.
instructions_absolute() {
  local p="${1:-}" d b t r n=0
  [ -n "$p" ] || return 1
  d="$(dirname "$p")"; b="$(basename "$p")"
  while [ "$n" -lt 32 ]; do
    # A directory that does not exist yet is not an error here — both sides of every comparison
    # run through this function, so a lexical answer still compares correctly. Refusing instead
    # would make a bridge whose target is not installed YET look like somebody else's file.
    r="$(cd "$d" 2>/dev/null && pwd -P)" && d="$r"
    [ -L "$d/$b" ] || break
    t="$(readlink "$d/$b" 2>/dev/null)" || return 1
    case "$t" in
      /*) d="$(dirname "$t")" ;;
      *)  d="$d/$(dirname "$t")" ;;
    esac
    b="$(basename "$t")"
    n=$((n + 1))
  done
  [ "$n" -lt 32 ] || return 1                   # a symlink cycle: say nothing rather than hang
  printf '%s/%s' "$d" "$b"
}

# ── instructions_bridge_shape_ok — is the Copilot path OUR symlink? (shape only; target may not exist) ─
instructions_bridge_shape_ok() {
  local cop a b
  cop="$(instructions_copilot_bridge)"
  [ -L "$cop" ] || return 1
  a="$(instructions_absolute "$cop")" || return 1
  b="$(instructions_absolute "$(instructions_global)")" || return 1
  [ "$a" = "$b" ]
}

# ── instructions_exec_readback — EXECUTE the shipped helper and read its effects back ──────────────────
# Rule 4: verify by running the thing, not by finding it on disk. Rule 5: and prove the check
# can say no — the second arm plants a real CLAUDE.md and requires the helper to REFUSE (rc 4)
# with the file byte-intact. A verifier that only ever exercises the happy path would pass just
# as happily over the `ln -sfn` one-liner that silently destroys an existing instructions file.
instructions_exec_readback() {
  local d rc init tpl body
  init="$(instructions_repo_init)"; tpl="$(instructions_template)"
  [ -x "$init" ] || return 1
  [ -r "$tpl" ]  || return 1
  d="$(mktemp -d "${TMPDIR:-/tmp}/m2iv.XXXXXX")" 2>/dev/null || return 1

  # positive arm — a fresh directory is wired
  ( cd "$d" && BOOTSTRAP_REPO_TEMPLATE="$tpl" "$init" . ) >/dev/null 2>&1 || { rm -rf "$d"; return 1; }
  [ -f "$d/AGENTS.md" ] || { rm -rf "$d"; return 1; }
  [ -L "$d/CLAUDE.md" ] || { rm -rf "$d"; return 1; }
  [ "$(readlink "$d/CLAUDE.md" 2>/dev/null)" = "AGENTS.md" ] || { rm -rf "$d"; return 1; }
  cmp -s "$d/AGENTS.md" "$tpl" || { rm -rf "$d"; return 1; }

  # idempotence arm — re-running is the recovery procedure, so it must change nothing
  ( cd "$d" && BOOTSTRAP_REPO_TEMPLATE="$tpl" "$init" . ) >/dev/null 2>&1 || { rm -rf "$d"; return 1; }
  cmp -s "$d/AGENTS.md" "$tpl" || { rm -rf "$d"; return 1; }
  [ "$(readlink "$d/CLAUDE.md" 2>/dev/null)" = "AGENTS.md" ] || { rm -rf "$d"; return 1; }

  # NEGATIVE CONTROL — a real CLAUDE.md must be refused, preserved, and leave no AGENTS.md
  mkdir -p "$d/neg" 2>/dev/null || { rm -rf "$d"; return 1; }
  printf 'PRECIOUS existing rules\n' > "$d/neg/CLAUDE.md" 2>/dev/null || { rm -rf "$d"; return 1; }
  ( cd "$d/neg" && BOOTSTRAP_REPO_TEMPLATE="$tpl" "$init" . ) >/dev/null 2>&1
  rc=$?
  body="$(cat "$d/neg/CLAUDE.md" 2>/dev/null)" || body=""
  if [ "$rc" -ne 4 ] || [ "$body" != "PRECIOUS existing rules" ] || [ -e "$d/neg/AGENTS.md" ]; then
    rm -rf "$d"; return 1
  fi

  rm -rf "$d"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# verify_ — the end state, read back through a different code path than the installer wrote it.
# The installer copies bytes and calls ln; this compares bytes with cmp, resolves the link, and
# EXECUTES the helper. Nothing here greps for a string we wrote.
# ─────────────────────────────────────────────────────────────────────────────────────────────
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_instructions()    { printf '%s' 'a 6 KB repo-agnostic instructions file both agents read, plus a per-repo template'; }
cost_instructions()    { printf '%s' 'two files and one symlink. No installs, no permissions. Replaceable with your own.'; }
profile_instructions() { printf '%s' 'lite'; }

verify_instructions() {
  local g t r cop

  g="$(instructions_asset global-CLAUDE.md)" || return 1
  t="$(instructions_asset repo-CLAUDE.md)"   || return 1
  r="$(instructions_asset agent-repo-init)"  || return 1

  # 1. the global file is byte-for-byte the shipped asset
  cmp -s "$g" "$(instructions_global)" || return 1

  # 2. the Copilot bridge is a SYMLINK — not a copy, which would drift — that RESOLVES to it
  cop="$(instructions_copilot_bridge)"
  instructions_bridge_shape_ok || return 1
  [ -f "$cop" ] || return 1                     # it resolves (a dangling link is not a bridge)
  cmp -s "$cop" "$g" || return 1                # …and to these exact bytes

  # 3. the per-repo template is staged
  cmp -s "$t" "$(instructions_template)" || return 1

  # 4. the per-repo wiring helper is present, current, and PROVEN BY EXECUTION
  cmp -s "$r" "$(instructions_repo_init)" || return 1
  instructions_exec_readback || return 1

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# gate_ — exit 0 iff a human must decide something. Here that is exactly one situation: this
# machine already has an instructions file of its own at one of the two paths we would write.
# That is a merge, and a merge is a judgment, so it is the operator's. A fresh Mac never gates.
# ─────────────────────────────────────────────────────────────────────────────────────────────
gate_instructions() {
  local g gl cop
  g="$(instructions_asset global-CLAUDE.md)" || return 1  # asset unresolvable ⇒ a FAILURE, not a gesture

  gl="$(instructions_global)"
  if [ -e "$gl" ] || [ -L "$gl" ]; then
    cmp -s "$g" "$gl" || return 0
  fi

  cop="$(instructions_copilot_bridge)"
  if [ -e "$cop" ] || [ -L "$cop" ]; then
    instructions_bridge_shape_ok || return 0
  fi

  return 1
}

note_instructions() {
  local g gl cop
  g="$(instructions_asset global-CLAUDE.md)" || {
    printf 'the shipped instructions file is not in the release tree this run verified'
    return 0; }

  gl="$(instructions_global)"
  if { [ -e "$gl" ] || [ -L "$gl" ]; } && ! cmp -s "$g" "$gl"; then
    printf 'this Mac already has its own global agent instructions at $HOME/.claude/CLAUDE.md; nothing was overwritten, and merging the two is your call'
    return 0
  fi

  cop="$(instructions_copilot_bridge)"
  if { [ -e "$cop" ] || [ -L "$cop" ]; } && ! instructions_bridge_shape_ok; then
    printf 'Copilot already has its own $HOME/.copilot/copilot-instructions.md; nothing was overwritten, so move yours aside if you want it bridged to the Claude file'
    return 0
  fi

  printf 'the global instructions file and its Copilot bridge are not installed'
  return 0
}

# ONE resolved command, executable exactly as typed, and spelled with $HOME so no user name
# lands in the receipt. Never a bare path: a path pasted into a shell is executed, not opened.
gesture_instructions() {
  local g gl cop
  g="$(instructions_asset global-CLAUDE.md)" || return 0

  gl="$(instructions_global)"
  if { [ -e "$gl" ] || [ -L "$gl" ]; } && ! cmp -s "$g" "$gl"; then
    printf 'diff "$HOME/.claude/CLAUDE.md" "%s"' "$(instructions_homeify "$g")"
    return 0
  fi

  cop="$(instructions_copilot_bridge)"
  if { [ -e "$cop" ] || [ -L "$cop" ]; } && ! instructions_bridge_shape_ok; then
    printf 'mv "%s" "%s.yours"' "$(instructions_homeify "$cop")" "$(instructions_homeify "$cop")"
    return 0
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# install_ — reversible work only. Writes through a temp file and mv, so a half-written
# instructions file can never land; refuses, loudly, rather than overwrite anything it did not
# write. Returns non-zero if any leg refused, which sends the driver back to gate_.
# ─────────────────────────────────────────────────────────────────────────────────────────────
install_instructions() {
  local g t r rc=0
  g="$(instructions_asset global-CLAUDE.md)" || { bootstrap_warn "instructions: cannot resolve assets/global-CLAUDE.md"; return 1; }
  t="$(instructions_asset repo-CLAUDE.md)"   || { bootstrap_warn "instructions: cannot resolve assets/repo-CLAUDE.md";   return 1; }
  r="$(instructions_asset agent-repo-init)"  || { bootstrap_warn "instructions: cannot resolve assets/agent-repo-init";  return 1; }

  # THE BRIDGE IS CONDITIONAL ON THE GLOBAL FILE BEING OURS, and that ordering is load-bearing.
  # Found by running the conflict fixture: when the global leg refuses (the operator's own file is
  # there) an unconditional bridge points Copilot at a file this module did not write — and when
  # there is no global file at all it leaves a DANGLING symlink, which the next fixture then
  # wrote *through*, silently creating the very file the refusal had just preserved us from.
  # We route Copilot at our own file or at nothing.
  if instructions_place_guarded "$g" "$(instructions_global)"; then
    instructions_place_bridge || rc=1
  else
    rc=1
  fi
  instructions_place_ours "$t" "$(instructions_template)"  ''   || rc=1
  instructions_place_ours "$r" "$(instructions_repo_init)" exec || rc=1
  return $rc
}

# A file we must NOT own: install it only into an empty slot, or when it is already ours.
instructions_place_guarded() {
  local src="$1" dst="$2" tmp
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    cmp -s "$src" "$dst" && return 0
    bootstrap_warn "instructions: $dst already exists and differs from the shipped file — refusing to overwrite it."
    return 1
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null || { bootstrap_warn "instructions: cannot create $(dirname "$dst")"; return 1; }
  tmp="$dst.mac-bootstrap-tmp.$$"
  cp "$src" "$tmp" 2>/dev/null || { bootstrap_warn "instructions: cannot stage $dst"; return 1; }
  mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; bootstrap_warn "instructions: cannot place $dst"; return 1; }
  return 0
}

# A file that IS ours, under $BOOTSTRAP_STATE_DIR: a stale copy there is our own older release, so it
# is replaced rather than refused. Still written via temp+mv, never edited in place.
instructions_place_ours() {
  local src="$1" dst="$2" mode="${3:-}" tmp
  cmp -s "$src" "$dst" 2>/dev/null && { [ "$mode" = exec ] && chmod 0755 "$dst" 2>/dev/null; return 0; }
  mkdir -p "$(dirname "$dst")" 2>/dev/null || { bootstrap_warn "instructions: cannot create $(dirname "$dst")"; return 1; }
  tmp="$dst.mac-bootstrap-tmp.$$"
  cp "$src" "$tmp" 2>/dev/null || { bootstrap_warn "instructions: cannot stage $dst"; return 1; }
  [ "$mode" = exec ] && chmod 0755 "$tmp" 2>/dev/null
  mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; bootstrap_warn "instructions: cannot place $dst"; return 1; }
  return 0
}

# The Copilot bridge. `ln -s` is not idempotent (rc 1, "File exists" on the second run) and the
# obvious repair, `ln -sfn`, silently destroys a real file at that path. Guarded in all three
# states instead; the refusal preserves what is there.
instructions_place_bridge() {
  local cop
  cop="$(instructions_copilot_bridge)"
  instructions_bridge_shape_ok && return 0
  if [ -e "$cop" ] || [ -L "$cop" ]; then
    bootstrap_warn "instructions: $cop already exists and is not a link to the Claude file — refusing to replace it."
    return 1
  fi
  mkdir -p "$(dirname "$cop")" 2>/dev/null || { bootstrap_warn "instructions: cannot create $(dirname "$cop")"; return 1; }
  ln -s "$(instructions_global)" "$cop" 2>/dev/null || { bootstrap_warn "instructions: cannot create the Copilot bridge"; return 1; }
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# uninstall_ — removes ONLY what this module wrote, identified by content, never by path.
# A global file the operator has since edited is left exactly where it is.
# ─────────────────────────────────────────────────────────────────────────────────────────────
uninstall_instructions() {
  local g gl cop
  g="$(instructions_asset global-CLAUDE.md)" || g=""

  gl="$(instructions_global)"
  if [ -f "$gl" ] && [ -n "$g" ] && cmp -s "$g" "$gl"; then
    rm -f "$gl" 2>/dev/null || { bootstrap_warn "instructions: cannot remove $gl"; return 1; }
  fi

  cop="$(instructions_copilot_bridge)"
  if instructions_bridge_shape_ok; then
    rm -f "$cop" 2>/dev/null || { bootstrap_warn "instructions: cannot remove $cop"; return 1; }
  fi

  rm -f "$(instructions_template)" "$(instructions_repo_init)" 2>/dev/null
  rmdir "$(instructions_state)/templates" 2>/dev/null    # only if we left it empty
  return 0
}
