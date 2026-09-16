#!/bin/bash
# github_cli — the GitHub CLI (`gh`) in your home folder, with no admin and no Homebrew, and signed in.
#
# SOURCED, never executed. Six verbs, no top-level side effects (CONTRACT.md §1).
#
# WHY IT IS HERE: git and GitHub access is load-bearing for the agent workflow this repo sets up —
# cloning, pull requests, issues, `gh api`, and the credential helper `gh auth setup-git` writes. The
# repo installed neither Homebrew nor gh, so on a corporate Mac with no admin rights there was no
# route to it at all.
#
# THE END STATE, stated so verify_ can be read against it: `gh` resolves, running it answers
# `--version` with a version parsed out of ITS OWN OUTPUT, and one GitHub host is signed in. A `gh`
# already on the Mac by any route (Homebrew, a .pkg IT pushed, a manual unpack) counts as it is and
# is never reinstalled, upgraded or removed.
#
# WHAT IS PINNED, measured 2026-09-15 by downloading the artifact and running it:
#   GitHub CLI 2.101.0 — the latest release of cli/cli that day. Both sha256s are the ones in that
#     release's own gh_2.101.0_checksums.txt; the arm64 zip was fetched, its hash confirmed, unpacked
#     (`gh_<ver>_macOS_<arch>/bin/gh` + share/man + LICENSE), `codesign --verify --strict` clean,
#     TeamIdentifier=VEKTX9H2N7 — the same GitHub Team ID agent_cli pins for Copilot CLI — and
#     `gh --version` answered `gh version 2.101.0 (2026-09-15)`.
#
# ONE MEASURED SIDE EFFECT this module steers around. Do not "simplify" it away:
#   · EVERY gh invocation — `--version` included, not just `auth status` — creates
#     $HOME/.local/state/gh/device-id on a Mac where gh has never run. The looking modes
#     (--list, --plan, --egress) call gate_, and a verb they call must not write (CONTRACT.md §5).
#     So every probe here runs with XDG_STATE_HOME pointed at a throwaway directory, which gh
#     honours: measured, $HOME stayed empty. GH_NO_UPDATE_NOTIFIER=1 goes with it, so a probe never
#     makes gh's own new-release call.
#
# AUTHENTICATION IS THE HUMAN'S, ALWAYS. `gh auth login` is a browser or device flow that ends in the
# system credential store — never run it here; report it as the gate and print the one command. It is
# also why install_ returns 3 when nothing is signed in: that makes the driver ask gate_ again and
# record NEEDS_HUMAN, instead of reading a true "installed but not signed in" as FAILED.
#
# A download refused by a proxy, DNS or an untrusted certificate is the network's, not ours:
# NEEDS_HUMAN naming the host and BOOTSTRAP_ARTIFACT_MIRROR. So is a verified binary this Mac will
# not execute (Santa, binary authorization). A wrong sha256 or a wrong signer is FAILED.
#
# bash 3.2 · set -u, no set -e.

GITHUB_CLI_VERSION='2.101.0'
GITHUB_CLI_SHA256_ARM64='e4303e39d8f07141c4bad4b99b01079f05029c59b27076e8fbc825c985ecdd8b'
GITHUB_CLI_SHA256_X64='a6fd66c88e2f07d6e4e058173db341d07dd74d58cf8f19ae668293d2bb614ca3'
GITHUB_CLI_TEAM='VEKTX9H2N7'
# Test seam: a fixture carries no real signature, so codesign comes from a fixture too.
GITHUB_CLI_CODESIGN="${BOOTSTRAP_GITHUB_CLI_CODESIGN:-/usr/bin/codesign}"

