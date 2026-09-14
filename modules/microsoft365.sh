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

# microsoft365_node — a node >= 18 at a path that SURVIVES a node upgrade, or rc 1.
# Homebrew's bin/ symlinks are repointed by `brew upgrade`, and fnm's aliases/default by
# `fnm default`. A versioned path, or fnm's per-shell fnm_multishells path, silently disappears
# the day node moves and takes the server with it, with no error anyone would see — so `command -v`
# is the last resort, and a multishell answer is refused outright.
microsoft365_node() {
  local c major
  for c in /opt/homebrew/bin/node /usr/local/bin/node \
           "$HOME/Library/Application Support/fnm/aliases/default/bin/node" \
           "$(command -v node 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    case "$c" in */fnm_multishells/*) continue ;; esac
    major="$("$c" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || continue
    case "$major" in ''|*[!0-9]*) continue ;; esac
    [ "$major" -ge 18 ] || continue
    printf '%s' "$c"; return 0
  done
  return 1
}

# microsoft365_env_json — the env block both registrations carry.
microsoft365_env_json() {
  local id
  id="$(microsoft365_client_id)"
  if [ -n "$id" ]; then
    printf '{"MS365_MCP_TENANT_ID":"%s","MS365_MCP_CLIENT_ID":"%s"}' \
      "$(bootstrap_json_escape "$(microsoft365_tenant)")" "$(bootstrap_json_escape "$id")"
  else
    printf '{"MS365_MCP_TENANT_ID":"%s"}' "$(bootstrap_json_escape "$(microsoft365_tenant)")"
  fi
}

# microsoft365_run <node> <args…> — run the INSTALLED server the way an agent will: same tenant, same
# client id. Logs go to a throwaway directory so a verify writes nothing into $HOME; the token cache
# stays at its default, because the sign-in check must read the real one.
microsoft365_run() {
  local node="$1" logs rc id; shift
  logs="$(mktemp -d -t microsoft365logs)" || return 1
  id="$(microsoft365_client_id)"
  if [ -n "$id" ]; then
    MS365_MCP_LOG_DIR="$logs" MS365_MCP_TENANT_ID="$(microsoft365_tenant)" MS365_MCP_CLIENT_ID="$id" "$node" "$@"
  else
    MS365_MCP_LOG_DIR="$logs" MS365_MCP_TENANT_ID="$(microsoft365_tenant)" "$node" "$@"
  fi
  rc=$?
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
  id="$(microsoft365_client_id)"
  [ "$(bootstrap_settings_get "$f" "$k.env.MS365_MCP_CLIENT_ID" raw 2>/dev/null)" = "$id" ] || return 1
  return 0
}

microsoft365_installed() {
  local node
  node="$(microsoft365_node)" || return 1
  [ "$(microsoft365_run "$node" "$(microsoft365_entry)" --version 2>/dev/null)" = "$MICROSOFT365_SERVER_VERSION" ]
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_microsoft365()    { printf '%s' 'Outlook mail, calendar, contacts and OneDrive for both agents, through a local MCP server that talks only to Microsoft'; }
cost_microsoft365()    { printf '%s' '~85 MB. Needs node (brew install node) and one Microsoft sign-in in your browser; a corporate tenant may also need IT to approve the app.'; }
profile_microsoft365() { printf '%s' 'standard'; }

verify_microsoft365() {
  local node out
  node="$(microsoft365_node)" || return 1

  # READ-BACK BY EXECUTION: the pinned version answers from the installed bytes.
  [ "$(microsoft365_run "$node" "$(microsoft365_entry)" --version 2>/dev/null)" = "$MICROSOFT365_SERVER_VERSION" ] || return 1

  # Both registrations, read back through plutil — a different engine from the jq that usually wrote.
  microsoft365_registered "$(microsoft365_claude_config)" stdio "$node" || return 1
  microsoft365_registered "$(microsoft365_copilot_config)" local "$node" || return 1
  [ "$(bootstrap_settings_get "$(microsoft365_copilot_config)" "mcpServers.$MICROSOFT365_SERVER_KEY.tools.0" raw 2>/dev/null)" = "*" ] || return 1

  # The server starts under the registered env and answers MCP with its mail tools…
  out="$(microsoft365_probe "$node" tools/list)" || return 1
  case "$out" in *list-mail-messages*) : ;; *) return 1 ;; esac
  # …and the NEGATIVE CONTROL: the same probe over a method that does not exist must list nothing,
  # or the check above proves only that something printed.
  out="$(microsoft365_probe "$node" tools/no-such-method)" && return 1
  [ -z "$out" ] || return 1

  microsoft365_signed_in "$node"
}

