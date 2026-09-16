# shellcheck shell=bash
# browser_automation — the agent-browser CLI, so an agent can navigate, fill, screenshot and extract.
#
# WHAT LANDS: one pinned npm package (agent-browser, zero dependencies) in a module-private prefix
# under $BOOTSTRAP_STATE_DIR, plus a small launcher at $HOME/.local/bin — the same bin directory
# agent_cli already puts on a login shell's PATH, which is why this module declares needs_ on it.
# Nothing global, no sudo, nothing outside $HOME.
#
# WHAT DOES NOT LAND: a browser. This module installs none and downloads none — a browser on a
# corporate Mac is IT's to distribute, and Chrome's own installer is a GUI drag into /Applications
# that a standard user cannot make. So a Mac with no Chromium-family browser is NEEDS_HUMAN with the
# gesture named in plain English: ask IT for Chrome. Automation cannot run without one; there is
# nothing for the CLI to drive.
#
# WHY THE NATIVE BINARY IS RUN DIRECTLY: the npm package ships prebuilt binaries for both Macs and
# its own bin/agent-browser.js does nothing but spawn the one for this CPU (read from its source).
# Running that file ourselves means node is needed to INSTALL and never to RUN, so the package's
# engines.node ">=24" — which governs only the launcher we do not use — cannot strand this module on
# a Mac whose node is older. npm is called with --ignore-scripts for the same reason it is called at
# all: the package's postinstall exists to fetch a binary the tarball already carries, from a THIRD
# host (github.com), and to rewrite npm's own bin shims. Neither is wanted, so neither runs, and
# --egress below has one install host instead of two. The exec bit npm drops is set here instead.
#
# WHICH BROWSER IT DRIVES: the CLI's own search looks only in /Applications and does not know about
# Edge (both read out of the shipped binary). A corporate Mac often has Edge, and a standard user
# installs into $HOME/Applications. So this module detects the browser itself, records the executable
# it found, and the launcher passes it as AGENT_BROWSER_EXECUTABLE_PATH — the CLI's own documented
# variable — unless the caller names one. "The browser this module will drive" is therefore one
# recorded fact that verify_ reads back, not a guess about a search order.
#
# No permission, no credential, no allow-list keypath is written here.

BROWSER_AUTOMATION_PACKAGE="agent-browser"
BROWSER_AUTOMATION_VERSION="0.37.1"

# node is needed only to run npm. The floor is npm's, not the package's: 20 is the oldest LTS whose
# npm installs a dependency-free package unchanged. The pinned build is the same version, from the
# same host, under the same sha256s as microsoft365 pins, linked into the same $(bootstrap_tools_dir)
# — so on a Mac where either module has already fetched node, the other fetches nothing.
BROWSER_AUTOMATION_NODE_FLOOR=20
BROWSER_AUTOMATION_NODE_VERSION="24.21.0"
BROWSER_AUTOMATION_NODE_SHA256_ARM64="6239d4cf92d864487ec8cd3615038f7b67e7f58b77b21cd2f09ea9fbd68065fe"
BROWSER_AUTOMATION_NODE_SHA256_X64="0ae5a24c24bb7d015cd816c5036b3f90f2945aa872fcf54e58da054753b3a299"
BROWSER_AUTOMATION_NODE_MIN_MACOS="13.5"

# The Chromium-family browsers this module will drive, in preference order, one .app name per line.
# Each one's executable is Contents/MacOS/<the name without .app> (checked on all five). Safari is
# absent on purpose: it speaks WebDriver, not the DevTools protocol this CLI uses.
BROWSER_AUTOMATION_BROWSERS='Google Chrome.app
Microsoft Edge.app
Chromium.app
Brave Browser.app
Google Chrome Canary.app'

