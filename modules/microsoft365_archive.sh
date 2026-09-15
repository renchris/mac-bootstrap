# shellcheck shell=bash
# microsoft365_archive — every Teams meeting you attend, and your Copilot upload folder, kept as
# markdown in one folder on this Mac, refreshed hourly by a LaunchAgent.
#
# WHAT IT INSTALLS
#   $BOOTSTRAP_STATE_DIR/microsoft365-archive/   the archive engine (node, zero dependencies:
#                                                archive.js, render.js, resolve.js, the offline
#                                                fake-server.js and its fixtures/), the shared
#                                                converter markdown-convert.sh, and `config`
#   $BOOTSTRAP_STATE_DIR/bin/microsoft365-archive a wrapper that runs the pinned node on archive.js
#                                                with MICROSOFT365_ARCHIVE_CONFIG pointing at config
#   $HOME/Library/LaunchAgents/com.mac-bootstrap.microsoft365-archive.plist
#                                                [wrapper, run] at minute 7 of every hour, and at load
#   the archive folder itself                    BOOTSTRAP_ARCHIVE_DIR, default $HOME/Microsoft365Archive
#
# HOW IT TALKS TO MICROSOFT: it does not, directly. The engine starts the SAME Softeria server the
# microsoft365 module installed, over stdio, exactly as an agent does, and asks it only for Graph
# GETs — the engine refuses any other tool, any non-GET batch request and any /special/ path before
# every call, because a launchd job never passes the agent's PreToolUse guard. The sign-in is the
# one microsoft365 already asks for; this module never reads a token and never writes one.
#
# WHY THE LAUNCHD LOAD IS REFUSED UNDER A SANDBOXED HOME: `launchctl bootstrap gui/<uid>` acts on the
# REAL per-user launchd domain whatever $HOME says — the same escape class as `defaults`, which
# bootstrap_defaults_home_ok already guards. `HOME=$(mktemp -d) bash bootstrap.sh` is the documented
# test, so without the refusal every test run would leave a job in the real domain pointing into a
# temp dir. Under a foreign HOME the files land (they are inside that HOME) and the load is reported
# as NEEDS_HUMAN; BOOTSTRAP_ALLOW_FOREIGN_DEFAULTS=1 is the same deliberate override defaults honours.
#
# THE ARCHIVE FOLDER IS REFUSED INSIDE A SYNC CLIENT'S TREE ($HOME/Library/CloudStorage, iCloud's
# $HOME/Library/Mobile Documents): client meeting content written there would be re-uploaded to
# wherever that folder syncs. Judged on the real path of the deepest ancestor that exists, so a
# symlink into a synced folder is caught too.
#
# bash 3.2 · set -u, no set -e · every verb runs in its own subshell, so nothing survives between
# verbs and everything below re-derives what it needs. No permission, allow-list or credential is
# written anywhere in this file.

MICROSOFT365_ARCHIVE_LABEL="com.mac-bootstrap.microsoft365-archive"
MICROSOFT365_ARCHIVE_VERSION_LINE="microsoft365-archive 1"
MICROSOFT365_ARCHIVE_ENGINE_FILES="archive.js render.js resolve.js fake-server.js"
MICROSOFT365_ARCHIVE_PERSONAL_TENANT="9188040d-6c67-4c5b-b112-36a304b66dad"   # every personal Microsoft account
# Minute past the hour. StartCalendarInterval, not StartInterval: an interval missed while the Mac
# sleeps is dropped, a calendar slot coalesces into one run at the next wake.
MICROSOFT365_ARCHIVE_MINUTE=7

# ── paths, re-derived per verb ───────────────────────────────────────────────────────────────
microsoft365_archive_state_dir() { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
microsoft365_archive_dir()       { printf '%s/microsoft365-archive' "$(microsoft365_archive_state_dir)"; }
microsoft365_archive_wrapper()   { printf '%s/bin/microsoft365-archive' "$(microsoft365_archive_state_dir)"; }
microsoft365_archive_config()    { printf '%s/config' "$(microsoft365_archive_dir)"; }
microsoft365_archive_converter() { printf '%s/markdown-convert.sh' "$(microsoft365_archive_dir)"; }
microsoft365_archive_log()       { printf '%s/launchd.log' "$(microsoft365_archive_dir)"; }
microsoft365_archive_plist()     { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$MICROSOFT365_ARCHIVE_LABEL"; }
microsoft365_archive_domain()    { printf 'gui/%s' "$(/usr/bin/id -u)"; }
# The microsoft365 module's server. Its module file cannot be sourced from here (each verb sources
# only its own module), so the path is re-derived the way that module spells it.
microsoft365_archive_server()    { printf '%s/microsoft365/node_modules/@softeria/ms-365-mcp-server/dist/index.js' "$(microsoft365_archive_state_dir)"; }

# The choices a person made through the environment, recorded at install so a cold verify with no
# environment agrees. Written only when the variable is set, so a re-run without it never resets
# a choice made earlier.
microsoft365_archive_chosen_root_file()    { printf '%s/chosen-archive-dir' "$(microsoft365_archive_dir)"; }
microsoft365_archive_chosen_account_file() { printf '%s/chosen-account' "$(microsoft365_archive_dir)"; }

microsoft365_archive_root() {
  local f
  [ -n "${BOOTSTRAP_ARCHIVE_DIR:-}" ] && { printf '%s' "${BOOTSTRAP_ARCHIVE_DIR%/}"; return 0; }
  f="$(microsoft365_archive_chosen_root_file)"
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  printf '%s/Microsoft365Archive' "$HOME"
}

# Tenant and client id exactly as microsoft365 derives them: environment, then what that module
# recorded, then its work-account default — so the archive signs in the way the agents do.
microsoft365_archive_tenant() {
  local f
  [ -n "${BOOTSTRAP_MICROSOFT_TENANT:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_TENANT"; return 0; }
  f="$(microsoft365_archive_state_dir)/microsoft365/tenant"
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  printf 'organizations'
}
microsoft365_archive_client_id() {
  local f
  [ -n "${BOOTSTRAP_MICROSOFT_CLIENT_ID:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_CLIENT_ID"; return 0; }
  f="$(microsoft365_archive_state_dir)/microsoft365/client-id"
  [ -s "$f" ] && head -n 1 "$f"
  return 0
}

# microsoft365_archive_node — the same candidate list, in the same order, as microsoft365_node: a node
# >= 18 at a path that survives a node upgrade. A per-shell fnm_multishells path is refused, because
# it vanishes with the shell and the hourly job would die with it, silently.
microsoft365_archive_node() {
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

# Paths are shown as $HOME/… literally: executable as typed, and no username in the output.
microsoft365_archive_short_path() {
  case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

# microsoft365_archive_rerun <module> [<VAR=value …>] — the command a person re-runs to finish a module,
# with the given environment on the bootstrap run itself: the clone's bootstrap.sh when there is one;
# from a curl'd bootstrap (no clone) the same pinned release fetched again. The fetched entry script is
# the one AT the pin, which pins an older tree, so BOOTSTRAP_PIN is passed to hold it to this release.
# Nothing is printed when neither can be spelled — a command that does not run as typed is worse.
microsoft365_archive_rerun() {
  local module="$1" env="${2:-}" root pin raw
  [ -n "$env" ] && env="$env "
  if [ -n "${BOOTSTRAP_ASSETS:-}" ]; then
    root="$(dirname "$BOOTSTRAP_ASSETS")"
    [ -r "$root/bootstrap.sh" ] && { printf '%sbash "%s/bootstrap.sh" --only %s' "$env" "$(microsoft365_archive_short_path "$root")" "$module"; return 0; }
  fi
  pin="${BOOTSTRAP_PIN:-}"; raw="${BOOTSTRAP_RAW:-}"
  case "$pin" in ''|*[!0-9A-Fa-f]*) return 0 ;; esac
  case "$raw" in "https://raw.githubusercontent.com/"*"/$pin") : ;; *) return 0 ;; esac
  case "$raw" in *[!A-Za-z0-9._/:-]*) return 0 ;; esac
  printf 'curl -fsSL -o /tmp/mac-bootstrap.sh %s/bootstrap.sh && %sBOOTSTRAP_PIN=%s bash /tmp/mac-bootstrap.sh --only %s' "$raw" "$env" "$pin" "$module"
}

