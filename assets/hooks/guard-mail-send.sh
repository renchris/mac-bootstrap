#!/bin/bash
# guard-mail-send.sh — PreToolUse + UserPromptSubmit. The agent never sends email on its own say-so.
#
# PREVENTS: an agent putting mail on the wire that the person never read. A Microsoft Graph send is
# immediate and irreversible — Outlook's "undo send" is a client-side delay that does not exist on
# this path — so the only moment to stop one is before the tool call.
# CAUSES, for the ms365 server's mail tools, on BOTH agents:
#   1. COMPOSE-AND-SEND IS DENIED, ALWAYS. The tools that write AND transmit in one call
#      (send-mail, reply-*, forward-*, their shared-mailbox twins, group-thread replies, calendar
#      forwards) are refused with the draft tool to use instead. No override: an escape hatch
#      conditioned on "the user said to send it" is worthless, because a model asserting that
#      consent is exactly the failure being prevented.
#   2. ONE TURN MAY COMPOSE OR SEND, NEVER BOTH. send-draft-message is allowed — sending a draft
#      the person could open and read first — but not in a turn that wrote or changed a draft,
#      because create-draft then send-draft is send-mail with extra steps. A prompt the person
#      TYPES starts a new turn; injected traffic (task notifications, Stop-hook feedback) does not.
#      No session id means no way to tell, so the send is refused: it fails CLOSED.
#   3. A BATCH MAY ONLY READ. graph-batch forwards up to 20 raw Graph requests, so one POST inside it
#      reaches /me/sendMail — and every other write — without passing rules 1 or 2 (measured: before
#      this rule a batched POST /me/sendMail was allowed, rc 0 and silent). It is allowed only when
#      every sub-request is a GET; a batch whose request list cannot be read is refused.
#   4. THE SIGN-IN IS THE PERSON'S. logout and remove-account delete it and select-account switches
#      it for every session sharing the server's cache; only a person can put either back. The tools
#      take an account parameter per call, so nothing an agent legitimately does needs them.
#   5. NOTHING ELSE LEAVES IN ONE CALL EITHER. Mail is not the only way a tool puts data in front of
#      someone else. Each of these acts on another person the moment it runs, and each is refused,
#      with a way to prepare the same thing for the person to finish instead:
#        share-drive-item                        grants access, and can email an invitation
#        create-drive-item-share-link            any link but a "users" link naming nobody: an
#                                                anonymous or organization link is readable by
#                                                whoever gets the URL; a missing scope is the tenant
#                                                default, which may be anonymous
#        create-/update-mail-rule                a forwardTo, forwardAsAttachmentTo or redirectTo
#                                                action sends every matching message on, for good
#        create-(specific-)calendar-event        attendees: Exchange sends the invitation, body included
#        update-(specific-)calendar-event        any attendee list: adding sends invitations, and
#                                                removing sends cancellations
#        accept-/decline-/tentatively-accept-…   unless sendResponse is false: the reply and its
#                                                comment go to the organizer
#        cancel-calendar-event                   sends the cancellation, comment included, to everyone
#        create-/update-my-calendar-permission   shares the calendar with an address
#        create-/update-subscription             Graph pushes change notifications to any https URL
#        update-mailbox-settings                 automaticRepliesSetting answers every sender
#      Graph reads property names in any letter case (this server's own schema spells accept's
#      SendResponse and Comment in PascalCase), so a key is matched in any case, anywhere in the
#      payload, both as sent and as plutil decodes it — "Attendees", "attendees" and a key
#      sent twice all count. (Measured: plutil decodes an escaped key and keeps null.)
#
# KNOWN GAP of rule 5: changing the body or time of a meeting that already HAS attendees makes
# Exchange send them the update. The guard cannot see an event's attendees without asking Graph,
# and refusing every calendar edit would refuse editing the person's own appointments.
#
# ── HOW A TURN IS SEEN, AND WHY NOT FROM THE TRANSCRIPT ─────────────────────────────────────
# The obvious design reads the transcript back to the last human prompt. Copilot CLI 1.0.83 sends
# no transcript path (measured: its PreToolUse payload is hook_event_name, session_id, timestamp,
# cwd, tool_name, tool_input). So the guard keeps its own record instead: a compose tool touches
# turns/<session>.composed, and a genuine UserPromptSubmit removes it. Both agents fire both events
# with session_id and (for the prompt) `prompt` — measured on Copilot with a fake ms365 server.
#
# ── TOOL NAMES DIFFER BY AGENT (measured) ────────────────────────────────────────────────────
#   Claude Code  mcp__ms365__send-mail        Copilot CLI  ms365-send-mail
# Both deny shapes were measured honoured by Copilot; the Claude Code envelope below is the one
# its docs specify and the one this Mac's own mail guard has used in production.
#
# KNOWN GAP, stated so nobody over-trusts it: an agent that issues create-draft and send-draft in
# ONE parallel batch can have the send's PreToolUse run before the compose's (Copilot ran them out
# of order in the probe). Sending the draft just written needs its id, which only the compose's
# RESULT carries, so the draft this turn wrote cannot be sent that way — an older draft could.
#
# 🚨 EVERY EXIT PATH IS AN EXPLICIT 0. Copilot's preToolUse FAILS CLOSED on a non-zero exit, and on
# Copilot this hook sees every tool call, so a crash here would block the agent's every tool.
# Seams: BOOTSTRAP_MAIL_GUARD_DIR (where turn markers live). Self-test: bash guard-mail-send.sh --selftest
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || HOOK_DIR="."
HOOK_SELF="$HOOK_DIR/$(basename "${BASH_SOURCE[0]:-$0}")"
# shellcheck source=bootstrap-lib.sh disable=SC1091
. "$HOOK_DIR/bootstrap-lib.sh" 2>/dev/null || exit 0