github_cli_state() { printf '%s/github-cli' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
github_cli_marker() { printf '%s/unreachable' "$(github_cli_state)"; }
github_cli_dir()   { printf '%s/gh-%s' "$(bootstrap_tools_dir)" "$GITHUB_CLI_VERSION"; }
github_cli_link()  { printf '%s/bin/gh' "$(bootstrap_tools_dir)"; }
github_cli_zip()   { printf '%s/downloads/gh-%s.zip' "$(bootstrap_tools_dir)" "$GITHUB_CLI_VERSION"; }
github_cli_short() { case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
# The tenant this Mac talks to: GitHub Enterprise when GH_HOST names one, github.com otherwise.
github_cli_gh_host() { printf '%s' "${GH_HOST:-github.com}"; }

# The vendor's own rule, as agent_cli reads it: a shell translated by Rosetta still gets arm64.
github_cli_arch() {
  [ "$(/usr/bin/uname -m)" = arm64 ] && { printf arm64; return; }
  [ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ] && { printf arm64; return; }
  printf x64
}
github_cli_url() {
  printf '%s' "${BOOTSTRAP_GITHUB_CLI_URL:-https://github.com/cli/cli/releases/download/v$GITHUB_CLI_VERSION/gh_${GITHUB_CLI_VERSION}_macOS_$(github_cli_arch).zip}"
}
github_cli_sha() {
  local d
  case "$(github_cli_arch)" in arm64) d="$GITHUB_CLI_SHA256_ARM64" ;; *) d="$GITHUB_CLI_SHA256_X64" ;; esac
  printf '%s' "${BOOTSTRAP_GITHUB_CLI_SHA256:-$d}"
}
github_cli_host() { local h="${1#*://}"; h="${h%%/*}"; printf '%s' "${h:-the download URL}"; }
# Where bootstrap_fetch_pinned tries FIRST: IT's mirror when one is set, else the vendor.
github_cli_source() {
  if [ -n "${BOOTSTRAP_ARTIFACT_MIRROR:-}" ]; then printf '%s/%s' "${BOOTSTRAP_ARTIFACT_MIRROR%/}" "${1#*://}"
  else printf '%s' "$1"; fi
}

# github_cli_bounded <secs> <outfile> <cmd…> — run with stdin closed and stdout to <outfile>, killed
# after <secs> (macOS has no timeout(1)); a kill leaves <outfile>.timeout. `gh auth status` calls the
# API to test the stored token, and a TLS-inspecting proxy can sit on that call for minutes.
github_cli_bounded() {
  local secs="$1" out="$2" pid rc; shift 2
  "$@" >"$out" 2>/dev/null </dev/null &
  pid=$!
  ( i=0; while [ "$i" -lt "$secs" ]; do /bin/sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; i=$((i + 1)); done
    : >"$out.timeout"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wait "$pid"; rc=$?
  return "$rc"
}

# github_cli_ask <secs> <bin> <args…> — ask gh something, writing NOTHING to $HOME (see the header's
# device-id note). Prints gh's first line; rc is gh's own, or 124 if we killed it.
github_cli_ask() {
  local secs="$1" tmp rc; shift
  tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/github-cli.XXXXXX")" || return 1
  github_cli_bounded "$secs" "$tmp/out" /usr/bin/env XDG_STATE_HOME="$tmp/state" GH_NO_UPDATE_NOTIFIER=1 "$@"
  rc=$?
  [ -e "$tmp/out.timeout" ] && rc=124
  /usr/bin/head -1 "$tmp/out" 2>/dev/null
  /bin/rm -rf "$tmp"
  return "$rc"
}

# github_cli_exec <bin> — prints the version gh REPORTS OF ITSELF, never the file we downloaded.
# rc 0 it ran · 3 this Mac refused to execute it (126, or a signal that was not our timeout) · 1 else.
github_cli_exec() {
  local line rc v
  line="$(github_cli_ask 60 "$1" --version)"; rc=$?
  case "$rc" in
    0) v="$(printf '%s' "$line" | /usr/bin/sed -n 's/^gh version \([0-9][0-9.]*\).*/\1/p')"
       [ -n "$v" ] || return 1
       printf '%s' "$v"; return 0 ;;
    126|129|13[0-9]|14[0-9]|15[0-9]) return 3 ;;
  esac
  return 1
}

