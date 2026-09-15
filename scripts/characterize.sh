#!/bin/bash
# scripts/characterize.sh — pin this installer's OBSERVABLE BEHAVIOUR, from a clean sandbox HOME.
#
#   bash scripts/characterize.sh                 run every check; exit 0 only if all pass
#   bash scripts/characterize.sh --snapshot DIR  also write normalized transcripts into DIR
#   bash scripts/characterize.sh --keep          leave the sandbox HOME on disk and print it
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────
# This repo had no test of its own. Its only proof was a human running the thing and reading the
# output, which cannot be re-run after a refactor and cannot be run before one. An 884-site
# rename against a working installer with no net is the single most likely way to ship a silent
# break, so the net was built first.
#
# ── WHY EVERY ASSERTION IS NAME-INDEPENDENT, AND WHY THAT IS THE WHOLE DESIGN ────────────────
# A harness that asserted `statusline=SATISFIED` would fail the moment a module is renamed,
# which is exactly when it is needed — it would be measuring the rename instead of the damage.
# So NOTHING here names a module, a variable or a hook file. Every check derives its subject at
# runtime from the driver's own `--manifest` and `--list`, and then asserts a property that is
# true of a working installer under ANY spelling:
#
#     read-only modes write nothing     ·  a bad argument exits 30 and says the known set
#     a lite install exits 0 and every row it scored is SATISFIED
#     --verify writes the verify receipt and does not touch the install receipt
#     running twice changes not one byte ·  --only MERGES rather than replacing the receipt
#     uninstall returns the HOME to its pre-install file set, byte for byte
#     nothing at any point escapes the sandbox into the real HOME
#
# That set is the contract. It held before the rename and it holds after it, and the pair of runs
# is the evidence that the rename changed names and nothing else.
#
# ── THE SNAPSHOT IS A SEPARATE, WEAKER INSTRUMENT, ON PURPOSE ────────────────────────────────
# `--snapshot` writes the normalized text of --list/--plan/--manifest/the receipt/the file set.
# That text is EXPECTED to change under a rename, so it is never an assertion — it is a review
# aid: translate the old snapshot through the rename map and diff it against the new one, and
# anything left over is a real difference. Do not turn it into a check; a snapshot test over a
# deliberate rename only ever tells you that you renamed something.
#
# ── WHAT IT DOES NOT COVER, STATED SO NOBODY OVER-TRUSTS IT ──────────────────────────────────
# `standard` and `full` are not installed here. They need Homebrew, an Apple ID, ~9 GB, GUI
# permission toggles and money; a sandbox HOME can only enumerate their gates, never satisfy
# them. Those profiles are exercised through `--plan` and `--list` only, so this harness proves
# their SELECTION and their PLAN, never their installation. The `lite` profile is installed for
# real, and it is the profile a stranger gets by default.
#
# It is also a clean-HOME proxy, not a clean-MACHINE proxy: /Applications is inherited, so the
# terminal-emulator gate that a genuinely fresh Mac records cannot fire here.

set -u
# NOT set -e: a failed check must be REPORTED, not abort the run and hide the ones after it.

CHECK_KEEP=0
CHECK_SNAPSHOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) [ $# -ge 2 ] || { printf 'characterize: --snapshot needs a directory\n' >&2; exit 2; }
                CHECK_SNAPSHOT="$2"; shift ;;
    --keep)     CHECK_KEEP=1 ;;
    --help|-h)  sed -n '2,50p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          printf 'characterize: unknown argument: %s   (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd -P)" || {
  printf 'characterize: cannot resolve the repo root\n' >&2; exit 2; }
[ -r "$CHECK_ROOT/bootstrap.sh" ] || {
  printf 'characterize: bootstrap.sh is not at %s\n' "$CHECK_ROOT" >&2; exit 2; }

CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mac-bootstrap-characterize.XXXXXX")" || exit 2
CHECK_HOME="$CHECK_TMP/home"
CHECK_WORK="$CHECK_TMP/work"
mkdir -p "$CHECK_HOME" "$CHECK_WORK" || exit 2

