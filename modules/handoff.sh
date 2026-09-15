#!/bin/bash
# handoff — portable /handoff and self-recycle, END TO END, NO HUMAN.
#
# FIVE artifacts, and two of them are documents rather than programs:
#   $BOOTSTRAP_STATE_DIR/bin/agent-handoff            the verb: capture | status | fire | resume | doctor
#   $BOOTSTRAP_STATE_DIR/succession/{oracle,seed,driver-tmux,driver-kitty,driver-iterm2}.sh
#                                              the engine: one oracle, one seeder, one driver per
#                                              terminal behind ONE seam
#   $BOOTSTRAP_STATE_DIR/succession/README.md         the state machine, the invariant, the failure
#                                              taxonomy, and what is UNPROVEN
#   $HOME/.claude/commands/handoff.md          a real typed /handoff in Claude Code
#   $HOME/.copilot/skills/handoff/SKILL.md     the SAME bytes as a Copilot PERSONAL skill
#
# 🚨 WHAT CHANGED, AND WHY. The previous version of this module shipped a `fire` that printed a
#    paste line for a human, on the strength of two measurements:
#      (a) "the engagement detector cannot say NO" — it returned ENGAGED for a pane parked on the
#          first-run theme picker; and
#      (b) "`claude \"<prompt>\"` auto-submit is REFUTED on a fresh Mac".
#    (a) was TRUE OF THAT DETECTOR and is not a property of the problem: assets/succession/oracle.sh
#    answers NO on eight negative configurations, including the one every cheaper oracle fails —
#    a successor that received the prompt and CANNOT AUTHENTICATE, which writes a real `user`
#    record AND a real content-bearing `assistant` turn. Its negative arms ship as a runnable
#    selftest, so the claim is re-derivable rather than quotable.
#    (b) was entirely two absent JSON booleans. Onboarding is a ONE-TIME state; seeding
#    `hasCompletedOnboarding` and `projects[<abs cwd>].hasTrustDialogAccepted` before the first
#    launch makes the refutation stop applying — measured on a brand-new config dir under a
#    brand-new $HOME, which is the fresh-Mac case the refutation was about.
#    So the automatic path is back, and what makes it safe is not optimism, it is an INVARIANT:
#    the predecessor retires ONLY after the oracle proves the successor engaged, and on timeout
#    the predecessor SURVIVES with a resumable state on disk. `verify_` below asserts the negative
#    arms of exactly those two claims, because an engine that can only say YES is the failure this
#    module previously chose to avoid by not shipping one.
#
# 🚨 WHY THE COPILOT COPY IS AT ~/.copilot AND NOT AT ~/.claude (the Copilot user-tier path). Copilot CLI 1.0.83 has NO
#    mechanism to register a /name — its slash set is a hardcoded array and `.claude/commands`
#    appears zero times in its bundle. The discovery that WAS measured (Copilot reading
#    `.claude/commands/` and `.claude/skills/`) is a REPO-tier result, and the nearest USER-tier
#    measurement points the other way: `$HOME/.claude/skills` is measured NOT read by Copilot.
#    So this module writes Copilot's own personal path explicitly rather than generalising a
#    repo-tier result up a tier. The file stays TOP-LEVEL in its skill directory: a nested
#    `.claude/commands/nested/deep.md` is invisible to Copilot.
#    The user-tier arm is marked UNPROVEN in the file's own header and must be probed on the
#    target with Copilot's `/env`. Installing it is cheap and verifiable; BELIEVING it is not.
#
# 🚨 NOTHING HERE EDITS A SHELL rc, AND THAT IS WHY EVERY PATH IS ABSOLUTE. The consumer of
#    `agent-handoff` is the AGENT, invoked from the command/skill file, not a human at a prompt —
#    so the documents name `$HOME/.mac-bootstrap/bin/agent-handoff` in full. The alternative was
#    appending a PATH line to ~/.zshrc, whose only honest read-back is spawning an interactive
#    login shell; a bootstrap that hangs on somebody's rc to prove its own success is a worse
#    trade than four extra words in a document.
#
# This module writes no settings file, so it needs no writer: its whole surface is files under
# $HOME plus mode bits. It never writes credentials, allowlists or anything that authorizes the
# agent. The ONE authorization-adjacent write in the whole deliverable — the per-directory
# workspace-trust boolean — happens at RUN time, in seed.sh, under guards ($HOME and / refused,
# AH_SEED_TRUST=0 disables it), never at install time and never from here.
#
# bash 3.2 · set -u, no set -e · every verb runs in its own subshell, so no state survives
# between them and everything below re-derives what it needs.

