#!/bin/bash
# scripts/release.sh — cut a release, and PROVE both hops before calling it one.
#
#   bash scripts/release.sh           cut a release from the current HEAD
#   bash scripts/release.sh --check   re-verify the release the README already points at
#   bash scripts/release.sh --dry     say what it would do; write nothing, push nothing
#
# ── THE CIRCULARITY, and why the pin names the PARENT ────────────────────────────────────────
# bootstrap.sh is fetched on its own, so modules/ and assets/ are not beside it: it MUST fetch
# them, and from an IMMUTABLE ref — a branch name serves up to five minutes of stale CDN bytes
# (cache-control: max-age=300, measured). That ref cannot be the commit that carries it, because
# a commit cannot contain its own sha. The first release shipped the literal placeholder
# `__PIN_SHA__` for exactly this reason, and every fetch refused: EXIT 30 on both documented
# entry points, on a repo that was otherwise complete and public.
#
# So the pin names a commit that ALREADY EXISTS: the content commit the release is cut from.
#
#   X   content commit, already pushed ......... BOOTSTRAP_PIN points here — modules/ and assets/
#   Y   release commit, one line of bootstrap.sh  the README's curl URL points here
#   Z   docs commit, README only ............... what a reader sees at the head of main
#
# Y changes the pin line and the release manifest block beneath it — the sha256 of every module and
# asset at X, which the driver checks every fetched byte against — and nothing else, so every module
# and asset the driver fetches from X is byte-identical to the one that sat beside it when it was
# tested, and PROVABLY so from whichever host served it. The alternative — inlining
# the modules into bootstrap.sh — removes the second hop entirely but turns the only entry point
# into a ~200 KB generated artifact and gives this repo a build step it deliberately does not
# have.
#
# ── IT VERIFIES BY INDEPENDENT READ-BACK ─────────────────────────────────────────────────────
# Never by grepping for a phrase it just wrote. It re-fetches the published bootstrap.sh
# anonymously, reads the pin back OUT of those bytes, then fetches bootstrap-lib.sh and every module
# and asset at that pin and compares each sha256 against `git show <pin>:<path>`. A release that
# cannot be fetched is not a release — which is the one thing the first one was never asked.

set -u

RELEASE_REPO="renchris/mac-bootstrap"
RELEASE_MODE="cut"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   RELEASE_MODE=check ;;
    --dry)     RELEASE_MODE=dry ;;
    --help|-h) sed -n '2,45p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'release: unknown argument: %s   (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

RELEASE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'release: not inside a git checkout\n' >&2; exit 2; }
cd "$RELEASE_ROOT" || exit 2

release_say()  { printf '%s\n' "$*"; }
release_fail() { printf 'release: %s\n' "$*" >&2; }

# ── read-back helpers ────────────────────────────────────────────────────────────────────────
release_raw() { printf 'https://raw.githubusercontent.com/%s/%s/%s' "$RELEASE_REPO" "$1" "$2"; }

release_fetch() {                                    # release_fetch <ref> <relpath> <dest> → 0 on a real 200
  local code
  code="$(curl -sS -L -o "$3.part" -w '%{http_code}' "$(release_raw "$1" "$2")" 2>/dev/null)" || {
    rm -f "$3.part" 2>/dev/null; return 1; }
  [ "$code" = "200" ] || { rm -f "$3.part" 2>/dev/null; return 1; }
  [ -s "$3.part" ] || { rm -f "$3.part" 2>/dev/null; return 1; }
  mv -f "$3.part" "$3"
}