MAIL_SERVER_KEY="ms365"
# Write AND transmit in one call → denied, with the tool that composes the same thing as a draft.
mail_draft_instead() {
  case "$1" in
    send-mail)                     printf 'create-draft-email' ;;
    reply-mail-message)            printf 'create-reply-draft' ;;
    reply-all-mail-message)        printf 'create-reply-all-draft' ;;
    forward-mail-message)          printf 'create-forward-draft' ;;
    send-shared-mailbox-mail)      printf 'create-shared-mailbox-draft' ;;
    reply-shared-mailbox-mail|reply-all-shared-mailbox-mail|forward-shared-mailbox-mail)
                                   printf 'create-shared-mailbox-draft' ;;
    reply-to-group-thread|forward-calendar-event)
                                   printf 'nothing — tell the person what you would send and let them send it' ;;
    *) return 1 ;;
  esac
}
# Writing or changing a draft's content. update-mail-message counts only when it touches content
# (flagging or marking read must not trip the gate); attachments are content.
mail_composes_always() {
  case "$1" in
    create-draft-email|create-reply-draft|create-reply-all-draft|create-forward-draft\
    |create-shared-mailbox-draft|add-mail-attachment|create-mail-attachment-upload-session) return 0 ;;
  esac
  return 1
}
MAIL_CONTENT_KEYS="body subject toRecipients ccRecipients bccRecipients"
# Injected traffic that arrives as a "prompt" but was typed by no one.
mail_auto_prompt() {
  case "$1" in
    '<task-notification>'*|'<local-command-stdout>'*|'<teammate-message'*|'Stop hook feedback:'*\
    |'[Request interrupted'*|'<system-reminder>'*) return 0 ;;
  esac
  return 1
}

mail_turns_dir() { printf '%s' "${BOOTSTRAP_MAIL_GUARD_DIR:-$HOOK_DIR/turns}"; }

