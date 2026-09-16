# shellcheck shell=bash
# scripts/checks/github-cli.sh — github_cli on a fresh corporate Mac: no gh, no Homebrew, no admin.
# Sourced by scripts/characterize.sh, which supplies the harness; never run on its own.
#
# No network: the download is a file:// fixture zip laid out exactly as the vendor's is
# (gh_<ver>_macOS_<arch>/bin/gh), holding a tiny shell-script "gh"; the one unreachable host is
# 127.0.0.1:9 (connection refused, locally). A fixture carries no real signature, so codesign comes
# from a fixture too, through the module's one test seam. The positive arm on the REAL bytes —
# sha256 equal to the release's own gh_2.101.0_checksums.txt, codesign --strict clean, Team ID
# VEKTX9H2N7, `gh --version` answering `gh version 2.101.0 (2026-09-15)` — was measured by hand on
# 2026-09-15; it needs a 14 MB vendor download.
#
# The fixture gh reproduces the measured side effect that shapes the module: EVERY invocation writes
# a device-id under XDG_STATE_HOME (default $HOME/.local/state/gh). That is what makes the
# "writes nothing" checks below a real control rather than a tautology.

GH_FX="$CHECK_TMP/github-cli-fixtures"
GH_VER=2.101.0
GH_ARCH=x64; [ "$(/usr/bin/uname -m)" = arm64 ] && GH_ARCH=arm64
mkdir -p "$GH_FX/src/gh_${GH_VER}_macOS_${GH_ARCH}/bin"

cat >"$GH_FX/src/gh_${GH_VER}_macOS_${GH_ARCH}/bin/gh" <<'F'
#!/bin/sh
s="${XDG_STATE_HOME:-$HOME/.local/state}/gh"; mkdir -p "$s" && : >"$s/device-id"
case "$1 $2" in
  "--version "*) echo "gh version ${FIXTURE_GH_VERSION:-2.101.0} (2026-09-15)"
                 echo "https://github.com/cli/cli/releases/tag/v2.101.0"; exit 0 ;;
  "auth login") : >"$HOME/.fixture-gh-login-ran"; exit 0 ;;
  "auth status")
    h=github.com; [ "$3" = --hostname ] && h="$4"
    [ -f "$HOME/.fixture-gh-in-$h" ] && exit 0
    echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
esac
exit 1
F
chmod +x "$GH_FX/src/gh_${GH_VER}_macOS_${GH_ARCH}/bin/gh"
cp "$GH_FX/src/gh_${GH_VER}_macOS_${GH_ARCH}/bin/gh" "$GH_FX/plain-gh"
(cd "$GH_FX/src" && /usr/bin/zip -qr "$GH_FX/gh.zip" .)
# what Santa does to an unlisted binary, in a zip of the same shape
mkdir -p "$GH_FX/refused/gh_${GH_VER}_macOS_${GH_ARCH}/bin"
printf '#!/bin/sh\nkill -9 $$\n' >"$GH_FX/refused/gh_${GH_VER}_macOS_${GH_ARCH}/bin/gh"
chmod +x "$GH_FX/refused/gh_${GH_VER}_macOS_${GH_ARCH}/bin/gh"
(cd "$GH_FX/refused" && /usr/bin/zip -qr "$GH_FX/refused.zip" .)
cat >"$GH_FX/codesign" <<'F'
#!/bin/sh
case "$1" in
  --verify) exit 0 ;;
  -dv) echo "TeamIdentifier=${FIXTURE_GH_TEAM:-VEKTX9H2N7}" >&2 ;;
esac
F
chmod +x "$GH_FX/codesign"
gh_sha() { /usr/bin/shasum -a 256 "$1" | cut -d' ' -f1; }
GH_URL="file://$GH_FX/gh.zip"; GH_SHA="$(gh_sha "$GH_FX/gh.zip")"

