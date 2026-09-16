# shellcheck shell=bash
# modules/skills.sh — three portable agent skills, the same bytes for BOTH agents.
#
# A skill is a directory holding a SKILL.md with YAML frontmatter; an agent reads the
# description to decide whether to load the body. This module ships three that are about how a
# coding agent should WORK, and are true of any repository:
#
#   handoff-continuation   handing a session's live state to a successor
#   plan-conventions       integrate, never overwrite; compact what is done, expand what is next
#   verify-by-readback     verify through a different code path than the one that wrote it
#
# WHERE THEY GO, AND WHY EACH PATH IS THE ONE IT IS:
#
#   $HOME/.claude/skills/<name>/SKILL.md     Claude Code's personal skills directory — its plain
#                                            documented default, the same tier `instructions`
#                                            writes $HOME/.claude/CLAUDE.md into. Not probed here:
#                                            a live read-back needs a signed-in agent, and the
#                                            sign-in is bound to the config directory.
#   $HOME/.copilot/skills/<name>/SKILL.md    Copilot CLI's personal skills directory — NOT a
#                                            generalisation from the repo tier. `copilot skill
#                                            --help` on 1.0.83 names it in its own words
#                                            ("Personal  ~/.copilot/skills/ or ~/.agents/skills/"),
#                                            and the path was then measured end to end: after this
#                                            module installed into a sandbox COPILOT_HOME, all
#                                            three appeared under "Personal skills:" in
#                                            `copilot skill list` — the agent's OWN loader — each
#                                            with its name and its description. The sibling
#                                            ~/.agents/skills is the same tier and is deliberately
#                                            not written to as well — one copy per agent, not two.
#
# 🚨 ONLY INTO A ROOT THAT ALREADY EXISTS. If $HOME/.claude is not there, this module does not
#    create it to have somewhere to put its files. A skills directory belonging to an agent that
#    is not installed is litter, and — worse — it would make an absent agent look configured. With
#    neither root present there is nothing to install and nothing to claim, so verify_ is
#    vacuously true and what_/note_ say so rather than the receipt implying a surface exists.
#
# 🚨 NOTHING THAT IS NOT OURS IS EVER TOUCHED. Every file this module writes carries a marker
#    line, and a SKILL.md at one of our three names that does not carry it is somebody else's
#    work at a colliding name. That is a merge, and a merge is a judgment: the module installs
#    nothing, reports NEEDS_HUMAN and hands over the diff. uninstall_ removes only files carrying
#    the marker, so a skill the person has since made their own survives it.
#
# It writes no settings file, so it needs no writer: its whole surface is markdown files under
# $HOME plus their mode bits. Nothing runs, nothing reaches the network, no permission is asked.
#
# bash 3.2 · set -u, no set -e.

SKILLS_NAMES="handoff-continuation plan-conventions verify-by-readback"
SKILLS_MARKER="mac-bootstrap: installed skill"

# ── where things are ─────────────────────────────────────────────────────────────────────────
skills_claude_root()  { printf '%s' "$HOME/.claude"; }
skills_copilot_root() { printf '%s' "${COPILOT_HOME:-$HOME/.copilot}"; }

# skills_roots — one `<agent-root>/skills` line per agent root that EXISTS. Nothing is created here.
skills_roots() {
  local r
  for r in "$(skills_claude_root)" "$(skills_copilot_root)"; do
    [ -d "$r" ] && printf '%s/skills\n' "$r"
  done
  return 0
}

