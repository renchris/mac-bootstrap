# shellcheck shell=bash
# scripts/checks/microsoft.sh — the two modules that move the person's own mail, calendar and files
# (microsoft365, microsoft365_archive), on a fresh corporate Mac. Sourced by scripts/characterize.sh,
# which supplies the harness; never run on its own. No network, no real npm install, no Microsoft.

MS_GUARD="$CHECK_ROOT/assets/hooks/guard-mail-send.sh"

# ── 1. THE GUARD — every tool that reaches another person in one call, on both agents' spellings ──
# Driven straight at the shipped hook, independently of its own --selftest, so a selftest that
# stopped asserting something cannot hide it. <expect> <tool> <tool_input>, one per line.
MS_GUARD_CASES='deny share-drive-item {"body":{"recipients":[{"email":"a@example.com"}]}}
deny create-drive-item-share-link {"body":{"scope":"anonymous"}}
deny create-drive-item-share-link {"body":{"scope":"organization"}}
deny create-drive-item-share-link {"body":{"type":"view"}}
deny create-mail-rule {"body":{"actions":{"forwardTo":[{"emailAddress":{"address":"a@example.com"}}]}}}
deny update-mail-rule {"body":{"actions":{"redirectTo":[{"emailAddress":{"address":"a@example.com"}}]}}}
deny create-mail-rule {"body":{"actions":{"forwardAsAttachmentTo":[{"emailAddress":{"address":"a@example.com"}}]}}}
deny create-calendar-event {"body":{"attendees":[{"emailAddress":{"address":"a@example.com"}}]}}
deny create-specific-calendar-event {"body":{"Attendees":[{"emailAddress":{"address":"a@example.com"}}]}}
deny update-calendar-event {"body":{"attendees":[{"emailAddress":{"address":"a@example.com"}}]}}
deny update-specific-calendar-event {"body":{"attendees":[]}}
deny accept-calendar-event {"body":{"Comment":"x"}}
deny decline-calendar-event {"body":{"SendResponse":true}}
deny tentatively-accept-calendar-event {"body":{}}
deny cancel-calendar-event {"body":{}}
deny create-my-calendar-permission {"body":{"role":"read"}}
deny create-subscription {"body":{"notificationUrl":"https://example.com/x"}}
deny update-mailbox-settings {"body":{"automaticRepliesSetting":{"status":"alwaysEnabled"}}}
quiet create-drive-item-share-link {"body":{"scope":"users"}}
quiet create-mail-rule {"body":{"actions":{"moveToFolder":"f1"}}}
quiet create-calendar-event {"body":{"subject":"focus"}}
quiet create-calendar-event {"body":{"attendees":[]}}
quiet update-calendar-event {"body":{"subject":"moved"}}
quiet accept-calendar-event {"body":{"SendResponse":false}}
quiet update-mailbox-settings {"body":{"timeZone":"UTC"}}
quiet create-draft-email {"body":{"subject":"x"}}
quiet list-mail-messages {}'
ms_guard_run() {                               # <tool_name> <tool_input> → the hook's stdout, rc
  printf '{"hook_event_name":"PreToolUse","session_id":"characterize","tool_name":"%s","tool_input":%s}' "$1" "$2" \
    | BOOTSTRAP_MAIL_GUARD_DIR="$CHECK_WORK/mail-guard-turns" /bin/bash "$MS_GUARD" 2>/dev/null
}
MS_DENIED=0; MS_QUIET=0; MS_WRONG=""
while read -r ms_want ms_tool ms_input; do
  [ -n "$ms_tool" ] || continue
  for ms_name in "mcp__ms365__$ms_tool" "ms365-$ms_tool"; do
    ms_out="$(ms_guard_run "$ms_name" "$ms_input")"; ms_rc=$?
    case "$ms_want:$ms_rc:$ms_out" in
      deny:0:*'"permissionDecision":"deny"'*) MS_DENIED=$((MS_DENIED + 1)) ;;
      quiet:0:)                               MS_QUIET=$((MS_QUIET + 1)) ;;
      *) MS_WRONG="$MS_WRONG $ms_want:$ms_name(rc $ms_rc)" ;;
    esac
  done
done <<EOF
$MS_GUARD_CASES
EOF
if [ -z "$MS_WRONG" ]; then pass "microsoft-guard-new-denies" "$MS_DENIED denied, $MS_QUIET controls left alone, both spellings"
else fail "microsoft-guard-new-denies" "$MS_WRONG"; fi
# The same tools on ANOTHER server are not ours to judge: the guard must stay silent.
ms_out="$(ms_guard_run mcp__other__share-drive-item '{}')"
same "microsoft-guard-other-server-silent" "$ms_out" ""
if /bin/bash "$MS_GUARD" --selftest > "$CHECK_WORK/mail-guard-selftest.txt" 2>&1; then
  pass "microsoft-guard-selftest" "$(tail -1 "$CHECK_WORK/mail-guard-selftest.txt")"