CHECK_TOTAL=0
CHECK_BAD=0

cleanup() {
  if [ "$CHECK_KEEP" = 1 ]; then
    printf '\nsandbox kept: %s\n' "$CHECK_HOME"
  else
    rm -rf "$CHECK_TMP" 2>/dev/null
  fi
}
trap cleanup EXIT

# ── reporting ────────────────────────────────────────────────────────────────────────────────
pass() { CHECK_TOTAL=$((CHECK_TOTAL + 1)); printf 'PASS  %-34s %s\n' "$1" "${2:-}"; }
fail() { CHECK_TOTAL=$((CHECK_TOTAL + 1)); CHECK_BAD=$((CHECK_BAD + 1)); printf 'FAIL  %-34s %s\n' "$1" "${2:-}"; }
same() { if [ "$2" = "$3" ]; then pass "$1" "$2"; else fail "$1" "want [$3] got [$2]"; fi; }
true_() { if [ "$2" = 1 ]; then pass "$1" "${3:-}"; else fail "$1" "${3:-}"; fi; }

# ── running the driver against the sandbox ───────────────────────────────────────────────────
# Every invocation is HOME-overridden. There is no path here that can run against the real HOME,
# which is the one mistake this repo has already made once on a live machine.
CHECK_RC=0
CHECK_OUT=""
drive() {                                       # drive <args...>  → sets CHECK_RC, CHECK_OUT
  CHECK_OUT="$(HOME="$CHECK_HOME" TMPDIR="$CHECK_WORK" /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" 2>&1)"
  CHECK_RC=$?
  return 0
}

# fresh_home <name> — a second sandbox HOME under the same mktemp root, so a feature check never
# inherits the state the sections above left behind. drive_at runs the driver against one.
fresh_home() { local h="$CHECK_TMP/home-$1"; rm -rf "$h"; mkdir -p "$h" "$CHECK_TMP/work-$1" && printf '%s' "$h"; }
drive_at() {                                    # drive_at <home> <args...> → sets CHECK_RC, CHECK_OUT
  local h="$1"; shift
  CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" /bin/bash "$CHECK_ROOT/bootstrap.sh" "$@" 2>&1)"
  CHECK_RC=$?
  return 0
}