# github_cli_signed <file> — codesign --strict clean AND signed by exactly GitHub's Team ID.
github_cli_signed() {
  local t
  "$GITHUB_CLI_CODESIGN" --verify --strict "$1" >/dev/null 2>&1 || return 1
  t="$("$GITHUB_CLI_CODESIGN" -dv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  [ "$t" = "$GITHUB_CLI_TEAM" ]
}

# github_cli_auth <bin> — signed in? gh's own answer, never a config file we might misread. On a
# GitHub Enterprise tenant only THAT host counts: being signed into github.com is not being signed
# into your company's, and `gh auth status` alone exits 0 on either.
github_cli_auth() {
  if [ -n "${GH_HOST:-}" ]; then github_cli_ask 30 "$1" auth status --hostname "$GH_HOST" >/dev/null
  else github_cli_ask 30 "$1" auth status >/dev/null; fi
}

# github_cli_ours — rc 0 iff the gh on the search path is the one THIS module linked.
github_cli_ours() {
  case "$(/usr/bin/readlink "$(github_cli_link)" 2>/dev/null)" in
    "../gh-$GITHUB_CLI_VERSION/bin/gh") [ -x "$(github_cli_link)" ] ;;
    *) return 1 ;;
  esac
}
# github_cli_bin — the gh this Mac will run: ours, else any route the library's search order knows.
github_cli_bin() {
  github_cli_ours && { github_cli_link; return 0; }
  bootstrap_find_tool gh
}

# github_cli_unreachable <url> — rc 0 iff fetching <url> fails for an ENVIRONMENT reason (DNS,
# refused, timeout, proxy 403/407, TLS); prints why. A 404 or an unreadable fixture is OUR bug, and
# says no. bootstrap_fetch_pinned answers only "not fetched"; this is what tells the two apart.
github_cli_unreachable() {
  local code rc
  code="$(/usr/bin/curl -sS -L -r 0-0 -o /dev/null --connect-timeout 10 -m 30 -w '%{http_code}' "$1" 2>/dev/null)"
  rc=$?
  case "$rc:$code" in
    0:403|0:407) printf 'the proxy refused it (HTTP %s)' "$code" ;;
    0:*|3:*|37:*) return 1 ;;
    6:*|5:*)     printf 'the name did not resolve' ;;
    7:*)         printf 'the connection was refused' ;;
    28:*)        printf 'it timed out' ;;
    35:*|51:*|58:*|60:*|77:*|83:*) printf 'its certificate is not trusted on this Mac' ;;
    *)           printf 'curl could not connect (error %s)' "$rc" ;;
  esac
}

# github_cli_gate_reason — "<kind>|<detail>" for the first thing only a person can clear, or nothing.
# gate_, note_ and gesture_ all read this, so they can never disagree.
github_cli_gate_reason() {
  local bin rc why
  if ! bin="$(github_cli_bin)"; then
    [ -f "$(github_cli_marker)" ] || return 0        # not downloaded yet: install_ has work to do
    # a marker is only as good as the network it describes: re-probe, so a fixed proxy is not a gate
    why="$(github_cli_unreachable "$(github_cli_source "$(github_cli_url)")")" || return 0
    printf 'unreachable|%s' "$why"; return 0
  fi
  github_cli_exec "$bin" >/dev/null; rc=$?
  [ "$rc" = 3 ] && { printf 'refused|%s' "$bin"; return 0; }
  [ "$rc" = 0 ] || return 0
  github_cli_auth "$bin" || printf 'login|%s' "$bin"
  return 0
}

verify_github_cli() {
  local bin
  bin="$(github_cli_bin)" || return 1
  github_cli_exec "$bin" >/dev/null || return 1
  github_cli_auth "$bin"
}

