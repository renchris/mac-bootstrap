# shellcheck shell=bash
# scripts/checks/shared-folders.sh — a client's shared folder: nothing of it leaves the Mac. Sourced by
# scripts/characterize.sh, which supplies the harness; never run on its own.
#
# The promise is "no second copy, nothing leaves", and each way it could break is checked by what
# ACTUALLY happens, never by a phrase: what a stand-in markitdown was handed (its own record), what git
# itself says it would commit (check-ignore, ls-files — not a read of the lines we wrote), which paths
# the link was refused under, and the receipt state the driver records. Every positive has a negative
# control beside it that proves the check can say no. Fixtures only: no network, no real tool installed.

SF_CLI="$CHECK_ROOT/assets/shared-folders/shared-folder"
SF_CONVERT="$CHECK_ROOT/assets/markdown-convert.sh"
SF_T="$CHECK_TMP/shared-folders"
mkdir -p "$SF_T/stub" "$SF_T/home" "$SF_T/state" "$SF_T/managed" "$SF_T/cloud/OneDrive-Contoso/Clients/Acme"
printf '# brief\n' > "$SF_T/cloud/OneDrive-Contoso/Clients/Acme/brief.md"

# The CLI, pointed at fixtures for everything it reads: a fake cloud, no managed OneDrive preferences,
# a state dir of its own, and a HOME that is a fixture too (sync roots are found under $HOME).
sf_cli() { HOME="$SF_T/home" BOOTSTRAP_STATE_DIR="$SF_T/state" SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/managed" /bin/bash "$SF_CLI" "$@"; }
# git with no user or system config, so a developer's init.templateDir or hooks cannot change a fixture.
sf_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }

# ── 1. the converter's shipped selftest. (The CLI's runs inside verify_, so every driver run in §5
#    below already fails if it does — running it a sixth time here would only cost ten seconds.) ────
out="$(/bin/bash "$SF_CONVERT" --selftest 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then pass "converter-selftest" "$(printf '%s\n' "$out" | tail -1)"
else fail "converter-selftest" "$(printf '%s\n' "$out" | grep FAIL | head -3 | tr '\n' ' ')"; fi

# ── 2. markitdown is never handed audio — a stand-in on PATH records every file it is handed ─────
cat > "$SF_T/stub/python3" <<'STUB'
#!/bin/bash
[ "${1:-}" = -I ] && shift
if [ "${1:-}" = -c ]; then printf '%s\n' "${STUB_SPEECH:-absent}"; exit 0; fi
shift
[ "${1:-}" = --version ] && { printf 'markitdown 0.0.0-stub\n'; exit 0; }
printf '%s\n' "$*" >> "$STUB_LOG"
printf '# converted by the stand-in\n'
STUB
printf '#!%s\n' "$SF_T/stub/python3" > "$SF_T/stub/markitdown"
chmod 755 "$SF_T/stub/python3" "$SF_T/stub/markitdown"
printf 'RIFF\044\000\000\000WAVEfmt \020\000\000\000\001\000\001\000\104\254\000\000\210\130\001\000\002\000\020\000data\000\000\000\000' > "$SF_T/report.pdf"
printf '%%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n%%%%EOF\n' > "$SF_T/minutes.pdf"
sf_convert() { PATH="$SF_T/stub:/usr/bin:/bin" MARKDOWN_CONVERT_TOOL_DIRS='' STUB_LOG="$SF_T/stub.log" /bin/bash "$SF_CONVERT" "$@"; }
: > "$SF_T/stub.log"; sf_convert "$SF_T/report.pdf" > /dev/null 2>&1; rc=$?
same "converter-audio-pdf-never-handed-over" "$rc|$(cat "$SF_T/stub.log")" "10|"
: > "$SF_T/stub.log"; sf_convert "$SF_T/minutes.pdf" > /dev/null 2>&1; rc=$?
same "converter-text-pdf-is-handed-over" "$rc|$(cat "$SF_T/stub.log")" "0|$SF_T/minutes.pdf"
: > "$SF_T/stub.log"; STUB_SPEECH=present sf_convert "$SF_T/minutes.pdf" > /dev/null 2>&1; rc=$?
same "converter-refuses-transcribing-markitdown" "$rc|$(cat "$SF_T/stub.log")" "10|"