# microsoft365_gated_file — prints "<file>|<why>" for the first config file only a person can decide
# about, rc 1 if none. gate_ and note_ both read this, so they can never name different files.
microsoft365_gated_file() {
  local f a
  for f in "$(microsoft365_claude_config)" "$(microsoft365_copilot_config)"; do
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

# The two gates that exist only AFTER the reversible work: node missing, and not signed in. The
# second must not fire on a bare machine — gate_ runs before install_, and a true gate there makes
# the driver skip the install it was about to do (the handoff module measured exactly that).
microsoft365_ready_for_sign_in() {
  local node
  node="$(microsoft365_node)" || return 1
  microsoft365_installed || return 1
  microsoft365_registered "$(microsoft365_claude_config)" stdio "$node" || return 1
  microsoft365_registered "$(microsoft365_copilot_config)" local "$node"
}

gate_microsoft365() {
  microsoft365_gated_file >/dev/null 2>&1 && return 0
  microsoft365_node >/dev/null 2>&1 || return 0
  microsoft365_ready_for_sign_in || return 1
  microsoft365_signed_in "$(microsoft365_node)" && return 1
  return 0
}

# Paths are shown as $HOME/… literally: executable as typed, and no username in the output.
microsoft365_short_path() {
  case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

note_microsoft365() {
  local g f why
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
  if ! microsoft365_node >/dev/null 2>&1; then
    printf 'the Microsoft 365 server needs node 18 or later, and this Mac has none.'
    return 0
  fi
  if microsoft365_ready_for_sign_in; then
    printf 'the Microsoft 365 server is installed for both agents; sign in once with your work account (%s) and approve the app.' "$(microsoft365_tenant)"
    return 0
  fi
  printf 'the Microsoft 365 server is not installed or not registered with both agents yet.'
}

gesture_microsoft365() {
  local g node id pre
  if g="$(microsoft365_gated_file)"; then
    printf 'open -e "%s"' "$(microsoft365_short_path "${g%%|*}")"
    return 0
  fi
  node="$(microsoft365_node)" || { printf 'brew install node'; return 0; }
  microsoft365_ready_for_sign_in || return 0
  id="$(microsoft365_client_id)"
  pre="MS365_MCP_TENANT_ID=$(microsoft365_tenant)"
  [ -n "$id" ] && pre="$pre MS365_MCP_CLIENT_ID=$id"
  printf '%s "%s" "%s" --login' "$pre" "$(microsoft365_short_path "$node")" "$(microsoft365_short_path "$(microsoft365_entry)")"
}

install_microsoft365() {
  local node dir npm out ent rc envj
  node="$(microsoft365_node)" || { bootstrap_warn "microsoft365: no node 18+ on this Mac"; return 1; }
  dir="$(microsoft365_dir)"
  mkdir -p "$dir" 2>/dev/null || { bootstrap_warn "microsoft365: cannot create $dir"; return 1; }

  # Record the choice a later cold verify must agree with — only when the caller made one, so a
  # re-run without the variable never silently resets a tenant chosen earlier.
  [ -n "${BOOTSTRAP_MICROSOFT_TENANT:-}" ] && printf '%s\n' "$BOOTSTRAP_MICROSOFT_TENANT" > "$dir/tenant"
  [ -n "${BOOTSTRAP_MICROSOFT_CLIENT_ID:-}" ] && printf '%s\n' "$BOOTSTRAP_MICROSOFT_CLIENT_ID" > "$dir/client-id"

  if ! microsoft365_installed; then
    # npm beside the node we chose, with that node first on PATH (npm's own shebang is `env node`).
    # The cache lives inside $dir and is dropped afterwards, so nothing lands in $HOME/.npm.
    npm="$(dirname "$node")/npm"
    [ -x "$npm" ] || { bootstrap_warn "microsoft365: no npm beside $node"; return 1; }
    PATH="$(dirname "$node"):$PATH" "$npm" install --prefix "$dir" --cache "$dir/.npm-cache" \
      --no-fund --no-audit --omit=dev "$MICROSOFT365_PACKAGE@$MICROSOFT365_SERVER_VERSION" >&2 \
      || { bootstrap_warn "microsoft365: npm install of $MICROSOFT365_PACKAGE@$MICROSOFT365_SERVER_VERSION failed"; return 1; }
    rm -rf "$dir/.npm-cache" 2>/dev/null
    microsoft365_installed || { bootstrap_warn "microsoft365: installed, but the server does not report $MICROSOFT365_SERVER_VERSION"; return 1; }
  fi

  # Rule 4, before we register anything: a server that cannot answer MCP must never be written into
  # an agent's config, where it would fail at every session start.
  out="$(microsoft365_probe "$node" tools/list)" || { bootstrap_warn "microsoft365: the installed server did not answer tools/list — not registering it"; return 1; }
  case "$out" in *list-mail-messages*) : ;; *) bootstrap_warn "microsoft365: the server answered without its mail tools — not registering it"; return 1 ;; esac

  envj="$(microsoft365_env_json)"
  ent="{\"type\":\"stdio\",\"command\":\"$(bootstrap_json_escape "$node")\",\"args\":[\"$(bootstrap_json_escape "$(microsoft365_entry)")\"],\"env\":$envj}"
  bootstrap_settings_merge "$(microsoft365_claude_config)" "mcpServers.$MICROSOFT365_SERVER_KEY" "$ent"; rc=$?
  [ "$rc" = 0 ] || { bootstrap_warn "microsoft365: could not register with Claude Code (rc $rc)"; return 1; }

  mkdir -p "$(dirname "$(microsoft365_copilot_config)")" 2>/dev/null
  # Copilot's own `copilot mcp add` writes this exact shape: type "local" and a tools filter.
  ent="{\"type\":\"local\",\"command\":\"$(bootstrap_json_escape "$node")\",\"args\":[\"$(bootstrap_json_escape "$(microsoft365_entry)")\"],\"env\":$envj,\"tools\":[\"*\"]}"
  bootstrap_settings_merge "$(microsoft365_copilot_config)" "mcpServers.$MICROSOFT365_SERVER_KEY" "$ent"; rc=$?
  [ "$rc" = 0 ] || { bootstrap_warn "microsoft365: could not register with Copilot (rc $rc)"; return 1; }

  # Everything reversible is done. Not signed in is a gate the installer has now DISCOVERED, so
  # return non-zero and let the driver re-ask gate_, which reports the sign-in as NEEDS_HUMAN.
  microsoft365_signed_in "$node" || return 3
  return 0
}

