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

# 8. A standard user with no tmux and no Homebrew of their own: a plain sentence, and no brew to run.
#    PATH without tmux; the seam treats a Homebrew outside $HOME as an administrator's.
h="$(fresh_home agent-config-standard)"
HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_MANAGED_ROOT="$AGENT_CONFIG/none" BOOTSTRAP_ASSUME_STANDARD_USER=1 \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/env -u CLAUDE_CONFIG_DIR -u COPILOT_HOME \
  /bin/bash "$CHECK_ROOT/bootstrap.sh" --only handoff >/dev/null 2>&1
agent_config_expect "standard-user-no-tmux-says-why" "$h" handoff NEEDS_HUMAN "needs an administrator"
same "standard-user-gets-no-brew-gesture" "$(agent_config_row "$h" handoff human_command)" ""
#    CONTROL: the same run as an administrator whose Homebrew is writable DOES offer it — so the empty
#    gesture above is the standard-user rule speaking, not a gesture that can never appear.
AGENT_CONFIG_BREW="$(PATH=/usr/bin:/bin . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1; bootstrap_find_tool brew)" || AGENT_CONFIG_BREW=""
if [ -n "$AGENT_CONFIG_BREW" ] && [ -w "$(dirname "$AGENT_CONFIG_BREW")" ]; then
  h="$(fresh_home agent-config-admin)"
  HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_MANAGED_ROOT="$AGENT_CONFIG/none" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/env -u CLAUDE_CONFIG_DIR -u COPILOT_HOME -u BOOTSTRAP_ASSUME_STANDARD_USER \
    /bin/bash "$CHECK_ROOT/bootstrap.sh" --only handoff >/dev/null 2>&1
  case "$(agent_config_row "$h" handoff human_command)" in
    *"install tmux") pass "brew-owner-gets-brew-gesture" ;;
    *) fail "brew-owner-gets-brew-gesture" "[$(agent_config_row "$h" handoff human_command)]" ;;
  esac
else
  pass "brew-owner-gets-brew-gesture" "n/a: no Homebrew this account can write on this Mac"
fi

# 9. agent-handoff's own fixtures, including the routing allowlist and its credential controls.
if /bin/bash "$CHECK_ROOT/assets/agent-handoff" selftest >"$CHECK_WORK/agent-handoff-selftest" 2>&1; then
  pass "agent-handoff-selftest" "$(tail -1 "$CHECK_WORK/agent-handoff-selftest")"
else
  fail "agent-handoff-selftest" "$(grep FAIL "$CHECK_WORK/agent-handoff-selftest" | head -3 | tr '\n' ' ')"
fi

# 10. /handoff carries WHICH HOST and WHICH MODEL, not only which provider. The REAL ah_write_launcher
#     (the script with its command dispatch cut off) writes the launcher; the launcher then runs an
#     agent stand-in that prints its environment, so what is read back is what a successor receives.
AGENT_CONFIG_AH="$AGENT_CONFIG/handoff-route"
mkdir -p "$AGENT_CONFIG_AH/run"
sed '/^case "\${1:-status}" in/,$d' "$CHECK_ROOT/assets/agent-handoff" > "$AGENT_CONFIG_AH/lib.sh"
printf '#!/bin/bash\nexec /usr/bin/env\n' > "$AGENT_CONFIG_AH/envstub"; chmod 755 "$AGENT_CONFIG_AH/envstub"
AGENT_CONFIG_ROUTE="GH_HOST=acme.ghe.com COPILOT_GH_HOST=acme.ghe.com ANTHROPIC_MODEL=pin-model
  ANTHROPIC_DEFAULT_OPUS_MODEL=pin-opus ANTHROPIC_DEFAULT_SONNET_MODEL=pin-sonnet ANTHROPIC_DEFAULT_HAIKU_MODEL=pin-haiku
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000 GOOGLE_CLOUD_PROJECT=acme-project
  VERTEX_REGION_CLAUDE_4_0_OPUS=us-east5 VERTEX_REGION_CLAUDE_3_5_HAIKU=europe-west1"
