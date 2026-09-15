# shellcheck shell=bash
# scripts/checks/release-tree.sh — a curl'd bootstrap.sh, run with nothing beside it. Sourced by
# scripts/characterize.sh, which supplies the harness; never run on its own.
#
# A clone never exercises this path — modules/ is beside the script — which is how a whole class of
# release defect has shipped before. So this builds, from the working tree, exactly what a release
# publishes: a copy of bootstrap.sh stamped with a manifest of every module and asset, and a mirror
# holding those files, served over file:// so no network is involved. Then it runs the copy from an
# empty directory, the way a person's /tmp/mac-bootstrap.sh runs, and tampers with one byte to prove
# the manifest is what decides — not where the bytes came from.

TREE_PIN="0000000000000000000000000000000000c0ffee"
TREE_MIRROR="$CHECK_TMP/mirror/mac-bootstrap-$TREE_PIN"
TREE_ENTRY="$CHECK_TMP/entry"
mkdir -p "$TREE_MIRROR" "$TREE_ENTRY"

# The payload a release publishes: every tracked module and asset except the README's pictures.
( cd "$CHECK_ROOT" && git ls-files -- modules assets 2>/dev/null | grep -v '^assets/diagrams/' ) > "$CHECK_WORK/tree-files"
{ printf 'pin %s\n' "$TREE_PIN"
  while IFS= read -r rel; do
    mkdir -p "$TREE_MIRROR/$(dirname "$rel")" && cp -f "$CHECK_ROOT/$rel" "$TREE_MIRROR/$rel"
    printf '%s  %s\n' "$(shasum -a 256 "$CHECK_ROOT/$rel" | cut -d' ' -f1)" "$rel"
  done < "$CHECK_WORK/tree-files"
} > "$CHECK_WORK/tree-manifest"
# The same substitution scripts/release.sh makes: everything between the markers is replaced.
tree_stamp() {                                  # tree_stamp <manifest> <out>
  awk -v mf="$1" '
    /^BOOTSTRAP_RELEASE_MANIFEST$/ { skip = 0 }
    !skip { print }
    /<<'\''BOOTSTRAP_RELEASE_MANIFEST'\''$/ { while ((getline l < mf) > 0) print l; skip = 1 }
  ' "$CHECK_ROOT/bootstrap.sh" > "$2"
}
tree_stamp "$CHECK_WORK/tree-manifest" "$TREE_ENTRY/bootstrap.sh"
( cd "$CHECK_TMP/mirror" && tar -czf "$CHECK_WORK/tree.tgz" "mac-bootstrap-$TREE_PIN" )

tree_run() {                                    # tree_run <home> <env assignments…> -- <args…>
  local h="$1"; shift
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  CHECK_OUT="$(cd "$TREE_ENTRY" && env HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_NONINTERACTIVE=1 "${envs[@]}" \
               /bin/bash "$TREE_ENTRY/bootstrap.sh" "$@" 2>&1)"; CHECK_RC=$?
}
TREE_FIRST="$(printf '%s\n' "$MODULES" | head -1)"

# 1. From a mirror, file by file: the tree arrives, every file verifies, and the module installs.
h="$(fresh_home tree-mirror)"
tree_run "$h" BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="file://$TREE_MIRROR" -- --only "$TREE_FIRST"
same "tree-from-mirror-rc" "$CHECK_RC" 0
if ( cd "$h/.mac-bootstrap/release/$TREE_PIN" 2>/dev/null && grep -v '^pin ' "$CHECK_WORK/tree-manifest" | shasum -a 256 -c --status - ); then
  pass "tree-from-mirror-verifies" "$(grep -vc '^pin ' "$CHECK_WORK/tree-manifest" | tr -d ' ') files, re-checked by a second reader"
else fail "tree-from-mirror-verifies" "the tree on disk does not match the manifest"; fi
if [ -e "$h/.mac-bootstrap/release/$TREE_PIN/README.md" ] || [ -e "$h/.mac-bootstrap/release/$TREE_PIN/bootstrap.sh" ]; then
  fail "tree-holds-only-the-manifest" "a file the manifest does not name landed in the tree"
else pass "tree-holds-only-the-manifest"; fi

