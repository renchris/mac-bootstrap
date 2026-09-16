# shellcheck shell=bash
# microsoft365_archive — every Teams meeting you attend, and your Copilot upload folder, kept as
# markdown in one folder on this Mac, refreshed hourly by a LaunchAgent.
#
# WHAT IT INSTALLS
#   $BOOTSTRAP_STATE_DIR/microsoft365-archive/   the archive engine (node, zero dependencies:
#                                                archive.js, render.js, resolve.js, the offline
#                                                fake-server.js and its fixtures/), the shared
#                                                converter markdown-convert.sh, and `config`
#   $BOOTSTRAP_STATE_DIR/bin/microsoft365-archive a wrapper that runs the pinned node on archive.js
#                                                with MICROSOFT365_ARCHIVE_CONFIG pointing at config
#   $HOME/Library/LaunchAgents/com.mac-bootstrap.microsoft365-archive.plist
#                                                [wrapper, run] at minute 7 of every hour, and at load;
#                                                with BOOTSTRAP_MICROSOFT365_ARCHIVE_SCHEDULE=off, no
#                                                trigger at all (run it with launchctl kickstart)
#   the archive folder itself                    BOOTSTRAP_ARCHIVE_DIR, default $HOME/Microsoft365Archive
#
# THE ARCHIVE IS A COPY. Transcripts, chats, notes, AI notes and Copilot files land here as markdown,
# where the tenant's DLP, retention and eDiscovery no longer reach them. cost_ and clearance_ say so
# first, and uninstall_ keeps the folder (it is the person's data) but names it and the command that
# removes it.
#
# HOW IT TALKS TO MICROSOFT: it does not, directly. The engine starts a Softeria server over stdio,
# exactly as an agent does, and asks it only for Graph GETs — the engine refuses any other tool, any
# non-GET batch request and any /special/ path before every call, because a launchd job never passes
# the agent's PreToolUse guard. WHICH server, in order: the one BOOTSTRAP_MICROSOFT_SERVER names; the
# one the microsoft365 module installed; the ms365 server an agent already runs, read (never written)
# from $HOME/.claude.json. A Mac whose agent already runs Softeria's server keeps its registration and
# its tenant, and the archive signs in the way that agent does. Each candidate is accepted only when
# it RUNS as the server. The sign-in is the server's own; this module never reads a token and never
# writes one.
#
# WHY THE LAUNCHD LOAD IS REFUSED UNDER A SANDBOXED HOME: `launchctl bootstrap gui/<uid>` acts on the
# REAL per-user launchd domain whatever $HOME says — the same escape class as `defaults`, which
# bootstrap_defaults_home_ok already guards. `HOME=$(mktemp -d) bash bootstrap.sh` is the documented
# test, so without the refusal every test run would leave a job in the real domain pointing into a
# temp dir. Under a foreign HOME the files land (they are inside that HOME) and the load is reported
# as NEEDS_HUMAN; BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 is the same deliberate override defaults honours.
#
# THE ARCHIVE FOLDER IS REFUSED INSIDE A SYNC CLIENT'S TREE ($HOME/Library/CloudStorage, iCloud's
# $HOME/Library/Mobile Documents): client meeting content written there would be re-uploaded to
# wherever that folder syncs. Judged on the real path of the deepest ancestor that exists, so a
# symlink into a synced folder is caught too.
#
# bash 3.2 · set -u, no set -e · every verb runs in its own subshell, so nothing survives between
# verbs and everything below re-derives what it needs. No permission, allow-list or credential is
# written anywhere in this file.

MICROSOFT365_ARCHIVE_LABEL="com.mac-bootstrap.microsoft365-archive"
MICROSOFT365_ARCHIVE_VERSION_LINE="microsoft365-archive 1"
MICROSOFT365_ARCHIVE_ENGINE_FILES="archive.js render.js resolve.js fake-server.js"
MICROSOFT365_ARCHIVE_PERSONAL_TENANT="9188040d-6c67-4c5b-b112-36a304b66dad"   # every personal Microsoft account
# Minute past the hour. StartCalendarInterval, not StartInterval: an interval missed while the Mac
# sleeps is dropped, a calendar slot coalesces into one run at the next wake.
MICROSOFT365_ARCHIVE_MINUTE=7

# ── paths, re-derived per verb ───────────────────────────────────────────────────────────────
microsoft365_archive_state_dir() { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
microsoft365_archive_dir()       { printf '%s/microsoft365-archive' "$(microsoft365_archive_state_dir)"; }
microsoft365_archive_wrapper()   { printf '%s/bin/microsoft365-archive' "$(microsoft365_archive_state_dir)"; }
microsoft365_archive_config()    { printf '%s/config' "$(microsoft365_archive_dir)"; }
microsoft365_archive_converter() { printf '%s/markdown-convert.sh' "$(microsoft365_archive_dir)"; }
microsoft365_archive_log()       { printf '%s/launchd.log' "$(microsoft365_archive_dir)"; }
microsoft365_archive_plist()     { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$MICROSOFT365_ARCHIVE_LABEL"; }
microsoft365_archive_domain()    { printf 'gui/%s' "$(/usr/bin/id -u)"; }
# The microsoft365 module's server, and the key it registers under. Its module file cannot be sourced
# from here (each verb sources only its own module), so both are re-derived the way that module spells
# them. Which server the archive actually uses is microsoft365_archive_server, further down.
microsoft365_archive_module_server() { printf '%s/microsoft365/node_modules/@softeria/ms-365-mcp-server/dist/index.js' "$(microsoft365_archive_state_dir)"; }
MICROSOFT365_ARCHIVE_REGISTRATION_KEY="ms365"
MICROSOFT365_ARCHIVE_SERVER_TAIL="/@softeria/ms-365-mcp-server/dist/index.js"
microsoft365_archive_agent_config()  { printf '%s/.claude.json' "${CLAUDE_CONFIG_DIR:-$HOME}"; }

# The choices a person made through the environment, recorded at install so a cold verify with no
# environment agrees. Written only when the variable is set, so a re-run without it never resets
# a choice made earlier.
microsoft365_archive_chosen_root_file()    { printf '%s/chosen-archive-dir' "$(microsoft365_archive_dir)"; }
microsoft365_archive_chosen_account_file() { printf '%s/chosen-account' "$(microsoft365_archive_dir)"; }
microsoft365_archive_chosen_server_file()  { printf '%s/chosen-server' "$(microsoft365_archive_dir)"; }
microsoft365_archive_chosen_schedule_file() { printf '%s/chosen-schedule' "$(microsoft365_archive_dir)"; }

# The schedule: `hourly` (the default — minute 7 of every hour, and at login) or `off`, where the
# LaunchAgent is loaded with no trigger at all and runs only when the person starts it
# (BOOTSTRAP_MICROSOFT365_ARCHIVE_SCHEDULE=off). Any other value is hourly.
microsoft365_archive_schedule() {
  local v f
  v="${BOOTSTRAP_MICROSOFT365_ARCHIVE_SCHEDULE:-}"
  if [ -z "$v" ]; then f="$(microsoft365_archive_chosen_schedule_file)"; [ -s "$f" ] && v="$(head -n 1 "$f")"; fi
  case "$v" in [Oo][Ff][Ff]) printf 'off' ;; *) printf 'hourly' ;; esac
}
# The one command that runs the job once, through launchd, so it gets the plist's own environment.
microsoft365_archive_run_once() { printf 'launchctl kickstart "gui/$(id -u)/%s"' "$MICROSOFT365_ARCHIVE_LABEL"; }

microsoft365_archive_root() {
  local f
  [ -n "${BOOTSTRAP_ARCHIVE_DIR:-}" ] && { printf '%s' "${BOOTSTRAP_ARCHIVE_DIR%/}"; return 0; }
  f="$(microsoft365_archive_chosen_root_file)"
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  printf '%s/Microsoft365Archive' "$HOME"
}

# Tenant and client id the way the server in use is signed in to. For the microsoft365 module's server
# (or one BOOTSTRAP_MICROSOFT_SERVER names) exactly as microsoft365 derives them: environment, then what
# that module recorded, then its work-account default. For a server an agent already runs, from THAT
# registration's env — no MS365_MCP_TENANT_ID there is Softeria's own default, common — so the archive
# signs in the way the agent does, and never on a tenant the agent does not use.
microsoft365_archive_tenant() {
  local f t
  if [ "$(microsoft365_archive_server_source)" = agent-registration ]; then
    t="$(microsoft365_archive_registration_env MS365_MCP_TENANT_ID)"
    printf '%s' "${t:-common}"; return 0
  fi
  [ -n "${BOOTSTRAP_MICROSOFT_TENANT:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_TENANT"; return 0; }
  f="$(microsoft365_archive_state_dir)/microsoft365/tenant"
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  printf 'organizations'
}
microsoft365_archive_client_id() {
  local f
  if [ "$(microsoft365_archive_server_source)" = agent-registration ]; then
    microsoft365_archive_registration_env MS365_MCP_CLIENT_ID; return 0
  fi
  [ -n "${BOOTSTRAP_MICROSOFT_CLIENT_ID:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_CLIENT_ID"; return 0; }
  f="$(microsoft365_archive_state_dir)/microsoft365/client-id"
  [ -s "$f" ] && head -n 1 "$f"
  return 0
}

