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
#   X   content commit, already pushed ......... MB_PIN points here — modules/ and assets/
#   Y   release commit, one line of bootstrap.sh  the README's curl URL points here
#   Z   docs commit, README only ............... what a reader sees at the head of main
#
# Y changes exactly one line, so every module and asset the driver fetches from X is
# byte-identical to the one that sat beside it when it was tested. The alternative — inlining
# the modules into bootstrap.sh — removes the second hop entirely but turns the only entry point
# into a ~200 KB generated artifact and gives this repo a build step it deliberately does not
# have.
#
# ── IT VERIFIES BY INDEPENDENT READ-BACK ─────────────────────────────────────────────────────
# Never by grepping for a phrase it just wrote. It re-fetches the published bootstrap.sh
# anonymously, reads the pin back OUT of those bytes, then fetches pb-lib.sh and every module
# and asset at that pin and compares each sha256 against `git show <pin>:<path>`. A release that
# cannot be fetched is not a release — which is the one thing the first one was never asked.

set -u

RL_REPO="renchris/mac-bootstrap"
RL_MODE="cut"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   RL_MODE=check ;;
    --dry)     RL_MODE=dry ;;
    --help|-h) sed -n '2,45p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'release: unknown argument: %s   (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

RL_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'release: not inside a git checkout\n' >&2; exit 2; }
cd "$RL_ROOT" || exit 2

rl_say()  { printf '%s\n' "$*"; }
rl_fail() { printf 'release: %s\n' "$*" >&2; }

# ── read-back helpers ────────────────────────────────────────────────────────────────────────
rl_raw() { printf 'https://raw.githubusercontent.com/%s/%s/%s' "$RL_REPO" "$1" "$2"; }

rl_fetch() {                                    # rl_fetch <ref> <relpath> <dest> → 0 on a real 200
  local code
  code="$(curl -sS -L -o "$3.part" -w '%{http_code}' "$(rl_raw "$1" "$2")" 2>/dev/null)" || {
    rm -f "$3.part" 2>/dev/null; return 1; }
  [ "$code" = "200" ] || { rm -f "$3.part" 2>/dev/null; return 1; }
  [ -s "$3.part" ] || { rm -f "$3.part" 2>/dev/null; return 1; }
  mv -f "$3.part" "$3"
}

rl_sha_file() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
rl_sha_blob() { git show "$1:$2" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

# The files a standalone bootstrap.sh has to fetch: every module, and every asset except the
# rendered diagrams, which only the README consumes.
rl_payload() { git ls-tree -r --name-only "$1" -- modules assets 2>/dev/null | grep -v '^assets/diagrams/'; }

# rl_verify <readme_ref> — the whole claim, from outside, with no local file trusted.
rl_verify() {
  local ref="$1" tmp boot pin rel got want n=0 bad=0
  tmp="$(mktemp -d)" || return 1
  boot="$tmp/bootstrap.sh"

  rl_say "  hop 1: bootstrap.sh @ ${ref}"
  if ! rl_fetch "$ref" bootstrap.sh "$boot"; then
    rl_fail "hop 1 FAILED: cannot fetch bootstrap.sh at $ref"; rm -rf "$tmp"; return 1
  fi
  rl_say "         $(rl_sha_file "$boot")  $(wc -l < "$boot" | tr -d ' ') lines"

  # The pin, read back out of the PUBLISHED bytes — not out of the working tree.
  pin="$(sed -n 's/^MB_PIN="\${MB_PIN:-\([^}]*\)}".*/\1/p' "$boot" | head -1)"
  case "$pin" in
    ''|__PIN_SHA__|main|master)
      rl_fail "hop 2 IMPOSSIBLE: the published bootstrap.sh carries pin '$pin'."
      rl_fail "  Every module and asset fetch refuses before any network call. Cut a release."
      rm -rf "$tmp"; return 1 ;;
  esac
  case "$pin" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
    *) rl_fail "hop 2 REFUSED: pin '$pin' is not a commit sha"; rm -rf "$tmp"; return 1 ;;
  esac
  rl_say "  hop 2: payload @ ${pin}"

  for rel in $(rl_payload "$pin"); do
    n=$((n + 1))
    if ! rl_fetch "$pin" "$rel" "$tmp/blob"; then
      rl_fail "  MISSING  $rel"; bad=$((bad + 1)); continue
    fi
    got="$(rl_sha_file "$tmp/blob")"
    want="$(rl_sha_blob "$pin" "$rel")"
    if [ -n "$want" ] && [ "$got" != "$want" ]; then
      rl_fail "  MISMATCH $rel"; bad=$((bad + 1))
    fi
  done
  rm -rf "$tmp"

  if [ "$n" = 0 ]; then
    rl_fail "the pinned tree lists no modules or assets — is $pin in this checkout? (git fetch)"
    return 1
  fi
  if [ "$bad" != 0 ]; then
    rl_fail "$bad of $n payload file(s) are not fetchable at the pin"
    return 1
  fi
  rl_say "         $n payload file(s) fetched anonymously, every sha256 matching the pinned tree"
  return 0
}

