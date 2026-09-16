#!/bin/bash
# extra_agents — the two OTHER coding-agent CLIs this Mac runs: OpenAI's Codex CLI and Google's
# Gemini CLI, installed into $HOME with no admin, no Homebrew and no global npm.
#
# SOURCED, never executed. Six verbs, no top-level side effects (CONTRACT.md §1).
#
# WHY IT IS OPT-IN (`profile_ full`): this repo's contract is Claude Code and Copilot CLI. These two
# are extra, and each is a SEPARATE model provider — a company may sanction one and refuse another,
# so clearance_ names them one per line and egress_ says where each sends your work.
#
# THE END STATE, stated so verify_ can be read against it: every CLI named in BOOTSTRAP_EXTRA_AGENTS
# (default "codex gemini"; "none" selects nothing) resolves, ANSWERS `--version` when run, and is
# signed in. A CLI already on this Mac by any route counts as it is and is never reinstalled,
# upgraded or removed. The two are INDEPENDENT: one blocked, absent or unsigned-in never stops the
# other — extra_agents_states reports a line per CLI and every verb reads that one answer.
#
# WHAT IS PINNED, measured 2026-09-15 by downloading each artifact and running it:
#   Codex CLI 0.154.0 — the release tarball from openai/codex `rust-v0.154.0`, sha256 of the bytes
#     GitHub served; it holds ONE file, named for the target (codex-aarch64-apple-darwin),
#     `codesign --verify --strict` clean, Team ID 2DC432GLL2, and answers `codex-cli 0.154.0`.
#   Gemini CLI 0.60.0 — @google/gemini-cli's own npm tarball, sha256 of the bytes registry.npmjs.org
#     served. The package declares ZERO dependencies (its `bundle/` is pre-bundled), so it is fetched
#     as one pinned artifact and unpacked — never `npm install`, which would resolve a tree no hash
#     of ours covers. Run by node, it answers `0.60.0`.
#
# WHY GEMINI IS NOT A BINARY, measured the same day, because it looks like an obvious simplification:
# google-gemini/gemini-cli v0.60.0 does ship gemini-darwin-arm64-unsigned.zip, and the name is
# literal — `codesign -dv` says "code object is not signed at all", and running it on Apple silicon
# exits 137, SIGKILL from the kernel. An unsigned Mach-O is not installable here at any hash. The npm
# bundle under a signed node is the only route that runs, and it is the one IT can reason about.
#
# THE NODE IS REUSED, NOT DUPLICATED: modules/microsoft365.sh fetches the same pinned nodejs.org LTS
# and links it at $(bootstrap_tools_dir)/bin/node, which bootstrap_find_tool looks in first. When that
# node — or any node >= 20 this Mac already has, outside $HOME — is there, this module fetches
# nothing; otherwise it fetches that same pinned build into its OWN prefix. The constants below are
# microsoft365's, deliberately identical: two modules fetching the same bytes to the same layout is
# idempotent, two modules fetching different nodes is not.
#
# A download refused by a proxy, DNS or an untrusted certificate is the network's, not ours:
# NEEDS_HUMAN naming the host. So is a verified binary this Mac will not execute (Santa, binary
# authorization). A wrong sha256 or a wrong signer is FAILED, and nothing is left behind.
#
# CREDENTIALS ARE NEVER READ: sign-in is the PRESENCE of the vendor's own credential file, or an
# exported key being non-empty. No value is read, copied or logged, and no login is ever run — that
# is the human's gesture, one per CLI.
#
# bash 3.2 · set -u, no set -e · every verb runs in its own subshell.