# microsoft365_archive_node_ok <path> — an executable node >= 20 (the Softeria server's dependency tree
# needs it: @azure/msal-node 5.6.0 says so) at a path that survives a node upgrade. A per-shell
# fnm_multishells path is refused, because it vanishes with the shell and the hourly job would die
# with it, silently. A "|" is refused because the server pick below is "|"-joined.
microsoft365_archive_node_ok() {
  local c="$1" major
  [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ] || return 1
  case "$c" in */fnm_multishells/*|*'|'*) return 1 ;; esac
  major="$("$c" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge 20 ]
}

# microsoft365_archive_node — the same candidate list, in the same order, as microsoft365_node: the
# library's search first (the pinned node microsoft365 fetches on a Mac with none, Homebrew's two
# prefixes, PATH), then the fixed list, because that search stops at its first hit. It is the node
# that probes candidate servers, and the one that runs the microsoft365 module's server; a server an
# agent already runs is run by that agent's node (microsoft365_archive_node_beside).
microsoft365_archive_node() {
  local c
  for c in "$(bootstrap_find_tool node 2>/dev/null)" "$(bootstrap_tools_dir)/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node \
           "$HOME/Library/Application Support/fnm/aliases/default/bin/node" \
           "$(command -v node 2>/dev/null)"; do
    microsoft365_archive_node_ok "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ── TLS ──────────────────────────────────────────────────────────────────────────────────────
# The hourly job is a node process that reaches Microsoft through the server, so behind an inspecting
# proxy it needs NODE_EXTRA_CA_CERTS in the LaunchAgent's environment (node ignores the keychain).
# Asked per host, because proxies bypass inspection per host; BOOTSTRAP_TLS_PROBE_URL replaces both
# (a test seam). Loaded once per verb, at its top — each probe is two HTTPS requests.
MICROSOFT365_ARCHIVE_TLS_LOADED=""; MICROSOFT365_ARCHIVE_TLS_VAR=""; MICROSOFT365_ARCHIVE_TLS_RC=1
microsoft365_archive_tls_load() {
  local u out rc known=1 untrusted=0
  [ -n "$MICROSOFT365_ARCHIVE_TLS_LOADED" ] && return 0
  MICROSOFT365_ARCHIVE_TLS_VAR=""
  for u in ${BOOTSTRAP_TLS_PROBE_URL:-https://login.microsoftonline.com/ https://graph.microsoft.com/}; do
    out="$(bootstrap_node_ca_env "$u" 2>/dev/null)"; rc=$?
    case "$rc" in
      0) known=0; [ -n "$out" ] && MICROSOFT365_ARCHIVE_TLS_VAR="$out" ;;
      2) untrusted=1 ;;
    esac
  done
  MICROSOFT365_ARCHIVE_TLS_RC="$known"; [ "$untrusted" = 1 ] && MICROSOFT365_ARCHIVE_TLS_RC=2
  MICROSOFT365_ARCHIVE_TLS_LOADED=1
}
# The CA file the job is started with, or nothing: the one this network needs now, else one an earlier
# run exported — kept, so a Mac set up at the office and verified at home does not lose it (it holds
# only roots the OS already trusts). The path is the one bootstrap_node_ca_env writes.
microsoft365_archive_ca_path() {
  local pem
  microsoft365_archive_tls_load
  [ -n "$MICROSOFT365_ARCHIVE_TLS_VAR" ] && { printf '%s' "${MICROSOFT365_ARCHIVE_TLS_VAR#NODE_EXTRA_CA_CERTS=}"; return 0; }
  pem="$(microsoft365_archive_state_dir)/trusted-roots.pem"
  [ -s "$pem" ] && printf '%s' "$pem"
  return 0
}

# microsoft365_archive_real_file <node> <path> — the physical path of a FILE, symlinks resolved, read
# by node's own realpath — node is required on every path that gets this far, so nothing else is.
MICROSOFT365_ARCHIVE_REALPATH_JS='try { process.stdout.write(require("fs").realpathSync(process.argv[1])); } catch (e) { process.exit(1); }'
microsoft365_archive_real_file() { "$1" -e "$MICROSOFT365_ARCHIVE_REALPATH_JS" "$2" 2>/dev/null; }

# microsoft365_archive_node_beside <probe-node> <server-as-named> — the node an agent runs a named
# server with. A bin link (`…/bin/ms-365-mcp-server`, what an agent registers) starts through its
# `#!/usr/bin/env node`, and fnm, nvm, nodejs.org and Homebrew all put that node in the same bin/, so
# the node beside the link is the agent's. It matters beyond the version: the server keeps its sign-in
# key in the login Keychain, whose access list trusts the binary that stored it — measured on this
# kind of Mac, Homebrew's node is ad-hoc signed and fnm's is Developer ID signed — and a job that reads
# it as a different binary meets the Keychain's access check as a stranger. No node beside it: the probe.
microsoft365_archive_node_beside() {
  local probe="$1" named="$2" beside
  beside="$(dirname "$named")/node"
  if microsoft365_archive_node_ok "$beside"; then printf '%s' "$beside"; else printf '%s' "$probe"; fi
}

# Paths are shown as $HOME/… literally: executable as typed, and no username in the output.
microsoft365_archive_short_path() {
  case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

# microsoft365_archive_kept_line <root> — one sentence naming an archive folder that still holds
# anything, and the one command that removes it; nothing when there is nothing there. Neither
# uninstall_ nor anything else here deletes it: it is the person's data, and it may hold meetings
# Microsoft no longer keeps. The command is left out for a path that would break out of its quotes.
microsoft365_archive_kept_line() {
  local r="$1" s
  [ -d "$r" ] && [ -n "$(ls -A "$r" 2>/dev/null)" ] || return 0
  s="$(microsoft365_archive_short_path "$r")"
  printf 'the meeting archive at %s was kept — local markdown copies of your meetings and Copilot files, outside your tenant'\''s DLP, retention and eDiscovery' "$s"
  case "$r" in *'"'*|*'`'*|*'\'*) printf '; delete that folder yourself to remove them.' ;;
    *) case "${r#"$HOME"}" in *'$'*) printf '; delete that folder yourself to remove them.' ;;
         *) printf '; to remove them too, run: rm -rf "%s"' "$s" ;; esac ;; esac
}

# microsoft365_archive_rerun <module> [<VAR=value …>] — the command a person re-runs to finish a module,
# with the given environment on the run itself: the entry script the driver names in BOOTSTRAP_ENTRY
# (the clone's bootstrap.sh, or the copy a file-run kept). Nothing under `curl … | bash`, where there
# is no file to name, nor for a path that would break out of its quotes — a command that does not run
# as typed is worse than none. (The old curl-with-BOOTSTRAP_PIN form is gone: the driver now refuses
# a pin that does not match its own manifest.)
microsoft365_archive_rerun() {
  local module="$1" env="${2:-}"
  case "${BOOTSTRAP_ENTRY:-}" in ''|*'"'*|*'$'*|*'`'*|*'\'*) return 0 ;; esac
  [ -n "$env" ] && env="$env "
  printf '%sbash "%s" --only %s' "$env" "$(microsoft365_archive_short_path "$BOOTSTRAP_ENTRY")" "$module"
}

# ── bounded execution ────────────────────────────────────────────────────────────────────────
# macOS has no timeout(1), and a selftest that hangs would hang the whole bootstrap. node's
# spawnSync carries the ceiling instead; a timeout exits 124. The program is executed as launchd
# will execute it — through its own shebang.
MICROSOFT365_ARCHIVE_BOUNDED_JS='
const argv = process.argv.slice(1);
const r = require("child_process").spawnSync(argv[1], argv.slice(2),
  {timeout: Number(argv[0]), stdio: ["ignore", "inherit", "inherit"]});
process.exit(r.status === null ? 124 : r.status);
'
microsoft365_archive_bounded() {                    # <node> <ms> <program> <args…>
  local node="$1"; shift
  "$node" -e "$MICROSOFT365_ARCHIVE_BOUNDED_JS" "$@"
}

# ── the server: which one, and proving it is one ─────────────────────────────────────────────
# microsoft365_archive_is_server <node> <path> — rc 0 iff <path> is Softeria's server: absolute, its
# real path ends in the package's dist/index.js, and EXECUTING it on <node> answers --version with one
# semver line and rc 0. Neither half alone is acceptance: any file can sit at that path, and any script
# can print a version. Bounded, so a candidate that hangs cannot hang the bootstrap; its log goes to a
# throwaway folder, never the real server's.
microsoft365_archive_is_server() {
  local node="$1" p="$2" real logs out rc
  case "$p" in /*) : ;; *) return 1 ;; esac
  case "$p" in */fnm_multishells/*|*'|'*) return 1 ;; esac
  [ -f "$p" ] || return 1
  real="$(microsoft365_archive_real_file "$node" "$p")" || return 1
  case "$real" in *"$MICROSOFT365_ARCHIVE_SERVER_TAIL") : ;; *) return 1 ;; esac
  logs="$(mktemp -d -t microsoft365archiveprobe)" || return 1
  out="$(export MS365_MCP_LOG_DIR="$logs"; microsoft365_archive_bounded "$node" 20000 "$node" "$p" --version 2>/dev/null)"; rc=$?
  rm -rf "$logs" 2>/dev/null
  [ "$rc" = 0 ] || return 1
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s\n' "$out" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?'
}

# microsoft365_archive_registration_env <NAME> — that variable in the agent's ms365 registration's
# env block, or nothing. Read with bootstrap_settings_get; this module never writes $HOME/.claude.json.
microsoft365_archive_registration_env() {
  local v
  v="$(bootstrap_settings_get "$(microsoft365_archive_agent_config)" "mcpServers.$MICROSOFT365_ARCHIVE_REGISTRATION_KEY.env.$1" raw 2>/dev/null)" || v=""
  printf '%s' "$v"
}

# microsoft365_archive_registration <probe-node> — "<node>|<server>" for the ms365 server an agent
# already runs, or rc 1. Two registration shapes are Softeria's: a `command` whose real path is the
# package's dist/index.js (the bin link a global install puts on PATH), or a node `command` whose
# args.0 is. A bare command name is looked up on PATH; one that lands in a per-shell fnm_multishells
# folder is replaced by its real path, the same binary at a path that outlives the shell. A tenant or
# client id holding anything but [A-Za-z0-9._-] is refused: both are printed into a command a person runs.
microsoft365_archive_registration() {
  local probe="$1" f k cmd real node server v
  f="$(microsoft365_archive_agent_config)"
  k="mcpServers.$MICROSOFT365_ARCHIVE_REGISTRATION_KEY"
  [ -f "$f" ] || return 1
  cmd="$(bootstrap_settings_get "$f" "$k.command" raw 2>/dev/null)" || return 1
  case "$cmd" in
    /*) : ;;
    ''|*/*) return 1 ;;
    *) cmd="$(command -v "$cmd" 2>/dev/null)" || return 1
       case "$cmd" in /*) : ;; *) return 1 ;; esac ;;
  esac
  real="$(microsoft365_archive_real_file "$probe" "$cmd")" || return 1
  case "$cmd" in */fnm_multishells/*) cmd="$real" ;; esac
  case "$real" in
    *"$MICROSOFT365_ARCHIVE_SERVER_TAIL")
      server="$cmd"
      node="$(microsoft365_archive_node_beside "$probe" "$cmd")" ;;
    */node)
      server="$(bootstrap_settings_get "$f" "$k.args.0" raw 2>/dev/null)" || return 1
      node="$cmd"
      microsoft365_archive_node_ok "$node" || node="$real"
      microsoft365_archive_node_ok "$node" || node="$probe" ;;
    *) return 1 ;;
  esac
  for v in "$(microsoft365_archive_registration_env MS365_MCP_TENANT_ID)" "$(microsoft365_archive_registration_env MS365_MCP_CLIENT_ID)"; do
    case "$v" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  done
  microsoft365_archive_is_server "$node" "$server" || return 1
  printf '%s|%s' "$node" "$server"
}

