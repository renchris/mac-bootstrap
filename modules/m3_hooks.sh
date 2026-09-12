#!/bin/bash
# m3_hooks.sh — DELIVERABLE 2b: the agent lifecycle hook core, for BOTH agents.
#
# INSTALLS five files into $BOOTSTRAP_STATE_DIR/hooks — bootstrap-lib.sh and four hooks — and REGISTERS THREE
# of them, twice: once in $HOME/.claude/settings.json and once in
# $HOME/.copilot/hooks/00-lifecycle.json. The wire table is assets/copilot-hooks.json (_spec.wire);
# this module renders it, it does not carry a second copy of it.
#
#   session-start.sh  SessionStart  → frozen scope · last ledger · LIVE git read · jq warning
#   stop.sh           Stop          → ledger · context-fill advisory (C3) · bounded continue
#   guard-write.sh    PreToolUse    → backup + INTEGRATE-never-overwrite advisory
#   guard-bash.sh     (not wired)   → installed, deliberately unregistered. See below.
#
# ── WHY BOTH AGENTS TAKE ONE SET OF SCRIPTS ──────────────────────────────────────────────────
# Registered under Claude Code's PascalCase event names — which GitHub documents as the "VS Code
# compatible format" and which were MEASURED firing on Copilot CLI 1.0.83 with six near-miss
# controls silent — Copilot's hook stdin is field-for-field Claude Code's snake_case, including
# tool_name: "Bash". So there is no shim, no second script and no dialect branch, and the only
# divergences are handled inside the hooks themselves (see assets/copilot-hooks.json _pb).
# The USER tier is used on both: Copilot repo-level hooks are trust-gated and silently do not
# fire until a folder is trusted, so a bootstrap that used them would install a hook set that
# does nothing and says so nowhere.
#
# ── WHY guard-bash.sh IS INSTALLED AND NOT WIRED ──────────────────────────────────────────
# It false-allowed its own flagship class: a quoted `rm -rf "$HOME/…"`, a quoted force-push to
# trunk, a bare `~`, a `${HOME}` spelling and a `+main` refspec all got through, because its
# quote-stripping pre-pass deleted the token its patterns matched and every one of its fourteen
# must-deny fixtures was unquoted. It is rewritten and now passes a 66-case matrix with a quoted
# arm per class and a pre-fix arm asserted RED — but a guard believed present and inert is worse
# than one known absent, and this one has already been wrong in the unrecoverable direction.
# verify_m3_hooks ASSERTS it is absent from both settings files, so "unwired" is a checked fact.
#
# ── THE ONE WRITER ───────────────────────────────────────────────────────────────────────────
# Every settings write goes through bootstrap_hook_wire / bootstrap_copilot_hook_wire / bootstrap_settings_merge.
# This module contains no plutil and no jq call that writes. That is C2, and it is why a Mac
# without jq gets the same hooks rather than a statusline and no hooks.
#
# Contract: six verbs, no top-level side effects, bash 3.2, set -u, never `exit`.

# ── small helpers this module needs and bootstrap-lib.sh does not have. Noted as contract deviations. ──

m3_dir()      { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/hooks"; }
m3_cc()       { printf '%s' "$HOME/.claude/settings.json"; }
m3_cop()      { printf '%s' "$HOME/.copilot/hooks/00-lifecycle.json"; }
m3_scripts()  { printf '%s' "session-start.sh stop.sh guard-write.sh guard-bash.sh"; }
m3_unwired()  { printf '%s' "guard-bash.sh"; }

# m3_asset <relpath> <dest> — resolve a shipped asset: the clone first, then the installed copy,
# then the pinned raw URL. Returns 1 if it cannot be had, and never leaves a partial file.
m3_asset() {
  local rel="${1:-}" dest="${2:-}" code
  [ -n "$rel" ] && [ -n "$dest" ] || return 1
  if [ -r "${BOOTSTRAP_ASSETS:-}/$rel" ]; then cp -f "${BOOTSTRAP_ASSETS}/$rel" "$dest" 2>/dev/null && return 0; fi
  if [ -r "$(m3_dir)/$(basename "$rel")" ] && [ "$dest" != "$(m3_dir)/$(basename "$rel")" ]; then
    cp -f "$(m3_dir)/$(basename "$rel")" "$dest" 2>/dev/null && return 0
  fi
  case "${BOOTSTRAP_PIN:-}" in __PIN_SHA__|main|master|"") return 1 ;; esac
  command -v curl >/dev/null 2>&1 || return 1
  code="$(curl -sS -L -o "$dest.part" -w '%{http_code}' "${BOOTSTRAP_RAW:-}/assets/$rel" 2>/dev/null)" || {
    rm -f "$dest.part" 2>/dev/null; return 1; }
  [ "$code" = 200 ] && [ -s "$dest.part" ] || { rm -f "$dest.part" 2>/dev/null; return 1; }
  mv -f "$dest.part" "$dest" 2>/dev/null
}

