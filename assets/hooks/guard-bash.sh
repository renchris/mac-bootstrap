#!/bin/bash
# guard-bash.sh — PreToolUse(Bash). Five irreversible shapes, denied by CLASS not by spelling.
#
# ══════════════════════════════════════════════════════════════════════════════════════════════
# 🚨 THIS FILE SHIPS UNWIRED, DELIBERATELY, AND STAYS UNWIRED EVEN THOUGH IT IS NOW FIXED.
#
# The version this repo inherited FALSE-ALLOWED its own flagship class. Measured against the
# shipped file: `rm -rf "$HOME/stuff"`, `rm -rf "$HOME"/stuff`, a quoted absolute home path,
# `rm -rf ~`, `rm -rf ${HOME}/x`, `git push --force origin "main"` and `git push origin +main`
# were all ALLOWED — because its quote-stripping pre-pass deleted the quoted BODY, i.e. exactly
# the token its deny patterns matched, and because all fourteen of its must-deny fixtures were
# UNQUOTED, holding the axis under test constant at the one value that cannot express the bug.
# Quoting a path is the MORE idiomatic agent spelling, so the bypass was the likelier shape. The
# rewrite below fixes it and proves the fix with a matrix carrying at least one quoted variant
# per must-deny row plus refspec, ${HOME} and bare-`~` arms — but the wiring decision is not a
# code decision. A guard BELIEVED PRESENT but inert is strictly worse than one known absent: it
# buys false confidence in the one direction — an irreversible command — where being wrong cannot
# be undone. This file has now been wrong once in exactly that direction, so it earns its wiring
# by running in anger under a real agent, not by passing its own author's fixtures.
# `hooks.sh` installs it and does NOT register it; `verify_hooks` ASSERTS it is absent from
# both settings files, so "unwired" is a checked fact rather than a hope. To wire it deliberately,
# after reading this paragraph:   bash guard-bash.sh --wire-me-instructions
# ══════════════════════════════════════════════════════════════════════════════════════════════
#
# PREVENTS: (1) recursive+force rm reaching $HOME or / ; (2) git clean -x/-X, which deletes
# GITIGNORED files — .env, credentials, build caches, and any generated or paid asset ignored on
# purpose; (3) --no-verify / commit -n, which bypasses the hook that just caught something real;
# (4) force-push touching the trunk, including BY REFSPEC (`+main`), which carries no flag at all;
# (5) git add -f, which defeats .gitignore and bloats history with binaries.
#
# FOUR DESIGN RULES, each of which cost a measured false result when it was absent:
#  · DELETE-THEN-MATCH ON FLAG LETTERS, never a list of spellings. -rf, -fr, -Rf, -r -f and
#    --recursive --force are ONE command; a literal "-rf" pattern lets the other four through.
#  · PER-SEGMENT. Split on && || ; | and judge each segment alone. A whole-string flag scan
#    measured 2 false positives: `git add -A && rm -f /tmp/x` reads as `git add` + `-f`.
#  · SPLIT FIRST, THEN DROP QUOTE **CHARACTERS**, KEEPING THE BODY. This is the R1 repair. The
#    normaliser is one awk pass that tracks quote state, so `;` and `|` INSIDE a quoted string
#    are not separators and the path inside the quotes still reaches the patterns.
#  · A SEGMENT WHOSE COMMAND WORD PRINTS IS NOT RUNNING ANYTHING. `echo "git push --force origin
#    main" > notes.txt` writes a note. That is what the quote-body strip was really for, and it
#    is bought here by looking at the command word instead of by deleting the evidence.
#
# FAIL-OPEN EVERYWHERE: unreadable stdin, no jq, any error ⇒ the tool proceeds. EVERY exit is an
# explicit 0 — Copilot's preToolUse fails CLOSED on any non-zero exit, so a crash here would deny
# the tool call. The deny is carried in the JSON, never in the exit code.
#
# RESIDUAL THE RESEARCH RECORDED AND THIS VERSION NO LONGER HAS, stated because the old text is
# still quoted elsewhere: "with no jq this hook is FULLY INERT". That WAS true — bootstrap_json refuses a
# nested path without jq, so $CMD came back empty and every command was allowed. It is fixed here,
# not by a better regex but by using the other engine the library already trusts: hook_field writes
# the payload to a temp file and reads it with plutil, which parses nesting and quoting properly.
# Measured: the whole 66-case matrix passes under BOOTSTRAP_NO_JQ=1, and the selftest carries a no-jq arm
# so the degrade is tested rather than asserted.
# THE RESIDUAL THAT REMAINS: `rm -rf ..`, and absolute system paths other than `/` itself, are NOT
# in the measured class and are NOT denied. Do not read this file as a general destructive-command
# firewall; it denies five named shapes.
#
# Seams: BOOTSTRAP_BASH_GUARD_HOOK=0 disables. Self-test: bash guard-bash.sh --selftest
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || HOOK_DIR="."
HOOK_SELF="$HOOK_DIR/$(basename "${BASH_SOURCE[0]:-$0}")"
# shellcheck source=bootstrap-lib.sh disable=SC1091
. "$HOOK_DIR/bootstrap-lib.sh" 2>/dev/null || exit 0

