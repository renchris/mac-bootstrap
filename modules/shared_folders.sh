#!/bin/bash
# shared_folders — a client's shared OneDrive or SharePoint folder, reachable from any repo as a
# plain path, with read-only markdown views beside it, and no copy of its own that can drift.
#
# WHAT THIS INSTALLS
#   $BOOTSTRAP_STATE_DIR/bin/shared-folder                   the CLI: add | remove | check | relink |
#                                                            refresh | list
#   $BOOTSTRAP_STATE_DIR/shared-folders/markdown-convert.sh  the converter the views are built with
#   $BOOTSTRAP_STATE_DIR/shared-folders/links                the record: one line per link,
#                                                            `<link-path>\t<relative-path>[\t<web url>]`
#
# WHY A SYMLINK INTO THE SYNC CLIENT'S OWN COPY, AND NOT A MIRROR. The OneDrive app's File Provider
# replica under $HOME/Library/CloudStorage IS the synced source of truth: two-way, push-fed and
# already signed in. Any tool that COPIES it (rclone, a Graph download loop) is a second copy that
# drifts and a second credential store. A symlink adds no copy. The markdown views ARE copies, which
# is exactly why each one records the source's size, mtime and sha256 and is regenerated from them.
#
# WHY THE LINK TARGET IS RE-RESOLVED ON EVERY COMMAND. The root's name embeds the organisation's
# display name (`OneDrive-Contoso`), so it moves on a tenant rename and on the sync-engine upgrade
# that gives each library its own root. The record therefore stores the path RELATIVE to the root,
# never the absolute target, and install_ runs `relink` so a renamed root is followed on every run.
#
# WHAT THIS MODULE NEVER DOES
#   * It never writes inside $HOME/Library/CloudStorage. Anything written there is uploaded to the
#     client's SharePoint, and a delete there deletes the client's file. uninstall_ removes only the
#     symlinks it recorded (`test -L`, then `rm` of the link itself), never a link's target.
#   * It never performs the sync gesture. Adding a folder to OneDrive ("Add shortcut to My files",
#     or the Sync button on a client's site) is the human's; this module reports it as the gate.
#   * It never writes permissions, allowlists or credentials. The deny rule that stops an agent
#     editing through the link (`Edit(~/Library/CloudStorage/**)`) is the operator's to add in chat.
#   * It never reaches a network. The OneDrive app does the syncing; the converter runs pandoc only
#     sandboxed and markitdown only when it cannot transcribe audio (see markdown-convert.sh), and our
#     own scripts come from the verified release tree the driver unpacked, never from a fetch.
#   * It never lets git see a link or its views: a link inside a work tree has `/<link>` and
#     `/<link>.views/` in that clone's LOCAL exclude file (never a tracked .gitignore), recorded in
#     $BOOTSTRAP_STATE_DIR/shared-folders/git-excludes so remove and uninstall take out only those lines.
#
# WHEN IT CANNOT BE DELIVERED: a real file where a link belongs, a folder no OneDrive root has, a
# folder two roots have, a link git has already committed, or your company's OneDrive policy
# (BlockExternalSync, AllowTenantList) stopping a client's folder from syncing — each is NEEDS_HUMAN,
# never SATISFIED over a folder that will not stay current.
#
# TEST SEAMS (module-scoped; CONTRACT.md §5 does not carry them):
#   SHARED_FOLDERS_CLOUD_DIR  replaces $HOME/Library/CloudStorage — where the OneDrive* roots are
#                             looked for. The CLI honours the same variable, so both agree.
#   BOOTSTRAP_MANAGED_ROOT    the library's seam: prefixes the system paths OneDrive's managed
#                             preferences are read from.
#
# bash 3.2 · set -u, never set -e · every verb runs in its own subshell, so everything below is
# re-derived per verb and nothing is carried between them.

SHARED_FOLDERS_VERSION_LINE="shared-folder 1"

shared_folders_state_dir() { printf '%s' "${BOOTSTRAP_STATE_DIR:-$HOME/.mac-bootstrap}"; }
shared_folders_dir()       { printf '%s/shared-folders' "$(shared_folders_state_dir)"; }
shared_folders_bin()       { printf '%s/bin/shared-folder' "$(shared_folders_state_dir)"; }
shared_folders_converter() { printf '%s/markdown-convert.sh' "$(shared_folders_dir)"; }
shared_folders_links()     { printf '%s/links' "$(shared_folders_dir)"; }
shared_folders_cloud_dir() { printf '%s' "${SHARED_FOLDERS_CLOUD_DIR:-$HOME/Library/CloudStorage}"; }

# The two assets and where each lands, as "<asset-relpath> <installed-path>" lines.
shared_folders_parts() {
  printf 'markdown-convert.sh %s\n' "$(shared_folders_converter)"
  printf 'shared-folders/shared-folder %s\n' "$(shared_folders_bin)"
}