# microsoft365_archive_pick_derive — "<source>|<node>|<server>": the server the archive reads through
# and the node that runs it, in the documented order, each accepted only by microsoft365_archive_is_server.
#   bootstrap-env       BOOTSTRAP_MICROSOFT_SERVER, else the one it named at an earlier install
#   module              the microsoft365 module's own install
#   agent-registration  the ms365 server in $HOME/.claude.json
# rc 1 = none. rc 2 = a NAMED server that does not run as one: printed anyway so the note can name it,
# and never replaced by a later candidate — a person who named a server is told it is wrong, not
# silently given another one on a tenant they did not pick.
microsoft365_archive_pick_derive() {
  local probe named f node server
  probe="$(microsoft365_archive_node)" || return 1
  named="${BOOTSTRAP_MICROSOFT_SERVER:-}"
  if [ -z "$named" ]; then
    f="$(microsoft365_archive_chosen_server_file)"
    [ -s "$f" ] && named="$(head -n 1 "$f")"
  fi
  if [ -n "$named" ]; then
    node="$(microsoft365_archive_node_beside "$probe" "$named")"
    printf 'bootstrap-env|%s|%s' "$node" "$named"
    microsoft365_archive_is_server "$node" "$named" && return 0
    return 2
  fi
  server="$(microsoft365_archive_module_server)"
  if [ -f "$server" ] && microsoft365_archive_is_server "$probe" "$server"; then
    printf 'module|%s|%s' "$probe" "$server"; return 0
  fi
  node="$(microsoft365_archive_registration "$probe")" || return 1
  printf 'agent-registration|%s' "$node"
}

# microsoft365_archive_pick — the same, remembered for the rest of ONE verb. Proving a candidate runs
# it, and a verb asks a dozen times, so each verb calls this once at its top (never inside $(…), whose
# subshell would forget it) and every later $(…) inherits the answer. The memory is keyed on what the
# answer depends on, and every verb starts in a fresh subshell, so no verb reuses another's answer.
MICROSOFT365_ARCHIVE_PICK_KEY=""
microsoft365_archive_pick() {
  local key="$HOME|${BOOTSTRAP_STATE_DIR:-}|${BOOTSTRAP_MICROSOFT_SERVER:-}"
  if [ "$MICROSOFT365_ARCHIVE_PICK_KEY" != "$key" ]; then
    MICROSOFT365_ARCHIVE_PICKED="$(microsoft365_archive_pick_derive)"; MICROSOFT365_ARCHIVE_PICK_RC=$?
    MICROSOFT365_ARCHIVE_PICK_KEY="$key"
  fi
  printf '%s' "$MICROSOFT365_ARCHIVE_PICKED"
  return "$MICROSOFT365_ARCHIVE_PICK_RC"
}

# One field of a USABLE pick (rc 0), or rc 1 and nothing.
microsoft365_archive_pick_field() {
  local p rest
  p="$(microsoft365_archive_pick)" || return 1
  rest="${p#*|}"
  case "$1" in
    source) printf '%s' "${p%%|*}" ;;
    node)   printf '%s' "${rest%%|*}" ;;
    server) printf '%s' "${rest#*|}" ;;
  esac
}
microsoft365_archive_server()        { microsoft365_archive_pick_field server; }
microsoft365_archive_server_source() { microsoft365_archive_pick_field source; }
# The node that runs the archive: the pick's, else the probe (so the node gate still has an answer).
microsoft365_archive_run_node()      { microsoft365_archive_pick_field node || microsoft365_archive_node; }
# The named server that does not run as one (pick rc 2), or rc 1.
microsoft365_archive_server_named() {
  local p rc
  p="$(microsoft365_archive_pick)"; rc=$?
  [ "$rc" = 2 ] || return 1
  p="${p#*|}"; printf '%s' "${p#*|}"
}

# ── the account ──────────────────────────────────────────────────────────────────────────────
# microsoft365_archive_account_candidates <node> — the signed-in accounts in the configured tenant,
# one username per line. `--list-accounts` is local (MSAL's cache, read by the server itself, never
# by us); each id is "<object id>.<tenant id>", so the tenant test is the one microsoft365 applies.
microsoft365_archive_account_candidates() {
  local node="$1" tmp logs n i id tenant_of_account user want client_id keep server
  server="$(microsoft365_archive_server)" || return 1
  tmp="$(mktemp -t microsoft365archiveaccounts)" || return 1
  logs="$(mktemp -d -t microsoft365archivelogs)" || { rm -f "$tmp"; return 1; }
  client_id="$(microsoft365_archive_client_id)"
  if [ -n "$client_id" ]; then
    MS365_MCP_LOG_DIR="$logs" MS365_MCP_TENANT_ID="$(microsoft365_archive_tenant)" MS365_MCP_CLIENT_ID="$client_id" \
      "$node" "$server" --list-accounts 2>/dev/null | grep '^{' | tail -n 1 > "$tmp"
  else
    MS365_MCP_LOG_DIR="$logs" MS365_MCP_TENANT_ID="$(microsoft365_archive_tenant)" \
      "$node" "$server" --list-accounts 2>/dev/null | grep '^{' | tail -n 1 > "$tmp"
  fi
  rm -rf "$logs" 2>/dev/null
  n="$(bootstrap_settings_get "$tmp" accounts raw 2>/dev/null)" || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  want="$(microsoft365_archive_tenant)"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="$(bootstrap_settings_get "$tmp" "accounts.$i.id" raw 2>/dev/null)" || id=""
    user="$(bootstrap_settings_get "$tmp" "accounts.$i.username" raw 2>/dev/null)" || user=""
    i=$((i + 1))
    [ -n "$id" ] || continue
    [ -n "$user" ] || user="$id"
    tenant_of_account="${id##*.}"
    keep=1
    case "$want" in
      common)        : ;;
      consumers)     [ "$tenant_of_account" = "$MICROSOFT365_ARCHIVE_PERSONAL_TENANT" ] || keep=0 ;;
      *-*-*-*-*)     [ "$tenant_of_account" = "$want" ] || keep=0 ;;
      *)             [ "$tenant_of_account" != "$MICROSOFT365_ARCHIVE_PERSONAL_TENANT" ] || keep=0 ;;   # organizations, or a domain name
    esac
    [ "$keep" = 1 ] && printf '%s\n' "$user"
  done
  rm -f "$tmp" 2>/dev/null
  return 0
}

