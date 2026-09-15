# shellcheck shell=bash
# scripts/checks/agent-cli.sh — agent_cli on a fresh corporate Mac: no Claude Code, no Copilot CLI,
# no admin. Sourced by scripts/characterize.sh, which supplies the harness; never run on its own.
#
# No network: every download is a file:// fixture of a tiny shell-script "agent", and the one
# unreachable host is 127.0.0.1:9 (connection refused, locally). A fixture carries no real signature,
# so codesign and the keychain come from fixtures too, through the module's two test seams. The
# positive arm on the REAL bytes — both archs' sha256 equal to manifest.json / SHA256SUMS.txt,
# codesign --strict clean, Team IDs Q6L2SF6YDW / VEKTX9H2N7, `--version` answering offline — was
# measured by hand on 2026-09-15; it needs 400 MB of vendor downloads.
#
# Units source the library and the module into a clean bash, the way the driver calls a verb, with
# bootstrap_find_tool narrowed to $HOME/elsewhere: this Mac has its own claude and copilot on the
# library's search path, and a fresh corporate Mac has neither.

AC_FX="$CHECK_TMP/agent-cli-fixtures"
mkdir -p "$AC_FX/src"

# The two fixture agents. `auth status` and `--version` reproduce the side effects measured on the
# real ones: claude creates $HOME/.claude.json, copilot unpacks into its package cache.
cat >"$AC_FX/src/claude" <<'F'
#!/bin/sh
case "$1" in
  --version) echo "${FIXTURE_CLAUDE_VERSION:-2.1.267} (Claude Code)" ;;
  auth) [ -f "$HOME/.claude.json" ] || echo '{}' >"$HOME/.claude.json"; : >"$HOME/.fixture-auth-ran"
        [ "$2" = login ] && { : >"$HOME/.fixture-login-ran"; exit 0; }
        if [ -f "$HOME/.fixture-signed-in" ]; then echo '{"loggedIn": true}'; exit 0; fi
        echo '{"loggedIn": false}'; exit 1 ;;
esac
F
cat >"$AC_FX/src/copilot" <<'F'
#!/bin/sh
a=arm64; [ "$(uname -m)" = arm64 ] || a=x64
mkdir -p "${COPILOT_PKG_CACHE_HOME:-$HOME/Library/Caches/copilot}/pkg/darwin-$a/1.0.83" && : >"${COPILOT_PKG_CACHE_HOME:-$HOME/Library/Caches/copilot}/pkg/darwin-$a/1.0.83/index.js"
case "$1" in --version) echo "GitHub Copilot CLI 1.0.83." ;; login) : >"$HOME/.fixture-login-ran" ;; esac
F
printf '#!/bin/sh\nkill -9 $$\n' >"$AC_FX/src/refused"        # what Santa does to an unlisted binary
chmod +x "$AC_FX/src/claude" "$AC_FX/src/copilot" "$AC_FX/src/refused"
(cd "$AC_FX/src" && /usr/bin/tar -czf "$AC_FX/copilot.tar.gz" copilot)
cat >"$AC_FX/codesign" <<'F'
#!/bin/sh
case "$1" in
  --verify) exit 0 ;;
  -dv) case "$2" in *claude*) echo "TeamIdentifier=${FIXTURE_TEAM_CLAUDE:-Q6L2SF6YDW}" >&2 ;; *) echo "TeamIdentifier=VEKTX9H2N7" >&2 ;; esac ;;
esac
F
printf '#!/bin/sh\n[ "${FIXTURE_KEYCHAIN:-0}" = 1 ] && exit 0\nexit 44\n' >"$AC_FX/security"
chmod +x "$AC_FX/codesign" "$AC_FX/security"
ac_sha() { /usr/bin/shasum -a 256 "$1" | cut -d' ' -f1; }
AC_CLAUDE_URL="file://$AC_FX/src/claude";      AC_CLAUDE_SHA="$(ac_sha "$AC_FX/src/claude")"
AC_COPILOT_URL="file://$AC_FX/copilot.tar.gz"; AC_COPILOT_SHA="$(ac_sha "$AC_FX/copilot.tar.gz")"