# 2. From the tarball alone (the mirror named here does not exist, so only the tarball can serve it).
h="$(fresh_home tree-tarball)"
tree_run "$h" BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="file://$CHECK_TMP/no-such-mirror" BOOTSTRAP_TARBALL="file://$CHECK_WORK/tree.tgz" -- --only "$TREE_FIRST"
same "tree-from-tarball-rc" "$CHECK_RC" 0

# 3. NEGATIVE CONTROL — one byte changed in one module: refused before anything is sourced or written.
cp -R "$CHECK_TMP/mirror" "$CHECK_TMP/mirror-bad"
printf '\n# one extra byte\n' >> "$CHECK_TMP/mirror-bad/mac-bootstrap-$TREE_PIN/modules/$TREE_FIRST.sh"
h="$(fresh_home tree-tampered)"
tree_run "$h" BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="file://$CHECK_TMP/mirror-bad/mac-bootstrap-$TREE_PIN" -- --only "$TREE_FIRST"
same "tree-tampered-rc" "$CHECK_RC" 30
case "$CHECK_OUT" in *"modules/$TREE_FIRST.sh"*) pass "tree-tampered-names-the-file" ;;
  *) fail "tree-tampered-names-the-file" "$(printf '%s' "$CHECK_OUT" | grep -m1 'could not')" ;; esac
if [ -e "$h/.claude" ] || [ -e "$h/.mac-bootstrap/release/$TREE_PIN" ]; then fail "tree-tampered-writes-nothing"
else pass "tree-tampered-writes-nothing"; fi

# 4. A pin the manifest does not describe is refused — the list cannot vouch for another tree.
h="$(fresh_home tree-otherpin)"
tree_run "$h" BOOTSTRAP_PIN="1111111111111111111111111111111111111111" BOOTSTRAP_RAW="file://$TREE_MIRROR" -- --only "$TREE_FIRST"
same "tree-other-pin-rc" "$CHECK_RC" 30

# 5. A bootstrap.sh with no manifest at all fetches nothing.
awk '/<<'\''BOOTSTRAP_RELEASE_MANIFEST'\''$/ { print; skip = 1; next } /^BOOTSTRAP_RELEASE_MANIFEST$/ { skip = 0 } !skip { print }' \
  "$CHECK_ROOT/bootstrap.sh" > "$TREE_ENTRY/unstamped.sh"
h="$(fresh_home tree-unstamped)"
CHECK_OUT="$(cd "$TREE_ENTRY" && HOME="$h" BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="file://$TREE_MIRROR" /bin/bash "$TREE_ENTRY/unstamped.sh" --list 2>&1)"; CHECK_RC=$?
same "tree-no-manifest-rc" "$CHECK_RC" 30

# 6. THE ONE COMMAND, as a person meets it: `curl … | bash`, with a person at the terminal. Stdin is
#    the SCRIPT, so the menu must read the terminal; script(1) gives the run a real pseudo-terminal.
#    The answers are typed while stdin stays open, as a person's would be — closing it early sends
#    end-of-input, which picker.sh covers. The released script, a verified tree, the menu, the
#    install: every piece of the standalone path in one run, with no network.
if [ -x /usr/bin/script ]; then
  h="$(fresh_home tree-pipe)"
  ( printf 'none 1\n\ny\n'
    w=0; while [ ! -e "$h/.mac-bootstrap/receipt.json" ] && [ "$w" -lt 90 ]; do sleep 1; w=$((w + 1)); done
  ) | ( cd "$TREE_ENTRY" && env -u CLAUDECODE -u CI HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_PICK_TIMEOUT=60 \
          BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="file://$TREE_MIRROR" \
          /usr/bin/script -q "$CHECK_WORK/tree-pipe.log" /bin/bash -c 'cat ./bootstrap.sh | /bin/bash' ) >/dev/null 2>&1
  case "$(tr -d '\r' < "$CHECK_WORK/tree-pipe.log" 2>/dev/null)" in
    *"Pick what to install"*) pass "pipe-to-bash-shows-the-menu" ;;
    *) fail "pipe-to-bash-shows-the-menu" "$(tr -d '\r' < "$CHECK_WORK/tree-pipe.log" 2>/dev/null | grep -m1 bootstrap:)" ;;
  esac
  same "pipe-to-bash-installs-the-choice" "$(receipt_states "$h/.mac-bootstrap/receipt.json" | tr '\n' ' ')" "$TREE_FIRST SATISFIED "
else
  pass "pipe-to-bash-shows-the-menu" "n/a: no /usr/bin/script"
fi
