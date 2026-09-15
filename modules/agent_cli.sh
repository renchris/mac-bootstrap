#!/bin/bash
# agent_cli — Claude Code and GitHub Copilot CLI, installed into $HOME with no admin, no Homebrew
# and no node, and one of them signed in.
#
# SOURCED, never executed. Six verbs, no top-level side effects (CONTRACT.md §1).
#
# THE END STATE, stated so verify_ can be read against it: every agent named in BOOTSTRAP_AGENTS
# (default "claude copilot"; "none" selects nothing) resolves and answers `--version` when run;
# every one this module installed is found by a fresh login zsh; and at least one selected agent
# is signed in. An agent already on the Mac, by any route (npm, Homebrew, the vendor installer),
# counts as it is and is never reinstalled, upgraded or removed.
#
# WHAT IS PINNED, measured 2026-09-15 by downloading each artifact and running it:
#   Claude Code 2.1.267 — the `stable` pointer on 2026-09-15 (it moved from 2.1.236 that same day; re-pinned
#     and re-measured: sha256 = manifest.json, Team ID Q6L2SF6YDW, `--version` offline). The native Mach-O install.sh
#     fetches, sha256 from that release's manifest.json, codesign --strict clean, Team ID Q6L2SF6YDW.
#     Laid out as `claude install` lays it out: <data>/claude/versions/<ver> + ~/.local/bin/claude.
#   Copilot CLI 1.0.83 — the release tarball gh.io/copilot-install fetches, sha256 from that
#     release's SHA256SUMS.txt; it holds one file, `copilot`, codesign clean, Team ID VEKTX9H2N7.
#
# THREE MEASURED SIDE EFFECTS this module steers around. Do not "simplify" them back:
#   · `claude auth status` CREATES $HOME/.claude.json (plus .claude/backups) on a Mac where Claude
#     has never started. So it is run only when that file already exists: no file, no sign-in.
#     It answered offline (network denied by sandbox-exec) with {"loggedIn":false,...} and rc 1.
#   · `copilot --version` unpacks 124 MB into ~/Library/Caches/copilot on its first run.
#     COPILOT_PKG_CACHE_HOME moves that; the read-only modes point it at a throwaway directory.
#   · Copilot has no status command. A sign-in is recorded as `loggedInUsers` in its config.json
#     (key names read from the 1.0.83 runtime) with the token in the keychain, or given by
#     COPILOT_GITHUB_TOKEN. Only presence is read — never a value, never `security -w` or `-g`.
#
# A download refused by a proxy, DNS or an untrusted certificate is the network's, not ours:
# NEEDS_HUMAN naming the host. So is a verified binary this Mac will not execute (Santa, binary
# authorization): "ask IT to allow" the signer. A wrong sha256 or a wrong signer is FAILED.
#
# bash 3.2 · set -u, no set -e · every verb runs in its own subshell.

AGENT_CLI_CLAUDE_VERSION='2.1.267'
AGENT_CLI_CLAUDE_SHA256_ARM64='a681f3008f0050029aeebcab3af51bb6a55ddeb625a3af3141a4416d43cd2558'
AGENT_CLI_CLAUDE_SHA256_X64='071988cb2e5a4378d8543d78e0ff5f8ed1ecc5e113271774a0582ee74fb0ef79'
AGENT_CLI_CLAUDE_TEAM='Q6L2SF6YDW'
AGENT_CLI_COPILOT_VERSION='1.0.83'
AGENT_CLI_COPILOT_SHA256_ARM64='80a5ded6f1db484b4661af676ea914605ecfbcaf49f6b4bed81e6df16cbd56bd'
AGENT_CLI_COPILOT_SHA256_X64='7e4f7236b0cd5ee474e6ab6d35ea67b8c33d5ec6483498e0fdd0218f458b2d53'
AGENT_CLI_COPILOT_TEAM='VEKTX9H2N7'
AGENT_CLI_BLOCK_BEGIN='# >>> mac-bootstrap agent_cli >>>'
AGENT_CLI_BLOCK_END='# <<< mac-bootstrap agent_cli <<<'
# Test seams: a fixture's signature and keychain cannot come from the real tools.
AGENT_CLI_CODESIGN="${BOOTSTRAP_AGENT_CLI_CODESIGN:-/usr/bin/codesign}"
AGENT_CLI_SECURITY="${BOOTSTRAP_AGENT_CLI_SECURITY:-/usr/bin/security}"