# agent_unit <home> <script> — run <script> with the module's verbs, on a fresh Mac, fixtures wired.
agent_unit() {
  HOME="$1" BOOTSTRAP_STATE_DIR="$1/.mac-bootstrap" BOOTSTRAP_ASSUME_STANDARD_USER=1 TMPDIR="$CHECK_WORK" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin BOOTSTRAP_LOG=/dev/null \
  BOOTSTRAP_AGENT_CLI_CLAUDE_URL="${AC_CLAUDE_URL_OVERRIDE:-$AC_CLAUDE_URL}" \
  BOOTSTRAP_AGENT_CLI_CLAUDE_SHA256="${AC_CLAUDE_SHA_OVERRIDE:-$AC_CLAUDE_SHA}" \
  BOOTSTRAP_AGENT_CLI_COPILOT_URL="$AC_COPILOT_URL" BOOTSTRAP_AGENT_CLI_COPILOT_SHA256="$AC_COPILOT_SHA" \
  BOOTSTRAP_AGENT_CLI_CODESIGN="$AC_FX/codesign" BOOTSTRAP_AGENT_CLI_SECURITY="$AC_FX/security" \
  /usr/bin/env -u BOOTSTRAP_AGENTS -u CLAUDE_CONFIG_DIR -u COPILOT_HOME -u COPILOT_GITHUB_TOKEN -u BOOTSTRAP_ARTIFACT_MIRROR -u XDG_DATA_HOME \
  /bin/bash -c '
    . "$1/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1
    . "$1/modules/agent_cli.sh" >/dev/null 2>&1
    bootstrap_find_tool() { [ -x "$HOME/elsewhere/$1" ] || return 1; printf "%s" "$HOME/elsewhere/$1"; }
    eval "$2"' agent_unit "$CHECK_ROOT" "$2" 2>&1
}
ac_files() { (cd "$1" && find . -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do
  if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$f" "$(ac_sha "$f")"; fi; done); }
ac_blocks() { grep -c '^# >>> mac-bootstrap agent_cli >>>$' "$1/.zprofile" 2>/dev/null | tr -d ' '; }
ac_same_files() { local now; now="$(ac_files "$2")"
  if [ "$now" = "$3" ]; then pass "$1" "$(printf "%s\n" "$now" | grep -c . | tr -d " ") file(s) byte-identical"
  else fail "$1" "$(diff <(printf "%s\n" "$3") <(printf "%s\n" "$now") | head -4 | tr "\n" " ")"; fi; }
AC_STATES='gate_agent_cli; echo "gate=$?"; verify_agent_cli; echo "verify=$?"'

# ── 1. The fixture download installs, and verifies only once someone is signed in ───────────
h="$(fresh_home agentcli-both)"
out="$(agent_unit "$h" 'install_agent_cli; echo "install=$?"')"
same "agentcli-install-rc-waits-on-login" "$(printf '%s\n' "$out" | sed -n 's/^install=//p')" 3
same "agentcli-claude-laid-out-like-vendor" "$(readlink "$h/.local/bin/claude")" "$h/.local/share/claude/versions/2.1.267"
if [ -x "$h/.local/bin/copilot" ]; then pass "agentcli-copilot-in-local-bin"; else fail "agentcli-copilot-in-local-bin"; fi
out="$(agent_unit "$h" "$AC_STATES"'; echo "G=$(gesture_agent_cli)"; echo "N=$(note_agent_cli)"')"
case "$out" in *gate=0*verify=1*) pass "agentcli-unsigned-is-needs-human" ;; *) fail "agentcli-unsigned-is-needs-human" "$out" ;; esac
AC_G="$(printf '%s\n' "$out" | sed -n 's/^G=//p')"
same "agentcli-gesture-is-the-login" "$AC_G" '$HOME/.local/bin/claude auth login'
HOME="$h" /bin/zsh -c "$AC_G" >/dev/null 2>&1
if [ -f "$h/.fixture-login-ran" ]; then pass "agentcli-gesture-runs-as-typed"; else fail "agentcli-gesture-runs-as-typed" "$AC_G"; fi
: >"$h/.fixture-signed-in"; echo "{}" >"$h/.claude.json"
out="$(agent_unit "$h" "$AC_STATES")"
case "$out" in *gate=1*verify=0*) pass "agentcli-signed-in-verifies" ;; *) fail "agentcli-signed-in-verifies" "$out" ;; esac
# independent read-back of PATH: a new Terminal's login zsh, not the module's own helper
same "agentcli-zsh-finds-claude" "$(env -i HOME="$h" PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -lc 'command -v claude' 2>/dev/null)" "$h/.local/bin/claude"
same "agentcli-zprofile-block-once" "$(ac_blocks "$h")" 1
AC_BEFORE="$(ac_files "$h")"
out="$(agent_unit "$h" 'install_agent_cli; echo "install=$?"')"
same "agentcli-second-install-rc" "$(printf '%s\n' "$out" | sed -n 's/^install=//p')" 0
ac_same_files "agentcli-second-install-changes-nothing" "$h" "$AC_BEFORE"
agent_unit "$h" 'uninstall_agent_cli' >/dev/null
AC_LEFT="$(ac_files "$h" | grep -v '\.fixture-\|\.claude\.json' | tr '\n' ' ')"
same "agentcli-uninstall-removes-its-own" "$AC_LEFT" ""