# ── hook_field <payload> <keypath> — READ A FIELD OUT OF THE HOOK PAYLOAD, WITH OR WITHOUT jq. ──
# bootstrap_json is the library's reader and is deliberately conservative without jq: it handles only
# FLAT keys whose values are QUOTED STRINGS, because sed-extracting a quote-laden shell command
# out of JSON mis-parses silently and a wrong answer is worse than none. Two consequences bit
# here, both MEASURED under BOOTSTRAP_NO_JQ=1:
#   · `stop_hook_active` is a flat key with a BOOLEAN value, so it read EMPTY — and bound B1, the
#     one that makes a blocking Stop hook provably terminate, silently disarmed.
#   · every nested read (`tool_input.file_path`, `tool_input.command`) read EMPTY, so both guards
#     were inert rather than merely weaker.
# The repair is not a better regex: it is to use the OTHER engine the library already trusts.
# plutil parses the payload properly — booleans, numbers, nesting, embedded quotes — so we write
# the payload to a temp file ONCE and extract through bootstrap_settings_get, which emits only on rc 0
# (plutil writes its failure message to STDOUT, so a reader that forwards stdout blindly hands
# its caller an error sentence where a value belongs). With jq present this path never runs.
HOOK_PAYLOAD=""
hook_field() {
  local v
  v="$(bootstrap_json "${1:-}" "${2:-}")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  if [ -z "$HOOK_PAYLOAD" ]; then
    HOOK_PAYLOAD="$(mktemp -t hook-payload 2>/dev/null)" || { HOOK_PAYLOAD=""; return 0; }
    printf '%s' "${1:-}" > "$HOOK_PAYLOAD" 2>/dev/null || { rm -f "$HOOK_PAYLOAD"; HOOK_PAYLOAD=""; return 0; }
  fi
  bootstrap_settings_get "$HOOK_PAYLOAD" "${2:-}" raw 2>/dev/null
  return 0
}
hook_field_cleanup() { [ -n "$HOOK_PAYLOAD" ] && rm -f "$HOOK_PAYLOAD" 2>/dev/null; HOOK_PAYLOAD=""; return 0; }
trap hook_field_cleanup EXIT

HOOK_REASON=""

# ── hook_segments — split a command into judgeable segments, quote-aware. ─────────────────────
# One awk pass over the characters: quote chars are DROPPED (the body survives), and `;` `|` `&`
# become separators ONLY outside quotes. Reads on stdin, never argv: the string being judged is
# the user's whole command, and a command in argv is a command `ps` prints to every other uid.
hook_segments() {
  awk '
  {
    line = $0; out = ""; sq = 0; dq = 0
    n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (sq) { if (c == "\047") sq = 0; else out = out c; continue }
      if (dq) {
        if (c == "\\") { i++; out = out substr(line, i, 1); continue }
        if (c == "\"") { dq = 0; continue }
        out = out c; continue
      }
      if (c == "\047") { sq = 1; continue }
      if (c == "\"")   { dq = 1; continue }
      if (c == ";" || c == "|" || c == "&") { out = out "\n"; continue }
      out = out c
    }
    print out
  }'
}