# skills_asset <name> — a readable path to the shipped SKILL.md, or nothing. Only the release tree
# the driver already fetched and hash-checked ($BOOTSTRAP_ASSETS); this module fetches nothing of
# its own, so there is no path by which unchecked bytes could arrive.
skills_asset() {
  local c="${BOOTSTRAP_ASSETS:-}/skills/${1:-}/SKILL.md"
  case "$c" in /*) : ;; *) return 1 ;; esac
  [ -n "${1:-}" ] && [ -r "$c" ] || return 1
  printf '%s' "$c"
}

skills_count() { set -- $SKILLS_NAMES; printf '%s' "$#"; }

# $HOME/x rather than an expanded home directory — house rule 9, applied to what we PRINT too.
skills_homeify() {
  case "${1:-}" in
    "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;;
    *)         printf '%s' "${1:-}" ;;
  esac
}

# ── skills_frontmatter <file> <key> — the value of a top-level frontmatter key. ────────────────
# A STRUCTURAL walk of the document, not a grep for our own text: line 1 must open the block, the
# block must close, and the key must carry a non-empty value inside it. This is the read-back path
# — the installer copies bytes with cp, this parses the result as the document it claims to be —
# and it is a property no truncated or half-written copy can fake.
skills_frontmatter() {
  [ -f "${1:-}" ] || return 1
  awk -v want="${2:-}" '
    NR == 1 { if ($0 != "---") exit 1; open = 1; next }
    open && $0 == "---" { closed = 1; exit }
    open {
      k = $0; sub(/:.*$/, "", k)
      if (k == want) {
        v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
        if (v != "") { val = v; found = 1 }
      }
    }
    END { if (!(open && closed && found)) exit 1; print val }
  ' "$1" 2>/dev/null
}

# skills_is_ours <file> — 0 iff this module wrote it, by the marker line it writes. Ownership only:
# it decides what may be replaced and what may be removed, and is never the evidence that an
# install worked. That evidence is skills_frontmatter plus the byte compare in verify_.
skills_is_ours() {
  [ -f "${1:-}" ] || return 1
  [ -L "${1:-}" ] && return 1
  grep -q "$SKILLS_MARKER" "$1" 2>/dev/null
}

# ── company policy: the files are in place but the agent will not load them ───────────────────
# strictPluginOnlyCustomization, true or a list naming "skills", stops an agent loading personal
# skills — so a byte-perfect install would sit there unread. Per agent: a lock on one leaves the
# other's skills working, and the sentence names only the one that is locked. A policyHelper means
# the policy is computed by a program at startup and cannot be read from here, which is not
# SATISFIED either. The exact key is named so the person can quote it to IT.
skills_policy() {
  local a name found=1
  for a in claude copilot; do
    case "$a" in claude) name='Claude Code' ;; *) name='Copilot CLI' ;; esac
    if bootstrap_policy "$a" policyHelper raw >/dev/null 2>&1; then
      printf '%s: your company computes its policy with a helper program (policyHelper) that cannot be read from here, so whether it loads personal skills is unknown; ask IT\n' "$name"
      found=0
    elif bootstrap_policy_restricts "$a" skills 2>/dev/null; then
      printf "%s: your company's policy strictPluginOnlyCustomization disables personal skills, so the three skill files would never be loaded; ask IT\n" "$name"
      found=0
    fi
  done
  return "$found"
}
skills_policy_note() { skills_policy | awk '{ printf "%s%s", (NR > 1 ? ". " : ""), $0 }'; }

# ── skills_obstacle — the first thing a human must settle, as "<kind>|<path>"; rc 1 when none. ──
# `collision` — a SKILL.md at one of our names that we did not write (a symlink counts: writing
# through one would rewrite a file somewhere else entirely). `readonly` — a directory we cannot
# write, walked up to the deepest ancestor that exists, because a directory we can simply create
# is not something a human has to do.
skills_obstacle() {
  local root n f p
  for root in $(skills_roots); do
    for n in $SKILLS_NAMES; do
      f="$root/$n/SKILL.md"
      if [ -e "$f" ] || [ -L "$f" ]; then
        skills_is_ours "$f" || { printf 'collision|%s' "$f"; return 0; }
        [ -w "$f" ] || { printf 'readonly|%s' "$f"; return 0; }
      fi
    done
    p="$root"
    while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -e "$p" ]; do p="$(dirname "$p")"; done
    [ -d "$p" ] && [ ! -w "$p" ] && { printf 'readonly|%s' "$p"; return 0; }
  done
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_skills()    { printf '%s' 'three skills both agents can load — handing a session on, keeping a plan document, and verifying by independent read-back'; }
cost_skills()    { printf '%s' 'three small markdown files per agent installed (about 12 KB). No installs, no permissions, no network, and nothing is written for an agent this Mac does not have.'; }
profile_skills() { printf '%s' 'lite'; }
# Nothing here reaches the network at install or at run time: three markdown documents an agent
# reads from local disk. What the AGENT does with them is the agent's own egress, declared by agent_cli.
egress_skills()  { :; }
clearance_skills() {
  printf '%s\n' 'agent three instruction files a coding agent loads into its own context and follows; they change how it works, and nothing in them runs, starts at login or reaches the network'
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# verify_ — the end state, read back through a different code path than the installer wrote it.
# The installer copies bytes with cp; this PARSES each installed file's frontmatter as a document,
# requires the name inside it to be the directory it sits in (a copy that landed under the wrong
# name is invisible to any check that only counts files), requires a non-empty description — which
# is the half an agent reads first — and compares the whole file with the shipped asset when that
# is reachable. Nothing here greps for a phrase we wrote.
verify_skills() {
  local root n f src got want
  skills_policy >/dev/null 2>&1 && return 1
  want="$(skills_count)"
  [ "$want" -gt 0 ] || return 1
  [ -n "$(skills_roots)" ] || return 0        # no agent root: nothing to install, nothing claimed
  for root in $(skills_roots); do
    got=0
    for n in $SKILLS_NAMES; do
      f="$root/$n/SKILL.md"
      [ "$(skills_frontmatter "$f" name)" = "$n" ] || return 1
      skills_frontmatter "$f" description >/dev/null || return 1
      # Byte identity with the shipped file, when there is a release tree to compare against. A
      # --verify run from a machine with no clone has no source; the parse above is then what we
      # have, and the difference is stated here rather than silently weakening the check.
      if src="$(skills_asset "$n")"; then cmp -s "$src" "$f" || return 1; fi
      got=$((got + 1))
    done
    [ "$got" -eq "$want" ] || return 1
  done
  return 0
}

# gate_ — 0 iff a human must settle something: IT's policy, a colliding skill of somebody else's,
# or a directory this account cannot write. Never the absence of an agent — that is agent_cli's
# business, and installing nothing for an agent that is not here needs no gesture.
gate_skills() {
  skills_policy >/dev/null 2>&1 && return 0
  skills_obstacle >/dev/null 2>&1 && return 0
  return 1
}

note_skills() {
  local o kind p
  if skills_policy >/dev/null 2>&1; then skills_policy_note; return 0; fi
  if o="$(skills_obstacle 2>/dev/null)" && [ -n "$o" ]; then
    kind="${o%%|*}"; p="${o#*|}"
    if [ "$kind" = collision ]; then
      printf 'this Mac already has a different skill at %s; nothing was overwritten, and merging the two is your call' "$(skills_homeify "$p")"
    elif bootstrap_is_admin; then
      printf 'cannot write %s — it is not writable by this user, so the skill files cannot be installed there' "$(skills_homeify "$p")"
    else
      printf 'cannot write %s — it is not writable by this user and changing its owner needs an administrator; ask IT' "$(skills_homeify "$p")"
    fi
    return 0
  fi
  if [ -z "$(skills_roots)" ]; then
    printf 'neither agent has a configuration directory on this Mac yet, so there is nowhere to put the skills; install an agent and re-run'
    return 0
  fi
  printf 'the three portable agent skills are not installed'
  return 0
}

# ONE resolved command, executable exactly as typed, spelled with $HOME so no user name lands in
# the receipt. Never a bare path: a path pasted into a shell is executed, not opened.
gesture_skills() {
  local o kind p n src
  skills_policy >/dev/null 2>&1 && return 0          # IT's policy: there is no command, only IT
  o="$(skills_obstacle 2>/dev/null)" || return 0
  kind="${o%%|*}"; p="${o#*|}"
  if [ "$kind" = collision ]; then
    n="$(basename "$(dirname "$p")")"
    src="$(skills_asset "$n")" || return 0
    printf 'diff "%s" "%s"' "$(skills_homeify "$p")" "$(skills_homeify "$src")"
  elif bootstrap_is_admin; then                      # a standard user has no sudo to offer
    printf 'sudo chown "$(id -un)" %s' "$(skills_homeify "$p")"
  fi
  return 0
}

# ── install_ — reversible work only: markdown files under an agent root that already exists. ───
# Written through a temp file and mv, so a half-written SKILL.md can never land; an existing file
# of ours is backed up before it is replaced, and one that is not ours is never touched at all
# (gate_ has already reported that case, so reaching it here means it appeared mid-run).
install_skills() {
  local root n src dst tmp rc=0
  [ -n "$(skills_roots)" ] || return 0        # no agent root, and we create none to fill
  for root in $(skills_roots); do
    for n in $SKILLS_NAMES; do
      src="$(skills_asset "$n")" || { bootstrap_warn "skills: cannot resolve assets/skills/$n/SKILL.md"; rc=1; continue; }
      dst="$root/$n/SKILL.md"
      if [ -e "$dst" ] || [ -L "$dst" ]; then
        skills_is_ours "$dst" || { bootstrap_warn "skills: $dst is not ours — refusing to overwrite it."; rc=1; continue; }
        cmp -s "$src" "$dst" && continue      # already current: the second run changes nothing
        bootstrap_backup "$dst"
      fi
      mkdir -p "$root/$n" 2>/dev/null || { bootstrap_warn "skills: cannot create $root/$n"; rc=1; continue; }
      tmp="$dst.mac-bootstrap-tmp.$$"
      if cp "$src" "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null; then
        chmod 644 "$dst" 2>/dev/null
      else
        rm -f "$tmp" 2>/dev/null; bootstrap_warn "skills: cannot place $dst"; rc=1
      fi
    done
  done
  return "$rc"
}

# ── uninstall_ — removes ONLY files carrying our marker, and only the directories that leaves ──
# empty. A skill the person has since edited into their own no longer carries it and stays, as
# does anything of theirs that happens to live under the same root. Safe when nothing is installed.
uninstall_skills() {
  local root n f
  for root in $(skills_roots); do
    for n in $SKILLS_NAMES; do
      f="$root/$n/SKILL.md"
      skills_is_ours "$f" || continue
      rm -f "$f" 2>/dev/null || { bootstrap_warn "skills: cannot remove $f"; return 1; }
      rmdir "$root/$n" 2>/dev/null            # only if we left it empty
    done
    rmdir "$root" 2>/dev/null
  done
  return 0
}
