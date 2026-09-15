# shellcheck shell=bash
# microsoft365 — Outlook mail, calendar, contacts and OneDrive for BOTH agents, through a LOCAL MCP server.
#
# Installs Softeria's @softeria/ms-365-mcp-server, at a pinned version, into
# $BOOTSTRAP_STATE_DIR/microsoft365/ and registers it with Claude Code ($HOME/.claude.json) and
# Copilot CLI ($HOME/.copilot/mcp-config.json) — both through the ONE writer, bootstrap_settings_merge.
#
# WHERE THE TRAFFIC GOES, because a corporate reader will ask first: the server is a node process
# each agent starts itself and talks to over stdio pipes. It calls exactly two hosts,
# graph.microsoft.com and login.microsoftonline.com (measured by listing every URL in its dist/);
# there is no relay, no hosted component and no telemetry. What it does NOT change: whatever a tool
# returns enters the model's context, and that goes to the agent's model provider.
#
# WHY A WORK ACCOUNT BY DEFAULT: the target is a corporate Mac with a corporate Outlook, so the
# tenant is `organizations` (any work or school account). BOOTSTRAP_MICROSOFT_TENANT overrides it —
# the company's tenant id, or `consumers` for a personal Outlook.com account, which the server's own
# README says must not use `common` (since June 2026 a `common` refresh token dies about an hour in).
# The choice is written to disk at install, because a later cold `verify` has no environment.
#
# WHY NO --org-mode: org mode adds Teams, SharePoint and the directory, and its ~60 Graph scopes
# include several only a tenant admin can grant (Directory.Read.All, Group.ReadWrite.All,
# Sites.ReadWrite.All). The default set — 13 scopes: mail, calendar, contacts, files, notes, tasks —
# is the one a user can most often approve alone. When the tenant refuses Softeria's app outright,
# IT registers its own and BOOTSTRAP_MICROSOFT_CLIENT_ID carries that app's id (public, not a secret).
#
# THE SIGN-IN IS THE HUMAN'S. It is a device-code flow in a browser, and the token it produces is a
# credential; this module never performs it and never reads it. It is the gate this module reports.
#
# THE AGENT NEVER SENDS MAIL ON ITS OWN SAY-SO. assets/hooks/guard-mail-send.sh is installed beside
# the server and wired on both agents (PreToolUse + UserPromptSubmit) BEFORE the server is
# registered, so the send tools are never reachable unguarded: compose-and-send is denied outright,
# a draft may be sent only in a later turn than the one that wrote it, graph-batch may only batch
# GETs, the tools that delete or switch the sign-in are refused, and so is every other call that
# puts data in front of another person at once — a share, a public link, a forwarding rule, an
# invitation with attendees, a reply to an organizer. The guard's header carries the measurements.
# Without it this module is not satisfied.
#
# No permission, no credential, no allow-list keypath is written here or anywhere below.

MICROSOFT365_SERVER_VERSION="0.143.0"
MICROSOFT365_PACKAGE="@softeria/ms-365-mcp-server"
# The registration key. It is the name the package's own README registers it under, and it becomes
# the tool-name prefix (mcp__ms365__send-mail …) that any email guard hook matches on — so it is
# the vendor's spelling, kept, not one of ours.
MICROSOFT365_SERVER_KEY="ms365"

microsoft365_dir()      { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/microsoft365"; }
microsoft365_entry()    { printf '%s/node_modules/%s/dist/index.js' "$(microsoft365_dir)" "$MICROSOFT365_PACKAGE"; }
microsoft365_claude_config()  { printf '%s' "$HOME/.claude.json"; }
microsoft365_copilot_config() { printf '%s' "$HOME/.copilot/mcp-config.json"; }
microsoft365_guard()          { printf '%s/hooks/guard-mail-send.sh' "$(microsoft365_dir)"; }
microsoft365_claude_settings() { printf '%s' "$HOME/.claude/settings.json"; }
# Copilot loads every file in hooks/ (measured with a probe file of another name), so the guard gets
# its own file and never shares one with the hooks module's 00-lifecycle.json.
microsoft365_copilot_hooks()   { printf '%s' "$HOME/.copilot/hooks/microsoft365-mail.json"; }
# Claude Code matches PreToolUse on tool_name, so only this server's tools spawn the guard there.
# Copilot's names are ms365-<tool> and its matcher semantics were not measured, so its rows carry
# no matcher — every tool — and the guard's own fast path drops the rest.
MICROSOFT365_CLAUDE_MATCHER="mcp__ms365__.*"
MICROSOFT365_GUARD_EVENTS="PreToolUse UserPromptSubmit"

# The tenant and client id in force: the environment when set, else what install_ recorded, else the
# work-account default. Every verb re-derives them this way, so verify agrees with what install wrote.
microsoft365_tenant() {
  local f
  [ -n "${BOOTSTRAP_MICROSOFT_TENANT:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_TENANT"; return 0; }
  f="$(microsoft365_dir)/tenant"
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  printf 'organizations'
}
microsoft365_client_id() {
  local f
  [ -n "${BOOTSTRAP_MICROSOFT_CLIENT_ID:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_CLIENT_ID"; return 0; }
  f="$(microsoft365_dir)/client-id"
  [ -s "$f" ] && head -n 1 "$f"
  return 0
}

# ── node ─────────────────────────────────────────────────────────────────────────────────────
# The floor is the server's dependency tree's, not the server's own: 0.143.0 says node >= 18, but the
# @azure/msal-node 5.6.0 it installs says >= 20 (both read from the installed package.json files).
MICROSOFT365_NODE_FLOOR=20
# When this Mac has no usable node, the module fetches one: no Homebrew, no admin, nothing outside
# $BOOTSTRAP_STATE_DIR. The current LTS, pinned by nodejs.org's own SHASUMS256.txt for that release,
# copied here by hand because base macOS has no gpg to check the signed file. The builds are
# Developer ID signed, and a file curl writes carries no quarantine flag, so no Gatekeeper prompt —
# which is why the hash is not optional. Both builds need macOS 13.5 or later.
MICROSOFT365_NODE_VERSION="24.21.0"
MICROSOFT365_NODE_SHA256_ARM64="6239d4cf92d864487ec8cd3615038f7b67e7f58b77b21cd2f09ea9fbd68065fe"
MICROSOFT365_NODE_SHA256_X64="0ae5a24c24bb7d015cd816c5036b3f90f2945aa872fcf54e58da054753b3a299"
MICROSOFT365_NODE_MIN_MACOS="13.5"

# microsoft365_node_ok <path> — an executable node at or above the floor, at a path that SURVIVES a
# node upgrade. Homebrew's bin/ symlinks are repointed by `brew upgrade`, fnm's aliases/default by
# `fnm default`, and the pinned node's bin/ link by the next pin. fnm's per-shell fnm_multishells
# path disappears with the shell and takes the server with it, with no error anyone would see.
microsoft365_node_ok() {
  local c="$1" major
  [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ] || return 1
  case "$c" in */fnm_multishells/*) return 1 ;; esac
  major="$("$c" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge "$MICROSOFT365_NODE_FLOOR" ]
}

# microsoft365_node — the node this module runs, or rc 1. The library's search comes first (the pinned
# copy, Homebrew's two prefixes, PATH); the fixed list after it is there because that search stops at
# its first hit, and a first hit below the floor must not hide a usable node behind it.
microsoft365_node() {
  local c
  for c in "$(bootstrap_find_tool node 2>/dev/null)" "$(bootstrap_tools_dir)/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node \
           "$HOME/Library/Application Support/fnm/aliases/default/bin/node" \
           "$(command -v node 2>/dev/null)"; do
    microsoft365_node_ok "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# microsoft365_node_arch — nodejs.org's name for this Mac's CPU. Apple silicon is asked of the kernel,
# because a shell running under Rosetta answers x86_64 to uname.
microsoft365_node_arch() {
  [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && { printf 'arm64'; return 0; }
  [ "$(/usr/bin/uname -m 2>/dev/null)" = x86_64 ] && { printf 'x64'; return 0; }
  return 1
}
microsoft365_node_home() { printf '%s/node-v%s-darwin-%s' "$(bootstrap_tools_dir)" "$MICROSOFT365_NODE_VERSION" "$1"; }

# microsoft365_macos_ok — rc 0 iff this macOS runs the pinned node (13.5 or later).
microsoft365_macos_ok() {
  local v major minor
  v="$(/usr/bin/sw_vers -productVersion 2>/dev/null)" || return 1
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  case "$major$minor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -gt 13 ] || { [ "$major" = 13 ] && [ "$minor" -ge 5 ]; }
}

# A fetch that failed is recorded with the DRIVER's pid — every verb of one run is a subshell of it, so
# $$ is the same in all of them — and only that run's gate_ reports it. A later run tries again,
# which is the whole point of re-running.
microsoft365_node_marker() { printf '%s/node-fetch-failed' "$(microsoft365_dir)"; }

# microsoft365_node_blocked — one token naming why no node can be had, or rc 1: this macOS is too old
# for the pinned build, there is no build for this CPU, or this run's fetch failed (not-fetched: the
# download did not complete; refused: it did, and its sha256 was not the pinned one).
microsoft365_node_blocked() {
  local m pid why
  microsoft365_node >/dev/null 2>&1 && return 1
  microsoft365_macos_ok || { printf 'macos-old'; return 0; }
  microsoft365_node_arch >/dev/null || { printf 'no-build'; return 0; }
  m="$(microsoft365_node_marker)"
  [ -s "$m" ] || return 1
  read -r pid why < "$m" 2>/dev/null || return 1
  [ "$pid" = "$$" ] || return 1
  printf '%s' "${why:-not-fetched}"
}

# microsoft365_node_fetch — the pinned node, into $(bootstrap_tools_dir), linked as tools/bin/node and
# tools/bin/npm (the library's search looks there first). Verified by EXECUTING it, never by tar's rc.
microsoft365_node_fetch() {
  local arch sha home tools tarball stage rc m
  tools="$(bootstrap_tools_dir)"; m="$(microsoft365_node_marker)"
  mkdir -p "$(microsoft365_dir)" "$tools/bin" 2>/dev/null || return 1
  microsoft365_macos_ok || { printf '%s macos-old\n' "$$" > "$m"; return 1; }
  arch="$(microsoft365_node_arch)" || { printf '%s no-build\n' "$$" > "$m"; return 1; }
  case "$arch" in arm64) sha="$MICROSOFT365_NODE_SHA256_ARM64" ;; *) sha="$MICROSOFT365_NODE_SHA256_X64" ;; esac
  home="$(microsoft365_node_home "$arch")"
  if [ "$("$home/bin/node" --version 2>/dev/null)" != "v$MICROSOFT365_NODE_VERSION" ]; then
    tarball="$tools/.node-v$MICROSOFT365_NODE_VERSION-darwin-$arch.tar.xz"
    bootstrap_fetch_pinned "https://nodejs.org/dist/v$MICROSOFT365_NODE_VERSION/node-v$MICROSOFT365_NODE_VERSION-darwin-$arch.tar.xz" \
      "$sha" "$tarball"; rc=$?
    case "$rc" in
      0) : ;;
      2) printf '%s refused\n' "$$" > "$m"; return 1 ;;
      *) printf '%s not-fetched\n' "$$" > "$m"; return 1 ;;
    esac
    stage="$tools/.node-stage.$$"
    rm -rf "$stage"; mkdir -p "$stage" 2>/dev/null || { rm -f "$tarball"; return 1; }
    /usr/bin/tar -xf "$tarball" -C "$stage" 2>/dev/null
    rm -f "$tarball"
    [ "$("$stage/${home##*/}/bin/node" --version 2>/dev/null)" = "v$MICROSOFT365_NODE_VERSION" ] || {
      rm -rf "$stage"; printf '%s not-fetched\n' "$$" > "$m"
      bootstrap_warn "microsoft365: the node $MICROSOFT365_NODE_VERSION archive unpacked, but its node does not run"; return 1; }
    rm -rf "$home"; mv -f "$stage/${home##*/}" "$home" 2>/dev/null || { rm -rf "$stage"; return 1; }
    rm -rf "$stage"
  fi
  # Relative links, so the whole state dir can move; npm's own bin/ entry is itself a link into lib/.
  ln -sfn "../${home##*/}/bin/node" "$tools/bin/node" && ln -sfn "../${home##*/}/bin/npm" "$tools/bin/npm" || return 1
  [ "$("$tools/bin/node" -p 'process.versions.node' 2>/dev/null)" = "$MICROSOFT365_NODE_VERSION" ] || return 1
  rm -f "$m" 2>/dev/null
  return 0
}

