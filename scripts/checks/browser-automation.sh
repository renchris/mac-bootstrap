# shellcheck shell=bash
# scripts/checks/browser-automation.sh — the agent-browser CLI module. Sourced by
# scripts/characterize.sh, which supplies the harness; never run on its own.
#
# No network, no real npm install, no real browser is launched. The installed tree is a FAKE: a
# /bin/sh script standing where the native binary goes, which answers --version the way the real one
# does and otherwise prints the browser it was handed. That is enough to drive every arm that
# matters — the read-back, the launcher's choice of browser, and the three gates — because the
# module's own contract is "execute what is installed and parse what it prints".

if [ -r "$CHECK_ROOT/modules/browser_automation.sh" ]; then

BA_MODULE="$CHECK_ROOT/modules/browser_automation.sh"
BA_DEAD_URL="https://127.0.0.1:9/"
# A browser name that is NOT on the machine running this suite, so detection is hermetic: the real
# /Applications is searched first and a real Chrome there would decide every answer below.
BA_BROWSERS='Checkium.app'
BA_OVERRIDE="BROWSER_AUTOMATION_BROWSERS='$BA_BROWSERS';"

# ba_run <home> <snippet> [VAR=value …] — a fresh /bin/bash with the library and the module sourced,
# HOME set to <home>, the browser list narrowed, then <snippet>. Every TLS probe goes to a closed
# local port unless a check says otherwise, so nothing here reaches the network.
ba_run() {
  local h="$1" s="$2"; shift 2
  env HOME="$h" BOOTSTRAP_STATE_DIR="$h/.mac-bootstrap" BOOTSTRAP_LIB="$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" \
      BOOTSTRAP_ASSETS="$CHECK_ROOT/assets" BOOTSTRAP_TLS_PROBE_URL="$BA_DEAD_URL" TMPDIR="$CHECK_WORK" "$@" \
      /bin/bash -c '. "$BOOTSTRAP_LIB"; . "$1"; eval "$2"' browser-check "$BA_MODULE" "$BA_OVERRIDE$s" 2>/dev/null
}
ba_arch() { [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && printf arm64 || printf x64; }
ba_browser() {                                  # ba_browser <home> — a fake Chromium-family browser
  local x="$1/Applications/Checkium.app/Contents/MacOS/Checkium"
  mkdir -p "$(dirname "$x")"
  printf '#!/bin/sh\necho "Checkium 99.0.1234.5"\n' > "$x"; chmod 755 "$x"
  printf '%s' "$x"
}
ba_install() {                                  # ba_install <home> [version] — the fake installed tree
  local d="$1/.mac-bootstrap/browser-automation/node_modules/agent-browser/bin"
  mkdir -p "$d"
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "agent-browser %s"; exit 0; }\necho "EXE=${AGENT_BROWSER_EXECUTABLE_PATH:-}"\nexit 0\n' \
    "${2:-0.37.1}" > "$d/agent-browser-darwin-$(ba_arch)"
  chmod 755 "$d/agent-browser-darwin-$(ba_arch)"
}

# ── 1. the catalog: egress declared and well formed, clearance names both classes, opt-in ────
h="$(fresh_home ba-catalog)"
ba_out="$(ba_run "$h" 'egress_browser_automation')"
ba_bad="$(printf '%s\n' "$ba_out" | awk 'NF && ($2 != "install" && $2 != "run" || NF < 3) { print "[" $0 "]" }')"
ba_n="$(printf '%s\n' "$ba_out" | awk 'NF' | wc -l | tr -d ' ')"
if [ "$ba_n" = 3 ] && [ -z "$ba_bad" ] && ! printf '%s' "$ba_out" | grep -q raw.githubusercontent.com; then
  pass "browser-egress-declared" "$ba_n host(s)"
else fail "browser-egress-declared" "lines=$ba_n malformed=$ba_bad"; fi
case "$ba_out" in *"registry.npmjs.org install"*) pass "browser-egress-names-npm" ;; *) fail "browser-egress-names-npm" "$ba_out" ;; esac
# The run line is the honest one: the CLI reaches whatever the person opens, and says so.
case "$ba_out" in *" run "*"whatever page"*) pass "browser-egress-run-is-honest" ;; *) fail "browser-egress-run-is-honest" "$ba_out" ;; esac
ba_out="$(ba_run "$h" 'clearance_browser_automation')"
case "$ba_out" in
  *"software "*"agent "*) pass "browser-clearance-classes" ;;
  *) fail "browser-clearance-classes" "$ba_out" ;;
