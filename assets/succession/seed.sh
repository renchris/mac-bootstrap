#!/bin/bash
# seed.sh — turn the fresh-Mac blockers into disk facts written BEFORE the successor launches.
#
#   seed.sh check      <cfgdir> <abs-cwd>                 what is still open, one line each
#   seed.sh onboarding <cfgdir>                           kill the first-run theme picker
#   seed.sh trust      <cfgdir> <abs-cwd>                 kill the per-directory workspace-trust modal
#   seed.sh goal       <cfgdir> <abs-cwd> <sid> <cond> [version]   arm a /goal from a FILE
#   seed.sh auth       <cfgdir>                           the login preflight (fail-closed on a NO)
#   seed.sh hooks-ok   <cfgdir>                           refuse a config that has disabled /goal
#   seed.sh selftest
#
# ═══ THE THREE GATES, IN ORDER, AND ONLY THE THIRD NEEDS A HUMAN ═════════════════════════════
# | gate                  | where it lives                                        | seedable |
# | theme picker          | $CLAUDE_CONFIG_DIR/.claude.json hasCompletedOnboarding | YES      |
# | workspace trust       | …projects["<absolute cwd>"].hasTrustDialogAccepted     | YES      |
# | login                 | macOS Keychain, Claude Code-credentials-<sha256(path)[:8]> | NO   |
# Bisected one variable at a time: nothing seeded -> theme picker, prompt SWALLOWED, ZERO
# transcripts. `settings.json {"theme":"dark"}` alone -> the picker STILL appears (theme is not
# the gate). hasCompletedOnboarding alone -> picker gone, stops at the trust modal whose DEFAULT
# SELECTION IS "No, exit" — so a successor that meets it and receives a blind Enter CLOSES
# ITSELF. Both seeded -> straight to the composer and the positional prompt AUTO-SUBMITS, on a
# brand-new config dir under a brand-new $HOME.
# So "claude \"<prompt>\" does not auto-submit on a fresh Mac" was entirely an artifact of two
# absent booleans. It stops applying the moment they are written.
#
# ═══ WHAT THIS FILE WILL NOT WRITE ═══════════════════════════════════════════════════════════
# `hasTrustDialogAccepted` is the one authorization-adjacent key here, and it is written under
# guards: only for an ABSOLUTE, EXISTING directory that is NOT $HOME and NOT a filesystem root
# (on $HOME the dialog itself warns "this folder pre-approves 339 tool permissions"), only when
# AH_SEED_TRUST is not 0, and only for the exact cwd the succession targets. Nothing here writes
# `permissions`, `allowedTools`, `apiKeyHelper`, `settings.local.json` or any credential. There
# is no flag that makes it do so. A login is asked for in chat; it is never scripted.
#
# ═══ NO python3 ══════════════════════════════════════════════════════════════════════════════
# /usr/bin/python3 on a Mac without the Command Line Tools is the CLT stub multiplexer — the same
# inode as /usr/bin/git, 78 links — and running it opens an INSTALL DIALOG. Every published
# recipe for this seeding used python3; this file uses /usr/bin/plutil, which is a real
# base-system binary, and awk.
set -u

SD_P=/usr/bin/plutil
sd_say() { printf '%s\n' "$*"; }
sd_err() { printf '%s\n' "$*" >&2; }

# plutil keypaths are dot-separated, so a key containing a dot must escape it. Our keys are
# ABSOLUTE PATHS, and `.worktrees` / `foo.bar` are ordinary directory names.
sd_kp() { printf '%s' "${1:-}" | LC_ALL=C sed 's/\\/\\\\/g; s/\./\\./g'; }
sd_jstr() {  # minimal JSON string escaping; control characters are REFUSED, not escaped
  printf '%s' "${1:-}" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g'
}
# ── sd_json_ok — validate a JSON document. NOT `plutil -lint`. ───────────────────────────────
# MEASURED TRAP, and it is the obvious spelling: `plutil -lint` REJECTS valid JSON.
#     $ printf '{"a":1}\n' > f.json ; plutil -lint -- f.json
#     f.json: Unexpected character { at line 1          rc=1
# -lint only reads property lists. The validator that actually answers the question is
# `-convert json -o /dev/null`, which is rc 0 on valid JSON and rc 1 on garbage — both arms
# measured. A guard built on -lint would refuse EVERY file it was asked to protect, and its
# refusal message would name the file rather than the instrument.
sd_json_ok() { [ -s "${1:-}" ] && "$SD_P" -convert json -o /dev/null -- "$1" >/dev/null 2>&1; }