else
  fail "microsoft-guard-selftest" "$(grep -v '^  ok ' "$CHECK_WORK/mail-guard-selftest.txt" | head -5 | tr '\n' ' ')"
fi

# ── harness for the module verbs ─────────────────────────────────────────────────────────────
# ms_run <home> <snippet> [VAR=value …] — a fresh /bin/bash with the library and both modules sourced,
# HOME set to <home>, then <snippet>. Every TLS probe goes to a closed local port unless a check says
# otherwise (BOOTSTRAP_TLS_PROBE_URL), so nothing here reaches the network.
MS_DEAD_URL="https://127.0.0.1:9/"
ms_run() {
  local h="$1" s="$2"; shift 2
  env HOME="$h" BOOTSTRAP_STATE_DIR="$h/.mac-bootstrap" BOOTSTRAP_LIB="$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" \
      BOOTSTRAP_ASSETS="$CHECK_ROOT/assets" BOOTSTRAP_TLS_PROBE_URL="$MS_DEAD_URL" TMPDIR="$CHECK_WORK" "$@" \
      /bin/bash -c '. "$BOOTSTRAP_LIB"; . "$1"; . "$2"; eval "$3"' microsoft-check \
      "$CHECK_ROOT/modules/microsoft365.sh" "$CHECK_ROOT/modules/microsoft365_archive.sh" "$s" 2>/dev/null
}
ms_drive() {                                   # ms_drive <home> <args…> — the driver, TLS probe closed
  local h="$1"; shift
  CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_TLS_PROBE_URL="${MS_PROBE_URL:-$MS_DEAD_URL}" BOOTSTRAP_NONINTERACTIVE=1 \
    /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" 2>&1)"
  CHECK_RC=$?   # read by the checks below, and by the harness
}
ms_plan_line() { printf '%s\n' "$CHECK_OUT" | grep -E "^    $1 " | head -1; }

# ── 2. EGRESS — both modules declare, every line is <host> <install|run> <purpose>, none fetches our code
for ms_m in microsoft365 microsoft365_archive; do
  ms_out="$(ms_run "$(fresh_home "egress-$ms_m")" "egress_$ms_m")"
  ms_bad="$(printf '%s\n' "$ms_out" | awk 'NF && ($2 != "install" && $2 != "run" || NF < 3) { print "[" $0 "]" }')"
  ms_n="$(printf '%s\n' "$ms_out" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$ms_n" -gt 0 ] && [ -z "$ms_bad" ] && ! printf '%s' "$ms_out" | grep -q raw.githubusercontent.com; then
    pass "microsoft-egress-$ms_m" "$ms_n host(s)"
  else fail "microsoft-egress-$ms_m" "lines=$ms_n malformed=$ms_bad"; fi
done
ms_out="$(ms_run "$(fresh_home egress-node)" "egress_microsoft365")"
case "$ms_out" in *"nodejs.org install"*) pass "microsoft-egress-names-nodejs" ;; *) fail "microsoft-egress-names-nodejs" ;; esac