# gh_unit <home> <script> — run <script> with the module's verbs, on a fresh Mac, fixtures wired.
# bootstrap_find_tool is narrowed to $HOME/elsewhere: this Mac may have its own gh on the library's
# search path, and a fresh corporate Mac has none.
gh_unit() {
  HOME="$1" BOOTSTRAP_STATE_DIR="$1/.mac-bootstrap" BOOTSTRAP_ASSUME_STANDARD_USER=1 TMPDIR="$CHECK_WORK" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin BOOTSTRAP_LOG=/dev/null \
  BOOTSTRAP_GITHUB_CLI_URL="${GH_URL_OVERRIDE:-$GH_URL}" \
  BOOTSTRAP_GITHUB_CLI_SHA256="${GH_SHA_OVERRIDE:-$GH_SHA}" \
  BOOTSTRAP_GITHUB_CLI_CODESIGN="$GH_FX/codesign" \
  /usr/bin/env -u BOOTSTRAP_ARTIFACT_MIRROR -u XDG_STATE_HOME "${GH_ENV[@]}" \
  /bin/bash -c '
    . "$1/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1
    . "$1/modules/github_cli.sh" >/dev/null 2>&1
    bootstrap_find_tool() { [ -x "$HOME/elsewhere/$1" ] || return 1; printf "%s" "$HOME/elsewhere/$1"; }
    eval "$2"' gh_unit "$CHECK_ROOT" "$2" 2>&1
}
GH_ENV=(-u GH_HOST)
gh_files() { (cd "$1" && find . -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do
  if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$f" "$(gh_sha "$f")"; fi; done); }
gh_same_files() { local now; now="$(gh_files "$2")"
  if [ "$now" = "$3" ]; then pass "$1" "$(printf "%s\n" "$now" | grep -c . | tr -d " ") file(s) byte-identical"
  else fail "$1" "$(diff <(printf "%s\n" "$3") <(printf "%s\n" "$now") | head -4 | tr "\n" " ")"; fi; }
GH_STATES='gate_github_cli; echo "gate=$?"; verify_github_cli; echo "verify=$?"'

# ── 1. The pinned zip installs, and verifies only once someone is signed in ──────────────────
h="$(fresh_home githubcli-fresh)"
out="$(gh_unit "$h" 'install_github_cli; echo "install=$?"')"
same "githubcli-install-rc-waits-on-login" "$(printf '%s\n' "$out" | sed -n 's/^install=//p')" 3
same "githubcli-linked-into-tools-bin" "$(readlink "$h/.mac-bootstrap/tools/bin/gh" 2>/dev/null)" "../gh-$GH_VER/bin/gh"
if [ -x "$h/.mac-bootstrap/tools/gh-$GH_VER/bin/gh" ]; then pass "githubcli-payload-unpacked"; else fail "githubcli-payload-unpacked"; fi
same "githubcli-download-not-kept" "$(find "$h/.mac-bootstrap/tools/downloads" -type f 2>/dev/null | grep -c . | tr -d ' ')" 0
out="$(gh_unit "$h" "$GH_STATES"'; echo "G=$(gesture_github_cli)"; echo "N=$(note_github_cli)"')"
case "$out" in *gate=0*verify=1*) pass "githubcli-signed-out-is-needs-human" ;; *) fail "githubcli-signed-out-is-needs-human" "$out" ;; esac
case "$out" in *"not signed in to github.com"*) pass "githubcli-note-names-the-host" ;; *) fail "githubcli-note-names-the-host" "$out" ;; esac
GH_G="$(printf '%s\n' "$out" | sed -n 's/^G=//p')"
same "githubcli-gesture-is-the-login" "$GH_G" '$HOME/.mac-bootstrap/tools/bin/gh auth login'
HOME="$h" /bin/zsh -c "$GH_G" >/dev/null 2>&1
if [ -f "$h/.fixture-gh-login-ran" ]; then pass "githubcli-gesture-runs-as-typed"; else fail "githubcli-gesture-runs-as-typed" "$GH_G"; fi
rm -f "$h/.fixture-gh-login-ran"

# The probes must never write to $HOME — every gh invocation creates a device-id under the state dir.
rm -rf "$h/.local"
gh_unit "$h" "$GH_STATES"'; note_github_cli; gesture_github_cli' >/dev/null
[ -e "$h/.local/state/gh" ] && fail "githubcli-probes-write-nothing-to-home" || pass "githubcli-probes-write-nothing-to-home"
# POSITIVE CONTROL: the same fixture, run without the module's redirect, does create it.
HOME="$h" "$GH_FX/plain-gh" --version >/dev/null 2>&1
[ -e "$h/.local/state/gh/device-id" ] && pass "githubcli-device-id-control" || fail "githubcli-device-id-control"
rm -rf "$h/.local"