# ── TLS ──────────────────────────────────────────────────────────────────────────────────────
# Behind a TLS-inspecting proxy every node process of this module fails with
# UNABLE_TO_GET_ISSUER_CERT_LOCALLY — npm, the server each agent starts, verify's own runs of it —
# because node ships its own roots and ignores the keychain. bootstrap_node_ca_env answers, per host,
# with the variable that fixes it. Proxies bypass inspection per host, so each host a node process
# here talks to is asked: Microsoft's two always, npm's registry until the package is installed.
# BOOTSTRAP_TLS_PROBE_URL, when set, replaces every one of them (a test seam).
#
# The answer is loaded ONCE per verb, at the verb's top (never inside $(…), whose subshell would
# forget it), because each probe is two HTTPS requests.
MICROSOFT365_TLS_LOADED=""; MICROSOFT365_TLS_VAR=""; MICROSOFT365_TLS_RC=1
microsoft365_tls_load() {
  local urls u out rc known=1 untrusted=0
  [ -n "$MICROSOFT365_TLS_LOADED" ] && return 0
  if [ -n "${BOOTSTRAP_TLS_PROBE_URL:-}" ]; then urls="$BOOTSTRAP_TLS_PROBE_URL"
  else
    urls="https://login.microsoftonline.com/ https://graph.microsoft.com/"
    # The package on disk, not microsoft365_installed: that one RUNS the server, which asks for this.
    [ -f "$(microsoft365_entry)" ] || urls="$urls https://registry.npmjs.org/"
  fi
  MICROSOFT365_TLS_VAR=""
  for u in $urls; do
    out="$(bootstrap_node_ca_env "$u" 2>/dev/null)"; rc=$?
    case "$rc" in
      0) known=0; [ -n "$out" ] && MICROSOFT365_TLS_VAR="$out" ;;
      2) untrusted=1 ;;
    esac
  done
  MICROSOFT365_TLS_RC="$known"; [ "$untrusted" = 1 ] && MICROSOFT365_TLS_RC=2
  MICROSOFT365_TLS_LOADED=1
}
microsoft365_tls_untrusted() { microsoft365_tls_load; [ "$MICROSOFT365_TLS_RC" = 2 ]; }

# microsoft365_ca_path — the PEM every node process here is started with, or nothing: the one this
# network needs now, else one an earlier run exported. It STAYS once exported: a laptop set up behind
# the office proxy and verified at home would otherwise lose it, and the server would fail the moment
# the laptop was back at the office. The PEM holds only roots the OS itself trusts, so keeping it
# trusts nothing new. (The path is the one bootstrap_node_ca_env writes.)
microsoft365_ca_path() {
  local pem
  microsoft365_tls_load
  [ -n "$MICROSOFT365_TLS_VAR" ] && { printf '%s' "${MICROSOFT365_TLS_VAR#NODE_EXTRA_CA_CERTS=}"; return 0; }
  pem="${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/trusted-roots.pem"
  [ -s "$pem" ] && printf '%s' "$pem"
  return 0
}

# microsoft365_env_json — the env block both registrations carry. NODE_EXTRA_CA_CERTS is a path to
# public certificates, not a credential, and the one writer accepts it (it refuses *KEY*, *TOKEN*,
# *SECRET*, *PASSWORD*, *CREDENTIAL* and *AUTH* keypaths under env).
microsoft365_env_json() {
  local id ca out
  id="$(microsoft365_client_id)"; ca="$(microsoft365_ca_path)"
  # MS365_MCP_ORG_MODE pinned OFF: "1" or "true" inherited from the agent's environment would switch the
  # server into org mode, which adds Teams send tools. The guard refuses those too; this keeps them unoffered.
  out="{\"MS365_MCP_TENANT_ID\":\"$(bootstrap_json_escape "$(microsoft365_tenant)")\",\"MS365_MCP_ORG_MODE\":\"0\""
  [ -n "$id" ] && out="$out,\"MS365_MCP_CLIENT_ID\":\"$(bootstrap_json_escape "$id")\""
  [ -n "$ca" ] && out="$out,\"NODE_EXTRA_CA_CERTS\":\"$(bootstrap_json_escape "$ca")\""
  printf '%s}' "$out"
}