gate_github_cli() { [ -n "$(github_cli_gate_reason)" ]; }

note_github_cli() {
  local r kind detail v
  r="$(github_cli_gate_reason)"; kind="${r%%|*}"; detail="${r#*|}"
  case "$kind" in
    unreachable) printf 'the GitHub CLI was not downloaded: %s — ask IT to allow https://%s, or point BOOTSTRAP_ARTIFACT_MIRROR at a mirror holding the same file, then run this again' \
                   "$detail" "$(github_cli_host "$(github_cli_source "$(github_cli_url)")")" ;;
    refused)     printf 'the GitHub CLI is downloaded and its signature checked, but this Mac will not run it — ask IT to allow software signed by GitHub (Team ID %s)' "$GITHUB_CLI_TEAM" ;;
    login)       printf 'the GitHub CLI is installed but not signed in to %s — sign in once, in your browser' "$(github_cli_gh_host)"
                 v="$(github_cli_exec "$detail")"
                 case "$v" in "$GITHUB_CLI_VERSION") : ;;
                   *) printf ' (yours is %s, left as it is; the pin is %s)' "${v:-no version}" "$GITHUB_CLI_VERSION" ;; esac ;;
    *)           printf 'the GitHub CLI is not installed yet' ;;
  esac
}

# Only the sign-in has a command. "Ask IT" is not something a person pastes into a shell, so those
# two print nothing at all rather than a line that does not run.
gesture_github_cli() {
  local r kind bin
  r="$(github_cli_gate_reason)"; kind="${r%%|*}"; bin="${r#*|}"
  [ "$kind" = login ] || return 0
  case "$bin" in *' '*|*'"'*|*"'"*) return 0 ;; esac   # a path that would not survive being pasted
  if [ -n "${GH_HOST:-}" ]; then printf '%s auth login --hostname %s' "$(github_cli_short "$bin")" "$GH_HOST"
  else printf '%s auth login' "$(github_cli_short "$bin")"; fi
}

# github_cli_place — download, check the hash and the signer, land it. rc 0 in place · 1 not
# downloaded (a marker says why when it is the network's) · 2 refused: wrong sha256 or wrong signer,
# nothing left behind · 4 could not unpack or land it.
github_cli_place() {
  local url sha dl stage top rc why
  url="$(github_cli_url)"; sha="$(github_cli_sha)"; dl="$(github_cli_zip)"
  /bin/rm -f "$(github_cli_marker)"
  bootstrap_fetch_pinned "$url" "$sha" "$dl"; rc=$?
  if [ "$rc" = 1 ]; then
    if why="$(github_cli_unreachable "$(github_cli_source "$url")")"; then
      /bin/mkdir -p "$(github_cli_state)" && printf '%s\n' "$why" >"$(github_cli_marker)"
      bootstrap_warn "github_cli: $(github_cli_host "$(github_cli_source "$url")") unreachable ($why) — the GitHub CLI was not downloaded"
    else bootstrap_warn "github_cli: $url could not be fetched, and the network is not why"; fi
    return 1
  fi
  [ "$rc" = 0 ] || return 2
  stage="$(github_cli_dir).part"
  /bin/rm -rf "$stage"
  /bin/mkdir -p "$stage" || { /bin/rm -f "$dl"; return 4; }
  /usr/bin/unzip -qq -o "$dl" -d "$stage" >/dev/null 2>&1
  /bin/rm -f "$dl"
  top="$stage/gh_${GITHUB_CLI_VERSION}_macOS_$(github_cli_arch)"
  if [ ! -x "$top/bin/gh" ]; then
    /bin/rm -rf "$stage"; bootstrap_warn "github_cli: the release zip held no bin/gh"; return 4
  fi
  if ! github_cli_signed "$top/bin/gh"; then
    /bin/rm -rf "$stage"
    bootstrap_warn "github_cli: gh is not signed by Team ID $GITHUB_CLI_TEAM — refused"
    return 2
  fi
  /bin/rm -rf "$(github_cli_dir)"
  /bin/mv "$top" "$(github_cli_dir)" || { /bin/rm -rf "$stage"; return 4; }
  /bin/rm -rf "$stage"
  /bin/mkdir -p "$(bootstrap_tools_dir)/bin" || return 4
  /bin/ln -sfn "../gh-$GITHUB_CLI_VERSION/bin/gh" "$(github_cli_link)" || return 4
  return 0
}