# ── bounded execution ────────────────────────────────────────────────────────────────────────
# macOS has no timeout(1), and a selftest that hangs would hang the whole bootstrap. node's
# spawnSync carries the ceiling instead; a timeout exits 124. The program is executed as launchd
# will execute it — through its own shebang.
MICROSOFT365_ARCHIVE_BOUNDED_JS='
const argv = process.argv.slice(1);
const r = require("child_process").spawnSync(argv[1], argv.slice(2),
  {timeout: Number(argv[0]), stdio: ["ignore", "inherit", "inherit"]});
process.exit(r.status === null ? 124 : r.status);
'
microsoft365_archive_bounded() {                    # <node> <ms> <program> <args…>
  local node="$1"; shift
  "$node" -e "$MICROSOFT365_ARCHIVE_BOUNDED_JS" "$@"
}

# ── the account ──────────────────────────────────────────────────────────────────────────────
# microsoft365_archive_account_candidates <node> — the signed-in accounts in the configured tenant,
# one username per line. `--list-accounts` is local (MSAL's cache, read by the server itself, never
# by us); each id is "<object id>.<tenant id>", so the tenant test is the one microsoft365 applies.
microsoft365_archive_account_candidates() {
  local node="$1" tmp logs n i id tenant_of_account user want client_id keep
  [ -f "$(microsoft365_archive_server)" ] || return 1
  tmp="$(mktemp -t microsoft365archiveaccounts)" || return 1
  logs="$(mktemp -d -t microsoft365archivelogs)" || { rm -f "$tmp"; return 1; }
  client_id="$(microsoft365_archive_client_id)"
  if [ -n "$client_id" ]; then
    MS365_MCP_LOG_DIR="$logs" MS365_MCP_TENANT_ID="$(microsoft365_archive_tenant)" MS365_MCP_CLIENT_ID="$client_id" \
      "$node" "$(microsoft365_archive_server)" --list-accounts 2>/dev/null | grep '^{' | tail -n 1 > "$tmp"
  else
    MS365_MCP_LOG_DIR="$logs" MS365_MCP_TENANT_ID="$(microsoft365_archive_tenant)" \
      "$node" "$(microsoft365_archive_server)" --list-accounts 2>/dev/null | grep '^{' | tail -n 1 > "$tmp"
  fi
  rm -rf "$logs" 2>/dev/null
  n="$(bootstrap_settings_get "$tmp" accounts raw 2>/dev/null)" || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  want="$(microsoft365_archive_tenant)"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="$(bootstrap_settings_get "$tmp" "accounts.$i.id" raw 2>/dev/null)" || id=""
    user="$(bootstrap_settings_get "$tmp" "accounts.$i.username" raw 2>/dev/null)" || user=""
    i=$((i + 1))
    [ -n "$id" ] || continue
    [ -n "$user" ] || user="$id"
    tenant_of_account="${id##*.}"
    keep=1
    case "$want" in
      common)        : ;;
      consumers)     [ "$tenant_of_account" = "$MICROSOFT365_ARCHIVE_PERSONAL_TENANT" ] || keep=0 ;;
      *-*-*-*-*)     [ "$tenant_of_account" = "$want" ] || keep=0 ;;
      *)             [ "$tenant_of_account" != "$MICROSOFT365_ARCHIVE_PERSONAL_TENANT" ] || keep=0 ;;   # organizations, or a domain name
    esac
    [ "$keep" = 1 ] && printf '%s\n' "$user"
  done
  rm -f "$tmp" 2>/dev/null
  return 0
}