# microsoft365_archive_lower <text> — ASCII case folded, for comparisons a case-insensitive volume or
# a case-insensitive sign-in name would call equal.
microsoft365_archive_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# microsoft365_archive_signed_in <account> <candidates> — rc 0 iff the account is one of the signed-in
# candidates (one per line), compared case-insensitively as the engine compares it.
microsoft365_archive_signed_in() {
  local want line
  [ -n "$1" ] || return 1
  want="$(microsoft365_archive_lower "$1")"
  while IFS= read -r line; do
    [ -n "$line" ] && [ "$(microsoft365_archive_lower "$line")" = "$want" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# microsoft365_archive_held_account — the account= the installed config already holds, or nothing.
microsoft365_archive_held_account() {
  microsoft365_archive_config_get "$(microsoft365_archive_config)" account 2>/dev/null
  return 0
}

# microsoft365_archive_account_from <candidates> — the account the job will pass on every call, or
# rc 1: BOOTSTRAP_MICROSOFT_ACCOUNT, then the recorded choice, then the account the config already
# holds WHILE it is still signed in (a second account signing in later must not undo an earlier
# pick), then the ONE signed-in account in the tenant. Zero or several is a person's question, never a
# guess. A named account is returned even when it is not signed in — the gate reports that.
microsoft365_archive_account_from() {
  local list="$1" f held only
  [ -n "${BOOTSTRAP_MICROSOFT_ACCOUNT:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_ACCOUNT"; return 0; }
  f="$(microsoft365_archive_chosen_account_file)"
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  held="$(microsoft365_archive_held_account)"
  if [ -n "$held" ] && microsoft365_archive_signed_in "$held" "$list"; then printf '%s' "$held"; return 0; fi
  only="$(printf '%s\n' "$list" | awk 'NF')"
  [ -n "$only" ] || return 1
  [ "$(printf '%s\n' "$only" | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s' "$only"
}

# microsoft365_archive_account <node> — the same, asking the server for the candidates itself.
microsoft365_archive_account() {
  local list
  list="$(microsoft365_archive_account_candidates "$1" 2>/dev/null)" || list=""
  microsoft365_archive_account_from "$list"
}

# ── the cloud-path refusal ───────────────────────────────────────────────────────────────────
# microsoft365_archive_real_path <path> — the physical path: the deepest ancestor that exists,
# resolved with pwd -P, with the not-yet-existing tail put back.
microsoft365_archive_real_path() {
  local p="${1%/}" tail="" base
  [ -n "$p" ] || p="/"
  while [ ! -d "$p" ]; do
    base="${p##*/}"
    tail="/$base$tail"
    p="${p%/*}"
    [ -n "$p" ] || { p="/"; break; }
  done
  p="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  [ "$p" = "/" ] && p=""
  printf '%s%s' "$p" "$tail"
}

# microsoft365_archive_under_cloud <path> — rc 0 iff <path> is inside a sync client's tree. The two
# physical paths are compared with the letter case folded: `pwd -P` keeps the case that was TYPED, and
# on a case-insensitive volume (the macOS default) $HOME/library/cloudstorage IS the synced folder. On
# a case-sensitive volume the fold can only refuse more.
microsoft365_archive_under_cloud() {
  local p c
  p="$(microsoft365_archive_real_path "$1")" || return 0     # cannot tell => refuse, never guess safe
  p="$(microsoft365_archive_lower "$p")"
  for c in "$HOME/Library/CloudStorage" "$HOME/Library/Mobile Documents"; do
    c="$(microsoft365_archive_real_path "$c")" || return 0
    c="$(microsoft365_archive_lower "$c")"
    case "$p/" in "$c"/*) return 0 ;; esac
  done
  return 1
}

# microsoft365_archive_root_shape_ok <path> — absolute, with no "." or ".." segment. The tail of a
# path that does not exist yet is never resolved, so "$HOME/new/../Library/CloudStorage/x" would read
# as outside the cloud and then `mkdir -p` would create a folder inside it.
microsoft365_archive_root_shape_ok() {
  case "$1" in /*) : ;; *) return 1 ;; esac
  case "/$1/" in */./*|*/../*) return 1 ;; esac
  return 0
}

# microsoft365_archive_root_in_engine <path> — rc 0 iff <path> is, or is inside, a folder this module
# owns and uninstall removes (the engine folder, the wrapper's bin/): an archive there would go with it.
microsoft365_archive_root_in_engine() {
  local p d
  p="$(microsoft365_archive_real_path "$1")" || return 0
  p="$(microsoft365_archive_lower "$p")"
  for d in "$(microsoft365_archive_dir)" "$(microsoft365_archive_state_dir)/bin"; do
    d="$(microsoft365_archive_real_path "$d")" || return 0
    d="$(microsoft365_archive_lower "$d")"
    case "$p/" in "$d"/*) return 0 ;; esac
  done
  return 1
}

# ── the asset set ────────────────────────────────────────────────────────────────────────────
# Asset paths are relative to assets/: microsoft365-archive/<file> and markdown-convert.sh, read ONLY
# from $BOOTSTRAP_ASSETS — the verified release tree, a clone's or the one a curl'd driver checked
# against its sha256 manifest. This module used to fetch its own copy from raw.githubusercontent.com
# when there was no clone; that copy was the one set of bytes the manifest never saw, so it is gone,
# and with it the engine's own MANIFEST, which existed only to list what to fetch.
microsoft365_archive_source() {
  [ -r "${BOOTSTRAP_ASSETS:-}/microsoft365-archive/archive.js" ] && [ -r "${BOOTSTRAP_ASSETS}/markdown-convert.sh" ] \
    && { printf '%s' "$BOOTSTRAP_ASSETS"; return 0; }
  return 1
}

# microsoft365_archive_parts <source-root> — the engine's files, from the directory, relative to it:
# every file but hidden ones. Every file, not a fixed four: the folder's own package.json ("type":
# "commonjs") is what keeps node from reading the engine as ES modules under a package.json higher
# up (the repo's root one declares "type": "module"), and a fixed list would have silently dropped it.
microsoft365_archive_parts() {
  [ -d "$1/microsoft365-archive" ] || return 1
  (cd "$1/microsoft365-archive" && find . -type f ! -name '.*' ! -path '*/.*' 2>/dev/null) \
    | sed 's#^\./##' | LC_ALL=C sort
}

# ── generated files: the wrapper and the config ──────────────────────────────────────────────
microsoft365_archive_wrapper_text() {           # <node>
  local node="$1"
  printf '#!/bin/bash\n'
  printf '# microsoft365-archive — written by the mac-bootstrap module microsoft365_archive; re-running\n'
  printf '# the bootstrap rewrites it, so change the module, not this file.\n'
  printf '# launchd starts a job with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which holds neither node nor the\n'
  printf '# converters markdown-convert.sh looks for (pandoc, markitdown), so they go on PATH here.\n'
  # shellcheck disable=SC2016   # $HOME and $PATH are meant to expand when the wrapper runs, not now
  printf 'PATH=%q:/opt/homebrew/bin:/usr/local/bin:"$HOME/.local/bin":"${PATH:-/usr/bin:/bin}"\n' "$(dirname "$node")"
  printf 'export PATH\n'
  printf 'MICROSOFT365_ARCHIVE_CONFIG=%q\n' "$(microsoft365_archive_config)"
  printf 'export MICROSOFT365_ARCHIVE_CONFIG\n'
  # shellcheck disable=SC2016
  printf 'exec %q %q "$@"\n' "$node" "$(microsoft365_archive_dir)/archive.js"
}

# key=value, one per line, fixed order. account and client_id appear only when there is one. Which
# candidate the server came from is recorded as a COMMENT line: the engine refuses a key it does not
# know and has no use for this one, while config_ok below still reads it back like any other line, so
# a config written from one source never passes as current once the pick comes from another.
microsoft365_archive_config_text() {            # <node> <account-or-empty>
  local node="$1" account="$2" id
  printf 'root=%s\n' "$(microsoft365_archive_root)"
  [ -n "$account" ] && printf 'account=%s\n' "$account"
  printf 'node=%s\n' "$node"
  printf 'server=%s\n' "$(microsoft365_archive_server)"
  printf '# server_source=%s\n' "$(microsoft365_archive_server_source)"
  printf 'tenant=%s\n' "$(microsoft365_archive_tenant)"
  id="$(microsoft365_archive_client_id)"
  [ -n "$id" ] && printf 'client_id=%s\n' "$id"
  printf 'convert=%s\n' "$(microsoft365_archive_converter)"
}

# microsoft365_archive_config_get <file> <key> — the reader, awk rather than the printf that wrote.
microsoft365_archive_config_get() {
  [ -f "$1" ] || return 1
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found=1; exit } END { exit found ? 0 : 1 }' "$1"
}

# microsoft365_archive_config_ok <node> <account-or-empty> — every key parsed back equal, and no
# key we did not write.
microsoft365_archive_config_ok() {
  local f want line k n=0 m
  f="$(microsoft365_archive_config)"
  [ -f "$f" ] || return 1
  want="$(microsoft365_archive_config_text "$1" "$2")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    [ "$(microsoft365_archive_config_get "$f" "$k")" = "${line#*=}" ] || return 1
    n=$((n + 1))
  done <<EOF
$want
EOF
  m="$(awk 'NF' "$f" | wc -l | tr -d ' ')"
  [ "$m" = "$n" ]
}

# microsoft365_archive_land <src> <dest> <mode> — write only on a difference, via a temp file and a
# rename, so a second run touches no byte and an interrupted one never leaves half a file.
microsoft365_archive_land() {
  local src="$1" dest="$2" mode="$3" have
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
  if ! cmp -s "$src" "$dest" 2>/dev/null; then
    cp -f "$src" "$dest.tmp.$$" 2>/dev/null && chmod "$mode" "$dest.tmp.$$" 2>/dev/null \
      && mv -f "$dest.tmp.$$" "$dest" 2>/dev/null || { rm -f "$dest.tmp.$$" 2>/dev/null; return 1; }
    return 0
  fi
  have="$(stat -f %Lp "$dest" 2>/dev/null)" || have=""
  [ "$have" = "$mode" ] || chmod "$mode" "$dest" 2>/dev/null
  return 0
}

# ── the LaunchAgent ──────────────────────────────────────────────────────────────────────────
# microsoft365_archive_plist_build <dest> — built with plutil, key by key, never as a string. Behind an
# inspecting proxy the job's environment carries NODE_EXTRA_CA_CERTS: the engine and the server it
# starts both inherit it, and without it every hourly run dies at TLS.
microsoft365_archive_plist_build() {
  local p="$1" log ca
  log="$(microsoft365_archive_log)"; ca="$(microsoft365_archive_ca_path)"
  rm -f "$p" 2>/dev/null
  plutil -create xml1 "$p" >/dev/null 2>&1 \
    && plutil -insert Label -string "$MICROSOFT365_ARCHIVE_LABEL" "$p" >/dev/null 2>&1 \
    && plutil -insert ProgramArguments -array "$p" >/dev/null 2>&1 \
    && plutil -insert ProgramArguments -string "$(microsoft365_archive_wrapper)" -append "$p" >/dev/null 2>&1 \
    && plutil -insert ProgramArguments -string run -append "$p" >/dev/null 2>&1 || return 1
  # On demand: no trigger key at all, so launchd holds the job and never starts it by itself.
  if [ "$(microsoft365_archive_schedule)" = hourly ]; then
    plutil -insert StartCalendarInterval -dictionary "$p" >/dev/null 2>&1 \
      && plutil -insert StartCalendarInterval.Minute -integer "$MICROSOFT365_ARCHIVE_MINUTE" "$p" >/dev/null 2>&1 \
      && plutil -insert RunAtLoad -bool true "$p" >/dev/null 2>&1 || return 1
  fi
  plutil -insert StandardOutPath -string "$log" "$p" >/dev/null 2>&1 \
    && plutil -insert StandardErrorPath -string "$log" "$p" >/dev/null 2>&1 || return 1
  [ -n "$ca" ] || return 0
  plutil -insert EnvironmentVariables -dictionary "$p" >/dev/null 2>&1 \
    && plutil -insert EnvironmentVariables.NODE_EXTRA_CA_CERTS -string "$ca" "$p" >/dev/null 2>&1
}

# microsoft365_archive_plist_get <key> — plutil emits its failure SENTENCE on stdout (CONTRACT §7.3),
# so only an rc-0 answer is ever printed.
microsoft365_archive_plist_get() {
  local out
  out="$(plutil -extract "$1" raw "$(microsoft365_archive_plist)" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# microsoft365_archive_plist_ok — parses, and every field reads back as the job needs it. The array
# length is read too: an extra argument would change what launchd runs.
microsoft365_archive_plist_ok() {
  local p ca k
  p="$(microsoft365_archive_plist)"
  [ -f "$p" ] || return 1
  plutil -lint "$p" >/dev/null 2>&1 || return 1
  [ "$(microsoft365_archive_plist_get Label)" = "$MICROSOFT365_ARCHIVE_LABEL" ] || return 1
  [ "$(microsoft365_archive_plist_get ProgramArguments)" = 2 ] || return 1
  [ "$(microsoft365_archive_plist_get ProgramArguments.0)" = "$(microsoft365_archive_wrapper)" ] || return 1
  [ "$(microsoft365_archive_plist_get ProgramArguments.1)" = run ] || return 1
  # The triggers are exactly the schedule in force: hourly and at load, or none at all.
  if [ "$(microsoft365_archive_schedule)" = hourly ]; then
    [ "$(microsoft365_archive_plist_get StartCalendarInterval.Minute)" = "$MICROSOFT365_ARCHIVE_MINUTE" ] || return 1
    [ "$(microsoft365_archive_plist_get RunAtLoad)" = true ] || return 1
  else
    for k in StartCalendarInterval StartInterval RunAtLoad KeepAlive WatchPaths QueueDirectories StartOnMount; do
      plutil -type "$k" "$p" >/dev/null 2>&1 && return 1
    done
  fi
  [ "$(microsoft365_archive_plist_get StandardOutPath)" = "$(microsoft365_archive_log)" ] || return 1
  [ "$(microsoft365_archive_plist_get StandardErrorPath)" = "$(microsoft365_archive_log)" ] || return 1
  # The environment is exactly the CA file in force, or absent: nothing else may ride into the job.
  ca="$(microsoft365_archive_ca_path)"
  if [ -n "$ca" ]; then
    [ "$(plutil -extract EnvironmentVariables xml1 -o - "$p" 2>/dev/null | grep -c '<key>')" = 1 ] || return 1
    [ "$(microsoft365_archive_plist_get EnvironmentVariables.NODE_EXTRA_CA_CERTS)" = "$ca" ] || return 1
  else
    plutil -type EnvironmentVariables "$p" >/dev/null 2>&1 && return 1
  fi
  return 0
}

# microsoft365_archive_loaded_path [label] — the plist launchd loaded the label from, read out of
# launchd's own `print`; rc 1 when the label is not loaded. launchctl's rc is captured before the
# parse, so a pipe can never report the wrong stage's status (CONTRACT §7.8).
microsoft365_archive_loaded_path() {
  local out
  out="$(/bin/launchctl print "$(microsoft365_archive_domain)/${1:-$MICROSOFT365_ARCHIVE_LABEL}" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk 'index($0, "\tpath = ") == 1 { print substr($0, 9); exit }'
}

# microsoft365_archive_loaded_ours — rc 0 iff launchd holds the label AND loaded it from OUR plist.
# The label alone is not enough: one launchd domain serves every $HOME this user runs under, so a
# sandbox would otherwise count the real home's job as its own (and the reverse).
microsoft365_archive_loaded_ours() {
  local lp
  lp="$(microsoft365_archive_loaded_path)" || return 1
  [ -n "$lp" ] && [ -e "$lp" ] && [ "$lp" -ef "$(microsoft365_archive_plist)" ]
}

# The label is loaded, but from a plist that is not ours — another HOME's install, or a hand-made job.
microsoft365_archive_label_taken() {
  microsoft365_archive_loaded_path >/dev/null 2>&1 || return 1
  microsoft365_archive_loaded_ours && return 1
  return 0
}

microsoft365_archive_home_ok() { bootstrap_defaults_home_ok >/dev/null 2>&1; }

# ── Background Items ─────────────────────────────────────────────────────────────────────────
# macOS 13+ lets a person — or MDM — switch a LaunchAgent off in System Settings › Login Items
# ("Allow in the Background"). launchd then refuses to load it, and without this check install_'s
# `launchctl bootstrap` failed and the row read FAILED for a switch only the person can turn back on.
# The read is launchd's own table of disabled labels, which needs no admin; `sfltool dumpbtm` shows
# more but waits on an authorization prompt (measured: stalled over 120 s), so a verb never calls it.
# microsoft365_archive_disabled_in <print-disabled output> — rc 0 iff our label is listed disabled.
# Lines read `\t\t"<label>" => disabled` (measured, macOS 15.7).
microsoft365_archive_disabled_in() {
  printf '%s\n' "$1" | awk -v l="\"$MICROSOFT365_ARCHIVE_LABEL\"" '$1 == l && $2 == "=>" && $3 == "disabled" { f = 1 } END { exit f ? 0 : 1 }'
}
microsoft365_archive_background_off() {
  local out
  out="$(/bin/launchctl print-disabled "$(microsoft365_archive_domain)" 2>/dev/null)" || return 1
  microsoft365_archive_disabled_in "$out"
}

# ── the read-backs ───────────────────────────────────────────────────────────────────────────
# microsoft365_archive_files_ok — every engine file and the converter present, and byte-identical to
# the verified release tree whenever the driver provides one.
microsoft365_archive_files_ok() {
  local dir src rel parts
  dir="$(microsoft365_archive_dir)"
  for rel in $MICROSOFT365_ARCHIVE_ENGINE_FILES; do [ -f "$dir/$rel" ] || return 1; done
  [ -x "$(microsoft365_archive_converter)" ] || return 1
  src="$(microsoft365_archive_source 2>/dev/null)" || return 0
  parts="$(microsoft365_archive_parts "$src")" || return 1
  for rel in $parts; do
    cmp -s "$src/microsoft365-archive/$rel" "$dir/$rel" || return 1
  done
  cmp -s "$src/markdown-convert.sh" "$(microsoft365_archive_converter)"
}

# microsoft365_archive_wrapper_ok <node> — the wrapper is the one this Mac should have, and it RUNS:
# it answers --version with the engine's exact line, and (the negative control) a command the engine
# does not have is refused, so the version check is not merely "something printed".
microsoft365_archive_wrapper_ok() {
  local node="$1" w out tmp
  w="$(microsoft365_archive_wrapper)"
  [ -x "$w" ] || return 1
  tmp="$(mktemp -t microsoft365archivewrapper)" || return 1
  microsoft365_archive_wrapper_text "$node" > "$tmp"
  cmp -s "$tmp" "$w"; out=$?
  rm -f "$tmp" 2>/dev/null
  [ "$out" = 0 ] || return 1
  out="$(microsoft365_archive_bounded "$node" 20000 "$w" --version 2>/dev/null)" || return 1
  [ "$out" = "$MICROSOFT365_ARCHIVE_VERSION_LINE" ] || return 1
  microsoft365_archive_bounded "$node" 20000 "$w" no-such-command >/dev/null 2>&1 && return 1
  return 0
}

# microsoft365_archive_root_ok — the archive folder exists, is a folder, and is outside every synced
# tree and every folder uninstall removes; with its NEGATIVE CONTROLS, a path inside CloudStorage —
# spelled as on disk AND in another letter case — must be judged cloud, or the refusal can never say
# no and the pass means nothing.
microsoft365_archive_root_ok() {
  local r
  r="$(microsoft365_archive_root)"
  microsoft365_archive_root_shape_ok "$r" || return 1
  [ -d "$r" ] || return 1
  microsoft365_archive_under_cloud "$HOME/Library/CloudStorage/OneDrive-probe/x" || return 1
  microsoft365_archive_under_cloud "$(microsoft365_archive_lower "$HOME/Library/CloudStorage")/OneDrive-probe/x" || return 1
  microsoft365_archive_under_cloud "$r" && return 1
  microsoft365_archive_root_in_engine "$r" && return 1
  return 0
}

# The sha256 of the plist launchd was last bootstrapped from, written only after a load succeeded.
# launchd runs its in-memory copy, not the file, so a plist that changed on disk since is not live.
microsoft365_archive_loaded_marker() { printf '%s/loaded-plist.sha256' "$(microsoft365_archive_dir)"; }
microsoft365_archive_plist_sha() {
  local out
  out="$(/usr/bin/shasum -a 256 < "$(microsoft365_archive_plist)" 2>/dev/null)" || return 1
  printf '%s' "${out%% *}"
}
microsoft365_archive_loaded_current() {
  local have want
  have="$(head -n 1 "$(microsoft365_archive_loaded_marker)" 2>/dev/null)" || return 1
  want="$(microsoft365_archive_plist_sha)" || return 1
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# microsoft365_archive_ready <node> — everything reversible is in place (files, wrapper, config,
# plist, folder). The gates that only exist AFTER that work — the account, the sandboxed HOME, a
# label someone else loaded — are reported only once this holds, because gate_ runs before install_
# and a true gate there makes the driver skip the install it was about to do. The config is judged
# against the account it already HOLDS, not a fresh derivation: whether that account can still be
# used is the account gate's question, and it must be asked in --verify too.
microsoft365_archive_ready() {
  local node="$1"
  microsoft365_archive_files_ok || return 1
  microsoft365_archive_config_ok "$node" "$(microsoft365_archive_held_account)" || return 1
  microsoft365_archive_plist_ok || return 1
  microsoft365_archive_root_ok || return 1
  microsoft365_archive_wrapper_ok "$node"
}

# microsoft365_archive_gate_reason — ONE token naming the step only a person can take, or nothing.
# gate_, note_ and gesture_ all read this, so they can never disagree about which step it is.
microsoft365_archive_gate_reason() {
  local node n list account root rc
  microsoft365_archive_node >/dev/null || { printf 'node'; return 0; }
  microsoft365_archive_pick >/dev/null; rc=$?
  case "$rc" in 0) : ;; 2) printf 'server-named'; return 0 ;; *) printf 'server'; return 0 ;; esac
  node="$(microsoft365_archive_run_node)" || { printf 'node'; return 0; }
  microsoft365_archive_tls_load
  [ "$MICROSOFT365_ARCHIVE_TLS_RC" = 2 ] && { printf 'tls-untrusted'; return 0; }
  root="$(microsoft365_archive_root)"
  microsoft365_archive_root_shape_ok "$root" || { printf 'relative-root'; return 0; }
  microsoft365_archive_under_cloud "$root" && { printf 'cloud'; return 0; }
  microsoft365_archive_root_in_engine "$root" && { printf 'root-in-engine'; return 0; }
  microsoft365_archive_ready "$node" || return 0
  list="$(microsoft365_archive_account_candidates "$node" 2>/dev/null)" || list=""
  if ! account="$(microsoft365_archive_account_from "$list")"; then
    n="$(printf '%s\n' "$list" | awk 'NF' | wc -l | tr -d ' ')"
    case "$n" in 0|'') printf 'account-none' ;; *) printf 'account-many' ;; esac
    return 0
  fi
  microsoft365_archive_signed_in "$account" "$list" || { printf 'account-signed-out'; return 0; }
  microsoft365_archive_home_ok || { printf 'foreign-home'; return 0; }
  microsoft365_archive_label_taken && { printf 'label-taken'; return 0; }
  microsoft365_archive_background_off && { printf 'background-off'; return 0; }
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_microsoft365_archive() {
  if [ "$(microsoft365_archive_schedule)" = hourly ]; then
    printf '%s' 'every Teams meeting you attend, and your Copilot upload folder, kept as markdown in one local folder and refreshed hourly; read-only against Microsoft'
  else
    printf 'every Teams meeting you attend, and your Copilot upload folder, kept as markdown in one local folder, refreshed only when you run: %s; read-only against Microsoft' "$(microsoft365_archive_run_once)"
  fi
}
# What IT would ask first is said first: these are COPIES, on this Mac, that the tenant's controls no
# longer see, and something runs them in the background.
cost_microsoft365_archive() {
  printf 'keeps local markdown COPIES of your meeting transcripts, chats, notes, AI notes and Copilot files in %s, outside your tenant'\''s DLP, retention and eDiscovery; uninstall leaves them. A chat message your organisation'\''s DLP flagged is withheld, leaving only who sent it and when. ' \
    "$(microsoft365_archive_short_path "$(microsoft365_archive_root)")"
  if [ "$(microsoft365_archive_schedule)" = hourly ]; then
    printf 'A LaunchAgent (%s) runs it hourly and at every login (BOOTSTRAP_MICROSOFT365_ARCHIVE_SCHEDULE=off: only when you run it). ' "$MICROSOFT365_ARCHIVE_LABEL"
  else
    printf 'A LaunchAgent (%s) is loaded with no schedule and runs only when you start it. ' "$MICROSOFT365_ARCHIVE_LABEL"
  fi
  printf '%s' 'Under 1 MB plus the archive. Needs the microsoft365 sign-in; transcripts, AI notes and Copilot history each need a Microsoft grant your tenant may not have given, and the archive records which.'
}
clearance_microsoft365_archive() {
  printf 'data markdown copies of your Teams meeting transcripts, meeting chats, notes, AI notes and Copilot files in %s, outside the tenant'\''s DLP, retention and eDiscovery, which uninstall does not delete\n' \
    "$(microsoft365_archive_short_path "$(microsoft365_archive_root)")"
  if [ "$(microsoft365_archive_schedule)" = hourly ]; then
    printf 'background an hourly LaunchAgent (%s) that also starts at every login\n' "$MICROSOFT365_ARCHIVE_LABEL"
  else
    printf 'background a LaunchAgent (%s) loaded into launchd with no schedule, which runs only when you start it\n' "$MICROSOFT365_ARCHIVE_LABEL"
  fi
  printf '%s\n' 'software this bootstrap'\''s own archive engine (node scripts), which the job runs together with Softeria'\''s ms365 server outside any agent, so no agent hook sees its Graph reads'
}
profile_microsoft365_archive() { printf '%s' 'full'; }
needs_microsoft365_archive()   { printf '%s' 'microsoft365'; }
# One host per line: <host> <install|run> <purpose>. The engine's own downloads go to whatever
# pre-authenticated https URL Graph hands back (private and loopback addresses refused); these are
# the Microsoft content hosts that serves in practice.
egress_microsoft365_archive() { cat <<'E'
login.microsoftonline.com run hourly job (and at load) token refresh via the ms365 server; the TLS check at install and verify
graph.microsoft.com run hourly job Graph GETs: calendar, meetings, chats, OneDrive folders, /shares link resolution; the TLS check
*.sharepoint.com run pre-authenticated document downloads Graph returns (GET, no Authorization header)
*.files.1drv.com run pre-authenticated OneDrive downloads Graph returns (GET, no Authorization header)
*.svc.ms run pre-authenticated downloads Graph returns (GET, no Authorization header)
my.microsoftpersonalcontent.com run pre-authenticated personal-account downloads Graph returns (GET, no Authorization header)
E
}

verify_microsoft365_archive() {
  local node account list
  microsoft365_archive_pick >/dev/null || return 1
  node="$(microsoft365_archive_run_node)" || return 1
  [ -f "$(microsoft365_archive_plist)" ] || return 1       # nothing installed: say no before any request leaves
  microsoft365_archive_tls_load
  [ "$MICROSOFT365_ARCHIVE_TLS_RC" = 2 ] && return 1

  # Installed bytes against the shipped bytes, the folder, and the plist parsing to what launchd must
  # run — all local reads, so a Mac with nothing installed says no before any server is started.
  microsoft365_archive_files_ok || return 1
  microsoft365_archive_root_ok || return 1
  microsoft365_archive_plist_ok || return 1

  # The account the job passes must be one the server has signed in — read from the server's own
  # --list-accounts, not from what we recorded — or every hourly run stops at sign-in.
  list="$(microsoft365_archive_account_candidates "$node" 2>/dev/null)" || return 1
  account="$(microsoft365_archive_account_from "$list")" || return 1
  microsoft365_archive_signed_in "$account" "$list" || return 1

  # The generated config parsed back key by key — the server, and which candidate it came from, included.
  microsoft365_archive_config_ok "$node" "$account" || return 1

  # launchd holds the job, from THIS plist — read out of launchd, the one reader that is not us.
  # Under a sandboxed HOME nothing was loaded, and a job the real home loaded must not count.
  microsoft365_archive_home_ok || return 1
  microsoft365_archive_loaded_ours || return 1
  # NEGATIVE CONTROL: the same read for a label nobody loaded must fail, or the pass above proves
  # only that launchctl printed something.
  microsoft365_archive_loaded_path "$MICROSOFT365_ARCHIVE_LABEL.no-such-job" >/dev/null 2>&1 && return 1
  # …and what launchd holds is THIS plist's content, not an older one it was loaded with before the
  # file changed: launchd runs its in-memory copy until the job is re-bootstrapped.
  microsoft365_archive_loaded_current || return 1

  # The wrapper executes, and the engine proves itself on THIS node against its offline fixtures —
  # the end-to-end run twice with a zero-byte second pass, the GET-only guard refusing a POST.
  microsoft365_archive_wrapper_ok "$node" || return 1
  microsoft365_archive_bounded "$node" 180000 "$(microsoft365_archive_wrapper)" --selftest >/dev/null 2>&1
}

gate_microsoft365_archive() {
  microsoft365_archive_pick >/dev/null 2>&1
  microsoft365_archive_tls_load
  [ -n "$(microsoft365_archive_gate_reason)" ]
}

note_microsoft365_archive() {
  local r kept=""
  microsoft365_archive_pick >/dev/null 2>&1
  microsoft365_archive_tls_load
  r="$(microsoft365_archive_gate_reason)"
  # With no LaunchAgent in place (never installed, or uninstalled) an archive folder that still holds
  # copies is named, whatever else the line says: nothing here ever deletes it.
  [ -f "$(microsoft365_archive_plist)" ] || kept="$(microsoft365_archive_kept_line "$(microsoft365_archive_root)")"
  # The account gate is reported before the sandboxed-HOME one, but when both hold the line says so,
  # or the reader signs in, re-runs, and only then learns the job still will not load from here.
  case "$r" in account-*) microsoft365_archive_home_ok || {
    printf '%s Even then, this run has a sandboxed HOME, so the hourly job would not be loaded into your real launchd domain from it.' "$(microsoft365_archive_note_text "$r")"
    [ -n "$kept" ] && printf ' Also, %s.' "$kept"
    return 0; } ;; esac
  microsoft365_archive_note_text "$r"
  [ -n "$kept" ] && printf ' Also, %s.' "$kept"
  return 0
}