esac
case "$ba_out" in *"logged-in session"*) pass "browser-clearance-states-the-sessions" ;; *) fail "browser-clearance-states-the-sessions" "$ba_out" ;; esac
same "browser-profile-is-opt-in" "$(ba_run "$h" 'profile_browser_automation')" full
same "browser-needs-agent-cli"   "$(ba_run "$h" 'needs_browser_automation')" agent_cli

# ── 2. no browser is a GATE with a plain-English step and NO command ──────────────────────────
h="$(fresh_home ba-nobrowser)"; ba_install "$h"
ba_run "$h" 'gate_browser_automation' && pass "browser-none-is-a-gate" || fail "browser-none-is-a-gate" "gate said no"
case "$(ba_run "$h" 'note_browser_automation')" in
  *"no Chromium-family browser"*"cannot run without one"*"Ask IT"*) pass "browser-none-note-names-the-step" ;;
  *) fail "browser-none-note-names-the-step" "$(ba_run "$h" 'note_browser_automation')" ;;
esac
same "browser-none-no-gesture" "$(ba_run "$h" 'gesture_browser_automation')" ""
# …and the driver says so, in --plan. The driver cannot be told to narrow the browser list — it
# sources the module from the tree — so this arm runs only on a Mac that genuinely has no
# Chromium-family browser, and reports n/a on one that has.
if [ -z "$(HOME="$h" /bin/bash -c '. "$1"; . "$2"; browser_automation_detect' _ "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" "$BA_MODULE" 2>/dev/null)" ]; then
  CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_TLS_PROBE_URL="$BA_DEAD_URL" \
    /bin/bash "$CHECK_ROOT/bootstrap.sh" --plan --only browser_automation 2>&1)"; CHECK_RC=$?
  case "$(printf '%s\n' "$CHECK_OUT" | grep -E '^    browser_automation ' | head -1)" in
    *"NEEDS YOU"*) same "browser-none-plan-rc" "$CHECK_RC" 10 ;;
    *) fail "browser-none-plan-rc" "rc $CHECK_RC: $(printf '%s\n' "$CHECK_OUT" | grep -E '^    browser_automation ' | head -1)" ;;
  esac
else
  pass "browser-none-plan-rc" "n/a: this Mac has a Chromium-family browser and the driver reads the real /Applications"
fi

# ── 3. the browser it will drive is recorded, read back, and handed to the CLI ────────────────
h="$(fresh_home ba-browser)"; ba_install "$h"; BA_EXE="$(ba_browser "$h")"
ba_run "$h" 'gate_browser_automation' && fail "browser-present-not-gated" || pass "browser-present-not-gated"
same "browser-detects-the-one-present" "$(ba_run "$h" 'browser_automation_detect')" "$BA_EXE"
ba_run "$h" 'install_browser_automation >/dev/null 2>&1; verify_browser_automation' \
  && pass "browser-install-then-verify" || fail "browser-install-then-verify"
same "browser-records-what-it-drives" "$(cat "$h/.mac-bootstrap/browser-automation/browser" 2>/dev/null)" "$BA_EXE"
# The launcher hands the recorded browser to the CLI — read out of the CLI's own process, not the file.
same "browser-launcher-passes-the-browser" "$("$h/.local/bin/agent-browser" go 2>/dev/null)" "EXE=$BA_EXE"
# …and a caller who names one keeps it.
same "browser-launcher-yields-to-the-caller" \
  "$(AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/true "$h/.local/bin/agent-browser" go 2>/dev/null)" "EXE=/usr/bin/true"
same "browser-launcher-runs-the-pinned-cli" "$("$h/.local/bin/agent-browser" --version 2>/dev/null)" "agent-browser 0.37.1"

# ── 4. NEGATIVE CONTROLS — verify must be able to say no ──────────────────────────────────────
# A browser this module would never have chosen does not pass as one it did.
ba_run "$h" 'browser_automation_known /usr/bin/true' && fail "browser-known-refuses-a-stranger" || pass "browser-known-refuses-a-stranger"
# The recorded browser removed: satisfied yesterday, not satisfied now.
mv "$BA_EXE" "$BA_EXE.gone"
ba_run "$h" 'verify_browser_automation' && fail "browser-verify-sees-a-removed-browser" || pass "browser-verify-sees-a-removed-browser"
mv "$BA_EXE.gone" "$BA_EXE"
# A CLI of the wrong version is not this module's end state (the CLI exits 0 on an unknown command,
# so only the printed version can ever prove it).
ba_install "$h" 9.9.9
ba_run "$h" 'verify_browser_automation' && fail "browser-verify-checks-the-version" || pass "browser-verify-checks-the-version"
ba_install "$h"
# The launcher removed, the package still there.
mv "$h/.local/bin/agent-browser" "$h/launcher.gone"
ba_run "$h" 'verify_browser_automation' && fail "browser-verify-sees-a-missing-launcher" || pass "browser-verify-sees-a-missing-launcher"
mv "$h/launcher.gone" "$h/.local/bin/agent-browser"
ba_run "$h" 'verify_browser_automation' && pass "browser-verify-agrees-again" || fail "browser-verify-agrees-again"