# The payload goes to a temp file ONCE and every field is read through plutil — nested keys,
# booleans and embedded quotes included — so the jq and no-jq machines take the same path.
MAIL_PAYLOAD=""
mail_field() { bootstrap_settings_get "$MAIL_PAYLOAD" "$1" raw 2>/dev/null; }
mail_has()   { bootstrap_settings_type "$MAIL_PAYLOAD" "$1" >/dev/null 2>&1; }

# mail_batch_reads_only — rc 0 iff graph-batch's request list is readable, non-empty, and every
# method is GET (Graph reads the method case-insensitively, so this does too). Both placements are
# accepted: under body, where the server's schema puts it, and at the top of tool_input.
mail_batch_reads_only() {
  local k n i m
  for k in tool_input.body.requests tool_input.requests; do
    [ "$(bootstrap_settings_type "$MAIL_PAYLOAD" "$k" 2>/dev/null)" = array ] || continue
    n="$(bootstrap_settings_get "$MAIL_PAYLOAD" "$k" raw 2>/dev/null)" || return 1
    case "$n" in ''|*[!0-9]*|0) return 1 ;; esac
    i=0
    while [ "$i" -lt "$n" ]; do
      m="$(mail_field "$k.$i.method" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
      [ "$m" = GET ] || return 1
      i=$((i + 1))
    done
    return 0
  done
  return 1
}

# The payload as sent AND as plutil decodes it, each collapsed onto one line, for the any-case key
# scan of rule 5. Keys inside a JSON string are escaped (\"name\"), so they never match "name":.
MAIL_SCAN=""
mail_scan_load() {
  MAIL_SCAN="$(printf '%s' "$1" | LC_ALL=C tr '\n\r\t' '   ')
$(/usr/bin/plutil -convert json -o - "$MAIL_PAYLOAD" 2>/dev/null | LC_ALL=C tr '\n\r\t' '   ')"
}
# mail_key_count <name> [<value-regex>] — how many times a key named <name>, in any letter case, occurs
# in the scan; with a value regex, only the occurrences whose value matches it whole.
mail_key_count() {
  local re="\"$1\"[[:space:]]*:"
  [ -n "${2:-}" ] && re="${re}[[:space:]]*($2)[[:space:]]*[],}]"
  printf '%s\n' "$MAIL_SCAN" | LC_ALL=C grep -o -i -E "$re" 2>/dev/null | bootstrap_count
}
MAIL_EMPTY='null|false|""|\[[[:space:]]*\]|\{[[:space:]]*\}'
# mail_carries <name> — rc 0 iff some key named <name> holds a value that is not empty.
mail_carries() { [ "$(mail_key_count "$1")" -gt "$(mail_key_count "$1" "$MAIL_EMPTY")" ]; }
# mail_all <name> <value-regex> — rc 0 iff <name> occurs, and every occurrence's value matches.
mail_all() {
  local n
  n="$(mail_key_count "$1")"
  [ "$n" -gt 0 ] && [ "$n" = "$(mail_key_count "$1" "$2")" ]
}