microsoft365_archive_note_text() {
  local r="$1"
  case "$r" in
    node)          printf 'the meeting archive runs on node 20 or later, and this Mac has none yet; the microsoft365 module fetches one from nodejs.org, with no Homebrew and no admin.' ;;
    tls-untrusted) printf 'your network intercepts TLS with a certificate this Mac does not trust, so the hourly job could never reach Microsoft; ask IT to install that certificate on this Mac.' ;;
    server)        printf 'the meeting archive reads through Softeria'\''s Microsoft 365 server, and there is none here it can run: the microsoft365 module has not installed it, and no ms365 server registered in $HOME/.claude.json runs as one.' ;;
    server-named)  printf 'the meeting archive was pointed at %s (BOOTSTRAP_MICROSOFT_SERVER, now or at an earlier install), and that does not run as Softeria'\''s Microsoft 365 server; re-run the bootstrap with BOOTSTRAP_MICROSOFT_SERVER set to its dist/index.js or its bin link.' \
                     "$(microsoft365_archive_short_path "$(microsoft365_archive_server_named)")" ;;
    relative-root) printf 'BOOTSTRAP_ARCHIVE_DIR must be an absolute path with no "." or ".." in it; "%s" is not.' "$(microsoft365_archive_root)" ;;
    cloud)         printf 'the archive folder %s is inside a folder a sync client uploads, and client meeting content must not be re-uploaded; choose a folder outside it.' "$(microsoft365_archive_short_path "$(microsoft365_archive_root)")" ;;
    root-in-engine) printf 'the archive folder %s is inside %s, which is this module'\''s own and is deleted by an uninstall; choose a folder outside it.' \
                     "$(microsoft365_archive_short_path "$(microsoft365_archive_root)")" "$(microsoft365_archive_short_path "$(microsoft365_archive_state_dir)")" ;;
    account-none)  printf 'no Microsoft account in tenant %s is signed in on this Mac, so the archive has no account to read as; sign in once, as the microsoft365 module asks.' "$(microsoft365_archive_tenant)" ;;
    account-many)  printf 'several Microsoft accounts in tenant %s are signed in (%s), and which one to archive is your call: re-run the bootstrap with BOOTSTRAP_MICROSOFT_ACCOUNT set to it.' \
                     "$(microsoft365_archive_tenant)" "$(microsoft365_archive_account_candidates "$(microsoft365_archive_run_node)" 2>/dev/null | awk 'NF' | paste -sd, - | sed 's/,/, /g')" ;;
    account-signed-out)
                   printf 'the archive reads as %s, and that account is not signed in on this Mac, so every hourly run would stop at sign-in; sign it in once (or name a signed-in account in BOOTSTRAP_MICROSOFT_ACCOUNT).' \
                     "$(microsoft365_archive_account "$(microsoft365_archive_run_node)" 2>/dev/null)" ;;
    foreign-home)  printf 'everything is installed, but this run has a sandboxed HOME ($HOME is not your real home) and launchctl ignores $HOME, so loading the hourly job would put it in your REAL launchd domain; nothing was loaded.' ;;
    label-taken)   printf 'launchd already runs a job named %s from another plist (%s), and replacing it is your call, not mine.' \
                     "$MICROSOFT365_ARCHIVE_LABEL" "$(microsoft365_archive_short_path "$(microsoft365_archive_loaded_path)")" ;;
    background-off) printf 'macOS has the hourly archive job (%s) switched off in System Settings › General › Login Items, so launchd will not run it; turn on "Allow in the Background" for it, then run this again. If the switch is greyed out, your organization manages it: ask IT.' "$MICROSOFT365_ARCHIVE_LABEL" ;;
    *)             printf 'the meeting archive engine, its wrapper, its LaunchAgent and the archive folder are not all in place yet.' ;;
  esac
}