release_sha_file() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
release_sha_blob() { git show "$1:$2" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

# The files a standalone bootstrap.sh has to fetch: every module, and every asset except the
# rendered diagrams, which only the README consumes.
release_payload() { git ls-tree -r --name-only "$1" -- modules assets 2>/dev/null | grep -v '^assets/diagrams/'; }

# release_manifest <ref> — the block the driver verifies against: the tree it describes, then one
# `<sha256>  <path>` line per payload file, computed from git's own blobs, never from a working tree.
release_manifest() {
  local rel
  printf 'pin %s\n' "$1"
  for rel in $(release_payload "$1"); do printf '%s  %s\n' "$(release_sha_blob "$1" "$rel")" "$rel"; done
}

# release_embedded_manifest <bootstrap.sh> — the block as a published file carries it.
release_embedded_manifest() {
  awk '/^BOOTSTRAP_RELEASE_MANIFEST$/ { on = 0 } on { print } /<<'\''BOOTSTRAP_RELEASE_MANIFEST'\''$/ { on = 1 }' "$1"
}

# release_verify <readme_ref> — the whole claim, from outside, with no local file trusted.
release_verify() {
  local ref="$1" tmp boot pin rel got want n=0 bad=0 prompt_bad=0
  tmp="$(mktemp -d)" || return 1
  boot="$tmp/bootstrap.sh"

  release_say "  hop 1: bootstrap.sh @ ${ref}"
  if ! release_fetch "$ref" bootstrap.sh "$boot"; then
    release_fail "hop 1 FAILED: cannot fetch bootstrap.sh at $ref"; rm -rf "$tmp"; return 1
  fi
  release_say "         $(release_sha_file "$boot")  $(wc -l < "$boot" | tr -d ' ') lines"

  # The pin, read back out of the PUBLISHED bytes — not out of the working tree.
  # BOTH spellings, and this is deliberate. This function reads a PUBLISHED release, which may be
  # any release this repo has ever cut — and releases before 2026-09-12 spell the variable MB_PIN.
  # A reader that only knows today's spelling cannot check yesterday's release, which is exactly
  # the check that matters when someone reports that an old pasted URL stopped working.
  pin="$(sed -n 's/^BOOTSTRAP_PIN="\${BOOTSTRAP_PIN:-\([^}]*\)}".*/\1/p' "$boot" | head -1)"
  [ -n "$pin" ] || pin="$(sed -n 's/^MB_PIN="\${MB_PIN:-\([^}]*\)}".*/\1/p' "$boot" | head -1)"
  case "$pin" in
    ''|__PIN_SHA__|main|master)
      release_fail "hop 2 IMPOSSIBLE: the published bootstrap.sh carries pin '$pin'."
      release_fail "  Every module and asset fetch refuses before any network call. Cut a release."
      rm -rf "$tmp"; return 1 ;;
  esac
  case "$pin" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) release_fail "hop 2 REFUSED: pin '$pin' is not a commit sha"; rm -rf "$tmp"; return 1 ;;
  esac
  release_say "  hop 2: payload @ ${pin}"

  # The manifest inside the PUBLISHED bytes must describe the pinned tree exactly — every payload
  # file, each with git's own sha256, nothing extra — or the driver will refuse every fetch. A
  # release cut before the manifest existed carries none, and says so rather than failing.
  if grep -q "<<'BOOTSTRAP_RELEASE_MANIFEST'" "$boot"; then
    if [ "$(release_embedded_manifest "$boot")" = "$(release_manifest "$pin")" ]; then
      release_say "         manifest: $(release_embedded_manifest "$boot" | grep -vc '^pin ' | tr -d ' ') files, matching the pinned tree"
    else
      release_fail "hop 2 REFUSED: the published manifest does not describe the tree at $pin"
      rm -rf "$tmp"; return 1
    fi
  else
    release_say "         (a release from before the manifest: no embedded manifest to check)"
  fi

  for rel in $(release_payload "$pin"); do
    n=$((n + 1))
    if ! release_fetch "$pin" "$rel" "$tmp/blob"; then
      release_fail "  MISSING  $rel"; bad=$((bad + 1)); continue
    fi
    got="$(release_sha_file "$tmp/blob")"
    want="$(release_sha_blob "$pin" "$rel")"
    if [ -n "$want" ] && [ "$got" != "$want" ]; then
      release_fail "  MISMATCH $rel"; bad=$((bad + 1))
    fi
  done
  # Hop 3 — the one prompt's own LOOKING commands, run against the PUBLISHED script in a throwaway HOME.
  # A README can cite a flag the published script does not have: measured once, `--egress` against a
  # pin without it answered "unknown argument". Only a Mac can run the driver (plutil, sw_vers), so a
  # Linux runner says it skipped rather than claiming a pass.
  if ! grep -q "<<'BOOTSTRAP_RELEASE_MANIFEST'" "$boot"; then
    release_say "  hop 3: skipped — a release from before the prompt's looking commands existed"
  elif [ "$(uname -s)" = Darwin ] && [ "$bad" = 0 ]; then
    local home="$tmp/home" args rc out
    mkdir -p "$home"
    for args in "--list" "--plan --profile full" "--egress" "--advise-model"; do
      # shellcheck disable=SC2086  # the flags are deliberately word-split
      out="$(cd "$tmp" && HOME="$home" BOOTSTRAP_NONINTERACTIVE=1 /bin/bash "$boot" $args 2>&1 </dev/null)"; rc=$?
      case "$rc:$args" in
        0:*|20:--egress) : ;;          # --egress exits 20 when THIS Mac has a cloud path — a finding, not a defect
        *) release_fail "hop 3 FAILED: the published script answered '$args' with exit $rc: $(printf '%s\n' "$out" | grep -m1 -E 'bootstrap:|unknown')"
           prompt_bad=$((prompt_bad + 1)) ;;
      esac
    done
    [ "$prompt_bad" = 0 ] && release_say "  hop 3: the prompt's looking commands (--list, --plan, --egress, --advise-model) all answer"
  else
    release_say "  hop 3: skipped — the driver runs only on macOS"
  fi
  rm -rf "$tmp"

  if [ "$n" = 0 ]; then
    release_fail "the pinned tree lists no modules or assets — is $pin in this checkout? (git fetch)"
    return 1
  fi
  if [ "$bad" != 0 ]; then
    release_fail "$bad of $n payload file(s) are not fetchable at the pin"
    return 1
  fi
  if [ "$prompt_bad" != 0 ]; then
    release_fail "the README's prompt runs commands the published script cannot answer ($prompt_bad of 4)"
    return 1
  fi
  release_say "         $n payload file(s) fetched anonymously, every sha256 matching the pinned tree"
  return 0
}