# mail_reaches_others <tool> — rule 5. Prints why the call reaches another person and what to do
# instead (rc 0), or rc 1 when it reaches no one.
mail_reaches_others() {
  local k
  case "$1" in
    share-drive-item)
      printf 'share-drive-item gives another person access to a file, and can email them an invitation. Tell the person which file and with whom; they share it from OneDrive.' ;;
    create-drive-item-share-link)
      if mail_all scope '"users"' && ! mail_carries recipients && ! mail_carries sendNotification; then return 1; fi
      printf 'create-drive-item-share-link was refused: an anonymous or organization link, a link with no scope (the tenant default may be anonymous), or one that names recipients hands the file to people the person did not pick. A link with scope "users" and no recipients works only for people who can already open it; to share with anyone else, the person shares it from OneDrive.' ;;
    create-mail-rule|update-mail-rule)
      for k in forwardTo forwardAsAttachmentTo redirectTo; do
        mail_carries "$k" && {
          printf '%s was refused because it carries a %s action, which sends every matching message on to another address, for good. A rule that moves, flags or categorises is fine; forwarding is set up by the person in Outlook.' "$1" "$k"
          return 0; }
      done
      return 1 ;;
    create-calendar-event|create-specific-calendar-event)
      mail_carries attendees || return 1
      printf '%s was refused because it has attendees, and Exchange emails each of them the invitation, body included, the moment it is created. Create it with no attendees and tell the person whom to invite; they send the invitation from Outlook.' "$1" ;;
    update-calendar-event|update-specific-calendar-event)
      [ "$(mail_key_count attendees)" -gt 0 ] || return 1
      printf '%s was refused because it changes the attendee list: Exchange emails an invitation to everyone added and a cancellation to everyone removed. Change the other fields, and tell the person whom to add or remove; they do it in Outlook.' "$1" ;;
    accept-calendar-event|decline-calendar-event|tentatively-accept-calendar-event)
      mail_all sendResponse false && return 1
      printf '%s was refused because it would send a reply, and any comment, to the organizer. Pass sendResponse false to record the answer silently, or tell the person what to answer; they reply from Outlook.' "$1" ;;
    cancel-calendar-event)
      printf 'cancel-calendar-event emails the cancellation, and its comment, to every attendee. Tell the person which meeting to cancel; they cancel it from Outlook.' ;;
    create-my-calendar-permission|update-my-calendar-permission)
      printf '%s shares the calendar with another address. Tell the person whom to share it with and at what level; they share it from Outlook.' "$1" ;;
    create-subscription|update-subscription)
      printf '%s sends change notifications to a URL outside Microsoft. Read changes with the list and delta tools instead.' "$1" ;;
    update-mailbox-settings)
      mail_carries automaticRepliesSetting || return 1
      printf 'update-mailbox-settings was refused because an automatic reply answers everyone who writes, with text the person has not read. Tell the person what the reply should say; they turn it on in Outlook.' ;;
    *) return 1 ;;
  esac
  return 0
}

mail_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(printf '%s' "$1" | LC_ALL=C tr -d '"\\' | LC_ALL=C tr '\n\r\t' '   ')"
}

