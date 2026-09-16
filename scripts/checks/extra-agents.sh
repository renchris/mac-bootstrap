# shellcheck shell=bash
# scripts/checks/extra-agents.sh — the two extra coding-agent CLIs. Sourced by scripts/characterize.sh.
#
# Nothing here reaches the network: both CLIs are file:// fixtures under the pinned-download rail, so
# what is measured is the module's behaviour, not GitHub's or npm's. The fixtures are shaped like the
# real artifacts (measured 2026-09-15): Codex is a .tar.gz holding ONE file named for the target, Gemini
# is an npm .tgz holding package/bundle/gemini.js which a node runs.
#
# What each arm is for:
#   · install lands both, and the READ-BACK executes them — never greps the file we just wrote
#   · the module is opt-in (`full`), so a default run must not select it at all
#   · a sign-in is a GATE, not a failure: uninstalled credentials mean NEEDS_HUMAN (10), not FAILED
#   · INDEPENDENCE: an unreachable Codex must not stop Gemini, and must not turn into FAILED
#   · NEGATIVE CONTROL: a wrong sha256 is refused and nothing is left behind
#   · uninstall removes what it wrote and keeps what it did not

if [ -r "$CHECK_ROOT/modules/extra_agents.sh" ]; then
  XA_FIX="$CHECK_TMP/extra-agents-fixtures"; rm -rf "$XA_FIX"; mkdir -p "$XA_FIX/stage"

  # A Codex tarball: one executable file, named for this Mac's target exactly as OpenAI names it.
  if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then XA_TARGET=aarch64-apple-darwin
  else XA_TARGET=x86_64-apple-darwin; fi
  printf '#!/bin/sh\nprintf "codex-cli 0.154.0\\n"\n' > "$XA_FIX/stage/codex-$XA_TARGET"
  chmod 755 "$XA_FIX/stage/codex-$XA_TARGET"
  ( cd "$XA_FIX/stage" && tar -czf "$XA_FIX/codex.tar.gz" "codex-$XA_TARGET" )

  # A Gemini npm tarball: package/bundle/gemini.js, which the launcher hands to a node.
  mkdir -p "$XA_FIX/stage/package/bundle"
  printf '#!/bin/sh\nprintf "0.60.0\\n"\n' > "$XA_FIX/stage/package/bundle/gemini.js"
  ( cd "$XA_FIX/stage" && tar -czf "$XA_FIX/gemini.tgz" package )

  # The two stand-ins only a fixture needs. The node answers `node -p <expr>` (how the module asks a
  # node its major version) and hands everything else to /bin/sh, so the VERSION still comes from the
  # bundle rather than from this stub. The codesign stands in for the one thing a fixture cannot have:
  # a signature over bytes OpenAI never signed.
  printf '#!/bin/sh\ncase "$1" in -p) printf "%%s\\n" 24; exit 0 ;; esac\nexec /bin/sh "$@"\n' > "$XA_FIX/node"
  chmod 755 "$XA_FIX/node"
  printf '#!/bin/sh\ncase "$1" in -dv) printf "TeamIdentifier=2DC432GLL2\\n" >&2 ;; esac\nexit 0\n' > "$XA_FIX/codesign"
  chmod 755 "$XA_FIX/codesign"

  XA_CODEX_SHA="$(shasum -a 256 "$XA_FIX/codex.tar.gz" | cut -d' ' -f1)"
  XA_GEMINI_SHA="$(shasum -a 256 "$XA_FIX/gemini.tgz" | cut -d' ' -f1)"

  # xa_drive <home> <args…> — drive_at, plus the fixture seams, and a PATH with nothing on it: the real
  # Mac running this suite HAS codex and gemini, and the module is supposed to use an existing install.
  # Blanking PATH is what makes this an install test rather than a test of this developer's laptop.
  xa_drive() {
    local h="$1"; shift
    CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      BOOTSTRAP_EXTRA_AGENTS="${XA_SEL:-codex gemini}" \
      BOOTSTRAP_EXTRA_AGENTS_CODEX_URL="file://$XA_FIX/codex.tar.gz" \
      BOOTSTRAP_EXTRA_AGENTS_CODEX_SHA256="${XA_CODEX_SHA_OVERRIDE:-$XA_CODEX_SHA}" \
      BOOTSTRAP_EXTRA_AGENTS_GEMINI_URL="file://$XA_FIX/gemini.tgz" \
      BOOTSTRAP_EXTRA_AGENTS_GEMINI_SHA256="$XA_GEMINI_SHA" \
      BOOTSTRAP_EXTRA_AGENTS_NODE="$XA_FIX/node" \
      BOOTSTRAP_EXTRA_AGENTS_CODESIGN="$XA_FIX/codesign" \
      /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" 2>&1)"
    CHECK_RC=$?
    return 0
  }
  xa_run() { HOME="$1" "$1/.mac-bootstrap/tools/bin/$2" --version 2>/dev/null | head -1; }

  # ── it is opt-in: the default profile must not select it ───────────────────────────────────
  case "$SEL_LITE