browser_automation_dir()      { printf '%s/browser-automation' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
browser_automation_pkg()      { printf '%s/node_modules/%s' "$(browser_automation_dir)" "$BROWSER_AUTOMATION_PACKAGE"; }
browser_automation_record()   { printf '%s/browser' "$(browser_automation_dir)"; }
browser_automation_launcher() { printf '%s/.local/bin/%s' "$HOME" "$BROWSER_AUTOMATION_PACKAGE"; }

# nodejs.org's and the package's shared name for this Mac's CPU. Apple silicon is asked of the
# kernel, because a shell running under Rosetta answers x86_64 to uname.
browser_automation_arch() {
  [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && { printf 'arm64'; return 0; }
  [ "$(/usr/bin/uname -m 2>/dev/null)" = x86_64 ] && { printf 'x64'; return 0; }
  return 1
}
browser_automation_binary() {
  local a; a="$(browser_automation_arch)" || return 1
  printf '%s/bin/%s-darwin-%s' "$(browser_automation_pkg)" "$BROWSER_AUTOMATION_PACKAGE" "$a"
}

# ── the browser ──────────────────────────────────────────────────────────────────────────────
# browser_automation_detect — the executable of the first Chromium-family browser this Mac has, or
# rc 1. bootstrap_find_app covers both /Applications and $HOME/Applications, where a standard user
# can install; the CLI's own search covers neither fully, which is why the answer is recorded.
browser_automation_detect() {
  local out
  out="$(printf '%s\n' "$BROWSER_AUTOMATION_BROWSERS" | while IFS= read -r app; do
      [ -n "$app" ] || continue
      p="$(bootstrap_find_app "$app" 2>/dev/null)" || continue
      [ -x "$p/Contents/MacOS/${app%.app}" ] && { printf '%s/Contents/MacOS/%s' "$p" "${app%.app}"; break; }
    done)"
  [ -n "$out" ] && printf '%s' "$out"
}

# browser_automation_known <executable> — rc 0 iff that path is one of the browsers above, present
# and executable now. The read-back for the recorded choice: a record naming something this module
# would never have chosen, or a browser since removed, must not pass as satisfied.
browser_automation_known() {
  local want="$1" hit
  [ -n "$want" ] && [ -x "$want" ] || return 1
  # A [ ] test, not a case: a case pattern's own ")" closes the enclosing $( ) at parse time, and
  # neither `bash -n` nor shellcheck reports it — the substitution is parsed when it is run.
  hit="$(printf '%s\n' "$BROWSER_AUTOMATION_BROWSERS" | while IFS= read -r app; do
      [ -n "$app" ] || continue
      [ "${want##*/}" = "${app%.app}" ] && { printf yes; break; }
    done)"
  [ "$hit" = yes ]
}
browser_automation_recorded() {
  local f b; f="$(browser_automation_record)"
  [ -s "$f" ] || return 1
  IFS= read -r b < "$f" 2>/dev/null || return 1
  [ -n "$b" ] && printf '%s' "$b"
}