# m3_table — the wire table's path: the clone's copy if we have it, else the installed one.
m3_table() {
  if [ -r "${BOOTSTRAP_ASSETS:-}/copilot-hooks.json" ]; then printf '%s' "${BOOTSTRAP_ASSETS}/copilot-hooks.json"; return 0; fi
  [ -r "$(m3_dir)/copilot-hooks.json" ] && { printf '%s' "$(m3_dir)/copilot-hooks.json"; return 0; }
  return 1
}

# m3_rows — how many rows the wire table has (0 if it cannot be read).
m3_rows() {
  local t
  t="$(m3_table)" || { printf '0'; return 0; }
  bootstrap_array_len "$t" "_spec.wire"
}

# m3_field <row-index> <field> — one field of one wire row, or empty.
m3_field() {
  local t
  t="$(m3_table)" || return 1
  bootstrap_settings_get "$t" "_spec.wire.${1:-0}.${2:-script}" raw
}

# m3_cmd <script> — the ABSOLUTE command string we register. $HOME is expanded here rather than
# left literal: the settings file is machine-local runtime state, so the expanded path is both
# correct and free of any assumption about how the agent invokes it. No shipped file in this repo
# ever contains it (house rule 9).
m3_cmd() { printf '%s/%s' "$(m3_dir)" "${1:-}"; }

# m3_count_cc <settings> <command> — how many times this exact command appears anywhere under
# .hooks, across every event and group. A COUNT, not a boolean: "wired" and "wired twice" are
# different states, and only the count can tell them apart. plutil only — never the writer's jq.
m3_count_cc() {
  local f="${1:-}" cmd="${2:-}" ev i j c n=0
  [ -f "$f" ] || { printf '0'; return 0; }
  for ev in $(bootstrap_hook_events "$f"); do
    i=0
    while [ "$i" -lt 64 ] && bootstrap_settings_get "$f" "hooks.$ev.$i" json >/dev/null 2>&1; do
      j=0
      while [ "$j" -lt 64 ]; do
        c="$(bootstrap_settings_get "$f" "hooks.$ev.$i.hooks.$j.command" raw 2>/dev/null)" || break
        [ "$c" = "$cmd" ] && n=$((n + 1))
        j=$((j + 1))
      done
      i=$((i + 1))
    done
  done
  printf '%s' "$n"
}

# m3_count_cop <hooks.json> <command> — the same count in the Copilot envelope (.bash, no group).
m3_count_cop() {
  local f="${1:-}" cmd="${2:-}" ev i b n=0
  [ -f "$f" ] || { printf '0'; return 0; }
  for ev in $(bootstrap_hook_events "$f"); do
    i=0
    while [ "$i" -lt 64 ]; do
      b="$(bootstrap_settings_get "$f" "hooks.$ev.$i.bash" raw 2>/dev/null)" || break
      [ "$b" = "$cmd" ] && n=$((n + 1))
      i=$((i + 1))
    done
  done
  printf '%s' "$n"
}

# m3_file_unusable <file> — 0 when the file EXISTS and we must not touch it: unreadable, not
# writable, not valid JSON, or a plist wearing a .json name. That is a human's decision, not
# ours — we never repair a file the user owns.
m3_file_unusable() {
  local f="${1:-}"
  [ -f "$f" ] || return 1
  [ -r "$f" ] || return 0
  [ -w "$f" ] || return 0
  [ -s "$f" ] || return 1
  bootstrap_json_ok "$f" || return 0
  bootstrap_is_json_text "$f" || return 0
  return 1
}