: >"$h/.fixture-gh-in-github.com"
out="$(gh_unit "$h" "$GH_STATES")"
case "$out" in *gate=1*verify=0*) pass "githubcli-signed-in-verifies" ;; *) fail "githubcli-signed-in-verifies" "$out" ;; esac
GH_BEFORE="$(gh_files "$h")"
out="$(gh_unit "$h" 'install_github_cli; echo "install=$?"')"
same "githubcli-second-install-rc" "$(printf '%s\n' "$out" | sed -n 's/^install=//p')" 0
gh_same_files "githubcli-second-install-changes-nothing" "$h" "$GH_BEFORE"
gh_unit "$h" 'uninstall_github_cli' >/dev/null
same "githubcli-uninstall-removes-its-own" \
  "$(find "$h/.mac-bootstrap" \( -type f -o -type l \) 2>/dev/null | grep -c . | tr -d ' ')/$([ -e "$h/.mac-bootstrap/tools" ] && echo tools-left || echo tools-gone)" "0/tools-gone"

# ── 2. A wrong sha256, or a wrong signer, is FAILED and leaves nothing behind ────────────────
for c in sha signer; do
  h="$(fresh_home "githubcli-bad-$c")"
  if [ "$c" = sha ]; then
    GH_ENV=(-u GH_HOST)
    out="$(GH_SHA_OVERRIDE=0000000000000000000000000000000000000000000000000000000000000000 \
             gh_unit "$h" 'install_github_cli; echo "install=$?"; '"$GH_STATES")"
  else
    GH_ENV=(-u GH_HOST FIXTURE_GH_TEAM=ABCDE12345)
    out="$(gh_unit "$h" 'install_github_cli; echo "install=$?"; '"$GH_STATES")"
  fi
  case "$out" in *install=1*gate=1*verify=1*) pass "githubcli-wrong-$c-is-failed" ;; *) fail "githubcli-wrong-$c-is-failed" "$out" ;; esac
  same "githubcli-wrong-$c-leaves-no-gh" "$(find "$h/.mac-bootstrap/tools" \( -type f -o -type l \) 2>/dev/null | grep -c . | tr -d ' ')" 0
done
GH_ENV=(-u GH_HOST)

# ── 3. An unreachable host is NEEDS_HUMAN naming it; a missing fixture (our bug) is not ──────
h="$(fresh_home githubcli-offline)"
out="$(GH_URL_OVERRIDE="http://127.0.0.1:9/gh.zip" gh_unit "$h" 'install_github_cli; echo "install=$?"; '"$GH_STATES"'; echo "N=$(note_github_cli)"; echo "G=$(gesture_github_cli)"')"
case "$out" in *install=1*gate=0*verify=1*) pass "githubcli-unreachable-is-needs-human" ;; *) fail "githubcli-unreachable-is-needs-human" "$out" ;; esac
case "$out" in *"refused"*"ask IT to allow https://127.0.0.1:9"*"BOOTSTRAP_ARTIFACT_MIRROR"*) pass "githubcli-unreachable-names-host-and-mirror" ;;
  *) fail "githubcli-unreachable-names-host-and-mirror" "$out" ;; esac
case "$out" in *"G="$'\n'*|*"G=") pass "githubcli-unreachable-has-no-gesture" ;; *) fail "githubcli-unreachable-has-no-gesture" "$out" ;; esac
h="$(fresh_home githubcli-missing)"
out="$(GH_URL_OVERRIDE="file://$GH_FX/no-such-file" gh_unit "$h" 'install_github_cli; echo "install=$?"; '"$GH_STATES")"
case "$out" in *install=1*gate=1*) pass "githubcli-missing-artifact-is-failed" ;; *) fail "githubcli-missing-artifact-is-failed" "$out" ;; esac

# ── 4. A verified binary the Mac will not execute is NEEDS_HUMAN "ask IT", not FAILED ────────
h="$(fresh_home githubcli-refused)"
out="$(GH_URL_OVERRIDE="file://$GH_FX/refused.zip" GH_SHA_OVERRIDE="$(gh_sha "$GH_FX/refused.zip")" \
       gh_unit "$h" 'install_github_cli; echo "install=$?"; '"$GH_STATES"'; echo "N=$(note_github_cli)"; echo "G=$(gesture_github_cli)"')"
case "$out" in *install=1*gate=0*verify=1*) pass "githubcli-refused-is-needs-human" ;; *) fail "githubcli-refused-is-needs-human" "$out" ;; esac
case "$out" in *"ask IT to allow software signed by GitHub (Team ID VEKTX9H2N7)"*) pass "githubcli-refused-names-signer" ;;
  *) fail "githubcli-refused-names-signer" "$out" ;; esac
