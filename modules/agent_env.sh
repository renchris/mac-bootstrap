# shellcheck shell=bash
# modules/agent_env.sh — the environment this Mac's coding agent runs in, written down.
#
# A fresh install and this author's Mac install the same agent and then behave differently under
# load, because the difference is not in what is installed but in four environment variables. They
# go in the `env` block of $HOME/.claude/settings.json, which Claude Code applies to every session
# and every process it starts (documented). This module writes that block and nothing else.
#
#   MCP_TIMEOUT          how long an MCP server gets to START. Documented default 30000 ms. On a
#                        corporate network a TLS-inspecting proxy adds a handshake to every
#                        connection and an npx/uvx server fetches its package on first run, so 30 s
#                        is exactly where a slow network stops looking slow and starts looking dead.
#                        60 s doubles the budget and still reports a genuinely dead server inside a
#                        minute.
#   MCP_TOOL_TIMEOUT     how long one MCP tool CALL gets. The two documents disagree about the
#                        default — the environment-variable reference says 300000 ms, the MCP page
#                        says "about 28 hours" when the variable is unset — so under one reading
#                        600000 raises the ceiling and under the other it lowers one that is
#                        effectively absent. That disagreement IS the reason to set it: an explicit
#                        ten minutes is a number this Mac can predict, and it is far below the
#                        2147483647 maximum above which the documented behaviour is that the timer
#                        overflows and calls fail immediately. One server that genuinely needs
#                        longer keeps its own `timeout` field in .mcp.json, which the documentation
#                        says overrides this variable for that server alone — so a ten-minute
#                        ceiling here never becomes the ceiling for the one tool that needs an hour.
#   CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH
#                        intended to stop a subagent spawning subagents without bound. ⚠️ WE COULD
#                        NOT CONFIRM THIS ONE READS ANYTHING. It is absent from the documented
#                        environment-variable reference, and absent from every Claude Code package
#                        on this machine (2.1.113, 2.1.114, 2.1.183) — no `SPAWN_DEPTH` string at
#                        all — while the same grep in the same files finds DISABLE_AUTOUPDATER,
#                        MCP_TIMEOUT and four other CLAUDE_*SUBAGENT* names, so the instrument can
#                        say yes. Writing an env key no binary reads is inert, not harmful, and it
#                        is what this author's shell exports; it is written here so the setting is
#                        in one declared place rather than a login script. Do NOT read it as a
#                        bound that is known to hold.
#   DISABLE_AUTOUPDATER  OPT-IN ONLY, and off unless BOOTSTRAP_PIN_AGENT_VERSION is set. Freezing
#                        the version of somebody's agent is a decision with a security tail, and it
#                        is theirs, not ours. Set that variable and this module pins; leave it and
#                        the key is never written and never removed.
#
# COPILOT CLI: nothing is written for it. Copilot CLI documents no equivalent of any of these four,
# and this repo does not invent a key to write into another vendor's settings file. --egress and
# this comment say so rather than leaving the silence to be read as parity.
#
# THE VALUE IS THE DELIVERABLE, so unlike reporting_off.sh — where any non-empty value achieves the
# goal and overwriting would be gratuitous — this module writes its own value even over an existing
# one. bootstrap_settings_merge backs the file up before it does. uninstall_ still removes only a
# key that STILL holds our value: change one afterwards and it is yours, and we leave it alone.

AGENT_ENV_MCP_TIMEOUT=60000                        # ms — MCP server start-up; documented default 30000
AGENT_ENV_MCP_TOOL_TIMEOUT=600000                  # ms — one MCP tool call; see the header on the two defaults
AGENT_ENV_SPAWN_DEPTH=1                            # subagent nesting; unconfirmed, see the header
AGENT_ENV_AUTOUPDATER=1                            # only ever written when BOOTSTRAP_PIN_AGENT_VERSION is set

AGENT_ENV_ALWAYS="MCP_TIMEOUT MCP_TOOL_TIMEOUT CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"
AGENT_ENV_OPTIN="DISABLE_AUTOUPDATER"              # armed by BOOTSTRAP_PIN_AGENT_VERSION, never by default

agent_env_settings() { printf '%s/.claude/settings.json' "$HOME"; }

# The value for a key, in one place. A key with no case arm prints nothing, and every caller treats
# an empty want as "not ours" — so a typo in a key list can never write or remove an empty value.
agent_env_value() {
  case "${1:-}" in
    MCP_TIMEOUT)                            printf '%s' "$AGENT_ENV_MCP_TIMEOUT" ;;
    MCP_TOOL_TIMEOUT)                       printf '%s' "$AGENT_ENV_MCP_TOOL_TIMEOUT" ;;
    CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH)   printf '%s' "$AGENT_ENV_SPAWN_DEPTH" ;;
    DISABLE_AUTOUPDATER)                    printf '%s' "$AGENT_ENV_AUTOUPDATER" ;;
  esac
}