agent_cli_state()    { printf '%s/agent-cli' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
agent_cli_bindir()   { printf '%s/.local/bin' "$HOME"; }
agent_cli_versions() {
  case "${XDG_DATA_HOME:-}" in /*) printf '%s/claude/versions' "$XDG_DATA_HOME" ;;
    *) printf '%s/.local/share/claude/versions' "$HOME" ;; esac
}
agent_cli_record()   { printf '%s/%s.installed' "$(agent_cli_state)" "$1"; }
agent_cli_marker()   { printf '%s/%s.unreachable' "$(agent_cli_state)" "$1"; }
agent_cli_name()     { case "$1" in claude) printf 'Claude Code' ;; *) printf 'Copilot CLI' ;; esac; }
agent_cli_version()  { case "$1" in claude) printf '%s' "$AGENT_CLI_CLAUDE_VERSION" ;; *) printf '%s' "$AGENT_CLI_COPILOT_VERSION" ;; esac; }
agent_cli_team()     { case "$1" in claude) printf '%s' "$AGENT_CLI_CLAUDE_TEAM" ;; *) printf '%s' "$AGENT_CLI_COPILOT_TEAM" ;; esac; }
agent_cli_signer()   { case "$1" in claude) printf 'Anthropic PBC' ;; *) printf 'GitHub' ;; esac; }
agent_cli_short()    { case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# agent_cli_selected — the selected agents in canonical order; rc 1 when BOOTSTRAP_AGENTS names one
# we do not know (a typo must not quietly select nothing).
agent_cli_selected() {
  local w out=""
  for w in ${BOOTSTRAP_AGENTS-claude copilot}; do
    case "$w" in claude|copilot|none) : ;; *) return 1 ;; esac
  done
  for w in claude copilot; do
    case " ${BOOTSTRAP_AGENTS-claude copilot} " in *" $w "*) out="$out $w" ;; esac
  done
  printf '%s' "${out# }"
}

# The vendor's own rule: a shell translated by Rosetta on an Apple-silicon Mac still gets arm64.
agent_cli_arch() {
  [ "$(/usr/bin/uname -m)" = arm64 ] && { printf arm64; return; }
  [ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ] && { printf arm64; return; }
  printf x64
}
agent_cli_url() {
  local a; a="$(agent_cli_arch)"
  case "$1" in
    claude) printf '%s' "${BOOTSTRAP_AGENT_CLI_CLAUDE_URL:-https://downloads.claude.ai/claude-code-releases/$AGENT_CLI_CLAUDE_VERSION/darwin-$a/claude}" ;;
    *)      printf '%s' "${BOOTSTRAP_AGENT_CLI_COPILOT_URL:-https://github.com/github/copilot-cli/releases/download/v$AGENT_CLI_COPILOT_VERSION/copilot-darwin-$a.tar.gz}" ;;
  esac
}
agent_cli_sha() {
  local a; a="$(agent_cli_arch)"
  case "$1:$a" in
    claude:arm64)  printf '%s' "${BOOTSTRAP_AGENT_CLI_CLAUDE_SHA256:-$AGENT_CLI_CLAUDE_SHA256_ARM64}" ;;
    claude:*)      printf '%s' "${BOOTSTRAP_AGENT_CLI_CLAUDE_SHA256:-$AGENT_CLI_CLAUDE_SHA256_X64}" ;;
    copilot:arm64) printf '%s' "${BOOTSTRAP_AGENT_CLI_COPILOT_SHA256:-$AGENT_CLI_COPILOT_SHA256_ARM64}" ;;
    *)             printf '%s' "${BOOTSTRAP_AGENT_CLI_COPILOT_SHA256:-$AGENT_CLI_COPILOT_SHA256_X64}" ;;
  esac
}
agent_cli_host() { local h="${1#*://}"; h="${h%%/*}"; printf '%s' "${h:-the download URL}"; }

# agent_cli_bounded <secs> <outfile> <cmd…> — run with stdin closed and stdout to <outfile>, killed
# after <secs> (macOS has no timeout(1)); a kill leaves <outfile>.timeout. A person's slow shell rc or
# a hung network call must never wedge the bootstrap.
agent_cli_bounded() {
  local secs="$1" out="$2" pid rc; shift 2
  "$@" >"$out" 2>/dev/null </dev/null &
  pid=$!
  ( i=0; while [ "$i" -lt "$secs" ]; do /bin/sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; i=$((i + 1)); done
    : >"$out.timeout"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wait "$pid"; rc=$?
  return "$rc"
}

# agent_cli_ours <agent> — rc 0 iff this module installed the agent and its entry is still there.
agent_cli_ours() { [ -f "$(agent_cli_record "$1")" ] && [ -e "$(agent_cli_bindir)/$1" ]; }

# agent_cli_bin <agent> — the agent this Mac will run: ours, else any route the library knows, else
# the vendor's own ~/.local/bin, which a fresh shell's PATH usually lacks.
agent_cli_bin() {
  agent_cli_ours "$1" && { printf '%s/%s' "$(agent_cli_bindir)" "$1"; return 0; }
  bootstrap_find_tool "$1" && return 0
  [ -x "$(agent_cli_bindir)/$1" ] && { printf '%s/%s' "$(agent_cli_bindir)" "$1"; return 0; }
  return 1
}

# agent_cli_exec <agent> <bin> — prints the first line `--version` answers. rc 0 it ran · 3 this Mac
# refused to execute it (126, or killed by a signal that was not our timeout) · 1 anything else.
agent_cli_exec() {
  local tmp rc line cache=""
  tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-cli.XXXXXX")" || return 1
  [ "$1" = copilot ] && [ "${BOOTSTRAP_READ_ONLY:-0}" = 1 ] && cache="$tmp/cache"
  if [ -n "$cache" ]; then agent_cli_bounded 60 "$tmp/out" /usr/bin/env COPILOT_PKG_CACHE_HOME="$cache" "$2" --version
  else agent_cli_bounded 60 "$tmp/out" "$2" --version; fi
  rc=$?
  line="$(/usr/bin/head -1 "$tmp/out" 2>/dev/null)"
  [ -e "$tmp/out.timeout" ] && rc=1
  /bin/rm -rf "$tmp"
  case "$rc" in
    0) case "$line" in *[0-9]*) printf '%s' "$line"; return 0 ;; esac; return 1 ;;
    126|129|13[0-9]|14[0-9]|15[0-9]) return 3 ;;
  esac
  return 1
}

# agent_cli_signed <file> <team> — codesign --strict clean AND signed by exactly that Team ID.
agent_cli_signed() {
  local t
  "$AGENT_CLI_CODESIGN" --verify --strict "$1" >/dev/null 2>&1 || return 1
  t="$("$AGENT_CLI_CODESIGN" -dv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  [ "$t" = "$2" ]
}

# agent_cli_signed_in <agent> <bin> — read without the network and without any secret value.
agent_cli_signed_in() {
  local tmp v cfg
  if [ "$1" = claude ]; then
    cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    [ -f "$cfg" ] || return 1
    tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-cli.XXXXXX")" || return 1
    agent_cli_bounded 30 "$tmp/out" "$2" auth status --json
    v="$(/usr/bin/plutil -extract loggedIn raw -o - - <"$tmp/out" 2>/dev/null)" || v=""
    /bin/rm -rf "$tmp"
    [ "$v" = true ] && return 0
    # A claude too old to have `auth status` prints no JSON at all; its sign-in is the account record.
    [ -z "$v" ] && /usr/bin/plutil -extract oauthAccount.accountUuid raw -o /dev/null -- "$cfg" >/dev/null 2>&1
    return
  fi
  [ -n "${COPILOT_GITHUB_TOKEN:-}" ] && return 0
  cfg="${COPILOT_HOME:-$HOME/.copilot}/config.json"
  # config.json is JSONC (a `//` first line) and plutil dies on comments: strip those lines first.
  if [ -f "$cfg" ] && /usr/bin/sed '/^[[:space:]]*\/\//d' "$cfg" \
       | /usr/bin/plutil -extract loggedInUsers.0 json -o /dev/null - >/dev/null 2>&1; then return 0; fi
  "$AGENT_CLI_SECURITY" find-generic-password -s copilot-cli >/dev/null 2>&1
}

# agent_cli_zsh_finds <agent> — the read-back for PATH: a login zsh started the way a new Terminal
# window starts it (launchd's PATH, nothing inherited from this process) resolves the agent.
agent_cli_zsh_finds() {
  local tmp rc
  tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-cli.XXXXXX")" || return 1
  agent_cli_bounded 20 "$tmp/out" /usr/bin/env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
    SHELL=/bin/zsh TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -lc "command -v $1"
  rc=$?
  [ -s "$tmp/out" ] && [ ! -e "$tmp/out.timeout" ] || rc=1
  /bin/rm -rf "$tmp"
  return "$rc"
}

# agent_cli_source <url> — where bootstrap_fetch_pinned tries first: IT's BOOTSTRAP_ARTIFACT_MIRROR
# when one is set (the library's own rule), else the vendor.
agent_cli_source() {
  if [ -n "${BOOTSTRAP_ARTIFACT_MIRROR:-}" ]; then printf '%s/%s' "${BOOTSTRAP_ARTIFACT_MIRROR%/}" "${1#*://}"
  else printf '%s' "$1"; fi
}

# agent_cli_unreachable <url> — rc 0 iff fetching <url> fails for an ENVIRONMENT reason (DNS, refused,
# timeout, proxy 403/407, TLS); prints why. A 404 or an unreadable fixture is ours, and says no.
# bootstrap_fetch_pinned answers only "not fetched" (rc 1); this is what tells the two apart.
agent_cli_unreachable() {
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

# agent_cli_gate_reason — "<kind>|<agent>|<detail>" for the first thing only a person can clear, or
# nothing. gate_, note_ and gesture_ all read this, so they can never disagree.
agent_cli_gate_reason() {
  local sel a bin why rc any=0 first=""
  sel="$(agent_cli_selected)" || return 0
  for a in $sel; do
    [ -f "$(agent_cli_marker "$a")" ] || continue
    agent_cli_bin "$a" >/dev/null && continue
    # a marker is only as good as the network it describes: re-probe, so a fixed proxy is not a gate
    why="$(agent_cli_unreachable "$(agent_cli_source "$(agent_cli_url "$a")")")" || continue
    printf 'unreachable|%s|%s' "$a" "$why"; return 0
  done
  for a in $sel; do
    bin="$(agent_cli_bin "$a")" || return 0          # not installed yet: install_ has work to do
    agent_cli_exec "$a" "$bin" >/dev/null; rc=$?
    [ "$rc" = 3 ] && { printf 'refused|%s|%s' "$a" "$bin"; return 0; }
    [ "$rc" = 0 ] || return 0
  done
  for a in $sel; do
    [ -n "$first" ] || first="$a"
    agent_cli_signed_in "$a" "$(agent_cli_bin "$a")" && any=1
  done
  [ -n "$first" ] && [ "$any" = 0 ] && printf 'login|%s|%s' "$first" "$(agent_cli_bin "$first")"
  return 0
}

# agent_cli_mkdirs <dir> <record> — mkdir -p, recording each level it creates so uninstall_ removes
# exactly those (and only while they are empty).
agent_cli_mkdirs() {
  local d="$1" missing=""
  while [ -n "$d" ] && [ "$d" != / ] && [ ! -d "$d" ]; do missing="$d
$missing"; d="$(/usr/bin/dirname "$d")"; done
  /bin/mkdir -p "$1" 2>/dev/null || return 1
  printf '%s\n' "$missing" | while IFS= read -r d; do [ -n "$d" ] && printf 'dir\t%s\n' "$d" >>"$2"; done
  return 0
}

# agent_cli_place <agent> — download, verify the hash and the signer, land it. rc 0 in place ·
# 1 not downloaded (a network marker says why when it is the network's) · 2 refused: wrong sha256
# or wrong signer, nothing left behind · 4 could not unpack or land it.
agent_cli_place() {
  local a="$1" url sha dl stage rec rc why bindir
  url="$(agent_cli_url "$a")"; sha="$(agent_cli_sha "$a")"; bindir="$(agent_cli_bindir)"
  rec="$(agent_cli_record "$a")"; dl="$(bootstrap_tools_dir)/downloads/$a-$(agent_cli_version "$a")"
  /bin/rm -f "$(agent_cli_marker "$a")"
  bootstrap_fetch_pinned "$url" "$sha" "$dl"; rc=$?
  if [ "$rc" = 1 ]; then
    if why="$(agent_cli_unreachable "$(agent_cli_source "$url")")"; then
      /bin/mkdir -p "$(agent_cli_state)" && printf '%s\n' "$why" >"$(agent_cli_marker "$a")"
      bootstrap_warn "agent_cli: $(agent_cli_host "$(agent_cli_source "$url")") unreachable ($why) — $(agent_cli_name "$a") not downloaded"
    else bootstrap_warn "agent_cli: $url could not be fetched, and the network is not why"; fi
    return 1
  fi
  [ "$rc" = 0 ] || return 2
  if [ "$a" = copilot ]; then
    stage="$(/usr/bin/mktemp -d "$(bootstrap_tools_dir)/downloads/copilot.XXXXXX")" || { /bin/rm -f "$dl"; return 4; }
    /usr/bin/tar -xzf "$dl" -C "$stage" copilot 2>/dev/null; /bin/rm -f "$dl"
    [ -f "$stage/copilot" ] || { /bin/rm -rf "$stage"; bootstrap_warn "agent_cli: the Copilot tarball held no copilot"; return 4; }
    /bin/mv "$stage/copilot" "$dl"; /bin/rm -rf "$stage"
  fi
  /bin/chmod 755 "$dl"
  if ! agent_cli_signed "$dl" "$(agent_cli_team "$a")"; then
    /bin/rm -f "$dl"
    bootstrap_warn "agent_cli: $(agent_cli_name "$a") is not signed by Team ID $(agent_cli_team "$a") — refused"
    return 2
  fi
  /bin/mkdir -p "$(agent_cli_state)" || { /bin/rm -f "$dl"; return 4; }
  : >"$rec"
  agent_cli_mkdirs "$bindir" "$rec" || { /bin/rm -f "$dl"; return 4; }
  sha="$(/usr/bin/shasum -a 256 "$dl" | /usr/bin/cut -d' ' -f1)"
  if [ "$a" = claude ]; then
    agent_cli_mkdirs "$(agent_cli_versions)" "$rec" || { /bin/rm -f "$dl"; return 4; }
    /bin/mv -f "$dl" "$(agent_cli_versions)/$AGENT_CLI_CLAUDE_VERSION" || return 4
    /bin/ln -sfn "$(agent_cli_versions)/$AGENT_CLI_CLAUDE_VERSION" "$bindir/claude" || return 4
    printf 'file\t%s\t%s\nlink\t%s\t%s\n' "$(agent_cli_versions)/$AGENT_CLI_CLAUDE_VERSION" "$sha" \
      "$bindir/claude" "$(agent_cli_versions)/$AGENT_CLI_CLAUDE_VERSION" >>"$rec"
  else
    /bin/mv -f "$dl" "$bindir/copilot" || return 4
    printf 'file\t%s\t%s\ncache\t%s\n' "$bindir/copilot" "$sha" \
      "$HOME/Library/Caches/copilot/pkg/darwin-$(agent_cli_arch)/$AGENT_CLI_COPILOT_VERSION" >>"$rec"
  fi
  return 0
}

# agent_cli_path_block — a marked block in ~/.zprofile, ONLY when a new login zsh would not find an
# agent this module put in ~/.local/bin. No repo precedent writes a shell rc; this is the one.
agent_cli_path_block() {
  local f="$HOME/.zprofile" a need=0 how=appended
  for a in claude copilot; do
    agent_cli_ours "$a" || continue
    agent_cli_zsh_finds "$a" || need=1
  done
  [ "$need" = 1 ] || return 0
  [ -f "$f" ] && /usr/bin/grep -qxF "$AGENT_CLI_BLOCK_BEGIN" "$f" && return 0
  if [ ! -e "$f" ]; then how=created
  elif [ -s "$f" ] && [ -n "$(/usr/bin/tail -c 1 "$f")" ]; then how=appended-newline; printf '\n' >>"$f"; fi
  printf '%s\n%s\n%s\n' "$AGENT_CLI_BLOCK_BEGIN" 'export PATH="$HOME/.local/bin:$PATH"   # Claude Code, Copilot CLI' \
    "$AGENT_CLI_BLOCK_END" >>"$f" || return 1
  printf '%s\n' "$how" >"$(agent_cli_state)/zprofile.written"
}

verify_agent_cli() {
  local sel a bin any=0
  sel="$(agent_cli_selected)" || return 1
  [ -n "$sel" ] || return 0
  for a in $sel; do
    bin="$(agent_cli_bin "$a")" || return 1
    agent_cli_exec "$a" "$bin" >/dev/null || return 1
    if agent_cli_ours "$a"; then agent_cli_zsh_finds "$a" || return 1; fi
  done
  for a in $sel; do agent_cli_signed_in "$a" "$(agent_cli_bin "$a")" && any=1; done
  [ "$any" = 1 ]
}

gate_agent_cli() { [ -n "$(agent_cli_gate_reason)" ]; }

note_agent_cli() {
  local r kind a detail v
  r="$(agent_cli_gate_reason)"; kind="${r%%|*}"; a="${r#*|}"; detail="${a#*|}"; a="${a%%|*}"
  case "$kind" in
    unreachable) printf '%s was not downloaded: %s — ask IT to allow https://%s, then run this again' \
                   "$(agent_cli_name "$a")" "$detail" "$(agent_cli_host "$(agent_cli_source "$(agent_cli_url "$a")")")" ;;
    refused)     printf '%s is downloaded and verified, but this Mac will not run it — ask IT to allow software signed by %s (Team ID %s)' \
                   "$(agent_cli_name "$a")" "$(agent_cli_signer "$a")" "$(agent_cli_team "$a")" ;;
    login)       printf 'no coding agent is signed in yet — sign in to %s once, in your browser' "$(agent_cli_name "$a")"
                 v="$(agent_cli_exec "$a" "$detail")"
                 case "$v" in *"$(agent_cli_version "$a")"*) : ;;
                   *) printf ' (yours is %s, left as it is; the pin is %s)' "$v" "$(agent_cli_version "$a")" ;; esac ;;
    *) if ! v="$(agent_cli_selected)"; then
         printf "BOOTSTRAP_AGENTS='%s' names an agent this module does not know — use claude, copilot or none" "${BOOTSTRAP_AGENTS:-}"
       elif [ -z "$v" ]; then printf 'no coding agent selected (BOOTSTRAP_AGENTS=none), so nothing to install'
       else printf 'the coding agents are not installed yet'; fi ;;
  esac
}

gesture_agent_cli() {
  local r kind a bin
  r="$(agent_cli_gate_reason)"; kind="${r%%|*}"; a="${r#*|}"; bin="${a#*|}"; a="${a%%|*}"
  [ "$kind" = login ] || return 0
  case "$bin" in *' '*|*'"'*|*"'"*) return 0 ;; esac   # a path that would not survive being pasted
  case "$a" in claude) printf '%s auth login' "$(agent_cli_short "$bin")" ;; *) printf '%s login' "$(agent_cli_short "$bin")" ;; esac
}

install_agent_cli() {
  local sel a bin v failed=0 any=0
  sel="$(agent_cli_selected)" || { bootstrap_warn "agent_cli: BOOTSTRAP_AGENTS='${BOOTSTRAP_AGENTS:-}' names an agent other than claude, copilot or none"; return 1; }
  for a in $sel; do
    if ! agent_cli_ours "$a" && bin="$(agent_cli_bin "$a")"; then
      v="$(agent_cli_exec "$a" "$bin")"
      case "$v" in *"$(agent_cli_version "$a")"*) : ;;
        *) bootstrap_warn "agent_cli: $(agent_cli_name "$a") is already at $(agent_cli_short "$bin") (${v:-no version}); the pin is $(agent_cli_version "$a") — left as it is" ;; esac
      continue
    fi
    agent_cli_ours "$a" || agent_cli_place "$a" || { failed=1; continue; }
    agent_cli_exec "$a" "$(agent_cli_bindir)/$a" >/dev/null || failed=1
  done
  agent_cli_path_block || { bootstrap_warn "agent_cli: could not add \$HOME/.local/bin to $HOME/.zprofile"; failed=1; }
  [ "$failed" = 0 ] || return 1
  for a in $sel; do agent_cli_signed_in "$a" "$(agent_cli_bin "$a")" && any=1; done
  # Installed, and nobody signed in: a gate the installer has now DISCOVERED. Non-zero makes the
  # driver ask gate_ again, which reports the login.
  [ -z "$sel" ] || [ "$any" = 1 ] || return 3
  return 0
}

uninstall_agent_cli() {
  local a rec kind p x how f="$HOME/.zprofile" tmp
  for a in claude copilot; do
    rec="$(agent_cli_record "$a")"
    [ -f "$rec" ] || continue
    while IFS="$(printf '\t')" read -r kind p x; do
      case "$kind" in
        file)  [ -f "$p" ] && [ "$(/usr/bin/shasum -a 256 "$p" | /usr/bin/cut -d' ' -f1)" = "$x" ] && /bin/rm -f "$p" ;;
        link)  [ -L "$p" ] && [ "$(/usr/bin/readlink "$p")" = "$x" ] && /bin/rm -f "$p" ;;
        cache) /bin/rm -rf "$p" ;;
      esac
    done <"$rec"
    /usr/bin/sed -n 's/^dir	//p' "$rec" | /usr/bin/tail -r | while IFS= read -r p; do /bin/rmdir "$p" 2>/dev/null; done
    /bin/rm -f "$rec" "$(agent_cli_marker "$a")"
  done
  if [ -f "$(agent_cli_state)/zprofile.written" ] && [ -f "$f" ]; then
    how="$(/bin/cat "$(agent_cli_state)/zprofile.written")"
    tmp="$f.mac-bootstrap.$$"
    /usr/bin/awk -v b="$AGENT_CLI_BLOCK_BEGIN" -v e="$AGENT_CLI_BLOCK_END" \
      '$0==b{skip=1;next} skip&&$0==e{skip=0;next} !skip' "$f" >"$tmp" || { /bin/rm -f "$tmp"; return 1; }
    [ "$how" = appended-newline ] && { printf '%s' "$(/bin/cat "$tmp")" >"$tmp.2"; /bin/mv -f "$tmp.2" "$tmp"; }
    if [ "$how" = created ] && [ ! -s "$tmp" ]; then /bin/rm -f "$tmp" "$f"; else /bin/mv -f "$tmp" "$f"; fi
  fi
  /bin/rm -f "$(agent_cli_marker claude)" "$(agent_cli_marker copilot)" "$(agent_cli_state)/zprofile.written"
  /bin/rmdir "$(agent_cli_state)" 2>/dev/null
  return 0
}

what_agent_cli()    { printf '%s' 'Claude Code and GitHub Copilot CLI in your home folder — no admin, no Homebrew, pinned and signature-checked'; }
cost_agent_cli()    { printf '%s' '~320 MB for Claude Code, ~270 MB for Copilot CLI (146 MB + 124 MB it unpacks on first run), a few minutes of download; one sign-in per agent in your browser'; }
profile_agent_cli() { printf '%s' 'lite'; }
# The agents' own providers are declared once by the driver; these are the install hosts and the
# hosts each agent's own self-updater contacts at run time.
egress_agent_cli() {
  local sel; sel="$(agent_cli_selected)" || sel="claude copilot"
  case " $sel " in *" claude "*) cat <<'E'
downloads.claude.ai install the pinned Claude Code binary (sha256 and Anthropic's signature checked)
downloads.claude.ai run Claude Code's own auto-updater and version check (DISABLE_AUTOUPDATER=1 stops the background half)
E
  esac
  case " $sel " in *" copilot "*) cat <<'E'
github.com install the pinned Copilot CLI tarball (sha256 and GitHub's signature checked)
release-assets.githubusercontent.com install the Copilot CLI tarball github.com redirects to
api.github.com run Copilot CLI's own auto-update check (autoUpdate false or COPILOT_AUTO_UPDATE=false stops it)
github.com run Copilot CLI's own auto-update download, same switch
release-assets.githubusercontent.com run the update tarball github.com redirects to, same switch
E
  esac
}
clearance_agent_cli() {
  local sel; sel="$(agent_cli_selected)" || sel="claude copilot"
  case " $sel " in *" claude "*) printf '%s\n' "software Claude Code, a vendor binary signed by Anthropic PBC (Team ID $AGENT_CLI_CLAUDE_TEAM) that IT did not distribute, into \$HOME/.local — and it auto-updates itself" ;; esac
  case " $sel " in *" copilot "*) printf '%s\n' "software GitHub Copilot CLI, a vendor binary signed by GitHub (Team ID $AGENT_CLI_COPILOT_TEAM) that IT did not distribute, into \$HOME/.local/bin — and it auto-updates itself" ;; esac
}