# ── 2. A wrong sha256, or a wrong signer, is refused and leaves nothing in ~/.local ──────────
for c in sha signer; do
  h="$(fresh_home "agentcli-bad-$c")"
  if [ "$c" = sha ]; then out="$(AC_CLAUDE_SHA_OVERRIDE=0000000000000000000000000000000000000000000000000000000000000000 \
                                agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli; echo "install=$?"; '"$AC_STATES")"
  else out="$(FIXTURE_TEAM_CLAUDE=ABCDE12345 agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli; echo "install=$?"; '"$AC_STATES")"; fi
  case "$out" in *install=1*gate=1*verify=1*) pass "agentcli-wrong-$c-is-failed" ;; *) fail "agentcli-wrong-$c-is-failed" "$out" ;; esac
  same "agentcli-wrong-$c-leaves-nothing" "$(find "$h/.local" \( -type f -o -type l \) 2>/dev/null | grep -c . | tr -d ' ')" 0
done

# ── 3. An agent already on the Mac is SATISFIED as it is, and uninstall never touches it ─────
h="$(fresh_home agentcli-preinstalled)"
mkdir -p "$h/elsewhere"; cp "$AC_FX/src/claude" "$h/elsewhere/claude"; AC_OWN="$(ac_sha "$h/elsewhere/claude")"
echo '{}' >"$h/.claude.json"
out="$(FIXTURE_CLAUDE_VERSION=2.0.1 agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli; echo "install=$?"; echo "N=$(note_agent_cli)"')"
case "$out" in *install=3*) pass "agentcli-preinstalled-not-reinstalled" ;; *) fail "agentcli-preinstalled-not-reinstalled" "$out" ;; esac
[ -e "$h/.local/bin/claude" ] && fail "agentcli-preinstalled-nothing-downloaded" || pass "agentcli-preinstalled-nothing-downloaded"
case "$out" in *"yours is 2.0.1"*"pin is 2.1.267"*) pass "agentcli-note-names-version-drift" ;; *) fail "agentcli-note-names-version-drift" "$out" ;; esac
: >"$h/.fixture-signed-in"
out="$(agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; '"$AC_STATES"'; uninstall_agent_cli')"
case "$out" in *gate=1*verify=0*) pass "agentcli-preinstalled-satisfied" ;; *) fail "agentcli-preinstalled-satisfied" "$out" ;; esac
same "agentcli-uninstall-spares-preinstalled" "$(ac_sha "$h/elsewhere/claude" 2>/dev/null)" "$AC_OWN"