EXTRA_AGENTS_CODEX_VERSION='0.154.0'
EXTRA_AGENTS_CODEX_SHA256_ARM64='344310a0a591c1b192e04feff304321a69907c9498baaac331ca7e16ebcef9d7'
EXTRA_AGENTS_CODEX_SHA256_X64='1219c837d8f813b493a424c125c0038b5d9ca16279bc6d3fe6ce037a3e18a6e7'
EXTRA_AGENTS_CODEX_TEAM='2DC432GLL2'
EXTRA_AGENTS_GEMINI_VERSION='0.60.0'
EXTRA_AGENTS_GEMINI_SHA256='cecb24eabf2eb23f0f49bf131cddd640e65017336b6298da9297bdf9d213cc0b'
# microsoft365.sh's pin, kept identical on purpose (see the header).
EXTRA_AGENTS_NODE_VERSION='24.21.0'
EXTRA_AGENTS_NODE_SHA256_ARM64='6239d4cf92d864487ec8cd3615038f7b67e7f58b77b21cd2f09ea9fbd68065fe'
EXTRA_AGENTS_NODE_SHA256_X64='0ae5a24c24bb7d015cd816c5036b3f90f2945aa872fcf54e58da054753b3a299'
EXTRA_AGENTS_NODE_FLOOR=20
# Test seams: a fixture's signature cannot come from the real tool, and a suite must download nothing.
EXTRA_AGENTS_CODESIGN="${BOOTSTRAP_EXTRA_AGENTS_CODESIGN:-/usr/bin/codesign}"

extra_agents_state()  { printf '%s/extra-agents' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
extra_agents_prefix() { printf '%s/extra-agents' "$(bootstrap_tools_dir)"; }
extra_agents_bindir() { printf '%s/bin' "$(bootstrap_tools_dir)"; }
extra_agents_record() { printf '%s/%s.installed' "$(extra_agents_state)" "$1"; }
extra_agents_marker() { printf '%s/%s.unreachable' "$(extra_agents_state)" "$1"; }
extra_agents_name()   { case "$1" in codex) printf 'Codex CLI' ;; *) printf 'Gemini CLI' ;; esac; }
extra_agents_vendor() { case "$1" in codex) printf 'OpenAI' ;; *) printf 'Google' ;; esac; }
extra_agents_version(){ case "$1" in codex) printf '%s' "$EXTRA_AGENTS_CODEX_VERSION" ;; *) printf '%s' "$EXTRA_AGENTS_GEMINI_VERSION" ;; esac; }
extra_agents_short()  { case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# extra_agents_selected — the selected CLIs in canonical order; rc 1 when BOOTSTRAP_EXTRA_AGENTS names
# one we do not know (a typo must not quietly select nothing).
extra_agents_selected() {
  local w out=""
  for w in ${BOOTSTRAP_EXTRA_AGENTS-codex gemini}; do
    case "$w" in codex|gemini|none) : ;; *) return 1 ;; esac
  done
  for w in codex gemini; do
    case " ${BOOTSTRAP_EXTRA_AGENTS-codex gemini} " in *" $w "*) out="$out $w" ;; esac
  done
  printf '%s' "${out# }"
}

# The vendor's own rule: a shell translated by Rosetta on an Apple-silicon Mac still gets arm64.
extra_agents_arm64() {
  [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]
}
extra_agents_codex_target() { extra_agents_arm64 && printf 'aarch64-apple-darwin' || printf 'x86_64-apple-darwin'; }
extra_agents_node_arch()    { extra_agents_arm64 && printf 'arm64' || printf 'x64'; }

extra_agents_url() {
  case "$1" in
    codex)  printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_CODEX_URL:-https://github.com/openai/codex/releases/download/rust-v$EXTRA_AGENTS_CODEX_VERSION/codex-$(extra_agents_codex_target).tar.gz}" ;;
    gemini) printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_GEMINI_URL:-https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-$EXTRA_AGENTS_GEMINI_VERSION.tgz}" ;;
    *)      printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_NODE_URL:-https://nodejs.org/dist/v$EXTRA_AGENTS_NODE_VERSION/node-v$EXTRA_AGENTS_NODE_VERSION-darwin-$(extra_agents_node_arch).tar.xz}" ;;
  esac
}
extra_agents_sha() {
  case "$1" in
    codex)  if extra_agents_arm64; then printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_CODEX_SHA256:-$EXTRA_AGENTS_CODEX_SHA256_ARM64}"
            else printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_CODEX_SHA256:-$EXTRA_AGENTS_CODEX_SHA256_X64}"; fi ;;
    gemini) printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_GEMINI_SHA256:-$EXTRA_AGENTS_GEMINI_SHA256}" ;;
    *)      if extra_agents_arm64; then printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_NODE_SHA256:-$EXTRA_AGENTS_NODE_SHA256_ARM64}"
            else printf '%s' "${BOOTSTRAP_EXTRA_AGENTS_NODE_SHA256:-$EXTRA_AGENTS_NODE_SHA256_X64}"; fi ;;
  esac
}
# Where bootstrap_fetch_pinned tries first: IT's mirror when one is set, else the vendor.
extra_agents_source() {
  if [ -n "${BOOTSTRAP_ARTIFACT_MIRROR:-}" ]; then printf '%s/%s' "${BOOTSTRAP_ARTIFACT_MIRROR%/}" "${1#*://}"
  else printf '%s' "$1"; fi
}
extra_agents_host() { local h="${1#*://}"; h="${h%%/*}"; printf '%s' "${h:-the download URL}"; }

