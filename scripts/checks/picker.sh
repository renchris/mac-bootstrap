# shellcheck shell=bash
# scripts/checks/picker.sh — the menu (`--pick`, and the default at a terminal). Sourced by
# scripts/characterize.sh, which supplies the harness; never run on its own.
#
# The menu has three audiences and each one is checked here: a person answering (through the answer
# file seam, and through a real pseudo-terminal under `cat | bash`, which is what `curl | bash` is), a
# person who walks away or quits (nothing may be installed), and a shell with no person at all (it
# must never wait, and never show the menu uninvited). `perl -e setsid` gives a process with NO
# controlling terminal even when this suite is run from one — without it, a check meant to prove
# "no terminal" would find the developer's terminal and sit on it.

PICK_FIRST="$(printf '%s\n' "$MODULES" | head -1)"
PICK_ANS="$CHECK_WORK/pick-answers"
no_tty() { /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$@"; }

# 1. It installs exactly what was chosen — the rest of the manifest stays untouched.
h="$(fresh_home pick-choose)"
printf 'none 1\n\ny\n' > "$PICK_ANS"
BOOTSTRAP_PICK_INPUT="$PICK_ANS" drive_at "$h" --pick
same "pick-installs-the-choice-rc" "$CHECK_RC" 0
same "pick-installs-only-the-choice" "$(receipt_states "$h/.mac-bootstrap/receipt.json" | tr '\n' ' ')" "$PICK_FIRST SATISFIED "

# 2. A dependency is shown in the confirmation before anything runs. Declining writes nothing.
PICK_NEEDY=""; PICK_IDX=0; i=0
drive_at "$h" --list
for m in $(printf '%s\n' "$CHECK_OUT" | sed -n 's#^[ *]\{4\}\([a-z][a-z0-9_]*\) *\[[a-z]*\].*#\1#p'); do
  i=$((i + 1))
  if printf '%s\n' "$CHECK_OUT" | sed -n "/^[ *]\{4\}$m /,/^\$/p" | grep -q 'needs:'; then PICK_NEEDY="$m"; PICK_IDX="$i"; break; fi
done
if [ -n "$PICK_NEEDY" ]; then
  h="$(fresh_home pick-needs)"
  printf 'none %s\n\nn\nq\n' "$PICK_IDX" > "$PICK_ANS"
  BOOTSTRAP_PICK_INPUT="$PICK_ANS" drive_at "$h" --pick
  PICK_WANTS="$(printf '%s\n' "$CHECK_OUT" | grep -c "note: $PICK_NEEDY needs" | tr -d ' ')"
  if [ "${PICK_WANTS:-0}" -ge 1 ]; then pass "pick-names-its-dependencies" "$PICK_NEEDY"
  else fail "pick-names-its-dependencies" "no 'note: $PICK_NEEDY needs' line"; fi
  same "pick-declined-rc" "$CHECK_RC" 30
  if [ -e "$h/.mac-bootstrap/receipt.json" ] || [ -e "$h/.claude" ]; then fail "pick-declined-writes-nothing"
  else pass "pick-declined-writes-nothing"; fi
else
  pass "pick-names-its-dependencies" "n/a: no module declares needs"
fi

# 3. Walking away installs nothing, and returns at once: end of input is an answer of "no".
h="$(fresh_home pick-eof)"
: > "$PICK_ANS"
t0="$(date +%s)"
BOOTSTRAP_PICK_INPUT="$PICK_ANS" drive_at "$h" --pick
same "pick-eof-rc" "$CHECK_RC" 30
if [ -e "$h/.mac-bootstrap/receipt.json" ] || [ -e "$h/.claude" ]; then fail "pick-eof-writes-nothing"
else pass "pick-eof-writes-nothing" "$(( $(date +%s) - t0 ))s"; fi

# 4. No terminal at all: --pick refuses at once with the flags to use instead …
h="$(fresh_home pick-notty)"
t0="$(date +%s)"
CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_PICK_TIMEOUT=5 no_tty /bin/bash "$CHECK_ROOT/bootstrap.sh" --pick </dev/null 2>&1)"; CHECK_RC=$?
same "pick-without-terminal-rc" "$CHECK_RC" 30
case "$CHECK_OUT" in
  *"--only"*) pass "pick-without-terminal-says-what-to-pass" "$(( $(date +%s) - t0 ))s" ;;
  *) fail "pick-without-terminal-says-what-to-pass" "$(printf '%s' "$CHECK_OUT" | tail -2)" ;;
esac
# … and a plain run shows no menu uninvited: it takes the default profile and says so.
CHECK_OUT="$(HOME="$h" TMPDIR="$CHECK_WORK" no_tty env -u CLAUDECODE -u CI /bin/bash "$CHECK_ROOT/bootstrap.sh" </dev/null 2>&1)"; CHECK_RC=$?
case "$CHECK_OUT" in
  *"no terminal to ask you on"*) pass "no-terminal-takes-the-default" "rc $CHECK_RC" ;;
  *) fail "no-terminal-takes-the-default" "$(printf '%s' "$CHECK_OUT" | sed -n 2p)" ;;
esac
case "$CHECK_OUT" in *"Pick what to install"*) fail "no-terminal-shows-no-menu" ;; *) pass "no-terminal-shows-no-menu" ;; esac

# 5. `curl | bash`: stdin is the SCRIPT, so the answer must come from the terminal. script(1) gives
#    the run a real pseudo-terminal; the answers are typed into it while stdin stays open, as a
#    person's would be — closing it early sends end-of-input, which check 3 covers.
if [ -x /usr/bin/script ]; then
  h="$(fresh_home pick-pty)"
  ( printf 'none 1\n\ny\n'
    w=0; while [ ! -e "$h/.mac-bootstrap/receipt.json" ] && [ "$w" -lt 60 ]; do sleep 1; w=$((w + 1)); done
  ) | ( cd "$CHECK_ROOT" && env -u CLAUDECODE -u CI HOME="$h" TMPDIR="$CHECK_WORK" BOOTSTRAP_PICK_TIMEOUT=30 \
          /usr/bin/script -q "$CHECK_WORK/pick-pty.log" /bin/bash -c 'cat ./bootstrap.sh | /bin/bash' ) >/dev/null 2>&1
  case "$(tr -d '\r' < "$CHECK_WORK/pick-pty.log" 2>/dev/null)" in
    *"Pick what to install"*) pass "pipe-to-bash-shows-the-menu" ;;
    *) fail "pipe-to-bash-shows-the-menu" "no menu in the pty transcript" ;;
  esac
  same "pipe-to-bash-installs-the-choice" "$(receipt_states "$h/.mac-bootstrap/receipt.json" | tr '\n' ' ')" "$PICK_FIRST SATISFIED "
else
  pass "pipe-to-bash-shows-the-menu" "n/a: no /usr/bin/script"
fi
