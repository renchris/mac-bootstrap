# shellcheck shell=bash
# scripts/checks/agent-env.sh — the agent environment block. Sourced by scripts/characterize.sh.
#
# The module's whole deliverable is a VALUE, not a key, so every assertion here reads the value back
# with plutil — a different engine from the jq the merger prefers — and the negative control changes
# a value rather than removing a key, because a verifier that only notices absence would pass a Mac
# whose MCP timeout someone had set to two seconds.

if [ -r "$CHECK_ROOT/modules/agent_env.sh" ]; then
  h="$(fresh_home agentenv)"

  # A pre-existing value of OURS is overwritten (the value is the deliverable); an unrelated key is not.
  mkdir -p "$h/.claude" && printf '{"env": {"MCP_TIMEOUT": "2000", "KEEP_ME": "mine"}, "theme": "dark"}\n' > "$h/.claude/settings.json"
  drive_at "$h" --only agent_env
  same "agent-env-install-rc" "$CHECK_RC" 0
  same "agent-env-values-read-back" \
    "$(json_at "$h/.claude/settings.json" env.MCP_TIMEOUT)/$(json_at "$h/.claude/settings.json" env.MCP_TOOL_TIMEOUT)/$(json_at "$h/.claude/settings.json" env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH)" \
    "60000/600000/1"
  same "agent-env-keeps-what-is-not-ours" \
    "$(json_at "$h/.claude/settings.json" env.KEEP_ME)/$(json_at "$h/.claude/settings.json" theme)" "mine/dark"

  # The opt-in is OFF by default: the pin is never written unless the operator asks for it.
  same "agent-env-autoupdater-is-opt-in" \
    "$(json_at "$h/.claude/settings.json" env.DISABLE_AUTOUPDATER || printf absent)" "absent"

  AE_SUM="$(shasum -a 256 "$h/.claude/settings.json" | cut -d' ' -f1)"
  drive_at "$h" --only agent_env
  same "agent-env-second-run-changes-nothing" "$(shasum -a 256 "$h/.claude/settings.json" | cut -d' ' -f1)" "$AE_SUM"

  # NEGATIVE CONTROL: a key that is PRESENT but holds someone else's value must fail verify.
  plutil -replace env.MCP_TOOL_TIMEOUT -string 5000 "$h/.claude/settings.json" >/dev/null 2>&1
  HOME="$h" /bin/bash "$CHECK_ROOT/bootstrap.sh" --verify --only agent_env >/dev/null 2>&1; CHECK_RC=$?
  same "agent-env-verify-sees-a-wrong-value" "$CHECK_RC" 20
  drive_at "$h" --only agent_env
  same "agent-env-reinstall-repairs-the-value" "$(json_at "$h/.claude/settings.json" env.MCP_TOOL_TIMEOUT)" "600000"

  # Armed, the pin is written and verified; a cold verify from a separate process agrees.
  HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_PIN_AGENT_VERSION=1 \
    /bin/bash "$CHECK_ROOT/bootstrap.sh" --only agent_env >/dev/null 2>&1; CHECK_RC=$?
  same "agent-env-armed-install-rc" "$CHECK_RC" 0
  same "agent-env-armed-writes-the-pin" "$(json_at "$h/.claude/settings.json" env.DISABLE_AUTOUPDATER)" "1"
  HOME="$h" BOOTSTRAP_PIN_AGENT_VERSION=1 /bin/bash "$CHECK_ROOT/verify.sh" --only agent_env >/dev/null 2>&1
  same "agent-env-cold-verify-agrees" "$?" "0"

  # Uninstall removes exactly ours — including a pin armed by a variable that is no longer set —
  # and leaves a value someone changed afterwards alone.
  plutil -replace env.MCP_TIMEOUT -string 45000 "$h/.claude/settings.json" >/dev/null 2>&1
  drive_at "$h" --uninstall --only agent_env
  same "agent-env-uninstall-removes-only-ours" \
    "$(json_at "$h/.claude/settings.json" env.MCP_TIMEOUT)/$(json_at "$h/.claude/settings.json" env.MCP_TOOL_TIMEOUT || printf gone)/$(json_at "$h/.claude/settings.json" env.DISABLE_AUTOUPDATER || printf gone)/$(json_at "$h/.claude/settings.json" env.KEEP_ME)" \
    "45000/gone/gone/mine"

  # Where OUR keys were the only thing in `env`, the emptied block goes too — a module must leave
  # no container it created. The arm above is the control: there KEEP_ME survives, so `env` stays.
  h4="$(fresh_home agentenv-prune)"
  drive_at "$h4" --only agent_env
  drive_at "$h4" --uninstall --only agent_env
  same "agent-env-uninstall-prunes-the-block-it-made" \
    "$(tr -d ' \n\t' < "$h4/.claude/settings.json")" "{}"

  # Uninstall is safe on a Mac where nothing was ever installed.
  h2="$(fresh_home agentenv-bare)"
  drive_at "$h2" --uninstall --only agent_env
  same "agent-env-uninstall-on-a-bare-mac" "$CHECK_RC" 0

  # IT pinning one of our keys is NEEDS_HUMAN (10), never SATISFIED — our write would be ignored.
  h3="$(fresh_home agentenv-managed)"; AE_MR="$CHECK_TMP/managed-agentenv"
  mkdir -p "$AE_MR/Library/Application Support/ClaudeCode"
  printf '{"env": {"MCP_TIMEOUT": "9000"}}\n' > "$AE_MR/Library/Application Support/ClaudeCode/managed-settings.json"
  HOME="$h3" TMPDIR="$CHECK_WORK" BOOTSTRAP_MANAGED_ROOT="$AE_MR" \
    /bin/bash "$CHECK_ROOT/bootstrap.sh" --only agent_env >/dev/null 2>&1; CHECK_RC=$?
  same "agent-env-managed-key-is-needs-human" "$CHECK_RC" 10
  same "agent-env-managed-mac-is-not-written" \
    "$(json_at "$h3/.claude/settings.json" env.MCP_TIMEOUT || printf absent)" "absent"
fi