# extra_agents_unreachable <url> — rc 0 iff fetching <url> fails for an ENVIRONMENT reason (DNS,
# refused, timeout, proxy 403/407, TLS); prints why. A 404 or an unreadable fixture is ours, and says
# no. bootstrap_fetch_pinned answers only "not fetched"; this is what tells the two apart.
extra_agents_unreachable() {
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

# extra_agents_bounded <secs> <outfile> <cmd…> — run with stdin closed and stdout to <outfile>, killed
# after <secs> (macOS has no timeout(1)); a kill leaves <outfile>.timeout. A hung network call inside a
# CLI's own startup must never wedge the bootstrap.
extra_agents_bounded() {
  local secs="$1" out="$2" pid rc; shift 2
  "$@" >"$out" 2>/dev/null </dev/null &
  pid=$!
  ( i=0; while [ "$i" -lt "$secs" ]; do /bin/sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; i=$((i + 1)); done
    : >"$out.timeout"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wait "$pid"; rc=$?
  return "$rc"
}

# ── node, for Gemini's bundle ────────────────────────────────────────────────────────────────
# A path that survives a node upgrade: fnm's per-shell fnm_multishells path disappears with the shell
# and would take the launcher with it, silently.
extra_agents_node_ok() {
  local c="$1" major
  [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ] || return 1
  case "$c" in */fnm_multishells/*) return 1 ;; esac
  major="$("$c" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge "$EXTRA_AGENTS_NODE_FLOOR" ]
}
extra_agents_node_home() { printf '%s/node-v%s-darwin-%s' "$(extra_agents_prefix)" "$EXTRA_AGENTS_NODE_VERSION" "$(extra_agents_node_arch)"; }
# The node this module runs Gemini with, or rc 1. microsoft365's pinned copy first (bootstrap_find_tool
# looks in tools/bin), then ours, then the fixed list — the library's search stops at its first hit, and
# a first hit below the floor must not hide a usable node behind it.
extra_agents_node() {
  local c
  for c in "${BOOTSTRAP_EXTRA_AGENTS_NODE:-}" "$(bootstrap_find_tool node 2>/dev/null)" \
           "$(extra_agents_node_home)/bin/node" /opt/homebrew/bin/node /usr/local/bin/node \
           "$HOME/Library/Application Support/fnm/aliases/default/bin/node" "$(command -v node 2>/dev/null)"; do
    extra_agents_node_ok "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}
# Fetch the pinned node into THIS module's prefix. Verified by EXECUTING it, never by tar's rc.
extra_agents_node_fetch() {
  local home arch tarball stage rc rec="$1"
  arch="$(extra_agents_node_arch)"; home="$(extra_agents_node_home)"
  tarball="$(extra_agents_prefix)/.node-$arch.tar.xz"
  /bin/mkdir -p "$(extra_agents_prefix)" 2>/dev/null || return 1
  bootstrap_fetch_pinned "$(extra_agents_url node)" "$(extra_agents_sha node)" "$tarball"; rc=$?
  [ "$rc" = 0 ] || { /bin/rm -f "$tarball"; return "$rc"; }
  stage="$(extra_agents_prefix)/.node-stage.$$"
  /bin/rm -rf "$stage"; /bin/mkdir -p "$stage" 2>/dev/null || { /bin/rm -f "$tarball"; return 4; }
  /usr/bin/tar -xf "$tarball" -C "$stage" 2>/dev/null; /bin/rm -f "$tarball"
  if [ "$("$stage/${home##*/}/bin/node" --version 2>/dev/null)" != "v$EXTRA_AGENTS_NODE_VERSION" ]; then
    /bin/rm -rf "$stage"; bootstrap_warn "extra_agents: the node $EXTRA_AGENTS_NODE_VERSION archive unpacked, but its node does not run"; return 4
  fi
  /bin/rm -rf "$home"; /bin/mv -f "$stage/${home##*/}" "$home" 2>/dev/null || { /bin/rm -rf "$stage"; return 4; }
  /bin/rm -rf "$stage"
  printf 'tree\t%s\n' "$home" >>"$rec"
  return 0
}