# microsoft365_run <node> <args…> — run the INSTALLED server the way an agent will: same tenant, same
# client id, same CA file. Logs go to a throwaway directory so a verify writes nothing into $HOME; the
# token cache stays at its default, because the sign-in check must read the real one.
microsoft365_run() {
  local node="$1" logs rc id ca; shift
  logs="$(mktemp -d -t microsoft365logs)" || return 1
  id="$(microsoft365_client_id)"; ca="$(microsoft365_ca_path)"
  set -- MS365_MCP_LOG_DIR="$logs" MS365_MCP_ORG_MODE=0 MS365_MCP_TENANT_ID="$(microsoft365_tenant)" "$node" "$@"
  [ -n "$id" ] && set -- MS365_MCP_CLIENT_ID="$id" "$@"
  [ -n "$ca" ] && set -- NODE_EXTRA_CA_CERTS="$ca" "$@"
  /usr/bin/env "$@"; rc=$?
  rm -rf "$logs" 2>/dev/null
  return "$rc"
}

# microsoft365_probe <node> <method> — speak MCP to the installed server over stdio, exactly as an
# agent does, and print the tool names it answers <method> with. rc 0 only when it listed tools.
# Written in node rather than as a shell pipe: a pipe closes stdin, and the server exits on EOF, so
# whether the answer lands first is a race. This waits for the reply by id, with a 20 s ceiling.
MICROSOFT365_PROBE_JS='
const {spawn} = require("child_process");
const [entry, method] = process.argv.slice(1);
const p = spawn(process.execPath, [entry], {stdio: ["pipe", "pipe", "ignore"]});
const send = (m) => p.stdin.write(JSON.stringify(Object.assign({jsonrpc: "2.0"}, m)) + "\n");
const t = setTimeout(() => { p.kill(); process.exit(2); }, 20000);
let buf = "";
p.stdout.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    let m; try { m = JSON.parse(line); } catch (e) { continue; }
    if (m.id === 1) { send({method: "notifications/initialized"}); send({id: 2, method: method}); }
    else if (m.id === 2) {
      clearTimeout(t);
      const tools = (m.result && m.result.tools) || [];
      process.stdout.write(tools.map((x) => x.name).join("\n"));
      p.kill(); process.exit(tools.length ? 0 : 1);
    }
  }
});
p.on("exit", () => process.exit(3));
send({id: 1, method: "initialize", params: {protocolVersion: "2025-06-18", capabilities: {},
      clientInfo: {name: "mac-bootstrap-probe", version: "1"}}});
'
microsoft365_probe() {
  local node="$1" method="$2"
  microsoft365_run "$node" -e "$MICROSOFT365_PROBE_JS" "$(microsoft365_entry)" "$method" 2>/dev/null
}

# microsoft365_signed_in <node> — rc 0 iff the server holds a working token for this tenant.
# `--verify-login` exits 0 on FAILURE too (measured: rc 0 with {"success":false,…}), so its rc is
# worthless and the JSON is parsed instead — through plutil, a different engine from the server.
# It asks Microsoft, so it runs last in verify_, after every local check has already passed.
MICROSOFT365_LOGIN_JS='
const r = require("child_process").spawnSync(process.execPath, [process.argv[1], "--verify-login"],
  {timeout: 30000, encoding: "utf8"});
process.stdout.write(String(r.stdout || ""));
'
#
# …and `--verify-login` alone cannot say NO across tenants: measured, it reports success for ANY
# cached account, even with a tenant id nobody has. So the account the server will use must first
# belong to the configured tenant (microsoft365_account_in_tenant), or a personal Outlook.com
# sign-in left on the Mac would read as the work account.
MICROSOFT365_PERSONAL_TENANT="9188040d-6c67-4c5b-b112-36a304b66dad"   # every personal Microsoft account

# microsoft365_account_in_tenant <node> — rc 0 iff the account the server will use (the one marked
# selected, or the only one) sits in the configured tenant. `--list-accounts` is local: each id is
# MSAL's homeAccountId, "<object id>.<tenant id>". A tenant given as a domain name cannot be mapped
# to an id without asking Microsoft, so it accepts any work account.
microsoft365_account_in_tenant() {
  local node="$1" tmp n i id sel tid want
  tmp="$(mktemp -t microsoft365accounts)" || return 1
  microsoft365_run "$node" "$(microsoft365_entry)" --list-accounts 2>/dev/null | grep '^{' | tail -n 1 > "$tmp"
  n="$(bootstrap_settings_get "$tmp" accounts raw 2>/dev/null)" || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  id=""; i=0
  while [ "$i" -lt "$n" ]; do
    sel="$(bootstrap_settings_get "$tmp" "accounts.$i.selected" raw 2>/dev/null)" || sel=""
    [ "$sel" = "true" ] && { id="$(bootstrap_settings_get "$tmp" "accounts.$i.id" raw 2>/dev/null)"; break; }
    i=$((i+1))
  done
  [ -z "$id" ] && [ "$n" = 1 ] && id="$(bootstrap_settings_get "$tmp" accounts.0.id raw 2>/dev/null)"
  rm -f "$tmp" 2>/dev/null
  [ -n "$id" ] || return 1
  tid="${id##*.}"
  want="$(microsoft365_tenant)"
  case "$want" in
    common)        return 0 ;;
    organizations) [ "$tid" != "$MICROSOFT365_PERSONAL_TENANT" ] ;;
    consumers)     [ "$tid" = "$MICROSOFT365_PERSONAL_TENANT" ] ;;
    *-*-*-*-*)     [ "$tid" = "$want" ] ;;
    *)             [ "$tid" != "$MICROSOFT365_PERSONAL_TENANT" ] ;;
  esac
}

microsoft365_signed_in() {
  local node="$1" out line tmp ok
  microsoft365_account_in_tenant "$node" || return 1
  out="$(microsoft365_run "$node" -e "$MICROSOFT365_LOGIN_JS" "$(microsoft365_entry)" 2>/dev/null)" || return 1
  line="$(printf '%s\n' "$out" | grep '^{"success"' | tail -n 1)"
  [ -n "$line" ] || return 1
  tmp="$(mktemp -t microsoft365login)" || return 1
  printf '%s' "$line" > "$tmp"
  ok="$(bootstrap_settings_get "$tmp" success raw 2>/dev/null)" || ok=""
  rm -f "$tmp" 2>/dev/null
  [ "$ok" = "true" ]
}

# microsoft365_registered <file> <type> — rc 0 iff <file> registers OUR server, whole and current:
# the type the agent expects, this Mac's node, our entry as the only argument, and exactly the env
# block in force (a client id recorded but not registered is a mismatch, and so is the reverse).
microsoft365_registered() {
  local f="$1" type="$2" node="$3" k id
  k="mcpServers.$MICROSOFT365_SERVER_KEY"
  [ -f "$f" ] || return 1
  [ "$(bootstrap_settings_get "$f" "$k.type" raw 2>/dev/null)" = "$type" ] || return 1
  [ "$(bootstrap_settings_get "$f" "$k.command" raw 2>/dev/null)" = "$node" ] || return 1
  [ "$(bootstrap_settings_get "$f" "$k.args" raw 2>/dev/null)" = "1" ] || return 1
  [ "$(bootstrap_settings_get "$f" "$k.args.0" raw 2>/dev/null)" = "$(microsoft365_entry)" ] || return 1
  [ "$(bootstrap_settings_get "$f" "$k.env.MS365_MCP_TENANT_ID" raw 2>/dev/null)" = "$(microsoft365_tenant)" ] || return 1
  [ "$(bootstrap_settings_get "$f" "$k.env.MS365_MCP_ORG_MODE" raw 2>/dev/null)" = 0 ] || return 1
  id="$(microsoft365_client_id)"
  [ "$(bootstrap_settings_get "$f" "$k.env.MS365_MCP_CLIENT_ID" raw 2>/dev/null)" = "$id" ] || return 1
  [ "$(bootstrap_settings_get "$f" "$k.env.NODE_EXTRA_CA_CERTS" raw 2>/dev/null)" = "$(microsoft365_ca_path)" ] || return 1
  return 0
}

microsoft365_installed() {
  local node
  node="$(microsoft365_node)" || return 1
  [ "$(microsoft365_run "$node" "$(microsoft365_entry)" --version 2>/dev/null)" = "$MICROSOFT365_SERVER_VERSION" ]
}

# microsoft365_guard_source — the guard's bytes: the verified release tree's, else the copy an earlier
# run installed. Never a download of our own: the driver fetched and checked the tree already, and a
# module's own fetch would be the one file its manifest never saw.
microsoft365_guard_source() {
  if [ -r "${BOOTSTRAP_ASSETS:-}/hooks/guard-mail-send.sh" ]; then
    printf '%s' "${BOOTSTRAP_ASSETS}/hooks/guard-mail-send.sh"; return 0
  fi
  [ -r "$(microsoft365_guard)" ] || return 1
  printf '%s' "$(microsoft365_guard)"
}

