# shellcheck shell=bash
# scripts/checks/microsoft.sh — the two modules that move the person's own mail, calendar and files
# (microsoft365, microsoft365_archive), on a fresh corporate Mac. Sourced by scripts/characterize.sh,
# which supplies the harness; never run on its own. No network, no real npm install, no Microsoft.

MS_GUARD="$CHECK_ROOT/assets/hooks/guard-mail-send.sh"

# ── 1. THE GUARD — every tool that reaches another person in one call, on both agents' spellings ──
# Driven straight at the shipped hook, independently of its own --selftest, so a selftest that
# stopped asserting something cannot hide it. <expect> <tool> <tool_input>, one per line.
MS_GUARD_CASES='deny share-drive-item {"body":{"recipients":[{"email":"a@example.com"}]}}
deny create-drive-item-share-link {"body":{"scope":"anonymous"}}
deny create-drive-item-share-link {"body":{"scope":"organization"}}
deny create-drive-item-share-link {"body":{"type":"view"}}
deny create-mail-rule {"body":{"actions":{"forwardTo":[{"emailAddress":{"address":"a@example.com"}}]}}}
deny update-mail-rule {"body":{"actions":{"redirectTo":[{"emailAddress":{"address":"a@example.com"}}]}}}
deny create-mail-rule {"body":{"actions":{"forwardAsAttachmentTo":[{"emailAddress":{"address":"a@example.com"}}]}}}
deny create-calendar-event {"body":{"attendees":[{"emailAddress":{"address":"a@example.com"}}]}}
deny create-specific-calendar-event {"body":{"Attendees":[{"emailAddress":{"address":"a@example.com"}}]}}
deny update-calendar-event {"body":{"attendees":[{"emailAddress":{"address":"a@example.com"}}]}}
deny update-specific-calendar-event {"body":{"attendees":[]}}
deny accept-calendar-event {"body":{"Comment":"x"}}
deny decline-calendar-event {"body":{"SendResponse":true}}
deny tentatively-accept-calendar-event {"body":{}}
deny cancel-calendar-event {"body":{}}
deny create-my-calendar-permission {"body":{"role":"read"}}
deny create-subscription {"body":{"notificationUrl":"https://example.com/x"}}
deny update-mailbox-settings {"body":{"automaticRepliesSetting":{"status":"alwaysEnabled"}}}
quiet create-drive-item-share-link {"body":{"scope":"users"}}
quiet create-mail-rule {"body":{"actions":{"moveToFolder":"f1"}}}
quiet create-calendar-event {"body":{"subject":"focus"}}
quiet create-calendar-event {"body":{"attendees":[]}}
quiet update-calendar-event {"body":{"subject":"moved"}}
quiet accept-calendar-event {"body":{"SendResponse":false}}
quiet update-mailbox-settings {"body":{"timeZone":"UTC"}}
quiet create-draft-email {"body":{"subject":"x"}}
quiet list-mail-messages {}'
ms_guard_run() {                               # <tool_name> <tool_input> → the hook's stdout, rc
  printf '{"hook_event_name":"PreToolUse","session_id":"characterize","tool_name":"%s","tool_input":%s}' "$1" "$2" \
    | BOOTSTRAP_MAIL_GUARD_DIR="$CHECK_WORK/mail-guard-turns" /bin/bash "$MS_GUARD" 2>/dev/null
}
MS_DENIED=0; MS_QUIET=0; MS_WRONG=""
while read -r ms_want ms_tool ms_input; do
  [ -n "$ms_tool" ] || continue
  for ms_name in "mcp__ms365__$ms_tool" "ms365-$ms_tool"; do
    ms_out="$(ms_guard_run "$ms_name" "$ms_input")"; ms_rc=$?
    case "$ms_want:$ms_rc:$ms_out" in
      deny:0:*'"permissionDecision":"deny"'*) MS_DENIED=$((MS_DENIED + 1)) ;;
      quiet:0:)                               MS_QUIET=$((MS_QUIET + 1)) ;;
      *) MS_WRONG="$MS_WRONG $ms_want:$ms_name(rc $ms_rc)" ;;
    esac
  done
done <<EOF
$MS_GUARD_CASES
EOF
if [ -z "$MS_WRONG" ]; then pass "microsoft-guard-new-denies" "$MS_DENIED denied, $MS_QUIET controls left alone, both spellings"
else fail "microsoft-guard-new-denies" "$MS_WRONG"; fi
# The same tools on ANOTHER server are not ours to judge: the guard must stay silent.
ms_out="$(ms_guard_run mcp__other__share-drive-item '{}')"
same "microsoft-guard-other-server-silent" "$ms_out" ""
if /bin/bash "$MS_GUARD" --selftest > "$CHECK_WORK/mail-guard-selftest.txt" 2>&1; then
  pass "microsoft-guard-selftest" "$(tail -1 "$CHECK_WORK/mail-guard-selftest.txt")"
else
  fail "microsoft-guard-selftest" "$(grep -v '^  ok ' "$CHECK_WORK/mail-guard-selftest.txt" | head -5 | tr '\n' ' ')"
fi