# extra_agents_node_ref <node> — how the launcher may NAME that node: relative to the launcher's own
# directory when the node is one of ours, an absolute path when it is outside $HOME, and rc 1 when it
# is neither. A node under $HOME that this module did not place cannot go into a file without a user
# name in it (house rule 9) — and a launcher that spelt it "$HOME/..." would break for any caller with
# a different HOME, which is exactly what the version probe below is.
extra_agents_node_ref() {
  case "$1" in
    "$(extra_agents_bindir)/node") printf '"$d/node"' ;;
    "$(extra_agents_prefix)"/*)    printf '"$d/../extra-agents/%s"' "${1#"$(extra_agents_prefix)"/}" ;;
    "$HOME"/*)                     return 1 ;;
    *)                             printf '"%s"' "$1" ;;
  esac
}

# ── what is installed, and what it answers ───────────────────────────────────────────────────
extra_agents_ours() { [ -f "$(extra_agents_record "$1")" ] && [ -e "$(extra_agents_bindir)/$1" ]; }
# The CLI this Mac will run: ours, else any route the library knows (an existing install is used as
# it is, and nothing is installed over it).
extra_agents_bin() {
  extra_agents_ours "$1" && { printf '%s/%s' "$(extra_agents_bindir)" "$1"; return 0; }
  bootstrap_find_tool "$1" && return 0
  return 1
}
# extra_agents_exec <bin> — prints the first line `--version` answers. rc 0 it ran and named a version ·
# 3 this Mac REFUSED to execute it (126, or a signal that was not our timeout — Santa kills at 137) ·
# 1 anything else. The binary is executed; the downloaded file is never parsed for a version.
#
# It is run under a THROWAWAY HOME, in every mode, because asking one of these its version is not a
# free read: measured 2026-09-15, `gemini --version` alone creates $HOME/.gemini with projects.json
# and a history and tmp directory named for the current working directory, and codex leaves lock
# directories under $HOME/.codex/tmp. A looking mode (--list, --plan, --egress) must write nothing at
# all, and no mode should make a CLI's config appear because the bootstrap glanced at it. CODEX_HOME
# is set with it, since that is the one $HOME path codex resolves before it reads $HOME.
extra_agents_exec() {
  local tmp rc line
  tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/extra-agents.XXXXXX")" || return 1
  /bin/mkdir -p "$tmp/home" 2>/dev/null
  extra_agents_bounded 90 "$tmp/out" /usr/bin/env HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" "$1" --version
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
# codesign --strict clean AND signed by exactly that Team ID.
extra_agents_signed() {
  local t
  "$EXTRA_AGENTS_CODESIGN" --verify --strict "$1" >/dev/null 2>&1 || return 1
  t="$("$EXTRA_AGENTS_CODESIGN" -dv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  [ "$t" = "$2" ]
}
# PRESENCE of the vendor's own credential, or an exported key that is not empty. No value is read.
extra_agents_signed_in() {
  case "$1" in
    codex)  [ -n "${OPENAI_API_KEY:-}" ] && return 0
            [ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ] ;;
    *)      [ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}${GOOGLE_GENAI_USE_VERTEXAI:-}" ] && return 0
            [ -f "$HOME/.gemini/oauth_creds.json" ] ;;
  esac
}

# extra_agents_states — ONE line per selected CLI, "<cli> <state> [detail]", and the single answer every
# verb reads, so verify_, gate_, note_ and gesture_ can never disagree. States, worst first:
#   unreachable <why>  a host this run needs is blocked (re-probed, so a fixed proxy is not a gate)
#   refused <bin>      downloaded and verified, and this Mac will not execute it
#   no-node <why>      Gemini's bundle has no node to run it, and the network is why
#   absent             not installed yet, and nothing is stopping the installer
#   login <bin>        it runs, and nobody has signed in
#   ready <version>    it runs and is signed in
extra_agents_states() {
  local sel a bin rc v
  sel="$(extra_agents_selected)" || return 1
  for a in $sel; do
    if [ -f "$(extra_agents_marker "$a")" ] && ! extra_agents_bin "$a" >/dev/null 2>&1; then
      if v="$(extra_agents_unreachable "$(extra_agents_source "$(extra_agents_url "$a")")")"; then
        printf '%s unreachable %s\n' "$a" "$v"; continue
      fi
    fi
    if ! bin="$(extra_agents_bin "$a")"; then
      if [ "$a" = gemini ] && ! extra_agents_node >/dev/null 2>&1 \
         && v="$(extra_agents_unreachable "$(extra_agents_source "$(extra_agents_url node)")")"; then
        printf 'gemini no-node %s\n' "$v"; continue
      fi
      printf '%s absent\n' "$a"; continue
    fi
    v="$(extra_agents_exec "$bin")"; rc=$?
    [ "$rc" = 3 ] && { printf '%s refused %s\n' "$a" "$bin"; continue; }
    [ "$rc" = 0 ] || { printf '%s absent\n' "$a"; continue; }
    if extra_agents_signed_in "$a"; then printf '%s ready %s\n' "$a" "$v"; else printf '%s login %s\n' "$a" "$bin"; fi
  done
  return 0
}
# The first line that is not `ready` or `absent`, worst-first across both CLIs — the ONE thing a
# person is asked for at a time.
extra_agents_first_gate() {
  extra_agents_states 2>/dev/null | LC_ALL=C /usr/bin/awk '
    { r = ($2 == "unreachable") ? 1 : ($2 == "refused") ? 2 : ($2 == "no-node") ? 3 : ($2 == "login") ? 4 : 0 }
    r && (!best || r < best) { best = r; line = $0 }
    END { if (best) print line }'
}

# ── install ──────────────────────────────────────────────────────────────────────────────────
# extra_agents_place <cli> — download, verify the hash (and, for Codex, the signer), land it. rc 0 in
# place · 1 not downloaded (a marker says why when it is the network's) · 2 refused: a wrong sha256 or
# a wrong signer, nothing left behind · 4 could not unpack or land it.
extra_agents_place() {
  local a="$1" url sha dl rec dir bin rc why node ref="" member
  url="$(extra_agents_url "$a")"; sha="$(extra_agents_sha "$a")"; rec="$(extra_agents_record "$a")"
  bin="$(extra_agents_bindir)/$a"; dl="$(extra_agents_prefix)/.$a-download"
  /bin/rm -f "$(extra_agents_marker "$a")"
  /bin/mkdir -p "$(extra_agents_state)" "$(extra_agents_prefix)" "$(extra_agents_bindir)" 2>/dev/null || return 4
  bootstrap_fetch_pinned "$url" "$sha" "$dl"; rc=$?
  if [ "$rc" = 1 ]; then
    if why="$(extra_agents_unreachable "$(extra_agents_source "$url")")"; then
      printf '%s\n' "$why" >"$(extra_agents_marker "$a")"
      bootstrap_warn "extra_agents: $(extra_agents_host "$(extra_agents_source "$url")") unreachable ($why) — $(extra_agents_name "$a") not downloaded"
    else bootstrap_warn "extra_agents: $url could not be fetched, and the network is not why"; fi
    return 1
  fi
  [ "$rc" = 0 ] || { /bin/rm -f "$dl"; return 2; }
  : >"$rec"
  if [ "$a" = codex ]; then
    dir="$(extra_agents_prefix)/codex-$EXTRA_AGENTS_CODEX_VERSION"; member="codex-$(extra_agents_codex_target)"
    /bin/rm -rf "$dir"; /bin/mkdir -p "$dir" 2>/dev/null || { /bin/rm -f "$dl"; return 4; }
    /usr/bin/tar -xzf "$dl" -C "$dir" "$member" 2>/dev/null; /bin/rm -f "$dl"
    [ -f "$dir/$member" ] || { /bin/rm -rf "$dir"; bootstrap_warn "extra_agents: the Codex tarball held no $member"; return 4; }
    /bin/mv -f "$dir/$member" "$dir/codex" && /bin/chmod 755 "$dir/codex" || { /bin/rm -rf "$dir"; return 4; }
    if ! extra_agents_signed "$dir/codex" "$EXTRA_AGENTS_CODEX_TEAM"; then
      /bin/rm -rf "$dir"
      bootstrap_warn "extra_agents: Codex CLI is not signed by Team ID $EXTRA_AGENTS_CODEX_TEAM — refused"
      return 2
    fi
    /bin/ln -sfn "$dir/codex" "$bin" || { /bin/rm -rf "$dir"; return 4; }
    printf 'tree\t%s\nlink\t%s\t%s\n' "$dir" "$bin" "$dir/codex" >>"$rec"
    return 0
  fi
  dir="$(extra_agents_prefix)/gemini-cli-$EXTRA_AGENTS_GEMINI_VERSION"
  /bin/rm -rf "$dir"; /bin/mkdir -p "$dir" 2>/dev/null || { /bin/rm -f "$dl"; return 4; }
  /usr/bin/tar -xzf "$dl" -C "$dir" 2>/dev/null; /bin/rm -f "$dl"
  [ -f "$dir/package/bundle/gemini.js" ] || { /bin/rm -rf "$dir"; bootstrap_warn "extra_agents: the Gemini tarball held no package/bundle/gemini.js"; return 4; }
  printf 'tree\t%s\n' "$dir" >>"$rec"
  node="$(extra_agents_node)" && ref="$(extra_agents_node_ref "$node")"
  if [ -z "${ref:-}" ]; then
    extra_agents_node_fetch "$rec"; rc=$?
    case "$rc" in
      0) ref="$(extra_agents_node_ref "$(extra_agents_node_home)/bin/node")" ;;
      1) if why="$(extra_agents_unreachable "$(extra_agents_source "$(extra_agents_url node)")")"; then
           printf '%s\n' "$why" >"$(extra_agents_marker gemini)"
           bootstrap_warn "extra_agents: nodejs.org unreachable ($why) — Gemini CLI has nothing to run it"
         fi; return 1 ;;
      *) return "$rc" ;;
    esac
  fi
  # The launcher locates itself and names everything relative to that, so it carries no user name
  # (house rule 9) and keeps working for a caller whose HOME is not this one. It is a file we EXECUTE
  # to verify, never a string we grep for.
  printf '#!/bin/sh\n# mac-bootstrap extra_agents — Gemini CLI, run by the node this module chose.\nd=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 127\nexec %s "$d/../extra-agents/%s/package/bundle/gemini.js" "$@"\n' \
    "$ref" "${dir##*/}" >"$bin" || return 4
  /bin/chmod 755 "$bin" || return 4
  printf 'file\t%s\t%s\n' "$bin" "$(/usr/bin/shasum -a 256 "$bin" | /usr/bin/cut -d' ' -f1)" >>"$rec"
  return 0
}