case "$out" in *"G="$'\n'*|*"G=") pass "githubcli-refused-has-no-gesture" ;; *) fail "githubcli-refused-has-no-gesture" "$out" ;; esac

# ── 5. A gh already on the Mac is used as it is, and uninstall never touches it ──────────────
h="$(fresh_home githubcli-preinstalled)"
mkdir -p "$h/elsewhere"; cp "$GH_FX/plain-gh" "$h/elsewhere/gh"; GH_OWN="$(gh_sha "$h/elsewhere/gh")"
GH_ENV=(-u GH_HOST FIXTURE_GH_VERSION=2.60.1)
out="$(gh_unit "$h" 'install_github_cli; echo "install=$?"; echo "N=$(note_github_cli)"')"
case "$out" in *install=3*) pass "githubcli-preinstalled-not-reinstalled" ;; *) fail "githubcli-preinstalled-not-reinstalled" "$out" ;; esac
[ -e "$h/.mac-bootstrap/tools/bin/gh" ] && fail "githubcli-preinstalled-nothing-downloaded" || pass "githubcli-preinstalled-nothing-downloaded"
case "$out" in *"yours is 2.60.1"*"pin is $GH_VER"*) pass "githubcli-note-names-version-drift" ;; *) fail "githubcli-note-names-version-drift" "$out" ;; esac
: >"$h/.fixture-gh-in-github.com"
out="$(gh_unit "$h" "$GH_STATES"'; uninstall_github_cli')"
case "$out" in *gate=1*verify=0*) pass "githubcli-preinstalled-satisfied" ;; *) fail "githubcli-preinstalled-satisfied" "$out" ;; esac
same "githubcli-uninstall-spares-preinstalled" "$(gh_sha "$h/elsewhere/gh" 2>/dev/null)" "$GH_OWN"
GH_ENV=(-u GH_HOST)

# ── 6. GH_HOST: only the company's tenant counts, and the gesture names it ────────────────────
h="$(fresh_home githubcli-enterprise)"
GH_ENV=(GH_HOST=github.acme-corp.example)
gh_unit "$h" 'install_github_cli' >/dev/null
: >"$h/.fixture-gh-in-github.com"                       # signed into github.com, NOT into the tenant
out="$(gh_unit "$h" "$GH_STATES"'; echo "G=$(gesture_github_cli)"; echo "N=$(note_github_cli)"; echo "E=$(egress_github_cli | tr "\n" ";")"')"
case "$out" in *gate=0*verify=1*) pass "githubcli-enterprise-github-com-is-not-enough" ;; *) fail "githubcli-enterprise-github-com-is-not-enough" "$out" ;; esac
same "githubcli-enterprise-gesture-names-the-host" "$(printf '%s\n' "$out" | sed -n 's/^G=//p')" \
  '$HOME/.mac-bootstrap/tools/bin/gh auth login --hostname github.acme-corp.example'
case "$out" in *"E="*"github.acme-corp.example run every gh command"*) pass "githubcli-enterprise-egress-names-the-host" ;;
  *) fail "githubcli-enterprise-egress-names-the-host" "$out" ;; esac
: >"$h/.fixture-gh-in-github.acme-corp.example"
out="$(gh_unit "$h" "$GH_STATES")"
case "$out" in *gate=1*verify=0*) pass "githubcli-enterprise-signed-in-verifies" ;; *) fail "githubcli-enterprise-signed-in-verifies" "$out" ;; esac
GH_ENV=(-u GH_HOST)

# ── 7. The looking modes write nothing, and declare the egress ───────────────────────────────
h="$(fresh_home githubcli-looking)"
for mode in --list --egress; do
  drive_at "$h" "$mode" --only github_cli
  same "githubcli-looking${mode}-writes-nothing" "$(gh_files "$h" | grep -c . | tr -d ' ')" 0
done
case "$CHECK_OUT" in *"github_cli"*"github.com"*install*) pass "githubcli-egress-declared" ;; *) fail "githubcli-egress-declared" "$(printf '%s' "$CHECK_OUT" | head -3)" ;; esac
drive_at "$h" --plan --only github_cli
case "$CHECK_RC" in 0|10) pass "githubcli-plan-rc" "$CHECK_RC" ;; *) fail "githubcli-plan-rc" "$CHECK_RC" ;; esac