gesture_microsoft365_archive() {
  local node id pre
  microsoft365_archive_pick >/dev/null 2>&1
  microsoft365_archive_tls_load
  case "$(microsoft365_archive_gate_reason)" in
    node)          microsoft365_archive_rerun microsoft365 ;;       # it fetches the pinned node
    tls-untrusted) : ;;                                              # IT's certificate: no command exists
    server)        microsoft365_archive_rerun microsoft365 ;;
    server-named)  : ;;   # the right path is the person's to name; a command with one filled in would guess it
    relative-root|cloud|root-in-engine)
                   # shellcheck disable=SC2016   # $HOME is for the person's shell to expand
                   microsoft365_archive_rerun microsoft365_archive 'BOOTSTRAP_ARCHIVE_DIR="$HOME/Microsoft365Archive"' ;;
    account-none|account-signed-out)
      # The sign-in command for the server in use, spelled the way microsoft365 prints its own.
      node="$(microsoft365_archive_run_node)" || return 0
      id="$(microsoft365_archive_client_id)"
      pre="MS365_MCP_TENANT_ID=$(microsoft365_archive_tenant)"
      [ -n "$id" ] && pre="$pre MS365_MCP_CLIENT_ID=$id"
      printf '%s "%s" "%s" --login' "$pre" "$(microsoft365_archive_short_path "$node")" \
        "$(microsoft365_archive_short_path "$(microsoft365_archive_server)")" ;;
    account-many)  : ;;   # the choice IS the step: a command with one account filled in would make it for you
    foreign-home)  microsoft365_archive_rerun microsoft365_archive ;;       # from your own account, with no HOME override
    label-taken)   printf 'launchctl bootout %s/%s' "$(microsoft365_archive_domain)" "$MICROSOFT365_ARCHIVE_LABEL" ;;
    background-off) printf 'open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"' ;;
    *)             # On demand, the one thing left to do is run it.
                   [ "$(microsoft365_archive_schedule)" = off ] && [ -f "$(microsoft365_archive_plist)" ] && microsoft365_archive_run_once ;;
  esac
}