# ── node ─────────────────────────────────────────────────────────────────────────────────────
# A node at or above the floor whose path SURVIVES a node upgrade: fnm's per-shell path disappears
# with the shell. The library's search comes first; the fixed list after it is there because that
# search stops at its first hit, and a first hit below the floor must not hide a usable node.
browser_automation_node_ok() {
  local c="$1" major
  [ -n "$c" ] && [ -x "$c" ] || return 1
  case "$c" in */fnm_multishells/*) return 1 ;; esac
  major="$("$c" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge "$BROWSER_AUTOMATION_NODE_FLOOR" ]
}
browser_automation_node() {
  local c
  for c in "$(bootstrap_find_tool node 2>/dev/null)" "$(bootstrap_tools_dir)/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node \
           "$HOME/Library/Application Support/fnm/aliases/default/bin/node" \
           "$(command -v node 2>/dev/null)"; do
    browser_automation_node_ok "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}
browser_automation_macos_ok() {
  local v major minor
  v="$(/usr/bin/sw_vers -productVersion 2>/dev/null)" || return 1
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  case "$major$minor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -gt 13 ] || { [ "$major" = 13 ] && [ "$minor" -ge 5 ]; }
}
# A fetch that failed is recorded with the DRIVER's pid — every verb of one run is a subshell of it,
# so $$ is the same in all of them — and only that run's gate_ reports it. A later run tries again.
browser_automation_node_marker() { printf '%s/node-fetch-failed' "$(browser_automation_dir)"; }
browser_automation_node_blocked() {
  local m pid why
  browser_automation_node >/dev/null 2>&1 && return 1
  browser_automation_macos_ok || { printf 'macos-old'; return 0; }
  browser_automation_arch >/dev/null || { printf 'no-build'; return 0; }
  m="$(browser_automation_node_marker)"
  [ -s "$m" ] || return 1
  read -r pid why < "$m" 2>/dev/null || return 1
  [ "$pid" = "$$" ] || return 1
  printf '%s' "${why:-not-fetched}"
}
# The pinned node into $(bootstrap_tools_dir), linked as tools/bin/node and tools/bin/npm — the same
# layout and the same links microsoft365 writes, so the two modules share one copy. Verified by
# EXECUTING it, never by tar's rc.
browser_automation_node_fetch() {
  local arch sha home tools tarball stage rc m
  tools="$(bootstrap_tools_dir)"; m="$(browser_automation_node_marker)"
  mkdir -p "$(browser_automation_dir)" "$tools/bin" 2>/dev/null || return 1
  browser_automation_macos_ok || { printf '%s macos-old\n' "$$" > "$m"; return 1; }
  arch="$(browser_automation_arch)" || { printf '%s no-build\n' "$$" > "$m"; return 1; }
  case "$arch" in arm64) sha="$BROWSER_AUTOMATION_NODE_SHA256_ARM64" ;; *) sha="$BROWSER_AUTOMATION_NODE_SHA256_X64" ;; esac
  home="$tools/node-v$BROWSER_AUTOMATION_NODE_VERSION-darwin-$arch"
  if [ "$("$home/bin/node" --version 2>/dev/null)" != "v$BROWSER_AUTOMATION_NODE_VERSION" ]; then
    tarball="$tools/.node-v$BROWSER_AUTOMATION_NODE_VERSION-darwin-$arch.tar.xz"
    bootstrap_fetch_pinned "https://nodejs.org/dist/v$BROWSER_AUTOMATION_NODE_VERSION/node-v$BROWSER_AUTOMATION_NODE_VERSION-darwin-$arch.tar.xz" \
      "$sha" "$tarball"; rc=$?
    case "$rc" in
      0) : ;;
      2) printf '%s refused\n' "$$" > "$m"; return 1 ;;
      *) printf '%s not-fetched\n' "$$" > "$m"; return 1 ;;
    esac
    stage="$tools/.node-stage.$$"
    rm -rf "$stage"; mkdir -p "$stage" 2>/dev/null || { rm -f "$tarball"; return 1; }
    /usr/bin/tar -xf "$tarball" -C "$stage" 2>/dev/null
    rm -f "$tarball"
    [ "$("$stage/${home##*/}/bin/node" --version 2>/dev/null)" = "v$BROWSER_AUTOMATION_NODE_VERSION" ] || {
      rm -rf "$stage"; printf '%s not-fetched\n' "$$" > "$m"
      bootstrap_warn "browser_automation: the node $BROWSER_AUTOMATION_NODE_VERSION archive unpacked, but its node does not run"; return 1; }
    rm -rf "$home"; mv -f "$stage/${home##*/}" "$home" 2>/dev/null || { rm -rf "$stage"; return 1; }
    rm -rf "$stage"
  fi
  ln -sfn "../${home##*/}/bin/node" "$tools/bin/node" && ln -sfn "../${home##*/}/bin/npm" "$tools/bin/npm" || return 1
  [ "$("$tools/bin/node" -p 'process.versions.node' 2>/dev/null)" = "$BROWSER_AUTOMATION_NODE_VERSION" ] || return 1
  rm -f "$m" 2>/dev/null
  return 0
}

