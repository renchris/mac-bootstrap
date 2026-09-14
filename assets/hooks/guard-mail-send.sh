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