# microsoft365_copilot_wired <file> <event> <command> — parse-based, like bootstrap_hook_present.
microsoft365_copilot_wired() {
  local i=0 b
  [ -f "$1" ] || return 1
  while [ "$i" -lt 64 ]; do
    b="$(bootstrap_settings_get "$1" "hooks.$2.$i.bash" raw 2>/dev/null)" || return 1
    [ "$b" = "$3" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# microsoft365_guarded [quick] — rc 0 iff the send guard is installed, RUNS and discriminates (its
# shipped fixtures include the negative controls: a read tool and another server's send-mail stay
# silent), and is wired for both events on both agents. verify_ and install_ always execute the
# fixtures. `quick` is for the gate/note/gesture path, which only asks whether the reversible work
# is in place, and runs once per verb: there the selftest (134 cases, ~10 s) is skipped only when the
# guard AND the library beside it are byte-identical to the verified release's, whose fixtures install_
# ran; anything else is executed.
microsoft365_guarded() {
  local g ev
  g="$(microsoft365_guard)"
  [ -x "$g" ] && [ -f "$(dirname "$g")/bootstrap-lib.sh" ] || return 1
  if [ -r "${BOOTSTRAP_ASSETS:-}/hooks/guard-mail-send.sh" ]; then
    cmp -s "${BOOTSTRAP_ASSETS}/hooks/guard-mail-send.sh" "$g" || return 1
  fi
  if [ "${1:-}" = quick ] && [ -r "${BOOTSTRAP_ASSETS:-}/hooks/guard-mail-send.sh" ] \
     && cmp -s "${BOOTSTRAP_LIB:-/nonexistent}" "$(dirname "$g")/bootstrap-lib.sh"; then
    :
  else
    /bin/bash "$g" --selftest >/dev/null 2>&1 || return 1
  fi
  for ev in $MICROSOFT365_GUARD_EVENTS; do
    bootstrap_hook_present "$(microsoft365_claude_settings)" "$ev" "$g" || return 1
    microsoft365_copilot_wired "$(microsoft365_copilot_hooks)" "$ev" "$g" || return 1
  done
  return 0
}

# microsoft365_install_guard — stage, PROVE it runs, land it with the library beside it, then wire.
microsoft365_install_guard() {
  local src g d ev
  g="$(microsoft365_guard)"; d="$(dirname "$g")"
  src="$(microsoft365_guard_source)" || { bootstrap_warn "microsoft365: cannot find or fetch assets/hooks/guard-mail-send.sh"; return 1; }
  [ -r "${BOOTSTRAP_LIB:-}" ] || { bootstrap_warn "microsoft365: BOOTSTRAP_LIB is not readable"; return 1; }
  mkdir -p "$d" 2>/dev/null || { bootstrap_warn "microsoft365: cannot create $d"; return 1; }
  cmp -s "$BOOTSTRAP_LIB" "$d/bootstrap-lib.sh" 2>/dev/null || cp -f "$BOOTSTRAP_LIB" "$d/bootstrap-lib.sh" 2>/dev/null \
    || { bootstrap_warn "microsoft365: cannot place the library beside the guard"; return 1; }
  # Staged beside the library and PROVEN before it lands: a guard that fails its own fixtures must
  # never replace a working one, nor be wired — on Copilot it sees every tool call.
  if ! cmp -s "$src" "$g" 2>/dev/null; then
    cp -f "$src" "$g.tmp" 2>/dev/null && chmod 755 "$g.tmp" 2>/dev/null || { rm -f "$g.tmp"; return 1; }
    /bin/bash "$g.tmp" --selftest >/dev/null 2>&1 || {
      rm -f "$g.tmp"; bootstrap_warn "microsoft365: the mail guard failed its self-test — not installing it"; return 1; }
    mv -f "$g.tmp" "$g" 2>/dev/null || { rm -f "$g.tmp"; return 1; }
  fi
  /bin/bash "$g" --selftest >/dev/null 2>&1 || { bootstrap_warn "microsoft365: the installed mail guard failed its self-test — not wiring it"; return 1; }
  for ev in $MICROSOFT365_GUARD_EVENTS; do
    if [ "$ev" = PreToolUse ]; then
      bootstrap_hook_wire "$(microsoft365_claude_settings)" "$ev" "$MICROSOFT365_CLAUDE_MATCHER" "$g" 10 || return 1
    else
      bootstrap_hook_wire "$(microsoft365_claude_settings)" "$ev" "" "$g" 10 || return 1
    fi
    bootstrap_copilot_hook_wire "$(microsoft365_copilot_hooks)" "$ev" "" "$g" 10 || return 1
  done
  return 0
}

# ── IT policy, per agent ──────────────────────────────────────────────────────────────────────
# Everything above reads back the files THIS module wrote; the agent reads a managed policy that
# outranks them. Two outcomes matter, and they are not the same (managed-policy.md §0):
#   HOOKS LOCKED (allowManagedHooksOnly, disableAllHooks, strictPluginOnlyCustomization naming hooks —
#     or disableAllHooks in the person's own settings): the mail guard would never run there, so the
#     server is NOT registered on that agent at all, and a registration an earlier run made is taken
#     back. Registering it would hand an injected prompt send-mail with nothing in the way.
#   MCP NOT ADMITTED (managed-mcp.json, allowManagedMcpServersOnly, an allowedMcpServers that does not
#     name it, a deniedMcpServers that does, strictPluginOnlyCustomization naming mcp; for Copilot also
#     "MCP servers in Copilot" off for the seat): the agent will not start the server. Registering it
#     is harmless — the guard is wired — and it works the day IT admits it.
# Either way that agent's half is not delivered, so the row is NEEDS_HUMAN, "ask IT", and never
# SATISFIED; the other agent's half is installed as usual. Both are gates found AFTER the reversible
# work, like the sign-in — a gate before install_ would make the driver skip the other agent's half —
# unless neither agent can take the server, when there is nothing worth installing.
MICROSOFT365_AGENTS="claude copilot"
MICROSOFT365_SOFTERIA_APP="084a3e9f-a9f4-43f7-89f9-d229cf97853e"   # the server's default app (read from its dist/)
microsoft365_agent_name()   { case "$1" in claude) printf 'Claude Code' ;; *) printf 'Copilot CLI' ;; esac; }
microsoft365_agent_config() { case "$1" in claude) microsoft365_claude_config ;; *) microsoft365_copilot_config ;; esac; }
microsoft365_agent_type()   { case "$1" in claude) printf 'stdio' ;; *) printf 'local' ;; esac; }
microsoft365_agent_user_settings() { case "$1" in claude) printf '%s' "$HOME/.claude/settings.json" ;; *) printf '%s' "$HOME/.copilot/settings.json" ;; esac; }

# microsoft365_policy_source <agent> <key> — the first managed source carrying <key>, as a short path.
microsoft365_policy_source() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    /usr/bin/plutil -extract "$2" raw -o - -- "$f" >/dev/null 2>&1 && { microsoft365_short_path "$f"; return 0; }
    /usr/bin/plutil -type "$2" -- "$f" >/dev/null 2>&1 && { microsoft365_short_path "$f"; return 0; }
  done <<EOF
$(bootstrap_managed_sources "$1")
EOF
  return 1
}
# microsoft365_policy_text <agent> <key> — the policy's value as flat text: backslashes dropped, since
# plutil escapes "/" and Copilot's MDM keys hold JSON inside a string.
microsoft365_policy_text() { bootstrap_policy "$1" "$2" json 2>/dev/null | LC_ALL=C tr -d '\\\n'; }
microsoft365_names_ms365() { printf '%s' "$1" | LC_ALL=C grep -Eq "(^|[^A-Za-z0-9_-])$MICROSOFT365_SERVER_KEY([^A-Za-z0-9_-]|\$)"; }

# microsoft365_hooks_lock <agent> — prints what locks that agent's hooks, rc 0; rc 1 when nothing does.
microsoft365_hooks_lock() {
  local a="$1" k src f
  if bootstrap_policy_restricts "$a" hooks; then
    for k in allowManagedHooksOnly disableAllHooks; do
      [ "$(bootstrap_policy "$a" "$k" 2>/dev/null)" = true ] || continue
      src="$(microsoft365_policy_source "$a" "$k")" && { printf '%s in %s' "$k" "$src"; return 0; }
    done
    src="$(microsoft365_policy_source "$a" strictPluginOnlyCustomization)" \
      && { printf 'strictPluginOnlyCustomization in %s' "$src"; return 0; }
    printf 'a managed policy'; return 0
  fi
  f="$(microsoft365_agent_user_settings "$a")"
  [ "$(bootstrap_settings_get "$f" disableAllHooks raw 2>/dev/null)" = true ] \
    && { printf 'disableAllHooks in %s' "$(microsoft365_short_path "$f")"; return 0; }
  return 1
}
microsoft365_withheld() { microsoft365_hooks_lock "$1" >/dev/null 2>&1; }