mail_main() {
  local raw ev sid tool name d prompt k
  raw="$(cat 2>/dev/null)" || raw=""
  # Fast path: on Copilot this runs for EVERY tool call, and nearly none of them are mail.
  case "$raw" in *UserPromptSubmit*|*"$MAIL_SERVER_KEY"*) : ;; *) return 0 ;; esac

  MAIL_PAYLOAD="$(mktemp -t mailguard 2>/dev/null)" || return 0
  printf '%s' "$raw" > "$MAIL_PAYLOAD" 2>/dev/null
  ev="$(mail_field hook_event_name)"
  sid="$(mail_field session_id | LC_ALL=C tr -cd 'A-Za-z0-9._-')"
  d="$(mail_turns_dir)"

  if [ "$ev" = "UserPromptSubmit" ]; then
    prompt="$(mail_field prompt)"
    if [ -n "$sid" ] && ! mail_auto_prompt "$prompt"; then
      rm -f "$d/$sid.composed" 2>/dev/null
      find "$d" -name '*.composed' -mtime +2 -delete 2>/dev/null   # abandoned sessions
    fi
    return 0
  fi
  [ "$ev" = "PreToolUse" ] || return 0

  tool="$(mail_field tool_name)"
  case "$tool" in
    "mcp__${MAIL_SERVER_KEY}__"*) name="${tool#"mcp__${MAIL_SERVER_KEY}__"}" ;;   # Claude Code
    "${MAIL_SERVER_KEY}-"*)       name="${tool#"${MAIL_SERVER_KEY}-"}" ;;           # Copilot CLI
    *) return 0 ;;
  esac

  if k="$(mail_draft_instead "$name")"; then
    mail_deny "$name sends email the moment it runs, and this Mac never lets an agent do that. Write it as a draft with $k instead; the person reads it in Outlook and sends it, or tells you to send it in their next message."
    return 0
  fi

  mail_scan_load "$raw"
  if k="$(mail_reaches_others "$name")"; then
    mail_deny "$k"
    return 0
  fi

  if [ "$name" = "graph-batch" ]; then
    mail_batch_reads_only || mail_deny "graph-batch was refused because it carries a request that is not a GET, or a request list this guard cannot read. A batched POST reaches /me/sendMail and every other write without the checks the named tools get. Batch reads only, and make a write with its own tool — mail as a draft with create-draft-email."
    return 0
  fi
  case "$name" in
    logout|remove-account|select-account)
      mail_deny "$name changes which Microsoft account this Mac is signed in to, for every session sharing it, and only the person can put that back. Pass the account parameter on each call instead. If they want to sign out, they run the server with --logout themselves."
      return 0 ;;
  esac

  if mail_composes_always "$name"; then
    [ -n "$sid" ] && mkdir -p "$d" 2>/dev/null && touch "$d/$sid.composed" 2>/dev/null
    return 0
  fi
  if [ "$name" = "update-mail-message" ]; then
    for k in $MAIL_CONTENT_KEYS; do
      if mail_has "tool_input.body.$k"; then
        [ -n "$sid" ] && mkdir -p "$d" 2>/dev/null && touch "$d/$sid.composed" 2>/dev/null
        break
      fi
    done
    return 0
  fi

  if [ "$name" = "send-draft-message" ]; then
    if [ -z "$sid" ]; then
      mail_deny "send-draft-message was refused because this call carries no session id, so there is no way to tell whether this turn wrote the draft. The person can send it from Outlook."
    elif [ -e "$d/$sid.composed" ]; then
      mail_deny "send-draft-message was refused because this turn wrote or changed a draft, and the person has not seen it yet. Say the draft is ready in Outlook and stop; if they tell you to send it, their message starts a new turn and the send is allowed."
    fi
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════════════════════
# SHIPPED FIXTURES — both tool-name dialects, both engines, and the negative controls that make a
# deny mean something: a read tool, another server's send-mail, and a non-mail tool stay silent.
mail_selftest() {
  local T n=0 f=0 arm
  T="$(mktemp -d -t mailguardself)" || return 1
  run() { BOOTSTRAP_MAIL_GUARD_DIR="$T/turns" /bin/bash "$HOOK_SELF" 2>/dev/null; }
  # The default input is set on its own line: `${3:-{\}}` yields {} under bash 5 but {\} under
  # /bin/bash 3.2 — invalid JSON — so the fixtures passed on one shell and failed on the target one.
  pre() {
    local ti="${3:-}"
    [ -n "$ti" ] || ti='{}'
    printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"%s","tool_input":%s}' "$1" "$2" "$ti"
  }
  said() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"%s"}' "$1" "$2"; }
  expect() {   # <label> <deny|quiet> <payload>
    local out rc
    out="$(printf '%s' "$3" | run)"; rc=$?
    n=$((n + 1))
    if [ "$rc" != 0 ]; then f=$((f + 1)); printf '  FAIL %s (rc %s)\n' "$1" "$rc"; return; fi
    case "$2:$out" in
      deny:*'"permissionDecision":"deny"'*|quiet:) printf '  ok   %s\n' "$1" ;;
      *) f=$((f + 1)); printf '  FAIL %s\n       got [%s]\n' "$1" "$out" ;;
    esac
  }
  for arm in jq nojq; do
    if [ "$arm" = nojq ]; then export BOOTSTRAP_NO_JQ=1; else unset BOOTSTRAP_NO_JQ; fi
    rm -rf "$T/turns"
    expect "[$arm] Claude Code send-mail is denied"          deny  "$(pre s1 mcp__ms365__send-mail)"
    expect "[$arm] Copilot send-mail is denied"              deny  "$(pre s1 ms365-send-mail)"
    expect "[$arm] shared-mailbox reply is denied"           deny  "$(pre s1 mcp__ms365__reply-shared-mailbox-mail)"
    expect "[$arm] calendar forward is denied"               deny  "$(pre s1 ms365-forward-calendar-event)"
    expect "[$arm] reading mail is untouched"                quiet "$(pre s1 mcp__ms365__list-mail-messages)"
    expect "[$arm] ANOTHER server's send-mail is untouched"  quiet "$(pre s1 mcp__other__send-mail)"
    expect "[$arm] a non-mail tool is untouched"             quiet "$(pre s1 Bash '{"command":"ms365 send-mail"}')"
    expect "[$arm] send-draft with nothing composed passes"  quiet "$(pre s1 mcp__ms365__send-draft-message)"
    expect "[$arm] flagging a message is not composing"      quiet "$(pre s1 mcp__ms365__update-mail-message '{"body":{"isRead":true}}')"
    expect "[$arm] …so send-draft still passes"              quiet "$(pre s1 ms365-send-draft-message)"
    expect "[$arm] create-draft-email is allowed"            quiet "$(pre s1 mcp__ms365__create-draft-email)"
    expect "[$arm] send-draft in the SAME turn is denied"    deny  "$(pre s1 ms365-send-draft-message)"
    expect "[$arm] injected traffic is not a new turn"       quiet "$(said s1 '<task-notification>done')"
    expect "[$arm] …so send-draft is still denied"           deny  "$(pre s1 mcp__ms365__send-draft-message)"
    expect "[$arm] another session is unaffected"            quiet "$(pre s2 mcp__ms365__send-draft-message)"
    expect "[$arm] a typed prompt starts a new turn"         quiet "$(said s1 'send it')"
    expect "[$arm] …and the send is allowed"                 quiet "$(pre s1 mcp__ms365__send-draft-message)"
    expect "[$arm] editing a draft's subject IS composing"   quiet "$(pre s1 ms365-update-mail-message '{"body":{"subject":"x"}}')"
    expect "[$arm] …so send-draft is denied again"           deny  "$(pre s1 ms365-send-draft-message)"
    expect "[$arm] no session id: send-draft fails closed"   deny  '{"hook_event_name":"PreToolUse","tool_name":"mcp__ms365__send-draft-message","tool_input":{}}'
    expect "[$arm] garbage in exits 0 silently"              quiet 'not json ms365'
    expect "[$arm] batched POST /me/sendMail is denied"      deny  "$(pre s3 mcp__ms365__graph-batch '{"body":{"requests":[{"id":"1","method":"GET","url":"/me"},{"id":"2","method":"POST","url":"/me/sendMail","body":{}}]}}')"
    expect "[$arm] a lowercase post is still a post"         deny  "$(pre s3 ms365-graph-batch '{"body":{"requests":[{"id":"1","method":"post","url":"/me/messages/x/send"}]}}')"
    expect "[$arm] a batch with no request list is denied"   deny  "$(pre s3 mcp__ms365__graph-batch '{"body":{}}')"
    expect "[$arm] an empty request list is denied"          deny  "$(pre s3 mcp__ms365__graph-batch '{"body":{"requests":[]}}')"
    expect "[$arm] a batch of GETs passes"                   quiet "$(pre s3 mcp__ms365__graph-batch '{"body":{"requests":[{"id":"1","method":"GET","url":"/me"},{"id":"2","method":"get","url":"/me/events"}]}}')"
    expect "[$arm] top-level requests of GETs pass"          quiet "$(pre s3 ms365-graph-batch '{"requests":[{"id":"1","method":"GET","url":"/me"}]}')"
    expect "[$arm] ANOTHER server's graph-batch is untouched" quiet "$(pre s3 mcp__other__graph-batch '{"body":{"requests":[{"id":"1","method":"POST","url":"/x"}]}}')"
    expect "[$arm] logout is denied"                         deny  "$(pre s3 mcp__ms365__logout)"
    expect "[$arm] remove-account is denied"                 deny  "$(pre s3 ms365-remove-account)"
    expect "[$arm] select-account is denied"                 deny  "$(pre s3 mcp__ms365__select-account)"
    expect "[$arm] list-accounts is untouched"               quiet "$(pre s3 mcp__ms365__list-accounts)"
    # rule 5 — one call that puts data in front of someone else, on both spellings
    expect "[$arm] share-drive-item is denied"               deny  "$(pre s4 mcp__ms365__share-drive-item '{"body":{"recipients":[{"email":"a@example.com"}],"roles":["read"]}}')"
    expect "[$arm] Copilot share-drive-item is denied"       deny  "$(pre s4 ms365-share-drive-item)"
    expect "[$arm] an anonymous share link is denied"        deny  "$(pre s4 mcp__ms365__create-drive-item-share-link '{"body":{"type":"view","scope":"anonymous"}}')"
    expect "[$arm] an organization share link is denied"     deny  "$(pre s4 ms365-create-drive-item-share-link '{"body":{"type":"edit","scope":"organization"}}')"
    expect "[$arm] a share link with no scope is denied"     deny  "$(pre s4 mcp__ms365__create-drive-item-share-link '{"body":{"type":"view"}}')"
    expect "[$arm] a users link naming someone is denied"    deny  "$(pre s4 ms365-create-drive-item-share-link '{"body":{"scope":"users","recipients":[{"email":"a@example.com"}]}}')"
    expect "[$arm] a users link naming nobody passes"        quiet "$(pre s4 mcp__ms365__create-drive-item-share-link '{"body":{"type":"view","scope":"users"}}')"
    expect "[$arm] a forwarding rule is denied"              deny  "$(pre s4 mcp__ms365__create-mail-rule '{"mailFolderId":"inbox","body":{"displayName":"x","actions":{"forwardTo":[{"emailAddress":{"address":"a@example.com"}}]}}}')"
    expect "[$arm] Copilot redirecting rule update is denied" deny "$(pre s4 ms365-update-mail-rule '{"body":{"actions":{"redirectTo":[{"emailAddress":{"address":"a@example.com"}}]}}}')"
    expect "[$arm] a PascalCase forward-as-attachment is denied" deny "$(pre s4 mcp__ms365__create-mail-rule '{"body":{"Actions":{"ForwardAsAttachmentTo":[{"emailAddress":{"address":"a@example.com"}}]}}}')"
    expect "[$arm] a rule that only moves passes"            quiet "$(pre s4 ms365-create-mail-rule '{"body":{"displayName":"x","actions":{"moveToFolder":"f1"}}}')"
    expect "[$arm] clearing a rule's forward passes"         quiet "$(pre s4 mcp__ms365__update-mail-rule '{"body":{"actions":{"forwardTo":[]}}}')"
    expect "[$arm] an event with attendees is denied"        deny  "$(pre s4 mcp__ms365__create-calendar-event '{"body":{"subject":"x","attendees":[{"emailAddress":{"address":"a@example.com"}}]}}')"
    expect "[$arm] Copilot specific event with Attendees is denied" deny "$(pre s4 ms365-create-specific-calendar-event '{"calendarId":"c","body":{"Attendees":[{"emailAddress":{"address":"a@example.com"}}]}}')"
    expect "[$arm] an escaped attendees key is denied"       deny  "$(pre s4 mcp__ms365__create-calendar-event '{"body":{"\u0061ttendees":[{"emailAddress":{"address":"a@example.com"}}]}}')"
    expect "[$arm] attendees sent twice, last empty, is denied" deny "$(pre s4 ms365-create-calendar-event '{"body":{"attendees":[{"emailAddress":{"address":"a@example.com"}}],"attendees":[]}}')"
    expect "[$arm] an event with no attendees passes"        quiet "$(pre s4 mcp__ms365__create-calendar-event '{"body":{"subject":"focus","start":{"dateTime":"2026-09-16T09:00:00","timeZone":"UTC"}}}')"
    expect "[$arm] an empty attendee list passes"            quiet "$(pre s4 ms365-create-calendar-event '{"body":{"subject":"x","attendees":[]}}')"
    expect "[$arm] a null attendee list passes"              quiet "$(pre s4 mcp__ms365__create-calendar-event '{"body":{"subject":"x","attendees":null}}')"
    expect "[$arm] attendees quoted in the body text pass"   quiet "$(pre s4 mcp__ms365__create-calendar-event '{"body":{"body":{"content":"{\"attendees\": [\"a@example.com\"]}"}}}')"
    expect "[$arm] removing every attendee is denied"        deny  "$(pre s4 mcp__ms365__update-calendar-event '{"eventId":"e","body":{"attendees":[]}}')"
    expect "[$arm] Copilot specific event attendee update is denied" deny "$(pre s4 ms365-update-specific-calendar-event '{"body":{"attendees":[{"emailAddress":{"address":"a@example.com"}}]}}')"
    expect "[$arm] moving an event passes"                   quiet "$(pre s4 ms365-update-calendar-event '{"eventId":"e","body":{"start":{"dateTime":"2026-09-16T10:00:00","timeZone":"UTC"}}}')"
    expect "[$arm] accept with no sendResponse is denied"    deny  "$(pre s4 mcp__ms365__accept-calendar-event '{"eventId":"e","body":{}}')"
    expect "[$arm] Copilot decline with a comment is denied" deny  "$(pre s4 ms365-decline-calendar-event '{"body":{"SendResponse":true,"Comment":"x"}}')"
    expect "[$arm] a false and a true sendResponse is denied" deny "$(pre s4 mcp__ms365__tentatively-accept-calendar-event '{"body":{"sendResponse":false,"SendResponse":true}}')"
    expect "[$arm] a silent accept passes"                   quiet "$(pre s4 mcp__ms365__accept-calendar-event '{"body":{"SendResponse":false}}')"
    expect "[$arm] a silent decline with a comment passes"   quiet "$(pre s4 ms365-decline-calendar-event '{"body":{"sendResponse":false,"comment":"x"}}')"
    expect "[$arm] cancel-calendar-event is denied"          deny  "$(pre s4 mcp__ms365__cancel-calendar-event '{"eventId":"e","body":{}}')"
    expect "[$arm] sharing the calendar is denied"           deny  "$(pre s4 ms365-create-my-calendar-permission '{"body":{"emailAddress":{"address":"a@example.com"},"role":"read"}}')"
    expect "[$arm] a change-notification webhook is denied"  deny  "$(pre s4 mcp__ms365__create-subscription '{"body":{"notificationUrl":"https://example.com/x","resource":"me/messages"}}')"
    expect "[$arm] an automatic reply is denied"             deny  "$(pre s4 ms365-update-mailbox-settings '{"body":{"automaticRepliesSetting":{"status":"alwaysEnabled","externalReplyMessage":"x"}}}')"
    expect "[$arm] a time-zone change passes"                quiet "$(pre s4 mcp__ms365__update-mailbox-settings '{"body":{"timeZone":"UTC"}}')"
    expect "[$arm] listing events is untouched"              quiet "$(pre s4 ms365-list-calendar-events)"
    expect "[$arm] ANOTHER server's share-drive-item is untouched" quiet "$(pre s4 mcp__other__share-drive-item)"
  done
  rm -rf "$T"
  printf '%s/%s cases passed.\n' "$((n - f))" "$n"
  [ "$f" = 0 ]
}

case "${1:-}" in
  --selftest) mail_selftest; exit $? ;;
esac
mail_main
[ -n "$MAIL_PAYLOAD" ] && rm -f "$MAIL_PAYLOAD" 2>/dev/null
exit 0