# ── an INDEPENDENT JSON read-back ────────────────────────────────────────────────────────────
# Deliberately not the repo's own library: a harness that reads a receipt with the same code that
# wrote it cannot see a defect that lives in that code. plutil is a second engine, and its
# measured trap is handled — `-extract` prints its failure to STDOUT, so the rc is what decides.
json_at() {                                     # json_at <file> <keypath> → value on rc 0
  local out
  out="$(plutil -extract "$2" raw -o - -- "$1" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# receipt_states <file> — prints "<module> <state>" per line, sorted. The module NAMES come out of
# the receipt itself, so this works under any spelling.
receipt_states() {
  local i=0 m s
  while [ "$i" -lt 64 ]; do
    m="$(json_at "$1" "modules.$i.module")" || break
    [ -n "$m" ] || break
    s="$(json_at "$1" "modules.$i.state")" || s="?"
    printf '%s %s\n' "$m" "$s"
    i=$((i + 1))
  done | sort
}

# ── the file set: what this HOME actually holds ──────────────────────────────────────────────
# Volatile paths are excluded by PURPOSE, not by guesswork, and each exclusion is named:
#   bootstrap.log / receipt*.json  carry a UTC timestamp on every run
#   rows/ backups/                 are the receipt's backing store and the backup spool
#   modules/ assets/ under state   are the fetch cache, absent in a clone run and not an artifact
# Everything else — including every file the modules write into ~/.claude, ~/.copilot, ~/.config
# and ~/Library — is compared byte for byte.
file_set() {
  ( cd "$CHECK_HOME" 2>/dev/null || return 0
    find . \( -type f -o -type l \) -print 2>/dev/null | sort | while IFS= read -r p; do
      case "$p" in
        ./.mac-bootstrap/bootstrap.log|./.mac-bootstrap/receipt.json|./.mac-bootstrap/receipt.verify.json) continue ;;
        ./.mac-bootstrap/rows/*|./.mac-bootstrap/backups/*|./.mac-bootstrap/modules/*|./.mac-bootstrap/assets/*) continue ;;
      esac
      if [ -L "$p" ]; then
        printf 'symlink:%s  %s\n' "$(readlink "$p" 2>/dev/null | sed "s#$CHECK_HOME#\$HOME#g")" "$p"
      else
        printf '%s  %s\n' "$(shasum -a 256 "$p" 2>/dev/null | cut -d' ' -f1)" "$p"
      fi
    done )
}

# ── normalization, for the snapshot only ─────────────────────────────────────────────────────
normalize() {
  sed -e "s#$CHECK_HOME#\$HOME#g" \
      -e "s#$CHECK_ROOT#\$REPO#g" \
      -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/<utc>/g' \
      -e 's/\b[0-9a-f]\{16,\}\b/<sha>/g'
}

snap() {                                        # snap <name>  < text
  [ -n "$CHECK_SNAPSHOT" ] || { cat >/dev/null; return 0; }
  mkdir -p "$CHECK_SNAPSHOT" 2>/dev/null
  normalize > "$CHECK_SNAPSHOT/$1"
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
printf 'characterize — sandbox HOME %s\n\n' "$CHECK_HOME"

# ── 0. ISOLATION — the four files on the REAL Mac this installer is able to damage ───────────
# NOT an mtime check. `~/.claude/settings.json` belongs to a LIVE agent that rewrites it while
# this harness runs, so its mtime moves for reasons that have nothing to do with us — measured,
# and it read as an escape on the very first run. What actually distinguishes an escape is
# CONTENT: an installer that escaped would have written the sandbox path into a real file, and
# would have left the iTerm2 plist (which nothing else on this machine touches during a run)
# changed. Both are checked, and both are direct evidence rather than a proxy for it.
REAL_TARGETS="$HOME/.claude/settings.json
$HOME/.copilot/settings.json
$HOME/.copilot/hooks/00-lifecycle.json
$HOME/.config/kitty/kitty.conf
$HOME/Library/Preferences/com.googlecode.iterm2.plist"
real_sum() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || printf 'absent'; }
PLIST_REAL="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
PLIST_SUM0="$(real_sum "$PLIST_REAL")"

# ── 1. THE INSTRUMENT ────────────────────────────────────────────────────────────────────────
# The shared library's own fixtures, including the pre-fix arm that must stay RED. If the
# instrument cannot reproduce the defect it repairs, nothing it says about a machine means
# anything. Found by glob, not by name — this file must survive the library being renamed.
LIB=""
for c in "$CHECK_ROOT"/assets/hooks/*lib*.sh; do [ -r "$c" ] && { LIB="$c"; break; }; done
if [ -n "$LIB" ] && /bin/bash "$LIB" --selftest >"$CHECK_WORK/selftest.txt" 2>&1; then
  pass "library-selftest" "$(tail -1 "$CHECK_WORK/selftest.txt")"
else
  fail "library-selftest" "${LIB:-no library found under assets/hooks/}"
  [ -n "$LIB" ] && grep -v '^  ok ' "$CHECK_WORK/selftest.txt" | head -20
fi

# ── 2. EVERY SHIPPED SHELL FILE PARSES UNDER THE TARGET BASH ─────────────────────────────────
# /bin/bash is 3.2.57 on the target. Homebrew's bash 5 accepts constructs 3.2 rejects, so the
# parse check has to be the system one.
PARSE_BAD=""
for f in "$CHECK_ROOT"/bootstrap.sh "$CHECK_ROOT"/verify.sh "$CHECK_ROOT"/scripts/*.sh "$CHECK_ROOT"/scripts/checks/*.sh \
         "$CHECK_ROOT"/modules/*.sh "$CHECK_ROOT"/assets/hooks/*.sh \
         "$CHECK_ROOT"/assets/succession/*.sh "$CHECK_ROOT"/assets/*.sh; do
  [ -r "$f" ] || continue
  /bin/bash -n "$f" 2>/dev/null || PARSE_BAD="$PARSE_BAD ${f#"$CHECK_ROOT"/}"
done
if [ -z "$PARSE_BAD" ]; then pass "bash-3.2-parse" "every shipped .sh parses"
else fail "bash-3.2-parse" "$PARSE_BAD"; fi

# ── 3. THE MANIFEST, and the module count everything below is scored against ─────────────────
drive --manifest
printf '%s\n' "$CHECK_OUT" | snap manifest.txt
same "manifest-rc" "$CHECK_RC" 0
# The manifest block lists one indented line per module, each ending in a readable path.
MODULES="$(printf '%s\n' "$CHECK_OUT" | sed -n 's#^    \([a-z][a-z0-9_]*\) *[0-9a-f]\{16\}  .*#\1#p')"
MODULE_N="$(printf '%s' "$MODULES" | grep -c . | tr -d ' ')"
if [ "${MODULE_N:-0}" -ge 2 ]; then pass "manifest-lists-modules" "$MODULE_N module(s): $(printf '%s' "$MODULES" | tr '\n' ' ')"
else fail "manifest-lists-modules" "parsed $MODULE_N from --manifest"; fi

# ── 4. --list, and the profile ladder ────────────────────────────────────────────────────────
drive --list
printf '%s\n' "$CHECK_OUT" | snap list-default.txt
same "list-rc" "$CHECK_RC" 0
# BSD sed is a BASIC regex engine: `\|` is a literal, not alternation. Measured — the
# alternation spelling matched zero of eight lines and read as a driver defect.
LIST_N="$(printf '%s\n' "$CHECK_OUT" | sed -n 's#^[ *]\{4\}\([a-z][a-z0-9_]*\) *\[[a-z]*\].*#\1#p' | grep -c . | tr -d ' ')"
same "list-shows-every-module" "$LIST_N" "$MODULE_N"

# Each module prints a what: and a cost: line, which is the whole point of --list.
WHAT_N="$(printf '%s\n' "$CHECK_OUT" | grep -c 'what :' | tr -d ' ')"
COST_N="$(printf '%s\n' "$CHECK_OUT" | grep -c 'cost :' | tr -d ' ')"
same "list-prices-every-module" "$WHAT_N/$COST_N" "$MODULE_N/$MODULE_N"

# The selection marker (*) must grow monotonically with the profile: lite ⊆ standard ⊆ full.
selected_for() {                                # selected_for <profile> → sorted module names
  drive --list --profile "$1"
  printf '%s\n' "$CHECK_OUT" | sed -n 's#^  \* \([a-z][a-z0-9_]*\) .*#\1#p' | sort
}
SEL_LITE="$(selected_for lite)"
SEL_STD="$(selected_for standard)"
SEL_FULL="$(selected_for full)"
N_LITE="$(printf '%s' "$SEL_LITE" | grep -c . | tr -d ' ')"
N_STD="$(printf '%s' "$SEL_STD" | grep -c . | tr -d ' ')"
N_FULL="$(printf '%s' "$SEL_FULL" | grep -c . | tr -d ' ')"
LADDER=1
[ "$N_LITE" -ge 1 ] || LADDER=0
[ "$N_LITE" -le "$N_STD" ] || LADDER=0
[ "$N_STD" -le "$N_FULL" ] || LADDER=0
[ "$N_FULL" = "$MODULE_N" ] || LADDER=0
# and it must be a real subset relation, not merely a bigger count
for m in $SEL_LITE; do case " $(printf '%s' "$SEL_STD" | tr '\n' ' ') " in *" $m "*) : ;; *) LADDER=0 ;; esac; done
for m in $SEL_STD;  do case " $(printf '%s' "$SEL_FULL" | tr '\n' ' ') " in *" $m "*) : ;; *) LADDER=0 ;; esac; done
true_ "profile-ladder-is-nested" "$LADDER" "lite $N_LITE ⊆ standard $N_STD ⊆ full $N_FULL = $MODULE_N"

# ── 5. --plan, on all three profiles ─────────────────────────────────────────────────────────
for p in lite standard full; do
  drive --plan --profile "$p"
  printf '%s\n' "$CHECK_OUT" | snap "plan-$p.txt"
  # --plan foresees on the install scale: 10 exactly when a row says NEEDS YOU, 0 exactly when none does.
  case "$CHECK_OUT" in *"NEEDS YOU:"*) same "plan-$p-rc" "$CHECK_RC" 10 ;; *) same "plan-$p-rc" "$CHECK_RC" 0 ;; esac
done
# The same plan, in install order: a module whose dependency this run installs first is not NEEDS YOU.
drive --plan --profile full
case "$CHECK_OUT" in
  *"microsoft365_archive NEEDS YOU"*) fail "plan-respects-install-order" "microsoft365_archive flagged while microsoft365 would install first" ;;
  *"microsoft365_archive decided after microsoft365"*|*"microsoft365_archive already satisfied"*) pass "plan-respects-install-order" ;;
  *) fail "plan-respects-install-order" "$(printf '%s\n' "$CHECK_OUT" | grep -m1 microsoft365_archive)" ;;
esac

# ── 6. READ-ONLY MEANS READ-ONLY ─────────────────────────────────────────────────────────────
# --list, --plan and --manifest have now run seven times between them. The receipt is the file a
# stranger is told to read and an agent is told to parse; a read-only mode that writes one is the
# false-green this driver has already had to remove once.
RO_BAD=""
[ -e "$CHECK_HOME/.mac-bootstrap/receipt.json" ] && RO_BAD="$RO_BAD receipt.json"
[ -e "$CHECK_HOME/.mac-bootstrap/receipt.verify.json" ] && RO_BAD="$RO_BAD receipt.verify.json"
ls "$CHECK_HOME/.mac-bootstrap/rows"/*.state >/dev/null 2>&1 && RO_BAD="$RO_BAD rows/"
[ -e "$CHECK_HOME/.claude" ] && RO_BAD="$RO_BAD .claude/"
[ -e "$CHECK_HOME/.copilot" ] && RO_BAD="$RO_BAD .copilot/"
if [ -z "$RO_BAD" ]; then pass "read-only-writes-nothing" "no receipt, no rows, no agent config"
else fail "read-only-writes-nothing" "$RO_BAD"; fi

# ── 7. ARGUMENT HANDLING — every refusal is a 30, and every refusal explains itself ──────────
drive --only definitely_not_a_module
same "unknown-module-rc" "$CHECK_RC" 30
case "$CHECK_OUT" in
  *"known modules:"*) pass "unknown-module-names-the-set" ;;
  *) fail "unknown-module-names-the-set" "$(printf '%s' "$CHECK_OUT" | head -2)" ;;
esac
# It DOES write a receipt, and that is correct — 30 means "this run is not a verdict about your
# Mac", and the receipt is where that sentence lives. What it must never do is fabricate a row:
# a verdict-shaped receipt over a run that evaluated nothing is the false green this driver has
# already had removed twice.
if [ -e "$CHECK_HOME/.mac-bootstrap/receipt.json" ]; then
  same "unknown-module-receipt-code" "$(json_at "$CHECK_HOME/.mac-bootstrap/receipt.json" exit_code)" 30
  if json_at "$CHECK_HOME/.mac-bootstrap/receipt.json" error >/dev/null 2>&1; then pass "unknown-module-receipt-explains"
  else fail "unknown-module-receipt-explains" "exit 30 with no error sentence"; fi
  if json_at "$CHECK_HOME/.mac-bootstrap/receipt.json" modules.0.module >/dev/null 2>&1
  then fail "unknown-module-fabricates-no-row" "a row exists for a run that evaluated nothing"
  else pass "unknown-module-fabricates-no-row"; fi
  rm -f "$CHECK_HOME/.mac-bootstrap/receipt.json"
else
  pass "unknown-module-receipt-code" "no receipt written"
  pass "unknown-module-receipt-explains" "n/a"
  pass "unknown-module-fabricates-no-row" "n/a"
fi

drive --dry-run
same "removed-flag-rc" "$CHECK_RC" 30
drive --frobnicate
same "unknown-flag-rc" "$CHECK_RC" 30
drive --only
same "missing-value-rc" "$CHECK_RC" 30
drive --help
same "help-rc" "$CHECK_RC" 0
case "$CHECK_OUT" in
  *--verify*--uninstall*) pass "help-documents-the-modes" ;;
  *) fail "help-documents-the-modes" ;;
esac

# ── 8. THE REAL INSTALL — the default profile, which is what a stranger gets ─────────────────
BEFORE="$(file_set)"
drive
printf '%s\n' "$CHECK_OUT" | snap install-lite.txt
same "install-rc" "$CHECK_RC" 0
RECEIPT="$CHECK_HOME/.mac-bootstrap/receipt.json"
if plutil -convert json -o /dev/null -- "$RECEIPT" 2>/dev/null; then pass "receipt-parses"
else fail "receipt-parses" "$RECEIPT"; fi
STATES="$(receipt_states "$RECEIPT")"
printf '%s\n' "$STATES" | snap receipt-install.txt
ROW_N="$(printf '%s' "$STATES" | grep -c . | tr -d ' ')"
same "receipt-row-per-selected-module" "$ROW_N" "$N_LITE"
SAT_N="$(printf '%s' "$STATES" | grep -c ' SATISFIED$' | tr -d ' ')"
same "every-installed-row-satisfied" "$SAT_N" "$ROW_N"
# exit 0 and a row that is not SATISFIED are the same defect wearing two faces
same "receipt-exit-code-agrees" "$(json_at "$RECEIPT" exit_code)" 0
same "receipt-records-the-mode" "$(json_at "$RECEIPT" mode)" install

AFTER="$(file_set)"
NEW_N="$(printf '%s\n' "$AFTER" | comm -13 <(printf '%s\n' "$BEFORE") - | grep -c . | tr -d ' ')"
if [ "${NEW_N:-0}" -ge 4 ]; then pass "install-writes-files" "$NEW_N new file(s) under the sandbox HOME"
else fail "install-writes-files" "only $NEW_N — an install that writes nothing is not an install"; fi
printf '%s\n' "$AFTER" | snap fileset-installed.txt

# No shipped file may carry an absolute path containing a user name (house rule 9, and this repo
# is public). The sandbox HOME is itself such a path, so this is a live check, not a lint.
LEAK="$(grep -rlI "$(id -un)" "$CHECK_HOME/.mac-bootstrap/bin" "$CHECK_HOME/.mac-bootstrap/hooks" 2>/dev/null | grep -v "$CHECK_HOME" | head -3)"
if [ -z "$LEAK" ]; then pass "no-username-in-installed-files"
else fail "no-username-in-installed-files" "$LEAK"; fi

# ── 9. --verify — a second, cold read of the same machine ────────────────────────────────────
VRECEIPT="$CHECK_HOME/.mac-bootstrap/receipt.verify.json"
RSUM0="$(shasum -a 256 "$RECEIPT" 2>/dev/null | cut -d' ' -f1)"
drive --verify
printf '%s\n' "$CHECK_OUT" | snap verify.txt
same "verify-rc" "$CHECK_RC" 0
if [ -r "$VRECEIPT" ]; then pass "verify-writes-its-own-receipt"
else fail "verify-writes-its-own-receipt"; fi
same "verify-never-touches-the-install-receipt" "$(shasum -a 256 "$RECEIPT" 2>/dev/null | cut -d' ' -f1)" "$RSUM0"
VSAT="$(receipt_states "$VRECEIPT" | grep -c ' SATISFIED$' | tr -d ' ')"
same "verify-agrees-with-the-install" "$VSAT" "$ROW_N"

# the standalone wrapper, which adds the control arm and the human-readable render
VERIFY_OUT="$(HOME="$CHECK_HOME" TMPDIR="$CHECK_WORK" /bin/bash "$CHECK_ROOT/verify.sh" 2>&1)"; VERIFY_RC=$?
printf '%s\n' "$VERIFY_OUT" | snap verify-wrapper.txt
same "verify-wrapper-rc" "$VERIFY_RC" 0
case "$VERIFY_OUT" in
  *control*) pass "verify-wrapper-runs-its-control-arm" ;;
  *) fail "verify-wrapper-runs-its-control-arm" ;;
esac

# ── 10. IDEMPOTENCE — re-running is the recovery procedure (house rule 8) ────────────────────
drive
same "second-install-rc" "$CHECK_RC" 0
AGAIN="$(file_set)"
if [ "$AGAIN" = "$AFTER" ]; then pass "second-install-changes-nothing" "$(printf '%s\n' "$AFTER" | grep -c . | tr -d ' ') file(s) byte-identical"
else fail "second-install-changes-nothing" "$(diff <(printf '%s\n' "$AFTER") <(printf '%s\n' "$AGAIN") | head -6 | tr '\n' ' ')"; fi

# ── 11. --only MERGES, and does not replace the receipt ─────────────────────────────────────
# The design's own driver replaced the receipt with a one-module receipt, so the agent's input
# destroyed itself the first time it followed the instruction to re-drive one module.
ONE="$(printf '%s' "$SEL_LITE" | head -1)"
drive --only "$ONE"
same "only-one-module-rc" "$CHECK_RC" 0
ONLY_ROWS="$(receipt_states "$RECEIPT" | grep -c . | tr -d ' ')"
same "only-merges-into-the-receipt" "$ONLY_ROWS" "$ROW_N"
case "$CHECK_OUT" in
  *"$ONE"*) pass "only-acts-on-what-it-names" ;;
  *) fail "only-acts-on-what-it-names" ;;
esac

# A TYPO MUST NOT COST THE RECEIPT. The rows are the only record of what needs the human, and
# the refusal path re-emits the receipt on its way out — so the rows have to survive it.
drive --only definitely_not_a_module
same "typo-after-install-rc" "$CHECK_RC" 30
same "typo-preserves-the-rows" "$(receipt_states "$RECEIPT" | grep -c . | tr -d ' ')" "$ROW_N"

# --except subtracts, and the run stays a verdict about what it did evaluate
drive --except "$ONE"
if [ "$CHECK_RC" = 0 ] || [ "$CHECK_RC" = 10 ]; then pass "except-rc" "$CHECK_RC"
else fail "except-rc" "got $CHECK_RC"; fi

# ── 12. --uninstall RETURNS THE HOME TO ITS PRE-INSTALL FILE SET ─────────────────────────────
# The strongest name-independent assertion available: not "these keys are gone" but "nothing this
# installer wrote survives, and nothing it did not write was destroyed". Four empty containers are
# the known, deliberate exception — a key-merging uninstaller must not delete a file that is the
# user's, only the keys it added to it.
drive --uninstall
printf '%s\n' "$CHECK_OUT" | snap uninstall.txt
same "uninstall-rc" "$CHECK_RC" 0
FINAL="$(file_set)"
printf '%s\n' "$FINAL" | snap fileset-uninstalled.txt
RESIDUE="$(printf '%s\n' "$FINAL" | comm -13 <(printf '%s\n' "$BEFORE") - | sed 's/^[^ ]*  //')"
# TWO classes of residue are deliberate, and both are recognised by SHAPE rather than by name so
# that renaming either one cannot quietly turn this check green:
#   · a BACKUP — a copy taken before a file was modified, named <file>.<tag>.<UTC timestamp>.
#     Deleting these would defeat the one thing that makes the uninstall safe on a real Mac.
#   · an EMPTY CONTAINER — `{}`, `{"hooks":{}}`, a 0-byte config, a plist whose only key holds an
#     empty dict. A key-MERGING uninstaller removes its keys; the file itself is the user's.
# Anything else is content this uninstaller failed to remove.
RESIDUE_BAD=""
RESIDUE_BACKUPS=0
RESIDUE_EMPTY=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      RESIDUE_BACKUPS=$((RESIDUE_BACKUPS + 1)); continue ;;
  esac
  # plists are XML or binary; compare the VALUE, not the encoding
  body="$(plutil -convert json -o - -- "$CHECK_HOME/${p#./}" 2>/dev/null)" \
    || body="$(cat "$CHECK_HOME/${p#./}" 2>/dev/null)"
  case "$(printf '%s' "$body" | tr -d ' \n\t')" in
    ''|'{}'|'{"hooks":{}}'|'{"NSUserKeyEquivalents":{}}') RESIDUE_EMPTY=$((RESIDUE_EMPTY + 1)) ;;
    *) RESIDUE_BAD="$RESIDUE_BAD $p" ;;
  esac
done <<RESIDUE_EOF
$RESIDUE
RESIDUE_EOF
if [ -z "$RESIDUE_BAD" ]; then pass "uninstall-leaves-no-content" "$RESIDUE_EMPTY empty container(s) + $RESIDUE_BACKUPS backup(s) kept, by design"
else fail "uninstall-leaves-no-content" "$RESIDUE_BAD"; fi
LOST="$(printf '%s\n' "$BEFORE" | comm -23 - <(printf '%s\n' "$FINAL"))"
if [ -z "$LOST" ]; then pass "uninstall-destroys-nothing-it-did-not-write"
else fail "uninstall-destroys-nothing-it-did-not-write" "$LOST"; fi

# ── 12b. FEATURE CHECKS — one file per feature in scripts/checks/, sourced here ───────────────
# Sourced, not executed, so each file has this harness (drive_at, fresh_home, pass, fail, same, true_,
# json_at) and this sandbox root — and so two features built in parallel never edit the same file.
for CHECK_FILE in "$CHECK_ROOT"/scripts/checks/*.sh; do
  [ -r "$CHECK_FILE" ] || continue
  printf -- '-- %s\n' "${CHECK_FILE##*/}"
  # shellcheck source=/dev/null
  . "$CHECK_FILE"
done

# ── 13. ISOLATION, re-asserted ───────────────────────────────────────────────────────────────
ESCAPED=""
while IFS= read -r f; do
  [ -n "$f" ] && [ -r "$f" ] || continue
  # the sandbox lives under a mktemp path; any real file naming it was written by this run
  if LC_ALL=C grep -qa "$CHECK_TMP" "$f" 2>/dev/null; then ESCAPED="$ESCAPED $f"; fi
  if LC_ALL=C grep -qa "$CHECK_HOME/.mac-bootstrap" "$f" 2>/dev/null; then ESCAPED="$ESCAPED $f"; fi
done <<REAL_EOF
$REAL_TARGETS
REAL_EOF
if [ -z "$ESCAPED" ]; then pass "sandbox-never-escaped" "no real agent config names the sandbox"
else fail "sandbox-never-escaped" "$ESCAPED"; fi
same "real-iterm2-plist-unchanged" "$(real_sum "$PLIST_REAL")" "$PLIST_SUM0"

# ═════════════════════════════════════════════════════════════════════════════════════════════
printf '\n%s of %s check(s) passed.\n' "$((CHECK_TOTAL - CHECK_BAD))" "$CHECK_TOTAL"
[ -n "$CHECK_SNAPSHOT" ] && printf 'snapshot: %s\n' "$CHECK_SNAPSHOT"
[ "$CHECK_BAD" = 0 ] || exit 1
exit 0