# ── the six verbs ────────────────────────────────────────────────────────────────────────────
verify_extra_agents() {
  local s a st sel
  sel="$(extra_agents_selected)" || return 1
  [ -n "$sel" ] && [ "$sel" != none ] || return 0
  s="$(extra_agents_states)" || return 1
  for a in $sel; do
    st="$(printf '%s\n' "$s" | LC_ALL=C /usr/bin/awk -v a="$a" '$1 == a { print $2; exit }')"
    [ "$st" = ready ] || return 1
  done
  return 0
}
gate_extra_agents() { [ -n "$(extra_agents_first_gate)" ]; }

note_extra_agents() {
  local s a st detail out="" sel
  if ! sel="$(extra_agents_selected)"; then
    printf "BOOTSTRAP_EXTRA_AGENTS='%s' names a CLI this module does not know — use codex, gemini or none" "${BOOTSTRAP_EXTRA_AGENTS:-}"; return 0
  fi
  [ -n "$sel" ] && [ "$sel" != none ] || { printf 'no extra coding agent selected (BOOTSTRAP_EXTRA_AGENTS=none), so nothing to install'; return 0; }
  s="$(extra_agents_states)"
  while read -r a st detail; do
    [ -n "$a" ] || continue
    case "$st" in
      ready)       continue ;;
      unreachable) out="$out; $(extra_agents_name "$a") was not downloaded: $detail — ask IT to allow https://$(extra_agents_host "$(extra_agents_source "$(extra_agents_url "$a")")")" ;;
      no-node)     out="$out; $(extra_agents_name "$a") has no node to run it: $detail — ask IT to allow https://nodejs.org" ;;
      refused)     out="$out; $(extra_agents_name "$a") is verified but this Mac will not run it — ask IT to allow software signed by $(extra_agents_vendor "$a") (Team ID $EXTRA_AGENTS_CODEX_TEAM)" ;;
      login)       out="$out; $(extra_agents_name "$a") runs, but nobody has signed in to $(extra_agents_vendor "$a")" ;;
      *)           out="$out; $(extra_agents_name "$a") is not installed yet" ;;
    esac
  done <<EOF