# credential-shaped names under the family's prefix, and one variable on no list at all
AGENT_CONFIG_NOT="VERTEX_REGION_CLAUDE_API_KEY=planted-secret VERTEX_REGION_CLAUDE_X_TOKEN=planted-secret NOT_A_ROUTE=planted-other"
# agent_config_ah <extra env…> -- <shell snippet> — the snippet runs with the launcher's functions loaded
agent_config_ah() {
  local a=""
  while [ $# -gt 0 ] && [ "$1" != -- ]; do a="$a $1"; shift; done; shift
  # shellcheck disable=SC2086
  env -i HOME="$AGENT_CONFIG_AH/home" PATH=/usr/bin:/bin TMPDIR="$CHECK_WORK" $a \
    /bin/bash -c ". \"\$0\" && $1" "$AGENT_CONFIG_AH/lib.sh"
}
mkdir -p "$AGENT_CONFIG_AH/home"
# shellcheck disable=SC2086
agent_config_ah $AGENT_CONFIG_ROUTE $AGENT_CONFIG_NOT -- \
  "ah_write_launcher '$AGENT_CONFIG_AH/run' '$AGENT_CONFIG_AH/run/cfg' '$AGENT_CONFIG_AH/run' '$AGENT_CONFIG_AH/envstub' copilot SID 0 && '$AGENT_CONFIG_AH/run/launch.sh'" \
  > "$AGENT_CONFIG_AH/successor.env" 2>/dev/null
out=""
for p in $AGENT_CONFIG_ROUTE; do
  grep -qxF "export $p" "$AGENT_CONFIG_AH/run/env" 2>/dev/null || out="$out env-file:${p%%=*}"
  grep -qxF "$p" "$AGENT_CONFIG_AH/successor.env" 2>/dev/null || out="$out successor:${p%%=*}"
done
same "handoff-carries-host-and-model-routing" "${out:-all 10 arrived}" "all 10 arrived"
case "$(grep -c 'VERTEX_REGION_CLAUDE_' "$AGENT_CONFIG_AH/successor.env" 2>/dev/null)" in
  2) pass "handoff-carries-vertex-region-family" "2 members, matched by prefix" ;;
  *) fail "handoff-carries-vertex-region-family" "$(grep -o '^VERTEX_REGION_CLAUDE_[A-Z0-9_]*' "$AGENT_CONFIG_AH/successor.env" | tr '\n' ' ')" ;;
esac
if grep -q 'planted-secret' "$AGENT_CONFIG_AH/successor.env" "$AGENT_CONFIG_AH/run/env" "$AGENT_CONFIG_AH/run/launch.sh" 2>/dev/null; then
  fail "handoff-drops-credential-shaped-family" "a VERTEX_REGION_CLAUDE_*_KEY/_TOKEN value was carried"
else pass "handoff-drops-credential-shaped-family" "_API_KEY and _TOKEN under the prefix stay behind"; fi
# CONTROL: a variable on no list stays behind, so the arrivals above are the allowlist, not a leak
if grep -q 'planted-other' "$AGENT_CONFIG_AH/successor.env" 2>/dev/null; then fail "handoff-unlisted-variable-stays-behind"
else pass "handoff-unlisted-variable-stays-behind"; fi
agent_config_ah -- \
  "AH_PASS_ENV='ANTHROPIC_DEFAULT_OPUS_MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS VERTEX_REGION_CLAUDE_4_0_OPUS' ah_write_launcher '$AGENT_CONFIG_AH/run' '$AGENT_CONFIG_AH/run/cfg' '$AGENT_CONFIG_AH/run' /bin/echo claude SID 0" >/dev/null 2>&1
same "handoff-pass-env-of-carried-name-rc0" "$?" 0
# CONTROL: the refusal is still there for the session marker the scrub exists to stop
agent_config_ah -- \
  "AH_PASS_ENV=CLAUDE_CODE_SESSION_ID ah_write_launcher '$AGENT_CONFIG_AH/run' '$AGENT_CONFIG_AH/run/cfg' '$AGENT_CONFIG_AH/run' /bin/echo claude SID 0" >/dev/null 2>&1
same "handoff-pass-env-still-refuses-session-marker" "$?" 2