# ── verify ───────────────────────────────────────────────────────────────────────────────────
# Exit 0 IFF the end state is genuinely present, read back through a different code path than
# the installer wrote it with, and PROVEN BY EXECUTION where execution is possible:
#   · every file present and executable
#   · every command string registered EXACTLY ONCE in each settings file, read with plutil
#   · the unwired guard registered EXACTLY ZERO times in either file
#   · a bogus event name registered nowhere (the negative control: without it, "the hooks are
#     wired" is unfalsifiable — everything is wired if nothing is checked for absence)
#   · guard-write.sh FIRED with a real PreToolUse payload actually writes a backup file, and
#     fired with a tool name that cannot overwrite anything writes nothing
#   · stop.sh's own fixtures pass — they carry the C3 matrix (12%/82% × repo/bare/inert-git)
#
# HONEST BOUND, and it is the one thing this verifier cannot do: it does not launch an agent.
# Registering a hook and having a real agent RUN it are different claims, and the second needs an
# authenticated agent, quota, and in Copilot's case a CLI that is on no machine here. What is
# measured upstream (copilot-surface.md §3.4, R-A) is that these exact event names fire and six
# near-miss controls do not; what is measured HERE is that the scripts are registered exactly
# once and that they do what they claim when executed. Neither of those is "the agent ran it".
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_m3_hooks()    { printf '%s' 'session lifecycle hooks: a start brief, a state ledger, a context-fill advisory, a write guard'; }
cost_m3_hooks()    { printf '%s' 'four scripts plus hook entries in both settings files. No installs, no permissions.'; }
profile_m3_hooks() { printf '%s' 'lite'; }

verify_m3_hooks() {
  local d t n i s cmd ev rows T out before after rc=0
  d="$(m3_dir)"
  t="$(m3_table)" || return 1
  rows="$(m3_rows)"; case "$rows" in ''|*[!0-9]*) return 1 ;; esac
  [ "$rows" -gt 0 ] || return 1

  # files
  for s in $(m3_scripts); do
    [ -f "$d/$s" ] && [ -x "$d/$s" ] || return 1
    if [ -r "${BOOTSTRAP_ASSETS:-}/hooks/$s" ]; then
      cmp -s "${BOOTSTRAP_ASSETS}/hooks/$s" "$d/$s" || return 1
    fi
  done
  [ -f "$d/bootstrap-lib.sh" ] || return 1
  [ -f "$d/copilot-hooks.json" ] || return 1
  if [ -n "${BOOTSTRAP_LIB:-}" ] && [ -r "${BOOTSTRAP_LIB}" ]; then cmp -s "${BOOTSTRAP_LIB}" "$d/bootstrap-lib.sh" || return 1; fi

  # the wire table's two renderings must still agree — a table copied twice drifts in silence
  i=0
  while [ "$i" -lt "$rows" ]; do
    s="$(m3_field "$i" script)";  [ -n "$s" ] || return 1
    ev="$(m3_field "$i" event)";  [ -n "$ev" ] || return 1
    [ "$(bootstrap_settings_get "$t" "hooks.$ev.0.bash" raw 2>/dev/null)" = "\$HOME/.mac-bootstrap/hooks/$s" ] || return 1
    i=$((i + 1))
  done

  # registered exactly once, in both files, counted through plutil
  i=0
  while [ "$i" -lt "$rows" ]; do
    s="$(m3_field "$i" script)"
    cmd="$(m3_cmd "$s")"
    [ "$(m3_count_cc  "$(m3_cc)"  "$cmd")" = 1 ] || return 1
    [ "$(m3_count_cop "$(m3_cop)" "$cmd")" = 1 ] || return 1
    i=$((i + 1))
  done
  [ "$(bootstrap_settings_get "$(m3_cop)" version raw 2>/dev/null)" = 1 ] || return 1

  # the unwired guard: present on disk, registered NOWHERE
  for s in $(m3_unwired); do
    cmd="$(m3_cmd "$s")"
    [ "$(m3_count_cc  "$(m3_cc)"  "$cmd")" = 0 ] || return 1
    [ "$(m3_count_cop "$(m3_cop)" "$cmd")" = 0 ] || return 1
  done

  # NEGATIVE CONTROL: an event name that does not exist must be registered in neither file.
  # This is what makes the counts above mean something: it proves the counter can return 0.
  bootstrap_settings_get "$(m3_cc)"  "hooks.NotAnEventXYZ" json >/dev/null 2>&1 && return 1
  bootstrap_settings_get "$(m3_cop)" "hooks.NotAnEventXYZ" json >/dev/null 2>&1 && return 1

  # FIRE the write guard for real, in a sandbox, and require the file it promises to appear.
  T="$(mktemp -d -t m3v 2>/dev/null)" || return 1
  printf 'a\nb\n' > "$T/plan.md"
  out="$(BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$d/guard-write.sh" 2>/dev/null <<XIN
{"hook_event_name":"PreToolUse","session_id":"VERIFY","cwd":"$T","tool_name":"Write","tool_input":{"file_path":"$T/plan.md"}}
XIN
)"
  after="$(ls "$T/state/backups/"*.bak 2>/dev/null | bootstrap_count)"
  case "$out" in *'OVERWRITE GUARD'*) : ;; *) rc=1 ;; esac
  [ "${after:-0}" -ge 1 ] || rc=1
  # …and again on the PLUTIL ARM, because a nested payload read is where the no-jq degrade
  # actually bites: before this repo had hook_field, both guards were INERT without jq and every
  # structural check above still passed. A settings file can be perfectly wired to a hook that
  # does nothing.
  before="$after"
  BOOTSTRAP_NO_JQ=1 BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$d/guard-write.sh" >/dev/null 2>&1 <<XIN
{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"$T/plan.md"}}
XIN
  after="$(ls "$T/state/backups/"*.bak 2>/dev/null | bootstrap_count)"
  [ "${after:-0}" -gt "${before:-0}" ] || rc=1

  # …and the negative half: a tool that cannot overwrite a file must write nothing at all.
  before="$after"
  out="$(BOOTSTRAP_STATE_DIR="$T/state" /bin/bash "$d/guard-write.sh" 2>/dev/null <<XIN
{"hook_event_name":"PreToolUse","session_id":"VERIFY","cwd":"$T","tool_name":"NotAToolXYZ","tool_input":{"file_path":"$T/plan.md"}}
XIN
)"
  after="$(ls "$T/state/backups/"*.bak 2>/dev/null | bootstrap_count)"
  [ "$after" = "$before" ] || rc=1
  [ -z "$out" ] || rc=1
  rm -rf "$T" 2>/dev/null

  # the Stop hook's own fixtures — they carry the C3 matrix and the block bound
  /bin/bash "$d/stop.sh" --selftest >/dev/null 2>&1 || rc=1

  return "$rc"
}