# The same, through a REAL Python's import machinery: a venv (no pip, no network) whose launcher is a
# real Python script; a speech_recognition package dropped into it must make the converter refuse.
SF_PY=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null)"; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  [ "$c" = /usr/bin/python3 ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1 && continue
  SF_PY="$c"; break
done
if [ -n "$SF_PY" ] && "$SF_PY" -m venv --without-pip "$SF_T/venv" >/dev/null 2>&1; then
  SF_SITE="$("$SF_T/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  mkdir -p "$SF_T/real"
  { printf '#!%s\n' "$SF_T/venv/bin/python"
    printf 'import sys\nif sys.argv[1:] == ["--version"]:\n    print("markitdown 0.0.0-venv"); sys.exit(0)\n'
    printf 'import importlib.util as u\nopen("%s", "a").write(sys.argv[1] + (" CAN-IMPORT-SPEECH" if u.find_spec("speech_recognition") else "") + "\\n")\nprint("# converted")\n' "$SF_T/real.log"
  } > "$SF_T/real/markitdown"; chmod 755 "$SF_T/real/markitdown"
  sf_real() { PATH="$SF_T/real:/usr/bin:/bin" MARKDOWN_CONVERT_TOOL_DIRS='' /bin/bash "$SF_CONVERT" "$@"; }
  : > "$SF_T/real.log"; sf_real "$SF_T/minutes.pdf" > /dev/null 2>&1; rc=$?
  same "converter-real-python-without-speech-used" "$rc|$(cat "$SF_T/real.log")" "0|$SF_T/minutes.pdf"
  mkdir -p "$SF_SITE/speech_recognition"; : > "$SF_SITE/speech_recognition/__init__.py"
  : > "$SF_T/real.log"; sf_real "$SF_T/minutes.pdf" > /dev/null 2>&1; rc=$?
  same "converter-real-python-with-speech-refused" "$rc|$(cat "$SF_T/real.log")" "10|"
  # speech_recognition reachable ONLY through PYTHONPATH: the probe and the run are both isolated (-I),
  # so markitdown is used, and the run itself — recorded by the launcher — cannot import it either.
  rm -rf "$SF_SITE/speech_recognition"; mkdir -p "$SF_T/pythonpath/speech_recognition"; : > "$SF_T/pythonpath/speech_recognition/__init__.py"
  : > "$SF_T/real.log"; PYTHONPATH="$SF_T/pythonpath" sf_real "$SF_T/minutes.pdf" > /dev/null 2>&1; rc=$?
  same "converter-probe-and-run-both-isolated" "$rc|$(cat "$SF_T/real.log")" "0|$SF_T/minutes.pdf"
else
  pass "converter-real-python-without-speech-used" "n/a: no python3 that can make a venv here"
fi

# A standard user is never offered a Homebrew command, even with Homebrew present.
printf '#!/bin/bash\nexit 0\n' > "$SF_T/stub/brew"; chmod 755 "$SF_T/stub/brew"
printf '<p>x</p>\n' > "$SF_T/page.html"
out="$(BOOTSTRAP_ASSUME_STANDARD_USER=1 sf_convert "$SF_T/page.html" 2>&1 >/dev/null)"; rc=$?
case "$rc|$out" in 10\|*"brew install"*) fail "converter-no-brew-for-a-standard-user" "$out" ;;
  10\|*) pass "converter-no-brew-for-a-standard-user" ;; *) fail "converter-no-brew-for-a-standard-user" "rc $rc" ;; esac