# The keys THIS run is responsible for. The opt-in one joins only when the operator armed it.
agent_env_keys() {
  printf '%s' "$AGENT_ENV_ALWAYS"
  [ -n "${BOOTSTRAP_PIN_AGENT_VERSION:-}" ] && printf ' %s' "$AGENT_ENV_OPTIN"
  printf '\n'
}

# Keys IT pins in its own managed settings, which sit ABOVE user settings in the documented
# precedence — so a key named there makes our write inert, and a module whose write is ignored must
# never report SATISFIED. Read through the policy reader, which reads the files the agent reads.
agent_env_managed() {
  local k out=""
  for k in $(agent_env_keys); do
    bootstrap_policy claude "env.$k" raw >/dev/null 2>&1 && out="$out $k"
  done
  printf '%s' "${out# }"
}

# The read-back, and the engine of verify_ and note_. bootstrap_settings_get is plutil-only, so it
# is a different engine from the jq the merger prefers — and it compares the VALUE, not the key.
agent_env_wrong() {
  local k want got out=""
  local f; f="$(agent_env_settings)"
  for k in $(agent_env_keys); do
    want="$(agent_env_value "$k")"
    [ -n "$want" ] || continue
    got="$(bootstrap_settings_get "$f" "env.$k" raw 2>/dev/null)" || got=""
    [ "$got" = "$want" ] || out="$out $k"
  done
  printf '%s' "${out# }"
}

what_agent_env() { printf '%s' "gives the coding agent the environment this Mac runs it with: MCP start-up and tool-call timeouts long enough for a proxied corporate network, a declared subagent nesting depth, and — only if you ask — a pinned agent version"; }
cost_agent_env() { printf '%s' "up to four keys in Claude Code's settings. No installs, no downloads, no permissions, nothing at login. Reversible: uninstall removes only a key that still holds our value. Nothing is written for Copilot CLI, which documents no equivalent."; }
profile_agent_env() { printf '%s' 'lite'; }
egress_agent_env() { :; }
# Declared empty, deliberately: it writes settings keys. Nothing runs, nothing is downloaded, and
# these keys only change how long the agent WAITS on connections it was already going to make.
clearance_agent_env() {
  printf '%s\n' "agent sets the environment the coding agent and every process it starts run with (MCP timeouts, subagent nesting depth)"
  [ -n "${BOOTSTRAP_PIN_AGENT_VERSION:-}" ] && printf '%s\n' "agent pins the agent's version by switching its autoupdater off, so security fixes arrive only when someone updates it by hand"
  return 0
}

verify_agent_env() { [ -z "$(agent_env_wrong)" ]; }

# The one gesture-free gate in this module: IT reserving a key we would write. There is no command
# to print — it is a conversation with whoever manages this Mac — so gesture_ stays empty.
gate_agent_env() { [ -n "$(agent_env_managed)" ]; }
note_agent_env() {
  local m; m="$(agent_env_managed)"
  if [ -n "$m" ]; then
    printf 'your organisation pins these in managed settings, which override yours: %s' "$m"
  else
    printf 'the agent environment is not set here yet: %s' "$(agent_env_wrong)"
  fi
}
gesture_agent_env() { :; }

install_agent_env() {
  local k want f rc=0
  f="$(agent_env_settings)"
  for k in $(agent_env_wrong); do
    want="$(agent_env_value "$k")"
    [ -n "$want" ] || continue
    # A string, because Claude Code's `env` block is string→string — a bare 60000 would be a number.
    bootstrap_settings_merge "$f" "env.$k" "\"$(bootstrap_json_escape "$want")\"" || rc=1
  done
  return "$rc"
}

# Removes exactly what install_ wrote. The full set, not agent_env_keys, so a pin installed while
# BOOTSTRAP_PIN_AGENT_VERSION was set is still removed after it is unset — and safe either way,
# because a key whose value is no longer ours was changed by someone else and is left alone.
uninstall_agent_env() {
  local k want got f rc=0
  f="$(agent_env_settings)"
  [ -f "$f" ] || return 0
  for k in $AGENT_ENV_ALWAYS $AGENT_ENV_OPTIN; do
    want="$(agent_env_value "$k")"
    [ -n "$want" ] || continue
    got="$(bootstrap_settings_get "$f" "env.$k" raw 2>/dev/null)" || continue
    [ "$got" = "$want" ] || continue
    bootstrap_settings_remove "$f" "env.$k" || rc=1
  done
  # And leave behind no empty container of ours. `env` goes only when our keys were the last thing
  # in it — a key of the user's own keeps the whole block. Read through the plutil getter, so what
  # decides is the file's actual shape and not a count of what this function just did.
  case "$(bootstrap_settings_get "$f" env json 2>/dev/null | /usr/bin/tr -d ' \n\t')" in
    '{}') bootstrap_settings_remove "$f" env || rc=1 ;;
  esac
  return "$rc"
}