# 11. The route report names the GitHub host Copilot will use and Copilot's fully local route. Both
#     are ok lines: a GitHub Enterprise host is Copilot's own vendor, so the exit code stays 0.
mkdir -p "$AGENT_CONFIG/local-home"
agent_config_local() {                          # agent_config_local <VAR=value…> → stdout; CHECK_RC
  env -i HOME="$AGENT_CONFIG/local-home" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$CHECK_WORK" "$@" \
    /bin/bash "$CHECK_ROOT/assets/local-only-check.sh" --only agents 2>/dev/null
}
agent_config_local_has() {                      # agent_config_local_has <check> <output> <ERE>
  if printf '%s\n' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1" "no line matches [$3]: $(printf '%s' "$2" | tr '\n' '|')"; fi
}
out="$(agent_config_local GH_HOST=acme.ghe.com)"; rc=$?
agent_config_local_has "route-report-names-ghe-host" "$out" '^    ok    environment GH_HOST — Copilot signs in to acme\.ghe\.com'
same "route-report-ghe-host-is-not-a-finding" "$rc" 0
out="$(agent_config_local GH_HOST=ghes.example.com COPILOT_GH_HOST=https://acme.ghe.com)"
agent_config_local_has "route-report-copilot-gh-host-wins" "$out" '^    ok    environment COPILOT_GH_HOST — Copilot signs in to acme\.ghe\.com.*GH_HOST \(ghes\.example\.com\) is for gh'
out="$(agent_config_local GH_HOST=https://someone:hunter2@acme.ghe.com)"
case "$out" in *hunter2*|*someone*) fail "route-report-host-drops-userinfo" "userinfo reached the output" ;;
               *) pass "route-report-host-drops-userinfo" ;; esac
out="$(agent_config_local COPILOT_OFFLINE=true COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:11434/v1)"; rc=$?
agent_config_local_has "route-report-names-offline-local-route" "$out" "^    ok    environment COPILOT_OFFLINE — Copilot's fully local route"
same "route-report-offline-is-not-a-finding" "$rc" 0
# CONTROL: offline with a provider off this Mac is not called fully local
out="$(agent_config_local COPILOT_OFFLINE=true COPILOT_PROVIDER_BASE_URL=https://gateway.example.com/v1)"
if printf '%s\n' "$out" | grep -q 'fully local'; then fail "route-report-remote-provider-not-fully-local" "$out"
else agent_config_local_has "route-report-remote-provider-not-fully-local" "$out" '^    ok    environment COPILOT_OFFLINE — offline mode: .*gateway\.example\.com'; fi
# NEGATIVE CONTROL: with neither exported, neither line appears
out="$(agent_config_local)"
same "route-report-neither-set-prints-neither" "$(printf '%s\n' "$out" | grep -cE 'GH_HOST|COPILOT_OFFLINE')" 0

# 12. clearance_<m>: each of the five config modules declares what IT usually governs, one line per
#     thing, each line opening with a class from the fixed set. Absent is UNDECLARED, so absence fails.
agent_config_clearance_ok() {                   # stdin: clearance lines → rc 0 iff every line is well formed
  local l bad=0
  while IFS= read -r l; do
    case "$l" in data\ ?*|background\ ?*|trust\ ?*|permission\ ?*|software\ ?*|agent\ ?*) : ;; *) bad=1 ;; esac
  done
  return "$bad"
}
# CONTROL: the shape test can say no
if printf 'agent a real line\nnetwork not a class\n' | agent_config_clearance_ok; then fail "clearance-shape-test-can-say-no"
else pass "clearance-shape-test-can-say-no"; fi
for m in statusline:agent instructions: hooks:agent handoff:agent,permission reporting_off:; do
  want="${m#*:}"; m="${m%%:*}"
  # shellcheck source=/dev/null
  out="$( ( . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1; . "$CHECK_ROOT/modules/$m.sh" >/dev/null 2>&1
            command -v "clearance_$m" >/dev/null || { echo UNDECLARED; exit 0; }; "clearance_$m" ) 2>/dev/null)"
  if [ "$out" = UNDECLARED ]; then fail "clearance-$m-declared" "no clearance_$m"; continue; fi
  if ! printf '%s\n' "$out" | sed '/^$/d' | agent_config_clearance_ok; then fail "clearance-$m-well-formed" "$out"; continue; fi
  got="$(printf '%s\n' "$out" | sed '/^$/d' | cut -d' ' -f1 | sort -u | tr '\n' ',' | sed 's/,$//')"
  same "clearance-$m-classes" "$got" "$want"
done