# ── --check ──────────────────────────────────────────────────────────────────────────────────
if [ "$RELEASE_MODE" = check ]; then
  RELEASE_README_SHA="$(grep -o '[0-9a-f]\{40\}' README.md 2>/dev/null | head -1)"
  [ -n "$RELEASE_README_SHA" ] || { release_fail "the README pins no commit sha"; exit 1; }
  release_say "checking the release the README points at: $RELEASE_README_SHA"
  release_verify "$RELEASE_README_SHA" || exit 1
  release_say "OK — both hops work anonymously from a clean environment."
  exit 0
fi

# ── cut ──────────────────────────────────────────────────────────────────────────────────────
[ -z "$(git status --porcelain)" ] || { release_fail "the tree is dirty; commit or stash first"; exit 2; }

RELEASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$RELEASE_BRANCH" = main ] || { release_fail "cut releases from main, not '$RELEASE_BRANCH'"; exit 2; }

git fetch --quiet origin main 2>/dev/null || true
RELEASE_CONTENT_COMMIT="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$RELEASE_CONTENT_COMMIT" origin/main 2>/dev/null || {
  release_fail "HEAD is not on origin/main. The pin is a raw.githubusercontent reference, so the"
  release_fail "  content commit must be PUBLISHED before anything can point at it. Push first."
  exit 2; }

RELEASE_OLD_PIN="$(sed -n 's/^BOOTSTRAP_PIN="\${BOOTSTRAP_PIN:-\([^}]*\)}".*/\1/p' bootstrap.sh | head -1)"
release_say "content commit (the pin) : $RELEASE_CONTENT_COMMIT"
release_say "pin in the working tree  : $RELEASE_OLD_PIN"

if [ "$RELEASE_OLD_PIN" = "$RELEASE_CONTENT_COMMIT" ]; then
  release_fail "bootstrap.sh already pins $RELEASE_CONTENT_COMMIT — nothing to cut. Commit content first."
  exit 2
fi

if [ "$RELEASE_MODE" = dry ]; then
  release_say ""
  release_say "would commit Y: bootstrap.sh BOOTSTRAP_PIN -> $RELEASE_CONTENT_COMMIT, and its manifest ($(release_payload "$RELEASE_CONTENT_COMMIT" | grep -c . | tr -d ' ') files)"
  release_say "would commit Z: README curl sha -> <Y>, plus its line count and sha256"
  release_say "would then verify both hops anonymously against the published bytes"
  exit 0
fi

# Y — bootstrap.sh, one line.
awk -v pin="$RELEASE_CONTENT_COMMIT" '
  /^BOOTSTRAP_PIN="\$\{BOOTSTRAP_PIN:-/ && !seen { sub(/\$\{BOOTSTRAP_PIN:-[^}]*\}/, "${BOOTSTRAP_PIN:-" pin "}"); seen = 1 }
  { print }