# ── constants, re-derived per verb because no state survives between them ───────────────────
handoff_state_dir()   { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
handoff_bin()     { printf '%s/bin/agent-handoff' "$(handoff_state_dir)"; }
handoff_succession_dir()    { printf '%s/succession' "$(handoff_state_dir)"; }
handoff_claude_command()     { printf '%s/.claude/commands/handoff.md' "$HOME"; }
handoff_copilot_skill()   { printf '%s/.copilot/skills/handoff/SKILL.md' "$HOME"; }
handoff_parts()   { printf 'oracle.sh seed.sh driver-tmux.sh driver-kitty.sh driver-iterm2.sh README.md'; }

# ── handoff_source <asset-relpath> — print a readable path to the shipped asset, or nothing. ────
# Only the release tree the driver verified ($BOOTSTRAP_ASSETS). This used to fall back to a state-dir
# cache and then fetch the file itself from the raw URL; the driver now fetches and hash-checks the
# whole release once, so that fetch could only ever supply bytes nobody checked. With no release tree,
# handoff_doc_ok still makes its structural check and says the byte check was not possible.
handoff_source() {
  local c="${BOOTSTRAP_ASSETS:-}/${1:-}"
  case "$c" in /*) : ;; *) return 1 ;; esac
  [ -n "${1:-}" ] && [ -r "$c" ] || return 1
  printf '%s' "$c"
}

# ── company policy: /handoff is installed but the agent will not load it ────────────────────────
# strictPluginOnlyCustomization, set to true or to a list naming "skills", stops Claude Code reading
# $HOME/.claude/commands/ and stops Copilot CLI loading personal skills — so the byte compare in
# handoff_doc_ok stays true over a /handoff that never appears. Per agent: a lock on one leaves the
# other's /handoff working, and the sentence names only the one that is locked. A policyHelper means
# the policy is computed by a program at startup and cannot be read here.
# (A hook lock does NOT reach this module: nothing in this release wires agent-handoff into a hook, so
# the typed /handoff is the whole of what it installs.)
#
# handoff_policy — one line per cause, "it|<sentence>"; rc 1 when nothing stands in the way.
handoff_policy() {
  local a name what found=1
  for a in claude copilot; do
    case "$a" in
      claude) name='Claude Code'; what='the /handoff command in $HOME/.claude/commands never loads' ;;
      *)      name='Copilot CLI'; what='the handoff skill in $HOME/.copilot/skills never loads' ;;
    esac
    if bootstrap_policy "$a" policyHelper raw >/dev/null 2>&1; then
      printf 'it|%s: your company computes its policy with a helper program (policyHelper) that cannot be read from here, so whether /handoff loads is unknown; ask IT\n' "$name"
      found=0
    elif bootstrap_policy_restricts "$a" skills 2>/dev/null; then
      printf "it|%s: your company's policy strictPluginOnlyCustomization means %s; ask IT\n" "$name" "$what"
      found=0
    fi
  done
  return "$found"
}
handoff_policy_note() { handoff_policy | awk '{ sub(/^[^|]*\|/, ""); printf "%s%s", (NR > 1 ? ". " : ""), $0 }'; }

# ── handoff_brew — a Homebrew this account can install tmux with, or rc 1. ───────────────────────
# A standard user cannot install Homebrew, and cannot use one an administrator installed: the prefix
# is theirs. What this account CAN use is a Homebrew whose bin directory it may write — its own, or one
# IT handed to it. BOOTSTRAP_ASSUME_STANDARD_USER cannot change who owns the files on the Mac it runs
# on, so under it a Homebrew outside $HOME is treated as an administrator's, which is what it is on a
# standard user's Mac.
handoff_brew() {
  local b
  b="$(bootstrap_find_tool brew)" || return 1
  [ -w "$(dirname "$b")" ] || return 1
  case "$b" in
    "$HOME"/*) : ;;
    *) [ "${BOOTSTRAP_ASSUME_STANDARD_USER:-0}" = 1 ] && return 1 ;;
  esac
  printf '%s' "$b"
}

# ── handoff_frontmatter_ok <file> — a STRUCTURAL parse, not a grep for our own text. ────────────
# awk walks the document as a document: line 1 must open the block, the block must close, and
# `description:` must exist inside it with a non-empty value. That is the one property both
# consumers actually depend on — for Copilot the description IS the artifact, because a planted
# body token scored 0 while a description token scored 1 — and it is a property no `cp` can fake.
handoff_frontmatter_ok() {
  [ -f "${1:-}" ] || return 1
  awk '
    NR==1 { if ($0 != "---") exit 1; open=1; next }
    open && $0 == "---" { closed=1; exit }
    open && /^description:[ \t]*[^ \t]/ { d=1 }
    END { exit (open && closed && d) ? 0 : 1 }
  ' "$1" >/dev/null 2>&1
}

# ── handoff_doc_ok <installed> <asset-relpath> — the read-back for a prose asset. ────────────────
# Byte identity against the shipped source when the source is reachable (cmp, which is not the
# code path that wrote it), and the structural parse always. When no source is reachable — a
# --verify run on a machine with no clone and no cache — the parse is what we have, and the
# difference is stated rather than hidden: a check that silently weakens is a check that lies.
handoff_doc_ok() {
  local inst="${1:-}" rel="${2:-}" src
  [ -f "$inst" ] || return 1
  handoff_frontmatter_ok "$inst" || return 1
  src="$(handoff_source "$rel")" || return 0
  cmp -s "$inst" "$src"
}

# ── handoff_blocked_dir — print the first install target whose directory we cannot write. ────────
# Walks up to the deepest ancestor that exists: the gate is "a human must change something",
# and a directory we can simply create is not that.
handoff_blocked_dir() {
  local d p
  for d in "$(handoff_state_dir)/bin" "$(handoff_succession_dir)" "$HOME/.claude/commands" "$HOME/.copilot/skills/handoff"; do
    p="$d"
    while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -e "$p" ]; do p="$(dirname "$p")"; done
    [ -d "$p" ] && [ ! -w "$p" ] && { printf '%s' "$p"; return 0; }
  done
  for p in "$(handoff_bin)" "$(handoff_claude_command)" "$(handoff_copilot_skill)"; do
    [ -e "$p" ] && [ ! -w "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_handoff()    { printf '%s' '/handoff: the session retires itself and starts its successor with no human in the loop'; }
cost_handoff()    { printf '%s' 'a few scripts. Needs tmux (brew install tmux) for its fault tolerance; without it, degrades and says so.'; }
profile_handoff() { printf '%s' 'standard'; }
needs_handoff()   { printf '%s' 'statusline hooks'; }
# The scripts make no connection themselves. What they START does: the successor is a new agent
# session, and it sends its brief and everything after to that agent's own model provider — the same
# one the session it replaces was using, because agent-handoff carries the routing variables across
# (COPILOT_PROVIDER_*, CLAUDE_CODE_USE_BEDROCK/VERTEX, ANTHROPIC_BASE_URL, …). The hosts named are the
# defaults when nothing routes the agent elsewhere.
egress_handoff()  {
  printf '%s\n' 'api.anthropic.com run a Claude Code successor sends its brief to its provider (Anthropic, or the Bedrock/Vertex/gateway your settings route it to)'
  printf '%s\n' 'api.githubcopilot.com run a Copilot CLI successor sends its brief to its provider (GitHub, or the one COPILOT_PROVIDER_BASE_URL names)'
}

verify_handoff() {
  local bin succ out rc p
  # every file right and every negative arm green is still not SATISFIED if the agent will not load it
  handoff_policy >/dev/null 2>&1 && return 1
  bin="$(handoff_bin)"; succ="$(handoff_succession_dir)"
  [ -f "$bin" ] && [ -x "$bin" ] || return 1

  # READ-BACK BY EXECUTION. The installer copied bytes; this runs them. A copy that landed
  # truncated, or against a bash that cannot parse it, is invisible to any check that only looks
  # at the file — and it is exactly what a half-finished fetch produces.
  out="$("$bin" --version 2>/dev/null)" || return 1
  case "$out" in agent-handoff\ [0-9]*) : ;; *) return 1 ;; esac

  # …and it must answer about THIS machine's state dir, which proves the seam is wired, not
  # merely that the file parses.
  out="$("$bin" path 2>/dev/null)" || return 1
  case "$out" in "$(handoff_state_dir)/handoff/"*.md) : ;; *) return 1 ;; esac

  # THE ENGINE'S PARTS EXIST AND PARSE. A driver that cannot be parsed is a succession that fails
  # AFTER the successor has been launched — the one moment a refusal is most expensive.
  for p in $(handoff_parts); do
    [ -f "$succ/$p" ] || return 1
    case "$p" in *.sh) /bin/bash -n "$succ/$p" 2>/dev/null || return 1 ;; esac
  done

  # THE NEGATIVE CONTROLS, and they are the reason this module can claim anything at all.
  #
  # (1) The engagement oracle must be able to say NO. The refuted design's detector could only
  #     ever say YES, and reported a successor parked on a theme picker as ENGAGED — which, wired
  #     to a retire, converts a recoverable stall into the one unrecoverable outcome. Assert the
  #     installed oracle answers NO (or CANNOT-TELL) over a config dir holding nothing, with rc
  #     non-zero.
  out="$(/bin/bash "$succ/oracle.sh" probe --cfg "$succ/__m4_no_such_cfg__" \
           --sid __m4_no_such_sid__ --cwd /__m4_nowhere__ \
           --marker __m4_marker__ --nonce __m4_nonce__ 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || return 1
  case "$out" in *TIER=NO*|*TIER=CANNOT-TELL*) : ;; *) return 1 ;; esac

  # (2) The oracle's own fixtures, including the arm where an API-ERROR record QUOTES the nonce
  #     and must still not reach SPEAKING, and the arm where a sibling's transcript in the same
  #     cwd must not answer for a named session. Running the shipped selftest is the only check
  #     that the installed copy still DISCRIMINATES rather than merely existing.
  /bin/bash "$succ/oracle.sh" selftest >/dev/null 2>&1 || return 1

  # (3) The seeder's guard: it must REFUSE $HOME as a workspace-trust target. That key is the one
  #     authorization-adjacent write in this deliverable — on $HOME the product's own dialog warns
  #     it pre-approves hundreds of tool permissions — and a copy that lost its guard is worse
  #     than an absent one.
  /bin/bash "$succ/seed.sh" trust "$succ/__m4_no_such_cfg__" "$HOME" >/dev/null 2>&1 && return 1

  # (4) The Stop-arm predicate must be able to say NO for an unknown session: rc 1 AND no output.
  out="$("$bin" recycle-due __m4_verify_no_such_session__ 2>/dev/null)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  [ -z "$out" ] || return 1

  handoff_doc_ok "$(handoff_claude_command)"   handoff.md || return 1
  handoff_doc_ok "$(handoff_copilot_skill)" handoff.md || return 1
  # The deliverable is not "a /handoff exists", it is "a FAULT-TOLERANT, zero-human succession".
  # Without tmux the engine falls back to direct mode and loses survives-app-death, so this module
  # is NOT satisfied — gate_/note_/gesture_ then report it (as one `brew install tmux` where this
  # account has a Homebrew it can use, as a plain sentence where it does not) rather than letting
  # the receipt read SATISFIED over a guarantee that is not there.
  handoff_no_tmux && return 1

  return 0
}

# THE FAULT-TOLERANCE SUBSTRATE. The engine's survives-app-death guarantee IS tmux: a successor
# born into a detached tmux session outlives its predecessor AND the terminal application. With no
# tmux every driver falls back to `direct`, where the successor dies with the terminal and the
# retire cannot be verified — /handoff still runs, but the property the operator asked for
# ("end-to-end fault-tolerant") is silently absent. macOS ships no tmux, so on a clean-install Mac
# this is the normal state, not the exotic one. Reported, never assumed: a guarantee believed
# present but inert is worse than one known absent.
handoff_no_tmux()    { command -v tmux >/dev/null 2>&1 && return 1; return 0; }
# Installed-ness, asked cheaply. It matters because the driver consults gate_ BEFORE install_: a
# gate that is true on a bare machine makes the driver skip the install it was about to do, so the
# tmux arm below must fire only once the files are actually down. Measured — without this guard the
# no-tmux arm installed NOTHING and then reported "installed, but WITHOUT its fault tolerance",
# which is a worse failure than either outcome it was choosing between.
handoff_installed()  { [ -x "$(handoff_bin)" ]; }

gate_handoff() {
  handoff_policy >/dev/null 2>&1 && return 0
  handoff_blocked_dir >/dev/null 2>&1 && return 0
  # Only after the files exist: see handoff_installed. On a bare machine this returns false so the
  # driver installs; install_ then returns 3 and the driver re-asks, which is the contract's
  # "an installer may DISCOVER a gate" path.
  handoff_installed && handoff_no_tmux
}

note_handoff() {
  local b
  if handoff_policy >/dev/null 2>&1; then handoff_policy_note; return 0; fi
  if b="$(handoff_blocked_dir 2>/dev/null)" && [ -n "$b" ]; then
    if bootstrap_is_admin; then
      printf 'cannot write %s — it is not writable by this user, so the /handoff files cannot be installed there' "$b"
    else
      printf 'cannot write %s — it is not writable by this user and changing its owner needs an administrator; ask IT' "$b"
    fi
    return 0
  fi
  if handoff_no_tmux; then
    if handoff_brew >/dev/null 2>&1; then
      printf 'installed, but WITHOUT its fault tolerance: macOS ships no tmux, so a successor would be born in direct mode and die with the terminal app, and the retire could not be verified'
    else
      printf 'installed, but WITHOUT its fault tolerance: that needs tmux, and tmux needs Homebrew, which needs an administrator; /handoff still works in direct mode without it, but a successor dies with the terminal app — ask IT for tmux if it must outlive it'
    fi
    return 0
  fi
  printf 'the autonomous /handoff is not installed: no agent-handoff, no succession engine, no /handoff command, no Copilot skill'
  return 0
}

gesture_handoff() {
  local b
  handoff_policy >/dev/null 2>&1 && return 0          # IT's policy: there is no command, only IT
  if b="$(handoff_blocked_dir 2>/dev/null)" && [ -n "$b" ]; then
    bootstrap_is_admin && printf 'sudo chown "$(id -un)" %s' "$b"   # a standard user has no sudo to offer
    return 0
  fi
  if handoff_no_tmux && b="$(handoff_brew)"; then
    # the resolved brew, so it runs as typed without brew on PATH; spelled $HOME when it lives there
    case "$b" in "$HOME"/*) b="\$HOME/${b#"$HOME"/}" ;; esac
    printf 'HOMEBREW_NO_ANALYTICS=1 "%s" install tmux' "$b"
  fi
  return 0
}

install_handoff() {
  local state bin succ cmd skill src lib p
  state="$(handoff_state_dir)"; bin="$(handoff_bin)"; succ="$(handoff_succession_dir)"
  cmd="$(handoff_claude_command)"; skill="$(handoff_copilot_skill)"

  mkdir -p "$state/bin" "$state/handoff" "$succ" "$HOME/.claude/commands" \
           "$HOME/.copilot/skills/handoff" 2>/dev/null \
    || { bootstrap_warn "handoff: cannot create the install directories"; return 1; }

  # 1. the mechanism
  src="$(handoff_source agent-handoff)" || { bootstrap_warn "handoff: cannot find or fetch assets/agent-handoff"; return 1; }
  cp -f "$src" "$bin.handoff-tmp" 2>/dev/null || { bootstrap_warn "handoff: cannot stage $bin"; return 1; }
  chmod 755 "$bin.handoff-tmp" 2>/dev/null
  # Stage, PROVE IT RUNS, then land it. An agent-handoff that cannot execute is worse than an
  # absent one: the Stop arm calls it every turn and a broken copy would fail open forever,
  # silently, exactly as if the fill were simply unknown.
  if ! "$bin.handoff-tmp" --version >/dev/null 2>&1; then
    rm -f "$bin.handoff-tmp" 2>/dev/null
    bootstrap_warn "handoff: the staged agent-handoff does not execute — $bin left untouched"
    return 1
  fi
  mv -f "$bin.handoff-tmp" "$bin" 2>/dev/null || { rm -f "$bin.handoff-tmp" 2>/dev/null; return 1; }

  # 2. the succession engine. Each part is staged, PARSED, and only then landed — a driver that
  #    lands half-written fails after the successor exists, which is the worst moment for it.
  for p in $(handoff_parts); do
    src="$(handoff_source "succession/$p")" || { bootstrap_warn "handoff: cannot find or fetch assets/succession/$p"; return 1; }
    cp -f "$src" "$succ/$p.handoff-tmp" 2>/dev/null || { bootstrap_warn "handoff: cannot stage $succ/$p"; return 1; }
    case "$p" in
      *.sh)
        if ! /bin/bash -n "$succ/$p.handoff-tmp" 2>/dev/null; then
          rm -f "$succ/$p.handoff-tmp" 2>/dev/null
          bootstrap_warn "handoff: the staged $p does not parse — $succ/$p left untouched"
          return 1
        fi
        chmod 755 "$succ/$p.handoff-tmp" 2>/dev/null ;;
      *) chmod 644 "$succ/$p.handoff-tmp" 2>/dev/null ;;
    esac
    mv -f "$succ/$p.handoff-tmp" "$succ/$p" 2>/dev/null \
      || { rm -f "$succ/$p.handoff-tmp" 2>/dev/null; bootstrap_warn "handoff: cannot land $succ/$p"; return 1; }
  done

  # 3. bootstrap-lib.sh, where the installed agent-handoff looks for it.
  #    It carries the context-fill rules (600 s freshness · a null is not 0 · a float truncates ·
  #    never impute a window) and they are deliberately not re-implemented in the tool: two
  #    implementations of one rule are two rules. $state/assets/hooks/ is the rail's OWN fallback
  #    location for the library, so this puts a copy where the rail already looks — it does not
  #    invent a path. Refreshed every run so a stale copy cannot outlive an upgrade.
  lib="${BOOTSTRAP_LIB:-}"
  if [ -n "$lib" ] && [ -r "$lib" ] && [ "$lib" != "$state/assets/hooks/bootstrap-lib.sh" ]; then
    mkdir -p "$state/assets/hooks" 2>/dev/null && cp -f "$lib" "$state/assets/hooks/bootstrap-lib.sh" 2>/dev/null
  fi

  # 4. the document, in both tiers, from ONE source — so the two copies cannot drift.
  # 🚨 UNLINK A SYMLINK BEFORE WRITING THROUGH IT. `cp -f` FOLLOWS a symlink and overwrites its
  #    TARGET, so on a machine where `~/.claude/commands/handoff.md` is a link into somebody's
  #    own repo — measured on the development box, a link into a live checkout — a plain `cp`
  #    silently rewrites a file in THAT repo instead of installing here. A clean-install Mac has
  #    no such link, which is exactly why this would have shipped unnoticed.
  src="$(handoff_source handoff.md)" || { bootstrap_warn "handoff: cannot find or fetch assets/handoff.md"; return 1; }
  for p in "$cmd" "$skill"; do
    if [ -L "$p" ]; then
      bootstrap_warn "handoff: $p is a symlink; replacing the LINK, not writing through it to $(readlink "$p" 2>/dev/null)"
      rm -f "$p" 2>/dev/null
    fi
  done
  cp -f "$src" "$cmd"   2>/dev/null || { bootstrap_warn "handoff: cannot write $cmd"; return 1; }
  cp -f "$src" "$skill" 2>/dev/null || { bootstrap_warn "handoff: cannot write $skill"; return 1; }
  chmod 644 "$cmd" "$skill" 2>/dev/null
  # Everything above LANDED — /handoff is installed and works. But if tmux is absent the
  # fault-tolerance guarantee is not there, and the contract's "an installer may DISCOVER a gate"
  # path is how that reaches the receipt: a non-zero return here makes the driver re-ask gate_,
  # which reports NEEDS_HUMAN + `brew install tmux` instead of a SATISFIED that would be a lie.
  handoff_no_tmux && return 3

  return 0
}

uninstall_handoff() {
  local state succ p
  state="$(handoff_state_dir)"; succ="$(handoff_succession_dir)"
  rm -f "$(handoff_bin)" "$(handoff_claude_command)" "$(handoff_copilot_skill)" 2>/dev/null
  for p in $(handoff_parts); do rm -f "$succ/$p" 2>/dev/null; done
  rmdir "$succ" 2>/dev/null
  rmdir "$HOME/.copilot/skills/handoff" 2>/dev/null
  # The recycle latches are ours and go. THE BRIDGES STAY: they are the user's own writing, they
  # are the one thing in this deliverable that exists nowhere else, and an uninstall that deletes
  # the work is not an uninstall. The per-succession state directories stay for the same reason —
  # an unfinished succession's state is what `resume` needs, and deleting it would strand a
  # successor that is still alive. `rmdir` removes a directory only when it is genuinely empty.
  rm -f "$state"/handoff/recycle-latch.* 2>/dev/null
  rmdir "$state/handoff" 2>/dev/null
  rmdir "$state/bin" 2>/dev/null
  return 0
}
