#!/bin/bash
# verify.sh — cold, standalone re-verification of the machine.
#
#   bash verify.sh                 verify every module
#   bash verify.sh --only m1_statusline
#   bash verify.sh --no-selftest   skip the instrument control (not recommended)
#
# It changes NOTHING. It writes $HOME/.mac-bootstrap/receipt.verify.json and never touches
# receipt.json — the run's record of what needs the human is the one file a verification step
# must not be able to destroy.
#
# WHY THIS IS A WRAPPER AND NOT A SECOND IMPLEMENTATION. The point of a cold verifier is that it
# cannot DRIFT from the installer: the same `verify_<module>` functions, sourced from disk in a
# fresh process, read the end state back through a different code path than the one that wrote
# it. A verifier with its own copy of the state machine would be a second thing to keep in step,
# and the first divergence would be invisible. So the state machine lives in bootstrap.sh, once,
# and this file adds the two things a wrapper can add honestly:
#
#   1. A POSITIVE CONTROL ON THE INSTRUMENT, run BEFORE the verdict. `pb-lib.sh --selftest`
#      exercises the shared library's own fixtures — including the C1 pre-fix arm, which asserts
#      that `plutil -replace` against an empty root dict still FAILS. If the instrument cannot
#      reproduce the defect it repairs, a green verdict from it means nothing, so this exits 30
#      (precondition) rather than reporting a machine state it is not entitled to report.
#   2. A plain-English render of the receipt, and the exact command for each step that is yours.
#
# Exit codes are bootstrap.sh's, unchanged: 0 every module satisfied · 10 satisfied but waiting
# on you · 20 something failed · 30 this run is not a verdict.

set -u

VF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || VF_HERE="."
VF_STATE="$HOME/.mac-bootstrap"
VF_RECEIPT="$VF_STATE/receipt.verify.json"
VF_SELFTEST=1
VF_ARGS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-selftest) VF_SELFTEST=0 ;;
    --only)        [ $# -ge 2 ] || { printf 'verify: --only needs a module name\n' >&2; exit 30; }
                   VF_ARGS="$VF_ARGS --only $2"; shift ;;
    --help|-h)     sed -n '2,27p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             printf 'verify: unknown argument: %s   (try --help)\n' "$1" >&2; exit 30 ;;
  esac
  shift
done

VF_BOOT="$VF_HERE/bootstrap.sh"
VF_LIB="$VF_HERE/assets/hooks/pb-lib.sh"
[ -r "$VF_LIB" ] || VF_LIB="$VF_STATE/assets/hooks/pb-lib.sh"

if [ ! -r "$VF_BOOT" ]; then
  printf 'verify: bootstrap.sh is not beside this file (%s).\n' "$VF_HERE" >&2
  printf '  Run it from a clone of the repo, or use:  bash bootstrap.sh --verify\n' >&2
  exit 30
fi

# ── 1. the control arm ───────────────────────────────────────────────────────────────────────
if [ "$VF_SELFTEST" = 1 ]; then
  if [ -r "$VF_LIB" ]; then
    printf 'control: pb-lib fixtures ... '
    if VF_OUT="$(/bin/bash "$VF_LIB" --selftest 2>&1)"; then
      printf '%s\n' "$(printf '%s' "$VF_OUT" | tail -1)"
    else
      printf 'FAILED\n'
      printf '%s\n' "$VF_OUT" | grep -v '^  ok ' 
      printf '\nverify: the instrument failed its own fixtures, so any verdict it produced about\n' >&2
      printf '        your Mac would be meaningless. Nothing was verified.\n' >&2
      exit 30
    fi
  else
    printf 'verify: cannot find assets/hooks/pb-lib.sh — no control arm available.\n' >&2
    exit 30
  fi
fi

# ── 2. the verdict, produced by the one implementation ───────────────────────────────────────
printf '\n'
# shellcheck disable=SC2086  # VF_ARGS is a deliberately word-split flag list
/bin/bash "$VF_BOOT" --verify $VF_ARGS
VF_RC=$?

# ── 3. the render ────────────────────────────────────────────────────────────────────────────
if [ -r "$VF_LIB" ] && [ -r "$VF_RECEIPT" ]; then
  # shellcheck source=assets/hooks/pb-lib.sh
  . "$VF_LIB" 2>/dev/null || true
  printf '\n%s\n' "----------------------------------------------------------------------"
  vf_i=0; vf_gestures=""
  while [ "$vf_i" -lt 64 ]; do
    vf_m="$(pb_settings_get "$VF_RECEIPT" "modules.$vf_i.module" raw 2>/dev/null)" || break
    [ -n "$vf_m" ] || break
    vf_s="$(pb_settings_get "$VF_RECEIPT" "modules.$vf_i.state" raw 2>/dev/null)" || vf_s="?"
    vf_n="$(pb_settings_get "$VF_RECEIPT" "modules.$vf_i.note" raw 2>/dev/null)" || vf_n=""
    vf_g="$(pb_settings_get "$VF_RECEIPT" "modules.$vf_i.human_command" raw 2>/dev/null)" || vf_g=""
    printf '%-16s %-12s %s\n' "$vf_m" "$vf_s" "$vf_n"
    [ -n "$vf_g" ] && vf_gestures="$vf_gestures
  $vf_g"
    vf_i=$((vf_i + 1))
  done
  [ "$vf_i" = 0 ] && printf '(no modules recorded)\n'
  if [ -n "$vf_gestures" ]; then
    printf '\nThese are yours — each line is a command, executable as typed:%s\n' "$vf_gestures"
  fi
fi

exit "$VF_RC"