# ── hook_check_segment <segment> → 0 = deny (reason in HOOK_REASON) · 1 = nothing to say ───────
hook_check_segment() {
  local seg="${1:-}" cw="" sub="" flags="" longs=" " w bare tgt=0 root=0 trunk=0 plus=0 hadf

  case "$-" in *f*) hadf=1 ;; *) hadf=0 ;; esac
  set -f
  # shellcheck disable=SC2086  # deliberate word-split; globbing is off for exactly this line
  set -- $seg
  [ "$hadf" = 1 ] || set +f
  [ $# -gt 0 ] || return 1

  for w in "$@"; do
    if [ -z "$cw" ]; then
      case "$w" in *=*) continue ;; esac                            # VAR=value prefix
      case "${w##*/}" in
        sudo|doas|env|command|nohup|time|xargs|builtin) continue ;; # wrappers
      esac
      cw="${w##*/}"
      continue
    fi
    case "$w" in
      --) continue ;;
      --*) longs="$longs$w " ; continue ;;
      -?*) flags="$flags${w#-}" ; continue ;;
    esac
    [ -z "$sub" ] && sub="$w"
    # ── target classification, on a real (non-flag) word ──
    # shellcheck disable=SC2088  # the LITERAL tilde is the point: we are matching the text the
    # agent typed, not a path we intend to expand. `rm -rf ~` is the shape that got through.
    case "$w" in
      '~'|'~/'*|'$HOME'|'$HOME'/*|'${HOME}'|'${HOME}'/*) tgt=1 ;;
    esac
    if [ -n "${HOME:-}" ]; then
      case "$w" in "$HOME"|"$HOME"/*) tgt=1 ;; esac
    fi
    bare="$w"
    while [ -n "$bare" ] && [ "$bare" != "${bare%/}" ]; do bare="${bare%/}"; done
    case "$w" in /*) [ -z "$bare" ] && root=1 ;; esac
    case "$w" in '/*'|'/.'|'/..') root=1 ;; esac
    case "$w" in
      main|master|*:main|*:master|*/main|*/master) trunk=1 ;;
    esac
    case "$w" in
      '+'*) case "$w" in *main*|*master*) plus=1 ;; esac ;;
    esac
  done

  # a segment whose command word PRINTS is not running anything
  case "$cw" in echo|printf|cat|true|:|tee) return 1 ;; esac

  # delete-then-match: the SAFE long option is removed before --force is looked for
  longs="${longs//--force-with-lease/}"
  _hasf() { case "$flags" in *f*) return 0 ;; esac; case "$longs" in *--force*) return 0 ;; esac; return 1; }
  _hasr() { case "$flags" in *[rR]*) return 0 ;; esac; case "$longs" in *--recursive*) return 0 ;; esac; return 1; }

  # 1. recursive + force rm reaching $HOME or /
  if [ "$cw" = rm ] && _hasr && _hasf && { [ "$tgt" = 1 ] || [ "$root" = 1 ]; }; then
    HOOK_REASON="DENIED: a recursive+force rm naming \$HOME or /. Flag spelling is irrelevant — -rf, -fr, -Rf, -r -f and --recursive --force are the same command, and quoting the path changes nothing. Name a path relative to the project root instead."
    return 0
  fi
  # 2. git clean -x / -X — deletes GITIGNORED files
  if [ "$cw" = git ] && [ "$sub" = clean ]; then
    case "$flags" in *[xX]*)
      HOOK_REASON="DENIED: 'git clean' with -x/-X deletes GITIGNORED files — .env, credentials, build caches, and any generated or paid asset that is ignored on purpose. Preview with 'git clean -nd', then use 'git clean -fd' (no -x)."
      return 0 ;;
    esac
  fi
  # 3. --no-verify / git commit -n
  case "$longs" in *--no-verify*)
    HOOK_REASON="DENIED: --no-verify bypasses the pre-commit hook. If a hook blocked the commit it caught something real — fix the cause."
    return 0 ;;
  esac
  if [ "$cw" = git ] && [ "$sub" = commit ]; then
    case "$flags" in *n*)
      HOOK_REASON="DENIED: 'git commit -n' is the short form of --no-verify and bypasses the pre-commit hook. Fix the cause instead."
      return 0 ;;
    esac
  fi
  # 4. force-push touching the trunk — by flag, or BY REFSPEC, which carries no flag at all
  if [ "$cw" = git ] && [ "$sub" = push ]; then
    if [ "$plus" = 1 ]; then
      HOOK_REASON="DENIED: a leading '+' in a push refspec IS a force push, with no --force anywhere in the command, and this one targets the trunk. Push a topic branch and open a PR, or ask the operator explicitly."
      return 0
    fi
    if _hasf && [ "$trunk" = 1 ]; then
      HOOK_REASON="DENIED: force-push touching the trunk. This rewrites history other clones already have. Push a topic branch and open a PR, or ask the operator explicitly. (--force-with-lease is the safe form and is allowed.)"
      return 0
    fi
  fi
  # 5. git add -f — force-add a gitignored path
  if [ "$cw" = git ] && [ "$sub" = add ] && _hasf; then
    HOOK_REASON="DENIED: 'git add -f' force-adds a file .gitignore excludes. If it is ignored that was deliberate — force-adding bloats history and defeats the protection."
    return 0
  fi
  return 1
}

