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

# 2b. When tarball, git and raw are all blocked — measured on a live proxy that allowed only
#     api.github.com — jsDelivr's copy of the commit answers, and failing that GitHub's contents API.
TREE_NOPE="file://$CHECK_TMP/no-such"
h="$(fresh_home tree-jsdelivr)"
tree_run "$h" BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="$TREE_NOPE" BOOTSTRAP_TARBALL="$TREE_NOPE.tgz" \
  BOOTSTRAP_GIT_URL="$TREE_NOPE.git" BOOTSTRAP_JSDELIVR="file://$TREE_MIRROR" BOOTSTRAP_GITHUB_API="$TREE_NOPE" -- --only "$TREE_FIRST"
same "tree-from-jsdelivr-rc" "$CHECK_RC" 0
mkdir -p "$CHECK_TMP/api/repos/renchris/mac-bootstrap" && ln -sfn "$TREE_MIRROR" "$CHECK_TMP/api/repos/renchris/mac-bootstrap/contents"
h="$(fresh_home tree-api)"
tree_run "$h" BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="$TREE_NOPE" BOOTSTRAP_TARBALL="$TREE_NOPE.tgz" \
  BOOTSTRAP_GIT_URL="$TREE_NOPE.git" BOOTSTRAP_JSDELIVR="$TREE_NOPE" BOOTSTRAP_GITHUB_API="file://$CHECK_TMP/api" -- --only "$TREE_FIRST"
same "tree-from-github-api-rc" "$CHECK_RC" 0
# …and the control: with every route blocked, the run says why for each of the five, and exits 30.
h="$(fresh_home tree-none)"
tree_run "$h" BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="$TREE_NOPE" BOOTSTRAP_TARBALL="$TREE_NOPE.tgz" \
  BOOTSTRAP_GIT_URL="$TREE_NOPE.git" BOOTSTRAP_JSDELIVR="$TREE_NOPE" BOOTSTRAP_GITHUB_API="$TREE_NOPE" -- --only "$TREE_FIRST"
case "$CHECK_RC:$CHECK_OUT" in
  30:*jsdelivr:*api:*) pass "control-tree-no-route-names-all-five" ;;
  *) fail "control-tree-no-route-names-all-five" "rc $CHECK_RC: $(printf '%s' "$CHECK_OUT" | grep -m3 -E 'tarball|jsdelivr|api' | tr '\n' ' ')" ;;
esac

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


# ── A person at a real terminal: script(1) gives the run a pseudo-terminal. tree_type waits for the
#    prompt to be on screen before typing, as a person does; keys typed earlier are discarded (check 7).
tree_wait() {                                   # tree_wait <log> <text> <occurrence> — up to 60 s
  local w=0
  while [ "$(tr -d '\r' < "$1" 2>/dev/null | grep -c "$2")" -lt "$3" ] && [ "$w" -lt 120 ]; do sleep 0.5; w=$((w + 1)); done
}
tree_pty() {                                    # tree_pty <home> <log> <answers-script> — cat ./bootstrap.sh | bash, in a pty
  local h="$1" log="$2" answers="$3"
  : > "$log"
  # The screen is script(1)'s STDOUT, written as it arrives; its transcript file is buffered until exit
  # (measured: a waiter polling the file never saw the prompt), so the waiter reads the stdout copy.
  "$answers" "$log" "$h" | ( cd "$TREE_ENTRY" && env -u CLAUDECODE -u CI HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_PICK_TIMEOUT=20 \
      BOOTSTRAP_PIN="$TREE_PIN" BOOTSTRAP_RAW="file://$TREE_MIRROR" \
      /usr/bin/script -q /dev/null /bin/bash -c 'cat ./bootstrap.sh | /bin/bash' ) > "$log" 2>&1
}
tree_answers_choose_first() {                   # none 1 → Enter → y, each once its question is showing
  tree_wait "$1" 'Press Enter' 1; printf 'none 1\n'
  tree_wait "$1" 'Press Enter' 2; printf '\n'
  tree_wait "$1" 'Install these now' 1; printf 'y\n'
  local w=0; while [ ! -e "$2/.mac-bootstrap/receipt.json" ] && [ "$w" -lt 120 ]; do sleep 0.5; w=$((w + 1)); done
}
tree_answers_typeahead() {                      # two Enters BEFORE the menu exists, then nothing
  printf '\n\n'
  tree_wait "$1" 'gives up after' 1; sleep 1
}

if [ -x /usr/bin/script ]; then
  # 6. THE ONE COMMAND, as a person meets it: `curl … | bash`. The released script, a verified tree,
  #    the menu read from the terminal because stdin is the script, and the install — no network.
  h="$(fresh_home tree-pipe)"
  tree_pty "$h" "$CHECK_WORK/tree-pipe.log" tree_answers_choose_first
  case "$(tr -d '\r' < "$CHECK_WORK/tree-pipe.log" 2>/dev/null)" in
    *"Pick what to install"*) pass "pipe-to-bash-shows-the-menu" ;;
    *) fail "pipe-to-bash-shows-the-menu" "$(tr -d '\r' < "$CHECK_WORK/tree-pipe.log" 2>/dev/null | grep -m1 bootstrap:)" ;;
  esac
  same "pipe-to-bash-installs-the-choice" "$(receipt_states "$h/.mac-bootstrap/receipt.json" | tr '\n' ' ')" "$TREE_FIRST SATISFIED "

  # 7. Keys pressed before the menu was on screen are not consent. Measured before the drain: two
  #    stray Enters installed the preselected list with exit 0. Now they are discarded, the menu waits,
  #    and at its timeout nothing has been installed.
  h="$(fresh_home tree-typeahead)"
  tree_pty "$h" "$CHECK_WORK/tree-typeahead.log" tree_answers_typeahead
  if [ -e "$h/.mac-bootstrap/receipt.json" ] || [ -e "$h/.claude" ]; then fail "typeahead-is-not-consent" "something was installed"
  else pass "typeahead-is-not-consent"; fi