# ── 3. TLS — an inspecting proxy whose root this Mac does not trust (tls-proxy.md §5's recipe) ──
# The OS-trusted leg cannot be simulated without a trust write, which a test must never make; the
# untrusted leg and node's own behaviour can.
MS_TLS="$CHECK_WORK/tls"; MS_SRV=""; MS_URL=""
mkdir -p "$MS_TLS"
ms_ec() { /usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$1" 2>/dev/null; }
( cd "$MS_TLS" || exit 1
  ms_ec root.key; ms_ec int.key; ms_ec leaf.key
  /usr/bin/openssl req -x509 -new -sha256 -key root.key -out root.pem -days 1 -subj '/CN=Check Interception Root' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' 2>/dev/null
  /usr/bin/openssl req -new -key int.key -out int.csr -subj '/CN=Check Interception Intermediate' 2>/dev/null
  printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > int.ext
  /usr/bin/openssl x509 -req -sha256 -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -out int.pem -days 1 -extfile int.ext 2>/dev/null
  /usr/bin/openssl req -new -key leaf.key -out leaf.csr -subj '/CN=localhost' 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > leaf.ext
  /usr/bin/openssl x509 -req -sha256 -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial -out leaf.pem -days 1 -extfile leaf.ext 2>/dev/null
)
ms_tries=0
while [ -z "$MS_URL" ] && [ "$ms_tries" -lt 5 ] && [ -s "$MS_TLS/leaf.pem" ]; do
  ms_tries=$((ms_tries + 1)); ms_port=$(( 20000 + (RANDOM % 20000) ))
  /usr/bin/openssl s_server -accept "$ms_port" -cert "$MS_TLS/leaf.pem" -key "$MS_TLS/leaf.key" -CAfile "$MS_TLS/int.pem" -www -quiet >/dev/null 2>&1 &
  MS_SRV=$!
  ms_i=0
  while [ "$ms_i" -lt 30 ]; do
    /usr/bin/curl -sk -o /dev/null -m 1 "https://127.0.0.1:$ms_port/" 2>/dev/null && { MS_URL="https://127.0.0.1:$ms_port/"; break; }
    kill -0 "$MS_SRV" 2>/dev/null || break
    sleep 0.1; ms_i=$((ms_i + 1))
  done
  [ -z "$MS_URL" ] && { kill "$MS_SRV" 2>/dev/null; wait "$MS_SRV" 2>/dev/null; MS_SRV=""; }
done
if [ -z "$MS_URL" ]; then
  fail "microsoft-tls-fixture" "could not start openssl s_server"
else
  pass "microsoft-tls-fixture" "untrusted root at $MS_URL"
  # The plan says NEEDS YOU, names the certificate, and offers no command (only IT can install it).
  h="$(fresh_home tls-untrusted)"
  MS_PROBE_URL="$MS_URL" ms_drive "$h" --plan --only microsoft365
  case "$(ms_plan_line microsoft365)" in
    *"NEEDS YOU"*"intercepts TLS"*"ask IT"*) pass "microsoft-tls-untrusted-needs-human" ;;
    *) fail "microsoft-tls-untrusted-needs-human" "$(ms_plan_line microsoft365)" ;;
  esac
  same "microsoft-tls-untrusted-no-gesture" "$(ms_run "$h" gesture_microsoft365 BOOTSTRAP_TLS_PROBE_URL="$MS_URL")" ""
  # …and the control: the same Mac with the probe answering "no network" is not gated on TLS.
  ms_drive "$h" --plan --only microsoft365
  case "$(ms_plan_line microsoft365)" in
    *"intercepts TLS"*) fail "microsoft-tls-control-not-gated" "$(ms_plan_line microsoft365)" ;;
    *) pass "microsoft-tls-control-not-gated" ;;
  esac
  # node itself: refused without the CA file, accepted with it — only where a node exists to run.
  ms_node="$(ms_run "$h" microsoft365_node)"
  if [ -n "$ms_node" ]; then
    ms_js='require("https").get(process.argv[1],r=>{console.log("OK");process.exit(0)}).on("error",e=>{console.log(e.code);process.exit(0)})'
    same "microsoft-tls-node-refuses-without-ca" \
      "$(env -u NODE_EXTRA_CA_CERTS -u NODE_USE_SYSTEM_CA -u NODE_OPTIONS SSL_CERT_FILE=/etc/ssl/cert.pem "$ms_node" -e "$ms_js" "$MS_URL" 2>/dev/null)" UNABLE_TO_GET_ISSUER_CERT_LOCALLY
    same "microsoft-tls-node-accepts-with-ca" \
      "$(env -u NODE_OPTIONS NODE_EXTRA_CA_CERTS="$MS_TLS/root.pem" "$ms_node" -e "$ms_js" "$MS_URL" 2>/dev/null)" OK
  else
    pass "microsoft-tls-node-refuses-without-ca" "n/a: no node on this Mac"
    pass "microsoft-tls-node-accepts-with-ca" "n/a: no node on this Mac"
  fi
fi
[ -n "$MS_SRV" ] && { kill "$MS_SRV" 2>/dev/null; wait "$MS_SRV" 2>/dev/null; }

# The CA file, once exported, rides into BOTH registrations' env and the LaunchAgent's environment,
# and the one writer accepts it. A PEM left by an earlier run stands in for bootstrap_node_ca_env's
# export, which only an OS-trusted interception produces.
h="$(fresh_home tls-sticky)"; mkdir -p "$h/.mac-bootstrap"
cp "$MS_TLS/root.pem" "$h/.mac-bootstrap/trusted-roots.pem" 2>/dev/null
ms_out="$(ms_run "$h" 'f="$HOME/probe.json"; bootstrap_settings_merge "$f" mcpServers.ms365 "{\"type\":\"stdio\",\"command\":\"/x\",\"args\":[],\"env\":$(microsoft365_env_json)}" && bootstrap_settings_get "$f" mcpServers.ms365.env.NODE_EXTRA_CA_CERTS raw')"
same "microsoft-tls-env-in-registration" "$ms_out" "$h/.mac-bootstrap/trusted-roots.pem"
ms_out="$(ms_run "$(fresh_home tls-none)" 'microsoft365_env_json')"
case "$ms_out" in *NODE_EXTRA_CA_CERTS*) fail "microsoft-tls-no-env-without-pem" "$ms_out" ;; *) pass "microsoft-tls-no-env-without-pem" ;; esac
ms_out="$(ms_run "$h" 'p="$(microsoft365_archive_plist)"; mkdir -p "$(dirname "$p")"; microsoft365_archive_plist_build "$p" && microsoft365_archive_plist_ok && plutil -extract EnvironmentVariables.NODE_EXTRA_CA_CERTS raw -o - "$p"')"
same "microsoft-tls-env-in-launchagent" "$ms_out" "$h/.mac-bootstrap/trusted-roots.pem"
# Negative control: with the PEM gone, the same plist no longer reads back as correct.
rm -f "$h/.mac-bootstrap/trusted-roots.pem"
ms_run "$h" 'microsoft365_archive_plist_ok' && fail "microsoft-tls-launchagent-env-checked" "a stale CA entry passed" \
  || pass "microsoft-tls-launchagent-env-checked"