# microsoft365_archive_lower <text> — ASCII case folded, for comparisons a case-insensitive volume or
# a case-insensitive sign-in name would call equal.
microsoft365_archive_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# microsoft365_archive_signed_in <account> <candidates> — rc 0 iff the account is one of the signed-in
# candidates (one per line), compared case-insensitively as the engine compares it.
microsoft365_archive_signed_in() {
  local want line
  [ -n "$1" ] || return 1
  want="$(microsoft365_archive_lower "$1")"
  while IFS= read -r line; do
    [ -n "$line" ] && [ "$(microsoft365_archive_lower "$line")" = "$want" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# microsoft365_archive_held_account — the account= the installed config already holds, or nothing.
microsoft365_archive_held_account() {
  microsoft365_archive_config_get "$(microsoft365_archive_config)" account 2>/dev/null
  return 0
}

# microsoft365_archive_account_from <candidates> — the account the job will pass on every call, or
# rc 1: BOOTSTRAP_MICROSOFT_ACCOUNT, then the recorded choice, then the account the config already
# holds WHILE it is still signed in (a second account signing in later must not undo an earlier
# pick), then the ONE signed-in account in the tenant. Zero or several is a person's question, never a
# guess. A named account is returned even when it is not signed in — the gate reports that.
microsoft365_archive_account_from() {
  local list="$1" f held only
  [ -n "${BOOTSTRAP_MICROSOFT_ACCOUNT:-}" ] && { printf '%s' "$BOOTSTRAP_MICROSOFT_ACCOUNT"; return 0; }
  f="$(microsoft365_archive_chosen_account_file)"
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  held="$(microsoft365_archive_held_account)"
  if [ -n "$held" ] && microsoft365_archive_signed_in "$held" "$list"; then printf '%s' "$held"; return 0; fi
  only="$(printf '%s\n' "$list" | awk 'NF')"
  [ -n "$only" ] || return 1
  [ "$(printf '%s\n' "$only" | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s' "$only"
}

# microsoft365_archive_account <node> — the same, asking the server for the candidates itself.
microsoft365_archive_account() {
  local list
  list="$(microsoft365_archive_account_candidates "$1" 2>/dev/null)" || list=""
  microsoft365_archive_account_from "$list"
}

# ── the cloud-path refusal ───────────────────────────────────────────────────────────────────
# microsoft365_archive_real_path <path> — the physical path: the deepest ancestor that exists,
# resolved with pwd -P, with the not-yet-existing tail put back.
microsoft365_archive_real_path() {
  local p="${1%/}" tail="" base
  [ -n "$p" ] || p="/"
  while [ ! -d "$p" ]; do
    base="${p##*/}"
    tail="/$base$tail"
    p="${p%/*}"
    [ -n "$p" ] || { p="/"; break; }
  done
  p="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  [ "$p" = "/" ] && p=""
  printf '%s%s' "$p" "$tail"
}

# microsoft365_archive_under_cloud <path> — rc 0 iff <path> is inside a sync client's tree. The two
# physical paths are compared with the letter case folded: `pwd -P` keeps the case that was TYPED, and
# on a case-insensitive volume (the macOS default) $HOME/library/cloudstorage IS the synced folder. On
# a case-sensitive volume the fold can only refuse more.
microsoft365_archive_under_cloud() {
  local p c
  p="$(microsoft365_archive_real_path "$1")" || return 0     # cannot tell => refuse, never guess safe
  p="$(microsoft365_archive_lower "$p")"
  for c in "$HOME/Library/CloudStorage" "$HOME/Library/Mobile Documents"; do
    c="$(microsoft365_archive_real_path "$c")" || return 0
    c="$(microsoft365_archive_lower "$c")"
    case "$p/" in "$c"/*) return 0 ;; esac
  done
  return 1
}

# microsoft365_archive_root_shape_ok <path> — absolute, with no "." or ".." segment. The tail of a
# path that does not exist yet is never resolved, so "$HOME/new/../Library/CloudStorage/x" would read
# as outside the cloud and then `mkdir -p` would create a folder inside it.
microsoft365_archive_root_shape_ok() {
  case "$1" in /*) : ;; *) return 1 ;; esac
  case "/$1/" in */./*|*/../*) return 1 ;; esac
  return 0
}

# microsoft365_archive_root_in_engine <path> — rc 0 iff <path> is, or is inside, a folder this module
# owns and uninstall removes (the engine folder, the wrapper's bin/): an archive there would go with it.
microsoft365_archive_root_in_engine() {
  local p d
  p="$(microsoft365_archive_real_path "$1")" || return 0
  p="$(microsoft365_archive_lower "$p")"
  for d in "$(microsoft365_archive_dir)" "$(microsoft365_archive_state_dir)/bin"; do
    d="$(microsoft365_archive_real_path "$d")" || return 0
    d="$(microsoft365_archive_lower "$d")"
    case "$p/" in "$d"/*) return 0 ;; esac
  done
  return 1
}

# ── the asset set ────────────────────────────────────────────────────────────────────────────
# Asset paths are relative to assets/: microsoft365-archive/<file> and markdown-convert.sh. From a
# clone the engine's file list is the directory itself; a curl'd bootstrap has no directory to list,
# so it reads assets/microsoft365-archive/MANIFEST (one path per line, relative to that folder).
microsoft365_archive_clone() {
  [ -r "${BOOTSTRAP_ASSETS:-}/microsoft365-archive/archive.js" ] && [ -r "${BOOTSTRAP_ASSETS}/markdown-convert.sh" ] \
    && { printf '%s' "$BOOTSTRAP_ASSETS"; return 0; }
  return 1
}

# microsoft365_archive_part_ok <relpath> — a manifest line we are willing to turn into a path.
microsoft365_archive_part_ok() {
  case "$1" in
    ''|/*|*/|*//*|.*|*/.*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

# microsoft365_archive_listing <clone> — the engine's files, from the directory, relative to it:
# every file but the MANIFEST and hidden ones. Every file, not a fixed four: the folder's own
# package.json ("type": "commonjs") is what keeps node from reading the engine as ES modules under
# a package.json higher up (the repo's root one declares "type": "module"), and a fixed list would
# have silently dropped it.
microsoft365_archive_listing() {
  [ -d "$1/microsoft365-archive" ] || return 1
  (cd "$1/microsoft365-archive" && find . -type f ! -name MANIFEST ! -name '.*' ! -path '*/.*' 2>/dev/null) \
    | sed 's#^\./##' | LC_ALL=C sort
}

# microsoft365_archive_manifest_lines <file> — the MANIFEST's paths, validated; rc 1 on any bad line
# or when an engine file is missing from it.
microsoft365_archive_manifest_lines() {
  local line out="" f
  [ -s "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    microsoft365_archive_part_ok "$line" || return 1
    out="$out$line
"
  done < "$1"
  for f in $MICROSOFT365_ARCHIVE_ENGINE_FILES; do
    case "
$out" in *"
$f
"*) : ;; *) return 1 ;; esac
  done
  printf '%s' "$out"
}

# microsoft365_archive_curl <url> <dest> — a real 200 with a body, or nothing at all.
microsoft365_archive_curl() {
  local code
  code="$(curl -sS -L -o "$2.part" -w '%{http_code}' "$1" 2>/dev/null)" || code=""
  if [ "$code" = "200" ] && [ -s "$2.part" ]; then mv -f "$2.part" "$2"; return $?; fi
  rm -f "$2.part" 2>/dev/null
  return 1
}

# microsoft365_archive_fetched — the pinned release's asset set, fetched ONCE per pin into a cache
# keyed by the pin (a cache shared across pins would let a stale copy satisfy a newer release).
# Filled into a .part directory and renamed only when complete, so a half fetch is never a source.
microsoft365_archive_fetched() {
  local pin="${BOOTSTRAP_PIN:-}" cache part rel lines
  case "$pin" in __PIN_SHA__|main|master|'') return 1 ;; esac      # a moving ref is not a pin
  case "$pin" in *[!0-9A-Za-z]*) return 1 ;; esac
  cache="$(microsoft365_archive_dir)/.fetched/$pin"
  [ -f "$cache/.complete" ] && { printf '%s' "$cache"; return 0; }
  command -v curl >/dev/null 2>&1 || return 1
  part="$cache.part.$$"
  rm -rf "$part" 2>/dev/null
  mkdir -p "$part/microsoft365-archive" 2>/dev/null || return 1
  microsoft365_archive_curl "${BOOTSTRAP_RAW:-}/assets/microsoft365-archive/MANIFEST" "$part/microsoft365-archive/MANIFEST" \
    || { rm -rf "$part"; return 1; }
  lines="$(microsoft365_archive_manifest_lines "$part/microsoft365-archive/MANIFEST")" || { rm -rf "$part"; return 1; }
  for rel in $lines; do
    mkdir -p "$(dirname "$part/microsoft365-archive/$rel")" 2>/dev/null || { rm -rf "$part"; return 1; }
    microsoft365_archive_curl "${BOOTSTRAP_RAW:-}/assets/microsoft365-archive/$rel" "$part/microsoft365-archive/$rel" \
      || { rm -rf "$part"; return 1; }
  done
  microsoft365_archive_curl "${BOOTSTRAP_RAW:-}/assets/markdown-convert.sh" "$part/markdown-convert.sh" || { rm -rf "$part"; return 1; }
  : > "$part/.complete"
  rm -rf "$cache" 2>/dev/null
  mv -f "$part" "$cache" 2>/dev/null || { rm -rf "$part"; return 1; }
  printf '%s' "$cache"
}

# microsoft365_archive_source — the root to copy from: the clone, else the pinned fetch. rc 1 = none.
microsoft365_archive_source() {
  microsoft365_archive_clone && return 0
  microsoft365_archive_fetched
}

# microsoft365_archive_parts <source-root> — the engine file list for that root.
microsoft365_archive_parts() {
  if [ "$1" = "${BOOTSTRAP_ASSETS:-}" ]; then microsoft365_archive_listing "$1"
  else microsoft365_archive_manifest_lines "$1/microsoft365-archive/MANIFEST"; fi
}

# microsoft365_archive_manifest_agrees <clone> — from a clone, the MANIFEST must name exactly the
# files the directory holds. A clone can never see a curl'd install's file set otherwise, and a
# MANIFEST that forgot a fixture ships an engine whose selftest fails only on a stranger's Mac.
microsoft365_archive_manifest_agrees() {
  local a b
  a="$(microsoft365_archive_manifest_lines "$1/microsoft365-archive/MANIFEST")" || return 1
  a="$(printf '%s' "$a" | LC_ALL=C sort)"
  b="$(microsoft365_archive_listing "$1" | LC_ALL=C sort)"
  [ "$a" = "$b" ]
}

# ── generated files: the wrapper and the config ──────────────────────────────────────────────
microsoft365_archive_wrapper_text() {           # <node>
  local node="$1"
  printf '#!/bin/bash\n'
  printf '# microsoft365-archive — written by the mac-bootstrap module microsoft365_archive; re-running\n'
  printf '# the bootstrap rewrites it, so change the module, not this file.\n'
  printf '# launchd starts a job with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which holds neither node nor the\n'
  printf '# converters markdown-convert.sh looks for (pandoc, markitdown), so they go on PATH here.\n'
  # shellcheck disable=SC2016   # $HOME and $PATH are meant to expand when the wrapper runs, not now
  printf 'PATH=%q:/opt/homebrew/bin:/usr/local/bin:"$HOME/.local/bin":"${PATH:-/usr/bin:/bin}"\n' "$(dirname "$node")"
  printf 'export PATH\n'
  printf 'MICROSOFT365_ARCHIVE_CONFIG=%q\n' "$(microsoft365_archive_config)"
  printf 'export MICROSOFT365_ARCHIVE_CONFIG\n'
  # shellcheck disable=SC2016
  printf 'exec %q %q "$@"\n' "$node" "$(microsoft365_archive_dir)/archive.js"
}

# key=value, one per line, fixed order. account and client_id appear only when there is one.
microsoft365_archive_config_text() {            # <node> <account-or-empty>
  local node="$1" account="$2" id
  printf 'root=%s\n' "$(microsoft365_archive_root)"
  [ -n "$account" ] && printf 'account=%s\n' "$account"
  printf 'node=%s\n' "$node"
  printf 'server=%s\n' "$(microsoft365_archive_server)"
  printf 'tenant=%s\n' "$(microsoft365_archive_tenant)"
  id="$(microsoft365_archive_client_id)"
  [ -n "$id" ] && printf 'client_id=%s\n' "$id"
  printf 'convert=%s\n' "$(microsoft365_archive_converter)"
}

# microsoft365_archive_config_get <file> <key> — the reader, awk rather than the printf that wrote.
microsoft365_archive_config_get() {
  [ -f "$1" ] || return 1
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found=1; exit } END { exit found ? 0 : 1 }' "$1"
}

# microsoft365_archive_config_ok <node> <account-or-empty> — every key parsed back equal, and no
# key we did not write.
microsoft365_archive_config_ok() {
  local f want line k n=0 m
  f="$(microsoft365_archive_config)"
  [ -f "$f" ] || return 1
  want="$(microsoft365_archive_config_text "$1" "$2")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    [ "$(microsoft365_archive_config_get "$f" "$k")" = "${line#*=}" ] || return 1
    n=$((n + 1))
  done <<EOF
$want
EOF
  m="$(awk 'NF' "$f" | wc -l | tr -d ' ')"
  [ "$m" = "$n" ]
}

# microsoft365_archive_land <src> <dest> <mode> — write only on a difference, via a temp file and a
# rename, so a second run touches no byte and an interrupted one never leaves half a file.
microsoft365_archive_land() {
  local src="$1" dest="$2" mode="$3" have
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
  if ! cmp -s "$src" "$dest" 2>/dev/null; then
    cp -f "$src" "$dest.tmp.$$" 2>/dev/null && chmod "$mode" "$dest.tmp.$$" 2>/dev/null \
      && mv -f "$dest.tmp.$$" "$dest" 2>/dev/null || { rm -f "$dest.tmp.$$" 2>/dev/null; return 1; }
    return 0
  fi
  have="$(stat -f %Lp "$dest" 2>/dev/null)" || have=""
  [ "$have" = "$mode" ] || chmod "$mode" "$dest" 2>/dev/null
  return 0
}

# ── the LaunchAgent ──────────────────────────────────────────────────────────────────────────
# microsoft365_archive_plist_build <dest> — built with plutil, key by key, never as a string.
microsoft365_archive_plist_build() {
  local p="$1" log
  log="$(microsoft365_archive_log)"
  rm -f "$p" 2>/dev/null
  plutil -create xml1 "$p" >/dev/null 2>&1 \
    && plutil -insert Label -string "$MICROSOFT365_ARCHIVE_LABEL" "$p" >/dev/null 2>&1 \
    && plutil -insert ProgramArguments -array "$p" >/dev/null 2>&1 \
    && plutil -insert ProgramArguments -string "$(microsoft365_archive_wrapper)" -append "$p" >/dev/null 2>&1 \
    && plutil -insert ProgramArguments -string run -append "$p" >/dev/null 2>&1 \
    && plutil -insert StartCalendarInterval -dictionary "$p" >/dev/null 2>&1 \
    && plutil -insert StartCalendarInterval.Minute -integer "$MICROSOFT365_ARCHIVE_MINUTE" "$p" >/dev/null 2>&1 \
    && plutil -insert RunAtLoad -bool true "$p" >/dev/null 2>&1 \
    && plutil -insert StandardOutPath -string "$log" "$p" >/dev/null 2>&1 \
    && plutil -insert StandardErrorPath -string "$log" "$p" >/dev/null 2>&1
}

# microsoft365_archive_plist_get <key> — plutil emits its failure SENTENCE on stdout (CONTRACT §7.3),
# so only an rc-0 answer is ever printed.
microsoft365_archive_plist_get() {
  local out
  out="$(plutil -extract "$1" raw "$(microsoft365_archive_plist)" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# microsoft365_archive_plist_ok — parses, and every field reads back as the job needs it. The array
# length is read too: an extra argument would change what launchd runs.
microsoft365_archive_plist_ok() {
  local p
  p="$(microsoft365_archive_plist)"
  [ -f "$p" ] || return 1
  plutil -lint "$p" >/dev/null 2>&1 || return 1
  [ "$(microsoft365_archive_plist_get Label)" = "$MICROSOFT365_ARCHIVE_LABEL" ] || return 1
  [ "$(microsoft365_archive_plist_get ProgramArguments)" = 2 ] || return 1
  [ "$(microsoft365_archive_plist_get ProgramArguments.0)" = "$(microsoft365_archive_wrapper)" ] || return 1
  [ "$(microsoft365_archive_plist_get ProgramArguments.1)" = run ] || return 1
  [ "$(microsoft365_archive_plist_get StartCalendarInterval.Minute)" = "$MICROSOFT365_ARCHIVE_MINUTE" ] || return 1
  [ "$(microsoft365_archive_plist_get RunAtLoad)" = true ] || return 1
  [ "$(microsoft365_archive_plist_get StandardOutPath)" = "$(microsoft365_archive_log)" ] || return 1
  [ "$(microsoft365_archive_plist_get StandardErrorPath)" = "$(microsoft365_archive_log)" ] || return 1
}

# microsoft365_archive_loaded_path [label] — the plist launchd loaded the label from, read out of
# launchd's own `print`; rc 1 when the label is not loaded. launchctl's rc is captured before the
# parse, so a pipe can never report the wrong stage's status (CONTRACT §7.8).
microsoft365_archive_loaded_path() {
  local out
  out="$(/bin/launchctl print "$(microsoft365_archive_domain)/${1:-$MICROSOFT365_ARCHIVE_LABEL}" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk 'index($0, "\tpath = ") == 1 { print substr($0, 9); exit }'
}

# microsoft365_archive_loaded_ours — rc 0 iff launchd holds the label AND loaded it from OUR plist.
# The label alone is not enough: one launchd domain serves every $HOME this user runs under, so a
# sandbox would otherwise count the real home's job as its own (and the reverse).
microsoft365_archive_loaded_ours() {
  local lp
  lp="$(microsoft365_archive_loaded_path)" || return 1
  [ -n "$lp" ] && [ -e "$lp" ] && [ "$lp" -ef "$(microsoft365_archive_plist)" ]
}

# The label is loaded, but from a plist that is not ours — another HOME's install, or a hand-made job.
microsoft365_archive_label_taken() {
  microsoft365_archive_loaded_path >/dev/null 2>&1 || return 1
  microsoft365_archive_loaded_ours && return 1
  return 0
}

microsoft365_archive_home_ok() { bootstrap_defaults_home_ok >/dev/null 2>&1; }

# ── the read-backs ───────────────────────────────────────────────────────────────────────────
# microsoft365_archive_files_ok — every engine file and the converter present, and byte-identical to
# the source whenever a source is reachable (the clone, or this pin's fetched set).
microsoft365_archive_files_ok() {
  local dir src rel parts
  dir="$(microsoft365_archive_dir)"
  for rel in $MICROSOFT365_ARCHIVE_ENGINE_FILES; do [ -f "$dir/$rel" ] || return 1; done
  [ -x "$(microsoft365_archive_converter)" ] || return 1
  src="$(microsoft365_archive_source 2>/dev/null)" || return 0
  parts="$(microsoft365_archive_parts "$src")" || return 1
  for rel in $parts; do
    cmp -s "$src/microsoft365-archive/$rel" "$dir/$rel" || return 1
  done
  cmp -s "$src/markdown-convert.sh" "$(microsoft365_archive_converter)"
}

# microsoft365_archive_wrapper_ok <node> — the wrapper is the one this Mac should have, and it RUNS:
# it answers --version with the engine's exact line, and (the negative control) a command the engine
# does not have is refused, so the version check is not merely "something printed".
microsoft365_archive_wrapper_ok() {
  local node="$1" w out tmp
  w="$(microsoft365_archive_wrapper)"
  [ -x "$w" ] || return 1
  tmp="$(mktemp -t microsoft365archivewrapper)" || return 1
  microsoft365_archive_wrapper_text "$node" > "$tmp"
  cmp -s "$tmp" "$w"; out=$?
  rm -f "$tmp" 2>/dev/null
  [ "$out" = 0 ] || return 1
  out="$(microsoft365_archive_bounded "$node" 20000 "$w" --version 2>/dev/null)" || return 1
  [ "$out" = "$MICROSOFT365_ARCHIVE_VERSION_LINE" ] || return 1
  microsoft365_archive_bounded "$node" 20000 "$w" no-such-command >/dev/null 2>&1 && return 1
  return 0
}

# microsoft365_archive_root_ok — the archive folder exists, is a folder, and is outside every synced
# tree and every folder uninstall removes; with its NEGATIVE CONTROLS, a path inside CloudStorage —
# spelled as on disk AND in another letter case — must be judged cloud, or the refusal can never say
# no and the pass means nothing.
microsoft365_archive_root_ok() {
  local r
  r="$(microsoft365_archive_root)"
  microsoft365_archive_root_shape_ok "$r" || return 1
  [ -d "$r" ] || return 1
  microsoft365_archive_under_cloud "$HOME/Library/CloudStorage/OneDrive-probe/x" || return 1
  microsoft365_archive_under_cloud "$(microsoft365_archive_lower "$HOME/Library/CloudStorage")/OneDrive-probe/x" || return 1
  microsoft365_archive_under_cloud "$r" && return 1
  microsoft365_archive_root_in_engine "$r" && return 1
  return 0
}

# The sha256 of the plist launchd was last bootstrapped from, written only after a load succeeded.
# launchd runs its in-memory copy, not the file, so a plist that changed on disk since is not live.
microsoft365_archive_loaded_marker() { printf '%s/loaded-plist.sha256' "$(microsoft365_archive_dir)"; }
microsoft365_archive_plist_sha() {
  local out
  out="$(/usr/bin/shasum -a 256 < "$(microsoft365_archive_plist)" 2>/dev/null)" || return 1
  printf '%s' "${out%% *}"
}
microsoft365_archive_loaded_current() {
  local have want
  have="$(head -n 1 "$(microsoft365_archive_loaded_marker)" 2>/dev/null)" || return 1
  want="$(microsoft365_archive_plist_sha)" || return 1
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# microsoft365_archive_ready <node> — everything reversible is in place (files, wrapper, config,
# plist, folder). The gates that only exist AFTER that work — the account, the sandboxed HOME, a
# label someone else loaded — are reported only once this holds, because gate_ runs before install_
# and a true gate there makes the driver skip the install it was about to do. The config is judged
# against the account it already HOLDS, not a fresh derivation: whether that account can still be
# used is the account gate's question, and it must be asked in --verify too.
microsoft365_archive_ready() {
  local node="$1"
  microsoft365_archive_files_ok || return 1
  microsoft365_archive_config_ok "$node" "$(microsoft365_archive_held_account)" || return 1
  microsoft365_archive_plist_ok || return 1
  microsoft365_archive_root_ok || return 1
  microsoft365_archive_wrapper_ok "$node"
}

# microsoft365_archive_gate_reason — ONE token naming the step only a person can take, or nothing.
# gate_, note_ and gesture_ all read this, so they can never disagree about which step it is.
microsoft365_archive_gate_reason() {
  local node n list account root
  node="$(microsoft365_archive_node)" || { printf 'node'; return 0; }
  [ -f "$(microsoft365_archive_server)" ] || { printf 'server'; return 0; }
  root="$(microsoft365_archive_root)"
  microsoft365_archive_root_shape_ok "$root" || { printf 'relative-root'; return 0; }
  microsoft365_archive_under_cloud "$root" && { printf 'cloud'; return 0; }
  microsoft365_archive_root_in_engine "$root" && { printf 'root-in-engine'; return 0; }
  microsoft365_archive_ready "$node" || return 0
  list="$(microsoft365_archive_account_candidates "$node" 2>/dev/null)" || list=""
  if ! account="$(microsoft365_archive_account_from "$list")"; then
    n="$(printf '%s\n' "$list" | awk 'NF' | wc -l | tr -d ' ')"
    case "$n" in 0|'') printf 'account-none' ;; *) printf 'account-many' ;; esac
    return 0
  fi
  microsoft365_archive_signed_in "$account" "$list" || { printf 'account-signed-out'; return 0; }
  microsoft365_archive_home_ok || { printf 'foreign-home'; return 0; }
  microsoft365_archive_label_taken && { printf 'label-taken'; return 0; }
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_microsoft365_archive()    { printf '%s' 'every Teams meeting you attend, and your Copilot upload folder, kept as markdown in one local folder and refreshed hourly; read-only against Microsoft'; }
cost_microsoft365_archive()    { printf '%s' 'under 1 MB plus your archive. Needs the microsoft365 sign-in; transcripts, AI notes and Copilot history each need a Microsoft grant your tenant may not have given, and the archive records which.'; }
profile_microsoft365_archive() { printf '%s' 'full'; }
needs_microsoft365_archive()   { printf '%s' 'microsoft365'; }

verify_microsoft365_archive() {
  local node account list
  node="$(microsoft365_archive_node)" || return 1
  [ -f "$(microsoft365_archive_server)" ] || return 1
  # The account the job passes must be one the server has signed in — read from the server's own
  # --list-accounts, not from what we recorded — or every hourly run stops at sign-in.
  list="$(microsoft365_archive_account_candidates "$node" 2>/dev/null)" || return 1
  account="$(microsoft365_archive_account_from "$list")" || return 1
  microsoft365_archive_signed_in "$account" "$list" || return 1

  # Installed bytes against the shipped bytes, and the generated config parsed back key by key.
  microsoft365_archive_files_ok || return 1
  microsoft365_archive_config_ok "$node" "$account" || return 1
  microsoft365_archive_root_ok || return 1

  # The plist parses and says what launchd must run.
  microsoft365_archive_plist_ok || return 1

  # launchd holds the job, from THIS plist — read out of launchd, the one reader that is not us.
  # Under a sandboxed HOME nothing was loaded, and a job the real home loaded must not count.
  microsoft365_archive_home_ok || return 1
  microsoft365_archive_loaded_ours || return 1
  # NEGATIVE CONTROL: the same read for a label nobody loaded must fail, or the pass above proves
  # only that launchctl printed something.
  microsoft365_archive_loaded_path "$MICROSOFT365_ARCHIVE_LABEL.no-such-job" >/dev/null 2>&1 && return 1
  # …and what launchd holds is THIS plist's content, not an older one it was loaded with before the
  # file changed: launchd runs its in-memory copy until the job is re-bootstrapped.
  microsoft365_archive_loaded_current || return 1

  # The wrapper executes, and the engine proves itself on THIS node against its offline fixtures —
  # the end-to-end run twice with a zero-byte second pass, the GET-only guard refusing a POST.
  microsoft365_archive_wrapper_ok "$node" || return 1
  microsoft365_archive_bounded "$node" 180000 "$(microsoft365_archive_wrapper)" --selftest >/dev/null 2>&1
}

gate_microsoft365_archive() {
  [ -n "$(microsoft365_archive_gate_reason)" ]
}

note_microsoft365_archive() {
  local r
  r="$(microsoft365_archive_gate_reason)"
  # The account gate is reported before the sandboxed-HOME one, but when both hold the line says so,
  # or the reader signs in, re-runs, and only then learns the job still will not load from here.
  case "$r" in account-*) microsoft365_archive_home_ok || {
    printf '%s Even then, this run has a sandboxed HOME, so the hourly job would not be loaded into your real launchd domain from it.' "$(microsoft365_archive_note_text "$r")"; return 0; } ;; esac
  microsoft365_archive_note_text "$r"
}

microsoft365_archive_note_text() {
  local r="$1"
  case "$r" in
    node)          printf 'the meeting archive runs on node 18 or later, and this Mac has none.' ;;
    server)        printf 'the meeting archive reads through the Microsoft 365 server, and the microsoft365 module has not installed it yet.' ;;
    relative-root) printf 'BOOTSTRAP_ARCHIVE_DIR must be an absolute path with no "." or ".." in it; "%s" is not.' "$(microsoft365_archive_root)" ;;
    cloud)         printf 'the archive folder %s is inside a folder a sync client uploads, and client meeting content must not be re-uploaded; choose a folder outside it.' "$(microsoft365_archive_short_path "$(microsoft365_archive_root)")" ;;
    root-in-engine) printf 'the archive folder %s is inside %s, which is this module'\''s own and is deleted by an uninstall; choose a folder outside it.' \
                     "$(microsoft365_archive_short_path "$(microsoft365_archive_root)")" "$(microsoft365_archive_short_path "$(microsoft365_archive_state_dir)")" ;;
    account-none)  printf 'no Microsoft account in tenant %s is signed in on this Mac, so the archive has no account to read as; sign in once, as the microsoft365 module asks.' "$(microsoft365_archive_tenant)" ;;
    account-many)  printf 'several Microsoft accounts in tenant %s are signed in (%s), and which one to archive is your call: re-run the bootstrap with BOOTSTRAP_MICROSOFT_ACCOUNT set to it.' \
                     "$(microsoft365_archive_tenant)" "$(microsoft365_archive_account_candidates "$(microsoft365_archive_node)" 2>/dev/null | awk 'NF' | paste -sd, - | sed 's/,/, /g')" ;;
    account-signed-out)
                   printf 'the archive reads as %s, and that account is not signed in on this Mac, so every hourly run would stop at sign-in; sign it in once (or name a signed-in account in BOOTSTRAP_MICROSOFT_ACCOUNT).' \
                     "$(microsoft365_archive_account "$(microsoft365_archive_node)" 2>/dev/null)" ;;
    foreign-home)  printf 'everything is installed, but this run has a sandboxed HOME ($HOME is not your real home) and launchctl ignores $HOME, so loading the hourly job would put it in your REAL launchd domain; nothing was loaded.' ;;
    label-taken)   printf 'launchd already runs a job named %s from another plist (%s), and replacing it is your call, not mine.' \
                     "$MICROSOFT365_ARCHIVE_LABEL" "$(microsoft365_archive_short_path "$(microsoft365_archive_loaded_path)")" ;;
    *)             printf 'the meeting archive engine, its wrapper, its hourly LaunchAgent and the archive folder are not all in place yet.' ;;
  esac
}