# ── --check ──────────────────────────────────────────────────────────────────────────────────
if [ "$RL_MODE" = check ]; then
  RL_READ="$(grep -o '[0-9a-f]\{40\}' README.md 2>/dev/null | head -1)"
  [ -n "$RL_READ" ] || { rl_fail "the README pins no commit sha"; exit 1; }
  rl_say "checking the release the README points at: $RL_READ"
  rl_verify "$RL_READ" || exit 1
  rl_say "OK — both hops work anonymously from a clean environment."
  exit 0
fi

# ── cut ──────────────────────────────────────────────────────────────────────────────────────
[ -z "$(git status --porcelain)" ] || { rl_fail "the tree is dirty; commit or stash first"; exit 2; }

RL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$RL_BRANCH" = main ] || { rl_fail "cut releases from main, not '$RL_BRANCH'"; exit 2; }

git fetch --quiet origin main 2>/dev/null || true
RL_X="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$RL_X" origin/main 2>/dev/null || {
  rl_fail "HEAD is not on origin/main. The pin is a raw.githubusercontent reference, so the"
  rl_fail "  content commit must be PUBLISHED before anything can point at it. Push first."
  exit 2; }

RL_OLD_PIN="$(sed -n 's/^MB_PIN="\${MB_PIN:-\([^}]*\)}".*/\1/p' bootstrap.sh | head -1)"
rl_say "content commit (the pin) : $RL_X"
rl_say "pin in the working tree  : $RL_OLD_PIN"

if [ "$RL_OLD_PIN" = "$RL_X" ]; then
  rl_fail "bootstrap.sh already pins $RL_X — nothing to cut. Commit content first."
  exit 2
fi

if [ "$RL_MODE" = dry ]; then
  rl_say ""
  rl_say "would commit Y: bootstrap.sh MB_PIN -> $RL_X"
  rl_say "would commit Z: README curl sha -> <Y>, plus its line count and sha256"
  rl_say "would then verify both hops anonymously against the published bytes"
  exit 0
fi

# Y — bootstrap.sh, one line.
awk -v pin="$RL_X" '
  /^MB_PIN="\$\{MB_PIN:-/ && !seen { sub(/\$\{MB_PIN:-[^}]*\}/, "${MB_PIN:-" pin "}"); seen = 1 }
  { print }
' bootstrap.sh > bootstrap.sh.rl && mv -f bootstrap.sh.rl bootstrap.sh
/bin/bash -n bootstrap.sh || { rl_fail "the rewritten bootstrap.sh does not parse"; exit 1; }
grep -q "MB_PIN:-$RL_X}" bootstrap.sh || { rl_fail "the pin was not substituted"; exit 1; }

git add bootstrap.sh
git commit -q -m "release: pin the fetch tree at ${RL_X}

A curl'd bootstrap.sh has no modules/ beside it, so it fetches them — and the ref it
fetches from cannot be this commit, which does not know its own sha. It names its parent,
whose tree already holds every module and asset, and which this commit does not touch."
RL_Y="$(git rev-parse HEAD)"
rl_say "release commit (the README's sha): $RL_Y"

# Z — the README: the sha, the line count, the checksum.
RL_OLD_SHA="$(grep -o '[0-9a-f]\{40\}' README.md | head -1)"
RL_OLD_SUM="$(grep -o '[0-9a-f]\{64\}' README.md | head -1)"
RL_LINES="$(wc -l < bootstrap.sh | tr -d ' ')"
RL_SUM="$(rl_sha_file bootstrap.sh)"
RL_OLD_LINES="$(grep -o '`bootstrap.sh` is [0-9]* lines' README.md | grep -o '[0-9]*' | head -1)"

[ -n "$RL_OLD_SHA" ] && sed -i '' "s/$RL_OLD_SHA/$RL_Y/g" README.md
[ -n "$RL_OLD_SUM" ] && sed -i '' "s/$RL_OLD_SUM/$RL_SUM/g" README.md
[ -n "$RL_OLD_LINES" ] && sed -i '' "s/\`bootstrap.sh\` is $RL_OLD_LINES lines/\`bootstrap.sh\` is $RL_LINES lines/" README.md

if [ -n "$(git status --porcelain README.md)" ]; then
  git add README.md
  git commit -q -m "docs: point the entry point at ${RL_Y}

The sha in the curl URL is the release commit; the pin inside it is that commit's parent.
Nothing else in the prompt moves."
  rl_say "docs commit: $(git rev-parse HEAD)"
else
  rl_say "README already current"
fi

git push -q origin main || { rl_fail "push failed — nothing is published, so nothing is released"; exit 1; }
rl_say "pushed."
rl_say ""

# ── the read-back. Everything above wrote files; only this decides whether it is a release. ──
rl_say "verifying the published release, anonymously:"
if rl_verify "$RL_Y"; then
  rl_say ""
  rl_say "RELEASED — bootstrap.sh @ $RL_Y, payload @ $RL_X."
  exit 0
fi
rl_fail "the release does not fetch. It is pushed but it is NOT usable; fix before telling anyone."
exit 1