# ── gate ─────────────────────────────────────────────────────────────────────────────────────
# 0 IFF a human gesture is required. Wiring hooks needs no permission, no sudo and no dialog, so
# the ONLY gate here is a settings file that exists and that we must not touch: unreadable, not
# writable, invalid JSON, or an XML/binary plist wearing a .json name. Repairing a file the user
# owns is their call, not ours — and the alternative, a merge that "fixes" it, is how an agent
# silently starts with no settings at all.
gate_m3_hooks() {
  m3_file_unusable "$(m3_cc)"  && return 0
  m3_file_unusable "$(m3_cop)" && return 0
  [ -w "$HOME" ] || return 0
  return 1
}

note_m3_hooks() {
  if m3_file_unusable "$(m3_cc)"; then
    printf 'Your Claude Code settings file exists but is not JSON we can safely merge into (invalid, a plist, or not writable) — nothing was touched.'
  elif m3_file_unusable "$(m3_cop)"; then
    printf 'Your Copilot hooks file exists but is not JSON we can safely merge into (invalid, a plist, or not writable) — nothing was touched.'
  elif [ ! -w "$HOME" ]; then
    printf 'Your home directory is not writable by this account, so no agent settings can be installed.'
  else
    printf 'The lifecycle hooks are not installed or not registered for both agents.'
  fi
}

gesture_m3_hooks() {
  if m3_file_unusable "$(m3_cc)"; then
    printf 'open -e "%s"' "$(m3_cc)"
  elif m3_file_unusable "$(m3_cop)"; then
    printf 'open -e "%s"' "$(m3_cop)"
  fi
  return 0
}