# ── sd_get <file> <keypath> — the READ-BACK, and it is a different plutil verb than the write ─
# 🚨 MEASURED TRAP, and it cost a silent seeding failure: `plutil -extract` writes its FAILURE
#    MESSAGE TO STDOUT, not stderr. `2>/dev/null` therefore hides nothing, and a reader that
#    forwards stdout without checking the rc hands its caller an ERROR SENTENCE where a value
#    belongs. The damage is invisible for a `= "true"` test (a sentence is not "true", so the
#    caller does the right thing for the wrong reason) and fatal for a `= ""` test: the
#    "does `projects` exist yet?" check read the sentence as "yes, and it is non-empty", skipped
#    creating the key, and the trust seed then failed on every config dir the binary had already
#    written — which is EVERY real one. Emit only on rc 0.
sd_get() {
  local out rc
  out="$("$SD_P" -extract "$(sd_kp "${2:-}")" raw -o - -- "${1:-}" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out"
}
sd_get_raw() {
  local out rc
  out="$("$SD_P" -extract "${2:-}" raw -o - -- "${1:-}" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out"
}

sd_backup() {
  local f="${1:-}"
  [ -f "$f" ] || return 0
  local b; b="$f.ah-bak.$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)"
  [ -f "$b" ] || cp -p "$f" "$b" 2>/dev/null
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
cmd_onboarding() {
  local cfg="${1:-}" f tmp cur
  [ -n "$cfg" ] || { sd_err "onboarding: need <cfgdir>"; return 2; }
  mkdir -p "$cfg" 2>/dev/null || { sd_err "onboarding: cannot create $cfg"; return 2; }
  f="$cfg/.claude.json"

  if [ ! -s "$f" ]; then
    # Never create a bare {}: plutil -replace AND -insert BOTH fail against an EMPTY ROOT DICT,
    # which is the fresh-Mac case. Create it already populated.
    printf '{"hasCompletedOnboarding":true,"projects":{}}\n' > "$f" 2>/dev/null \
      || { sd_err "onboarding: cannot write $f"; return 2; }
  else
    sd_json_ok "$f" || { sd_err "onboarding: $f is not valid JSON — refusing to touch it"; return 2; }
    cur="$(sd_get "$f" hasCompletedOnboarding)"
    if [ "$cur" != "true" ]; then
      sd_backup "$f"
      tmp="$f.ah-tmp.$$"
      cp -p "$f" "$tmp" 2>/dev/null || { sd_err "onboarding: cannot stage $f"; return 2; }
      "$SD_P" -replace hasCompletedOnboarding -bool true -- "$tmp" >/dev/null 2>&1 \
        || { rm -f "$tmp"; sd_err "onboarding: plutil refused"; return 2; }
      sd_json_ok "$tmp" || { rm -f "$tmp"; sd_err "onboarding: the staged file no longer parses"; return 2; }
      mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 2; }
    fi
    if [ "$(sd_get "$f" projects)" = "" ] && ! "$SD_P" -extract projects json -o /dev/null -- "$f" >/dev/null 2>&1; then
      tmp="$f.ah-tmp.$$"; cp -p "$f" "$tmp" 2>/dev/null || return 2
      "$SD_P" -replace projects -json '{}' -- "$tmp" >/dev/null 2>&1 && mv -f "$tmp" "$f" 2>/dev/null
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  [ "$(sd_get "$f" hasCompletedOnboarding)" = "true" ] || { sd_err "onboarding: read-back says it did not take"; return 2; }
  return 0
}