install_github_cli() {
  local bin v
  if ! github_cli_ours && bin="$(bootstrap_find_tool gh)"; then
    v="$(github_cli_exec "$bin")"
    case "$v" in "$GITHUB_CLI_VERSION") : ;;
      *) bootstrap_warn "github_cli: gh is already at $(github_cli_short "$bin") (${v:-no version}); the pin is $GITHUB_CLI_VERSION — left as it is" ;;
    esac
  else
    github_cli_ours || github_cli_place || return 1
    bin="$(github_cli_link)"
    github_cli_exec "$bin" >/dev/null || return 1
  fi
  # Installed, and nobody signed in: a gate the installer has now DISCOVERED (CONTRACT.md §3).
  github_cli_auth "$bin" || return 3
  return 0
}

# Removes exactly what install_ put on this Mac. A gh that came from anywhere else is untouched, and
# so is every byte of the person's own gh — $HOME/.config/gh, the keychain item, the git credential
# helper `gh auth setup-git` wrote. Signing out is theirs, not ours.
uninstall_github_cli() {
  local link tgt dir
  link="$(github_cli_link)"
  tgt="$(/usr/bin/readlink "$link" 2>/dev/null)"
  case "$tgt" in
    ../gh-*/bin/gh)
      dir="${tgt#../}"; dir="$(bootstrap_tools_dir)/${dir%/bin/gh}"
      /bin/rm -f "$link"
      case "$dir" in "$(bootstrap_tools_dir)"/gh-*) /bin/rm -rf "$dir" ;; esac ;;
  esac
  /bin/rm -f "$(github_cli_zip)" "$(github_cli_marker)"
  /bin/rmdir "$(github_cli_state)" "$(bootstrap_tools_dir)/downloads" "$(bootstrap_tools_dir)/bin" \
             "$(bootstrap_tools_dir)" 2>/dev/null
  return 0
}

what_github_cli()    { printf '%s' 'the GitHub CLI (gh) in your home folder — no admin, no Homebrew, pinned and signature-checked — so cloning, pull requests, issues and gh api work, for you and for a coding agent'; }
cost_github_cli()    { printf '%s' '~40 MB unpacked (a 14 MB download), under a minute; one sign-in in your browser, which stores a token in your keychain'; }
profile_github_cli() { printf '%s' 'standard'; }
egress_github_cli() {
  cat <<'E'
github.com install the pinned GitHub CLI release zip (sha256 and GitHub's signature checked)
release-assets.githubusercontent.com install the zip github.com redirects to
github.com run the browser sign-in gh auth login opens, and gh's own new-release check (GH_NO_UPDATE_NOTIFIER=1 stops the check)
api.github.com run every gh command, and the token test gh auth status makes
E
  [ -n "${GH_HOST:-}" ] && printf '%s run every gh command, on the GitHub Enterprise tenant GH_HOST names\n' "$GH_HOST"
  return 0
}
clearance_github_cli() {
  printf '%s\n' "software the GitHub CLI, a vendor binary signed by GitHub (Team ID $GITHUB_CLI_TEAM) that IT did not distribute, into \$HOME/.mac-bootstrap/tools"
  printf '%s\n' "agent a coding agent can run gh on its own — reading and writing repositories, issues and pull requests on $(github_cli_gh_host) as you, with the token gh keeps in your keychain"
}