# ── 4. NO NODE — the pinned route, and never a Homebrew command for someone who cannot run one ────
# The whole-driver arm needs a Mac where the library's tool search finds no node; it cannot be told
# to skip Homebrew's two prefixes, so on a Mac with a Homebrew node it reports n/a. The arms after it
# stub the lookup (microsoft365_node) inside the module and check the logic that depends on it.
h="$(fresh_home no-node)"
if [ -z "$(ms_run "$h" 'microsoft365_node' PATH=/usr/bin:/bin)" ]; then
  MS_PROBE_URL="" ms_drive "$h" --plan --only microsoft365
  case "$(ms_plan_line microsoft365)" in
    *"brew install"*) fail "microsoft-no-node-plan-pinned" "$(ms_plan_line microsoft365)" ;;
    *"would install"*"nodejs.org"*) pass "microsoft-no-node-plan-pinned" "rc $CHECK_RC" ;;
    *) fail "microsoft-no-node-plan-pinned" "$(ms_plan_line microsoft365)" ;;
  esac
else
  pass "microsoft-no-node-plan-pinned" "n/a: a Homebrew node is present and bootstrap_find_tool cannot be told to ignore it"
fi
MS_NO_NODE='microsoft365_node() { return 1; }'
ms_out="$(ms_run "$h" "$MS_NO_NODE; what_microsoft365; printf '|'; gate_microsoft365 && printf gated || printf install" BOOTSTRAP_ASSUME_STANDARD_USER=1)"
case "$ms_out" in
  *"brew install"*) fail "microsoft-no-node-install-not-gate" "$ms_out" ;;
  *"fetches node 24.21.0 from nodejs.org"*"|install") pass "microsoft-no-node-install-not-gate" "no node is install_'s job, not a gate" ;;
  *) fail "microsoft-no-node-install-not-gate" "$ms_out" ;;
esac
# A fetch that failed in THIS run is a gate; a standard user is offered the re-run, never Homebrew.
MS_FAILED="$MS_NO_NODE; mkdir -p \"\$(microsoft365_dir)\"; printf '%s not-fetched\n' \"\$\$\" > \"\$(microsoft365_node_marker)\""
ms_out="$(ms_run "$h" "$MS_FAILED; gate_microsoft365 && printf 'gated|'; note_microsoft365; printf '|'; gesture_microsoft365" \
  BOOTSTRAP_ASSUME_STANDARD_USER=1 BOOTSTRAP_ENTRY="$h/bootstrap.sh")"
case "$ms_out" in
  "gated|"*"could not be downloaded from nodejs.org"*"|bash \"\$HOME/bootstrap.sh\" --only microsoft365") pass "microsoft-no-node-standard-user-rerun" ;;
  *) fail "microsoft-no-node-standard-user-rerun" "$ms_out" ;;
esac
ms_out="$(ms_run "$h" "$MS_FAILED; gesture_microsoft365" BOOTSTRAP_ASSUME_STANDARD_USER=1 BOOTSTRAP_ENTRY="")"
same "microsoft-no-node-curl-pipe-no-command" "$ms_out" ""
if [ -n "$(ms_run "$h" 'bootstrap_is_admin && bootstrap_find_tool brew')" ]; then
  ms_out="$(ms_run "$h" "$MS_FAILED; gesture_microsoft365")"
  case "$ms_out" in *'brew" install node') pass "microsoft-no-node-admin-may-brew" "$ms_out" ;; *) fail "microsoft-no-node-admin-may-brew" "$ms_out" ;; esac
else
  pass "microsoft-no-node-admin-may-brew" "n/a: not an admin with Homebrew"
fi
# A failure recorded by an EARLIER run is not a gate: this run tries the fetch again.
ms_out="$(ms_run "$h" "$MS_NO_NODE; printf '1 not-fetched\n' > \"\$(microsoft365_node_marker)\"; gate_microsoft365 && printf gated || printf install")"
same "microsoft-no-node-old-failure-retries" "$ms_out" install