# microsoft365_bounded <ms> <program> <args…> — its stdout, and its rc (124 on timeout). macOS has no
# timeout(1); node carries the ceiling, and node is on every path that gets this far.
MICROSOFT365_BOUNDED_JS='
const a = process.argv.slice(1);
const r = require("child_process").spawnSync(a[1], a.slice(2), {timeout: Number(a[0]), stdio: ["ignore", "pipe", "pipe"], encoding: "utf8"});
process.stdout.write(String(r.stdout || "") + String(r.stderr || ""));
process.exit(r.status === null ? 124 : r.status);
'
microsoft365_bounded() { local node; node="$(microsoft365_node)" || return 1; "$node" -e "$MICROSOFT365_BOUNDED_JS" "$@"; }

# microsoft365_claude_refuses — rc 0 iff Claude Code itself, asked, does not load the ms365 server this
# module registered: `claude mcp get ms365` exits 1 with `No MCP server named "ms365"` when a policy
# blocks it (measured: a deniedMcpServers entry), and 0 with the server's details when it loads. It
# reads every source Claude Code does, the server-managed cache and IT's policyHelper included, which
# the file reads above cannot. Skipped: before our registration exists (there is nothing to ask
# about), without the CLI, and under BOOTSTRAP_MANAGED_ROOT, where the CLI reads the real policy files
# while this module reads the fixture. CLAUDE_CONFIG_DIR is dropped so it reads the file we wrote.
microsoft365_claude_refuses() {
  local cl out rc
  [ -z "${BOOTSTRAP_MANAGED_ROOT:-}" ] || return 1
  [ "$(bootstrap_settings_get "$(microsoft365_claude_config)" "mcpServers.$MICROSOFT365_SERVER_KEY.args.0" raw 2>/dev/null)" = "$(microsoft365_entry)" ] || return 1
  cl="$(bootstrap_find_tool claude)" || return 1
  out="$(microsoft365_bounded 30000 /usr/bin/env -u CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER=1 \
         CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$cl" mcp get "$MICROSOFT365_SERVER_KEY" 2>/dev/null)"; rc=$?
  [ "$rc" = 1 ] || return 1
  case "$out" in *"No MCP server named"*) return 0 ;; esac
  return 1
}

# microsoft365_admitted <allowlist-text> — rc 0 iff the allowlist admits OUR server. Once it holds any
# serverCommand entry a stdio server must match one exactly, so then both our node and our entry must
# appear; otherwise an entry naming ms365 admits it. Anything this cannot prove is not admission.
microsoft365_admitted() {
  local node
  case "$1" in
    *serverCommand*)
      node="$(microsoft365_node 2>/dev/null)" || return 1
      case "$1" in *"$(microsoft365_entry)"*) : ;; *) return 1 ;; esac
      case "$1" in *"$node"*) return 0 ;; esac
      return 1 ;;
  esac
  microsoft365_names_ms365 "$1"
}

# microsoft365_mcp_block <agent> — prints why that agent will not start the ms365 server, rc 0; rc 1
# when nothing stops it.
microsoft365_mcp_block() {
  local a="$1" v f
  if [ "$a" = claude ] && [ -e "${BOOTSTRAP_MANAGED_ROOT:-}/Library/Application Support/ClaudeCode/managed-mcp.json" ]; then
    printf 'managed-mcp.json in %s, where IT lists every server' "$(microsoft365_short_path "${BOOTSTRAP_MANAGED_ROOT:-}/Library/Application Support/ClaudeCode")"; return 0
  fi
  v="$(bootstrap_policy "$a" strictPluginOnlyCustomization json 2>/dev/null)" && case "$v" in true|*'"mcp"'*)
    printf 'strictPluginOnlyCustomization in %s' "$(microsoft365_policy_source "$a" strictPluginOnlyCustomization)"; return 0 ;; esac
  v="$(microsoft365_policy_text "$a" deniedMcpServers)"
  if [ -n "$v" ] && { microsoft365_names_ms365 "$v" || case "$v" in *"$(microsoft365_entry)"*) true ;; *) false ;; esac; }; then
    printf 'deniedMcpServers in %s names it' "$(microsoft365_policy_source "$a" deniedMcpServers)"; return 0
  fi
  # Only the managed allowlist counts under allowManagedMcpServersOnly — so with none, nothing is admitted.
  v="$(microsoft365_policy_text "$a" allowedMcpServers)"
  if [ -n "$v" ]; then
    microsoft365_admitted "$v" || { printf 'allowedMcpServers in %s does not admit it' "$(microsoft365_policy_source "$a" allowedMcpServers)"; return 0; }
  elif [ "$(bootstrap_policy "$a" allowManagedMcpServersOnly 2>/dev/null)" = true ]; then
    printf 'allowManagedMcpServersOnly in %s, and no managed allowlist names it' "$(microsoft365_policy_source "$a" allowManagedMcpServersOnly)"; return 0
  fi
  if [ "$a" = copilot ]; then
    # The org policy "MCP servers in Copilot" arrives with the signed-in seat, cached here after the
    # first Copilot sign-in (a vendor verdict, not our write). Before that sign-in it cannot be known.
    f="$HOME/Library/Caches/copilot/copilot-user-cache.json"
    if [ -r "$f" ] && LC_ALL=C grep -Eq '"is_mcp_enabled"[[:space:]]*:[[:space:]]*false' "$f"; then
      printf 'the "MCP servers in Copilot" policy for your Copilot seat is off'; return 0
    fi
  fi
  if [ "$a" = claude ] && microsoft365_claude_refuses; then
    printf 'claude mcp get says it has no ms365 server although %s registers one — a policy this Mac cannot read, such as one set in the Claude admin console' "$(microsoft365_short_path "$(microsoft365_claude_config)")"
    return 0
  fi
  return 1
}

# microsoft365_usable_agents — the agents that can take the server (not withheld, not blocked).
microsoft365_usable_agents() {
  local a out=""
  for a in $MICROSOFT365_AGENTS; do
    microsoft365_withheld "$a" && continue
    microsoft365_mcp_block "$a" >/dev/null 2>&1 && continue
    out="$out $a"
  done
  printf '%s' "${out# }"
}
microsoft365_any_policy_block() {
  local a
  for a in $MICROSOFT365_AGENTS; do
    microsoft365_withheld "$a" && return 0
    microsoft365_mcp_block "$a" >/dev/null 2>&1 && return 0
  done
  return 1
}

# microsoft365_policy_note — one sentence per blocked agent, joined, for note_ and what_.
microsoft365_policy_note() {
  local a why out="" s node
  node="$(microsoft365_node 2>/dev/null)"; node="${node:-<node>}"
  for a in $MICROSOFT365_AGENTS; do
    s=""
    if why="$(microsoft365_hooks_lock "$a")"; then
      case "$why" in
        "disableAllHooks in \$HOME/"*)
          s="$(microsoft365_agent_name "$a") runs no hooks ($why), so the mail guard could not run there and the server is deliberately not registered with it; removing that setting is your call" ;;
        *)
          s="$(microsoft365_agent_name "$a")'s policy runs only hooks IT deploys ($why), so the mail guard could not run there and the server is deliberately not registered with it; ask IT to allow user hooks, or to deploy guard-mail-send.sh as a managed hook" ;;
      esac
    elif why="$(microsoft365_mcp_block "$a")"; then
      s="$(microsoft365_agent_name "$a") will not start the ms365 server ($why); ask IT to admit it — serverCommand [\"$(microsoft365_short_path "$node")\",\"$(microsoft365_short_path "$(microsoft365_entry)")\"]"
    fi
    [ -n "$s" ] && out="${out:+$out. }$s"
  done
  printf '%s' "$out"
}

# microsoft365_signin_code <node> — the AADSTS code Microsoft answers the signed-in account with, or
# nothing: no account in this tenant, or a sign-in that works, or a failure that carries no code.
microsoft365_signin_code() {
  local node="$1" out
  microsoft365_account_in_tenant "$node" 2>/dev/null || return 0
  out="$(microsoft365_run "$node" -e "$MICROSOFT365_LOGIN_JS" "$(microsoft365_entry)" 2>/dev/null)"
  printf '%s' "$out" | LC_ALL=C grep -Eo 'AADSTS[0-9]+' | head -n 1
}