# ── 4. A verified binary the Mac will not execute is NEEDS_HUMAN "ask IT", not FAILED ────────
h="$(fresh_home agentcli-refused)"
out="$(AC_CLAUDE_URL_OVERRIDE="file://$AC_FX/src/refused" AC_CLAUDE_SHA_OVERRIDE="$(ac_sha "$AC_FX/src/refused")" \
       agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli; echo "install=$?"; '"$AC_STATES"'; echo "G=$(gesture_agent_cli)"; echo "N=$(note_agent_cli)"')"
case "$out" in *install=1*gate=0*verify=1*) pass "agentcli-refused-is-needs-human" ;; *) fail "agentcli-refused-is-needs-human" "$out" ;; esac
case "$out" in *"ask IT to allow software signed by Anthropic PBC (Team ID Q6L2SF6YDW)"*) pass "agentcli-refused-names-signer" ;;
  *) fail "agentcli-refused-names-signer" "$out" ;; esac
case "$out" in *"G="$'\n'*|*"G=") pass "agentcli-refused-has-no-gesture" ;; *) fail "agentcli-refused-has-no-gesture" "$out" ;; esac

# ── 5. An unreachable host is NEEDS_HUMAN naming it; a missing fixture (our bug) is not ─────
h="$(fresh_home agentcli-offline)"
out="$(AC_CLAUDE_URL_OVERRIDE="http://127.0.0.1:9/claude" agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli; echo "install=$?"; '"$AC_STATES"'; echo "N=$(note_agent_cli)"')"
case "$out" in *install=1*gate=0*verify=1*) pass "agentcli-unreachable-is-needs-human" ;; *) fail "agentcli-unreachable-is-needs-human" "$out" ;; esac
case "$out" in *"refused"*"ask IT to allow https://127.0.0.1:9"*) pass "agentcli-unreachable-names-host" ;; *) fail "agentcli-unreachable-names-host" "$out" ;; esac
h="$(fresh_home agentcli-missing)"
out="$(AC_CLAUDE_URL_OVERRIDE="file://$AC_FX/no-such-file" agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli; echo "install=$?"; '"$AC_STATES")"
case "$out" in *install=1*gate=1*) pass "agentcli-missing-artifact-is-failed" ;; *) fail "agentcli-missing-artifact-is-failed" "$out" ;; esac

# ── 6. The .zprofile block: written only when needed, and uninstall restores the exact bytes ─
h="$(fresh_home agentcli-zprofile)"
printf 'export EDITOR=vi' >"$h/.zprofile"; AC_Z="$(ac_sha "$h/.zprofile")"   # no trailing newline, on purpose
agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli' >/dev/null
same "agentcli-zprofile-appended" "$(ac_blocks "$h")" 1
agent_unit "$h" 'uninstall_agent_cli' >/dev/null
same "agentcli-zprofile-restored-exactly" "$(ac_sha "$h/.zprofile")" "$AC_Z"
h="$(fresh_home agentcli-zprofile-new)"
agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli' >/dev/null
same "agentcli-zprofile-created" "$(ac_blocks "$h")" 1
agent_unit "$h" 'uninstall_agent_cli' >/dev/null
[ -e "$h/.zprofile" ] && fail "agentcli-zprofile-created-then-removed" || pass "agentcli-zprofile-created-then-removed"
h="$(fresh_home agentcli-zprofile-had-path)"
printf 'export PATH="$HOME/.local/bin:$PATH"\n' >"$h/.zprofile"
agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli' >/dev/null
same "agentcli-zprofile-not-written-when-found" "$(ac_blocks "$h")" 0