# IT policy — read from the agents' own policy files (fixtures under BOOTSTRAP_MANAGED_ROOT). The worst
# case managed-policy research found: hooks locked while MCP stays allowed means the mail guard never
# runs, so the server must not be registered on that agent at all. Each arm has a no-policy control.
ms_policy() {                                   # ms_policy <root> <function> [args] — one module function
  local root="$1"; shift
  ( export HOME="$MS_POLICY_HOME" BOOTSTRAP_MANAGED_ROOT="$root" CLAUDE_CONFIG_DIR="$MS_POLICY_HOME/.claude"
    . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1; . "$CHECK_ROOT/modules/microsoft365.sh" >/dev/null 2>&1
    "$@" ) 2>/dev/null
}
MS_POLICY_HOME="$(fresh_home ms-policy)"
MS_NONE="$CHECK_TMP/ms-policy-none"; mkdir -p "$MS_NONE"
MS_HOOKS="$CHECK_TMP/ms-policy-hooks/Library/Application Support/ClaudeCode"; mkdir -p "$MS_HOOKS"
printf '{"allowManagedHooksOnly": true}\n' > "$MS_HOOKS/managed-settings.json"
MS_DENY="$CHECK_TMP/ms-policy-deny/Library/Application Support/ClaudeCode"; mkdir -p "$MS_DENY"
printf '{"deniedMcpServers": [{"serverName": "ms365"}]}\n' > "$MS_DENY/managed-settings.json"

same "ms365-policy-control-no-lock" "$(ms_policy "$MS_NONE" microsoft365_hooks_lock claude >/dev/null; echo $?)" 1
case "$(ms_policy "$CHECK_TMP/ms-policy-hooks" microsoft365_hooks_lock claude)" in
  *allowManagedHooksOnly*) pass "ms365-hooks-locked-is-named" ;; *) fail "ms365-hooks-locked-is-named" ;; esac
same "ms365-hooks-locked-withholds-the-server" "$(ms_policy "$CHECK_TMP/ms-policy-hooks" microsoft365_withheld claude; echo $?)" 0
same "ms365-hooks-locked-leaves-copilot-alone" "$(ms_policy "$CHECK_TMP/ms-policy-hooks" microsoft365_withheld copilot; echo $?)" 1
same "ms365-policy-control-no-block" "$(ms_policy "$MS_NONE" microsoft365_mcp_block claude >/dev/null; echo $?)" 1
case "$(ms_policy "$CHECK_TMP/ms-policy-deny" microsoft365_mcp_block claude)" in
  *deniedMcpServers*) pass "ms365-denied-server-is-named" ;; *) fail "ms365-denied-server-is-named" ;; esac
case "$(ms_policy "$CHECK_TMP/ms-policy-deny" microsoft365_policy_note)" in
  *[Aa]sk\ IT*|*IT*) pass "ms365-policy-note-names-it" ;; *) fail "ms365-policy-note-names-it" ;; esac

# ── 5. IT POLICY — per agent, through the real driver ────────────────────────────────────────
# BOOTSTRAP_MANAGED_ROOT prefixes the system paths the policy readers look in, so a policy is a
# fixture. A fake Softeria server (node over stdio, no network) stands in for the npm install, so the
# driver reaches the states that exist only after the reversible work.
ms_policy_root() {                              # ms_policy_root <name> <claude-json|-> <copilot-json|-> → root
  local r="$CHECK_TMP/policy-$1"
  rm -rf "$r"
  mkdir -p "$r/Library/Application Support/ClaudeCode" "$r/Library/Application Support/GitHubCopilot"
  [ "$2" = - ] || printf '%s' "$2" > "$r/Library/Application Support/ClaudeCode/managed-settings.json"
  [ "$3" = - ] || printf '%s' "$3" > "$r/Library/Application Support/GitHubCopilot/managed-settings.json"
  printf '%s' "$r"
}
MS_EMPTY_ROOT="$(ms_policy_root none - -)"

h="$(fresh_home policy-hooks)"
MS_ROOT="$(ms_policy_root hooks '{"allowManagedHooksOnly":true}' -)"
BOOTSTRAP_MANAGED_ROOT="$MS_ROOT" ms_drive "$h" --plan --only microsoft365
ms_line="$(ms_plan_line microsoft365)"
case "$ms_line" in
  *"would install"*"Claude Code's policy runs only hooks IT deploys (allowManagedHooksOnly"*"deliberately not registered"*)
    case "$ms_line" in *"Copilot CLI"*) fail "microsoft-policy-hooks-withhold-claude-only" "$ms_line" ;;
                       *) pass "microsoft-policy-hooks-withhold-claude-only" "Copilot's half still installs" ;; esac ;;
  *) fail "microsoft-policy-hooks-withhold-claude-only" "$ms_line" ;;
esac
h="$(fresh_home policy-deny-both)"
MS_ROOT="$(ms_policy_root deny-both '{"deniedMcpServers":[{"serverName":"ms365"}]}' '{"deniedMcpServers":[{"serverName":"ms365"}]}')"
BOOTSTRAP_MANAGED_ROOT="$MS_ROOT" ms_drive "$h" --plan --only microsoft365
case "$(ms_plan_line microsoft365)" in
  *"NEEDS YOU"*"Claude Code will not start"*"deniedMcpServers"*"Copilot CLI will not start"*"deniedMcpServers"*) pass "microsoft-policy-deny-both-needs-human" ;;
  *) fail "microsoft-policy-deny-both-needs-human" "$(ms_plan_line microsoft365)" ;;