# Paths are shown as $HOME/… literally: executable as typed, and no username in the output.
shared_folders_short_path() {
  case "$1" in "$HOME"/*) printf '$HOME/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

# ── asset sources ────────────────────────────────────────────────────────────────────────────
# shared_folders_source <asset-relpath> — the file in the release tree the driver unpacked and
# verified against its manifest ($BOOTSTRAP_ASSETS), and nowhere else: never a fetch of its own, and
# never an older cache. rc 1 when there is none.
shared_folders_source() {
  local c="${BOOTSTRAP_ASSETS:-}/${1:-}"
  case "$c" in /*) : ;; *) return 1 ;; esac
  [ -r "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

# shared_folders_current <installed> <asset-relpath> — rc 0 iff the installed copy is a regular,
# executable file, byte-identical (cmp — not the cp that wrote it) to the shipped source whenever the
# release tree is reachable. Without it the executions in verify_ are what we have.
shared_folders_current() {
  local inst="${1:-}" rel="${2:-}" src
  [ -f "$inst" ] && [ ! -L "$inst" ] && [ -x "$inst" ] || return 1
  src="$(shared_folders_source "$rel")" || return 0
  cmp -s "$src" "$inst"
}

# ── paths and roots ──────────────────────────────────────────────────────────────────────────
# shared_folders_physical <path> — the physical path of <path> when it is a directory, else of its
# deepest existing ancestor. `cd -P` + `pwd -P`, because macOS ships no /bin/realpath.
shared_folders_physical() {
  local p="${1:-}"
  while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -d "$p" ]; do p="$(dirname "$p")"; done
  [ -n "$p" ] || p="/"
  (cd -P "$p" 2>/dev/null && pwd -P)
}

# shared_folders_sync_roots — every folder a sync client uploads, one per line, existing or not. The
# module's OWN list, deliberately not the CLI's code, holding the same families: the CloudStorage dir
# in force (seam or real) and the real one (OneDrive, Dropbox, Google Drive and Box in File Provider
# mode), iCloud Drive, Desktop and Documents when Finder says iCloud keeps them, and each client's
# pre-File-Provider root — including wherever Dropbox's own info.json says it was moved.
shared_folders_sync_roots() {
  local r k d
  for r in "$(shared_folders_cloud_dir)" "$HOME/Library/CloudStorage" "$HOME/Library/Mobile Documents" \
           "$HOME/Dropbox" "$HOME/Dropbox ("*")" "$HOME/Google Drive" "$HOME/My Drive" /Volumes/GoogleDrive \
           /Volumes/GoogleDrive-* "$HOME/Box" "$HOME/Box Sync" "$HOME/OneDrive" "$HOME/OneDrive - "*; do
    printf '%s\n' "$r"
  done
  for k in personal.path business.path; do
    r="$(/usr/bin/plutil -extract "$k" raw -o - -- "$HOME/.dropbox/info.json" 2>/dev/null)" || continue
    case "$r" in /*) printf '%s\n' "$r" ;; esac
  done
  for d in Desktop Documents; do
    case "$(/usr/bin/plutil -extract "FXICloudDrive$d" raw -o - -- "$HOME/Library/Preferences/com.apple.finder.plist" 2>/dev/null)" in
      true|1) printf '%s\n' "$HOME/$d" ;;
    esac
  done
}

# shared_folders_under_cloud <path> — rc 0 iff <path> physically sits inside a synced tree
# (shared_folders_sync_roots). Each is compared only when it exists — an absent one resolves to its
# ancestor, which would swallow all of ~/Library. Both sides are compared with the letter case folded:
# macOS volumes are case-insensitive by default and `pwd -P` keeps the case that was typed, so
# $HOME/library/cloudstorage IS the synced folder. On a case-sensitive volume the fold can only refuse more.
shared_folders_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
shared_folders_under_cloud() {
  local real c cr
  real="$(shared_folders_physical "${1:-}")" || return 1
  [ -n "$real" ] || return 1
  real="$(shared_folders_lower "$real")"
  while IFS= read -r c; do
    [ -n "$c" ] && [ -d "$c" ] || continue
    cr="$(cd -P "$c" 2>/dev/null && pwd -P)" || continue
    [ -n "$cr" ] || continue
    cr="$(shared_folders_lower "$cr")"
    case "$real/" in "$cr/"*) return 0 ;; esac
  done <<EOF
$(shared_folders_sync_roots)
EOF
  return 1
}

# ── git and policy: the module's own readers ────────────────────────────────────────────────────
# shared_folders_git — a git that runs without opening the Command Line Tools install dialog a fresh
# Mac's /usr/bin/git shows: the bootstrap's own, Homebrew's, or Apple's only where a developer
# directory holds it.
shared_folders_git() {
  local c dev
  for c in "$(shared_folders_state_dir)/tools/bin/git" /opt/homebrew/bin/git /usr/local/bin/git; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  dev="$(/usr/bin/xcode-select -p 2>/dev/null)" || return 1
  [ -x "$dev/usr/bin/git" ] && { printf '%s' "$dev/usr/bin/git"; return 0; }
  return 1
}

# shared_folders_work_tree <link> — the folder holding the .git of the work tree <link> sits in.
shared_folders_work_tree() {
  local d="${1%/*}"
  while :; do
    [ -e "${d:-}/.git" ] && { printf '%s' "${d:-/}"; return 0; }
    [ -n "$d" ] || return 1
    d="${d%/*}"
  done
}

# shared_folders_tracked <link> — rc 0 when git's INDEX already holds the link or anything in its
# views: an exclude line cannot untrack it, so only a person can take it out. This asks the index
# (ls-files); the CLI's `check` asks the ignore rules (check-ignore) — two different questions of git.
shared_folders_tracked() {
  local link="${1:-}" tree git rel
  tree="$(shared_folders_work_tree "$link")" || return 1
  git="$(shared_folders_git)" || return 1
  rel="${link#"${tree%/}"/}"
  [ -n "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE "$git" --literal-pathspecs -C "$tree" ls-files -- "$rel" "$rel.views" 2>/dev/null)" ]
}

# shared_folders_onedrive_policy <key> — what IT set for <key> in OneDrive's managed preferences (the
# per-user and device configuration profiles, and the plist a deployment script writes; standalone
# and App Store OneDrive). plutil on the files: no admin. The library's bootstrap_policy reads only the
# agents' domains, so this is its OneDrive twin.
shared_folders_onedrive_policy() {
  local r="${BOOTSTRAP_MANAGED_ROOT:-}" u d f v
  u="$(/usr/bin/id -un 2>/dev/null)"
  for d in com.microsoft.OneDrive com.microsoft.OneDrive-mac; do
    for f in "$r/Library/Managed Preferences/$u/$d.plist" "$r/Library/Managed Preferences/$d.plist" "$r/Library/Preferences/$d.plist"; do
      [ -f "$f" ] || continue
      v="$(/usr/bin/plutil -extract "$1" raw -o - -- "$f" 2>/dev/null)" && { printf '%s' "$v"; return 0; }
    done
  done
  return 1
}

# shared_folders_policy_block — the policy key that stops OneDrive keeping a client's folder current,
# rc 1 when none. BlockExternalSync stops folders shared from other organisations; an AllowTenantList
# with any entry lets only those organisations' accounts sync (plutil prints an array's count).
shared_folders_policy_block() {
  case "$(shared_folders_onedrive_policy BlockExternalSync)" in true|1) printf 'BlockExternalSync'; return 0 ;; esac
  case "$(shared_folders_onedrive_policy AllowTenantList)" in ''|0|false) return 1 ;; esac
  printf 'AllowTenantList'
}

# shared_folders_matches <relative-path> — every OneDrive root holding <relative-path>, one per line.
# This is the module's OWN resolver, deliberately not the CLI's: verify_ uses it to check the links
# the CLI made through a different code path, and gate_ to name a folder that no root has any more.
shared_folders_matches() {
  local rel="${1:-}" c r
  [ -n "$rel" ] || return 0
  rel="${rel#/}"; rel="${rel%/}"
  c="$(shared_folders_cloud_dir)"
  for r in "$c"/OneDrive*; do
    [ -d "$r" ] || continue
    [ -e "$r/$rel" ] && printf '%s\n' "$r/$rel"
  done
  return 0
}

# shared_folders_records — each record as "<link>\t<rel>\t<url>", comments and blanks skipped. A
# link's trailing slash is dropped: `rm link/` and `test -L link/` both follow the link.
shared_folders_records() {
  local f line link rel url tab
  tab="$(printf '\t')"
  f="$(shared_folders_links)"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    IFS="$tab" read -r link rel url <<EOF
$line
EOF
    [ -n "$link" ] && [ -n "$rel" ] || continue
    while [ "${#link}" -gt 1 ] && [ "${link%/}" != "$link" ]; do link="${link%/}"; done
    printf '%s\t%s\t%s\n' "$link" "$rel" "$url"
  done < "$f"
}

# shared_folders_needs_human — the first record only a person can fix, as
# "<why>\t<link>\t<rel>\t<n>\t<url>", rc 1 if none. <why>, in the CLI's own order of precedence:
#   not-a-link  a real file or folder sits where the link belongs; nothing here will ever move it
#   unsynced    no OneDrive root has the folder any more (n = 0)
#   ambiguous   n > 1 roots have it, so no link can be chosen without a person
#   tracked     git has already committed the link or its views; an exclude line cannot undo that
#   policy      your company's OneDrive policy stops a client's folder syncing (n = the policy key);
#               named against the first link, since it holds for every one
# gate_, note_ and gesture_ all read this, so they can never disagree about which folder they name.
shared_folders_needs_human() {
  local link rel url n tab first="" key
  tab="$(printf '\t')"
  while IFS="$tab" read -r link rel url; do
    [ -n "$link" ] || continue
    n="$(shared_folders_matches "$rel" | bootstrap_count)"
    # The optional URL goes LAST: a tab is IFS whitespace, so an empty field in the middle collapses.
    if [ -e "$link" ] && [ ! -L "$link" ]; then printf 'not-a-link\t%s\t%s\t%s\t%s' "$link" "$rel" "$n" "$url"; return 0; fi
    if [ "$n" = 0 ]; then printf 'unsynced\t%s\t%s\t%s\t%s' "$link" "$rel" "$n" "$url"; return 0; fi
    if [ "$n" -gt 1 ]; then printf 'ambiguous\t%s\t%s\t%s\t%s' "$link" "$rel" "$n" "$url"; return 0; fi
    if shared_folders_tracked "$link"; then printf 'tracked\t%s\t%s\t%s\t%s' "$link" "$rel" "$n" "$url"; return 0; fi
    [ -n "$first" ] || first="$link$tab$rel"
  done <<EOF
$(shared_folders_records)
EOF
  if [ -n "$first" ] && key="$(shared_folders_policy_block)"; then
    printf 'policy\t%s\t%s\t' "$first" "$key"; return 0
  fi
  return 1
}

# shared_folders_resolved <path> — the physical path of an EXISTING file or folder: a folder through
# `cd -P`, a file through its folder plus its name. rc 1 when it does not exist.
shared_folders_resolved() {
  local p="${1:-}" d
  [ -e "$p" ] || return 1
  if [ -d "$p" ]; then (cd -P "$p" 2>/dev/null && pwd -P); return; fi
  d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "${d%/}" "$(basename "$p")"
}

# shared_folders_record_healthy <link> <rel> — the independent read-back for ONE link. The CLI's
# `check` compares readlink's STRING with the path it would write; this compares where the link
# PHYSICALLY lands: it is a symlink, the path resolves under exactly one root, the link's target
# (followed, resolved) is that same file or folder, it sits inside the cloud dir, and the link's
# views, when there are any, sit outside it.
shared_folders_record_healthy() {
  local link="${1:-}" rel="${2:-}" want got n cloud t
  [ -L "$link" ] || return 1
  n="$(shared_folders_matches "$rel" | bootstrap_count)"
  [ "$n" = 1 ] || return 1
  want="$(shared_folders_resolved "$(shared_folders_matches "$rel")")" || return 1
  t="$(readlink "$link" 2>/dev/null)" || return 1
  case "$t" in /*) : ;; *) t="$(dirname "$link")/$t" ;; esac
  got="$(shared_folders_resolved "$t")" || return 1
  [ -n "$want" ] && [ "$got" = "$want" ] || return 1
  cloud="$(cd -P "$(shared_folders_cloud_dir)" 2>/dev/null && pwd -P)" || return 1
  case "$got/" in "$cloud/"*) : ;; *) return 1 ;; esac
  if [ -e "$link.views" ]; then
    shared_folders_under_cloud "$link.views" && return 1
  fi
  return 0
}

# shared_folders_check_says_no — the NEGATIVE CONTROL on the installed CLI's `check`: a record whose
# link does not exist, against a cloud dir holding no root, must NOT come back healthy. Run in a
# throwaway state dir and cloud dir, so it reads and writes nothing real. Without this, a `check`
# that exits 0 on everything would make every link read OK.
shared_folders_check_says_no() {
  local bin="$1" tmp rc
  tmp="$(mktemp -d -t sharedfoldersprobe)" || return 1
  mkdir -p "$tmp/state/shared-folders" "$tmp/cloud" 2>/dev/null
  printf '%s\t%s\n' "$tmp/no-such-link" "No Such Folder" > "$tmp/state/shared-folders/links"
  BOOTSTRAP_STATE_DIR="$tmp/state" SHARED_FOLDERS_CLOUD_DIR="$tmp/cloud" "$bin" check >/dev/null 2>&1
  rc=$?
  rm -rf "$tmp" 2>/dev/null
  [ "$rc" -ne 0 ]
}

# shared_folders_converter_works <converter> — EXECUTE the installed converter: a markdown file passes
# through byte for byte and names its converter, and the negative control — an extension nothing
# converts — must answer rc 10, not a conversion.
shared_folders_converter_works() {
  local conv="$1" tmp out rc
  tmp="$(mktemp -d -t sharedfoldersconvert)" || return 1
  printf '# probe\n\nshared folders converter probe\n' > "$tmp/probe.md"
  printf 'not a known format\n' > "$tmp/probe.no-such-extension"
  rc=0
  out="$("$conv" "$tmp/probe.md" 2>/dev/null)" || rc=1
  [ "$rc" = 0 ] && [ "$out" = "$(cat "$tmp/probe.md")" ] || rc=1
  if [ "$rc" = 0 ]; then
    out="$("$conv" --converter-id "$tmp/probe.md" 2>/dev/null)" || rc=1
    case "$out" in passthrough\ *) : ;; *) rc=1 ;; esac
  fi
  if [ "$rc" = 0 ]; then
    "$conv" "$tmp/probe.no-such-extension" >/dev/null 2>&1
    [ $? = 10 ] || rc=1
  fi
  rm -rf "$tmp" 2>/dev/null
  return "$rc"
}

# shared_folders_url_ok <url> — a SharePoint or OneDrive web URL safe to hand back inside `open '…'`:
# https, and no quote, backslash or whitespace. It is SINGLE-quoted because OneDrive share links
# (https://1drv.ms/f/s!…) always carry a '!', which interactive zsh and bash history-expand inside
# double quotes — `open "…s!Ak…"` fails with "event not found" before open ever runs.
shared_folders_url_ok() {
  case "${1:-}" in
    https://*) : ;;
    *) return 1 ;;
  esac
  case "$1" in *[\'\"\$\`\\\ ]*) return 1 ;; esac
  return 0
}

# shared_folders_views_ours <views-dir> — rc 0 only for a views folder the CLI generated: a real
# folder (not a link), outside every synced tree, whose _index.md names the generator on line 2 —
# the same ownership proof `shared-folder remove` uses. Nothing else is ever deleted as "views".
shared_folders_views_ours() {
  local v="${1:-}"
  [ -d "$v" ] && [ ! -L "$v" ] && [ -f "$v/_index.md" ] || return 1
  shared_folders_under_cloud "$v" && return 1
  [ "$(/usr/bin/awk 'NR == 2 { print; exit }' "$v/_index.md" 2>/dev/null)" = "generator: $SHARED_FOLDERS_VERSION_LINE" ]
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# ── catalog metadata (optional verbs; see CONTRACT.md) ────────────────────────────────────────
what_shared_folders()    { printf '%s' 'a shared OneDrive or SharePoint folder reachable from any repo as a plain path, through a link into the OneDrive app'\''s own synced copy, with read-only markdown views beside it; the link re-finds its folder when OneDrive renames its root'; }
cost_shared_folders()    { printf '%s' 'two small scripts. Each folder'\''s .views/ beside its link are markdown COPIES of the shared documents, on this Mac and outside the tenant'\''s DLP, retention and eDiscovery (a clone'\''s local exclude keeps them out of git). Needs the OneDrive app signed in and each folder added once with Add shortcut to My files (or Sync on a client'\''s site); Office and PDF views need pandoc or markitdown.'; }
# What corporate IT usually governs here, one class per line (CONTRACT "Catalog metadata").
clearance_shared_folders() { cat <<'E'
data markdown copies of each shared OneDrive or SharePoint folder's documents, in <link>.views/ beside its link, outside the tenant's DLP, retention and eDiscovery; each clone's local git exclude keeps them out of git
software two scripts of this bootstrap's own (the shared-folder CLI and its markdown converter), which run pandoc or markitdown when this Mac has them
E
}
profile_shared_folders() { printf '%s' 'full'; }

# egress_ — declared, and empty: nothing this module installs or runs reaches a network. The OneDrive
# app, which the person set up, does all the syncing. The converter's tools are configured with zero
# egress: pandoc runs --sandbox (measured: no request even for an html naming remote images), and
# markitdown runs only under a Python that cannot import speech_recognition, with no -d, --use-cu or -p,
# on a ./ or / path that is never read as a URL (markdown-convert.sh's header has the four network
# converters and why each is unreachable). Our own two scripts come from the release tree the driver
# already fetched and verified, so there is no install-time host either.
egress_shared_folders() { return 0; }

verify_shared_folders() {
  local bin conv out link rel url tab first=""
  bin="$(shared_folders_bin)"; conv="$(shared_folders_converter)"
  tab="$(printf '\t')"

  shared_folders_current "$bin" shared-folders/shared-folder || return 1
  shared_folders_current "$conv" markdown-convert.sh || return 1

  # READ-BACK BY EXECUTION. The installer copied bytes; this runs them.
  out="$("$bin" --version 2>/dev/null)" || return 1
  [ "$out" = "$SHARED_FOLDERS_VERSION_LINE" ] || return 1
  # The CLI's own fixtures: a fake cloud root renamed under a live link, the refusals, the views and
  # their no-write second refresh, the dataless file that must never be opened — each with its
  # negative control. Running them is the only proof the installed copy still DISCRIMINATES.
  "$bin" --selftest >/dev/null 2>&1 || return 1
  shared_folders_converter_works "$conv" || return 1
  shared_folders_check_says_no "$bin" || return 1

  # Every link you have added is healthy — by the CLI's `check`, and again by this module's own
  # resolver, which shares no code with it. Zero links is satisfied: the deliverable is the tool,
  # plus every link that exists being sound.
  [ -n "$(shared_folders_records)" ] || return 0
  "$bin" check >/dev/null 2>&1 || return 1
  while IFS="$tab" read -r link rel url; do
    [ -n "$link" ] || continue
    shared_folders_record_healthy "$link" "$rel" || return 1
    shared_folders_tracked "$link" && return 1          # committed to git: goes wherever the repo is pushed
    [ -n "$first" ] || first="$rel"
  done <<EOF
$(shared_folders_records)
EOF
  # A link can resolve perfectly and still be a folder OneDrive has stopped keeping current.
  shared_folders_policy_block >/dev/null && return 1
  # …and the same read-back must be able to say NO: a link that does not exist, over a folder that
  # DOES resolve, is not healthy — so the pass above is about the links, not merely the folders.
  shared_folders_record_healthy "$(shared_folders_dir)/__shared_folders_no_such_link__" "$first" && return 1
  return 0
}

# gate_ must not answer yes while drivable work remains: the driver reports NEEDS_HUMAN INSTEAD of
# installing. So it fires only once the tool is installed and current — on a bare machine, or after
# an upgrade, the install runs first and returns 3 if it then finds a folder no root has.
shared_folders_installed() {
  local bin
  bin="$(shared_folders_bin)"
  shared_folders_current "$bin" shared-folders/shared-folder || return 1
  shared_folders_current "$(shared_folders_converter)" markdown-convert.sh || return 1
  [ "$("$bin" --version 2>/dev/null)" = "$SHARED_FOLDERS_VERSION_LINE" ]
}

gate_shared_folders() {
  shared_folders_installed || return 1
  shared_folders_needs_human >/dev/null 2>&1
}

note_shared_folders() {
  local u why link rel n tab
  tab="$(printf '\t')"
  if u="$(shared_folders_needs_human)"; then
    IFS="$tab" read -r why link rel n _ <<EOF
$u
EOF
    case "$why" in
      not-a-link) printf 'a real file or folder sits at %s, where the link to the shared folder "%s" belongs, and nothing here will ever move or delete it; move it aside yourself and the next run relinks.' \
                   "$(shared_folders_short_path "$link")" "$rel" ;;
      ambiguous) printf 'the shared folder "%s" (linked at %s) is present under %s OneDrive roots in %s, so which one the link follows is your call; in the OneDrive app, stop syncing the root you no longer use, and never delete a folder under CloudStorage by hand.' \
                   "$rel" "$(shared_folders_short_path "$link")" "$n" "$(shared_folders_short_path "$(shared_folders_cloud_dir)")" ;;
      tracked)   printf 'git has already committed the link %s or its views in the repo %s, so they go wherever that repo is pushed and no exclude line can stop it; take them out of the index with the command below (your files stay), and check no pushed commit carries them.' \
                   "$(shared_folders_short_path "$link")" "$(shared_folders_short_path "$(shared_folders_work_tree "$link")")" ;;
      policy)    printf 'your company'\''s OneDrive policy (%s) stops OneDrive syncing folders from other organizations, so the shared folder "%s" (linked at %s) may look present but will not be kept current; ask IT to allow the client'\''s organization.' \
                   "$n" "$rel" "$(shared_folders_short_path "$link")" ;;
      *)         printf 'the shared folder "%s" (linked at %s) is no longer synced: no OneDrive root in %s has it, so the link points nowhere; add it back with Add shortcut to My files (or Sync on the client'\''s site) and the next run relinks it.' \
                   "$rel" "$(shared_folders_short_path "$link")" "$(shared_folders_short_path "$(shared_folders_cloud_dir)")" ;;
    esac
    return 0
  fi
  printf 'the shared-folder tool is not installed, or a folder you linked is not healthy yet.'
}

gesture_shared_folders() {
  local u why link url tab
  tab="$(printf '\t')"
  if u="$(shared_folders_needs_human)"; then
    IFS="$tab" read -r why link _ _ url <<EOF
$u
EOF
    if [ "$why" = not-a-link ]; then
      # Reveal it in Finder — unless the path holds a character that would break out of the quotes,
      # in which case there is no command that runs as typed, and printing none is the honest answer.
      # A '!' is history-expanded inside double quotes by an interactive shell, so a path holding one
      # is spelled "$HOME"'/…': $HOME still expands, and the rest is single-quoted, inert.
      case "${link#"$HOME"}" in *[\"\$\`\\]*) return 0 ;; esac
      case "$link" in
        *!*) case "$link" in *"'"*) return 0 ;; esac
             case "$link" in
               "$HOME"/*) printf 'open -R "$HOME"'\''/%s'\''' "${link#"$HOME"/}" ;;
               *)         printf "open -R '%s'" "$link" ;;
             esac ;;
        *)   printf 'open -R "%s"' "$(shared_folders_short_path "$link")" ;;
      esac
    elif [ "$why" = tracked ]; then
      # git rm --cached changes only the index, never a file. Printed only when both paths quote safely.
      shared_folders_untrack_command "$link"
    elif [ "$why" = policy ]; then
      :                                    # only IT can change it; the note says so, and there is no command
    elif [ "$why" = unsynced ] && shared_folders_url_ok "$url"; then
      printf "open '%s'" "$url"
    else
      printf 'open -a OneDrive'
    fi
    return 0
  fi
  return 0
}

# shared_folders_untrack_command <link> — `git -C "<repo>" rm -r --cached --ignore-unmatch -- '<rel>'
# '<rel>.views'`, or nothing when the repo or the path holds a character that would break the quotes.
shared_folders_untrack_command() {
  local tree rel
  tree="$(shared_folders_work_tree "$1")" || return 0
  rel="${1#"${tree%/}"/}"
  case "$rel" in *"'"*) return 0 ;; esac
  case "${tree#"$HOME"}" in *[\"\$\`\\!]*) return 0 ;; esac
  printf "git -C \"%s\" rm -r --cached --ignore-unmatch -- '%s' '%s.views'" "$(shared_folders_short_path "$tree")" "$rel" "$rel"
}

# shared_folders_land <asset-relpath> <installed-path> — stage, PROVE it runs, then land it. Bytes
# already identical are never rewritten, so a second run changes nothing.
shared_folders_land() {
  local rel="$1" dest="$2" src out
  src="$(shared_folders_source "$rel")" || { bootstrap_warn "shared_folders: assets/$rel is not in the release tree (BOOTSTRAP_ASSETS=${BOOTSTRAP_ASSETS:-unset}); nothing is fetched to make up for it"; return 1; }
  if [ ! -L "$dest" ] && [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    [ -x "$dest" ] || chmod 755 "$dest" 2>/dev/null
    return 0
  fi
  # `cp -f` FOLLOWS a symlink and writes its target; a link at our path is replaced, never written through.
  [ -L "$dest" ] && rm -f "$dest" 2>/dev/null
  cp -f "$src" "$dest.shared-folders-tmp" 2>/dev/null && chmod 755 "$dest.shared-folders-tmp" 2>/dev/null \
    || { rm -f "$dest.shared-folders-tmp" 2>/dev/null; bootstrap_warn "shared_folders: cannot stage $dest"; return 1; }
  if ! /bin/bash -n "$dest.shared-folders-tmp" 2>/dev/null; then
    rm -f "$dest.shared-folders-tmp" 2>/dev/null
    bootstrap_warn "shared_folders: the staged $rel does not parse under /bin/bash — $dest left untouched"
    return 1
  fi
  case "$rel" in
    shared-folders/shared-folder)
      out="$("$dest.shared-folders-tmp" --version 2>/dev/null)" || out=""
      if [ "$out" != "$SHARED_FOLDERS_VERSION_LINE" ]; then
        rm -f "$dest.shared-folders-tmp" 2>/dev/null
        bootstrap_warn "shared_folders: the staged CLI answered [$out], not [$SHARED_FOLDERS_VERSION_LINE] — $dest left untouched"
        return 1
      fi ;;
  esac
  # …and its own fixtures pass, run from the staged bytes: a copy that fails them must never replace
  # a working one. The CLI finds the converter at ../shared-folders/, which landed first.
  if ! "$dest.shared-folders-tmp" --selftest >/dev/null 2>&1; then
    rm -f "$dest.shared-folders-tmp" 2>/dev/null
    bootstrap_warn "shared_folders: the staged $rel failed its own --selftest — $dest left untouched"
    return 1
  fi
  mv -f "$dest.shared-folders-tmp" "$dest" 2>/dev/null \
    || { rm -f "$dest.shared-folders-tmp" 2>/dev/null; bootstrap_warn "shared_folders: cannot land $dest"; return 1; }
  return 0
}

install_shared_folders() {
  local state dir bin rel dest link url st tab rc=0
  tab="$(printf '\t')"
  state="$(shared_folders_state_dir)"; dir="$(shared_folders_dir)"; bin="$(shared_folders_bin)"
  mkdir -p "$state/bin" "$dir" 2>/dev/null || { bootstrap_warn "shared_folders: cannot create $state/bin and $dir"; return 1; }
  # Our own state must never sit in a synced tree: the record would be uploaded, and the views next to it.
  if shared_folders_under_cloud "$dir"; then
    bootstrap_warn "shared_folders: $dir is inside a synced cloud folder — refusing to install there"
    return 1
  fi

  # The converter first, so the CLI that uses it is never live without it.
  while read -r rel dest; do
    [ -n "$rel" ] || continue
    shared_folders_land "$rel" "$dest" || return 1
  done <<EOF
$(shared_folders_parts)
EOF

  # Follow any root OneDrive renamed since the last run. `relink` re-resolves every record and
  # repoints only the links whose target moved, so on a healthy machine it writes nothing.
  if [ -n "$(shared_folders_records)" ]; then
    "$bin" relink >&2 || rc=$?
    # `check` counts a view older than its source as not healthy, and verify_ runs `check`, so a view
    # left stale would make every run FAIL with nothing to repair it. Regenerate only the links that
    # already have views and report STALE-VIEWS: the stale test is size + mtime, a view is rewritten
    # only when its bytes change, and a dataless file is never read.
    while IFS="$tab" read -r link rel url; do
      [ -n "$link" ] && [ -d "$link.views" ] || continue
      st="$("$bin" check "$link" 2>/dev/null)"
      case "${st%%"$tab"*}" in
        STALE-VIEWS*) "$bin" refresh "$link" >&2 || { bootstrap_warn "shared_folders: refresh of $link failed"; rc=1; } ;;
      esac
    done <<EOF
$(shared_folders_records)
EOF
  fi
  # A folder no root has any more is a gate the installer has now DISCOVERED: return 3 and let the
  # driver re-ask gate_, which names the folder and the one gesture that brings it back.
  shared_folders_needs_human >/dev/null 2>&1 && return 3
  [ "$rc" = 0 ] || { bootstrap_warn "shared_folders: relink or refresh failed (rc $rc)"; return 1; }
  return 0
}

# shared_folders_unexclude_all — undo every line the CLI recorded appending to a clone's exclude file
# (ledger: "<link>\t<exclude-file>\t<line>", or an empty <link> with created-file / created-dir), and
# remove what it created once it is empty again. Lines somebody else wrote are never in the ledger.
shared_folders_unexclude_all() {
  local ledger file tmp rc=0
  ledger="$(shared_folders_dir)/git-excludes"
  [ -f "$ledger" ] || return 0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ -f "$file" ]; then
      tmp="$file.shared-folders.$$"
      LEDGER="$ledger" FILE="$file" /usr/bin/awk -F'\t' '
        FILENAME == ENVIRON["LEDGER"] { if ($1 != "" && $2 == ENVIRON["FILE"]) ours[$3] = 1; next }
        !($0 in ours) { print }
      ' "$ledger" "$file" > "$tmp" || { rm -f "$tmp"; rc=1; continue; }
      if cmp -s "$tmp" "$file"; then rm -f "$tmp"; else cat "$tmp" > "$file" && rm -f "$tmp" || rc=1; fi
      if FILE="$file" /usr/bin/awk -F'\t' '$1 == "" && $2 == ENVIRON["FILE"] && $3 == "created-file" { f = 1 } END { exit f ? 0 : 1 }' "$ledger" \
         && [ ! -s "$file" ]; then
        rm -f "$file"
      fi
    fi
    if FILE="$file" /usr/bin/awk -F'\t' '$1 == "" && $2 == ENVIRON["FILE"] && $3 == "created-dir" { f = 1 } END { exit f ? 0 : 1 }' "$ledger"; then
      rmdir "$(dirname "$file")" 2>/dev/null
    fi
  done <<EOF
$(/usr/bin/awk -F'\t' '!seen[$2]++ { print $2 }' "$ledger")
EOF
  [ "$rc" = 0 ] && rm -f "$ledger"
  return "$rc"
}

# uninstall_ removes the CLI, the converter and the record, the symlinks it recorded, and the views
# folder beside each link that the CLI provably generated — exactly what `shared-folder remove` takes
# for one link. NEVER a symlink's target, NEVER anything under CloudStorage: a delete there is a
# delete of the client's file, and on an orphaned sync domain it fails in ways the OneDrive app
# cannot repair. A real file or folder at a link path, or a `.views` folder without the generator's
# mark, is somebody else's and stays.
uninstall_shared_folders() {
  local link rel url dir tab rc=0
  tab="$(printf '\t')"
  while IFS="$tab" read -r link rel url; do
    [ -n "$link" ] || continue
    [ -L "$link" ] || continue                     # a real file or folder at that path is never ours
    if shared_folders_under_cloud "$(dirname "$link")"; then
      bootstrap_warn "shared_folders: $link sits inside a synced cloud folder — left in place"
      rc=1; continue
    fi
    rm -f -- "$link" 2>/dev/null || { bootstrap_warn "shared_folders: cannot remove the link $link"; rc=1; }
  done <<EOF
$(shared_folders_records)
EOF
  # The views go in a second pass, so a views folder beside a link that was already gone still goes.
  while IFS="$tab" read -r link rel url; do
    [ -n "$link" ] || continue
    shared_folders_views_ours "$link.views" || continue
    rm -rf -- "$link.views" 2>/dev/null || { bootstrap_warn "shared_folders: cannot remove $link.views"; rc=1; }
  done <<EOF
$(shared_folders_records)
EOF
  shared_folders_unexclude_all || rc=1
  rm -f "$(shared_folders_bin)" 2>/dev/null
  dir="$(shared_folders_dir)"
  if [ -L "$dir" ]; then
    rm -f "$dir" 2>/dev/null
  elif [ -d "$dir" ]; then
    if shared_folders_under_cloud "$dir"; then
      bootstrap_warn "shared_folders: $dir is inside a synced cloud folder — left in place"; rc=1
    else
      rm -rf "$dir" 2>/dev/null || rc=1
    fi
  fi
  rmdir "$(shared_folders_state_dir)/bin" 2>/dev/null
  return "$rc"
}