gesture_microsoft365_archive() {
  local node id pre
  case "$(microsoft365_archive_gate_reason)" in
    node)          printf 'brew install node' ;;
    server)        microsoft365_archive_rerun microsoft365 ;;
    relative-root|cloud|root-in-engine)
                   # shellcheck disable=SC2016   # $HOME is for the person's shell to expand
                   microsoft365_archive_rerun microsoft365_archive 'BOOTSTRAP_ARCHIVE_DIR="$HOME/Microsoft365Archive"' ;;
    account-none|account-signed-out)
      # microsoft365's own sign-in command, re-derived the way that module prints it.
      node="$(microsoft365_archive_node)" || return 0
      id="$(microsoft365_archive_client_id)"
      pre="MS365_MCP_TENANT_ID=$(microsoft365_archive_tenant)"
      [ -n "$id" ] && pre="$pre MS365_MCP_CLIENT_ID=$id"
      printf '%s "%s" "%s" --login' "$pre" "$(microsoft365_archive_short_path "$node")" \
        "$(microsoft365_archive_short_path "$(microsoft365_archive_server)")" ;;
    account-many)  : ;;   # the choice IS the step: a command with one account filled in would make it for you
    foreign-home)  microsoft365_archive_rerun microsoft365_archive ;;       # from your own account, with no HOME override
    label-taken)   printf 'launchctl bootout %s/%s' "$(microsoft365_archive_domain)" "$MICROSOFT365_ARCHIVE_LABEL" ;;
    *)             : ;;
  esac
}