# ── hook_verdict <command-string> → prints the deny JSON and returns 0, or prints nothing / 1 ──
# BOTH output shapes in one object: Claude Code reads hookSpecificOutput.permissionDecision,
# Copilot CLI reads the top-level permissionDecision. Each ignores the other's, so one file
# serves both. The exit code is ALWAYS 0; the decision travels in the JSON.
hook_verdict() {
  local cmd="${1:-}" s jq oldifs hadf rc=1
  [ -n "$cmd" ] || return 1
  case "$-" in *f*) hadf=1 ;; *) hadf=0 ;; esac
  oldifs="$IFS"; IFS='
'
  set -f
  # NOT `… | while read`: a pipeline's while runs in a SUBSHELL, so a verdict set there would be
  # lost and the guard would silently allow. Word-splitting on IFS=newline stays in THIS shell.
  # shellcheck disable=SC2046,SC2086
  set -- $(printf '%s' "$cmd" | hook_segments)
  IFS="$oldifs"; [ "$hadf" = 1 ] || set +f
  for s in "$@"; do
    [ -n "$s" ] || continue
    if hook_check_segment "$s"; then rc=0; break; fi
  done
  [ "$rc" = 0 ] || return 1
  jq="$(bootstrap_jq)" || jq=""
  if [ -n "$jq" ]; then
    "$jq" -nc --arg r "$HOOK_REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r},
        permissionDecision:"deny",permissionDecisionReason:$r}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"},"permissionDecision":"deny","permissionDecisionReason":"%s"}\n' \
      "$(bootstrap_json_escape "$HOOK_REASON")" "$(bootstrap_json_escape "$HOOK_REASON")"
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# SHIPPED FIXTURES — bash guard-bash.sh --selftest
# Every must-deny row carries at least one QUOTED variant, because the defect this file was
# rewritten for was invisible to a matrix in which every case was unquoted. The must-allow half
# is not decoration either: the printer skip and --force-with-lease are what keep it green, and a
# guard with no false-positive control is a guard nobody can leave switched on.
# ═════════════════════════════════════════════════════════════════════════════════════════════
hook_selftest() {
  local n=0 bad=0 out
  printf 'pb-guard-bash selftest · bash %s\n' "${BASH_VERSION:-?}"
  _deny() {  # _deny <command> — MUST be denied
    n=$((n+1)); out="$(hook_verdict "$1")"
    case "$out" in *'"deny"'*) printf '  ok   DENY   %s\n' "$1" ;;
      *) bad=$((bad+1)); printf '  FAIL ALLOWED (must deny)   %s\n' "$1" ;;
    esac
  }
  _allow() { # _allow <command> — MUST be allowed (any output here is a false positive)
    n=$((n+1)); out="$(hook_verdict "$1")"
    if [ -z "$out" ]; then printf '  ok   allow  %s\n' "$1"
    else bad=$((bad+1)); printf '  FAIL DENIED (false positive)   %s\n       %s\n' "$1" "$out"; fi
  }

  printf '\n-- MUST DENY (each class with an unquoted AND a quoted arm) --\n'
  _deny 'rm -rf $HOME/stuff'
  _deny 'rm -rf "$HOME/stuff"'
  _deny 'rm -rf "$HOME"/stuff'
  _deny "rm -rf '\$HOME/stuff'"
  _deny 'rm -rf ${HOME}/x'
  _deny 'rm -rf "${HOME}/x"'
  _deny 'rm -rf ~'
  _deny 'rm -rf ~/y'
  _deny 'rm -Rf "~/y"'
  _deny 'rm -fr $HOME/x'
  _deny 'rm -r -f $HOME/z'
  _deny 'rm --recursive --force $HOME/q'
  _deny "rm -rf $HOME/x"
  _deny "rm -rf \"$HOME/x\""
  _deny "su""do rm -rf \"$HOME/x\""
  _deny 'rm -rf /'
  _deny 'rm -rf "/"'
  _deny 'git clean -xfd'
  _deny 'git clean -xfd "."'
  _deny 'git clean -fdX'
  _deny 'git commit --no-verify -m x'
  _deny 'git commit --no-verify -m "x"'
  _deny 'git commit -n -m "wip"'
  _deny 'git push --force origin main'
  _deny 'git push --force origin "main"'
  _deny 'git push -f origin master'
  _deny 'git push -f origin "master"'
  _deny 'git push origin +main'
  _deny 'git push origin "+HEAD:main"'
  _deny 'git push origin +refs/heads/master'
  _deny 'git add -f secrets.env'
  _deny 'git add -f ".env"'
  _deny 'git add --force .env'
  _deny 'npm test && git push --force origin "main"'
  _deny 'echo starting; rm -rf "$HOME/x"'

  printf '\n-- MUST ALLOW (any output here is a false positive) --\n'
  _allow 'rm -rf ./node_modules'
  _allow 'rm -rf dist'
  _allow 'rm -rf "dist"'
  _allow 'rm -rf build/cache'
  _allow 'git clean -fd'
  _allow 'git clean -nd'
  _allow 'git commit -m "feat: x"'
  _allow 'git push origin HEAD:feature'
  _allow 'git push origin main'
  _allow 'git push --force-with-lease origin main'
  _allow 'git push --force origin my-topic-branch'
  _allow 'git push origin +HEAD:my-topic-branch'
  _allow 'git add -A'
  _allow 'git add --all'
  _allow 'git status --porcelain'
  _allow 'ls -la'
  _allow 'grep -rn foo .'
  _allow 'npm run build'
  _allow 'pnpm install --frozen-lockfile'
  _allow 'git add -A && rm -f /tmp/scratch'
  _allow 'rm -f /tmp/x && git add -A'
  _allow 'echo "git push --force origin main" > notes.txt'
  _allow "printf '%s' \"rm -rf \$HOME\" > note.txt"
  _allow 'echo "rm -rf ~" | tee note.txt'
  _allow 'rm -rf /tmp/pb-scratch-dir'

  printf '\n-- PRE-FIX (RED) ARM: the defect this rewrite repairs, still reproducible --\n'
  # The researcher's pre-pass, in shape: delete the quoted BODY, then test class 1's patterns.
  # It must ALLOW the quoted form (that IS the bug) while DENYING the unquoted one (that is the
  # instrument control proving the arm can say deny at all). One variable between them: quoting.
  # If this ever goes green, the repair below is no longer attributable to a measured defect.
  _prefix_would_deny() {
    local seg
    seg="$(printf '%s' "$1" | sed -e "s/'[^']*'/ /g" -e 's/"[^"]*"/ /g')"
    case "$seg" in *'$HOME'*|*"$HOME"*|*' ~/'*|*' ~ '*) return 0 ;; esac
    return 1
  }
  n=$((n+1))
  if _prefix_would_deny 'rm -rf $HOME/stuff'; then printf '  ok   PRE-FIX control: the old pass DOES deny the UNQUOTED form\n'
  else bad=$((bad+1)); printf '  FAIL PRE-FIX control could not deny anything — the arm proves nothing\n'; fi
  n=$((n+1))
  if _prefix_would_deny 'rm -rf "$HOME/stuff"'; then
    bad=$((bad+1)); printf '  FAIL PRE-FIX arm went GREEN — quote-body stripping no longer hides the target, so this rewrite is unattributed\n'
  else printf '  ok   PRE-FIX arm is RED: the old pass ALLOWS the QUOTED form (R1, the whole reason for this file)\n'; fi

  printf '\n-- INSTRUMENT CONTROLS --\n'
  n=$((n+1))
  if [ -z "$(hook_verdict '')" ]; then printf '  ok   an empty command says nothing\n'
  else bad=$((bad+1)); printf '  FAIL empty command produced a verdict\n'; fi
  n=$((n+1))
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf \\"$HOME/x\\""}}' | /bin/bash "$HOOK_SELF" 2>/dev/null)"
  case "$out" in *'"deny"'*) printf '  ok   END-TO-END through the real stdin path: a quoted $HOME rm is denied\n' ;;
    *) bad=$((bad+1)); printf '  FAIL end-to-end stdin path allowed it: [%s]\n' "$out" ;;
  esac
  n=$((n+1))
  printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf \\"$HOME/x\\""}}' | /bin/bash "$HOOK_SELF" >/dev/null 2>&1
  if [ $? -eq 0 ]; then printf '  ok   a DENY still exits 0 (Copilot preToolUse fails CLOSED on non-zero)\n'
  else bad=$((bad+1)); printf '  FAIL a deny exited non-zero\n'; fi
  n=$((n+1))
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf \\"$HOME/x\\""}}' | BOOTSTRAP_NO_JQ=1 /bin/bash "$HOOK_SELF" 2>/dev/null)"
  case "$out" in *'"deny"'*) printf '  ok   NO-JQ arm: the nested tool_input.command still resolves and the deny stands\n' ;;
    *) bad=$((bad+1)); printf '  FAIL NO-JQ arm: the guard is INERT without jq: [%s]\n' "$out" ;;
  esac
  n=$((n+1))
  out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | /bin/bash "$HOOK_SELF" 2>/dev/null)"
  if [ -z "$out" ]; then printf '  ok   a harmless command through the real path says nothing\n'
  else bad=$((bad+1)); printf '  FAIL harmless command produced [%s]\n' "$out"; fi

  printf '\n%s/%s cases passed.\n' "$((n - bad))" "$n"
  [ "$bad" = 0 ] && return 0
  return 1
}