# microsoft365_signin_note — what signing in takes on THIS tenant. A work tenant's default consent
# policy usually removes mail and calendar access from what a user may approve (managed-policy.md §6),
# so "sign in and approve" is promised only where it can be true. When an account is already signed in
# and failing, the AADSTS code Microsoft answered with names the fix (Microsoft's own meanings, from
# its Entra error reference and its Conditional Access pages).
#
# Two of them no sign-in on this Mac can clear. AADSTS530084 is Conditional Access "require token
# protection for sign-in sessions": it admits only a client that signs in through Microsoft's identity
# broker (Company Portal's SSO extension or Platform SSO) with a device-bound key — sign-in status 1008,
# "client doesn't use an identity broker", is exactly this server, which is MSAL Node signing in on its
# own, and --auth-browser is no different (it is the same MSAL, through a loopback redirect).
# AADSTS530036 is the device-code sign-in itself being refused: the token it left is "protocol
# tracked" by an authentication-flows policy and "will never be usable", so only a sign-in by another
# flow — --auth-browser — replaces it.
microsoft365_signin_note() {
  local node="$1" tenant id code
  tenant="$(microsoft365_tenant)"; id="$(microsoft365_client_id)"
  code="$(microsoft365_signin_code "$node")"
  case "$code" in
    AADSTS65001|AADSTS90094|AADSTS90095)
      printf 'Microsoft refused the sign-in (%s): your tenant lets only an administrator approve this app'\''s mail and calendar access; ask IT to grant admin consent to app %s, or to register their own and give you its id for BOOTSTRAP_MICROSOFT_CLIENT_ID.' "$code" "${id:-$MICROSOFT365_SOFTERIA_APP}"; return 0 ;;
    AADSTS53000|AADSTS53001)
      printf 'Microsoft refused the sign-in (%s): your organization lets only compliant or managed devices sign in; ask IT to enrol this Mac (Company Portal), then sign in again.' "$code"; return 0 ;;
    AADSTS53003)
      printf 'Microsoft refused the sign-in (%s): a Conditional Access policy blocks it; if it is the code sign-in it blocks, sign in again with --auth-browser, otherwise ask IT which policy applies.' "$code"; return 0 ;;
    AADSTS530036)
      printf 'Microsoft refused the sign-in (%s): your organization'\''s Conditional Access blocks the device-code sign-in, and the token that sign-in left can never be used again; sign in again in the browser (--auth-browser). If that is refused too, ask IT.' "$code"; return 0 ;;
    AADSTS530084)
      printf 'Microsoft refused the sign-in (%s): your organization requires token protection, which only apps signing in through Microsoft'\''s identity broker (Company Portal) can meet; this server cannot meet it on any Mac, so ask IT to exempt it from that policy, or do without it.' "$code"; return 0 ;;
    AADSTS7000112)
      printf 'Microsoft refused the sign-in (%s): the app this server signs in through (%s) is disabled — in your tenant or by its publisher; ask IT to enable it, or to register their own and give you its id for BOOTSTRAP_MICROSOFT_CLIENT_ID.' "$code" "${id:-$MICROSOFT365_SOFTERIA_APP}"; return 0 ;;
    AADSTS50105)
      printf 'Microsoft refused the sign-in (%s): IT has not assigned you to this app; ask them to.' "$code"; return 0 ;;
    '') : ;;
    *) printf 'the signed-in Microsoft account no longer works (%s); sign in again.' "$code"; return 0 ;;
  esac
  case "$tenant" in
    consumers) printf 'the Microsoft 365 server is installed; sign in once with your personal Microsoft account and approve the app.' ;;
    *)
      if [ -n "$id" ]; then
        printf 'the Microsoft 365 server is installed; sign in once with your work account (%s), through the app your IT registered (%s).' "$tenant" "$id"
      else
        printf 'the Microsoft 365 server is installed; sign in once with your work account (%s). Most work tenants let only an administrator approve this app'\''s mail and calendar access — if Microsoft answers AADSTS65001 or AADSTS90094, ask IT to grant admin consent to app %s (Softeria), or to register their own and give you its id for BOOTSTRAP_MICROSOFT_CLIENT_ID; AADSTS53000 means only compliant devices may sign in. The sign-in uses a device code, which IT'\''s Conditional Access may block (AADSTS53003, AADSTS530036) or flag to security as a phishing pattern: if so, add --auth-browser to sign in in the browser instead. Token protection (AADSTS530084), where IT requires it, cannot be met by this server on any Mac.' "$tenant" "$MICROSOFT365_SOFTERIA_APP"
      fi ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
# what_ is the line --plan prints for a module it would install, so it says what THIS Mac would get.
what_microsoft365() {
  local pol
  printf '%s' 'Outlook mail, calendar, contacts and OneDrive for both agents, through a local MCP server that talks only to Microsoft; the agent drafts mail but never sends it on its own'
  microsoft365_node >/dev/null 2>&1 || microsoft365_node_blocked >/dev/null 2>&1 \
    || printf '. This Mac has no node %s or later, so it first fetches node %s from nodejs.org into %s (checked against its pinned sha256; no Homebrew, no admin)' \
         "$MICROSOFT365_NODE_FLOOR" "$MICROSOFT365_NODE_VERSION" "$(microsoft365_short_path "$(bootstrap_tools_dir)")"
  pol="$(microsoft365_policy_note)"
  [ -n "$pol" ] && printf '. %s' "$pol"
  return 0
}
cost_microsoft365()    { printf '%s' "~85 MB, plus ~200 MB for node $MICROSOFT365_NODE_VERSION from nodejs.org when this Mac has no node $MICROSOFT365_NODE_FLOOR or later (no admin needed). One Microsoft sign-in in your browser; a work tenant usually needs IT to approve the app."; }
profile_microsoft365() { printf '%s' 'standard'; }
# One host per line: <host> <install|run> <purpose>. The TLS check (bootstrap_node_ca_env) makes a
# request to each Microsoft host at install and verify, and to npm's registry until the package is in.
egress_microsoft365() { cat <<'E'
nodejs.org install node 24.21.0, pinned by sha256, only when this Mac has no node 20 or later
registry.npmjs.org install npm package @softeria/ms-365-mcp-server@0.143.0 and its dependencies (or the registry ~/.npmrc names)
github.com install keytar prebuilt binary (prebuild-install), redirects to release-assets.githubusercontent.com
release-assets.githubusercontent.com install keytar prebuilt binary download
login.microsoftonline.com run Microsoft sign-in and token refresh; the TLS check at install and verify
graph.microsoft.com run every mail, calendar and files tool call; /v1.0/me and the TLS check at verify
*.sharepoint.com run file content Graph redirects a download to (download-bytes)
*.files.1drv.com run OneDrive content Graph redirects a download to (download-bytes)
E
}

verify_microsoft365() {
  local node out
  # Local facts first, so a Mac with nothing installed says no before any request leaves it.
  [ -f "$(microsoft365_entry)" ] || return 1
  node="$(microsoft365_node)" || return 1
  microsoft365_tls_load
  microsoft365_tls_untrusted && return 1

  # READ-BACK BY EXECUTION: the pinned version answers from the installed bytes.
  [ "$(microsoft365_run "$node" "$(microsoft365_entry)" --version 2>/dev/null)" = "$MICROSOFT365_SERVER_VERSION" ] || return 1

  # Each agent as this module owes it, read back through plutil — a different engine from the jq that
  # usually wrote: our registration, whole and current — or, where hooks are locked, none of ours.
  microsoft365_agents_in_place "$node" || return 1

  # The send guard: installed, passing its own fixtures, wired for both events on both agents.
  microsoft365_guarded || return 1

  # The server starts under the registered env and answers MCP with its mail tools…
  out="$(microsoft365_probe "$node" tools/list)" || return 1
  case "$out" in *list-mail-messages*) : ;; *) return 1 ;; esac
  # …and the NEGATIVE CONTROL: the same probe over a method that does not exist must list nothing,
  # or the check above proves only that something printed.
  out="$(microsoft365_probe "$node" tools/no-such-method)" && return 1
  [ -z "$out" ] || return 1

  # An agent IT's policy keeps from the server — or from the guard — is a half not delivered.
  microsoft365_any_policy_block && return 1

  microsoft365_signed_in "$node"
}

# microsoft365_ours_on <agent> — rc 0 iff that agent's config holds OUR registration (by entry path).
microsoft365_ours_on() {
  [ "$(bootstrap_settings_get "$(microsoft365_agent_config "$1")" "mcpServers.$MICROSOFT365_SERVER_KEY.args.0" raw 2>/dev/null)" = "$(microsoft365_entry)" ]
}