# ── TLS ──────────────────────────────────────────────────────────────────────────────────────
# Behind a TLS-inspecting proxy npm fails with UNABLE_TO_GET_ISSUER_CERT_LOCALLY, because node ships
# its own roots and ignores the keychain. bootstrap_node_ca_env answers, per host, with the variable
# that fixes it; a root the OS does NOT trust is IT's to install and nothing here can proceed.
# Loaded ONCE per verb (never inside $(…), whose subshell would forget it): each probe is two
# requests. BOOTSTRAP_TLS_PROBE_URL replaces the hosts, as a test seam.
BROWSER_AUTOMATION_TLS_LOADED=""; BROWSER_AUTOMATION_TLS_VAR=""; BROWSER_AUTOMATION_TLS_RC=1
browser_automation_tls_load() {
  local urls u out rc known=1 untrusted=0
  [ -n "$BROWSER_AUTOMATION_TLS_LOADED" ] && return 0
  if [ -n "${BOOTSTRAP_TLS_PROBE_URL:-}" ]; then urls="$BOOTSTRAP_TLS_PROBE_URL"
  else
    urls="https://registry.npmjs.org/"
    browser_automation_node >/dev/null 2>&1 || urls="$urls https://nodejs.org/"
  fi
  BROWSER_AUTOMATION_TLS_VAR=""
  for u in $urls; do
    out="$(bootstrap_node_ca_env "$u" 2>/dev/null)"; rc=$?
    case "$rc" in
      0) known=0; [ -n "$out" ] && BROWSER_AUTOMATION_TLS_VAR="$out" ;;
      2) untrusted=1 ;;
    esac
  done
  BROWSER_AUTOMATION_TLS_RC="$known"; [ "$untrusted" = 1 ] && BROWSER_AUTOMATION_TLS_RC=2
  BROWSER_AUTOMATION_TLS_LOADED=1
}
browser_automation_tls_untrusted() { browser_automation_tls_load; [ "$BROWSER_AUTOMATION_TLS_RC" = 2 ]; }
# The PEM npm is started with, or nothing: the one this network needs now, else one an earlier run
# exported. It STAYS once exported, and holds only roots the OS itself trusts, so it trusts nothing new.
browser_automation_ca_path() {
  local pem
  browser_automation_tls_load
  [ -n "$BROWSER_AUTOMATION_TLS_VAR" ] && { printf '%s' "${BROWSER_AUTOMATION_TLS_VAR#NODE_EXTRA_CA_CERTS=}"; return 0; }
  pem="${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}/trusted-roots.pem"
  [ -s "$pem" ] && printf '%s' "$pem"
  return 0
}

# ── the launcher ─────────────────────────────────────────────────────────────────────────────
# A /bin/sh script, not a symlink: it has to name the browser. The recorded browser is READ at run
# time rather than baked in, so the record is the single source of truth and re-recording needs no
# rewrite. A caller that names its own browser keeps it.
browser_automation_launcher_write() {
  local f bin rec
  bin="$(browser_automation_binary)" || return 1
  rec="$(browser_automation_record)"; f="$(browser_automation_launcher)"
  # Single quotes hold both paths; a $HOME with a quote in it would break out of them, so refuse.
  case "$bin$rec" in *"'"*) bootstrap_warn "browser_automation: a path holds a single quote; no launcher was written"; return 1 ;; esac
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  cat > "$f.mac-bootstrap-tmp.$$" <<EOF || { rm -f "$f.mac-bootstrap-tmp.$$"; return 1; }
#!/bin/sh
# $BROWSER_AUTOMATION_PACKAGE $BROWSER_AUTOMATION_VERSION — installed by mac-bootstrap (browser_automation).
# Runs the pinned native binary directly; the package's own node launcher only spawns this same file.
# The browser is the Chromium-family one this Mac was found to have, unless you name another.
if [ -z "\${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && [ -s '$rec' ]; then
  AGENT_BROWSER_BROWSER=\$(cat '$rec')
  if [ -x "\$AGENT_BROWSER_BROWSER" ]; then
    AGENT_BROWSER_EXECUTABLE_PATH="\$AGENT_BROWSER_BROWSER"
    export AGENT_BROWSER_EXECUTABLE_PATH
  fi
  unset AGENT_BROWSER_BROWSER
fi
exec '$bin' "\$@"
EOF
  chmod 755 "$f.mac-bootstrap-tmp.$$" 2>/dev/null || { rm -f "$f.mac-bootstrap-tmp.$$"; return 1; }
  mv -f "$f.mac-bootstrap-tmp.$$" "$f" 2>/dev/null || { rm -f "$f.mac-bootstrap-tmp.$$"; return 1; }
}
# Ours by content: a launcher of someone else's that happens to share the name is never removed.
browser_automation_launcher_ours() { grep -q "mac-bootstrap (browser_automation)" "$(browser_automation_launcher)" 2>/dev/null; }