# ── 5. an intercepting proxy whose root this Mac does not trust: gate, ask IT, no command ─────
BA_UNTRUSTED='bootstrap_node_ca_env() { return 2; };'
ba_run "$h" "$BA_UNTRUSTED gate_browser_automation" && pass "browser-tls-untrusted-is-a-gate" || fail "browser-tls-untrusted-is-a-gate"
case "$(ba_run "$h" "$BA_UNTRUSTED note_browser_automation")" in
  *"intercepts TLS"*"ask IT"*) pass "browser-tls-untrusted-note" ;;
  *) fail "browser-tls-untrusted-note" "$(ba_run "$h" "$BA_UNTRUSTED note_browser_automation")" ;;
esac
same "browser-tls-untrusted-no-gesture" "$(ba_run "$h" "$BA_UNTRUSTED gesture_browser_automation")" ""
# The control: the same Mac with the probe merely unreachable is not gated on TLS.
ba_run "$h" 'gate_browser_automation' && fail "browser-tls-control-not-gated" || pass "browser-tls-control-not-gated"

# ── 6. no node: install_'s job, never a gate — and never Homebrew for someone who cannot run it ──
BA_NO_NODE='browser_automation_node() { return 1; };'
ba_run "$h" "$BA_NO_NODE gate_browser_automation" && fail "browser-no-node-is-not-a-gate" || pass "browser-no-node-is-not-a-gate"
# A fetch that failed in THIS run is a gate, and a standard user is offered the re-run, never brew.
ba_out="$(ba_run "$h" "$BA_NO_NODE printf '%s not-fetched\n' \$\$ > \"\$(browser_automation_node_marker)\"; gate_browser_automation && printf gated; printf '|'; note_browser_automation; printf '|'; gesture_browser_automation" \
  BOOTSTRAP_ASSUME_STANDARD_USER=1 BOOTSTRAP_ENTRY="$CHECK_ROOT/bootstrap.sh")"
case "$ba_out" in
  gated\|*"could not be downloaded from nodejs.org"*\|*"--only browser_automation") pass "browser-no-node-fetch-failed-is-a-gate" ;;
  *) fail "browser-no-node-fetch-failed-is-a-gate" "$ba_out" ;;
esac
case "$ba_out" in *"brew install"*) fail "browser-no-node-never-brew-for-standard-user" "$ba_out" ;; *) pass "browser-no-node-never-brew-for-standard-user" ;; esac

# ── 7. uninstall takes back what it wrote, and nothing else ───────────────────────────────────
h="$(fresh_home ba-uninstall)"; ba_install "$h"; BA_EXE="$(ba_browser "$h")"
mkdir -p "$h/.mac-bootstrap/tools/bin"; printf 'shared node\n' > "$h/.mac-bootstrap/tools/bin/node"
mkdir -p "$h/.local/bin"
printf '#!/bin/sh\n# someone else\n' > "$h/.local/bin/other-tool"; chmod 755 "$h/.local/bin/other-tool"
ba_run "$h" 'install_browser_automation >/dev/null 2>&1; uninstall_browser_automation'
same "browser-uninstall-removes-the-prefix" "$([ -e "$h/.mac-bootstrap/browser-automation" ] && printf left || printf gone)" gone
same "browser-uninstall-removes-its-launcher" "$([ -e "$h/.local/bin/agent-browser" ] && printf left || printf gone)" gone
same "browser-uninstall-keeps-the-shared-node" "$([ -e "$h/.mac-bootstrap/tools/bin/node" ] && printf kept || printf gone)" kept
same "browser-uninstall-keeps-the-browser" "$([ -x "$BA_EXE" ] && printf kept || printf gone)" kept
same "browser-uninstall-keeps-what-is-not-ours" "$([ -e "$h/.local/bin/other-tool" ] && printf kept || printf gone)" kept
# A launcher of the same name that is NOT ours is never removed.
h="$(fresh_home ba-foreign)"; mkdir -p "$h/.local/bin"
printf '#!/bin/sh\necho mine\n' > "$h/.local/bin/agent-browser"; chmod 755 "$h/.local/bin/agent-browser"
ba_run "$h" 'uninstall_browser_automation'
same "browser-uninstall-keeps-a-foreign-launcher" "$([ -e "$h/.local/bin/agent-browser" ] && printf kept || printf gone)" kept

fi