install_microsoft365_archive() {
  local node dir root account written list src parts rel stage out rc tmp f lp i
  node="$(microsoft365_archive_node)" || { bootstrap_warn "microsoft365_archive: no node 18+ on this Mac"; return 1; }
  [ -f "$(microsoft365_archive_server)" ] || { bootstrap_warn "microsoft365_archive: the microsoft365 server is not installed"; return 1; }
  root="$(microsoft365_archive_root)"
  microsoft365_archive_root_shape_ok "$root" || { bootstrap_warn "microsoft365_archive: BOOTSTRAP_ARCHIVE_DIR must be an absolute path with no . or .. segment: $root"; return 1; }
  microsoft365_archive_under_cloud "$root" && { bootstrap_warn "microsoft365_archive: refusing an archive folder inside a synced folder: $root"; return 1; }
  microsoft365_archive_root_in_engine "$root" && { bootstrap_warn "microsoft365_archive: refusing an archive folder inside this module's own folder, which uninstall deletes: $root"; return 1; }
  dir="$(microsoft365_archive_dir)"
  mkdir -p "$dir" 2>/dev/null || { bootstrap_warn "microsoft365_archive: cannot create $dir"; return 1; }

  tmp="$(mktemp -t microsoft365archivechoice)" || return 1
  if [ -n "${BOOTSTRAP_ARCHIVE_DIR:-}" ]; then
    printf '%s\n' "$root" > "$tmp"; microsoft365_archive_land "$tmp" "$(microsoft365_archive_chosen_root_file)" 644
  fi
  if [ -n "${BOOTSTRAP_MICROSOFT_ACCOUNT:-}" ]; then
    printf '%s\n' "$BOOTSTRAP_MICROSOFT_ACCOUNT" > "$tmp"; microsoft365_archive_land "$tmp" "$(microsoft365_archive_chosen_account_file)" 644
  fi
  rm -f "$tmp" 2>/dev/null

  # ── the engine: staged whole, PROVEN on this node, and only then landed ──────────────────
  src="$(microsoft365_archive_source)" || { bootstrap_warn "microsoft365_archive: cannot find or fetch assets/microsoft365-archive"; return 1; }
  if [ "$src" = "${BOOTSTRAP_ASSETS:-}" ] && ! microsoft365_archive_manifest_agrees "$src"; then
    bootstrap_warn "microsoft365_archive: assets/microsoft365-archive/MANIFEST does not list exactly the files in that folder — a curl'd install would ship a different engine than this clone"
    return 1
  fi
  parts="$(microsoft365_archive_parts "$src")" || { bootstrap_warn "microsoft365_archive: the asset manifest is unreadable"; return 1; }
  stage="$(mktemp -d "$(microsoft365_archive_state_dir)/microsoft365-archive-stage.XXXXXX")" || return 1
  for rel in $parts; do
    mkdir -p "$(dirname "$stage/$rel")" 2>/dev/null && cp -f "$src/microsoft365-archive/$rel" "$stage/$rel" 2>/dev/null \
      || { rm -rf "$stage"; bootstrap_warn "microsoft365_archive: cannot stage $rel"; return 1; }
  done
  cp -f "$src/markdown-convert.sh" "$stage/markdown-convert.sh" 2>/dev/null || { rm -rf "$stage"; return 1; }
  out="$(microsoft365_archive_bounded "$node" 20000 "$node" "$stage/archive.js" --version 2>/dev/null)" || out=""
  [ "$out" = "$MICROSOFT365_ARCHIVE_VERSION_LINE" ] || {
    rm -rf "$stage"; bootstrap_warn "microsoft365_archive: the engine answered --version with \"$out\" — not installing it"; return 1; }
  microsoft365_archive_bounded "$node" 180000 "$node" "$stage/archive.js" --selftest >&2 || {
    rm -rf "$stage"; bootstrap_warn "microsoft365_archive: the engine failed its selftest on $node — not installing it"; return 1; }
  for rel in $parts; do
    microsoft365_archive_land "$stage/$rel" "$dir/$rel" 644 || { rm -rf "$stage"; bootstrap_warn "microsoft365_archive: cannot install $rel"; return 1; }
  done
  microsoft365_archive_land "$stage/markdown-convert.sh" "$(microsoft365_archive_converter)" 755 || { rm -rf "$stage"; return 1; }
  rm -rf "$stage" 2>/dev/null
  # A fixture a newer release dropped must not linger and change what the selftest reads.
  if [ -d "$dir/fixtures" ]; then
    while IFS= read -r f; do
      case "
$parts
" in *"
$f
"*) : ;; *) rm -f "$dir/$f" 2>/dev/null ;; esac
    done <<EOF
$(cd "$dir" && find fixtures -type f 2>/dev/null)
EOF
  fi
  # Fetched sets of other pins are dead weight once this one is installed.
  if [ -d "$dir/.fetched" ]; then
    for f in "$dir/.fetched"/*; do
      [ -e "$f" ] || continue
      [ "${f##*/}" = "${BOOTSTRAP_PIN:-}" ] || rm -rf "$f" 2>/dev/null
    done
  fi

  # ── the archive folder, then the generated files ─────────────────────────────────────────
  # The folder first, and judged again once it EXISTS (its real path is then fully resolved), before
  # any config names it or any job is loaded to write into it.
  mkdir -p "$root" 2>/dev/null || { bootstrap_warn "microsoft365_archive: cannot create the archive folder $root"; return 1; }
  if microsoft365_archive_under_cloud "$root" || microsoft365_archive_root_in_engine "$root"; then
    bootstrap_warn "microsoft365_archive: the archive folder $root resolves inside a synced folder or this module's own — not using it"; return 1
  fi
  list="$(microsoft365_archive_account_candidates "$node" 2>/dev/null)" || list=""
  account="$(microsoft365_archive_account_from "$list")" || account=""
  # With no account to name this run (every account signed out, or several and none chosen), the
  # config keeps the one it already holds: rewriting a working config without account= would stop the
  # loaded hourly job for good, while the held account may simply sign back in.
  written="$account"
  [ -n "$written" ] || written="$(microsoft365_archive_held_account)"
  tmp="$(mktemp -t microsoft365archivegen)" || return 1
  microsoft365_archive_wrapper_text "$node" > "$tmp"
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_wrapper)" 755 || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: cannot write the wrapper"; return 1; }
  microsoft365_archive_config_text "$node" "$written" > "$tmp"
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_config)" 644 || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: cannot write the config"; return 1; }
  rm -f "$tmp" 2>/dev/null

  tmp="$(mktemp -t microsoft365archiveplist)" || return 1
  microsoft365_archive_plist_build "$tmp" || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: plutil could not build the LaunchAgent"; return 1; }
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_plist)" 644 || { rm -f "$tmp"; bootstrap_warn "microsoft365_archive: cannot write the LaunchAgent"; return 1; }
  rm -f "$tmp" 2>/dev/null
  microsoft365_archive_plist_ok || { bootstrap_warn "microsoft365_archive: the LaunchAgent does not read back as written"; return 1; }

  # Everything reversible is done. What remains is a gate the installer has now DISCOVERED: return
  # non-zero and the driver re-asks gate_, which reports it as NEEDS_HUMAN.
  [ -n "$account" ] || return 3
  microsoft365_archive_signed_in "$account" "$list" || return 3
  microsoft365_archive_home_ok || return 3
  microsoft365_archive_label_taken && return 3

  # ── launchd: re-load when what it holds is not THIS plist, load when it is not loaded ─────────
  # "What it holds" is the sha256 recorded after the last successful load — not whether this run
  # happened to rewrite the file: a run that landed a new plist and then stopped at a gate would
  # otherwise leave launchd on the old definition for good, since the next run finds the file current.
  if microsoft365_archive_loaded_ours && ! microsoft365_archive_loaded_current; then
    /bin/launchctl bootout "$(microsoft365_archive_domain)/$MICROSOFT365_ARCHIVE_LABEL" >/dev/null 2>&1
    i=0
    while microsoft365_archive_loaded_ours && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
  fi
  if ! microsoft365_archive_loaded_ours; then
    # A bootstrap straight after a bootout can race launchd's teardown (EIO), so it is retried.
    i=0; rc=1
    while [ "$i" -lt 5 ]; do
      /bin/launchctl bootstrap "$(microsoft365_archive_domain)" "$(microsoft365_archive_plist)" >/dev/null 2>&1; rc=$?
      [ "$rc" = 0 ] && break
      microsoft365_archive_loaded_ours && { rc=0; break; }
      i=$((i + 1)); sleep 1
    done
    [ "$rc" = 0 ] || { bootstrap_warn "microsoft365_archive: launchctl bootstrap failed (rc $rc)"; return 1; }
  fi
  lp="$(microsoft365_archive_loaded_path)" || lp=""
  microsoft365_archive_loaded_ours || { bootstrap_warn "microsoft365_archive: launchd does not hold the job from our plist (it reports: ${lp:-nothing})"; return 1; }
  tmp="$(mktemp -t microsoft365archiveloaded)" || return 1
  microsoft365_archive_plist_sha > "$tmp" && printf '\n' >> "$tmp"
  microsoft365_archive_land "$tmp" "$(microsoft365_archive_loaded_marker)" 644 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp" 2>/dev/null
  return 0
}