# ── the catalog ──────────────────────────────────────────────────────────────────────────────
what_browser_automation() {
  printf 'the agent-browser CLI, so an agent can open a page, click, fill a form, take a screenshot and read the page back — driving %s' \
    "$(browser_automation_detect >/dev/null 2>&1 && printf 'the %s this Mac already has' "$(browser_automation_browser_name)" || printf 'a Chromium-family browser (Chrome, Edge, Chromium or Brave), which it does NOT install')"
}
browser_automation_browser_name() {
  local b; b="$(browser_automation_detect)" || { printf 'browser'; return 0; }
  b="${b##*/}"; printf '%s' "$b"
}
cost_browser_automation() {
  printf '~60 MB, under a minute. No admin, no sudo, no permission prompt. It installs NO browser: without Chrome, Edge, Chromium or Brave already on this Mac there is nothing to drive, and that is a step for IT'
  browser_automation_node >/dev/null 2>&1 || printf '. This Mac has no node %s or later, so it first fetches node %s from nodejs.org into $HOME/.mac-bootstrap (checked against its pinned sha256; no Homebrew, no admin)' \
    "$BROWSER_AUTOMATION_NODE_FLOOR" "$BROWSER_AUTOMATION_NODE_VERSION"
}
# Opt-in: an agent that can drive the browser holding your logged-in sessions is not something a
# person should receive without having asked for it.
profile_browser_automation() { printf 'full'; }
# agent_cli is what puts $HOME/.local/bin — where the launcher goes — on a login shell's PATH.
needs_browser_automation()   { printf 'agent_cli'; }

egress_browser_automation() {
  printf '%s\n' \
    "registry.npmjs.org install $BROWSER_AUTOMATION_PACKAGE@$BROWSER_AUTOMATION_VERSION, one package with no dependencies (its postinstall, which would also fetch from github.com, is not run)" \
    "nodejs.org install node $BROWSER_AUTOMATION_NODE_VERSION, pinned by sha256, only when this Mac has no node $BROWSER_AUTOMATION_NODE_FLOOR or later" \
    'any-page-you-open run the CLI itself calls nothing; the browser it drives reaches exactly the hosts of whatever page the person or the agent tells it to open, and this module cannot bound that list'
}
clearance_browser_automation() {
  printf '%s\n' \
    "software the $BROWSER_AUTOMATION_PACKAGE CLI from the npm registry, and a node from nodejs.org when this Mac has none — neither distributed by IT" \
    'agent an agent drives a real Chromium browser on this Mac. With --profile, --auto-connect or a saved session it drives the person'"'"'s OWN profile, carrying their live logged-in sessions — corporate mail, the intranet, anything they are signed into — to whatever page the agent is told to open, and it can read and type there as they can. Nothing here limits which sites; --allowed-domains does, per run, and only when the person passes it'
}