$s
EOF
  printf '%s' "${out#; }"
}

# ONE command, for the FIRST outstanding gate. Each CLI's sign-in is its own gesture: clear this one,
# re-run, and the next CLI's is reported. Never a list, never a bare path.
gesture_extra_agents() {
  local g a st bin
  g="$(extra_agents_first_gate)" || return 0
  [ -n "$g" ] || return 0
  a="${g%% *}"; st="$(printf '%s' "${g#* }")"; bin="${st#* }"; st="${st%% *}"
  [ "$st" = login ] || return 0
  case "$bin" in *' '*|*'"'*|*"'"*) return 0 ;; esac
  case "$a" in
    codex) printf '%s login' "$(extra_agents_short "$bin")" ;;
    *)     printf '%s' "$(extra_agents_short "$bin")" ;;   # Gemini signs in on its first run
  esac
}

install_extra_agents() {
  local sel a bin v failed=0 missing=0
  sel="$(extra_agents_selected)" || { bootstrap_warn "extra_agents: BOOTSTRAP_EXTRA_AGENTS='${BOOTSTRAP_EXTRA_AGENTS:-}' names a CLI other than codex, gemini or none"; return 1; }
  [ -n "$sel" ] && [ "$sel" != none ] || return 0
  # Independent by construction: each CLI is placed in its own pass and a failure only sets a flag.
  for a in $sel; do
    if ! extra_agents_ours "$a" && bin="$(extra_agents_bin "$a")"; then
      v="$(extra_agents_exec "$bin")"
      case "$v" in *"$(extra_agents_version "$a")"*) : ;;
        *) bootstrap_warn "extra_agents: $(extra_agents_name "$a") is already at $(extra_agents_short "$bin") (${v:-no version}); the pin is $(extra_agents_version "$a") — left as it is" ;; esac
      continue
    fi
    extra_agents_ours "$a" || extra_agents_place "$a" || { failed=1; continue; }
    extra_agents_exec "$(extra_agents_bindir)/$a" >/dev/null || failed=1
  done
  [ "$failed" = 0 ] || return 1
  for a in $sel; do extra_agents_signed_in "$a" || missing=1; done
  # Installed, and a sign-in is outstanding: a gate the installer has now DISCOVERED. Non-zero makes
  # the driver ask gate_ again, which reports the login.
  [ "$missing" = 0 ] || return 3
  return 0
}