# microsoft365_agents_in_place <node> — every agent is as this module owes it: where hooks are locked,
# NO registration of ours (the guard could not stop a send there); elsewhere ours, whole and current,
# and Copilot's with the tools filter its own `copilot mcp add` writes.
microsoft365_agents_in_place() {
  local node="$1" a f
  for a in $MICROSOFT365_AGENTS; do
    f="$(microsoft365_agent_config "$a")"
    if microsoft365_withheld "$a"; then
      microsoft365_ours_on "$a" && return 1
      continue
    fi
    microsoft365_registered "$f" "$(microsoft365_agent_type "$a")" "$node" || return 1
    if [ "$a" = copilot ]; then
      [ "$(bootstrap_settings_get "$f" "mcpServers.$MICROSOFT365_SERVER_KEY.tools.0" raw 2>/dev/null)" = "*" ] || return 1
    fi
  done
  return 0
}

# microsoft365_gated_file — prints "<file>|<why>" for the first config file only a person can decide
# about, rc 1 if none. gate_ and note_ both read this, so they can never name different files.
microsoft365_gated_file() {
  local f a
  for f in "$(microsoft365_claude_config)" "$(microsoft365_copilot_config)" \
           "$(microsoft365_claude_settings)" "$(microsoft365_copilot_hooks)"; do
    if [ -f "$f" ]; then
      bootstrap_is_json_text "$f" >/dev/null 2>&1 || { printf '%s|unparseable' "$f"; return 0; }
      bootstrap_json_ok "$f" >/dev/null 2>&1 || { printf '%s|unparseable' "$f"; return 0; }
      [ -w "$f" ] || { printf '%s|readonly' "$f"; return 0; }
      # Somebody else's ms365 — a hand-made registration, another install. Ours is recognised by its
      # entry path, not its node, so a node that moved is repaired rather than reported as foreign.
      a="$(bootstrap_settings_get "$f" "mcpServers.$MICROSOFT365_SERVER_KEY.args.0" raw 2>/dev/null)" || a=""
      if bootstrap_settings_type "$f" "mcpServers.$MICROSOFT365_SERVER_KEY" >/dev/null 2>&1 \
         && [ "$a" != "$(microsoft365_entry)" ]; then
        printf '%s|taken' "$f"; return 0
      fi
    else
      [ -d "$(dirname "$f")" ] && [ ! -w "$(dirname "$f")" ] && { printf '%s|dir' "$f"; return 0; }
    fi
  done
  return 1
}

# The gates that exist only AFTER the reversible work — an agent IT's policy keeps from the server,
# and not signed in — must not fire on a bare machine: gate_ runs before install_, and a true gate
# there makes the driver skip the install it was about to do (the handoff module measured exactly that).
microsoft365_ready_for_sign_in() {
  local node
  node="$(microsoft365_node)" || return 1
  microsoft365_installed || return 1
  microsoft365_agents_in_place "$node" || return 1
  microsoft365_guarded quick
}

# No node is not a gate by itself: install_ fetches one. It becomes one only when no fetch can help —
# this macOS is too old, nodejs.org builds nothing for this CPU — or when this run's fetch failed.
gate_microsoft365() {
  microsoft365_gated_file >/dev/null 2>&1 && return 0
  microsoft365_tls_load
  microsoft365_tls_untrusted && return 0
  microsoft365_node_blocked >/dev/null && return 0
  # Neither agent can take the server: installing ~85 MB for no one is not worth doing.
  [ -n "$(microsoft365_usable_agents)" ] || return 0
  microsoft365_node >/dev/null 2>&1 || return 1
  microsoft365_ready_for_sign_in || return 1
  microsoft365_any_policy_block && return 0
  microsoft365_signed_in "$(microsoft365_node)" && return 1
  return 0
}

# Paths are shown as $HOME/… literally: executable as typed, and no username in the output.
microsoft365_short_path() {
  case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

# microsoft365_rerun — the command that runs this module again, or nothing. BOOTSTRAP_ENTRY is empty
# under `curl … | bash`, where there is no file to name; a command that does not run as typed is worse
# than none, and so is one whose path would break out of its quotes.
microsoft365_rerun() {
  case "${BOOTSTRAP_ENTRY:-}" in ''|*'"'*|*'$'*|*'`'*|*'\'*) return 0 ;; esac
  printf 'bash "%s" --only microsoft365' "$(microsoft365_short_path "$BOOTSTRAP_ENTRY")"
}

note_microsoft365() {
  local g f why pol sig node
  microsoft365_tls_load
  if g="$(microsoft365_gated_file)"; then
    f="$(microsoft365_short_path "${g%%|*}")"; why="${g##*|}"
    case "$why" in
      taken)       printf 'an ms365 server of your own is already registered in %s, and replacing it is your call, not mine.' "$f" ;;
      unparseable) printf '%s is not valid JSON, so nothing here will touch it.' "$f" ;;
      readonly)    printf '%s is not writable by you.' "$f" ;;
      *)           printf 'the folder holding %s is not writable by you.' "$f" ;;
    esac
    return 0
  fi
  if microsoft365_tls_untrusted; then
    printf 'your network intercepts TLS with a certificate this Mac does not trust, so npm and the Microsoft 365 server cannot reach npm or Microsoft; ask IT to install that certificate on this Mac.'
    return 0
  fi
  if why="$(microsoft365_node_blocked)"; then
    case "$why" in
      macos-old)   printf 'the Microsoft 365 server needs node %s or later, and the node build this module fetches needs macOS %s or later; update macOS, or ask IT for node.' "$MICROSOFT365_NODE_FLOOR" "$MICROSOFT365_NODE_MIN_MACOS" ;;
      no-build)    printf 'the Microsoft 365 server needs node %s or later, and nodejs.org has no build for this processor; ask IT for node.' "$MICROSOFT365_NODE_FLOOR" ;;
      refused)     printf 'node %s was downloaded from nodejs.org, but its sha256 is not the one this release pins, so it was thrown away: something between this Mac and nodejs.org changed it. Try again on another network, or ask IT.' "$MICROSOFT365_NODE_VERSION" ;;
      *)           printf 'node %s could not be downloaded from nodejs.org (a proxy or firewall may block it), and this Mac has no node %s or later; run this again once nodejs.org is reachable, or ask IT to allow it.' "$MICROSOFT365_NODE_VERSION" "$MICROSOFT365_NODE_FLOOR" ;;
    esac
    return 0
  fi
  pol="$(microsoft365_policy_note)"
  if [ -z "$(microsoft365_usable_agents)" ]; then
    printf 'neither agent can take the Microsoft 365 server, so nothing was installed. %s.' "$pol"
    return 0
  fi
  if microsoft365_ready_for_sign_in; then
    node="$(microsoft365_node)"
    sig=""; microsoft365_signed_in "$node" || sig="$(microsoft365_signin_note "$node")"
    if [ -n "$pol" ]; then
      printf '%s.' "$pol"
      [ -n "$sig" ] && printf ' Meanwhile, for %s: %s' "$(for a in $(microsoft365_usable_agents); do microsoft365_agent_name "$a"; printf ' '; done | sed 's/ $//; s/ Copilot/ and Copilot/')" "$sig"
    else
      printf '%s' "$sig"
    fi
    return 0
  fi
  printf 'the Microsoft 365 server is not installed or not registered with the agents yet.'
}

gesture_microsoft365() {
  local g node id pre brew flow
  microsoft365_tls_load
  if g="$(microsoft365_gated_file)"; then
    printf 'open -e "%s"' "$(microsoft365_short_path "${g%%|*}")"
    return 0
  fi
  microsoft365_tls_untrusted && return 0                  # IT's certificate: no command exists
  if g="$(microsoft365_node_blocked)"; then
    case "$g" in
      refused|not-fetched)
        # Homebrew only for someone who can run it: a standard user's `brew install` stops at sudo.
        if bootstrap_is_admin && brew="$(bootstrap_find_tool brew)"; then printf '"%s" install node' "$brew"
        else microsoft365_rerun; fi ;;
    esac
    return 0
  fi
  node="$(microsoft365_node)" || return 0
  # The one policy line a person may change themselves: disableAllHooks in their own settings file.
  for g in $MICROSOFT365_AGENTS; do
    case "$(microsoft365_hooks_lock "$g")" in
      "disableAllHooks in \$HOME/"*) printf 'open -e "%s"' "$(microsoft365_short_path "$(microsoft365_agent_user_settings "$g")")"; return 0 ;;
    esac
  done
  [ -n "$(microsoft365_usable_agents)" ] || return 0      # IT's to change: no command exists
  microsoft365_ready_for_sign_in || return 0
  microsoft365_signed_in "$node" && return 0             # only IT's steps remain
  id="$(microsoft365_client_id)"
  pre="MS365_MCP_TENANT_ID=$(microsoft365_tenant)"
  [ -n "$id" ] && pre="$pre MS365_MCP_CLIENT_ID=$id"
  # A token IT's policy killed for being a device-code sign-in is replaced only by another flow.
  flow=""; [ "$(microsoft365_signin_code "$node")" = AADSTS530036 ] && flow=" --auth-browser"
  printf '%s "%s" "%s" --login%s' "$pre" "$(microsoft365_short_path "$node")" "$(microsoft365_short_path "$(microsoft365_entry)")" "$flow"
}