# ── 3. a link inside a git work tree never reaches git — git itself is asked ─────────────────────
if command -v git >/dev/null 2>&1 && sf_git init -q "$SF_T/repo" 2>/dev/null; then
  SF_EXCLUDE="$(sf_git -C "$SF_T/repo" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$(dirname "$SF_EXCLUDE")"; [ -f "$SF_EXCLUDE" ] || printf '# git ls-files --others --exclude-from=.git/info/exclude\n' > "$SF_EXCLUDE"
  cp "$SF_EXCLUDE" "$SF_T/exclude.before"
  mkdir -p "$SF_T/repo/docs"; ln -s "$SF_T/cloud" "$SF_T/repo/docs/acme"
  sf_git -C "$SF_T/repo" check-ignore -q docs/acme; rc=$?
  same "git-negative-control-a-plain-link-is-not-ignored" "$rc" "1"
  rm -f "$SF_T/repo/docs/acme"
  sf_cli add "$SF_T/repo/docs/acme" "Clients/Acme" > "$SF_T/add.out" 2>&1
  SF_N="$(wc -l < "$SF_T/exclude.before" | tr -d ' ')"
  same "git-add-appends-exactly-two-lines" "$(tail -n "+$((SF_N + 1))" "$SF_EXCLUDE" | tr '\n' '|')" "/docs/acme|/docs/acme.views/|"
  if head -n "$SF_N" "$SF_EXCLUDE" | cmp -s - "$SF_T/exclude.before"; then pass "git-add-changes-nothing-else"; else fail "git-add-changes-nothing-else"; fi
  sf_git -C "$SF_T/repo" check-ignore -q docs/acme && sf_git -C "$SF_T/repo" check-ignore -q docs/acme.views/ && sf_git -C "$SF_T/repo" check-ignore -q docs/acme.views/brief.md.md; rc=$?
  same "git-itself-ignores-the-link-and-views" "$rc" "0"
  case "$(cat "$SF_T/add.out")" in *"kept out of git"*"/repo/.git/info/exclude"*) pass "git-add-says-where-it-wrote" ;; *) fail "git-add-says-where-it-wrote" "$(cat "$SF_T/add.out")" ;; esac
  cp "$SF_EXCLUDE" "$SF_T/exclude.after"
  sf_cli add "$SF_T/repo/docs/acme" "Clients/Acme" > /dev/null 2>&1
  if cmp -s "$SF_EXCLUDE" "$SF_T/exclude.after"; then pass "git-second-add-writes-no-line"; else fail "git-second-add-writes-no-line"; fi
  sf_cli refresh "$SF_T/repo/docs/acme" > /dev/null 2>&1
  same "git-status-shows-nothing-after-views" "$(sf_git -C "$SF_T/repo" status --porcelain --untracked-files=all | tr '\n' '|')" ""
  # the lines taken out by hand: check says NOT-EXCLUDED, and relink puts them back
  cp "$SF_T/exclude.before" "$SF_EXCLUDE"
  out="$(sf_cli check "$SF_T/repo/docs/acme")"; rc=$?
  same "git-check-says-not-excluded" "$(printf '%s\n' "$out" | cut -f1) $rc" "NOT-EXCLUDED 1"
  sf_cli relink > /dev/null 2>&1
  out="$(sf_cli check "$SF_T/repo/docs/acme")"; rc=$?
  same "git-relink-restores-exclusion" "$(printf '%s\n' "$out" | cut -f1) $rc" "OK 0"
  sf_cli remove "$SF_T/repo/docs/acme" > /dev/null 2>&1
  if cmp -s "$SF_EXCLUDE" "$SF_T/exclude.before"; then pass "git-remove-leaves-the-file-as-before"; else fail "git-remove-leaves-the-file-as-before" "$(diff "$SF_T/exclude.before" "$SF_EXCLUDE" | tr '\n' ' ')"; fi
  # a linked worktree writes to the MAIN clone's exclude file, where git reads it
  sf_git -C "$SF_T/repo" commit -q --allow-empty -m fixture && sf_git -C "$SF_T/repo" worktree add -q "$SF_T/worktree" 2>/dev/null
  if [ -f "$SF_T/worktree/.git" ]; then
    sf_cli add "$SF_T/worktree/acme" "Clients/Acme" > /dev/null 2>&1
    sf_git -C "$SF_T/worktree" check-ignore -q acme && sf_git -C "$SF_T/worktree" check-ignore -q acme.views/; rc=$?
    same "git-worktree-link-is-ignored" "$rc" "0"
    sf_cli remove "$SF_T/worktree/acme" > /dev/null 2>&1
    if cmp -s "$SF_EXCLUDE" "$SF_T/exclude.before"; then pass "git-worktree-remove-restores"; else fail "git-worktree-remove-restores"; fi
  else
    fail "git-worktree-link-is-ignored" "could not make a worktree fixture"
  fi
  # a template with no info/ at all: the file and its folder are made, and taken away again
  mkdir -p "$SF_T/empty-template"; sf_git init -q --template="$SF_T/empty-template" "$SF_T/bare-template"
  sf_cli add "$SF_T/bare-template/acme" "Clients/Acme" > /dev/null 2>&1
  sf_git -C "$SF_T/bare-template" check-ignore -q acme; rc=$?
  sf_cli remove "$SF_T/bare-template/acme" > /dev/null 2>&1
  same "git-no-info-dir-made-then-removed" "$rc $([ -e "$SF_T/bare-template/.git/info" ] && echo left-behind)" "0 "