else
  pass "pipe-to-bash-shows-the-menu" "n/a: no /usr/bin/script"
fi

# 8. Under `curl | bash`, stdin is the rest of the script. A module that reads stdin must neither eat
#    the driver nor hang: measured before the fix, one swallowed 4,227 bytes and the run exited 0 with
#    no verdict. A release carrying such a module still prints its verdict and writes its receipt.
TREE_EAT_MIRROR="$CHECK_TMP/mirror-eat/t"; mkdir -p "$CHECK_TMP/mirror-eat" && cp -R "$TREE_MIRROR" "$TREE_EAT_MIRROR"
cat > "$TREE_EAT_MIRROR/modules/stdin_reader.sh" <<'MODULE_EOF'
# shellcheck shell=bash
verify_stdin_reader()  { [ -e "$HOME/.stdin-reader-ran" ]; }
gate_stdin_reader()    { return 1; }
note_stdin_reader()    { printf 'not run'; }
gesture_stdin_reader() { :; }
install_stdin_reader() { cat > "$HOME/.stdin-reader-ate"; : > "$HOME/.stdin-reader-ran"; }
uninstall_stdin_reader() { rm -f "$HOME/.stdin-reader-ran" "$HOME/.stdin-reader-ate"; }
MODULE_EOF
{ cat "$CHECK_WORK/tree-manifest"; printf '%s  modules/stdin_reader.sh\n' "$(shasum -a 256 "$TREE_EAT_MIRROR/modules/stdin_reader.sh" | cut -d' ' -f1)"; } > "$CHECK_WORK/tree-eat-manifest"
mkdir -p "$CHECK_TMP/entry-eat"; tree_stamp "$CHECK_WORK/tree-eat-manifest" "$CHECK_TMP/entry-eat/bootstrap.sh"
h="$(fresh_home tree-eat)"
CHECK_OUT="$(cd "$CHECK_TMP/entry-eat" && cat ./bootstrap.sh | env HOME="$h" BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_PIN="$TREE_PIN" \
             BOOTSTRAP_RAW="file://$TREE_EAT_MIRROR" /bin/bash -s -- --only stdin_reader 2>&1)"; CHECK_RC=$?
same "stdin-reading-module-cannot-eat-the-driver" "$CHECK_RC/$(json_at "$h/.mac-bootstrap/receipt.json" exit_code)/$(wc -c < "$h/.stdin-reader-ate" 2>/dev/null | tr -d ' ')" "0/0/0"

# 9. The git route — the one a network that allows only github.com leaves open — used alone. Its
#    manifest is of a real commit (HEAD), so git can fetch it from this clone over file://.
if git -C "$CHECK_ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1 && /usr/bin/xcode-select -p >/dev/null 2>&1; then
  TREE_HEAD="$(git -C "$CHECK_ROOT" rev-parse HEAD)"
  { printf 'pin %s\n' "$TREE_HEAD"
    git -C "$CHECK_ROOT" ls-tree -r --name-only "$TREE_HEAD" -- modules assets | grep -v '^assets/diagrams/' | while IFS= read -r rel; do
      printf '%s  %s\n' "$(git -C "$CHECK_ROOT" show "$TREE_HEAD:$rel" | shasum -a 256 | cut -d' ' -f1)" "$rel"; done
  } > "$CHECK_WORK/tree-git-manifest"
  mkdir -p "$CHECK_TMP/entry-git"; tree_stamp "$CHECK_WORK/tree-git-manifest" "$CHECK_TMP/entry-git/bootstrap.sh"
  h="$(fresh_home tree-git)"
  CHECK_OUT="$(cd "$CHECK_TMP/entry-git" && env HOME="$h" BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_PIN="$TREE_HEAD" \
               BOOTSTRAP_TARBALL="file://$CHECK_TMP/no-tarball" BOOTSTRAP_GIT_URL="file://$CHECK_ROOT" \
               BOOTSTRAP_RAW="file://$CHECK_TMP/no-mirror" /bin/bash ./bootstrap.sh --only "$TREE_FIRST" 2>&1)"; CHECK_RC=$?
  same "tree-from-git-alone-rc" "$CHECK_RC" 0
  case "$CHECK_OUT" in *"tarball"*) fail "tree-failed-routes-are-silent-on-success" ;; *) pass "tree-failed-routes-are-silent-on-success" ;; esac
  # …and when every route fails, each one says why.
  h="$(fresh_home tree-noroute)"
  CHECK_OUT="$(cd "$CHECK_TMP/entry-git" && env HOME="$h" BOOTSTRAP_NONINTERACTIVE=1 BOOTSTRAP_PIN="$TREE_HEAD" \
               BOOTSTRAP_TARBALL="file://$CHECK_TMP/no-tarball" BOOTSTRAP_GIT_URL="file://$CHECK_TMP/no-repo" \
               BOOTSTRAP_RAW="file://$CHECK_TMP/no-mirror" /bin/bash ./bootstrap.sh --only "$TREE_FIRST" 2>&1)"; CHECK_RC=$?
  TREE_WHY="$(printf '%s\n' "$CHECK_OUT" | grep -c -E '^ +(tarball|git|files): ' | tr -d ' ')"
  same "tree-every-route-says-why" "$CHECK_RC/$TREE_WHY" "30/3"
else
  pass "tree-from-git-alone-rc" "n/a: no git with Command Line Tools here"
fi