install_microsoft365() {
  local node dir npm out ent rc envj ca a f why
  microsoft365_tls_load
  microsoft365_tls_untrusted && { bootstrap_warn "microsoft365: TLS to npm or Microsoft is intercepted by a certificate this Mac does not trust"; return 1; }
  if ! node="$(microsoft365_node)"; then
    microsoft365_node_fetch || { bootstrap_warn "microsoft365: no node $MICROSOFT365_NODE_FLOOR+ on this Mac, and node $MICROSOFT365_NODE_VERSION could not be fetched"; return 1; }
    node="$(microsoft365_node)" || { bootstrap_warn "microsoft365: node $MICROSOFT365_NODE_VERSION was fetched but is not found"; return 1; }
  fi
  dir="$(microsoft365_dir)"
  mkdir -p "$dir" 2>/dev/null || { bootstrap_warn "microsoft365: cannot create $dir"; return 1; }

  # Record the choice a later cold verify must agree with — only when the caller made one, so a
  # re-run without the variable never silently resets a tenant chosen earlier.
  [ -n "${BOOTSTRAP_MICROSOFT_TENANT:-}" ] && printf '%s\n' "$BOOTSTRAP_MICROSOFT_TENANT" > "$dir/tenant"
  [ -n "${BOOTSTRAP_MICROSOFT_CLIENT_ID:-}" ] && printf '%s\n' "$BOOTSTRAP_MICROSOFT_CLIENT_ID" > "$dir/client-id"

  if ! microsoft365_installed; then
    # npm beside the node we chose, with that node first on PATH (npm's own shebang is `env node`).
    # The cache lives inside $dir and is dropped afterwards, so nothing lands in $HOME/.npm. Behind an
    # inspecting proxy it gets the CA file too — never npm's --cafile, which REPLACES node's roots.
    npm="$(dirname "$node")/npm"
    [ -x "$npm" ] || { bootstrap_warn "microsoft365: no npm beside $node"; return 1; }
    ca="$(microsoft365_ca_path)"
    set -- PATH="$(dirname "$node"):$PATH"
    [ -n "$ca" ] && set -- "$@" NODE_EXTRA_CA_CERTS="$ca"
    /usr/bin/env "$@" "$npm" install --prefix "$dir" --cache "$dir/.npm-cache" \
      --no-fund --no-audit --no-update-notifier --omit=dev "$MICROSOFT365_PACKAGE@$MICROSOFT365_SERVER_VERSION" >&2 \
      || { bootstrap_warn "microsoft365: npm install of $MICROSOFT365_PACKAGE@$MICROSOFT365_SERVER_VERSION failed"; return 1; }
    rm -rf "$dir/.npm-cache" 2>/dev/null
    microsoft365_installed || { bootstrap_warn "microsoft365: installed, but the server does not report $MICROSOFT365_SERVER_VERSION"; return 1; }
  fi

  # Rule 4, before we register anything: a server that cannot answer MCP must never be written into
  # an agent's config, where it would fail at every session start.
  out="$(microsoft365_probe "$node" tools/list)" || { bootstrap_warn "microsoft365: the installed server did not answer tools/list — not registering it"; return 1; }
  case "$out" in *list-mail-messages*) : ;; *) bootstrap_warn "microsoft365: the server answered without its mail tools — not registering it"; return 1 ;; esac

  # The send guard goes in BEFORE either agent learns the server exists, so there is no window in
  # which the send tools are reachable unguarded.
  microsoft365_install_guard || { bootstrap_warn "microsoft365: the mail guard is not in place — not registering the server"; return 1; }

  envj="$(microsoft365_env_json)"
  for a in $MICROSOFT365_AGENTS; do
    f="$(microsoft365_agent_config "$a")"
    # Hooks locked: no guard can run there, so no server either — and one an earlier run registered
    # comes out, or it would be a live send-mail with nothing in front of it.
    if why="$(microsoft365_hooks_lock "$a")"; then
      if microsoft365_ours_on "$a"; then
        bootstrap_settings_remove "$f" "mcpServers.$MICROSOFT365_SERVER_KEY" \
          || { bootstrap_warn "microsoft365: could not take the server back out of $f"; return 1; }
      fi
      bootstrap_warn "microsoft365: not registering with $(microsoft365_agent_name "$a"): its hooks are locked ($why), so the mail guard could not run there"
      continue
    fi
    if [ "$a" = claude ]; then
      ent="{\"type\":\"stdio\",\"command\":\"$(bootstrap_json_escape "$node")\",\"args\":[\"$(bootstrap_json_escape "$(microsoft365_entry)")\"],\"env\":$envj}"
    else
      mkdir -p "$(dirname "$f")" 2>/dev/null
      # Copilot's own `copilot mcp add` writes this exact shape: type "local" and a tools filter.
      ent="{\"type\":\"local\",\"command\":\"$(bootstrap_json_escape "$node")\",\"args\":[\"$(bootstrap_json_escape "$(microsoft365_entry)")\"],\"env\":$envj,\"tools\":[\"*\"]}"
    fi
    bootstrap_settings_merge "$f" "mcpServers.$MICROSOFT365_SERVER_KEY" "$ent"; rc=$?
    [ "$rc" = 0 ] || { bootstrap_warn "microsoft365: could not register with $(microsoft365_agent_name "$a") (rc $rc)"; return 1; }
  done

  # Everything reversible is done. An agent IT keeps from the server, and not signed in, are gates the
  # installer has now DISCOVERED: return non-zero and the driver re-asks gate_, which reports them.
  microsoft365_any_policy_block && return 3
  microsoft365_signed_in "$node" || return 3
  return 0
}

# The sign-in token is NOT removed: install_ never wrote it — the human's sign-in did, into the
# server's own cache ($HOME/Library/Application Support/ms-365-mcp-server). To drop it too, run the
# server with --logout before uninstalling.
uninstall_microsoft365() {
  local f a g ev i b t l keep=0 rc=0
  for f in "$(microsoft365_claude_config)" "$(microsoft365_copilot_config)"; do
    [ -f "$f" ] || continue
    a="$(bootstrap_settings_get "$f" "mcpServers.$MICROSOFT365_SERVER_KEY.args.0" raw 2>/dev/null)" || a=""
    [ "$a" = "$(microsoft365_entry)" ] || continue       # someone else's ms365 is not ours to remove
    bootstrap_settings_remove "$f" "mcpServers.$MICROSOFT365_SERVER_KEY" || rc=1
  done
  # The node this module fetched, and only it: a link is removed only while it points into a node
  # folder of ours, so a tool some other install put in tools/bin stays.
  t="$(bootstrap_tools_dir)"
  for l in node npm; do
    case "$(readlink "$t/bin/$l" 2>/dev/null)" in "../node-v"*"-darwin-"*"/bin/$l") rm -f "$t/bin/$l" 2>/dev/null ;; esac
  done
  rm -rf "$t"/node-v*-darwin-arm64 "$t"/node-v*-darwin-x64 2>/dev/null
  rmdir "$t/bin" "$t" 2>/dev/null
  # The guard comes out LAST, after the server it guards is gone. Ownership is the directory.
  g="$(microsoft365_guard)"
  bootstrap_hook_unwire "$(microsoft365_claude_settings)" "$(dirname "$g")/" >/dev/null 2>&1 || rc=1
  # The Copilot file is ours by name; remove it only if every entry in it is ours.
  f="$(microsoft365_copilot_hooks)"
  if [ -f "$f" ]; then
    for ev in $(bootstrap_hook_events "$f"); do
      i=0
      while b="$(bootstrap_settings_get "$f" "hooks.$ev.$i.bash" raw 2>/dev/null)"; do
        case "$b" in "$(dirname "$g")/"*) : ;; *) keep=1 ;; esac
        i=$((i + 1))
      done
    done
    if [ "$keep" = 0 ]; then rm -f "$f" 2>/dev/null
    else bootstrap_warn "microsoft365: $f holds a hook that is not ours, so it was left in place"; rc=1; fi
  fi
  rm -rf "$(microsoft365_dir)" 2>/dev/null
  return "$rc"
}