install_microsoft365_archive() {
  local node dir root account written list src parts rel stage out rc tmp f lp i
  microsoft365_archive_node >/dev/null || { bootstrap_warn "microsoft365_archive: no node 20+ on this Mac"; return 1; }
  microsoft365_archive_tls_load
  [ "$MICROSOFT365_ARCHIVE_TLS_RC" = 2 ] && { bootstrap_warn "microsoft365_archive: TLS to Microsoft is intercepted by a certificate this Mac does not trust"; return 1; }
  microsoft365_archive_pick >/dev/null 2>&1
  microsoft365_archive_server >/dev/null || { bootstrap_warn "microsoft365_archive: no Softeria server here runs as one (BOOTSTRAP_MICROSOFT_SERVER, the microsoft365 module's, the ms365 one in \$HOME/.claude.json)"; return 1; }
  node="$(microsoft365_archive_run_node)" || return 1
  root="$(microsoft365_archive_root)"
  microsoft365_archive_root_shape_ok "$root" || { bootstrap_warn "microsoft365_archive: BOOTSTRAP_ARCHIVE_DIR must be an absolute path with no . or .. segment: $root"; return 1; }
  microsoft365_archive_under_cloud "$root" && { bootstrap_warn "microsoft365_archive: refusing an archive folder inside a synced folder: $root"; return 1; }
  microsoft365_archive_root_in_engine "$root" && { bootstrap_warn "microsoft365_archive: refusing an archive folder inside this module's own folder, which uninstall deletes: $root"; return 1; }
  dir="$(microsoft365_archive_dir)"
  mkdir -p "$dir" 2>/dev/null || { bootstrap_warn "microsoft365_archive: cannot create $dir"; return 1; }

  tmp="$(mktemp -t microsoft365archivechoice)" || return 1
  if [ -n "${BOOTSTRAP_ARCHIVE_DIR:-}" ]; then
    printf '%s\n' "$root" > "$tmp"; microsoft365_archive_land "$tmp" "$(microsoft365_archive_chosen_root_file)" 644
  fi
  if [ -n "${BOOTSTRAP_MICROSOFT_ACCOUNT:-}" ]; then
    printf '%s\n' "$BOOTSTRAP_MICROSOFT_ACCOUNT" > "$tmp"; microsoft365_archive_land "$tmp" "$(microsoft365_archive_chosen_account_file)" 644
  fi
  # Reached only once the named server has RUN as one (the pick above), so a mistyped path is never kept.
  if [ -n "${BOOTSTRAP_MICROSOFT_SERVER:-}" ]; then
    printf '%s\n' "$BOOTSTRAP_MICROSOFT_SERVER" > "$tmp"; microsoft365_archive_land "$tmp" "$(microsoft365_archive_chosen_server_file)" 644
  fi
  if [ -n "${BOOTSTRAP_MICROSOFT365_ARCHIVE_SCHEDULE:-}" ]; then
    microsoft365_archive_schedule > "$tmp"; printf '\n' >> "$tmp"
    microsoft365_archive_land "$tmp" "$(microsoft365_archive_chosen_schedule_file)" 644
  fi
  rm -f "$tmp" 2>/dev/null

  # ── the engine: staged whole, PROVEN on this node, and only then landed ──────────────────
  src="$(microsoft365_archive_source)" || { bootstrap_warn "microsoft365_archive: the release tree has no assets/microsoft365-archive (BOOTSTRAP_ASSETS)"; return 1; }
  parts="$(microsoft365_archive_parts "$src")" || { bootstrap_warn "microsoft365_archive: cannot list assets/microsoft365-archive"; return 1; }
  stage="$(mktemp -d "$(microsoft365_archive_state_dir)/microsoft365-archive-stage.XXXXXX")" || return 1
  for rel in $parts; do
    mkdir -p "$(dirname "$stage/$rel")" 2>/dev/null && cp -f "$src/microsoft365-archive/$rel" "$stage/$rel" 2>/dev/null \
      || { rm -rf "$stage"; bootstrap_warn "microsoft365_archive: cannot stage $rel"; return 1; }
  done
  cp -f "$src/markdown-convert.sh" "$stage/markdown-convert.sh" 2>/dev/null || { rm -rf "$stage"; return 1; }
  out="$(microsoft365_archive_bounded "$node" 20000 "$node" "$stage/archive.js" --version 2>/dev/null)" || out=""
  [ "$out" = "$MICROSOFT365_ARCHIVE_VERSION_LINE" ] || {
    rm -rf "$stage"; bootstrap_warn "microsoft365_archive: the engine answered --version with \"$out\" — not installing it"; return 1; }
  microsoft365_archive_bounded "$node" 180000 "$node" "$stage/archive.js" --selftest >&2 || {
    rm -rf "$stage"; bootstrap_warn "microsoft365_archive: the engine failed its selftest on $node — not installing it"; return 1; }
  for rel in $parts; do
    microsoft365_archive_land "$stage/$rel" "$dir/$rel" 644 || { rm -rf "$stage"; bootstrap_warn "microsoft365_archive: cannot install $rel"; return 1; }
  done
  microsoft365_archive_land "$stage/markdown-convert.sh" "$(microsoft365_archive_converter)" 755 || { rm -rf "$stage"; return 1; }
  rm -rf "$stage" 2>/dev/null
  # A fixture a newer release dropped must not linger and change what the selftest reads.
  if [ -d "$dir/fixtures" ]; then
    while IFS= read -r f; do
      case "
$parts
" in *"
$f
"*) : ;; *) rm -f "$dir/$f" 2>/dev/null ;; esac
    done <<EOF
$(cd "$dir" && find fixtures -type f 2>/dev/null)
EOF
  fi
  # The download cache an older release kept for its own fetch is dead weight now.
  rm -rf "$dir/.fetched" 2>/dev/null

  # ── the archive folder, then the generated files ─────────────────────────────────────────
  # The folder first, and judged again once it EXISTS (its real path is then fully resolved), before
  # any config names it or any job is loaded to write into it.
  mkdir -p "$root" 2>/dev/null || { bootstrap_warn "microsoft365_archive: cannot create the archive folder $root"; return 1; }
  if microsoft365_archive_under_cloud "$root" || microsoft365_archive_root_in_engine "$root"; then
    bootstrap_warn "microsoft365_archive: the archive folder $root resolves inside a synced folder or this module's own — not using it"; return 1
  fi
  list="$(microsoft365_archive_account_candidates "$node" 2>/dev/null)" || list=""
  account="$(microsoft365_archive_account_from "$list")" || account=""
  # With no account to name this run (every account signed out, or several and none chosen), the
  # config keeps the one it already holds: rewriting a working config without account= would stop the
  # loaded hourly job for good, while the held account may simply sign back in.
  written="$account"
  [ -n "$written" ] || written="$(microsoft365_archive_held_account)"
  tmp="$(mktemp -t microsoft365archivegen)" || return 1
  microsoft365_archive_wrapper_text "$node" > "$tmp"
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_wrapper)" 755 || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: cannot write the wrapper"; return 1; }
  microsoft365_archive_config_text "$node" "$written" > "$tmp"
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_config)" 644 || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: cannot write the config"; return 1; }
  rm -f "$tmp" 2>/dev/null

  tmp="$(mktemp -t microsoft365archiveplist)" || return 1
  microsoft365_archive_plist_build "$tmp" || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: plutil could not build the LaunchAgent"; return 1; }
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_plist)" 644 || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: cannot write the LaunchAgent"; return 1; }
  rm -f "$tmp" 2>/dev/null
  microsoft365_archive_plist_ok || { bootstrap_warn "microsoft365_archive: the LaunchAgent does not read back as written"; return 1; }

  # Everything reversible is done. What remains is a gate the installer has now DISCOVERED: return
  # non-zero and the driver re-asks gate_, which reports it as NEEDS_HUMAN.
  [ -n "$account" ] || return 3
  microsoft365_archive_signed_in "$account" "$list" || return 3
  microsoft365_archive_home_ok || return 3
  microsoft365_archive_label_taken && return 3
  microsoft365_archive_background_off && return 3

  # ── launchd: re-load when what it holds is not THIS plist, load when it is not loaded ─────────
  # "What it holds" is the sha256 recorded after the last successful load — not whether this run
  # happened to rewrite the file: a run that landed a new plist and then stopped at a gate would
  # otherwise leave launchd on the old definition for good, since the next run finds the file current.
  if microsoft365_archive_loaded_ours && ! microsoft365_archive_loaded_current; then
    /bin/launchctl bootout "$(microsoft365_archive_domain)/$MICROSOFT365_ARCHIVE_LABEL" >/dev/null 2>&1
    i=0
    while microsoft365_archive_loaded_ours && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
  fi
  if ! microsoft365_archive_loaded_ours; then
    # A bootstrap straight after a bootout can race launchd's teardown (EIO), so it is retried.
    i=0; rc=1
    while [ "$i" -lt 5 ]; do
      /bin/launchctl bootstrap "$(microsoft365_archive_domain)" "$(microsoft365_archive_plist)" >/dev/null 2>&1; rc=$?
      [ "$rc" = 0 ] && break
      microsoft365_archive_loaded_ours && { rc=0; break; }
      i=$((i + 1)); sleep 1
    done
    [ "$rc" = 0 ] || { bootstrap_warn "microsoft365_archive: launchctl bootstrap failed (rc $rc)"; return 1; }
  fi
  lp="$(microsoft365_archive_loaded_path)" || lp=""
  microsoft365_archive_loaded_ours || { bootstrap_warn "microsoft365_archive: launchd does not hold the job from our plist (it reports: ${lp:-nothing})"; return 1; }
  tmp="$(mktemp -t microsoft365archiveloaded)" || return 1
  microsoft365_archive_plist_sha > "$tmp" && printf '\n' >> "$tmp"
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_loaded_marker)" 644 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp" 2>/dev/null
  return 0
}

