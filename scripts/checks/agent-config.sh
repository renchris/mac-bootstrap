# shellcheck shell=bash
# scripts/checks/agent-config.sh — a company policy (or the user's own setting) that switches off what
# statusline, hooks, instructions or handoff install must turn their row NEEDS_HUMAN, naming the policy,
# with no gesture — never SATISFIED over files the agent ignores. Sourced by scripts/characterize.sh,
# which supplies the harness; never run on its own.
#
# Every policy file is a fixture under $CHECK_TMP, reached through BOOTSTRAP_MANAGED_ROOT; the "no
# policy" control points that root at an EMPTY fixture rather than at the real /Library, and
# CLAUDE_CONFIG_DIR is dropped so the real server-managed cache can never answer for the sandbox.

AGENT_CONFIG="$CHECK_TMP/agent-config"
AGENT_CONFIG_CLAUDE="Library/Application Support/ClaudeCode/managed-settings.json"
AGENT_CONFIG_COPILOT="Library/Application Support/GitHubCopilot/managed-settings.json"
mkdir -p "$AGENT_CONFIG/none" "$AGENT_CONFIG/bin"
# a tmux stand-in, so handoff's "no policy" control does not depend on this Mac having tmux
printf '#!/bin/sh\nexit 0\n' > "$AGENT_CONFIG/bin/tmux"; chmod 755 "$AGENT_CONFIG/bin/tmux"

# agent_config_policy <name> <claude|copilot> <json> — a managed root holding one policy file; prints it.
agent_config_policy() {
  local r="$AGENT_CONFIG/$1" f
  case "$2" in claude) f="$r/$AGENT_CONFIG_CLAUDE" ;; *) f="$r/$AGENT_CONFIG_COPILOT" ;; esac
  mkdir -p "$(dirname "$f")" && printf '%s\n' "$3" > "$f"
  printf '%s' "$r"
}

# agent_config_drive <home> <managed-root> <args…> — the driver, sandboxed, with the given IT policy.
agent_config_drive() {
  local h="$1" m="$2"; shift 2
  HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_MANAGED_ROOT="$m" PATH="$AGENT_CONFIG/bin:$PATH" \
    /usr/bin/env -u CLAUDE_CONFIG_DIR -u COPILOT_HOME /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" >"$CHECK_WORK/agent-config.out" 2>&1
  CHECK_RC=$?
}

# agent_config_row <home> <module> <state|note|human_command> — one field of one receipt row.
agent_config_row() {
  local f="$1/.mac-bootstrap/receipt.json" i=0 m
  while [ "$i" -lt 64 ]; do
    m="$(json_at "$f" "modules.$i.module")" || return 1
    [ "$m" = "$2" ] && { json_at "$f" "modules.$i.$3"; return $?; }
    i=$((i + 1))
  done
  return 1
}

# agent_config_expect <check> <home> <module> <state> [note-must-contain] [note-must-not-contain]
agent_config_expect() {
  local st note
  st="$(agent_config_row "$2" "$3" state)" || st="(no row)"
  note="$(agent_config_row "$2" "$3" note)" || note=""
  if [ "$st" != "$4" ]; then fail "$1" "$3 is $st, want $4 — $note"; return 0; fi
  case "$note" in *"${5:-}"*) : ;; *) fail "$1" "$3 note does not name [$5]: $note"; return 0 ;; esac
  if [ -n "${6:-}" ]; then case "$note" in *"$6"*) fail "$1" "$3 note names [$6]: $note"; return 0 ;; esac; fi
  pass "$1" "$3 $st"
}

AGENT_CONFIG_ALL="statusline,hooks,instructions,handoff"

# 1. NEGATIVE CONTROL — the same sandbox with no policy: all four SATISFIED, so every NEEDS_HUMAN
#    below is the policy's doing and not the sandbox's.
h="$(fresh_home agent-config-open)"
agent_config_drive "$h" "$AGENT_CONFIG/none" --only "$AGENT_CONFIG_ALL"
for m in statusline hooks instructions handoff; do
  agent_config_expect "no-policy-$m-satisfied" "$h" "$m" SATISFIED
done
same "no-policy-exits-0" "$CHECK_RC" 0

# 2. Claude Code reserves hooks to IT: both the hooks and the status line never run. Empty gesture.
h="$(fresh_home agent-config-hooks-only)"
r="$(agent_config_policy hooks-only claude '{"allowManagedHooksOnly": true}')"
agent_config_drive "$h" "$r" --only "statusline,hooks"
agent_config_expect "managed-hooks-only-fails-statusline" "$h" statusline NEEDS_HUMAN "allowManagedHooksOnly"
agent_config_expect "managed-hooks-only-fails-hooks" "$h" hooks NEEDS_HUMAN "allowManagedHooksOnly"
same "managed-policy-has-no-gesture" "$(agent_config_row "$h" hooks human_command)" ""
same "managed-policy-exits-10" "$CHECK_RC" 10