else
  fail "git-add-appends-exactly-two-lines" "no git to make a fixture repo with"
fi

# ── 4. every sync client's root is refused, by the CLI and by the module's own reader ────────────
SF_H="$SF_T/synchome"
mkdir -p "$SF_H/.dropbox" "$SF_H/Library/Preferences" "$SF_T/moved-dropbox" "$SF_H/plain" "$SF_H/Desktop"
printf '{"personal": {"path": "%s"}}\n' "$SF_T/moved-dropbox" > "$SF_H/.dropbox/info.json"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>FXICloudDriveDocuments</key><true/><key>FXICloudDriveDesktop</key><false/></dict></plist>\n' \
  > "$SF_H/Library/Preferences/com.apple.finder.plist"
SF_FAMILIES="Library/CloudStorage/Dropbox|Library/CloudStorage/GoogleDrive-a@b.example|Library/CloudStorage/Box-Box|Library/CloudStorage/OneDrive-Other|Library/Mobile Documents/com~apple~CloudDocs|Dropbox|Dropbox (Acme)|Google Drive|My Drive|Box|Box Sync|OneDrive|OneDrive - Contoso|Documents"
cli_bad=""; mod_bad=""
while IFS= read -r fam; do
  [ -n "$fam" ] || continue
  mkdir -p "$SF_H/$fam"
  HOME="$SF_H" BOOTSTRAP_STATE_DIR="$SF_T/state" SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/managed" \
    /bin/bash "$SF_CLI" add "$SF_H/$fam/link" "Clients/Acme" > /dev/null 2>&1; rc=$?
  [ "$rc" = 23 ] && [ ! -L "$SF_H/$fam/link" ] || cli_bad="$cli_bad [$fam: rc $rc]"
  ( HOME="$SF_H"; export HOME; . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1; . "$CHECK_ROOT/modules/shared_folders.sh"
    shared_folders_under_cloud "$SF_H/$fam/link" ) || mod_bad="$mod_bad [$fam]"