# uninstall_ unloads the job (only one loaded from OUR plist — a job another HOME loaded under the
# same label is not ours to stop), and removes the plist, the wrapper and the engine directory.
# It NEVER deletes the archive folder: that is the user's data — meeting transcripts and notes that
# may no longer exist at Microsoft — and removing a tool must never remove what the tool collected.
uninstall_microsoft365_archive() {
  local rc=0 i dir f
  if microsoft365_archive_loaded_ours; then
    /bin/launchctl bootout "$(microsoft365_archive_domain)/$MICROSOFT365_ARCHIVE_LABEL" >/dev/null 2>&1
    i=0
    while microsoft365_archive_loaded_ours && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
    microsoft365_archive_loaded_ours && { bootstrap_warn "microsoft365_archive: launchd still holds the job after bootout"; rc=1; }
  fi
  rm -f "$(microsoft365_archive_plist)" "$(microsoft365_archive_wrapper)" 2>/dev/null
  dir="$(microsoft365_archive_dir)"
  if microsoft365_archive_root_in_engine "$(microsoft365_archive_root)"; then
    # The archive folder was put INSIDE the engine folder (install refuses that now; an older one did
    # not). The folder cannot go without the archive going with it, so only this module's own files
    # are removed, by name, and the folder is left holding the archive.
    for f in $MICROSOFT365_ARCHIVE_ENGINE_FILES package.json MANIFEST markdown-convert.sh config chosen-account \
             chosen-archive-dir launchd.log loaded-plist.sha256; do
      rm -f "$dir/$f" 2>/dev/null
    done
    rm -rf "$dir/fixtures" "$dir/.fetched" 2>/dev/null
    bootstrap_warn "microsoft365_archive: $dir holds the archive folder $(microsoft365_archive_root), so only the engine's own files were removed from it"
    for f in $MICROSOFT365_ARCHIVE_ENGINE_FILES config; do [ -e "$dir/$f" ] && rc=1; done
  else
    rm -rf "$dir" 2>/dev/null
    [ -e "$dir" ] && rc=1
  fi
  [ -e "$(microsoft365_archive_plist)" ] && rc=1
  [ -e "$(microsoft365_archive_wrapper)" ] && rc=1
  return "$rc"
}