# 3. The same key on COPILOT fails only the Copilot half: hooks names Copilot and not Claude Code, and
#    the status line (no Copilot gate on it is known) is not claimed either way — it stays SATISFIED.
h="$(fresh_home agent-config-copilot)"
r="$(agent_config_policy copilot-hooks copilot '{"allowManagedHooksOnly": true}')"
agent_config_drive "$h" "$r" --only "statusline,hooks"
agent_config_expect "copilot-policy-names-only-copilot" "$h" hooks NEEDS_HUMAN "Copilot CLI" "Claude Code"
agent_config_expect "copilot-policy-leaves-statusline" "$h" statusline SATISFIED

# 4. A list names what it reserves: ["mcp"] leaves the hooks alone …
h="$(fresh_home agent-config-mcp-list)"
r="$(agent_config_policy mcp-list claude '{"strictPluginOnlyCustomization": ["mcp"]}')"
agent_config_drive "$h" "$r" --only hooks
agent_config_expect "mcp-lockdown-does-not-fail-hooks" "$h" hooks SATISFIED
#    … and ["skills"] takes /handoff's command away while the hooks keep running.
h="$(fresh_home agent-config-skills-list)"
r="$(agent_config_policy skills-list claude '{"strictPluginOnlyCustomization": ["skills"]}')"
agent_config_drive "$h" "$r" --only "hooks,handoff"
agent_config_expect "skills-lockdown-fails-handoff" "$h" handoff NEEDS_HUMAN "strictPluginOnlyCustomization"
agent_config_expect "skills-lockdown-leaves-hooks" "$h" hooks SATISFIED

# 5. The instructions file excluded by IT; an exclusion that matches something else changes nothing.
h="$(fresh_home agent-config-md-excluded)"
r="$(agent_config_policy md-excluded claude '{"claudeMdExcludes": ["~/.claude/CLAUDE.md"]}')"
agent_config_drive "$h" "$r" --only instructions
agent_config_expect "claude-md-exclude-fails-instructions" "$h" instructions NEEDS_HUMAN "claudeMdExcludes"
h="$(fresh_home agent-config-md-elsewhere)"
r="$(agent_config_policy md-elsewhere claude '{"claudeMdExcludes": ["/somewhere/else/**"]}')"
agent_config_drive "$h" "$r" --only instructions
agent_config_expect "unrelated-exclude-leaves-instructions" "$h" instructions SATISFIED

# 6. A policy computed by IT's helper program cannot be read, so it is never SATISFIED.
h="$(fresh_home agent-config-helper)"
r="$(agent_config_policy helper claude '{"policyHelper": {"path": "/usr/local/bin/it-policy"}}')"
agent_config_drive "$h" "$r" --only hooks
agent_config_expect "policy-helper-is-never-satisfied" "$h" hooks NEEDS_HUMAN "policyHelper"

# 7. The user's OWN disableAllHooks — no IT at all. The gesture shows the setting; it never edits it.
h="$(fresh_home agent-config-user-off)"
mkdir -p "$h/.claude" && printf '{"disableAllHooks": true}\n' > "$h/.claude/settings.json"
agent_config_drive "$h" "$AGENT_CONFIG/none" --only hooks
agent_config_expect "user-disable-all-hooks-fails-hooks" "$h" hooks NEEDS_HUMAN "disableAllHooks"
same "user-disable-gesture-shows-it" "$(agent_config_row "$h" hooks human_command)" 'grep -n disableAllHooks "$HOME/.claude/settings.json"'
if [ "$(json_at "$h/.claude/settings.json" disableAllHooks)" = true ]; then pass "user-disable-left-as-it-was"
else fail "user-disable-left-as-it-was" "the user's disableAllHooks was changed"; fi

# 9. agent-handoff's own fixtures, including the routing allowlist and its credential controls.
if /bin/bash "$CHECK_ROOT/assets/agent-handoff" selftest >"$CHECK_WORK/agent-handoff-selftest" 2>&1; then
  pass "agent-handoff-selftest" "$(tail -1 "$CHECK_WORK/agent-handoff-selftest")"
else
  fail "agent-handoff-selftest" "$(grep FAIL "$CHECK_WORK/agent-handoff-selftest" | head -3 | tr '\n' ' ')"
fi