esac
h="$(fresh_home policy-none)"
BOOTSTRAP_MANAGED_ROOT="$MS_EMPTY_ROOT" ms_drive "$h" --plan --only microsoft365
case "$(ms_plan_line microsoft365)" in
  *"would install"*"policy"*|*"will not start"*|*"NEEDS YOU"*) fail "microsoft-policy-none-control" "$(ms_plan_line microsoft365)" ;;
  *"would install"*) pass "microsoft-policy-none-control" ;;
  *) fail "microsoft-policy-none-control" "$(ms_plan_line microsoft365)" ;;
esac

# The installed states, only where a node exists to run the fake server.
if [ -n "$(ms_run "$CHECK_HOME" microsoft365_node)" ]; then
  h="$(fresh_home policy-installed)"
  ms_srv="$h/.mac-bootstrap/microsoft365/node_modules/@softeria/ms-365-mcp-server/dist"
  mkdir -p "$ms_srv"
  cat > "$ms_srv/index.js" <<'JS'
// A stand-in for Softeria's server: the answers the module reads, and nothing that leaves the Mac.
const a = process.argv.slice(2);
if (a.includes("--version")) { console.log("0.143.0"); process.exit(0); }
if (a.includes("--list-accounts")) { console.log(JSON.stringify({accounts: []})); process.exit(0); }
if (a.includes("--verify-login")) { console.log(JSON.stringify({success: false, message: "no account"})); process.exit(0); }
let buf = "";
process.stdin.on("data", (d) => {
  buf += d; let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    let m; try { m = JSON.parse(line); } catch (e) { continue; }
    if (m.id === undefined) continue;
    const r = m.method === "initialize" ? {result: {protocolVersion: "2025-06-18", capabilities: {tools: {}}, serverInfo: {name: "fake", version: "0.143.0"}}}
            : m.method === "tools/list" ? {result: {tools: [{name: "list-mail-messages"}, {name: "send-mail"}]}}
            : {error: {code: -32601, message: "no such method"}};
    process.stdout.write(JSON.stringify(Object.assign({jsonrpc: "2.0", id: m.id}, r)) + "\n");
  }
});
process.stdin.on("end", () => process.exit(0));
JS
  # Claude Code's MCP policy denies ms365: registered on both agents (harmless — the guard is wired),
  # and the row is NEEDS_HUMAN naming the policy, never SATISFIED.
  MS_ROOT="$(ms_policy_root deny-claude '{"deniedMcpServers":[{"serverName":"ms365"}]}' -)"
  BOOTSTRAP_MANAGED_ROOT="$MS_ROOT" ms_drive "$h" --only microsoft365
  same "microsoft-policy-deny-claude-rc" "$CHECK_RC" 10
  same "microsoft-policy-deny-claude-row" "$(receipt_states "$h/.mac-bootstrap/receipt.json" | tr '\n' ' ')" "microsoft365 NEEDS_HUMAN "
  ms_note="$(BOOTSTRAP_MANAGED_ROOT="$MS_ROOT" ms_run "$h" note_microsoft365)"
  case "$ms_note" in *"Claude Code will not start the ms365 server (deniedMcpServers"*"Meanwhile, for Copilot CLI:"*) pass "microsoft-policy-deny-claude-names-policy" ;;
    *) fail "microsoft-policy-deny-claude-names-policy" "$ms_note" ;; esac
  same "microsoft-policy-deny-claude-still-registered" \
    "$(json_at "$h/.claude.json" mcpServers.ms365.args.0)|$(json_at "$h/.copilot/mcp-config.json" mcpServers.ms365.args.0)" "$ms_srv/index.js|$ms_srv/index.js"
  # Now Claude Code's hooks are locked too: the server comes OUT of Claude Code, Copilot keeps it.
  MS_ROOT="$(ms_policy_root lock-claude '{"allowManagedHooksOnly":true}' -)"
  BOOTSTRAP_MANAGED_ROOT="$MS_ROOT" ms_drive "$h" --only microsoft365
  same "microsoft-policy-hooks-lock-rc" "$CHECK_RC" 10
  if json_at "$h/.claude.json" mcpServers.ms365.args.0 >/dev/null; then fail "microsoft-policy-hooks-lock-takes-it-back" "still in .claude.json"
  else pass "microsoft-policy-hooks-lock-takes-it-back" "gone from Claude Code"; fi
  same "microsoft-policy-hooks-lock-copilot-kept" "$(json_at "$h/.copilot/mcp-config.json" mcpServers.ms365.args.0)" "$ms_srv/index.js"
  BOOTSTRAP_MANAGED_ROOT="$MS_ROOT" ms_run "$h" verify_microsoft365 && fail "microsoft-policy-hooks-lock-not-satisfied" \
    || pass "microsoft-policy-hooks-lock-not-satisfied"
  # Control: the same installed Mac with no policy is gated only on the sign-in.
  ms_note="$(BOOTSTRAP_MANAGED_ROOT="$MS_EMPTY_ROOT" ms_run "$h" 'install_microsoft365 >/dev/null 2>&1; note_microsoft365')"
  case "$ms_note" in *policy*|*"will not start"*) fail "microsoft-policy-installed-control" "$ms_note" ;;
    *"sign in once with your work account"*) pass "microsoft-policy-installed-control" ;;
    *) fail "microsoft-policy-installed-control" "$ms_note" ;; esac
  # The person's own disableAllHooks is theirs to change: the gesture opens that file.
  mkdir -p "$h/.claude"; printf '{"disableAllHooks":true}' > "$h/.claude/settings.json"
  same "microsoft-policy-own-disable-gesture" "$(BOOTSTRAP_MANAGED_ROOT="$MS_EMPTY_ROOT" ms_run "$h" gesture_microsoft365)" 'open -e "$HOME/.claude/settings.json"'