cmd_trust() {
  local cfg="${1:-}" cwd="${2:-}" f tmp kp cur homep
  [ -n "$cfg" ] && [ -n "$cwd" ] || { sd_err "trust: need <cfgdir> <abs-cwd>"; return 2; }
  [ "${AH_SEED_TRUST:-1}" = 0 ] && { sd_err "trust: disabled by AH_SEED_TRUST=0"; return 3; }
  case "$cwd" in /*) : ;; *) sd_err "trust: cwd must be absolute: $cwd"; return 2 ;; esac
  [ -d "$cwd" ] || { sd_err "trust: cwd does not exist: $cwd"; return 2; }
  # GUARDS. The trust key is the one authorization-adjacent write here, so it is refused for the
  # two targets where it would be a blanket grant rather than a per-workspace one.
  homep="$(cd "$HOME" 2>/dev/null && pwd -P)" || homep="$HOME"
  case "$cwd" in
    /) sd_err "trust: REFUSED for the filesystem root"; return 2 ;;
  esac
  if [ "$cwd" = "$HOME" ] || [ "$cwd" = "$homep" ]; then
    sd_err "trust: REFUSED for \$HOME — the dialog itself warns that this pre-approves hundreds of"
    sd_err "       tool permissions. Give the successor an explicit project directory."
    return 2
  fi
  cmd_onboarding "$cfg" || return 2
  f="$cfg/.claude.json"; kp="projects.$(sd_kp "$cwd")"

  cur="$(sd_get_raw "$f" "$kp.hasTrustDialogAccepted")"
  [ "$cur" = "true" ] && return 0

  sd_backup "$f"
  tmp="$f.ah-tmp.$$"
  cp -p "$f" "$tmp" 2>/dev/null || { sd_err "trust: cannot stage $f"; return 2; }
  if "$SD_P" -extract "$kp" json -o /dev/null -- "$tmp" >/dev/null 2>&1; then
    # the project entry exists — set ONE key inside it, never replace the object (that would
    # discard the entry's history and any tool state the operator already has there)
    "$SD_P" -replace "$kp.hasTrustDialogAccepted" -bool true -- "$tmp" >/dev/null 2>&1 \
      || { rm -f "$tmp"; sd_err "trust: plutil refused $kp.hasTrustDialogAccepted"; return 2; }
  else
    # plutil does NOT auto-create intermediate dicts, so a brand-new entry is written whole.
    # ONE key. No allowedTools, no permissions, nothing that authorizes a tool.
    "$SD_P" -replace "$kp" -json '{"hasTrustDialogAccepted":true}' -- "$tmp" >/dev/null 2>&1 \
      || { rm -f "$tmp"; sd_err "trust: plutil refused $kp"; return 2; }
  fi
  sd_json_ok "$tmp" || { rm -f "$tmp"; sd_err "trust: the staged file no longer parses"; return 2; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 2; }
  [ "$(sd_get_raw "$f" "$kp.hasTrustDialogAccepted")" = "true" ] \
    || { sd_err "trust: read-back says it did not take"; return 2; }
  return 0
}

# ── goal — arm a /goal from a FILE, with no keystrokes and no second message. ─────────────────
# There is NO --goal launcher flag on 2.1.260: --help has no `goal`, the binary registers 93
# `.option("--…")` and none is --goal, and `--goal X` is rejected byte-identically to
# `--zzzbogusflag X`. What exists instead is a seam in the product's own restore path: setting a
# goal appends ONE `goal_status` attachment to the transcript, and `restoreGoalFromTranscript`
# reads back exactly THE LAST such attachment (returning nothing if it is met/failed) and
# re-registers the session-scoped Stop hook from it. So the bootstrap writes that line itself and
# launches `claude --resume <sid> "<brief>"`: ONE exec delivers the goal AND the initial prompt,
# and the restore happens during session init — i.e. the successor's very FIRST turn already has
# the goal armed. That also settles the ordering question for free.
# Measured: a fully SYNTHETIC one-line seed resumes to `Goal active: …`; the same seed with
# met:true resumes to `No goal set`; the interactive TUI shows `◎ /goal active` on the first and
# not on the second. `-c`/`--continue` does NOT find a synthetic seed — resume by explicit uuid.
cmd_goal() {
  local cfg="${1:-}" cwd="${2:-}" sid="${3:-}" cond="${4:-}" ver="${5:-2.1.260}"
  [ -n "$cfg" ] && [ -n "$cwd" ] && [ -n "$sid" ] && [ -n "$cond" ] \
    || { sd_err "goal: need <cfgdir> <abs-cwd> <sid> <condition> [version]"; return 2; }
  case "$cond" in *"
"*) sd_err "goal: the condition must be ONE line"; return 2 ;; esac
  # The seed path BYPASSES the 4000-character cap the command path enforces. Read that as a
  # hazard as much as a feature: it hands the Stop evaluator a condition no validator ever saw.
  if [ "${#cond}" -gt 4000 ]; then
    sd_err "goal: the condition is ${#cond} chars. The command path refuses over 4000; this file"
    sd_err "      path would silently accept it. Shorten it — point at a brief, do not inline one."
    return 2
  fi
  local slug d f uuid ts
  slug="$(printf '%s' "$cwd" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  d="$cfg/projects/$slug"
  mkdir -p "$d" 2>/dev/null || { sd_err "goal: cannot create $d"; return 2; }
  f="$d/$sid.jsonl"
  [ -s "$f" ] && { sd_err "goal: $f already exists — refusing to append a goal to somebody else's transcript"; return 2; }
  uuid="$(/usr/bin/uuidgen 2>/dev/null | LC_ALL=C tr 'A-Z' 'a-z')" || uuid=""
  [ -n "$uuid" ] || uuid="$sid"
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null)" || ts="1970-01-01T00:00:00.000Z"
  printf '{"parentUuid":null,"isSidechain":false,"type":"attachment","uuid":"%s","timestamp":"%s","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"%s"},"userType":"external","entrypoint":"cli","cwd":"%s","sessionId":"%s","version":"%s","gitBranch":"HEAD"}\n' \
    "$uuid" "$ts" "$(sd_jstr "$cond")" "$(sd_jstr "$cwd")" "$sid" "$ver" > "$f" 2>/dev/null \
    || { sd_err "goal: cannot write $f"; return 2; }
  # READ-BACK through a different code path than the writer: the line must be a valid JSON
  # document, and the condition must come back out of it.
  local one="$f.lint.$$"
  cp -f "$f" "$one" 2>/dev/null
  sd_json_ok "$one" || { rm -f "$one"; sd_err "goal: the seed line is not valid JSON"; return 2; }
  [ "$(sd_get_raw "$one" 'attachment.condition')" = "$cond" ] \
    || { rm -f "$one"; sd_err "goal: read-back did not return the condition"; return 2; }
  [ "$(sd_get_raw "$one" 'attachment.met')" = "false" ] \
    || { rm -f "$one"; sd_err "goal: read-back says met is not false — the restore would find nothing"; return 2; }
  rm -f "$one" 2>/dev/null
  printf '%s\n' "$f"
  return 0
}

# ── copilot-trust — the Copilot twin of the workspace-trust seed. ────────────────────────────
# Copilot's ONE first-run modal is `Confirm folder trust`; there is no theme picker. Its state
# lives in $COPILOT_HOME/config.json (NOT settings.json), and `COPILOT_HOME` relocates the whole
# state dir. Two differences from Claude Code worth knowing before trusting the analogy:
#   * Copilot's trust modal DEFAULTS TO "Yes"; Claude Code's defaults to "No, exit".
#   * Copilot gates on LOGIN BEFORE submitting, where Claude Code submits and then fails on auth.
#     So the transcript oracle that works pre-auth for Claude Code does not exist for Copilot —
#     which is why the Copilot bar is ACTED (the ack file), not SPEAKING.
# 🚨 The file is JSON WITH A `//` COMMENT HEADER that Copilot writes itself, so no JSON parser
#    reads it as-is. The header is split off, the body is edited, and the header is put back —
#    never discarded, because it is the product's own note to the user.
cmd_copilot_trust() {
  local ch="${1:-}" cwd="${2:-}" f hdr body tmp cur n i
  [ -n "$ch" ] && [ -n "$cwd" ] || { sd_err "copilot-trust: need <copilot-home> <abs-cwd>"; return 2; }
  case "$cwd" in /*) : ;; *) sd_err "copilot-trust: cwd must be absolute"; return 2 ;; esac
  [ -d "$cwd" ] || { sd_err "copilot-trust: cwd does not exist: $cwd"; return 2; }
  mkdir -p "$ch" 2>/dev/null || { sd_err "copilot-trust: cannot create $ch"; return 2; }
  f="$ch/config.json"
  if [ ! -s "$f" ]; then
    printf '{"firstLaunchAt":"%s","appTipShown":true,"reasoningSummariesCleanupDone":true,"trustedFolders":["%s"]}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null)" "$(sd_jstr "$cwd")" > "$f" 2>/dev/null \
      || { sd_err "copilot-trust: cannot write $f"; return 2; }
    return 0
  fi
  hdr="$f.ah-hdr.$$"; body="$f.ah-body.$$"; tmp="$f.ah-tmp.$$"
  LC_ALL=C awk -v H="$hdr" -v B="$body" 'started{print > B; next}
      /^[ \t]*\/\// { print > H; next }
      { started=1; print > B }' "$f" 2>/dev/null
  [ -f "$body" ] || { rm -f "$hdr" "$body"; sd_err "copilot-trust: $f has no JSON body"; return 2; }
  sd_json_ok "$body" || { rm -f "$hdr" "$body"; sd_err "copilot-trust: the JSON body of $f does not parse — refusing to touch it"; return 2; }
  # MEASURED TRAP: `plutil -extract <an array> raw` prints the element COUNT, not the elements.
  # Reading it as a list (`| grep -c .`) answers 1 for every array of any size, so the
  # already-present check never matched and every re-seed appended a duplicate.
  n="$("$SD_P" -extract trustedFolders raw -o - -- "$body" 2>/dev/null)" || n=0
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  i=0
  while [ "$i" -lt "$n" ]; do
    cur="$("$SD_P" -extract "trustedFolders.$i" raw -o - -- "$body" 2>/dev/null)"
    [ "$cur" = "$cwd" ] && { rm -f "$hdr" "$body"; return 0; }
    i=$((i + 1))
  done
  sd_backup "$f"
  if [ "$n" = 0 ]; then
    "$SD_P" -replace trustedFolders -json "[\"$(sd_jstr "$cwd")\"]" -- "$body" >/dev/null 2>&1 || i=99
  else
    "$SD_P" -insert "trustedFolders.$n" -string "$cwd" -- "$body" >/dev/null 2>&1 || i=99
  fi
  [ "$i" != 99 ] || { rm -f "$hdr" "$body"; sd_err "copilot-trust: plutil refused"; return 2; }
  sd_json_ok "$body" || { rm -f "$hdr" "$body"; sd_err "copilot-trust: the staged body no longer parses"; return 2; }
  { [ -s "$hdr" ] && cat "$hdr"; cat "$body"; } > "$tmp" 2>/dev/null
  rm -f "$hdr" "$body"
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 2; }
  return 0
}

# ── hooks-ok — a "minimal safe defaults" bootstrap can DISABLE /goal as a side effect. ────────
# Measured, two arms: with no settings.json, `claude -p "/goal …"` answers `Goal set: …`; with
# {"disableAllHooks":true} it answers "/goal can't run while hooks are restricted (disableAllHooks
# or allowManagedHooksOnly is set in settings or by policy)."
cmd_hooks_ok() {
  local cfg="${1:-}" f k
  f="$cfg/settings.json"
  [ -s "$f" ] || return 0
  sd_json_ok "$f" || return 0
  for k in disableAllHooks allowManagedHooksOnly; do
    if [ "$(sd_get "$f" "$k")" = "true" ]; then
      sd_say "$f sets $k:true — that DISABLES /goal outright. Remove it, or fire with --no-goal."
      return 2
    fi
  done
  return 0
}

# ── auth — the one gate no file can seed. FAIL-CLOSED on a definite NO, PROCEED on unknown. ────
# Credentials are macOS Keychain items named `Claude Code-credentials-<first 8 hex of
# sha256(absolute config-dir path)>` — verified 4/4 against real dirs plus a negative control, and
# md5/sha1 of the same paths match nothing. Consequences, all load-bearing:
#   * `cp -R` of a config dir produces a dir that is ONBOARDED and LOGGED OUT.
#   * moving or renaming a config dir LOGS IT OUT SILENTLY, because the hash changes.
#   * therefore: ONE `claude auth login` per config-dir PATH, once, ever.
# `claude auth status --json` is the instrument, and it is ONE-ARMED as measured (only the
# negative arm was observed), so an UNRECOGNISED answer is reported as unknown and does NOT
# refuse: a preflight that refuses on a working machine makes the feature unusable, while the
# oracle's AUTHFAIL tier catches a real logout in about a second and lands on HOLD with the
# predecessor alive. Fail-closed belongs at the gate that costs work, not at the one that costs a
# false refusal.
cmd_auth() {
  local cfg="${1:-}" bin="${2:-claude}" out
  [ -n "$cfg" ] || { sd_err "auth: need <cfgdir>"; return 2; }
  command -v "$bin" >/dev/null 2>&1 || bin="$(command -v claude 2>/dev/null)" || bin=""
  [ -n "$bin" ] || { sd_say "unknown: no claude binary to ask"; return 3; }
  # NEVER pipe this: `claude -p … | head` reports rc 0 over a refusal that exits 1 and prints on
  # STDOUT. Capture, then read the rc off the capture.
  out="$(CLAUDE_CONFIG_DIR="$cfg" "$bin" auth status --json 2>/dev/null)"
  case "$out" in
    *'"loggedIn":true'*|*'"loggedIn": true'*)   return 0 ;;
    *'"loggedIn":false'*|*'"loggedIn": false'*)
      sd_say "NOT LOGGED IN. This is the ONE human gesture, once per config-dir PATH, ever:"
      sd_say "  CLAUDE_CONFIG_DIR=$cfg $bin auth login"
      sd_say "Do not move or rename $cfg afterwards — the Keychain item is keyed on its absolute path."
      return 2 ;;
    *) sd_say "unknown: 'claude auth status --json' did not answer loggedIn (this instrument has"
       sd_say "         only a demonstrated NEGATIVE arm). Proceeding; the oracle's AUTHFAIL tier"
       sd_say "         catches a real logout in ~1s and HOLDS the predecessor."
       return 3 ;;
  esac
}

cmd_check() {
  local cfg="${1:-}" cwd="${2:-}" f kp rc=0
  f="$cfg/.claude.json"
  if [ "$(sd_get "$f" hasCompletedOnboarding)" = "true" ]; then sd_say "onboarding: seeded"
  else sd_say "onboarding: OPEN — the successor will park on the first-run theme picker"; rc=1; fi
  if [ -n "$cwd" ]; then
    kp="projects.$(sd_kp "$cwd")"
    if [ "$(sd_get_raw "$f" "$kp.hasTrustDialogAccepted")" = "true" ]; then sd_say "trust[$cwd]: seeded"
    else sd_say "trust[$cwd]: OPEN — the successor will park on the workspace-trust modal, whose DEFAULT IS 'No, exit'"; rc=1; fi
  fi
  cmd_hooks_ok "$cfg" || rc=1
  return $rc
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
sd__t=0; sd__f=0
sd_ok()  { sd__t=$((sd__t+1)); printf '  ok   %s\n' "$1"; }
sd_bad() { sd__t=$((sd__t+1)); sd__f=$((sd__f+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
sd_is()  { if [ "$2" = "$3" ]; then sd_ok "$1"; else sd_bad "$1" "want [$3] got [$2]"; fi; }

cmd_selftest() {
  local tmp cfg wd out rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sd-selftest.XXXXXX")" || return 1
  cfg="$tmp/cfg"; wd="$tmp/a.b_c d/wt"      # a cwd with a dot, an underscore and a space
  mkdir -p "$wd"
  printf 'seed.sh selftest\n'

  # ── a VIRGIN dir: both gates OPEN (this is the fresh-Mac state, and the negative arm)
  mkdir -p "$cfg"
  out="$(cmd_check "$cfg" "$wd")"; rc=$?
  sd_is "NEG virgin config: check fails"        "$rc" "1"
  case "$out" in *"onboarding: OPEN"*) sd_ok "NEG virgin: onboarding reported OPEN" ;;
                 *) sd_bad "NEG virgin: onboarding reported OPEN" "got [$out]" ;; esac
  case "$out" in *"trust[$wd]: OPEN"*) sd_ok "NEG virgin: trust reported OPEN" ;;
                 *) sd_bad "NEG virgin: trust reported OPEN" "got [$out]" ;; esac

  # ── seed, then read back through a DIFFERENT verb than the writer used
  cmd_onboarding "$cfg" && sd_ok "POS onboarding seeds" || sd_bad "POS onboarding seeds"
  cmd_trust "$cfg" "$wd" && sd_ok "POS trust seeds (cwd with . _ and a space)" || sd_bad "POS trust seeds"
  out="$(cmd_check "$cfg" "$wd")"; rc=$?
  sd_is "POS both gates closed: check passes"   "$rc" "0"
  sd_json_ok "$cfg/.claude.json" && sd_ok "POS the file still parses as JSON" || sd_bad "POS the file still parses"

  # ── ADDITIVE: an existing project entry keeps its other keys
  "$SD_P" -replace "projects.$(sd_kp "$wd").someOperatorKey" -string keepme -- "$cfg/.claude.json" >/dev/null 2>&1
  "$SD_P" -replace "projects.$(sd_kp "$wd").hasTrustDialogAccepted" -bool false -- "$cfg/.claude.json" >/dev/null 2>&1
  cmd_trust "$cfg" "$wd" >/dev/null 2>&1
  sd_is "POS re-seeding preserves the operator's other keys" \
        "$(sd_get_raw "$cfg/.claude.json" "projects.$(sd_kp "$wd").someOperatorKey")" "keepme"
  sd_is "POS ... and sets the trust key"        \
        "$(sd_get_raw "$cfg/.claude.json" "projects.$(sd_kp "$wd").hasTrustDialogAccepted")" "true"

  # ── IDEMPOTENT
  cmd_trust "$cfg" "$wd" >/dev/null 2>&1 && sd_ok "POS trust is idempotent" || sd_bad "POS trust is idempotent"

  # ── THE GUARDS: $HOME and / are refused, and AH_SEED_TRUST=0 disables the write entirely
  cmd_trust "$cfg" "$HOME" >/dev/null 2>&1; sd_is "NEG trust REFUSES \$HOME" "$?" "2"
  cmd_trust "$cfg" "/" >/dev/null 2>&1;     sd_is "NEG trust REFUSES /"     "$?" "2"
  ( AH_SEED_TRUST=0; export AH_SEED_TRUST; cmd_trust "$cfg" "$wd" >/dev/null 2>&1 )
  sd_is "NEG AH_SEED_TRUST=0 refuses"         "$?" "3"
  cmd_trust "$cfg" "$tmp/nope" >/dev/null 2>&1; sd_is "NEG trust refuses a cwd that does not exist" "$?" "2"

  # ── an EMPTY ROOT DICT is the fresh-Mac case plutil cannot -replace into. Both arms.
  printf '{}\n' > "$tmp/empty.json"
  "$SD_P" -replace hasCompletedOnboarding -bool true -- "$tmp/empty.json" >/dev/null 2>&1
  sd_is "NEG plutil -replace into an EMPTY root dict FAILS (this is why we never create {})" "$?" "1"

  # ── THE READER. `plutil -extract` prints its FAILURE to STDOUT, so a missing key must come
  #    back EMPTY rather than as an error sentence. This is the bug that broke trust seeding on
  #    every config dir the binary itself had already written.
  sd_is "NEG a missing key reads back EMPTY, not as an error sentence" \
        "$(sd_get "$cfg/.claude.json" noSuchKeyAnywhere)" ""
  sd_get "$cfg/.claude.json" noSuchKeyAnywhere >/dev/null 2>&1; sd_is "NEG ... and rc is 1" "$?" "1"
  # the pre-fix form, kept so the repair is attributable rather than merely asserted
  out="$("$SD_P" -extract noSuchKeyAnywhere raw -o - -- "$cfg/.claude.json" 2>/dev/null)"
  [ -n "$out" ] && sd_ok "NEG the PRE-FIX reader returns a non-empty error sentence (this is the defect)" \
                || sd_bad "NEG the pre-fix reader was expected to leak an error sentence"

  # ── a config dir the BINARY wrote first (the real shape: no 'projects' key at all) must still
  #    take the trust seed. This is the exact file that failed before the reader was fixed.
  mkdir -p "$tmp/real"
  printf '{"migrationVersion":14,"firstStartTime":"2026-01-01T00:00:00.000Z","machineID":"x","seenNotifications":{}}' > "$tmp/real/.claude.json"
  cmd_trust "$tmp/real" "$wd" && sd_ok "POS trust seeds a config dir that has NO projects key yet" \
                              || sd_bad "POS trust seeds a config dir with no projects key"
  sd_is "POS ... and it reads back true" \
        "$(sd_get_raw "$tmp/real/.claude.json" "projects.$(sd_kp "$wd").hasTrustDialogAccepted")" "true"
  sd_is "POS ... without destroying what the binary wrote" \
        "$(sd_get "$tmp/real/.claude.json" machineID)" "x"

  # ── the VALIDATOR itself, both arms — because the obvious spelling (`plutil -lint`) rejects
  #    every valid JSON file, which would make the guard below refuse everything it protects.
  sd_json_ok "$cfg/.claude.json" && sd_ok "POS the JSON validator accepts valid JSON" \
                                 || sd_bad "POS the JSON validator accepts valid JSON"
  printf 'not json\n' > "$tmp/notjson.json"
  sd_json_ok "$tmp/notjson.json" && sd_bad "NEG the JSON validator rejects garbage" \
                                 || sd_ok "NEG the JSON validator rejects garbage"
  "$SD_P" -lint -- "$cfg/.claude.json" >/dev/null 2>&1 \
    && sd_bad "NEG plutil -lint is NOT the validator (it must reject this valid JSON)" \
    || sd_ok "NEG plutil -lint REJECTS valid JSON — this is why sd_json_ok uses -convert"

  # ── a file that is not JSON is refused, not clobbered
  cmd_onboarding "$tmp/badcfg" >/dev/null 2>&1
  printf 'not json at all\n' > "$tmp/badcfg/.claude.json"
  cmd_onboarding "$tmp/badcfg" >/dev/null 2>&1
  sd_is "NEG a non-JSON .claude.json is REFUSED"  "$?" "2"
  sd_is "NEG ... and left untouched"              "$(cat "$tmp/badcfg/.claude.json")" "not json at all"

  # ── THE GOAL SEED, both arms
  local sid="11111111-2222-3333-4444-555555555555"
  out="$(cmd_goal "$cfg" "$wd" "$sid" 'land the branch and print git log -1 --oneline')"; rc=$?
  sd_is "POS goal seed writes a file"           "$rc" "0"
  [ -s "$out" ] && sd_ok "POS the seed file exists" || sd_bad "POS the seed file exists"
  sd_is "POS the seed lands at the MEASURED slug (every non-alnum -> dash)" \
        "$(basename "$(dirname "$out")")" "$(printf '%s' "$wd" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  sd_is "POS the seed's condition reads back"   \
        "$(sd_get_raw "$out" 'attachment.condition')" "land the branch and print git log -1 --oneline"
  cmd_goal "$cfg" "$wd" "$sid" 'second try' >/dev/null 2>&1
  sd_is "NEG goal REFUSES to append to an existing transcript" "$?" "2"
  cmd_goal "$cfg" "$wd" "22222222-2222-3333-4444-555555555555" "$(printf 'a\nb')" >/dev/null 2>&1
  sd_is "NEG goal REFUSES a multi-line condition" "$?" "2"
  local big; big="$(LC_ALL=C awk 'BEGIN{s="";while(length(s)<4100)s=s "x";print s}')"
  cmd_goal "$cfg" "$wd" "33333333-2222-3333-4444-555555555555" "$big" >/dev/null 2>&1
  sd_is "NEG goal REFUSES over the 4000-char cap the command path enforces" "$?" "2"
  # a condition carrying JSON metacharacters must survive the round trip
  cmd_goal "$cfg" "$wd" "44444444-2222-3333-4444-555555555555" 'print "x" \ and $Y — ✓' >/dev/null 2>&1
  sd_is "POS a condition with quotes, a backslash and unicode round-trips" \
        "$(sd_get_raw "$cfg/projects/$(printf '%s' "$wd" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')/44444444-2222-3333-4444-555555555555.jsonl" 'attachment.condition')" \
        'print "x" \ and $Y — ✓'

  # ── hooks gate, both arms
  cmd_hooks_ok "$cfg" >/dev/null 2>&1; sd_is "POS no settings.json -> hooks OK" "$?" "0"
  printf '{"disableAllHooks":true}\n' > "$cfg/settings.json"
  cmd_hooks_ok "$cfg" >/dev/null 2>&1; sd_is "NEG disableAllHooks:true -> REFUSED (it disables /goal)" "$?" "2"
  printf '{"allowManagedHooksOnly":true}\n' > "$cfg/settings.json"
  cmd_hooks_ok "$cfg" >/dev/null 2>&1; sd_is "NEG allowManagedHooksOnly:true -> REFUSED" "$?" "2"
  rm -f "$cfg/settings.json"

  # ── COPILOT TRUST, including the `//` comment header the product writes itself
  local ch="$tmp/cph"
  cmd_copilot_trust "$ch" "$wd" && sd_ok "POS copilot-trust creates a fresh config" || sd_bad "POS copilot-trust creates a fresh config"
  printf '// User settings belong in settings.json.\n// This file is managed automatically.\n{\n  "appTipShown": true,\n  "trustedFolders": ["/already/here"]\n}\n' > "$ch/config.json"
  cmd_copilot_trust "$ch" "$wd" && sd_ok "POS copilot-trust edits a config WITH a // header" || sd_bad "POS copilot-trust edits a // header config"
  sd_is "POS ... the header survives" "$(head -1 "$ch/config.json")" "// User settings belong in settings.json."
  sd_is "POS ... the existing entry survives" \
        "$(LC_ALL=C awk 'started{print;next} /^[ \t]*\/\//{next} {started=1;print}' "$ch/config.json" > "$ch/b.json"; "$SD_P" -extract trustedFolders.0 raw -o - -- "$ch/b.json" 2>/dev/null)" "/already/here"
  sd_is "POS ... and the new one is appended" \
        "$("$SD_P" -extract trustedFolders.1 raw -o - -- "$ch/b.json" 2>/dev/null)" "$wd"
  cmd_copilot_trust "$ch" "$wd" && sd_ok "POS copilot-trust is idempotent" || sd_bad "POS copilot-trust is idempotent"
  LC_ALL=C awk 'started{print;next} /^[ \t]*\/\//{next} {started=1;print}' "$ch/config.json" > "$ch/b2.json"
  # `-extract <array> raw` prints the COUNT — the trap that made the de-dup check vacuous.
  sd_is "POS ... re-running adds no duplicate (2, not 3)" \
        "$("$SD_P" -extract trustedFolders raw -o - -- "$ch/b2.json" 2>/dev/null)" "2"
  printf '// hdr\nthis is not json\n' > "$ch/config.json"
  cmd_copilot_trust "$ch" "$wd" >/dev/null 2>&1; sd_is "NEG an unparseable copilot config is REFUSED, not clobbered" "$?" "2"
  sd_is "NEG ... and left untouched" "$(tail -1 "$ch/config.json")" "this is not json"

  # ── auth: the demonstrated NEGATIVE arm is a config dir that cannot be logged in
  out="$(cmd_auth "$cfg")"; rc=$?
  case "$rc" in
    2) case "$out" in *"auth login"*) sd_ok "NEG unauthenticated cfg -> refuse, and names the gesture" ;;
                      *) sd_bad "NEG unauthenticated cfg names the gesture" "got [$out]" ;; esac ;;
    3) sd_ok "NEG auth: unknown answer -> proceeds (one-armed instrument, stated)" ;;
    *) sd_bad "NEG auth on a virgin dir must not report logged in" "rc=$rc [$out]" ;;
  esac

  rm -rf "$tmp" 2>/dev/null
  printf '\n%s tests, %s failed\n' "$sd__t" "$sd__f"
  [ "$sd__f" = 0 ]
}

case "${1:-}" in
  check)      shift; cmd_check "${1:-}" "${2:-}" ;;
  onboarding) shift; cmd_onboarding "${1:-}" ;;
  trust)      shift; cmd_trust "${1:-}" "${2:-}" ;;
  copilot-trust) shift; cmd_copilot_trust "${1:-}" "${2:-}" ;;
  goal)       shift; cmd_goal "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  hooks-ok)   shift; cmd_hooks_ok "${1:-}" ;;
  auth)       shift; cmd_auth "${1:-}" "${2:-}" ;;
  slug)       shift; printf '%s\n' "$(printf '%s' "${1:-}" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')" ;;
  selftest)   cmd_selftest ;;
  *) sd_err "usage: seed.sh check|onboarding|trust|goal|hooks-ok|auth|slug|selftest"; exit 2 ;;
esac