done <<SF_EOF
$(printf '%s\n' "$SF_FAMILIES" | tr '|' '\n')
SF_EOF
HOME="$SF_H" BOOTSTRAP_STATE_DIR="$SF_T/state" SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" /bin/bash "$SF_CLI" add "$SF_T/moved-dropbox/link" "Clients/Acme" > /dev/null 2>&1
[ $? = 23 ] || cli_bad="$cli_bad [Dropbox moved by info.json]"
same "cli-refuses-every-sync-root" "$cli_bad" ""
same "module-sees-every-sync-root" "$mod_bad" ""
for plain in plain Desktop; do
  HOME="$SF_H" BOOTSTRAP_STATE_DIR="$SF_T/state" SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" /bin/bash "$SF_CLI" add "$SF_H/$plain/link" "Clients/Acme" > /dev/null 2>&1; rc=$?
  same "sync-negative-control-$plain" "$rc" "0"
  HOME="$SF_H" BOOTSTRAP_STATE_DIR="$SF_T/state" SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" /bin/bash "$SF_CLI" remove "$SF_H/$plain/link" > /dev/null 2>&1
done

# ── 5. the module through the driver: policy and a committed link are NEEDS_HUMAN, never SATISFIED ─
SF_DH="$(fresh_home shared-folders)"
mkdir -p "$SF_T/block/Library/Managed Preferences" "$SF_DH/proj"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>BlockExternalSync</key><true/></dict></plist>\n' \
  > "$SF_T/block/Library/Managed Preferences/com.microsoft.OneDrive.plist"
sf_state() { json_at "$SF_DH/.mac-bootstrap/receipt.json" "modules.0.$1"; }
# The tool is put in place by the module's own install_ (no driver run, so no verify, so no selftest),
# and a link added; then every driver run below is one question with one answer.
( HOME="$SF_DH"; BOOTSTRAP_ASSETS="$CHECK_ROOT/assets"; SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud"; BOOTSTRAP_MANAGED_ROOT="$SF_T/managed"
  export HOME BOOTSTRAP_ASSETS SHARED_FOLDERS_CLOUD_DIR BOOTSTRAP_MANAGED_ROOT
  . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1; . "$CHECK_ROOT/modules/shared_folders.sh"
  install_shared_folders >/dev/null 2>&1 && "$(shared_folders_bin)" add "$SF_DH/links/acme" "Clients/Acme" > /dev/null 2>&1 )
SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/managed" drive_at "$SF_DH" --only shared_folders
same "module-with-a-link-satisfied" "$CHECK_RC $(sf_state state)" "0 SATISFIED"
SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/block" drive_at "$SF_DH" --only shared_folders
same "module-policy-blocked-is-needs-human" "$(sf_state state)" "NEEDS_HUMAN"
case "$(sf_state note)" in *BlockExternalSync*"ask IT"*) pass "module-policy-note-says-ask-it" ;; *) fail "module-policy-note-says-ask-it" "$(sf_state note)" ;; esac
same "module-policy-offers-no-command" "$(sf_state human_command)" ""
if command -v git >/dev/null 2>&1 && sf_git init -q "$SF_DH/proj"; then
  cp "$SF_DH/proj/.git/info/exclude" "$SF_T/proj-exclude.before" 2>/dev/null || : > "$SF_T/proj-exclude.before"
  HOME="$SF_DH" SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/managed" \
    "$SF_DH/.mac-bootstrap/bin/shared-folder" add "$SF_DH/proj/acme" "Clients/Acme" > /dev/null 2>&1
  sf_git -C "$SF_DH/proj" add -f acme && sf_git -C "$SF_DH/proj" commit -q -m "a link that should never have been committed"
  SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/managed" drive_at "$SF_DH" --only shared_folders
  same "module-committed-link-is-needs-human" "$(sf_state state)" "NEEDS_HUMAN"
  # The gesture is a command executable as typed: run it, and the next run is satisfied.
  SF_GESTURE="$(sf_state human_command)"
  ( cd "$SF_T" && HOME="$SF_DH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 /bin/bash -c "$SF_GESTURE" ) > /dev/null 2>&1
  same "module-gesture-untracks-the-link" "$(sf_git -C "$SF_DH/proj" ls-files | tr '\n' ' ')" ""
  SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/managed" drive_at "$SF_DH" --only shared_folders
  same "module-after-the-gesture-satisfied" "$(sf_state state)" "SATISFIED"
  sf_git -C "$SF_DH/proj" commit -q -m "untrack the link"
fi
# uninstall takes out exactly the exclude lines it wrote, and nothing is left behind in the repo
SHARED_FOLDERS_CLOUD_DIR="$SF_T/cloud" BOOTSTRAP_MANAGED_ROOT="$SF_T/managed" drive_at "$SF_DH" --uninstall --only shared_folders
if [ -d "$SF_DH/proj/.git" ]; then
  same "module-uninstall-untouches-git" "$(sf_git -C "$SF_DH/proj" status --porcelain --untracked-files=all | tr '\n' ' ')$([ -L "$SF_DH/proj/acme" ] && echo link-left)" ""
  if cmp -s "$SF_DH/proj/.git/info/exclude" "$SF_T/proj-exclude.before"; then pass "module-uninstall-restores-the-exclude-file"
  else fail "module-uninstall-restores-the-exclude-file" "$(diff "$SF_T/proj-exclude.before" "$SF_DH/proj/.git/info/exclude" | tr '\n' ' ')"; fi
fi

# ── 6. no network of its own: egress declared empty, and install never fetches ───────────────────
out="$( . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1; . "$CHECK_ROOT/modules/shared_folders.sh"
        command -v egress_shared_folders >/dev/null || { echo UNDECLARED; exit; }; egress_shared_folders )"