else
  for ms_c in deny-claude-rc deny-claude-row deny-claude-names-policy deny-claude-still-registered hooks-lock-rc \
              hooks-lock-takes-it-back hooks-lock-copilot-kept hooks-lock-not-satisfied installed-control own-disable-gesture; do
    pass "microsoft-policy-$ms_c" "n/a: no node on this Mac"
  done
fi
# Copilot's own seat policy, read from its user cache after a sign-in.
h="$(fresh_home policy-copilot-seat)"; mkdir -p "$h/Library/Caches/copilot"
printf '// cache\n// v1\n{"abc":{"is_mcp_enabled": false}}' > "$h/Library/Caches/copilot/copilot-user-cache.json"
case "$(BOOTSTRAP_MANAGED_ROOT="$MS_EMPTY_ROOT" ms_run "$h" 'microsoft365_mcp_block copilot')" in
  *"MCP servers in Copilot"*) pass "microsoft-policy-copilot-seat-off" ;; *) fail "microsoft-policy-copilot-seat-off" ;; esac
printf '{"abc":{"is_mcp_enabled": true}}' > "$h/Library/Caches/copilot/copilot-user-cache.json"
same "microsoft-policy-copilot-seat-on-control" "$(BOOTSTRAP_MANAGED_ROOT="$MS_EMPTY_ROOT" ms_run "$h" 'microsoft365_mcp_block copilot || printf none')" none

# ── 6. TENANT — what signing in takes, said only where it can be true ────────────────────────
MS_NO_ACCOUNT='microsoft365_account_in_tenant() { return 1; }'
ms_out="$(ms_run "$CHECK_HOME" "$MS_NO_ACCOUNT; microsoft365_signin_note /x")"
case "$ms_out" in *"approve the app"*) fail "microsoft-tenant-work-no-self-approve" "$ms_out" ;;
  *"AADSTS65001"*"admin consent to app 084a3e9f-a9f4-43f7-89f9-d229cf97853e"*"AADSTS53003"*"--auth-browser"*) pass "microsoft-tenant-work-no-self-approve" ;;
  *) fail "microsoft-tenant-work-no-self-approve" "$ms_out" ;; esac
ms_out="$(ms_run "$CHECK_HOME" "$MS_NO_ACCOUNT; microsoft365_signin_note /x" BOOTSTRAP_MICROSOFT_TENANT=consumers)"
case "$ms_out" in *"personal Microsoft account and approve the app"*) pass "microsoft-tenant-personal-approves" ;; *) fail "microsoft-tenant-personal-approves" "$ms_out" ;; esac
ms_out="$(ms_run "$CHECK_HOME" "$MS_NO_ACCOUNT; microsoft365_signin_note /x" BOOTSTRAP_MICROSOFT_CLIENT_ID=11111111-2222-3333-4444-555555555555)"
case "$ms_out" in *"app your IT registered (11111111-"*) pass "microsoft-tenant-it-app" ;; *) fail "microsoft-tenant-it-app" "$ms_out" ;; esac
ms_out="$(ms_run "$CHECK_HOME" 'microsoft365_account_in_tenant() { return 0; }; microsoft365_run() { printf "{\"success\":false,\"message\":\"AADSTS53003: blocked\"}\n"; }; microsoft365_signin_note /x')"
case "$ms_out" in *"(AADSTS53003)"*"Conditional Access"*"--auth-browser"*) pass "microsoft-tenant-conditional-access" ;; *) fail "microsoft-tenant-conditional-access" "$ms_out" ;; esac
ms_out="$(ms_run "$CHECK_HOME" 'microsoft365_account_in_tenant() { return 0; }; microsoft365_run() { printf "{\"success\":false,\"message\":\"AADSTS65001: consent\"}\n"; }; microsoft365_signin_note /x')"
case "$ms_out" in *"(AADSTS65001)"*"admin consent"*) pass "microsoft-tenant-admin-consent" ;; *) fail "microsoft-tenant-admin-consent" "$ms_out" ;; esac
# The codes IT's policies answer with: each names its own fix, and a code with no entry stays generic.
ms_code() {                                      # ms_code <message> <snippet> — a signed-in account Microsoft answers with <message>
  ms_run "$CHECK_HOME" "microsoft365_account_in_tenant() { return 0; }; microsoft365_run() { printf '{\"success\":false,\"message\":\"%s\"}\n' '$1'; }; $2"
}
while read -r ms_c ms_want; do
  [ -n "$ms_c" ] || continue
  ms_out="$(ms_code "$ms_c: refused" 'microsoft365_signin_note /x')"
  case "$ms_out" in *"($ms_c)"*) case "$ms_out" in *"$ms_want"*) pass "microsoft-tenant-$ms_c"; continue ;; esac ;; esac
  fail "microsoft-tenant-$ms_c" "$ms_out"
