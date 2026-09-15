# shellcheck shell=bash
# scripts/checks/shared-folders.sh — a client's shared folder: nothing of it leaves the Mac. Sourced by
# scripts/characterize.sh, which supplies the harness; never run on its own.
#
# The promise is "no second copy, nothing leaves", and each way it could break is checked by what
# ACTUALLY happens, never by a phrase. Fixtures only: no network, no real tool installed.

SF_T="$CHECK_TMP/shared-folders"
mkdir -p "$SF_T/stub" "$SF_T/home" "$SF_T/state" "$SF_T/managed" "$SF_T/cloud/OneDrive-Contoso/Clients/Acme"
printf '# brief\n' > "$SF_T/cloud/OneDrive-Contoso/Clients/Acme/brief.md"

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