same "egress-declared-and-empty" "$out" ""
drive_at "$(fresh_home shared-folders-egress)" --egress --only shared_folders
case "$(printf '%s\n' "$CHECK_OUT" | grep -E '^ +shared_folders ')" in
  *"none — no network at all"*) pass "egress-report-says-no-network" ;;
  *) fail "egress-report-says-no-network" "$(printf '%s\n' "$CHECK_OUT" | grep -E 'shared_folders' | head -2 | tr '\n' ' ')" ;; esac
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$SF_T/curl.log" > "$SF_T/stub/curl"; chmod 755 "$SF_T/stub/curl"
: > "$SF_T/curl.log"
( HOME="$SF_T/nofetch"; PATH="$SF_T/stub:/usr/bin:/bin"; BOOTSTRAP_ASSETS="$SF_T/no-release-tree"; BOOTSTRAP_PIN=0123456789abcdef0123456789abcdef01234567
  BOOTSTRAP_RAW="https://example.invalid"; export HOME PATH BOOTSTRAP_ASSETS BOOTSTRAP_PIN BOOTSTRAP_RAW; mkdir -p "$HOME"
  . "$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" >/dev/null 2>&1; . "$CHECK_ROOT/modules/shared_folders.sh"
  install_shared_folders >/dev/null 2>&1; echo "$?" > "$SF_T/nofetch.rc" )
same "install-never-fetches-its-own-code" "$(cat "$SF_T/nofetch.rc")|$(cat "$SF_T/curl.log")" "1|"

# ── clearance_ — "<class> <clause>" lines, the views disclosed as copies outside DLP ──────────────
out="$(env HOME="$SF_T/home" BOOTSTRAP_STATE_DIR="$SF_T/state" BOOTSTRAP_LIB="$CHECK_ROOT/assets/hooks/bootstrap-lib.sh" /bin/bash -c \
  '. "$BOOTSTRAP_LIB"; . "$1"; clearance_shared_folders; printf "|"; cost_shared_folders' x "$CHECK_ROOT/modules/shared_folders.sh" 2>/dev/null)"
bad="$(printf '%s\n' "${out%%|*}" | awk 'NF && !($1 ~ /^(data|background|trust|permission|software|agent)$/ && NF >= 4) { print "[" $0 "]" }')"
case "$out" in
  "data "*".views/"*"DLP, retention and eDiscovery"*"|"*COPIES*"DLP, retention and eDiscovery"*) [ -z "$bad" ] && pass "shared-folders-clearance" || fail "shared-folders-clearance" "$bad" ;;
  *) fail "shared-folders-clearance" "$out" ;;
esac