# microsoft365_settings_remove <file> <keypath> — the un-write. bootstrap-lib.sh has one writer and no
# remover, so this lives here with the same discipline statusline's does: back up, work on a temp
# copy, read the removal back THERE, and only then let it land.
microsoft365_settings_remove() {
  local f="${1:-}" k="${2:-}" tmp
  [ -f "$f" ] || return 0
  bootstrap_settings_type "$f" "$k" >/dev/null 2>&1 || return 0        # already absent
  bootstrap_json_ok "$f" >/dev/null 2>&1 || return 2
  bootstrap_is_json_text "$f" >/dev/null 2>&1 || return 2
  bootstrap_backup "$f"
  tmp="$f.microsoft365-tmp.$$"
  cp -p "$f" "$tmp" 2>/dev/null || return 2
  "$BOOTSTRAP_PLUTIL" -remove "$k" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 2; }
  bootstrap_json_ok "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 2; }
  bootstrap_settings_type "$tmp" "$k" >/dev/null 2>&1 && { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 2; }
  return 0
}

# The sign-in token is NOT removed: install_ never wrote it — the human's sign-in did, into the
# server's own cache ($HOME/Library/Application Support/ms-365-mcp-server). To drop it too, run the
# server with --logout before uninstalling.
uninstall_microsoft365() {
  local f a rc=0
  for f in "$(microsoft365_claude_config)" "$(microsoft365_copilot_config)"; do
    [ -f "$f" ] || continue
    a="$(bootstrap_settings_get "$f" "mcpServers.$MICROSOFT365_SERVER_KEY.args.0" raw 2>/dev/null)" || a=""
    [ "$a" = "$(microsoft365_entry)" ] || continue       # someone else's ms365 is not ours to remove
    microsoft365_settings_remove "$f" "mcpServers.$MICROSOFT365_SERVER_KEY" || rc=1
  done
  rm -rf "$(microsoft365_dir)" 2>/dev/null
  return "$rc"
}