# Removes exactly what install_ recorded, and only while it still matches what we wrote.
uninstall_extra_agents() {
  local a rec kind p x
  for a in codex gemini; do
    rec="$(extra_agents_record "$a")"
    [ -f "$rec" ] || continue
    while IFS="$(printf '\t')" read -r kind p x; do
      case "$kind" in
        file) [ -f "$p" ] && [ "$(/usr/bin/shasum -a 256 "$p" | /usr/bin/cut -d' ' -f1)" = "$x" ] && /bin/rm -f "$p" ;;
        link) [ -L "$p" ] && [ "$(/usr/bin/readlink "$p")" = "$x" ] && /bin/rm -f "$p" ;;
        tree) case "$p" in "$(extra_agents_prefix)"/*) /bin/rm -rf "$p" ;; esac ;;
      esac
    done <"$rec"
    /bin/rm -f "$rec" "$(extra_agents_marker "$a")"
  done
  /bin/rmdir "$(extra_agents_prefix)" "$(extra_agents_state)" 2>/dev/null
  return 0
}

# ── the catalog ──────────────────────────────────────────────────────────────────────────────
what_extra_agents()    { printf '%s' "the two other coding-agent CLIs this Mac runs — OpenAI's Codex CLI and Google's Gemini CLI — pinned, hash-checked and in your home folder, in \$HOME/.mac-bootstrap/tools/bin"; }
cost_extra_agents()    { printf '%s' "~88 MB downloaded for Codex CLI (222 MB unpacked), ~21 MB for Gemini CLI plus ~50 MB of node if this Mac has none; a few minutes. One browser sign-in per CLI, and each is a separate vendor account."; }
profile_extra_agents() { printf '%s' 'full'; }
# One line per host, and the first `run` line of each CLI is the one that matters: this is a second
# and a third model provider on this Mac, each sending your work to its own vendor.
egress_extra_agents() {
  local sel; sel="$(extra_agents_selected)" || sel="codex gemini"
  case " $sel " in *" codex "*) cat <<'E'
api.openai.com run Codex CLI sends the code, files and prompts of whatever you point it at to OpenAI — a model provider of its own, separate from Claude Code's and Copilot's
chatgpt.com run Codex CLI's ChatGPT-plan sign-in and its model calls on that plan
auth.openai.com run the browser sign-in you do once, per account
github.com install the pinned Codex CLI release tarball (sha256 and OpenAI's signature checked)
release-assets.githubusercontent.com install the Codex tarball github.com redirects to
E
  esac
  case " $sel " in *" gemini "*) cat <<'E'
cloudcode-pa.googleapis.com run Gemini CLI sends the code, files and prompts of whatever you point it at to Google — a third model provider, separate from the other two
generativelanguage.googleapis.com run Gemini CLI's model calls when it is signed in with an API key instead
oauth2.googleapis.com run the token refresh for that sign-in
accounts.google.com run the browser sign-in you do once, per account
registry.npmjs.org install the pinned @google/gemini-cli bundle (sha256 checked; the package has no dependencies, so nothing else is resolved)
nodejs.org install the pinned node that runs that bundle — only when this Mac has no node 20 or later
E
  esac
}
clearance_extra_agents() {
  local sel; sel="$(extra_agents_selected)" || sel="codex gemini"
  case " $sel " in *" codex "*)
    printf '%s\n' "software OpenAI Codex CLI $EXTRA_AGENTS_CODEX_VERSION, a vendor binary signed by OpenAI (Team ID $EXTRA_AGENTS_CODEX_TEAM) that IT did not distribute, into \$HOME/.mac-bootstrap/tools"
    printf '%s\n' "agent Codex CLI sends work content — the code and files it is pointed at — to OpenAI, a model provider IT may sanction separately from Anthropic's and GitHub's" ;;
  esac
  case " $sel " in *" gemini "*)
    printf '%s\n' "software Google Gemini CLI $EXTRA_AGENTS_GEMINI_VERSION, Google's own npm bundle run by a pinned nodejs.org node, neither distributed by IT, into \$HOME/.mac-bootstrap/tools"
    printf '%s\n' "agent Gemini CLI sends work content — the code and files it is pointed at — to Google, a third model provider, sanctioned separately again" ;;
  esac
}