# ── install ──────────────────────────────────────────────────────────────────────────────────
# Reversible, idempotent, and every settings write goes through the library's one writer.
install_m3_hooks() {
  local d t rows i s ev mt to cmd rc=0
  d="$(m3_dir)"
  mkdir -p "$d" 2>/dev/null || { bootstrap_warn "m3: cannot create $d"; return 1; }

  # the library the hooks source: the one in force, so a hook can never run against a different
  # bootstrap-lib.sh than the driver did. Falls back to the shipped asset when BOOTSTRAP_LIB is unset.
  if [ -n "${BOOTSTRAP_LIB:-}" ] && [ -r "${BOOTSTRAP_LIB}" ]; then
    cp -f "${BOOTSTRAP_LIB}" "$d/bootstrap-lib.sh" 2>/dev/null || { bootstrap_warn "m3: cannot place bootstrap-lib.sh"; return 1; }
  else
    m3_asset hooks/bootstrap-lib.sh "$d/bootstrap-lib.sh" || { bootstrap_warn "m3: cannot resolve bootstrap-lib.sh"; return 1; }
  fi
  for s in $(m3_scripts); do
    m3_asset "hooks/$s" "$d/$s" || { bootstrap_warn "m3: cannot resolve $s"; return 1; }
    chmod +x "$d/$s" 2>/dev/null || true
  done
  m3_asset copilot-hooks.json "$d/copilot-hooks.json" || { bootstrap_warn "m3: cannot resolve copilot-hooks.json"; return 1; }

  t="$(m3_table)" || { bootstrap_warn "m3: no wire table"; return 1; }
  rows="$(m3_rows)"; case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
  [ "$rows" -gt 0 ] || { bootstrap_warn "m3: wire table is empty"; return 1; }

  i=0
  while [ "$i" -lt "$rows" ]; do
    s="$(m3_field "$i" script)"
    ev="$(m3_field "$i" event)"
    to="$(m3_field "$i" timeout)"; case "$to" in ''|*[!0-9]*) to=10 ;; esac
    cmd="$(m3_cmd "$s")"
    [ -n "$s" ] && [ -n "$ev" ] || { bootstrap_warn "m3: wire row $i is incomplete"; rc=1; i=$((i + 1)); continue; }

    mt="$(m3_field "$i" claude_matcher)"
    bootstrap_hook_wire "$(m3_cc)" "$ev" "$mt" "$cmd" "$to" || { bootstrap_warn "m3: could not wire $s into $(m3_cc)"; rc=1; }

    # Copilot: an EMPTY matcher is omitted by the library rather than written as "" — matcher is
    # a regex there, and an empty regex is not a wildcard.
    mt="$(m3_field "$i" copilot_matcher)"
    bootstrap_copilot_hook_wire "$(m3_cop)" "$ev" "$mt" "$cmd" "$to" || { bootstrap_warn "m3: could not wire $s into $(m3_cop)"; rc=1; }
    i=$((i + 1))
  done
  return "$rc"
}

# ── uninstall ────────────────────────────────────────────────────────────────────────────────
# Safe when nothing is installed. Removes OUR registrations and OUR scripts, and nothing else:
# the backups the write guard made are the user's own data and are deliberately left behind.
uninstall_m3_hooks() {
  local d f i ev b keep=0 s
  d="$(m3_dir)"
  # OWNERSHIP IS THE DIRECTORY, NOT A FILENAME PREFIX. This used to match the hook scripts by
  # their old shared filename prefix, so renaming them silently stopped the uninstall unwiring
  # them: the registrations survived in the user's settings.json, pointing at scripts that had
  # just been deleted. The hooks directory is ours entirely — that is the fact, and a filename
  # convention nothing enforced was never it.
  bootstrap_hook_unwire "$(m3_cc)" "$d/" >/dev/null 2>&1

  # The Copilot file is ours by name (00-lifecycle.json). Remove it only if every entry in it is
  # ours; if a human added one, leave the file alone and say so rather than editing around them.
  f="$(m3_cop)"
  if [ -f "$f" ]; then
    for ev in $(bootstrap_hook_events "$f"); do
      i=0
      while [ "$i" -lt 64 ]; do
        b="$(bootstrap_settings_get "$f" "hooks.$ev.$i.bash" raw 2>/dev/null)" || break
        case "$b" in "$d/"*) : ;; *) keep=1 ;; esac
        i=$((i + 1))
      done
    done
    if [ "$keep" = 0 ]; then
      bootstrap_backup "$f"; rm -f "$f" 2>/dev/null
    else
      bootstrap_warn "m3: $f also holds hooks this bootstrap did not write — leaving it in place."
    fi
  fi

  for s in $(m3_scripts); do rm -f "$d/$s" 2>/dev/null; done
  rm -f "$d/bootstrap-lib.sh" "$d/copilot-hooks.json" 2>/dev/null
  rmdir "$d" 2>/dev/null || true
  rm -f "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/stop-count" \
        "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/last-ledger" 2>/dev/null
  return 0
}