# ── 7. BOOTSTRAP_AGENTS picks: claude alone leaves copilot alone; none is nothing; typos fail ─
h="$(fresh_home agentcli-claude-only)"
out="$(agent_unit "$h" 'BOOTSTRAP_AGENTS=claude; install_agent_cli; echo "E=$(egress_agent_cli | tr "\n" ";")"')"
[ -e "$h/.local/bin/copilot" ] || [ -d "$h/Library/Caches/copilot" ] && fail "agentcli-claude-only-leaves-copilot" || pass "agentcli-claude-only-leaves-copilot"
case "$out" in *github.com*) fail "agentcli-claude-only-egress" "$out" ;; *downloads.claude.ai*) pass "agentcli-claude-only-egress" ;; *) fail "agentcli-claude-only-egress" "$out" ;; esac
h="$(fresh_home agentcli-none)"
out="$(agent_unit "$h" 'BOOTSTRAP_AGENTS=none; install_agent_cli; echo "install=$?"; '"$AC_STATES"'; echo "N=$(note_agent_cli)"')"
case "$out" in *install=0*gate=1*verify=0*"no coding agent selected"*) pass "agentcli-none-is-satisfied" ;; *) fail "agentcli-none-is-satisfied" "$out" ;; esac
same "agentcli-none-writes-nothing" "$(ac_files "$h" | grep -c . | tr -d ' ')" 0
out="$(agent_unit "$h" 'BOOTSTRAP_AGENTS="claude codex"; install_agent_cli; echo "install=$?"; '"$AC_STATES"'; echo "N=$(note_agent_cli)"')"
case "$out" in *install=1*gate=1*verify=1*"use claude, copilot or none"*) pass "agentcli-unknown-agent-is-failed" ;; *) fail "agentcli-unknown-agent-is-failed" "$out" ;; esac

# ── 8. Reading the sign-in writes nothing, and the looking modes write nothing ────────────────
h="$(fresh_home agentcli-readonly)"
agent_unit "$h" 'install_agent_cli' >/dev/null
rm -rf "$h/Library" "$h/.claude.json" "$h/.fixture-auth-ran"; AC_BEFORE="$(ac_files "$h")"
agent_unit "$h" 'BOOTSTRAP_READ_ONLY=1; '"$AC_STATES"'; note_agent_cli; gesture_agent_cli' >/dev/null
ac_same_files "agentcli-read-only-writes-nothing" "$h" "$AC_BEFORE"
[ -e "$h/.fixture-auth-ran" ] && fail "agentcli-no-claude-json-no-auth-probe" || pass "agentcli-no-claude-json-no-auth-probe"
echo '{}' >"$h/.claude.json"
agent_unit "$h" "$AC_STATES" >/dev/null                         # the control: with the file, it does ask
[ -e "$h/.fixture-auth-ran" ] && pass "agentcli-claude-json-auth-probe-runs" || fail "agentcli-claude-json-auth-probe-runs"
# Copilot's sign-in, read three ways without a value: the JSONC config, the keychain item, the env
out="$(agent_unit "$h" 'mkdir -p "$HOME/.copilot"; printf "// c\n{\"loggedInUsers\":[]}\n" >"$HOME/.copilot/config.json"
  agent_cli_signed_in copilot x && echo EMPTY-IN; printf "// c\n{\"loggedInUsers\":[{\"host\":\"https://github.com\"}]}\n" >"$HOME/.copilot/config.json"
  agent_cli_signed_in copilot x && echo CONFIG-IN; rm "$HOME/.copilot/config.json"
  FIXTURE_KEYCHAIN=1 agent_cli_signed_in copilot x && echo KEYCHAIN-IN; agent_cli_signed_in copilot x || echo NONE-OUT')"
same "agentcli-copilot-sign-in-reads" "$(printf '%s' "$out" | tr '\n' ' ')" "CONFIG-IN KEYCHAIN-IN NONE-OUT"
h="$(fresh_home agentcli-looking)"
for mode in --list --egress; do
  BOOTSTRAP_AGENTS=claude drive_at "$h" "$mode" --only agent_cli
  same "agentcli-looking${mode}-writes-nothing" "$(ac_files "$h" | grep -c . | tr -d ' ')" 0
done
case "$CHECK_OUT" in *"agent_cli"*"downloads.claude.ai"*install*) pass "agentcli-egress-declared" ;; *) fail "agentcli-egress-declared" "$(printf '%s' "$CHECK_OUT" | head -3)" ;; esac