' bootstrap.sh > bootstrap.sh.rl && mv -f bootstrap.sh.rl bootstrap.sh
/bin/bash -n bootstrap.sh || { release_fail "the rewritten bootstrap.sh does not parse"; exit 1; }
grep -q "BOOTSTRAP_PIN:-$RELEASE_CONTENT_COMMIT}" bootstrap.sh || { release_fail "the pin was not substituted"; exit 1; }

# …and the manifest beneath it, replaced whole: whatever was between the markers is the previous tree.
release_manifest "$RELEASE_CONTENT_COMMIT" > bootstrap.sh.manifest
awk -v mf=bootstrap.sh.manifest '
  /^BOOTSTRAP_RELEASE_MANIFEST$/ { skip = 0 }
  !skip { print }
  /<<'\''BOOTSTRAP_RELEASE_MANIFEST'\''$/ { while ((getline l < mf) > 0) print l; skip = 1 }
' bootstrap.sh > bootstrap.sh.rl && mv -f bootstrap.sh.rl bootstrap.sh
rm -f bootstrap.sh.manifest
/bin/bash -n bootstrap.sh || { release_fail "the bootstrap.sh with its manifest does not parse"; exit 1; }
[ "$(release_embedded_manifest bootstrap.sh)" = "$(release_manifest "$RELEASE_CONTENT_COMMIT")" ] || {
  release_fail "the manifest written into bootstrap.sh does not read back as the tree at $RELEASE_CONTENT_COMMIT"; exit 1; }

git add bootstrap.sh
git commit -q -m "release: pin the fetch tree at ${RELEASE_CONTENT_COMMIT}

A curl'd bootstrap.sh has no modules/ beside it, so it fetches them — and the ref it
fetches from cannot be this commit, which does not know its own sha. It names its parent,
whose tree already holds every module and asset, and which this commit does not touch."
RELEASE_COMMIT="$(git rev-parse HEAD)"
release_say "release commit (the README's sha): $RELEASE_COMMIT"

# Z — the README: the sha, the line count, the checksum.
RELEASE_OLD_SHA="$(grep -o '[0-9a-f]\{40\}' README.md | head -1)"
RELEASE_OLD_SUM="$(grep -o '[0-9a-f]\{64\}' README.md | head -1)"
RELEASE_LINES="$(wc -l < bootstrap.sh | tr -d ' ')"
RELEASE_SUM="$(release_sha_file bootstrap.sh)"
RELEASE_OLD_LINES="$(grep -o '`bootstrap.sh` is [0-9]* lines' README.md | grep -o '[0-9]*' | head -1)"

[ -n "$RELEASE_OLD_SHA" ] && sed -i '' "s/$RELEASE_OLD_SHA/$RELEASE_COMMIT/g" README.md
[ -n "$RELEASE_OLD_SUM" ] && sed -i '' "s/$RELEASE_OLD_SUM/$RELEASE_SUM/g" README.md
[ -n "$RELEASE_OLD_LINES" ] && sed -i '' "s/\`bootstrap.sh\` is $RELEASE_OLD_LINES lines/\`bootstrap.sh\` is $RELEASE_LINES lines/" README.md

if [ -n "$(git status --porcelain README.md)" ]; then
  git add README.md
  git commit -q -m "docs: point the entry point at ${RELEASE_COMMIT}

The sha in the curl URL is the release commit; the pin inside it is that commit's parent.
Nothing else in the prompt moves."
  release_say "docs commit: $(git rev-parse HEAD)"
else
  release_say "README already current"
fi

git push -q origin main || { release_fail "push failed — nothing is published, so nothing is released"; exit 1; }
release_say "pushed."
release_say ""

# ── the read-back. Everything above wrote files; only this decides whether it is a release. ──
release_say "verifying the published release, anonymously:"
if release_verify "$RELEASE_COMMIT"; then
  release_say ""
  release_say "RELEASED — bootstrap.sh @ $RELEASE_COMMIT, payload @ $RELEASE_CONTENT_COMMIT."
  exit 0
fi
release_fail "the release does not fetch. It is pushed but it is NOT usable; fix before telling anyone."
exit 1