case "${1:-}" in
  --selftest) hook_selftest; exit $? ;;
  --wire-me-instructions)
    cat <<'WIRE'
guard-bash.sh ships UNWIRED. Read the header paragraph first, then, if you still want it:

  Claude Code   settings.json                       .hooks.PreToolUse[]  matcher "Bash"
  Copilot CLI   ~/.copilot/hooks/00-lifecycle.json  .hooks.PreToolUse[]  matcher "Bash"

Wire it with the repo's own writer, never by hand-editing a settings file:

  . "$HOME/.mac-bootstrap/hooks/bootstrap-lib.sh"
  bootstrap_hook_wire         "$HOME/.claude/settings.json"            PreToolUse Bash "$HOME/.mac-bootstrap/hooks/guard-bash.sh" 10
  bootstrap_copilot_hook_wire "$HOME/.copilot/hooks/00-lifecycle.json" PreToolUse Bash "$HOME/.mac-bootstrap/hooks/guard-bash.sh" 10

Then re-run `bash "$HOME/.mac-bootstrap/hooks/guard-bash.sh" --selftest`, and know that
verify_hooks will then report FAILED: it asserts this hook is NOT wired, on purpose.
WIRE
    exit 0 ;;
esac

[ "${BOOTSTRAP_BASH_GUARD_HOOK:-1}" = 1 ] || exit 0
HOOK_STDIN="$(cat 2>/dev/null || true)"
HOOK_COMMAND="$(hook_field "$HOOK_STDIN" tool_input.command)"
[ -n "$HOOK_COMMAND" ] || exit 0
hook_verdict "$HOOK_COMMAND" || true
exit 0