done <<'EOF'
AADSTS530036 --auth-browser
AADSTS530084 cannot meet it on any Mac
AADSTS7000112 is disabled
AADSTS99999 no longer works
EOF
MS_SIGNIN_READY='microsoft365_node() { printf /n; }; microsoft365_gated_file() { return 1; }; microsoft365_tls_untrusted() { return 1; }; microsoft365_node_blocked() { return 1; }; microsoft365_hooks_lock() { return 1; }; microsoft365_usable_agents() { printf claude; }; microsoft365_ready_for_sign_in() { return 0; }; microsoft365_signed_in() { return 1; }; gesture_microsoft365'
case "$(ms_code 'AADSTS530036: refused' "$MS_SIGNIN_READY")" in *' --login --auth-browser') pass "microsoft-tenant-530036-gesture-browser" ;;
  *) fail "microsoft-tenant-530036-gesture-browser" "$(ms_code 'AADSTS530036: refused' "$MS_SIGNIN_READY")" ;; esac
case "$(ms_code 'AADSTS53000: refused' "$MS_SIGNIN_READY")" in *'" --login') pass "microsoft-tenant-gesture-device-code-control" ;;
  *) fail "microsoft-tenant-gesture-device-code-control" "$(ms_code 'AADSTS53000: refused' "$MS_SIGNIN_READY")" ;; esac
# Before any sign-in, the note already says a code sign-in may be blocked or flagged, and what is never met.
ms_out="$(ms_run "$CHECK_HOME" "$MS_NO_ACCOUNT; microsoft365_signin_note /x")"
case "$ms_out" in *"device code"*"Conditional Access may block"*"flag"*"--auth-browser"*"Token protection"*"any Mac"*) pass "microsoft-tenant-device-code-warned" ;;
  *) fail "microsoft-tenant-device-code-warned" "$ms_out" ;; esac

# ── 7. ARCHIVE — Background Items off is the person's switch, and re-run hints name BOOTSTRAP_ENTRY ──
MS_BTM_ON="$(printf '\tdisabled services = {\n\t\t"com.mac-bootstrap.microsoft365-archive" => enabled\n\t\t"com.other" => disabled\n\t}')"
MS_BTM_OFF="$(printf '\tdisabled services = {\n\t\t"com.mac-bootstrap.microsoft365-archive" => disabled\n\t}')"
ms_out="$(env HOME="$CHECK_HOME" BOOTSTRAP_LIB="$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" /bin/bash -c \
  '. "$BOOTSTRAP_LIB"; . "$1"; microsoft365_archive_disabled_in "$2" && printf off; microsoft365_archive_disabled_in "$3" && printf " off" || printf " on"' \
  x "$CHECK_ROOT/modules/microsoft365_archive.sh" "$MS_BTM_OFF" "$MS_BTM_ON" 2>/dev/null)"
same "microsoft-archive-background-off-read" "$ms_out" "off on"
ms_out="$(ms_run "$CHECK_HOME" 'microsoft365_archive_note_text background-off; printf "|"; microsoft365_archive_gate_reason() { printf background-off; }; gesture_microsoft365_archive')"
case "$ms_out" in *"Allow in the Background"*'|open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"') pass "microsoft-archive-background-off-needs-human" ;;
  *) fail "microsoft-archive-background-off-needs-human" "$ms_out" ;; esac
same "microsoft-archive-rerun-entry" "$(ms_run "$CHECK_HOME" 'microsoft365_archive_rerun microsoft365' BOOTSTRAP_ENTRY="$CHECK_HOME/x/bootstrap.sh")" 'bash "$HOME/x/bootstrap.sh" --only microsoft365'
same "microsoft-archive-rerun-curl-pipe" "$(ms_run "$CHECK_HOME" 'microsoft365_archive_rerun microsoft365' BOOTSTRAP_ENTRY= BOOTSTRAP_PIN=abc BOOTSTRAP_RAW=https://raw.githubusercontent.com/o/r/abc)" ""