# ── the contract ─────────────────────────────────────────────────────────────────────────────
# Read back by EXECUTING what was installed and parsing what it prints — never by npm's rc and never
# by looking for a string we wrote. The CLI exits 0 on an unknown command (measured), so only the
# printed version proves anything.
verify_browser_automation() {
  local bin f b
  bin="$(browser_automation_binary)" || return 1
  [ -x "$bin" ] || return 1
  f="$(browser_automation_launcher)"
  [ -x "$f" ] || return 1
  [ "$("$f" --version 2>/dev/null)" = "$BROWSER_AUTOMATION_PACKAGE $BROWSER_AUTOMATION_VERSION" ] || return 1
  # The browser this module will drive is the one it recorded, it is still one of the browsers this
  # module knows, and it runs: asked of the browser itself, which prints its name and version.
  b="$(browser_automation_recorded)" || return 1
  browser_automation_known "$b" || return 1
  case "$("$b" --version 2>/dev/null)" in *[0-9].[0-9]*) return 0 ;; esac
  return 1
}

gate_browser_automation() {
  browser_automation_tls_load
  browser_automation_tls_untrusted && return 0
  browser_automation_node_blocked >/dev/null && return 0
  browser_automation_detect >/dev/null 2>&1 || return 0
  return 1
}

note_browser_automation() {
  local why
  browser_automation_tls_load
  if browser_automation_tls_untrusted; then
    printf 'your network intercepts TLS with a certificate this Mac does not trust, so npm cannot be reached; ask IT to install that certificate on this Mac.'
    return 0
  fi
  if why="$(browser_automation_node_blocked)"; then
    case "$why" in
      macos-old) printf 'installing the agent-browser CLI needs node, and the node build this module fetches needs macOS %s or later; update macOS, or ask IT for node.' "$BROWSER_AUTOMATION_NODE_MIN_MACOS" ;;
      no-build)  printf 'installing the agent-browser CLI needs node, and nodejs.org has no build for this processor; ask IT for node.' ;;
      refused)   printf 'node %s was downloaded from nodejs.org, but its sha256 is not the one this release pins, so it was thrown away: something between this Mac and nodejs.org changed it. Try again on another network, or ask IT.' "$BROWSER_AUTOMATION_NODE_VERSION" ;;
      *)         printf 'node %s could not be downloaded from nodejs.org (a proxy or firewall may block it), and this Mac has no node %s or later; run this again once nodejs.org is reachable, or ask IT to allow it.' "$BROWSER_AUTOMATION_NODE_VERSION" "$BROWSER_AUTOMATION_NODE_FLOOR" ;;
    esac
    return 0
  fi
  if ! browser_automation_detect >/dev/null 2>&1; then
    printf 'this Mac has no Chromium-family browser, and browser automation cannot run without one — there is nothing for the CLI to drive. Ask IT to install Google Chrome (Microsoft Edge, Chromium or Brave do just as well); installing one is a drag into /Applications, which is why it is not done here.'
    return 0
  fi
  printf 'the agent-browser CLI is not installed yet.'
}