$SEL_STD" in
    *extra_agents*) fail "extra-agents-is-opt-in" "it is in lite or standard; it must be full only" ;;
    *) pass "extra-agents-is-opt-in" "not in lite or standard" ;;
  esac

  # ── install, and read it back by EXECUTING what landed ─────────────────────────────────────
  h="$(fresh_home extraagents)"
  xa_drive "$h" --only extra_agents
  same "extra-agents-install-rc" "$CHECK_RC" 10       # both landed; two sign-ins are the human's
  same "extra-agents-codex-runs" "$(xa_run "$h" codex)" "codex-cli 0.154.0"
  same "extra-agents-gemini-runs" "$(xa_run "$h" gemini)" "0.60.0"
  same "extra-agents-nothing-outside-its-prefix" \
    "$(find "$h/.mac-bootstrap/tools" -maxdepth 1 -mindepth 1 | sed "s|^$h/.mac-bootstrap/tools/||" | sort | tr '\n' ' ')" \
    "bin extra-agents "

  # A sign-in is a GATE, so the driver must say so and name ONE command, never a list.
  case "$CHECK_OUT" in *"needs you:"*) pass "extra-agents-login-is-a-gate" ;; *) fail "extra-agents-login-is-a-gate" ;; esac
  XA_GEST="$(printf '%s\n' "$CHECK_OUT" | grep -c 'tools/bin/codex login')"
  same "extra-agents-gesture-is-one-command" "$XA_GEST" "1"

  # ── the credential is only ever tested for PRESENCE ────────────────────────────────────────
  mkdir -p "$h/.codex" "$h/.gemini"
  : > "$h/.codex/auth.json"; : > "$h/.gemini/oauth_creds.json"
  xa_owned() { find "$1/.mac-bootstrap/tools" "$1/.mac-bootstrap/extra-agents" -type f \
    -exec shasum -a 256 {} \; 2>/dev/null | sed "s|$1||" | sort | shasum -a 256; }
  XA_SUM="$(xa_owned "$h")"
  xa_drive "$h" --only extra_agents
  same "extra-agents-signed-in-is-satisfied" "$CHECK_RC" 0
  same "extra-agents-second-run-changes-nothing" "$(xa_owned "$h")" "$XA_SUM"

  # A cold, separate process agrees — and then a NEGATIVE CONTROL: take one credential away and the
  # same verifier must say no, for that CLI alone.
  xa_drive "$h" --verify --only extra_agents
  same "extra-agents-cold-verify-agrees" "$CHECK_RC" 0
  rm -f "$h/.gemini/oauth_creds.json"
  xa_drive "$h" --verify --only extra_agents
  same "extra-agents-verify-sees-one-missing-sign-in" "$CHECK_RC" 10
  case "$CHECK_OUT" in
    *"Gemini CLI runs, but nobody has signed in"*) pass "extra-agents-names-the-cli-that-needs-you" ;;
    *) fail "extra-agents-names-the-cli-that-needs-you" "$(printf '%s' "$CHECK_OUT" | tr '\n' ' ' | cut -c1-120)" ;;
  esac
  : > "$h/.gemini/oauth_creds.json"

  # ── INDEPENDENCE: one CLI blocked must never stop or fail the other ────────────────────────
  h2="$(fresh_home extraagents-blocked)"
  mkdir -p "$h2/.codex" "$h2/.gemini"; : > "$h2/.codex/auth.json"; : > "$h2/.gemini/oauth_creds.json"
  XA_MISSING="$XA_FIX/codex.tar.gz"; XA_CODEX_SHA_OVERRIDE="$XA_CODEX_SHA"
  mv "$XA_MISSING" "$XA_FIX/codex.hidden"
  xa_drive "$h2" --only extra_agents
  mv "$XA_FIX/codex.hidden" "$XA_MISSING"
  same "extra-agents-blocked-one-still-installs-the-other" "$(xa_run "$h2" gemini)" "0.60.0"
  if [ -e "$h2/.mac-bootstrap/tools/bin/codex" ]; then fail "extra-agents-blocked-one-lands-nothing"
  else pass "extra-agents-blocked-one-lands-nothing"; fi

  # ── NEGATIVE CONTROL: a wrong sha256 is refused, and leaves nothing behind ─────────────────
  h3="$(fresh_home extraagents-badsha)"
  XA_SEL=codex XA_CODEX_SHA_OVERRIDE="0000000000000000000000000000000000000000000000000000000000000000" \
    xa_drive "$h3" --only extra_agents
  unset XA_CODEX_SHA_OVERRIDE
  same "extra-agents-wrong-sha-is-failed" "$CHECK_RC" 20
  if [ -e "$h3/.mac-bootstrap/tools/bin/codex" ]; then fail "extra-agents-wrong-sha-leaves-nothing"
  else pass "extra-agents-wrong-sha-leaves-nothing"; fi

  # ── a name it does not know is a typo, never a silent empty selection ──────────────────────
  h4="$(fresh_home extraagents-typo)"
  XA_SEL="codex banana" xa_drive "$h4" --only extra_agents
  same "extra-agents-unknown-name-fails" "$CHECK_RC" 20

  # ── uninstall removes what it wrote, and keeps what it did not ─────────────────────────────
  XA_KEEP="$h/.mac-bootstrap/tools/bin/somebody-elses-tool"
  printf '#!/bin/sh\nexit 0\n' > "$XA_KEEP"; chmod 755 "$XA_KEEP"
  xa_drive "$h" --uninstall --only extra_agents
  same "extra-agents-uninstall-rc" "$CHECK_RC" 0
  same "extra-agents-uninstall-removes-what-it-wrote" \
    "$(ls "$h/.mac-bootstrap/tools/extra-agents" 2>/dev/null | wc -l | tr -d ' ')/$([ -e "$h/.mac-bootstrap/tools/bin/codex" ] && printf yes || printf no)/$([ -e "$h/.mac-bootstrap/tools/bin/gemini" ] && printf yes || printf no)" \
    "0/no/no"
  if [ -x "$XA_KEEP" ]; then pass "extra-agents-uninstall-keeps-what-is-not-ours"
  else fail "extra-agents-uninstall-keeps-what-is-not-ours"; fi
  if [ -f "$h/.codex/auth.json" ] && [ -f "$h/.gemini/oauth_creds.json" ]; then
    pass "extra-agents-uninstall-never-touches-a-credential"
  else fail "extra-agents-uninstall-never-touches-a-credential"; fi

  unset XA_SEL XA_CODEX_SHA_OVERRIDE; unset -f xa_owned xa_drive xa_run
fi