# uninstall_ unloads the job (only one loaded from OUR plist — a job another HOME loaded under the
# same label is not ours to stop), and removes the plist, the wrapper and the engine directory.
# It NEVER deletes the archive folder: that is the user's data — meeting transcripts and notes that
# may no longer exist at Microsoft — and removing a tool must never remove what the tool collected.
uninstall_microsoft365_archive() {
  local rc=0 i dir f root
  root="$(microsoft365_archive_root)"                     # read before chosen-archive-dir goes
  if microsoft365_archive_loaded_ours; then
    /bin/launchctl bootout "$(microsoft365_archive_domain)/$MICROSOFT365_ARCHIVE_LABEL" >/dev/null 2>&1
    i=0
    while microsoft365_archive_loaded_ours && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
    microsoft365_archive_loaded_ours && { bootstrap_warn "microsoft365_archive: launchd still holds the job after bootout"; rc=1; }
  fi
  rm -f "$(microsoft365_archive_plist)" "$(microsoft365_archive_wrapper)" 2>/dev/null
  dir="$(microsoft365_archive_dir)"
  if microsoft365_archive_root_in_engine "$(microsoft365_archive_root)"; then
    # The archive folder was put INSIDE the engine folder (install refuses that now; an older one did
    # not). The folder cannot go without the archive going with it, so only this module's own files
    # are removed, by name, and the folder is left holding the archive.
    for f in $MICROSOFT365_ARCHIVE_ENGINE_FILES package.json MANIFEST markdown-convert.sh config chosen-account \
             chosen-archive-dir chosen-server chosen-schedule launchd.log loaded-plist.sha256; do
      rm -f "$dir/$f" 2>/dev/null
    done
    rm -rf "$dir/fixtures" "$dir/.fetched" 2>/dev/null
    bootstrap_warn "microsoft365_archive: $dir holds the archive folder $(microsoft365_archive_root), so only the engine's own files were removed from it"
    for f in $MICROSOFT365_ARCHIVE_ENGINE_FILES config; do [ -e "$dir/$f" ] && rc=1; done
  else
    rm -rf "$dir" 2>/dev/null
    [ -e "$dir" ] && rc=1
  fi
  [ -e "$(microsoft365_archive_plist)" ] && rc=1
  [ -e "$(microsoft365_archive_wrapper)" ] && rc=1
  # The copies stay, and the person is told where, and how to remove them too.
  f="$(microsoft365_archive_kept_line "$root")"
  [ -n "$f" ] && bootstrap_warn "microsoft365_archive: $f"
  return "$rc"
}