# One resolved command or nothing. A browser is a GUI install into /Applications: there is no
# command that does it, and offering one that does not run is worse than offering none.
gesture_browser_automation() {
  local why brew entry
  browser_automation_tls_load
  browser_automation_tls_untrusted && return 0
  if why="$(browser_automation_node_blocked)"; then
    case "$why" in
      refused|not-fetched)
        if bootstrap_is_admin && brew="$(bootstrap_find_tool brew)"; then printf '"%s" install node'  "$brew"; return 0; fi
        entry="${BOOTSTRAP_ENTRY:-}"
        case "$entry" in ''|*'"'*|*'$'*|*'`'*|*'\'*) return 0 ;; esac
        case "$entry" in "$HOME"/*) entry="\$HOME/${entry#"$HOME"/}" ;; esac
        printf 'bash "%s" --only browser_automation' "$entry" ;;
    esac
    return 0
  fi
  return 0
}

install_browser_automation() {
  local node dir npm bin ca b
  browser_automation_tls_load
  browser_automation_tls_untrusted && { bootstrap_warn "browser_automation: TLS to the npm registry is intercepted by a certificate this Mac does not trust"; return 1; }
  if ! node="$(browser_automation_node)"; then
    browser_automation_node_fetch || { bootstrap_warn "browser_automation: no node $BROWSER_AUTOMATION_NODE_FLOOR+ on this Mac, and node $BROWSER_AUTOMATION_NODE_VERSION could not be fetched"; return 1; }
    node="$(browser_automation_node)" || { bootstrap_warn "browser_automation: node $BROWSER_AUTOMATION_NODE_VERSION was fetched but is not found"; return 1; }
  fi
  dir="$(browser_automation_dir)"
  mkdir -p "$dir" 2>/dev/null || { bootstrap_warn "browser_automation: cannot create $dir"; return 1; }
  bin="$(browser_automation_binary)" || { bootstrap_warn "browser_automation: nodejs.org and npm have no build for this processor"; return 1; }

  if [ "$("$bin" --version 2>/dev/null)" != "$BROWSER_AUTOMATION_PACKAGE $BROWSER_AUTOMATION_VERSION" ]; then
    # npm beside the node we chose, with that node first on PATH (npm's own shebang is `env node`).
    # The cache lives inside $dir and is dropped afterwards, so nothing lands in $HOME/.npm. Behind an
    # inspecting proxy it gets the CA file too — never npm's --cafile, which REPLACES node's roots.
    # --engine-strict=false: the package declares engines.node >=24 for a launcher this module does
    # not use, and a company .npmrc that turns engine-strict on would otherwise refuse the install.
    npm="$(dirname "$node")/npm"
    [ -x "$npm" ] || { bootstrap_warn "browser_automation: no npm beside $node"; return 1; }
    ca="$(browser_automation_ca_path)"
    set -- PATH="$(dirname "$node"):$PATH"
    [ -n "$ca" ] && set -- "$@" NODE_EXTRA_CA_CERTS="$ca"
    /usr/bin/env "$@" "$npm" install --prefix "$dir" --cache "$dir/.npm-cache" \
      --ignore-scripts --engine-strict=false --no-fund --no-audit --no-update-notifier --omit=dev \
      "$BROWSER_AUTOMATION_PACKAGE@$BROWSER_AUTOMATION_VERSION" >&2 \
      || { bootstrap_warn "browser_automation: npm install of $BROWSER_AUTOMATION_PACKAGE@$BROWSER_AUTOMATION_VERSION failed"; return 1; }
    rm -rf "$dir/.npm-cache" 2>/dev/null
    # npm drops the exec bit the package's own postinstall would have restored; this module does it.
    [ -f "$bin" ] || { bootstrap_warn "browser_automation: $BROWSER_AUTOMATION_PACKAGE@$BROWSER_AUTOMATION_VERSION carries no build for this processor"; return 1; }
    chmod 755 "$bin" 2>/dev/null
    [ "$("$bin" --version 2>/dev/null)" = "$BROWSER_AUTOMATION_PACKAGE $BROWSER_AUTOMATION_VERSION" ] \
      || { bootstrap_warn "browser_automation: installed, but the CLI does not report $BROWSER_AUTOMATION_VERSION"; return 1; }
  fi

  # Record the browser BEFORE the launcher, so a launcher never exists naming a record that does not.
  if b="$(browser_automation_detect)"; then printf '%s\n' "$b" > "$(browser_automation_record)"; fi
  browser_automation_launcher_write || { bootstrap_warn "browser_automation: could not write $(browser_automation_launcher)"; return 1; }
  # No browser is a gate the driver reports, not a failure of the install: return non-zero and it re-asks gate_.
  browser_automation_detect >/dev/null 2>&1 || return 3
  return 0
}

# The module-private prefix and the launcher this module wrote. NOT the node in tools/ — microsoft365
# shares that copy — and never the browser, which is the person's or IT's.
uninstall_browser_automation() {
  local rc=0
  if browser_automation_launcher_ours; then rm -f "$(browser_automation_launcher)" 2>/dev/null || rc=1; fi
  rm -rf "$(browser_automation_dir)" 2>/dev/null || rc=1
  return "$rc"
}
